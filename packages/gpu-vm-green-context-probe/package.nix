# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  stdenv,
  nvidia-jetpack,
}:
stdenv.mkDerivation {
  pname = "gpu-vm-green-context-probe";
  version = "1.0";
  src = ./.;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -Wall -Wextra -Werror \
      -I${nvidia-jetpack.cudaPackages.cuda_cudart}/include runner.c \
      -o gpu-vm-green-context-probe \
      -L${nvidia-jetpack.l4t-cuda}/lib -l:libcuda.so.1 \
      -Wl,-rpath,${nvidia-jetpack.l4t-cuda}/lib
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 gpu-vm-green-context-probe \
      $out/bin/gpu-vm-green-context-probe
    runHook postInstall
  '';

  meta = {
    description = "CUDA Green Context capability probe for gpu-vm";
    platforms = [ "aarch64-linux" ];
    mainProgram = "gpu-vm-green-context-probe";
  };
}
