// SPDX-License-Identifier: GPL-2.0-only
// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
/*
 * dce-iso-anchor: claim the nvdisplay ISO SMMU stream (smmu_iso StreamID 1)
 * with a translating domain and install the DCE high-IOVA -> carveout
 * mappings the display FE's scanout DMA needs under GPU passthrough.
 *
 * Background: the guest hands the host-owned DCE R5 ctxdma FrameAddrs in the
 * native display high-IOVA range (DCE_HI_BASE + carveout phys). The FE's ISO
 * scanout fetch issues those under StreamID 1 through smmu_iso
 * (iommu@10000000). The host runs headless, display@13800000 is unbound, no
 * device claims SID 1, and arm-smmu.disable_bypass=0 leaves the stream in
 * BYPASS -- the high IOVA goes out as a raw physical to nowhere and the panel
 * scans black. (Raw ISO addresses are not an option: the R5 aborts the whole
 * UPDATE on a non-IOVA ctxdma address -- no completion, no raster.)
 *
 * Binding an anchor device to <&smmu_iso 1> gives SID 1 a translating DMA
 * domain; mapping DCE_HI_BASE+carveout -> carveout there makes the FE's
 * scanout fetch land on the real pixels. A previous attempt hung this off
 * dce_host_proxy itself (dc382ce4) and broke the proxy's own IPC; the anchor
 * is a separate, DMA-less device so nothing else changes context.
 *
 * The DT node is created at runtime from an embedded overlay (the flashed DTB
 * carries no anchor node; the live tree has __symbols__, so &smmu_iso
 * resolves). Loadable any time after boot, before gpu-vm starts.
 */

#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/iommu.h>
#include <linux/delay.h>

#include "dce-iso-anchor-dtbo.h"

#define DCE_HI_BASE 0x7f00000000ULL

static const struct { u64 pa; u64 size; } dce_hi_ranges[] = {
	{ 0x60000000, 0x04000000 },  /* vm_hs */
	{ 0x80000000, 0x30000000 },  /* vm_cma */
	{ 0xb0000000, 0x08000000 },  /* scanout */
	{ 0xe2000000, 0x04000000 },  /* disp-vm CMA (split-RAM low bank): NVKMS
				      * allocates 3440x1440 scanout from here, not
				      * from 0xb0 scanout pool. Inside 1:1 dispram_lo
				      * (0xb8..0xe6), stops before the DMA32/WLAN hole.
				      * Without this, SID-7 faults on 0x7fe2xxxxxx. */
};

static int ovcs_id;
static struct platform_device *anchor_pdev; /* only if we created it */
static struct platform_device *niso_anchor_pdev;

static int dce_iso_anchor_probe(struct platform_device *pdev)
{
	struct iommu_domain *dom = iommu_get_domain_for_dev(&pdev->dev);
	int i, ret;

	if (!dom) {
		dev_err(&pdev->dev, "no iommu domain (iommus missing?)\n");
		return -ENODEV;
	}
	dev_info(&pdev->dev, "iso domain type=%d\n", dom->type);

	for (i = 0; i < ARRAY_SIZE(dce_hi_ranges); i++) {
		u64 iova = DCE_HI_BASE + dce_hi_ranges[i].pa;

		if (iommu_iova_to_phys(dom, iova) == dce_hi_ranges[i].pa) {
			dev_info(&pdev->dev, "0x%llx already mapped\n", iova);
			continue;
		}
		ret = iommu_map(dom, iova, dce_hi_ranges[i].pa,
				dce_hi_ranges[i].size,
				IOMMU_READ | IOMMU_WRITE | IOMMU_CACHE,
				GFP_KERNEL);
		dev_info(&pdev->dev, "iso map 0x%llx -> 0x%llx sz 0x%llx = %d\n",
			 iova, dce_hi_ranges[i].pa, dce_hi_ranges[i].size, ret);
		if (ret)
			return ret;
	}

	return 0;
}

static const struct of_device_id dce_iso_anchor_of_match[] = {
	{ .compatible = "nvidia,dce-iso-anchor" },
	{ }
};
MODULE_DEVICE_TABLE(of, dce_iso_anchor_of_match);

static struct platform_driver dce_iso_anchor_driver = {
	.probe = dce_iso_anchor_probe,
	.driver = {
		.name = "dce-iso-anchor",
		.of_match_table = dce_iso_anchor_of_match,
	},
};

/* Create the platform device for an overlay-added root child unless
 * OF_DYNAMIC's bus notifier already did. Returns the created pdev (NULL if
 * one existed or creation failed); drops the lookup reference either way. */
static struct platform_device *anchor_pdev_ensure(struct device_node *np)
{
	struct platform_device *existing = of_find_device_by_node(np);

	if (existing) {
		put_device(&existing->dev);
		return NULL;
	}
	return of_platform_device_create(np, NULL, NULL);
}

static int __init dce_iso_anchor_init(void)
{
	struct device_node *np;
	int ret;

	ret = of_overlay_fdt_apply(dce_iso_anchor_dtbo, dce_iso_anchor_dtbo_len,
				   &ovcs_id, NULL);
	if (ret) {
		pr_err("dce_iso_anchor: overlay apply failed: %d\n", ret);
		return ret;
	}

	np = of_find_node_by_path("/dce_iso_anchor");
	if (!np) {
		pr_err("dce_iso_anchor: node missing after overlay\n");
		of_overlay_remove(&ovcs_id);
		return -ENODEV;
	}
	anchor_pdev = anchor_pdev_ensure(np);
	of_node_put(np);

	/* Same for the NISO anchor (smmu_niso0 SID 7 = TEGRA234_SID_NVDISPLAY,
	 * the stock stream for display pushbuffer/instmem/notifier traffic). */
	np = of_find_node_by_path("/dce_niso_anchor");
	if (np) {
		niso_anchor_pdev = anchor_pdev_ensure(np);
		of_node_put(np);
	}

	ret = platform_driver_register(&dce_iso_anchor_driver);
	if (ret) {
		pr_err("dce_iso_anchor: driver register failed: %d\n", ret);
		if (niso_anchor_pdev)
			of_platform_device_destroy(&niso_anchor_pdev->dev, NULL);
		if (anchor_pdev)
			of_platform_device_destroy(&anchor_pdev->dev, NULL);
		of_overlay_remove(&ovcs_id);
	}

	return ret;
}
module_init(dce_iso_anchor_init);

/* Deliberately no module_exit: this module must live for the boot. Binding
 * the anchors makes Tegra MC retag the NVDISPLAYR/NVDISPLAYR1 client SID
 * overrides (MC+0x490/+0x508) from PASSTHROUGH 0x7f to the anchors' SMMU
 * SIDs, and nothing restores them on unbind -- unloading would tear down the
 * translating domains while the physical scanout clients keep emitting into
 * them (display faults / white panel). No exit handler makes rmmod
 * impossible instead of unsafe. */

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("smmu_iso SID-1 anchor: DCE high-IOVA scanout mappings");
