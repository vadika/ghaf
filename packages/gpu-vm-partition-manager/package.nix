# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  stdenv,
  buildPackages,
  nvidia-jetpack,
}:
stdenv.mkDerivation {
  pname = "gpu-vm-partition-manager";
  version = "1.0";
  src = ./.;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -Wall -Wextra -Werror -I. \
      -I${nvidia-jetpack.cudaPackages.cuda_cudart}/include \
      manager.c -o gpu-partition-manager -pthread -ldl \
      -L${nvidia-jetpack.l4t-cuda}/lib -l:libcuda.so.1 \
      -Wl,-rpath,${nvidia-jetpack.l4t-cuda}/lib
    $CC -std=c11 -Wall -Wextra -Werror -I. \
      client.c -o gpu-partition-run
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 gpu-partition-manager $out/bin/gpu-partition-manager
    install -Dm755 gpu-partition-run $out/bin/gpu-partition-run
    install -Dm644 protocol.h $out/include/ghaf/gpu-partition-manager/protocol.h
    install -Dm644 plugin.h $out/include/ghaf/gpu-partition-manager/plugin.h
    runHook postInstall
  '';

  meta = {
    description = "Managed CUDA Green Context jobs for the Ghaf gpu-vm";
    platforms = [ "aarch64-linux" ];
  };

  passthru = {
    pluginAbiVersion = 1;
    protocolVersion = 1;
    tests.unit = buildPackages.callPackage ./tests/package.nix { };
  };
}
