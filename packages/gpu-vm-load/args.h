// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
//
// Pure argument parsing for gpu-vm-load, split out so it can be unit-tested on
// the build host without libcuda.
#ifndef GPU_VM_LOAD_ARGS_H
#define GPU_VM_LOAD_ARGS_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct gvl_opts {
  int secs;      // burn duration, seconds
  int device;    // CUDA device ordinal to select
  int list_only; // 1 = print device count and exit
};

// Returns 0 on success (*out fully populated, defaults applied), nonzero on a
// bad argument (writes a message into err, size >= 128).
static inline int gvl_parse_args(int argc, char **argv, struct gvl_opts *out,
                                 char *err) {
  out->secs = 20;
  out->device = 0;
  out->list_only = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--count")) {
      out->list_only = 1;
      continue;
    }
    if (!strcmp(argv[i], "--device") || !strcmp(argv[i], "-d")) {
      if (i + 1 >= argc) {
        snprintf(err, 128, "%s needs a device ordinal", argv[i]);
        return 1;
      }
      char *end;
      long v = strtol(argv[++i], &end, 10);
      if (*argv[i] == '\0' || *end != '\0' || v < 0 || v > 15) {
        snprintf(err, 128, "invalid device ordinal '%s' (expected 0..15)",
                 argv[i]);
        return 1;
      }
      out->device = (int)v;
      continue;
    }
    char *end;
    long v = strtol(argv[i], &end, 10);
    if (*argv[i] == '\0' || *end != '\0' || v <= 0 || v > 86400) {
      snprintf(err, 128, "invalid duration '%s' (expected 1..86400 seconds)",
               argv[i]);
      return 1;
    }
    out->secs = (int)v;
  }
  return 0;
}
#endif
