// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#ifndef GHAF_GPU_PARTITION_PROTOCOL_H
#define GHAF_GPU_PARTITION_PROTOCOL_H

#include <stdint.h>

#define GPM_PROTOCOL_MAGIC 0x314d5047U /* GPM1, native little endian */
#define GPM_PROTOCOL_VERSION 1U
#define GPM_SOCKET_PATH "/run/gpu-partition-manager/control.sock"
#define GPM_MAX_PAYLOAD 4096U
#define GPM_PLUGIN_NAME_MAX 64U
#define GPM_ARGUMENTS_MAX 1024U
#define GPM_REPORT_MAX 2048U
#define GPM_SLOT_AUTO UINT32_MAX

enum gpm_opcode {
  GPM_OP_LIST = 1,
  GPM_OP_STATUS = 2,
  GPM_OP_RUN = 3,
  GPM_OP_CANCEL = 4,
  GPM_OP_RUN_ACCEPTED = 5,
  GPM_OP_RUN_RESULT = 6,
  GPM_OP_RESPONSE = 7,
};

enum gpm_status {
  GPM_STATUS_OK = 0,
  GPM_STATUS_INVALID = 1,
  GPM_STATUS_NOT_FOUND = 2,
  GPM_STATUS_BUSY = 3,
  GPM_STATUS_CANCELLED = 4,
  GPM_STATUS_PLUGIN_ERROR = 5,
  GPM_STATUS_CUDA_ERROR = 6,
  GPM_STATUS_INTERNAL = 7,
};

struct gpm_header {
  uint32_t magic;
  uint16_t version;
  uint16_t opcode;
  uint32_t payload_length;
  uint64_t request_id;
};

struct gpm_run_request {
  uint32_t slot;
  uint32_t argc;
  char plugin[GPM_PLUGIN_NAME_MAX];
  uint32_t arguments_length;
  char arguments[GPM_ARGUMENTS_MAX];
};

struct gpm_cancel_request {
  uint64_t job_id;
};

struct gpm_run_accepted {
  uint64_t job_id;
  uint32_t slot;
  uint32_t sm_count;
};

struct gpm_run_result {
  uint64_t job_id;
  uint32_t status;
  char report[GPM_REPORT_MAX];
};

struct gpm_response {
  uint32_t status;
  char report[GPM_REPORT_MAX];
};

#endif
