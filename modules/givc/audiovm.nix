# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  ...
}:
let
  audioCfg = config.ghaf.services.audio;
  cfg = config.ghaf.givc.audiovm;
  inherit (lib)
    mkEnableOption
    mkIf
    optionals
    ;
  guivmName = "gui-vm";
  inherit (config.ghaf.networking) hosts;
  inherit (config.networking) hostName;
  tlsMode = config.ghaf.global-config.givc.tls.mode or config.ghaf.givc.tls.mode;
  tlsSpiffeSocketPath =
    config.ghaf.global-config.givc.tls.spiffeSocketPath or config.ghaf.givc.tls.spiffeSocketPath;
  tlsTrustDomain = config.ghaf.global-config.givc.tls.trustDomain or config.ghaf.givc.tls.trustDomain;
  tlsAllowedIDs = config.ghaf.global-config.givc.tls.allowedIDs or config.ghaf.givc.tls.allowedIDs;
in
{
  _file = ./audiovm.nix;

  options.ghaf.givc.audiovm = {
    enable = mkEnableOption "Enable audiovm givc module.";
  };

  config = mkIf (cfg.enable && config.ghaf.givc.enable) {
    # Configure audiovm service
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
      capabilities = {
        services = [
          "poweroff.target"
          "reboot.target"
        ]
        ++ optionals config.ghaf.services.power-manager.vm.enable [
          "suspend.target"
          "systemd-suspend.service"
        ];
        socketProxy = {
          sockets = lib.optionals (builtins.elem guivmName config.ghaf.common.vms) [
            {
              transport = {
                name = guivmName;
                addr = hosts.${guivmName}.ipv4;
                port = "9011";
                protocol = "tcp";
              };
              socket = "/tmp/dbusproxy_snd.sock";
            }
            (lib.optionalAttrs (audioCfg.enable && audioCfg.server.pipewireForwarding.enable) {
              transport = {
                name = guivmName;
                addr = hosts.${guivmName}.ipv4;
                inherit (audioCfg.server.pipewireForwarding) port;
                protocol = "tcp";
              };
              inherit (audioCfg.server.pipewireForwarding) socket;
            })
          ];
          enable = builtins.elem guivmName config.ghaf.common.vms;
        };
        eventProxy = {
          events = lib.optionals (builtins.elem guivmName config.ghaf.common.vms) [
            {
              transport = {
                name = guivmName;
                addr = hosts.${guivmName}.ipv4;
                port = "9012";
                protocol = "tcp";
              };
              producer = true;
              device = "mouse";
            }
          ];
          enable = builtins.elem guivmName config.ghaf.common.vms;
        };
      };
    };
    givc.dbusproxy = {
      enable = true;
      system = {
        enable = true;
        user = config.ghaf.users.proxyUser.name;
        socket = "/tmp/dbusproxy_snd.sock";
        policy = {
          talk = [
            "org.bluez.*"
            "org.blueman.Mechanism.*"
          ];
        };
      };
    };
    ghaf.security.audit.extraRules = [
      "-w /etc/givc/ -p wa -k givc-${hostName}"
    ];
  };
}
