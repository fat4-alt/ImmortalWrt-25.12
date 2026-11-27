#!/bin/bash
# ============================================================
#  custom/diy.sh  ——  ImmortalWrt 25.12 / MT7981B 5G CPE
#
#  基于原 custom/diy.sh 重写：
#    x 不含 SONiC fullcone（不打 984~987 内核补丁、不删 firewall4 依赖、
#      不替换 NAT 栈、不默认全开 fullcone、不 restart firewall）
#    + 加入主线 PPE 硬件加速（WED 无线 + HW flow offload 有线）
#    + 修复「刷机后拿不到内网 IP / 进不了后台 / 无法联网」
#    + 脚本自包含健壮性：空片段不崩、不写空 DTS、不破坏板级网络配置
#
#  只改本文件；0.config / workflow / d.txt / f.txt / n.txt 内容均不改动，
#  所有改动都在编译树内运行时生成（0.config 仅做幂等补齐，见第 4 节）。
#
#  ★ 部署提示：workflow 里 DIY_SH 当前是 custom/diy_ppe.sh。
#    二选一才生效：
#      a) 把本文件覆盖保存为 custom/diy_ppe.sh（推荐，不动 workflow）
#      b) 把 .github/workflows/*.yml 的 DIY_SH 改成 custom/diy.sh
#    同时把实现包原样放进 custom/extdev/（第 7 节会装配它）。
#    确认 CONFIG_FILE 指向的配置里含有本机型 profile；第 4 节只在配置为空
#    时才补最小基线。
# ============================================================
set -e

# ---------------- 可调开关 ----------------
PPE_WED=1            # 1 = 打开 WED（无线侧 PPE / WDMA）
PPE_HW_OFFLOAD=1     # 1 = 打开主线硬件 flow offload（有线侧 PPE）
USB5G_EXTDEV=1       # 1 = 启用已按 6.12 收包路径写完的 USB/5G → PPE 回送层
                     #     （custom/extdev/ 实现包）；0 = 只留主线原生加速
EXTDEV_PREFIX="wwan,usb,eth2"   # QMI/MBIM=wwan0，ECM/RNDIS=usb0/ethX
LAN_IP="192.168.6.1"
BOARD="fzs,5gcpe-p5"
DEVICE="fzs_5gcpe-p5"

# ---------------- 路径 ----------------
SRC="$GITHUB_WORKSPACE/custom"
[ -d "$SRC" ] || SRC="$GITHUB_WORKSPACE"        # 兼容根目录布局（.config / diy.sh）
DTS_DIR="target/linux/mediatek/dts"
DTS="$DTS_DIR/mt7981b-fzs-5gcpe-p5.dts"
MK="target/linux/mediatek/image/filogic.mk"
NET="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
KCFG="target/linux/mediatek/filogic/config-6.12"
CFG_CANDIDATES="$SRC/0.config $GITHUB_WORKSPACE/.config $SRC/.config"

echo "[diy] SRC=$SRC  PPE_WED=$PPE_WED  PPE_HW_OFFLOAD=$PPE_HW_OFFLOAD"

# ============================================================
# 1) 品牌 / 管理地址（原逻辑，加存在性保护）
#    注意：只改默认 IP，不动 LAN 接口与 DHCP 的生成逻辑
# ============================================================
CG="package/base-files/files/bin/config_generate"
if [ -f "$CG" ]; then
    sed -i "s/192\.168\.1\.1/$LAN_IP/g" "$CG"
    sed -i 's/ImmortalWrt/FZSWrt/g' "$CG"
    echo "[diy] config_generate: lan=$LAN_IP, brand=FZSWrt"
else
    echo "[diy] WARN: $CG missing, skip" >&2
fi

if [ -f feeds/luci/collections/luci/Makefile ]; then
    sed -i 's/luci-theme-argon/luci-theme-bootstrap/g' feeds/luci/collections/luci/Makefile
fi

# ============================================================
# 2) 设备适配三件套（原逻辑 + 空片段防护）
#
#    ★ 这是「刷机后没 IP / 没后台」的主要修复点之一：
#      原脚本 `lines[0]` 在 d/f/n.txt 为空时抛 IndexError，
#      配合开头 set -e 会让整个 diy.sh 中途退出，导致
#      02_network 没写入 -> config_generate 不生成 br-lan ->
#      dnsmasq 无 DHCP -> 拿不到 IP、进不了后台、也上不了网。
#      本版：片段为空就跳过并告警，绝不写空 DTS / 空 mk / 空 block，
#      且 python 注入全程不抛异常，保证脚本一定跑完。
# ============================================================
nonempty() { [ -f "$1" ] && [ "$(wc -c < "$1")" -gt 8 ]; }

DTS_OK=0; MK_OK=0; NET_OK=0
if nonempty "$SRC/d.txt" && nonempty "$SRC/f.txt" && nonempty "$SRC/n.txt"; then
    DTS_OK=1; MK_OK=1; NET_OK=1
else
    echo "[diy] WARN: d.txt/f.txt/n.txt 缺失或为空 -> 跳过板级注入（不写空文件）" >&2
    echo "[diy]       若这是新机型，请把完整的 DTS/设备定义/02_network 片段放进 custom/" >&2
    echo "[diy]       本脚本的第 3 节 LAN 兜底仍会保证后台可达" >&2
fi

if [ "$DTS_OK" = "1" ]; then
    mkdir -p "$DTS_DIR"
    cp -f "$SRC/d.txt" "$DTS"
    echo "[diy] dts -> $DTS"
elif [ -f "$SRC/d.txt" ] && [ ! -s "$DTS" ]; then
    :    # 不创建空 DTS：空 DTS 会让 kernel 编译直接失败
fi

if [ "$MK_OK" = "1" ]; then
    grep -q "define Device/$DEVICE" "$MK" || cat "$SRC/f.txt" >> "$MK"
    echo "[diy] filogic.mk: Device/$DEVICE ready"
fi

if [ "$NET_OK" = "1" ]; then
    python3 - "$SRC/n.txt" "$NET" "$BOARD" <<'PY' || echo "[diy] WARN: 02_network inject skipped" >&2
import sys
frag, target, board = sys.argv[1:4]
try:
    lines = [l.rstrip() for l in open(frag).read().splitlines() if l.strip()]
    if not lines:
        print("[diy] WARN: empty n.txt, 02_network untouched")
        sys.exit(0)
    if not lines[0].startswith("\t"):
        lines[0] = "\t" + lines[0].lstrip()
        lines[1:] = ["\t\t" + l.lstrip() for l in lines[1:]]
    block = "".join(l + "\n" for l in lines)
    s = open(target).read()
    if board + ")" not in s:
        start = s.index("mediatek_setup_interfaces()")
        pos = s.index("\tesac", start)
        s = s[:pos] + block + s[pos:]
        open(target, "w").write(s)
        print("[diy] 02_network: board case injected")
    else:
        print("[diy] 02_network: board case already present")
except Exception as e:
    print("[diy] WARN: 02_network inject failed (%s), left untouched" % e)
    sys.exit(0)          # 关键：不把 set -e 触发成整体失败
PY
    if [ -f "$NET" ]; then chmod +x "$NET"; fi
fi
echo "[diy] board injection done (dts=$DTS_OK mk=$MK_OK net=$NET_OK)"

# ============================================================
# 3) ★ 修复「刷机后无内网 IP / 进不了后台」的根部兜底
#
#    OpenWrt 首次开机由 config_generate 依据 /etc/board.json 生成
#    /etc/config/network 与 /etc/config/dhcp。只要 02_network 没匹配到
#    板子（或上一步被中断），br-lan / lan / dhcp.lan 全部不会生成：
#      -> 电脑拿不到地址、192.168.6.1 打不开、dnsmasq 没起、NAT 也没了。
#    这里放一个只在「缺失时」生效的 uci-defaults：补 br-lan + lan +
#    dhcp.lan，且绝不覆盖已有配置。uci-defaults 执行后会自动删除，
#    不会在后续开机反复改用户配置；也不 restart 任何服务。
# ============================================================
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/97-lan-fallback <<EOF
#!/bin/sh
# 首次开机兜底：仅在 lan / dhcp.lan 缺失时补最小可用局域网配置。
# 已有配置一律不动；不重启服务（boot 阶段 network 尚未 start）。
LAN_IP='$LAN_IP'

if ! uci -q get network.lan >/dev/null 2>&1; then
    # 1) 建 br-lan，纳入实际存在的物理口（DSA 与独立网口都兼容）
    uci -q set network.br_lan=device
    uci -q set network.br_lan.name='br-lan'
    uci -q set network.br_lan.type='bridge'
    for p in lan1 lan2 lan3 lan4 lan eth0 eth1 eth2; do
        if [ -d "/sys/class/net/\$p" ]; then
            uci -q add_list network.br_lan.ports="\$p"
        fi
    done

    # 2) lan 静态地址（后台管理页）
    uci -q set network.lan=interface
    uci -q set network.lan.device='br-lan'
    uci -q set network.lan.proto='static'
    uci -q set network.lan.ipaddr="\$LAN_IP"
    uci -q set network.lan.netmask='255.255.255.0'
    uci -q set network.lan.ip6assign='60'
    uci -q commit network
    echo "[lan-fallback] network.lan created at \$LAN_IP"
fi

# 3) DHCP 服务器：没有 dhcp.lan 就补上，否则 dnsmasq 不发地址
if ! uci -q get dhcp.lan >/dev/null 2>&1; then
    uci -q set dhcp.lan=dhcp
    uci -q set dhcp.lan.interface='lan'
    uci -q set dhcp.lan.start='100'
    uci -q set dhcp.lan.limit='150'
    uci -q set dhcp.lan.leasetime='12h'
    uci -q commit dhcp
    echo "[lan-fallback] dhcp.lan created"
fi

exit 0
EOF
chmod +x files/etc/uci-defaults/97-lan-fallback
echo "[diy] LAN/DHCP fallback installed (only fills missing config)"

# ============================================================
# 4) 编译配置幂等补齐
#    workflow 在 diy.sh 之后才执行 `mv 0.config .config && make defconfig`，
#    所以这里改 0.config 是生效的；不直接写 .config（会被覆盖）。
#    不认识的 CONFIG 会被 make defconfig 自动丢弃，不会伤配置。
# ============================================================
for C in $CFG_CANDIDATES; do
    [ -f "$C" ] || continue
    python3 - "$C" "$DEVICE" <<'PYCFG' || echo "[diy] WARN: config patch skipped for $C" >&2
import sys, os, re
path, device = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8', errors='ignore').read()

# 配置为空/近乎为空时，补一套最小可编译的 MT7981 filogic 基线
if len([l for l in s.splitlines() if l.strip()]) < 2:
    base = [
        'CONFIG_TARGET_mediatek=y',
        'CONFIG_TARGET_mediatek_filogic=y',
        'CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_%s=y' % device,
        'CONFIG_PACKAGE_dnsmasq=y',
        'CONFIG_PACKAGE_firewall4=y',
        'CONFIG_PACKAGE_kmod-mt7915e=y',
        'CONFIG_PACKAGE_kmod-usb-serial-option=y',
        'CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y',
        'CONFIG_PACKAGE_kmod-usb-net-cdc-mbim=y',
        'CONFIG_PACKAGE_kmod-usb-net-rndis=y',
        'CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y',
        'CONFIG_PACKAGE_bridger=y',
    ]
    s = '\n'.join(base) + '\n'
    print('[diy] %s was empty -> minimal filogic baseline written' % path)
else:
    def force(sym):
        global s
        p = re.compile(r'(?m)^#\s*' + re.escape(sym) + r' is not set\s*$')
        if p.search(s):
            s = p.sub(sym + '=y', s)
        elif not re.search(r'(?m)^' + re.escape(sym) + r'=y\s*$', s):
            s = s.rstrip('\n') + '\n' + sym + '=y\n'
    # 只补 PPE/WED 相关包，不动用户已有的 target/profile/插件选择
    for sym in ('CONFIG_PACKAGE_kmod-mt7915e',
                'CONFIG_PACKAGE_bridger',
                'CONFIG_PACKAGE_dnsmasq',
                'CONFIG_PACKAGE_firewall4'):
        force(sym)
    print('[diy] %s: PPE packages ensured (rest untouched)' % path)

open(path, 'w', encoding='utf-8').write(s)
PYCFG
done

# ============================================================
# 5) 主线 PPE 硬件加速：内核侧
#    写 target/linux/mediatek/filogic/config-6.12（内核 config 片段），
#    不写 .config；make defconfig 会合并，且不受 0.config 覆盖影响。
#      NET_MEDIATEK_SOC_WED     -> WED / WDMA，PPE 直连无线
#      NF_FLOW_TABLE_HW_OFFLOAD -> 有线侧 flowtable 下发到 PPE
#      NF_CONNTRACK_EVENTS      -> 流老化同步（PPE 表项回收）
#    这三样都是 25.12 / 6.12 原生能力，不改驱动、不打内核补丁。
# ============================================================
if [ -f "$KCFG" ]; then
    python3 - "$KCFG" "$PPE_WED" "$PPE_HW_OFFLOAD" <<'PYK' || echo "[diy] WARN: kernel config tweak skipped" >&2
import sys, re
path, wed, hw = sys.argv[1], sys.argv[2] == '1', sys.argv[3] == '1'
s = open(path).read()

def set_sym(sym, on):
    global s
    p = re.compile(r'(?m)^#?\s*' + re.escape(sym) + r'(?:=.*| is not set)\s*$')
    line = (sym + '=y') if on else ('# ' + sym + ' is not set')
    if p.search(s):
        s = p.sub(line, s)
    else:
        s = s.rstrip('\n') + '\n' + line + '\n'

set_sym('CONFIG_NET_MEDIATEK_SOC_WED', wed)
set_sym('CONFIG_NF_FLOW_TABLE_HW_OFFLOAD', hw)
set_sym('CONFIG_NF_CONNTRACK_EVENTS', hw)
open(path, 'w').write(s)
print('[diy] %s: WED=%s HW_OFFLOAD=%s' % (path, wed, hw))
PYK
else
    echo "[diy] WARN: $KCFG not found (kernel PPE config skipped)" >&2
fi

# ============================================================
# 6) 主线 PPE 硬件加速：rootfs 侧
# ============================================================
mkdir -p files/etc/modules.d files/etc/uci-defaults files/usr/sbin

# 6a) WED 模块参数（OpenWrt 24.10+ 写法；sysupgrade 后需重新放）
if [ "$PPE_WED" = "1" ]; then
    cat > files/etc/modules.d/50-mtk-ppe-wed <<'EOF'
# WED: 让 PPE 直接处理来往 WiFi chipset 的包（仅 5G/6G radio）
# MT7996 / MT7987 请换成: mt7996e wed_enable=Y
# 此文件不在默认 sysupgrade 备份列表里，升级后需重新添加。
mt7915e wed_enable=Y
EOF
fi

# 6b) firewall4 的两个标准开关。只 uci commit，绝不 restart firewall
#     （上一版 sonic 的 restart + NAT 补丁替换正是「无法联网」的放大项）
cat > files/etc/uci-defaults/98-mtk-ppe-offload <<EOF
#!/bin/sh
# 主线 PPE 硬件加速默认开；首次开机执行一次后自动删除
if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
    uci -q set firewall.@defaults[0].flow_offloading='1'
    if [ '$PPE_HW_OFFLOAD' = '1' ]; then
        uci -q set firewall.@defaults[0].flow_offloading_hw='1'
    else
        uci -q delete firewall.@defaults[0].flow_offloading_hw 2>/dev/null || true
    fi
    uci -q commit firewall
fi
# 不碰 fullcone、不碰 NAT 规则、不重启任何服务
exit 0
EOF
chmod +x files/etc/uci-defaults/98-mtk-ppe-offload

# 6c) 验证脚本
cat > files/usr/sbin/verify-ppe.sh <<'EOF'
#!/bin/sh
# 打流时运行：确认 PPE 真的在干活，而不是只有吞吐变高
say() { printf '\n=== %s ===\n' "$*"; }

say "1. LAN / 后台（先确认能进管理页）"
ip -4 addr show br-lan 2>/dev/null || ip -4 addr show lan 2>/dev/null || echo "  !! br-lan 不存在"
uci -q get network.lan.ipaddr
uci -q get dhcp.lan.interface
ps | grep -q '[d]nsmasq' && echo "  dnsmasq: running" || echo "  !! dnsmasq: NOT running"

say "2. WED 参数"
for m in mt7915e mt7996e; do
    f="/sys/module/$m/parameters/wed_enable"
    [ -r "$f" ] && { printf '  %s = ' "$m"; cat "$f"; }
done

say "3. 硬件 flow offload 开关"
uci -q get firewall.@defaults[0].flow_offloading
uci -q get firewall.@defaults[0].flow_offloading_hw

say "4. PPE 已绑定流（决定性判据）"
for p in /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind \
         /sys/kernel/debug/mtk_ppe/bind; do
    [ -r "$p" ] || continue
    printf '  -- %s --\n' "$p"
    grep -E 'BND' "$p" | head -20
done
echo "  看 orig=/new= 里是否出现你的 LAN / WiFi 客户端 IP 或 MAC"

say "5. 硬件计数（打流时须增长）"
tc -s filter show dev eth0 ingress 2>/dev/null | grep -E 'in_hw|Sent hardware' | head -5
sleep 5
tc -s filter show dev eth0 ingress 2>/dev/null | grep -E 'Sent hardware' | head -5

say "6. CPU"
cat /proc/loadavg
echo "  有效 offload 时 ksoftirqd 应明显低于纯软件转发"

say "7. A/B"
echo "  关掉 flow_offloading_hw 再测：BND 流应消失、CPU 应上升。"
echo "  吞吐变高不等于 PPE 生效，软件 flowtable 也能提吞吐。"
EOF
chmod +x files/usr/sbin/verify-ppe.sh

# ============================================================
# 7) USB/5G 模组 → 有线/无线 PPE 加速：6.12 主线回送层（完整实现）
#
#    custom/extdev/ 里是实现包：
#      1001-mtk-ppe-extdev.patch   由 gen_patch.py 对真实 6.12 源码生成
#      gen_patch.py                内核小版本升级时重新生成补丁
#      mtk_ppe_extdev.c/.h         学流 / rx_handler / FOE 建表 / 老化
#      mtk_ppe_extdev_tx.c         QDMA TX 注入，fport = PSE_PPE0_PORT
#
#    机制：QDMA TX 描述符把未经 NAT 的原始 skb 送进 PPE 查表引擎；
#    HNAPT FOE 表项由主线 mtk_flow_set_output_device() 编码 DSA/GDM/WDMA，
#    并由新增的 mtk_foe_entry_bind_hw() 主动写进硬件槽位
#    （6.12 的 mtk_foe_entry_commit() 只挂软件链表、留 UNBIND）。
#    上行 → USB 模组仍走 CPU：FOE 没有 USB 出口。
# ============================================================
EXT_SRC="$SRC/extdev"
PDIR="target/linux/mediatek/patches-6.12"
FDIR="target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek"

if [ "$USB5G_EXTDEV" = "1" ]; then
    MISSING=0
    for f in 1001-mtk-ppe-extdev.patch mtk_ppe_extdev.c \
             mtk_ppe_extdev.h mtk_ppe_extdev_tx.c; do
        [ -s "$EXT_SRC/$f" ] || { echo "[diy] extdev: missing $f" >&2; MISSING=1; }
    done

    if [ "$MISSING" = "0" ] && [ -f "$KCFG" ]; then
        mkdir -p "$PDIR" "$FDIR" files/etc/uci-defaults
        cp -f "$EXT_SRC/1001-mtk-ppe-extdev.patch" "$PDIR/"
        cp -f "$EXT_SRC/mtk_ppe_extdev.c" "$EXT_SRC/mtk_ppe_extdev.h" \
              "$EXT_SRC/mtk_ppe_extdev_tx.c" "$FDIR/"
        # gen_patch.py 是开发工具，不进编译树（留在 custom/extdev/ 即可）

        # Kconfig: NET_MEDIATEK_PPE_EXTDEV depends on
        # NET_MEDIATEK_SOC && NET_MEDIATEK_SOC_WED &&
        # NF_CONNTRACK && NF_CONNTRACK_EVENTS
        python3 - "$KCFG" <<'PYEXT' || echo "[diy] WARN: extdev kconfig skipped" >&2
import sys, re
p = sys.argv[1]
s = open(p).read()
def on(sym):
    global s
    pat = re.compile(r'(?m)^#?\s*' + re.escape(sym) + r'(?:=.*| is not set)\s*$')
    if pat.search(s):
        s = pat.sub(sym + '=y', s)
    else:
        s = s.rstrip('\n') + '\n' + sym + '=y\n'
for x in ('CONFIG_NET_MEDIATEK_SOC', 'CONFIG_NET_MEDIATEK_SOC_WED',
          'CONFIG_NF_CONNTRACK', 'CONFIG_NF_CONNTRACK_EVENTS',
          'CONFIG_NET_MEDIATEK_PPE_EXTDEV'):
    on(x)
open(p, 'w').write(s)
print('[diy] extdev: kernel config enabled')
PYEXT

        # built-in 模块参数：modules.d 对 built-in 无效，用 uci-defaults 写 sysfs
        cat > files/etc/uci-defaults/96-mtk-ppe-extdev <<'EOF'
#!/bin/sh
# mtk_eth 是 built-in，参数在 /sys/module/mtk_eth/parameters/
# 运行时一键回退：echo 0 > /sys/module/mtk_eth/parameters/extdev_enable
P=/sys/module/mtk_eth/parameters/extdev_prefix
[ -w "$P" ] && echo '__PREFIX__' > "$P"
exit 0
EOF
        sed -i "s|__PREFIX__|$EXTDEV_PREFIX|g" files/etc/uci-defaults/96-mtk-ppe-extdev
        chmod +x files/etc/uci-defaults/96-mtk-ppe-extdev

        # 把 extdev 判据追加到验证脚本
        cat >> files/usr/sbin/verify-ppe.sh <<'EOF'

say "8. extdev（USB/5G → PPE 回送层）"
echo "  sysfs: /sys/module/mtk_eth/parameters/extdev_{prefix,enable}"
for f in /sys/kernel/debug/mtk_ppe_extdev/*; do
    [ -r "$f" ] && { printf '  %-12s = ' "$(basename "$f")"; cat "$f"; }
done
echo "  rx_inject 涨 + stale_out=0 + ppe0/bind 有 BND 流 = 硬件真在转发"
dmesg | grep -i extdev | tail -10
EOF

        echo "[diy] extdev: ENABLED (patch + 3 sources + kconfig + rootfs)"
        echo "[diy] extdev: fport=PSE_PPE0_PORT, bind_hw=on, stale self-heal=on"
    else
        echo "[diy] extdev: 实现包不全或 $KCFG 缺失 -> 自动回退为 0（不破坏编译）" >&2
        USB5G_EXTDEV=0
    fi
fi

# ============================================================
# 8) 收尾自检
# ============================================================
echo "[diy] --- summary ---"
echo "[diy] no SONiC fullcone / no NAT patch / no package removal / no service restart"
echo "[diy] LAN fallback   : files/etc/uci-defaults/97-lan-fallback"
echo "[diy] PPE offload    : files/etc/uci-defaults/98-mtk-ppe-offload"
echo "[diy] WED module     : $([ "$PPE_WED" = 1 ] && echo files/etc/modules.d/50-mtk-ppe-wed || echo disabled)"
echo "[diy] verify script  : files/usr/sbin/verify-ppe.sh"
echo "[diy] USB5G extdev   : $USB5G_EXTDEV (1 = PSE_PPE0_PORT 注入 + bind_hw)"
echo "[diy] extdev pkg     : $([ "$USB5G_EXTDEV" = 1 ] && echo custom/extdev/ || echo not used)"
echo "[diy] done"
