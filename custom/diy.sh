#!/bin/bash
set -e

SRC="$GITHUB_WORKSPACE/custom"
DTS_DIR="target/linux/mediatek/dts"
MK="target/linux/mediatek/image/filogic.mk"
NET="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"

# ---------- 原有个性化设置（保留，可按需删改） ----------
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate
sed -i 's/ImmortalWrt/FZSWrt/g' package/base-files/files/bin/config_generate
# diy.sh 在 feeds update 之前执行，此时 feeds/luci 尚未生成，故加存在性判断；
# 主题实际由 .config 的 luci-theme-bootstrap=y 决定
if [ -f feeds/luci/collections/luci/Makefile ]; then
    sed -i 's/luci-theme-argon/luci-theme-bootstrap/g' feeds/luci/collections/luci/Makefile
fi

# ---------- 1/3 0.txt -> 设备树（文件名须与 DEVICE_DTS 一致） ----------
mkdir -p "$DTS_DIR"
cp "$SRC/0.txt" "$DTS_DIR/mt7981b-fzs-5gcpe-p5.dts"

# ---------- 2/3 filogic-.txt -> 追加设备定义 ----------
grep -q "define Device/fzs_5gcpe-p5" "$MK" || cat "$SRC/f.txt" >> "$MK"

# ---------- 3/3 02_network.txt -> 插入第一个 case（不能覆盖整个脚本） ----------
python3 - "$SRC/n.txt" "$NET" <<'PY'
import sys
frag, target = sys.argv[1], sys.argv[2]
# 片段通常已带 tab（首行 1 个、其余 2 个）；若上传的是无缩进纯文本，则规范化一次
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

