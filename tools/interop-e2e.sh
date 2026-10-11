#!/usr/bin/env bash
# 三家互通 · 端到端验证台（真脚本 / 真服务代码 / 真客户端入口）
#
# 设计: proxy-node-compat/docs/three-way-interop.md
#
#   服务端: conf/share.sh create               真分享脚本, 真载荷/原生产品构建
#   存储  : proxy-share-service（Share-Service/src/share_service.py）
#            —— **独立实例**: 自己的端口、自己的数据目录, 绝不碰生产
#   客户端: Client/bin/xbd node sub             真客户端入口, 真决策/回退/导入
#
# 断言:
#   ① 同内核同发行版 → 客户端拉**原生**（日志里那行"本次拉取: 原生 …"）
#   ② 声明缺失（裸地址）→ 拉**普通话**, 且不报错
#   ③ 声明在、原生地址 404 → **回退普通话**（并把原因打出来）
#   ④ 带声明的地址与裸地址返回**逐字节相同**的内容（第三方客户端零影响）
#   ⑤ 两条产品逐字段：URI 侧非空的字段原生侧必须一致（原生允许多带, 不许少）
#   ⑥ **刷新**旧记录（互通之前建的）→ 补成对 + 补声明, token/地址不变, 幂等
#   ⑦ **刷新**不抹互通字段（role/native_token/distribution/formats 保留）
#   ⑧ 面板不谎报陈旧: 两个记录都带**当前生成器**版本号 (原生记录也要带)
#
# 用法:
#   bash tools/interop-e2e.sh                  # 合成语料（默认）
#   TW_CONF=/root/catmi/xray/conf TW_SHARE=/root/catmi/xray/out/share \
#     bash tools/interop-e2e.sh                # 拿真实部署的片段跑（只读拷贝）
# 环境变量: TW_WORK（默认 /tmp/xray-interop-e2e）/ TW_PORT / TW_HOST
#           TW_SERVICE（分享服务源码路径; 找不到就**明说并退出 3**, 不静默跳过）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
WORK="${TW_WORK:-/tmp/xray-interop-e2e}"
PORT="${TW_PORT:-0}"
HOST_OVERRIDE="${TW_HOST:-}"
SRC_CONF="${TW_CONF:-}"
SRC_SHARE="${TW_SHARE:-}"
pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

svc_src="${TW_SERVICE:-}"
if [[ -z "$svc_src" ]]; then
  for c in "$HOME/Share-Service/src/share_service.py" \
           /root/deepseek/Share-Service/src/share_service.py \
           /opt/proxy-share-service/share_service.py \
           "$ROOT/../Share-Service/src/share_service.py"; do
    [[ -f "$c" ]] && { svc_src="$c"; break; }
  done
fi
if [[ -z "$svc_src" || ! -f "$svc_src" ]]; then
  echo "  跳过: 找不到 proxy-share-service 源码（TW_SERVICE=... 指定）—— 端到端**没有**验证" >&2
  exit 3
fi
if [[ -z "$PORT" || "$PORT" = 0 ]]; then
  PORT=$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
fi

rm -rf "$WORK"; mkdir -p "$WORK/etc" "$WORK/data" "$WORK/out" "$WORK/base"
printf 'x' > "$WORK/etc/admin.token"
printf 'SHARE_PORT=%s\n' "$PORT" > "$WORK/etc/env"

# ---- 语料: 合成, 或拿真实部署的片段（只读拷贝）----
if [[ -n "$SRC_CONF" && -d "$SRC_CONF" ]]; then
  echo "=== 语料: 真实部署片段（只读拷贝）$SRC_CONF ==="
  mkdir -p "$WORK/base/conf" "$WORK/base/out/share"
  cp -a "$SRC_CONF/." "$WORK/base/conf/"
  [[ -n "$SRC_SHARE" && -d "$SRC_SHARE" ]] && cp -a "$SRC_SHARE/." "$WORK/base/out/share/"
  # 元数据里的对外地址保持不变（客户端真的去连它）; 只补缺 host 的
  [[ -n "$HOST_OVERRIDE" ]] && python3 - "$WORK/base/out/share" "$HOST_OVERRIDE" <<'PY'
import glob, json, os, sys
d, host = sys.argv[1], sys.argv[2]
for f in glob.glob(os.path.join(d, "*.json")):
    try: m = json.load(open(f, encoding="utf-8"))
    except Exception: continue
    m["host"] = host
    json.dump(m, open(f, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
else
  echo "=== 语料: 合成（各协议/传输/加密 + 四类边界） ==="
  python3 "$ROOT/tools/interop-corpus.py" "$WORK/base" ${HOST_OVERRIDE:+--host "$HOST_OVERRIDE"} >/dev/null
fi
mkdir -p "$WORK/out/share"
cp -a "$WORK/base/conf" "$WORK/conf"
cp -a "$WORK/base/out/share/." "$WORK/out/share/" 2>/dev/null || true
for c in xbd xbd2 xbd3; do
  mkdir -p "$WORK/$c"/{nodes,config,runtime,logs,generated,backup,scripts,tools,docs}
done

# ---- 独立分享服务实例（自己的端口/数据目录; 不碰生产）----
echo
echo "=== 1 · 独立分享服务实例 127.0.0.1:$PORT（数据目录 $WORK/data） ==="
SHARE_DATA_DIR="$WORK/data" SHARE_PORT="$PORT" \
  SHARE_ADMIN_TOKEN_FILE="$WORK/etc/admin.token" SHARE_PORT_FILE="$WORK/etc/port" \
  python3 "$svc_src" >"$WORK/svc.log" 2>&1 &
SVC_PID=$!
trap 'kill $SVC_PID 2>/dev/null' EXIT
UP=0
for _ in $(seq 1 40); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/api/v1/health" && { UP=1; break; }
  sleep 0.25
done
if [[ "$UP" != 1 ]]; then
  no "分享服务没起来（看 $WORK/svc.log）"
  sed 's/^/    /' "$WORK/svc.log" >&2
  echo; echo "=== 结果: $pass 通过, $fail 失败 ==="; exit 1
fi
ok "服务在跑（版本 $(curl -s "http://127.0.0.1:$PORT/api/v1/health" | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null)）"

# 本机没有 xray 二进制时, 服务端**拒绝**产出原生（不猜发行版）—— 那是对的,
# 但这个验证台要测原生这条路, 所以允许显式声明构建身份（TW_XRAY_VERSION）。
# 注意语义: 这是测试台的输入, 不是生产行为; 生产上探测不到就不产出原生。
if [[ -n "${TW_XRAY_VERSION:-}" ]]; then
  export XBD_XRAY_VERSION="$TW_XRAY_VERSION"
  echo "  本机构建身份由 TW_XRAY_VERSION=$TW_XRAY_VERSION 声明（测试台输入）"
elif ! command -v xray >/dev/null 2>&1 && [[ ! -f /usr/local/bin/xray ]]; then
  echo "  [!] 本机没有 xray 二进制 —— 服务端不会产出原生; 用 TW_XRAY_VERSION=26.3.27 可测原生路径" >&2
fi

export XRAY_BASE="$WORK" XRAY_CONF_DIR="$WORK/conf" XRAY_SHARE_DIR="$WORK/out/share" \
       XRAY_OUT_DIR="$WORK/out" SHARE_ETC="$WORK/etc" SHARE_PORT="$PORT" \
       SHARE_ADMIN_TOKEN_FILE="$WORK/etc/admin.token" SHARE_PORT_FILE="$WORK/etc/port" \
       SHARE_PROVIDER=xray

# ---- 服务端: 真 share.sh create ----
echo
echo "=== 2 · 服务端创建分享（conf/share.sh create） ==="
printf '\n\n0\n0\n' | bash "$ROOT/conf/share.sh" create >"$WORK/create.out" 2>&1
sed -n '/分享已生成/,/有效期/p' "$WORK/create.out" | sed 's/^/  /'
# 用 sed -n 1p 而不是 head -1: head 命中即退出, 上游 grep 会吃 SIGPIPE,
# 在 pipefail 下整条命令变 141（说好的地址变成空串）。
URL=$(grep -oE 'http://[0-9a-zA-Z.:_-]+/share/[0-9a-f]{32}\?interop=[^ ]+' "$WORK/create.out" | sed -n 1p)
if [[ -z "$URL" ]]; then
  no "没取到带声明的地址"; sed 's/^/    /' "$WORK/create.out"; echo
  echo "=== 结果: $pass 通过, $fail 失败 ==="; exit 1
fi
if grep -E 'formats=uri(%2C|,)xray' <<<"$URL" >/dev/null; then
  ok "地址上带声明, 且 formats 含原生（$(sed 's/.*?//' <<<"$URL" | cut -c1-60)…）"
else
  no "声明里没有原生格式: $URL"
fi

echo
echo "=== 3 · 两条产品记录 ==="
LIST=$(SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" list 2>/dev/null)
printf '%s' "$LIST" | python3 -c '
import json,sys
recs=json.load(sys.stdin)
prim=[r for r in recs if (r.get("meta") or {}).get("role")=="primary"]
nat=[r for r in recs if (r.get("meta") or {}).get("role")=="native"]
print("  primary=%d native=%d" % (len(prim), len(nat)))
if prim: print("  primary content_type=%s" % prim[0].get("content_type"))
if nat:  print("  native  content_type=%s" % nat[0].get("content_type"))
if prim: print("  primary meta.native_token=%s…" % ((prim[0].get("meta") or {}).get("native_token","")[:12]))
' 2>/dev/null | sed 's/^/  /'
NATN=$(printf '%s' "$LIST" | python3 -c 'import json,sys
print(len([r for r in json.load(sys.stdin) if (r.get("meta") or {}).get("role")=="native"]))' 2>/dev/null)
PTOK=$(printf '%s' "$LIST" | python3 -c 'import json,sys
print(next((r["token"] for r in json.load(sys.stdin) if (r.get("meta") or {}).get("role")=="primary"), ""))' 2>/dev/null)
NTOK=$(printf '%s' "$LIST" | python3 -c 'import json,sys
print(next((r["token"] for r in json.load(sys.stdin) if (r.get("meta") or {}).get("role")=="native"), ""))' 2>/dev/null)
[[ "$NATN" = 1 && -n "$PTOK" && -n "$NTOK" ]] \
  && ok "原生产物是一条独立记录（content_type=application/json）" \
  || no "原生产物记录数=$NATN（primary=${PTOK:0:8} native=${NTOK:0:8}）"

# ---- 客户端: 真 xbd 入口 ----
xbd(){ XBD_PREFIX="$1" bash "$ROOT/Client/bin/xbd" "${@:2}"; }

echo
echo "=== 4 · 同内核 → 客户端必须走原生 ==="
xbd "$WORK/xbd" node sub "$URL" 三个互通 >"$WORK/c1.log" 2>&1
grep -E '本次拉取|解析出|已导入' "$WORK/c1.log" | sed 's/^/  /'
if grep '本次拉取: 原生' "$WORK/c1.log" >/dev/null; then ok "客户端选了原生"; else no "客户端没走原生"; fi
N1=$(ls "$WORK/xbd/nodes" 2>/dev/null | grep -c '\.json$')
[[ "${N1:-0}" -gt 0 ]] && ok "落盘节点 $N1 个" || no "一个节点都没落盘"

echo
echo "=== 5 · 声明缺失（裸地址）→ 回退普通话, 不报错 ==="
BARE="${URL%%\?*}"
xbd "$WORK/xbd2" node sub "$BARE" 裸地址 >"$WORK/c2.log" 2>&1
grep -E '本次拉取|解析出' "$WORK/c2.log" | sed 's/^/  /'
if grep '本次拉取: 普通话' "$WORK/c2.log" >/dev/null; then ok "回退普通话（不是报错）"; else no "没有回退"; fi
N2=$(ls "$WORK/xbd2/nodes" 2>/dev/null | grep -c '\.json$')
[[ "${N2:-0}" -gt 0 ]] && ok "落盘节点 $N2 个" || no "回退后没有节点"

echo
echo "=== 6 · 声明在、原生地址 404 → 回退普通话 ==="
BAD="${URL/url-xray=*/url-xray=http%3A%2F%2F127.0.0.1%3A$PORT%2Fshare%2F$(printf '9%.0s' {1..32})}"
xbd "$WORK/xbd3" node sub "$BAD" 坏原生 >"$WORK/c3.log" 2>&1
grep -E '本次拉取|解析出' "$WORK/c3.log" | sed 's/^/  /'
if grep '本次拉取: 普通话' "$WORK/c3.log" >/dev/null; then ok "原生取不到 → 回退普通话（原因已打出）"; else no "没有回退"; fi
N3=$(ls "$WORK/xbd3/nodes" 2>/dev/null | grep -c '\.json$')
[[ "${N3:-0}" -gt 0 ]] && ok "回退后落盘节点 $N3 个" || no "回退后没有节点"

echo
echo "=== 7 · 带声明 vs 裸地址: 逐字节相同（第三方客户端零影响） ==="
A=$(curl -s "http://127.0.0.1:$PORT/share/$PTOK" | sha256sum | awk '{print $1}')
B=$(curl -s "http://127.0.0.1:$PORT/share/$PTOK?interop=1&kernel=sing-box&distribution=sing-box&formats=uri,sing-box" | sha256sum | awk '{print $1}')
[[ "$A" = "$B" && -n "$A" ]] && ok "逐字节相同（$A）" || no "带声明的响应被改写了: $A vs $B"

echo
echo "=== 8 · 两条产品逐字段（客户端解析器, URI ⊆ 原生） ==="
python3 - "$ROOT" "$WORK" "$PORT" "$PTOK" "$NTOK" <<'PY' | sed 's/^/  /'
import base64, json, os, subprocess, sys, urllib.request
root, work, port, ptok, ntok = sys.argv[1:6]
def get(tok):
    with urllib.request.urlopen("http://127.0.0.1:%s/share/%s" % (port, tok), timeout=20) as r:
        return r.read().decode("utf-8", "replace")
def parse(text):
    p = subprocess.run(["python3", os.path.join(root, "Client", "lib", "node.py"),
                        "subscription", "-"], input=text, capture_output=True, text=True)
    return json.loads(p.stdout or "[]") if p.returncode == 0 else []
uri_nodes = parse(get(ptok))
nat_doc = json.loads(get(ntok))
native_nodes = parse(json.dumps(nat_doc, ensure_ascii=False))
print("URI 节点 %d 个 / 原生节点 %d 个" % (len(uri_nodes), len(native_nodes)))
COMPARE = ("protocol", "address", "port", "uuid", "password", "method", "transport",
           "security", "sni", "host", "path", "mode", "flow", "encryption",
           "alpn", "service_name", "reality_public_key", "reality_short_id",
           "reality_spider_x", "fingerprint", "pinned_cert_sha256", "ech",
           "up", "down", "mport")
fails = []
nat = {n.get("name"): n for n in native_nodes}
missing_native = [u.get("name") for u in uri_nodes if u.get("name") not in nat]
for u in uri_nodes:
    nv = nat.get(u.get("name"))
    if nv is None:
        continue
    for f in COMPARE:
        a, b = u.get(f), nv.get(f)
        if a == b or a in (None, "", False):
            continue
        # 唯一有据可依的例外: ss:// 装不下 reality（uri-representation.md §2
        # uri.ss.reality = NONE）→ "URI=none / 原生=reality"是原生的改进。
        if (f == "security" and u.get("protocol") == "shadowsocks"
                and a == "none" and b in ("tls", "reality")):
            print("  %-20s 原生多带: security=%s（ss:// 装不下, 有据）" % (u.get("name"), b))
            continue
        # service_name 是同一条已有约定: URI 侧 vmess 把它写成 path 的副本,
        # 只有 grpc 传输才真的读它（genconfig 的 grpc 分支）。
        if f == "service_name" and u.get("transport") != "grpc":
            continue
        fails.append("[%s] %s: URI=%r 原生=%r" % (u.get("name"), f, a, b))
gained = []
for name, nv in nat.items():
    u = next((x for x in uri_nodes if x.get("name") == name), None)
    if u is None:
        continue
    for f in ("ech", "mode", "service_name", "pinned_cert_sha256", "reality_spider_x"):
        if nv.get(f) and not u.get(f):
            gained.append("%s:%s" % (name, f))
if gained:
    print("原生多带: " + ", ".join(gained))
if missing_native:
    fails.append("原生里没有同名节点: %s" % ", ".join(map(str, missing_native)))
if len(uri_nodes) != len(native_nodes):
    fails.append("节点数不同: URI=%d 原生=%d" % (len(uri_nodes), len(native_nodes)))
if fails:
    print("✗ %d 条不一致:" % len(fails))
    for f in fails:
        print("   ", f)
    raise SystemExit(1)
print("✓ URI ⊆ 原生: %d 个节点逐字段一致（原生允许多带）" % len(uri_nodes))
PY
if [[ "${PIPESTATUS[0]}" = 0 ]]; then ok "两条产品一致（URI ⊆ 原生）"; else no "两条产品不一致（见上）"; fi

echo
echo "=== 9 · 刷新: 互通之前建的记录必须被补成「声明 + 成对」 ==="
# 场景: 在互通代码 (da5fff0/32f65ef) 之前发出的分享 —— meta 里只有
# name/tags/payload_schema, 没有原生产品, 地址上也没有声明。
# 用公共服务的 update/delete 把第 2 步那条分享**还原成**那个形态
# (这是记录数据, 不是产物文件), 再跑一次 conf/share.sh refresh。
#
# 期望 (就是"看起来成功、其实什么都没做"的那一类):
#   ① 补出原生产品, 并与主记录**同一到期时间/同一次数上限**;
#   ② 地址变成带声明的形态 (interop/kernel/distribution/formats/url-xray),
#      而 **token 与不带声明的地址一字不变** —— 已发出的链接不能失效;
#   ③ 幂等: 再刷一次不重复建原生, native_token 不变;
#   ④ meta 不被抹: 已带互通字段的记录刷新后 role/native_token/distribution
#      必须仍在 (旧实现是整体替换, 会静默把成对关系抹掉 → 撤销连带不到原生)。
meta_of(){ # <list json> <token> <field, 支持 meta.x>
  printf '%s' "$1" | python3 -c 'import json, sys
tok, fld = sys.argv[1], sys.argv[2]
v = ""
try:
    r = next((x for x in json.load(sys.stdin) if x.get("token") == tok), {})
    cur = r
    for k in fld.split("."):
        cur = (cur or {}).get(k) if isinstance(cur, dict) else ""
    v = cur
except Exception:
    v = ""
print("" if v is None else (",".join(map(str, v)) if isinstance(v, list) else v))' "$2" "$3" 2>/dev/null
}
njson(){ # 原生记录条数 (content_type=application/json 是 X 分享里它唯一的用法)
  printf '%s' "$1" | python3 -c 'import json,sys
print(len([r for r in json.load(sys.stdin)
           if str(r.get("content_type","")).startswith("application/json")]))' 2>/dev/null
}
declared(){ bash "$ROOT/conf/share.sh" list 2>&1 | grep -oE 'http://[^ ]+' | sed -n 1p; }

LIST=$(SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" list 2>/dev/null)
BEFORE_URL=$(declared)
BEFORE_BASE=${BEFORE_URL%%\?*}
BEFORE_SHA=$(meta_of "$LIST" "$PTOK" content_sha256)
PNAME=$(meta_of "$LIST" "$PTOK" meta.name)
PTAGS=$(meta_of "$LIST" "$PTOK" meta.tags)
LEGACY=$(PNAME="$PNAME" PTAGS="$PTAGS" python3 -c 'import json, os
print(json.dumps({"name": os.environ["PNAME"], "tags": os.environ["PTAGS"].split(","),
                  "payload_schema": 2}, ensure_ascii=False))')
SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" update \
    --token "$PTOK" --meta "$LEGACY" >/dev/null 2>&1
SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" delete \
    --token "$NTOK" >/dev/null 2>&1
LIST=$(SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" list 2>/dev/null)
LEG_URL=$(declared)
if [[ "$(njson "$LIST")" = 0 && "$LEG_URL" != *"url-xray"* && "${LEG_URL%%\?*}" = "$BEFORE_BASE" ]]; then
  ok "已还原成互通之前的形态（无原生记录 / 地址无声明 / token 未变）"
else
  no "还原失败: native=$(njson "$LIST") url=$LEG_URL"
fi

REFRESH_OUT=$(bash "$ROOT/conf/share.sh" refresh 2>&1)
printf '%s\n' "$REFRESH_OUT" | grep -E '刷新|补建|失败|不可达' | sed 's/^/  /'
AFTER=$(SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" list 2>/dev/null)
NTOK2=$(printf '%s' "$AFTER" | python3 -c 'import json,sys
print(next((r["token"] for r in json.load(sys.stdin)
            if (r.get("meta") or {}).get("role") == "native"), ""))' 2>/dev/null)
AFTER_URL=$(declared)
# ① 成对: 原生记录回来了, 且只有一条, content_type 是 JSON, 能解析出节点
NATN=$(njson "$AFTER")
NAT_NODES=$(curl -s "http://127.0.0.1:$PORT/share/$NTOK2" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("outbounds") or []))
except Exception: print(0)' 2>/dev/null)
[[ "$NATN" = 1 && -n "$NTOK2" && "${NAT_NODES:-0}" -gt 0 ]] \
  && ok "刷新补建了原生产品（1 条, JSON, $NAT_NODES 个出站）" \
  || no "没有补出原生产品 (native=$NATN tok=${NTOK2:0:8} outbounds=${NAT_NODES:-0})"
# ② 声明: 地址上带齐, 且 token/base 不变
if [[ "${AFTER_URL%%\?*}" = "$BEFORE_BASE" \
      && "$AFTER_URL" = *"interop=1"* && "$AFTER_URL" = *"kernel=xray"* \
      && "$AFTER_URL" = *"distribution=xray"* \
      && "$AFTER_URL" = *"formats=uri%2Cxray"* && "$AFTER_URL" = *"url-xray="* ]]; then
  ok "地址补上了声明且 token/基址未变（$(printf '%s' "$AFTER_URL" | sed 's/.*?//' | cut -c1-52)…）"
else
  no "声明没补上或地址变了: $AFTER_URL"
fi
# ③ 主记录 meta: 声明字段 + native_token 指向新记录, 内容哈希未变
PMETA_OK=$(printf '%s' "$AFTER" | python3 -c 'import json,sys
r = next((x for x in json.load(sys.stdin) if x.get("token") == sys.argv[1]), {})
m = r.get("meta") or {}
f = m.get("formats") or []
f = f if isinstance(f, list) else [f]
print("ok" if (m.get("role") == "primary" and m.get("interop") == 1
               and m.get("kernel") == "xray" and m.get("distribution") == "xray"
               and m.get("kernel_version") and "xray" in f
               and m.get("native_token") == sys.argv[2]) else
      "bad role=%r interop=%r dist=%r formats=%r ntok=%r" % (
          m.get("role"), m.get("interop"), m.get("distribution"), f,
          (m.get("native_token") or "")[:8]))' "$PTOK" "$NTOK2" 2>/dev/null)
[[ "$PMETA_OK" = ok ]] && ok "主记录 meta 写了完整声明, native_token 指向新记录" \
                       || no "主记录 meta 不对: $PMETA_OK"
[[ "$(meta_of "$AFTER" "$PTOK" content_sha256)" = "$BEFORE_SHA" ]] \
  && ok "普通话内容未被这次刷新改动（sha 相同 $BEFORE_SHA）" \
  || no "普通话内容被改动了: $BEFORE_SHA → $(meta_of "$AFTER" "$PTOK" content_sha256)"
# ④ 成对语义: 到期时间与次数上限同源 (一条永久一条 24h 会让用户以为原生自己坏了)
PAIR=$(printf '%s' "$AFTER" | python3 -c 'import json,sys
recs = json.load(sys.stdin)
p = next((x for x in recs if x.get("token") == sys.argv[1]), {})
n = next((x for x in recs if x.get("token") == sys.argv[2]), {})
print("ok" if (p.get("expires_at") == n.get("expires_at")
               and p.get("max_uses") == n.get("max_uses")) else
      "bad exp %s/%s uses %s/%s" % (p.get("expires_at"), n.get("expires_at"),
                                    p.get("max_uses"), n.get("max_uses")))' "$PTOK" "$NTOK2" 2>/dev/null)
[[ "$PAIR" = ok ]] && ok "原生产品与主记录同到期时间/同次数上限" || no "成对语义不一致: $PAIR"
# ⑤ 幂等: 再刷一次不重复建原生
bash "$ROOT/conf/share.sh" refresh >/dev/null 2>&1
AFTER2=$(SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" list 2>/dev/null)
NTOK3=$(printf '%s' "$AFTER2" | python3 -c 'import json,sys
print(next((r["token"] for r in json.load(sys.stdin)
            if (r.get("meta") or {}).get("role") == "native"), ""))' 2>/dev/null)
[[ "$(njson "$AFTER2")" = 1 && "$NTOK3" = "$NTOK2" ]] \
  && ok "幂等: 再刷一次仍是 1 条原生, native_token 未变" \
  || no "幂等被破坏: native=$(njson "$AFTER2") ${NTOK2:0:8} → ${NTOK3:0:8}"
# ⑥ meta 不被抹: 把 schema 改成旧版 (逼刷新走更新分支), 互通字段必须留住
BAD_META=$(printf '%s' "$AFTER2" | python3 -c 'import json,sys
m = dict(next((x.get("meta") or {} for x in json.load(sys.stdin)
               if x.get("token") == sys.argv[1]), {}))
m["payload_schema"] = 1
print(json.dumps(m, ensure_ascii=False))' "$PTOK" 2>/dev/null)
SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" update \
    --token "$PTOK" --meta "$BAD_META" >/dev/null 2>&1
bash "$ROOT/conf/share.sh" refresh >/dev/null 2>&1
AFTER3=$(SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" list 2>/dev/null)
KEEP=$(printf '%s' "$AFTER3" | python3 -c 'import json,sys
r = next((x for x in json.load(sys.stdin) if x.get("token") == sys.argv[1]), {})
m = r.get("meta") or {}
f = m.get("formats") or []
f = f if isinstance(f, list) else [f]
print("ok" if (m.get("role") == "primary" and m.get("native_token") == sys.argv[2]
               and m.get("distribution") == "xray" and "xray" in f) else
      "bad role=%r ntok=%r dist=%r formats=%r" % (
          m.get("role"), (m.get("native_token") or "")[:8],
          m.get("distribution"), f))' "$PTOK" "$NTOK2" 2>/dev/null)
[[ "$KEEP" = ok && "$(meta_of "$AFTER3" "$PTOK" meta.payload_schema)" = 2 ]] \
  && ok "刷新保留互通字段（role/native_token/distribution/formats 未被整体替换抹掉）" \
  || no "互通字段被抹掉了: $KEEP schema=$(meta_of "$AFTER3" "$PTOK" meta.payload_schema)"

echo
echo "=== 10 · 面板不得谎报『陈旧!』（原生记录也必须带生成器版本号） ==="
# 原生 JSON 由 native.py 生成, 普通话 base64 由 share_payload.py 生成 —— 但
# "陈旧"的判据是 meta.payload_schema **一个**字段。原生记录不带号 (或带一个
# 面板不认识的号), 面板就会把每条原生都标成"陈旧!"并劝用户去 refresh ——
# 假警报, 用户会以为订阅坏了。这里断言: 刚建/刚刷过的分享, 两个记录都显示
# "最新", 且都带**当前**生成器版本号。
LISTNOW=$(bash "$ROOT/conf/share.sh" list 2>&1)
printf '%s\n' "$LISTNOW" | grep -E 'TOKEN|x-|陈旧' | sed 's/^/  /'
# 两个条件一起断言: 少了后半条, "一条原生记录都没有" 也会让"没有陈旧"成立 ——
# 那正是"因为什么都没做所以没有假警报"的假绿。
if printf '%s' "$LISTNOW" | grep '陈旧' >/dev/null; then
  no "面板把最新内容报成『陈旧!』（假警报）"
elif ! printf '%s' "$LISTNOW" | grep '原生' >/dev/null; then
  no "列表里根本没有原生记录 —— 『没有陈旧』不算通过（什么都没做）"
else
  ok "面板没有谎报陈旧（列表里确有原生记录, 且全部显示最新）"
fi
SCHEMAS=$(printf '%s' "$AFTER3" | python3 -c 'import json,sys
p = n = None
for r in json.load(sys.stdin):
    m = r.get("meta") or {}
    if m.get("role") == "native":
        n = m.get("payload_schema")
    elif m.get("role") == "primary":
        p = m.get("payload_schema")
print("%s/%s" % (p, n))' 2>/dev/null)
WANT_SCH=$(LIB="$ROOT/conf/lib" python3 -c 'import os, sys
sys.path.insert(0, os.environ["LIB"])
import share_payload
print("%s/%s" % (share_payload.PAYLOAD_SCHEMA, share_payload.PAYLOAD_SCHEMA))' 2>/dev/null)
[[ "$SCHEMAS" = "$WANT_SCH" ]] \
  && ok "两个记录都带当前生成器版本号（主/原生=$SCHEMAS, 期望 $WANT_SCH）" \
  || no "版本号不对: 主/原生=$SCHEMAS 期望 $WANT_SCH"

echo
echo "=== 结果: $pass 通过, $fail 失败 ==="
[[ "$fail" -eq 0 ]]
