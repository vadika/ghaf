# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  stdenv,
  nvidia-jetpack,
  pluginName,
  pluginSource,
}:
stdenv.mkDerivation {
  pname = "gpu-vm-partition-plugin-${pluginName}";
  version = "1.0";

  dontUnpack = true;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    cp ${pluginSource} plugin.c
    cp ${./plugin.h} plugin.h
    cp ${./protocol.h} protocol.h
    cp ${../gpu-vm-load/vadd.ptx} vadd.ptx
    $CC -std=c11 -Wall -Wextra -Werror -fPIC -shared -I. \
      -I${nvidia-jetpack.cudaPackages.cuda_cudart}/include \
      plugin.c -o plugin.so \
      -L${nvidia-jetpack.l4t-cuda}/lib -l:libcuda.so.1 \
      -Wl,-rpath,${nvidia-jetpack.l4t-cuda}/lib
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 plugin.so $out/lib/gpu-partition-manager/plugin.so
    runHook postInstall
  '';

  passthru.gpuPartitionPluginName = pluginName;

  meta = {
    description = "${pluginName} workload for gpu-vm-partition-manager";
    platforms = [ "aarch64-linux" ];
  };
}
