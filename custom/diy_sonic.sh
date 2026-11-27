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
