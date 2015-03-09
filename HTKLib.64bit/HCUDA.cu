/* ----------------------------------------------------------- */
/*                                                             */
/*                          ___                                */
/*                       |_| | |_/   SPEECH                    */
/*                       | | | | \   RECOGNITION               */
/*                       =========   SOFTWARE                  */
/*                                                             */
/*                                                             */
/* ----------------------------------------------------------- */
/*         Copyright: Microsoft Corporation                    */
/*          1995-2000 Redmond, Washington USA                  */
/*                    http://www.microsoft.com                 */
/*                                                             */
/*   Use of this software is governed by a License Agreement   */
/*    ** See the file License for the Conditions of Use  **    */
/*    **     This banner notice must not be removed      **    */
/*                                                             */
/* ----------------------------------------------------------- */
/*                 File: HCUDA.cu:   CUDA Utilities            */
/* ----------------------------------------------------------- */

#ifdef __cplusplus
extern "C" {
#endif

char *hcuda_version = "!HVER!HCUDA:   3.4.1 [CUED 30/11/13]";
char *hcuda_vc_id = "$Id: HCUDA.cu,v 1.1.1.1 2013/11/13 09:54:58 cz277 Exp $";

#include <cuda.h>
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include "HCUDA.h"
#include "HShell.h"
#include "HMem.h"
#include "HMath.h"
#include "cfgs.h"


/* --------------------------- Trace Flags ------------------------ */

#define CEIL(x,y) (((x)+(y)-1) / (y))

/* --------------------------- Trace Flags ------------------------ */

static int trace = 0;                           /*  */
#define T_TOP 0001                              /* Top Level tracing */

static ConfParam *cParm[MAXGLOBS];              /* config parameters */
static int nParm = 0;

static int GPUDevId = -1;                       /*  */
static Boolean GPUInit = FALSE;                 /*  */
static char *GPUIdEnvVar = "";                  /*  */
cublasHandle_t handle;				/*  */
static size_t GPUMemUsed = 0;			/*  */

/* ----------------------- Device Management ---------------------- */

/*  */
static void ShowAllGPUs(void) {
    int nGPU, i;
    cudaError_t error;
    cudaDeviceProp prop;
    /*CUResult result;*/

    error = cudaGetDeviceCount(&nGPU);    
    if (error != cudaSuccess) {
        HError(9999, "ShowAllGPUs: %s", cudaGetErrorString(error)); 
    }
    if (nGPU == 0) {
        HError(9999, "ShowAllGPUs: No GPU device");
    }
    for (i = 0; i < nGPU; ++i) {
        error = cudaGetDeviceProperties(&prop, i);
        if (error != cudaSuccess) {
            HError(9999, "ShowAllGPUs: %s", cudaGetErrorString(error));
        }
        printf("GPU %d: %s, %dMB, SM = %d.%d", i, prop.name, prop.totalGlobalMem / 1048576, prop.major, prop.minor);
        if (GPUDevId == i)
            printf(" [Selected]");
        printf("\n");
    }
}

/* To check CUDA requirement */
static void CheckCUDAReq(cudaDeviceProp *prop)
{
    int driverVer;
    int runtimeVer;
    int cublasVer;
    cudaError_t error;    
    cublasStatus_t status;
    
    error = cudaDriverGetVersion(&driverVer);
    if (error != cudaSuccess) {
        HError(9999, "CheckCUDAReq: %s", cudaGetErrorString(error));
    }
    if (driverVer < MINCUDAVER) {
        HError(9999, "CheckCUDAReq: CUDA driver version %d is lower than the minimum required version %d", driverVer, MINCUDAVER);
    }

    error = cudaRuntimeGetVersion(&runtimeVer);
    if (error != cudaSuccess) {
        HError(9999, "CheckCUDAReq: %s", cudaGetErrorString(error));
    }
    if (runtimeVer < MINCUDAVER) {
        HError(9999, "CheckCUDAReq: CUDA runtime version %d is lower than the minimum required version %d", runtimeVer, MINCUDAVER);
    }

    status = cublasGetVersion(handle, &cublasVer);
    if (status != CUBLAS_STATUS_SUCCESS) {
        HError(9999, "CheckCUDAReq: Fail to get CUBLAS library version");
    }
    if (cublasVer < MINCUDAVER) {
        HError(9999, "CheckCUDAReq: CUBLAS library version %d is lower than the minimum required version %d", cublasVer, MINCUDAVER);
    }

    if (prop->major <= MINMAJORSMARCH && prop->minor <= MINMINORSMARCH) {
        HError(9999, "CheckCUDAReq: SM architecture is lower than the minimum requirement, %d.%d", MINMAJORSMARCH, MINMINORSMARCH);
    }

    printf("CUDA driver version %d\n", driverVer);
    printf("CUDA runtime version %d\n", runtimeVer);
    printf("CUBLAS library version %d\n", cublasVer);
}

/* Initialize the GPU device. It first loads the GPU device
   from the config file. Then
*/
void InitCUDA(void)
{
    int intVal;
    char buf[256];
    ConfParam *cpVal;

    Register(hcuda_version, hcuda_vc_id);

    /* load parameters from the config file */
    nParm = GetConfig("HCUDA", TRUE, cParm, MAXGLOBS);
    if (nParm > 0) {
        if (GetConfInt(cParm, nParm, "TRACE", &intVal)) {
            trace = intVal;
        }
        if (GetConfAny(cParm, nParm, "GPUID", &cpVal)) {
            if (cpVal->kind == IntCKind) {
                GPUDevId = cpVal->val.i;
            }
            else if (cpVal->kind == StrCKind) {
                strcpy(buf, cpVal->val.s);
                GPUIdEnvVar = (char *) New(&gcheap, sizeof(char) * strlen(buf));
                strcpy(GPUIdEnvVar, buf);
            }
            else {
                HError(9999, "InitCUDA: Unknown GPUID kind");
            }
        }
    }
}

/*  */
void StartCUDA(void) {
    char *envVar;
    cudaError_t error;
    cublasStatus_t status;
    cudaDeviceProp prop;

    /* initialize the library and device */
    if (!GPUInit) {
        /* select a device */
        if (strcmp(GPUIdEnvVar, "") != 0) { /* use env variable */
            envVar = getenv(GPUIdEnvVar);
            if (envVar == NULL) {
                printf("InitCUDA: Fail to get environment variable %s\n", GPUIdEnvVar);
            }
            GPUDevId =  atoi(envVar);
        }
        if (GPUDevId < 0) {
            error = cudaChooseDevice(&GPUDevId, &prop);
            if (error != cudaSuccess) {
                HError(9999, "InitCUDA: %s", cudaGetErrorString(error));
            }
        }
        error = cudaSetDevice(GPUDevId);
        if (error != cudaSuccess) {
            HError(9999, "InitCUDA: %s", cudaGetErrorString(error));
        }
        error = cudaGetDeviceProperties(&prop, GPUDevId);
        if (error != cudaSuccess) {
            HError(9999, "InitCUDA: %s", cudaGetErrorString(error));
        }
        /* initiate CUBLAS */
        status = cublasCreate(&handle);
        if (status != CUBLAS_STATUS_SUCCESS) {
            HError(9999, "InitCUDA: Fail to initialise CUBLAS");
        }
        /* check version */
        CheckCUDAReq(&prop);
        /* set GPUInit flag */
        GPUInit = TRUE;
        /* show devices */
        ShowAllGPUs();
    }
    else {
        printf("InitCUDA: GPU device %d already initialised", GPUDevId);
    }
}

/*  */
void StopCUDA(void) {
    if (GPUInit) {
        /* destroy the context on the GPU */
        cublasDestroy(handle);
        /* shutdown CUBLAS */
        cudaDeviceReset();
        /* reset GPU IDs and the flag */
        GPUDevId = -1;
        GPUInit = FALSE;
    }
    else {
        printf("StopCUDA: GPU device has already stopped");
    }
}

/* --------------------------- Trace Flags ------------------------ */

__global__ void HKern_SetNSegment(NFloat val, NFloat *segPtr, int segLen) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < segLen) {
        segPtr[pos] = val;
    }
}

__global__ void HKern_ScaledSelfAddNSegment(NFloat *rhPtr, int segLen, NFloat scale, NFloat *lhPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < segLen) {
        lhPtr[pos] = scale * lhPtr[pos] + rhPtr[pos];
    }
}

__global__ void HKern_DupNSegment(NFloat *srcPtr, int segLen, NFloat *dstPtr, int times) {
    int srcPos, dstPos;
    
    dstPos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (dstPos < segLen * times) {
        srcPos = dstPos % segLen;
        dstPtr[dstPos] = srcPtr[srcPos];
    }
}

__global__ void HKern_SubNSegment(NFloat *lhPtr, NFloat *rhPtr, int segLen, NFloat *resPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < segLen) {
        resPtr[pos] = lhPtr[pos] - rhPtr[pos];
    }
}

__global__ void HKern_MulNSegment(NFloat *lhPtr, NFloat *rhPtr, int segLen, NFloat *resPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < segLen) {
        resPtr[pos] = lhPtr[pos] * rhPtr[pos];
    }
}

__global__ void HKern_ApplyReLAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        if (srcPtr != dstPtr && srcPtr[pos] > 0) {
            dstPtr[pos] = srcPtr[pos];
        }
        if (srcPtr[pos] < 0) {
            dstPtr[pos] = srcPtr[pos] * RELUNEGSCALE;
            /* cz277 - standard ReLU */
            /*dstPtr[pos] = 0.0;*/
        }
    }
}

__global__ void HKern_ApplyDReLAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        if (srcPtr[pos] > 0.0) {
            dstPtr[pos] = 1.0;
        }
        else {
            dstPtr[pos] = RELUNEGSCALE;
            /* cz277 - standard ReLU */
            /*dstPtr[pos] = 0.0;*/
        }
    }
}

__global__ void HKern_ApplyDLinearAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        dstPtr[pos] = 1.0;
    }
}

__global__ void HKern_ApplySigmoidAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;
    NFloat floatVal;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        floatVal = -1.0 * srcPtr[pos];
        CHKNFLTEXPE(floatVal)
        dstPtr[pos] = 1.0 / (1.0 + exp(floatVal));
    }
}

__global__ void HKern_ApplyDSigmoidAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        dstPtr[pos] = (1 - srcPtr[pos]) * srcPtr[pos];
    }
}

__global__ void HKern_ApplyTanHAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;
    NFloat floatVal;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        floatVal = srcPtr[pos];
        CHKNFLTEXPE(floatVal)
        floatVal = exp(floatVal);
        dstPtr[pos] = (floatVal - 1.0 / floatVal) / (floatVal + 1.0 / floatVal);
    }
}

__global__ void HKern_ApplyDTanHAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        dstPtr[pos] = 1 - pow(srcPtr[pos], 2);
    }
}

__global__ void HKern_DualSumByRow(NFloat *srcPtr, int col, int size, int incr, NFloat *dstPtr) {
    int lhpos, rhpos, lhidx, rhidx, mod;

    lhpos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (lhpos < size) {
        mod = incr * 2;
        lhidx = lhpos % col;
        if (lhidx % mod == 0) {
            rhidx = lhidx + incr;
            rhpos = lhpos + incr;
            if (rhidx >= col) {
                dstPtr[lhpos] = srcPtr[lhpos];
            }
            else {
                dstPtr[lhpos] = srcPtr[lhpos] + srcPtr[rhpos];
            }
        }
    }
}

__global__ void HKern_ApplySoftmaxAct(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    int frame, i, base, off;
    NFloat den, floatVal;

    frame = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (frame < row) {
        den = 0.0;
        base = frame * col;
        for (i = 0, off = base; i < col; ++i, ++off) {
            floatVal = srcPtr[off];
            CHKNFLTEXPE(floatVal)
            floatVal = exp(floatVal);
            dstPtr[off] = floatVal;
            den += floatVal;
        }
        for (i = 0, off = base; i < col; ++i, ++off) {
            dstPtr[off] /= den;
        }
    }
}

__global__ void HKern_ApplyRedSoftmaxAct(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    extern __shared__ NFloat tmpPtr[];
    int thdIdx, rowIdx, thdNum, base, idx, incr, pos;
    NFloat maxVal, sumVal, tmpVal;

    thdIdx = threadIdx.x;	/* num threads per block */
    rowIdx = blockIdx.x;	/* block index, i.e., row num (minibatch size)  */
    thdNum = min(blockDim.x, col);
    if (thdIdx < thdNum && rowIdx < row) {
        base = rowIdx * col;
        /* 1. find the max val for current frame (rowIdx) and store it in tmpPtr[thdIdx] */
        /* a. collect the maxes for the groups */
        idx = thdIdx;
        tmpPtr[thdIdx] = srcPtr[base + idx];
        idx += thdNum;
        while (idx < col) {
            pos = base + idx;
            if (tmpPtr[thdIdx] < srcPtr[pos])
                tmpPtr[thdIdx] = srcPtr[pos];
            idx += thdNum;
        }
        __syncthreads();
        /* b. dual max within current block */
        for (idx = thdNum; idx > 1; idx = incr) {
            incr = idx / 2;
            if (idx % 2 != 0) {
                ++incr;
            }
            if (thdIdx < incr) {
                pos = thdIdx + incr;
                if (pos < idx && tmpPtr[thdIdx] < tmpPtr[pos]) {
                    tmpPtr[thdIdx] = tmpPtr[pos];
                }
            }
            __syncthreads();
        }
        maxVal = tmpPtr[0];
        __syncthreads();
        /* 2. find the sum */
        /* a. collect the sum for the groups */
        idx = thdIdx;
        tmpPtr[thdIdx] = 0.0;
        while (idx < col) {
            pos = base + idx;
            tmpVal = srcPtr[pos] - maxVal;
            CHKNFLTEXPE(tmpVal)
            dstPtr[pos] = exp(tmpVal);
            tmpPtr[thdIdx] += dstPtr[pos];
            idx += thdNum;
        }
        __syncthreads();
        /* b. dual add within current block */
        for (idx = thdNum; idx > 1; idx = incr) {
            incr = idx / 2;
            if (idx % 2 != 0) {
                ++incr;
            }
            if (thdIdx < incr) {
                pos = thdIdx + incr;
                if (pos < idx) {
                    tmpPtr[thdIdx] += tmpPtr[pos];
                }
            }
            __syncthreads();
        }

        sumVal = tmpPtr[0];
        /* 3. normalise */
        idx = thdIdx; 
        while (idx < col) {
            dstPtr[base + idx] /= sumVal;
            idx += thdNum;
        }
    } 
}

__global__ void HKern_ApplySoftReLAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;
    NFloat floatVal;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        floatVal = srcPtr[pos];
        CHKNFLTEXPE(floatVal)
        dstPtr[pos] = log(1.0 + exp(floatVal));
    } 
}

__global__ void HKern_ApplyDSoftReLAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;
    NFloat floatVal;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        floatVal = srcPtr[pos];
        CHKNFLTEXPE(floatVal)
        dstPtr[pos] = 1.0 - 1.0 / exp(floatVal);
    }
}

__global__ void HKern_ApplySoftSignAct(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        dstPtr[pos] = srcPtr[pos] / (1 + abs(srcPtr[pos]));
    }
}

__global__ void HKern_ApplyLogTrans(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int pos;
    NFloat floatVal;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        floatVal = srcPtr[pos];
        if (floatVal <= 0) {
            floatVal = LZERO;
        }
        else {        
            floatVal = log(floatVal);
            if (floatVal < LSMALL) {
                floatVal = LSMALL;
            }
        }
        dstPtr[pos] = floatVal;
    }
}

__global__ void HKern_RedSumNMatrixByColCUDA(NFloat *srcPtr, int row, int col, Boolean accFlag, NFloat *dstPtr) {
    extern __shared__ NFloat tmpPtr[];
    int thdIdx, colIdx, thdNum, base, idx, incr, pos, step;

    thdIdx = threadIdx.x;       /* num threads per block */
    colIdx = blockIdx.x;        /* block index, i.e., row num (minibatch size)  */
    thdNum = min(blockDim.x, row);
    if (thdIdx < thdNum && colIdx < col) {
        /*base = colIdx;*/
        /* collect the sums for the groups (and transpose the matrix) */
        tmpPtr[thdIdx] = 0.0;/*srcPtr[base + idx * col];*/
        base = colIdx;
        idx = thdIdx;
        pos = base + idx * col;
        step = thdNum * col;
        while (idx < row) {
            tmpPtr[thdIdx] += srcPtr[pos];
            pos += step;
            idx += thdNum;
        }
        __syncthreads();
        for (idx = thdNum; idx > 1; idx = incr) {
            incr = idx / 2;
            if (idx % 2 != 0) {
                ++incr;
            }
            if (thdIdx < incr) {
                pos = thdIdx + incr;
                if (pos < idx) {
                    tmpPtr[thdIdx] += tmpPtr[pos];
                }
            }
            __syncthreads();
        }

        /* copy the value to dstPtr */
        if (thdIdx == 0) {
            if (accFlag == FALSE) 
                dstPtr[colIdx] = 0.0; 
            dstPtr[colIdx] += tmpPtr[0];
        }
    }
}

__global__ void HKern_SumNMatrixByCol(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    int i, pos;
    NFloat sum;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < col) {
        sum = 0.0;
        for (i = 0; i < row; ++i) {
            sum += srcPtr[i * col + pos];
        }
        dstPtr[pos] = sum;
    }
}

__global__ void HKern_SumNMatrixByColAcc(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    int i, pos;
    NFloat sum;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < col) {
        sum = 0.0;
        for (i = 0; i < row; ++i) {
            sum += srcPtr[i * col + pos];
        }
        dstPtr[pos] += sum;
    }
}

__global__ void HKern_SquaredNSegment(NFloat *srcPtr, int segLen, NFloat *dstPtr) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < segLen) {
        dstPtr[pos] = pow(srcPtr[pos], 2);
    }
}

__global__ void HKern_CompAdaGradNSegment(NFloat eta, int K, int segLen, NFloat *ssgSeg, NFloat *nlrSeg) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < segLen) {
        nlrSeg[pos] = eta / sqrt(K + ssgSeg[pos]);
    }
}

__global__ void HKern_CalXENTCriterionCUDA(NFloat *refPtr, NFloat *hypPtr, int segLen, NFloat *crtPtr) {
    __shared__ NFloat tmpPtr[THREADPERBLOCK];
    int thdIdx, thdNum, pos, idx, incr;
    NFloat tn, yn;

    thdIdx = threadIdx.x;
    thdNum = blockDim.x;

    if (thdIdx < thdNum) {
        /* a. collect the sums for the groups */
        pos = thdIdx;
        tmpPtr[thdIdx] = 0.0;
        while (pos < segLen) {
            tn = refPtr[pos];
            yn = hypPtr[pos];
            if (tn == 0.0) {
                tmpPtr[thdIdx] += 0.0;
            }
            else if (yn == 0.0) {
                tmpPtr[thdIdx] += tn * LZERO;
            }
            else {
                tmpPtr[thdIdx] += (-1.0) * tn * log(yn / tn); 
            }
            pos += thdNum;
        }
        __syncthreads();
        /* b. dual add within current block */
        for (idx = thdNum; idx > 1; idx = incr) {
            incr = idx / 2;
            if (idx % 2 != 0) {
                ++incr;
            }
            if (thdIdx < incr) {
                pos = thdIdx + incr;
                if (pos < idx) {
                    tmpPtr[thdIdx] += tmpPtr[pos];
                }
            }
            __syncthreads();
        }
        *crtPtr = tmpPtr[0];
    } 
}

__global__ void HKern_CalMMSECriterionCUDA(NFloat *refPtr, NFloat *hypPtr, int segLen, NFloat *crtPtr) {
    __shared__ NFloat tmpPtr[THREADPERBLOCK];
    int thdIdx, thdNum, pos, idx, incr;

    thdIdx = threadIdx.x;
    thdNum = blockDim.x;
    
    if (thdIdx < thdNum) {
        /* a. collect the sums for the groups */
        pos = thdIdx;
        tmpPtr[thdIdx] = 0.0;
        while (pos < segLen) {
            tmpPtr[thdIdx] += pow(refPtr[pos] - hypPtr[pos], 2);
            pos += thdNum;
        }
        __syncthreads();
        /* dual add within current block */
        for (idx = thdNum; idx > 1; idx = incr) {
            incr = idx / 2;
            if (idx % 2 != 0) {
                ++incr;
            }
            if (thdIdx < incr) {
                pos = thdIdx + incr;
                if (pos < idx) {
                    tmpPtr[thdIdx] += tmpPtr[pos];
                }
            }
            __syncthreads();
        }
        *crtPtr = tmpPtr[0];
    }
}

__global__ void HKern_AddSegmentTargetPen(NFloat *srcPtr, NFloat *penPtr, int row, int col, NFloat *dstPtr) {
    int pos, off;
    
    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < row * col) {
        off = pos % col;
        dstPtr[pos] = srcPtr[pos] + penPtr[off];
    }
}

/*__global__ void HKern_SubNSegmentByConst(NFloat *srcSeg, int segLen, float constVal, NFloat *dstSeg) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < segLen) {
        dstSeg[pos] = srcSeg[pos] - constVal;
    }
}*/

/* cz277 - semi */
__global__ void HKern_ShiftNSegmentVals(NFloat *srcSeg, int segLen, float shiftVal, NFloat *dstSeg) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < segLen) {
        dstSeg[pos] = srcSeg[pos] + shiftVal;
    }
}

/* cz277 - 1007 */
__global__ void HKern_CopyPartialNSegment(int minRow, int minCol, NFloat *srcPtr, int srcCol, NFloat *dstPtr, int dstCol) {
    int pos, rowIdx, colIdx;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < minRow * minCol) {
        rowIdx = pos / minCol;
        colIdx = pos % minCol;
        dstPtr[rowIdx * dstCol + colIdx] = srcPtr[rowIdx * srcCol + colIdx];
    }
}

/* cz277 - gradlim */
__global__ void HKern_ClipNSegmentVals(NFloat* srcSeg, int len, NFloat upperLim, NFloat lowerLim, NFloat *dstSeg) {
    int pos;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < len) {
        if (srcSeg[pos] > upperLim)
            dstSeg[pos] = upperLim;
        else if (srcSeg[pos] < lowerLim)
            dstSeg[pos] = lowerLim;
        else if (srcSeg != dstSeg)
            dstSeg[pos] = srcSeg[pos];
    }
}

__global__ void HKern_RedMaxElementIndex(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    extern __shared__ NFloat tmpPtr[];
    int thdIdx, rowIdx, thdNum, base, idx, incr, pos, off = THREADPERBLOCK;

    thdIdx = threadIdx.x;       /* num threads per block */
    rowIdx = blockIdx.x;        /* block index, i.e., row num (minibatch size)  */
    thdNum = min(blockDim.x, col);
    if (thdIdx < thdNum && rowIdx < row) {
        base = rowIdx * col;
        /* find the max val for current frame (rowIdx) and store it in tmpPtr[thdIdx] */
        /* a. collect the maxes for the groups */
        idx = thdIdx;
        tmpPtr[thdIdx] = srcPtr[base + idx];
        tmpPtr[off + thdIdx] = idx;
        idx += thdNum;
        while (idx < col) {
            pos = base + idx;
            if (tmpPtr[thdIdx] < srcPtr[pos]) {
                tmpPtr[thdIdx] = srcPtr[pos];
                tmpPtr[off + thdIdx] = idx;
            }
            idx += thdNum;
        }
        __syncthreads();
        /* b. dual max within current block */
        for (idx = thdNum; idx > 1; idx = incr) {
            incr = idx / 2;
            if (idx % 2 != 0) {
                ++incr;
            }
            if (thdIdx < incr) {
                pos = thdIdx + incr;
                if (pos < idx && tmpPtr[thdIdx] < tmpPtr[pos]) {
                    tmpPtr[thdIdx] = tmpPtr[pos];
                    tmpPtr[off + thdIdx] = tmpPtr[off + pos];
                }
            }
            __syncthreads();
        }
        /*__syncthreads();*/
        if (thdIdx == 0)
            dstPtr[rowIdx] = tmpPtr[off + 0];
            /*dstPtr[rowIdx] = (NFloat) tmpPtr[off + 0];*/
        /*__syncthreads();*/
    }	
}

/* cz277 - max norm */
__global__ void HKern_RedCalExtNMatrixL2Norm(NFloat *matPtr, NFloat *vecPtr, int row, int col, NFloat *alphas) {
    extern __shared__ NFloat tmpPtr[];
    int thdIdx, rowIdx, thdNum, base, idx, incr, pos;

    thdIdx = threadIdx.x;       /* num threads per block */
    rowIdx = blockIdx.x;        /* block index, i.e., row num (minibatch size)  */
    thdNum = min(blockDim.x, col);
    if (thdIdx < thdNum && rowIdx < row) {
        /* 1. accumulate the L2 norm for each row */
        base = rowIdx * col;
        idx = thdIdx;
        tmpPtr[thdIdx] = 0.0;
        while (idx < col) {
            pos = base + idx;
            tmpPtr[thdIdx] += pow(matPtr[pos], 2);
            idx += thdNum;
        }
        __syncthreads();
        /* b. dual add within current block */
        for (idx = thdNum; idx > 1; idx = incr) {
            incr = idx / 2;
            if (idx % 2 != 0) {
                ++incr;                                   
	    }
            if (thdIdx < incr) {
                pos = thdIdx + incr;
                if (pos < idx) {
                    tmpPtr[thdIdx] += tmpPtr[pos];
                }
            }
            __syncthreads();
        }
        
        if (thdIdx == 0)
            alphas[rowIdx] = tmpPtr[0] + pow(vecPtr[rowIdx], 2);
    }
}

/* cz277 - max norm */
__global__ void HKern_RedMaxElementValue(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    extern __shared__ NFloat tmpPtr[];
    int thdIdx, rowIdx, thdNum, base, idx, incr, pos;

    thdIdx = threadIdx.x;       /* num threads per block */
    rowIdx = blockIdx.x;        /* block index, i.e., row num (minibatch size)  */
    thdNum = min(blockDim.x, col);
    if (thdIdx < thdNum && rowIdx < row) {
        base = rowIdx * col;
        /* find the max val for current frame (rowIdx) and store it in tmpPtr[thdIdx] */
        /* a. collect the maxes for the groups */
        idx = thdIdx;
        tmpPtr[thdIdx] = srcPtr[base + idx];
        idx += thdNum;
        while (idx < col) {
            pos = base + idx;
            if (tmpPtr[thdIdx] < srcPtr[pos]) {
                tmpPtr[thdIdx] = srcPtr[pos];
            }
            idx += thdNum;
        }
        __syncthreads();
        /* b. dual max within current block */
        for (idx = thdNum; idx > 1; idx = incr) {
            incr = idx / 2;
            if (idx % 2 != 0) {
                ++incr;
            }
            if (thdIdx < incr) {
                pos = thdIdx + incr;
                if (pos < idx && tmpPtr[thdIdx] < tmpPtr[pos]) {
                    tmpPtr[thdIdx] = tmpPtr[pos];
                }
            }
            __syncthreads();
        }
        /*__syncthreads();*/
        if (thdIdx == 0)
            dstPtr[rowIdx] = tmpPtr[0];
    }
}

/* --------------------------- HFBLat Kerns ------------------------ */

/* cz277 - cuda fblat */
__global__ void HKern_Setotprob4q(int T, NFloat *llhPtr, int ncols, int *qLo, int *qHi, int Q, float probScale, AcousticDev *acList) {
    int pos, tIdx, tRel, qIdx, s, Nq1;
    AcousticDev *curAc;
    NFloat *otprob;
    NFloat *matptr;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < T * Q) {
        tIdx = pos / Q + 1;
        qIdx = pos % Q + 1;
        if (qIdx >= qLo[tIdx] && qIdx <= qHi[tIdx]) {
            curAc = &acList[qIdx];
            Nq1 = curAc->Nq + 1;
            if (tIdx >= curAc->t_start && tIdx <= curAc->t_end) {	/* q is active at t */
                matptr = llhPtr + (tIdx - 1) * ncols;
                tRel = tIdx - curAc->t_start + 1;
                otprob = curAc->otprob + tRel * Nq1;
                for (s = 2; s < curAc->Nq; ++s) {
                    otprob[s] = matptr[curAc->indexes[s] - 1];
                }
            }
        }
    }
}


/* cz277 - cuda fblat */
__device__ NFloat LAddDev(NFloat x, NFloat y) {
    NFloat temp, diff, z;

    if (x < y) {
        temp = x;
        x = y;
        y = temp;
    }
    diff = y - x;
    if (diff < -23.025851) {
        if (x < LSMALL) {
            return LZERO;
        }
        else {
            return x;
        }
    }
    else {
        z = exp(diff);
        return x + log(1.0 + z);
    }
}

/* cz277 - cuda fblat */
__global__ void HKern_SetModelPlus(int Q, AcousticDev *acList) {
    int tIdx, tRel, qIdx, Nq1, i, j;
    AcousticDev *curAc;
    NFloat *bqt, *bqt1, x;

    qIdx = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (qIdx < Q) {
        qIdx += 1;
        curAc = acList + qIdx;
        Nq1 = curAc->Nq + 1;
        for (tIdx = curAc->t_end; tIdx >= curAc->t_start; --tIdx) {
            tRel = tIdx - curAc->t_start + 1;
            /* SetModelPlus subroutine */
            x = LZERO;
            bqt = &curAc->betaPlus[tRel * Nq1];
            bqt1 = &curAc->betaPlus[(tRel + 1) * Nq1];
            if (tIdx == curAc->t_end) 
                bqt[curAc->Nq] = 0;
            else 
                bqt[curAc->Nq] = LZERO;
            for (i = 2; i < curAc->Nq; ++i) {
                x = bqt[curAc->Nq] + curAc->transp[i * Nq1 + curAc->Nq]; 
                if (tIdx + 1 <= curAc->t_end) {	/* in beam next time frame */
                    for (j = 2; j < curAc->Nq; ++j) {
                        x = LAddDev(x, bqt1[j] + curAc->transp[i * Nq1 + j]);
                    }
                }
                x += curAc->otprob[tRel * Nq1 + i];
                bqt[i] = x;
            }
            x = LZERO;
            for (i = 2; i < curAc->Nq; ++i) {
                x = LAddDev(x, bqt[i] + curAc->transp[1 * Nq1 + i]);
            }
            bqt[1] = x;
        }
        /* neet to set the total accumulated acoustics (tRel ~ tIdx = curAc->t_start) */
        if (curAc->SP == TRUE)
            curAc->aclike = curAc->transp[1 * Nq1 + curAc->Nq];
        else
            curAc->aclike = curAc->betaPlus[tRel * Nq1 + 1];
    }
}


/* cz277 - cuda fblat */
__global__ void HKern_ZeroAlphas(int T, int Q, AcousticDev *acList) {
    int i, pos, Nq1, tIdx, tRel, qIdx;
    AcousticDev *curAc;
    NFloat *alpha;

    pos = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (pos < T * Q) {
        tIdx = pos / Q + 1;
        qIdx = pos % Q + 1;
        curAc = &acList[qIdx];
        /* q is active at t */
        if (tIdx >= curAc->t_start && tIdx <= curAc->t_end) { 
            tRel = tIdx - curAc->t_start + 1;
            Nq1 = curAc->Nq + 1;
            alpha = &curAc->alphaPlus[tRel * Nq1];
            if (curAc->SP == FALSE) {
                for (i = 1; i < Nq1; ++i) {
                    alpha[i] = LZERO;    
                }
            }
        }
    }
}


/* cz277 - cuda fblat */
__global__ void HKern_StepAlpha(int Q, AcousticDev *acList) {
    int tIdx, qIdx, Nq1, i, j, tRel;
    AcousticDev *curAc;
    NFloat *aq, *laq, x = 0.0, y, a;
    NFloat *outprob;

    qIdx = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (qIdx < Q) {
        qIdx += 1;
        curAc = acList + qIdx;
        /* for each time */
        for (tIdx = curAc->t_start; tIdx <= curAc->t_end; ++tIdx) {
            tRel = tIdx - curAc->t_start + 1;
            Nq1 = curAc->Nq + 1;
            aq = &curAc->alphaPlus[tRel * Nq1];
            laq = (tIdx - 1 >= curAc->t_start && tIdx - 1 <= curAc->t_end)? &curAc->alphaPlus[(tRel - 1) * Nq1]: NULL;
            /* outprob != NULL ?? */
            outprob = &curAc->otprob[tRel * Nq1];
            if (tIdx == curAc->t_start) 
                aq[1] = curAc->locc - curAc->aclike;
            else 
                aq[1] = LZERO;
            x = LZERO;
            for (j = 2; j < curAc->Nq; ++j) {
                a = curAc->transp[1 * Nq1 + j];
                x = (a > LSMALL)? a + aq[1]: LZERO;
                for (i = 2; i <= curAc->Nq; ++i) {
                    a = curAc->transp[i * Nq1 + j];
                    y = (laq? laq[i]: LZERO);
                    if (a > LSMALL && y > LSMALL) {
                        x = LAddDev(x, y + a);
                        /*x = log(x + y + a);*/
                    }
                }
                aq[j] = x + outprob[j];
            }
            x = LZERO;
            for (i = 2; i < curAc->Nq; ++i) {
                a = curAc->transp[i * Nq1 + curAc->Nq];
                y = aq[i];
                if (a > LSMALL && y > LSMALL) {
                    x = LAddDev(x, y + a);
                    /*x = log(x + y + a);*/
                }
            }
	    aq[curAc->Nq] = x;
            /* work out the exit problem for checking purpose */
        }
    }
}


/* --------------------------- Trace Flags ------------------------ */

/*  */
void SyncDev2Host(void *devPtr, void *hostPtr, size_t size) {
    cudaMemcpy(hostPtr, devPtr, size, cudaMemcpyDeviceToHost);
}

/*  */
void SyncHost2Dev(void *hostPtr, void *devPtr, size_t size) {
    cudaMemcpy(devPtr, hostPtr, size, cudaMemcpyHostToDevice);	
}

/*  */
void DevDispose(void *devPtr, size_t size) {
    cudaFree(devPtr);
    GPUMemUsed -= size;
}

/*  */
void DevNew(void **devAddr, size_t size) {
    cudaMalloc(devAddr, size);
    GPUMemUsed += size;
}

/*  */
void ShowGPUMemUsage(void) {
    printf("%dMB Memory Used on GPU %d\n", GPUMemUsed / 1048576, GPUDevId);
}

/*  */
void SetNSegmentCUDA(NFloat val, NFloat *segPtr, int segLen) {
    int nBlocks;

    nBlocks = CEIL(segLen, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "SetNSegmentCUDA: Block number exceeds the maximum");
    HKern_SetNSegment<<<nBlocks, THREADPERBLOCK>>>(val, segPtr, segLen);
}

/*  */
void ClearNSegmentCUDA(NFloat *segPtr, int segLen) {
    int nBlocks;
    cudaError_t status;

    nBlocks = CEIL(segLen, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ClearNSegmentCUDA: Block number exceeds the maximum");
    /*HKern_SetNSegment<<<nBlocks, THREADPERBLOCK>>>(0, segPtr, segLen);*/
    status = cudaMemset(segPtr, 0, segLen * sizeof(NFloat));
    if (status != cudaSuccess) {
        HError(9999, "ClearNSegmentCUDA: cudaMemset funtion failed");
    }
    /*cudaDeviceSynchronize();*/
}


/*  */
void CopyNSegmentCUDA(NFloat *srcPtr, int segLen, NFloat *dstPtr) {
    cublasStatus_t status;

#ifdef DOUBLEANN
    status = cublasDcopy(handle, segLen, srcPtr, 1, dstPtr, 1);
#else
    status = cublasScopy(handle, segLen, srcPtr, 1, dstPtr, 1);
#endif
    if (status != CUBLAS_STATUS_SUCCESS) {
        HError(9999, "CopyNSegmentCUDA: CUBLAS library copy function failed");
    }
}

/*  */
void AddNSegmentCUDA(NFloat *srcPtr, int segLen, NFloat *dstPtr) {
    cublasStatus_t status;
    const NFloat alpha = 1.0;

#ifdef DOUBLEANN
    status = cublasDaxpy(handle, segLen, &alpha, srcPtr, 1, dstPtr, 1);
#else
    status = cublasSaxpy(handle, segLen, &alpha, srcPtr, 1, dstPtr, 1);
#endif
    if (status != CUBLAS_STATUS_SUCCESS) {
        HError(9999, "AddNSegmentCUDA: CUBLAS library copy function failed");
    }
}

/* cz277 - l2 fix */
void AddScaledNSegmentCUDA(NFloat *srcPtr, int segLen, NFloat scale, NFloat *dstPtr) {
    cublasStatus_t status;
    const NFloat alpha = scale;

#ifdef DOUBLEANN
    status = cublasDaxpy(handle, segLen, &alpha, srcPtr, 1, dstPtr, 1);
#else
    status = cublasSaxpy(handle, segLen, &alpha, srcPtr, 1, dstPtr, 1);
#endif
    if (status != CUBLAS_STATUS_SUCCESS) {
        HError(9999, "AddScaledNSegmentCUDA: CUBLAS library copy function failed");
    }
    
}

/*  */
void ScaleNSegmentCUDA(int segLen, NFloat scale, NFloat *valPtr) {
    cublasStatus_t status;

#ifdef DOUBLEANN
    status = cublasDscal(handle, segLen, &scale, valPtr, 1);
#else
    status = cublasSscal(handle, segLen, &scale, valPtr, 1);
#endif
    if (status != CUBLAS_STATUS_SUCCESS) {
        HError(9999, "ScaleNSegmentCUDA: CUBLAS library copy function failed");
    }
}

/*  */
void ScaledSelfAddNSegmentCUDA(NFloat *rhPtr, int segLen, NFloat scale, NFloat *lhPtr) {
    int nBlocks;
    
    nBlocks = CEIL(segLen, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ScaledSelfAddNSegmentCUDA: Block number exceeds the maximum");
    HKern_ScaledSelfAddNSegment<<<nBlocks, THREADPERBLOCK>>>(rhPtr, segLen, scale, lhPtr);
}

/*  */
void DupNSegmentCUDA(NFloat *srcPtr, int segLen, NFloat *dstPtr, int times) {
    int nBlocks;

    nBlocks = CEIL(segLen * times, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "DupNSegmentCUDA: Block number exceeds the maximum");
    HKern_DupNSegment<<<nBlocks, THREADPERBLOCK>>>(srcPtr, segLen, dstPtr, times);
}

/*  */
void SubNSegmentCUDA(NFloat *lhPtr, NFloat *rhPtr, int segLen, NFloat *resPtr) {
    int nBlocks;
  
    nBlocks = CEIL(segLen, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "SubNSegmentCUDA: Block number exceeds the maximum");
    HKern_SubNSegment<<<nBlocks, THREADPERBLOCK>>>(lhPtr, rhPtr, segLen, resPtr);
}

/*  */
void MulNSegmentCUDA(NFloat *lhPtr, NFloat *rhPtr, int segLen, NFloat *resPtr) {
    int nBlocks;

    nBlocks = CEIL(segLen, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "MulNSegmentCUDA: Block number exceeds the maximum");
    HKern_MulNSegment<<<nBlocks, THREADPERBLOCK>>>(lhPtr, rhPtr, segLen, resPtr);
}

/*  */
void ApplyReLActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;
    
    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplyReLActCUDA: Block number exceeds the maximum");
    HKern_ApplyReLAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}

/*  */
void ApplyDReLActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplyDReLActCUDA: Block number exceeds the maximum");
    HKern_ApplyDReLAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}

/*  */
void ApplyDLinearActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplyDLinearActCUDA: Block number exceeds the maximum");
    HKern_ApplyDLinearAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}

/*  */
void ApplySigmoidActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplySigmoidActCUDA: Block number exceeds the maximum");
    HKern_ApplySigmoidAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}

/*  */
void ApplyDSigmoidActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplyDSigmoidActCUDA: Block number exceeds the maximum");
    HKern_ApplyDSigmoidAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}

/*  */
void ApplyTanHActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplyTanHActCUDA: Block number exceeds the maximum");
    HKern_ApplyTanHAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}

/*  */
void ApplyDTanHActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplyDTanHActCUDA: Block number exceeds the maximum");
    HKern_ApplyDTanHAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}


/*  */
void ApplyRedSoftmaxActCUDA(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    int nBlocks, sBytes;

    nBlocks = row;
    sBytes = sizeof(NFloat) * THREADPERBLOCK;
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplyRedSoftmaxActCUDA: Block number exceeds the maximum");
    HKern_ApplyRedSoftmaxAct<<<nBlocks, THREADPERBLOCK, sBytes>>>(srcPtr, row, col, dstPtr);
}

/*  */
void ApplySoftmaxActCUDA(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(row, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplySoftmaxActCUDA: Block number exceeds the maximum");
    HKern_ApplySoftmaxAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, row, col, dstPtr);
}

/*  */
void ApplySoftReLActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;
 
    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplySoftReLActCUDA: Block number exceeds the maximum");
    HKern_ApplySoftReLAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}

/*  */
void ApplyDSoftReLActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplySoftReLActCUDA: Block number exceeds the maximum");
    HKern_ApplyDSoftReLAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);
}

/*  */
void ApplySoftSignActCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplySoftSignActCUDA: Block number exceeds the maximum");
    HKern_ApplySoftSignAct<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);    
}

/*  */
void ApplyLogTransCUDA(NFloat *srcPtr, int len, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ApplyLogTransCUDA: Block number exceeds the maximum");
    HKern_ApplyLogTrans<<<nBlocks, THREADPERBLOCK>>>(srcPtr, len, dstPtr);    
}

/*  */
void RedSumNMatrixByColCUDA(NFloat *srcPtr, int row, int col, Boolean accFlag, NFloat *dstPtr) {
    int nBlocks, sBytes;

    nBlocks = col;
    sBytes = sizeof(NFloat) * THREADPERBLOCK;
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "RedSumNMatrixByColCUDA: Block number exceeds the maximum");
    HKern_RedSumNMatrixByColCUDA<<<nBlocks, THREADPERBLOCK, sBytes>>>(srcPtr, row, col, accFlag, dstPtr);
}

/*  */
void SumNMatrixByColCUDA(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(col, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "SumNMatrixByColCUDA: Block number exceeds the maximum");
    HKern_SumNMatrixByCol<<<nBlocks, THREADPERBLOCK>>>(srcPtr, row, col, dstPtr);
}

/*  */
void SquaredNSegmentCUDA(NFloat *srcPtr, int segLen, NFloat *dstPtr) {
    int nBlocks;

    nBlocks = CEIL(segLen, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "SquaredNSegmentCUDA: Block number exceeds the maximum");
    HKern_SquaredNSegment<<<nBlocks, THREADPERBLOCK>>>(srcPtr, segLen, dstPtr);
}

/*  */
void CompAdaGradNSegmentCUDA(NFloat eta, int K, int segLen, NFloat *ssgSeg, NFloat *nlrSeg) {
    int nBlocks;

    nBlocks = CEIL(segLen, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "CompAdaGradNSegmentCUDA: Block number exceeds the maximum");
    HKern_CompAdaGradNSegment<<<nBlocks, THREADPERBLOCK>>>(eta, K, segLen, ssgSeg, nlrSeg);
}

/*  */
void HNBlasNNgemmCUDA(int m, int n, int k, NFloat alpha, NFloat *A, NFloat *B, NFloat beta, NFloat *C) {
    cublasStatus_t status;

#ifdef DOUBLEANN
    status = cublasDgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, &alpha, A, m, B, k, &beta, C, m);
#else
    status = cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, &alpha, A, m, B, k, &beta, C, m);
#endif
    if (status != CUBLAS_STATUS_SUCCESS) {
        HError(9999, "HNBlasNNgemmCUDA: CUBLAS library gemm function failed");
    }
}

/*  */
void HNBlasNTgemmCUDA(int m, int n, int k, NFloat alpha, NFloat *A, NFloat *B, NFloat beta, NFloat *C) {
    cublasStatus_t status;

#ifdef DOUBLEANN
    status = cublasDgemm(handle, CUBLAS_OP_N, CUBLAS_OP_T, m, n, k, &alpha, A, m, B, n, &beta, C, m);
#else
    status = cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_T, m, n, k, &alpha, A, m, B, n, &beta, C, m);
#endif
    if (status != CUBLAS_STATUS_SUCCESS) {
        HError(9999, "HNBlasNTgemmCUDA: CUBLAS library gemm function failed");
    }
}

/*  */
void HNBlasTNgemmCUDA(int m, int n, int k, NFloat alpha, NFloat *A, NFloat *B, NFloat beta, NFloat *C) {
    cublasStatus_t status;

#ifdef DOUBLEANN
    status = cublasDgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, m, n, k, &alpha, A, k, B, k, &beta, C, m);
#else
    status = cublasSgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, m, n, k, &alpha, A, k, B, k, &beta, C, m);
#endif
    if (status != CUBLAS_STATUS_SUCCESS) {
        HError(9999, "HNBlasTNgemmCUDA: CUBLAS library gemm function failed");
    }
}

/*  */
void CalXENTCriterionCUDA(NFloat *refPtr, NFloat *hypPtr, int segLen, NFloat *crtPtr) {
    HKern_CalXENTCriterionCUDA<<<1, THREADPERBLOCK>>>(refPtr, hypPtr, segLen, crtPtr);
}

/*  */
void CalMMSECriterionCUDA(NFloat *refPtr, NFloat *hypPtr, int segLen, NFloat *crtPtr) {
    HKern_CalMMSECriterionCUDA<<<1, THREADPERBLOCK>>>(refPtr, hypPtr, segLen, crtPtr);
}

/*  */
void AddNSegmentTargetPenCUDA(NFloat *srcSeg, NFloat *penSeg, int row, int col, NFloat *dstSeg) {
    int nBlocks, size;

    size = row * col;
    nBlocks = CEIL(size, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "AddNVectorTargetPenCUDA: Block number exceeds the maximum");

    HKern_AddSegmentTargetPen<<<nBlocks, THREADPERBLOCK>>>(srcSeg, penSeg, row, col, dstSeg);
}

void FindMaxElementCUDA(NFloat *srcPtr, int row, int col, NFloat *dstPtr) {
    int nBlocks, sBytes;

    nBlocks = row;
    sBytes = 2 * sizeof(NFloat) * THREADPERBLOCK;
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "FindMaxElementCUDA: Block number exceeds the maximum");
    HKern_RedMaxElementIndex<<<nBlocks, THREADPERBLOCK, sBytes>>>(srcPtr, row, col, dstPtr);
}

/*  */
/*void SubNSegmentByConstCUDA(NFloat *srcSeg, int segLen, NFloat constVal, NFloat *dstSeg) {
    int nBlocks;

    nBlocks = CEIL(segLen, THREADPERBLOCK); 
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "SubNSegmentByConstCUDA: Block number exceeds the maximum");

    HKern_SubNSegmentByConst<<<nBlocks, THREADPERBLOCK>>>(srcSeg, segLen, constVal, dstSeg);
}*/

/* cz277 - semi */
/*  */
void ShiftNSegmentValsCUDA(NFloat *srcSeg, int segLen, NFloat shiftVal, NFloat *dstSeg) {
    int nBlocks;

    nBlocks = CEIL(segLen, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ShiftNSegmentValsCUDA: Block number exceeds the maximum");

    HKern_ShiftNSegmentVals<<<nBlocks, THREADPERBLOCK>>>(srcSeg, segLen, shiftVal, dstSeg);
}

/* cz277 - 1007 */
void CopyPartialNSegmentCUDA(int minRow, int minCol, NFloat *srcPtr, int srcCol, NFloat *dstPtr, int dstCol) {
    int len, nBlocks;

    len = minRow * minCol;
    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "CopyPartialNSegmentCUDA: Block number exceeds the maximum");
    HKern_CopyPartialNSegment<<<nBlocks, THREADPERBLOCK>>>(minRow, minCol, srcPtr, srcCol, dstPtr, dstCol);
}

/* --------------------------- HFBLat funcs ------------------------ */

/* cz277 - cuda fblat */
void SetModelBetaPlusCUDA(int T, NMatrix *llhMat, int *qLo, int *qHi, int Q, float probScale, AcousticDev *acList) {
    int nBlocks;

    /* t in [1 ... T]; q in [1 ... Q] */
    nBlocks = CEIL(T * Q, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "SetModelBetaPlusCUDA: Block number exceeds the maximum");
    /* setotprob */
    HKern_Setotprob4q<<<nBlocks, THREADPERBLOCK>>>(T, llhMat->devElems, llhMat->colNum, qLo, qHi, Q, probScale, acList);
    /* set model beta plus */
    nBlocks = CEIL(Q, THREADPERBLOCK);
    HKern_SetModelPlus<<<nBlocks, THREADPERBLOCK>>>(Q, acList);

} 


/* cz277 - cuda fblat */
void ZeroAlphasCUDA(int T, int Q, AcousticDev *acList) {
    int nBlocks;

    nBlocks = CEIL(T * Q, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "ZeroAlphasCUDA: Block number exceeds the maximum");
    HKern_ZeroAlphas<<<nBlocks, THREADPERBLOCK>>>(T, Q, acList);
}


/* cz277 - cuda fblat */
void StepAlphaCUDA(int Q, AcousticDev *acList) {
    int nBlocks;

    nBlocks = CEIL(Q, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "StepAlphaCUDA: Block number exceeds the maximum");
    HKern_StepAlpha<<<nBlocks, THREADPERBLOCK>>>(Q, acList);
}

/* cz277 - gradlim */
void ClipNSegmentValsCUDA(NFloat* srcSeg, int len, NFloat upperLim, NFloat lowerLim, NFloat *dstSeg) {
    int nBlocks;

    nBlocks = CEIL(len, THREADPERBLOCK);
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "LimitNSegmentValsCUDA: Block number exceeds the maximum");
    HKern_ClipNSegmentVals<<<nBlocks, THREADPERBLOCK>>>(srcSeg, len, upperLim, lowerLim, dstSeg);
}

/* cz277 - max norm */
void CalExtNMatrixL2NormCUDA(NFloat *matPtr, NFloat *vecPtr, int row, int col, NFloat *alphas) {
    int nBlocks, sBytes;
  
    nBlocks = row;
    sBytes = sizeof(NFloat) * THREADPERBLOCK;
    if (nBlocks > MAXBLOCKNUM)
        HError(9999, "CalExtNMatrixL2NormCUDA: Block number exceeds the maximum");
    HKern_RedCalExtNMatrixL2Norm<<<nBlocks, THREADPERBLOCK, sBytes>>>(matPtr, vecPtr, row, col, alphas);
    nBlocks = 1;
    HKern_RedMaxElementValue<<<nBlocks, THREADPERBLOCK, sBytes>>>(alphas, 1, row, alphas);
}


/* --------------------------- Trace Flags ------------------------ */


#ifdef __cplusplus
}
#endif


