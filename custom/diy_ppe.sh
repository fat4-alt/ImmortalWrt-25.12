#!/bin/bash
set -e

SRC="$GITHUB_WORKSPACE/custom"
DTS_DIR="target/linux/mediatek/dts"
MK="target/linux/mediatek/image/filogic.mk"
NET="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"


sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate
sed -i 's/ImmortalWrt/FZSWrt/g' package/base-files/files/bin/config_generate

if [ -f feeds/luci/collections/luci/Makefile ]; then
    sed -i 's/luci-theme-argon/luci-theme-bootstrap/g' feeds/luci/collections/luci/Makefile
fi


mkdir -p "$DTS_DIR"
cp "$SRC/d.txt" "$DTS_DIR/mt7981b-fzs-5gcpe-p5.dts"


grep -q "define Device/fzs_5gcpe-p5" "$MK" || cat "$SRC/f.txt" >> "$MK"


python3 - "$SRC/n.txt" "$NET" <<'PY'
import sys
frag, target = sys.argv[1], sys.argv[2]

lines = [l.rstrip() for l in open(frag).read().splitlines() if l.strip()]
if not lines[0].startswith("\t"):
    lines[0] = "\t" + lines[0].lstrip()
    lines[1:] = ["\t\t" + l.lstrip() for l in lines[1:]]
block = "".join(l + "\n" for l in lines)
s = open(target).read()
if "fzs,5gcpe-p5)" not in s:
    start = s.index("mediatek_setup_interfaces()")
    pos = s.index("\tesac", start)
    s = s[:pos] + block + s[pos:]
open(target, "w").write(s)
PY
chmod +x "$NET"

echo "[p5] injected from $SRC : dts + filogic.mk + 02_network"

# ============================================================
# FullCone 实现替换 + 默认全开 + LuCI 开关
#   ImmortalWrt 25.12 内置 kmod-nft-fullcone (Chion/llccd, UDP only)
#     -> SONiC fullcone (mufeng05/openwrt-sonic-fullcone, 内核态 EIM/EIF)
#
#   默认全开 = 全局 gate 打开 + 所有出口(masq) zone 打开 + 全协议
#   LuCI 开关 = 全局 / zone 级 / 协议限定，三个都补齐（中文，不依赖 po）
#
# 只改动 openwrt 源码树；custom/、workflow、0.config 全部保持原样。
# ============================================================

# 项目默认分支是 master，不要用 main
SONIC_INSTALLER="https://raw.githubusercontent.com/mufeng05/openwrt-sonic-fullcone/master/add_sonic_fullcone.sh"

# 1 = 刷机即全开（默认）；改成 0 则回到 sonic 原生默认（全局开关关闭）
SONIC_FULLCONE_DEFAULT=1

# 1) 删掉 ImmortalWrt 自带的 fullconenat 独立内核模块包
#    （kmod-nft-fullcone / kmod-ipt-fullconenat / iptables-mod-fullconenat）
for d in $(find package -maxdepth 6 -type d -iname '*fullconenat*' 2>/dev/null || true); do
    echo "[fullcone] remove legacy package: $d"
    rm -rf "$d"
done

# 2) 去掉 firewall4 / firewall3 对这些已删除模块的依赖
#    不去掉的话 `make defconfig` 会因依赖缺失把 firewall4 一起关掉，固件没有防火墙
if [ -f package/network/config/firewall4/Makefile ]; then
    sed -i 's/+kmod-nft-fullcone//g' package/network/config/firewall4/Makefile
fi
if [ -f package/network/config/firewall/Makefile ]; then
    sed -i 's/+iptables-mod-fullconenat//g' package/network/config/firewall/Makefile
fi

# 3) 清掉 ImmortalWrt 自己的 fullcone 补丁，避免和 sonic 补丁重复 apply
#    firewall4 的 001-firewall4-add-support-for-fullcone-nat.patch 必须删；
#    libnftnl / nftables 的同名补丁会由 sonic 脚本用 cp -f 覆盖回来，一并先清干净
for d in package/network/config/firewall4/patches \
         package/network/config/firewall/patches \
         package/libs/libnftnl/patches \
         package/network/utils/nftables/patches \
         package/network/utils/iptables/patches ; do
    [ -d "$d" ] || continue
    for p in "$d"/*.patch; do
        [ -f "$p" ] || continue
        if grep -qi 'fullcone' "$p"; then
            echo "[fullcone] drop legacy patch: $p"
            rm -f "$p"
        fi
    done
done

# 4) sonic 的 LuCI 补丁依赖 feeds/luci，而工作流把 diy.sh 排在 feeds 之前
#    这里提前跑一次；工作流随后还会再跑一次，无副作用
./scripts/feeds update -a
./scripts/feeds install -a

# 5) 应用 sonic 全套补丁（内核 984/985/986/987 + fw3/fw4 + iptables +
#    libnftnl/nftables + LuCI），脚本会自动 clone 仓库并识别 6.12 内核
curl -fsSL "$SONIC_INSTALLER" -o /tmp/add_sonic_fullcone.sh
bash /tmp/add_sonic_fullcone.sh

# ============================================================
# 6) LuCI 防火墙页面：补齐 sonic 的三个开关
# ------------------------------------------------------------
# ImmortalWrt 25.12 自带的 zones.js 只有一段：
#     if (L.hasSystemFeature('fullcone')) {
#         Enable FullCone NAT / Enable FullCone NAT6
#     }
#   - 受旧 kmod-nft-fullcone 的 feature 控制，模块删掉后这个开关可能直接隐藏
#   - fullcone6 是 turboacc NAT6 的选项，sonic 完全不认
#   - 最要命：没有 zone 级 fullcone 和 fullcone_proto。而 sonic 的 fw4 判定是
#     zone.fullcone = !!(defaults.fullcone && zone.fullcone)，没有 zone 开关
#     就只能命令行改 UCI，Web 界面看不到也改不了
#
# sonic 自带的 001-add-fullcone-options.patch 是按官方 LuCI 写的，hunk 上下文
# 与 ImmortalWrt 版 zones.js 对不上（第 58 行插了 if 块），直接 apply 会让
# luci-app-firewall 的 Build/Prepare 失败 -> 删掉它，改成按结构注入。
#
# 注入结果同时走两条路，内容完全一致：
#   a) 未跟踪的补丁文件 -> 构建期 apply，包里就是改好的（不碰 feeds 已跟踪文件）
#   b) files/ 覆盖 -> rootfs 兜底，不受 patch 上下文和 feeds update 影响
# 中文文案直接写进 JS，不依赖 po/lmo，所以可以放心还原 sonic 追加的翻译。
# ============================================================
LUCI_FW="feeds/luci/applications/luci-app-firewall"
ZONES_REL="htdocs/luci-static/resources/view/firewall/zones.js"
ZONES_SRC="$LUCI_FW/$ZONES_REL"
LUCI_PATCH="$LUCI_FW/patches/001-sonic-fullcone-luci.patch"
ROOTFS_JS="files/www/luci-static/resources/view/firewall/zones.js"

# 删掉 apply 不上的 sonic 原版 LuCI 补丁
rm -f "$LUCI_FW/patches/001-add-fullcone-options.patch"

# sonic 脚本往 po 追加过中文翻译；还原它，保证工作流后面 feeds update -a
# 时 git 工作区干净（补丁文件是未跟踪文件，reset --hard 不会删）
if [ -d feeds/luci/.git ]; then
    ( cd feeds/luci && git checkout -- applications/luci-app-firewall/po/zh_Hans/firewall.po ) 2>/dev/null || true
fi

[ -f "$ZONES_SRC" ] || { echo "[fullcone] ERROR: $ZONES_SRC not found" >&2; exit 1; }

mkdir -p "$LUCI_FW/patches" "files/www/luci-static/resources/view/firewall"

python3 - "$ZONES_SRC" "$ROOTFS_JS" "$LUCI_PATCH" "$ZONES_REL" <<'PYJS'
import sys, re, difflib

src, rootfs_js, patch_out, zones_rel = sys.argv[1:5]
orig = open(src, encoding='utf-8').read()
MARK = '/* SONiC fullcone (diy.sh) */'

if MARK in orig:
    new = orig
else:
    lines = orig.splitlines(True)

    # 6a) 移除 ImmortalWrt 条件渲染的旧全局开关块（含 sonic 不认的 fullcone6）
    out, skip, depth = [], False, 0
    for l in lines:
        if not skip and "L.hasSystemFeature('fullcone')" in l:
            skip, depth = True, l.count('{') - l.count('}')
            continue
        if skip:
            depth += l.count('{') - l.count('}')
            if depth <= 0:
                skip = False
            continue
        out.append(l)
    lines = out

    def insert_before(needle, block):
        for i, l in enumerate(lines):
            if needle in l:
                ind = re.match(r'^(\s*)', l).group(1)
                sub = ind + '\t'
                lines[i:i] = [b.replace('@@I@@', ind).replace('@@S@@', sub) + '\n'
                              for b in block]
                return
        raise SystemExit('zones.js: anchor not found: ' + needle)

    # 6b) 全局 gate：无条件显示、中文、默认开
    glob = [
        '@@I@@' + MARK,
        "@@I@@o = s.option(form.Flag, 'fullcone', '全锥形 NAT（SONiC）',",
        "@@S@@'SONiC 全锥形 NAT 全局总开关。开启后，还需在每个区域的设置中单独启用全锥形 NAT。');",
        "@@I@@o.default = '1';",
        '@@I@@o.rmempty = true;',
        '@@I@@o.optional = true;',
        '@@I@@',
    ]
    for i, l in enumerate(lines):
        if "s.option(form.Flag, 'drop_invalid'" in l:
            ind = re.match(r'^(\s*)', l).group(1)
            sub = ind + '\t'
            lines[i + 1:i + 1] = [b.replace('@@I@@', ind).replace('@@S@@', sub) + '\n'
                                  for b in glob]
            break
    else:
        raise SystemExit('zones.js: drop_invalid anchor not found')

    # 6c) zone 级开关（常规标签，仅 masq zone 可见）
    insert_before("s.taboption('general', form.Flag, 'mtu_fix'", [
        "@@I@@o = s.taboption('general', form.Flag, 'fullcone', '全锥形 NAT',",
        "@@S@@'为此区域启用 SONiC 全锥形 NAT（需先在常规设置中打开全局开关）；可在高级设置中限定协议。');",
        '@@I@@o.editable = true;',
        "@@I@@o.depends('masq', '1');",
        '@@I@@',
    ])

    # 6d) 协议限定（高级标签，留空 = 全协议）
    insert_before("s.taboption('conntrack', form.Flag, 'masq_allow_invalid'", [
        "@@I@@o = s.taboption('advanced', form.MultiValue, 'fullcone_proto', '全锥形 NAT 协议',",
        "@@S@@'留空表示全部协议（TCP / UDP / UDP-Lite / SCTP / DCCP）使用全锥形 NAT；游戏与 P2P 建议仅选 UDP。UDP-Lite、SCTP、DCCP 还需内核开启对应连接跟踪。');",
        "@@I@@o.value('tcp', 'TCP');",
        "@@I@@o.value('udp', 'UDP');",
        "@@I@@o.value('udplite', 'UDP-Lite');",
        "@@I@@o.value('sctp', 'SCTP');",
        "@@I@@o.value('dccp', 'DCCP');",
        "@@I@@o.depends('fullcone', '1');",
        '@@I@@o.modalonly = true;',
        '@@I@@o.optional = true;',
        "@@I@@o.placeholder = '全部协议';",
        '@@I@@o.display_size = 5;',
        "@@I@@o.delimiter = ' ';",
        '@@I@@',
    ])

    new = ''.join(lines)

# a) rootfs 覆盖（兜底，一定生效）
open(rootfs_js, 'w', encoding='utf-8').write(new)

# b) 构建期补丁（未跟踪文件，reset --hard 不会删）
if new != orig:
    diff = ''.join(difflib.unified_diff(
        orig.splitlines(True), new.splitlines(True),
        fromfile='a/' + zones_rel, tofile='b/' + zones_rel, n=3))
    open(patch_out, 'w', encoding='utf-8').write(diff)
    print('[fullcone] LuCI zones.js: 3 switches injected, patch generated')
else:
    print('[fullcone] LuCI zones.js: already injected, rootfs override refreshed')
PYJS

# 补丁做一次 dry-run 自检：能 apply 就留着（构建期生效），不能就删掉只靠 files/ 覆盖
if [ -s "$LUCI_PATCH" ]; then
    if ( cd "$LUCI_FW" && patch -p1 --dry-run --forward -i patches/001-sonic-fullcone-luci.patch >/dev/null 2>&1 ); then
        echo "[fullcone] LuCI patch verified OK (build-time + rootfs override)"
    else
        echo "[fullcone] LuCI patch dry-run failed, dropped (rootfs override only)"
        rm -f "$LUCI_PATCH"
    fi
fi

# ============================================================
# 7) 默认全开：固化到源码默认配置 + 首次启动兜底，两层保障
#    sonic 是两级开关：defaults.fullcone 是全局 gate，每个 zone 还要单独开。
#    ImmortalWrt 25.12 的默认 firewall.config 里 defaults.fullcone 已经是 1，
#    真正缺的是 zone 级 option fullcone —— 这一步把它补上。
# ============================================================
if [ "$SONIC_FULLCONE_DEFAULT" = "1" ]; then

    # 7a) 源码层：给默认 firewall 配置的每个 masq zone 补 option fullcone 1
    #     只给 masq/masq6 的出口 zone 开：fw4 模板是 `zone.masq && zone.fullcone`
    #     才生成规则，且 sonic 补丁会对 fullcone zone 关闭 auto_helper，
    #     给 lan 这类内网 zone 开有害无益。
    #     不写 fullcone_proto —— 留空即全协议（tcp/udp/udplite/sctp/dccp）。
    python3 - <<'PYFW'
import os, re

candidates = [
    "package/network/config/firewall/files/firewall.config",
    "package/network/config/firewall4/files/firewall.config",
    "package/network/config/firewall/root/etc/config/firewall",
    "package/network/config/firewall4/root/etc/config/firewall",
]

for path in candidates:
    if not os.path.isfile(path):
        continue
    text = open(path).read()
    blocks = re.split(r'(?m)(?=^config\s+\S)', text)
    out = []
    changed = False
    for b in blocks:
        lines_src = b.lstrip().splitlines()
        head = lines_src[0] if lines_src else ''
        if head.startswith('config defaults'):
            if not re.search(r'(?m)^\s*option\s+fullcone\b', b):
                ls = b.splitlines(True)
                for i, l in enumerate(ls):
                    if re.match(r'^\s*option\s', l):
                        indent = re.match(r'^(\s*)', l).group(1)
                        ls.insert(i, indent + 'option fullcone 1\n')
                        changed = True
                        break
                b = ''.join(ls)
        elif head.startswith('config zone'):
            has_masq = re.search(r'(?m)^\s*option\s+masq6?\s+[\'"]?1[\'"]?\s*$', b)
            if has_masq and not re.search(r'(?m)^\s*option\s+fullcone\b', b):
                ls = b.splitlines(True)
                for i, l in enumerate(ls):
                    if re.match(r'^\s*option\s+masq6?\s', l):
                        indent = re.match(r'^(\s*)', l).group(1)
                        ls.insert(i + 1, indent + 'option fullcone 1\n')
                        changed = True
                        break
                b = ''.join(ls)
        out.append(b)
    if changed:
        open(path, 'w').write(''.join(out))
        print("[fullcone] defaults written into", path)
PYFW

    # 7b) 运行层兜底：不管 /etc/config/firewall 由哪个包提供，首次开机都强制打开
    #     uci-defaults 执行后会自动删除，不会反复覆盖用户后续手动改的配置
    mkdir -p files/etc/uci-defaults
    cat > files/etc/uci-defaults/99-sonic-fullcone <<'EOF'
#!/bin/sh
# SONiC fullcone 默认全开（首次启动执行一次）
# 全局 gate + 所有出口 zone + 不设 fullcone_proto（全协议）
uci -q set firewall.@defaults[0].fullcone='1'

i=0
while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
    z="firewall.@zone[$i]"
    if [ "$(uci -q get "${z}.masq")" = "1" ] || [ "$(uci -q get "${z}.masq6")" = "1" ]; then
        uci -q set "${z}.fullcone=1"
        uci -q delete "${z}.fullcone_proto" 2>/dev/null || true
    fi
    i=$((i + 1))
done
uci -q commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1 || true
exit 0
EOF
    chmod +x files/etc/uci-defaults/99-sonic-fullcone
    echo "[fullcone] default ON: global gate + all masq zones + all protocols"
else
    echo "[fullcone] default OFF (sonic native defaults)"
fi

# hack-6.12/952-net-conntrack-events-... 是通用 conntrack notifier 补丁，
# 改的文件与 sonic 的 984/987（nf_nat_core.c）不同，保留不冲突。
echo "[fullcone] done: SONiC fullcone installed, legacy nft-fullcone removed, LuCI switches ready"

# ============================================================
# 8) USB/5G 模组 -> 有线 / 无线 PPE 加速（主线 mt76 + 主线 mtk_ppe）
# ------------------------------------------------------------
# 基线：immortalwrt/immortalwrt 分支 openwrt-25.12，Linux 6.12，
#       不使用闭源 mt_wifi / mediatek_hnat。
#
# 只修改本文件（custom/diy_sonic.sh）。
#   custom/0.config、workflow、d.txt / f.txt / n.txt 一律不动；
#   所有改动都在编译树内由本脚本运行时生成。
#
# 重要：本工作流把 diy.sh 排在 `mv 0.config .config && make defconfig` 之前，
#       所以 .config 此时还不存在，改 .config 会被覆盖 -> 一律改
#       target/linux/mediatek/filogic/config-6.12（内核 config 片段）。
#
# 接线分两层：
#   [A] 默认启用，零编译风险：打开主线 WED + HW flow offload，
#       部署 /etc/modules.d、uci-defaults、验证脚本。
#   [B] 默认关闭（EXTDEV_ENABLE=0）：USB/5G external-device 回送层。
#       上一轮交付的实现包是「骨架」——核心 mtk_ppe_extdev_inject()
#       的 QDMA/PSE loopback 描述符填充留了 TODO(6.12)，且补丁按 5.14
#       版 mtk_ppe_offload.c 上下文写的，6.12 已重构，直接启用会编译失败。
#       所以先把补丁/源码完整落盘到 extdev-staging/，不进编译树；
#       对齐 6.12 源码后把 EXTDEV_ENABLE 改成 1 即全面启用。
#       编译报 extdev 符号错误时，改回 0 即可恢复出固件。
# ============================================================

EXTDEV_ENABLE=0                      # 0 = 接线待启用（云编译必成功）；1 = 全面启用
EXTDEV_PREFIX="wwan,usb,eth2"        # QMI/MBIM=wwan0，ECM/RNDIS=usb0/eth1/eth2

TK="target/linux/mediatek"
PDIR="$TK/patches-6.12"
FDIR="$TK/files-6.12/drivers/net/ethernet/mediatek"
STAGE="$TK/extdev-staging"
CFG="$TK/filogic/config-6.12"

mkdir -p "$STAGE" "$FDIR" "$PDIR" 2>/dev/null || true

# ------------------------------------------------------------
# 8.1 [A] 内核 config：主线 WED + 硬件 flow offload（默认启用）
#     这几项是 25.12 原生能力，开在内核 config 片段里，
#     make defconfig 会合并，不受 0.config 覆盖影响。
# ------------------------------------------------------------
if [ -f "$CFG" ]; then
    python3 - "$CFG" "$EXTDEV_ENABLE" <<'PYCFG' || true
import sys, re
path, enable = sys.argv[1], sys.argv[2] == '1'
s = open(path).read()

def set_sym(sym, val):
    global s
    pat = re.compile(r'(?m)^#?\s*' + re.escape(sym) + r'(?:=.*| is not set)\s*$')
    line = ('# %s is not set' % sym) if val == 'n' else ('%s=%s' % (sym, val))
    if pat.search(s):
        s = pat.sub(line, s)
    else:
        s = s.rstrip('\n') + '\n' + line + '\n'

set_sym('CONFIG_NET_MEDIATEK_SOC_WED', 'y')
set_sym('CONFIG_NF_FLOW_TABLE_HW_OFFLOAD', 'y')
set_sym('CONFIG_NF_CONNTRACK_EVENTS', 'y')
set_sym('CONFIG_NET_MEDIATEK_PPE_EXTDEV', 'y' if enable else 'n')
open(path, 'w').write(s)
print('[extdev] kernel config updated:', path)
PYCFG
else
    echo "[extdev] WARN: $CFG not found, skip kernel config tweak"
fi

# ------------------------------------------------------------
# 8.2 [B] 实现包落盘（补丁 + 源码），默认只放 staging，不进编译树
# ------------------------------------------------------------

cat > "$STAGE/1001-mtk-ppe-extdev.patch" <<'PATCHEOF'
From: porting skeleton <local>
Subject: [PATCH] net: ethernet: mtk_eth_soc: add external-device (USB/5G) PPE ingress

Downlink-only hardware offload for flows whose WAN side is a USB 5G modem.
The modem netdev is NOT part of the PSE/GDM matrix, so a CPU-side rx_handler
injects skbs into the PPE lookup path; FOE entries reuse the existing DSA /
WDMA egress encoders in mtk_ppe_offload.c. Uplink stays on the CPU.

STATUS: skeleton. All TODO(6.12) markers must be reconciled with the actual
6.12 tree (see extdev-staging/README) before this patch will apply/compile.
The hunk line numbers below are ESTIMATES; `patch -p1 --fuzz=3` tolerates
offset, but the context lines must be re-checked against 6.12 source.
---
 drivers/net/ethernet/mediatek/Kconfig            |  8 +++
 drivers/net/ethernet/mediatek/Makefile           |  1 +
 drivers/net/ethernet/mediatek/mtk_eth_soc.c      | 38 ++++++++++
 drivers/net/ethernet/mediatek/mtk_eth_soc.h      |  4 ++
 drivers/net/ethernet/mediatek/mtk_ppe_offload.c  | 96 ++++++++++++++++++++++
 5 files changed

diff --git a/drivers/net/ethernet/mediatek/Kconfig b/drivers/net/ethernet/mediatek/Kconfig
--- a/drivers/net/ethernet/mediatek/Kconfig
+++ b/drivers/net/ethernet/mediatek/Kconfig
@@ -1,3 +1,11 @@
+# PPE external-device (USB/5G modem) downlink offload
+config NET_MEDIATEK_PPE_EXTDEV
+	bool "PPE external-device (USB/5G modem) downlink offload"
+	depends on NET_MEDIATEK_SOC && NET_MEDIATEK_SOC_WED
+	depends on NF_CONNTRACK && NF_FLOW_TABLE
+	help
+	  Downlink-only PPE offload for USB-attached 5G modems acting as WAN.
+	  Non-upstreamable hack. Requires wed_enable=Y on the mt76 wifi driver.
+
 # SPDX-License-Identifier: GPL-2.0-only
 config NET_MEDIATEK_SOC
 	tristate "MediaTek SoC Ethernet support"
diff --git a/drivers/net/ethernet/mediatek/Makefile b/drivers/net/ethernet/mediatek/Makefile
--- a/drivers/net/ethernet/mediatek/Makefile
+++ b/drivers/net/ethernet/mediatek/Makefile
@@ -1,3 +1,4 @@
 mtk_eth-y			+= mtk_ppe_offload.o
+mtk_eth-$(CONFIG_NET_MEDIATEK_PPE_EXTDEV) += mtk_ppe_extdev.o
 # NOTE: compiled INTO mtk_eth, not a standalone module, so that
 # mtk_ppe_offload.c's static helpers and eth->flow_table can be shared.
 obj-$(CONFIG_NET_MEDIATEK_SOC) += mtk_eth.o
diff --git a/drivers/net/ethernet/mediatek/mtk_eth_soc.h b/drivers/net/ethernet/mediatek/mtk_eth_soc.h
--- a/drivers/net/ethernet/mediatek/mtk_eth_soc.h
+++ b/drivers/net/ethernet/mediatek/mtk_eth_soc.h
@@ -1709,6 +1709,7 @@ struct mtk_eth {
 	u8 debug_level;
 	u8 qos_toggle;
 	u8 l4s_toggle;
 	struct mtk_ppe *ppe[3];
 	struct rhashtable flow_table;
+	struct mtk_extdev *extdev;	/* NULL unless CONFIG_NET_MEDIATEK_PPE_EXTDEV */
 };
diff --git a/drivers/net/ethernet/mediatek/mtk_eth_soc.c b/drivers/net/ethernet/mediatek/mtk_eth_soc.c
--- a/drivers/net/ethernet/mediatek/mtk_eth_soc.c
+++ b/drivers/net/ethernet/mediatek/mtk_eth_soc.c
@@ -1,3 +1,41 @@
+/*
+ * CPU -> PPE injection point.
+ *
+ * TODO(6.12): THE HARDEST PART. The FOE entry for this flow is already
+ * committed; we need the QDMA/PSE loopback descriptor that makes the PPE
+ * actually forward the skb. Derive it from:
+ *   - mtk_ppe_check_skb() / __mtk_ppe_check_skb() in mtk_ppe.c
+ *   - MTK_PPE_CPU_REASON_HIT_UNBIND_RATE_REACHED handling in mtk_eth_soc.c
+ *   - closed-source mtk_hnat "rxppd" + skb_hnat_magic_tag mechanism
+ *   - the 25.12 ports (chasey-dev/immortalwrt-mt798x-rebase, OpenFi 6C),
+ *     whose changelog says "USB HNAT loopback rewritten against upstream's
+ *     new RX code" -- expect to redo this on every kernel bump.
+ * Returns 0 when handed to the PPE, negative on fallback (software xmit).
+ */
+int mtk_ppe_extdev_inject(struct mtk_eth *eth, struct sk_buff *skb,
+			  struct mtk_extdev_flow *f)
+{
+	struct mtk_ppe *ppe = eth->ppe[f->ppe_index];
+	if (unlikely(!ppe))
+		return -ENODEV;
+	/* mtk_ppe_check_skb(ppe, skb, f->foe_hash);  <-- validates binding
+	 * ONLY, it does NOT make the hardware forward the packet. */
+	return -EOPNOTSUPP;
+}
+EXPORT_SYMBOL_GPL(mtk_ppe_extdev_inject);
+
+/* probe/remove hooks: add to mtk_probe() / mtk_remove() */
+/*	if (IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV))
+ *		mtk_extdev_init(eth);
+ *	if (IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV))
+ *		mtk_extdev_deinit(eth);
+ */
+
 #include "mtk_eth_soc.h"
 #include "mtk_wed.h"
 #include "mtk_ppe.h"
+
+#if IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV)
+#include "mtk_ppe_extdev.h"
+#endif
diff --git a/drivers/net/ethernet/mediatek/mtk_ppe_offload.c b/drivers/net/ethernet/mediatek/mtk_ppe_offload.c
--- a/drivers/net/ethernet/mediatek/mtk_ppe_offload.c
+++ b/drivers/net/ethernet/mediatek/mtk_ppe_offload.c
@@ -1,3 +1,99 @@
+/*
+ * IMPORTANT: do NOT "fix" mtk_flow_set_output_device()'s -EOPNOTSUPP by
+ * adding the USB netdev as a pse_port. It is the INGRESS side and must be
+ * represented by MTK_PPE_EXTDEV_PORT instead; only EGRESS goes through there.
+ */
+#if IS_ENABLED(CONFIG_NET_MEDIATEK_PPE_EXTDEV)
+#include "mtk_ppe_extdev.h"
+
+int mtk_flow_offload_replace_extdev(struct mtk_eth *eth,
+				    struct mtk_extdev_flow *f,
+				    struct mtk_foe_entry *foe)
+{
+	struct net_device *dev = f->odev;
+	struct mtk_wdma_info info;
+	struct mtk_flow_entry *entry;
+	int dsa_port, err;
+
+	mtk_foe_entry_prepare(eth, foe, MTK_PPE_EXTDEV_PORT);
+	err = mtk_foe_entry_set_ipv4_tuple(foe, true,
+					   f->src_addr, f->src_port,
+					   f->dst_addr, f->dst_port);
+	if (err)
+		return err;
+
+	dsa_port = mtk_flow_get_dsa_port(&dev);	/* swaps dev to cpu master */
+	if (dsa_port >= 0) {
+		mtk_foe_entry_set_dsa(foe, dsa_port);
+		f->egress = MTK_EXTDEV_EGRESS_DSA;
+		f->e.dsa_port = dsa_port;
+	} else if (dev == eth->netdev[0] || dev == eth->netdev[1]) {
+		int pse = (dev == eth->netdev[0]) ? 1 : 2;
+		mtk_foe_entry_set_pse_port(foe, pse);
+		f->egress = MTK_EXTDEV_EGRESS_PSE;
+		f->e.pse_port = pse;
+	} else if (mtk_flow_get_wdma_info(dev, f->eth_dst, &info) == 0) {
+		/* Requires CONFIG_NET_MEDIATEK_SOC_WED=y and wed_enable=Y.
+		 * WED covers 5G/6G radios only, mutually exclusive with AQL. */
+		mtk_foe_entry_set_wdma(foe, info.wdma_idx, info.txq,
+				       info.bss, info.wcid);
+		f->egress = MTK_EXTDEV_EGRESS_WDMA;
+		f->e.wdma.wdma_idx = info.wdma_idx;
+		f->e.wdma.txq      = info.txq;
+		f->e.wdma.bss      = info.bss;
+		f->e.wdma.wcid     = info.wcid;
+	} else {
+		return -EOPNOTSUPP;
+	}
+
+	/* Share eth->flow_table with the driver: 6.12 rework (c4f033d9e03e)
+	 * walks it for stats/aging. A parallel table causes counter underflow
+	 * (see "preserve sibling PPE bindings" fix on 25.12.5). */
+	entry = kzalloc(sizeof(*entry), GFP_ATOMIC);
+	if (!entry)
+		return -ENOMEM;
+	entry->cookie    = f->cookie;
+	entry->ppe_index = f->ppe_index;
+	entry->hash      = 0xffff;
+	entry->type      = MTK_FLOW_TYPE_L2;	/* TODO(6.12): confirm vs L2_SUBFLOW */
+	memcpy(&entry->data, foe, sizeof(*foe));
+	rhashtable_insert_fast(&eth->flow_table, &entry->node, mtk_flow_ht_params);
+	hlist_add_head(&entry->list,
+		       &eth->ppe[f->ppe_index]->foe_flow[
+			   mtk_ppe_hash_entry(eth, foe) / eth->soc->hash_offset]);
+	f->foe_hash = mtk_ppe_hash_entry(eth, foe);
+	mtk_foe_entry_commit(eth->ppe[f->ppe_index], entry);
+	f->foe = entry;
+	return 0;
+}
+
+void mtk_flow_offload_destroy_extdev(struct mtk_eth *eth,
+				     struct mtk_extdev_flow *f)
+{
+	if (!f->foe)
+		return;
+	mtk_foe_entry_clear(eth->ppe[f->ppe_index], f->foe);
+	rhashtable_remove_fast(&eth->flow_table, &f->foe->node, mtk_flow_ht_params);
+	kfree(f->foe);	/* TODO(6.12): call_rcu if the driver walks it under RCU */
+	f->foe = NULL;
+}
+#endif /* CONFIG_NET_MEDIATEK_PPE_EXTDEV */
+
+/*
+ * ALSO REQUIRED (see extdev-staging/README):
+ *  - give USB netdevs .ndo_fill_forward_path returning DEV_PATH_HOST,
+ *    otherwise dev_fill_forward_path() aborts and out.ifindex==0 drops one
+ *    packet per re-offload cycle. Backport OpenWrt aa9479b0 or implement ndo.
+ *  - keep nft flowtable devices = { SoC ports only }; do NOT add wwan0,
+ *    FLOW_BLOCK_BIND would fail / fall back to software for the whole table.
+ */
+
 #include "mtk_eth_soc.h"
 #include "mtk_wed.h"
PATCHEOF

# 自动校正 hunk 头计数（骨架补丁的行号是估计值，计数必须与内容一致，
# 否则 patch 直接报 malformed patch；偏移由 patch -p1 --fuzz=3 自行查找）
python3 - "$STAGE/1001-mtk-ppe-extdev.patch" <<'PYHUNK' || true
import re, sys
path = sys.argv[1]
L = open(path).read().splitlines(True)
out, i = [], 0
while i < len(L):
    m = re.match(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$', L[i])
    if not m:
        out.append(L[i]); i += 1; continue
    j, old, new = i + 1, 0, 0
    while j < len(L) and not re.match(r'^(@@ |diff --git|--- |\+\+\+ )', L[j]):
        c = L[j][:1]
        if c in ' -': old += 1
        if c in ' +': new += 1
        j += 1
    out.append('@@ -%s,%d +%s,%d @@%s\n' %
               (m.group(1), old, m.group(3), new, m.group(5)))
    out.extend(L[i + 1:j])
    i = j
open(path, 'w').writelines(out)
print('[extdev] patch hunk counts normalized')
PYHUNK

cat > "$STAGE/mtk_ppe_extdev.h" <<'HEOF'
/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * External (USB/5G modem) ingress for MediaTek PPE, 25.12 / Linux 6.12.
 * Skeleton: TODO(6.12) markers must be reconciled with the real 6.12 tree.
 */
#ifndef __MTK_PPE_EXTDEV_H
#define __MTK_PPE_EXTDEV_H
#include <linux/netdevice.h>
#include <linux/rhashtable.h>
#include <linux/skbuff.h>
#include <linux/timer.h>
#include "mtk_eth_soc.h"

#define MTK_PPE_EXTDEV_PORT		0
#define MTK_EXTDEV_PREFIX_MAX		64
#define MTK_EXTDEV_FLOW_TIMEOUT		(30 * HZ)

enum mtk_extdev_egress {
	MTK_EXTDEV_EGRESS_DSA,
	MTK_EXTDEV_EGRESS_PSE,
	MTK_EXTDEV_EGRESS_WDMA,
};

struct mtk_extdev_wdma { int wdma_idx, txq, bss, wcid; };

struct mtk_extdev_flow {
	struct rhash_head node;
	unsigned long cookie;
	__be32 src_addr, dst_addr;
	__be16 src_port, dst_port;
	u8 l4proto;
	u8 eth_src[ETH_ALEN], eth_dst[ETH_ALEN];
	__be16 eth_proto;
	enum mtk_extdev_egress egress;
	union { int dsa_port; int pse_port; struct mtk_extdev_wdma wdma; } e;
	struct net_device *odev;
	u16 foe_hash;
	u8 ppe_index;
	unsigned long last_used;
	struct mtk_flow_entry *foe;
	struct rcu_head rcu;
};

struct mtk_extdev_port {
	struct list_head list;
	struct net_device *dev;
	struct mtk_eth *eth;
	char name[IFNAMSIZ];
	bool rx_handler_owned;
	struct mtk_extdev *ed;
};

struct mtk_extdev {
	struct mtk_eth *eth;
	struct list_head ports;
	struct rhashtable flows;
	spinlock_t lock;
	struct timer_list gc_timer;
	char prefix[MTK_EXTDEV_PREFIX_MAX];
	u64 rx_packets, hit_packets, pass_packets, learned, aged_out, egress_fail;
};

static const struct rhashtable_params mtk_extdev_flow_ht_params = {
	.head_offset = offsetof(struct mtk_extdev_flow, node),
	.key_offset  = offsetof(struct mtk_extdev_flow, cookie),
	.key_len     = sizeof(unsigned long),
	.automatic_shrinking = true,
};

int  mtk_extdev_init(struct mtk_eth *eth);
void mtk_extdev_deinit(struct mtk_eth *eth);
int  mtk_extdev_bind_port(struct mtk_extdev *ed, struct net_device *dev);
void mtk_extdev_unbind_all(struct mtk_extdev *ed);
int  mtk_extdev_flow_add(struct mtk_extdev *ed, struct sk_buff *skb,
			 struct net_device *odev);
void mtk_extdev_flow_del(struct mtk_extdev *ed, unsigned long cookie);
int  mtk_flow_offload_replace_extdev(struct mtk_eth *eth,
				     struct mtk_extdev_flow *f,
				     struct mtk_foe_entry *foe);
void mtk_flow_offload_destroy_extdev(struct mtk_eth *eth,
				    struct mtk_extdev_flow *f);
int  mtk_ppe_extdev_inject(struct mtk_eth *eth, struct sk_buff *skb,
			   struct mtk_extdev_flow *f);
#endif
HEOF

cat > "$STAGE/mtk_ppe_extdev.c" <<'CEOF'
/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * External (USB/5G modem) ingress for MediaTek PPE -- 25.12 skeleton.
 * Compile INTO mtk_eth (see patch Makefile hunk), NOT as standalone module.
 *
 * STATUS: NOT compiled against a 6.12 tree. The injection function in
 * 1001-mtk-ppe-extdev.patch is the missing hardware piece -- until it is
 * implemented this module only gives a software fastpath (L2 rewrite +
 * dev_queue_xmit), NOT actual PPE forwarding.
 */
#include <linux/module.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/jhash.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/rtnetlink.h>
#include <linux/string.h>
#include <net/neighbour.h>
#include "mtk_ppe.h"
#include "mtk_ppe_extdev.h"

static char *extdev_prefix = "wwan,usb,eth2";
module_param(extdev_prefix, charp, 0644);
MODULE_PARM_DESC(extdev_prefix, "comma-separated USB/5G netdev name prefixes");

static unsigned long mtk_extdev_tuple_cookie(const struct iphdr *iph, u8 l4)
{
	__be16 sp = 0, dp = 0;
	if (iph->protocol == IPPROTO_TCP || iph->protocol == IPPROTO_UDP) {
		const __be16 *ports = (const __be16 *)((const u8 *)iph + iph->ihl * 4);
		sp = ports[0]; dp = ports[1];
	}
	return (unsigned long)jhash_3words(iph->saddr ^ iph->daddr,
					   (__force u32)sp << 16 | (__force u32)dp,
					   l4, 0x5a17c0de);
}

static bool mtk_extdev_name_matches(struct mtk_extdev *ed, const char *name)
{
	char buf[MTK_EXTDEV_PREFIX_MAX], *p, *tok;
	strscpy(buf, ed->prefix, sizeof(buf));
	p = buf;
	while ((tok = strsep(&p, ",")) != NULL)
		if (*tok && !strncmp(name, tok, strlen(tok)))
			return true;
	return false;
}

static rx_handler_result_t mtk_extdev_rx_handler(struct sk_buff **pskb)
{
	struct sk_buff *skb = *pskb;
	struct mtk_extdev_port *p = rcu_dereference(skb->dev->rx_handler_data);
	struct mtk_extdev *ed;
	struct mtk_extdev_flow *f;
	struct iphdr *iph;
	unsigned long cookie;
	int ret;

	if (unlikely(!p || !p->ed))
		return RX_HANDLER_PASS;
	ed = p->ed;
	ed->rx_packets++;

	if (skb->protocol != htons(ETH_P_IP))
		goto pass;
	if (!pskb_may_pull(skb, sizeof(struct iphdr) + 4))
		goto pass;
	iph = ip_hdr(skb);
	if (iph->frag_off & htons(IP_MF | IP_OFFSET))
		goto pass;
	if (iph->protocol != IPPROTO_TCP && iph->protocol != IPPROTO_UDP)
		goto pass;
	if (skb->ip_summed == CHECKSUM_NONE)
		goto pass;		/* ECM/RNDIS often ships bad/partial csum */

	cookie = mtk_extdev_tuple_cookie(iph, iph->protocol);
	rcu_read_lock();
	f = rhashtable_lookup(&ed->flows, &cookie, mtk_extdev_flow_ht_params);
	if (!f) {
		rcu_read_unlock();
		goto pass;		/* first packet: let netfilter learn it */
	}
	if (unlikely(skb_cow_head(skb, ETH_HLEN))) {
		rcu_read_unlock();
		kfree_skb(skb);
		return RX_HANDLER_CONSUMED;
	}
	ether_addr_copy(eth_hdr(skb)->h_source, f->eth_src);
	ether_addr_copy(eth_hdr(skb)->h_dest,   f->eth_dst);
	eth_hdr(skb)->h_proto = f->eth_proto;
	skb->dev = f->odev;
	skb->offload_fwd_mark = 1;
	f->last_used = jiffies;

	ret = mtk_ppe_extdev_inject(p->eth, skb, f);
	rcu_read_unlock();
	if (ret == 0) {
		ed->hit_packets++;
		return RX_HANDLER_CONSUMED;	/* real PPE offload */
	}
	/* TODO(6.12): software fastpath fallback only. Still saves netfilter,
	 * but is NOT PPE acceleration. Remove once inject() is implemented. */
	dev_queue_xmit(skb);
	ed->hit_packets++;
	return RX_HANDLER_CONSUMED;

pass:
	ed->pass_packets++;
	return RX_HANDLER_PASS;
}

static unsigned int mtk_extdev_postrouting(void *priv, struct sk_buff *skb,
					   const struct nf_hook_state *state)
{
	struct mtk_extdev *ed = priv;
	struct mtk_extdev_port *p;
	struct net_device *idev, *odev;
	bool found = false;

	idev = skb->dev ? : state->in;
	odev = skb_dst(skb) ? skb_dst(skb)->dev : state->out;
	if (!idev || !odev)
		return NF_ACCEPT;
	list_for_each_entry_rcu(p, &ed->ports, list)
		if (p->dev == idev) { found = true; break; }
	if (!found)
		return NF_ACCEPT;
	/* TODO(6.12): validate egress via mtk_flow_get_dsa_port() /
	 * mtk_flow_get_wdma_info() BEFORE inserting into the flow table. */
	return mtk_extdev_flow_add(ed, skb, odev) == 0 ? NF_ACCEPT : NF_ACCEPT;
}

static const struct nf_hook_ops mtk_extdev_nf_ops[] = {
	{ .hook = mtk_extdev_postrouting, .pf = NFPROTO_IPV4,
	  .hooknum = NF_INET_POST_ROUTING, .priority = NF_IP_PRI_LAST - 1 },
};

int mtk_extdev_flow_add(struct mtk_extdev *ed, struct sk_buff *skb,
			struct net_device *odev)
{
	struct mtk_extdev_flow *f;
	struct iphdr *iph = ip_hdr(skb);
	struct neighbour *neigh;
	struct mtk_foe_entry foe = {};
	unsigned long cookie;
	int err;

	cookie = mtk_extdev_tuple_cookie(iph, iph->protocol);
	if (rhashtable_lookup(&ed->flows, &cookie, mtk_extdev_flow_ht_params))
		return -EEXIST;

	neigh = dst_neigh_lookup(skb_dst(skb), &iph->daddr);
	if (!neigh || is_zero_ether_addr(neigh->ha))
		return -ENOENT;

	f = kzalloc(sizeof(*f), GFP_ATOMIC);
	if (!f)
		return -ENOMEM;
	f->cookie    = cookie;
	f->src_addr  = iph->saddr;
	f->dst_addr  = iph->daddr;
	f->l4proto   = iph->protocol;
	f->odev      = odev;
	f->ppe_index = 0;
	f->last_used = jiffies;
	f->eth_proto = htons(ETH_P_IP);
	ether_addr_copy(f->eth_dst, neigh->ha);
	/* TODO(6.12): source MAC must be the egress netdev's dev_addr */
	neigh_release(neigh);

	err = mtk_flow_offload_replace_extdev(ed->eth, f, &foe);
	if (err) { kfree(f); ed->egress_fail++; return err; }
	rhashtable_insert_fast(&ed->flows, &f->node, mtk_extdev_flow_ht_params);
	ed->learned++;
	return 0;
}

void mtk_extdev_flow_del(struct mtk_extdev *ed, unsigned long cookie)
{
	struct mtk_extdev_flow *f;
	f = rhashtable_lookup(&ed->flows, &cookie, mtk_extdev_flow_ht_params);
	if (!f)
		return;
	rhashtable_remove_fast(&ed->flows, &f->node, mtk_extdev_flow_ht_params);
	mtk_flow_offload_destroy_extdev(ed->eth, f);
	dev_put(f->odev);
	kfree_rcu(f, rcu);
}

static void mtk_extdev_gc(struct timer_list *t)
{
	struct mtk_extdev *ed = from_timer(ed, t, gc_timer);
	struct mtk_extdev_flow *f;
	struct rhashtable_iter it;
	rhashtable_walk_enter(&ed->flows, &it);
	rhashtable_walk_start(&it);
	while ((f = rhashtable_walk_next(&it)) != NULL) {
		if (IS_ERR(f))
			continue;
		if (time_after(jiffies, f->last_used + MTK_EXTDEV_FLOW_TIMEOUT)) {
			mtk_extdev_flow_del(ed, f->cookie);
			ed->aged_out++;
		}
	}
	rhashtable_walk_stop(&it);
	rhashtable_walk_exit(&it);
	mod_timer(&ed->gc_timer, jiffies + HZ);
}

int mtk_extdev_bind_port(struct mtk_extdev *ed, struct net_device *dev)
{
	struct mtk_extdev_port *p;
	int err;
	if (!mtk_extdev_name_matches(ed, dev->name))
		return 0;
	p = kzalloc(sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;
	p->dev = dev; p->eth = ed->eth; p->ed = ed;
	strscpy(p->name, dev->name, sizeof(p->name));
	dev_hold(dev);
	rtnl_lock();
	err = netdev_rx_handler_register(dev, mtk_extdev_rx_handler, p);
	rtnl_unlock();
	if (err == -EBUSY) {
		netdev_warn(dev, "extdev: rx_handler busy (bridged?); "
			    "keep it unbridged or attach to bridge master + rxppd\n");
		goto err_put;
	}
	if (err)
		goto err_put;
	p->rx_handler_owned = true;
	list_add_tail_rcu(&p->list, &ed->ports);
	netdev_info(dev, "extdev: bound to PPE pseudo port %d\n", MTK_PPE_EXTDEV_PORT);
	return 0;
err_put:
	dev_put(dev); kfree(p); return err;
}

void mtk_extdev_unbind_all(struct mtk_extdev *ed)
{
	struct mtk_extdev_port *p, *n;
	rtnl_lock();
	list_for_each_entry_safe(p, n, &ed->ports, list) {
		if (p->rx_handler_owned)
			netdev_rx_handler_unregister(p->dev);
		list_del_rcu(&p->list);
		dev_put(p->dev);
		kfree(p);
	}
	rtnl_unlock();
}

/* TODO(6.12): register_netdevice_notifier() to auto-bind hotplugged modems. */
int mtk_extdev_init(struct mtk_eth *eth)
{
	struct mtk_extdev *ed;
	struct net_device *dev;
	int err;
	ed = kzalloc(sizeof(*ed), GFP_KERNEL);
	if (!ed) return -ENOMEM;
	ed->eth = eth;
	INIT_LIST_HEAD(&ed->ports);
	spin_lock_init(&ed->lock);
	strscpy(ed->prefix, extdev_prefix, sizeof(ed->prefix));
	err = rhashtable_init(&ed->flows, &mtk_extdev_flow_ht_params);
	if (err) goto err_free;
	err = nf_register_net_hooks(&init_net, mtk_extdev_nf_ops,
				    ARRAY_SIZE(mtk_extdev_nf_ops));
	if (err) goto err_ht;
	timer_setup(&ed->gc_timer, mtk_extdev_gc, 0);
	mod_timer(&ed->gc_timer, jiffies + HZ);
	eth->extdev = ed;
	rcu_read_lock();
	for_each_netdev(&init_net, dev)
		mtk_extdev_bind_port(ed, dev);	/* takes rtnl itself */
	rcu_read_unlock();
	return 0;
err_ht: rhashtable_destroy(&ed->flows);
err_free: kfree(ed); return err;
}

void mtk_extdev_deinit(struct mtk_eth *eth)
{
	struct mtk_extdev *ed = eth->extdev;
	if (!ed) return;
	del_timer_sync(&ed->gc_timer);
	nf_unregister_net_hooks(&init_net, mtk_extdev_nf_ops,
				ARRAY_SIZE(mtk_extdev_nf_ops));
	mtk_extdev_unbind_all(ed);
	/* TODO(6.12): walk flows, mtk_flow_offload_destroy_extdev() each */
	rhashtable_destroy(&ed->flows);
	kfree(ed);
	eth->extdev = NULL;
}

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("USB/5G modem -> wired/wireless PPE offload (downlink only, skeleton)");
CEOF

cat > "$STAGE/README" <<'REOF'
启用前必读（EXTDEV_ENABLE=1 之前必须完成）
==========================================
1. 本目录里的 1001-mtk-ppe-extdev.patch 是按 5.14 版 mtk_ppe_offload.c
   上下文写的骨架，行号是估计值。6.12 已经过 c4f033d9e03e /
   33fc42de3327 重构，且本仓库的 sonic fullcone 脚本还会往内核打 984~987
   号补丁。请先把 patch 的 5 个 hunk 对齐到：
     build_dir/target-*/linux-mediatek_filogic/linux-6.12.*/drivers/net/ethernet/mediatek/
   再 `patch -p1 --dry-run --fuzz=3` 验证。
2. mtk_ppe_extdev.c 的 mtk_ppe_extdev_inject() 目前返回 -EOPNOTSUPP，
   rx_handler 退化成软件快路径（只省 netfilter，不是 PPE 硬件转发）。
   真正的 QDMA/PSE loopback 需要从 6.12 收包路径反推，参照
   mtk_ppe_check_skb() / 闭源 mtk_hnat 的 rxppd / 已移植的 25.12 分支。
3. 必须给 USB netdev 补 .ndo_fill_forward_path，或回移 OpenWrt
   aa9479b0 ("netfilter: fix flow offload with an unknown forward path")，
   否则 out.ifindex==0，每个 re-offload 周期丢一个包。
4. 不要把 wwan0 加进 nft flowtable 的 devices = {...}：USB netdev 没有
   NETIF_F_HW_FLOW_OFFLOAD，FLOW_BLOCK_BIND 会失败并整体回退软件路径。
5. 拓扑：USB WAN 保持独立三层接口（不进 br-lan），rx_handler 才不被
   bridge 占用；若必须进桥，改挂 bridge master 并保留 rxppd。
6. WED 与 QoS AQL 互斥；25.12 早期 bridger 有 bug，需更新版 +
   内核 042f7034ea / PR #26484。
7. 判定真加速：/sys/kernel/debug/ppe0/bind 出现 BND 流，且
   tc -s filter show dev eth0 ingress 的 "Sent hardware" 在打流时增长。
   吞吐变高不等于 PPE 生效（软件 flowtable 也能提吞吐）。

编译失败时：把 diy_sonic.sh 顶部 EXTDEV_ENABLE 改回 0，
           固件照常产出，本目录内容不进编译树。
REOF

# ------------------------------------------------------------
# 8.3 开关：EXTDEV_ENABLE=1 才把补丁/源码放进编译树
# ------------------------------------------------------------
if [ "$EXTDEV_ENABLE" = "1" ]; then
    if [ -d "$PDIR" ] && [ -d "$FDIR" ]; then
        cp -f "$STAGE/1001-mtk-ppe-extdev.patch" "$PDIR/1001-mtk-ppe-extdev.patch"
        cp -f "$STAGE/mtk_ppe_extdev.c" "$FDIR/mtk_ppe_extdev.c"
        cp -f "$STAGE/mtk_ppe_extdev.h" "$FDIR/mtk_ppe_extdev.h"
        echo "[extdev] ENABLED: patch -> $PDIR, sources -> $FDIR"
        echo "[extdev] WARNING: patch context / 6.12 symbols NOT yet verified;"
        echo "[extdev]          read $STAGE/README before building."
    else
        echo "[extdev] ERROR: $PDIR or $FDIR missing, kernel layer skipped" >&2
        EXTDEV_ENABLE=0
    fi
else
    echo "[extdev] extdev kernel layer staged only (EXTDEV_ENABLE=0):"
    echo "[extdev]   $STAGE/{1001-mtk-ppe-extdev.patch,mtk_ppe_extdev.c,.h,README}"
fi

# ------------------------------------------------------------
# 8.4 [A] rootfs 层：WED 参数、默认 offload、验证脚本（始终部署）
#     files/ 会被 OpenWrt 作为 rootfs overlay，不受 patch 上下文影响。
# ------------------------------------------------------------
mkdir -p files/etc/modules.d files/etc/uci-defaults files/usr/sbin 2>/dev/null || true

cat > files/etc/modules.d/50-mtk-ppe-extdev.conf <<'CONFEOF'
# WED must be on for the wireless (WDMA) egress branch.
# MT7981/MT7986 -> mt7915e; MT7996/MT7987 -> mt7996e.
# Re-apply after sysupgrade: modules.d is not in the default backup tarball.
mt7915e wed_enable=Y
CONFEOF

cat > files/etc/uci-defaults/98-mtk-ppe-extdev <<'UCIEOF'
#!/bin/sh
# 主线 PPE / WED 硬件 flow offload 默认全开（首次启动执行一次）
uci -q set firewall.@defaults[0].flow_offloading='1'
uci -q set firewall.@defaults[0].flow_offloading_hw='1'
uci -q commit firewall

# extdev 模块参数（built-in 时也可通过 /sys/module 写）
P=/sys/module/mtk_ppe_extdev/parameters/extdev_prefix
[ -w "$P" ] && echo '__EXTDEV_PREFIX__' > "$P"

/etc/init.d/firewall restart >/dev/null 2>&1 || true
exit 0
UCIEOF
sed -i "s|__EXTDEV_PREFIX__|$EXTDEV_PREFIX|g" files/etc/uci-defaults/98-mtk-ppe-extdev
chmod +x files/etc/uci-defaults/98-mtk-ppe-extdev

cat > files/usr/sbin/verify-extdev.sh <<'VERIFYEOF'
#!/bin/sh
# USB/5G -> 有线/无线 PPE 加速 验证脚本（打流时运行）
say() { printf '\n=== %s ===\n' "$*"; }

say "1. WED module parameter"
for m in mt7915e mt7996e; do
    f="/sys/module/$m/parameters/wed_enable"
    [ -r "$f" ] && { printf '  %s = ' "$m"; cat "$f"; }
done

say "2. bound external devices"
dmesg | grep -E 'extdev: (bound|rx_handler busy)' | tail -20
for f in /sys/kernel/debug/mtk_ppe/extdev/*; do
    [ -r "$f" ] && { printf '  %s = ' "$(basename "$f")"; cat "$f"; }
done

say "3. PPE bound flows (decisive check)"
for p in /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind \
         /sys/kernel/debug/mtk_ppe/bind; do
    [ -r "$p" ] || continue
    printf '  -- %s --\n' "$p"
    grep -E 'BND' "$p" | head -20
    echo "  (look for your LAN/WiFi client IP or MAC in orig=/new=)"
done

say "4. hardware counters (must grow while traffic flows)"
tc -s filter show dev eth0 ingress 2>/dev/null | grep -E 'in_hw|Sent hardware' | head -5
sleep 5
tc -s filter show dev eth0 ingress 2>/dev/null | grep -E 'Sent hardware' | head -5

say "5. CPU"
cat /proc/loadavg
echo "  mpstat -P ALL 1 3  (expect ~10-25% with offload, ~90% without)"

say "6. A/B control"
echo "  rmmod/mtk_ppe_extdev off -> BND flows disappear, CPU rises."
echo "  Throughput alone is NOT proof: software flowtable also helps."
VERIFYEOF
chmod +x files/usr/sbin/verify-extdev.sh

echo "[extdev] rootfs deployed: modules.d/50-mtk-ppe-extdev.conf,"
echo "[extdev]   uci-defaults/98-mtk-ppe-extdev, usr/sbin/verify-extdev.sh"
echo "[extdev] done (EXTDEV_ENABLE=$EXTDEV_ENABLE, prefix=$EXTDEV_PREFIX)"
