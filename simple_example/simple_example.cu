// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * simple_example.cu
 *
 * @brief Simple example driver for all three primitives
 */

#include <stdio.h> 
#include <string>
#include <deque>
#include <vector>
#include <iostream>

// Utilities and correctness-checking
#include <gunrock/util/test_utils.cuh>

// Graph construction utils
#include <gunrock/graphio/market.cuh>

// CC includes
#include <gunrock/app/cc/cc_enactor.cuh>
#include <gunrock/app/cc/cc_problem.cuh>
#include <gunrock/app/cc/cc_functor.cuh>

// BFS includes
#include <gunrock/app/bfs/bfs_enactor.cuh>
#include <gunrock/app/bfs/bfs_problem.cuh>
#include <gunrock/app/bfs/bfs_functor.cuh>

// BC includes
#include <gunrock/app/bc/bc_enactor.cuh>
#include <gunrock/app/bc/bc_problem.cuh>
#include <gunrock/app/bc/bc_functor.cuh>

// Operator includes
#include <gunrock/oprtr/vertex_map/kernel.cuh>
#include <gunrock/oprtr/edge_map_forward/kernel.cuh>

// Boost includes for CPU CC reference algorithm
// and BC algorithm
#include <boost/config.hpp>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/connected_components.hpp>
#include <boost/graph/bc_clustering.hpp>
#include <boost/graph/iteration_macros.hpp>


using namespace gunrock;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::cc;
using namespace gunrock::app::bfs;
using namespace gunrock::app::bc;


/******************************************************************************
 * Defines, constants, globals 
 ******************************************************************************/

bool g_verbose;
bool g_undirected;
bool g_quick;
bool g_stream_from_host;

template <typename VertexId>
struct CcList {
    VertexId        root;
    unsigned int    histogram;

    CcList(VertexId root, unsigned int histogram) : root(root), histogram(histogram) {}
};

template<typename CcList>
bool CCCompare(
    CcList elem1,
    CcList elem2)
{
    return elem1.histogram > elem2.histogram;
}


/******************************************************************************
 * Housekeeping Routines
 ******************************************************************************/
 void Usage()
 {
 printf("\nsimple_example <graph type> <graph type args> [--device=<device_index>] "
        "[--instrumented] [--quick] [--num_gpus=<gpu number>]\n"
        "\n"
        "Graph types and args:\n"
        "  market [<file>]\n"
        "    Reads a Matrix-Market coordinate-formatted graph of directed/undirected\n"
        "    edges from stdin (or from the optionally-specified file).\n"
        "--instrumentd: If include then show detailed kernel running stats.\n"
        "--quick: If include then do not perform CPU validity code.\n"
        "--num_gpus=<gpu number>: Using gpu number GPUs to compute,\n"
        "default value is 1, currently only support single GPU."
        );
 }

 /**
  * Displays the CC result (i.e., number of components)
  */
 template<typename VertexId, typename SizeT>
 void DisplayCCSolution(VertexId *comp_ids, SizeT nodes, unsigned int num_components)
 {
    printf("Number of components: %d\n", num_components);

    if (nodes <= 40) {
        printf("[");
        for (VertexId i = 0; i < nodes; ++i) {
            PrintValue(i);
            printf(":");
            PrintValue(comp_ids[i]);
            printf(",");
            printf(" ");
        }
        printf("]\n");
    }
 }

 /**
  * Displays the BFS result (i.e., distance from source)
  */
 template<typename VertexId, typename SizeT>
 void DisplayBFSSolution(VertexId *source_path, VertexId *preds, SizeT nodes, bool MARK_PREDECESSORS)
 {
    if (nodes > 40)
        nodes = 40;
    printf("[");
    for (VertexId i = 0; i < nodes; ++i) {
        PrintValue(i);
        printf(":");
        PrintValue(source_path[i]);
        printf(",");
        if (MARK_PREDECESSORS)
            PrintValue(preds[i]);
        printf(" ");
    }
    printf("]\n");
 }

 /**
  * Displays the BC result (sigma value and BC value)
  */
 template<typename Value, typename SizeT>
 void DisplayBCSolution(Value *bc_values, SizeT nodes)
{
    if (nodes > 40)
        nodes = 40;
    printf("[");
    for (SizeT i = 0; i < nodes; ++i) {
        PrintValue(i);
        printf(":");
        PrintValue(bc_values[i]);
        printf(" ");
    }
    printf("]\n");
}

 /**
  * Performance/Evaluation statistics
  */

 struct Statistic
 {
    double mean;
    double m2;
    int count;

    Statistic() : mean(0.0), m2(0.0), count(0) {}

    /**
     * Updates running statistic, returning bias-corrected sample variance.
     * Online method as per Knuth.
     */
    double Update(double sample)
    {
        count++;
        double delta = sample - mean;
        mean = mean + (delta / count);
        m2 = m2 + (delta * (sample - mean));
        return m2 / (count - 1);                //bias-corrected
    }
};

struct Stats {
    char *name;
    Statistic rate;
    Statistic search_depth;
    Statistic redundant_work;
    Statistic duty;

    Stats() : name(NULL), rate(), search_depth(), redundant_work(), duty() {}
    Stats(char *name) : name(name), rate(), search_depth(), redundant_work(), duty() {}
};

/**
 * Displays timing and correctness statistics
 */
template<
    bool MARK_PREDECESSORS,
    typename VertexId,
    typename Value,
    typename SizeT>
void DisplayBFSStats(
    Stats               &stats,
    VertexId            src,
    VertexId            *h_labels,
    const Csr<VertexId, Value, SizeT> &graph,
    double              elapsed,
    VertexId            search_depth,
    long long           total_queued,
    double              avg_duty)
{
    // Compute nodes and edges visited
    SizeT edges_visited = 0;
    SizeT nodes_visited = 0;
    for (VertexId i = 0; i < graph.nodes; ++i) {
        if (h_labels[i] > -1) {
            ++nodes_visited;
            edges_visited += graph.row_offsets[i+1] - graph.row_offsets[i];
        }
    }

    double redundant_work = 0.0;
    if (total_queued > 0) {
        redundant_work = ((double) total_queued - edges_visited) / edges_visited;        // measure duplicate edges put through queue
    }
    redundant_work *= 100;

    // Display test name
    printf("[%s] finished. ", stats.name);

    // Display statistics
    if (nodes_visited < 5) {
        printf("Fewer than 5 vertices visited.\n");
    } else {
        // Display the specific sample statistics
        double m_teps = (double) edges_visited / (elapsed * 1000.0);
        printf(" elapsed: %.3f ms, rate: %.3f MiEdges/s", elapsed, m_teps);
        if (search_depth != 0) printf(", search_depth: %lld", (long long) search_depth);
        if (avg_duty != 0) {
            printf("\n avg CTA duty: %.2f%%", avg_duty * 100);
        }
        printf("\n src: %lld, nodes_visited: %lld, edges visited: %lld",
            (long long) src, (long long) nodes_visited, (long long) edges_visited);
        if (total_queued > 0) {
            printf(", total queued: %lld", total_queued);
        }
        if (redundant_work > 0) {
            printf(", redundant work: %.2f%%", redundant_work);
        }
        printf("\n");
    }
    
}

 /**
  * A simple CPU-based reference BFS ranking implementation.
  */
 template<
    typename VertexId,
    typename Value,
    typename SizeT>
void SimpleReferenceBfs(
    const Csr<VertexId, Value, SizeT>       &graph,
    VertexId                                *source_path,
    VertexId                                src)
{
    //initialize distances
    for (VertexId i = 0; i < graph.nodes; ++i) {
        source_path[i] = -1;
    }
    source_path[src] = 0;
    VertexId search_depth = 0;

    // Initialize queue for managing previously-discovered nodes
    std::deque<VertexId> frontier;
    frontier.push_back(src);

    //
    //Perform BFS
    //

    CpuTimer cpu_timer;
    cpu_timer.Start();
    while (!frontier.empty()) {
        
        // Dequeue node from frontier
        VertexId dequeued_node = frontier.front();
        frontier.pop_front();
        VertexId neighbor_dist = source_path[dequeued_node] + 1;

        // Locate adjacency list
        int edges_begin = graph.row_offsets[dequeued_node];
        int edges_end = graph.row_offsets[dequeued_node + 1];

        for (int edge = edges_begin; edge < edges_end; ++edge) {
            //Lookup neighbor and enqueue if undiscovered
            VertexId neighbor = graph.column_indices[edge];
            if (source_path[neighbor] == -1) {
                source_path[neighbor] = neighbor_dist;
                if (search_depth < neighbor_dist) {
                    search_depth = neighbor_dist;
                }
                frontier.push_back(neighbor);
            }
        }
    }

    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();
    search_depth++;

    printf("CPU BFS finished in %lf msec. Search depth is:%d\n", elapsed, search_depth);
}

// Graph edge properties (bundled properties)
struct EdgeProperties
{
    int weight;
};

 /**
  * A simple CPU-based reference BC ranking implementation.
  */
 template<
    typename VertexId,
    typename Value,
    typename SizeT>
void RefCPUBC(
    const Csr<VertexId, Value, SizeT>       &graph,
    Value                                   *bc_values,
    VertexId                                src)
{
    // Perform full exact BC using BGL

    using namespace boost;
    typedef adjacency_list <setS, vecS, undirectedS, no_property, EdgeProperties> Graph;
    typedef Graph::vertex_descriptor Vertex;
    typedef Graph::edge_descriptor Edge;

    Graph G;
    for (int i = 0; i < graph.nodes; ++i)
    {
        for (int j = graph.row_offsets[i]; j < graph.row_offsets[i+1]; ++j)
        {
            add_edge(vertex(i, G), vertex(graph.column_indices[j], G), G);
        }
    }

    typedef std::map<Edge, int> StdEdgeIndexMap;
    StdEdgeIndexMap my_e_index;
    typedef boost::associative_property_map< StdEdgeIndexMap > EdgeIndexMap;
    EdgeIndexMap e_index(my_e_index);

    // Define EdgeCentralityMap
    std::vector< double > e_centrality_vec(boost::num_edges(G), 0.0);
    // Create the external property map
    boost::iterator_property_map< std::vector< double >::iterator, EdgeIndexMap >
        e_centrality_map(e_centrality_vec.begin(), e_index);

    // Define VertexCentralityMap
    typedef boost::property_map< Graph, boost::vertex_index_t>::type VertexIndexMap;
    VertexIndexMap v_index = get(boost::vertex_index, G);
    std::vector< double > v_centrality_vec(boost::num_vertices(G), 0.0);

    // Create the external property map
    boost::iterator_property_map< std::vector< double >::iterator, VertexIndexMap>
        v_centrality_map(v_centrality_vec.begin(), v_index);

    //
    //Perform BC
    // 
    CpuTimer cpu_timer;
    cpu_timer.Start();
    brandes_betweenness_centrality( G, v_centrality_map, e_centrality_map );
    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();

    BGL_FORALL_VERTICES(vertex, G, Graph)
    {
        bc_values[vertex] = (Value)v_centrality_map[vertex];
    }

    printf("CPU BC finished in %lf msec.", elapsed);

}


/**
 * CPU-based reference CC algorithm using Boost Graph Library
 */
template<typename VertexId, typename SizeT>
unsigned int RefCPUCC(SizeT *row_offsets, VertexId *column_indices, int num_nodes, int *labels)
{
    using namespace boost;
    typedef adjacency_list <vecS, vecS, undirectedS> Graph;
    Graph G;
    for (int i = 0; i < num_nodes; ++i)
    {
        for (int j = row_offsets[i]; j < row_offsets[i+1]; ++j)
        {
            add_edge(i, column_indices[j], G);
        }
    }
    CpuTimer cpu_timer;
    cpu_timer.Start();
    int num_components = connected_components(G, &labels[0]);
    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();
    printf("CPU CC finished in %lf msec.\n", elapsed);
    return num_components;
}

/**
 * Run tests
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool INSTRUMENT>
void RunTests(
    const Csr<VertexId, Value, SizeT> &graph,
    int max_grid_size,
    int num_gpus,
    double max_queue_sizing)
{
    typedef CCProblem<
        VertexId,
        SizeT,
        Value,
        true> CCProblem_T; //use double buffer for edgemap and vertexmap.

    typedef UpdateMaskFunctor<
        VertexId,
        SizeT,
        Value,
        CCProblem_T> UpdateMaskFunctor;

    typedef HookMinFunctor<
        VertexId,
        SizeT,
        Value,
        CCProblem_T> HookMinFunctor;
    
    typedef HookMaxFunctor<
        VertexId,
        SizeT,
        Value,
        CCProblem_T> HookMaxFunctor;

    typedef PtrJumpFunctor<
        VertexId,
        SizeT,
        Value,
        CCProblem_T> PtrJumpFunctor;

    typedef PtrJumpMaskFunctor<
        VertexId,
        SizeT,
        Value,
        CCProblem_T> PtrJumpMaskFunctor;

    typedef PtrJumpUnmaskFunctor<
        VertexId,
        SizeT,
        Value,
        CCProblem_T> PtrJumpUnmaskFunctor;


        // Allocate host-side label array (for both reference and gpu-computed results)
        VertexId    *reference_component_ids        = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        VertexId    *h_component_ids                = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        VertexId    *reference_check                = (g_quick) ? NULL : reference_component_ids;
        unsigned int ref_num_components             = 0;

        // Allocate CC enactor map
        CCEnactor<INSTRUMENT> cc_enactor(g_verbose);

        // Allocate problem on GPU
        CCProblem_T *cc_problem = new CCProblem_T;
        if (cc_problem->Init(
            g_stream_from_host,
            graph.nodes,
            graph.edges,
            graph.row_offsets,
            graph.column_indices,
            num_gpus)) exit(1);

        //
        // Compute reference CPU CC solution for source-distance
        //
        if (reference_check != NULL)
        {
            printf("compute ref value\n");
            ref_num_components = RefCPUCC(
                    graph.row_offsets,
                    graph.column_indices,
                    graph.nodes,
                    reference_check);
            printf("\n");
        }

        cudaError_t         retval = cudaSuccess;

        // Perform CC
        GpuTimer gpu_timer;

        if (retval = cc_problem->Reset(cc_enactor.GetFrontierType(), 1.0)) exit(1);
        gpu_timer.Start();
        if (retval = cc_enactor.template Enact<CCProblem_T,
                                            UpdateMaskFunctor,
                                            HookMinFunctor,
                                            HookMaxFunctor,
                                            PtrJumpFunctor,
                                            PtrJumpMaskFunctor,
                                            PtrJumpUnmaskFunctor>(cc_problem, max_grid_size)) exit(1);
        gpu_timer.Stop();

        if (retval && (retval != cudaErrorInvalidDeviceFunction)) {
            exit(1);
        }

        float elapsed = gpu_timer.ElapsedMillis();

        // Copy out results
        if (cc_problem->Extract(h_component_ids)) exit(1);

        // Validity
        if (ref_num_components == cc_problem->num_components)
            printf("CORRECT.\n");
        else {
            printf("INCORRECT. Ref Component Count: %d, GPU Computed Component Count: %d\n", ref_num_components, cc_problem->num_components);
            return;
        }

        // Compute size and root of each component
        VertexId        *h_roots            = new VertexId[cc_problem->num_components];
        unsigned int    *h_histograms       = new unsigned int[cc_problem->num_components];

        cc_problem->ComputeDetails(h_component_ids, h_roots, h_histograms);

        // Display Solution
        DisplayCCSolution(h_component_ids, graph.nodes, ref_num_components);

        typedef CcList<VertexId> CcListType;
        //sort the components by size
        CcListType *cclist = (CcListType*)malloc(sizeof(CcListType) * ref_num_components);
        for (int i = 0; i < ref_num_components; ++i)
        {
            cclist[i].root = h_roots[i];
            cclist[i].histogram = h_histograms[i];
        }
        std::stable_sort(cclist, cclist + ref_num_components, CCCompare<CcListType>);

        // Print out at most top 10 largest components
        int top = (ref_num_components < 10) ? ref_num_components : 10;
        printf("Top %d largest components:\n", top);
        for (int i = 0; i < top; ++i)
        {
            printf("CC ID: %d, CC Root: %d, CC Size: %d\n", i, cclist[i].root, cclist[i].histogram);
        }

        printf("GPU Connected Component finished in %lf msec.\n", elapsed);

        VertexId src = cclist[0].root;      // Set the root of the largest components as BFS source
 
        // Cleanup
        if (cc_problem) delete cc_problem;
        if (h_roots) delete[] h_roots;
        if (h_histograms) delete[] h_histograms;
        if (cclist) free(cclist);
        if (reference_component_ids) free(reference_component_ids);
        if (h_component_ids) free(h_component_ids);

        cudaDeviceSynchronize();

        bool MARK_PREDECESSORS = true; // Set MARK_PREDECESSORS flag
    
    typedef BFSProblem<
        VertexId,
        SizeT,
        Value,
        true,                // Set MARK_PREDECESSORS flag true
        false> BFSProblem_T; // does not use double buffer

    typedef BFSFunctor<
        VertexId,
        SizeT,
        Value,
        BFSProblem_T> BfsFunctor;


        // Allocate host-side label array (for both reference and gpu-computed results)
        VertexId    *reference_labels       = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        VertexId    *h_labels               = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        reference_check                     = (g_quick) ? NULL : reference_labels;
        VertexId    *h_preds                = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);


        // Allocate BFS enactor map
        BFSEnactor<INSTRUMENT> bfs_enactor(g_verbose);

        // Allocate problem on GPU
        BFSProblem_T *bfs_problem = new BFSProblem_T;
        if (bfs_problem->Init(
            g_stream_from_host,
            graph.nodes,
            graph.edges,
            graph.row_offsets,
            graph.column_indices,
            num_gpus)) exit(1);

        //
        // Compute reference CPU BFS solution for source-distance
        //
        if (reference_check != NULL)
        {
            printf("compute ref value\n");
            SimpleReferenceBfs(
                    graph,
                    reference_check,
                    src);
            printf("\n");
        }

        retval = cudaSuccess;

        Stats *stats = new Stats("GPU BFS");

        long long           total_queued = 0;
        VertexId            search_depth = 0;
        double              avg_duty = 0.0;

        // Perform BFS
        gpu_timer;

        if (retval = bfs_problem->Reset(src, bfs_enactor.GetFrontierType(), max_queue_sizing)) exit(1);
        gpu_timer.Start();
        if (retval = bfs_enactor.template Enact<BFSProblem_T, BfsFunctor>(bfs_problem, src, max_grid_size)) exit(1);
        gpu_timer.Stop();

        bfs_enactor.GetStatistics(total_queued, search_depth, avg_duty);

        if (retval && (retval != cudaErrorInvalidDeviceFunction)) {
            exit(1);
        }

        elapsed = gpu_timer.ElapsedMillis();

        // Copy out results
        if (bfs_problem->Extract(h_labels, h_preds)) exit(1);

        // Verify the result
        if (reference_check != NULL) {
            printf("Validity: ");
            CompareResults(h_labels, reference_check, graph.nodes, true);
        }
        printf("\nFirst 40 labels of the GPU result."); 
        // Display Solution
        DisplayBFSSolution(h_labels, h_preds, graph.nodes, MARK_PREDECESSORS);

        DisplayBFSStats<true>( //set MARK_PREDECESSORS flag
            *stats,
            src,
            h_labels,
            graph,
            elapsed,
            search_depth,
            total_queued,
            avg_duty);


        // Cleanup
        delete stats;
        if (bfs_problem) delete bfs_problem;
        if (reference_labels) free(reference_labels);
        if (h_labels) free(h_labels);
        if (h_preds) free(h_preds);

        cudaDeviceSynchronize();

        // Perform BC
        src = -1;
        typedef BCProblem<
            VertexId,
            SizeT,
            Value,
            false> BCProblem_T; //does not use double buffer

        typedef ForwardFunctor<
            VertexId,
            SizeT,
            Value,
            BCProblem_T> FFunctor;

        typedef BackwardFunctor<
            VertexId,
            SizeT,
            Value,
            BCProblem_T> BFunctor;


        // Allocate host-side array (for both reference and gpu-computed results)
        Value       *reference_bc_values        = (Value*)malloc(sizeof(Value) * graph.nodes);
        Value       *h_bc_values                = (Value*)malloc(sizeof(Value) * graph.nodes);
        Value       *reference_check_bc_values  = (g_quick) ? NULL : reference_bc_values;

        // Allocate BC enactor map
        BCEnactor<INSTRUMENT> bc_enactor(g_verbose);

        // Allocate problem on GPU
        BCProblem_T *bc_problem = new BCProblem_T;
        if (bc_problem->Init(
                    g_stream_from_host,
                    graph.nodes,
                    graph.edges,
                    graph.row_offsets,
                    graph.column_indices,
                    num_gpus)) exit(1);

        //
        // Compute reference CPU BC solution for source-distance
        //
        if (reference_check_bc_values != NULL)
        {
            printf("compute ref value\n");
            RefCPUBC(
                    graph,
                    reference_check_bc_values,
                    src);
            printf("\n");
        }

        retval = cudaSuccess;

        avg_duty = 0.0;

        // Perform BC
        VertexId start_src = 0;
        VertexId end_src = graph.nodes;

        gpu_timer.Start();
        for (VertexId i = start_src; i < end_src; ++i)
        {
            if (retval = bc_problem->Reset(i, bc_enactor.GetFrontierType(), max_queue_sizing)) exit(1);
            if (retval = bc_enactor.template Enact<BCProblem_T, FFunctor, BFunctor>(bc_problem, i, max_grid_size)) exit(1);

            if (retval && (retval != cudaErrorInvalidDeviceFunction)) {
                exit(1);
            }
        }

        // Normalize BC value
        util::MemsetScaleKernel<<<128, 128>>>(bc_problem->data_slices[0]->d_bc_values, 0.5f, graph.nodes);

        gpu_timer.Stop();

        elapsed = gpu_timer.ElapsedMillis();

        bc_enactor.GetStatistics(avg_duty);

        // Copy out results
        if (bc_problem->Extract(NULL, h_bc_values)) exit(1);

        // Verify the result
        if (reference_check_bc_values != NULL) {
            printf("Validity BC Value: ");
            CompareResults(h_bc_values, reference_check_bc_values, graph.nodes, true);
            printf("\n"); 
        }

        printf("\nFirst 40 bc_values of the GPU result.");
        // Display Solution
        DisplayBCSolution(h_bc_values, graph.nodes);

        printf("GPU BC finished in %lf msec.\n", elapsed);
        if (avg_duty != 0)
            printf("\n avg CTA duty: %.2f%%", avg_duty * 100);


        // Cleanup
        if (bc_problem) delete bc_problem;
        if (reference_bc_values) free(reference_bc_values);
        if (h_bc_values) free(h_bc_values);

        cudaDeviceSynchronize();
}


template <
    typename VertexId,
    typename Value,
    typename SizeT>
void RunTests(
    Csr<VertexId, Value, SizeT> &graph,
    CommandLineArgs &args)
{
    bool                instrumented        = false;        // Whether or not to collect instrumentation from kernels
    int                 max_grid_size       = 0;            // maximum grid size (0: leave it up to the enactor)
    int                 num_gpus            = 1;            // Number of GPUs for multi-gpu enactor to use
    double              max_queue_sizing    = 1.3;          // Maximum size scaling factor for work queues. (e.g., 1.3 creates [1.3n] and [1.3m]-element vertex and edge frontiers.

    instrumented = args.CheckCmdLineFlag("instrumented");

    g_quick = args.CheckCmdLineFlag("quick");
    args.GetCmdLineArgument("num-gpus", num_gpus);
    g_verbose = args.CheckCmdLineFlag("v");

    if (instrumented) {
            RunTests<VertexId, Value, SizeT, true>(
                graph,
                max_grid_size,
                num_gpus,
                max_queue_sizing);
    } else {
            RunTests<VertexId, Value, SizeT, false>(
                graph,
                max_grid_size,
                num_gpus,
                max_queue_sizing);
    }
}

/******************************************************************************
 * Main
 ******************************************************************************/

int main( int argc, char** argv)
{
	CommandLineArgs args(argc, argv);

	if ((argc < 2) || (args.CheckCmdLineFlag("help"))) {
		Usage();
		return 1;
	}

	DeviceInit(args);
	cudaSetDeviceFlags(cudaDeviceMapHost);

	// Parse graph-contruction params
	g_undirected = true;

	std::string graph_type = argv[1];
	int flags = args.ParsedArgc();
	int graph_args = argc - flags - 1;

	if (graph_args < 1) {
		Usage();
		return 1;
	}
	
	//
	// Construct graph and perform search(es)
	//

	if (graph_type == "market") {

		// Matrix-market coordinate-formatted graph file

		typedef int VertexId;							// Use as the node identifier type
		typedef float Value;								// Use as the value type
		typedef int SizeT;								// Use as the graph size type
		Csr<VertexId, Value, SizeT> csr(false);         // default value for stream_from_host is false

		if (graph_args < 1) { Usage(); return 1; }
		char *market_filename = (graph_args == 2) ? argv[2] : NULL;
		if (graphio::BuildMarketGraph<false>(
			market_filename, 
			csr, 
			g_undirected) != 0) 
		{
			return 1;
		}

        csr.DisplayGraph();
        fflush(stdout);

		// Run tests
		RunTests(csr, args);


	} else {

		// Unknown graph type
		fprintf(stderr, "Unspecified graph type\n");
		return 1;

	}

	return 0;
}
