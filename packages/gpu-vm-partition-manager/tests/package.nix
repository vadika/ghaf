# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  stdenv,
  bash,
  coreutils,
  gnugrep,
  gnused,
}:
stdenv.mkDerivation {
  pname = "gpu-vm-partition-manager-tests";
  version = "1.0";
  src = ./..;

  dontConfigure = true;
  nativeBuildInputs = [
    bash
    coreutils
    gnugrep
    gnused
  ];

  buildPhase = ''
    runHook preBuild
    testFlags="-fsanitize=address,undefined -fno-omit-frame-pointer"
    $CC -std=c11 -Wall -Wextra -Werror $testFlags -Itests -I. \
      manager.c tests/mock-cuda.c -o gpu-partition-manager -pthread -ldl
    $CC -std=c11 -Wall -Wextra -Werror $testFlags -I. \
      client.c -o gpu-partition-run
    $CC -std=c11 -Wall -Wextra -Werror $testFlags -I. \
      tests/bad-client.c -o bad-client
    $CC -std=c11 -Wall -Wextra -Werror $testFlags -fPIC -shared -Itests -I. \
      tests/mock-plugin.c -o mock-plugin.so
    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck
    patchShebangs tests/integration.sh
    bash tests/integration.sh
    runHook postCheck
  '';
  doCheck = true;

  installPhase = ''
    mkdir -p $out
    touch $out/passed
  '';
}
