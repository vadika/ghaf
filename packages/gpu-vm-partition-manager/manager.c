// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
#define _GNU_SOURCE
#include "plugin.h"
#include "protocol.h"

#include <cuda.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define GPM_SLOT_COUNT 2U
#define GPM_MAX_JOBS 16U
#define GPM_MAX_PLUGINS 32U
#define GPM_MAX_ARGUMENT_COUNT 32U

struct loaded_plugin {
  void *handle;
  const struct gpm_plugin_v1 *api;
  const char *path;
};

struct job {
  uint64_t id;
  unsigned int slot;
  struct loaded_plugin *plugin;
  int argc;
  char **argv;
  char *arguments;
  volatile sig_atomic_t cancelled;
  bool finished;
  enum gpm_status status;
  char report[GPM_REPORT_MAX];
  pthread_mutex_t mutex;
  pthread_cond_t condition;
  struct job *next;
};

struct manager;

struct worker_slot {
  struct manager *manager;
  unsigned int index;
  unsigned int sm_count;
  CUgreenCtx green_context;
  pthread_t thread;
  bool thread_created;
  bool ready;
  bool init_failed;
  bool busy;
  unsigned int queued;
  struct job *head;
  struct job *tail;
  struct job *current;
};

struct manager {
  CUdevice device;
  CUcontext primary;
  bool primary_retained;
  unsigned int device_sm_count;
  CUdevResource groups[GPM_SLOT_COUNT];
  CUdevResource remainder;
  CUdevResourceDesc descriptors[GPM_SLOT_COUNT];
  struct worker_slot slots[GPM_SLOT_COUNT];
  struct loaded_plugin plugins[GPM_MAX_PLUGINS];
  unsigned int plugin_count;
  unsigned int job_count;
  uint64_t next_job_id;
  pthread_mutex_t queue_mutex;
  pthread_cond_t queue_condition;
  pthread_mutex_t clients_mutex;
  pthread_cond_t clients_condition;
  unsigned int client_count;
};

struct client_context {
  struct manager *manager;
  int fd;
};

static volatile sig_atomic_t stopping;
static volatile sig_atomic_t fatal_error;
static int listen_fd = -1;

static void request_stop(void) {
  stopping = 1;
  if (listen_fd >= 0)
    (void)shutdown(listen_fd, SHUT_RDWR);
}

static void signal_handler(int signal_number) {
  (void)signal_number;
  request_stop();
}

static void cuda_error(const char *call, CUresult result) {
  const char *name = "unknown";
  const char *description = "unknown";
  (void)cuGetErrorName(result, &name);
  (void)cuGetErrorString(result, &description);
  fprintf(stderr, "CUDA call=%s result=%d name=%s description=%s\n", call,
          (int)result, name != NULL ? name : "unknown",
          description != NULL ? description : "unknown");
}

#define CUDA_SETUP(expression)                                                \
  do {                                                                         \
    CUresult setup_result = (expression);                                      \
    if (setup_result != CUDA_SUCCESS) {                                        \
      cuda_error(#expression, setup_result);                                   \
      goto fail;                                                               \
    }                                                                          \
  } while (0)

static bool send_packet(int fd, uint16_t opcode, uint64_t request_id,
                        const void *payload, uint32_t payload_length) {
  struct gpm_header header = {
      .magic = GPM_PROTOCOL_MAGIC,
      .version = GPM_PROTOCOL_VERSION,
      .opcode = opcode,
      .payload_length = payload_length,
      .request_id = request_id,
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
      header->payload_length > GPM_MAX_PAYLOAD ||
      header->payload_length > payload_capacity ||
      received != (ssize_t)(sizeof(*header) + header->payload_length))
    return false;
  if (header->payload_length != 0)
    memcpy(payload, packet + sizeof(*header), header->payload_length);
  return true;
}

static bool send_response(int fd, uint64_t request_id, enum gpm_status status,
                          const char *report) {
  struct gpm_response response = {.status = status};
  snprintf(response.report, sizeof(response.report), "%s",
           report != NULL ? report : "");
  return send_packet(fd, GPM_OP_RESPONSE, request_id, &response,
                     sizeof(response));
}

static struct loaded_plugin *find_plugin(struct manager *manager,
                                         const char *name) {
  for (unsigned int index = 0; index < manager->plugin_count; index++)
    if (strcmp(manager->plugins[index].api->name, name) == 0)
      return &manager->plugins[index];
  return NULL;
}

static bool load_plugin(struct manager *manager, const char *path) {
  struct loaded_plugin *loaded;
  gpm_plugin_get_v1_fn entrypoint;
  const struct gpm_plugin_v1 *api;

  if (manager->plugin_count == GPM_MAX_PLUGINS) {
    fprintf(stderr, "too many plugins (maximum %u)\n", GPM_MAX_PLUGINS);
    return false;
  }
  loaded = &manager->plugins[manager->plugin_count];
  loaded->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (loaded->handle == NULL) {
    fprintf(stderr, "cannot load plugin %s: %s\n", path, dlerror());
    return false;
  }
  dlerror();
  *(void **)(&entrypoint) = dlsym(loaded->handle, GPM_PLUGIN_ENTRYPOINT);
  const char *symbol_error = dlerror();
  if (symbol_error != NULL || entrypoint == NULL) {
    fprintf(stderr, "plugin %s has no %s: %s\n", path,
            GPM_PLUGIN_ENTRYPOINT,
            symbol_error != NULL ? symbol_error : "unknown error");
    goto fail;
  }
  api = entrypoint();
  if (api == NULL || api->abi_version != GPM_PLUGIN_ABI_VERSION ||
      api->name == NULL || api->summary == NULL || api->run == NULL ||
      api->name[0] == '\0' || strlen(api->name) >= GPM_PLUGIN_NAME_MAX) {
    fprintf(stderr, "plugin %s does not implement ABI v%u\n", path,
            GPM_PLUGIN_ABI_VERSION);
    goto fail;
  }
  if (find_plugin(manager, api->name) != NULL) {
    fprintf(stderr, "duplicate plugin name: %s\n", api->name);
    goto fail;
  }
  loaded->api = api;
  loaded->path = path;
  manager->plugin_count++;
  printf("plugin=%s summary=%s path=%s\n", api->name, api->summary, path);
  return true;

fail:
  dlclose(loaded->handle);
  memset(loaded, 0, sizeof(*loaded));
  return false;
}

static void unload_plugins(struct manager *manager) {
  for (unsigned int index = manager->plugin_count; index > 0; index--)
    if (manager->plugins[index - 1].handle != NULL)
      dlclose(manager->plugins[index - 1].handle);
  manager->plugin_count = 0;
}

static enum gpm_status plugin_status(int result) {
  switch (result) {
  case GPM_PLUGIN_OK:
    return GPM_STATUS_OK;
  case GPM_PLUGIN_INVALID_ARGUMENT:
    return GPM_STATUS_INVALID;
  case GPM_PLUGIN_CANCELLED:
    return GPM_STATUS_CANCELLED;
  case GPM_PLUGIN_CUDA_ERROR:
    return GPM_STATUS_CUDA_ERROR;
  default:
    return GPM_STATUS_PLUGIN_ERROR;
  }
}

static void finish_job(struct job *job, enum gpm_status status) {
  pthread_mutex_lock(&job->mutex);
  job->status = status;
  job->finished = true;
  pthread_cond_broadcast(&job->condition);
  pthread_mutex_unlock(&job->mutex);
}

static void *worker_main(void *opaque) {
  struct worker_slot *slot = opaque;
  struct manager *manager = slot->manager;
  CUcontext context = NULL;
  CUstream stream = NULL;
  CUresult result;

  result = cuCtxFromGreenCtx(&context, slot->green_context);
  if (result == CUDA_SUCCESS)
    result = cuCtxSetCurrent(context);
  if (result == CUDA_SUCCESS)
    result = cuGreenCtxStreamCreate(&stream, slot->green_context,
                                    CU_STREAM_NON_BLOCKING, 0);

  pthread_mutex_lock(&manager->queue_mutex);
  slot->ready = true;
  slot->init_failed = result != CUDA_SUCCESS;
  pthread_cond_broadcast(&manager->queue_condition);
  pthread_mutex_unlock(&manager->queue_mutex);
  if (result != CUDA_SUCCESS) {
    cuda_error("initialize Green Context worker", result);
    fatal_error = 1;
    request_stop();
    return NULL;
  }

  for (;;) {
    struct job *job;
    int plugin_result;

    pthread_mutex_lock(&manager->queue_mutex);
    while (slot->head == NULL && !stopping)
      pthread_cond_wait(&manager->queue_condition, &manager->queue_mutex);
    if (slot->head == NULL && stopping) {
      pthread_mutex_unlock(&manager->queue_mutex);
      break;
    }
    job = slot->head;
    slot->head = job->next;
    if (slot->head == NULL)
      slot->tail = NULL;
    slot->queued--;
    slot->busy = true;
    slot->current = job;
    pthread_mutex_unlock(&manager->queue_mutex);

    plugin_result = job->plugin->api->run(
        stream, slot->sm_count, job->argc, (const char *const *)job->argv,
        &job->cancelled, job->report, sizeof(job->report));
    pthread_mutex_lock(&manager->queue_mutex);
    slot->current = NULL;
    slot->busy = false;
    manager->job_count--;
    pthread_mutex_unlock(&manager->queue_mutex);
    finish_job(job, plugin_status(plugin_result));
    if (plugin_result == GPM_PLUGIN_CUDA_ERROR) {
      fprintf(stderr, "slot=%u fatal CUDA plugin error; restarting daemon\n",
              slot->index);
      fatal_error = 1;
      request_stop();
    }
  }

  if (stream != NULL)
    (void)cuStreamDestroy(stream);
  (void)cuCtxSetCurrent(NULL);
  return NULL;
}

static bool setup_partition(struct manager *manager) {
  CUdevResource device_resource = {0};
  CUdevResource queried = {0};
  unsigned int group_count = GPM_SLOT_COUNT;
  unsigned int half;
  int device_count = 0;
  char device_name[256] = {0};

  CUDA_SETUP(cuInit(0));
  CUDA_SETUP(cuDeviceGetCount(&device_count));
  if (device_count < 1) {
    fprintf(stderr, "no CUDA device found\n");
    goto fail;
  }
  CUDA_SETUP(cuDeviceGet(&manager->device, 0));
  CUDA_SETUP(cuDeviceGetName(device_name, sizeof(device_name), manager->device));
  CUDA_SETUP(cuDevicePrimaryCtxRetain(&manager->primary, manager->device));
  manager->primary_retained = true;
  CUDA_SETUP(cuCtxSetCurrent(manager->primary));
  CUDA_SETUP(cuDeviceGetDevResource(manager->device, &device_resource,
                                    CU_DEV_RESOURCE_TYPE_SM));
  manager->device_sm_count = device_resource.sm.smCount;
  if (manager->device_sm_count < 4 || manager->device_sm_count % 4 != 0) {
    fprintf(stderr,
            "unsupported SM geometry: total=%u; need two equal even groups\n",
            manager->device_sm_count);
    goto fail;
  }
  half = manager->device_sm_count / GPM_SLOT_COUNT;
  CUDA_SETUP(cuDevSmResourceSplitByCount(
      manager->groups, &group_count, &device_resource, &manager->remainder, 0,
      half));
  if (group_count != GPM_SLOT_COUNT ||
      manager->groups[0].sm.smCount != half ||
      manager->groups[1].sm.smCount != half ||
      (manager->remainder.type == CU_DEV_RESOURCE_TYPE_SM &&
       manager->remainder.sm.smCount != 0)) {
    fprintf(stderr,
            "CUDA did not produce an exact equal split: total=%u groups=%u "
            "counts=%u,%u remainder=%u\n",
            manager->device_sm_count, group_count,
            manager->groups[0].sm.smCount, manager->groups[1].sm.smCount,
            manager->remainder.type == CU_DEV_RESOURCE_TYPE_SM
                ? manager->remainder.sm.smCount
                : 0);
    goto fail;
  }

  for (unsigned int index = 0; index < GPM_SLOT_COUNT; index++) {
    CUDA_SETUP(cuDevResourceGenerateDesc(&manager->descriptors[index],
                                         &manager->groups[index], 1));
    CUDA_SETUP(cuGreenCtxCreate(&manager->slots[index].green_context,
                                manager->descriptors[index], manager->device,
                                CU_GREEN_CTX_DEFAULT_STREAM));
    CUDA_SETUP(cuGreenCtxGetDevResource(manager->slots[index].green_context,
                                        &queried, CU_DEV_RESOURCE_TYPE_SM));
    if (queried.type != CU_DEV_RESOURCE_TYPE_SM ||
        queried.sm.smCount != half) {
      fprintf(stderr, "slot=%u Green Context readback mismatch\n", index);
      goto fail;
    }
    manager->slots[index].sm_count = queried.sm.smCount;
  }
  CUDA_SETUP(cuCtxSetCurrent(NULL));
  printf("device=%s total_sm_count=%u slots=2 slot_sm_count=%u remainder=0\n",
         device_name, manager->device_sm_count, half);
  return true;

fail:
  (void)cuCtxSetCurrent(NULL);
  return false;
}

static void destroy_partition(struct manager *manager) {
  for (int index = (int)GPM_SLOT_COUNT - 1; index >= 0; index--) {
    if (manager->slots[index].green_context != NULL) {
      CUresult result =
          cuGreenCtxDestroy(manager->slots[index].green_context);
      if (result != CUDA_SUCCESS)
        cuda_error("cuGreenCtxDestroy", result);
      manager->slots[index].green_context = NULL;
    }
  }
  if (manager->primary_retained) {
    CUresult result = cuDevicePrimaryCtxRelease(manager->device);
    if (result != CUDA_SUCCESS)
      cuda_error("cuDevicePrimaryCtxRelease", result);
    manager->primary_retained = false;
  }
}

static bool start_workers(struct manager *manager) {
  for (unsigned int index = 0; index < GPM_SLOT_COUNT; index++) {
    struct worker_slot *slot = &manager->slots[index];
    slot->manager = manager;
    slot->index = index;
    int result = pthread_create(&slot->thread, NULL, worker_main, slot);
    if (result != 0) {
      fprintf(stderr, "cannot start slot %u worker: %s\n", index,
              strerror(result));
      request_stop();
      return false;
    }
    slot->thread_created = true;
  }

  pthread_mutex_lock(&manager->queue_mutex);
  while ((!manager->slots[0].ready || !manager->slots[1].ready) && !stopping)
    pthread_cond_wait(&manager->queue_condition, &manager->queue_mutex);
  bool ready = manager->slots[0].ready && manager->slots[1].ready &&
               !manager->slots[0].init_failed &&
               !manager->slots[1].init_failed;
  pthread_mutex_unlock(&manager->queue_mutex);
  return ready;
}

static void stop_workers(struct manager *manager) {
  pthread_mutex_lock(&manager->queue_mutex);
  for (unsigned int index = 0; index < GPM_SLOT_COUNT; index++) {
    for (struct job *job = manager->slots[index].head; job != NULL;
         job = job->next)
      job->cancelled = 1;
    if (manager->slots[index].current != NULL)
      manager->slots[index].current->cancelled = 1;
  }
  pthread_cond_broadcast(&manager->queue_condition);
  pthread_mutex_unlock(&manager->queue_mutex);
  for (unsigned int index = 0; index < GPM_SLOT_COUNT; index++)
    if (manager->slots[index].thread_created)
      pthread_join(manager->slots[index].thread, NULL);
}

static bool parse_job_arguments(const struct gpm_run_request *request,
                                struct job *job) {
  const char *cursor;
  size_t remaining;

  if (request->argc > GPM_MAX_ARGUMENT_COUNT ||
      request->arguments_length > GPM_ARGUMENTS_MAX)
    return false;
  job->argc = (int)request->argc;
  if (request->arguments_length == 0)
    return request->argc == 0;
  if (request->arguments[request->arguments_length - 1] != '\0')
    return false;
  job->arguments = malloc(request->arguments_length);
  job->argv = calloc(request->argc, sizeof(*job->argv));
  if (job->arguments == NULL || (request->argc != 0 && job->argv == NULL))
    return false;
  memcpy(job->arguments, request->arguments, request->arguments_length);
  cursor = job->arguments;
  remaining = request->arguments_length;
  for (uint32_t index = 0; index < request->argc; index++) {
    size_t length = strnlen(cursor, remaining);
    if (length == remaining)
      return false;
    job->argv[index] = (char *)cursor;
    cursor += length + 1;
    remaining -= length + 1;
  }
  return remaining == 0;
}

static void destroy_job(struct job *job) {
  if (job == NULL)
    return;
  pthread_cond_destroy(&job->condition);
  pthread_mutex_destroy(&job->mutex);
  free(job->argv);
  free(job->arguments);
  free(job);
}

static int choose_slot(struct manager *manager, uint32_t requested) {
  if (requested < GPM_SLOT_COUNT)
    return (int)requested;
  if (requested != GPM_SLOT_AUTO)
    return -1;
  unsigned int load0 = manager->slots[0].queued + manager->slots[0].busy;
  unsigned int load1 = manager->slots[1].queued + manager->slots[1].busy;
  return load0 <= load1 ? 0 : 1;
}

static enum gpm_status enqueue_job(struct manager *manager, struct job *job,
                                   uint32_t requested_slot) {
  pthread_mutex_lock(&manager->queue_mutex);
  int selected = choose_slot(manager, requested_slot);
  if (selected < 0) {
    pthread_mutex_unlock(&manager->queue_mutex);
    return GPM_STATUS_INVALID;
  }
  if (manager->job_count >= GPM_MAX_JOBS || stopping) {
    pthread_mutex_unlock(&manager->queue_mutex);
    return GPM_STATUS_BUSY;
  }
  struct worker_slot *slot = &manager->slots[selected];
  job->id = manager->next_job_id++;
  job->slot = (unsigned int)selected;
  if (slot->tail != NULL)
    slot->tail->next = job;
  else
    slot->head = job;
  slot->tail = job;
  slot->queued++;
  manager->job_count++;
  pthread_cond_broadcast(&manager->queue_condition);
  pthread_mutex_unlock(&manager->queue_mutex);
  return GPM_STATUS_OK;
}

static bool peer_disconnected(int fd) {
  unsigned char byte;
  ssize_t result = recv(fd, &byte, sizeof(byte), MSG_PEEK | MSG_DONTWAIT);
  return result == 0 || (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
                         errno != EINTR);
}

static void handle_run(struct manager *manager, int fd,
                       const struct gpm_header *header,
                       const struct gpm_run_request *request) {
  struct loaded_plugin *plugin;
  struct job *job;
  enum gpm_status status;

  if (header->payload_length != sizeof(*request) ||
      memchr(request->plugin, '\0', sizeof(request->plugin)) == NULL) {
    (void)send_response(fd, header->request_id, GPM_STATUS_INVALID,
                        "invalid RUN request");
    return;
  }
  plugin = find_plugin(manager, request->plugin);
  if (plugin == NULL) {
    (void)send_response(fd, header->request_id, GPM_STATUS_NOT_FOUND,
                        "unknown plugin");
    return;
  }
  job = calloc(1, sizeof(*job));
  if (job == NULL) {
    (void)send_response(fd, header->request_id, GPM_STATUS_INTERNAL,
                        "job allocation failed");
    return;
  }
  pthread_mutex_init(&job->mutex, NULL);
  pthread_cond_init(&job->condition, NULL);
  job->plugin = plugin;
  if (!parse_job_arguments(request, job)) {
    destroy_job(job);
    (void)send_response(fd, header->request_id, GPM_STATUS_INVALID,
                        "invalid argument encoding");
    return;
  }
  status = enqueue_job(manager, job, request->slot);
  if (status != GPM_STATUS_OK) {
    destroy_job(job);
    (void)send_response(fd, header->request_id, status,
                        status == GPM_STATUS_BUSY ? "job queue is full"
                                                  : "invalid slot");
    return;
  }

  struct gpm_run_accepted accepted = {
      .job_id = job->id,
      .slot = job->slot,
      .sm_count = manager->slots[job->slot].sm_count,
  };
  if (!send_packet(fd, GPM_OP_RUN_ACCEPTED, header->request_id, &accepted,
                   sizeof(accepted)))
    job->cancelled = 1;

  pthread_mutex_lock(&job->mutex);
  while (!job->finished) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += 250000000L;
    if (deadline.tv_nsec >= 1000000000L) {
      deadline.tv_sec++;
      deadline.tv_nsec -= 1000000000L;
    }
    (void)pthread_cond_timedwait(&job->condition, &job->mutex, &deadline);
    if (stopping || peer_disconnected(fd))
      job->cancelled = 1;
  }
  struct gpm_run_result result = {
      .job_id = job->id,
      .status = job->status,
  };
  snprintf(result.report, sizeof(result.report), "%s", job->report);
  pthread_mutex_unlock(&job->mutex);
  (void)send_packet(fd, GPM_OP_RUN_RESULT, header->request_id, &result,
                    sizeof(result));
  destroy_job(job);
}

static void handle_list(struct manager *manager, int fd,
                        const struct gpm_header *header) {
  struct gpm_response response = {.status = GPM_STATUS_OK};
  size_t used = 0;
  for (unsigned int index = 0; index < manager->plugin_count; index++) {
    int written = snprintf(response.report + used, sizeof(response.report) - used,
                           "%s%s: %s", index == 0 ? "" : "\n",
                           manager->plugins[index].api->name,
                           manager->plugins[index].api->summary);
    if (written < 0 || (size_t)written >= sizeof(response.report) - used)
      break;
    used += (size_t)written;
  }
  (void)send_packet(fd, GPM_OP_RESPONSE, header->request_id, &response,
                    sizeof(response));
}

static void handle_status(struct manager *manager, int fd,
                          const struct gpm_header *header) {
  struct gpm_response response = {.status = GPM_STATUS_OK};
  pthread_mutex_lock(&manager->queue_mutex);
  snprintf(response.report, sizeof(response.report),
           "total_sm_count=%u slot0_sm_count=%u slot0_busy=%u "
           "slot0_queued=%u slot1_sm_count=%u slot1_busy=%u "
           "slot1_queued=%u jobs=%u",
           manager->device_sm_count, manager->slots[0].sm_count,
           manager->slots[0].busy, manager->slots[0].queued,
           manager->slots[1].sm_count, manager->slots[1].busy,
           manager->slots[1].queued, manager->job_count);
  pthread_mutex_unlock(&manager->queue_mutex);
  (void)send_packet(fd, GPM_OP_RESPONSE, header->request_id, &response,
                    sizeof(response));
}

static void handle_cancel(struct manager *manager, int fd,
                          const struct gpm_header *header,
                          const struct gpm_cancel_request *request) {
  bool found = false;
  if (header->payload_length != sizeof(*request)) {
    (void)send_response(fd, header->request_id, GPM_STATUS_INVALID,
                        "invalid CANCEL request");
    return;
  }
  pthread_mutex_lock(&manager->queue_mutex);
  for (unsigned int index = 0; index < GPM_SLOT_COUNT && !found; index++) {
    struct worker_slot *slot = &manager->slots[index];
    if (slot->current != NULL && slot->current->id == request->job_id) {
      slot->current->cancelled = 1;
      found = true;
    }
    for (struct job *job = slot->head; job != NULL && !found; job = job->next)
      if (job->id == request->job_id) {
        job->cancelled = 1;
        found = true;
      }
  }
  pthread_mutex_unlock(&manager->queue_mutex);
  (void)send_response(fd, header->request_id,
                      found ? GPM_STATUS_OK : GPM_STATUS_NOT_FOUND,
                      found ? "cancellation requested" : "job not found");
}

static void *client_main(void *opaque) {
  struct client_context *context = opaque;
  struct manager *manager = context->manager;
  int fd = context->fd;
  struct gpm_header header;
  unsigned char payload[GPM_MAX_PAYLOAD] = {0};

  free(context);
  if (!receive_packet(fd, &header, payload, sizeof(payload))) {
    (void)send_response(fd, 0, GPM_STATUS_INVALID,
                        "invalid protocol frame or version");
    goto done;
  }
  switch (header.opcode) {
  case GPM_OP_LIST:
    if (header.payload_length == 0)
      handle_list(manager, fd, &header);
    else
      (void)send_response(fd, header.request_id, GPM_STATUS_INVALID,
                          "LIST has no payload");
    break;
  case GPM_OP_STATUS:
    if (header.payload_length == 0)
      handle_status(manager, fd, &header);
    else
      (void)send_response(fd, header.request_id, GPM_STATUS_INVALID,
                          "STATUS has no payload");
    break;
  case GPM_OP_RUN:
    handle_run(manager, fd, &header,
               (const struct gpm_run_request *)payload);
    break;
  case GPM_OP_CANCEL:
    handle_cancel(manager, fd, &header,
                  (const struct gpm_cancel_request *)payload);
    break;
  default:
    (void)send_response(fd, header.request_id, GPM_STATUS_INVALID,
                        "unknown opcode");
    break;
  }

done:
  close(fd);
  pthread_mutex_lock(&manager->clients_mutex);
  manager->client_count--;
  pthread_cond_broadcast(&manager->clients_condition);
  pthread_mutex_unlock(&manager->clients_mutex);
  return NULL;
}

static int create_server(const char *path) {
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
  (void)unlink(path);
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
      chmod(path, 0660) != 0 || listen(fd, 32) != 0) {
    perror("bind/listen manager socket");
    close(fd);
    (void)unlink(path);
    return -1;
  }
  return fd;
}

static void wait_for_clients(struct manager *manager) {
  pthread_mutex_lock(&manager->clients_mutex);
  while (manager->client_count != 0)
    pthread_cond_wait(&manager->clients_condition, &manager->clients_mutex);
  pthread_mutex_unlock(&manager->clients_mutex);
}

static void usage(const char *program) {
  fprintf(stderr, "Usage: %s --plugin /nix/store/.../plugin.so [--plugin ...]\n",
          program);
}

int main(int argc, char **argv) {
  struct manager manager = {
      .next_job_id = 1,
      .queue_mutex = PTHREAD_MUTEX_INITIALIZER,
      .queue_condition = PTHREAD_COND_INITIALIZER,
      .clients_mutex = PTHREAD_MUTEX_INITIALIZER,
      .clients_condition = PTHREAD_COND_INITIALIZER,
  };
  const char *socket_path = GPM_SOCKET_PATH;
  struct sigaction action = {.sa_handler = signal_handler};
  int exit_status = EXIT_FAILURE;

  setvbuf(stdout, NULL, _IOLBF, 0);
  for (int index = 1; index < argc; index++) {
    if (strcmp(argv[index], "--plugin") == 0 && index + 1 < argc) {
      if (!load_plugin(&manager, argv[++index]))
        goto cleanup;
    } else if (strcmp(argv[index], "--socket") == 0 && index + 1 < argc) {
      socket_path = argv[++index];
    } else {
      usage(argv[0]);
      goto cleanup;
    }
  }
  if (manager.plugin_count == 0) {
    usage(argv[0]);
    goto cleanup;
  }
  sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGTERM, &action, NULL);
  signal(SIGPIPE, SIG_IGN);

  if (!setup_partition(&manager)) {
    exit_status = 78; /* EX_CONFIG: do not enter a systemd restart loop. */
    goto cleanup;
  }
  if (!start_workers(&manager))
    goto shutdown;
  listen_fd = create_server(socket_path);
  if (listen_fd < 0)
    goto shutdown;
  printf("GPU_PARTITION_MANAGER_READY socket=%s plugins=%u\n", socket_path,
         manager.plugin_count);

  while (!stopping) {
    int client_fd = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC);
    if (client_fd < 0) {
      if (errno == EINTR)
        continue;
      if (!stopping)
        perror("accept");
      break;
    }
    struct client_context *context = malloc(sizeof(*context));
    if (context == NULL) {
      close(client_fd);
      continue;
    }
    context->manager = &manager;
    context->fd = client_fd;
    pthread_t thread;
    pthread_mutex_lock(&manager.clients_mutex);
    manager.client_count++;
    pthread_mutex_unlock(&manager.clients_mutex);
    int result = pthread_create(&thread, NULL, client_main, context);
    if (result != 0) {
      fprintf(stderr, "cannot create client thread: %s\n", strerror(result));
      close(client_fd);
      free(context);
      pthread_mutex_lock(&manager.clients_mutex);
      manager.client_count--;
      pthread_mutex_unlock(&manager.clients_mutex);
      continue;
    }
    pthread_detach(thread);
  }
  exit_status = fatal_error ? EXIT_FAILURE
                            : (stopping ? EXIT_SUCCESS : EXIT_FAILURE);

shutdown:
  request_stop();
  if (listen_fd >= 0) {
    close(listen_fd);
    listen_fd = -1;
  }
  stop_workers(&manager);
  wait_for_clients(&manager);
  (void)unlink(socket_path);

cleanup:
  destroy_partition(&manager);
  unload_plugins(&manager);
  pthread_cond_destroy(&manager.clients_condition);
  pthread_mutex_destroy(&manager.clients_mutex);
  pthread_cond_destroy(&manager.queue_condition);
  pthread_mutex_destroy(&manager.queue_mutex);
  return exit_status;
}
