#!/bin/bash
# ============================================================
#  diy_ppe.sh —— 云编译切换为 chasey-dev / immortalwrt-mt798x-rebase
#
#  用途：把 P3TERX 风格 workflow 默认 clone 的
#          immortalwrt/immortalwrt  @ openwrt-25.12
#        在 diy 阶段「原地」切成
#          chasey-dev/immortalwrt-mt798x-rebase @ 25.12
#        并只保留与这套源码树兼容的少量自定义。
#
#  ★ 相对上一版（主线 mtk_ppe / extdev 版）删掉了什么：
#    - custom/extdev/ 的内核补丁、3 个 .c、Kconfig 写入
#      （chasey-dev 自带 mtk_hnat + mt_wifi，主线 extdev 打上去必失败）
#    - 全部内核 config 写入（NET_MEDIATEK_SOC_WED / NF_FLOW_TABLE* /
#      NF_CONNTRACK / PPE_EXTDEV 一个都不写）
#    - modules.d、以及所有改写防火墙加速开关的 uci-defaults
#    - 主线 PPE 的验证判据（ppe0/bind 那套）
#    ★ 按要求：本脚本内完全不出现、不读写任何防火墙加速开关，
#      它是开是关、是否冲突，全部交给 chasey-dev 源码树自身的默认。
#
#  ★ 为什么不改 workflow 也能换源：
#    workflow step 4 已经 clone 完，step 5 才执行本脚本。
#    这里用 git remote/fetch/checkout 在【同一个目录 inode】里换内容，
#    而不是 rm -rf 重建目录 —— 父 shell 后面还要
#      echo 'src-git qmodem ...' >> feeds.conf.default
#      ./scripts/feeds update -a / install -a
#    cwd 必须仍然有效。此做法已用本地 git 仓库模拟验证过。
#
#  ★ 分支名必须是 25.12，不是 openwrt-25.12：
#    chasey-dev 仓库同时存在这两个分支，只有 25.12 带
#    MTK OpenWrt Feeds 补丁（README 的 Commit Cutoff 基于它），
#    openwrt-25.12 是纯净镜像分支。
#
#  ★ 部署：覆盖 workflow 里 DIY_SH 指向的那个文件即可
#    （页面显示可能是根目录 diy.sh，也可能是 custom/diy_ppe.sh）。
#    config 文件（.config / custom/0.config）本脚本一律不碰。
#    若你已在 workflow 的 env 里改了 REPO_URL / REPO_BRANCH，
#    脚本会识别 origin 已是 chasey-dev 并自动跳过切源，不会重复操作。
# ============================================================
set -e

# ---------------- 可调开关 ----------------
TARGET_REPO="https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git"
TARGET_BRANCH="25.12"
SWITCH_SOURCE=1          # 0 = 只做后面的自定义，不切源（已改 workflow 时用）

DO_BRAND=1               # 改默认管理 IP / 品牌
DO_BOARD=1               # 注入 d.txt / f.txt / n.txt 设备片段
DO_LAN_FALLBACK=1        # 首次开机 LAN / DHCP 兜底

LAN_IP="192.168.6.1"
BOARD="fzs,5gcpe-p5"
DEVICE="fzs_5gcpe-p5"

# ---------------- 路径 ----------------
TREE="$(pwd)"
GWS="${GITHUB_WORKSPACE:-$(cd "$TREE/../.." 2>/dev/null && pwd)}"
SRC="$GWS/custom"
[ -d "$SRC" ] || SRC="$GWS"        # 兼容根目录布局（.config / diy.sh）

DTS_DIR="target/linux/mediatek/dts"
DTS="$DTS_DIR/mt7981b-fzs-5gcpe-p5.dts"
MK="target/linux/mediatek/image/filogic.mk"
NET="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
CG="package/base-files/files/bin/config_generate"

echo "[diy] TREE=$TREE  SRC=$SRC"
echo "[diy] TARGET=$TARGET_REPO @ $TARGET_BRANCH  SWITCH_SOURCE=$SWITCH_SOURCE"

# ============================================================
# 0) 原地切换源码树
# ============================================================
if [ "$SWITCH_SOURCE" = "1" ]; then
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "[diy] ERROR: cwd 不是 git 工作树，无法切源（workflow 的 clone 步骤是否失败？）" >&2
        exit 1
    fi

    CUR="$(git remote get-url origin 2>/dev/null || true)"
    case "$CUR" in
        *chasey-dev/immortalwrt-mt798x-rebase*)
            echo "[diy] origin 已是 chasey-dev，跳过切源" ;;
        *)
            echo "[diy] 切源: ${CUR:-<no origin>} -> $TARGET_REPO @ $TARGET_BRANCH"
            if git remote get-url origin >/dev/null 2>&1; then
                git remote set-url origin "$TARGET_REPO"
            else
                git remote add origin "$TARGET_REPO"
            fi
            # 保留完整历史（OpenWrt scripts/getver.sh 会用 git log 取版本号）
            git fetch --no-tags origin "$TARGET_BRANCH"
            git checkout -f -B "$TARGET_BRANCH" FETCH_HEAD
            # 清掉旧树残留的 untracked；diy.sh 自身正在执行，必须保留
            git clean -fdx -e diy.sh -e .config >/dev/null 2>&1 || true
            echo "[diy] HEAD=$(git log -1 --format='%h %s')"
            echo "[diy] 切源完成，父 shell 的 cwd=$(pwd) 未被替换"
            ;;
    esac
fi

# ============================================================
# 1) 品牌 / 默认管理地址
#    chasey-dev 树同样自带 package/base-files/files/bin/config_generate
# ============================================================
if [ "$DO_BRAND" = "1" ]; then
    if [ -f "$CG" ]; then
        sed -i "s/192\.168\.1\.1/$LAN_IP/g" "$CG"
        sed -i 's/ImmortalWrt/FZSWrt/g' "$CG"
        echo "[diy] config_generate: lan=$LAN_IP, brand=FZSWrt"
    else
        echo "[diy] WARN: $CG 不存在，跳过品牌修改" >&2
    fi
fi

# ============================================================
# 2) 设备适配三件套（健壮版）
#    目标文件不存在 / 片段为空 -> 跳过并告警，绝不写空文件、
#    绝不创建假的 filogic.mk，保证 set -e 下脚本一定跑完。
#
#    ★ 注意：这三个片段原本是给 immortalwrt 官方树写的。
#      chasey-dev 树的 image/Makefile、02_network 结构可能不同；
#      脚本只做「文件存在才追加 / 找到锚点才插入」，找不到就跳过，
#      不会破坏编译。机型是否已被 chasey-dev 支持请自行核对源码树。
# ============================================================
nonempty() { [ -f "$1" ] && [ "$(wc -c < "$1")" -gt 8 ]; }

if [ "$DO_BOARD" = "1" ]; then
    DTS_OK=0; MK_OK=0; NET_OK=0
    if nonempty "$SRC/d.txt" && nonempty "$SRC/f.txt" && nonempty "$SRC/n.txt"; then
        DTS_OK=1; MK_OK=1; NET_OK=1
    else
        echo "[diy] WARN: d.txt/f.txt/n.txt 缺失或为空 -> 跳过板级注入" >&2
        echo "[diy]       请把完整的 DTS / 设备定义 / 02_network 片段放到" >&2
        echo "[diy]       $SRC/ 下；LAN 兜底仍会保证后台可达" >&2
    fi

    if [ "$DTS_OK" = "1" ]; then
        mkdir -p "$DTS_DIR"
        cp -f "$SRC/d.txt" "$DTS"
        echo "[diy] dts -> $DTS"
    fi

    if [ "$MK_OK" = "1" ]; then
        if [ -f "$MK" ]; then
            if ! grep -q "define Device/$DEVICE" "$MK"; then
                cat "$SRC/f.txt" >> "$MK"
                echo "[diy] filogic.mk: Device/$DEVICE appended"
            else
                echo "[diy] filogic.mk: Device/$DEVICE 已存在"
            fi
        else
            echo "[diy] WARN: $MK 不存在，跳过设备定义注入" >&2
        fi
    fi

    if [ "$NET_OK" = "1" ] && [ -f "$NET" ]; then
        python3 - "$SRC/n.txt" "$NET" "$BOARD" <<'PY' || echo "[diy] WARN: 02_network 注入跳过" >&2
import sys
frag, target, board = sys.argv[1:4]
try:
    lines = [l.rstrip() for l in open(frag).read().splitlines() if l.strip()]
    if not lines:
        print("[diy] WARN: n.txt 为空，02_network 未改动")
        sys.exit(0)
    if not lines[0].startswith("\t"):
        lines[0] = "\t" + lines[0].lstrip()
        lines[1:] = ["\t\t" + l.lstrip() for l in lines[1:]]
    block = "".join(l + "\n" for l in lines)
    s = open(target).read()
    if board + ")" in s:
        print("[diy] 02_network: board case 已存在")
        sys.exit(0)
    start = s.index("mediatek_setup_interfaces()")
    pos = s.index("\tesac", start)
    open(target, "w").write(s[:pos] + block + s[pos:])
    print("[diy] 02_network: board case injected")
except (ValueError, OSError) as e:
    print("[diy] WARN: 02_network 锚点未找到，未改动 (%s)" % e)
PY
    elif [ "$NET_OK" = "1" ]; then
        echo "[diy] WARN: $NET 不存在，跳过 02_network 注入" >&2
    fi
    echo "[diy] board injection done (dts=$DTS_OK mk=$MK_OK net=$NET_OK)"
fi

# ============================================================
# 3) LAN / DHCP 首次开机兜底（只在配置缺失时补，绝不覆盖已有配置，
#    不重启任何服务；uci-defaults 执行完会自动删除）
# ============================================================
if [ "$DO_LAN_FALLBACK" = "1" ]; then
    mkdir -p files/etc/uci-defaults files/usr/sbin
    cat > files/etc/uci-defaults/97-lan-fallback <<EOF
#!/bin/sh
LAN_IP='$LAN_IP'
if ! uci -q get network.lan >/dev/null 2>&1; then
    uci -q set network.br_lan=device
    uci -q set network.br_lan.name='br-lan'
    uci -q set network.br_lan.type='bridge'
    for p in lan1 lan2 lan3 lan4 lan eth0 eth1 eth2 rxppd; do
        if [ -d "/sys/class/net/\$p" ]; then
            uci -q add_list network.br_lan.ports="\$p"
        fi
    done
    uci -q set network.lan=interface
    uci -q set network.lan.device='br-lan'
    uci -q set network.lan.proto='static'
    uci -q set network.lan.ipaddr="\$LAN_IP"
    uci -q set network.lan.netmask='255.255.255.0'
    uci -q set network.lan.ip6assign='60'
    uci -q commit network
    echo "[lan-fallback] network.lan created at \$LAN_IP"
fi
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
    echo "[diy] LAN/DHCP fallback installed"
fi

# ============================================================
# 4) 只读验证脚本（不写任何配置，纯观察）
# ============================================================
mkdir -p files/usr/sbin
cat > files/usr/sbin/verify-hnat.sh <<'EOF'
#!/bin/sh
say() { printf '\n=== %s ===\n' "$*"; }

say "1. LAN / 后台"
ip -4 addr show br-lan 2>/dev/null || echo "  !! br-lan 不存在"
printf '  lan ipaddr = '; uci -q get network.lan.ipaddr
ps | grep -q '[d]nsmasq' && echo "  dnsmasq: running" || echo "  !! dnsmasq NOT running"

say "2. 版本"
cat /etc/openwrt_release 2>/dev/null

say "3. HNAT 角色 / 开关（只读）"
for f in /sys/kernel/debug/hnat/hnat_lan_if \
         /sys/kernel/debug/hnat/hnat_wan_if \
         /sys/kernel/debug/hnat/hook_toggle \
         /sys/kernel/debug/hnat/external_interface; do
    [ -r "$f" ] && { printf '  %-24s = ' "$(basename "$f")"; cat "$f"; }
done

say "4. PPE 已绑定流（打流时应增长）"
for p in /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind; do
    [ -r "$p" ] && { printf '  %-28s BIND=%s\n' "$p" "$(grep -c BIND "$p")"; }
done

say "5. CPU / 日志"
cat /proc/loadavg
dmesg | grep -iE 'hnat|mt7915|wed|ppe|extif' | tail -15
EOF
chmod +x files/usr/sbin/verify-hnat.sh

# ============================================================
# 5) 收尾自检
# ============================================================
echo "[diy] --- summary ---"
echo "[diy] source tree   : $(git log -1 --format='%h %s' 2>/dev/null || echo '<not a git tree>')"
echo "[diy] origin        : $(git remote get-url origin 2>/dev/null || echo '<none>')"
echo "[diy] kernel config : NOT touched"
echo "[diy] modules.d     : NOT touched"
echo "[diy] firewall cfg  : NOT touched (按要求忽略)"
if [ "$DO_LAN_FALLBACK" = "1" ]; then
    echo "[diy] LAN fallback  : files/etc/uci-defaults/97-lan-fallback"
else
    echo "[diy] LAN fallback  : disabled"
fi
echo "[diy] verify script : files/usr/sbin/verify-hnat.sh"
echo "[diy] done"
