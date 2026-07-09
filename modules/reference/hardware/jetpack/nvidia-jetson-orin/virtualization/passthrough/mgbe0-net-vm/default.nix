# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Pass the AGX Orin's on-SoC ethernet controller (MGBE0, ethernet@6800000) to
# net-vm.
#
# Two channels:
#
#   data     vfio-platform hands the MAC's MMIO windows and IRQs to the guest.
#            DMA goes through the SMMU with IOVA = GPA; MGBE0 is alone in its
#            IOMMU group, so VFIO can take it cleanly.
#
#   control  every clock, reset and the power domain on the node is a <&bpmp ...>
#            reference and the guest has no BPMP. The guest's tegra_bpmp core is
#            redirected -- via the `virtual-pa` property on its /bpmp node -- to
#            a QEMU MMIO bridge, which forwards to /dev/bpmp-host on the host.
#
# The guest device tree is emitted by QEMU, never hand-written: `virt` exits
# outright if a dynamic sysbus device has no FDT binding, and a stale hand-rolled
# -dtb cannot describe the machine QEMU actually built.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.ghaf.hardware.nvidia.passthroughs.mgbe0_net_vm;
  virt = config.ghaf.hardware.nvidia.virtualization;
in
{
  _file = ./default.nix;

  options.ghaf.hardware.nvidia.passthroughs.mgbe0_net_vm.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Pass MGBE0 (ethernet@6800000) through to the Net-VM on NVIDIA Orin";
  };

  config = lib.mkIf cfg.enable {
    # The guest can only bring MGBE0 up through the BPMP host proxy.
    ghaf.hardware.nvidia.virtualization.host.bpmp.enable = true;

    services.udev.extraRules = ''
      # QEMU opens /dev/bpmp-host in instance_init, and microvm.nix runs it as
      # user microvm, group kvm. The char device is otherwise 0600 root:root.
      KERNEL=="bpmp-host", GROUP="kvm", MODE="0660"

      # vfio group nodes for the passed-through platform device.
      SUBSYSTEM=="vfio", GROUP="kvm"
    '';

    ghaf.hardware.definition.netvm.extraModules = [
      (
        { config, pkgs, ... }:
        let
          guestKernelVersion = config.boot.kernelPackages.kernel.version;
        in
        {
          # dwmac-tegra >= v6.13 (commit 426046e2d) reads the SMMU stream ID via
          # tegra_dev_iommu_get_stream_id(), which needs an iommu_fwspec. A QEMU
          # virt guest has no IOMMU, so probe would return -EINVAL. v6.12
          # hardcodes SID 0x6 -- MGBE0's actual stream ID -- and already carries
          # the Oct-2024 serdes bring-up fix (1cff6ff30) that v6.6 lacks.
          boot.kernelPackages = lib.mkForce pkgs.linuxPackages_6_12;

          # MANDATORY. The guest's tegra_bpmp core registers the BPMP clock and
          # power-domain providers, and at late_initcall the kernel calls
          # clk_disable_unused() / genpd_power_off_unused() to switch off
          # everything it does not claim. Through the BPMP guest proxy those
          # requests reach the REAL BPMP and would turn off clocks the host needs
          # (its eMMC controller among them), wedging the host. These params stop
          # the guest from ever issuing the disable requests. See the header of
          # bpmp-host-proxy.c. This is not optional, independent of the host
          # proxy's allow-list.
          boot.kernelParams = [
            "clk_ignore_unused"
            "pd_ignore_unused"
          ];

          boot.kernelPatches = [
            {
              name = "bpmp-virt proxy drivers";
              patch = virt.sourcesPatch;
            }
            {
              name = "bpmp-virt core hooks";
              patch =
                if lib.versionAtLeast guestKernelVersion "6.12" then
                  ../../common/bpmp-virt-common/patches/0001-bpmp-virt-hooks-6.12.patch
                else
                  ../../common/bpmp-virt-common/patches/0001-bpmp-virt-hooks.patch;
            }
            {
              name = "bpmp guest proxy kernel configuration";
              patch = null;
              structuredExtraConfig = with lib.kernel; {
                # tegra_bpmp_match[] only registers "nvidia,tegra186-bpmp" when one
                # of the 186/194/234 SoCs is enabled, and TEGRA_BPMP itself depends
                # on TEGRA_HSP_MBOX and TEGRA_IVC.
                ARCH_TEGRA = yes;
                ARCH_TEGRA_234_SOC = yes;
                TEGRA_HSP_MBOX = yes;
                TEGRA_IVC = yes;
                TEGRA_BPMP = yes;
                TEGRA_BPMP_GUEST_PROXY = yes;
                TEGRA_BPMP_HOST_PROXY = no;
              };
            }
          ];

          # Only this VM gets the QEMU that has the BPMP bridge and, crucially,
          # still has -device vfio-platform (removed upstream in 10.2).
          ghaf.virtualization.qemu.package = lib.mkForce pkgs.ghaf-qemu-bpmp;
        }
      )
    ];
  };
}
