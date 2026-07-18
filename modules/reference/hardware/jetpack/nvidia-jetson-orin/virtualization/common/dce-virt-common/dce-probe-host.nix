# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Task 1d -- DCE display-proxy HOST integration (AGX only).
#
# The companion to gpu-vm's guest overlay (../../passthrough/gpu-vm). The guest
# takes display@13800000 and drives the panel through a synthetic DCE proxy; the
# HOST keeps the REAL dce@d800000 and owns its R5. This module makes the host:
#   - stay headless (no COSMIC/graphics, display RM blacklisted) so the host
#     CCPLEX never touches display@13800000 -- only the guest CCPLEX and the
#     host R5 share it;
#   - force-load tegra-dce so it bootstraps and owns the real DCE R5;
#   - build + load the dce-host-proxy .ko and inject a "nvidia,dce-host-proxy"
#     DT node so the proxy binds and creates /dev/dce-host (the QEMU DCE bridge
#     relays the guest's DCE IPC through it to the R5);
#   - keep gpu_vm ENABLED (unlike the Phase-0 spike, which forced it off).
#
# AGX-only on purpose -- imported from agx/orin-agx.nix, never hoisted into a
# shared orin.nix.
{
  lib,
  pkgs,
  ...
}:
let
  # Inject a bare "nvidia,dce-host-proxy" node so the dce-host-proxy platform
  # driver binds and creates /dev/dce-host. The driver reads no reg/vpa -- it
  # relays via tegra-dce's exported CPU_RM client API -- so the node only needs
  # the compatible. Mirrors bpmp-virt-host's bpmp_host_overlay pattern (a DT
  # overlay instead of a patch against NVIDIA's device trees).
  dceHostOverlay = pkgs.writeText "dce_host_overlay.dts" ''
    /dts-v1/;
    /plugin/;
    / {
        overlay-name = "DCE host proxy";
        compatible = "nvidia,tegra234";
        fragment@0 {
            target-path = "/";
            __overlay__ {
                dce_host_proxy: dce_host_proxy {
                    compatible = "nvidia,dce-host-proxy";
                    status = "okay";
                };
            };
        };
    };
  '';
in
{
  _file = ./dce-probe-host.nix;

  # The host display driver is blacklisted (headless), so nothing in Linux claims
  # the display clocks/power-domains (dpaux0, SOR, disp, the DP PLLs) or the DCE.
  # Without these, clk_disable_unused()/genpd_disable_unused() at late_initcall
  # gate them off as "unused" -- but the host-owned DCE R5 needs them ON to do
  # DP-AUX transactions (read EDID) and drive the SOR (physical output). Symptom
  # when gated: DP connector reads "connected" (HPD survives) but EDID is 0 bytes
  # (AUX unclocked) and no mode is ever set (SOR unclocked) -> no signal. Keep all
  # unused clocks + power-domains on so the R5's display hardware stays alive.
  boot.kernelParams = [
    "clk_ignore_unused"
    "pd_ignore_unused"
  ];

  # Host runs headless: nothing may bring up COSMIC/graphics and register a
  # CPU_RM display client on the host, and the host CCPLEX must never program
  # display@13800000 (it belongs to the guest).
  ghaf.profiles.graphics.enable = lib.mkForce false;

  # Host kernel = the base jetpack-nixos assembles for orin-agx
  # (pkgs.nvidia-jetpack.kernelPackages), plus dce-host-proxy spliced into
  # nvidia-oot-modules. mkForce is required: jetpack-nixos's own
  # hardware.nvidia-jetpack module already sets boot.kernelPackages at normal
  # priority.
  boot.kernelPackages = lib.mkForce (
    (pkgs.nvidia-jetpack.kernelPackages.extend pkgs.nvidia-jetpack.kernelPackagesOverlay).extend (
      _final: prev: {
        nvidia-oot-modules = prev.nvidia-oot-modules.overrideAttrs (o: {
          # nvidia-oot-modules' src is the combined l4t-oot-modules-sources tree
          # (nvidia-oot/, nvgpu/, nvdisplay/, ... each nested under its own
          # project name). dce-host-proxy relays a guest's DCE IPC to the real
          # DCE; it links the same EXPORT_SYMBOL'd DCE client API as tegra-dce,
          # so it must build INSIDE nvidia-oot (not the kernel tree). Flatten its
          # source into the dce/ dir (whose Makefile ccflags already resolve the
          # public dce-client-ipc.h include) and add it as its own obj-m .ko.
          # dtc + xxd: dce-iso-anchor embeds its runtime DT overlay as a C
          # array (compiled with -@ so &smmu_iso resolves against the live
          # tree's __symbols__ at of_overlay_fdt_apply time).
          nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [
            pkgs.buildPackages.dtc
            pkgs.buildPackages.unixtools.xxd
          ];
          postPatch = (o.postPatch or "") + ''
            install -D ${./sources/drivers/platform/tegra/dce-host-proxy/dce-host-proxy.c} \
              nvidia-oot/drivers/platform/tegra/dce/dce-host-proxy.c
            install -D ${./sources/drivers/platform/tegra/dce-host-proxy/dce-host-proxy.h} \
              nvidia-oot/drivers/platform/tegra/dce/dce-host-proxy.h
            echo 'obj-m += dce-host-proxy.o' >> nvidia-oot/drivers/platform/tegra/dce/Makefile

            install -D ${./sources/drivers/platform/tegra/dce-iso-anchor/dce-iso-anchor.c} \
              nvidia-oot/drivers/platform/tegra/dce/dce-iso-anchor.c
            dtc -@ -I dts -O dtb -o dce-iso-anchor.dtbo \
              ${./sources/drivers/platform/tegra/dce-iso-anchor/dce-iso-anchor.dts}
            xxd -i -n dce_iso_anchor_dtbo dce-iso-anchor.dtbo \
              > nvidia-oot/drivers/platform/tegra/dce/dce-iso-anchor-dtbo.h
            echo 'obj-m += dce-iso-anchor.o' >> nvidia-oot/drivers/platform/tegra/dce/Makefile
          '';
        });
      }
    )
  );

  # boot.extraModulePackages: not needed here. jetpack-nixos' own
  # hardware.nvidia-jetpack module already sets
  # `boot.extraModulePackages = [ config.boot.kernelPackages.nvidia-oot-modules ]`
  # for jetpackAtLeast "6", and that reference resolves against the forced
  # boot.kernelPackages above, so dce-host-proxy.ko rides along automatically.

  # Blacklist the host display RM stack so no CPU_RM display client is
  # registered on the host and the host never programs display@13800000.
  # tegra-dce is deliberately NOT blacklisted (the host must keep bootstrapping
  # and owning the DCE R5). gpu-vm's own default.nix additionally blacklists
  # nvgpu/host1x; the two lists merge.
  boot.blacklistedKernelModules = [
    "nvidia"
    "nvidia_modeset"
    "nvidia_drm"
    "tegra_drm"
  ];

  # nvidia-oot modules do NOT autoload from a DT compatible match. Force-load
  # tegra-dce (binds the real d800000.dce and drives the R5 bootstrap to LOCKED)
  # and dce-host-proxy (binds the injected node above and creates /dev/dce-host).
  # dce-host-proxy links tegra-dce's exported symbols, so modprobe orders
  # tegra-dce first.
  boot.kernelModules = [
    "tegra-dce"
    "dce-host-proxy"
    # smmu_iso SID-1 anchor: gives the FE's ISO scanout stream a translating
    # domain with the DCE high-IOVA -> carveout maps (panel is otherwise
    # lit-but-black under passthrough). Applies its own DT overlay at load.
    "dce-iso-anchor"
  ];

  # /dev/dce-host is opened by the patched QEMU (running as the microvm user in
  # the kvm group) to relay the guest's DCE IPC. Grant the kvm group access,
  # mirroring the bpmp-host / vfio rule in gpu-vm's default.nix.
  services.udev.extraRules = ''
    KERNEL=="dce-host", GROUP="kvm", MODE="0660"
  '';

  hardware.deviceTree.enable = true;
  hardware.deviceTree.overlays = [
    {
      name = "dce_host_overlay";
      dtsFile = dceHostOverlay;
    }
  ];
}
