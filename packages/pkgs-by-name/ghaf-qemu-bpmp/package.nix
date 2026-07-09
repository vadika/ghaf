# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# ghaf-qemu plus the NVIDIA BPMP guest bridge, a sysbus MMIO device that forwards
# a guest's BPMP messages to the host proxy via /dev/bpmp-host.
#
# Only VMs that receive a BPMP-backed passthrough device need this. The bridge is
# created unconditionally by the `virt` machine, so give it to those VMs alone by
# setting microvm.qemu.package in their scope -- not via
# ghaf.virtualization.qemu.package, which every VM consumes.
#
#   nix build .#ghaf-qemu-bpmp
#
{ ghaf-qemu, ... }:
ghaf-qemu.overrideAttrs (
  _final: prev: {
    pname = "ghaf-qemu-bpmp";

    patches = (prev.patches or [ ]) ++ [ ./patches/0001-nvidia-bpmp-guest-hooks.patch ];

    # The device is carried as source rather than as ~180 lines of `+` in a diff.
    postPatch = (prev.postPatch or "") + ''
      cp ${./sources/hw/misc/nvidia_bpmp_guest.c} hw/misc/nvidia_bpmp_guest.c
      cp ${./sources/include/hw/misc/nvidia_bpmp_guest.h} include/hw/misc/nvidia_bpmp_guest.h
      chmod u+w hw/misc/nvidia_bpmp_guest.c include/hw/misc/nvidia_bpmp_guest.h
    '';
  }
)
