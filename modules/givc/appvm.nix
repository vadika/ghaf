# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  ...
}:
let
  cfg = config.ghaf.givc.appvm;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;
  inherit (config.ghaf.networking) hosts;
  inherit (config.networking) hostName;
  tlsMode = config.ghaf.global-config.givc.tls.mode or config.ghaf.givc.tls.mode;
  tlsSpiffeSocketPath =
    config.ghaf.global-config.givc.tls.spiffeSocketPath or config.ghaf.givc.tls.spiffeSocketPath;
  tlsTrustDomain = config.ghaf.global-config.givc.tls.trustDomain or config.ghaf.givc.tls.trustDomain;
  tlsAllowedIDs = config.ghaf.global-config.givc.tls.allowedIDs or config.ghaf.givc.tls.allowedIDs;
in
{
  _file = ./appvm.nix;

  options.ghaf.givc.appvm = {
    enable = mkEnableOption "Enable appvm givc module.";
    applications = mkOption {
      type = types.listOf types.attrs;
      default = [ { } ];
      description = "Applications to run in the appvm.";
    };
  };

  config = mkIf (cfg.enable && config.ghaf.givc.enable) {
    # Configure appvm service
    givc.appvm = {
      enable = true;
      inherit (config.ghaf.givc) debug;
      inherit (config.ghaf.users.homedUser) uid;
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
      capabilities = {
        inherit (cfg) applications;
      };
    };
    ghaf.security.audit.extraRules = [
      "-w /etc/givc/ -p wa -k givc-${hostName}"
    ];
  };
}
