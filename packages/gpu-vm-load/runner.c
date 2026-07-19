// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
//
// gpu-vm-load: CUDA Driver-API smoke test for the gpu-vm passthrough. Embeds
// the burn-kernel PTX as a blob, launches it in a loop for N seconds, prints
// the GPU's compute capability. Hand-declared prototypes + RPATH-wired native
// L4T libcuda.so.1, so it needs no CUDA toolkit, LD_LIBRARY_PATH, or nvcc.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stddef.h>
#include "args.h"

typedef int CUresult;
typedef int CUdevice;
typedef struct CUctx_st *CUcontext;
typedef struct CUmod_st *CUmodule;
typedef struct CUfunc_st *CUfunction;
typedef unsigned long long CUdeviceptr;
typedef struct { unsigned char bytes[16]; } CUuuid;

// CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_{MAJOR,MINOR}
enum { ATTR_CC_MAJOR = 75, ATTR_CC_MINOR = 76 };

extern CUresult cuInit(unsigned int);
extern CUresult cuDeviceGet(CUdevice *, int);
extern CUresult cuDeviceGetCount(int *);
extern CUresult cuDeviceGetName(char *, int, CUdevice);
extern CUresult cuDeviceGetUuid(CUuuid *, CUdevice);
extern CUresult cuDeviceGetAttribute(int *, int, CUdevice);
extern CUresult cuCtxCreate_v2(CUcontext *, unsigned int, CUdevice);
extern CUresult cuModuleLoadData(CUmodule *, const void *);
extern CUresult cuModuleGetFunction(CUfunction *, CUmodule, const char *);
extern CUresult cuMemAlloc_v2(CUdeviceptr *, size_t);
extern CUresult cuLaunchKernel(CUfunction, unsigned, unsigned, unsigned,
                               unsigned, unsigned, unsigned, unsigned, void *,
                               void **, void **);
extern CUresult cuCtxSynchronize(void);

// Embed the hand-written PTX as a null-terminated blob via the assembler's
// .incbin, so no CUDA toolkit is needed to build (see vadd.ptx).
__asm__(".pushsection .rodata\n"
        ".global vadd_ptx\n"
        "vadd_ptx:\n"
        ".incbin \"vadd.ptx\"\n"
        ".byte 0\n"
        ".popsection\n");
extern const char vadd_ptx[];

#define CK(x)                                                                  \
  do {                                                                         \
    CUresult _r = (x);                                                         \
    if (_r) {                                                                  \
      fprintf(stderr, "%s failed: CUresult=%d\n", #x, _r);                     \
      return 1;                                                                \
    }                                                                          \
  } while (0)

int main(int argc, char **argv) {
  struct gvl_opts opt;
  char err[128];
  if (gvl_parse_args(argc, argv, &opt, err)) {
    fprintf(stderr, "%s\n", err);
    return 2;
  }
  size_t n = (size_t)1 << 20;

  CK(cuInit(0));

  int count = 0;
  CK(cuDeviceGetCount(&count));
  printf("CUDA device count: %d\n", count);
  if (opt.list_only)
    return 0;
  if (opt.device >= count) {
    fprintf(stderr, "device %d out of range (count=%d)\n", opt.device, count);
    return 2;
  }

  CUdevice dev;
  CK(cuDeviceGet(&dev, opt.device));

  char name[256] = {0};
  CK(cuDeviceGetName(name, sizeof(name), dev));
  CUuuid uuid;
  CK(cuDeviceGetUuid(&uuid, dev));
  printf("device %d: name='%s' uuid=", opt.device, name);
  for (int i = 0; i < 16; i++)
    printf("%02x", uuid.bytes[i]);
  printf("\n");

  int ccmaj = 0, ccmin = 0;
  CK(cuDeviceGetAttribute(&ccmaj, ATTR_CC_MAJOR, dev));
  CK(cuDeviceGetAttribute(&ccmin, ATTR_CC_MINOR, dev));
  printf("GPU compute capability: sm_%d%d\n", ccmaj, ccmin);

  CUcontext ctx;
  CK(cuCtxCreate_v2(&ctx, 0, dev));
  CUmodule mod;
  CK(cuModuleLoadData(&mod, vadd_ptx));
  CUfunction fn;
  CK(cuModuleGetFunction(&fn, mod, "burn"));
  CUdeviceptr out;
  CK(cuMemAlloc_v2(&out, n * sizeof(float)));

  int nn = (int)n;
  void *args[] = {&out, &nn};
  unsigned grid = (unsigned)((n + 255) / 256);
  printf("running GPU load on device %d for %d s "
         "(watch /sys/devices/platform/64000000.gpu/load)\n",
         opt.device, opt.secs);
  fflush(stdout);

  time_t t0 = time(NULL);
  time_t last = t0;
  unsigned long iters = 0;
  while (time(NULL) - t0 < opt.secs) {
    CK(cuLaunchKernel(fn, grid, 1, 1, 256, 1, 1, 0, NULL, args, NULL));
    CK(cuCtxSynchronize());
    iters++;
    time_t now = time(NULL);
    if (now != last) { // one timestamped progress line per second
      printf("[t+%lds] device %d iters=%lu\n", (long)(now - t0), opt.device,
             iters);
      fflush(stdout);
      last = now;
    }
  }
  if (iters == 0) {
    fprintf(stderr, "GPU_LOAD_FAIL: no kernel launches completed\n");
    return 1;
  }
  printf("GPU_LOAD_OK device=%d iters=%lu\n", opt.device, iters);
  return 0;
}
