# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# GPU VM Base Module
#
# Minimal base configuration for the GPU VM (Orin AGX). It takes globalConfig
# and hostConfig via specialArgs and can be composed using extendModules.
#
# This is deliberately MINIMAL: it is the smallest config that boots, gives a
# shell, and exposes the Jetson CUDA userspace so GPU compute can be proven.
# It does NOT set up wifi/wan/NAT/desktop. The GPU/display passthrough wiring
# (kernel, DTB, vfio devices) is layered on via
# ghaf.hardware.definition.gpuvm.extraModules (see the gpu-vm passthrough
# module) and applied through applyVmConfig at evaluatedConfig time.
#
# Usage in profiles:
#   lib.nixosSystem {
#     modules = [ inputs.self.nixosModules.gpuvm-base ];
#     specialArgs = { inherit globalConfig hostConfig; };
#   }
#
# Then extend with:
#   base.extendModules { modules = [ ... ]; }
#
{
  lib,
  pkgs,
  inputs,
  globalConfig,
  hostConfig,
  ...
}:
let
  vmName = "gpu-vm";
  timezoneEnabled = lib.ghaf.features.isEnabledFor globalConfig "timezone" vmName;
in
{
  _file = ./gpuvm-base.nix;

  imports = [
    inputs.preservation.nixosModules.preservation
    inputs.self.nixosModules.givc
    inputs.self.nixosModules.hardware-x86_64-guest-kernel
    inputs.self.nixosModules.vm-modules
    inputs.self.nixosModules.profiles
  ];

  ghaf = {
    # Profiles - from globalConfig
    profiles.debug.enable = lib.mkDefault (globalConfig.debug.enable or false);

    development = {
      ssh.daemon.enable = lib.mkDefault (globalConfig.development.ssh.daemon.enable or false);
      debug.tools.enable = lib.mkDefault (globalConfig.development.debug.tools.enable or false);
      nix-setup.enable = lib.mkDefault (globalConfig.development.nix-setup.enable or false);
    };

    # Networking hosts - from hostConfig
    # Required for vm-networking.nix to look up this VM's MAC/IP
    networking.hosts = hostConfig.networking.hosts or { };

    # Common namespace - from hostConfig
    common = hostConfig.common or { };

    # User configuration - from hostConfig
    users = {
      profile = hostConfig.users.profile or { };
      admin = hostConfig.users.admin or { };
      managed = hostConfig.users.managed or { };
    };

    # Enable dynamic hostname export for VMs
    identity.vmHostNameExport.enable = true;

    # System
    type = "system-vm";

    systemd = {
      enable = true;
      withName = "gpuvm-systemd";
      withLocaled = true;
      withNss = true;
      withResolved = true;
      withTimesyncd = true;
      withDebug = globalConfig.debug.enable or false;
      withHardenedConfigs = true;
    };

    # GIVC configuration - from globalConfig.
    # ponytail: no dedicated gpuvm givc role exists; enable transport only, no
    # policyClient. Task 7's gpuvm.nix guards policy/spire wiring on those being
    # enabled, so a plain client is the minimal correct thing. Add a role later
    # if the GPU VM needs to serve/receive GIVC commands.
    givc = {
      enable = globalConfig.givc.enable or false;
      debug = globalConfig.givc.debug or false;
    };

    # Storage - from globalConfig
    storagevm = {
      enable = true;
      name = vmName;
      encryption.enable = globalConfig.storage.encryption.enable or false;
    };

    virtualization.microvm = {
      swap.enable = true;

      vm-networking = {
        enable = true;
        inherit vmName;
      };

      tpm.emulated = {
        # Orin is aarch64: TPM passthrough is x86-only, so use emulated when
        # encryption is enabled.
        enable = globalConfig.storage.encryption.enable or false;
        name = vmName;
      };
    };

    # Logging - from globalConfig
    logging = {
      inherit (globalConfig.logging) enable listener;
      journalClient = {
        inherit (globalConfig.logging) enable;
      };
    };

    security = {
      fail2ban.enable = globalConfig.development.ssh.daemon.enable or false;
      audit.enable = lib.mkDefault (globalConfig.security.audit.enable or false);

      spire.agent = {
        enable = globalConfig.spire.enable or false;
        logLevel = if globalConfig.spire.debug then "DEBUG" else "INFO";
        nodeAttestationMode = if globalConfig.givc.enable then "x509pop" else "join_token";
      };
    };

    services.timezone.enable = lib.mkDefault (
      timezoneEnabled && globalConfig.platform.timeZone == null
    );
  };

  # Jetson CUDA userspace for GPU compute. l4t-cuda ships the userspace CUDA
  # driver (libcuda.so.1); l4t-tools ships tegrastats. cuda_cudart is the CUDA
  # runtime. This is the minimal runtime to prove compute once the GPU is
  # passed through.
  # ponytail: no prebuilt CUDA sample (deviceQuery/vectorAdd) is packaged by
  # nvidia-jetpack, so none is added here. If Task 10's smoke test needs to
  # compile one on-device, add pkgs.nvidia-jetpack.cudaPackages.cuda_nvcc.
  environment.systemPackages =
    (with pkgs.nvidia-jetpack; [
      l4t-cuda
      l4t-tools
    ])
    ++ (with pkgs.nvidia-jetpack.cudaPackages; [
      cuda_cudart
      cuda_nvrtc
      libcublas
      # nvcc + a host compiler so a GPU compute load can be built on-device for
      # the Task 10 GR3D_FREQ smoke test (see /etc/gpu-test/vectorAdd.cu).
      cuda_nvcc
    ])
    ++ [
      pkgs.gcc
      # Prebuilt CUDA compute-load smoke test (driver API + embedded PTX,
      # RPATH-wired to the native libcuda). On-device compilation is not
      # possible in this minimal guest, so the workload is built at image time.
      (pkgs.callPackage ../../../packages/gpu-vm-load/package.nix {
        inherit (pkgs) nvidia-jetpack;
      })
    ];

  # The passed-through GPU nodes (/dev/nvgpu/*, /dev/nvhost-*, /dev/nvmap) are
  # created root-only, and the /dev/nvgpu/* nodes appear at nvgpu module load
  # (early boot) before udev rules reliably apply to them, so a udev rule alone
  # leaves them root:root. A boot service re-grants video-group access once the
  # nodes exist, so CUDA runs as the ghaf user without sudo (sudo would strip
  # the LD_LIBRARY_PATH the desktop cuda_compat path needs; the prebuilt
  # gpu-vm-load is RPATH-wired so it needs neither sudo nor the env var).
  systemd.services.gpu-vm-node-access = {
    description = "Grant video-group access to the passed-through GPU nodes";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for d in /dev/nvgpu /dev/nvhost-* /dev/nvmap; do
        [ -e "$d" ] || continue
        chgrp -R video "$d" || true
        chmod -R g+rw "$d" || true
      done
    '';
  };
  users.users.ghaf.extraGroups = [ "video" ];

  # The desktop cudaPackages pull in cuda_compat, whose libcuda.so.1 wins the
  # system-path collision over l4t-cuda's native driver. That compat libcuda
  # can't locate the full native L4T driver stack (libnvcucompat + libnvrm_*),
  # so cuInit fails with error 999. l4t-cuda's lib output ships the native
  # libcuda plus the complete driver stack together; putting it first on the
  # loader path makes CUDA initialise the passed-through GPU.
  # Proven: __nvcc_device_query returns 87 (sm_87 / ga10b) with this set.
  # ponytail: blunt global LD_LIBRARY_PATH, acceptable for a compute-only test
  # VM. Move to a /run/opengl-driver runpath if this VM ever runs general apps.
  environment.variables.LD_LIBRARY_PATH = lib.mkForce (
    lib.makeLibraryPath [ pkgs.nvidia-jetpack.l4t-cuda ]
  );

  # Sustained GPU compute load for verifying passthrough (tegrastats GR3D_FREQ).
  # Compile on-device: nvcc /etc/gpu-test/vectorAdd.cu -o /tmp/va && /tmp/va
  environment.etc."gpu-test/vectorAdd.cu".text = ''
    #include <cstdio>
    __global__ void vadd(float *a, float *b, float *c, int n) {
      int i = blockIdx.x * blockDim.x + threadIdx.x;
      if (i < n) c[i] = a[i] + b[i] * 1.0001f;
    }
    int main() {
      int n = 1 << 22; size_t sz = (size_t)n * sizeof(float);
      float *a, *b, *c;
      if (cudaMalloc(&a, sz) || cudaMalloc(&b, sz) || cudaMalloc(&c, sz)) {
        printf("cudaMalloc failed\n"); return 1;
      }
      for (int k = 0; k < 300000; k++) vadd<<<(n + 255) / 256, 256>>>(a, b, c, n);
      cudaDeviceSynchronize();
      printf("GPU_COMPUTE_OK\n");
      return 0;
    }
  '';

  time.timeZone = lib.mkIf (!timezoneEnabled) (lib.mkDefault globalConfig.platform.timeZone);

  system.stateVersion = lib.trivial.release;

  nixpkgs = {
    buildPlatform.system = globalConfig.platform.buildSystem or "x86_64-linux";
    hostPlatform.system = globalConfig.platform.hostSystem or "aarch64-linux";
  };

  microvm = {
    optimize.enable = false;
    # ponytail: vcpu is pinned to 4 because tegra234-gpuvm.dts is generated for
    # 4 cores; changing it requires regenerating the DTS. mem is a default so a
    # profile/vmConfig can shrink it.
    vcpu = 4;
    mem = lib.mkDefault 6000;
    hypervisor = "qemu";

    shares = [
      {
        tag = "ghaf-common";
        source = "/persist/common";
        mountPoint = "/etc/common";
        proto = "virtiofs";
      }
    ]
    # Shared store (when not using storeOnDisk)
    ++ lib.optionals (!(globalConfig.storage.storeOnDisk.enable or false)) [
      {
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        proto = "virtiofs";
      }
    ];

    writableStoreOverlay = lib.mkIf (
      !(globalConfig.storage.storeOnDisk.enable or false)
    ) "/nix/.rw-store";

    qemu = {
      machine =
        {
          x86_64-linux = "q35";
          aarch64-linux = "virt";
        }
        .${globalConfig.platform.hostSystem or "aarch64-linux"};
    };
  }
  // lib.optionalAttrs (globalConfig.storage.storeOnDisk.enable or false) (
    let
      compLevelSuffix = lib.optionalString (
        globalConfig.storage.storeOnDisk.compression.level != null
      ) ",${toString globalConfig.storage.storeOnDisk.compression.level}";
    in
    {
      storeOnDisk = true;
      storeDiskType = "erofs";
      storeDiskErofsFlags = [
        "-Eztailpacking"
        "-Efragments"
        "--workers=$(( (NIX_BUILD_CORES < 1 || NIX_BUILD_CORES > 4) ? 4 : NIX_BUILD_CORES ))"
      ]
      ++ {
        lz4hc = [ "-zlz4hc${compLevelSuffix}" ];
        zstd = [
          "-zzstd${compLevelSuffix}"
          "-E48bit"
        ];
      }
      .${globalConfig.storage.storeOnDisk.compression.algorithm};
    }
  );
}
