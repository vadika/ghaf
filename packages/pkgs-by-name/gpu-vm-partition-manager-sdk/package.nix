# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  runCommand,
}:
runCommand "gpu-vm-partition-manager-sdk-1.0"
  {
    meta = {
      description = "Public protocol and plugin ABI headers for the Ghaf GPU partition manager";
      license = lib.licenses.asl20;
      platforms = lib.platforms.linux;
    };
    passthru = {
      pluginAbiVersion = 1;
      protocolVersion = 1;
    };
  }
  ''
    install -Dm644 ${../../gpu-vm-partition-manager/plugin.h} \
      $out/include/ghaf/gpu-partition-manager/plugin.h
    install -Dm644 ${../../gpu-vm-partition-manager/protocol.h} \
      $out/include/ghaf/gpu-partition-manager/protocol.h
  ''
