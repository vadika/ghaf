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

**Upstream `dwmac-tegra` probes but cannot reach the PHY.** Rebinding
`6800000.ethernet` from `nvethernet` to `tegra-mgbe` on the running host:

```
tegra-mgbe 6800000.ethernet: User ID: 0x76, Synopsys ID: 0x31
tegra-mgbe 6800000.ethernet: 	XGMAC2
...
mdio_bus stmmac-1: MDIO device at address 0 is missing.
tegra-mgbe 6800000.ethernet eth0: __stmmac_open: Cannot attach to PHY (error: -19)
```

Clocks, resets and all three named `reg` windows resolve from NVIDIA's DT node; the MAC
identifies itself correctly; `eth0` registers. Only MDIO fails. Ruled out: the PHY reset
GPIO (never requested), and `nvethernet` still holding the device (`rmmod`'d, same
result). Reproducible.

Prime suspect, **not yet root-caused** — the v6.6 clock list is short and contains a
duplicate:

```c
static const char *const mgbe_clks[] = {
	"rx-pcs", "tx", "tx-pcs", "mac-divider", "mac", "mgbe", "ptp-ref", "mac"
};
```

`rx-input`, `rx-input-m`, `rx-pcs-m`, `rx-pcs-input` and `eee-pcs` are absent, and
`"mac"` appears twice. `nvethernet` enables all 13. Later mainline corrects the list.
Proving or disproving this is step 1 of implementation, and it gates the guest driver
choice.

## Architecture

```
net-vm: dwmac-tegra ──MMIO/DMA──▶ vfio-platform ──▶ MGBE0 @ 0x6800000
        │                                            (SMMU SID 6, IOMMU group 8)
        └─ clk/reset/power ─▶ guest bpmp node (virtual-pa = 0x090c0000)
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

- Kernel patch fixing `mgbe_clks[]` in `drivers/net/ethernet/stmicro/stmmac/dwmac-tegra.c`:
  add `rx-input`, `rx-input-m`, `rx-pcs-m`, `rx-pcs-input`, `eee-pcs`; drop the duplicate
  `"mac"`.
- `mgbe0_passthrough_overlay.dts`: on `/bus@0/ethernet@6800000`, set
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
  - `bpmp { compatible = "nvidia,tegra234-bpmp", "nvidia,tegra186-bpmp"; virtual-pa = <0x0 0x090c0000>; }`
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
- **Guest kernel**: `TEGRA_BPMP_GUEST_PROXY=y`, `DWMAC_TEGRA=y`, plus the Tegra BPMP clock,
  reset and power-domain providers. `VFIO`, `VIRTIO_MMIO` are already enabled by
  `bpmp-virt-common`. No nvidia-oot module tree in net-vm.
- The existing WLAN passthrough (`-device vfio-pci,host=0001:01:00.0`) is untouched and
  continues to work; different bus, no interaction.

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
  breaks DMA silently — faults, not a probe error.
- **No `interconnects` in the guest** means no EMC bandwidth request. Irrelevant at 1 Gbps.
  Possibly not at 10 Gbps; revisit if the link is ever negotiated above 1 G.
- **Host loses its only NIC.** Already effectively true — `eth0` is down, unbridged, and the
  host's default route goes via net-vm at `192.168.100.1`. Recovery is over serial
  (`/dev/ttyACM0`, `ghaf-host login:`).
