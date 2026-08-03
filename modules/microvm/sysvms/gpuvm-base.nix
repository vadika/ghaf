# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# GPU VM Base Module (Orin AGX)
#
# Smallest config that boots, gives a shell, and exposes the Jetson CUDA
# userspace to prove GPU compute. No wifi/wan/NAT/desktop. Passthrough wiring
# (kernel, DTB, vfio) is layered on via ghaf.hardware.definition.gpuvm.extraModules
# (the gpu-vm passthrough module) at evaluatedConfig time. Takes globalConfig +
# hostConfig via specialArgs; compose with extendModules.
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

  # Prebuilt CUDA smoke test (driver API + embedded PTX, RPATH-wired to native
  # libcuda); also the payload of the container smoke image.
  gpuVmLoad = pkgs.callPackage ../../../packages/gpu-vm-load/package.nix {
    inherit (pkgs) nvidia-jetpack;
  };

  # Static CDI spec: the guest device layout is fixed by the passthrough DTS and
  # the CUDA userspace is a store path, so generate the spec at build time
  # instead of running nvidia-container-toolkit's generator in the guest.
  # Mounts = full l4t-cuda runtime closure at its own store paths, so RPATHs
  # and LD_LIBRARY_PATH resolve identically inside the container.
  nvidiaCdiSpec =
    pkgs.runCommand "nvidia-cdi-spec"
      {
        nativeBuildInputs = [ pkgs.buildPackages.jq ];
        closureInfo = pkgs.closureInfo { rootPaths = [ pkgs.nvidia-jetpack.l4t-cuda ]; };
        libPath = lib.makeLibraryPath [ pkgs.nvidia-jetpack.l4t-cuda ];
      }
      ''
        jq -n \
          --rawfile paths "$closureInfo/store-paths" \
          --arg libPath "$libPath" \
          '{
            cdiVersion: "0.6.0",
            kind: "nvidia.com/gpu",
            devices: [
              {
                name: "all",
                containerEdits: {
                  # Hardware-enumerated set (2026-08-02, running gpu-vm). r36 libcuda
                  # initializes through the tegra_drm render node and host1x-fence
                  # (strace-proven); without them cuInit fails with CUresult=801.
                  deviceNodes: (
                    [
                      "/dev/nvhost-as-gpu",
                      "/dev/nvhost-ctrl-gpu",
                      "/dev/nvhost-ctxsw-gpu",
                      "/dev/nvhost-dbg-gpu",
                      "/dev/nvhost-gpu",
                      "/dev/nvhost-nvsched-gpu",
                      "/dev/nvhost-nvsched_ctrl_fifo-gpu",
                      "/dev/nvhost-power-gpu",
                      "/dev/nvhost-prof-ctx-gpu",
                      "/dev/nvhost-prof-dev-gpu",
                      "/dev/nvhost-prof-gpu",
                      "/dev/nvhost-sched-gpu",
                      "/dev/nvhost-tsg-gpu",
                      "/dev/nvmap",
                      "/dev/nvgpu/igpu0/as",
                      "/dev/nvgpu/igpu0/channel",
                      "/dev/nvgpu/igpu0/ctrl",
                      "/dev/nvgpu/igpu0/ctxsw",
                      "/dev/nvgpu/igpu0/dbg",
                      "/dev/nvgpu/igpu0/nvsched",
                      "/dev/nvgpu/igpu0/nvsched_ctrl_fifo",
                      "/dev/nvgpu/igpu0/power",
                      "/dev/nvgpu/igpu0/prof",
                      "/dev/nvgpu/igpu0/prof-ctx",
                      "/dev/nvgpu/igpu0/prof-dev",
                      "/dev/nvgpu/igpu0/sched",
                      "/dev/nvgpu/igpu0/tsg",
                      "/dev/dri/renderD128",
                      "/dev/host1x-fence"
                    ] | map({ path: . })
                  )
                }
              }
            ],
            containerEdits: {
              # ponytail: this env edit clobbers any image-provided LD_LIBRARY_PATH;
              # switch to an ldconfig-hook approach if third-party images matter.
              env: [ ("LD_LIBRARY_PATH=" + $libPath) ],
              mounts: (
                $paths | split("\n") | map(select(length > 0) | {
                  hostPath: .,
                  containerPath: .,
                  options: [ "ro", "bind", "nosuid", "nodev" ]
                })
              )
            }
          }' > "$out"
      '';

  # OCI image holding only the smoke binary; CUDA libs arrive via CDI mounts,
  # and gpu-vm-load's RPATH points at the same l4t-cuda store path CDI mounts.
  gpuSmokeImage = pkgs.dockerTools.buildImage {
    name = "gpu-smoke";
    tag = "latest";
    copyToRoot = gpuVmLoad;
    config.Cmd = [
      "/bin/gpu-vm-load"
      "5"
    ];
  };

  gpuContainerSmoke = pkgs.writeShellApplication {
    name = "gpu-container-smoke";
    runtimeInputs = [ pkgs.docker ];
    text = ''
      # Proves CDI end-to-end: spec resolution, device-node injection, lib
      # mounts, and a real kernel launch on the passed-through GPU.
      docker load < ${gpuSmokeImage}
      docker run --rm --device nvidia.com/gpu=all gpu-smoke:latest | grep GPU_LOAD_OK
      echo CONTAINER_GPU_OK
    '';
  };
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

    # GIVC transport only (no gpuvm role yet); gpuvm.nix guards policy/spire on
    # these being enabled. Add a role later if the VM must serve GIVC commands.
    givc = {
      enable = globalConfig.givc.enable or false;
      debug = globalConfig.givc.debug or false;
    };

    # Storage - from globalConfig
    storagevm = {
      enable = true;
      name = vmName;
      encryption.enable = globalConfig.storage.encryption.enable or false;
      # Docker image/container store survives gpu-vm reboots.
      directories = [
        {
          directory = "/var/lib/docker";
          mode = "0710";
        }
      ];
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

      spire.agents.downstream = {
        enable = globalConfig.spire.enable or false;
        logLevel = if globalConfig.spire.debug then "DEBUG" else "INFO";
      };
    };

    services.timezone.enable = lib.mkDefault (
      timezoneEnabled && globalConfig.platform.timeZone == null
    );
  };

  # Minimal Jetson CUDA userspace to prove compute: l4t-cuda (libcuda.so.1),
  # l4t-tools (tegrastats), cuda runtime.
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
      # the GR3D_FREQ smoke test (see /etc/gpu-test/vectorAdd.cu).
      cuda_nvcc
    ])
    ++ [
      pkgs.gcc
      # Prebuilt smoke test (driver API + embedded PTX, RPATH-wired to native
      # libcuda), built at image time since the guest can't compile on-device.
      gpuVmLoad
      gpuContainerSmoke
    ];

  # GPU nodes are created root-only at early nvgpu load, before udev rules
  # reliably apply, so a rule alone leaves them root:root. Re-grant video-group
  # access once they exist so CUDA runs as ghaf without sudo (sudo strips
  # LD_LIBRARY_PATH).
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
  users.users.ghaf.extraGroups = [
    "video"
    "docker"
  ];

  # Rootful Docker with CDI so CUDA payloads run in containers:
  #   docker run --device nvidia.com/gpu=all <image>
  # The CDI spec at /etc/cdi/nvidia.json is nix-generated (see below); no
  # nvidia-container-toolkit in the guest.
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      features.cdi = true;
      cdi-spec-dirs = [ "/etc/cdi" ];
    };
  };

  # cudaPackages' cuda_compat libcuda.so.1 wins the path collision but can't find
  # the native L4T driver stack -> cuInit error 999. Put l4t-cuda's native libcuda
  # first instead. Blunt global var, fine for a compute-only VM; move to a
  # /run/opengl-driver runpath if this VM ever runs general apps.
  environment.variables.LD_LIBRARY_PATH = lib.mkForce (
    lib.makeLibraryPath [ pkgs.nvidia-jetpack.l4t-cuda ]
  );

  environment.etc."cdi/nvidia.json".source = nvidiaCdiSpec;

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
    # vcpu is pinned to 4 because tegra234-gpuvm.dts is generated for
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
