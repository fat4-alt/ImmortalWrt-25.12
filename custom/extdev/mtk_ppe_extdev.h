/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * External (USB/5G modem) ingress for the MAINLINE MediaTek PPE.
 *
 * Target: Linux 6.12 (ImmortalWrt / OpenWrt 25.12), mainline mt76 + mtk_ppe.
 * No closed-source mtwifi, no mediatek_hnat.
 *
 * Hardware model
 * --------------
 * The PPE FOE table only knows SoC-internal PSE ports (GDM1/2/3, WDMA0/1/2,
 * PPE0/1/2, QDMA TX/RX, DROP). A USB 5G modem netdev (wwan0/usb0/eth2) is
 * reached over xHCI -> CPU and is NOT one of them.
 *
 * BUT netsys exposes PSE_PPE0_PORT as a QDMA TX "forward port": a descriptor
 * with txd4[11:8] = PSE_PPE0_PORT hands the skb straight to the PPE lookup
 * engine instead of a physical GDM. The PPE then:
 *   - hashes ipv4.orig of the INJECTED (pre-NAT) packet,
 *   - on a BIND hit rewrites IP/port/L2/TTL/checksum from ipv4.new + l2,
 *   - pushes the packet to IB2.DEST_PORT (GDM / DSA / WDMA).
 * The CPU never sees the packet again. That is real hardware offload.
 *
 * We therefore:
 *   1) learn the downlink flow from the FIRST packet via a POST_ROUTING hook,
 *   2) build a normal HNAPT FOE entry using the very same helpers the mainline
 *      mtk_ppe_offload.c uses (mtk_foe_entry_prepare / set_ipv4_tuple /
 *      mtk_flow_set_output_device),
 *   3) on subsequent packets, intercept them at the USB netdev rx_handler
 *      (which runs at the very top of __netif_receive_skb, BEFORE ip_rcv and
 *      BEFORE any NAT), and inject the ORIGINAL, UNMODIFIED skb into PPE0.
 *
 * Uplink (LAN/WiFi -> USB modem) has no FOE egress port and stays on the CPU.
 * This is a hardware topology limit, not an implementation shortcut.
 */
#ifndef __MTK_PPE_EXTDEV_H
#define __MTK_PPE_EXTDEV_H

#include <linux/atomic.h>
#include <linux/if_ether.h>
#include <linux/netdevice.h>
#include <linux/rhashtable.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/timer.h>
#include <linux/types.h>

struct mtk_eth;
struct mtk_flow_entry;
struct mtk_extdev;
struct dentry;

/* cookie space separation: mainline nft flowtable cookies come from nf_flowtable
 * and are small; keep our entries in a disjoint high range so the two never
 * collide inside eth->flow_table. */
#define MTK_EXTDEV_COOKIE_BASE		0x4000000000000000ULL
#define MTK_EXTDEV_COOKIE_MASK		0x3fffffffffffffffULL

#define MTK_EXTDEV_PREFIX_MAX		96
#define MTK_EXTDEV_FLOW_TIMEOUT		(30 * HZ)
#define MTK_EXTDEV_GC_INTERVAL		HZ
#define MTK_EXTDEV_STALE_LIMIT		8	/* inject rounds w/o HW hit -> retire */
#define MTK_EXTDEV_MAX_PORTS		8

/* Key is the 5-tuple of the packet AS IT ARRIVES on the USB modem (pre-NAT),
 * i.e. conntrack's REPLY tuple. Exactly the tuple stored in foe.ipv4.orig and
 * the tuple mtk_ppe_hash_entry() hashes in hardware. */
struct mtk_extdev_key {
	__be32	src_ip;
	__be32	dst_ip;
	__be16	src_port;
	__be16	dst_port;
	u8	l4proto;
	u8	pad[3];
};

struct mtk_extdev_flow {
	struct rhash_head	node;
	struct rcu_head		rcu;
	unsigned long		cookie;
	struct mtk_extdev_key	key;

	struct net_device	*odev;		/* egress net_device, ref held */
	s8			wed_index;
	u8			ppe_index;
	u16			foe_hash;

	struct mtk_flow_entry	*foe;		/* lives in eth->flow_table */

	unsigned long		last_used;
	u64			inject_pkts;
	u64			hw_pkts;
	u64			last_inject;
	u8			stale;		/* HW not consuming -> retire */
	u8			pending_remove;
};

struct mtk_extdev_port {
	struct list_head	list;
	struct rcu_head		rcu;
	struct net_device	*dev;
	struct mtk_extdev	*ed;	/* rx_handler_data 只存 port，需要自带上下文 */
	char			name[IFNAMSIZ];
};

struct mtk_extdev {
	struct mtk_eth		*eth;
	struct list_head	ports;
	struct rhashtable	flows;
	spinlock_t		lock;
	struct timer_list	gc;
	struct dentry		*dbg;
	struct notifier_block	nb;
	unsigned int		nr_ports;
	char			prefix[MTK_EXTDEV_PREFIX_MAX];

	/* counters, exported via debugfs */
	u64	rx_total;
	u64	rx_inject;
	u64	rx_pass;		/* first packets -> software path */
	u64	rx_drop;
	u64	learn_ok;
	u64	learn_fail;
	u64	aged_out;
	u64	stale_out;
	u64	tx_busy;
	u64	tx_fail;
};

/* ---- implemented in mtk_ppe_extdev_tx.c, included by mtk_eth_soc.c ------- */
int  mtk_ppe_extdev_inject(struct mtk_eth *eth, struct sk_buff *skb);

/* ---- implemented in mtk_ppe_extdev.c, included by mtk_ppe_offload.c ----- */
int  mtk_ppe_extdev_init(struct mtk_eth *eth);
void mtk_ppe_extdev_deinit(struct mtk_eth *eth);

extern const struct rhashtable_params mtk_extdev_flow_ht_params;

#endif /* __MTK_PPE_EXTDEV_H */
