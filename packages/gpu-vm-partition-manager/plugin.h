// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#ifndef GHAF_GPU_PARTITION_PLUGIN_H
#define GHAF_GPU_PARTITION_PLUGIN_H

#include "protocol.h"

#include <cuda.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>

#define GPM_PLUGIN_ABI_VERSION 1U
#define GPM_PLUGIN_ENTRYPOINT "gpm_plugin_get_v1"

enum gpm_plugin_result {
  GPM_PLUGIN_OK = 0,
  GPM_PLUGIN_INVALID_ARGUMENT = 1,
  GPM_PLUGIN_CUDA_ERROR = 2,
  GPM_PLUGIN_CANCELLED = 3,
  GPM_PLUGIN_INTERNAL_ERROR = 4,
};

struct gpm_plugin_v1 {
  uint32_t abi_version;
  const char *name;
  const char *summary;
  int (*run)(CUstream stream, unsigned int sm_count, int argc,
             const char *const *argv, const volatile sig_atomic_t *cancelled,
             char *report, size_t report_size);
};

typedef const struct gpm_plugin_v1 *(*gpm_plugin_get_v1_fn)(void);

#endif
