// SPDX-License-Identifier: GPL-2.0-only
#ifndef __DCE_HOST_PROXY__H__
#define __DCE_HOST_PROXY__H__

#include <linux/types.h>

/*
 * struct dce_host_msg - the single write() fop payload shared with the
 * guest-side QEMU bridge (nvidia_dce_guest.c, Task 1c). Layout must stay
 * in lockstep across both sides: iface selects the DCE IPC interface
 * (DCE_CLIENT_IPC_TYPE_*, see dce-client-ipc.h), tx/rx mirror
 * struct dce_ipc_message, and ret carries back the relay result.
 */
struct dce_host_msg {
	u32 iface;
	struct {
		void *data;
		size_t size;
	} tx;
	struct {
		void *data;
		size_t size;
	} rx;
	s32 ret;
};

/*
 * Reverse doorbell: one asynchronous DCE notification, as handed to userspace.
 *
 * DCE pushes these unsolicited (vblank, and the flip-completion event that
 * nvidia-drm's atomic commit blocks on). The bridge poll()s /dev/dce-host and
 * read()s one struct per event; `size` says how many of `data` are valid.
 *
 * Sized to DCE's own maximum IPC message so no notification is ever truncated.
 */
#define DCE_HOST_EVENT_MAX_DATA 4096

struct dce_host_event {
	u32 iface;
	u32 size;
	u8 data[DCE_HOST_EVENT_MAX_DATA];
};

#endif
