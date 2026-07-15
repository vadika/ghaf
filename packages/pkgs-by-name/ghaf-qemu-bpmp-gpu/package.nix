# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# GPU-VM variant of ghaf-qemu-bpmp. Same QEMU 10.1.5 + BPMP bridge, plus two
# patches the GPU needs and net-vm does not:
#   - vfio-platform mmio-base + a large platform bus, for 1:1 GPA=HPA mapping of
#     the GPU's large reserved-memory MMIO regions.
#   - a predefined-DTB path so gpu-vm can supply a hand-written guest device tree
#     (GPU + display + engines; too complex to emit from a QEMU FDT binding).
# Kept a SEPARATE binary so net-vm's memory map stays byte-identical to
# ghaf-qemu-bpmp.
{ ghaf-qemu-bpmp }:
ghaf-qemu-bpmp.override {
  variantName = "-gpu";
  extraPatches = [
    ../ghaf-qemu-bpmp/patches/0002-vfio-platform-mmio-base.patch
    ../ghaf-qemu-bpmp/patches/0003-nop-predefined-dtb-memory.patch
  ];
}
