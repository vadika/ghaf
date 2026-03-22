# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Ghaf-specific QEMU package with ivshmem, TPM, USB, and ACPI patches.
# This module provides a patched QEMU via ghaf.virtualization.qemu.package
# instead of overriding pkgs.qemu_kvm globally, avoiding rebuild cascades.
#
{
  lib,
  pkgs,
  ...
}:
let

  qemu_version = pkgs.qemu_kvm.version;

  ghafQemu = pkgs.qemu_kvm.overrideAttrs (
    _final: prev:
    (lib.optionalAttrs (lib.versionAtLeast qemu_version "10.1") {
      patches =
        prev.patches
        ++ [
          # Shared memory support for inter-VM communication
          ./qemu-patches/0001-ivshmem-flat-memory-support.patch
          # Increase TPM command timeout
          ./qemu-patches/0002-Increase-timeout-in-tpm_util_request.patch
          # USB host autoscan for bus/addr passthrough
          ./qemu-patches/usb-host-enable-autoscan-for-bus-addr.patch
        ]
        ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
          # ACPI battery/power management for VMs
          # https://github.com/blochl/qemu/pull/3
          # TODO: remove when merged upstream
          ./qemu-patches/0001-hw-acpi-Support-extended-GPE-handling-for-additional.patch
          ./qemu-patches/0002-hw-acpi-Introduce-the-QEMU-Battery.patch
          ./qemu-patches/0003-hw-acpi-Introduce-the-QEMU-AC-adapter.patch
          ./qemu-patches/0004-hw-acpi-Introduce-the-QEMU-lid-button.patch
        ];
    })
    // {
      postInstall = (prev.postInstall or "") + ''
        cp contrib/ivshmem-server/ivshmem-server $out/bin
      '';
    }
  );
in
{
  _file = ./qemu.nix;

  options.ghaf.virtualization.qemu = {
    package = lib.mkOption {
      type = lib.types.package;
      default = ghafQemu;
      defaultText = lib.literalExpression "pkgs.qemu_kvm with Ghaf patches";
      description = "The QEMU package used across Ghaf modules.";
    };
  };
}
