// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#include "cuda.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct mock_context {
  int unused;
};
struct mock_stream {
  int unused;
};
struct mock_resource_desc {
  unsigned int sm_count;
};
struct mock_green_context {
  unsigned int sm_count;
  struct mock_context context;
};

static struct mock_context primary;

CUresult cuInit(unsigned int flags) {
  (void)flags;
  return CUDA_SUCCESS;
}
CUresult cuDeviceGetCount(int *count) {
  *count = 1;
  return CUDA_SUCCESS;
}
CUresult cuDeviceGet(CUdevice *device, int ordinal) {
  *device = ordinal;
  return CUDA_SUCCESS;
}
CUresult cuDeviceGetName(char *name, int length, CUdevice device) {
  (void)device;
  snprintf(name, (size_t)length, "Mock CUDA device");
  return CUDA_SUCCESS;
}
CUresult cuDevicePrimaryCtxRetain(CUcontext *context, CUdevice device) {
  (void)device;
  *context = &primary;
  return CUDA_SUCCESS;
}
CUresult cuDevicePrimaryCtxRelease(CUdevice device) {
  (void)device;
  return CUDA_SUCCESS;
}
CUresult cuCtxSetCurrent(CUcontext context) {
  (void)context;
  return CUDA_SUCCESS;
}
CUresult cuDeviceGetDevResource(CUdevice device, CUdevResource *resource,
                                unsigned int type) {
  (void)device;
  resource->type = type;
  resource->sm.smCount = 16;
  return CUDA_SUCCESS;
}
CUresult cuDevSmResourceSplitByCount(CUdevResource *results,
                                     unsigned int *count,
                                     const CUdevResource *input,
                                     CUdevResource *remainder,
                                     unsigned int flags,
                                     unsigned int minimum) {
  (void)flags;
  if (*count < 2 || minimum * 2 > input->sm.smCount)
    return 1;
  *count = 2;
  for (unsigned int index = 0; index < 2; index++) {
    results[index].type = CU_DEV_RESOURCE_TYPE_SM;
    results[index].sm.smCount = minimum;
  }
  remainder->type = CU_DEV_RESOURCE_TYPE_SM;
  remainder->sm.smCount = input->sm.smCount - 2 * minimum;
  return CUDA_SUCCESS;
}
CUresult cuDevResourceGenerateDesc(CUdevResourceDesc *descriptor,
                                   const CUdevResource *resources,
                                   unsigned int count) {
  if (count != 1)
    return 1;
  *descriptor = malloc(sizeof(**descriptor));
  if (*descriptor == NULL)
    return 1;
  (*descriptor)->sm_count = resources[0].sm.smCount;
  return CUDA_SUCCESS;
}
CUresult cuGreenCtxCreate(CUgreenCtx *green_context,
                          CUdevResourceDesc descriptor, CUdevice device,
                          unsigned int flags) {
  (void)device;
  (void)flags;
  *green_context = calloc(1, sizeof(**green_context));
  if (*green_context == NULL)
    return 1;
  (*green_context)->sm_count = descriptor->sm_count;
  free(descriptor);
  return CUDA_SUCCESS;
}
CUresult cuGreenCtxGetDevResource(CUgreenCtx green_context,
                                  CUdevResource *resource, unsigned int type) {
  resource->type = type;
  resource->sm.smCount = green_context->sm_count;
  return CUDA_SUCCESS;
}
CUresult cuGreenCtxDestroy(CUgreenCtx green_context) {
  free(green_context);
  return CUDA_SUCCESS;
}
CUresult cuCtxFromGreenCtx(CUcontext *context, CUgreenCtx green_context) {
  *context = &green_context->context;
  return CUDA_SUCCESS;
}
CUresult cuGreenCtxStreamCreate(CUstream *stream, CUgreenCtx green_context,
                                unsigned int flags, int priority) {
  (void)green_context;
  (void)flags;
  (void)priority;
  *stream = calloc(1, sizeof(**stream));
  return *stream == NULL ? 1 : CUDA_SUCCESS;
}
CUresult cuStreamDestroy(CUstream stream) {
  free(stream);
  return CUDA_SUCCESS;
}
CUresult cuGetErrorName(CUresult error, const char **name) {
  (void)error;
  *name = "MOCK_ERROR";
  return CUDA_SUCCESS;
}
CUresult cuGetErrorString(CUresult error, const char **description) {
  (void)error;
  *description = "mock CUDA error";
  return CUDA_SUCCESS;
}
