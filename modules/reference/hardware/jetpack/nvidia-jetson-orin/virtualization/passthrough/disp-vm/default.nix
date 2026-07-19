# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Pass the AGX Orin's display path to a SECOND microvm, disp-vm, so it can run
# concurrently with gpu-vm (experiment/orin-two-vm-host1x, Step 2: concurrent
# two-VM build). disp-vm is DISPLAY-ONLY: no host1x, no gpu, no media. It owns
# exactly 3 physical devices -- 1:1 vfio-platform, mmio-base -- ALL already
# declared+reserved by the gpu-vm passthrough module's
# gpu_passthrough_overlay.dts (the `_p` dummy nodes + reserved-memory): the
# scanout carveout, and the two display keyhole MMIO windows. No new host
# carveouts are added here.
#
# The companion gpu-vm, in this concurrent build, runs with
# host1xExperiment = "compute-with-host1x": it keeps host1x/gpu/media/shim,
# shrinks its own guest RAM bank1 to 0x80000000..0xb0000000, and drops its
# scanout claim -- releasing 0xb0000000 for disp-vm below. See
# ../gpu-vm/default.nix and orin-agx.nix.
#
# Guest RAM design (the crux -- see tegra234-dispvm.dts): disp-vm's general
# guest RAM (memory@80000000, bank1 only, 0x80000000..0xb0000000) is plain
# QEMU -m emulated RAM, NOT a 1:1 host carveout -- disp-vm claims no vm_cma_p
# device, so there is no host-PA collision with gpu-vm's own (disjoint) use of
# the same GPA range in its own, separate QEMU process. Only the scanout
# region (0xb0000000, real 1:1 GPA=HPA) and the display MMIO keyholes are
# physical passthrough.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.ghaf.hardware.nvidia.passthroughs.disp_vm;

  # Host-side virtualization config (sourcesPatch), same pattern as gpu-vm.
  virt = config.ghaf.hardware.nvidia.virtualization;

  # disp-vm's ONLY physical devices: the scanout carveout (1:1 GPA=HPA via
  # mmio-base) and the two display keyhole MMIO windows. No engines
  # (gpu/host1x/vic/nvdec/nvjpg) and no vm_cma_p/vm_hs_p/vm_cma_vram_p -- those
  # stay with gpu-vm as host1x owner. See ../gpu-vm/gpu_passthrough_overlay.dts
  # for where scanout_p/disp_caps_pt/disp_chan_pt are declared+reserved.
  reservedMem = [
    {
      dev = "b0000000.scanout_p";
      base = "0xb0000000";
    }
    # disp-vm guest RAM, 1:1 GPA=HPA carveout (0xb8000000..0x100000000, 1.125GB).
    # QEMU -m does not reliably back the guest in this passthrough setup (its virt
    # RAM base != the DTB memory@); like gpu-vm's vm_cma, disp-vm gets real RAM
    # from this carveout instead. Disjoint from every gpu-vm carveout.
    {
      dev = "b8000000.dispram_lo_p";
      base = "0xb8000000";
    }
    {
      dev = "200000000.dispram_hi_p";
      base = "0x200000000";
    }
  ];
  dispCaps = [
    {
      dev = "13830000.disp_caps_pt";
      base = "0x66230000";
    }
    {
      dev = "13870000.disp_chan_pt";
      base = "0x66270000";
    }
  ];
  allDevs = map (r: r.dev) (reservedMem ++ dispCaps);

  vfioArgs = lib.concatMap (r: [
    "-device"
    "vfio-platform,host=${r.dev},mmio-base=${r.base}"
  ]) (reservedMem ++ dispCaps);

  # Guest device tree, compiled to dtb. Mirrors ../gpu-vm/default.nix's
  # gpuvm-dtb derivation; reuses gpu-vm's vendored NVIDIA-only dt-bindings
  # headers (dt-bindings/interrupt/tegra234-irq.h,
  # dt-bindings/p2u/tegra234-p2u.h) rather than duplicating them.
  dispvm-dtb = pkgs.stdenv.mkDerivation {
    name = "dispvm-dtb";
    src = ./tegra234-dispvm.dts;
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.buildPackages.dtc
      pkgs.buildPackages.gcc
    ];
    buildPhase =
      let
        kernel = config.boot.kernelPackages.kernel;
        mainInc = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/source/include";
      in
      ''
        cp $src tegra234-dispvm.dts
        $CC -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
          -I${mainInc} \
          -I${../gpu-vm/nv-dt-bindings} \
          tegra234-dispvm.dts > preprocessed.dts
        dtc -I dts -O dtb -o tegra234-dispvm.dtb preprocessed.dts
      '';
    installPhase = ''
      mkdir -p $out
      cp tegra234-dispvm.dtb $out/
    '';
  };
in
{
  _file = ./default.nix;

  options.ghaf.hardware.nvidia.passthroughs.disp_vm.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Pass the Tegra234 display path through to a second microvm, disp-vm, on NVIDIA Orin AGX";
  };

  config = lib.mkIf cfg.enable {
    # Register the disp-vm microvm now that its extraModules are populated below.
    ghaf.virtualization.microvm.dispvm.enable = true;

    # BPMP allow-list, host bpmp.enable, host graphics/nvpmodel/nvidia-docker
    # disable, host1x/gpu kernel-module blacklist, and the
    # gpu_passthrough_overlay.dts device-tree overlay registration are ALL
    # already provided by ../gpu-vm/default.nix (ghaf.hardware.nvidia.passthroughs.gpu_vm),
    # unconditionally on that module's cfg.enable -- not gated by
    # host1xExperiment. disp_vm is only ever enabled alongside gpu_vm in this
    # design (see orin-agx.nix), so none of that is duplicated here.

    systemd.services.bindDispVm = {
      description = "Bind disp-vm's display devices to the vfio-platform driver";
      wantedBy = [ "multi-user.target" ];
      before = [ "microvm@disp-vm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
        ExecStartPre = map (
          d:
          "${pkgs.bash}/bin/bash -c \"echo vfio-platform > /sys/bus/platform/devices/${d}/driver_override\""
        ) allDevs;
        # Idempotent bind: only bind a device not already on vfio-platform.
        # A blanket "|| true" would mask a genuinely missing device; this skips
        # the already-bound case (re-bind writes EBUSY) while still failing hard
        # if the device is absent (driver symlink stays non-vfio-platform).
        ExecStart = map (
          d:
          "${pkgs.bash}/bin/bash -c '"
          + "cur=$(basename \"$(readlink -f /sys/bus/platform/devices/${d}/driver 2>/dev/null)\"); "
          + "if [ \"$cur\" != vfio-platform ]; then echo ${d} > /sys/bus/platform/drivers/vfio-platform/bind; fi'"
        ) allDevs;
      };
    };
    # Requires (not just after): after= alone never STARTS the bind service, so
    # a manual/socket start of the VM could race past unbound devices.
    systemd.services."microvm@disp-vm" = {
      after = [ "bindDispVm.service" ];
      requires = [ "bindDispVm.service" ];
      # disp-vm is the DCE display owner: opt in to the QEMU DCE bridge so it
      # (and only it, among the display-less VMs) opens /dev/dce-host. See the
      # GHAF_DCE_GUEST gate in ghaf-qemu-bpmp patch 0002.
      environment.GHAF_DCE_GUEST = "1";
    };

    # Guest configuration for the disp-vm microvm: the proven
    # display-no-host1x guest (Exp B, hardware-validated 2026-07-19) --
    # nvidia-modeset/nvidia-drm/tegra-dce/dce-guest-proxy, the no-syncpt
    # patch (applied unconditionally here: disp-vm is always display-only),
    # the DCE guest-proxy postPatch splice, nvidia-drm.modeset=1,
    # hardware.graphics, the diagnostic guest ssh key, and the earlycon
    # params. Patches are referenced from ../gpu-vm/patches rather than
    # duplicated.
    # ponytail: the kmscube/mesa-demos/drm_info userspace debug tools and the
    # GPU-falcon l4t-firmware from gpu-vm's extraModules are NOT carried here
    # (display bring-up doesn't need them; gpu-vm's copy is unaffected). Add
    # back if interactive HW debugging on disp-vm needs a KMS test client.
    ghaf.hardware.definition.dispvm.extraModules = [
      (
        { config, pkgs, ... }:
        {
          # NVIDIA/Jetson graphics userspace (EGL/GLES/GBM) via
          # /run/opengl-driver, mirroring ../gpu-vm/default.nix and
          # jetpack-nixos modules/graphics.nix.
          hardware.graphics = {
            enable = true;
            package = pkgs.symlinkJoin {
              name = "l4t-3d-core-egl-gbm-1.1.3";
              paths = [
                (pkgs.egl-gbm.overrideAttrs (o: {
                  patches = (o.patches or [ ]) ++ [
                    ../gpu-vm/patches/userspace/egl-gbm-single-device-fallback.patch
                  ];
                }))
                pkgs.nvidia-jetpack.l4t-3d-core
              ];
              postBuild = ''
                rm -f $out/share/egl/egl_external_platform.d/nvidia_gbm.json
              '';
            };
            extraPackages =
              (with pkgs.nvidia-jetpack; [
                l4t-core
                l4t-cuda
                l4t-nvsci
                l4t-wayland
              ])
              ++ [
                (pkgs.symlinkJoin {
                  name = "l4t-gbm-sans-egl-gbm";
                  paths = [ pkgs.nvidia-jetpack.l4t-gbm ];
                  postBuild = ''
                    rm -f $out/lib/libnvidia-egl-gbm.so*
                    rm -f $out/share/egl/egl_external_platform.d/nvidia_gbm.json
                  '';
                })
              ];
          };
          # libEGL_nvidia.so.0 discovers its EGL platform modules here.
          environment.etc."egl/egl_external_platform.d".source =
            "${pkgs.addDriverRunpath.driverLink}/share/egl/egl_external_platform.d/";

          # Guest kernel = vanilla 6.12 + jetpack OOT overlay (Bring-Your-Own-
          # Kernel), same display passthrough patch set as gpu-vm's
          # display-no-host1x mode, referenced from ../gpu-vm/patches.
          boot.kernelPackages = lib.mkForce (
            (pkgs.linuxPackages_6_12.extend pkgs.nvidia-jetpack.kernelPackagesOverlay).extend (
              _final: prev: {
                nvidia-oot-modules = prev.nvidia-oot-modules.overrideAttrs (o: {
                  patches = (o.patches or [ ]) ++ [
                    ../gpu-vm/patches/0001-gpu-add-support-for-passthrough.patch
                    ../gpu-vm/patches/0002-add-support-for-gpu-display-passthrough.patch
                    ../gpu-vm/patches/0003-add-support-for-display-passthrough.patch
                    ../gpu-vm/patches/0005-force-niso-display-surfaces-contiguous.patch
                    ../gpu-vm/patches/0006-dce-addresses-cpu-phys-high-iova.patch
                    ../gpu-vm/patches/0008-fix-dual-mode-honor-rm-connect-state.patch
                    ../gpu-vm/patches/0009-core-notifier-plain-write-no-awaken.patch
                    ../gpu-vm/patches/0020-synthesize-boot-hotplug-long-pulse.patch
                    ../gpu-vm/patches/0010-dce-drop-r5-completion-event.patch
                    ../gpu-vm/patches/0011-window-notifier-plain-write.patch
                    ../gpu-vm/patches/0013-drm-vblank-flip-completion.patch
                    # disp-vm is always display-only: the no-syncpt NVKMS path
                    # applies unconditionally (unlike gpu-vm, where it's gated
                    # on the displayOnly experiment arm).
                    ../gpu-vm/patches/0021-nvkms-force-no-syncpt-support.patch
                  ];
                  postPatch = (o.postPatch or "") + ''
                    patch -p1 -d nvidia-oot < ${../../common/dce-virt-common/patches/0001-dce-virt-hooks.patch}
                    patch -p1 -d nvidia-oot < ${../../common/dce-virt-common/patches/0002-dce-client-ipc-inject.patch}
                    install -D ${../../common/dce-virt-common/sources/drivers/platform/tegra/dce-guest-proxy/dce-guest-proxy.c} \
                      nvidia-oot/drivers/platform/tegra/dce/dce-guest-proxy.c
                    echo 'obj-m += dce-guest-proxy.o' >> nvidia-oot/drivers/platform/tegra/dce/Makefile
                  '';
                });
              }
            )
          );

          # nvidia-drm.modeset=1 + fbdev=1: bring up NVIDIA KMS + fbcon, which
          # triggers the modeset that drives the DCE handshake through the
          # proxy to scanout. See ../gpu-vm/default.nix for the full rationale.
          boot.kernelParams = [
            "clk_ignore_unused"
            "pd_ignore_unused"
            "nvidia-drm.modeset=1"
            "log_buf_len=16M"
            "drm.vblankoffdelay=0"
            "nvidia-drm.fbdev=1"
          ];

          boot.extraModulePackages = [ config.boot.kernelPackages.nvidia-oot-modules ];
          boot.kernelModules = [
            "nvmap"
            "tegra-dce"
            "dce-guest-proxy"
            "nvidia-modeset"
            "nvidia-drm"
          ];

          boot.kernelPatches = [
            {
              name = "tegra fixed chip id";
              patch = ../gpu-vm/patches/0004-tegra-fixed-chip-id.patch;
            }
            {
              name = "bpmp-virt proxy drivers";
              patch = virt.sourcesPatch;
            }
            {
              name = "bpmp-virt core hooks";
              patch = ../../common/bpmp-virt-common/patches/0001-bpmp-virt-hooks-6.12.patch;
            }
            {
              name = "bpmp guest proxy kernel configuration";
              patch = null;
              structuredExtraConfig = with lib.kernel; {
                ARCH_TEGRA = yes;
                ARCH_TEGRA_234_SOC = yes;
                TEGRA_HSP_MBOX = yes;
                TEGRA_IVC = yes;
                TEGRA_BPMP = yes;
                TEGRA_BPMP_GUEST_PROXY = yes;
                TEGRA_BPMP_HOST_PROXY = no;
                CLK_TEGRA_BPMP = yes;
                RESET_TEGRA_BPMP = yes;
                PM_GENERIC_DOMAINS = yes;
                ARM64_PMEM = yes;
                # DIAGNOSTIC: allow guest /dev/mem access to the 1:1 scanout
                # carveout and claimed display MMIO. Drop for release.
                STRICT_DEVMEM = lib.mkForce no;
                IO_STRICT_DEVMEM = lib.mkForce (option no);
              };
            }
          ];

          ghaf.virtualization.qemu.package = lib.mkForce pkgs.ghaf-qemu-bpmp-gpu;

          microvm.qemu.extraArgs = [
            "-dtb"
            "${dispvm-dtb}/tegra234-dispvm.dtb"
          ]
          ++ vfioArgs;
        }
      )
    ];
  };
}
