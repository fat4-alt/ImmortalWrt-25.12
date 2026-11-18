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

