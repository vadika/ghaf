# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Disp VM Configuration Module
#
# This module uses the globalConfig pattern:
# - Global settings (debug, development, logging, storage) come via globalConfig specialArg
# - Host-specific settings (networking.hosts) come via hostConfig specialArg
#
# The VM configuration is self-contained and does not reference `configHost`.
# All platforms must use the evaluatedConfig pattern with a profile's dispvmBase.
#
# NOTE: dispvmBase (analogous to gpuvmBase) is exported by the orin profile,
# which also wires ghaf.virtualization.microvm.dispvm.evaluatedConfig. This VM
# stays inert unless that wiring is present: enable is only ever true when
# ghaf.hardware.nvidia.passthroughs.disp_vm.enable is true (Orin AGX only), and
# the assertion below fires if enable is set without the profile-side wiring.
{
  config,
  lib,
  inputs,
  ...
}:
let
  vmName = "disp-vm";

  cfg = config.ghaf.virtualization.microvm.dispvm;
in
{
  _file = ./dispvm.nix;

  options.ghaf.virtualization.microvm.dispvm = {
    enable = lib.mkEnableOption "DispVM";

    evaluatedConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
      description = "Pre-evaluated NixOS configuration for Disp VM set via profile's dispvmBase.extendModules.";
    };

    extraNetworking = lib.mkOption {
      type = lib.types.networking;
      description = "Extra Networking option";
      default = { };
    };
  };

  config = lib.mkMerge [
    {
      ghaf.virtualization.microvm.sysvm.vms.dispvm = {
        inherit vmName;
        inherit (cfg) enable evaluatedConfig extraNetworking;
      };
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.evaluatedConfig != null;
          message = ''
            ghaf.virtualization.microvm.dispvm.evaluatedConfig must be set.
            Use a profile that provides dispvmBase (orin).

            For Jetson (Orin AGX), the orin profile wires it as:
              dispvm.evaluatedConfig = config.ghaf.profiles.orin.dispvmBase.extendModules {
                modules = lib.ghaf.vm.applyVmConfig {
                  inherit config;
                  vmName = "dispvm";
                };
              };
          '';
        }
      ];

      ghaf.common = {
        extraNetworking.hosts.${vmName} = cfg.extraNetworking;
        policies = lib.mkIf cfg.evaluatedConfig.config.ghaf.givc.policyClient.enable {
          "${vmName}" = cfg.evaluatedConfig.config.ghaf.givc.policyClient.policies;
        };
        spire.agents = lib.mkIf cfg.evaluatedConfig.config.ghaf.security.spire.agent.enable {
          "${vmName}" = {
            inherit (cfg.evaluatedConfig.config.ghaf.security.spire.agent) nodeAttestationMode workloads;
          };
        };
      };

      microvm.vms."${vmName}" = {
        autostart = !config.ghaf.microvm-boot.enable;
        restartIfChanged = false;
        inherit (inputs) nixpkgs;
        inherit (cfg) evaluatedConfig;
      };
    })
  ];
}
