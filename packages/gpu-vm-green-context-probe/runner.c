// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
//
// Probe CUDA Green Context support on the passed-through GA10B. This is a
// userspace resource-partitioning experiment: it neither changes nvgpu MIG
// configuration nor creates devices that can be assigned to separate VMs.
#define _GNU_SOURCE
#include <cuda.h>

#include <errno.h>
#include <getopt.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Reuse the hand-written burn kernel from gpu-vm-load. The package copies it
// into the build directory before compiling this source.
__asm__(".pushsection .rodata\n"
        ".global burn_ptx\n"
        "burn_ptx:\n"
        ".incbin \"vadd.ptx\"\n"
        ".byte 0\n"
        ".popsection\n");
extern const char burn_ptx[];

enum run_mode { MODE_PROBE, MODE_SOLO, MODE_DUAL };

struct options {
  enum run_mode mode;
  unsigned int min_sm_count;
  unsigned int seconds;
  unsigned int group;
};

struct green_partition {
  CUdevice device;
  CUcontext primary;
  bool primary_retained;
  CUdevResource groups[2];
  CUdevResource remainder;
  CUdevResourceDesc descriptors[2];
  CUgreenCtx contexts[2];
  unsigned int group_count;
};

struct start_gate {
  pthread_mutex_t mutex;
  pthread_cond_t cond;
  unsigned int expected;
  unsigned int ready;
  bool failed;
};

struct worker {
  unsigned int id;
  unsigned int seconds;
  CUgreenCtx green_context;
  unsigned int sm_count;
  struct start_gate *gate;
  bool passed;
  unsigned long iterations;
};

static pthread_mutex_t output_mutex = PTHREAD_MUTEX_INITIALIZER;

static void cuda_result(const char *call, CUresult result) {
  const char *name = "unknown";
  const char *description = "unknown";

  (void)cuGetErrorName(result, &name);
  (void)cuGetErrorString(result, &description);
  printf("CUDA call=%s result=%d name=%s description=%s\n", call,
         (int)result, name != NULL ? name : "unknown",
         description != NULL ? description : "unknown");
}

static bool worker_cuda_result(unsigned int worker_id, const char *call,
                               CUresult result) {
  const char *name = "unknown";
  const char *description = "unknown";

  if (result == CUDA_SUCCESS)
    return true;

  (void)cuGetErrorName(result, &name);
  (void)cuGetErrorString(result, &description);
  pthread_mutex_lock(&output_mutex);
  fprintf(stderr,
          "worker=%u CUDA call=%s result=%d name=%s description=%s\n",
          worker_id, call, (int)result, name != NULL ? name : "unknown",
          description != NULL ? description : "unknown");
  pthread_mutex_unlock(&output_mutex);
  return false;
}

#define PROBE_CALL(expression)                                                 \
  do {                                                                         \
    CUresult call_result = (expression);                                       \
    cuda_result(#expression, call_result);                                     \
    if (call_result == CUDA_ERROR_NOT_SUPPORTED) {                             \
      fprintf(stderr,                                                          \
              "GREEN_CONTEXT_UNSUPPORTED reason=cuda_api call=%s\n",         \
              #expression);                                                    \
      goto fail;                                                               \
    }                                                                          \
    if (call_result != CUDA_SUCCESS) {                                         \
      fprintf(stderr, "GREEN_CONTEXT_FAIL reason=cuda_api call=%s\n",        \
              #expression);                                                    \
      goto fail;                                                               \
    }                                                                          \
  } while (0)

#define WORKER_CALL(worker_id, expression)                                    \
  do {                                                                         \
    if (!worker_cuda_result((worker_id), #expression, (expression)))           \
      goto rendezvous;                                                         \
  } while (0)

static uint64_t monotonic_ns(void) {
  struct timespec now;

  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return 0;
  return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static bool parse_unsigned(const char *text, unsigned int minimum,
                           unsigned int maximum, unsigned int *value) {
  char *end = NULL;
  unsigned long parsed;

  errno = 0;
  parsed = strtoul(text, &end, 10);
  if (errno != 0 || text[0] == '\0' || end == NULL || *end != '\0' ||
      parsed < minimum || parsed > maximum)
    return false;
  *value = (unsigned int)parsed;
  return true;
}

static void usage(FILE *stream, const char *program) {
  fprintf(stream,
          "Usage:\n"
          "  %s probe [--min-sm-count N]\n"
          "  %s solo [--group 0|1] [--seconds N] [--min-sm-count N]\n"
          "  %s dual [--seconds N] [--min-sm-count N]\n\n"
          "probe creates and verifies two Green Contexts without launching "
          "kernels.\n"
          "solo and dual run the existing deterministic gpu-vm burn kernel.\n",
          program, program, program);
}

static bool parse_options(int argc, char **argv, struct options *options) {
  static const struct option long_options[] = {
      {"group", required_argument, NULL, 'g'},
      {"seconds", required_argument, NULL, 's'},
      {"min-sm-count", required_argument, NULL, 'm'},
      {"help", no_argument, NULL, 'h'},
      {NULL, 0, NULL, 0},
  };
  bool group_set = false;
  int option;

  if (argc < 2)
    return false;
  if (strcmp(argv[1], "probe") == 0)
    options->mode = MODE_PROBE;
  else if (strcmp(argv[1], "solo") == 0)
    options->mode = MODE_SOLO;
  else if (strcmp(argv[1], "dual") == 0)
    options->mode = MODE_DUAL;
  else
    return false;

  options->min_sm_count = 4;
  options->seconds = 30;
  options->group = 0;

  optind = 2;
  while ((option = getopt_long(argc, argv, "g:s:m:h", long_options, NULL)) !=
         -1) {
    switch (option) {
    case 'g':
      if (!parse_unsigned(optarg, 0, 1, &options->group))
        return false;
      group_set = true;
      break;
    case 's':
      if (!parse_unsigned(optarg, 1, 86400, &options->seconds))
        return false;
      break;
    case 'm':
      if (!parse_unsigned(optarg, 1, 1024, &options->min_sm_count))
        return false;
      break;
    case 'h':
      usage(stdout, argv[0]);
      exit(EXIT_SUCCESS);
    default:
      return false;
    }
  }

  if (optind != argc)
    return false;
  if (group_set && options->mode != MODE_SOLO)
    return false;
  return true;
}

static void destroy_partition(struct green_partition *partition) {
  for (int index = 1; index >= 0; index--) {
    if (partition->contexts[index] != NULL) {
      CUresult result = cuGreenCtxDestroy(partition->contexts[index]);
      cuda_result("cuGreenCtxDestroy", result);
      partition->contexts[index] = NULL;
    }
  }
  if (partition->primary_retained) {
    CUresult result = cuDevicePrimaryCtxRelease(partition->device);
    cuda_result("cuDevicePrimaryCtxRelease", result);
    partition->primary_retained = false;
  }
}

static bool create_partition(struct green_partition *partition,
                             unsigned int min_sm_count) {
  CUdevResource device_resource = {0};
  CUdevResource queried = {0};
  unsigned int dry_run_groups = 2;
  int driver_version = 0;
  int device_count = 0;
  int major = 0;
  int minor = 0;
  char device_name[256] = {0};

  memset(partition, 0, sizeof(*partition));

  PROBE_CALL(cuInit(0));
  PROBE_CALL(cuDriverGetVersion(&driver_version));
  PROBE_CALL(cuDeviceGetCount(&device_count));
  if (device_count < 1) {
    fprintf(stderr, "GREEN_CONTEXT_UNSUPPORTED reason=no_cuda_device\n");
    goto fail;
  }
  PROBE_CALL(cuDeviceGet(&partition->device, 0));
  PROBE_CALL(cuDeviceGetName(device_name, sizeof(device_name),
                             partition->device));
  PROBE_CALL(cuDeviceGetAttribute(
      &major, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR, partition->device));
  PROBE_CALL(cuDeviceGetAttribute(
      &minor, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, partition->device));
  printf("device=0 name=%s driver_version=%d compute_capability=sm_%d%d\n",
         device_name, driver_version, major, minor);

  PROBE_CALL(cuDevicePrimaryCtxRetain(&partition->primary,
                                      partition->device));
  partition->primary_retained = true;
  PROBE_CALL(cuCtxSetCurrent(partition->primary));
  PROBE_CALL(cuDeviceGetDevResource(partition->device, &device_resource,
                                    CU_DEV_RESOURCE_TYPE_SM));
  printf("device_sm_count=%u requested_groups=2 min_sm_count=%u\n",
         device_resource.sm.smCount, min_sm_count);

  PROBE_CALL(cuDevSmResourceSplitByCount(
      NULL, &dry_run_groups, &device_resource, NULL, 0, min_sm_count));
  printf("dry_run_group_count=%u\n", dry_run_groups);
  if (dry_run_groups < 2) {
    fprintf(stderr,
            "GREEN_CONTEXT_UNSUPPORTED reason=insufficient_symmetric_groups "
            "groups=%u\n",
            dry_run_groups);
    goto fail;
  }

  partition->group_count = 2;
  PROBE_CALL(cuDevSmResourceSplitByCount(
      partition->groups, &partition->group_count, &device_resource,
      &partition->remainder, 0, min_sm_count));
  if (partition->group_count != 2) {
    fprintf(stderr,
            "GREEN_CONTEXT_UNSUPPORTED reason=real_split_group_count "
            "groups=%u\n",
            partition->group_count);
    goto fail;
  }
  printf("split group0_sm_count=%u group1_sm_count=%u remainder_sm_count=%u\n",
         partition->groups[0].sm.smCount, partition->groups[1].sm.smCount,
         partition->remainder.type == CU_DEV_RESOURCE_TYPE_SM
             ? partition->remainder.sm.smCount
             : 0);

  for (unsigned int index = 0; index < partition->group_count; index++) {
    PROBE_CALL(cuDevResourceGenerateDesc(&partition->descriptors[index],
                                         &partition->groups[index], 1));
    PROBE_CALL(cuGreenCtxCreate(&partition->contexts[index],
                                partition->descriptors[index],
                                partition->device,
                                CU_GREEN_CTX_DEFAULT_STREAM));
    PROBE_CALL(cuGreenCtxGetDevResource(partition->contexts[index], &queried,
                                        CU_DEV_RESOURCE_TYPE_SM));
    printf("green_context=%u requested_sm_count=%u queried_sm_count=%u\n",
           index, partition->groups[index].sm.smCount, queried.sm.smCount);
    if (queried.type != CU_DEV_RESOURCE_TYPE_SM ||
        queried.sm.smCount != partition->groups[index].sm.smCount) {
      fprintf(stderr,
              "GREEN_CONTEXT_FAIL reason=resource_query_mismatch context=%u\n",
              index);
      goto fail;
    }
  }

  PROBE_CALL(cuCtxSetCurrent(NULL));
  printf("GREEN_CONTEXT_PROBE_OK groups=2\n");
  return true;

fail:
  (void)cuCtxSetCurrent(NULL);
  destroy_partition(partition);
  return false;
}

static bool gate_wait(struct start_gate *gate, bool prepared) {
  bool start;

  pthread_mutex_lock(&gate->mutex);
  gate->ready++;
  if (!prepared)
    gate->failed = true;
  if (gate->ready == gate->expected || gate->failed)
    pthread_cond_broadcast(&gate->cond);
  while (gate->ready < gate->expected && !gate->failed)
    pthread_cond_wait(&gate->cond, &gate->mutex);
  start = !gate->failed;
  pthread_mutex_unlock(&gate->mutex);
  return start;
}

static void gate_abort(struct start_gate *gate) {
  pthread_mutex_lock(&gate->mutex);
  gate->failed = true;
  pthread_cond_broadcast(&gate->cond);
  pthread_mutex_unlock(&gate->mutex);
}

static void print_progress(const struct worker *worker, uint64_t started,
                           uint64_t now) {
  pthread_mutex_lock(&output_mutex);
  printf("worker=%u elapsed_ms=%llu iterations=%lu\n", worker->id,
         (unsigned long long)((now - started) / 1000000ULL),
         worker->iterations);
  fflush(stdout);
  pthread_mutex_unlock(&output_mutex);
}

static void *run_worker(void *opaque) {
  const size_t element_count = (size_t)1 << 20;
  struct worker *worker = opaque;
  CUcontext context = NULL;
  CUstream stream = NULL;
  CUmodule module = NULL;
  CUfunction function = NULL;
  CUdeviceptr output = 0;
  uint64_t started = 0;
  uint64_t stopped = 0;
  uint64_t next_progress = 0;
  float samples[3] = {0};
  bool prepared = false;
  bool valid = false;
  int count = (int)element_count;
  void *arguments[] = {&output, &count};
  unsigned int grid = (unsigned int)((element_count + 255) / 256);

  WORKER_CALL(worker->id,
              cuCtxFromGreenCtx(&context, worker->green_context));
  WORKER_CALL(worker->id, cuCtxSetCurrent(context));
  WORKER_CALL(worker->id,
              cuGreenCtxStreamCreate(&stream, worker->green_context,
                                     CU_STREAM_NON_BLOCKING, 0));
  WORKER_CALL(worker->id, cuModuleLoadData(&module, burn_ptx));
  WORKER_CALL(worker->id,
              cuModuleGetFunction(&function, module, "burn"));
  WORKER_CALL(worker->id,
              cuMemAlloc(&output, element_count * sizeof(float)));
  WORKER_CALL(worker->id,
              cuMemsetD8(output, 0, element_count * sizeof(float)));
  prepared = true;

rendezvous:
  if (!gate_wait(worker->gate, prepared))
    goto cleanup;

  started = monotonic_ns();
  next_progress = started + 1000000000ULL;
  pthread_mutex_lock(&output_mutex);
  printf("worker=%u green_context=%u sm_count=%u start_ns=%llu\n", worker->id,
         worker->id, worker->sm_count, (unsigned long long)started);
  fflush(stdout);
  pthread_mutex_unlock(&output_mutex);

  while (monotonic_ns() - started < (uint64_t)worker->seconds * 1000000000ULL) {
    if (!worker_cuda_result(
            worker->id, "cuLaunchKernel",
            cuLaunchKernel(function, grid, 1, 1, 256, 1, 1, 0, stream,
                           arguments, NULL)))
      goto cleanup;
    if (!worker_cuda_result(worker->id, "cuStreamSynchronize",
                            cuStreamSynchronize(stream)))
      goto cleanup;
    worker->iterations++;
    uint64_t now = monotonic_ns();
    if (now >= next_progress) {
      print_progress(worker, started, now);
      next_progress = now + 1000000000ULL;
    }
  }

  if (worker->iterations == 0)
    goto cleanup;
  if (!worker_cuda_result(worker->id, "cuMemcpyDtoH(first)",
                          cuMemcpyDtoH(&samples[0], output,
                                       sizeof(samples[0]))))
    goto cleanup;
  if (!worker_cuda_result(
          worker->id, "cuMemcpyDtoH(middle)",
          cuMemcpyDtoH(&samples[1],
                       output + (element_count / 2) * sizeof(float),
                       sizeof(samples[1]))))
    goto cleanup;
  if (!worker_cuda_result(
          worker->id, "cuMemcpyDtoH(last)",
          cuMemcpyDtoH(&samples[2],
                       output + (element_count - 1) * sizeof(float),
                       sizeof(samples[2]))))
    goto cleanup;
  valid = isfinite(samples[0]) && samples[0] > 1.0f &&
          samples[0] == samples[1] && samples[1] == samples[2];
  worker->passed = valid;

cleanup:
  stopped = monotonic_ns();
  pthread_mutex_lock(&output_mutex);
  printf("worker=%u stop_ns=%llu iterations=%lu validation=%s sample=%g\n",
         worker->id, (unsigned long long)stopped, worker->iterations,
         valid ? "ok" : "failed", samples[0]);
  fflush(stdout);
  pthread_mutex_unlock(&output_mutex);

  if (output != 0)
    (void)worker_cuda_result(worker->id, "cuMemFree", cuMemFree(output));
  if (module != NULL)
    (void)worker_cuda_result(worker->id, "cuModuleUnload",
                             cuModuleUnload(module));
  if (stream != NULL)
    (void)worker_cuda_result(worker->id, "cuStreamDestroy",
                             cuStreamDestroy(stream));
  if (context != NULL)
    (void)worker_cuda_result(worker->id, "cuCtxSetCurrent(NULL)",
                             cuCtxSetCurrent(NULL));
  return NULL;
}

static bool run_workload(struct green_partition *partition,
                         const struct options *options) {
  struct start_gate gate = {
      .mutex = PTHREAD_MUTEX_INITIALIZER,
      .cond = PTHREAD_COND_INITIALIZER,
      .expected = options->mode == MODE_DUAL ? 2 : 1,
  };
  struct worker workers[2] = {0};
  pthread_t threads[2] = {0};
  unsigned int created = 0;
  unsigned int first = options->mode == MODE_SOLO ? options->group : 0;
  unsigned int count = options->mode == MODE_DUAL ? 2 : 1;
  bool passed = true;

  for (unsigned int index = 0; index < count; index++) {
    unsigned int group = first + index;
    workers[index] = (struct worker){
        .id = group,
        .seconds = options->seconds,
        .green_context = partition->contexts[group],
        .sm_count = partition->groups[group].sm.smCount,
        .gate = &gate,
    };
    int result = pthread_create(&threads[index], NULL, run_worker,
                                &workers[index]);
    if (result != 0) {
      fprintf(stderr, "pthread_create failed: %s\n", strerror(result));
      gate_abort(&gate);
      passed = false;
      break;
    }
    created++;
  }

  for (unsigned int index = 0; index < created; index++) {
    int result = pthread_join(threads[index], NULL);
    if (result != 0) {
      fprintf(stderr, "pthread_join failed: %s\n", strerror(result));
      passed = false;
    }
    if (!workers[index].passed)
      passed = false;
  }

  pthread_cond_destroy(&gate.cond);
  pthread_mutex_destroy(&gate.mutex);
  if (passed)
    printf("GREEN_CONTEXT_RUN_OK workers=%u seconds=%u\n", count,
           options->seconds);
  else
    fprintf(stderr, "GREEN_CONTEXT_RUN_FAIL workers=%u\n", count);
  return passed;
}

int main(int argc, char **argv) {
  struct options options;
  struct green_partition partition;
  bool passed;

  setvbuf(stdout, NULL, _IOLBF, 0);
  if (!parse_options(argc, argv, &options)) {
    usage(stderr, argv[0]);
    return 2;
  }
  if (!create_partition(&partition, options.min_sm_count))
    return 1;

  passed = options.mode == MODE_PROBE || run_workload(&partition, &options);
  destroy_partition(&partition);
  return passed ? 0 : 1;
}
