#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate 1001-mtk-ppe-extdev.patch for a given Linux 6.12 mediatek source dir.

Usage (inside an OpenWrt build tree, after the kernel has been unpacked AND
all official patches have been applied):

    python3 gen_patch.py <build_dir/.../linux-6.12.x/drivers/net/ethernet/mediatek> \
                         [output.patch]

WHY A GENERATOR
  OpenWrt 25.12 does not build vanilla v6.12. It builds linux-6.12.118 with
  ~150 mediatek patches + ~60 generic hack patches on top, producing a
  mtk_eth_soc.c of 6000+ lines. In that tree mtk_tx_map() has different
  context, so a hand-written patch with fixed hunk offsets fails.

  Version 2 of this patch deliberately does NOT touch mtk_tx_map() at all:
  injection uses a per-CPU forward-port flag + mtk_start_xmit(), so the only
  two anchors in mtk_eth_soc.c are the forward-port switch and the trailing
  #include -- both proven to apply in the failing cloud build log.

  The script still does exact string replacement (asserting each anchor occurs
  exactly once) and emits a difflib patch with correct line numbers, then
  verifies it with `patch -p1 --dry-run`.

Kernel bump procedure:
  1) run a build until it unpacks the kernel (make target/linux/prepare), or
     grab the source from the failed build_dir
  2) python3 gen_patch.py <that dir> 1001-mtk-ppe-extdev.patch
  3) commit the regenerated patch into custom/extdev/
"""
import difflib
import os
import subprocess
import sys
import tempfile

# (file, old, new) -- `old` must appear EXACTLY ONCE.
REPLACEMENTS = [
    # ---------------------------------------------------------------- Kconfig
    ("Kconfig",
     "config NET_MEDIATEK_STAR_EMAC\n",
     """config NET_MEDIATEK_PPE_EXTDEV
\tbool "PPE external-device (USB/5G modem) downlink offload"
\tdepends on NET_MEDIATEK_SOC && NF_CONNTRACK && NF_CONNTRACK_EVENTS
\tdepends on NET_MEDIATEK_SOC_WED
\thelp
\t  Downlink-only PPE offload for a USB-attached 5G modem acting as WAN.
\t  Matched packets are re-injected into the PPE through a QDMA TX
\t  descriptor whose forward port is PSE_PPE0_PORT. FOE entries reuse the
\t  mainline DSA / GDM / WDMA egress encoders. Uplink stays on the CPU.
\t  Non-upstreamable. Requires wed_enable=Y on the mt76 wifi driver.

config NET_MEDIATEK_STAR_EMAC
"""),

    # -------------------------------------------------------- mtk_eth_soc.h
    # NOTE: intentionally NO change to struct mtk_tx_dma_desc_info. Version 1
    # added an s8 fport there and had to patch mtk_tx_map() to set it -- that
    # is exactly what failed. Version 2 uses a per-CPU flag instead.
    ("mtk_eth_soc.h",
     """\tstruct mtk_ppe\t\t\t*ppe[3];
\tstruct rhashtable\t\tflow_table;
""",
     """\tstruct mtk_ppe\t\t\t*ppe[3];
\tstruct rhashtable\t\tflow_table;
\tstruct mtk_extdev\t\t*extdev;\t/* NULL when extdev is off */
"""),

    # -------------------------------------------------------- mtk_ppe.h
    ("mtk_ppe.h",
     """int mtk_foe_entry_commit(struct mtk_ppe *ppe, struct mtk_flow_entry *entry);
void mtk_foe_entry_clear(struct mtk_ppe *ppe, struct mtk_flow_entry *entry);
""",
     """int mtk_foe_entry_commit(struct mtk_ppe *ppe, struct mtk_flow_entry *entry);
int mtk_foe_entry_bind_hw(struct mtk_ppe *ppe, struct mtk_flow_entry *entry);
void mtk_foe_entry_clear(struct mtk_ppe *ppe, struct mtk_flow_entry *entry);
"""),

    # -------------------------------------------------------- mtk_ppe.c
    ("mtk_ppe.c",
     """\treturn 0;
}

static void
mtk_foe_entry_commit_subflow(struct mtk_ppe *ppe, struct mtk_flow_entry *entry,
""",
     """\treturn 0;
}

/* Explicitly bind a software FOE entry into its hardware slot.
 * Mainline relies on the PPE sending the first packet to the CPU, where
 * mtk_poll_rx() -> __mtk_ppe_check_skb() learns the slot number from the RX
 * descriptor. An skb injected through PSE_PPE0_PORT cannot use that path
 * (its sport is not a GDM, mtk_poll_rx() drops it), so compute the slot with
 * the same mtk_ppe_hash_entry() the hardware uses and commit it now. */
int mtk_foe_entry_bind_hw(struct mtk_ppe *ppe, struct mtk_flow_entry *entry)
{
\tu32 hash;

\tif (!ppe || !entry)
\t\treturn -EINVAL;

\thash = mtk_ppe_hash_entry(ppe->eth, &entry->data);
\tspin_lock_bh(&ppe_lock);
\tentry->hash = (u16)hash;
\t__mtk_foe_entry_commit(ppe, &entry->data, hash);
\tspin_unlock_bh(&ppe_lock);

\treturn (int)hash;
}
EXPORT_SYMBOL_GPL(mtk_foe_entry_bind_hw);

static void
mtk_foe_entry_commit_subflow(struct mtk_ppe *ppe, struct mtk_flow_entry *entry,
"""),

    ("mtk_ppe.c",
     """void mtk_ppe_deinit(struct mtk_eth *eth)
{
\tint i;

\tfor (i = 0; i < ARRAY_SIZE(eth->ppe); i++) {
""",
     """void mtk_ppe_deinit(struct mtk_eth *eth)
{
\tint i;

\textern void mtk_ppe_extdev_deinit(struct mtk_eth *eth);
\tif (IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV))
\t\tmtk_ppe_extdev_deinit(eth);

\tfor (i = 0; i < ARRAY_SIZE(eth->ppe); i++) {
"""),

    # -------------------------------------------------------- mtk_eth_soc.c
    # Hunk A: forward port. Insert a BLOCK-SCOPE prototype so we do not need
    # another declaration hunk in a header. mtk_extdev_get_fport() is defined
    # in mtk_ppe_extdev_tx.c which is #included at the end of this file.
    ("mtk_eth_soc.c",
     """\t /* set forward port */
\tswitch (mac->id) {
\tcase MTK_GMAC1_ID:
\t\tdata = PSE_GDM1_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\tbreak;
\tcase MTK_GMAC2_ID:
\t\tdata = PSE_GDM2_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\tbreak;
\tcase MTK_GMAC3_ID:
\t\tdata = PSE_GDM3_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\tbreak;
\t}
""",
     """\t/* set forward port. extdev injection overrides with PSE_PPE0_PORT. */
\t{
\t\tu8 mtk_extdev_get_fport(void); /* defined in mtk_ppe_extdev_tx.c */
\t\tu8 extdev_fport = mtk_extdev_get_fport();

\t\tif (extdev_fport) {
\t\t\tdata = (u32)extdev_fport << TX_DMA_FPORT_SHIFT_V2;
\t\t} else {
\t\t\tswitch (mac->id) {
\t\t\tcase MTK_GMAC1_ID:
\t\t\t\tdata = PSE_GDM1_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\t\t\tbreak;
\t\t\tcase MTK_GMAC2_ID:
\t\t\t\tdata = PSE_GDM2_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\t\t\tbreak;
\t\t\tcase MTK_GMAC3_ID:
\t\t\t\tdata = PSE_GDM3_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\t\t\tbreak;
\t\t\t}
\t\t}
\t}
"""),

    # Hunk B: trailing include (verified in the failing build log:
    #         "Hunk #6 succeeded at 6051 (offset 677 lines)")
    ("mtk_eth_soc.c",
     """MODULE_LICENSE("GPL");
MODULE_AUTHOR("John Crispin <blogic@openwrt.org>");
MODULE_DESCRIPTION("Ethernet driver for MediaTek SoC");
""",
     """MODULE_LICENSE("GPL");
MODULE_AUTHOR("John Crispin <blogic@openwrt.org>");
MODULE_DESCRIPTION("Ethernet driver for MediaTek SoC");

/* Same translation unit: mtk_ppe_extdev_tx.c uses mtk_start_xmit(),
 * mtk_cal_txd_req(), the TX ring and the per-CPU fport flag, all static
 * above. It intentionally does NOT call mtk_tx_map() directly. */
#include "mtk_ppe_extdev_tx.c"
"""),

    # -------------------------------------------------------- mtk_ppe_offload.c
    ("mtk_ppe_offload.c",
     """int mtk_eth_offload_init(struct mtk_eth *eth, u8 id)
{
\tif (!eth->ppe[id] || !eth->ppe[id]->foe_table)
\t\treturn 0;
\treturn rhashtable_init(&eth->flow_table, &mtk_flow_ht_params);
}
""",
     """extern int mtk_ppe_extdev_init(struct mtk_eth *eth);

int mtk_eth_offload_init(struct mtk_eth *eth, u8 id)
{
\tint err;

\tif (!eth->ppe[id] || !eth->ppe[id]->foe_table)
\t\treturn 0;
\terr = rhashtable_init(&eth->flow_table, &mtk_flow_ht_params);
\tif (err)
\t\treturn err;
\tif (id == 0 && IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV))
\t\tmtk_ppe_extdev_init(eth);
\treturn 0;
}

/* Same translation unit: mtk_ppe_extdev.c reuses the static
 * mtk_flow_ht_params / mtk_flow_set_output_device() / WDMA helpers above. */
#include "mtk_ppe_extdev.c"
"""),
]

HEADER = """From: USB/5G extdev PPE backport <local>
Subject: [PATCH] net: ethernet: mtk_eth_soc: external-device (USB/5G) PPE ingress

Downlink hardware offload for a USB 5G modem acting as WAN on Linux 6.12
mainline mtk_ppe (no mtk_hnat, no closed-source wifi). Packets are injected
into the PPE through a QDMA TX descriptor with fport=PSE_PPE0_PORT; FOE
entries are built with the mainline DSA/GDM/WDMA helpers and bound to their
hardware slot explicitly (6.12 leaves new entries UNBIND).

v2: does NOT modify mtk_tx_map() (its context differs after OpenWrt's own
patches). A per-CPU forward-port flag is read by mtk_tx_set_dma_desc_v2()
while mtk_start_xmit() runs synchronously. Only two hunks in mtk_eth_soc.c.

Generated by gen_patch.py against the real 6.12 source; verify with
`patch -p1 --dry-run` before building. Companion files mtk_ppe_extdev.{c,h}
and mtk_ppe_extdev_tx.c must be present in the same directory.

---
"""


def dry_run(src, patch_path):
    """Apply the generated patch to a throwaway copy with `patch --dry-run`."""
    with tempfile.TemporaryDirectory() as td:
        d = os.path.join(td, "drivers/net/ethernet/mediatek")
        os.makedirs(d)
        for name in dict.fromkeys(r[0] for r in REPLACEMENTS):
            p = os.path.join(src, name)
            if not os.path.isfile(p):
                continue
            with open(p, "rb") as fh:
                data = fh.read()
            with open(os.path.join(d, name), "wb") as fh:
                fh.write(data)
        # dummy companion sources so #include lines resolve (dry-run only
        # checks hunks, but create them anyway for completeness)
        for n in ("mtk_ppe_extdev.c", "mtk_ppe_extdev.h", "mtk_ppe_extdev_tx.c"):
            open(os.path.join(d, n), "w").close()
        r = subprocess.run(["patch", "-p1", "--dry-run", "-i", patch_path],
                           cwd=td, capture_output=True, text=True)
        ok = r.returncode == 0
        print("dry-run: %s" % ("OK" if ok else "FAILED"), file=sys.stderr)
        if not ok:
            print(r.stdout + r.stderr, file=sys.stderr)
        return ok


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "1001-mtk-ppe-extdev.patch"

    files = {}
    for name, old, new in REPLACEMENTS:
        path = os.path.join(src, name)
        if name not in files:
            with open(path, encoding="utf-8") as fh:
                files[name] = fh.read()
        s = files[name]
        n = s.count(old)
        if n != 1:
            print("ERROR: %s: anchor occurs %d times (expected 1):\n%s" %
                  (name, n, old[:160]), file=sys.stderr)
            print("HINT: run against the kernel tree that OpenWrt actually "
                  "builds (build_dir/target-*/linux-*/linux-6.12.*/drivers/"
                  "net/ethernet/mediatek/), after all official patches applied.",
                  file=sys.stderr)
            return 1
        files[name] = s.replace(old, new, 1)

    chunks = [HEADER]
    for name in dict.fromkeys(r[0] for r in REPLACEMENTS):
        path = os.path.join(src, name)
        with open(path, encoding="utf-8") as fh:
            orig = fh.readlines()
        new = files[name].splitlines(True)
        d = list(difflib.unified_diff(
            orig, new,
            fromfile="a/drivers/net/ethernet/mediatek/" + name,
            tofile="b/drivers/net/ethernet/mediatek/" + name,
            n=3))
        if not d:
            print("WARN: no diff for %s" % name, file=sys.stderr)
            continue
        chunks.append("".join(d))

    with open(out, "w", encoding="utf-8") as fh:
        fh.write("".join(chunks))
    print("wrote %s (%d bytes, %d files)" %
          (out, os.path.getsize(out), len(chunks) - 1))
    return 0 if dry_run(src, out) else 1


if __name__ == "__main__":
    sys.exit(main())
