# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Reference hardware modules
#
{ pkgs, lib, ... }:
{
  _file = ./orin-agx.nix;

  imports = [
    ../../../../common/services/hwinfo
    # Task 1d DCE display-proxy HOST integration (AGX only). Keeps gpu_vm
    # enabled, runs the host headless, force-loads tegra-dce so the host owns
    # the real DCE R5, and builds + loads the dce-host-proxy .ko (with an
    # injected nvidia,dce-host-proxy DT node) so the guest can drive the panel
    # through the host-owned DCE. AGX-only on purpose -- do not hoist into a
    # shared orin.nix.
    ../nvidia-jetson-orin/virtualization/common/dce-virt-common/dce-probe-host.nix
  ];

  ghaf = {
    # Enable hardware info generation on host
    services.hwinfo = {
      enable = true;
      outputDir = "/var/lib/ghaf-hwinfo";
    };

    hardware = {
      nvidia.orin = {
        enable = true;
        kernelVersion = "upstream-6-6";
        somType = "agx";
        agx.enableNetvmWlanPCIPassthrough = true;
        carrierBoard = "devkit";
        # AGX devkit boots rootfs from eMMC.
        flashScriptOverrides = {
          deviceDisk = "mmcblk0";
          deviceDiskEspPartition = "mmcblk0p1";
          deviceDiskRootfsPartition = "mmcblk0p2";
        };
      };

      # AGX has the on-SoC MGBE0 ethernet controller (Aquantia PHY on the
      # p3737 carrier); pass it through to net-vm. Orin NX has no MGBE0.
      nvidia.passthroughs.mgbe0_net_vm.enable = true;
      nvidia.passthroughs.gpu_vm.enable = true;
      # Branch-only host1x-ownership experiment selector (experiment/orin-two-vm-host1x).
      # Flip to "compute-no-host1x" / "display-no-host1x" for the respective
      # feasibility gate, then back to "off" when done. Never promote off "off".
      nvidia.passthroughs.gpu_vm.host1xExperiment = "off";

      # Net VM hardware-specific modules - use hardware.definition for composition model
      definition.netvm.extraModules = [
        {
          # The Nvidia Orin hardware dependent configuration is in
          # modules/reference/hardware/jetpack Please refer to that
          # section for hardware dependent netvm configuration.

          # Wireless Configuration. Orin AGX has WiFi enabled where Orin NX does
          # not.

          # To enable or disable wireless
          networking.wireless.enable = true;

          # For WLAN firmwares
          hardware = {
            enableRedistributableFirmware = true;
            wirelessRegulatoryDatabase = true;
          };

        }
        # Hardware info guest support
        {
          imports = [ ../../../../common/services/hwinfo ];
          ghaf.services.hwinfo-guest.enable = true;
        }
        # Ensure hardware info is generated before net-vm starts
        {
          systemd.services."microvm@net-vm" = {
            wants = [ "ghaf-hwinfo-generate.service" ];
            after = [ "ghaf-hwinfo-generate.service" ];
          };
        }
        # QEMU arguments to pass hardware info via fw_cfg
        {
          microvm.qemu.extraArgs = [
            "-fw_cfg"
            "name=opt/com.ghaf.hwinfo,file=/var/lib/ghaf-hwinfo/hwinfo.json"
          ];
        }
        ../../../personalize
        { ghaf.reference.personalize.keys.enable = true; }
      ];
    };
  };

  # To enable or disable wireless
  networking.wireless.enable = true;

  # DIAGNOSTIC (AST verification): relax STRICT_DEVMEM so the notifier carveout
  # page can be read back from the host during a guest modeset. Drop for release.
  # iomem=relaxed only lifts IO_STRICT_DEVMEM (claimed MMIO); RAM-backed pages
  # (the notifier carveout) additionally need CONFIG_STRICT_DEVMEM=n.
  boot.kernelParams = [ "iomem=relaxed" ];
  boot.kernelPatches = [
    {
      name = "diagnostic-strict-devmem-off";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        STRICT_DEVMEM = lib.mkForce no;
        IO_STRICT_DEVMEM = lib.mkForce no;
      };
    }
  ];

  hardware = {
    # Device Tree
    deviceTree.name = "tegra234-p3737-0000+p3701-0000-nv.dtb";
    nvidia-jetpack = {
      enable = true;
      som = "orin-agx";
      carrierBoard = "devkit";
      modesetting.enable = true;
      flashScriptOverrides = {
        flashArgs = [
          "-r"
          "jetson-agx-orin-devkit"
          "mmcblk0p1"
        ];
      };
      firmware.uefi = {
        logo = "${pkgs.ghaf-artwork}/1600px-Ghaf_logo.svg";
        edk2NvidiaPatches = [
          # DCE display proxy wants UEFI to reset the display on exit (clean
          # controller for the guest nvdisplay) + disable the EFI FB (panics at
          # boot with HDMI connected). The carried patch is stale (April-2024
          # edk2-nvidia; hunks reject against 36.5.0's NvDisplayControllerDxe.c).
          # Re-enable once rebased -- flash without it boots fine (no panic seen).
          # ./edk2-nvidia-always-reset-display.patch
        ];
      };
    };
  };
}
