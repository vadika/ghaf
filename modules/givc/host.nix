# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  ...
}:
let
  cfg = config.ghaf.givc.host;
  inherit (lib)
    mkEnableOption
    mkIf
    optionalString
    optionals
    ;
in
{
  _file = ./host.nix;

  options.ghaf.givc.host = {
    enable = mkEnableOption "Enable host givc module.";
  };

  config = mkIf (cfg.enable && config.ghaf.givc.enable) {
    # Configure host service
    givc.host = {
      enable = true;
      inherit (config.ghaf.givc) debug;
      network = {
        agent.transport = {
          name = config.networking.hostName;
          addr = config.ghaf.networking.hosts.${config.networking.hostName}.ipv4;
          port = "9000";
        };
        admin.transport = lib.head config.ghaf.givc.adminConfig.addresses;
        tls = {
          enable = config.ghaf.givc.tls.mode != "none";
          inherit (config.ghaf.givc.tls) mode;
          spiffeEndpoint = config.ghaf.givc.tls.spiffeSocketPath;
          inherit (config.ghaf.givc.tls) trustDomain;
          inherit (config.ghaf.givc.tls) allowedIDs;
        };
      };
      capabilities = {
        services = [
          "reboot.target"
          "poweroff.target"
          "suspend.target"
        ]
        ++ optionals config.ghaf.services.performance.host.tuned.enable [
          "host-powersave.service"
          "host-balanced.service"
          "host-performance.service"
          "host-powersave-battery.service"
          "host-balanced-battery.service"
          "host-performance-battery.service"
        ];
        vmServices = {
          adminVm = optionalString (
            config.ghaf.common.adminHost != null
          ) "microvm@${config.ghaf.common.adminHost}.service";
          systemVms = map (vmName: "microvm@${vmName}.service") config.ghaf.common.systemHosts;
          appVms = map (vmName: "microvm@${vmName}.service") config.ghaf.common.appHosts;
        };
        exec.enable = true;
      };
    };

    givc.tls = {
      enable = config.ghaf.givc.tls.mode == "static";
      agents = lib.attrsets.mapAttrsToList (n: v: {
        name = n;
        addr = v.ipv4;
      }) config.ghaf.networking.hosts;
      generatorHostName = config.networking.hostName;
      storagePath = "/persist/storagevm/givc";
    };

    ghaf.security.audit.extraRules = [
      "-w /etc/givc/ -p wa -k givc-${config.networking.hostName}"
    ];
  };
}
