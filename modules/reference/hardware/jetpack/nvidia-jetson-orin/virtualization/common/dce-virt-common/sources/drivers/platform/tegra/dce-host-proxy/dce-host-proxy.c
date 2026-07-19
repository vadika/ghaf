// SPDX-License-Identifier: GPL-2.0-only
// dce-host-proxy: relays a guest's DCE display IPC to the real,
// host-owned DCE via the CPU_RM client interface exported by tegra-dce.
// Char-device scaffold, bounds-check and bounce-buffer hygiene mirror
// bpmp-host-proxy.c; the relay call and client registration are DCE's.
#include <linux/module.h>	  // Core header for modules.
#include <linux/device.h>	  // Supports driver model.
#include <linux/kernel.h>	  // Kernel header for convenient functions.
#include <linux/fs.h>		  // File-system support.
#include <linux/uaccess.h>	  // User access copy function support.
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/mod_devicetable.h>	  // struct of_device_id (full definition)
#include <linux/poll.h>
#include <linux/sched.h>
#include <linux/spinlock.h>
#include <linux/wait.h>
#include <linux/debugfs.h>
#include <linux/io.h>
#include <linux/seq_file.h>
#include <linux/iommu.h>
#include <linux/platform/tegra/dce/dce-client-ipc.h>
#include "dce-host-proxy.h"

/*
 * DIAGNOSTIC: translate display surface IOVAs through the passed-through
 * display's VFIO IOMMU domain (group 15), via the safe iommu framework API
 * (no MMIO -- unlike the register peek, this cannot fault the host). Shows
 * exactly where the display hardware's DMA to each IOVA actually lands, so we
 * can see whether the guest CPU's 1:1 MMIO view and the display's DMA mapping
 * agree. The display DMA (SID_NVDISPLAY) shares the domain of the passed
 * display-channel device 13870000.disp_chan_pt.
 */
static int dce_iova_show(struct seq_file *s, void *unused)
{
	static const u64 iovas[] = {
		0x60010000,  /* pushbuffer (vm_hs, R5 reads OK) */
		0x88340000,  /* boot notifier (vm_cma) */
		0x8e000000,  /* later notifier (vm_cma) */
		0x88400000,  /* coherent surface (0xc0c0c0 seen from CPU) */
		0x80000000,  /* vm_cma base */
		0xb0000000,  /* scanout carveout */
	};
	struct device *dev;
	struct iommu_domain *domain;
	int i;

	dev = bus_find_device_by_name(&platform_bus_type, NULL,
				      "13870000.disp_chan_pt");
	if (!dev) {
		seq_puts(s, "13870000.disp_chan_pt not found\n");
		return 0;
	}
	domain = iommu_get_domain_for_dev(dev);
	if (!domain) {
		seq_puts(s, "no iommu domain for disp_chan_pt\n");
		put_device(dev);
		return 0;
	}
	seq_printf(s, "disp_chan_pt domain type=%d\n", domain->type);
	for (i = 0; i < ARRAY_SIZE(iovas); i++) {
		phys_addr_t pa = iommu_iova_to_phys(domain, iovas[i]);

		seq_printf(s, "IOVA 0x%09llx -> PA 0x%09llx  %s\n",
			   iovas[i], (u64)pa,
			   !pa ? "UNMAPPED" :
			   (pa == iovas[i] ? "identity" : "REMAPPED"));
	}
	put_device(dev);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(dce_iova);
static struct dentry *dce_iova_dbg;

/*
 * EXPERIMENT (high-IOVA mirror): native hands the R5 high display-SMMU IOVAs
 * (0x7fff_xxxxxx) via a TRANSLATING domain; the guest hands it low identity
 * addresses via the VFIO identity domain. To mirror native, the guest offsets
 * each surface FrameAddr by DCE_HI_BASE (nvdisplay patch), and here we add the
 * matching translating mappings into the display's VFIO domain so the high IOVA
 * resolves back to the real carveout page. If the R5 then writes the notifier,
 * the "R5 needs its native IOVA range" hypothesis holds -- and because the high
 * IOVA maps back to the carveout, the guest reads the notifier normally.
 *
 * Read dce_himap (any read) to install the mappings; must be done AFTER the
 * gpu-vm has attached the display to its VFIO domain (group 15).
 */
#define DCE_HI_BASE 0x7f00000000ULL

static const struct { u64 pa; u64 size; } dce_hi_ranges[] = {
	{ 0x60000000, 0x04000000 },  /* vm_hs */
	{ 0x80000000, 0x30000000 },  /* vm_cma */
	{ 0xb0000000, 0x08000000 },  /* scanout */
	{ 0xe2000000, 0x04000000 },  /* disp-vm CMA (split-RAM low bank) -- mirror
				      * of the iso-anchor range; NVKMS scanout lands
				      * at 0xe2, not the 0xb0 pool. See dce-iso-anchor.c. */
};

static int dce_himap_show(struct seq_file *s, void *unused)
{
	struct device *dev;
	struct iommu_domain *domain;
	int i, ret;

	dev = bus_find_device_by_name(&platform_bus_type, NULL,
				      "13870000.disp_chan_pt");
	if (!dev) {
		seq_puts(s, "disp_chan_pt not found (gpu-vm not up?)\n");
		return 0;
	}
	domain = iommu_get_domain_for_dev(dev);
	if (!domain) {
		seq_puts(s, "no domain\n");
		put_device(dev);
		return 0;
	}
	for (i = 0; i < ARRAY_SIZE(dce_hi_ranges); i++) {
		u64 iova = DCE_HI_BASE + dce_hi_ranges[i].pa;

		/* Skip if already present (re-read is idempotent). */
		if (iommu_iova_to_phys(domain, iova) == dce_hi_ranges[i].pa) {
			seq_printf(s, "0x%llx -> 0x%llx already mapped\n",
				   iova, dce_hi_ranges[i].pa);
			continue;
		}
		/* IOMMU_CACHE: nvkms maps the notifier WRITE_BACK (SOC NISO is
		 * IO-coherent); a non-snooping mirror write would land in DRAM
		 * below the guest CPU's live cache line and never be seen. */
		ret = iommu_map(domain, iova, dce_hi_ranges[i].pa,
				dce_hi_ranges[i].size,
				IOMMU_READ | IOMMU_WRITE | IOMMU_CACHE,
				GFP_KERNEL);
		seq_printf(s, "iommu_map 0x%llx -> 0x%llx size 0x%llx = %d\n",
			   iova, dce_hi_ranges[i].pa, dce_hi_ranges[i].size, ret);
	}
	put_device(dev);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(dce_himap);
static struct dentry *dce_himap_dbg;

/*
 * DIAGNOSTIC (AST verification): dump the DCE R5's live AST translation table.
 * The R5 owns and programs its AST; the CPU cannot devmem it (wrong mapping
 * attribute), but a device-memory ioremap of the DCE register aperture can read
 * it. Each AST region maps an input (slave) address window to an output
 * (master) physical base. This tells us whether the R5's AST covers the guest
 * carveout surfaces DCE must DMA to (notifier, scanout) -- if it does not,
 * DCE's writes are mistranslated, which would explain the read/write asymmetry.
 */
#define DCE_APERTURE_BASE 0x0d800000UL
#define DCE_APERTURE_SIZE 0x00800000UL

static int dce_ast_show(struct seq_file *s, void *unused)
{
	void __iomem *regs;
	int ast, r;

	regs = ioremap(DCE_APERTURE_BASE, DCE_APERTURE_SIZE);
	if (!regs) {
		seq_puts(s, "ioremap failed\n");
		return 0;
	}

	for (ast = 0; ast < 2; ast++) {
		u32 base = ast ? 0x50000 : 0x40000;

		seq_printf(s, "AST%d control=0x%08x\n", ast,
			   readl(regs + base + 0x0));
		for (r = 0; r < 8; r++) {
			u32 rb = base + 0x100 + r * 0x20;
			u32 slo = readl(regs + rb + 0x00);
			u32 shi = readl(regs + rb + 0x04);
			u32 klo = readl(regs + rb + 0x08);
			u32 khi = readl(regs + rb + 0x0c);
			u32 mlo = readl(regs + rb + 0x10);
			u32 mhi = readl(regs + rb + 0x14);

			if (!(slo | shi | klo | khi | mlo | mhi))
				continue;	/* empty region */
			seq_printf(s,
				"AST%d region%d: slave=0x%08x%08x mask=0x%08x%08x master=0x%08x%08x\n",
				ast, r, shi, slo, khi, klo, mhi, mlo);
		}
	}

	iounmap(regs);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(dce_ast);

static struct dentry *dce_ast_dbg;

/*
 * DIAGNOSTIC (notifier-write test): read an arbitrary physical page from the
 * host via ioremap -- authoritative, bypasses STRICT_DEVMEM, the vfio claim on
 * the guest carveout, and any guest-side cache. Write the target phys to
 * dce_peek_addr, then read dce_peek to dump the first 64 words. Answers whether
 * the R5 actually DMA-writes the notifier at the FrameAddr it was handed
 * (fixable guest-side observation bug) vs never writes it (firmware).
 */
static u64 dce_peek_addr;
static struct dentry *dce_peek_dbg;

static void dce_peek_dump(struct seq_file *s, const char *tag, void __iomem *p)
{
	int i;

	seq_printf(s, "%s:", tag);
	for (i = 0; i < 32; i++) {
		if ((i & 7) == 0)
			seq_printf(s, "\n+0x%03x:", i * 4);
		seq_printf(s, " %08x", readl(p + i * 4));
	}
	seq_puts(s, "\n");
}

static int dce_peek_show(struct seq_file *s, void *unused)
{
	u64 base = dce_peek_addr & ~0xfffULL;
	void __iomem *pc, *pu;

	if (!dce_peek_addr) {
		seq_puts(s, "set dce_peek_addr first\n");
		return 0;
	}
	seq_printf(s, "phys 0x%llx (cached vs uncached -- differ => coherency bug)\n",
		   base);

	/* Cached view: what a normal CPU/guest read sees. */
	pc = ioremap_cache(base, 0x1000);
	if (pc) {
		dce_peek_dump(s, "cached  ", pc);
		iounmap(pc);
	} else {
		seq_puts(s, "cached ioremap failed\n");
	}

	/* Uncached view: what the R5's coherent DMA write actually left in DRAM,
	 * regardless of CPU cache state. If this is written but cached reads zero,
	 * the R5 DID write and the bug is coherency (fixable), not a no-write. */
	pu = ioremap(base, 0x1000);
	if (pu) {
		dce_peek_dump(s, "uncached", pu);
		iounmap(pu);
	} else {
		seq_puts(s, "uncached ioremap failed\n");
	}
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(dce_peek);


#define DEVICE_NAME "dce-host"    // Device name.
#define CLASS_NAME  "dce_chardrv" // The device class -- distinct from
				  // bpmp-host-proxy's "chardrv" so both
				  // drivers can be built into the same
				  // kernel without a duplicate sysfs class.

MODULE_LICENSE("GPL");						 ///< The license type -- this affects available functionality
MODULE_AUTHOR("Vadim Likholetov");					 ///< The author -- visible when you use modinfo
MODULE_DESCRIPTION("NVidia DCE Host Proxy Kernel Module"); ///< The description -- see modinfo
MODULE_VERSION("0.1");						 ///< A version number to inform users


#define DCE_HOST_VERBOSE    0

#if DCE_HOST_VERBOSE
#define deb_info(...)     printk(KERN_INFO DEVICE_NAME ": "__VA_ARGS__)
#else
#define deb_info(...)
#endif

#define deb_error(...)    printk(KERN_ALERT DEVICE_NAME ": "__VA_ARGS__)
#define deb_warn(...)     printk(KERN_WARNING DEVICE_NAME ": "__VA_ARGS__)

/**
 * Important variables that store data and keep track of relevant information.
 */
static int major_number;

static struct class *dce_host_proxy_class = NULL;	///< The device-driver class struct pointer
static struct device *dce_host_proxy_device = NULL; ///< The device-driver device struct pointer

// Lazily-registered CPU_RM IPC client. Registered on first write(), guarded
// by dce_host_client_lock, torn down in remove().
static DEFINE_MUTEX(dce_host_client_lock);
static u32 dce_host_client_handle;
static bool dce_host_client_registered;

/*
 * Reverse doorbell, host end.
 *
 * DCE pushes unsolicited notifications (RM_NOTIFY -- vblank, and crucially the
 * flip-completion event nvidia-drm's atomic commit blocks on) on its own IPC
 * channel. Those are delivered to whoever registered the RM_EVENT client; with
 * nobody registered, tegra-dce drops them ("Failed to retrieve client info for
 * ch_type: [3]") and the guest's modeset times out.
 *
 * So register RM_EVENT too, and turn its callback into a queue the bridge can
 * drain: events land in a small ring, read() pops one, poll() reports readable.
 * The sync relay keeps using write(); read() was an unused stub.
 */
static DEFINE_MUTEX(dce_host_event_client_lock);
static u32 dce_host_event_handle;
static bool dce_host_event_registered;

#define DCE_EVT_SLOTS 8

static struct dce_host_event *dce_evt_ring;
static unsigned int dce_evt_head, dce_evt_tail;	 /* head==tail => empty */
static DEFINE_SPINLOCK(dce_evt_lock);
static DECLARE_WAIT_QUEUE_HEAD(dce_evt_wq);
static unsigned long dce_evt_dropped;
static unsigned long dce_evt_count;

static bool dce_evt_pending(void)
{
	bool pending;
	unsigned long flags;

	spin_lock_irqsave(&dce_evt_lock, flags);
	pending = dce_evt_head != dce_evt_tail;
	spin_unlock_irqrestore(&dce_evt_lock, flags);

	return pending;
}

/**
 * Prototype functions for file operations.
 */
static int open(struct inode *, struct file *);
static int close(struct inode *, struct file *);
static ssize_t read(struct file *, char *, size_t, loff_t *);
static ssize_t write(struct file *, const char *, size_t, loff_t *);
static __poll_t dce_host_poll(struct file *, struct poll_table_struct *);

/**
 * File operations structure and the functions it points to.
 */
static struct file_operations fops =
	{
		.owner = THIS_MODULE,
		.open = open,
		.release = close,
		.read = read,
		.write = write,
		.poll = dce_host_poll,
};

/*
 * Queue one DCE notification for the bridge to pick up. Called from tegra-dce's
 * IPC callback, which may run in atomic context, so this must not sleep.
 *
 * The ring drops the oldest event when full rather than blocking DCE: a stale
 * vblank is worth less than stalling the R5's notify channel. Drops are counted
 * and warned about, because losing a flip completion hangs a guest modeset.
 */
static void dce_host_proxy_queue_event(u32 interface_type, u32 msg_length,
				       void *msg_data)
{
	struct dce_host_event *e;
	unsigned long flags;
	unsigned int next;

	if (msg_length > DCE_HOST_EVENT_MAX_DATA)
		msg_length = DCE_HOST_EVENT_MAX_DATA;

	spin_lock_irqsave(&dce_evt_lock, flags);

	if (!dce_evt_ring) {
		spin_unlock_irqrestore(&dce_evt_lock, flags);
		return;
	}

	next = (dce_evt_head + 1) % DCE_EVT_SLOTS;
	if (next == dce_evt_tail) {
		/* Full: drop the oldest so the newest (most relevant) survives. */
		dce_evt_tail = (dce_evt_tail + 1) % DCE_EVT_SLOTS;
		dce_evt_dropped++;
	}

	e = &dce_evt_ring[dce_evt_head];
	e->iface = interface_type;
	e->size = msg_length;
	if (msg_length && msg_data)
		memcpy(e->data, msg_data, msg_length);

	dce_evt_head = next;
	dce_evt_count++;

	spin_unlock_irqrestore(&dce_evt_lock, flags);

	// Loud for the first few, then silent: enough to confirm on hardware that
	// DCE really does push async notifications once RM_EVENT is claimed,
	// without spamming the log at vblank rate.
	if (dce_evt_count <= 4)
		pr_info("dce_host_proxy: EVENT #%lu iface=%u len=%u\n",
			dce_evt_count, interface_type, msg_length);

	wake_up_interruptible(&dce_evt_wq);
}

/*
 * Callback for the CPU_RM IPC client, invoked by tegra-dce when DCE sends an
 * unsolicited notification on the sync interface.
 */
static void dce_host_proxy_ipc_cb(u32 handle, u32 interface_type,
				   u32 msg_length, void *msg_data,
				   void *usr_ctx)
{
	deb_info("cpu_rm notify: handle=%u iface=%u len=%u\n",
		 handle, interface_type, msg_length);

	dce_host_proxy_queue_event(interface_type, msg_length, msg_data);
}

/*
 * Callback for the RM_EVENT IPC client: DCE's asynchronous notify channel.
 * This is the one that carries the flip-completion event.
 */
static void dce_host_proxy_event_cb(u32 handle, u32 interface_type,
				    u32 msg_length, void *msg_data,
				    void *usr_ctx)
{
	dce_host_proxy_queue_event(interface_type, msg_length, msg_data);
}

/**
 * Initializes module at installation
 */
static int dce_host_proxy_probe(struct platform_device *pdev)
{
	deb_info("%s, installing module.", __func__);

	// Reverse-doorbell event ring. Allocated up front so the DCE callback --
	// which can fire as soon as the RM_EVENT client is registered, in atomic
	// context -- never has to allocate.
	dce_evt_ring = kcalloc(DCE_EVT_SLOTS, sizeof(*dce_evt_ring), GFP_KERNEL);
	if (!dce_evt_ring)
		return -ENOMEM;

	// Allocate a major number for the device.
	major_number = register_chrdev(0, DEVICE_NAME, &fops);
	if (major_number < 0)
	{
		deb_error("could not register number.\n");
		kfree(dce_evt_ring);
		dce_evt_ring = NULL;
		return major_number;
	}
	deb_info("registered correctly with major number %d\n", major_number);

	// Register the device class
	dce_host_proxy_class = class_create(CLASS_NAME);
	if (IS_ERR(dce_host_proxy_class))
	{ // Check for error and clean up if there is
		unregister_chrdev(major_number, DEVICE_NAME);
		deb_error("Failed to register device class\n");
		return PTR_ERR(dce_host_proxy_class); // Correct way to return an error on a pointer
	}
	deb_info("device class registered correctly\n");

	// Register the device driver
	dce_host_proxy_device = device_create(dce_host_proxy_class, NULL, MKDEV(major_number, 0), NULL, DEVICE_NAME);
	if (IS_ERR(dce_host_proxy_device))
	{								 // Clean up if there is an error
		class_destroy(dce_host_proxy_class);
		unregister_chrdev(major_number, DEVICE_NAME);
		deb_error("Failed to create the device\n");
		return PTR_ERR(dce_host_proxy_device);
	}

	deb_info("device class created correctly\n"); // Made it! device was initialized

	// DIAGNOSTIC: /sys/kernel/debug/dce_ast dumps the R5's live AST table;
	// dce_peek_addr + dce_peek read an arbitrary physical page (notifier test).
	dce_ast_dbg = debugfs_create_file("dce_ast", 0444, NULL, NULL,
					  &dce_ast_fops);
	debugfs_create_x64("dce_peek_addr", 0644, NULL, &dce_peek_addr);
	dce_peek_dbg = debugfs_create_file("dce_peek", 0444, NULL, NULL,
					   &dce_peek_fops);
	dce_iova_dbg = debugfs_create_file("dce_iova", 0444, NULL, NULL,
					   &dce_iova_fops);
	dce_himap_dbg = debugfs_create_file("dce_himap", 0444, NULL, NULL,
					    &dce_himap_fops);

	return 0;
}



/*
 * Removes module, sends appropriate message to kernel
 */
static int dce_host_proxy_remove(struct platform_device *pdev)
{
	deb_info("removing module.\n");

	debugfs_remove(dce_ast_dbg);
	debugfs_lookup_and_remove("dce_peek_addr", NULL);
	debugfs_remove(dce_peek_dbg);
	debugfs_remove(dce_iova_dbg);

	mutex_lock(&dce_host_client_lock);
	if (dce_host_client_registered) {
		tegra_dce_unregister_ipc_client(dce_host_client_handle);
		dce_host_client_registered = false;
	}
	mutex_unlock(&dce_host_client_lock);

	mutex_lock(&dce_host_event_client_lock);
	if (dce_host_event_registered) {
		tegra_dce_unregister_ipc_client(dce_host_event_handle);
		dce_host_event_registered = false;
	}
	mutex_unlock(&dce_host_event_client_lock);

	// Both clients are gone, so no callback can be queueing any more: safe to
	// drop the ring. Wake any reader blocked in read() first.
	wake_up_interruptible(&dce_evt_wq);
	kfree(dce_evt_ring);
	dce_evt_ring = NULL;

	if (dce_evt_dropped)
		deb_warn("dropped %lu DCE notification(s) -- ring too small or bridge too slow\n",
			 dce_evt_dropped);

	device_destroy(dce_host_proxy_class, MKDEV(major_number, 0)); // remove the device
	class_unregister(dce_host_proxy_class);						  // unregister the device class
	class_destroy(dce_host_proxy_class);						  // remove the device class
	unregister_chrdev(major_number, DEVICE_NAME);		  // unregister the major number
	deb_info("Goodbye from the LKM!\n");
	return 0;
}

/*
 * Opens device module, sends appropriate message to kernel
 */
static int open(struct inode *inodep, struct file *filep)
{
	deb_info("device opened.\n");
	return 0;
}

/*
 * Closes device module, sends appropriate message to kernel
 */
static int close(struct inode *inodep, struct file *filep)
{
	deb_info("device closed.\n");
	return 0;
}

/*
 * Reverse doorbell: pop one queued DCE notification.
 *
 * The bridge poll()s and then read()s; each read returns exactly one event
 * (never a partial or coalesced one), so the reader never has to frame them.
 */
static ssize_t read(struct file *filep, char *buffer, size_t len, loff_t *offset)
{
	struct dce_host_event *e;
	unsigned long flags;
	size_t copy;
	int ret;

	if (len < sizeof(struct dce_host_event))
		return -EINVAL;

	if (!dce_evt_pending()) {
		if (filep->f_flags & O_NONBLOCK)
			return -EAGAIN;

		ret = wait_event_interruptible(dce_evt_wq, dce_evt_pending());
		if (ret)
			return ret;
	}

	e = kmalloc(sizeof(*e), GFP_KERNEL);
	if (!e)
		return -ENOMEM;

	spin_lock_irqsave(&dce_evt_lock, flags);
	if (dce_evt_head == dce_evt_tail) {
		/* Raced with another reader. */
		spin_unlock_irqrestore(&dce_evt_lock, flags);
		kfree(e);
		return -EAGAIN;
	}
	/* PEEK, don't pop: a failed copy_to_user used to silently LOSE the
	 * event (popped before the copy) -- observed on hardware as the plug
	 * half of a replug never reaching the guest. Advance the tail only
	 * after the copy succeeds. Single reader (the QEMU bridge), so the
	 * peek-then-pop window is not contended. */
	*e = dce_evt_ring[dce_evt_tail];
	spin_unlock_irqrestore(&dce_evt_lock, flags);

	/* Only the header plus the bytes this event actually carries. */
	copy = offsetof(struct dce_host_event, data) + e->size;
	if (copy_to_user(buffer, e, copy)) {
		pr_warn_ratelimited("dce_host_proxy: event copy_to_user failed (len=%zu copy=%zu), event retained\n",
				    len, copy);
		kfree(e);
		return -EFAULT;
	}

	spin_lock_irqsave(&dce_evt_lock, flags);
	if (dce_evt_head != dce_evt_tail)
		dce_evt_tail = (dce_evt_tail + 1) % DCE_EVT_SLOTS;
	spin_unlock_irqrestore(&dce_evt_lock, flags);

	kfree(e);

	return copy;
}

static __poll_t dce_host_poll(struct file *filep, struct poll_table_struct *wait)
{
	poll_wait(filep, &dce_evt_wq, wait);

	return dce_evt_pending() ? (EPOLLIN | EPOLLRDNORM) : 0;
}

/*
 * Ensures exactly one CPU_RM IPC client is registered with tegra-dce,
 * registering it lazily on first use -- exactly as dce-probe-test.c does.
 * Safe to call on every write(); a no-op once registered.
 */
static int dce_host_proxy_ensure_client(void)
{
	int ret = 0;

	mutex_lock(&dce_host_client_lock);
	if (!dce_host_client_registered) {
		ret = tegra_dce_register_ipc_client(DCE_CLIENT_IPC_TYPE_CPU_RM,
						     dce_host_proxy_ipc_cb, NULL,
						     &dce_host_client_handle);
		if (ret) {
			pr_err("dce_host_proxy: CPU_RM registration failed: %d\n", ret);
		} else {
			dce_host_client_registered = true;
			pr_info("dce_host_proxy: registered CPU_RM client, handle=%u\n",
				 dce_host_client_handle);
		}
	}
	mutex_unlock(&dce_host_client_lock);

	return ret;
}

/*
 * Register the RM_EVENT client: DCE's asynchronous notify channel, which nobody
 * else claims (tegra-dce otherwise logs "Failed to retrieve client info for
 * ch_type: [3]" and drops the notifications). Registered lazily alongside the
 * CPU_RM client. A failure here is not fatal to the sync relay -- it only costs
 * async events -- so it warns rather than failing the write().
 */
static void dce_host_proxy_ensure_event_client(void)
{
	int ret;

	mutex_lock(&dce_host_event_client_lock);
	if (!dce_host_event_registered) {
		ret = tegra_dce_register_ipc_client(DCE_CLIENT_IPC_TYPE_RM_EVENT,
						    dce_host_proxy_event_cb, NULL,
						    &dce_host_event_handle);
		if (ret) {
			deb_warn("RM_EVENT registration failed: %d (async events, incl. flip completion, will not reach the guest)\n",
				 ret);
		} else {
			dce_host_event_registered = true;
			pr_info("dce_host_proxy: registered RM_EVENT client, handle=%u\n",
				dce_host_event_handle);
		}
	}
	mutex_unlock(&dce_host_event_client_lock);
}

#define BUF_SIZE DCE_CLIENT_MAX_IPC_MSG_SIZE

/*
 * Writes to the device
 */

static ssize_t write(struct file *filep, const char *buffer, size_t len, loff_t *offset)
{

	int ret = len;
	struct dce_host_msg *kbuf = NULL;
	void *txbuf = NULL;
	void *rxbuf = NULL;
	void *usertxbuf = NULL;
	void *userrxbuf = NULL;
	struct dce_ipc_message m;

	if (len > 65535) {	/* paranoia */
		deb_error("count %zu exceeds max # of bytes allowed, "
			"aborting write\n", len);
		goto out_nomem;
	}

	ret = -ENOMEM;
	kbuf = kmalloc(len, GFP_KERNEL);


	if (!kbuf)
		goto out_nomem;

	memset(kbuf, 0, len);

	ret = -EFAULT;

	// Copy header
	if (copy_from_user(kbuf, buffer, len)) {
		deb_error("copy_from_user(1) failed\n");
		goto out_cfu;
	}

	deb_info("\nwants to write %zu bytes, with iface: %u\n", len, kbuf->iface);

	// A malformed or malicious guest can set tx.size/rx.size larger than
	// the BUF_SIZE bounce buffers below; copy_from_user would then
	// overflow the host slab and corrupt unrelated allocations (see the
	// matching comment in bpmp-host-proxy.c). DCE messages are bounded
	// by DCE_CLIENT_MAX_IPC_MSG_SIZE, so anything larger is rejected.
	if (kbuf->tx.size > BUF_SIZE || kbuf->rx.size > BUF_SIZE) {
		deb_error("tx.size %zu / rx.size %zu exceeds %d, rejecting\n",
			  kbuf->tx.size, kbuf->rx.size, BUF_SIZE);
		goto out_cfu;
	}

	if(kbuf->tx.size > 0){
		txbuf = kmalloc(BUF_SIZE, GFP_KERNEL);
		if (!txbuf)
			goto out_nomem;
		memset(txbuf, 0, BUF_SIZE);
		if (copy_from_user(txbuf, kbuf->tx.data, kbuf->tx.size)) {
			deb_error("copy_from_user(2) failed\n");
			goto out_cfu;
		}
	}

	rxbuf = kmalloc(BUF_SIZE, GFP_KERNEL);
	if (!rxbuf)
		goto out_nomem;

	memset(rxbuf, 0, BUF_SIZE);
	if (copy_from_user(rxbuf, kbuf->rx.data, kbuf->rx.size)) {
		deb_error("copy_from_user(3) failed\n");
		goto out_cfu;
	}


	usertxbuf = (void*)kbuf->tx.data; //save userspace buffers addresses
	userrxbuf = kbuf->rx.data;


	kbuf->tx.data = txbuf; //reassing to kernel space buffers
	kbuf->rx.data = rxbuf;

	ret = dce_host_proxy_ensure_client();
	if (ret) {
		deb_error("no CPU_RM client available, can't do transfer!\n");
		goto out_cfu;
	}

	// Claim DCE's async notify channel too, so its events (vblank, and the flip
	// completion a guest modeset blocks on) reach us instead of being dropped.
	// Best-effort: the sync relay works without it.
	dce_host_proxy_ensure_event_client();

	m.tx.data = txbuf;
	m.tx.size = kbuf->tx.size;
	m.rx.data = rxbuf;
	m.rx.size = kbuf->rx.size;

	ret = tegra_dce_client_ipc_send_recv(dce_host_client_handle, &m);
	{	/* DIAGNOSTIC: trace the first relayed transfers */
		static int dbg_n;
		if (dbg_n < 12) {
			pr_info("dce_host_proxy: XFER #%d iface=%u tx=%zu rx=%zu -> ret=%d rx_out=%zu\n",
				dbg_n, kbuf->iface, kbuf->tx.size, kbuf->rx.size, ret, m.rx.size);
			dbg_n++;
		}
	}
	kbuf->ret = ret;
	/* Clamp the DCE-reported received length to the capacity we handed it
	 * (still in kbuf->rx.size here, already bounded to BUF_SIZE above). A
	 * buggy/corrupted DCE core reporting a larger rx.size would otherwise
	 * drive an out-of-bounds read of the bounce buffer and an oversized
	 * copy_to_user into QEMU's buffer. */
	kbuf->rx.size = min_t(size_t, m.rx.size, kbuf->rx.size);   /* actual received length */

	if (copy_to_user((void *)usertxbuf, kbuf->tx.data, kbuf->tx.size)) {
		deb_error("copy_to_user(2) failed\n");
		goto out_notok;
	}

	if (copy_to_user((void *)userrxbuf, kbuf->rx.data, kbuf->rx.size)) {
		deb_error("copy_to_user(3) failed\n");
		goto out_notok;
	}

	kbuf->tx.data=usertxbuf;
	kbuf->rx.data=userrxbuf;

	if (copy_to_user((void *)buffer, kbuf, len)) {
		deb_error("copy_to_user(1) failed\n");
		goto out_notok;
	}



	kfree(kbuf);
	kfree(txbuf);
	kfree(rxbuf);
	return len;
out_notok:
out_nomem:
	deb_error("memory allocation failed");
out_cfu:
	kfree(kbuf);
	kfree(txbuf);
	kfree(rxbuf);
    return -EINVAL;

}

static const struct of_device_id dce_host_proxy_ids[] = {
	{ .compatible = "nvidia,dce-host-proxy" },
	{ }
};
MODULE_DEVICE_TABLE(of, dce_host_proxy_ids);

static struct platform_driver dce_host_proxy_driver = {
	.driver = {
		.name = "dce_host_proxy",
		.of_match_table = dce_host_proxy_ids,
	},
	.probe = dce_host_proxy_probe,
	.remove = dce_host_proxy_remove,
};
/* Built as a loadable .ko inside nvidia-oot (it links the DCE client IPC
 * symbols exported there), so it must register via module init/exit --
 * builtin_platform_driver's device_initcall never runs on insmod. */
module_platform_driver(dce_host_proxy_driver);
