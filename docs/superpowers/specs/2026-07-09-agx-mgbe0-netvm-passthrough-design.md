# AGX Orin MGBE0 ethernet passthrough to net-vm

Design, 2026-07-09. Target: NVIDIA Jetson AGX Orin devkit (p3737-0000 + p3701-0000),
Ghaf `main` @ `80ddbae0`, jetpack kernel 6.6.129, QEMU hypervisor, microvm.nix.

Goal: the wired NIC is owned by `net-vm`, not by `ghaf-host`. True MMIO passthrough —
the ethernet driver runs inside the guest and drives the real controller through
`vfio-platform`. `ghaf-host` ends up with no network interface of its own.

## Hardware facts

All read off the running device (`/proc/device-tree/bus@0/ethernet@6800000`), not
from documentation.

| Property | Value |
|---|---|
| Node | `ethernet@6800000`, `compatible = "nvidia,tegra234-mgbe"` |
| Host driver today | `nvethernet` (NVIDIA out-of-tree), `eth0`, link 1 Gbps |
| `reg` | `0x6800000` hypervisor, `0x6810000` mac, `0x68a0000` xpcs, `0x68d0000` macsec-base — 64 KB each |
| `interrupts` | 8 SPIs, 384–391 (`common`, `vm0`–`vm4`, `macsec-ns-irq`, `macsec-s-irq`) |
| `iommus` | `<&smmu 6>` where `smmu` = `iommu@12000000` (`nvidia,tegra234-smmu`) |
| IOMMU group | 8, sole member `6800000.ethernet` |
| `dma-coherent` | present |
| `power-domains` | `<&bpmp 18>` (MGBEA) |
| `resets` | `<&bpmp 46>` mac, `<&bpmp 45>` pcs, `<&bpmp 47>` macsec_ns_rst |
| `clocks` | 13, all `<&bpmp …>`: 357, 361, 369, 373, 374, 375, 376, 377, 379, 380, 381, 378, 248 |
| `interconnects` | `<&mc … &emc>` ×2 |
| PHY | c45, MDIO address 0, `phy-mode = "10gbase-r"` |
| MAC address | `48:b0:2d:a5:12:80` |
| `nvidia,phy-reset-gpio` | `<&gpio@2200000 145 0>` → `gpio-657 (PAC.07)` |

Only MGBE0 is enabled. `eqos@2310000` and `mgbe1..3` are `status = "disabled"`.

Two findings from testing on the device shape the design:

**`nvidia,phy-reset-gpio` is inert.** `/sys/kernel/debug/gpio` shows `gpio-657` with no
owner even while `nvethernet` is bound and the link is up. No driver ever requests the
line. Upstream `dwmac-tegra` does not know the property exists. There is therefore no
GPIO anywhere in the passthrough path, and no `gpio-guest-proxy` is needed — which
removes a kernel-driver-pair plus QEMU-device subproject from scope.

**Upstream `dwmac-tegra` works at cold boot; `nvethernet`'s `.remove` poisons it.**
*Resolved 2026-07-09.*

Rebinding `6800000.ethernet` from `nvethernet` to `tegra-mgbe` on a running host fails —
the MAC identifies itself, `eth0` registers, but no PHY device is ever instantiated
(`/sys/bus/mdio_bus/devices/` stays empty):

```
mdio_bus stmmac-1: MDIO device at address 0 is missing.
tegra-mgbe 6800000.ethernet eth0: __stmmac_open: Cannot attach to PHY (error: -19)
```

Booting with `modprobe.blacklist=nvethernet` so `tegra-mgbe` claims the device first:

```
tegra-mgbe 6800000.ethernet eth0: configuring for phy/10gbase-r link mode
tegra-mgbe 6800000.ethernet eth0: Link is Up - 1Gbps/Full - flow control off
PASS: driver=tegra-mgbe phy=Aquantia AQR113C
```

So the driver is sound on this silicon and this DT node. `nvethernet`'s unbind leaves the
MAC or PHY in a state `dwmac-tegra` cannot recover from. That is irrelevant to the design:
the host DT overlay gives MGBE0 `compatible = "nvidia,dummy"`, so `nvethernet` never binds
it in the first place.

`dwmac-tegra`'s **own** unbind/rebind cycle is clean — verified by unbinding and rebinding
it on the cold-booted host, which re-attaches the PHY and brings the link back up. net-vm
can therefore be restarted without wedging the NIC.

Two facts fall out of this:

- The PHY is an **Aquantia AQR113C**. The guest needs `CONFIG_AQUANTIA_PHY`, not a Marvell
  driver.
- Disproven along the way: v6.6's short `mgbe_clks[]` list (omits `rx-input`, `rx-input-m`,
  `rx-pcs-m`, `rx-pcs-input`, `eee-pcs`; names `"mac"` twice) is byte-identical in v6.6,
  v6.12 and v6.18, and mainline drives this exact board with it. No kernel patch is needed.
  `Cannot get CSR clock` and `Invalid PTP clock rate` are benign — they appear on the
  working cold-booted system too.

## QEMU constraints (discovered 2026-07-09, they shape everything below)

**`-device vfio-platform` was removed in QEMU 10.2.** Ghaf's `qemu_kvm` is 11.0.1 and nixpkgs
has no older attr. Upstream's reasoning: *"the vfio-platform infrastructure requires some
adaptation at both kernel and qemu level. No such attempt has been done for years ... PCIe
passthrough shall be the mainline solution."* Verified: `hw/vfio/platform.c` is present at
`v10.1.5`, absent at `v10.2.0`. The **kernel** side is untouched (`CONFIG_VFIO_PLATFORM=y`,
`/sys/bus/platform/drivers/vfio-platform` exists on the device).

Consequence: net-vm's QEMU is pinned to **10.1.5**, the last release with the device, as a
separate package `ghaf-qemu-bpmp`. Every other VM stays on nixpkgs QEMU. The pin is a
liability — net-vm is network-facing and will not get QEMU security fixes after 10.1.x.

**A passthrough device needs an FDT binding in QEMU, or QEMU exits.** `virt` allows
`-device vfio-platform` as a dynamic sysbus device, but at machine-done
`add_fdt_node()` walks `bindings[]` in `hw/core/sysbus-fdt.c`; the only vfio-platform entry
matches compat `amd,xgbe-seattle-v1a`. Anything else falls through to
`error_report("Device %s can not be dynamically instantiated"); exit(1)`. There is no
catch-all `no_fdt_node` for vfio-platform, in 9.2, 10.1 or 11.

This is almost certainly why UARTI passthrough is disabled as "broken" in
`modules/profiles/orin.nix`, and it is why a hand-written `-dtb` never helped: QEMU exits
before the guest runs. `tegra234-netvm.dts` is in any case a dump of one specific QEMU 8.x
machine — one CPU, hardcoded initrd addresses, a `bootargs` naming a 23.11 store path — and
QEMU only rewrites `/memory` and `/chosen` when given `-dtb`, never `/cpus`.

Consequence: **guest device-tree nodes are emitted by QEMU, not hand-written.** The `/bpmp`
node comes from the `nvidia_bpmp_guest` patch. MGBE0's node comes from a
`VFIO_PLATFORM_BINDING("nvidia,tegra234-mgbe", ...)` added to `bindings[]`. Both then carry
the GPAs and SPIs QEMU actually assigned, and there is no `-dtb` anywhere in the design.

Corroboration: PR #1240's gpu-vm depends on `-device vfio-platform` too, and was written
against QEMU 9.2. It cannot work on today's Ghaf either.

## Architecture

```
net-vm: dwmac-tegra ──MMIO/DMA──▶ vfio-platform ──▶ MGBE0 @ 0x6800000
        │                                            (SMMU SID 6, IOMMU group 8)
        └─ clk/reset/power ─▶ guest bpmp node (virtual-pa = 0x090d0000)
                                 │ MMIO
                              QEMU nvidia_bpmp_guest device
                                 │ write(2)
                              /dev/bpmp-host ─▶ bpmp-host-proxy (allow-list) ─▶ real BPMP
```

Two independent channels.

The **data channel** is plain `vfio-platform`. MGBE0 is alone in its IOMMU group, so VFIO
can take it cleanly. Guest DMA goes through the SMMU with `IOVA = GPA`; VFIO type1 maps
guest RAM into the domain. No reserved carveouts, and therefore **no `mmio-base` QEMU
patch** — that patch exists for the GPU's 1:1 CMA requirement and costs `VIRT_PLATFORM_BUS`
growing to 130 GB and `VIRT_MEM` relocating to `0x2000000000`. MGBE0's windows are 64 KB
each and fit the stock 32 MB platform bus.

`dwmac-tegra` executes `writel(MGBE_SID /* 0x6 */, hv + MGBE_WRAP_AXI_ASID0_CTRL)` during
probe — it programs the stream ID itself, and `0x6` is exactly the SID in the host's
`iommus` property. Consequence: the host overlay must **not** retarget `iommus` to
`TEGRA234_SID_PASSTHROUGH`, the way `uarti_pt_host_overlay.dts` and
`gpu_passthrough_overlay.dts` both do. If it did, VFIO would program the SMMU for one
stream ID while the MAC emitted another, and every DMA would fault.

The **control channel** is BPMP virtualization. It is unavoidable: every clock, every
reset and the power domain on this node is a `<&bpmp …>` reference, and the guest has no
BPMP. The machinery exists in Ghaf already but is switched off (`modules/profiles/orin.nix`
lines 158-165) and only ships the kernel-5.15 variant of the proxy drivers, block-commented.
PR #1240 (`jetson-gpu-pt-rebase`, the live rebase of #1031) carries the 6.6 variant.

## Host changes

Reuse from PR #1240, in `modules/reference/hardware/jetpack/nvidia-jetson-orin/virtualization/`:

- `0001-Add-bpmp-virt-kernel-modules-for-kernel-6.6.patch` — the host and guest proxy
  drivers. Replaces the 5.15-only patch on `main`.
- `0003-bpmp-support-bpmp-virt.patch` — teaches the Tegra BPMP core to honour a
  `virtual-pa` DT property and redirect `tegra_bpmp_transfer` through the guest proxy.
- `0005-bpmp-overlay.patch` — adds `bpmp-virt` to the jetpack kernel overlay lists.
- `0002-Bpmp-host-allows-all-domains.patch` — bring-up only, see below.

New:

- No kernel-side fix for `dwmac-tegra` is required — see the driver finding above. The host
  overlay's `compatible = "nvidia,dummy"` is what keeps `nvethernet` away from the device.
- `mgbe0_pt_host_overlay.dts`: on `/bus@0/ethernet@6800000`, set
  `compatible = "nvidia,dummy"`. Nothing else. `reg`, `interrupts`, `iommus` and
  `dma-coherent` stay as they are. Neither `nvethernet` nor `tegra-mgbe` binds, and
  `vfio-platform` takes the device by `driver_override`. The IOMMU group is formed from
  `iommus` at device creation and is unaffected by `compatible`.
- `bindMgbe0.service`: `echo vfio-platform > …/6800000.ethernet/driver_override`, then
  `echo 6800000.ethernet > …/drivers/vfio-platform/bind`. Ordered before
  `microvm@net-vm.service`. Structurally a copy of the existing `bindSerial31d0000`.
- udev: `SUBSYSTEM=="vfio",GROUP="kvm"`, plus a rule granting the microvm user access to
  `/dev/bpmp-host` — QEMU opens it in `instance_init`, and microvm.nix does not run QEMU
  as root.

Changed:

- `modules/profiles/orin.nix`: `virtualization.host.bpmp.enable = true`.
- `bpmp_host_overlay.dts`: extend `allowed-clocks` with MGBE0's 13 clock IDs, `allowed-resets`
  with 45/46/47, and add the MGBEA power domain (18). During bring-up
  `0002-Bpmp-host-allows-all-domains.patch` short-circuits the allow-list entirely; the
  allow-list must be tightened and that patch dropped before this merges. Note the clock
  framework may also touch parent clocks (PLLs) not listed on the node — the allow-list has
  to cover whatever the guest actually requests, which step 5 of bring-up reveals.

`vfio_platform`'s `reset_required=false` patch is already applied on `main` and is what
lets VFIO bind a device with no VFIO reset driver.

## Guest changes (net-vm)

The bridge sits at guest physical address **`0x090d0000`**, not the `0x090c0000` used by
PR #1240. From QEMU 10 onward that slot is `[VIRT_ACPI_PCIHP]`, which `ARM_VIRT` selects, so
the original address overlaps a live MMIO region. The guest `bpmp` node's `virtual-pa` must
match whatever the QEMU patch uses.

- **QEMU package, scoped to net-vm only.** Set `microvm.qemu.package` inside net-vm's
  `hardware.definition.netvm.extraModules`, to `ghaf-qemu` plus
  `0001-nvidia-bpmp-guest-driver-initial-commit.patch`. Deliberately *not* via
  `ghaf.virtualization.qemu.package`: that option is consumed by
  `modules/microvm/common/vm-qemu.nix` for every VM, and the patch calls
  `nvidia_bpmp_guest_create()` unconditionally from `create_virtio_devices()`, which opens
  `/dev/bpmp-host`. admin-vm and gui-vm have no business opening it.
- **Hand-written guest DTB** `tegra234-netvm-mgbe.dts`, passed as `-dtb`, built by a `dtc`
  derivation. Modelled on the existing `tegra234-netvm.dts`. Contents beyond the standard
  QEMU `virt` skeleton:
  - `bpmp { compatible = "nvidia,tegra234-bpmp", "nvidia,tegra186-bpmp"; virtual-pa = <0x0 0x090d0000>; }`
  - `platform-bus@c000000` containing `ethernet@…` with:
    - three `reg` windows — `hypervisor`, `mac`, `xpcs`. `macsec-base` is not needed;
      `dwmac-tegra` fetches its windows by name.
    - one interrupt. `dwmac-tegra` takes `platform_get_irq(pdev, 0)`, i.e. `common`.
    - the clocks `dwmac-tegra` asks for by name — the corrected `mgbe_clks[]` list from the
      host patch, so the two must be kept in step — plus `mac` and `pcs` resets and
      `power-domains = <&bpmp 18>`.
    - `phy-handle` → `mdio { phy@0 { compatible = "ethernet-phy-ieee802.3-c45"; reg = <0>; } }`
    - `mac-address = [48 b0 2d a5 12 80]`
    - no `interconnects` — the guest has no `&mc`/`&emc`.
  - `ranges` on the platform bus translate the real hardware addresses the DT node names
    to whatever GPA QEMU assigned each VFIO region, as `tegra234-gpuvm.dts` does. PR #1240's
    `0003-Print-irqs.patch` reports the SPIs QEMU allocated.
- **Guest kernel pinned to `linuxPackages_6_12`.** net-vm otherwise takes nixpkgs' default
  (6.18). From v6.13 (commit `426046e2d`) `tegra_mgbe_probe()` reads the SMMU stream ID via
  `tegra_dev_iommu_get_stream_id()`, which requires an `iommu_fwspec`; a QEMU `virt` guest
  has no IOMMU, so probe would return `-EINVAL`. v6.12 hardcodes `MGBE_SID 0x6` — exactly
  MGBE0's stream ID — and already carries the Oct-2024 serdes bring-up fix (`1cff6ff30`)
  that v6.6 lacks. Config: `TEGRA_BPMP_GUEST_PROXY=y`, `DWMAC_TEGRA=y`, `STMMAC_ETH=y`,
  a c45 PHY driver, plus the Tegra BPMP clock, reset and power-domain providers. `VFIO` and
  `VIRTIO_MMIO` are already enabled by `bpmp-virt-common`. No nvidia-oot module tree in
  net-vm.
- The existing WLAN passthrough (`-device vfio-pci,host=0001:01:00.0`) is untouched and
  continues to work; different bus, no interaction. Note that in practice net-vm's uplink
  today is a **USB ethernet dongle** (`enp0s11u2`); the passed-through WLAN (`wlp0s4f0`) is
  down. So the wired MAC is an addition to, not a replacement for, net-vm's current WAN.

## Bring-up sequence

Each step is independently falsifiable. Do not proceed past a failing step.

1. **Fix and validate `dwmac-tegra` on the host.** Apply the `mgbe_clks[]` patch, cold-boot
   with `nvethernet` blacklisted, let `tegra-mgbe` bind. Expect PHY attach, link up, DHCP.
   If the PHY is still unreachable, the clock list was not the cause and the driver choice
   reverts to `nvethernet` in the guest — a heavier guest DT (four windows, eight IRQs, the
   nvidia-oot tree) but the scaffolding in every other section is unchanged.
2. **Enable bpmp-virt on the host alone.** Verify `/dev/bpmp-host` appears and the host boots
   normally with all existing VMs.
3. **Bind MGBE0 to `vfio-platform`.** Host loses `eth0`. Verify the IOMMU group appears under
   `/dev/vfio/`.
4. **Boot net-vm with the custom DTB, no `vfio-platform` device yet.** Proves the hand-written
   guest DT boots at all. This is the checkpoint where the existing UARTI path is known to
   fail — see Risks.
5. **Add `-device vfio-platform,host=6800000.ethernet`.** Verify `dwmac-tegra` probes in the
   guest and that BPMP clock/reset requests arrive at the host proxy. Record which clock IDs
   the guest actually requests, to tighten the allow-list.
6. **Link up, DHCP inside net-vm, route traffic through it.**

## Risks

- **The UARTI passthrough is already broken.** `modules/profiles/orin.nix` disables it with
  "uarti passthrough is currently broken, it will be enabled later after a further analysis."
  Step 4 exercises the same custom-guest-DTB machinery. If that machinery is what's broken,
  it gets debugged before any ethernet-specific code matters. This is the largest schedule
  risk in the plan and it is entirely upstream of the ethernet work.
- **`/dev/bpmp-host` permissions.** QEMU opens it at `instance_init`, before dropping into
  the VM, and microvm.nix runs QEMU as a non-root user. Unproven; `gpuvm.nix` from PR #1240
  may already solve it — check there first.
- **BPMP allow-list completeness.** The guest's clock framework may request parent clocks
  (PLLs) that are not named on the MGBE0 node. The `allows-all-domains` patch masks this
  during bring-up and will hide the problem until it is removed.
- **`dwmac-tegra` hardcodes SID 6.** Any future overlay that retargets `iommus` on this node
  breaks DMA silently — faults, not a probe error. And any bump of net-vm's guest kernel past
  v6.12 turns that hardcode into a DT read the guest cannot satisfy, breaking probe outright.
- **No aarch64 builder.** Every image goes through the cross target
  `nvidia-jetson-orin-agx-debug-from-x86_64`. Kernel and QEMU changes mean full rebuilds;
  iterations are slow.
- **Serial is the only recovery path.** `ghaf-host` has no NIC of its own and no known
  inbound SSH route; it reaches the network through net-vm. A net-vm that will not boot
  leaves `/dev/ttyACM0` as the only way in.
- **No `interconnects` in the guest** means no EMC bandwidth request. Irrelevant at 1 Gbps.
  Possibly not at 10 Gbps; revisit if the link is ever negotiated above 1 G.
- **Host loses a working NIC.** With a cable plugged in, `ghaf-host` brings `eth0` up and
  takes a DHCP lease on it (observed: `192.168.68.108`), giving the host direct LAN access
  and a second route alongside net-vm at `192.168.100.1`. Passthrough removes that. Recovery
  is over serial (`/dev/ttyACM0`, `ghaf-host login:`) or via the ProxyJump through net-vm.
- **`nixos-rebuild switch` cannot change the kernel on this target.**
  `modules/profiles/orin.nix` `mkForce`s `system.build.installBootLoader` to a stub that
  runs `bootctl install/update` and `exit 0` — it never writes a
  `/boot/loader/entries/nixos-generation-N.conf`. The device has exactly one entry and one
  generation, and `loader.conf` has `timeout 0`. Any task that changes the kernel (all the
  BPMP work) must therefore either write a loader entry by hand, fix the stub, or reflash.
  A one-shot entry plus `bootctl set-oneshot` is the safe way to test a kernel change: the
  default generation stays default, so a failed boot recovers on the next power cycle.
