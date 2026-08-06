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
        ".global gpm_burn_ptx\n"
        "gpm_burn_ptx:\n"
        ".incbin \"vadd.ptx\"\n"
        ".byte 0\n"
        ".popsection\n");
extern const char gpm_burn_ptx[];

static uint64_t monotonic_ns(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return 0;
  return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static bool parse_seconds(int argc, const char *const *argv,
                          unsigned int *seconds) {
  char *end = NULL;
  unsigned long value;

  *seconds = 30;
  if (argc == 0)
    return true;
  if (argc != 2 || strcmp(argv[0], "--seconds") != 0)
    return false;
  errno = 0;
  value = strtoul(argv[1], &end, 10);
  if (errno != 0 || argv[1][0] == '\0' || end == NULL || *end != '\0' ||
      value < 1 || value > 3600)
    return false;
  *seconds = (unsigned int)value;
  return true;
}

static int burn_run(CUstream stream, unsigned int sm_count, int argc,
                    const char *const *argv,
                    const volatile sig_atomic_t *cancelled, char *report,
                    size_t report_size) {
  const size_t element_count = (size_t)1 << 20;
  CUmodule module = NULL;
  CUfunction function = NULL;
  CUdeviceptr output = 0;
  CUresult cuda_result;
  unsigned int seconds;
  unsigned long iterations = 0;
  uint64_t started;
  float samples[3] = {0};
  int count = (int)element_count;
  unsigned int grid = (unsigned int)((element_count + 255) / 256);
  void *arguments[] = {&output, &count};
  int result = GPM_PLUGIN_CUDA_ERROR;

  if (!parse_seconds(argc, argv, &seconds)) {
    snprintf(report, report_size,
             "invalid arguments; usage: burn [--seconds 1..3600]");
    return GPM_PLUGIN_INVALID_ARGUMENT;
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

  CUDA_TRY(cuModuleLoadData(&module, gpm_burn_ptx));
  CUDA_TRY(cuModuleGetFunction(&function, module, "burn"));
  CUDA_TRY(cuMemAlloc(&output, element_count * sizeof(float)));
  CUDA_TRY(cuMemsetD8(output, 0, element_count * sizeof(float)));

  started = monotonic_ns();
  while (monotonic_ns() - started < (uint64_t)seconds * 1000000000ULL) {
    if (*cancelled != 0) {
      snprintf(report, report_size,
               "plugin=burn status=cancelled iterations=%lu", iterations);
      result = GPM_PLUGIN_CANCELLED;
      goto cleanup;
    }
    CUDA_TRY(cuLaunchKernel(function, grid, 1, 1, 256, 1, 1, 0, stream,
                            arguments, NULL));
    CUDA_TRY(cuStreamSynchronize(stream));
    iterations++;
  }

  if (iterations == 0) {
    snprintf(report, report_size, "plugin=burn completed no iterations");
    result = GPM_PLUGIN_INTERNAL_ERROR;
    goto cleanup;
  }
  CUDA_TRY(cuMemcpyDtoH(&samples[0], output, sizeof(samples[0])));
  CUDA_TRY(cuMemcpyDtoH(&samples[1],
                        output + (element_count / 2) * sizeof(float),
                        sizeof(samples[1])));
  CUDA_TRY(cuMemcpyDtoH(&samples[2],
                        output + (element_count - 1) * sizeof(float),
                        sizeof(samples[2])));
  if (!(samples[0] > 1.0f && samples[0] == samples[1] &&
        samples[1] == samples[2])) {
    snprintf(report, report_size,
             "plugin=burn validation=failed iterations=%lu sample=%g",
             iterations, samples[0]);
    result = GPM_PLUGIN_INTERNAL_ERROR;
    goto cleanup;
  }

  snprintf(report, report_size,
           "plugin=burn status=ok sm_count=%u seconds=%u iterations=%lu "
           "sample=%g",
           sm_count, seconds, iterations, samples[0]);
  result = GPM_PLUGIN_OK;

cleanup:
  if (output != 0)
    (void)cuMemFree(output);
  if (module != NULL)
    (void)cuModuleUnload(module);
  return result;
#undef CUDA_TRY
}

static const struct gpm_plugin_v1 plugin = {
    .abi_version = GPM_PLUGIN_ABI_VERSION,
    .name = "burn",
    .summary = "Sustained deterministic CUDA burn workload",
    .run = burn_run,
};

const struct gpm_plugin_v1 *gpm_plugin_get_v1(void) { return &plugin; }
