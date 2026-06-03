// ve_diag.c — read-only diagnostic for the Allwinner Cedar VE on the AD5M (T113).
// Exposes /proc/ve_diag dumping the VE interrupt status/ctrl registers + the GIC state
// for the VE IRQ, to determine WHY the VE never raises a completion interrupt:
//   - if int_status shows "done" but GIC pending/enabled is wrong -> IRQ delivery bug (pokeable)
//   - if int_status never sets "done" -> the VE engine isn't actually executing the op
// Reg layout from the BSP cedar_ve.c: MACC base 0x01C0E000; encode int regs at +0xb14/+0xb1c,
// decode at +0xa08/+0xa10. GIC dist at 0x03021000 (sun8iw20p1.dtsi). VE IRQ = GIC hwirq 98.
#include <linux/module.h>
#include <linux/io.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>

#define VE_BASE   0x01C0E000
#define VE_SIZE   0x2000
#define GIC_DIST  0x03021000
#define GIC_SIZE  0x1000
#define VE_IRQ    98
#define IOMMU_BASE 0x02010000
#define IOMMU_SIZE 0x1000
#define SYSCFG_BASE 0x03000000   /* VE node reg[1]: SRAM-to-MACC remap control */
#define SYSCFG_SIZE 0x1000
#define MBUS_BASE  0x03102000    /* sun8i-mbus controller; VE = port 26 */
#define MBUS_SIZE  0x1000

static void __iomem *ve, *gic, *iommu, *syscfg, *mbus;

static int ve_qos = 0;   /* if 1: set VE MBUS port26 to high pri + max QoS (driver's intent) */
module_param(ve_qos, int, 0644);

static int ve_diag_show(struct seq_file *m, void *v)
{
	u32 modual  = readl(ve + 0x000);
	u32 enc_ctl = readl(ve + 0xb14), enc_sts = readl(ve + 0xb1c);
	u32 dec_ctl = readl(ve + 0xa08), dec_sts = readl(ve + 0xa10);
	u32 off = (VE_IRQ / 32) * 4, bit = 1u << (VE_IRQ % 32);
	u32 isen   = readl(gic + 0x100 + off);   /* GICD_ISENABLER */
	u32 ispend = readl(gic + 0x200 + off);   /* GICD_ISPENDR   */
	u32 isact  = readl(gic + 0x300 + off);   /* GICD_ISACTIVER */

	seq_printf(m, "modual_sel       = 0x%08x\n", modual);
	seq_printf(m, "enc int_ctl@0xb14= 0x%08x  int_sts@0xb1c = 0x%08x\n", enc_ctl, enc_sts);
	seq_printf(m, "dec int_ctl@0xa08= 0x%08x  int_sts@0xa10 = 0x%08x\n", dec_ctl, dec_sts);
	seq_printf(m, "GIC irq%d: enabled=%d pending=%d active=%d\n",
		   VE_IRQ, !!(isen & bit), !!(ispend & bit), !!(isact & bit));
	/* Allwinner VE internal MMU regs live around base+0xe00 (enable/ctrl/status/fault). */
	seq_printf(m, "MMU e00=%08x e04=%08x e08=%08x e0c=%08x e10=%08x e14=%08x e18=%08x e1c=%08x\n",
		   readl(ve+0xe00), readl(ve+0xe04), readl(ve+0xe08), readl(ve+0xe0c),
		   readl(ve+0xe10), readl(ve+0xe14), readl(ve+0xe18), readl(ve+0xe1c));
	/* Hunt the whole VE register space for the input buffer address the VE is reading
	 * (0x02c0xxxx invalid below-DRAM, or 0x42c0xxxx valid DRAM) -> tells us if it's an
	 * address bug or a stall for another reason. */
	{ int o; for (o = 0x000; o < 0xf00; o += 4) {
		u32 val = readl(ve + o);
		if (val) seq_printf(m, "  r%03x=%08x", o, val);
	} seq_printf(m, "\n"); }
	/* IOMMU state — is the VE (master 0 on sun8iw20) translating or in bypass?
	 * and is there a fault (VE accessing an unmapped IOVA)? */
	if (syscfg) {
		u32 c0 = readl(syscfg + 0x0), c4 = readl(syscfg + 0x4);
		seq_printf(m, "SYSCFG[0x00]=%08x (bit0=%d SRAM%s-to-VE) [0x04]=%08x (bit24=%d)\n",
			   c0, !!(c0&1), (c0&1)?"-NOT-mapped":"-mapped", c4, !!(c4&(1<<24)));
	}
	if (mbus) {
		u32 acen0 = readl(mbus + 0x20), acen1 = readl(mbus + 0x24), acen2 = readl(mbus + 0x28);
		/* VE MBUS port = 26 -> ACEN reg0 bit26 */
		seq_printf(m, "MBUS ACEN0@0x20=%08x (VE port26 enabled=%d) ACEN1@0x24=%08x ACEN2@0x28=%08x\n",
			   acen0, !!(acen0 & (1u<<26)), acen1, acen2);
		seq_printf(m, "MBUS VE cfg0@%03x=%08x cfg1@%03x=%08x  (port26 QoS/pri/bwl)\n",
			   0x210+0x10*26, readl(mbus + 0x210 + 0x10*26),
			   0x214+0x10*26, readl(mbus + 0x214 + 0x10*26));
	}
	if (iommu) {
		seq_printf(m, "IOMMU enable=%08x bypass=%08x ttb=%08x int_sta=%08x\n",
			   readl(iommu + 0x020), readl(iommu + 0x030),
			   readl(iommu + 0x050), readl(iommu + 0x108));
		seq_printf(m, "IOMMU fault_addr[VE=0]=%08x data0=%08x a1=%08x a2=%08x a3=%08x\n",
			   readl(iommu + 0x110), readl(iommu + 0x130),
			   readl(iommu + 0x114), readl(iommu + 0x118), readl(iommu + 0x11c));
	}
	return 0;
}

static int ve_diag_open(struct inode *i, struct file *f) { return single_open(f, ve_diag_show, NULL); }
static const struct file_operations ve_diag_fops = {
	.owner = THIS_MODULE, .open = ve_diag_open,
	.read = seq_read, .llseek = seq_lseek, .release = single_release,
};

static int __init ve_diag_init(void)
{
	ve  = ioremap(VE_BASE, VE_SIZE);
	gic = ioremap(GIC_DIST, GIC_SIZE);
	iommu = ioremap(IOMMU_BASE, IOMMU_SIZE);
	syscfg = ioremap(SYSCFG_BASE, SYSCFG_SIZE);
	mbus = ioremap(MBUS_BASE, MBUS_SIZE);
	if (!ve || !gic) { pr_err("ve_diag: ioremap failed\n"); return -ENOMEM; }
	if (ve_qos && mbus) {
		u32 v = readl(mbus + 0x3b0);                 /* MBUS port26 (VE) CFG0 */
		writel((v & ~0xe) | 0xe, mbus + 0x3b0);      /* pri=1 (bit1), qos=3 (bits2-3) */
		pr_info("ve_diag: VE MBUS cfg0 0x%08x -> 0x%08x\n", v, readl(mbus + 0x3b0));
	}
	proc_create("ve_diag", 0444, NULL, &ve_diag_fops);
	pr_info("ve_diag: loaded (ve=%p gic=%p)\n", ve, gic);
	return 0;
}
static void __exit ve_diag_exit(void)
{
	remove_proc_entry("ve_diag", NULL);
	if (ve) iounmap(ve);
	if (gic) iounmap(gic);
	if (iommu) iounmap(iommu);
	if (syscfg) iounmap(syscfg);
	if (mbus) iounmap(mbus);
}
module_init(ve_diag_init);
module_exit(ve_diag_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Cedar VE / GIC diagnostic for AD5M HW-encode bringup");
