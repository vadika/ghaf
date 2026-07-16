# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Pass the AGX Orin's on-SoC GPU (ga10b) and supporting engines to gpu-vm.
#
# Data:    vfio-platform hands the GPU + host1x/vic/nvdec/nvjpg/dce + three
#          reserved-memory carveouts to the guest. The carveouts use mmio-base
#          for 1:1 GPA=HPA (large regions; see ghaf-qemu-bpmp-gpu).
# Control: clocks/resets/power-domains route through the BPMP host proxy, gated
#          by the union allow-list (ids enumerated on hardware, Task 8).
#
# Display (13800000.display) is carried but known non-functional (no video
# output). It must not destabilize GPU compute.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.ghaf.hardware.nvidia.passthroughs.gpu_vm;
  # Host-side virtualization config (sourcesPatch is defined here, not on the
  # guest). Captured from the host scope so the guest extraModules below can
  # reference it without the inner `config` shadow picking up the guest config.
  virt = config.ghaf.hardware.nvidia.virtualization;

  # Devices passed to gpu-vm. Reserved-memory carveouts take an explicit
  # mmio-base for 1:1 GPA=HPA; engines use the default mapping.
  reservedMem = [
    {
      dev = "60000000.vm_hs_p";
      base = "0x60000000";
    }
    {
      dev = "80000000.vm_cma_p";
      base = "0x80000000";
    }
    {
      dev = "100000000.vm_cma_vram_p";
      base = "0x100000000";
    }
  ];
  # GPU compute engines only. display@13800000 and dce@d800000 (the display
  # pipeline) are NOT passed through: display passthrough is non-functional
  # (carried, not fixed) and yanking the display/dce out from under the host's
  # still-active display stack panicked the host at boot (OP-TEE display TA +
  # fatal exception in interrupt). They stay with the host. GPU compute needs
  # only the GPU + host1x + the multimedia engines.
  engines = [
    "17000000.gpu"
    "13e00000.host1x_pt"
    "15340000.vic"
    "15480000.nvdec"
    "15540000.nvjpg"
  ];
  allDevs = (map (r: r.dev) reservedMem) ++ engines;

  vfioArgs =
    (lib.concatMap (r: [
      "-device"
      "vfio-platform,host=${r.dev},mmio-base=${r.base}"
    ]) reservedMem)
    ++ (lib.concatMap (d: [
      "-device"
      "vfio-platform,host=${d}"
    ]) engines);

  # Guest device tree, compiled to dtb. The tegra234 dt-bindings come from the
  # guest kernel's mainline headers -- their TEGRA234_CLK_*/RESET_*/
  # POWER_DOMAIN_* values were verified to equal the ids the SoC's live device
  # tree uses (GPUSYS=304 GPC0CLK=41 GPC1CLK=236, RESET_GPU=19, PD_GPU=35), so
  # the guest requests exactly the bpmp ids the host proxy allow-list grants.
  # Two headers are NVIDIA-only (absent from mainline) and are vendored under
  # ./nv-dt-bindings: dt-bindings/interrupt/tegra234-irq.h and
  # dt-bindings/p2u/tegra234-p2u.h.
  gpuvm-dtb = pkgs.stdenv.mkDerivation {
    name = "gpuvm-dtb";
    src = ./tegra234-gpuvm.dts;
    dontUnpack = true;
    # Build-platform tools: this preprocesses + compiles a device tree at build
    # time (arch-agnostic text), so it must run on the builder, not the aarch64
    # target -- use buildPackages so `gcc` is the native compiler in a cross build.
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
        cp $src tegra234-gpuvm.dts
        # $CC is set by stdenv to the toolchain's compiler (triple-prefixed in a
        # cross build, where a bare `gcc` does not exist); -E only preprocesses,
        # so the target triple is irrelevant to the text output.
        $CC -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
          -I${mainInc} \
          -I${./nv-dt-bindings} \
          tegra234-gpuvm.dts > preprocessed.dts
        dtc -I dts -O dtb -o tegra234-gpuvm.dtb preprocessed.dts
      '';
    installPhase = ''
      mkdir -p $out
      cp tegra234-gpuvm.dtb $out/
    '';
  };
in
{
  _file = ./default.nix;

  options.ghaf.hardware.nvidia.passthroughs.gpu_vm.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Pass the Tegra234 GPU and engines through to gpu-vm on NVIDIA Orin AGX";
  };

  config = lib.mkIf cfg.enable {
    ghaf.hardware.nvidia.virtualization.host.bpmp.enable = true;

    # Register the gpu-vm microvm now that its extraModules are populated below.
    ghaf.virtualization.microvm.gpuvm.enable = true;

    # GPU BPMP allow-list contribution. Raw bpmp ids read from the live host
    # device tree (od -t u4 --endian=big on each node's clocks/resets/
    # power-domains, keeping only the cells whose provider phandle is &bpmp).
    # Union across the passed-through COMPUTE engines:
    #   gpu@17000000    clocks 304 41 236   reset 19    pd 35
    #   host1x@13e00000 clocks 46 1
    #   vic@15340000    clock 167           reset 113   pd 29
    #   nvdec@15480000  clocks 83 40 154    reset 44    pd 23
    #   nvjpg@15540000  clock 20            reset 10    pd 36
    # display@13800000 and dce@d800000 are deliberately EXCLUDED: display
    # passthrough is non-functional (carried, not fixed) and its ~60 PLL clocks
    # would needlessly widen the host-safety boundary. As with MGBE0, the host
    # proxy logging "clock not allowed" for probed parent clocks at guest boot is
    # the boundary working, not a defect. If GPU init fails on a specific denied
    # id (Task 10), add only that id here.
    ghaf.hardware.nvidia.virtualization.host.bpmp.allow = {
      clocks = [
        1
        20
        40
        41
        46
        83
        154
        167
        236
        304
      ];
      resets = [
        10
        19
        44
        113
      ];
      powerDomains = [
        23
        29
        35
        36
      ];
    };

    services.udev.extraRules = ''
      KERNEL=="bpmp-host", GROUP="kvm", MODE="0660"
      SUBSYSTEM=="vfio", GROUP="kvm"
    '';

    # The Orin profile runs the COSMIC desktop natively on the host, driving this
    # same GPU. With the GPU passed through to gpu-vm the host must not touch it:
    # leaving host graphics on faulted the host the instant bindGpuVm handed the
    # GPU/host1x to vfio. Turn the host desktop off when gpu_vm is enabled.
    ghaf.profiles.graphics.enable = lib.mkForce false;

    # The stock nvpmodel profiles require sysfs interfaces provided by the host
    # GPU driver. Those interfaces do not exist while vfio-platform owns the
    # GPU, causing nvpmodel.service to fail and restart indefinitely. Power
    # policy should eventually be split so the host controls CPU/EMC limits and
    # gpu-vm controls GPU limits.
    services.nvpmodel.enable = lib.mkForce false;

    # NVIDIA Docker cannot use the GPU while vfio-platform assigns it to
    # gpu-vm. Containerized GPU workloads should eventually run inside gpu-vm
    # instead of keeping the host NVIDIA container stack enabled.
    ghaf.virtualization.nvidia-docker.daemon.enable = lib.mkForce false;

    # Release the GPU + host1x compute stack from the host so vfio-platform binds
    # pristine devices (as MGBE0 does). host1x is blacklisted too because the GPU
    # and the multimedia engines (vic/nvdec/nvjpg) are its clients -- without the
    # host1x bus up, the host never binds them, so they hand over cleanly.
    boot.blacklistedKernelModules = [
      "nvgpu"
      "nvidia"
      "nvidia_modeset"
      "nvidia_drm"
      "tegra_drm"
      "host1x"
    ];

    systemd.services.bindGpuVm = {
      description = "Bind GPU devices to the vfio-platform driver";
      wantedBy = [ "multi-user.target" ];
      before = [ "microvm@gpu-vm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
        ExecStartPre = map (
          d:
          "${pkgs.bash}/bin/bash -c \"echo vfio-platform > /sys/bus/platform/devices/${d}/driver_override\""
        ) allDevs;
        ExecStart = map (
          d: "${pkgs.bash}/bin/bash -c \"echo ${d} > /sys/bus/platform/drivers/vfio-platform/bind\""
        ) allDevs;
      };
    };
    systemd.services."microvm@gpu-vm".after = [ "bindGpuVm.service" ];

    # Host DT overlay exposing the GPU nodes to passthrough.
    hardware.deviceTree.overlays = [
      {
        name = "gpu_passthrough_overlay";
        dtsFile = ./gpu_passthrough_overlay.dts;
      }
    ];

    # Guest configuration for the gpu-vm microvm.
    ghaf.hardware.definition.gpuvm.extraModules = [
      (
        { config, pkgs, ... }:
        {
          # Guest kernel = vanilla 6.12 + jetpack OOT overlay (Bring-Your-Own-
          # Kernel), with #1031's GPU/display passthrough patches applied to
          # nvidia-oot-modules (validated: base OOT builds clean on 6.12.93).
          boot.kernelPackages = lib.mkForce (
            (pkgs.linuxPackages_6_12.extend pkgs.nvidia-jetpack.kernelPackagesOverlay).extend (
              _final: prev: {
                nvidia-oot-modules = prev.nvidia-oot-modules.overrideAttrs (o: {
                  patches = (o.patches or [ ]) ++ [
                    ./patches/0001-gpu-add-support-for-passthrough.patch
                    ./patches/0002-add-support-for-gpu-display-passthrough.patch
                    ./patches/0003-add-support-for-display-passthrough.patch
                  ];
                });
              }
            )
          );
          boot.kernelParams = [
            "clk_ignore_unused"
            "pd_ignore_unused"
          ];

          # The NVIDIA GPU drivers are out-of-tree (nvidia-oot-modules): unlike
          # MGBE0's in-tree dwmac they do NOT autoload from a DT compatible
          # match. Make the built .ko set available and load the stack, so
          # something actually binds gpu@17000000 and creates /dev/nvgpu,
          # /dev/nvmap, /dev/nvhost-* (without which CUDA's NvRmMemMgr init
          # fails and no compute is possible). nvgpu pulls nvmap/host1x/nvhost
          # via module dependencies; listed explicitly for robustness.
          boot.extraModulePackages = [ config.boot.kernelPackages.nvidia-oot-modules ];
          boot.kernelModules = [
            "nvmap"
            "host1x"
            "nvhost"
            "nvgpu"
          ];

          # gk20a boots the GPU's falcon microcode (fecs/gpccs/gpmu) from
          # /lib/firmware at probe time. The minimal guest ships no firmware
          # (empty /lib/firmware), so the falcon boot times out and gk20a probe
          # fails with -110. Ship the L4T GPU firmware in the guest.
          hardware.firmware = [ pkgs.nvidia-jetpack.l4t-firmware ];

          boot.kernelPatches = [
            {
              name = "tegra fixed chip id";
              patch = ./patches/0004-tegra-fixed-chip-id.patch;
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
                # Required by NVIDIA Bring-Your-Own-Kernel for the OOT modules.
                ARM64_PMEM = yes;
              };
            }
          ];

          # (The nvidia-oot GPU/display passthrough patches are applied to
          # nvidia-oot-modules via the kernelPackages overlay above, not here.)

          ghaf.virtualization.qemu.package = lib.mkForce pkgs.ghaf-qemu-bpmp-gpu;

          microvm.qemu.extraArgs = [
            "-dtb"
            "${gpuvm-dtb}/tegra234-gpuvm.dtb"
          ]
          ++ vfioArgs;
        }
      )
    ];
  };
}
