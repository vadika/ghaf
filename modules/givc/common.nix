# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  ...
}:
let
  cfg = config.ghaf.givc;
  inherit (lib)
    mkOption
    mkEnableOption
    mkDefault
    mkIf
    types
    optionalString
    ;
  addressSubmodule = types.submodule {
    options = {
      name = mkOption {
        description = "Name of the IP range for parsing";
        type = types.str;
      };
      addr = mkOption {
        description = "IP address of admin server";
        type = types.str;
      };
      port = mkOption {
        description = "Port of admin server";
        type = types.str;
      };
      protocol = mkOption {
        description = "Protocol of admin server";
        type = types.enum [
          "tcp"
          "unix"
          "vsock"
        ];
      };
    };
  };

  # Safe access for VMs which don't have ghaf.virtualization.microvm options
  mitmEnabled =
    (config.ghaf.virtualization.microvm.idsvm.enable or false)
    && (config.ghaf.virtualization.microvm.idsvm.mitmproxy.enable or false);
  idsExtraArgs = optionalString mitmEnabled "--user-data-dir=/home/${config.ghaf.users.appUser.name}/.config/google-chrome/Default --test-type --ignore-certificate-errors-spki-list=Bq49YmAq1CG6FuBzp8nsyRXumW7Dmkp7QQ/F82azxGU=";
in
{
  _file = ./common.nix;

  options.ghaf.givc = {
    enable = mkEnableOption "Enable gRPC inter-vm communication";
    debug = mkEnableOption "Enable givc debug mode";
    enableTls = mkOption {
      description = "Enable TLS for gRPC communication globally, or disable for debugging.";
      type = types.bool;
      default = true;
    };
    tls = {
      mode = mkOption {
        description = "TLS mode for GIVC endpoints: static, spiffe, or none.";
        type = types.enum [
          "static"
          "spiffe"
          "none"
        ];
        default = "static";
      };
      spiffeSocketPath = mkOption {
        description = "SPIFFE Workload API socket endpoint URI.";
        type = types.str;
        default = "unix:///run/spire/agent.sock";
      };
      trustDomain = mkOption {
        description = "SPIFFE trust domain used by GIVC workloads.";
        type = types.str;
        default = "ghaf.internal";
      };
      allowedIDs = mkOption {
        description = "Allowed SPIFFE IDs for peer authorization.";
        type = types.listOf types.str;
        default = [ ];
      };
    };
    idsExtraArgs = mkOption {
      description = "Extra arguments for applications when IDS/MITM is enabled.";
      type = types.str;
    };
    appPrefix = mkOption {
      description = "Common application path prefix.";
      type = types.str;
    };
    adminConfig = mkOption {
      description = "Admin server configuration.";
      type = types.submodule {
        options = {
          name = mkOption {
            description = "Host name of admin server";
            type = types.str;
          };
          addresses = mkOption {
            description = "Addresses of admin server";
            type = types.listOf addressSubmodule;
          };
        };
      };
    };
    cliArgs = mkOption {
      description = "Arguments for the givc-cli to contact the admin service.";
      type = types.str;
      default = "";
    };
  };

  config = mkIf cfg.enable {

    assertions = [
      {
        assertion = cfg.debug -> (!config.ghaf.logging.enable);
        message = "Do not enable givc debug and logging simultaneously, you may leak private information.";
      }
    ];

    # Build admin address here (inside config block) to defer hosts evaluation
    # Use 'or' pattern to handle case where admin-vm isn't yet in hosts during evaluation
    ghaf.givc =
      let
        inherit (config.ghaf.networking) hosts;
        adminAddr = hosts."admin-vm".ipv4 or "192.168.100.5"; # fallback to default admin-vm IP
        adminAddress = {
          name = "admin-vm";
          addr = adminAddr;
          port = "9001";
          protocol = "tcp";
        };
      in
      {
        inherit idsExtraArgs;
        tls = {
          mode = mkDefault (config.ghaf.global-config.givc.tls.mode or "static");
          spiffeSocketPath = mkDefault (
            config.ghaf.global-config.givc.tls.spiffeSocketPath or "unix:///run/spire/agent.sock"
          );
          trustDomain = mkDefault (config.ghaf.global-config.givc.tls.trustDomain or "ghaf.internal");
          allowedIDs = mkDefault (config.ghaf.global-config.givc.tls.allowedIDs or [ ]);
        };
        enableTls = mkDefault (config.ghaf.givc.tls.mode == "static");
        appPrefix = "/run/current-system/sw/bin";
        cliArgs =
          if config.ghaf.givc.tls.mode == "spiffe" then
            builtins.replaceStrings [ "\n" ] [ " " ] ''
              --name ${adminAddress.name}
              --addr ${adminAddress.addr}
              --port ${adminAddress.port}
              --spiffe-endpoint ${config.ghaf.givc.tls.spiffeSocketPath}
              --trust-domain ${config.ghaf.givc.tls.trustDomain}
            ''
          else
            builtins.replaceStrings [ "\n" ] [ " " ] ''
              --name ${adminAddress.name}
              --addr ${adminAddress.addr}
              --port ${adminAddress.port}
              ${optionalString (config.ghaf.givc.tls.mode == "static") "--cacert /run/givc/ca-cert.pem"}
              ${optionalString (config.ghaf.givc.tls.mode == "static") "--cert /run/givc/cert.pem"}
              ${optionalString (config.ghaf.givc.tls.mode == "static") "--key /run/givc/key.pem"}
              ${optionalString (config.ghaf.givc.tls.mode == "none") "--notls"}
            '';
        # Givc admin server configuration
        adminConfig = {
          inherit (adminAddress) name;
          addresses = [
            adminAddress
          ];
        };
      };
  };
}
