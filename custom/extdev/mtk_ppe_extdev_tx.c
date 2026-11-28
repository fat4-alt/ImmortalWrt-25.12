/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * CPU -> PPE0 injection over the QDMA TX ring.
 *
 * This file is #included at the END of drivers/net/ethernet/mediatek/mtk_eth_soc.c
 * so it can see that translation unit's static helpers and the TX ring.
 *
 * >>> IMPORTANT: 6.12 portability note <<<
 * OpenWrt 25.12 ships linux-6.12.118 with a stack of its own patches
 * (750/751 mtk_eth_soc mt7987 support, hack-6.12/730 hw dump, ...). In that
 * tree mtk_tx_map() has a DIFFERENT context/signature than vanilla v6.12, so
 * an earlier patch that modified mtk_tx_map() failed 4/6 hunks.
 *
 * This version therefore does NOT touch mtk_tx_map() at all. Instead:
 *   - a per-CPU byte mtk_extdev_fport is set to PSE_PPE0_PORT for the duration
 *     of one synchronous ndo_start_xmit() call;
 *   - mtk_tx_set_dma_desc_v2() reads it via mtk_extdev_get_fport() and writes
 *     that value into txd4[11:8] instead of the mac->id derived GDM port;
 *   - the normal mtk_start_xmit() -> mtk_tx_map() path does all the ring work,
 *     whatever its internal signature happens to be in this kernel.
 *
 * The only two anchors in mtk_eth_soc.c are the forward-port switch (proven to
 * apply in the failing build log) and the trailing #include (also proven).
 *
 * skb ownership: mtk_start_xmit() hands the skb to the TX ring; on its drop
 * path it frees the skb. Either way the caller MUST NOT touch it again and
 * MUST return RX_HANDLER_CONSUMED.
 */

#include <linux/percpu.h>

/* Forward declarations: this file is #included into mtk_eth_soc.c, so its own
 * prototypes are not otherwise visible (kernel -Wmissing-prototypes). */
u8 mtk_extdev_get_fport(void);
int mtk_ppe_extdev_inject(struct mtk_eth *eth, struct sk_buff *skb);

#if IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV)

DEFINE_PER_CPU(u8, mtk_extdev_fport);

/* Called from mtk_tx_set_dma_desc_v2() for EVERY TX descriptor. A block-scope
 * prototype there avoids adding a new #include / declaration hunk to
 * mtk_eth_soc.h, which keeps the patch to exactly two mtk_eth_soc.c hunks. */
u8 mtk_extdev_get_fport(void)
{
	return this_cpu_read(mtk_extdev_fport);
}

/**
 * mtk_ppe_extdev_inject - hand an unmodified skb to the PPE lookup engine
 * @eth: mtk_eth context
 * @skb: original (pre-NAT, pre-netfilter) packet received on a USB/5G netdev
 *
 * Returns 0 when the skb was submitted to the TX ring (caller must CONSUME),
 * negative when the caller should fall back to the software receive path.
 */
int mtk_ppe_extdev_inject(struct mtk_eth *eth, struct sk_buff *skb)
{
	struct net_device *dev;
	struct mtk_tx_ring *ring;
	int tx_num;

	if (unlikely(!eth || !skb))
		return -EINVAL;

	/* Carrier netdev for BQL / txd_info.qid accounting. The descriptor's
	 * FPORT is overridden to PSE_PPE0_PORT, so nothing leaves on this MAC. */
	dev = eth->netdev[0];
	if (unlikely(!dev))
		return -ENODEV;

	/* Startup gate (translation-unit-local equivalent of ed->hw_ready).
	 * mtk_ppe_extdev_init() runs in the PROBE path, before register_netdev()
	 * and before mtk_open() allocates the QDMA TX ring / starts the PPE.
	 * netif_running() only becomes true once ndo_open succeeded, which is
	 * the same point where the notifier sets ed->hw_ready. Without this,
	 * an early modem packet could submit a descriptor to an unallocated
	 * ring and panic the box into a watchdog reset loop. */
	if (unlikely(!netif_running(dev)))
		return -EAGAIN;

	if (unlikely(test_bit(MTK_RESETTING, &eth->state)))
		return -ENETDOWN;

	/* PPE cannot segment; caller already rejects GSO, double-check here. */
	if (unlikely(skb_is_gso(skb)))
		return -EOPNOTSUPP;
	/* Keep only the single-descriptor case: a fragmented skb would need the
	 * SG loop to also carry the override (it does, but the extra DMA maps
	 * are not worth it for a modem flow). */
	if (unlikely(skb_is_nonlinear(skb)))
		return -EOPNOTSUPP;

	/* Queue 0 is the unrestricted non-DSA QDMA queue and is always valid
	 * for netdev_get_tx_queue() inside mtk_start_xmit(). */
	skb_set_queue_mapping(skb, 0);
	skb->dev = dev;

	/* Lock-free pre-check. mtk_start_xmit() takes eth->page_lock itself and
	 * would deadlock if we held it. The tiny race only costs one packet,
	 * which TCP retransmits; the GC stale detector also covers it. */
	ring = &eth->tx_ring;
	tx_num = mtk_cal_txd_req(eth, skb);
	if (unlikely(atomic_read(&ring->free_count) <= tx_num + 4))
		return -EAGAIN;

	/* mtk_start_xmit() disables preemption (spin_lock) while it runs
	 * mtk_tx_map() -> mtk_tx_set_dma_desc_v2(), so the per-CPU value is
	 * read on this same CPU and cannot leak to another CPU's normal TX. */
	preempt_disable();
	__this_cpu_write(mtk_extdev_fport, PSE_PPE0_PORT);
	mtk_start_xmit(skb, dev);
	__this_cpu_write(mtk_extdev_fport, 0);
	preempt_enable();

	return 0;
}

#else  /* !CONFIG_NET_MEDIATEK_PPE_EXTDEV */

/* Stub so mtk_tx_set_dma_desc_v2() links when the feature is compiled out. */
u8 mtk_extdev_get_fport(void)
{
	return 0;
}

#endif /* CONFIG_NET_MEDIATEK_PPE_EXTDEV */
