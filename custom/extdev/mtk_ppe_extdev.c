/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * External (USB/5G modem) ingress for the MAINLINE MediaTek PPE, Linux 6.12.
 *
 * This file is #included at the END of
 *   drivers/net/ethernet/mediatek/mtk_ppe_offload.c
 * so it can reuse the STATIC helpers of that translation unit:
 *   mtk_flow_ht_params, mtk_flow_set_output_device(), mtk_flow_get_dsa_port(),
 *   mtk_flow_get_wdma_info(), mtk_wed_flow_add()/remove().
 *
 * Flow of a downlink connection (LAN client -> internet, reply comes back on
 * the USB modem):
 *
 *   packet #1  wwan0 -> rx_handler (no entry) -> RX_HANDLER_PASS
 *              -> ip_rcv -> conntrack + SNAT -> POST_ROUTING hook
 *              -> build HNAPT FOE entry (orig = conntrack REPLY tuple,
 *                 new = post-NAT iphdr, egress = DSA / GDM / WDMA)
 *              -> mtk_foe_entry_commit()   (software hash bucket)
 *              -> mtk_foe_entry_bind_hw()  (write the actual hardware slot)
 *              -> register key in extdev rhashtable
 *
 *   packet #N  wwan0 -> rx_handler (entry found, hw BIND)
 *              -> mtk_ppe_extdev_inject() with fport = PSE_PPE0_PORT
 *              -> PPE hashes ipv4.orig, hits the BIND slot, rewrites
 *                 IP/port/L2/TTL/csum from ipv4.new + l2, pushes to
 *                 IB2.DEST_PORT (wired DSA/GDM or wireless WDMA).
 *              -> the skb is freed by the QDMA TX cleanup, CPU never sees it.
 *
 * This is genuine hardware offload; the only CPU work for packet #N is the
 * USB RX DMA + one descriptor write. Uplink stays on the CPU (no FOE egress
 * port exists for a USB device).
 */

#if IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV)

#include <linux/debugfs.h>
#include <linux/etherdevice.h>
#include <linux/jhash.h>
#include <linux/ip.h>
#include <linux/moduleparam.h>
#include <linux/netdevice.h>
#include <linux/netfilter.h>
#include <linux/notifier.h>
#include <linux/netfilter_ipv4.h>
#include <linux/rtnetlink.h>
#include <linux/string.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <net/dst.h>
#include <net/neighbour.h>
#include <net/netfilter/nf_conntrack.h>
#include <net/netfilter/nf_conntrack_tuple.h>
#include "mtk_ppe.h"
#include "mtk_wed.h"
#include "mtk_ppe_extdev.h"

/* Some OpenWrt 25.12 / 6.12.118 vendor trees expose this in mtk_ppe.c but
 * not always through the header chain that reaches this translation unit.
 * The signature is identical to upstream v6.12.118 (mtk_ppe.c:851), so a
 * redundant declaration here is legal C and harmless when the header one is
 * present. */
extern struct mtk_foe_accounting *
mtk_foe_entry_get_mib(struct mtk_ppe *ppe, u32 index,
		      struct mtk_foe_accounting *diff);

static char *extdev_prefix = "wwan,usb,eth2";
module_param(extdev_prefix, charp, 0644);
MODULE_PARM_DESC(extdev_prefix,
	"comma-separated netdev name prefixes of USB/5G modem WAN interfaces");

/* Runtime kill switch. The module is built into mtk_eth, so the sysfs path is
 * /sys/module/mtk_eth/parameters/extdev_enable (NOT mtk_ppe_extdev). */
static bool extdev_enable = true;
module_param(extdev_enable, bool, 0644);
MODULE_PARM_DESC(extdev_enable,
	"set to 0 to fall back to software forwarding without reflashing");

const struct rhashtable_params mtk_extdev_flow_ht_params = {
	.head_offset		= offsetof(struct mtk_extdev_flow, node),
	.key_offset		= offsetof(struct mtk_extdev_flow, cookie),
	.key_len		= sizeof(unsigned long),
	.automatic_shrinking	= true,
};

/* ------------------------------------------------------------------ */
/* tuple key: MUST match the bytes of the packet as it arrives on USB   */
/* ------------------------------------------------------------------ */

static inline unsigned long
mtk_extdev_key_cookie(__be32 src_ip, __be32 dst_ip,
		      __be16 src_port, __be16 dst_port, u8 l4proto)
{
	u32 h = jhash_3words((__force u32)src_ip ^ (__force u32)dst_ip,
			     ((__force u32)src_port << 16) | (__force u32)dst_port,
			     l4proto, 0x9e3779b9UL);
	return MTK_EXTDEV_COOKIE_BASE | (h & MTK_EXTDEV_COOKIE_MASK);
}

static inline bool
mtk_extdev_skb_key(struct sk_buff *skb, struct mtk_extdev_key *k)
{
	struct iphdr *iph;
	__be16 *ports;

	if (skb->protocol != htons(ETH_P_IP))
		return false;
	if (!pskb_may_pull(skb, sizeof(struct iphdr) + 4))
		return false;

	iph = ip_hdr(skb);
	if (iph->version != 4 || iph->ihl < 5)
		return false;
	/* IP_MF (0x2000) | IP_OFFSET (0x1FFF) == 0x3FFF. Those macros live in
	 * <net/ip.h>, which pulls in a lot of conntrack/ipstack internals;
	 * use the numeric value so this file stays header-light. */
	if (iph->frag_off & htons(0x3fff))
		return false;
	if (iph->protocol != IPPROTO_TCP && iph->protocol != IPPROTO_UDP)
		return false;
	if (skb_is_gso(skb))
		return false;
	if (skb_vlan_tag_present(skb))
		return false;

	ports = (__be16 *)((u8 *)iph + iph->ihl * 4);
	k->src_ip   = iph->saddr;
	k->dst_ip   = iph->daddr;
	k->src_port = ports[0];
	k->dst_port = ports[1];
	k->l4proto  = iph->protocol;
	memset(k->pad, 0, sizeof(k->pad));
	return true;
}

static bool mtk_extdev_name_matches(struct mtk_extdev *ed, const char *name)
{
	char buf[MTK_EXTDEV_PREFIX_MAX];
	char *p = buf, *tok;

	strscpy(buf, ed->prefix, sizeof(buf));
	while ((tok = strsep(&p, ",")) != NULL) {
		if (*tok && !strncmp(name, tok, strlen(tok)))
			return true;
	}
	return false;
}

/* Never hijack a netdev the PPE already owns, nor a bridge slave that has
 * its own rx_handler. A USB WAN is a plain L3 interface here. */
static bool mtk_extdev_is_candidate(struct mtk_extdev *ed,
				    struct net_device *dev)
{
	int i;

	if (!mtk_extdev_name_matches(ed, dev->name))
		return false;
	for (i = 0; i < MTK_MAX_DEVS; i++)
		if (ed->eth->netdev[i] == dev)
			return false;
	if (netdev_uses_dsa(dev))
		return false;
	/* A bridge slave already owns rx_handler; netdev_rx_handler_register()
	 * will return -EBUSY and we log a clear hint. No need for if_bridge.h
	 * helpers here (their availability varies across 6.12.y releases). */
	return true;
}

/* ------------------------------------------------------------------ */
/* flow lifecycle                                                      */
/* ------------------------------------------------------------------ */

static void mtk_extdev_flow_free(struct mtk_extdev *ed,
				 struct mtk_extdev_flow *f)
{
	struct mtk_eth *eth = ed->eth;

	if (f->foe) {
		mtk_foe_entry_clear(eth->ppe[f->ppe_index], f->foe);
		rhashtable_remove_fast(&eth->flow_table, &f->foe->node,
				       mtk_flow_ht_params);
		if (f->wed_index >= 0)
			mtk_wed_flow_remove(f->wed_index);
		kfree(f->foe);
		f->foe = NULL;
	}
	dev_put(f->odev);
	kfree_rcu(f, rcu);
}

static void mtk_extdev_flow_del(struct mtk_extdev *ed, unsigned long cookie)
{
	struct mtk_extdev_flow *f;

	f = rhashtable_lookup_fast(&ed->flows, &cookie,
				   mtk_extdev_flow_ht_params);
	if (!f)
		return;
	if (rhashtable_remove_fast(&ed->flows, &f->node,
				   mtk_extdev_flow_ht_params) == 0)
		mtk_extdev_flow_free(ed, f);
}

/* ------------------------------------------------------------------ */
/* Build the FOE entry. Uses the exact same primitives as the mainline  */
/* mtk_flow_offload_replace(), so DSA / WDMA / PSE encoding is correct. */
/* ------------------------------------------------------------------ */

static int mtk_extdev_learn(struct mtk_extdev *ed, struct sk_buff *skb,
			    struct nf_conn *ct,
			    const struct nf_hook_state *state)
{
	struct mtk_eth *eth = ed->eth;
	const struct nf_conntrack_tuple *rt;
	struct mtk_extdev_key key = {};
	struct mtk_extdev_flow *f;
	struct mtk_flow_entry *entry;
	struct mtk_foe_entry foe;
	struct iphdr *iph;
	struct neighbour *neigh;
	struct net_device *odev;
	unsigned long cookie;
	__be16 *l4;
	u8 src_mac[ETH_ALEN], dst_mac[ETH_ALEN];
	int wed_index = -1, ppe_index = 0, slot = -1, err;

	/* Only IPv4 TCP/UDP for now. Everything else stays on the CPU. */
	if (!mtk_extdev_skb_key(skb, &key))
		return -EOPNOTSUPP;

	/* The POST_ROUTING skb is already NAT-ed. We need the PRE-NAT tuple
	 * (what the NEXT packet will look like on wwan0) from conntrack's
	 * REPLY direction, and the POST-NAT values from the current iphdr. */
	rt = &ct->tuplehash[IP_CT_DIR_REPLY].tuple;
	if (rt->src.l3num != AF_INET)
		return -EOPNOTSUPP;

	iph = ip_hdr(skb);
	l4 = (__be16 *)((u8 *)iph + iph->ihl * 4);

	cookie = mtk_extdev_key_cookie(rt->src.u3.ip, rt->dst.u3.ip,
				      rt->src.u.all, rt->dst.u.all,
				      key.l4proto);
	if (rhashtable_lookup_fast(&ed->flows, &cookie,
				   mtk_extdev_flow_ht_params))
		return -EEXIST;

	odev = skb_dst(skb) ? skb_dst(skb)->dev : state->out;
	if (!odev)
		return -ENODEV;

	/* L2 header the PPE will write on the egress side.
	 * mtk_flow_set_output_device() below is the single authority on egress
	 * validation: it returns -EOPNOTSUPP for anything that is not a WDMA
	 * path, a MTK DSA user port, or one of eth->netdev[0..2]. Do not
	 * pre-validate here (dev_fill_forward_path needs a real daddr). */
	if (!skb_dst(skb))
		return -ENODEV;
	neigh = dst_neigh_lookup(skb_dst(skb), &iph->daddr);
	if (!neigh || is_zero_ether_addr(neigh->ha)) {
		if (neigh)
			neigh_release(neigh);
		return -ENOENT;
	}
	ether_addr_copy(dst_mac, neigh->ha);
	neigh_release(neigh);
	ether_addr_copy(src_mac, odev->dev_addr);
	if (!is_valid_ether_addr(src_mac) || !is_valid_ether_addr(dst_mac))
		return -EINVAL;

	/* ---- FOE: orig = injected (pre-NAT) packet, new = post-NAT ------- */
	err = mtk_foe_entry_prepare(eth, &foe, MTK_PPE_PKT_TYPE_IPV4_HNAPT,
				    key.l4proto, 0, src_mac, dst_mac);
	if (err)
		return err;

	err = mtk_foe_entry_set_ipv4_tuple(eth, &foe, false,
					   rt->src.u3.ip, rt->src.u.all,
					   rt->dst.u3.ip, rt->dst.u.all);
	if (err)
		return err;
	err = mtk_foe_entry_set_ipv4_tuple(eth, &foe, true,
					   iph->saddr, l4[0],
					   iph->daddr, l4[1]);
	if (err)
		return err;

	/* Handles WDMA (wireless WED), DSA user ports and plain GDM,
	 * including queue selection. This is the mainline helper. */
	err = mtk_flow_set_output_device(eth, &foe, odev, dst_mac, &wed_index);
	if (err)
		return err;

	if (wed_index >= 0) {
		err = mtk_wed_flow_add(wed_index);
		if (err < 0)
			return err;
	}

	entry = kzalloc(sizeof(*entry), GFP_ATOMIC);
	if (!entry) {
		err = -ENOMEM;
		goto err_wed;
	}
	entry->cookie    = cookie;
	entry->type      = MTK_FLOW_TYPE_L4;
	entry->ppe_index = ppe_index;
	entry->wed_index = wed_index;
	memcpy(&entry->data, &foe, sizeof(entry->data));

	/* Software bookkeeping (shared with the mainline driver so that
	 * __mtk_ppe_check_skb(), ageing and stats see this entry). */
	err = mtk_foe_entry_commit(eth->ppe[ppe_index], entry);
	if (err < 0)
		goto err_entry;
	err = rhashtable_insert_fast(&eth->flow_table, &entry->node,
				     mtk_flow_ht_params);
	if (err < 0)
		goto err_clear;

	/* *** The 6.12-specific step ***
	 * mtk_foe_entry_commit() only links the entry into the software hash
	 * bucket and leaves entry->hash == 0xffff (UNBIND). Normally the PPE
	 * would send the first packet to the CPU and mtk_poll_rx() ->
	 * __mtk_ppe_check_skb() would write the hardware slot. A packet we
	 * inject through PSE_PPE0_PORT that misses would come back on a sport
	 * that mtk_poll_rx() refuses (only GDM1/2/3 map to a mac), so that
	 * learning path cannot complete. Bind the slot ourselves instead. */
	slot = mtk_foe_entry_bind_hw(eth->ppe[ppe_index], entry);
	if (slot < 0) {
		err = slot;
		goto err_unlink;
	}

	f = kzalloc(sizeof(*f), GFP_ATOMIC);
	if (!f) {
		err = -ENOMEM;
		goto err_unlink;
	}
	f->cookie	= cookie;
	f->key		= key;
	f->odev		= odev;
	f->wed_index	= wed_index;
	f->ppe_index	= ppe_index;
	f->foe		= entry;
	f->foe_hash	= (u16)slot;
	f->last_used	= jiffies;

	err = rhashtable_insert_fast(&ed->flows, &f->node,
				     mtk_extdev_flow_ht_params);
	if (err < 0) {
		kfree(f);
		goto err_unlink;
	}
	dev_hold(odev);

	ed->learn_ok++;
	return 0;

err_unlink:
	rhashtable_remove_fast(&eth->flow_table, &entry->node,
			       mtk_flow_ht_params);
err_clear:
	mtk_foe_entry_clear(eth->ppe[ppe_index], entry);
err_entry:
	kfree(entry);
err_wed:
	if (wed_index >= 0)
		mtk_wed_flow_remove(wed_index);
	ed->learn_fail++;
	return err;
}

/* ------------------------------------------------------------------ */
/* rx_handler: runs at the TOP of __netif_receive_skb, before ip_rcv   */
/* and before any NAT. The skb here is byte-identical to packet #N on   */
/* the wire, which is exactly what foe.ipv4.orig was built from.        */
/* ------------------------------------------------------------------ */

static rx_handler_result_t
mtk_extdev_rx_handler(struct sk_buff **pskb)
{
	struct sk_buff *skb = *pskb;
	struct mtk_extdev_port *p;
	struct mtk_extdev *ed;
	struct mtk_extdev_flow *f;
	struct mtk_extdev_key key;
	unsigned long cookie;
	int ret;

	p = rcu_dereference(skb->dev->rx_handler_data);
	if (unlikely(!p || !p->ed))
		return RX_HANDLER_PASS;
	ed = p->ed;
	ed->rx_total++;

	if (unlikely(!extdev_enable))
		goto pass;

	if (!mtk_extdev_skb_key(skb, &key))
		goto pass;

	cookie = mtk_extdev_key_cookie(key.src_ip, key.dst_ip,
				       key.src_port, key.dst_port,
				       key.l4proto);

	rcu_read_lock();
	f = rhashtable_lookup_fast(&ed->flows, &cookie,
				   mtk_extdev_flow_ht_params);
	if (!f || !f->foe || f->stale) {
		rcu_read_unlock();
		goto pass;		/* first packet, or flow retired */
	}
	if (unlikely(f->foe->hash == 0xffff)) {
		rcu_read_unlock();
		goto pass;		/* hardware slot not bound (race) */
	}

	f->last_used = jiffies;
	f->inject_pkts++;

	ret = mtk_ppe_extdev_inject(ed->eth, skb);
	rcu_read_unlock();

	if (ret == 0) {
		ed->rx_inject++;
		/* skb is now owned by the QDMA TX ring. Returning CONSUMED is
		 * mandatory: it must NOT continue up the receive path. */
		return RX_HANDLER_CONSUMED;
	}

	if (ret == -EAGAIN)
		ed->tx_busy++;
	else
		ed->tx_fail++;

	/* Ring full / reset / GSO: let this one packet through the software
	 * stack. Connection survives, next packet will try injection again. */
pass:
	ed->rx_pass++;
	return RX_HANDLER_PASS;
}

/* ------------------------------------------------------------------ */
/* netfilter hook: learn on the first post-NAT packet                   */
/* ------------------------------------------------------------------ */

static unsigned int
mtk_extdev_postrouting(void *priv, struct sk_buff *skb,
		       const struct nf_hook_state *state)
{
	struct mtk_extdev *ed = priv;
	struct mtk_extdev_port *p;
	struct nf_conn *ct;
	enum ip_conntrack_info ctinfo;
	struct net_device *idev;
	bool ours = false;

	idev = skb->dev ? skb->dev : state->in;
	if (!idev)
		return NF_ACCEPT;

	rcu_read_lock();
	list_for_each_entry_rcu(p, &ed->ports, list) {
		if (p->dev == idev) {
			ours = true;
			break;
		}
	}
	rcu_read_unlock();
	if (!ours)
		return NF_ACCEPT;

	ct = nf_ct_get(skb, &ctinfo);
	if (!ct)
		return NF_ACCEPT;

	mtk_extdev_learn(ed, skb, ct, state);
	return NF_ACCEPT;		/* never drop on a learning failure */
}

static const struct nf_hook_ops mtk_extdev_nf_ops[] = {
	{
		.hook	 = mtk_extdev_postrouting,
		.pf	 = NFPROTO_IPV4,
		.hooknum = NF_INET_POST_ROUTING,
		.priority = NF_IP_PRI_LAST - 1,
	},
};

/* ------------------------------------------------------------------ */
/* Ageing + stale detection.
 *
 * If the QDMA/PSE forward-port trick does not make the PPE consume our
 * packets on a given SoC (netsys version differences), a naive implementation
 * black-holes the connection: "ping works, TCP/UDP dead" (a well-known
 * symptom with external-device HNAT). Guard against it: compare injected
 * packets with the hardware MIB counter of the FOE slot. If injections keep
 * growing while the hardware counter does not, retire the flow and fall back
 * to the software path. Never silently lose traffic.
 * ------------------------------------------------------------------ */

static void mtk_extdev_gc(struct timer_list *t)
{
	struct mtk_extdev *ed = from_timer(ed, t, gc);
	struct mtk_extdev_flow *f;
	struct rhashtable_iter it;
	struct mtk_foe_accounting diff;
	unsigned long doomed[64];
	int i, ndoomed = 0;

	/* rhashtable_walk_start() returns VOID in 6.12 (it used to return int
	 * in older kernels). Do not test its return value. */
	rhashtable_walk_enter(&ed->flows, &it);
	rhashtable_walk_start(&it);

	/* Two-phase: never remove entries while the walker is active -- the
	 * rhashtable documentation forbids it (may skip / revisit objects).
	 * Collect cookies, then delete after walk_stop(). */
	while ((f = rhashtable_walk_next(&it)) != NULL) {
		u64 prev_inj, prev_hw;
		bool mib_ok = false, retire = false;

		if (IS_ERR(f))
			continue;

		prev_inj = f->last_inject;
		prev_hw  = f->hw_pkts;
		f->last_inject = f->inject_pkts;

		memset(&diff, 0, sizeof(diff));
		/* mtk_foe_entry_get_mib() returns the DELTA since the last read
		 * (and clears the hardware counter), not a cumulative total. */
		if (f->foe && f->foe->hash != 0xffff &&
		    mtk_foe_entry_get_mib(ed->eth->ppe[f->ppe_index],
					  f->foe->hash, &diff)) {
			f->hw_pkts += diff.packets;
			mib_ok = true;
		}

		/* Only judge staleness when the MIB is actually available and
		 * traffic kept being injected during this interval. Otherwise a
		 * build without PPE accounting would retire every flow. */
		if (mib_ok && prev_inj && f->inject_pkts > prev_inj) {
			if (f->hw_pkts > prev_hw) {
				f->stale = 0;		/* hardware is consuming */
			} else if (++f->stale >= MTK_EXTDEV_STALE_LIMIT) {
				netdev_warn(f->odev,
					"extdev: PPE slot %u not consuming injected "
					"traffic, retiring flow (software fallback)\n",
					f->foe_hash);
				ed->stale_out++;
				retire = true;
			}
		} else if (!mib_ok) {
			f->stale = 0;
		}

		if (!retire &&
		    time_after(jiffies, f->last_used + MTK_EXTDEV_FLOW_TIMEOUT)) {
			ed->aged_out++;
			retire = true;
		}

		if (retire && ndoomed < ARRAY_SIZE(doomed))
			doomed[ndoomed++] = f->cookie;
	}
	rhashtable_walk_stop(&it);
	rhashtable_walk_exit(&it);

	for (i = 0; i < ndoomed; i++)
		mtk_extdev_flow_del(ed, doomed[i]);

	mod_timer(&ed->gc, jiffies + MTK_EXTDEV_GC_INTERVAL);
}

/* ------------------------------------------------------------------ */
/* Bind / unbind USB netdevs, including hotplug                        */
/* ------------------------------------------------------------------ */

/* @have_rtnl: caller already holds rtnl_mutex (netdev notifier callbacks and
 * the initial for_each_netdev() sweep do). netdev_rx_handler_register()
 * requires it, and taking it twice would deadlock. */
static int mtk_extdev_bind(struct mtk_extdev *ed, struct net_device *dev,
			   bool have_rtnl)
{
	struct mtk_extdev_port *p;
	int err;

	if (!mtk_extdev_is_candidate(ed, dev))
		return 0;

	/* Called under rtnl_mutex (notifier / init sweep), so a plain
	 * list_for_each_entry is sufficient and avoids a lockdep RCU warning. */
	list_for_each_entry(p, &ed->ports, list)
		if (p->dev == dev)
			return 0;

	if (ed->nr_ports >= MTK_EXTDEV_MAX_PORTS)
		return -ENOSPC;

	p = kzalloc(sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;
	p->dev = dev;
	p->ed = ed;		/* rx_handler_data = p; rx_handler needs ed back */
	strscpy(p->name, dev->name, sizeof(p->name));
	dev_hold(dev);

	if (!have_rtnl)
		rtnl_lock();
	err = netdev_rx_handler_register(dev, mtk_extdev_rx_handler, p);
	if (err) {
		if (!have_rtnl)
			rtnl_unlock();
		if (err == -EBUSY)
			netdev_warn(dev, "extdev: rx_handler busy (bridged?); "
				    "keep the 5G WAN unbridged for PPE injection\n");
		goto err_put;
	}
	list_add_tail_rcu(&p->list, &ed->ports);
	ed->nr_ports++;
	if (!have_rtnl)
		rtnl_unlock();

	netdev_info(dev, "extdev: bound, injecting matched flows into PSE_PPE0_PORT\n");
	return 0;

err_put:
	dev_put(dev);
	kfree(p);
	return err;
}

static int mtk_extdev_netdev_event(struct notifier_block *nb,
				   unsigned long event, void *ptr)
{
	struct net_device *dev = netdev_notifier_info_to_dev(ptr);
	struct mtk_extdev *ed = container_of(nb, struct mtk_extdev, nb);

	if (event == NETDEV_REGISTER || event == NETDEV_UP)
		mtk_extdev_bind(ed, dev, true);
	else if (event == NETDEV_UNREGISTER) {
		struct mtk_extdev_port *p, *n;
		list_for_each_entry_safe(p, n, &ed->ports, list) {
			if (p->dev != dev)
				continue;
			list_del_rcu(&p->list);
			ed->nr_ports--;
			netdev_rx_handler_unregister(p->dev);
			dev_put(p->dev);
			kfree_rcu(p, rcu);
		}
	}
	return NOTIFY_DONE;
}

/* ------------------------------------------------------------------ */
/* init / deinit                                                        */
/* ------------------------------------------------------------------ */

int mtk_ppe_extdev_init(struct mtk_eth *eth)
{
	struct mtk_extdev *ed;
	struct net_device *dev;
	int err;

	if (!eth->ppe[0] || !eth->ppe[0]->foe_table)
		return 0;		/* no PPE on this SoC */

	/* Only mtk_tx_set_dma_desc_v2() (netsys v2/v3) honours the forward-port
	 * override. On v1 the descriptor has a different layout and an injected
	 * skb would leave through a real GDM port. Refuse to start instead. */
	if (!mtk_is_netsys_v2_or_greater(eth)) {
		pr_warn("mtk_ppe_extdev: netsys v1 not supported, disabled\n");
		return 0;
	}

	ed = kzalloc(sizeof(*ed), GFP_KERNEL);
	if (!ed)
		return -ENOMEM;
	ed->eth = eth;
	INIT_LIST_HEAD(&ed->ports);
	spin_lock_init(&ed->lock);
	strscpy(ed->prefix, extdev_prefix, sizeof(ed->prefix));
	ed->nb.notifier_call = mtk_extdev_netdev_event;

	err = rhashtable_init(&ed->flows, &mtk_extdev_flow_ht_params);
	if (err)
		goto err_free;
	err = register_netdevice_notifier(&ed->nb);
	if (err)
		goto err_ht;
	err = nf_register_net_hooks(&init_net, mtk_extdev_nf_ops,
				    ARRAY_SIZE(mtk_extdev_nf_ops));
	if (err)
		goto err_notifier;

	timer_setup(&ed->gc, mtk_extdev_gc, 0);
	mod_timer(&ed->gc, jiffies + MTK_EXTDEV_GC_INTERVAL);

	ed->dbg = debugfs_create_dir("mtk_ppe_extdev", NULL);
	debugfs_create_u64("rx_total",  0444, ed->dbg, &ed->rx_total);
	debugfs_create_u64("rx_inject", 0444, ed->dbg, &ed->rx_inject);
	debugfs_create_u64("rx_pass",   0444, ed->dbg, &ed->rx_pass);
	debugfs_create_u64("learn_ok",  0444, ed->dbg, &ed->learn_ok);
	debugfs_create_u64("learn_fail",0444, ed->dbg, &ed->learn_fail);
	debugfs_create_u64("aged_out",  0444, ed->dbg, &ed->aged_out);
	debugfs_create_u64("stale_out", 0444, ed->dbg, &ed->stale_out);
	debugfs_create_u64("tx_busy",   0444, ed->dbg, &ed->tx_busy);
	debugfs_create_u64("tx_fail",   0444, ed->dbg, &ed->tx_fail);

	eth->extdev = ed;

	/* Devices that already exist (modem probed before mtk_eth_soc). */
	rtnl_lock();
	for_each_netdev(&init_net, dev)
		mtk_extdev_bind(ed, dev, true);
	rtnl_unlock();

	pr_info("mtk_ppe_extdev: USB/5G -> wired/wireless PPE injection ready "
		"(prefix=%s, WED=%d)\n", ed->prefix,
		IS_ENABLED(CONFIG_NET_MEDIATEK_SOC_WED));
	return 0;

err_notifier:
	unregister_netdevice_notifier(&ed->nb);
err_ht:
	rhashtable_destroy(&ed->flows);
err_free:
	kfree(ed);
	return err;
}

void mtk_ppe_extdev_deinit(struct mtk_eth *eth)
{
	struct mtk_extdev *ed = eth->extdev;
	struct mtk_extdev_port *p, *n;
	struct rhashtable_iter it;
	struct mtk_extdev_flow *f;

	if (!ed)
		return;
	eth->extdev = NULL;

	del_timer_sync(&ed->gc);
	unregister_netdevice_notifier(&ed->nb);
	nf_unregister_net_hooks(&init_net, mtk_extdev_nf_ops,
				ARRAY_SIZE(mtk_extdev_nf_ops));
	debugfs_remove_recursive(ed->dbg);

	rhashtable_walk_enter(&ed->flows, &it);
	rhashtable_walk_start(&it);
	/* Only free the objects here. Removing from ed->flows while walking is
	 * forbidden; rhashtable_destroy() below discards the whole table. */
	while ((f = rhashtable_walk_next(&it)) != NULL) {
		if (!IS_ERR(f))
			mtk_extdev_flow_free(ed, f);
	}
	rhashtable_walk_stop(&it);
	rhashtable_walk_exit(&it);
	rhashtable_destroy(&ed->flows);

	rtnl_lock();
	list_for_each_entry_safe(p, n, &ed->ports, list) {
		list_del_rcu(&p->list);
		ed->nr_ports--;
		netdev_rx_handler_unregister(p->dev);
		dev_put(p->dev);
		kfree_rcu(p, rcu);
	}
	rtnl_unlock();
	kfree(ed);
}

#endif /* CONFIG_NET_MEDIATEK_PPE_EXTDEV */
