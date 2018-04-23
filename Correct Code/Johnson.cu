﻿
#ifndef __CUDACC__ 
#define __CUDACC__
#endif

#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <cuda.h>
#include <device_functions.h>
#include <cuda_runtime_api.h>
#include <limits>
#include <stdio.h>
#include <iostream>
#include <fstream>
#include <vector>
#include <set>
#include <utility>
#include <cfloat>
#include <time.h>
//#include <windows.h>
#include <string>
#include "helper_functions.h"
#include "helper_cuda.h"

typedef union _LARGE_INTEGER {
  struct {
    unsigned long LowPart;
    long  HighPart;
  };
  struct {
    unsigned long LowPart;
    long  HighPart;
  } u;
  long long QuadPart;
} LARGE_INTEGER, *PLARGE_INTEGER;

/////////////////////////////////////////////////////////////////////////////////////////////////
__global__ void shfl_scan_test(int *data, int width, int *partial_sums = NULL)
{
	extern __shared__ int sums[];
	int id = ((blockIdx.x * blockDim.x) + threadIdx.x);
	int lane_id = id % warpSize;
	// determine a warp_id within a block
	int warp_id = threadIdx.x / warpSize;

	// Below is the basic structure of using a shfl instruction
	// for a scan.
	// Record "value" as a variable - we accumulate it along the way
	int value = data[id];

	// Now accumulate in log steps up the chain
	// compute sums, with another thread's value who is
	// distance delta away (i).  Note
	// those threads where the thread 'i' away would have
	// been out of bounds of the warp are unaffected.  This
	// creates the scan sum.
#pragma unroll

	for (int i = 1; i <= width; i *= 2)
	{
		int n = __shfl_up(value, i, width);

		if (lane_id >= i) value += n;
	}

	// value now holds the scan value for the individual thread
	// next sum the largest values for each warp

	// write the sum of the warp to smem
	if (threadIdx.x % warpSize == warpSize - 1)
	{
		sums[warp_id] = value;
	}

	__syncthreads();

	//
	// scan sum the warp sums
	// the same shfl scan operation, but performed on warp sums
	//
	if (warp_id == 0 && lane_id < (blockDim.x / warpSize))
	{
		int warp_sum = sums[lane_id];

		for (int i = 1; i <= width; i *= 2)
		{
			int n = __shfl_up(warp_sum, i, width);

			if (lane_id >= i) warp_sum += n;
		}

		sums[lane_id] = warp_sum;
	}

	__syncthreads();

	// perform a uniform add across warps in the block
	// read neighbouring warp's sum and add it to threads value
	int blockSum = 0;

	if (warp_id > 0)
	{
		int index = warp_id - 1;
		blockSum = sums[index];
	}

	value += blockSum;

	// Now write out our result
	data[id] = value;

	// last thread has sum, write write out the block's sum
	if (partial_sums != NULL && threadIdx.x == blockDim.x - 1)
	{
		partial_sums[blockIdx.x] = value;
	}
}

// Uniform add: add partial sums array
__global__ void uniform_add(int *data, int *partial_sums, int len)
{
	__shared__ int buf;
	int id = ((blockIdx.x * blockDim.x) + threadIdx.x);

	if (id > len) return;

	if (threadIdx.x == 0)
	{
		buf = partial_sums[blockIdx.x];
	}

	__syncthreads();
	data[id] += buf;
}

static unsigned int iDivUp(unsigned int dividend, unsigned int divisor)
{
	return ((dividend % divisor) == 0) ?
		(dividend / divisor) :
		(dividend / divisor + 1);
}

bool CPUverify(int *h_data, int *h_result, int n_elements)
{
	// cpu verify
	for (int i = 0; i<n_elements - 1; i++)
	{
		int next = i + 1;
		h_data[next] = h_data[i] + h_data[next];
	}

	int diff = 0;

	for (int i = 0; i<n_elements; i++)
	{
		diff += h_data[i] - h_result[i];
	}

	printf("CPU verify result diff (GPUvsCPU) = %d\n", diff);
	bool bTestResult = false;

	if (diff == 0) bTestResult = true;

	StopWatchInterface *hTimer = NULL;
	sdkCreateTimer(&hTimer);
	sdkResetTimer(&hTimer);
	sdkStartTimer(&hTimer);

	for (int j = 0; j<100; j++)
		for (int i = 0; i<n_elements - 1; i++)
		{
			int next = j + 1;
			h_data[next] = h_data[i] + h_data[next];
		}

	sdkStopTimer(&hTimer);
	double cput = sdkGetTimerValue(&hTimer);
	printf("CPU sum (naive) took %f ms\n", cput / 100);
	return bTestResult;
}

bool shuffle_simple_test(int argc, char **argv)
{
	int *h_data, *h_partial_sums, *h_result;
	int *d_data, *d_partial_sums;
	const int n_elements = 65036;
	int sz = sizeof(int)*n_elements;
	//int cuda_device = 0;

	//printf("Starting shfl_scan\n");

	//// use command-line specified CUDA device, otherwise use device with highest Gflops/s
	//cuda_device = findCudaDevice(argc, (const char **)argv);

	//cudaDeviceProp deviceProp;
	//checkCudaErrors(cudaGetDevice(&cuda_device));

	//checkCudaErrors(cudaGetDeviceProperties(&deviceProp, cuda_device));

	//printf("> Detected Compute SM %d.%d hardware with %d multi-processors\n",
	//       deviceProp.major, deviceProp.minor, deviceProp.multiProcessorCount);

	//// __shfl intrinsic needs SM 3.0 or higher
	//if (deviceProp.major < 3)
	//{
	//    printf("> __shfl() intrinsic requires device SM 3.0+\n");
	//    printf("> Waiving test.\n");
	//    exit(EXIT_WAIVED);
	//}

	checkCudaErrors(cudaMallocHost((void **)&h_data, sizeof(int)*n_elements));
	checkCudaErrors(cudaMallocHost((void **)&h_result, sizeof(int)*n_elements));

	//initialize data:
	printf("Computing Simple Sum test\n");
	printf("---------------------------------------------------\n");

	printf("Initialize test data [1, 1, 1...]\n");

	for (int i = 0; i<n_elements; i++)
	{
		h_data[i] = 1;
	}

	int blockSize = 256;
	int gridSize = n_elements / blockSize + 1;
	int nWarps = blockSize / 32;
	int shmem_sz = nWarps * sizeof(int);
	int n_partialSums = n_elements / blockSize + 1;
	int partial_sz = n_partialSums*sizeof(int);

	printf("Scan summation for %d elements, %d partial sums\n",
		n_elements, n_elements / blockSize);

	int p_blockSize = std::min(n_partialSums, blockSize);
	int p_gridSize = iDivUp(n_partialSums, p_blockSize);
	printf("Partial summing %d elements with %d blocks of size %d\n",
		n_partialSums, p_gridSize, p_blockSize);

	// initialize a timer
	cudaEvent_t start, stop;
	checkCudaErrors(cudaEventCreate(&start));
	checkCudaErrors(cudaEventCreate(&stop));
	float et = 0;
	float inc = 0;

	checkCudaErrors(cudaMalloc((void **)&d_data, sz));
	checkCudaErrors(cudaMalloc((void **)&d_partial_sums, partial_sz));
	checkCudaErrors(cudaMemset(d_partial_sums, 0, partial_sz));

	checkCudaErrors(cudaMallocHost((void **)&h_partial_sums, partial_sz));
	checkCudaErrors(cudaMemcpy(d_data, h_data, sz, cudaMemcpyHostToDevice));

	checkCudaErrors(cudaEventRecord(start, 0));
	shfl_scan_test << <gridSize, blockSize, shmem_sz >> >(d_data, 32, d_partial_sums);
	shfl_scan_test << <p_gridSize, p_blockSize, shmem_sz >> >(d_partial_sums, 32);
	uniform_add << <gridSize - 1, blockSize >> >(d_data + blockSize, d_partial_sums, n_elements);
	checkCudaErrors(cudaEventRecord(stop, 0));
	checkCudaErrors(cudaEventSynchronize(stop));
	checkCudaErrors(cudaEventElapsedTime(&inc, start, stop));
	et += inc;

	checkCudaErrors(cudaMemcpy(h_result, d_data, sz, cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_partial_sums, d_partial_sums, partial_sz,
		cudaMemcpyDeviceToHost));

	printf("Test Sum: %d\n", h_partial_sums[n_partialSums - 1]);
	printf("Time (ms): %f\n", et);
	printf("%d elements scanned in %f ms -> %f MegaElements/s\n",
		n_elements, et, n_elements / (et / 1000.0f) / 1000000.0f);

	bool bTestResult = CPUverify(h_data, h_result, n_elements);

	checkCudaErrors(cudaFreeHost(h_data));
	checkCudaErrors(cudaFreeHost(h_result));
	checkCudaErrors(cudaFreeHost(h_partial_sums));
	checkCudaErrors(cudaFree(d_data));
	checkCudaErrors(cudaFree(d_partial_sums));

	return bTestResult;
}

//////////////////////////////////////////////////////////////////////////////////////////////////
using namespace std;
#define INF 1000000000 
#define BS 512


#define BEGIN_ATOMIC 	bool isSet = false; do { if (isSet = atomicCAS(mutex, 0, 1) == 0) {
#define END_ATOMIC		}if (isSet){*mutex = 0;}} while (!isSet);
#define GET_THREAD_ID (blockIdx.x * blockDim.x + threadIdx.x);
#include "cuda_profiler_api.h"

#define CUDA_API_PER_THREAD_DEFAULT_STREAM


#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }

inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort = true)
{
	if (code != cudaSuccess)
	{
		fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
		//if (abort) exit(code);
	}
}


//! used for calculating time in CPU
double PCFreq = 0.0;
long CounterStart = 0;
float minTime;
float maxTime;

//! starts the counter (for CPU)
/*void StartCounter()
{
	LARGE_INTEGER li;
	if (!QueryPerformanceFrequency(&li))
		std::cout << "QueryPerformanceFrequency failed!\n";

	PCFreq = double(li.QuadPart) / 1000.0;

	QueryPerformanceCounter(&li);
	CounterStart = li.QuadPart;
}*/

//! gives the elapse time from the call of StartCounter()
double GetCounter()
{
	LARGE_INTEGER li;
	double quadMinCount = li.QuadPart - CounterStart;
	//QueryPerformanceCounter(&li);
	//return double(li.QuadPart - CounterStart) / PCFreq;
	return quadMinCount/PCFreq;
}

__device__ volatile int sem = 0;

__device__ void acquire_semaphore(volatile int *lock){
	while (atomicCAS((int *)lock, 0, 1) != 0);
}

__device__ void release_semaphore(volatile int *lock){
	*lock = 0;
	__threadfence();
}

/**********************************************************************************************************************************/

__global__ void reweightKernel(int* bfWeights, int* d_edgeIndex, int* d_edges, int* in_costs, int* d_out_costs, int* numOfThreads)
{
	unsigned int i = GET_THREAD_ID

		__shared__ int shared_amca[1];
	int* s_data = shared_amca;

	if (threadIdx.x == 0)
		s_data[0] = *numOfThreads;

	__syncthreads();

	if (i < s_data[0])
	{
		int next = i + 1;				
		int edgeStart = d_edgeIndex[i];
		int edgeEnd = d_edgeIndex[next];

		int u = bfWeights[i];
		// for all successors of node i
		for (int m = edgeStart; m < edgeEnd; m++)
		{
			int adj = d_edges[m]; // neighbor
			int w = in_costs[m]; // its cost 
			int v = bfWeights[adj];
			int wu = w + u;
			d_out_costs[m] = wu - v;
		}
	}
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void spawnVertices(int *edgeIndex, int *edges, int * costs,
	int* nodeW, int* nodeParent, int* itNo, int* source,
	int* F1, int* F2, int *head1, int* head2, int currIt, int* mutex)
{

	unsigned int i = GET_THREAD_ID

		__shared__ int shared_amca[1];
	int* s_data = shared_amca;
	if (threadIdx.x == 0)
		s_data[0] = *head1;

	__syncthreads();


	if (i < s_data[0])
	{

		int nodeIndex = F1[i];
		int edgeStart = edgeIndex[nodeIndex];
		int nextNodeIndex = nodeIndex + 1;
		int edgeEnd = edgeIndex[nextNodeIndex];     //<------------------------------------------------------------------------------changed this


		for (int e = edgeStart; e < edgeEnd; e++)
		{

			int adj = edges[e];
			int nextAdj = adj + 1;		//<-------------------------------------------------Cgabge		
			//printf("%d\n", adj);


			int newCost = nodeW[nodeIndex] + costs[e];

			int outDegree = edgeIndex[nextAdj] - edgeIndex[adj];//<--------------------------------------------asdf


			if (nodeIndex == adj)
				continue;

			BEGIN_ATOMIC

				if (newCost < nodeW[adj])
				{
					nodeW[adj] = newCost;
					nodeParent[adj] = nodeIndex;

					if (itNo[adj] != currIt && outDegree > 0){

						//printf("			%d -- %d\n", adj, nodeIndex);
						*(F2 + *head2) = adj;
						*head2 += 1;
						itNo[adj] = currIt;
					}
				}
			END_ATOMIC
		}


	}

}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void BF(int *edgeIndex, int *edges, int * costs,
	int* nodeW, int* nodeParent, int* itNo, int* source,
	int* F1, int* F2, int *head1, int* head2, int* mutex, int* n)
{
	unsigned int i = GET_THREAD_ID

		__shared__ int shared_amca[1];
	int* s_data = shared_amca;
	if (threadIdx.x == 0)
		s_data[0] = *n;

	__syncthreads();


	if (i < s_data[0])
	{
		unsigned int s = *source;
		//! initialize
		if (i == s){
			nodeW[i] = 0;
			nodeParent[i] = -2;
		}
		else{
			nodeW[i] = INF;
			nodeParent[i] = -1;
		}

		itNo[i] = -1;

		if (i == 0){
			*(F1 + *head1) = s;
			*head1 = 1;
		}

		__syncthreads();


		if (i == 0){

			int ss = 0;
			while (true){
				int h1 = *head1;
				if (h1 == 0)
					break;


				int numOfThreads = BS;
				int numOfBlocks = *head1 / numOfThreads + (*head1%numOfThreads == 0 ? 0 : 1);

				//for (int q = 0; q < h1; q++)
				//printf("%d	", F1[q]);
				//printf("\n\n");
				spawnVertices << <numOfBlocks, numOfThreads >> >(edgeIndex, edges, costs, nodeW, nodeParent, itNo, source, F1, F2, head1, head2, ss, mutex);
				cudaDeviceSynchronize();

				int *temp = F1;
				F1 = F2;
				F2 = temp;

				*head1 = *head2;
				*head2 = 0;
				ss++;
			}
		}
	}

	__syncthreads();

	if (i == 0)
	{
		int threadsPerBlock = 512;
		int numOfBlocks = s_data[0] / threadsPerBlock + (s_data[0] % threadsPerBlock == 0 ? 0 : 1);

		reweightKernel << <numOfBlocks, threadsPerBlock >> > (nodeW, edgeIndex, edges, costs, costs, n);
	}

}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void relaxKernel(int* edgeIndex, int* edges, int*costs, int* nodeW, int* nodeParent, int* F, int* U, int* numOfThreads)
{
	__shared__ int shared[1];

	int* s_data = shared;
	unsigned int i = GET_THREAD_ID

		if (threadIdx.x == 0)
			s_data[0] = *numOfThreads;

	__syncthreads();
	if (i < s_data[0])
	{
		if (F[i] == 1)
		{
			int next = i + 1;//<-------------------------------------next
			int edgeStart = edgeIndex[i];
			int edgeEnd = edgeIndex[next];//<-----------------------added next
			// for all successors of node i
			for (int m = edgeStart; m < edgeEnd; m++)
			{
				int adj = edges[m]; // neighbor
				int cost = costs[m]; // its cost 
				if (U[adj] == 1)
				{
					//nodeParent[adj] = i;
					/* TODO : insan gibi atomic */
					//BEGIN_ATOMIC
					// get the minimum value for relaxing
					atomicMin(nodeW + adj, nodeW[i] + cost);
					//nodeW[adj] = nodeW[adj] < (nodeW[i] + cost) ? nodeW[adj] : (nodeW[i] + cost);
					//END_ATOMIC
				}
			}

		}
	}


}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void updateKernel(int* edgeIndex, int* edges, int*costs, int* nodeW, int* F, int* U, int* threshold, int* numOfThreads)
{
	__shared__ int shared[1];

	int* s_data = shared;
	unsigned int i = GET_THREAD_ID

		if (threadIdx.x == 0)
			s_data[0] = *numOfThreads;

	__syncthreads();
	if (i < s_data[0])
	{
		F[i] = 0;
		if (U[i] == 1 && nodeW[i] <= *threshold)
		{
			F[i] = 1;
			U[i] = 0;
			//printf("	%d\n", i);
		}
	}
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void updateKernelQ(int* edgeIndex, int* edges, int*costs, int* nodeW, int* F, int* headF, int* U, int* threshold, int* numOfThreads)
{

	__shared__ int shared[1];

	int* s_data = shared;
	unsigned int i = GET_THREAD_ID

		if (threadIdx.x == 0)
			s_data[0] = *numOfThreads;

	__syncthreads();
	if (i < s_data[0])
	{
		if (i == 0)
		{
			*headF = 0;
		}
		__syncthreads();

		if (U[i] == 1 && nodeW[i] <= *threshold)
		{
			U[i] = 0;
			//	atomicAdd(headF, 1);
			atomicExch(F + atomicAdd(headF, 1), i);
		}
	}
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void relaxKernelQ(int* edgeIndex, int* edges, int*costs, int* nodeW, int* nodeParent, int* F, int* headF, int* U)
{

	__shared__ int shared[1];

	int* s_data = shared;
	unsigned int i = GET_THREAD_ID

		if (threadIdx.x == 0)
			s_data[0] = *headF;

	__syncthreads();
	if (i < s_data[0])
	{

		int nodeIdx = F[i];
		int nodeIdNext = nodeIdx + 1;//<----------------------------------------AFASFASDFASD
		int edgeStart = edgeIndex[nodeIdx];
		int edgeEnd = edgeIndex[nodeIdNext];//<-----------------------------------ASFDASFS

		// for all successors of node i
		for (int m = edgeStart; m < edgeEnd; m++)
		{
			int adj = edges[m]; // neighbor
			int cost = costs[m]; // its cost 
			int toll = nodeW[nodeIdx + cost];//<--------------------------------------------------dumb variable
			int* wAndAdj = nodeW + adj;//<----------------------------FIXED NEEDED *
			if (U[adj] == 1)
			{

				/* TODO : insan gibi atomic */
				//	BEGIN_ATOMIC
				// get the minimum value for relaxing
				nodeParent[adj] = nodeIdx;
				//nodeW[adj] = nodeW[adj] < (nodeW[nodeIdx] + cost) ? nodeW[adj] : (nodeW[nodeIdx] + cost);
				//END_ATOMIC

				atomicMin(wAndAdj, toll);
			}
		}
	}


}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void computeDeltaUKernel(int *edgeIndex, int *edges, int * costs, int* deltas, int* numOfThreads)
{

	__shared__ int shared[1];

	int* s_data = shared;
	unsigned int i = GET_THREAD_ID

		if (threadIdx.x == 0)
			s_data[0] = *numOfThreads;

	__syncthreads();
	if (i < s_data[0])
	{
		int next = i + 1;
		int edgeStart = edgeIndex[i];
		int edgeEnd = edgeIndex[next];
		int minVal = INF;
		// for all successors of node i
		for (int m = edgeStart; m < edgeEnd; m++)
		{
			int cost = costs[m]; // its cost 

			minVal = minVal < cost ? minVal : cost;
		}

		deltas[i] = minVal;
	}
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void
reduce3(int *g_idata, int *g_odata, unsigned int n, unsigned int n2)
{


	extern __shared__ int s_type[];
	int *sdata = s_type;

	// perform first level of reduction,
	// reading from global memory, writing to shared memory
	unsigned int tid = threadIdx.x;	//<=================================================TONS OF CHANGES HERE===================================
	unsigned int blockDimDub = blockDim.x + blockDim.x;
	unsigned int idByDim = blockIdx.x * blockDimDub; 
	unsigned int i = idByDim + threadIdx.x;
	unsigned int idByThread = blockIdx.x * blockDim.x;
					//<====================================================END OF CHANGE BLOCK================================						
	int myMin = (i < n) ? g_idata[i] : INF;

	if (i + blockDim.x < n)
	{
		int tempMin = g_idata[i + blockDim.x];
		myMin = myMin < tempMin ? myMin : tempMin;
	}


	sdata[tid] = myMin;
	__syncthreads();

	// do reduction in shared mem
	for (unsigned int s = blockDim.x / 2; s>0; s >>= 1)
	{
		if (tid < s)
		{
			int temp = sdata[tid + s];

			sdata[tid] = myMin = myMin  < temp ? myMin : temp;
		}

		__syncthreads();
	}

	// write result for this block to global mem

	if (tid == 0)
		g_odata[blockIdx.x] = sdata[0];

	__syncthreads();

	// minnak version
	if (idByThread + threadIdx.x == 0){//<-----------------------------------------------------change
		int minnak = g_odata[0];
		for (int j = 1; j < n2; j++)
			if (minnak > g_odata[j])
				minnak = g_odata[j];
		g_odata[0] = minnak;
	}
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void minimumKernel(int *edgeIndex, int *edges, int * costs, int* deltas, int* U, int* nodeW, int* g_odata, int* numOfThreads)
{

	unsigned int i = GET_THREAD_ID
		unsigned int tid = threadIdx.x;
	extern __shared__ int amca[];
	int * s_data = amca;

	if (i < *numOfThreads)
	{
		int wPlusDeltas = nodeW[i] + deltas[i];
		if (U[i] == 1)
		{
			if (deltas[i] == INF)
				s_data[tid] = INF;
			else
				s_data[tid] = wPlusDeltas;         
		}
		else
		{
			s_data[tid] = INF;
		}

	}
	else
	{
		s_data[tid] = INF;
	}
	__syncthreads();
	// Reduce2 Cuda SDK
	for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1)
	{
		int tidPlusS = tid + s;//<----------------------------------------------------------------------
		if (tid < s)
		{
			//printf("amca : %d\n", blockDim.x);
			if (s_data[tid] > s_data[tidplusS])
			{
				s_data[tid] = s_data[tidPlusS];//<---------------------------------------------------
			}
		}
		__syncthreads();
	}

	// write result for this block to global mem
	if (tid == 0)
	{
		g_odata[blockIdx.x] = s_data[0];
	}
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void fillQPrefix(int* F, int* Qcondition, int* prefixSum, int n_elements,int *headF)
{
	unsigned int i = GET_THREAD_ID;
	unsigned int elementPrev = n_elements - 1;
	unsigned int prefixPrev = prefixSum[i] - 1;//<asdhfasjdhfkjashdfhkjasdf

	if (i < n_elements)
	{
		                                                                      
		if (i == 0)
		{
			*headF = prefixSum[elementPrev];//<--------------------------asfasdf
		}
		if (Qcondition[i] == 1)
		{
			F[(prefixSum[i] - 1)] = i;
		}
	}
	
}



__global__ void updateKernelPrefix(int* edgeIndex, int* edges, int*costs, int* nodeW, int* F, int* headF, int* U, int* isInQ, int* partialSums, int* Qcondition, int* threshold, int* numOfThreads)
{

	__shared__ int shared[1];
	int nData = *numOfThreads;
	unsigned int i = GET_THREAD_ID;
	
	int* s_data = shared;

	if (threadIdx.x == 0)
		s_data[0] = nData;

	__syncthreads();
	bool cond_isInQ, cond_isInQ2;
	if (i < s_data[0])
	{
		cond_isInQ = (U[i] == 1) && (nodeW[i] <= *threshold);
		if (cond_isInQ)
		{
			U[i] = 0;
			isInQ[i] = 1;
			Qcondition[i] = 1;	
		}
		else
		{
			isInQ[i] = 0;
			Qcondition[i] = 0;
		}
	}
		
}




/**********************************************************************************************************************************/
/**********************************************************************************************************************************/

__global__ void Dijkstra(int *edgeIndex, int *edges, int * costs,
	int* nodeW, int* nodeParent, int* source, int* F, int* U, int* threshold, int* deltas, int* g_odata, int* numOfThreads)
{

	__shared__ int shared[1];

	int* s_data = shared;
	unsigned int i = GET_THREAD_ID

		if (threadIdx.x == 0)
			s_data[0] = *numOfThreads;

	__syncthreads();
	if (i < s_data[0])
	{
		unsigned int s = *source;

		//! initialize
		if (i == s)
		{
			nodeW[i] = 0;
			nodeParent[i] = -2;
			U[i] = 0;  // control
			F[i] = 1;
		}
		else
		{
			nodeW[i] = INF;
			nodeParent[i] = -1;
			U[i] = 1;
			F[i] = 0;
		}

		__syncthreads();

		if (i == 0)
		{
			int threadsPerBlock = BS;
			//int numOfBlocks = *numOfThreads / threadsPerBlock + (*numOfThreads % threadsPerBlock == 0 ? 0 : 1);
			//=================== ADDED ALL UP TO WHILE===========================================================
			int blocks = *numOfThreads / threadsPerBlock;
			int blocksLeftovers = *numOfThreads % threadsPerBlock;
			int extrasA = blocks + blocksLeftovers;
	
			int numOfBlocks =  (extrasA == 0 ? 0 : 1);
			cudaStream_t s;
			cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking);
			
			int reduceTPB = 32;//<----------------------------------------------movede up 
			int blocksPerTPB = numOfBlocks / reduceTPB;
			int blocksPerTPBLeftovers = numOfBlocks % reduceTPB;
			int extrasB = blocksPerTPB + blocksPerTPBLeftovers;			
	
			//threshold = INF;
			while (true)
			{
				*threshold = INF;

				relaxKernel << < numOfBlocks, threadsPerBlock, 0, s >> > (edgeIndex, edges, costs, nodeW, nodeParent, F, U, numOfThreads);

				minimumKernel << < numOfBlocks, threadsPerBlock, 4096, s >> > (edgeIndex, edges, costs, deltas, U, nodeW, g_odata, numOfThreads);

				
				int numOfBlocks2 = (extrasB == 0 ? 0 : 1);

				reduce3 << <numOfBlocks2, reduceTPB, 1024, s >> >(g_odata, threshold, numOfBlocks, numOfBlocks2);

				updateKernel << < numOfBlocks, threadsPerBlock, 0, s >> >(edgeIndex, edges, costs, nodeW, F, U, threshold, numOfThreads);

				cudaDeviceSynchronize();
				//printf("threshold = %f \n", *threshold);

				if (*threshold == INF)
				{
					break;
				}

				//printf("\n*************************************************************************\n");
			}
		}
	}
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void DijkstraQ(int *edgeIndex, int *edges, int * costs,
	int* nodeW, int* nodeParent, int* source, int* F, int* headF, int* U, int* threshold, int* deltas, int* g_odata, int* numOfThreads)
{


	__shared__ int shared[1];

	int* s_data = shared;
	unsigned int i = GET_THREAD_ID

		if (threadIdx.x == 0)
			s_data[0] = *numOfThreads;

	__syncthreads();
	if (i < s_data[0])
	{
		unsigned int s = *source;

		//! initialize
		if (i == s)
		{
			nodeW[i] = 0;
			nodeParent[i] = -2;
			U[i] = 0;  // control
			*headF = 0;
			F[*headF] = i;
			*headF = 1;
		}
		else
		{
			nodeW[i] = INF;
			nodeParent[i] = -1;
			U[i] = 1;
		}

		__syncthreads();

		if (i == 0)
		{
			int reduceTPB = 32;//added all this befire while asfdaskjfkjasdfkjasdhfhkjasdhfkljadskjfhkjashdfldkjasf
			int threadsPerBlock = BS;
			int blocks = *numOfThreads / threadsPerBlock;
			int blocksLeftovers = *numOfThreads % threadsPerBlock;
			int extrasC = blocks + blocksLeftovers;
			int numOfBlocks = (extrasC == 0 ? 0 : 1);	

			//int numOfBlocks = *numOfThreads / threadsPerBlock + (*numOfThreads % threadsPerBlock == 0 ? 0 : 1);

			//printf("numOfBlocks: %d \n", numOfBlocks);
			computeDeltaUKernel << <  numOfBlocks, threadsPerBlock >> >(edgeIndex, edges, costs, deltas, numOfThreads);


			while (true)
			{
				*threshold = INF;

				int threadsPerBlockQ = threadsPerBlock;
				int headAmt = *headF / threadsPerBlockQ;
				int headAmtLeftovers = *headF % threadsPerBlockQ;
				int extrasD = headAmt + headAmtLeftovers;//<----------------------------------------------------------------------------------
				
				int numOfBlocksQ = (extrasD == 0 ? 0 : 1);//<----------------------------------------------------------------------------------
//				int numOfBlocksQ = *headF / threadsPerBlockQ + (*headF % threadsPerBlockQ == 0 ? 0 : 1);

				relaxKernelQ << < numOfBlocksQ, threadsPerBlockQ >> >(edgeIndex, edges, costs, nodeW, nodeParent, F, headF, U);
				minimumKernel << < numOfBlocks, threadsPerBlock, 16536 >> > (edgeIndex, edges, costs, deltas, U, nodeW, g_odata, numOfThreads);
		
				int blocksPerTPB = numOfBlocks / reduceTPB;
				int blocksPerTPBLeftovers = numOfBlocks % reduceTPB;
				int extrasE = blocksPerTPB + blocksPerTPBLeftovers;	
				int numOfBlocks2 = (extrasE == 0 ? 0 : 1);//<----------------------------------------------------------------------------------------

				reduce3 << <numOfBlocks2, reduceTPB, 4096 >> >(g_odata, threshold, numOfBlocks, numOfBlocks2);

				updateKernelQ << < numOfBlocks, threadsPerBlock >> >(edgeIndex, edges, costs, nodeW, F, headF, U, threshold, numOfThreads);

				cudaDeviceSynchronize();


				if (*threshold == INF)
				{
					break;
				}

			}

		}
	}
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


__global__ void DijkstraPrefix(int *edgeIndex, int *edges, int * costs,
	int* nodeW, int* nodeParent, int* source, int* F, int* headF, int* U, int* isInQ, int* partialSums, int* Qcondition, int* threshold, int* deltas, int* g_odata, int* numOfThreads)
{
	
	__shared__ int shared[1];

	int* s_data = shared;
	unsigned int i = GET_THREAD_ID;
	/*if (i == 0)
	{
		printf("%d\n", *source);
	}*/

	if (threadIdx.x == 0)
		s_data[0] = *numOfThreads;

	__syncthreads();
	if (i < s_data[0])
	{
		unsigned int s = *source;

		//! initialize
		if (i == s)
		{
			nodeW[i] = 0;
			nodeParent[i] = -2;
			U[i] = 0;  // control
			*headF = 0;
			F[*headF] = i;
			*headF = 1;
		}
		else
		{
			nodeW[i] = INF;
			nodeParent[i] = -1;
			U[i] = 1;
		}

		__syncthreads();

		if (i == 0)
		{
			int threadsPerBlock = BS;
			int blocks = *numOfThreads/threadsPerBlock;
			int blockLeftovers = *numOfThreads % threadsPerBlock;
			int extrasF =  blocks + blockLeftovers;
			int numOfBlocks = (extrasF == 0 ? 0 : 1);//<------------------------------------------------------4/20 edit it

			//printf("numOfBlocks: %d \n", numOfBlocks);
			computeDeltaUKernel << <  numOfBlocks, threadsPerBlock >> >(edgeIndex, edges, costs, deltas, numOfThreads);

			int n_elements = *numOfThreads;
			int blockSize = BS;

			int gridSize = n_elements / blockSize + ((n_elements % blockSize) == 0 ? 0 : 1);
			int nWarps = blockSize / 32;
			int shmem_sz = nWarps * sizeof(int);
			int n_partialSums = gridSize;
			int partial_sz = n_partialSums*sizeof(int);

			


			int p_blockSize = (n_partialSums < blockSize) ? n_partialSums : blockSize;
			int p_gridSize = ((n_partialSums % p_blockSize) == 0) ?
				(n_partialSums / p_blockSize) :
				(n_partialSums / p_blockSize + 1);  //iDivUp(n_partialSums, p_blockSize);

			int reduceTPB = 32;//<-----------------------------------------------------
			while (true)
			{
				*threshold = INF;
				int threadsPerBlockQ = threadsPerBlock;
				int headBlockPerThread = *headF/threadsPerBlockQ;
				int headBlockPerThreadLeftovers = *headF % threadsPerBlockQ;
				int extrasG = headBlockPerThread + headBlockPerThreadLeftovers;
				int numOfBlocksQ = (extrasG == 0 ? 0 : 1);//<---------------------------------------------------------------------------------------------

				relaxKernelQ << < numOfBlocksQ, threadsPerBlockQ >> >(edgeIndex, edges, costs, nodeW, nodeParent, F, headF, U);
				minimumKernel << < numOfBlocks, threadsPerBlock, 16536 >> > (edgeIndex, edges, costs, deltas, U, nodeW, g_odata, numOfThreads);
				int blocksPerTPB = numOfBlocks / reduceTPB;
				int blocksPerTPBLeftovers = numOfBlocks % reduceTPB;
				int extrasH = blocksPerTPB + blocksPerTPBLeftovers;
				int numOfBlocks2 = ( extrasH == 0 ? 0 : 1);//<0--------------------------------------------------------------------addddddddddd

				reduce3 << <numOfBlocks2, reduceTPB, 4096 >> >(g_odata, threshold, numOfBlocks, numOfBlocks2);
				cudaDeviceSynchronize();
				updateKernelPrefix << < numOfBlocks, threadsPerBlock >> >(edgeIndex, edges, costs, nodeW, F, headF, U, isInQ, partialSums, Qcondition, threshold, numOfThreads);
		
				

				shfl_scan_test << <gridSize, blockSize, shmem_sz >> >(isInQ, 32, partialSums);
				shfl_scan_test << <p_gridSize, p_blockSize, shmem_sz >> >(partialSums, 32);
				uniform_add << <gridSize - 1, blockSize >> >(isInQ + blockSize, partialSums, n_elements);
				
				
				fillQPrefix << <gridSize, blockSize >> >(F, Qcondition, isInQ, n_elements,headF);
				
				
				cudaDeviceSynchronize();
				
				
				if (*threshold == INF)
				{
					//printf("%d		%d\n", *headF, *threshold);
					break;
				}

			}

		}
	}
}


__global__ void cudaWarmup()
{
	int i = GET_THREAD_ID
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/

struct Edge {
	int head;
	int cost;
};

typedef std::vector<std::vector<Edge> > Graph;// = std::vector<std::vector<Edge>>;
typedef std::vector<int> SingleSP;;// = vector<int>;
typedef std::vector<std::vector<int> > AllSP;//using AllSP = vector<vector<int>>;

SingleSP djikstra(const Graph& g, int s) {
	SingleSP dist(g.size(), INF);
	set<pair<int, int> > frontier;

	frontier.insert(pair<int, int>(0, s));
	
	while (!frontier.empty()) {
		pair<int, int> p = *frontier.begin();
		frontier.erase(frontier.begin());

		int d = p.first;
		int n = p.second;

		// this is our shortest path to n
		dist[n] = d;
		
		// now look at all edges out from n to update the frontier
		for (int k = 0; k < g[n].size(); k++) {
                        Edge e = g[n][k];
			int tempFrontier = d + e.cost;//<----------------------------------------------------------------------------------------
			// update this node in the frontier if we have a shorter path
			if (tempFrontier < dist[e.head]) {
				if (dist[e.head] != INF) {
					// we've seen this node before, so erase it from the set in order to update it
					frontier.erase(frontier.find(pair<int, int>(dist[e.head], e.head)));                                                                  
				}
				frontier.insert(pair<int, int>(tempFrontier, e.head));
				dist[e.head] = tempFrontier;//<=-----------------------------------------------------------------------------------------
			}
		}
	}
	return dist;

}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/

void GPUDijkstraQ(int edgeSize, int nodeSize, int source, int* d_edgeIndex, int* d_edges, int* d_costs, int* nodeW, int* nodeParent){


	int * d_nodeW = 0;
	int* d_nodeParent = 0;
	int * d_headF = 0;
	int * d_head2 = 0;
	int* d_source = 0;
	int* d_F = 0;	// Frontier set
	int* d_U = 0;	// Unsettled set
	int* d_threshold = 0;
	int* d_deltas = 0;
	int* g_odata = 0;
	int* d_numOfThreads = 0;

	cudaEvent_t start, stop;
	float elapsedTime;
	cudaEventCreate(&start);
	cudaEventRecord(start, 0);

	int numOfThreads = 1024;
	//NOTE: This developer that made this program used this function frequently, may be possible to declare globally
	int nodesPerThread = nodeSize / numOfThreads;
	int nodesPerThreadLeftovers = nodeSize%numOfThreads;
	int extrasH = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH == 0 ? 0 : 1);	

	//int numOfBlocks = nodeSize / numOfThreads + (nodeSize%numOfThreads == 0 ? 0 : 1);



	cudaMalloc((void**)&d_nodeW, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_source, sizeof(int));
	cudaMalloc((void**)&d_F, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_U, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_threshold, 512 * sizeof(int));
	cudaMalloc((void**)&d_deltas, sizeof(int) * nodeSize);
	cudaMalloc((void**)&g_odata, sizeof(int) * 1024/* blocksize max 1024*/);
	cudaMalloc((void**)&d_numOfThreads, sizeof(int));

	cudaMemcpy(d_source, &source, sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(d_numOfThreads, &nodeSize, sizeof(int), cudaMemcpyHostToDevice);



	/* TEST DIJKSTRA WITH QUEUE */
	DijkstraQ << <numOfBlocks, numOfThreads >> >(d_edgeIndex, d_edges, d_costs, d_nodeW, d_nodeParent, d_source, d_F, d_headF, d_U, d_threshold, d_deltas, g_odata, d_numOfThreads);



	cudaEventCreate(&stop);
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&elapsedTime, start, stop);
	printf("GPU time with Q: %lf ms\n", elapsedTime);


	cudaMemcpy(nodeW, d_nodeW, nodeSize*sizeof(int), cudaMemcpyDeviceToHost);
	cudaMemcpy(nodeParent, d_nodeParent, nodeSize*sizeof(int), cudaMemcpyDeviceToHost);

	std::cout << "**************************************" << std::endl;
	for (int i = 0; i < 5; i++){

		int next = nodeParent[i];
		if (next == -1){
			std::cout << "unreachable" << std::endl;
			continue;;
		}
		std::cout << i << "	";
		while (next != -2){

			std::cout << next << "	";
			next = nodeParent[next];

		}
		std::cout << " ---->  " << nodeW[i];
		std::cout << std::endl;

	}


	cudaFree(d_source);
	cudaFree(d_nodeW);
	cudaFree(d_F);
	cudaFree(d_U);
	cudaFree(d_threshold);
	cudaFree(d_deltas);
	cudaFree(g_odata);
	cudaFree(d_numOfThreads);

}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


void GPUDijkstra(int edgeSize, int nodeSize, int source, int* d_edgeIndex, int* d_edges, int* d_costs, int* nodeW, int* nodeParent){

	int * d_nodeW = 0;
	int* d_nodeParent = 0;
	int* d_source = 0;
	int* d_F = 0;	// Frontier set
	int* d_U = 0;	// Unsettled set
	int* d_threshold = 0;
	int* d_deltas = 0;
	int* g_odata = 0;
	int* d_numOfThreads = 0;



	cudaEvent_t start, stop;
	float elapsedTime;
	cudaEventCreate(&start);
	cudaEventRecord(start, 0);

	int numOfThreads = BS;
	int nodesPerThread = nodeSize / numOfThreads;
	int nodesPerThreadLeftovers = nodeSize%numOfThreads;
	int extrasH = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH == 0 ? 0 : 1);
//	int numOfBlocks = nodeSize / numOfThreads + (nodeSize%numOfThreads == 0 ? 0 : 1);	<------------------------------------------------------------------------


	cudaMalloc((void**)&d_nodeW, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_nodeParent, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_source, sizeof(int));
	cudaMalloc((void**)&d_F, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_U, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_threshold, sizeof(int));
	cudaMalloc((void**)&d_deltas, sizeof(int) * nodeSize);
	cudaMalloc((void**)&g_odata, sizeof(int) * 1024/* blocksize max 1024*/);
	cudaMalloc((void**)&d_numOfThreads, sizeof(int));


	cudaMemcpy(d_source, &source, sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(d_numOfThreads, &nodeSize, sizeof(int), cudaMemcpyHostToDevice);



	/* RUN DIJKSTRA*/
	Dijkstra << <numOfBlocks, numOfThreads >> >(d_edgeIndex, d_edges, d_costs, d_nodeW, d_nodeParent, d_source, d_F, d_U, d_threshold, d_deltas, g_odata, d_numOfThreads);

	cudaMemcpy(nodeW, d_nodeW, nodeSize*sizeof(int), cudaMemcpyDeviceToHost);

	cudaEventCreate(&stop);
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&elapsedTime, start, stop);
	printf("GPU time: %lf ms\n", elapsedTime);


	cudaFree(d_source);
	cudaFree(d_nodeW);
	cudaFree(d_nodeParent);
	cudaFree(d_F);
	cudaFree(d_U);
	cudaFree(d_threshold);
	cudaFree(d_deltas);
	cudaFree(g_odata);
	cudaFree(d_numOfThreads);


}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


void oneGPUDijkstra(int edgeSize, int nodeSize, int source, int head1, int head2, int mutex, int* d_edgeIndex, int* d_edges, int* d_costs, int* d_deltas, vector<int*>& allWeights, cudaStream_t* stream){


	int* nodeW = allWeights[0];
	int* nodeParent = 0;


	int * d_nodeW = 0;
	int* d_nodeParent = 0;
	int* d_source = 0;
	int* d_F = 0;	// Frontier set
	int* d_U = 0;	// Unsettled set
	int* d_threshold = 0;
	int* g_odata = 0;
	int* d_numOfThreads = 0;


	int numOfThreads = BS;
	int nodesPerThread = nodeSize / numOfThreads;
	int nodesPerThreadLeftovers = nodeSize%numOfThreads;
	int extrasH = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH == 0 ? 0 : 1);
//	int numOfBlocks = nodeSize / numOfThreads + (nodeSize%numOfThreads == 0 ? 0 : 1);


	cudaMalloc((void**)&d_nodeW, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_nodeParent, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_source, sizeof(int));
	cudaMalloc((void**)&d_F, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_U, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_threshold, sizeof(int));
	cudaMalloc((void**)&g_odata, sizeof(int) * 1024/* blocksize max 1024*/);
	cudaMalloc((void**)&d_numOfThreads, sizeof(int));


	cudaMemcpyAsync(d_source, &source, sizeof(int), cudaMemcpyHostToDevice, *stream);
	cudaMemcpyAsync(d_numOfThreads, &nodeSize, sizeof(int), cudaMemcpyHostToDevice, *stream);



	/* RUN DIJKSTRA */
	Dijkstra << <numOfBlocks, numOfThreads, 0, *stream >> >(d_edgeIndex, d_edges, d_costs, d_nodeW, d_nodeParent, d_source, d_F, d_U, d_threshold, d_deltas, g_odata, d_numOfThreads);


	cudaMemcpyAsync(nodeW, d_nodeW, nodeSize*sizeof(int), cudaMemcpyDeviceToHost, *stream);
	//cudaMemcpy(nodeParent, d_nodeParent, nodeSize*sizeof(int), cudaMemcpyDeviceToHost);


	cudaFree(d_source);
	cudaFree(d_nodeW);
	cudaFree(d_nodeParent);
	cudaFree(d_F);
	cudaFree(d_U);
	cudaFree(d_threshold);
	cudaFree(g_odata);
	cudaFree(d_numOfThreads);


}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


void oneGPUDijkstraQ(int edgeSize, int nodeSize, int source, int* d_edgeIndex, int* d_edges, int* d_costs, int* d_deltas, vector<int*>& allWeights, cudaStream_t* stream){


	//int* nodeW = allWeights[source];
	int* nodeW = allWeights[0];
	int* nodeParent = 0;



	int * d_nodeW = 0;
	int* d_nodeParent = 0;
	int* d_source = 0;
	int* d_F = 0;	// Frontier set
	int* d_headF = 0;
	int* d_U = 0;	// Unsettled set
	int* d_threshold = 0;
	int* g_odata = 0;
	int* d_numOfThreads = 0;


	int numOfThreads = BS;
	int nodesPerThread = nodeSize / numOfThreads;
	int nodesPerThreadLeftovers = nodeSize%numOfThreads;
	int extrasH = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH == 0 ? 0 : 1);
//	int numOfBlocks = nodeSize / numOfThreads + (nodeSize%numOfThreads == 0 ? 0 : 1);



	cudaMalloc((void**)&d_nodeW, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_nodeParent, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_source, sizeof(int));
	cudaMalloc((void**)&d_F, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_U, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_headF, sizeof(int));
	cudaMalloc((void**)&d_threshold, sizeof(int));
	cudaMalloc((void**)&g_odata, sizeof(int) * 1024/* blocksize max 1024*/);
	cudaMalloc((void**)&d_numOfThreads, sizeof(int));



	cudaMemcpyAsync(d_source, &source, sizeof(int), cudaMemcpyHostToDevice, *stream);
	cudaMemcpyAsync(d_numOfThreads, &nodeSize, sizeof(int), cudaMemcpyHostToDevice, *stream);


	/* RUN DIJKSTRA WITH QUEUE */
	DijkstraQ << <numOfBlocks, numOfThreads, 0, *stream >> >(d_edgeIndex, d_edges, d_costs, d_nodeW, d_nodeParent, d_source, d_F, d_headF, d_U, d_threshold, d_deltas, g_odata, d_numOfThreads);

	//cudaDeviceSynchronize();

	cudaMemcpyAsync(nodeW, d_nodeW, nodeSize*sizeof(int), cudaMemcpyDeviceToHost, *stream);

	/*cudaDeviceSynchronize();
	cout << source << endl;
	for (int i = 0; i < nodeSize; i++)
		cout << allWeights[source][i] << "  ";

	
	cout << endl;*/

	//cudaMemcpy(nodeParent, d_nodeParent, nodeSize*sizeof(int), cudaMemcpyDeviceToHost);


	cudaFree(d_source);

	cudaFree(d_nodeW);
	cudaFree(d_nodeParent);
	cudaFree(d_F);

	cudaFree(d_U);
	cudaFree(d_threshold);
	cudaFree(g_odata);
	cudaFree(d_numOfThreads);




}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


void oneGPUDijkstraQVerify(int edgeSize, int nodeSize, int source, int* d_edgeIndex, int* d_edges, int* d_costs, int* d_deltas, vector<int*>& allWeights, cudaStream_t* stream){


	int* nodeW = allWeights[source];
	
	int* nodeParent = 0;



	int * d_nodeW = 0;
	int* d_nodeParent = 0;
	int* d_source = 0;
	int* d_F = 0;	// Frontier set
	int* d_headF = 0;
	int* d_U = 0;	// Unsettled set
	int* d_threshold = 0;
	int* g_odata = 0;
	int* d_numOfThreads = 0;


	int numOfThreads = BS;
	int nodesPerThread = nodeSize / numOfThreads;
	int nodesPerThreadLeftovers = nodeSize%numOfThreads;
	int extrasH = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH == 0 ? 0 : 1);
//	int numOfBlocks = nodeSize / numOfThreads + (nodeSize%numOfThreads == 0 ? 0 : 1);



	cudaMalloc((void**)&d_nodeW, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_nodeParent, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_source, sizeof(int));
	cudaMalloc((void**)&d_F, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_U, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_headF, sizeof(int));
	cudaMalloc((void**)&d_threshold, sizeof(int));
	cudaMalloc((void**)&g_odata, sizeof(int) * 1024/* blocksize max 1024*/);
	cudaMalloc((void**)&d_numOfThreads, sizeof(int));



	cudaMemcpyAsync(d_source, &source, sizeof(int), cudaMemcpyHostToDevice, *stream);
	cudaMemcpyAsync(d_numOfThreads, &nodeSize, sizeof(int), cudaMemcpyHostToDevice, *stream);


	/* RUN DIJKSTRA WITH QUEUE */
	DijkstraQ << <numOfBlocks, numOfThreads, 0, *stream >> >(d_edgeIndex, d_edges, d_costs, d_nodeW, d_nodeParent, d_source, d_F, d_headF, d_U, d_threshold, d_deltas, g_odata, d_numOfThreads);

	//cudaDeviceSynchronize();

	cudaMemcpyAsync(nodeW, d_nodeW, nodeSize*sizeof(int), cudaMemcpyDeviceToHost, *stream);

	/*cudaDeviceSynchronize();
	cout << source << endl;
	for (int i = 0; i < nodeSize; i++)
	cout << allWeights[source][i] << "  ";


	cout << endl;*/

	//cudaMemcpy(nodeParent, d_nodeParent, nodeSize*sizeof(int), cudaMemcpyDeviceToHost);


	cudaFree(d_source);

	cudaFree(d_nodeW);
	cudaFree(d_nodeParent);
	cudaFree(d_F);

	cudaFree(d_U);
	cudaFree(d_threshold);
	cudaFree(g_odata);
	cudaFree(d_numOfThreads);




}
/**********************************************************************************************************************************/
/**********************************************************************************************************************************/


void oneGPUDijkstraPrefix(int edgeSize, int nodeSize, int source, int* d_edgeIndex, int* d_edges, int* d_costs, int* d_deltas, vector<int*>& allWeights, cudaStream_t* stream){


	//int* nodeW = allWeights[source];
	int* nodeW = allWeights[0];
	int* nodeParent = 0;



	int * d_nodeW = 0;
	int* d_nodeParent = 0;
	int* d_source = 0;
	int* d_F = 0;	// Frontier set
	int* d_headF = 0;
	int* d_U = 0;	// Unsettled set
	int* d_threshold = 0;
	int* g_odata = 0;
	int* d_numOfThreads = 0;
	int* d_isInQ = 0;
	int* d_partialSums = 0;
	int* d_Qcondition = 0;
	int sizeByNode = sizeof(int) * nodeSize;

	int numOfThreads = BS;
	int nodesPerThread = nodeSize / numOfThreads;
	int nodesPerThreadLeftovers = nodeSize%numOfThreads;
	int extrasH = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH == 0 ? 0 : 1);
//	int numOfBlocks = nodeSize / numOfThreads + (nodeSize%numOfThreads == 0 ? 0 : 1);       


	cudaMalloc((void**)&d_nodeW, sizeByNode);
	cudaMalloc((void**)&d_nodeParent, sizeByNode);
	cudaMalloc((void**)&d_source, sizeof(int));
	cudaMalloc((void**)&d_F, sizeByNode);
	cudaMalloc((void**)&d_U, sizeByNode);
	cudaMalloc((void**)&d_headF, sizeof(int));
	cudaMalloc((void**)&d_threshold, sizeof(int));
	cudaMalloc((void**)&g_odata, sizeof(int) * 1024/* blocksize max 1024*/);
	cudaMalloc((void**)&d_numOfThreads, sizeof(int));
	cudaMalloc((void**)&d_Qcondition, sizeByNode);
	cudaMalloc((void**)&d_isInQ, sizeByNode);		//Size by node was added in since the beginning of this block


	int nodePerBull = nodeSize/BS;				//<------------------------------------------------------------------------------------------------------------
	int nodePerBullLeftovers = nodeSize%BS;
	int extrasAA = nodePerBull + nodePerBullLeftovers;
	int n_partialSums = (extrasAA == 0 ? 0 : 1);
	cudaMalloc((void**)&d_partialSums, sizeof(int) * n_partialSums);



	cudaMemcpyAsync(d_source, &source, sizeof(int), cudaMemcpyHostToDevice, *stream);
	cudaMemcpyAsync(d_numOfThreads, &nodeSize, sizeof(int), cudaMemcpyHostToDevice, *stream);


	/* RUN DIJKSTRA WITH QUEUE */
	DijkstraPrefix << <numOfBlocks, numOfThreads, 0, *stream >> >(d_edgeIndex, d_edges, d_costs, d_nodeW, d_nodeParent, d_source, d_F, d_headF, d_U, d_isInQ, d_partialSums, d_Qcondition, d_threshold, d_deltas, g_odata, d_numOfThreads);

	cudaMemcpyAsync(nodeW, d_nodeW, nodeSize*sizeof(int), cudaMemcpyDeviceToHost, *stream);

	/*cudaDeviceSynchronize();
	cout << source << endl;
	for (int i = 0; i < nodeSize; i++)
	cout << allWeights[source][i] << "  ";


	cout << endl;*/

	//cudaMemcpy(nodeParent, d_nodeParent, nodeSize*sizeof(int), cudaMemcpyDeviceToHost);


	cudaFree(d_source);

	cudaFree(d_nodeW);
	cudaFree(d_nodeParent);
	cudaFree(d_F);
	cudaFree(d_headF);
	cudaFree(d_U);
	cudaFree(d_threshold);
	cudaFree(g_odata);
	cudaFree(d_numOfThreads);
	cudaFree(d_isInQ);
	cudaFree(d_Qcondition);
	cudaFree(d_partialSums);

}


void oneGPUDijkstraPrefixVerify(int edgeSize, int nodeSize, int source, int* d_edgeIndex, int* d_edges, int* d_costs, int* d_deltas, vector<int*>& allWeights, cudaStream_t* stream){


	int* nodeW = allWeights[source];
	//int* nodeW = allWeights[0];
	int* nodeParent = 0;



	int * d_nodeW = 0;
	int* d_nodeParent = 0;
	int* d_source = 0;
	int* d_F = 0;	// Frontier set
	int* d_headF = 0;
	int* d_U = 0;	// Unsettled set
	int* d_threshold = 0;
	int* g_odata = 0;
	int* d_numOfThreads = 0;
	int* d_isInQ = 0;
	int* d_partialSums = 0;
	int* d_Qcondition = 0;
	int sizeByNode = sizeof(int) * nodeSize;

	int numOfThreads = BS;
	int nodesPerThread = nodeSize / numOfThreads;
	int nodesPerThreadLeftovers = nodeSize%numOfThreads;
	int extrasH = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH == 0 ? 0 : 1);//<-------------------------------------------------------- 
//	int numOfBlocks = nodeSize / numOfThreads + (nodeSize%numOfThreads == 0 ? 0 : 1);


	
	cudaMalloc((void**)&d_nodeW, sizeByNode);
	cudaMalloc((void**)&d_nodeParent, sizeByNode);
	cudaMalloc((void**)&d_source, sizeof(int));
	cudaMalloc((void**)&d_F, sizeByNode);
	cudaMalloc((void**)&d_U, sizeByNode);
	cudaMalloc((void**)&d_headF, sizeof(int));
	cudaMalloc((void**)&d_threshold, sizeof(int));
	cudaMalloc((void**)&g_odata, sizeof(int) * 1024/* blocksize max 1024*/);
	cudaMalloc((void**)&d_numOfThreads, sizeof(int));
	cudaMalloc((void**)&d_Qcondition, sizeByNode);
	cudaMalloc((void**)&d_isInQ, sizeByNode);	//same as above
	

	int nodePerBull = nodeSize/BS;
	int nodePerBullLeftovers = nodeSize%BS;
	int extrasZ = nodePerBull + nodePerBullLeftovers;
	int n_partialSums =(extrasZ == 0 ? 0 : 1);//<---------------------------------------------------------
	cudaMalloc((void**)&d_partialSums, sizeof(int) * n_partialSums);



	cudaMemcpyAsync(d_source, &source, sizeof(int), cudaMemcpyHostToDevice, *stream);
	cudaMemcpyAsync(d_numOfThreads, &nodeSize, sizeof(int), cudaMemcpyHostToDevice, *stream);


	/* RUN DIJKSTRA WITH QUEUE */
	DijkstraPrefix << <numOfBlocks, numOfThreads, 0, *stream >> >(d_edgeIndex, d_edges, d_costs, d_nodeW, d_nodeParent, d_source, d_F, d_headF, d_U, d_isInQ, d_partialSums, d_Qcondition, d_threshold, d_deltas, g_odata, d_numOfThreads);

	//cudaDeviceSynchronize();

	cudaMemcpyAsync(nodeW, d_nodeW, nodeSize*sizeof(int), cudaMemcpyDeviceToHost, *stream);

	/*cudaDeviceSynchronize();
	cout << source << endl;
	for (int i = 0; i < nodeSize; i++)
	cout << allWeights[source][i] << "  ";


	cout << endl;*/

	//cudaMemcpy(nodeParent, d_nodeParent, nodeSize*sizeof(int), cudaMemcpyDeviceToHost);


	cudaFree(d_source);

	cudaFree(d_nodeW);
	cudaFree(d_nodeParent);
	cudaFree(d_F);

	cudaFree(d_U);
	cudaFree(d_threshold);
	cudaFree(g_odata);
	cudaFree(d_numOfThreads);




}



void Johnson1(int* outW, int* edgeIndex, int* edges, int* costs, int nodeSize, int edgeSize){

	int source = nodeSize;
	edgeSize += nodeSize;
	nodeSize++;

	int head1 = 0;
	int head2 = 0;
	int mutex = 0;
	int* d_nodeW;
	int* d_nodeParent;
	int* F1 = 0;
	int* F2 = 0;
	int * d_head1 = 0;
	int * d_head2 = 0;
	int* d_itNo = 0;
	int* d_source = 0;
	int* d_mutex = 0;
	int *d_numOfThreads = 0;
	cudaMalloc((void**)&F1, sizeof(int) * nodeSize);
	cudaMalloc((void**)&F2, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_itNo, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_head1, sizeof(int));
	cudaMalloc((void**)&d_head2, sizeof(int));
	cudaMalloc((void**)&d_source, sizeof(int));
	cudaMalloc((void**)&d_mutex, sizeof(int));
	cudaMalloc((void**)&d_nodeParent, sizeof(int) * nodeSize);
	cudaMalloc((void**)&d_numOfThreads, sizeof(int));
	cudaMalloc((void**)&d_nodeW, sizeof(int) * nodeSize);


	int* d_edgeIndex, *d_edges, *d_costs;
	cudaMalloc((void**)&d_edgeIndex, sizeof(int) * (nodeSize + 1));
	cudaMalloc((void**)&d_edges, sizeof(int) * edgeSize);
	cudaMalloc((void**)&d_costs, sizeof(int) * edgeSize);

	cudaMemcpy(d_edgeIndex, edgeIndex, sizeof(int) * (nodeSize + 1), cudaMemcpyHostToDevice);
	cudaMemcpy(d_edges, edges, sizeof(int) * (edgeSize), cudaMemcpyHostToDevice);
	cudaMemcpy(d_costs, costs, sizeof(int) * (edgeSize), cudaMemcpyHostToDevice);



	cudaMemcpy(d_head1, &head1, sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(d_head2, &head2, sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(d_source, &source, sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(d_mutex, &mutex, sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(d_numOfThreads, &nodeSize, sizeof(int), cudaMemcpyHostToDevice);

	int numOfThreads = BS;
	int nodesPerThread = nodeSize / numOfThreads;
	int nodesPerThreadLeftovers = nodeSize%numOfThreads;
	int extrasH = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH == 0 ? 0 : 1);
//	int numOfBlocks = nodeSize / numOfThreads + (nodeSize%numOfThreads == 0 ? 0 : 1); <--------------------------------------------------------------------------------------------Kind of hidden here

	BF << <numOfBlocks, numOfThreads >> >(d_edgeIndex, d_edges, d_costs, d_nodeW, d_nodeParent, d_itNo, d_source, F1, F2, d_head1, d_head2, d_mutex, d_numOfThreads);



	cudaMemcpy(costs, d_costs, edgeSize*sizeof(int), cudaMemcpyDeviceToHost);
	cudaMemcpy(outW, d_nodeW, (nodeSize)*sizeof(int), cudaMemcpyDeviceToHost);


	//for (int i = 0; i < nodeSize; i++)
	//	cout << outW[i]<<"	" ;
	//cout << endl << endl;


	//for (int i = 0; i < edgeSize ; i++)
	//	cout <<costs[i]<<"   ";
	//cout << endl << endl;



}



Graph addZeroEdge(Graph g) {
	// add a zero-cost edge from vertex 0 to all other edges
	for (int i = 1; i < g.size(); i++) {
                Edge e; e.head=i; e.cost=0; 
		g[0].push_back(e);
	}

	return g;
}

SingleSP bellmanford(Graph &g, int s) {
	vector<vector<int> > memo(1, vector<int>(g.size(), INF));

	// initialise base case
	memo[0][s] = 0;

	for (int i = 1; i < memo.size(); i++) {
		// compute shortest paths from s to all vertices, with max hop-count i
		for (int n = 0; n < g.size(); n++) {
			/*	if (memo[0][n] < memo[0][n]) {
			memo[0][n] = memo[0][n];
			}*/
			for (int k = 0; k < g[n].size(); k++) {
                                Edge e = g[n][k];
				if (memo[0][n] != INF) {
					if (memo[0][n] + e.cost < memo[0][e.head]) {
						memo[0][e.head] = memo[0][n] + e.cost;
					}
				}
			}
		}
	}

	// check if the last iteration differed from the 2nd-last
	/*for (int j = 0; j < g.size(); j++) {
	if (memo[g.size() + 1][j] != memo[g.size()][j]) {
	throw string{ "negative cycle found" };
	}
	}*/

	return memo[0];
}


/**********************************************************************************************************************************/
/**********************************************************************************************************************************/

// CPU - GPU verification
int main1()
{


	srand(time(NULL));
	int edgeSize = 12;
	int nodeSize = 9;
	int source = 0;
	int head1 = 0;
	int head2 = 0;
	int mutex = 0;


	std::ifstream f;
	

	string graphName = "graph1.txt" ;
	//string graphName = "graph2.txt";
	//string graphName = "graph3.txt";
	//string graphName = "graph4.txt";
	//string graphName = "graph5.txt";
	//string graphName = "graph6.txt";
	//string graphName = "graph7.txt";
	//string graphName = "graph8.txt";
	//string graphName = "graph9.txt";
	

	//std::string graphName = "50k_1m.txt";

	f.open(graphName.c_str());

	std::cout << graphName << std::endl;

	if (!f.is_open())
	{
		std::cout << "File not found!" << std::endl;
		getchar();
		return -1;
	}
	f >> nodeSize;
	f >> edgeSize;

	cout << edgeSize << "		" << nodeSize << endl;



	int* edgeIndex, *edges, *costs;
	cudaMallocHost((void**)&edgeIndex, (nodeSize + 2)*sizeof(int));
	cudaMallocHost((void**)&edges, (edgeSize + nodeSize)*sizeof(int));
	cudaMallocHost((void**)&costs, (edgeSize + nodeSize)*sizeof(int));


	int* nodeW = new int[nodeSize];
	int* nodeParent = new int[nodeSize];

	/*******************/
	Graph g;
	g.resize(nodeSize);

	/******************/
	std::vector<std::vector<int> > edgesVector;
	edgesVector.resize(nodeSize + 1);
	std::vector<std::vector<int> > costsVector;
	costsVector.resize(nodeSize + 1);
	for (int i = 0; i < edgeSize; i++){

		int from, to;
		int cost;

		f >> from;
		f >> to;

		//from--;
		//to--;
		f >> cost;
		//cost = rand() % 10 + 1;

		edgesVector[from].push_back(to);
		costsVector[from].push_back(cost);


		/***********/
		Edge e;
		e.head = to;
		e.cost = cost;
		g[from].push_back(e);
		/***********/
	}

	for (int i = 0; i < nodeSize; i++){

		edgesVector[nodeSize].push_back(i);
		costsVector[nodeSize].push_back(0);

	}


	int offset = 0;

	for (int i = 0; i < nodeSize; i++){

		edgeIndex[i] = offset;
		//printf("%d", offset);
		int end = offset + edgesVector[i].size();

		for (int j = offset; j < end; j++){
			
			int jSubOffset = j - offset;//<------------------------------------------------------------------------------------added this
			edges[j] = edgesVector[i][jSubOffset];
			costs[j] = costsVector[i][jSubOffset];

		}


		offset = end;

	}

	edgeIndex[nodeSize] = edgeSize;


	for (int i = edgeSize; i < edgeSize + nodeSize; i++){
		
		int iSubEdgesize = i - edgeSize;//<-------------------------------------------------------------------------------------this too
		edges[i] = edgesVector[nodeSize][iSubEdgesize];
		costs[i] = costsVector[nodeSize][iSubEdgesize];


	}



	int totSize = edgeSize + nodeSize;//<-----------------------------------------------------------------------------------------another add
	int nodeNext = nodeSize + 1;
	int sizeByEdges = sizeof(int) * edgeSize;
	int sizeByNodes = sizeof(int) * nodeSize;
	edgeIndex[nodeNext] = totSize;             
	f.close();



	//GPUDijkstraQ(edgeSize, nodeSize, source, head1, head2, mutex, edgeIndex, edges, costs, nodeW, nodeParent);
	//GPUDijkstra(edgeSize, nodeSize, source, head1, head2, mutex, edgeIndex, edges, costs, nodeW, nodeParent);


	vector<int*> allWeights;

	//for (int w = 0; w < nodeSize; w++)
	//{
	//	int* amca = new int[nodeSize + 1];
	//	allWeights.push_back(amca);
	//}

	for (int w = 0; w < nodeSize; w++)
	{
		int* amca = new int[nodeNext];//<--------------------------------------------------------------------------------possible breaking point
		allWeights.push_back(amca);
	}



	int* d_edgeIndex, *d_edges, *d_costs;
	cudaMalloc((void**)&d_edgeIndex, sizeByNodes);//<---------------------------asdfasdf
	cudaMalloc((void**)&d_edges, sizeByEdges);
	cudaMalloc((void**)&d_costs, sizeByEdges);

	const int numOfStreams =  1;
	cudaStream_t streams[numOfStreams];

	for (int i = 0; i < numOfStreams; i++)
	{
		cudaStreamCreate(&streams[i]);
	}




	cudaMemcpy(d_edgeIndex, edgeIndex, sizeByNodes, cudaMemcpyHostToDevice);//<-------------------------------------------------------------nodeNext
	cudaMemcpy(d_edges, edges, sizeByEdges, cudaMemcpyHostToDevice);//<=-----------------------------------------------------------------

	//GPUDijkstra(edgeSize, nodeSize, source, head1, head2, mutex, edgeIndex, edges, costs, nodeW, nodeParent);

	//GPUDijkstra(edgeSize, nodeSize, source, head1, head2, mutex, edgeIndex, edges, costs, allWeights[0], nodeParent);

	//oneGPUDijkstra(edgeSize, nodeSize, 0, head1, head2, mutex, edgeIndex, edges, costs, allWeights);


	//cudaProfilerStart();
	cudaEvent_t start, stop;
	float elapsedTime;
	cudaEventCreate(&start);
	cudaEventRecord(start, 0);

	Johnson1(nodeW, edgeIndex, edges, costs, nodeSize, edgeSize);
	cudaMemcpy(d_costs, costs, sizeByEdges, cudaMemcpyHostToDevice);//<--------------------------


	int* d_deltas = 0;
	int* d_numOfThreads = 0;

	cudaMalloc((void**)&d_numOfThreads, sizeof(int));
	cudaMalloc((void**)&d_deltas, sizeByNodes);//<---------------------------------------------------------one of many inserted in this section

	cudaMemcpy(d_numOfThreads, &nodeSize, sizeByEdges, cudaMemcpyHostToDevice);//<--------------------------------------------------

	cudaDeviceSynchronize();
	int threadsPerBlock = BS;
	int nodesPerThread = nodeSize / threadsPerBlock;
	int nodesPerThreadLeftovers = nodeSize%threadsPerBlock;
	int extrasH2 = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasH2 == 0 ? 0 : 1);
//nt numOfBlocks = nodeSize / threadsPerBlock + (nodeSize % threadsPerBlock == 0 ? 0 : 1);

	computeDeltaUKernel << <  numOfBlocks, threadsPerBlock >> >(d_edgeIndex, d_edges, d_costs, d_deltas, d_numOfThreads);


	cudaDeviceSynchronize();
	for (int n = 0; n < nodeSize; n++)
	{
		//cudaDeviceSynchronize();
		//std::cout << n << std::endl;
		//oneGPUDijkstra(edgeSize, nodeSize, n, head1, head2, mutex, d_edgeIndex, d_edges, d_costs, d_deltas, allWeights, &streams[n%numOfStreams]);
		//oneGPUDijkstraQVerify(edgeSize, nodeSize, n, d_edgeIndex, d_edges, d_costs, d_deltas, allWeights, &streams[n%numOfStreams]);
		oneGPUDijkstraPrefixVerify(edgeSize, nodeSize, n, d_edgeIndex, d_edges, d_costs, d_deltas, allWeights, &streams[n%numOfStreams]);


		//std::cout << n << std::endl;
	}

	cout << "GPU done" << endl;


	cudaEventCreate(&stop);
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&elapsedTime, start, stop);
	printf("GPU time: %lf ms\n", elapsedTime);



	
	//StartCounter();


	Graph gprime = addZeroEdge(g);

	SingleSP ssp;
	try {
	ssp = bellmanford(gprime, 0);
	}
	catch (string e) {
	cout << "Negative cycles found in graph.  Cannot compute shortest paths." << endl;
	throw e;
	}



	for (int i = 1; i < g.size(); i++) {
		for (int k = 0; k < g[i].size(); k++) {
       			Edge e = g[i][k];
		       	e.cost = e.cost + ssp[i] - ssp[e.head];
		}
	}


	AllSP allsp(g.size());
	for (int i = 0; i < g.size(); i++) {
		allsp[i] = djikstra(g, i);
	}

	cout << "CPU Time:	" << GetCounter() << endl;


	//cout << "GPU Matrix:" << endl;
	//for (unsigned int i = 0; i < 1; i++){
	//	for (unsigned int j = 0; j < allWeights.size(); j++)
	//		cout << allWeights[i][j] << " ";
	//	cout << endl;
	//}
	/*
	cout << "CPU Matrix:" << endl;
	cout << endl << endl;
	for (unsigned int i = 0; i < allsp.size(); i++){
		for (unsigned int j = 0; j < allsp[i].size(); j++)
			cout << allsp[i][j] << " ";
		cout << endl;
	}*/

	int count = 0;
	bool succes = true;
	for (unsigned int i = 0; i < allWeights.size(); i++){
		for (unsigned int j = 0; j < allWeights.size(); j++){
			//cout << allsp[i][j] << "	" << allWeights[i][j] << endl;
			if (allsp[i][j] != allWeights[i][j]){
				succes = false;
				count++;
				//cout << i << endl;

				//cout << "***************************" << endl;
			}
		}
	}

	if (succes)
		std::cout << "successful" << std::endl;
	else
		std::cout << "fail" << std::endl;
	if (count)
		cout << count<< endl;


	getchar();


	//delete[] edgeIndex;
	//delete[] edges;
	//delete[] costs;
	cudaFreeHost(edgeIndex);
	cudaFreeHost(edges);
	cudaFreeHost(costs);
	//delete[] nodeW;
	//delete[] nodeParent;
	//delete[] streams;

	return 0;
}


//! gpu performance
int main()
{


	srand(time(NULL));
	int edgeSize = 12;
	int nodeSize = 9;
	int source = 0;
	int head1 = 0;
	int head2 = 0;
	int mutex = 0;
	int totSize = edgeSize + nodeSize;//<-----------------------------------------
	int totalBySizeOfInt = totSize * sizeof(int);
	int nodeAddTwo= nodeSize + 2;
	int nodeAddTwoBySize = nodeAddTwo * sizeof(int);
	std::ifstream f;


	string graphName = "graph1.txt";
	//string graphName = "graph2.txt";
	//string graphName = "graph3.txt";
	//string graphName = "graph4.txt";
	//string graphName = "graph5.txt";
	//string graphName = "graph6.txt";
	//string graphName = "graph7.txt";
	//string graphName = "graph8.txt";

	f.open(graphName.c_str());

	std::cout << graphName << std::endl;

	if (!f.is_open())
	{
		std::cout << "File not found!" << std::endl;
		getchar();
		return -1;
	}
	f >> nodeSize;
	f >> edgeSize;

	cout << edgeSize << "		" << nodeSize << endl;


        cout << "ALLOCATING MEMORY...." << endl;
	int* edgeIndex, *edges, *costs;
	cudaMallocHost((void**)&edgeIndex, nodeAddTwoBySize);
	cudaMallocHost((void**)&edges, totalBySizeOfInt);
	cudaMallocHost((void**)&costs, totalBySizeOfInt);//<--------------------------------


	int* nodeW = new int[nodeSize];
	int* nodeParent = new int[nodeSize];
        cout << "DONE." << endl;
	/*******************/
	Graph g;
	g.resize(nodeSize);
        cout << "MADE GRAPH" << endl;
	/******************/
	int nodeNext = nodeSize + 1;//<-------------------------------------------------
	std::vector<std::vector<int> > edgesVector;
	edgesVector.resize(nodeNext);
	std::vector<std::vector<int> > costsVector;
	costsVector.resize(nodeNext);//<---------------------------------------------------------
	for (int i = 0; i < edgeSize; i++){

		int from, to;
		int cost;

		f >> from;
		f >> to;

		//from--;
		//to--;
		f >> cost;
		//cost = rand() % 10 + 1;

		edgesVector[from].push_back(to);
		costsVector[from].push_back(cost);


		/***********/
		Edge e;
		e.head = to;
		e.cost = cost;
		g[from].push_back(e);
		/***********/
	}

	for (int i = 0; i < nodeSize; i++){

		edgesVector[nodeSize].push_back(i);
		costsVector[nodeSize].push_back(0);

	}


	int offset = 0;

	for (int i = 0; i < nodeSize; i++){

		edgeIndex[i] = offset;
		//printf("%d", offset);
		int end = offset + edgesVector[i].size();

		for (int j = offset; j < end; j++){
			int jSubOffset = j - offset;//<--------------------------------------------------------
			edges[j] = edgesVector[i][jSubOffset];
			costs[j] = costsVector[i][jSubOffset];

		}


		offset = end;

	}
	//used to have nodeSize
	edgeIndex[nodeNext] = edgeSize;


	for (int i = edgeSize; i < totSize; i++){//WAS tot size
		int iSubEdgeSize = i - edgeSize;//<-------------------------------------------------------
		edges[i] = edgesVector[nodeSize][iSubEdgeSize];
		costs[i] = costsVector[nodeSize][iSubEdgeSize];


	}
	int sizeByEdges = sizeof(int) * edgeSize;
	int sizeByNodes = sizeof(int) * nodeSize;
	int sizeByNodeAddOne = sizeof(int) * nodeNext; //<----------------------------------------------------------lots of new variables

	edgeIndex[nodeNext] = totSize;
	f.close();

	vector<int*> allWeights;

	for (int w = 0; w < 1; w++)
	{
		int* amca = new int[nodeSize + 1];
		allWeights.push_back(amca);
	}

	int* d_edgeIndex, *d_edges, *d_costs;
	cudaMalloc((void**)&d_edgeIndex, sizeByNodeAddOne);
	cudaMalloc((void**)&d_edges, sizeByEdges);
	cudaMalloc((void**)&d_costs, sizeByEdges);

	const int numOfStreams = 1;
	cudaStream_t streams[numOfStreams];

	for (int i = 0; i < numOfStreams; i++)
	{
		cudaStreamCreate(&streams[i]);
	}

	cudaMemcpy(d_edgeIndex, edgeIndex, sizeByNodeAddOne, cudaMemcpyHostToDevice);//<------------------------------------------------BROKE PROGRAM/okay now though?
	cudaMemcpy(d_edges, edges, sizeByEdges, cudaMemcpyHostToDevice);

	//cudaProfilerStart();
	cudaEvent_t start, stop;
	float elapsedTime;
	cudaEventCreate(&start);
	cudaEventRecord(start, 0);

	Johnson1(nodeW, edgeIndex, edges, costs, nodeSize, edgeSize);
	cudaMemcpy(d_costs, costs, sizeByEdges, cudaMemcpyHostToDevice);


	int* d_deltas = 0;
	int* d_numOfThreads = 0;

	cudaMalloc((void**)&d_numOfThreads, sizeof(int));
	cudaMalloc((void**)&d_deltas, sizeByNodes);

	cudaMemcpy(d_numOfThreads, &nodeSize, sizeByEdges, cudaMemcpyHostToDevice);

	cudaDeviceSynchronize();
	int threadsPerBlock = BS;
	int nodesPerThread = nodeSize / threadsPerBlock;
	int nodesPerThreadLeftovers = nodeSize%threadsPerBlock;
	int extrasZ = nodesPerThread + nodesPerThreadLeftovers;
	int numOfBlocks = (extrasZ == 0 ? 0 : 1);//<--------------------------------------------------------added
//	int numOfBlocks = nodeSize / threadsPerBlock + (nodeSize % threadsPerBlock == 0 ? 0 : 1);

	computeDeltaUKernel << <  numOfBlocks, threadsPerBlock >> >(d_edgeIndex, d_edges, d_costs, d_deltas, d_numOfThreads);


	cudaDeviceSynchronize();
	for (int n = 0; n <nodeSize; n++)
	{
		
		oneGPUDijkstra(edgeSize, nodeSize, n, head1, head2, mutex, d_edgeIndex, d_edges, d_costs, d_deltas, allWeights, &streams[n%numOfStreams]);
		//oneGPUDijkstraQ(edgeSize, nodeSize, n, d_edgeIndex, d_edges, d_costs, d_deltas, allWeights, &streams[n%numOfStreams]);
		//oneGPUDijkstraPrefix(edgeSize, nodeSize, n, d_edgeIndex, d_edges, d_costs, d_deltas, allWeights, &streams[n%numOfStreams]);

	}

	cout << "done" << endl;

	cudaEventCreate(&stop);
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&elapsedTime, start, stop);
	printf("GPU time: %lf ms\n", elapsedTime);



	getchar();
	//delete[] edgeIndex;
	//delete[] edges;
	//delete[] costs;
	cudaFreeHost(edgeIndex);
	cudaFreeHost(edges);
	cudaFreeHost(costs);
	//delete[] nodeW;
	//delete[] nodeParent;
	//delete[] streams;

	return 0;
}

//! cpu performance
int main2()
{


	srand(time(NULL));
	int edgeSize = 12;
	int nodeSize = 9;
	int source = 0;
	int head1 = 0;
	int head2 = 0;
	int mutex = 0;
	int nodePlusTwo = nodeSize + 2;//<----------------------------------------------------new
	int nodeNext = nodeSize + 1;
	int totSize = edgeSize + nodeSize;
	int nodePlusTwoBySizeOf = nodePlusTwo * sizeof(int);
	int totBySize = totSize * sizeof(int);//<00000000000000000

	std::ifstream f;


	//string graphName = "graph1.txt";
	//string graphName = "graph2.txt";
	//string graphName = "graph3.txt";
	//string graphName = "graph4.txt";
	//string graphName = "graph5.txt";
	//string graphName = "graph6.txt";
	//string graphName = "graph7.txt";
	string graphName = "graph8.txt";
	


	//std::string graphName = "50k_1m.txt";

	f.open(graphName.c_str());

	std::cout << graphName << std::endl;

	if (!f.is_open())
	{
		std::cout << "File not found!" << std::endl;
		getchar();
		return -1;
	}
	f >> nodeSize;
	f >> edgeSize;

	cout << edgeSize << "		" << nodeSize << endl;



	int* edgeIndex, *edges, *costs;
	cudaMallocHost((void**)&edgeIndex, nodePlusTwoBySizeOf);
	cudaMallocHost((void**)&edges, totBySize);//<-----------------------------------
	cudaMallocHost((void**)&costs, totBySize);                          


	int* nodeW = new int[nodeSize];//<------------------------------------------
	int* nodeParent = new int[nodeSize];//<----------------

	/*******************/
	Graph g;
	g.resize(nodeSize);

	/******************/
	std::vector<std::vector<int> > edgesVector;
	edgesVector.resize(nodeNext);   //<----------------------------------------------------------     
	std::vector<std::vector<int> > costsVector;
	costsVector.resize(nodeNext);       //<----------------

	
	for (int i = 0; i < edgeSize; i++){

		int from, to;
		int cost;

		f >> from;
		f >> to;

		//from--;
		//to--;
		//f >> cost;
		cost = rand() % 10 + 1;

		edgesVector[from].push_back(to);
		costsVector[from].push_back(cost);


		/***********/
		Edge e;
		e.head = to;
		e.cost = cost;
		g[from].push_back(e);
		/***********/
	}




	for (int i = 0; i < nodeSize; i++){

		edgesVector[nodeSize].push_back(i);//<---------------------------------------------------------
		costsVector[nodeSize].push_back(0);

	}


	int offset = 0;

	for (int i = 0; i < nodeSize; i++){

		edgeIndex[i] = offset;
		//printf("%d", offset);
		int end = offset + edgesVector[i].size();

		for (int j = offset; j < end; j++){
			int jSubOffset = j - offset;//<------------------
			edges[j] = edgesVector[i][jSubOffset];
			costs[j] = costsVector[i][jSubOffset];

		}


		offset = end;

	}

	edgeIndex[nodeSize] = edgeSize;//<----------------


	for (int i = edgeSize; i < edgeSize + nodeSize; i++){
		int iSubEdgeSize = i - edgeSize;//<-----------------0
		edges[i] = edgesVector[nodeSize][iSubEdgeSize];
		costs[i] = costsVector[nodeSize][iSubEdgeSize];


	}




	edgeIndex[nodeNext] = totSize;                     
	f.close();



	//StartCounter();
	Graph gprime = addZeroEdge(g);

	SingleSP ssp;
	try {
	ssp = bellmanford(gprime, 0);
	}
	catch (string e) {
	cout << "Negative cycles found in graph.  Cannot compute shortest paths." << endl;
	throw e;
	}



	for (int i = 1; i < g.size(); i++) {
	        for (int k = 0; k < g[i].size(); k++) {
        		Edge e = g[i][k];
			e.cost = e.cost + ssp[i] - ssp[e.head];
		}
	}


	AllSP allsp(1);
	for (int i = 0; i < g.size(); i++) {
		allsp[0] = djikstra(g, i);
	}

	cout << "CPU Time:	" << GetCounter() << endl;
	getchar();


	//delete[] edgeIndex;
	//delete[] edges;
	//delete[] costs;
	cudaFreeHost(edgeIndex);
	cudaFreeHost(edges);
	cudaFreeHost(costs);
	//delete[] nodeW;
	//delete[] nodeParent;
	//delete[] streams;

	return 0;
}


__global__ void prescan(float *g_odata, float *g_idata, int *n)
{
	int thid = threadIdx.x;
	int thidDub = thid + thid;
	int oddThid = thidDub + 1;
	int offset = 1;


	extern __shared__ float temp[];  // allocated on invocation
	temp[thidDub] = g_idata[thidDub]; // load input into shared memory  
	temp[oddThid] = g_idata[oddThid] ;

	for (int d = *n >> 1; d > 0; d >>= 1)                    // build sum in place up the tree  
	{

		__syncthreads();
		if (thid < d)
		{
			int ai = offset*(oddThid) - 1;
			int bi = offset*(oddThid + 1) - 1;

			temp[bi] += temp[ai];
		}
		offset *= 2;
	}
	if (thid == 0) { temp[*n - 1] = 0; } // clear the last element  

	for (int d1 = 1; d1 < *n; d1 *= 2) // traverse down tree & build scan  
	{

		offset >>= 1;
		__syncthreads();
		if (thid < d1)
		{

			int ai = offset*(oddThid) - 1;
			int bi = offset*(oddThid + 1) - 1;

			float t = temp[ai];

			temp[ai] = temp[bi];

			temp[bi] += t;

		}
	}
	__syncthreads();


	g_odata[thidDub] = temp[thidDub]; // write results to device memory  
	g_odata[oddThid] = temp[oddThid];
}


int makeItPowerOf2(int size){

	int powerOfTwo = 1;

	while (size > powerOfTwo){
		powerOfTwo *= 2;
	}

	return powerOfTwo;

}


//! prefix sum test
int main4(int argc, char *argv[])
{
	// Initialization.  The shuffle intrinsic is not available on SM < 3.0
	// so waive the test if the hardware is not present.
	//  int cuda_device = 0;

	printf("Starting shfl_scan\n");

	//// use command-line specified CUDA device, otherwise use device with highest Gflops/s
	//cuda_device = findCudaDevice(argc, (const char **)argv);

	//cudaDeviceProp deviceProp;
	//checkCudaErrors(cudaGetDevice(&cuda_device));

	//checkCudaErrors(cudaGetDeviceProperties(&deviceProp, cuda_device));

	//printf("> Detected Compute SM %d.%d hardware with %d multi-processors\n",
	//       deviceProp.major, deviceProp.minor, deviceProp.multiProcessorCount);

	//// __shfl intrinsic needs SM 3.0 or higher
	//if (deviceProp.major < 3)
	//{
	//    printf("> __shfl() intrinsic requires device SM 3.0+\n");
	//    printf("> Waiving test.\n");
	//    exit(EXIT_WAIVED);
	//}


	bool bTestResult = true;
	bool simpleTest = shuffle_simple_test(argc, argv);
	// bool intTest = shuffle_integral_image_test();

	//  bTestResult = simpleTest & intTest;

	// cudaDeviceReset causes the driver to clean up all state. While
	// not mandatory in normal operation, it is good practice.  It is also
	// needed to ensure correct operation when the application is being
	// profiled. Calling cudaDeviceReset causes all profile data to be
	// flushed before the application exits
	getchar();
	cudaDeviceReset();
	exit((bTestResult) ? EXIT_SUCCESS : EXIT_FAILURE);
}
