// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0
//
// Host-buildable self-check for gvl_parse_args. No libcuda needed — runs on the
// x86 build host with a native cc.
#include <assert.h>
#include "args.h"

int main(void) {
  char err[128];
  struct gvl_opts o;

  char *a0[] = {"prog"};
  assert(gvl_parse_args(1, a0, &o, err) == 0);
  assert(o.secs == 20 && o.device == 0 && o.list_only == 0);

  char *a1[] = {"prog", "15"};
  assert(gvl_parse_args(2, a1, &o, err) == 0);
  assert(o.secs == 15 && o.device == 0);

  char *a2[] = {"prog", "--device", "1", "30"};
  assert(gvl_parse_args(4, a2, &o, err) == 0);
  assert(o.device == 1 && o.secs == 30);

  char *a3[] = {"prog", "-d", "0"};
  assert(gvl_parse_args(3, a3, &o, err) == 0);
  assert(o.device == 0);

  char *a4[] = {"prog", "--count"};
  assert(gvl_parse_args(2, a4, &o, err) == 0);
  assert(o.list_only == 1);

  char *a5[] = {"prog", "--device", "99"};
  assert(gvl_parse_args(3, a5, &o, err) != 0);

  char *a6[] = {"prog", "abc"};
  assert(gvl_parse_args(2, a6, &o, err) != 0);

  char *a7[] = {"prog", "--device"};
  assert(gvl_parse_args(2, a7, &o, err) != 0);

  return 0;
}
