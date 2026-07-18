/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
 *
 * gbm-nomod-shim: force plain no-modifier GBM window surfaces.
 *
 * On this passthrough guest the NVIDIA EGLStream producer fails its first
 * buffer allocation (EGL_BAD_ALLOC at eglMakeCurrent) whenever the GBM
 * surface was created with an explicit modifier list, and the closed
 * nvidia-drm GBM backend rejects any usage flags on plain creation. A
 * flags-0, no-modifier surface allocates and scans out correctly, so route
 * every surface-creation variant there. Preloaded around GBM/KMS demo
 * clients (see kmscube wrapper in gpu-vm default.nix).
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <dlfcn.h>

static void *plain(void *dev, uint32_t w, uint32_t h, uint32_t fmt)
{
    void *(*real)(void *, uint32_t, uint32_t, uint32_t, uint32_t) =
        dlsym(RTLD_NEXT, "gbm_surface_create");
    return real(dev, w, h, fmt, 0);
}

void *gbm_surface_create(void *dev, uint32_t w, uint32_t h,
                         uint32_t fmt, uint32_t flags)
{
    (void)flags;
    return plain(dev, w, h, fmt);
}

void *gbm_surface_create_with_modifiers(void *dev, uint32_t w, uint32_t h,
                                        uint32_t fmt, const uint64_t *mods,
                                        unsigned count)
{
    (void)mods; (void)count;
    return plain(dev, w, h, fmt);
}

void *gbm_surface_create_with_modifiers2(void *dev, uint32_t w, uint32_t h,
                                         uint32_t fmt, const uint64_t *mods,
                                         unsigned count, uint32_t flags)
{
    (void)mods; (void)count; (void)flags;
    return plain(dev, w, h, fmt);
}
