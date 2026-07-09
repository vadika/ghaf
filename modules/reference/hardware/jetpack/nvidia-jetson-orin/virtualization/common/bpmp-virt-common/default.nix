# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ lib, config, ... }:
let
  cfg = config.ghaf.hardware.nvidia.virtualization;
  kernelVersion = config.boot.kernelPackages.kernel.version;
in
{
  _file = ./default.nix;

  options.ghaf.hardware.nvidia.virtualization.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Enable virtualization support for NVIDIA Orin

      This option is an implementation level detail and is toggled automatically
      by modules that need it. Manually enabling this option is not recommended in
      release builds.
    '';
  };

  config = lib.mkIf cfg.enable {
    boot.kernelPatches = [
      {
        name = "Added Configurations to Support Vda";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          PCI_STUB = lib.mkDefault yes;
          VFIO = lib.mkDefault yes;
          VIRTIO_PCI = lib.mkDefault yes;
          VIRTIO_MMIO = lib.mkDefault yes;
          HOTPLUG_PCI = lib.mkDefault yes;
          PCI_DEBUG = lib.mkDefault yes;
          PCI_HOST_GENERIC = lib.mkDefault yes;
          VFIO_IOMMU_TYPE1 = lib.mkDefault yes;
          HOTPLUG_PCI_ACPI = lib.mkDefault yes;
          PCI_HOST_COMMON = lib.mkDefault yes;
          VFIO_PLATFORM = lib.mkDefault yes;
          TEGRA_BPMP_GUEST_PROXY = lib.mkDefault no;
          TEGRA_BPMP_HOST_PROXY = lib.mkDefault no;
        };
      }
      {
        name = "Vfio_platform Reset Required False";
        patch = ./patches/0002-vfio_platform-reset-required-false.patch;
      }
      # The bpmp-virt drivers. The 6.6 variant is self-contained: it adds
      # drivers/firmware/tegra/bpmp-{host,guest}-proxy/ along with the
      # Kconfig/Makefile wiring and the bpmp.c / bpmp-tegra186.c hooks that read
      # the `virtual-pa` DT property. It therefore subsumes the old
      # 0003-bpmp-support-bpmp-virt and 0005-bpmp-overlay patches, which exist
      # only for the 5.15 variant's out-of-tree drivers/ layout.
      (
        if lib.versionAtLeast kernelVersion "6.6" then
          {
            name = "Add bpmp-virt modules";
            patch = ./patches/0001-Add-bpmp-virt-kernel-modules-for-kernel-6.6.patch;
          }
        else
          {
            name = "Add bpmp-virt modules";
            patch = ./patches/0004-bpmp-virt-drivers-5-15.patch;
          }
      )
    ]
    ++ lib.optionals (lib.versionAtLeast kernelVersion "6.6") [
      {
        # Bring-up only: flips BPMP_HOST_ALLOWS_ALL so the host proxy accepts
        # every clock/reset/power domain instead of consulting the allowed-*
        # properties in bpmp_host_overlay.dts.
        # TODO: drop once the allow-list covers everything net-vm requests.
        name = "Bpmp-host: allows all domains";
        patch = ./patches/0002-Bpmp-host-allows-all-domains.patch;
      }
    ];

    boot.kernelParams = [
      "vfio_iommu_type1.allow_unsafe_interrupts=1"
      "arm-smmu.disable_bypass=0"
    ];
  };
}
