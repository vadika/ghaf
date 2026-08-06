// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#define _POSIX_C_SOURCE 200809L
#include "plugin.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

__asm__(".pushsection .rodata\n"
        ".global gpm_latency_ptx\n"
        "gpm_latency_ptx:\n"
        ".incbin \"vadd.ptx\"\n"
        ".byte 0\n"
        ".popsection\n");
extern const char gpm_latency_ptx[];

static uint64_t monotonic_ns(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return 0;
  return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static int compare_u64(const void *left, const void *right) {
  const uint64_t a = *(const uint64_t *)left;
  const uint64_t b = *(const uint64_t *)right;
  return (a > b) - (a < b);
}

static bool parse_iterations(int argc, const char *const *argv,
                             unsigned int *iterations) {
  char *end = NULL;
  unsigned long value;

  *iterations = 10000;
  if (argc == 0)
    return true;
  if (argc != 2 || strcmp(argv[0], "--iterations") != 0)
    return false;
  errno = 0;
  value = strtoul(argv[1], &end, 10);
  if (errno != 0 || argv[1][0] == '\0' || end == NULL || *end != '\0' ||
      value < 1 || value > 1000000)
    return false;
  *iterations = (unsigned int)value;
  return true;
}

static int latency_run(CUstream stream, unsigned int sm_count, int argc,
                       const char *const *argv,
                       const volatile sig_atomic_t *cancelled, char *report,
                       size_t report_size) {
  const size_t element_count = 256;
  CUmodule module = NULL;
  CUfunction function = NULL;
  CUdeviceptr output = 0;
  CUresult cuda_result;
  uint64_t *samples = NULL;
  unsigned int iterations;
  unsigned int completed = 0;
  int count = (int)element_count;
  void *arguments[] = {&output, &count};
  int result = GPM_PLUGIN_CUDA_ERROR;

  if (!parse_iterations(argc, argv, &iterations)) {
    snprintf(report, report_size,
             "invalid arguments; usage: latency [--iterations 1..1000000]");
    return GPM_PLUGIN_INVALID_ARGUMENT;
  }
  samples = calloc(iterations, sizeof(*samples));
  if (samples == NULL) {
    snprintf(report, report_size, "latency sample allocation failed");
    return GPM_PLUGIN_INTERNAL_ERROR;
  }

#define CUDA_TRY(expression)                                                   \
  do {                                                                         \
    cuda_result = (expression);                                                \
    if (cuda_result != CUDA_SUCCESS) {                                         \
      snprintf(report, report_size, "CUDA call %s failed: %d", #expression, \
               (int)cuda_result);                                              \
      goto cleanup;                                                            \
    }                                                                          \
  } while (0)

  CUDA_TRY(cuModuleLoadData(&module, gpm_latency_ptx));
  CUDA_TRY(cuModuleGetFunction(&function, module, "burn"));
  CUDA_TRY(cuMemAlloc(&output, element_count * sizeof(float)));
  CUDA_TRY(cuMemsetD8(output, 0, element_count * sizeof(float)));

  for (unsigned int warmup = 0; warmup < 32; warmup++) {
    CUDA_TRY(cuLaunchKernel(function, 1, 1, 1, 256, 1, 1, 0, stream,
                            arguments, NULL));
    CUDA_TRY(cuStreamSynchronize(stream));
  }

  for (completed = 0; completed < iterations; completed++) {
    uint64_t started;
    if (*cancelled != 0) {
      snprintf(report, report_size,
               "plugin=latency status=cancelled iterations=%u", completed);
      result = GPM_PLUGIN_CANCELLED;
      goto cleanup;
    }
    started = monotonic_ns();
    CUDA_TRY(cuLaunchKernel(function, 1, 1, 1, 256, 1, 1, 0, stream,
                            arguments, NULL));
    CUDA_TRY(cuStreamSynchronize(stream));
    samples[completed] = monotonic_ns() - started;
  }

  qsort(samples, iterations, sizeof(*samples), compare_u64);
  snprintf(report, report_size,
           "plugin=latency status=ok sm_count=%u iterations=%u p50_ns=%llu "
           "p95_ns=%llu p99_ns=%llu max_ns=%llu",
           sm_count, iterations,
           (unsigned long long)samples[(iterations - 1) * 50 / 100],
           (unsigned long long)samples[(iterations - 1) * 95 / 100],
           (unsigned long long)samples[(iterations - 1) * 99 / 100],
           (unsigned long long)samples[iterations - 1]);
  result = GPM_PLUGIN_OK;

cleanup:
  if (output != 0)
    (void)cuMemFree(output);
  if (module != NULL)
    (void)cuModuleUnload(module);
  free(samples);
  return result;
#undef CUDA_TRY
}

static const struct gpm_plugin_v1 plugin = {
    .abi_version = GPM_PLUGIN_ABI_VERSION,
    .name = "latency",
    .summary = "CUDA launch and completion latency distribution",
    .run = latency_run,
};

const struct gpm_plugin_v1 *gpm_plugin_get_v1(void) { return &plugin; }
