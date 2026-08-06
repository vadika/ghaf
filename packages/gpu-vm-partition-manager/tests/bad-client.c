// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#include "protocol.h"

#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int connect_socket(const char *path) {
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
  if (fd < 0)
    return -1;
  snprintf(address.sun_path, sizeof(address.sun_path), "%s", path);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static int expect_rejection(const char *path, struct gpm_header header) {
  unsigned char response[sizeof(struct gpm_header) + sizeof(struct gpm_response)];
  int fd = connect_socket(path);
  ssize_t length;
  struct gpm_header *response_header = (struct gpm_header *)response;
  struct gpm_response *payload =
      (struct gpm_response *)(response + sizeof(*response_header));

  if (fd < 0 || send(fd, &header, sizeof(header), 0) != (ssize_t)sizeof(header))
    return 1;
  length = recv(fd, response, sizeof(response), 0);
  close(fd);
  if (length != (ssize_t)sizeof(response) ||
      response_header->opcode != GPM_OP_RESPONSE ||
      payload->status != GPM_STATUS_INVALID)
    return 1;
  return 0;
}

int main(int argc, char **argv) {
  struct gpm_header bad_version = {
      .magic = GPM_PROTOCOL_MAGIC,
      .version = 99,
      .opcode = GPM_OP_LIST,
      .request_id = 1,
  };
  struct gpm_header bad_length = {
      .magic = GPM_PROTOCOL_MAGIC,
      .version = GPM_PROTOCOL_VERSION,
      .opcode = GPM_OP_LIST,
      .payload_length = 1,
      .request_id = 2,
  };
  struct gpm_header bad_opcode = {
      .magic = GPM_PROTOCOL_MAGIC,
      .version = GPM_PROTOCOL_VERSION,
      .opcode = 999,
      .request_id = 3,
  };

  if (argc != 2)
    return 2;
  if (expect_rejection(argv[1], bad_version) != 0 ||
      expect_rejection(argv[1], bad_length) != 0 ||
      expect_rejection(argv[1], bad_opcode) != 0)
    return 1;
  puts("MALFORMED_PROTOCOL_REJECTED");
  return 0;
}
