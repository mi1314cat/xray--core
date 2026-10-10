#!/usr/bin/env bash
# ============================================================================
#  Client 发布打包脚本（在开发机上运行，产物提交到 /Client）
# ============================================================================
#  产出：
#      Client/xbd-client.tar.gz    可直接下载解压的发布包
#      Client/xbd-client.tar.gz.sha256
#  用法：
#      bash tools/make-release.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_GZ="$HERE/xbd-client.tar.gz"
OUT_XZ="$HERE/xbd-client.tar.xz"

# 校验必需文件，防止打出残缺包
for f in RUN.sh bin/xbd l.sh uninstall-xray-client.sh lib/actions.sh lib/node.py lib/genconfig.py \
         service/xray-client.service scripts/run-xray.sh tools/selftest-arch.sh \
         lib/compat.py lib/compat2.py tools/dualkernel-compare.py tools/compat-corpus.json \
         lib/proxy_node_compat/__init__.py lib/proxy_node_compat/engine.py \
         lib/proxy_node_compat/data/rules.json; do
  [ -e "$HERE/$f" ] || { echo "缺少必需文件: $f" >&2; exit 1; }
done

# vendored 依赖的完整性：少一个 .py 或 rules.json 空了，客户端不会报错，
# 只会**静默**退回旧判定（compat.py 的 _compat2() 取不到就 return None）——
# 那正是最难发现的一类退化，所以在打包这一关就挡住。
python3 - "$HERE/lib" <<'PY' || exit 1
import json, os, sys
lib = sys.argv[1]
sys.path.insert(0, lib)
try:
    import proxy_node_compat as p
except Exception as exc:
    sys.exit(f"vendored proxy_node_compat 导入失败: {exc}")
d = json.load(open(os.path.join(lib, "proxy_node_compat", "data", "rules.json"),
                   encoding="utf-8"))
if not d.get("rules") or not d.get("evidence"):
    sys.exit("proxy_node_compat/data/rules.json 为空或残缺")
if not os.path.exists(os.path.join(lib, "compat2.py")):
    sys.exit("缺少 lib/compat2.py")
print(f"vendored {p.__version__}: {len(d['rules'])} 规则 / {len(d['evidence'])} 证据")
PY

# 已废弃的 dialer 实例单元绝不能被重新打进包 —— 它会把架构退回双实例
for f in service/xray-dialer.service lib/state.py; do
  case "$f" in
    service/xray-dialer.service) [ -e "$HERE/$f" ] && { echo "废弃文件不该存在: $f" >&2; exit 1; } ;;
  esac
done
grep -q 'xray-dialer' "$HERE/lib/actions.sh" && { echo "lib/actions.sh 仍引用 xray-dialer" >&2; exit 1; }
grep -q 'XRAY_BROWSER_DIALER' "$HERE/scripts/run-xray.sh" || { echo "run-xray.sh 没有 XRAY_BROWSER_DIALER" >&2; exit 1; }

bash -n "$HERE/tools/selftest-arch.sh" || { echo "selftest-arch.sh 语法错误" >&2; exit 1; }

cd "$HERE"
# 固定 mtime/gid/uid/owner：让同一份源码打出可复现的包
# 先打一份未压缩 tar，再分别用 gzip / xz 压 —— 两个包内容**逐字节一致**，
# 只是压缩方式不同。这样 l.sh 可以按本机有没有 xz 自由选择，而校验脚本只需比对 sha256。
TAR_TMP="$(mktemp -t xbd-release-XXXXXX.tar)"
tar --sort=name \
    --mtime='2000-01-01 00:00:00' \
    --owner=0 --group=0 --numeric-owner \
    --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='xbd-client.tar.gz' --exclude='xbd-client.tar.gz.sha256' \
    --exclude='xbd-client.tar.xz' --exclude='xbd-client.tar.xz.sha256' \
    --exclude='nodes' --exclude='runtime' --exclude='logs' \
    --exclude='generated' --exclude='backup' --exclude='config' \
    -cf "$TAR_TMP" \
    RUN.sh RUN.md l.sh uninstall-xray-client.sh bin lib service scripts docs tools VERSION README.md

gzip -9 -c "$TAR_TMP" > "$OUT_GZ"
xz   -9e -c "$TAR_TMP" > "$OUT_XZ"
rm -f "$TAR_TMP"

sha256sum "$OUT_GZ" | awk '{print $1}' > "$OUT_GZ.sha256"
sha256sum "$OUT_XZ" | awk '{print $1}' > "$OUT_XZ.sha256"

printf '已生成两个格式（内容一致）\n'
printf '  %-22s %8s  SHA256 %s\n' "xbd-client.tar.xz" "$(du -h "$OUT_XZ" | cut -f1)" "$(cut -c1-16 "$OUT_XZ.sha256")…"
printf '  %-22s %8s  SHA256 %s\n' "xbd-client.tar.gz" "$(du -h "$OUT_GZ" | cut -f1)" "$(cut -c1-16 "$OUT_GZ.sha256")…"
printf '  内容   :\n'
tar tzf "$OUT_GZ" > "$OUT_GZ.list"
awk 'NR<=12 {print "    " $0}' "$OUT_GZ.list"
printf '    … 共 %s 项\n' "$(wc -l < "$OUT_GZ.list")"
rm -f "$OUT_GZ.list"
