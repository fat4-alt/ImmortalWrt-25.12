#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate 1001-mtk-ppe-extdev.patch for a given Linux 6.12 mediatek source dir.

Usage (inside an OpenWrt build tree, or with any 6.12 kernel tree):
    python3 gen_patch.py <path-to-drivers/net/ethernet/mediatek> [output.patch]

Why a generator instead of a fixed patch:
  6.12.y point releases and OpenWrt's target/linux/mediatek/patches-6.12/*
  shift line numbers and occasionally reword context. A fixed hunk offsets
  silently; this script does exact string replacement (asserting each anchor is
  unique) and emits a difflib patch with correct line numbers. Re-run it when
  you bump the kernel and re-check `patch -p1 --dry-run`.
"""
import difflib
import os
import sys

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
    ("mtk_eth_soc.h",
     """struct mtk_tx_dma_desc_info {
\tdma_addr_t\taddr;
\tu32\t\tsize;
\tu16\t\tvlan_tci;
\tu16\t\tqid;
\tu8\t\tgso:1;
""",
     """struct mtk_tx_dma_desc_info {
\tdma_addr_t\taddr;
\tu32\t\tsize;
\tu16\t\tvlan_tci;
\tu16\t\tqid;
\ts8\t\tfport;\t\t/* >=0: PSE forward port override; -1: use mac->id */
\tu8\t\tgso:1;
"""),

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
\tif (info->fport >= 0) {
\t\tdata = (u32)info->fport << TX_DMA_FPORT_SHIFT_V2;
\t} else {
\t\tswitch (mac->id) {
\t\tcase MTK_GMAC1_ID:
\t\t\tdata = PSE_GDM1_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\t\tbreak;
\t\tcase MTK_GMAC2_ID:
\t\t\tdata = PSE_GDM2_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\t\tbreak;
\t\tcase MTK_GMAC3_ID:
\t\t\tdata = PSE_GDM3_PORT << TX_DMA_FPORT_SHIFT_V2;
\t\t\tbreak;
\t\t}
\t}
"""),

    ("mtk_eth_soc.c",
     """static int mtk_tx_map(struct sk_buff *skb, struct net_device *dev,
\t\t      int tx_num, struct mtk_tx_ring *ring, bool gso)
""",
     """static int mtk_tx_map(struct sk_buff *skb, struct net_device *dev,
\t\t      int tx_num, struct mtk_tx_ring *ring, bool gso,
\t\t      int fport)
"""),

    ("mtk_eth_soc.c",
     """\t\t.csum = skb->ip_summed == CHECKSUM_PARTIAL,
\t\t.vlan = skb_vlan_tag_present(skb),
\t\t.qid = skb_get_queue_mapping(skb),
""",
     """\t\t.csum = skb->ip_summed == CHECKSUM_PARTIAL,
\t\t.vlan = skb_vlan_tag_present(skb),
\t\t.qid = skb_get_queue_mapping(skb),
\t\t.fport = fport,
"""),

    ("mtk_eth_soc.c",
     """\t\t\ttxd_info.size = min_t(unsigned int, frag_size,
\t\t\t\t\t      soc->tx.dma_max_len);
\t\t\ttxd_info.qid = queue;
\t\t\ttxd_info.last = i == skb_shinfo(skb)->nr_frags - 1 &&
""",
     """\t\t\ttxd_info.size = min_t(unsigned int, frag_size,
\t\t\t\t\t      soc->tx.dma_max_len);
\t\t\ttxd_info.qid = queue;
\t\t\ttxd_info.fport = fport;
\t\t\ttxd_info.last = i == skb_shinfo(skb)->nr_frags - 1 &&
"""),

    ("mtk_eth_soc.c",
     "\tif (mtk_tx_map(skb, dev, tx_num, ring, gso) < 0)\n",
     "\tif (mtk_tx_map(skb, dev, tx_num, ring, gso, -1) < 0)\n"),

    ("mtk_eth_soc.c",
     """MODULE_LICENSE("GPL");
MODULE_AUTHOR("John Crispin <blogic@openwrt.org>");
MODULE_DESCRIPTION("Ethernet driver for MediaTek SoC");
""",
     """MODULE_LICENSE("GPL");
MODULE_AUTHOR("John Crispin <blogic@openwrt.org>");
MODULE_DESCRIPTION("Ethernet driver for MediaTek SoC");

/* Same translation unit: mtk_ppe_extdev_tx.c uses mtk_tx_map(), the TX ring
 * and eth->page_lock, all static above. */
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

Generated by gen_patch.py against the real 6.12 source -- line numbers and
context are exact. Companion files mtk_ppe_extdev.{c,h} and
mtk_ppe_extdev_tx.c must be present in the same directory.

---
"""


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
                  (name, n, old[:120]), file=sys.stderr)
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
