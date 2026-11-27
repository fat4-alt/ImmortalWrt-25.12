/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * CPU -> PPE0 injection over the QDMA TX ring.
 *
 * This file is #included at the END of drivers/net/ethernet/mediatek/mtk_eth_soc.c
 * so it can reuse the static helpers mtk_cal_txd_req(), mtk_tx_map(), the TX
 * ring and eth->page_lock. See 1001-mtk-ppe-extdev.patch for the three small
 * signature changes that make the forward port selectable.
 *
 * Why PSE_PPE0_PORT and not PSE_GDM1_PORT:
 *   GDM1 is a real physical port. A packet injected there that misses the FOE
 *   table would actually leave the box on WAN/LAN (leak + loop). PSE_PPE0_PORT
 *   is the lookaside port of the PPE itself; a hit is forwarded by hardware,
 *   a miss is handed to the CPU port (never to a wire). We only inject flows we
 *   have already confirmed exist in the FOE table, so misses are a rare race
 *   between ageing and injection, not the steady state.
 *
 * skb ownership: mtk_tx_map() stores the skb in itx_buf->data (MTK_TYPE_SKB).
 * The TX cleanup path (mtk_poll_tx / mtk_tx_clean) frees it. On success the
 * caller MUST NOT touch the skb again and MUST return RX_HANDLER_CONSUMED.
 */

#if IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV)

/**
 * mtk_ppe_extdev_inject - hand an unmodified skb to the PPE lookup engine
 * @eth: mtk_eth context
 * @skb: original (pre-NAT, pre-netfilter) packet received on a USB/5G netdev
 *
 * Returns 0 on success (skb now owned by the TX ring), negative on failure
 * (caller must fall back to the normal software receive path).
 */
int mtk_ppe_extdev_inject(struct mtk_eth *eth, struct sk_buff *skb)
{
	struct net_device *dev;
	struct mtk_tx_ring *ring;
	int tx_num, ret;

	if (unlikely(!eth || !skb))
		return -EINVAL;

	/* Carrier netdev for the TX ring / BQL accounting. GMAC0 always exists
	 * on Filogic. The descriptor's FPORT is overridden to PSE_PPE0_PORT so
	 * the packet is NOT transmitted on this MAC. */
	dev = eth->netdev[0];
	if (unlikely(!dev))
		return -ENODEV;

	ring = &eth->tx_ring;

	/* USB RX skbs can carry an arbitrary queue mapping. Queues 0..2 are the
	 * unrestricted non-DSA queues on QDMA; force 0 so the descriptor's QID
	 * matches what the FOE entry (mtk_foe_entry_set_queue) expects. */
	skb_set_queue_mapping(skb, 0);

	/* GSO/TSO must not reach the PPE: hardware cannot segment a forwarded
	 * flow and would corrupt the L4 payload. Caller already rejects GSO. */
	if (unlikely(skb_is_gso(skb)))
		return -EOPNOTSUPP;

	spin_lock(&eth->page_lock);

	if (unlikely(test_bit(MTK_RESETTING, &eth->state))) {
		ret = -ENETDOWN;
		goto out;
	}

	tx_num = mtk_cal_txd_req(eth, skb);
	/* Keep a small reserve so a burst of injected packets cannot starve the
	 * ordinary netdev TX queues. */
	if (unlikely(atomic_read(&ring->free_count) <= tx_num + 4)) {
		ret = -EAGAIN;
		goto out;
	}

	/* fport = PSE_PPE0_PORT is the whole trick. mtk_tx_map() will place it
	 * in txd4[11:8] for both the head and the SG descriptors. */
	ret = mtk_tx_map(skb, dev, tx_num, ring, false, PSE_PPE0_PORT);
	if (ret == 0)
		skb = NULL;		/* ownership transferred to the TX ring */

out:
	spin_unlock(&eth->page_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(mtk_ppe_extdev_inject);

#endif /* CONFIG_NET_MEDIATEK_PPE_EXTDEV */
