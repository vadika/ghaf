// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#define _POSIX_C_SOURCE 200809L
#include "protocol.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;

static void signal_handler(int signal_number) {
  (void)signal_number;
  interrupted = 1;
}

static uint64_t request_id(void) {
  struct timespec now = {0};
  (void)clock_gettime(CLOCK_MONOTONIC, &now);
  return ((uint64_t)(uint32_t)getpid() << 32) ^ (uint64_t)now.tv_nsec ^
         (uint64_t)now.tv_sec;
}

static int connect_manager(const char *path) {
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  int fd;

  if (strlen(path) >= sizeof(address.sun_path)) {
    fprintf(stderr, "socket path is too long: %s\n", path);
    return -1;
  }
  fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    perror("socket");
    return -1;
  }
  snprintf(address.sun_path, sizeof(address.sun_path), "%s", path);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    fprintf(stderr, "cannot connect to %s: %s\n", path, strerror(errno));
    close(fd);
    return -1;
  }
  return fd;
}

static bool send_packet(int fd, uint16_t opcode, uint64_t id,
                        const void *payload, uint32_t payload_length) {
  struct gpm_header header = {
      .magic = GPM_PROTOCOL_MAGIC,
      .version = GPM_PROTOCOL_VERSION,
      .opcode = opcode,
      .payload_length = payload_length,
      .request_id = id,
  };
  struct iovec vectors[2] = {
      {.iov_base = &header, .iov_len = sizeof(header)},
      {.iov_base = (void *)payload, .iov_len = payload_length},
  };
  struct msghdr message = {
      .msg_iov = vectors,
      .msg_iovlen = payload_length == 0 ? 1 : 2,
  };
  ssize_t sent = sendmsg(fd, &message, MSG_NOSIGNAL);
  return sent == (ssize_t)(sizeof(header) + payload_length);
}

static bool receive_packet(int fd, struct gpm_header *header, void *payload,
                           size_t payload_capacity) {
  unsigned char packet[sizeof(struct gpm_header) + GPM_MAX_PAYLOAD];
  ssize_t received = recv(fd, packet, sizeof(packet), 0);
  if (received < (ssize_t)sizeof(*header))
    return false;
  memcpy(header, packet, sizeof(*header));
  if (header->magic != GPM_PROTOCOL_MAGIC ||
      header->version != GPM_PROTOCOL_VERSION ||
      header->payload_length > payload_capacity ||
      received != (ssize_t)(sizeof(*header) + header->payload_length))
    return false;
  if (header->payload_length != 0)
    memcpy(payload, packet + sizeof(*header), header->payload_length);
  return true;
}

static int response_exit_status(const struct gpm_response *response) {
  if (response->report[0] != '\0')
    printf("%s\n", response->report);
  return response->status == GPM_STATUS_OK ? EXIT_SUCCESS : EXIT_FAILURE;
}

static int simple_request(const char *socket_path, uint16_t opcode,
                          const void *payload, uint32_t payload_length) {
  struct gpm_header header;
  struct gpm_response response;
  uint64_t id = request_id();
  int fd = connect_manager(socket_path);
  int result = EXIT_FAILURE;

  if (fd < 0)
    return result;
  if (!send_packet(fd, opcode, id, payload, payload_length) ||
      !receive_packet(fd, &header, &response, sizeof(response)) ||
      header.opcode != GPM_OP_RESPONSE || header.request_id != id ||
      header.payload_length != sizeof(response)) {
    fprintf(stderr, "invalid manager response\n");
    goto done;
  }
  result = response_exit_status(&response);
done:
  close(fd);
  return result;
}

static void usage(FILE *stream, const char *program) {
  fprintf(stream,
          "Usage:\n"
          "  %s [--socket PATH] list\n"
          "  %s [--socket PATH] status\n"
          "  %s [--socket PATH] cancel JOB_ID\n"
          "  %s [--socket PATH] [--slot auto|0|1] PLUGIN [ARGS...]\n",
          program, program, program, program);
}

static bool parse_job_id(const char *text, uint64_t *value) {
  char *end = NULL;
  unsigned long long parsed;
  errno = 0;
  parsed = strtoull(text, &end, 10);
  if (errno != 0 || text[0] == '\0' || end == NULL || *end != '\0' ||
      parsed == 0)
    return false;
  *value = (uint64_t)parsed;
  return true;
}

static bool encode_arguments(struct gpm_run_request *request, int argc,
                             char **argv) {
  size_t used = 0;
  if (argc > 32)
    return false;
  for (int index = 0; index < argc; index++) {
    size_t length = strlen(argv[index]) + 1;
    if (length > sizeof(request->arguments) - used)
      return false;
    memcpy(request->arguments + used, argv[index], length);
    used += length;
  }
  request->argc = (uint32_t)argc;
  request->arguments_length = (uint32_t)used;
  return true;
}

static void cancel_job(const char *socket_path, uint64_t job_id) {
  struct gpm_cancel_request request = {.job_id = job_id};
  (void)simple_request(socket_path, GPM_OP_CANCEL, &request, sizeof(request));
}

static int run_job(const char *socket_path, uint32_t slot, const char *plugin,
                   int argc, char **argv) {
  struct gpm_run_request request = {.slot = slot};
  struct gpm_header header;
  union {
    struct gpm_response response;
    struct gpm_run_accepted accepted;
    struct gpm_run_result result;
  } payload;
  struct sigaction action = {.sa_handler = signal_handler};
  uint64_t id = request_id();
  uint64_t job_id = 0;
  bool cancellation_sent = false;
  int fd;

  if (strlen(plugin) >= sizeof(request.plugin) ||
      !encode_arguments(&request, argc, argv)) {
    fprintf(stderr, "plugin name or argument vector is too long\n");
    return EXIT_FAILURE;
  }
  snprintf(request.plugin, sizeof(request.plugin), "%s", plugin);
  fd = connect_manager(socket_path);
  if (fd < 0)
    return EXIT_FAILURE;
  if (!send_packet(fd, GPM_OP_RUN, id, &request, sizeof(request)) ||
      !receive_packet(fd, &header, &payload, sizeof(payload))) {
    fprintf(stderr, "manager did not accept the job\n");
    close(fd);
    return EXIT_FAILURE;
  }
  if (header.opcode == GPM_OP_RESPONSE &&
      header.payload_length == sizeof(payload.response)) {
    int result = response_exit_status(&payload.response);
    close(fd);
    return result;
  }
  if (header.opcode != GPM_OP_RUN_ACCEPTED || header.request_id != id ||
      header.payload_length != sizeof(payload.accepted)) {
    fprintf(stderr, "invalid job acknowledgement\n");
    close(fd);
    return EXIT_FAILURE;
  }
  job_id = payload.accepted.job_id;
  printf("job_id=%llu slot=%u sm_count=%u\n",
         (unsigned long long)job_id, payload.accepted.slot,
         payload.accepted.sm_count);
  fflush(stdout);

  sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGTERM, &action, NULL);
  for (;;) {
    struct pollfd poll_fd = {.fd = fd, .events = POLLIN | POLLHUP};
    int poll_result = poll(&poll_fd, 1, 250);
    if (interrupted && !cancellation_sent) {
      cancel_job(socket_path, job_id);
      cancellation_sent = true;
    }
    if (poll_result < 0 && errno == EINTR)
      continue;
    if (poll_result < 0) {
      perror("poll");
      break;
    }
    if (poll_result == 0)
      continue;
    if (!receive_packet(fd, &header, &payload, sizeof(payload))) {
      fprintf(stderr, "manager disconnected before reporting a result\n");
      break;
    }
    if (header.opcode != GPM_OP_RUN_RESULT || header.request_id != id ||
        header.payload_length != sizeof(payload.result) ||
        payload.result.job_id != job_id) {
      fprintf(stderr, "invalid job result\n");
      break;
    }
    if (payload.result.report[0] != '\0')
      printf("%s\n", payload.result.report);
    close(fd);
    if (payload.result.status == GPM_STATUS_OK)
      return EXIT_SUCCESS;
    if (payload.result.status == GPM_STATUS_CANCELLED)
      return 130;
    return EXIT_FAILURE;
  }
  close(fd);
  return EXIT_FAILURE;
}

int main(int argc, char **argv) {
  const char *socket_path = GPM_SOCKET_PATH;
  uint32_t slot = GPM_SLOT_AUTO;
  int index = 1;

  while (index < argc) {
    if (strcmp(argv[index], "--socket") == 0 && index + 1 < argc) {
      socket_path = argv[index + 1];
      index += 2;
    } else if (strcmp(argv[index], "--slot") == 0 && index + 1 < argc) {
      const char *value = argv[index + 1];
      if (strcmp(value, "auto") == 0)
        slot = GPM_SLOT_AUTO;
      else if (strcmp(value, "0") == 0)
        slot = 0;
      else if (strcmp(value, "1") == 0)
        slot = 1;
      else {
        usage(stderr, argv[0]);
        return 2;
      }
      index += 2;
    } else {
      break;
    }
  }
  if (index >= argc) {
    usage(stderr, argv[0]);
    return 2;
  }
  if (strcmp(argv[index], "list") == 0 && index + 1 == argc)
    return simple_request(socket_path, GPM_OP_LIST, NULL, 0);
  if (strcmp(argv[index], "status") == 0 && index + 1 == argc)
    return simple_request(socket_path, GPM_OP_STATUS, NULL, 0);
  if (strcmp(argv[index], "cancel") == 0 && index + 2 == argc) {
    struct gpm_cancel_request request;
    if (!parse_job_id(argv[index + 1], &request.job_id)) {
      fprintf(stderr, "invalid job id: %s\n", argv[index + 1]);
      return 2;
    }
    return simple_request(socket_path, GPM_OP_CANCEL, &request,
                          sizeof(request));
  }
  return run_job(socket_path, slot, argv[index], argc - index - 1,
                 argv + index + 1);
}
