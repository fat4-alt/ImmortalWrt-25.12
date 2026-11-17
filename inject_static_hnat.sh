#!/bin/bash
# =============================================================================
# FZS 5GCPE P5 / ImmortalWrt 25.12 静态 HNAT 注入脚本
#
# 由 .github/workflows/ImmortalWrt-25.12-builder.yml 的 Step 6 调用：
#   cd openwrt
#   [ -e $GITHUB_WORKSPACE/.config ] && mv ... .config
#   bash "$GITHUB_WORKSPACE/inject_static_hnat.sh"     ★ 必须在 make defconfig 之前
#   make defconfig
#
# 工作目录必须是源码根（openwrt/）。
# 素材目录：$GITHUB_WORKSPACE/static_hnat/
#
# 本脚本自包含，不依赖 fork 里有没有设备文件：
#   fork fat4-alt/immortalwrt-mt798x-rebase@25.12 里没有
#   mt7981b-fzs-5gcpe-p5.dts / 02_network 的 fzs 分支 / filogic.mk 的 Device，
#   所以这里一并注入。
# =============================================================================

set -euo pipefail

WAN_DEV="${WAN_DEV:-wwan0}"          # ← 固定 wwan0（workflow env 里也写了）
WS="${GITHUB_WORKSPACE:-$(cd .. && pwd)}"
B="$WS/static_hnat"

echo "=============================================================="
echo " FZS static HNAT injection"
echo " cwd       = $(pwd)"
echo " workspace = $WS"
echo " bundle    = $B"
echo " wan_dev   = $WAN_DEV"
echo "=============================================================="

[ -f include/toplevel.mk ] || { echo "ERROR: 当前目录不是 OpenWrt 源码根"; exit 1; }
[ -d "$B" ] || { echo "ERROR: 素材目录 $B 不存在"; exit 1; }
for f in 0.txt 03_dts_hnat_append.dts filogic-.txt 02_network_branch.txt \
         05_uci-defaults_zz-fzs-hnat-static 06_initd_fzs-hnat; do
    [ -f "$B/$f" ] || { echo "ERROR: 缺少素材 $B/$f"; exit 1; }
done

# =============================================================================
# A. 设备文件注入（fork 里没有，必须补）
# =============================================================================

# ---- A1. DTS：0.txt + 静态 &hnat ----
DTS="target/linux/mediatek/dts/mt7981b-fzs-5gcpe-p5.dts"
mkdir -p "$(dirname "$DTS")"
cat "$B/0.txt" > "$DTS"
printf '\n' >> "$DTS"                       # 0.txt 末尾无换行，补一个再拼
sed "s/<WAN_DEV>/$WAN_DEV/g" "$B/03_dts_hnat_append.dts" >> "$DTS"
grep -q '^&hnat {' "$DTS" || { echo "ERROR: &hnat 未写入 DTS"; exit 1; }
echo "[A1] DTS OK: $(wc -l < "$DTS") 行, &hnat 已追加"

# ---- A2. filogic.mk 设备定义 ----
FMK="target/linux/mediatek/image/filogic.mk"
if grep -q 'define Device/fzs_5gcpe-p5' "$FMK"; then
    echo "[A2] filogic.mk 已含 fzs_5gcpe-p5，跳过"
else
    printf '\n' >> "$FMK"
    cat "$B/filogic-.txt" >> "$FMK"
    printf '\n' >> "$FMK"
    echo "[A2] filogic.mk 已追加 Device/fzs_5gcpe-p5"
fi
grep -q 'TARGET_DEVICES += fzs_5gcpe-p5' "$FMK" || { echo "ERROR: 设备定义未写入"; exit 1; }

# ---- A3. 02_network：在 mediatek_setup_interfaces 的 case 里插入 fzs 分支 ----
NET="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
python3 - "$NET" "$B/02_network_branch.txt" <<'PY'
import sys
p, bfile = sys.argv[1], sys.argv[2]
s = open(p).read()

if 'fzs,5gcpe-p5)' in s:
    # 已存在：只把旧的 lan wan 升级成 "lan rxppd" wan
    s = s.replace('ucidef_set_interfaces_lan_wan lan wan',
                  'ucidef_set_interfaces_lan_wan "lan rxppd" wan', 1)
else:
    branch = open(bfile).read().rstrip('\n') + '\n'
    start = s.index('mediatek_setup_interfaces()')
    # 第 272 行是 "\t*)"（单 tab），第 341 行是 "\t\t*)"（双 tab，属于 setup_macs）
    # 用 "\n\t*)" 精确锚定 setup_interfaces 的默认分支
    idx = s.index('\n\t*)', start)
    s = s[:idx + 1] + branch + s[idx + 1:]

open(p, 'w').write(s)
PY
grep -q 'ucidef_set_interfaces_lan_wan "lan rxppd" wan' "$NET" || {
    echo "ERROR: 02_network 注入失败"; exit 1; }
echo "[A3] 02_network OK: fzs 分支 = \"lan rxppd\" wan"

# =============================================================================
# B. 方案 1：禁用 hnat-detect + 静态 HNAT
# =============================================================================

# ---- B1. 内核符号（.config 带不动，必须改 config-6.12） ----
KCFG="target/linux/mediatek/filogic/config-6.12"
sed -i 's/^# CONFIG_NET_MEDIATEK_HNAT is not set$/CONFIG_NET_MEDIATEK_HNAT=y/' "$KCFG"
grep -q '^CONFIG_NET_MEDIATEK_HNAT=y' "$KCFG" || {
    echo "ERROR: CONFIG_NET_MEDIATEK_HNAT 未打开"; exit 1; }
echo "[B1] config-6.12: CONFIG_NET_MEDIATEK_HNAT=y"

# ---- B2. 从 DEFAULT_PACKAGES 移除 hnat-detect ----
TMK="target/linux/mediatek/filogic/target.mk"
sed -i 's/ l1util hnat-detect$/ l1util/' "$TMK"
# 只断言 DEFAULT_PACKAGES 行，注释里出现不影响
grep '^DEFAULT_PACKAGES' "$TMK" | grep -q 'hnat-detect' && {
    echo "ERROR: hnat-detect 仍在 DEFAULT_PACKAGES"; exit 1; }
echo "[B2] target.mk: hnat-detect 已移除"

# ---- B3. .config（此时 Step 6 已把仓库的 .config mv 进来） ----
[ -s .config ] || { echo "ERROR: .config 为空！请用交付包里的 .config 覆盖仓库根目录那个 1 字节空文件"; exit 1; }
sed -i 's/^CONFIG_PACKAGE_hnat-detect=y$/# CONFIG_PACKAGE_hnat-detect is not set/' .config
sed -i 's/^CONFIG_DEFAULT_hnat-detect=y$/# CONFIG_DEFAULT_hnat-detect is not set/' .config
grep -q '^# CONFIG_PACKAGE_hnat-detect is not set$' .config || \
    echo '# CONFIG_PACKAGE_hnat-detect is not set' >> .config
# 保留项兜底
grep -q '^CONFIG_PACKAGE_kmod-dummy=y$' .config || echo 'CONFIG_PACKAGE_kmod-dummy=y' >> .config
grep -q '^CONFIG_PACKAGE_kmod-mediatek_hnat=y$' .config || echo 'CONFIG_PACKAGE_kmod-mediatek_hnat=y' >> .config
grep -q '^CONFIG_PACKAGE_luci-app-turboacc-mtk=y$' .config || echo 'CONFIG_PACKAGE_luci-app-turboacc-mtk=y' >> .config
grep -q '^CONFIG_TARGET_mediatek_filogic_DEVICE_fzs_5gcpe-p5=y$' .config || {
    echo "ERROR: .config 里没有选中 fzs_5gcpe-p5 设备"; exit 1; }
echo "[B3] .config OK: 设备=$(grep -c '^CONFIG_TARGET_mediatek_filogic_DEVICE_fzs_5gcpe-p5=y' .config), 探测包已禁用"

# ---- B4. files/ 覆盖（运行时脚本） ----
mkdir -p files/etc/init.d files/etc/uci-defaults
sed "s/^WAN_DEV=\"wwan0\".*$/WAN_DEV=\"$WAN_DEV\"/" \
    "$B/06_initd_fzs-hnat" > files/etc/init.d/fzs-hnat
cp "$B/05_uci-defaults_zz-fzs-hnat-static" \
    files/etc/uci-defaults/zz-fzs-hnat-static
chmod 755 files/etc/init.d/fzs-hnat files/etc/uci-defaults/zz-fzs-hnat-static
echo "[B4] files/ 覆盖 OK (755)"

# =============================================================================
# C. 注入自检（有问题当场 fail，别浪费两小时编译）
# =============================================================================
echo
echo "================= inject summary ================="
echo "-- DTS / &hnat 静态映射 --"
grep -nE '^\&hnat \{|^\s+(mtketh-|ext-devices|status)' "$DTS" || true
echo "-- filogic.mk --"
grep -n 'fzs_5gcpe-p5' "$FMK" || true
echo "-- 02_network --"
grep -A2 'fzs,5gcpe-p5)' "$NET" || true
echo "-- target.mk --"
grep -n '^DEFAULT_PACKAGES' "$TMK"
echo "-- config-6.12 --"
grep -n 'CONFIG_NET_MEDIATEK_HNAT' "$KCFG"
echo "-- .config hnat-detect --"
grep -n 'hnat-detect' .config || true
echo "-- files/ --"
ls -l files/etc/init.d/fzs-hnat files/etc/uci-defaults/zz-fzs-hnat-static
echo "=================================================="
echo "注入完成。下一步就是 make defconfig（不要再让 hnat-detect 回来）。"
exit 0
