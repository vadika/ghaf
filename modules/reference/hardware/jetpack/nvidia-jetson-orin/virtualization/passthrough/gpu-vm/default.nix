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
# Display (13800000.display) is NOT passed through: the host-owned DCE R5 must
# keep it (and drives scanout directly). vfio-binding display to the guest
# resets/reprograms it out from under the R5, which then aborts at dce_ss_set
# (DCE_HALTED) during its own bootstrap -- confirmed on hardware with the guest
# even stopped, so it is the vfio binding alone, not guest activity. The guest
# reaches the panel only through the DCE host-proxy IPC path, never display MMIO.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.ghaf.hardware.nvidia.passthroughs.gpu_vm;

  # Flip to true to re-enable the dce-dbg bring-up instrumentation
  # (patches/debug/), which logs every DCE-facing address, RPC and payload.
  # Extremely chatty -- pair with the guest's log_buf_len bump.
  # NOTE: temporarily forced to true (original default: false) to build the
  # flip-awaken-contract instrumentation (patches/debug/0008-...). Restore to
  # false once that diagnostic run is done.
  gpuvmDceDebug = true;
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
    # 1:1 scanout carveout: nvdisplay allocates its scanout surface here and
    # the host-owned DCE R5 DMAs it at the same PA. Mirrors scanout/scanout_p
    # in gpu_passthrough_overlay.dts and dce_scanout in tegra234-gpuvm.dts.
    {
      dev = "b0000000.scanout_p";
      base = "0xb0000000";
    }
  ];
  # GPU compute engines. Neither dce@d800000 nor display@13800000 is here: the
  # host keeps the real DCE, bootstraps its R5, and the R5 drives display@13800000
  # directly. Passing display to the guest via vfio resets it and halts the R5
  # (DCE_HALTED at dce_ss_set), so display stays host-side and unbound; the guest
  # reaches the panel only through the DCE host-proxy IPC path.
  #
  # host1x@13e00000 is still passed: the guest GPU stack (nvgpu) needs host1x
  # syncpoints. If the R5 still halts with display host-side, host1x is the next
  # candidate to keep host-side (it would then cost guest GPU compute until the
  # guest gets a virtual host1x).
  engines = [
    "17000000.gpu"
    "13e00000.host1x_pt"
    "15340000.vic"
    "15480000.nvdec"
    "15540000.nvjpg"
  ];
  # Keyhole MMIO passthrough: the single 4KB read-only EVO display-capabilities
  # strap page (display base + 0x30000 = 0x13830000), placed in the guest at its
  # display-aperture caps offset (0x66200000 + 0x30000 = 0x66230000) via the
  # mmio-base form. This backs the guest nvdisplay EvoGetCapabilities read
  # WITHOUT handing over the display control aperture (which requires rewriting
  # display@13800000 and kills the host DCE R5). See gpu_passthrough_overlay.dts
  # fragment@9. The guest display@13800000 node already declares the full
  # aperture; only this one page is backed, so any OTHER display-register access
  # the guest attempts still aborts -- which is how we discover the guest's real
  # MMIO footprint.
  # Second keyhole: the EVO channel doorbell (PUT/GET) register region -- core
  # at display+0x70000 and window channels from display+0x80000 -- mapped into
  # the guest at its display-aperture offset (0x66200000 + 0x70000 = 0x66270000),
  # size 0x20000. The guest nvkms writes PUT to these display MMIO registers to
  # tell the DCE R5 to fetch a channel's pushbuffer; without them backed, the
  # window channel's GET pointer never advances. See gpu_passthrough_overlay.dts
  # fragment@10. CPU-RM-facing user doorbells (guest is the CPU RM); R5-safe.
  # NOTE: dpaux0 (0x155C0000) and MIPI_CAL (0x03990000) are deliberately NOT
  # keyholed. They were tried and proved INERT: on T234D the CPU-side RM never
  # instantiates OBJDPAUX, so no guest code touches those registers -- EDID and AUX
  # are RmControl -> DCE-RPC, serviced by the R5, which owns the pads. Keyholing
  # them changed nothing on hardware.
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
  allDevs = (map (r: r.dev) (reservedMem ++ dispCaps)) ++ engines;

  vfioArgs =
    (lib.concatMap (r: [
      "-device"
      "vfio-platform,host=${r.dev},mmio-base=${r.base}"
    ]) (reservedMem ++ dispCaps))
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
    # display@13800000 is host-side now (the R5 drives it), so the guest no
    # longer requests these display clock/reset/power-domain ids -- but they are
    # left in the closed allow-list harmlessly (still NOT allow-all) so the list
    # need not change again if the guest re-acquires a display path. They are the
    # exact ids the guest display@13800000 node declares (TEGRA234_CLK_* /
    # RESET_* / POWER_DOMAIN_* resolved against tegra234 dt-bindings). dce@d800000
    # needs no ids: the host owns the real DCE and the guest's synthetic dce node
    # has no clocks. As with MGBE0, the host proxy logging "clock not allowed" for
    # probed parent PLLs the guest re-checks is the boundary working; add an id
    # here only if display/GPU init actually fails on that specific denied id
    # (Task 10).
    ghaf.hardware.nvidia.virtualization.host.bpmp.allow = {
      # compute engines (see per-device breakdown above)
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
      ]
      # 13800000.display: nvdisplayhub/disp/p0/p1, dpaux, fuse, the DSI/SP/V
      # PLL tree, RG/SOR/SF paths, mipi-cal, osc, dsc, maud, aza.
      ++ [
        # Root parents of the SOR clock tree. The guest's clk_prepare_enable
        # on sor0 propagates enables up to these; a denied parent fails the
        # WHOLE chain, so the SOR never turns on (no video signal despite a
        # completed modeset -- observed as CLK_ENABLE (cmd 7) denials for 14
        # and 102 at display init). Host-critical always-on roots: a guest
        # enable is a BPMP refcount no-op, and the guest runs
        # clk_ignore_unused so it never mass-disables them.
        14 # TEGRA234_CLK_CLK_M
        102 # TEGRA234_CLK_PLLP_OUT0
        19
        40
        71
        72
        84
        85
        86
        87
        88
        91
        125
        126
        127
        128
        129
        130
        132
        162
        178
        179
        180
        181
        182
        183
        184
        # NOTE: the guest display RM also probes host-critical clocks during
        # its clock-tree walk (observed denials 429-434=CPU DSU/SCE/RCE/DCE_CPU,
        # 472=MCHUB, etc). Those denials are CORRECT and HARMLESS (the host
        # already runs them) and must STAY denied -- never add CPU/coprocessor/
        # memory clocks here. The list above is exactly the 62 clock ids the
        # guest display@13800000 node declares (computed from the guest 6.12
        # tegra234-clock.h), which is the complete closed display set.
        435
        436
        437
        438
        439
        440
        441
        442
        443
        444
        445
        446
        447
        448
        449
        450
        451
        452
        453
        454
        455
        456
        457
        458
        459
        460
        461
        462
        463
        464
        465
        466
        467
        468
        469
        470
        471
      ];
      # compute resets ++ display (nvdisplay 16, dpaux 8, dsi-core 3, mipi-cal 37)
      resets = [
        10
        19
        44
        113
      ]
      ++ [
        3
        8
        16
        37
      ];
      # compute power-domains ++ display DISP (3)
      powerDomains = [
        23
        29
        35
        36
      ]
      ++ [ 3 ];
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
          # DRM userspace: this nvidia-drm build has no fbdev support (it rejects
          # nvidia-drm.fbdev with "unknown parameter"), so there is no fbcon to
          # trigger a modeset -- the connector is detected with a full mode list but
          # nothing ever asks for a mode, so the panel stays dark. Ship modetest so a
          # modeset can be driven from userspace until a compositor runs here.
          environment.systemPackages =
            let
              # Forces plain no-modifier GBM window surfaces; see the shim
              # source for why the modifier path EGL_BAD_ALLOCs on this guest.
              gbm-nomod-shim = pkgs.runCommandCC "gbm-nomod-shim" { } ''
                mkdir -p $out/lib
                $CC -O2 -fPIC -shared -o $out/lib/gbm-nomod-shim.so \
                  ${./sources/gbm-nomod-shim.c} -ldl
              '';
              kmscube-wrapped =
                pkgs.runCommand "kmscube-nomod"
                  {
                    nativeBuildInputs = [ pkgs.buildPackages.makeWrapper ];
                  }
                  ''
                    mkdir -p $out/bin
                    makeWrapper ${pkgs.kmscube}/bin/kmscube $out/bin/kmscube \
                      --set LD_PRELOAD ${gbm-nomod-shim}/lib/gbm-nomod-shim.so
                  '';
            in
            [
              pkgs.libdrm
              kmscube-wrapped
              # Graphics ABI verification (accelerated-rendering bring-up):
              # eglinfo/eglgears to prove the NVIDIA EGL implementation and a
              # GA10B renderer string, drm_info to map render/KMS nodes.
              pkgs.mesa-demos
              pkgs.drm_info
            ];

          # NVIDIA/Jetson graphics userspace (EGL/GLES/GBM) via
          # /run/opengl-driver, mirroring jetpack-nixos modules/graphics.nix.
          # The guest cannot enable hardware.nvidia-jetpack (BYO kernel), so
          # lift just the userspace wiring. l4t-3d-core ships the GL vendor
          # libs; the extras carry their runtime deps (nvrm/gbm/wayland/nvsci).
          hardware.graphics = {
            enable = true;
            # l4t-3d-core with its bundled libnvidia-egl-gbm 1.1.0 shadowed by
            # nixpkgs egl-gbm 1.1.3: the 1.1.0 EGL GBM platform heap-corrupts
            # eglInitialize under mesa 26's libgbm (surfaceless/device
            # platforms are fine). First path wins in the join; drop the l4t
            # json so the platform module isn't loaded twice.
            package = pkgs.symlinkJoin {
              name = "l4t-3d-core-egl-gbm-1.1.3";
              paths = [
                # single-device fallback: on Tegra the EGL device's DRM node
                # (tegra-drm) never path-matches the gbm fd (nvidia-drm), so
                # stock matching always fails eglInitialize on GBM.
                (pkgs.egl-gbm.overrideAttrs (o: {
                  patches = (o.patches or [ ]) ++ [
                    ./patches/userspace/egl-gbm-single-device-fallback.patch
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
                # l4t-gbm minus its bundled libnvidia-egl-gbm 1.1.0 (and its
                # platform json): the nixpkgs egl-gbm 1.1.3 in `package`
                # provides that library; keep only the nvidia-drm_gbm backend.
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
          # Kernel), with #1031's GPU/display passthrough patches applied to
          # nvidia-oot-modules (validated: base OOT builds clean on 6.12.93).
          boot.kernelPackages = lib.mkForce (
            (pkgs.linuxPackages_6_12.extend pkgs.nvidia-jetpack.kernelPackagesOverlay).extend (
              _final: prev: {
                nvidia-oot-modules = prev.nvidia-oot-modules.overrideAttrs (o: {
                  patches =
                    (o.patches or [ ])
                    ++ [
                      ./patches/0001-gpu-add-support-for-passthrough.patch
                      ./patches/0002-add-support-for-gpu-display-passthrough.patch
                      ./patches/0003-add-support-for-display-passthrough.patch
                      # Force NISO display surfaces (channel pushbuffer, notifier,
                      # semaphores) contiguous so they land in the 1:1 physical
                      # carveout the host DCE R5 can resolve -- otherwise the window
                      # channel never advances ("waiting for GPU progress", NVC67E).
                      ./patches/0005-force-niso-display-surfaces-contiguous.patch
                      # Address policy for everything handed to the host-owned DCE
                      # R5 (inst-mem base, channel pushbuffers, ctxdma FrameAddrs):
                      # CPU physical (1:1 GPA=HPA carveout), offset into the native
                      # display high-IOVA range (raw physicals abort the R5's
                      # UPDATE), absolute ctxdma Limit computed after the offset.
                      # The host maps hi->carveout in the display SMMU domains and
                      # retags the scanout readers' MC SIDs (dce-iso-anchor).
                      ./patches/0006-dce-addresses-cpu-phys-high-iova.patch
                      # DP++ dual-mode: a passive HDMI adapter asserts HPD but has
                      # no DP sink; trust RM's DDC/LOAD detection over the DP lib's
                      # HPD-only guess so detection falls through to the TMDS
                      # partner displayId where the sink really is.
                      ./patches/0008-fix-dual-mode-honor-rm-connect-state.patch
                      # Core notifier: plain WRITE, never WRITE_AWAKEN -- the
                      # awaken rides the DCE async event path the guest cannot
                      # receive and the R5 aborts the whole completion write.
                      # NB: dropping this to get awaken-paced completions was
                      # retried 2026-07-17 WITH the ch3 relay live: flips stop
                      # completing entirely (modetest -v never reports a freq).
                      # The R5-side abort is not about the guest lacking an
                      # event path; keep plain WRITE.
                      ./patches/0009-core-notifier-plain-write-no-awaken.patch
                      # Boot hotplug: a panel connected at boot produces no HPD
                      # edge, so the host DCE never sends the hotplug event and
                      # the SOR is never assigned (dark until manual replug).
                      # Schedule the same deferred hotplug work once at init.
                      ./patches/0020-synthesize-boot-hotplug-long-pulse.patch
                      # Window-channel completion notifier: restore
                      # WRITE_AWAKEN for an active-primary window only
                      # (pSurfaceEvo[NVKMS_LEFT] != NULL) -- generates the real
                      # per-flip R5 completion (measured 60/s, no abort).
                      # Phase C trial (2026-07-18): the R5 event IS now the DRM
                      # completion source -- 0010 (trace-drop) and 0013 (vblank
                      # completion) are OUT of the list, so the native
                      # CompletionNotifierEvent -> NVKMS -> KAPI -> nvidia-drm
                      # chain delivers each flip. Testing whether native R5
                      # completion alone gives tear-free 60fps before investing
                      # in Blocker 2's ACK-decouple FIFO.
                      ./patches/0011-window-notifier-plain-write.patch
                    ]
                    # dce-dbg bring-up instrumentation (ctxdma/pushbuffer/instmem
                    # FE-arming params, DISPRM RPC + payload hexdumps, core PB
                    # dumps, DP attach + SOR assignment + RG probes). Applies on
                    # top of the functional set; flip gpuvmDceDebug to enable.
                    ++ lib.optionals gpuvmDceDebug [
                      ./patches/debug/0001-dce-debug-instrumentation.patch
                      ./patches/debug/0002-dce-debug-async-event-dispatch.patch
                      ./patches/debug/0003-dce-debug-flip-occurred-path.patch
                      ./patches/debug/0004-dce-debug-event-interest.patch
                      ./patches/debug/0005-dce-debug-flip-delivered.patch
                      ./patches/debug/0006-dce-debug-flip-rm-callback.patch
                      # Flip-completion awaken contract: logs the three
                      # points where a kickoff's WRITE vs WRITE_AWAKEN
                      # notifier mode is decided/consumed (nvidia-drm's
                      # pending_events_plane_mask, KAPI's awaken flag, and
                      # what EvoFlipC3Common actually programs after 0011's
                      # ISO-surface gate) -- to catch a pending flip that
                      # never gets its R5 awaken.
                      ./patches/debug/0008-dce-debug-flip-awaken-contract.patch
                      # Per-flip pre-syncpt probe: usingSyncpt + pre-syncpt id/
                      # threshold, to test the unsatisfied-acquire-syncpt freeze
                      # (window channel BEGUN but never latched -> no FINISHED).
                      ./patches/debug/0009-dce-debug-flip-presyncpt.patch
                    ];
                  # DCE display proxy (guest side): redirect the guest's DCE IPC
                  # through the shared MMIO window and skip the R5 bootstrap (the
                  # R5 is host-owned). The hook patch is written against the
                  # nvidia-oot project root (no nvidia-oot/ prefix) so apply it
                  # scoped to nvidia-oot/; splice the guest proxy in as its own
                  # obj-m .ko (it links tegra-dce's exported symbols, so it must
                  # build inside nvidia-oot).
                  postPatch = (o.postPatch or "") + ''
                    patch -p1 -d nvidia-oot < ${../../common/dce-virt-common/patches/0001-dce-virt-hooks.patch}
                    # Reverse-doorbell stage 2: export the async-event injector
                    # the guest proxy uses to deliver relayed ch3 events to
                    # nvdisplay's RM_EVENT client.
                    patch -p1 -d nvidia-oot < ${../../common/dce-virt-common/patches/0002-dce-client-ipc-inject.patch}
                    install -D ${../../common/dce-virt-common/sources/drivers/platform/tegra/dce-guest-proxy/dce-guest-proxy.c} \
                      nvidia-oot/drivers/platform/tegra/dce/dce-guest-proxy.c
                    echo 'obj-m += dce-guest-proxy.o' >> nvidia-oot/drivers/platform/tegra/dce/Makefile
                  '';
                });
              }
            )
          );
          # nvidia-drm.modeset=1 + fbdev=1: bring up the NVIDIA KMS layer and its
          # framebuffer console. fbcon drawing to the panel is the modeset TRIGGER
          # that makes nvdisplay actually bring up the display -> DCE handshake
          # through the proxy -> scanout. Without a modeset request nothing drives
          # the display (the device binds but stays idle).
          boot.kernelParams = [
            "clk_ignore_unused"
            "pd_ignore_unused"
            "nvidia-drm.modeset=1"
            # 16M kernel ring: the dce-dbg method/control dumps otherwise wrap
            # the default ring within seconds and destroy every capture.
            "log_buf_len=16M"
            # Never auto-disable vblank interrupts. nvidia-drm disables them
            # the moment the last flip completes; under the DCE proxy each
            # re-enable is a synchronous EVENT_SET_NOTIFICATION RPC to the R5
            # (~10ms) plus a slow stream restart, which quantized flips to
            # ~122ms (~8 fps). With the vblank stream always on, the R5 emits
            # completions at the 60Hz vblank cadence (confirmed host-side).
            "drm.vblankoffdelay=0"
            # NB: this nvidia-drm build REJECTS fbdev ("unknown parameter 'fbdev'
            # ignored"), so there is no framebuffer console here and nothing
            # automatically requests a modeset -- the connector is detected with a
            # full mode list but stays unlit until a DRM client sets a mode. Kept
            # only so it takes effect if a driver that supports it is used later.
            "nvidia-drm.fbdev=1"
            # NOTE: do NOT add "video=DP-1:...e" here. The trailing 'e' forces the
            # connector on (DRM_FORCE_ON), which makes nvidia-drm set
            # forceConnected, and nvDpyGetDynamicData then short-circuits to
            # "connected" for the DisplayPort displayId before it ever consults the
            # DP lib or RM. The AGX DP port is DP++ dual-mode (0x100 SOR_DP_A and
            # 0x200 SINGLE_TMDS_A are one physical connector sharing a DRM connector
            # with two encoders); forcing the DP encoder on stops connector detect at
            # it, so the TMDS partner -- where a passive HDMI adapter's sink actually
            # lives -- is never probed, and every EDID read fails on AUX forever.
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
            # DCE display proxy (guest): tegra-dce binds the synthetic dce node
            # (dce-virtual-pa, no reg) in proxy mode; dce-guest-proxy binds the
            # nvidia,dce-guest-proxy node, ioremaps the shared window and installs
            # the send redirect. Neither autoloads from a DT match (OOT modules),
            # so load them explicitly. dce-guest-proxy links tegra-dce's exported
            # redirect symbol, so modprobe orders tegra-dce first.
            "tegra-dce"
            "dce-guest-proxy"
            # Display KMS stack: gives the guest a /dev/dri KMS device + crtcs for
            # display@13800000 (bound by nv_platform). With nvidia-drm.modeset=1 +
            # fbdev=1 (kernelParams) fbcon draws to the panel -> the modeset that
            # makes nvdisplay bring up the display -> DCE handshake via the proxy.
            # nvidia-drm pulls nvidia-modeset + nvidia via module deps.
            "nvidia-modeset"
            "nvidia-drm"
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
                # DIAGNOSTIC: allow guest /dev/mem access to the 1:1 carveouts
                # and claimed display MMIO (DCE notifier poison/GET-PUT tests).
                # Drop for release.
                STRICT_DEVMEM = lib.mkForce no;
                # STRICT_DEVMEM=n hides this prompt; `option` tolerates it being unused.
                IO_STRICT_DEVMEM = lib.mkForce (option no);
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
