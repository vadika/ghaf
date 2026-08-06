# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.virtualization.gpuPartitionManager;
  manager = pkgs.callPackage ../../../packages/gpu-vm-partition-manager/package.nix {
    inherit (pkgs) nvidia-jetpack;
  };
  probe = pkgs.callPackage ../../../packages/gpu-vm-green-context-probe/package.nix {
    inherit (pkgs) nvidia-jetpack;
  };
  pluginArguments = lib.concatMap (plugin: [
    "--plugin"
    "${plugin}/lib/gpu-partition-manager/plugin.so"
  ]) cfg.plugins;
in
{
  _file = ./gpuvm-partition-manager.nix;

  options.ghaf.virtualization.gpuPartitionManager = {
    enable = lib.mkEnableOption "cooperative CUDA Green Context job manager";

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Trusted Nix packages implementing the gpu-partition-manager ABI.
        Each package must expose gpuPartitionPluginName and install its shared
        object at lib/gpu-partition-manager/plugin.so.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.plugins != [ ];
        message = "gpuPartitionManager requires at least one trusted plugin";
      }
      {
        assertion = lib.all (plugin: plugin ? gpuPartitionPluginName) cfg.plugins;
        message = "every gpuPartitionManager plugin must expose gpuPartitionPluginName";
      }
      {
        assertion =
          lib.length (lib.unique (map (plugin: plugin.gpuPartitionPluginName) cfg.plugins))
          == lib.length cfg.plugins;
        message = "gpuPartitionManager plugin names must be unique";
      }
    ];

    users.groups.gpu-partition = { };
    users.users = {
      gpu-partition = {
        isSystemUser = true;
        group = "gpu-partition";
        extraGroups = [ "video" ];
      };
      ghaf.extraGroups = [ "gpu-partition" ];
    };

    environment.systemPackages = [
      manager
      probe
    ];

    systemd.services.gpu-partition-manager = {
      description = "Managed CUDA Green Context jobs";
      wantedBy = [ "multi-user.target" ];
      wants = [ "gpu-vm-node-access.service" ];
      after = [ "gpu-vm-node-access.service" ];
      unitConfig = {
        StartLimitIntervalSec = 60;
        StartLimitBurst = 3;
      };
      serviceConfig = {
        Type = "simple";
        User = "gpu-partition";
        Group = "gpu-partition";
        RuntimeDirectory = "gpu-partition-manager";
        RuntimeDirectoryMode = "0750";
        UMask = "0007";
        ExecStart = lib.escapeShellArgs ([ "${manager}/bin/gpu-partition-manager" ] ++ pluginArguments);
        Restart = "on-failure";
        RestartSec = 2;
        RestartPreventExitStatus = 78;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_UNIX" ];
        LockPersonality = true;
      };
    };
  };
}
