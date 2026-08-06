#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

socket="$PWD/control.sock"
manager_log="$PWD/manager.log"
./gpu-partition-manager --socket "$socket" --plugin "$PWD/mock-plugin.so" \
  >"$manager_log" 2>&1 &
manager_pid=$!
cleanup() {
  kill "$manager_pid" 2>/dev/null || true
  wait "$manager_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  test -S "$socket" && break
  sleep 0.02
done
test -S "$socket"

./gpu-partition-run --socket "$socket" list | grep 'mock: Mock scheduler workload'
./gpu-partition-run --socket "$socket" status | grep 'total_sm_count=16'
./bad-client "$socket" | grep MALFORMED_PROTOCOL_REJECTED

./gpu-partition-run --socket "$socket" --slot 0 mock --milliseconds 500 \
  >job0.log &
job0_pid=$!
./gpu-partition-run --socket "$socket" --slot 1 mock --milliseconds 500 \
  >job1.log &
job1_pid=$!
for _ in $(seq 1 100); do
  grep -q '^job_id=' job0.log 2>/dev/null && break
  sleep 0.02
done
job0_id=$(sed -n 's/^job_id=\([0-9]*\).*/\1/p' job0.log)
test -n "$job0_id"
./gpu-partition-run --socket "$socket" status | grep 'slot0_busy=1'
./gpu-partition-run --socket "$socket" status | grep 'slot1_busy=1'
./gpu-partition-run --socket "$socket" cancel "$job0_id" |
  grep 'cancellation requested'
if wait "$job0_pid"; then
  echo 'cancelled job unexpectedly succeeded' >&2
  exit 1
else
  test "$?" -eq 130
fi
wait "$job1_pid"
grep 'plugin=mock status=cancelled' job0.log
grep 'plugin=mock status=ok sm_count=8' job1.log

if ./gpu-partition-run --socket "$socket" missing; then
  echo 'unknown plugin unexpectedly succeeded' >&2
  exit 1
fi
./gpu-partition-run --socket "$socket" status | grep 'jobs=0'

# Fill the complete running+queued budget, prove that job 17 is rejected, then
# kill every client to exercise disconnect-driven cancellation and queue drain.
queue_pids=()
for index in $(seq 0 15); do
  ./gpu-partition-run --socket "$socket" --slot "$((index % 2))" \
    mock --milliseconds 30000 >"queue-$index.log" 2>&1 &
  queue_pids+=("$!")
done
for _ in $(seq 1 200); do
  accepted=0
  for index in $(seq 0 15); do
    grep -q '^job_id=' "queue-$index.log" 2>/dev/null && accepted=$((accepted + 1))
  done
  test "$accepted" -eq 16 && break
  sleep 0.02
done
test "$accepted" -eq 16
if ./gpu-partition-run --socket "$socket" mock --milliseconds 1 \
  >queue-overflow.log 2>&1; then
  echo 'job 17 unexpectedly entered the bounded queue' >&2
  exit 1
fi
grep 'job queue is full' queue-overflow.log
for pid in "${queue_pids[@]}"; do
  kill -KILL "$pid" 2>/dev/null || true
done
for pid in "${queue_pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done
for _ in $(seq 1 200); do
  ./gpu-partition-run --socket "$socket" status >queue-status.log
  grep -q 'jobs=0' queue-status.log && break
  sleep 0.02
done
grep 'jobs=0' queue-status.log
grep 'GPU_PARTITION_MANAGER_READY' "$manager_log"
