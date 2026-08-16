# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.microvm;
  protection = cfg.crosvm.protection;
  isProtected = protection.mode != "unprotected";
  rawProtectionArgs = [
    "--protected-vm"
    "--protected-vm-with-firmware"
    "--protected-vm-without-firmware"
    "--unprotected-vm-with-firmware"
  ];
in
{
  _file = ./crosvm-protection.nix;

  options.microvm.crosvm.protection = {
    mode = lib.mkOption {
      type = lib.types.enum [
        "unprotected"
        "protected-without-firmware"
        "protected-with-firmware"
      ];
      default = "unprotected";
      description = "Crosvm guest-memory protection mode.";
    };

    firmware = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = "Custom protected-VM firmware used by the protected-with-firmware mode.";
    };
  };

  config.assertions = lib.optionals cfg.guest.enable [
    {
      assertion = lib.all (arg: !builtins.elem arg cfg.crosvm.extraArgs) rawProtectionArgs;
      message = "Use `microvm.crosvm.protection` instead of raw Crosvm protection arguments.";
    }
    {
      assertion = !isProtected || cfg.hypervisor == "crosvm";
      message = "Protected MicroVMs require the crosvm hypervisor.";
    }
    {
      assertion = !isProtected || pkgs.stdenv.hostPlatform.isAarch64;
      message = "Crosvm protected MicroVMs are currently supported only on AArch64.";
    }
    {
      assertion = protection.mode == "protected-with-firmware" || protection.firmware == null;
      message = "`microvm.crosvm.protection.firmware` requires protected-with-firmware mode.";
    }
    {
      assertion = protection.mode != "protected-with-firmware" || protection.firmware != null;
      message = "protected-with-firmware mode requires `microvm.crosvm.protection.firmware`.";
    }
    {
      assertion = !isProtected || !cfg.balloon;
      message = "Crosvm protected MicroVMs do not support ballooning in Ghaf yet.";
    }
    {
      assertion = !isProtected || cfg.shares == [ ];
      message = "Crosvm protected MicroVMs cannot use host shared-directory backends.";
    }
    {
      assertion = !isProtected || cfg.devices == [ ];
      message = "Crosvm protected MicroVM device assignment is not supported by the upstream pKVM backend.";
    }
    {
      assertion = !isProtected || !cfg.graphics.enable;
      message = "Crosvm protected MicroVMs cannot use the host vhost-user graphics backend.";
    }
  ];
}
