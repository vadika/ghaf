// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#define _POSIX_C_SOURCE 200809L
#include "plugin.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int mock_run(CUstream stream, unsigned int sm_count, int argc,
                    const char *const *argv,
                    const volatile sig_atomic_t *cancelled, char *report,
                    size_t report_size) {
  unsigned long milliseconds = 20;
  (void)stream;
  if (argc != 0) {
    char *end = NULL;
    if (argc != 2 || strcmp(argv[0], "--milliseconds") != 0)
      return GPM_PLUGIN_INVALID_ARGUMENT;
    errno = 0;
    milliseconds = strtoul(argv[1], &end, 10);
    if (errno != 0 || end == NULL || *end != '\0' || milliseconds > 60000)
      return GPM_PLUGIN_INVALID_ARGUMENT;
  }
  for (unsigned long elapsed = 0; elapsed < milliseconds; elapsed += 10) {
    struct timespec delay = {.tv_nsec = 10000000L};
    if (*cancelled != 0) {
      snprintf(report, report_size, "plugin=mock status=cancelled");
      return GPM_PLUGIN_CANCELLED;
    }
    nanosleep(&delay, NULL);
  }
  snprintf(report, report_size, "plugin=mock status=ok sm_count=%u", sm_count);
  return GPM_PLUGIN_OK;
}

static const struct gpm_plugin_v1 plugin = {
    .abi_version = GPM_PLUGIN_ABI_VERSION,
    .name = "mock",
    .summary = "Mock scheduler workload",
    .run = mock_run,
};

const struct gpm_plugin_v1 *gpm_plugin_get_v1(void) { return &plugin; }
