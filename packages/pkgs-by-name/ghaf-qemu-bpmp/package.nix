# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# ghaf-qemu, pinned to 10.1.5 and extended with the NVIDIA BPMP guest bridge --
# a sysbus MMIO device that forwards a guest's BPMP messages to the host proxy
# through /dev/bpmp-host, plus the guest /bpmp device-tree node describing it.
#
# Why the version pin, and why a separate package:
#
#   QEMU removed `-device vfio-platform` in 10.2 ("vfio-platform has not got any
#   traction. PCIe passthrough shall be the mainline solution.", see
#   docs/about/removed-features.rst). Passing an on-SoC MMIO device such as the
#   Orin's MGBE0 ethernet controller to a guest needs it, and nothing has
#   replaced it. 10.1.5 is the last release that has it.
#
#   Only the VM that receives such a device needs this QEMU. Everything else --
#   admin-vm, gui-vm, and the host's own tooling -- stays on the nixpkgs QEMU
#   via pkgs.ghaf-qemu. Consumers set microvm.qemu.package in their own scope.
#
# This pin is a liability: net-vm is network-facing and will not pick up QEMU
# security fixes released after 10.1.x. Revisit if upstream ever restores
# platform passthrough, or if the wired NIC moves behind PCIe.
#
#   nix build .#ghaf-qemu-bpmp
#
{ ghaf-qemu, fetchurl, ... }:
ghaf-qemu.overrideAttrs (
  _final: prev: rec {
    pname = "ghaf-qemu-bpmp";
    version = "10.1.5";

    src = fetchurl {
      url = "https://download.qemu.org/qemu-${version}.tar.xz";
      hash = "sha256-HxIJtNuC5sRBfq9ufgsHNWNXKgQtn7dJKwhLplqcBpM=";
    };

    patches = (prev.patches or [ ]) ++ [ ./patches/0001-nvidia-bpmp-guest-hooks.patch ];

    # The device is carried as source rather than as ~180 lines of `+` in a diff.
    postPatch = (prev.postPatch or "") + ''
      cp ${./sources/hw/misc/nvidia_bpmp_guest.c} hw/misc/nvidia_bpmp_guest.c
      cp ${./sources/include/hw/misc/nvidia_bpmp_guest.h} include/hw/misc/nvidia_bpmp_guest.h
      chmod u+w hw/misc/nvidia_bpmp_guest.c include/hw/misc/nvidia_bpmp_guest.h

      # ghaf-qemu's 0006-ivshmem-flat-memory-support.patch is written against QEMU 11,
      # where sysbus.h lives at include/hw/core/. In 10.1 it is still include/hw/.
      substituteInPlace hw/misc/ivshmem-pci.c \
        --replace-fail '#include "hw/core/sysbus.h"' '#include "hw/sysbus.h"'
    '';
  }
)
