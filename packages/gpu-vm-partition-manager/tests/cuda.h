// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#ifndef GPM_MOCK_CUDA_H
#define GPM_MOCK_CUDA_H

#include <stddef.h>

typedef int CUresult;
typedef int CUdevice;
typedef struct mock_context *CUcontext;
typedef struct mock_stream *CUstream;
typedef struct mock_green_context *CUgreenCtx;
typedef struct mock_resource_desc *CUdevResourceDesc;
typedef unsigned long long CUdeviceptr;
typedef void *CUmodule;
typedef void *CUfunction;

enum {
  CUDA_SUCCESS = 0,
  CU_DEV_RESOURCE_TYPE_SM = 1,
  CU_GREEN_CTX_DEFAULT_STREAM = 0,
  CU_STREAM_NON_BLOCKING = 1,
};

typedef struct {
  unsigned int type;
  struct {
    unsigned int smCount;
  } sm;
} CUdevResource;

CUresult cuInit(unsigned int flags);
CUresult cuDeviceGetCount(int *count);
CUresult cuDeviceGet(CUdevice *device, int ordinal);
CUresult cuDeviceGetName(char *name, int length, CUdevice device);
CUresult cuDevicePrimaryCtxRetain(CUcontext *context, CUdevice device);
CUresult cuDevicePrimaryCtxRelease(CUdevice device);
CUresult cuCtxSetCurrent(CUcontext context);
CUresult cuDeviceGetDevResource(CUdevice device, CUdevResource *resource,
                                unsigned int type);
CUresult cuDevSmResourceSplitByCount(CUdevResource *results,
                                     unsigned int *count,
                                     const CUdevResource *input,
                                     CUdevResource *remainder,
                                     unsigned int flags,
                                     unsigned int minimum);
CUresult cuDevResourceGenerateDesc(CUdevResourceDesc *descriptor,
                                   const CUdevResource *resources,
                                   unsigned int count);
CUresult cuGreenCtxCreate(CUgreenCtx *green_context,
                          CUdevResourceDesc descriptor, CUdevice device,
                          unsigned int flags);
CUresult cuGreenCtxGetDevResource(CUgreenCtx green_context,
                                  CUdevResource *resource, unsigned int type);
CUresult cuGreenCtxDestroy(CUgreenCtx green_context);
CUresult cuCtxFromGreenCtx(CUcontext *context, CUgreenCtx green_context);
CUresult cuGreenCtxStreamCreate(CUstream *stream, CUgreenCtx green_context,
                                unsigned int flags, int priority);
CUresult cuStreamDestroy(CUstream stream);
CUresult cuGetErrorName(CUresult error, const char **name);
CUresult cuGetErrorString(CUresult error, const char **description);

#endif
