// SPDX-License-Identifier: GPL-2.0-only
// dce-probe-test: confirm-or-kill probe for late CPU_RM registration on a
// headless, already-bootstrapped DCE. Throwaway experiment module.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/debugfs.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/platform/tegra/dce/dce-client-ipc.h>

static u32 probe_handle;
static bool probe_registered;
static struct dentry *probe_dir;
static DEFINE_MUTEX(probe_lock);
static int last_ret = -1;
static size_t last_rx_len;
static unsigned int notify_count;

static void probe_cb(u32 handle, u32 interface_type, u32 msg_length,
		     void *msg_data, void *usr_ctx)
{
	notify_count++;
	pr_info("dce_probe: NOTIFY type=%u len=%u count=%u\n",
		interface_type, msg_length, notify_count);
}

static ssize_t probe_send_write(struct file *f, const char __user *ubuf,
				size_t len, loff_t *ppos)
{
	struct dce_ipc_message msg = {};
	void *tx = NULL, *rx = NULL;
	int ret;

	if (len == 0 || len > DCE_CLIENT_MAX_IPC_MSG_SIZE)
		return -EINVAL;

	tx = kzalloc(len, GFP_KERNEL);
	rx = kzalloc(DCE_CLIENT_MAX_IPC_MSG_SIZE, GFP_KERNEL);
	if (!tx || !rx) {
		ret = -ENOMEM;
		goto out;
	}
	if (copy_from_user(tx, ubuf, len)) {
		ret = -EFAULT;
		goto out;
	}

	msg.tx.data = tx;
	msg.tx.size = len;
	msg.rx.data = rx;
	msg.rx.size = DCE_CLIENT_MAX_IPC_MSG_SIZE;

	mutex_lock(&probe_lock);
	if (!probe_registered) {
		mutex_unlock(&probe_lock);
		ret = -ENODEV;
		goto out;
	}
	ret = tegra_dce_client_ipc_send_recv(probe_handle, &msg);
	last_ret = ret;
	last_rx_len = (ret == 0) ? msg.rx.size : 0;
	mutex_unlock(&probe_lock);

	pr_info("dce_probe: send_recv ret=%d rx_len=%zu\n", ret, last_rx_len);
	print_hex_dump(KERN_INFO, "dce_probe: rx ", DUMP_PREFIX_OFFSET, 16, 1,
		       rx, min_t(size_t, last_rx_len, 64), true);
	ret = (ret == 0) ? (int)len : ret;
out:
	kfree(tx);
	kfree(rx);
	return ret;
}

static const struct file_operations probe_send_fops = {
	.owner = THIS_MODULE,
	.write = probe_send_write,
};

static int probe_result_show(struct seq_file *s, void *v)
{
	seq_printf(s, "last_ret=%d last_rx_len=%zu notify_count=%u\n",
		   last_ret, last_rx_len, notify_count);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(probe_result);

static int __init dce_probe_init(void)
{
	int ret;

	ret = tegra_dce_register_ipc_client(DCE_CLIENT_IPC_TYPE_CPU_RM,
					    probe_cb, NULL, &probe_handle);
	pr_info("dce_probe: register ret=%d handle=%u\n", ret, probe_handle);
	if (ret) {
		pr_err("dce_probe: CPU_RM registration FAILED (gate a fail)\n");
		return ret;
	}
	probe_registered = true;

	probe_dir = debugfs_create_dir("dce_probe", NULL);
	debugfs_create_file("send", 0200, probe_dir, NULL, &probe_send_fops);
	debugfs_create_file("result", 0400, probe_dir, NULL, &probe_result_fops);
	pr_info("dce_probe: registered CPU_RM, debugfs at /sys/kernel/debug/dce_probe\n");
	return 0;
}

static void __exit dce_probe_exit(void)
{
	debugfs_remove_recursive(probe_dir);
	if (probe_registered)
		tegra_dce_unregister_ipc_client(probe_handle);
	pr_info("dce_probe: unloaded\n");
}

module_init(dce_probe_init);
module_exit(dce_probe_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("DCE late-client confirm-or-kill probe");
