# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ config, lib, ... }:
let
  cfg = config.ghaf.givc.adminvm;
  inherit (lib) mkEnableOption mkIf;
  inherit (config.ghaf.givc.adminConfig) name;
  inherit (config.ghaf.networking) hosts;
  inherit (config.networking) hostName;
  tlsMode = config.ghaf.global-config.givc.tls.mode or config.ghaf.givc.tls.mode;
  tlsSpiffeSocketPath =
    config.ghaf.global-config.givc.tls.spiffeSocketPath or config.ghaf.givc.tls.spiffeSocketPath;
  tlsTrustDomain = config.ghaf.global-config.givc.tls.trustDomain or config.ghaf.givc.tls.trustDomain;
  tlsAllowedIDs = config.ghaf.global-config.givc.tls.allowedIDs or config.ghaf.givc.tls.allowedIDs;
  systemHosts = lib.lists.subtractLists (config.ghaf.common.appHosts ++ [ name ]) (
    builtins.attrNames config.ghaf.networking.hosts
  );
in
{
  _file = ./adminvm.nix;

  options.ghaf.givc.adminvm = {
    enable = mkEnableOption "Enable adminvm givc module.";
  };

  config = mkIf (cfg.enable && config.ghaf.givc.enable) {
    # Configure admin service
    givc.admin = {
      enable = true;
      inherit (config.ghaf.givc) debug;
      inherit name;
      inherit (config.ghaf.givc.adminConfig) addresses;
      services = map (host: "givc-${host}.service") systemHosts;
      tls = {
        enable = tlsMode != "none";
        mode = tlsMode;
        spiffeEndpoint = tlsSpiffeSocketPath;
        trustDomain = tlsTrustDomain;
        allowedIDs = tlsAllowedIDs;
      };
    };
    # Sysvm agent so admin-vm receives timezone/locale propagation
    givc.sysvm = {
      enable = true;
      inherit (config.ghaf.givc) debug;
      network = {
        agent.transport = {
          name = hostName;
          addr = hosts.${hostName}.ipv4;
          port = "9000";
        };
        admin.transport = lib.head config.ghaf.givc.adminConfig.addresses;
        tls = {
          enable = tlsMode != "none";
          mode = tlsMode;
          spiffeEndpoint = tlsSpiffeSocketPath;
          trustDomain = tlsTrustDomain;
          allowedIDs = tlsAllowedIDs;
        };
      };
      capabilities.services = [
        "poweroff.target"
        "reboot.target"
      ];
    };
    ghaf.security.audit.extraRules = [
      "-w /etc/givc/ -p wa -k givc-${name}"
    ];
  };
}
