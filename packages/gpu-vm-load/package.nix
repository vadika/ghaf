# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# gpu-vm-load: a prebuilt CUDA compute-load binary for the gpu-vm passthrough
# smoke test. On-device compilation is not possible in the minimal guest (no
# CUDA toolkit headers, and nvcc's baked host-compiler path is absent), and the
# Jetson nvcc cannot run on the x86 builder, so the workload is built here from
# hand-written PTX (vadd.ptx) driven by runner.c through the CUDA Driver API:
#   - the PTX is embedded via the assembler's .incbin (no CUDA toolkit needed);
#   - the Driver API needs no toolkit headers (prototypes are hand-declared);
#   - runner.c links against the native L4T libcuda.so.1 with an RPATH, so the
#     binary is self-contained and runs on the guest with no LD_LIBRARY_PATH
#     and no toolchain present.
{
  stdenv,
  nvidia-jetpack,
}:
stdenv.mkDerivation {
  pname = "gpu-vm-load";
  version = "1.0";
  src = ./.;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    # -I. so the assembler's .incbin finds vadd.ptx in the build dir.
    $CC -I. runner.c -o gpu-vm-load \
      -L${nvidia-jetpack.l4t-cuda}/lib -l:libcuda.so.1 \
      -Wl,-rpath,${nvidia-jetpack.l4t-cuda}/lib
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 gpu-vm-load $out/bin/gpu-vm-load
    runHook postInstall
  '';

  meta = {
    description = "CUDA compute-load smoke test for the gpu-vm passthrough";
    platforms = [ "aarch64-linux" ];
    mainProgram = "gpu-vm-load";
  };
}
