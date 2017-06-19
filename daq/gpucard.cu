/***********************************
***********************************
CUDA PART
***********************************
**********************************/

#include "gpucard.h"
#include "terminal.h"

#include <memory.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cufft.h>
#include <cuda_profiler_api.h>
#include <stdio.h>
#include <math.h>

#include <iostream>
#include <time.h>
#define FLOATIZE_X 4

static void HandleError( cudaError_t err,
                         const char *file,
                         int line ) {
    if (err != cudaSuccess) {
      printf( "CUDA fail: %s in %s at line %d\n", cudaGetErrorString( err ),
                file, line );
        exit(1);
    }
}
#define CHK( err ) (HandleError( err, __FILE__, __LINE__ ))

void gpuCardInit (GPUCARD *gc, SETTINGS *set) {
  
  //print out gpu properties
  cudaDeviceProp  devProp;
  CHK(cudaGetDeviceProperties(&devProp, 0));
  printf("\nGPU properties \n====================\n");
  printf("Version number:                %d.%d\n",  devProp.major, devProp.minor);
  printf("Name:                          %s\n",  devProp.name);
  printf("Total global memory:           %u\n",  devProp.totalGlobalMem);
  printf("Total shared memory per block: %u\n",  devProp.sharedMemPerBlock);
  printf("Total registers per block:     %d\n",  devProp.regsPerBlock);
  printf("Warp size:                     %d\n",  devProp.warpSize);
  printf("Maximum memory pitch:          %u\n",  devProp.memPitch);
  printf("Maximum threads per block:     %d\n",  devProp.maxThreadsPerBlock);
  for (int i = 0; i < 3; ++i)
  printf("Maximum dimension %d of block:  %d\n", i, devProp.maxThreadsDim[i]);
  for (int i = 0; i < 3; ++i)
  printf("Maximum dimension %d of grid:   %d\n", i, devProp.maxGridSize[i]);
  printf("Clock rate:                    %d\n",  devProp.clockRate);
  printf("Total constant memory:         %u\n",  devProp.totalConstMem);
  printf("Texture alignment:             %u\n",  devProp.textureAlignment);
  printf("Concurrent copy and execution: %s\n",  (devProp.deviceOverlap ? "Yes" : "No"));
  printf("Number of multiprocessors:     %d\n",  devProp.multiProcessorCount);
  printf("Kernel execution timeout:      %s\n\n",  (devProp.kernelExecTimeoutEnabled ? "Yes" : "No"));



  printf ("\n\nInitializing GPU\n");
  printf ("====================\n");
  printf ("Allocating GPU buffers\n");
  int Nb=set->cuda_streams;
  gc->cbuf=(void**)malloc(Nb*sizeof(void*));
  gc->cfbuf=(void**)malloc(Nb*sizeof(void*));
  gc->cfft=(void**)malloc(Nb*sizeof(void*));
  gc->coutps=(void**)malloc(Nb*sizeof(void*));
  int nchan=gc->nchan=1+(set->channel_mask==3);
  if ((nchan==2) and (FLOATIZE_X%2==1)) {
    printf ("Need FLOATIZE_X even for two channels\n");
    exit(1);
  }
  gc->fftsize=set->fft_size;
  uint32_t bufsize=gc->bufsize=set->fft_size*nchan;
  uint32_t transform_size=(set->fft_size/2+1)*nchan;
  float nunyq=set->sample_rate/2;
  float dnu=nunyq/(set->fft_size/2+1);
  gc->tot_pssize=0;
  gc->ncuts=set->n_cuts;
  for (int i=0; i<gc->ncuts; i++) {
    printf ("Cutout %i:\n",i);
    gc->fftavg[i]=set->fft_avg[i];
    // first sort  reflections etc.
    //
    float numin, numax;
    numin=set->nu_min[i];
    numax=set->nu_max[i];
    while (fabs(numin)>nunyq) numin-=set->sample_rate;
    while (fabs(numax)>nunyq) numax-=set->sample_rate;
    numin=abs(numin);
    numax=abs(numax);
    if (numax<numin) { float t=numin; numin=numax; numax=t; }
    printf ("   Frequencies %f - %f Mhz appear as %f - %f \n",set->nu_min[i]/1e6, set->nu_max[i]/1e6,
	    numin/1e6, numax/1e6);
    int imin=int(numin/dnu);
    if (imin==0) imin=1;
    int imax=int(numax/dnu)+1;
    gc->pssize1[i]=(imax-imin)/set->fft_avg[i];
    gc->ndxofs[i]=imin;
    if ((imax-imin)%set->fft_avg[i]>0) gc->pssize1[i]+=1;
    imax=imin+gc->pssize1[i]*set->fft_avg[i];
    numin=imin*dnu;
    numax=imax*dnu;
    set->nu_min[i]=numin;
    set->nu_max[i]=numax;
    set->pssize[i]=gc->pssize1[i];
    if (nchan==2)
      gc->pssize[i]=gc->pssize1[i]*4; // for other and two crosses
    else
      gc->pssize[i]=gc->pssize1[i]; // just one power spectrum
    gc->tot_pssize+=gc->pssize[i];
    printf ("   Actual freq range: %f - %f MHz (edges!)\n",numin/1e6, numax/1e6);
    printf ("   # PS offset, #PS bins: %i %i\n",gc->ndxofs[i],gc->pssize1[i]);
  }
  
  for (int i=0;i<Nb;i++) {
    int ** x = new int * [800]; 
    uint8_t** cbuf=(uint8_t**)&(gc->cbuf[i]);
    CHK(cudaMalloc(cbuf,bufsize));
    cufftReal** cfbuf=(cufftReal**)&(gc->cfbuf[i]);
    CHK(cudaMalloc(cfbuf, bufsize*sizeof(cufftReal)));
    cufftComplex** ffts=(cufftComplex**)&(gc->cfft[i]);
    CHK(cudaMalloc(ffts,transform_size*sizeof(cufftComplex)));
    float** coutps=(float**)&(gc->coutps[i]);
    CHK(cudaMalloc(coutps,gc->tot_pssize*sizeof(float)));
  }
  CHK(cudaHostAlloc(&gc->outps, gc->tot_pssize*sizeof(float), cudaHostAllocDefault));

  printf ("Setting up CUFFT\n");
  int status=cufftPlanMany(&gc->plan, 1, (int*)&(set->fft_size), NULL, 0, 0, 
        NULL, transform_size,1, CUFFT_R2C, nchan);

  if (status!=CUFFT_SUCCESS) {
       printf ("Plan failed:");
       if (status==CUFFT_ALLOC_FAILED) printf("CUFFT_ALLOC_FAILED");
       if (status==CUFFT_INVALID_VALUE) printf ("CUFFT_INVALID_VALUE");
       if (status==CUFFT_INTERNAL_ERROR) printf ("CUFFT_INTERNAL_ERROR");
       if (status==CUFFT_SETUP_FAILED) printf ("CUFFT_SETUP_FAILED");
       if (status==CUFFT_INVALID_SIZE) printf ("CUFFT_INVALID_SIZE");
       printf("\n");
       exit(1);
  }
  printf ("Setting up CUDA streams & events\n");
  gc->nstreams = set->cuda_streams;
  gc->threads=set->cuda_threads;
  if (gc->nstreams<1) {
    printf ("Cannot really work with less than one stream.\n");
    exit(1);
  }
  gc->streams=malloc(gc->nstreams*sizeof(cudaStream_t));
  gc->eStart=malloc(gc->nstreams*sizeof(cudaEvent_t));
  gc->eDoneCopy=malloc(gc->nstreams*sizeof(cudaEvent_t));
  gc->eDoneFloatize=malloc(gc->nstreams*sizeof(cudaEvent_t));
  gc->eDoneFFT=malloc(gc->nstreams*sizeof(cudaEvent_t));
  gc->eDonePost=malloc(gc->nstreams*sizeof(cudaEvent_t));
  gc->eDoneCopyBack=malloc(gc->nstreams*sizeof(cudaEvent_t));
  cudaEvent_t* eStart=(cudaEvent_t*)(gc->eStart);
  cudaEvent_t* eDoneCopy=(cudaEvent_t*)(gc->eDoneCopy);
  cudaEvent_t* eDoneFloatize=(cudaEvent_t*)(gc->eDoneFloatize);
  cudaEvent_t* eDoneFFT=(cudaEvent_t*)(gc->eDoneFFT);
  cudaEvent_t* eDonePost=(cudaEvent_t*)(gc->eDonePost);
  cudaEvent_t* eDoneCopyBack=(cudaEvent_t*)(gc->eDoneCopyBack);
  cudaStream_t* streams =(cudaStream_t*)(gc->streams);
  for (int i=0;i<gc->nstreams;i++) {
    //create stream
    CHK(cudaStreamCreate(&streams[i]));
    //create events for stream
    CHK(cudaEventCreate(&eStart[i]));
    CHK(cudaEventCreate(&eDoneCopy[i]));
    CHK(cudaEventCreate(&eDoneFloatize[i]));
    CHK(cudaEventCreate(&eDoneFFT[i]));
    CHK(cudaEventCreate(&eDonePost[i]));
    CHK(cudaEventCreate(&eDoneCopyBack[i]));
  }
 
  gc->fstream = 0;
  gc->bstream = -1;
  gc->active_streams = 0;
  //gc->isDone = malloc(gc->nstreams*sizeof(bool)); 
  printf ("GPU ready.\n");


}

/**
 * CUDA Kernel byte->float, 1 channel version
 *
 */
__global__ void floatize_1chan(int8_t* sample, cufftReal* fsample)  {
    int i = FLOATIZE_X*(blockDim.x * blockIdx.x + threadIdx.x);
    for (int j=0; j<FLOATIZE_X; j++) fsample[i+j]=float(sample[i+j]);
}

__global__ void floatize_2chan(int8_t* sample, cufftReal* fsample1, cufftReal* fsample2)  {
      int i = FLOATIZE_X*(blockDim.x * blockIdx.x + threadIdx.x);
      for (int j=0; j<FLOATIZE_X/2; j++) {
      fsample1[i/2+j]=float(sample[i+2*j]);
      fsample2[i/2+j]=float(sample[i+2*j+1]);
    }
}


//offset is fft size, so stack output from each channel in one array
__global__ void floatize_nchan(int8_t* sample, cufftReal* fsamples, int nchan, int offset) {
     int i = FLOATIZE_X*(blockDim.x * blockIdx.x + threadIdx.x);
     for(int j=0; j < FLOATIZE_X/nchan; j++)
      for(int k=0; k<nchan; k++)
       fsamples[k*offset+i/nchan+j] = float(sample[i+nchan*j+k]);
}



//Parallel reduction algorithm to calculate the mean of an array of numbers. The number of elements must be a power of 2. 
//Inputs: an array of floats that will be averaged. The means are conducted individually per block, with a max of 
//1024 threads/elements per block. 
//Outputs: an array of floats the size of the number of blocks. The mean for each block is placed here.
__global__ void mean_reduction (float * in, float * out){
        extern __shared__ float sdata[];
        int tid = threadIdx.x;
        int i = blockIdx.x * blockDim.x + threadIdx.x;
        sdata[tid] = in[i];
        __syncthreads();

        for(int s=blockDim.x/2; s>0; s>>=1){
                if(tid<s) sdata[tid] +=sdata[tid+s];
                __syncthreads();
        }   
	
	if(tid == 0) out[blockIdx.x] = sdata[0]/blockDim.x;
}
__global__ void mean_reduction2 (float * in, float * out){
        extern __shared__ float sdata[];
        int tid = threadIdx.x;
        int i = blockIdx.x * blockDim.x*2 + threadIdx.x;
        sdata[tid] = in[i] + in[i+blockDim.x];
        __syncthreads();

        for(int s=blockDim.x/2; s>0; s>>=1){
                if(tid<s) sdata[tid] +=sdata[tid+s];
                __syncthreads();
        }   
	
	if(tid == 0) out[blockIdx.x] = sdata[0]/blockDim.x;
}

//Parallel reduction algorithm to average the squares of numbers.
__global__ void rms_reduction (float * in, float * out){
        extern __shared__ float sdata[];
        int tid = threadIdx.x;
        int i = blockIdx.x * blockDim.x + threadIdx.x;
        sdata[tid] = in[i]*in[i];
        __syncthreads();
        for(int s =blockDim.x/2; s>0; s>>=1){
                if(tid<s) sdata[tid] +=sdata[tid+s];
                __syncthreads();
        }   

        if(tid == 0) out[blockIdx.x] = sdata[0]/blockDim.x;
}

//Parallel reduction algorithm, to calculate the absolute max of an array of numbers
__global__ void abs_max_reduction (float * in, float * out){
        extern __shared__ float sdata[];
        int tid = threadIdx.x;
        int i = blockIdx.x * blockDim.x + threadIdx.x;
        sdata[tid] = in[i];
        __syncthreads();

        for(int s=blockDim.x/2; s>0; s>>=1){
                if(tid<s) sdata[tid] = (abs(sdata[tid])> abs(sdata[tid+s]))? sdata[tid]:sdata[tid+s];
                __syncthreads();
        }
        if(tid == 0) abs(out[blockIdx.x]);
}
	


/**
 * CUDA reduction sum
 * we will take bsize complex numbers starting at ffts[istart+bsize*blocknumber]
 * and their copies in NCHUNS, and add the squares
 **/


__global__ void ps_reduce(cufftComplex *ffts, float* output_ps, size_t istart, size_t avgsize) {
  int tid=threadIdx.x; // thread
  int bl=blockIdx.x; // block, ps bin #
  int nth=blockDim.x; //nthreads
  __shared__ float work[1024];
  //global pos
  size_t pos=istart+bl*avgsize;
  size_t pose=pos+avgsize;
  pos+=tid;
  work[tid]=0;
  while (pos<pose) {
    work[tid]+=ffts[pos].x*ffts[pos].x+ffts[pos].y*ffts[pos].y;
    pos+=nth;
  }
  // now do the tree reduce.
  int csum=nth/2;
  while (csum>0) {
    __syncthreads();
    if (tid<csum) {
      work[tid]+=work[tid+csum];
    }
    csum/=2;
  }
  if (tid==0) output_ps[bl]=work[0];
}

/** 
 * CROSS power spectrum reducer
 **/
__global__ void ps_X_reduce(cufftComplex *fftsA, cufftComplex *fftsB, 
			    float* output_ps_real, float* output_ps_imag, size_t istart, size_t avgsize) {
  int tid=threadIdx.x; // thread
  int bl=blockIdx.x; // block, ps bin #
  int nth=blockDim.x; //nthreads
  __shared__ float workR[1024];
  __shared__ float workI[1024];
  //global pos
  size_t pos=istart+bl*avgsize;
  size_t pose=pos+avgsize;
  pos+=tid;
  workR[tid]=0;
  workI[tid]=0;
  while (pos<pose) {
    workR[tid]+=fftsA[pos].x*fftsB[pos].x+fftsA[pos].y*fftsB[pos].y;
    workI[tid]+=fftsA[pos].x*fftsB[pos].y-fftsA[pos].y*fftsB[pos].x;
    pos+=nth;
  }
  // now do the tree reduce.
  int csum=nth/2;
  while (csum>0) {
    __syncthreads();
    if (tid<csum) {
      workR[tid]+=workR[tid+csum];
      workI[tid]+=workI[tid+csum];
    }
    csum/=2;
  }
  if (tid==0) {
    output_ps_real[bl]=workR[0];
    output_ps_imag[bl]=workI[0];
  }
} 


void printDt (cudaEvent_t cstart, cudaEvent_t cstop) {
  float gpu_time;
  CHK(cudaEventElapsedTime(&gpu_time, cstart, cstop));
  printf (" %3.2fms ", gpu_time);
}

void printTiming(GPUCARD *gc, int i) {
  printf ("GPU timing (copy/floatize/fft/post/copyback): ");
  cudaEvent_t* eStart=(cudaEvent_t*)(gc->eStart);
  cudaEvent_t* eDoneCopy=(cudaEvent_t*)(gc->eDoneCopy);
  cudaEvent_t* eDoneFloatize=(cudaEvent_t*)(gc->eDoneFloatize);
  cudaEvent_t* eDoneFFT=(cudaEvent_t*)(gc->eDoneFFT);
  cudaEvent_t* eDonePost=(cudaEvent_t*)(gc->eDonePost);
  cudaEvent_t* eDoneCopyBack=(cudaEvent_t*)(gc->eDoneCopyBack);
  printDt (eStart[i], eDoneCopy[i]);
  printDt (eDoneCopy[i], eDoneFloatize[i]);
  printDt (eDoneFloatize[i], eDoneFFT[i]);
  printDt (eDoneFFT[i], eDonePost[i]);
  printDt (eDonePost[i], eDoneCopyBack[i]);
  tprintfn ("  ");
}



bool gpuProcessBuffer(GPUCARD *gc, int8_t *buf, WRITER *wr, SETTINGS *set) {
  struct timespec tstart, tnow;
  clock_gettime(CLOCK_REALTIME, &tstart);


  // pointers and vars
  int8_t** cbuf=(int8_t**)(gc->cbuf);
  cufftReal** cfbuf=(cufftReal**)(gc->cfbuf);
  cufftComplex** cfft=(cufftComplex**)(gc->cfft);
  float** coutps=(float**)(gc->coutps);

  cudaEvent_t* eStart=(cudaEvent_t*)(gc->eStart);
  cudaEvent_t* eDoneCopy=(cudaEvent_t*)(gc->eDoneCopy);
  cudaEvent_t* eDoneFloatize=(cudaEvent_t*)(gc->eDoneFloatize);
  cudaEvent_t* eDoneFFT=(cudaEvent_t*)(gc->eDoneFFT);
  cudaEvent_t* eDonePost=(cudaEvent_t*)(gc->eDonePost);
  cudaEvent_t* eDoneCopyBack=(cudaEvent_t*)(gc->eDoneCopyBack);
  cudaStream_t* streams=(cudaStream_t*)gc->streams;

  if (gc->nstreams==1) {
    /// non-streamed version
    cudaEventRecord(eStart[0], 0);
    CHK(cudaMemcpy(cbuf[0], buf, gc->bufsize , cudaMemcpyHostToDevice));
    cudaEventRecord(eDoneCopy[0], 0);
    int threadsPerBlock = gc->threads;
    int blocksPerGrid = gc->bufsize / threadsPerBlock/FLOATIZE_X;
    if (gc->nchan==1) 
      floatize_1chan<<<blocksPerGrid, threadsPerBlock >>>(cbuf[0],cfbuf[0]);
    else 
      floatize_2chan<<<blocksPerGrid, threadsPerBlock >>>(cbuf[0],cfbuf[0],&(cfbuf[0][gc->fftsize]));
    CHK(cudaGetLastError());

    cudaEventRecord(eDoneFloatize[0], 0);
    int status=cufftExecR2C(gc->plan, cfbuf[0], cfft[0]);
    cudaEventRecord(eDoneFFT[0], 0);
    if (status!=CUFFT_SUCCESS) {
      printf("CUFFT FAILED\n");
      exit(1);
    }    

    if (gc->nchan==1) {
      int psofs=0;
      for (int i=0; i<gc->ncuts; i++) {
	ps_reduce<<<gc->pssize[i], 1024>>> (&cfft[0][0], &(coutps[0][psofs]), gc->ndxofs[i], gc->fftavg[i]);
	psofs+=gc->pssize[i];
      }
    } else {
      // note we need to take into account the tricky N/2+1 FFT size while we do N/2 binning
      // pssize+2 = transformsize+1
      // note that pssize is the full *nchan pssize
      int psofs=0;
      for (int i=0; i<gc->ncuts; i++) {
	ps_reduce<<<gc->pssize1[i], 1024>>> (&cfft[0][0], &(coutps[0][psofs]), gc->ndxofs[i], gc->fftavg[i]);
	psofs+=gc->pssize1[i];
	ps_reduce<<<gc->pssize1[i], 1024>>> (&cfft[0][(gc->fftsize/2+1)], 
                                         &(coutps[0][psofs]), gc->ndxofs[i], gc->fftavg[i]);
	psofs+=gc->pssize1[i];
	ps_X_reduce<<<gc->pssize1[i], 1024>>> (&cfft[0][0], &cfft[0][(gc->fftsize/2+1)], 
					  &(coutps[0][psofs]), &(coutps[0][psofs+gc->pssize1[i]]),
					  gc->ndxofs[i], gc->fftavg[i]);
	psofs+=2*gc->pssize1[i];
      }
    }
    CHK(cudaGetLastError());
    cudaEventRecord(eDonePost[0], 0);
    CHK(cudaMemcpy(gc->outps,coutps[0], gc->tot_pssize*sizeof(float), cudaMemcpyDeviceToHost));
    cudaEventRecord(eDoneCopyBack[0], 0);
    cudaThreadSynchronize();
    printTiming(gc,0);
    if (set->print_meanvar) {
      // now find some statistic over subsamples of samples
      uint32_t bs=gc->bufsize;
      uint32_t step=gc->bufsize/(32768);
      float fac=bs/step;
      float m1=0.,m2=0.,v1=0.,v2=0.;
      for (int i=0; i<bs; i+=step) {
	float n=buf[i];
	m1+=n; v1+=n*n;
	n=buf[i+1];
	m2+=n; v2+=n*n;
      }
      m1/=fac; v1=sqrt(v1/fac-m1*m1);
      m2/=fac; v2=sqrt(v2/fac-m1*m1);
      tprintfn ("CH1 min/rms: %f %f   CH2 min/rms: %f %f   ",m1,v1,m2,v2);
    }
    if (set->print_maxp) {
      // find max power in each cutout in each channel.
      int of1=0; // CH1 auto
      for (int i=0; i<gc->ncuts; i++) {
	float ch1p=0, ch2p=0;
	int ch1i=0, ch2i=0;
	int of2=of1+gc->pssize1[i]; //CH2 auto
	for (int j=0; j<gc->pssize1[i];j++) {
	  if (gc->outps[of1+j] > ch1p) {ch1p=gc->outps[of1+j]; ch1i=j;}
	  if (gc->outps[of2+j] > ch2p) {ch2p=gc->outps[of2+j]; ch2i=j;}
	}
	of1+=gc->pssize[i];  // next cutout 
	float numin=set->nu_min[i];
	float nustep=(set->nu_max[i]-set->nu_min[i])/(gc->pssize1[i]);
	float ch1f=(numin+nustep*(0.5+ch1i))/1e6;
	float ch2f=(numin+nustep*(0.5+ch2i))/1e6;
	tprintfn ("Peak pow (cutout %i): CH1 %f at %f MHz;   CH2 %f at %f MHz  ",i,log(ch1p),ch1f,log(ch2p),ch2f);
      }
    }
    writerWritePS(wr,gc->outps);
  } 
 else {
   //streamed version
   //Check if other streams are finished and proccess the finished ones in order (i.e. print output to file)
   while(gc->active_streams > 0){
	if(cudaEventQuery(eDonePost[gc->fstream])==cudaSuccess){
                //print time and write to file
                CHK(cudaMemcpyAsync(gc->outps,coutps[gc->fstream], gc->tot_pssize*sizeof(float), cudaMemcpyDeviceToHost, streams[gc->fstream]));
                cudaEventRecord(eDoneCopyBack[gc->fstream], streams[gc->fstream]);
                //cudaThreadSynchronize();
		cudaEventSynchronize(eDoneCopyBack[gc->fstream]);
		printTiming(gc,gc->fstream);
                if (set->print_meanvar) {
                  // now find some statistic over subsamples of samples
                  uint32_t bs=gc->bufsize;
                  uint32_t step=gc->bufsize/(32768);
                  float fac=bs/step;
                  float m1=0.,m2=0.,v1=0.,v2=0.;
                  for (int i=0; i<bs; i+=step) {
            	float n=buf[i];
            	m1+=n; v1+=n*n;
            	n=buf[i+1];
            	m2+=n; v2+=n*n;
                  }
                  m1/=fac; v1=sqrt(v1/fac-m1*m1);
                  m2/=fac; v2=sqrt(v2/fac-m1*m1);
                  tprintfn ("CH1 min/rms: %f %f   CH2 min/rms: %f %f   ",m1,v1,m2,v2);
                }
                if (set->print_maxp) {
                  // find max power in each cutout in each channel.
                  int of1=0; // CH1 auto
                  for (int i=0; i<gc->ncuts; i++) {
            	float ch1p=0, ch2p=0;
            	int ch1i=0, ch2i=0;
            	int of2=of1+gc->pssize1[i]; //CH2 auto
            	for (int j=0; j<gc->pssize1[i];j++) {
            	  if (gc->outps[of1+j] > ch1p) {ch1p=gc->outps[of1+j]; ch1i=j;}
            	  if (gc->outps[of2+j] > ch2p) {ch2p=gc->outps[of2+j]; ch2i=j;}
            	}
            	of1+=gc->pssize[i];  // next cutout 
            	float numin=set->nu_min[i];
            	float nustep=(set->nu_max[i]-set->nu_min[i])/(gc->pssize1[i]);
            	float ch1f=(numin+nustep*(0.5+ch1i))/1e6;
            	float ch2f=(numin+nustep*(0.5+ch2i))/1e6;
            	tprintfn ("Peak pow (cutout %i): CH1 %f at %f MHz;   CH2 %f at %f MHz  ",i,log(ch1p),ch1f,log(ch2p),ch2f);
                  }
                }
                writerWritePS(wr,gc->outps);
        	gc->fstream = (++gc->fstream)%(gc->nstreams);
                gc->active_streams--;
 	}
        else 
		break;
        
    }
   	
    int csi = gc->bstream = (++gc->bstream)%(gc->nstreams); //add new stream

    if(gc->active_streams == gc->nstreams){ //if no empty streams
	//proccess current streams and then exit
 	//IMPLEMENT
    	printf("No free streams.\n");
        exit(1);
    }

    gc->active_streams++;


    cudaStream_t cs= streams[gc->bstream];
    cudaEventRecord(eStart[csi], cs);
    CHK(cudaMemcpyAsync(cbuf[csi], buf, gc->bufsize , cudaMemcpyHostToDevice,cs));
    CHK(cudaMemcpyAsync(cbuf[csi], buf, gc->bufsize , cudaMemcpyHostToDevice,cs));
    
    cudaEventRecord(eDoneCopy[csi], cs);
    int threadsPerBlock = gc->threads;
    int blocksPerGrid = gc->bufsize / threadsPerBlock/FLOATIZE_X;
    if (gc->nchan==1) 
      floatize_1chan<<<blocksPerGrid, threadsPerBlock, 0, cs>>>(cbuf[csi],cfbuf[csi]);
    else 
      floatize_2chan<<<blocksPerGrid, threadsPerBlock, 0, cs>>>(cbuf[csi],cfbuf[csi],&(cfbuf[csi][gc->fftsize]));
    cudaEventRecord(eDoneFloatize[csi], cs);
    


//    //RFI rejection
//    int n = 5;
//    int N = pow(2,n);
//    if(N > threadsPerBlock){
//	printf("RFI segment larger than number of threads.\n"); //can implement it so that will still work
//	exit(1);
//    }
//    
//    int rfiChunks = gc->bufsize/N;
//
//    float * mean, *rms, *hostMean, *hostrms;
//    CHK(cudaMalloc(&mean, rfiChunks*sizeof(float)));
//    CHK(cudaMalloc(&rms, rfiChunks*sizeof(float)));
//
//    hostMean = (float*)malloc(rfiChunks*sizeof(float));
//    hostrms = (float*)malloc(rfiChunks*sizeof(float));
//
//    mean_reduction2<<<rfiChunks, N, N*sizeof(float), cs>>>(cfbuf[csi], mean );
//    rms_reduction<<<rfiChunks, N, N*sizeof(float), cs>>>(cfbuf[csi], rms);
//    CHK(cudaMemcpyAsync(hostMean, mean, rfiChunks*sizeof(float), cudaMemcpyDeviceToHost, cs));
//    CHK(cudaMemcpyAsync(hostrms, rms, rfiChunks*sizeof(float), cudaMemcpyDeviceToHost, cs));
    
    
    //perform fft
    int status = cufftSetStream(gc->plan, cs);
    if(status !=CUFFT_SUCCESS) {
    	printf("CUFFTSETSTREAM failed\n");
 	exit(1);
    }
    status=cufftExecR2C(gc->plan, cfbuf[csi], cfft[csi]);
    cudaEventRecord(eDoneFFT[csi], cs);
    if (status!=CUFFT_SUCCESS) {
      printf("CUFFT FAILED\n");
      exit(1);
    } 

    if (gc->nchan==1) {
      int psofs=0;
      for (int i=0; i<gc->ncuts; i++) {
	ps_reduce<<<gc->pssize[i], 1024, 0, cs>>> (cfft[csi], &(coutps[csi][psofs]), gc->ndxofs[i], gc->fftavg[i]);
	psofs+=gc->pssize[i];
      }
    } else if(gc->nchan==2){
	  // note we need to take into account the tricky N/2+1 FFT size while we do N/2 binning
	  // pssize+2 = transformsize+1
	  // note that pssize is the full *nchan pssize
	  
	  int psofs=0;
	  for (int i=0; i<gc->ncuts; i++) {
	    ps_reduce<<<gc->pssize1[i], 1024, 0, cs>>> (&cfft[csi][0], &(coutps[csi][psofs]), gc->ndxofs[i], gc->fftavg[i]);
	    psofs+=gc->pssize1[i];
	    ps_reduce<<<gc->pssize1[i], 1024, 0, cs>>> (&cfft[csi][(gc->fftsize/2+1)], 
					     &(coutps[csi][psofs]), gc->ndxofs[i], gc->fftavg[i]);
	    psofs+=gc->pssize1[i];
	    ps_X_reduce<<<gc->pssize1[i], 1024, 0, cs>>> (&cfft[csi][0], &cfft[csi][(gc->fftsize/2+1)], 
					      &(coutps[csi][psofs]), &(coutps[csi][psofs+gc->pssize1[i]]),
					      gc->ndxofs[i], gc->fftavg[i]);
	    psofs+=2*gc->pssize1[i];
	}
  }
  else{
      printf("Can only handle 1 or 2 channels\n");
      exit(1);
  }
 
    CHK(cudaGetLastError());
    cudaEventRecord(eDonePost[csi], cs);
 }
  return true;
}
