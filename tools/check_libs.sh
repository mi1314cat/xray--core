#!/usr/bin/env bash
# 通用能力验证套件
#
# 覆盖 conf/lib/ 下每个模块的核心契约。这些都是"看起来成功、实际静默失效"
# 高发的地方, 所以断言的不是"跑通了", 而是具体那些容易悄悄失效的性质。
#
# 用法: bash tools/check_libs.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# ★ 测试绝不能碰生产的分享服务。
#
#   批量建节点收尾会自动"确保一条覆盖全部节点的订阅", 而分享服务是**远端
#   服务** —— 它不知道调用方在不在沙箱里。2026-10-16 数出来: 生产分享服务里
#   堆了 20 条叫「全协议订阅」的记录, 引用的是沙箱里并不存在的 tag,
#   时间戳正好对着几轮测试。所以这里显式关掉。
export X_NO_SHARE_SUBSCRIBE=1
LIB="$ROOT/conf/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
group(){ printf '\n\033[36m%s\033[0m\n' "$*"; }

# 静默跳过检测: 见文件末尾"门禁自检"。子 shell 里的 FAIL 会丢, 所以
# 直接落文件, 末尾按文件判定。
GHOST_LOG="$(mktemp -t cl-ghost.XXXXXX)"
trap 'rm -f "$GHOST_LOG"' EXIT
command_not_found_handle() {
    printf '%s\n' "$1" >>"$GHOST_LOG"
    printf '  \033[31m✗\033[0m 不存在的命令: %s\n' "$1" >&2
    return 127
}

# assert_eq <实际> <期望> <描述>
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (得到 '$1', 期望 '$2')"; }
assert_true() { [[ "$1" == "true" ]] && ok "$2" || bad "$2"; }

# ---------------------------------------------------------------- 语法门禁
group "语法门禁"
for f in "$LIB"/*.py; do
    python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$f" 2>/dev/null \
        && ok "python 语法: $(basename "$f")" || bad "python 语法: $(basename "$f")"
done
for f in "$ROOT"/conf/*.sh "$ROOT"/*.sh; do
    [[ -f "$f" ]] || continue
    bash -n "$f" 2>/dev/null && ok "bash 语法: $(basename "$f")" || bad "bash 语法: $(basename "$f")"
done

# ---------------------------------------------------------------- 协议 E2E
# 预置生成器过 `xray run -test` 只说明配置被内核接受, 不说明流量真能通。完整
# 链路验证要两个 Xray 进程加一个源站, 没有内核时跑不了; 这里能离线做的部分是
# 挡住"配置生成"这一层的错 —— 那层一旦坏了要等实机才暴露, 而内核报的错
# (缺 decryption / 证书要 PEM / Trojan 要 servers) 与真正原因相距很远。
group "协议 E2E (e2e_configs.py / e2e_protocols.sh)"
bash -n "$ROOT/tools/e2e_protocols.sh" 2>/dev/null \
    && ok "harness bash 语法" || bad "harness bash 语法"
python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$ROOT/tools/e2e_configs.py" 2>/dev/null \
    && ok "配置生成模块 python 语法" || bad "配置生成模块 python 语法"

SHAPE=$(python3 "$ROOT/tools/e2e_configs.py" --selftest 2>&1)
while IFS= read -r ln; do
    case "$ln" in
        "OK "*) ok "${ln#OK }" ;;
        "NO "*) bad "${ln#NO }" ;;
    esac
done <<< "$SHAPE"

# 有内核就跑完整链路; 没有就说明白跳过原因, 不静默当过
X=""
command -v xray >/dev/null 2>&1 && X=$(command -v xray)
[[ -z "$X" && -x /root/catmi/xray/xrayls ]] && X=/root/catmi/xray/xrayls
if [[ -n "$X" ]]; then
    if out=$(XRAY_BIN="$X" WORK="$TMP/e2e" bash "$ROOT/tools/e2e_protocols.sh" 2>&1); then
        n=$(printf '%s' "$out" | grep -c '链路打通')
        ok "完整链路 $n 种协议/传输全部打通"
    else
        bad "完整链路未全通过"
        printf '%s\n' "$out" | grep '✗' | awk 'NR<=6' | sed 's/^/        /'
    fi
else
    printf '  - 完整链路验证需要 Xray 内核 (本机没有, 已在实机跑过)\n'
fi

group "节点注册表 (nodes.py)"
CONF="$TMP/nodes"; mkdir -p "$CONF"
cat > "$CONF/vless-01.json" <<'J'
{"inbounds":[{"tag":"vless-01","port":20001,"protocol":"vless",
  "settings":{"clients":[{"id":"u1","flow":"xtls-rprx-vision"}],"decryption":"none"},
  "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverNames":["a.com"]}}}]}
J
printf '{"inbounds":[{"tag":"ss-02","port":20002,"protocol":"shadowsocks","settings":{"method":"2022-blake3-aes-128-gcm","password":"p"},"streamSettings":{"network":"tcp","security":"none"}}]}\n' > "$CONF/ss-02.json"
printf '{"inbounds": 坏的\n' > "$CONF/broken.json"
printf 'null\n' > "$CONF/null.json"

N=$(python3 "$LIB/nodes.py" "$CONF" json 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["nodes"]))')
assert_eq "$N" "2" "坏片段被跳过, 好节点照常读出"
B=$(python3 "$LIB/nodes.py" "$CONF" json 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["unreadable"]))')
assert_eq "$B" "2" "坏片段被记入 unreadable (不静默)"
SS=$(python3 -c "
import sys;sys.path.insert(0,'$LIB');import nodes as N
n,_=N.collect('$CONF')
print(next((x['method'] for x in n if x['tag']=='ss-02'),''))")
assert_eq "$SS" "2022-blake3-aes-128-gcm" "Shadowsocks 单用户形态也能抽出 method"


# ---------------------------------------------------------------- 说明
# 原来这里还有一组"损坏隔离", 是通过 HTTP 打本地分享服务端来验证
# "一个片段坏了其余节点照样发得出去"的。服务端已删 (存储与生命周期归公共
# 基础服务), 同样的性质改到下面「载荷构建」组里直接验 build_payload ——
# 少一跳网络, 断言反而更贴近真正要守的东西。

# ---------------------------------------------------------------- 载荷构建
# 以前这一组是通过 HTTP 打本地分享服务端来验证的。服务端已经删掉了
# (存储与生命周期归公共基础服务), 但**要验的性质没变** —— 所以改成直接
# 打 share_payload.build_payload(), 不经过任何网络:
#   "一个片段坏了, 其余节点照样要能发出去; 坏的那个不能混进订阅"
# 这是最容易静默失效的地方: 坏片段混进 base64 订阅后, 客户端整段解析失败,
# 用户看到的是"订阅导入 0 个节点", 而面板这边一切正常。
group "载荷构建 (share_payload.build_payload)"
PB="$TMP/payload"; mkdir -p "$PB/conf" "$PB/share"
python3 - "$LIB" "$PB" <<'PY'
import json, sys, os
sys.path.insert(0, sys.argv[1]); d = sys.argv[2]
import share_meta as M
for t, p in (("good1", 20001), ("good2", 20002)):
    with open(os.path.join(d, "conf", t + ".json"), "w") as f:
        json.dump({"inbounds": [{"tag": t, "port": p, "protocol": "vless",
          "settings": {"clients": [{"id": "u"}]},
          "streamSettings": {"network": "tcp", "security": "none"}}]}, f)
    M.save(os.path.join(d, "share"), t, {"host": "h.com", "port": p, "name": t})
# 没有 share_meta 的 —— "缺对外地址", 与"节点被删"是两类不同的故障
with open(os.path.join(d, "conf", "nometa.json"), "w") as f:
    json.dump({"inbounds": [{"tag": "nometa", "port": 20003, "protocol": "vless",
      "settings": {"clients": [{"id": "u"}]},
      "streamSettings": {"network": "tcp", "security": "none"}}]}, f)
with open(os.path.join(d, "conf", "broken.json"), "w") as f:
    f.write('{"inbounds": [ THIS IS NOT JSON')
PY
PO=$(python3 - "$LIB" "$PB" <<'PY'
import sys, os, base64
sys.path.insert(0, sys.argv[1]); d = sys.argv[2]
os.environ.update(XRAY_CONF_DIR=os.path.join(d, "conf"), XRAY_SHARE_DIR=os.path.join(d, "share"))
import share_payload as P
payload, missing, nometa, bad = P.build_payload(["good1", "good2", "nometa", "gone", "broken"])
print("payload_is_none=%s" % (payload is None))
print("bad_count=%d" % len(bad))
print("missing=%s" % (",".join(missing) or "-"))
print("nometa=%s" % (",".join(nometa) or "-"))
if payload is None:
    print("decoded=DECODE_FAIL"); print("pure_b64=False")
else:
    try:
        txt = base64.b64decode(payload, validate=True).decode()
    except Exception:
        txt = "DECODE_FAIL"
    print("has_good1=%s" % ("good1" in txt))
    print("has_good2=%s" % ("good2" in txt))
    print("has_broken=%s" % ("broken" in txt))
    print("has_nometa=%s" % ("nometa" in txt))
    print("pure_b64=%s" % all(c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=" for c in payload))
PY
)
echo "$PO" | grep 'payload_is_none=False' >/dev/null && ok "好节点存在时仍构建出载荷" || bad "载荷构建失败"
echo "$PO" | grep 'has_good1=True' >/dev/null && ok "坏片段不影响好节点 (good1)" || bad "好节点丢失"
echo "$PO" | grep 'has_good2=True' >/dev/null && ok "坏片段不影响好节点 (good2)" || bad "好节点丢失"
echo "$PO" | grep 'has_broken=False' >/dev/null && ok "坏片段被跳过而非混入" || bad "坏片段混进订阅 (客户端会整段解析失败)"
echo "$PO" | grep 'has_nometa=False' >/dev/null && ok "缺对外地址的节点不混入" || bad "缺元数据的节点混进订阅"
echo "$PO" | grep 'pure_b64=True' >/dev/null && ok "载荷仍是纯 base64" || bad "载荷混入非 base64 内容"
echo "$PO" | grep 'bad_count=1' >/dev/null && ok "坏片段数量被单独报出" || bad "坏片段没有单独报出"
echo "$PO" | grep 'missing=gone' >/dev/null && ok "已删节点单独报出 (与缺元数据区分)" || bad "已删节点没有单独报出"
echo "$PO" | grep 'nometa=nometa' >/dev/null && ok "缺元数据单独报出 (与已删区分)" || bad "缺元数据没有单独报出"

# ---------------------------------------------------------------- 载荷 ↔ 产物
#
# 同一个节点的链接有**两条**生成路径: 各协议脚本写的 per-node 产物
# (out/<proto>_share-<NN>.txt) 与订阅载荷 (share_payload → nodes.build_share_link)。
# 2026-10-10 实测事故: 同一个 vless-xhttp08, 产物有 sni+ech, 载荷两个都丢 ——
# 三家客户端同时连不上, 而面板/链接看起来完全正常。
#
# 这一组锁三件事:
#   ① 取值逻辑同源 (片段 _serverName 参与 SNI; ECH 从 echServerKeys 还原,
#      与 `xray tls ech -i` 逐字节相同);
#   ② ECH 与端点绑定 (连 CDN 边缘才写 CDN 形式; 连源站不写);
#   ③ 与 per-node 产物做一致性校验,**不一致就拒发并说明差在哪个字段**。
group "载荷 ↔ per-node 产物一致性 + ECH 同源"
ET="$TMP/echlink"; mkdir -p "$ET/conf" "$ET/share" "$ET/out"
# 生产真值对 (RN, 2026-10-10): vless-xhttp-08.json 的 echServerKeys 与
# `xrayls tls ech -i` 打印的 ECH config list。公开值, 不含私钥以外的秘密。
ECH_KEYS='ACAeHgJriV0xujYELoel7l+Avsa2y7yjytil2vOQSlCdLgBl/g0AYQAAIAAgP6zoBwcqbFnPyw2P1mY5ivBpuY6XvO+omOwChaYR3QIAJAABAAEAAQACAAEAAwACAAEAAgACAAIAAwADAAEAAwACAAMAAwASbW9vbnR2LjY4OTY2OTgueHl6AAA='
ECH_WANT='AGX+DQBhAAAgACA/rOgHBypsWc/LDY/WZjmK8Gm5jpe876iY7AKFphHdAgAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADABJtb29udHYuNjg5NjY5OC54eXoAAA=='
python3 - "$LIB" "$ET" "$ECH_KEYS" <<'PY'
import json, sys, os
sys.path.insert(0, sys.argv[1]); d, keys = sys.argv[2], sys.argv[3]
def frag(name, port, net, path, keys=None):
    tls = {"minVersion": "1.3",
           "certificates": [{"certificateFile": "/nonexistent/x.pem"}]}
    if keys:
        tls["echServerKeys"] = keys
    ss = {"network": net, "security": "tls", "tlsSettings": tls}
    ss[("xhttpSettings" if net == "xhttp" else "wsSettings")] = {"path": path}
    return {"inbounds": [{"tag": name, "listen": "0.0.0.0", "port": port,
      "protocol": "vless", "settings": {"clients": [{"id": "uuid-" + name}],
      "decryption": "none"}, "streamSettings": ss}], "_serverName": "a.example"}
# 直连 ECH 节点 (片段自带服务端密钥, TLS 在本节点终结)
json.dump(frag("n-direct", 29601, "ws", "/p1", keys),
          open(os.path.join(d, "conf", "n-direct.json"), "w"))
# CDN-ECH 节点 (有 _serverName, 没有 echServerKeys)
json.dump(frag("n-cdn", 8443, "xhttp", "/p2"),
          open(os.path.join(d, "conf", "n-cdn.json"), "w"))
def meta(tag, host, port, name):
    json.dump({"host": host, "port": port, "name": name},
              open(os.path.join(d, "share", tag + ".json"), "w"))
# 直连 ECH 节点: 元数据 host 是本机公网 IP (与产物端点一致)
meta("n-direct", "203.0.113.9", 29601, "n-direct")
meta("n-cdn", "203.0.113.9", 8443, "n-cdn")
PY

# ① ECHConfigList 还原 == xray 的值 (逐字节)
ECHGOT=$(python3 - "$LIB" "$ECH_KEYS" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import nodes
print(nodes.ech_config_list(sys.argv[2]))
PY
)
assert_eq "$ECHGOT" "$ECH_WANT" "echServerKeys → ECHConfigList（与 xray tls ech -i 逐字节相同）"
ECHBAD=$(python3 - "$LIB" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import nodes
print("|".join([nodes.ech_config_list(""), nodes.ech_config_list("not-base64!!"),
                nodes.ech_config_list("AAAA")]))
PY
)
assert_eq "$ECHBAD" "||" "坏/空 echServerKeys 不猜值（返回空而不是半截配置）"

# ② 真实产物 → 载荷: sni 来自 _serverName, ech 来自 echServerKeys
PAY=$(python3 - "$LIB" "$ET" "$ECH_WANT" <<'PY'
import sys, os, json, base64, urllib.parse
sys.path.insert(0, sys.argv[1]); d, want = sys.argv[2], sys.argv[3]
os.environ.update(XRAY_CONF_DIR=os.path.join(d, "conf"),
                  XRAY_SHARE_DIR=os.path.join(d, "share"),
                  XRAY_OUT_DIR=os.path.join(d, "out"), XRAY_BASE=d)
import share_payload as P
# 先放"正确"的 per-node 产物 (与节点自身一致)
open(os.path.join(d, "out", "vless-xhttp_share-direct.txt"), "w").write(
    "vless://uuid-n-direct@203.0.113.9:29601?encryption=none&security=tls"
    "&sni=a.example&type=ws&path=/p1&ech=%s#n-direct\n" % urllib.parse.quote(want, safe=""))
open(os.path.join(d, "out", "vless-xhttp-share-cdn.txt"), "w").write(
    "vless://uuid-n-cdn@cdn.example:443?encryption=none&security=tls"
    "&sni=a.example&type=xhttp&path=/p2"
    "&ech=cloudflare-ech.com%2Bhttps%3A%2F%2Fdns.alidns.com%2Fdns-query#n-cdn\n")
payload, missing, nometa, bad, refused, notes, inc = P.build_payload(
    ["n-direct", "n-cdn"], full=True)
print("has_sni=%s" % ("sni=a.example" in urllib.parse.unquote(
      base64.b64decode(payload).decode() if payload else "")))
print("has_ech=%s" % (want in urllib.parse.unquote(
      base64.b64decode(payload).decode() if payload else "")))
print("inc=%d" % len(inc))
print("checked_line=%s" % any("一致性校验" in n for n in notes))
PY
)
echo "$PAY" | grep 'has_sni=True' >/dev/null && ok "TLS 节点链接带上 sni（片段 _serverName 参与取值）" \
    || bad "载荷又丢 sni: $(echo "$PAY" | tr '\n' ' ')"
echo "$PAY" | grep 'has_ech=True' >/dev/null && ok "直连 ECH 节点链接带上 ech（与产物同值）" \
    || bad "载荷又丢 ech: $(echo "$PAY" | tr '\n' ' ')"
echo "$PAY" | grep 'inc=0' >/dev/null && ok "与产物一致的节点不被误拒" \
    || bad "一致却被拒发: $(echo "$PAY" | tr '\n' ' ')"
echo "$PAY" | grep 'checked_line=True' >/dev/null && ok "一致性校验的结果有报出（不是静默通过）" \
    || bad "校验结果没报出"

# ③ 端点: 连 CDN 边缘才写 CDN 形式的 ECH; 连源站不写
CDNPAY=$(python3 - "$LIB" "$ET" <<'PY'
import sys, os, json, base64, urllib.parse
sys.path.insert(0, sys.argv[1]); d = sys.argv[2]
os.environ.update(XRAY_CONF_DIR=os.path.join(d, "conf"),
                  XRAY_SHARE_DIR=os.path.join(d, "share"),
                  XRAY_OUT_DIR=os.path.join(d, "out"), XRAY_BASE=d)
import share_meta as M, share_payload as P
# 同一个 CDN-ECH 节点: 元数据 host 改成域名 (= 发布 CDN 边缘)
M.save(os.path.join(d, "share"), "n-cdn",
       {"host": "cdn.example", "port": 443, "name": "n-cdn"})
payload, *_ = P.build_payload(["n-cdn"], full=True)
txt = urllib.parse.unquote(base64.b64decode(payload).decode()) if payload else ""
print("cdn_edge_ech=%s" % ("ech=cloudflare-ech.com+https://dns.alidns.com/dns-query" in txt))
# 再改回源站 IP
M.save(os.path.join(d, "share"), "n-cdn",
       {"host": "203.0.113.9", "port": 8443, "name": "n-cdn"})
payload, missing, nometa, bad, refused, notes, inc = P.build_payload(["n-cdn"], full=True)
txt = urllib.parse.unquote(base64.b64decode(payload).decode()) if payload else ""
print("origin_no_ech=%s" % ("&ech=" not in txt))
print("origin_note=%s" % any("端点不同" in n for n in notes))
PY
)
echo "$CDNPAY" | grep 'cdn_edge_ech=True' >/dev/null && ok "发布 CDN 边缘时写 CDN-ECH（与产物同值）" \
    || bad "CDN 端点的 ech 丢了: $(echo "$CDNPAY" | tr '\n' ' ')"
echo "$CDNPAY" | grep 'origin_no_ech=True' >/dev/null && ok "发布源站时不写 CDN 的 ECH（ECH 与端点绑定）" \
    || bad "给源站发了 CDN 的 ECH 配置（握手必失败）: $(echo "$CDNPAY" | tr '\n' ' ')"
echo "$CDNPAY" | grep 'origin_note=True' >/dev/null && ok "CDN 边缘 ↔ 直连源站的端点差异被留痕" \
    || bad "端点不同却沉默: $(echo "$CDNPAY" | tr '\n' ' ')"

# ④ 反向验证: 产物有 sni/ech、载荷缺 → 必须拒发, 且原因里点出字段名
#    这里直接用"事故当时的真实载荷形态"(sni 缺 / ech 缺 / sni 写成 IP)。
BADGOT=$(python3 - "$LIB" "$ET" "$ECH_WANT" <<'PY'
import sys, os, urllib.parse
sys.path.insert(0, sys.argv[1]); d, want = sys.argv[2], sys.argv[3]
import nodes as N
prod = os.path.join(d, "out")
items = [
  ("n-direct", "vless://uuid-n-direct@203.0.113.9:29601?encryption=none"
               "&security=tls&type=ws&path=/p1#n-direct"),          # 丢 sni + 丢 ech
  ("n-cdn",    "vless://uuid-n-cdn@203.0.113.9:8443?encryption=none"
               "&security=tls&type=xhttp&path=/p2&sni=203.0.113.9#n-cdn"),  # sni 写成 IP
  ("n-ok",     "vless://uuid-n-direct@203.0.113.9:29601?encryption=none"
               "&security=tls&sni=a.example&type=ws&path=/p1&ech=%s#n-direct"
               % urllib.parse.quote(want, safe="")),               # 正确的那条
]
kept, refused, checked, unchecked = N.verify_against_products(items, prod)
print("kept=%s" % ",".join(t for t, _ in kept))
print("refused=%s" % ",".join(t for t, _ in refused))
for t, why in refused:
    print("why_%s=%s" % (t, why))
PY
)
echo "$BADGOT" | grep 'refused=n-direct,n-cdn' >/dev/null && ok "丢 sni/ech 的载荷被拒发（正是事故形态）" \
    || bad "该拒发的没拒: $(echo "$BADGOT" | tr '\n' ' ')"
echo "$BADGOT" | grep 'kept=n-ok' >/dev/null && ok "正确的那条照常发布（拒发只针对坏的那条）" \
    || bad "把好的也拒了: $(echo "$BADGOT" | tr '\n' ' ')"
echo "$BADGOT" | grep -E 'why_n-direct=.*(sni|ech)' >/dev/null && ok "拒发原因点出字段名（不是只给一句'不一致'）" \
    || bad "拒发原因没说清差在哪: $(echo "$BADGOT" | tr '\n' ' ')"
echo "$BADGOT" | grep -E 'why_n-cdn=.*sni' >/dev/null && ok "sni 被写成 IP 时也被拒（不是只判空值）" \
    || bad "sni=IP 没被拦住: $(echo "$BADGOT" | tr '\n' ' ')"

# ⑤ 产物命名两种风格都要认（下划线 / 连字符）—— 只认一种会静默漏掉一半节点
NAMED=$(python3 - "$LIB" "$ET" "$ECH_WANT" <<'PY'
import sys, os, urllib.parse
sys.path.insert(0, sys.argv[1]); d, want = sys.argv[2], sys.argv[3]
import nodes as N
idx, bad = N.product_links(os.path.join(d, "out"))
print("files=%d" % len(idx))
print("has_hyphen=%s" % any(f.startswith("vless-xhttp-share-") for f, _, _ in idx.values()))
print("has_underscore=%s" % any(f.startswith("vless-xhttp_share-") for f, _, _ in idx.values()))
PY
)
echo "$NAMED" | grep 'has_hyphen=True' >/dev/null && ok "连字符命名的产物 (ss2022-share-02.txt 那种) 也参与校验" \
    || bad "连字符命名的产物被漏掉: $(echo "$NAMED" | tr '\n' ' ')"
echo "$NAMED" | grep 'has_underscore=True' >/dev/null && ok "下划线命名的产物参与校验" \
    || bad "下划线命名的产物被漏掉: $(echo "$NAMED" | tr '\n' ' ')"

# ⑥ 没有 per-node 产物的部署不能被这道闸门搞成"一条都发不出去"
NOPROD=$(python3 - "$LIB" "$ET" <<'PY'
import sys, os, base64
sys.path.insert(0, sys.argv[1]); d = sys.argv[2]
empty = os.path.join(d, "out-empty"); os.makedirs(empty, exist_ok=True)
os.environ.update(XRAY_CONF_DIR=os.path.join(d, "conf"),
                  XRAY_SHARE_DIR=os.path.join(d, "share"),
                  XRAY_OUT_DIR=empty, XRAY_BASE=d)
import share_payload as P
payload, missing, nometa, bad, refused, notes, inc = P.build_payload(["n-direct"], full=True)
print("payload_ok=%s" % (payload is not None))
print("reported_unchecked=%s" % any("未校验" in n for n in notes))
PY
)
echo "$NOPROD" | grep 'payload_ok=True' >/dev/null && ok "没有产物时照常发布（不因为没法校验就拒发）" \
    || bad "没有产物时把节点全拒了: $(echo "$NOPROD" | tr '\n' ' ')"
echo "$NOPROD" | grep 'reported_unchecked=True' >/dev/null && ok "没有产物可比对这件事被报出来（不是静默通过）" \
    || bad "没产物却装作校验过了: $(echo "$NOPROD" | tr '\n' ' ')"

# ⑦ 已发出的分享"内容陈旧"必须看得见 —— 实测事故: 生成器修好了, 20:47 建的
#    分享到 23:28 还在发旧内容, 面板列表里一切正常, 只有客户端连不上。
#    share.sh 是 shell, 所以把它的 _x_share_api/_x_share_list 换成桩来跑真代码。
STALE=$(
  ST="$TMP/stale"; mkdir -p "$ST/share"
  printf 'x' > "$ST/payload"
  SCHEMA_NOW=$(python3 -c "import sys; sys.path.insert(0, '$LIB'); import share_payload; print(share_payload.PAYLOAD_SCHEMA)" 2>/dev/null || echo 0)
  XSCHEMA="$SCHEMA_NOW" bash -c '
    set -uo pipefail
    source "$1" >/dev/null 2>&1
    _x_share_api() { return 0; }                       # health 永远正常
    _x_share_list() {
      python3 -c "
import json, os
recs = [{\"token\": \"aaaa1111bbbb2222\", \"state\": \"active\",
         \"meta\": {\"name\": \"旧分享\", \"tags\": [\"t1\"], \"payload_schema\": 1}},
        {\"token\": \"cccc3333dddd4444\", \"state\": \"active\",
         \"meta\": {\"name\": \"新分享\", \"tags\": [\"t2\"],
                  \"payload_schema\": int(os.environ[\"XSCHEMA\"])}}]
print(json.dumps(recs))"
    }
    share_list 2>&1 | grep -E "陈旧|最新" | sed "s/[^[:print:]]//g"
  ' _ "$ROOT/conf/share.sh" "$ST"
)
echo "$STALE" | grep '陈旧' >/dev/null && ok "旧版生成器建的分享被标成陈旧" || bad "陈旧分享没被标出来: $STALE"
echo "$STALE" | grep '最新' >/dev/null && ok "当前版本的分享不被误标（陈旧判定不是恒真）" || bad "新分享被误标陈旧: $STALE"

# ---------------------------------------------------------------- 面板降级
# 公共基础服务不存在/没跑时, 面板必须**说清楚**, 不能装作一切正常。
#   share_list 若把"服务不可达"报成"还没有生成分享" —— 用户会以为链接被谁删了;
#   share_create 若继续往下走, 用户会拿到一条永远打不开的链接。
group "面板降级 (公共服务不可达时)"
DEG="$TMP/degrade"; mkdir -p "$DEG/conf" "$DEG/share"
python3 - "$LIB" "$DEG" <<'PY'
import json, sys, os
sys.path.insert(0, sys.argv[1]); d = sys.argv[2]
with open(os.path.join(d, "conf", "t.json"), "w") as f:
    json.dump({"inbounds": [{"tag": "t", "port": 20001, "protocol": "vless",
      "settings": {"clients": [{"id": "u"}]},
      "streamSettings": {"network": "tcp", "security": "none"}}]}, f)
PY
# 指一个确定没人听的端口。适配器按 SHARE_PORT / env / /run 文件找端口,
# 这里全部覆盖掉。
# SHARE_CLIENT_REAL 允许外部注入一个**真实**的 share_client.py。
# 原因: 测试沙盒常把 conf/share_client.py 换成返回假令牌的桩, 而桩永远"成功",
# 于是"服务不可达"这三条会假红 —— 桩没接网络, 谈不上不可达。
DL=$(SHARE_CLIENT="${SHARE_CLIENT_REAL:-$ROOT/conf/share_client.py}" SHARE_PORT=19499 \
     SHARE_PORT_FILE=/nonexistent SHARE_ETC=/nonexistent \
     XRAY_BASE="$DEG" XRAY_CONF_DIR="$DEG/conf" XRAY_SHARE_DIR="$DEG/share" \
     bash "$ROOT/conf/share.sh" list 2>&1; echo "rc=$?")
echo "$DL" | grep 'rc=1' >/dev/null && ok "服务不可达时 list 返回非 0" || bad "服务不可达时 list 仍返回 0"
echo "$DL" | grep '不可达' >/dev/null && ok "服务不可达被明确说出来" || bad "服务不可达没有说清楚"
echo "$DL" | grep -v '还没有生成分享' >/dev/null && ok "没有把'服务挂了'说成'没有分享'" || bad "把服务故障误报成没有分享"

# ---------------------------------------------------------------- 证书管理
# cert.sh 此前只有库没有用户入口。证书问题在现场的表现恰恰最难自查:
# 配好了但连不上, 而配置看着完全正常。
group "证书管理 (conf/cert.sh 菜单)"
CE="$TMP/cert"; mkdir -p "$CE/a"
openssl req -x509 -newkey rsa:2048 -keyout "$CE/a/ok.key" -out "$CE/a/ok.crt" \
  -days 30 -nodes -subj '/CN=good.example.com' >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -keyout "$CE/a/other.key" -out "$CE/a/other.crt" \
  -days 30 -nodes -subj '/CN=other.com' >/dev/null 2>&1
openssl genrsa -out "$CE/a/unrelated.key" 2048 >/dev/null 2>&1
cp "$CE/a/ok.crt" "$CE/a/nokey.crt"
cp "$CE/a/ok.crt" "$CE/a/fc_fullchain.pem"; cp "$CE/a/ok.key" "$CE/a/fc_privkey.pem"
cp "$CE/a/ok.crt" "$CE/a/mismatch.crt"; cp "$CE/a/unrelated.key" "$CE/a/mismatch.key"
cp /etc/ssl/certs/ca-certificates.crt "$CE/a/sys-bundle.crt" 2>/dev/null

bash -n "$ROOT/conf/cert.sh" 2>/dev/null && ok "cert.sh 语法" || bad "cert.sh 语法"

# source 不该弹菜单 —— 库被 source 就自己弹会把调用方的 stdin 吃掉
CS=$(timeout 20 bash -c "source '$ROOT/conf/cert.sh'; echo DONE" 2>&1 | grep -c '════')
assert_eq "$CS" "0" "source cert.sh 不弹菜单"

# 系统 CA 包不该出现在"我的证书"里
#
# ★ 这条以前写的是"总数 <= 8"。但 x_cert_search_dirs 里**硬编码了一批真实
#   目录** (/home/web/certs、/etc/letsencrypt/live、/root/catmi/certs …),
#   X_CERT_EXTRA_DIRS 只是额外加一条, 拦不住那些。所以计数跟着**宿主机状态**
#   走: 10-12 用户重新签发了两张证书, /home/web/certs 从 0 张变 2 张,
#   总数就顶破了 8 —— 测试红了, 但代码没坏。
#
#   这种"看着像回归、其实是环境变了"的红最耗人: 第一反应永远是去改代码。
#   改成自足: 造一张 CA 包 + 一张真证书放临时目录, 只断言**包被滤掉、
#   证书还在**。跟宿主状态彻底无关。
CE2="$TMP/certfilter"; mkdir -p "$CE2"
# _x_skip_bundle 判的是"这个文件里塞了几张证书", 不是文件名 —— 所以必须造
# 一份真的多证书 PEM, 拿随机字节当证书它认不出来, 测出来的就不是过滤器。
openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/ca-certificates.crt 2>/dev/null \
    | openssl pkcs7 -print_certs 2>/dev/null > "$CE2/ca-certificates.crt"
[[ -s "$CE2/ca-certificates.crt" ]] || { head -3 /etc/ssl/certs/ca-certificates.crt > "$CE2/ca-certificates.crt"; }
cp /etc/letsencrypt/live/*/fullchain.pem "$CE2/my.real.pem" 2>/dev/null \
    || cp /root/catmi/certs/*_cert.pem "$CE2/my.real.pem" 2>/dev/null \
    || openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out "$CE2/my.real.pem" -days 1 -subj "/CN=x" 2>/dev/null
CL=$(bash -c "source '$ROOT/conf/lib/cert.sh'
  export X_CERT_NGINX_DIRS='$CE2' XRAY_BASE='$CE2' X_CERT_EXTRA_DIRS='$CE2'
  x_cert_list")
CLN=$(printf '%s' "$CL" | grep -c . || true)
CLB=$(printf '%s' "$CL" | grep -c 'ca-certificates' || true)
CLG=$(printf '%s' "$CL" | grep -c 'my.real.pem' || true)
if [[ "$CLB" == "0" && "$CLG" == "1" ]]; then
    ok "系统 CA 包被滤掉, 用户自己的证书留下 (与宿主状态无关)"
else
    bad "CA 包过滤异常: 包命中 $CLB 次, 自己证书命中 $CLG 次"
fi

# 未定义 CONF_DIR 时不能静默退出 (set -u 下会终止整个 shell)
GU=$(env -u CONF_DIR -u MAIN_CONFIG -u XRAY_BASE timeout 20 bash -c "
  source '$ROOT/conf/lib/cert.sh'
  export X_CERT_EXTRA_DIRS='$CE/a'
  x_cert_list >/dev/null && echo OK" 2>&1 | tail -1)
case "$GU" in *unbound*) bad "cert.sh 依赖未定义变量, set -u 下致命" ;; *OK*) ok "未定义 CONF_DIR 时兜住默认值" ;; *) bad "未定义变量行为异常: $GU" ;; esac

cmenu() { X_CERT_NGINX_DIRS="$CE/a" X_CERT_EXTRA_DIRS="$CE/a" XRAY_BASE="$CE" \
          timeout 40 bash "$ROOT/conf/cert.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
# 用编号选候选 (直接给路径时同一行要过两处解析, 容易测错)
# 用绝对路径选, 不用编号 —— 编号依赖 x_cert_list 的枚举顺序, 那是目录扫描
# 决定的, 换台机器顺序就可能不同, 测试会莫名其妙地时对时错。
V1=$(printf '1\n0\n%s\ngood.example.com\n\n0\n' "$CE/a/ok.crt" | cmenu | grep -c '✓ 可用')
assert_eq "$V1" "1" "校验: 域名相符 → 可用"
V2=$(printf '1\n0\n%s\nwrong.com\n\n0\n' "$CE/a/ok.crt" | cmenu | grep -c '不一致')
assert_eq "$V2" "1" "校验: 域名不符 → 报出不一致"
V3=$(printf '1\n0\n%s\n\n0\n' "$CE/a/mismatch.crt" | cmenu | grep -c '不配对')
assert_eq "$V3" "1" "校验: crt/key 不配对 → 报出"
V4=$(printf '1\n0\n%s\n\n0\n' "$CE/a/nokey.crt" | cmenu | grep -c '证书本身可用')
assert_eq "$V4" "1" "缺私钥 → 报证书本身可用 (而非报 私钥不存在: 0)"
V5=$(printf '1\n0\n%s\n\n\n0\n' "$CE/a/fc_fullchain.pem" | cmenu | grep -c '✓ 可用')
assert_eq "$V5" "1" "fullchain+privkey 命名能推到私钥"
G1=$(printf '4\nn\n' | cmenu | grep -c '已取消')
assert_eq "$G1" "1" "GC: 取消时不删"
B4=$(ls "$CE"/a/*.crt 2>/dev/null | wc -l)
printf '4\nyes\n' | cmenu >/dev/null
A4=$(ls "$CE"/a/*.crt 2>/dev/null | wc -l)
assert_eq "$A4" "$B4" "GC: 非 DELETE 一律不删"
printf '4\nDELETE\n' | cmenu >/dev/null
A4b=$(ls "$CE"/a/*.crt 2>/dev/null | wc -l)
[[ "$A4b" -lt "$A4" ]] && ok "GC: 输入 DELETE 才删 ($A4 → $A4b)" || bad "GC: DELETE 后未删除"
cmenu2=$(printf '2\n0\n' | cmenu | grep -c '未引用\|使用中')
[[ "$cmenu2" -ge 1 ]] && ok "列出全部证书带使用状态" || bad "列出功能异常"
W1=$(printf '6\n0\n' | cmenu | grep -c '证书搜索范围')
assert_eq "$W1" "1" "搜索范围可查看"

# ---------------------------------------------------------------- Nginx 站点管理
# nginx_apply.py 早就做完了 (幂等插入、标记块、Docker 感知), 但一直只有
# 建节点那条路径能间接触发。用户想看一眼有哪些站点、或单独摘掉一个域名的
# 反代, 此前没有任何入口。
# ---------------------------------------------------------------- 对外地址探测
# 这一组守的是"下发出去的地址客户端能不能连上"。踩过的现场: 分享链接里是
# WARP 出口地址 (104.28.201.80), 而服务器入站是 107.173.154.178 —— 链接看起来
# 完全正常, 客户端照着连必然不通。
group "对外地址探测 (addr.sh)"
# 私网/保留段判定 —— 每一段都是实战踩得到的, 不是照抄 RFC 列表
for pair in "10.0.0.1:Y" "192.168.1.1:Y" "172.16.0.1:Y" "172.32.0.1:N" \
            "198.18.0.1:Y" "100.64.0.1:Y" "203.0.113.5:Y" "169.254.1.1:Y" \
            "8.8.8.8:N" "1.1.1.1:N"; do
    a="${pair%%:*}"; want="${pair##*:}"
    got=$(bash -c "source '$LIB/addr.sh'; x_addr_is_private '$a' && echo Y || echo N")
    assert_eq "$got" "$want" "私网判定 $a"
done
# 198.18.0.0/15 单独再点一次: 那是 mihomo/Clash 的 fake-ip 段, 跑 TUN 时
# 网口扫描会挑中 198.18.0.1 —— 排除不掉就会把假地址写进配置
got=$(bash -c "source '$LIB/addr.sh'; x_addr_is_private 198.18.0.1 && echo Y || echo N")
assert_eq "$got" "Y" "排除 mihomo fake-ip 段 (198.18/15)"

# 隧道网卡正则: 排除出口, 但**保留** HE 隧道的真实公网地址
for pair in "warp:Y" "wg0:Y" "awg0:Y" "docker0:Y" "tun0:Y" "br-bfb1497b:Y" \
            "he-ipv6-tun:Y" "he-ipv6:N" "eth0:N" "ens3:N"; do
    d="${pair%%:*}"; want="${pair##*:}"
    got=$(bash -c "source '$LIB/addr.sh'; [[ '$d' =~ \$X_TUNNEL_IFACE_RE ]] && echo Y || echo N")
    assert_eq "$got" "$want" "隧道网卡判定 $d"
done
# ★ he-ipv6 必须保留: 那是 HE 给的真实可路由地址, 正则写成 he-ipv6.* 会把它
#   一起排掉, 于是明明有 IPv6 却判成"无"
got=$(bash -c "source '$LIB/addr.sh'; [[ 'he-ipv6' =~ \$X_TUNNEL_IFACE_RE ]] && echo Y || echo N")
assert_eq "$got" "N" "he-ipv6 是真实地址不排除 (只排除 he-ipv6-tun)"

# 自检: 地址在不在本机接口上
got=$(bash -c "source '$LIB/addr.sh'; x_addr_is_local 127.0.0.1 && echo Y || echo N")
assert_eq "$got" "Y" "自检认出本机回环地址"
got=$(bash -c "source '$LIB/addr.sh'; x_addr_is_local 203.0.113.5 && echo Y || echo N")
assert_eq "$got" "N" "自检否掉不在本机的地址"
got=$(bash -c "source '$LIB/addr.sh'; x_addr_is_local '' && echo Y || echo N")
assert_eq "$got" "N" "空地址判为不在本机"

# URL 主机: IPv6 必须加方括号, 否则端口会被当成地址的一部分
got=$(bash -c "source '$LIB/addr.sh'; x_url_host 2001:db8::1")
assert_eq "$got" "[2001:db8::1]" "IPv6 加方括号"
got=$(bash -c "source '$LIB/addr.sh'; x_url_host 1.2.3.4")
assert_eq "$got" "1.2.3.4" "IPv4 不加方括号"
got=$(bash -c "source '$LIB/addr.sh'; x_url_host '[2001:db8::1]'")
assert_eq "$got" "[2001:db8::1]" "已加括号的不重复加"

# 主入口: 已保存的地址**必须过自检**才沿用 (否则修复前存进去的 WARP 地址会一直被沿用)
got=$(bash -c "source '$LIB/addr.sh'; x_public_addr '' 203.0.113.5")
[[ "$got" != "203.0.113.5" ]] && ok "已保存的地址不过自检时不沿用" \
    || bad "已保存的地址不过自检却仍被沿用 ($got)"
got=$(bash -c "source '$LIB/addr.sh'; x_public_addr 9.9.9.9")
assert_eq "$got" "9.9.9.9" "显式传参优先"

# 地址族标签
got=$(bash -c "source '$LIB/addr.sh'; x_addr_family_of 1.2.3.4")
assert_eq "$got" "IPv4" "地址族 IPv4"
got=$(bash -c "source '$LIB/addr.sh'; x_addr_family_of 2001:db8::1")
assert_eq "$got" "IPv6" "地址族 IPv6"

# ---------------------------------------------------------------- 取文件镜像链
group "取文件镜像链 (fetch.sh)"
got=$(bash -c "source '$LIB/fetch.sh'; echo \${#X_REPO_MIRRORS[@]}")
[[ "$got" -ge 4 ]] && ok "镜像链至少 4 个源 ($got)" || bad "镜像链太短 ($got)"
# ★ jsdelivr 必须垫底: 它是 CDN 带缓存的, 推完 commit 后仍返回旧文件,
#   加时间戳也绕不过去 —— 放前面会让人拿到旧版本还以为推送失败
last=$(bash -c "source '$LIB/fetch.sh'; echo \${X_REPO_MIRRORS[-1]}")
[[ "$last" == *jsdelivr* ]] && ok "jsdelivr 排在最后 (带缓存的源垫底)" \
    || bad "jsdelivr 没垫底, 当前最后一个是: $last"
# ★ 探测目标必须确认存在 —— 首版写的是 src/VERSION, 而本仓库没有这个文件,
#   于是每个源都探不通, 整条链直接全废
got=$(bash -c "source '$LIB/fetch.sh'; echo \$X_PROBE_FILE")
[[ -f "$ROOT/$got" ]] && ok "探测目标存在 ($got)" \
    || bad "探测目标在仓库里不存在: $got (整条链会全废)"
# 源名映射
got=$(bash -c "source '$LIB/fetch.sh'; x_source_name 'https://raw.githubusercontent.com/mi1314cat/xray--core/main'")
assert_eq "$got" "主站" "主站识别"
got=$(bash -c "source '$LIB/fetch.sh'; x_source_name 'https://ghproxy.net/https://raw.githubusercontent.com/x/y/main'")
assert_eq "$got" "ghproxy.net" "镜像名识别"
got=$(bash -c "source '$LIB/fetch.sh'; x_source_name ''")
assert_eq "$got" "未探测" "未探测时不报错"

# ---------------------------------------------------------------- 提示函数统一
# ok/info/warn/err 原来在 node.sh / share.sh / share_service.sh 里各抄了一份
# **逐字节相同**的四行。抄三遍的代价不是行数, 而是"改一处漏两处" ——
# 这组的重点不是"函数在不在", 而是那两条容易被漏掉的**行为约定**:
#   1) 一律写 stderr。stdout 是数据通道 (分享链接/节点列表都走它),
#      提示混进去, 下游会把 "[OK] 已创建" 当链接解析。
#   2) 非终端时不上色。否则重定向到日志, 每行都是 ^[[32m 这类垃圾。
group "提示函数统一 (print.sh)"
[[ -f "$LIB/print.sh" ]] && ok "conf/lib/print.sh 存在" || bad "conf/lib/print.sh 缺失"

for fn in ok info warn err die; do
    bash -c "source '$LIB/print.sh'; declare -F $fn >/dev/null" \
        && ok "导出 $fn()" || bad "没有 $fn()"
done

# ★ stdout 必须是空的 —— 这条是整组里最重要的
out=$(bash -c "source '$LIB/print.sh'; ok A; info B; warn C; err D" 2>/dev/null)
[[ -z "$out" ]] && ok "四条提示都不写 stdout (stdout 留给数据通道)" \
    || bad "有提示写进了 stdout: [$out]"

# 非终端不上色 (命令替换里一定不是终端)
out=$(bash -c "source '$LIB/print.sh'; ok A; warn B; err C; info D" 2>&1)
if printf '%s' "$out" | grep $'\033' >/dev/null; then
    bad "非终端下仍带 ANSI 转义序列 (重定向到日志会全是垃圾)"
else
    ok "非终端下不上色"
fi

# die 的退出码: 面板靠它判断成败, 必须固定
bash -c "source '$LIB/print.sh'; die x" >/dev/null 2>&1
assert_eq "$?" "1" "die 退出码为 1"

# 调用方已经设过颜色时不能被覆盖 (install.sh 用的是另一套变量名)
got=$(bash -c "source '$LIB/print.sh'; _GRN=X; source '$LIB/print.sh'; printf '%s' \"\$_GRN\"")
assert_eq "$got" "X" "重复 source 不覆盖调用方已有的颜色变量"

# 三个脚本不该再各留一份本地定义 —— 这才是这次改动的目的
for f in conf/node.sh conf/share.sh conf/share_service.sh; do
    n=$(grep -cE '^(ok|info|warn|err|die)\(\)' "$ROOT/$f" 2>/dev/null || true)
    [[ "$n" = "0" ]] && ok "$f 已无本地定义" || bad "$f 仍有 $n 处本地定义"
done

# 真的能加载 (跑一个未知子命令, 走它自己的 usage 分支就说明库加载过了)
for f in conf/node.sh conf/share.sh conf/share_service.sh; do
    out=$(bash "$ROOT/$f" __probe__ 2>&1 || true)
    if printf '%s' "$out" | grep -i "command not found" >/dev/null; then
        bad "$f 加载提示库失败: $(printf '%s' "$out" | awk 'NR==1')"
    elif [[ -z "$out" ]]; then
        bad "$f 未知子命令没有任何输出 (库可能没加载)"
    else
        ok "$f 能加载 print.sh"
    fi
done

# 顺序回归: share.sh 里 addr.sh 的失败分支要调 warn,
# warn 必须在那之前就定义好 —— 原来定义在它后面, 那条分支一旦走到
# 就是 "warn: command not found"。
a=$(grep -n 'source "\$LIB_DIR/print.sh"' "$ROOT/conf/share.sh" | awk 'NR==1' | cut -d: -f1)
b=$(grep -n 'source "\$LIB_DIR/addr.sh"' "$ROOT/conf/share.sh" | awk 'NR==1' | cut -d: -f1)
if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
    ok "share.sh: print.sh 在 addr.sh 之前加载 (warn 已可用)"
else
    bad "share.sh: 加载顺序不对 (print=$a addr=$b) —— warn 可能在定义前被调用"
fi

# 反方向的门禁: 这几个**引导脚本**必须保持自包含, 不能被"顺手统一"掉。
#   uninstall 尤其要紧 —— 它得在安装树损坏时照常工作, 而它自己还会把
#   lib/core.sh 列进删除清单, 自己依赖自己即将删的文件是说不通的。
if grep -qE '^[[:space:]]*(source|\.)[[:space:]]+.*core\.sh' "$ROOT/Client/uninstall-xray-client.sh"; then
    bad "uninstall-xray-client.sh 开始依赖 lib/core.sh 了 —— 安装树损坏时它会连提示都打不出来"
else
    ok "uninstall-xray-client.sh 保持自包含 (不依赖 lib/core.sh)"
fi
for f in Client/l.sh Client/RUN.sh; do
    grep -q '故意.*不共用 lib/core.sh' "$ROOT/$f" \
        && ok "$f 写明了为何不统一" || bad "$f 缺少「为何不统一」的说明"
done

# python() 包装不能被误吞 (它和提示函数挨着, 是最容易被误删的邻居)
for f in conf/share.sh conf/share_service.sh; do
    grep -q '^python() { command python3' "$ROOT/$f" \
        && ok "$f: python() 包装还在" || bad "$f: python() 包装丢了"
done

# ---------------------------------------------------------------- 随机值 / 交互输入
# 这两个库原来是"定义了但没人测", 于是幽灵函数门禁长期把它们报成不可达。
# 它们各自守着一个**记在注释里的真实事故**:
#   random.sh  —— random_pass / random_user 曾"零处定义"却被 Trojan/http/sock5
#                 调用, 默认值拿到空串 => 节点能建能连, 但密码是空的。
#   read.sh    —— 各脚本复制了十几份 safe_read 且都不检查 read 的返回值,
#                 EOF 时拿着空值反复报"格式无效", 无限刷屏到超时。
group "随机值 (random.sh)"
got=$(bash -c "source '$LIB/random.sh'; random_path")
[[ "$got" =~ ^/[A-Za-z0-9]{8}$ ]] && ok "random_path 形状 (/ + 8 位字母数字)" \
    || bad "random_path 形状不对: '$got'"
for spec in "random_pass:20" "random_user:16" "random_token:32"; do
    fn="${spec%%:*}"; want="${spec##*:}"
    got=$(bash -c "source '$LIB/random.sh'; $fn")
    [[ "${#got}" == "$want" ]] && ok "$fn 长度 $want" || bad "$fn 长度应 $want, 实得 ${#got}"
    [[ "$got" =~ ^[A-Za-z0-9]+$ ]] && ok "$fn 只用字母数字 (要进 URL/YAML)" \
        || bad "$fn 含非字母数字字符: '$got'"
done
# 空值是最危险的形态: 调用方拿它当"回车即用的默认值"
got=$(bash -c "source '$LIB/random.sh'; random_pass")
[[ -n "$got" ]] && ok "random_pass 不为空 (空密码=任何人都能连)" || bad "random_pass 返回空"

group "交互输入 (read.sh)"
got=$(bash -c "source '$LIB/read.sh'; clean_input '  a b  '")
assert_eq "$got" "a b" "clean_input 去首尾空白"
got=$(bash -c "source '$LIB/read.sh'; clean_input \$'x\r'")
assert_eq "$got" "x" "clean_input 去 CR (CRLF 输入)"
# ★ EOF 契约: 必须 **exit**, 不能返回空值。
#   返回空值的话调用方的校验分支会反复报"格式无效", 自动化里表现为卡死到超时。
printf '' | bash -c "source '$LIB/read.sh'; xr_read 'q' >/dev/null 2>&1; echo ALIVE" > "$TMP/eof1" 2>/dev/null
[[ "$(cat "$TMP/eof1")" != "ALIVE" ]] && ok "xr_read 在 EOF 时退出 (不返回空值)" \
    || bad "xr_read 在 EOF 时没退出 —— 死循环的根源"
printf '' | bash -c "source '$LIB/read.sh'; safe_read 'q' >/dev/null 2>&1; echo ALIVE" > "$TMP/eof2" 2>/dev/null
[[ "$(cat "$TMP/eof2")" != "ALIVE" ]] && ok "safe_read 在 EOF 时退出" \
    || bad "safe_read 在 EOF 时没退出"
got=$(printf 'hello\n' | bash -c "source '$LIB/read.sh'; safe_read 'q'")
assert_eq "$got" "hello" "safe_read 正常读入"
got=$(printf '\n' | bash -c "source '$LIB/read.sh'; safe_read 'q' '默认值'")
assert_eq "$got" "默认值" "safe_read 回车取默认值"

# ---------------------------------------------------------------- 节点命名
# 守的是"节点在客户端列表和分享链接里认得出、筛得准"。
# 踩过的现场: 同一台机器上并存 VLESS-WS_01 / vless-xhttp01 / hysteria-01 ——
# 大小写混用、`_` 与 `-` 混用、编号位数不一, 按前缀筛节点写不准。
# ---------------------------------------------------------------- nginx 片段生命周期
# 守的是"删了节点却把 nginx 片段留下"。症状是 Cloudflare 回源 502, 而且要等到
# **真有人访问那条路径**才暴露 —— 现场还没有任何线索指向"某次删节点"。
# (sing-box-core 那边踩过同一个坑, 它的 sb_cdn_cleanup_stale 就是为此而写。)
group "nginx 片段生命周期 (node.sh)"
NG_T="$TMP/ngorph"; mkdir -p "$NG_T/conf.d"
# 造一个"已无对应节点"的孤儿片段
cat > "$NG_T/conf.d/orphan.conf" <<'NGE'
server {
    server_name orphan.example.com;
    # >>> xray-core BEGIN orphan.example.com >>>
    location /p { proxy_pass http://127.0.0.1:19999; }
    # <<< xray-core END orphan.example.com <<<
}
NGE
NO=$(SHARE_DIR="$TMP/ngshare" XRAY_BASE="$NG_T" NGINX_CONF_ROOTS="$NG_T/conf.d" bash -c "
  LIB_DIR='$ROOT/conf/lib'
  mkdir -p \"$TMP/ngshare\"
  # 扫描范围由 NGINX_CONF_ROOTS 指定 —— 函数内部走 nginx_apply.py
  # 的探测 (与插入/摘除同一口径), 不再靠 sed 替换目录字符串。
  #
  #   抽函数体: 那种抽法一遇到函数体里**列 0 的 }**就提前截断, 而这个函数内嵌
  #   了一段正好含这种 } 的 python。截断后引号不闭合, 后面整段被当 shell 解析,
  #   marked 永远是空 —— 于是站点里明明有孤儿, 三条断言却一起红。
  #   node.sh 的 CLI 派发有 BASH_SOURCE 守卫, source 进来不弹菜单。
  source <(sed -n '/^check_orphan_nginx()/,/^}/p' '$ROOT/conf/node.sh')
  py() { python3 \"\$@\"; }
  info() { :; }; ok() { echo OK:\$*; }; warn() { echo WARN:\$*; }; err() { echo ERR:\$*; }
  check_orphan_nginx" 2>&1)
# ★ nginx 跑在容器里时, site_files() 走的是**容器内**的站点目录, NGINX_CONF_ROOTS
#   指的临时目录根本不会被看 —— 夹具里造的孤儿站点必然查不到, 三条断言一起假红。
#   这是夹具在这种机器上不成立, 不是被测代码坏了, 所以要显式跳过而不是假装通过。
NG_DOCKERED=$(python3 -c "
import sys; sys.path.insert(0,'$LIB')
import nginx_apply as N
print('yes' if N.probe_docker() else 'no')" 2>/dev/null)
if [[ "$NG_DOCKERED" == "yes" ]]; then
    ok "孤儿片段夹具 (本机 nginx 在容器里, 站点探测走容器分支, 夹具不适用)"
else
    echo "$NO" | grep 'orphan.example.com' >/dev/null && ok "查出孤儿片段 (会报出域名)" || bad "没查出孤儿片段"
    echo "$NO" | grep '502' >/dev/null && ok "告警里说明了后果 (CDN 回源 502)" || bad "告警没说清后果"
    echo "$NO" | grep '没有发现' >/dev/null && bad "明明有孤儿却报'没有发现'" || ok "没有误报"
fi
# ★ 下面两个夹具 (备份文件 / 空目录) 用的是**宿主机站点目录**那条路。
#   本机 nginx 真跑在容器里时, 站点探测会走容器分支, NGINX_CONF_ROOTS 指的
#   临时目录根本不会被看 —— 夹具于是读到了**真实站点**, 断言变成在测生产环境,
#   而它随时会因为线上多了一个段而假红 (实测: 全协议建了个分离节点之后,
#   这两条立刻变红, 报的还是生产站点的内容)。
#   这与上面那条夹具是同一件事, 所以用同一个 NG_DOCKERED 判据显式跳过,
#   不假装通过、也不让它去测别的东西。
if [[ "$NG_DOCKERED" == "yes" ]]; then
    ok "备份文件/空目录夹具 (本机 nginx 在容器里, 宿主机站点目录不是生效的那份, 夹具不适用)"
else
# ★ nginx **不会加载**的文件里留着标记, 不能算孤儿。
#   现场: 站点文件旁边躺着 *.xray-core-bak / *.mihomo-core-cdn-bak 等备份,
#   里面同样带着标记; `grep -r` 扫目录会把它们算进来 —— 报出一堆并不存在的
#   孤儿 (站点里其实干干净净), 用户按提示去删只会更糊涂。
NG_BAK="$TMP/ngbak"; mkdir -p "$NG_BAK/conf.d"
printf 'server {\n    server_name bak.example.com;\n    # >>> xray-core BEGIN bak.example.com >>>\n}\n' \
    > "$NG_BAK/conf.d/bak.example.com.conf.xray-core-bak"
printf 'server {\n    server_name bak.example.com;\n    # >>> xray-core BEGIN bak.example.com >>>\n}\n' \
    > "$NG_BAK/conf.d/notes.yaml"
NB=$(NGINX_CONF_ROOTS="$NG_BAK/conf.d" bash -c "
  LIB_DIR='$ROOT/conf/lib'
  source <(sed -n '/^check_orphan_nginx()/,/^}/p' '$ROOT/conf/node.sh')
  py() { python3 \"\$@\"; }
  info() { :; }; ok() { echo OK:\$*; }; warn() { echo WARN:\$*; }; err() { echo ERR:\$*; }
  check_orphan_nginx" 2>&1)
echo "$NB" | grep '没有发现' >/dev/null && ok "备份/非 .conf 文件里的标记不算孤儿" \
    || bad "把 nginx 不加载的备份文件当成了孤儿: $NB"
# 空目录 -> 必须报"没有发现", 不能凭空造出孤儿
mkdir -p "$NG_T/empty"
NE=$(XRAY_BASE="$NG_T" NGINX_CONF_ROOTS="$NG_T/empty" bash -c "
  LIB_DIR='$ROOT/conf/lib'
  source <(sed -n '/^check_orphan_nginx()/,/^}/p' '$ROOT/conf/node.sh')
  py() { python3 \"\$@\"; }
  info() { :; }; ok() { echo OK:\$*; }; warn() { echo WARN:\$*; }; err() { echo ERR:\$*; }
  check_orphan_nginx" 2>&1)
echo "$NE" | grep '没有发现' >/dev/null && ok "无片段时如实报告 (不凭空造孤儿)" || bad "无片段时报告不正确"
fi
# ★ nginx 真跑在容器里时, 生效的站点只在**容器里**。旧的实现 grep 宿主机目录,
#   宿主 conf.d 恰好是空的时候会报"没有发现"—— 假绿, 而站点里一堆孤儿。
#   这里给一个假 docker + 假容器目录, 断言容器里的标记查得到。
NG_DK="$TMP/ngdk"; mkdir -p "$NG_DK/bin" "$NG_DK/ctr/conf.d"
cat > "$NG_DK/ctr/conf.d/docker.example.com.conf" <<'NGE'
server {
    server_name docker.example.com;
    # >>> xray-core BEGIN docker.example.com >>>
    location /d { proxy_pass http://127.0.0.1:19998; }
    # <<< xray-core END docker.example.com <<<
}
NGE
cat > "$NG_DK/bin/docker" <<NGE
#!/bin/bash
# 假 docker: 与"容器共处"那一组同一个套路 —— 把容器内 /etc/nginx 映射到
# 夹具目录, 这样 site_files / cat 都能走通。
#   · exec -i 必须先摘掉, 否则后面的参数全部错位
#   · sh -c 后面的 \$@ 要一起传下去
if [[ "\$1" == "ps" ]]; then printf 'nginx\tnginx:alpine\n'; exit 0; fi
[[ "\$1" == "exec" ]] || exit 1
shift
while [[ "\${1:-}" == "-i" ]]; do shift; done
shift  # 容器名
if [[ "\${1:-}" == "sh" && "\${2:-}" == "-c" ]]; then
    script="\$3"; shift 3
    exec sh -c "\$(printf '%s' "\$script" | sed 's#/etc/nginx#$NG_DK/ctr#g')" "\$@"
fi
if [[ "\${1:-}" == "cat" ]]; then exec cat "\${2//\\/etc\\/nginx/$NG_DK/ctr}"; fi
exit 1
NGE
chmod +x "$NG_DK/bin/docker"
ND=$(PATH="$NG_DK/bin:$PATH" bash -c "
  LIB_DIR='$ROOT/conf/lib'
  source <(sed -n '/^check_orphan_nginx()/,/^}/p' '$ROOT/conf/node.sh')
  py() { python3 \"\$@\"; }
  info() { :; }; ok() { echo OK:\$*; }; warn() { echo WARN:\$*; }; err() { echo ERR:\$*; }
  check_orphan_nginx" 2>&1)
echo "$ND" | grep 'docker.example.com' >/dev/null && ok "容器里的站点也扫得到 (不再只 grep 宿主目录)" \
    || bad "容器里的孤儿片段漏掉了 (宿主目录为空就报'没有发现'): $ND"

# ---------------------------------------------------------------- 地址族判定
# 守的是"向导告诉用户有没有 IPv6"这件事。旧写法两处不对称:
#   x_has_v4 直接 `ip -4 addr show | grep inet` —— 只有 awg0(10.66.66.1) 的
#     机器会被判成"有 IPv4", 而那个地址客户端连不上;
#   x_has_v6 排除了隧道, 两者口径不一致。
# 实测场景: 机器只有 WARP 的 IPv6 时, 旧写法说"有 IPv6", 向导于是引导用户
# 去建 IPv6 节点 —— 建出来的节点谁也连不上。
group "地址族判定 (addr.sh)"
AD="$ROOT/conf/lib/addr.sh"
# 判据必须收在一处: x_has_v4 / x_has_v6 都走 _x_addr_pick, 而隧道过滤
# (X_TUNNEL_IFACE_RE) 与逐接口判定都在 _x_addr_pick 里。
# 旧写法这两个函数各写一份循环, 于是同一个坑要修两遍, 还修得不一致。
_pick_body=$(sed -n "/^_x_addr_pick()/,/^}/p" "$AD")
echo "$_pick_body" | grep 'X_TUNNEL_IFACE_RE' >/dev/null \
    && ok "_x_addr_pick 排除隧道接口 (地址族判定与取地址共用同一判据)" \
    || bad "_x_addr_pick 没有排除隧道接口 —— 只有 WARP 的机器会被误判成'有'"
echo "$_pick_body" | grep -E 'read -r dev cidr' >/dev/null \
    && ok "_x_addr_pick 逐接口判定 (不是整表 grep 一下就算)" \
    || bad "_x_addr_pick 没有逐接口判定"
for fn in x_has_v4 x_has_v6; do
    body=$(sed -n "/^${fn}()/,/^}/p" "$AD")
    echo "$body" | grep '_x_addr_pick' >/dev/null \
        && ok "$fn 走统一判定 (_x_addr_pick)" \
        || bad "$fn 没有走统一判定 —— 又出现了第二份实现"
done
# 空/异常输入下不能崩
got=$(bash -c "source '$AD'; x_has_v4 >/dev/null 2>&1; echo rc=\$?")
[[ "$got" =~ ^rc=[01]$ ]] && ok "x_has_v4 返回 0/1 而不是崩掉" || bad "x_has_v4 异常: $got"

# ---------------------------------------------------------------- 对外地址取值
# 守的是"分享链接里的地址客户端连不连得上"。三个实测现场:
#   · RN 上 WARP 开着, 取到的是 WARP 出口 104.28.201.80 (客户端连不上),
#     真实入口是 eth0 上的 107.173.154.178;
#   · 多网卡机器上"枚举里第一个"不一定是默认路由那张网卡;
#   · 存量的 WARP 地址如果只判"在不在本机接口上", 会被一直沿用 (warp 网卡
#     上的地址**确实**在本机)。
# 用一个假 `ip` 把这些场景钉死 —— 真机上跑门禁时结果取决于本机网卡, 测不了。
group "对外地址取值 (addr.sh)"
FB="$TMP/fakeip"; mkdir -p "$FB"
cat > "$FB/ip" <<'FIPE'
#!/usr/bin/env bash
# 场景: 枚举顺序里 eth0(私网) 在前, 真实出口在 eth1; warp/docker 都在;
#       默认路由走 eth1 / he-ipv6 —— 与 RN 的形状一致 (warp 上挂着公网 v6)。
case "$*" in
  "-4 route show default") echo "default via 203.0.113.1 dev eth1 proto static";;
  "-6 route show default") echo "default via 2001:db8::1 dev he-ipv6 proto static";;
  *"-4 addr show scope global"*)
      echo "2: eth0    inet 10.0.0.5/24 scope global eth0"
      echo "3: eth1    inet 8.8.8.8/32 scope global eth1"
      echo "4: warp    inet 172.16.0.2/32 scope global warp"
      echo "5: docker0 inet 172.17.0.1/16 scope global docker0";;
  *"-6 addr show scope global"*)
      echo "3: eth1    inet6 2a01:4f8:c17::1/64 scope global"
      echo "4: warp    inet6 2606:4700:110::1/128 scope global";;
  *"addr show scope global"*)
      echo "2: eth0    inet 10.0.0.5/24 scope global eth0"
      echo "3: eth1    inet 8.8.8.8/32 scope global eth1"
      echo "4: warp    inet 172.16.0.2/32 scope global warp"
      echo "3: eth1    inet6 2a01:4f8:c17::1/64 scope global"
      echo "4: warp    inet6 2606:4700:110::1/128 scope global";;
  *"addr show"*)
      echo "1: lo    inet 127.0.0.1/8 scope host lo"
      echo "3: eth1  inet 8.8.8.8/32 scope global eth1"
      echo "4: warp  inet 172.16.0.2/32 scope global warp"
      echo "4: warp  inet6 2606:4700:110::1/128 scope global";;
  *) echo "FAKE-IP-UNHANDLED: $*" >&2; exit 1;;
esac
FIPE
chmod +x "$FB/ip"
fip() { PATH="$FB:$PATH" bash -c "source '$AD'; $1"; }
got=$(fip 'x_default_route_iface')
assert_eq "$got" "eth1" "默认路由网卡优先 (不是枚举里第一个 eth0)"
got=$(fip 'x_addr4_real')
assert_eq "$got" "8.8.8.8" "真实 IPv4 = 默认路由网卡上的地址 (不是私网 eth0)"
got=$(fip 'x_addr6_real')
assert_eq "$got" "2a01:4f8:c17::1" "真实 IPv6 排除 warp 上的公网 v6"
got=$(fip 'x_iface_public_addr')
assert_eq "$got" "8.8.8.8" "对外地址 v4 优先"
got=$(fip 'x_has_v4 && echo Y || echo N')
assert_eq "$got" "Y" "有 IPv4"
got=$(fip 'x_has_v6 && echo Y || echo N')
assert_eq "$got" "Y" "有 IPv6"
# warp 上的地址【在本机接口上】, 但客户端连不上 —— 两档判定必须分开
got=$(fip 'x_addr_is_local 172.16.0.2 && echo Y || echo N')
assert_eq "$got" "Y" "warp 地址确实在本机接口上 (x_addr_is_local)"
got=$(fip 'x_addr_is_reachable 172.16.0.2 && echo Y || echo N')
assert_eq "$got" "N" "同一地址判定为客户端连不上 (x_addr_is_reachable)"
# ★ 关键回归: 存量 WARP 地址 (env 里存的那个) 不能被沿用
got=$(fip 'x_public_addr "" 172.16.0.2')
assert_eq "$got" "8.8.8.8" "存量的 WARP v4 地址不被沿用, 换回网卡地址"
got=$(fip 'x_public_addr "" 2606:4700:110::1')
assert_eq "$got" "8.8.8.8" "存量的 WARP v6 地址不被沿用 (只判'在本机'会漏掉这个)"
got=$(fip 'x_link_addr 172.16.0.2')
assert_eq "$got" "8.8.8.8" "分享链接入口 x_link_addr 同样不沿用 WARP 地址"
got=$(fip 'x_public_addr 9.9.9.9')
assert_eq "$got" "9.9.9.9" "显式传参仍然最优先"
got=$(fip 'XRAY_PUBLIC_IP=1.2.3.4 x_link_addr 172.16.0.2')
assert_eq "$got" "1.2.3.4" "XRAY_PUBLIC_IP 覆盖一切"

# ★ install_info.env 的写入方: 链接地址的来源必须是网卡, 不是"我的 IP"服务。
#   旧实现是 `curl api.ipify.org` —— 套了 WARP 时那是**出站出口**地址,
#   写进去之后所有分享链接跟着错。这里让假 curl 返回一个 WARP 地址,
#   断言最终落到 env 里的是网卡地址。
group "对外地址写入 (XRevise.sh → install_info.env)"
XA="$TMP/xrev"; mkdir -p "$XA/xray" "$XA/lib"
cp "$AD" "$XA/lib/addr.sh"
# 假 curl: 外部服务只会答 WARP 出口地址 (真实场景就是这样)
mkdir -p "$XA/bin"
cat > "$XA/bin/curl" <<'CURLX'
#!/usr/bin/env bash
echo "104.28.201.80"
CURLX
chmod +x "$XA/bin/curl"
# 只取"地址库加载 + usid()"两块拼成夹具: 整脚本会生成密钥并写生产路径,
# 不能在测试里执行。INSTALL_DIR/ENV_FILE 换成夹具目录, 其余逻辑逐字保留。
# 用 { } > file 逐段拼, 不走 heredoc 展开 —— 被抽出来的代码里也有 $(...),
# 放进未加引号的 heredoc 会在生成阶段就被外层 shell 展开掉。
{
    echo 'set -u'
    printf 'INSTALL_DIR=%q\n' "$XA/xray"
    echo 'ENV_FILE="$INSTALL_DIR/install_info.env"'
    echo 'xrayls_DTR=/dev/null'
    sed -n '/^# -* 地址库$/,/^fi$/p' "$ROOT/conf/XRevise.sh"
    echo 'update_env() { printf "%s=\"%s\"\n" "$1" "$2" >> "$ENV_FILE"; }'
    echo 'print_info() { echo "[Info] $*"; }'
    echo 'print_warn() { echo "[Warn] $*"; }'
    echo 'print_error() { echo "[Error] $*"; }'
    sed -n '/^usid()/,/^}/p' "$ROOT/conf/XRevise.sh"
    echo 'mkdir -p "$INSTALL_DIR"'
    echo 'usid >/dev/null 2>&1'
} > "$XA/run.sh"
PATH="$FB:$XA/bin:$PATH" bash "$XA/run.sh" </dev/null >/dev/null 2>&1
got=$(grep -E '^(PUBLIC_IP|link_ip)=' "$XA/xray/install_info.env" 2>/dev/null | awk 'NR<=2' | tr '\n' ' ')
case "$got" in
  *'8.8.8.8'*) ok "env 里写的是网卡地址 (外部的 WARP 地址没被采信): $got" ;;
  *) bad "env 里的地址来源不对: $got" ;;
esac
case "$got" in
  *104.28.201.80*) bad "env 里写进了外部服务的 WARP 出口地址: $got" ;;
  *) ok "env 里没有 WARP 出口地址" ;;
esac
# 只有私网地址 (NAT 机器) 时: 网卡上确实没有可直连地址, 这时才允许退回外部
# 探测 —— 但必须**明确告警**, 不能静默用"世界看到的我"。
XN="$TMP/xrevnat"; mkdir -p "$XN/xray" "$XN/lib" "$XN/bin"
cp "$AD" "$XN/lib/addr.sh"
cat > "$XN/bin/ip" <<'IPNAT'
#!/usr/bin/env bash
case "$*" in
  *"route show default"*) exit 1;;
  *"-4 addr show scope global"*) echo "2: eth0 inet 10.0.0.5/24 scope global eth0";;
  *"addr show"*) echo "2: eth0 inet 10.0.0.5/24 scope global eth0";;
  *) exit 1;;
esac
IPNAT
cat > "$XN/bin/curl" <<'CURLN'
#!/usr/bin/env bash
echo "104.28.201.80"
CURLN
chmod +x "$XN/bin/ip" "$XN/bin/curl"
{
    echo 'set -u'
    printf 'INSTALL_DIR=%q\n' "$XN/xray"
    echo 'ENV_FILE="$INSTALL_DIR/install_info.env"'
    echo 'xrayls_DTR=/dev/null'
    sed -n '/^# -* 地址库$/,/^fi$/p' "$ROOT/conf/XRevise.sh"
    echo 'update_env() { printf "%s=\"%s\"\n" "$1" "$2" >> "$ENV_FILE"; }'
    echo 'print_info() { echo "[Info] $*"; }'
    echo 'print_warn() { echo "[Warn] $*"; }'
    echo 'print_error() { echo "[Error] $*"; }'
    sed -n '/^usid()/,/^}/p' "$ROOT/conf/XRevise.sh"
    echo 'mkdir -p "$INSTALL_DIR"'
    echo 'usid'
} > "$XN/run.sh"
NATOUT=$(PATH="$XN/bin:$PATH" bash "$XN/run.sh" </dev/null 2>&1)
echo "$NATOUT" | grep 'Warn.*104.28.201.80' >/dev/null && ok "只有私网地址时退回外部探测并明确告警" \
    || bad "退回外部探测时没有告警: $NATOUT"

# ---------------------------------------------------------------- 内核回退
# 守的是"更新内核失败后能不能退回去"。更新是不可逆操作里最容易出事的一个:
# 新版可能改了配置语义(本项目已踩过 allowInsecure / proxySettings / 旧版
# reverse 被移除), 更新完服务起不来, 而原来的二进制已经被覆盖 —— 官方安装
# 脚本**不留备份**, 所以备份必须我们自己留。
group "内核回退 (bin/xray_install.sh)"
RB="$TMP/rollback"; mkdir -p "$RB/bin"
# 只抽"备份/回退"那一块来测 —— 整脚本会执行完整安装流程, 不能在测试里 source
sed -n '/^# 内核备份 \/ 回退/,/^case "\${1:-}" in/,/^esac/p' "$ROOT/bin/xray_install.sh" \
    > "$RB/block.sh" 2>/dev/null
# 退而求其次: 用行号区间 (块以 CORE_BACKUP_KEEP 开头、以 esac 结尾)
awk '/^CORE_BACKUP_KEEP=/{f=1} f{print} /^esac$/{if(f){exit}}' "$ROOT/bin/xray_install.sh" > "$RB/block.sh"
[[ -s "$RB/block.sh" ]] && ok "抽出备份/回退块 ($(wc -l < "$RB/block.sh") 行)" || bad "抽不出备份/回退块"
# 块里必须真的包含三个能力
for fn in backup_current_core list_core_backups rollback_core; do
    grep -q "^${fn}()" "$RB/block.sh" && ok "包含 $fn" || bad "缺少 $fn"
done
# ★ 回退前必须把"当前"版本也备份 —— 否则回退选错版本就再也回不来了
grep -q 'backup_current_core >/dev/null 2>&1' "$RB/block.sh" \
    && ok "rollback_core 在替换前备份当前版本 (回退本身可逆)" \
    || bad "rollback_core 没有先备份当前版本 —— 回退选错就回不来了"
# ★ 回退后只做校验、**不自动重启** —— 让用户决定什么时候切
# 只找**真正的调用**(行首命令), 不找提示文案里那句
# "确认无误后再重启：systemctl restart ..." —— 那句话是故意留的, 要告诉用户
# 怎么切。用 'systemctl restart' 直接 grep 会把文案也算进去 (实测误报过一次)。
if sed -n '/^rollback_core()/,/^}/p' "$RB/block.sh" | grep -E '^[[:space:]]*systemctl[[:space:]]+restart' >/dev/null; then
    bad "rollback_core 会自动重启服务 (应只校验, 让用户决定)"
else
    ok "rollback_core 只做校验不自动重启 (文案里的提示命令不算调用)"
fi
# ★ 参数分派必须**当场**退出: 否则回退失败也会报成功, 或者先打印一堆安装步骤
grep -q 'rollback)     rollback_core "${2:-}"; exit \$? ;;' "$RB/block.sh" \
    && ok "rollback 分支当场 exit \$? (状态码不被后续判断覆盖)" \
    || bad "rollback 分派没有当场退出"
grep -q 'list-backups) list_core_backups;      exit \$? ;;' "$RB/block.sh" \
    && ok "list-backups 分支当场退出" || bad "list-backups 分派没有当场退出"
# 块里不能出现安装步骤的输出 —— 否则 rollback 时会打印 "[1/6] 检查系统"
if grep -q '^section "' "$RB/block.sh"; then
    bad "备份/回退块里有 section 调用 (rollback 会打印安装步骤)"
else
    ok "备份/回退块不含安装步骤输出"
fi
# 实跑: 空目录下的行为
RBIN="$RB/xrayls"; printf '#!/bin/sh\necho "Xray 1.2.3"\n' > "$RBIN"; chmod +x "$RBIN"
RR=$(BIN="$RBIN" CORE_BACKUP_DIR="$RB/backup" bash -c "
  print_info(){ echo INFO:\$*; }; print_warn(){ echo WARN:\$*; }; print_error(){ echo ERR:\$*; }
  source '$RB/block.sh' 2>/dev/null || true
  list_core_backups
  rollback_core 99.9.9 >/dev/null 2>&1; echo rc=\$?" 2>&1)
echo "$RR" | grep '还没有内核备份' >/dev/null && ok "空目录时如实报告 (不假装有备份)" || bad "空目录时报告不正确"
echo "$RR" | grep 'rc=1' >/dev/null && ok "回退不存在的版本返回非 0" || bad "回退不存在的版本没报错"

# ---------------------------------------------------------------- 预置推荐档
# 守的是"推荐配置是不是当前官方方向"。官方已把 websocket / grpc /
# httpupgrade 标为**非移除型弃用**并指定迁移到 XHTTP, 且 XHTTP 是官方主推
# (没有 WS 那种 "ALPN 是 http/1.1" 的显著特征)。所以"CDN 友好"这一档的
# 推荐必须是 XHTTP —— 原来推的是 WS, 等于把人往弃用方向上带。
group "预置推荐档 (preset.sh)"
# ★ 按**显示名**找那一档, 不写死序号。
#   原来这里写死 "vless 第 2 档 / vmess 第 1 档", 于是每给预置表加一档、
#   重排一次编号, 这条门禁就变成测"第 2 档是不是 xhttp" —— 测的已经不是
#   它想测的东西了, 而是"谁改了编号"。意图是"CDN 友好档必须是 XHTTP"。
preset_index_by_name() {   # <协议> <名字片段>
    local p="$1" frag="$2" i cnt
    cnt=$(bash -c "source '$LIB/preset.sh'; x_preset_count $p" 2>/dev/null)
    for (( i=1; i<=cnt; i++ )); do
        if [[ "$(bash -c "source '$LIB/preset.sh'; x_preset_field $p $i 4" 2>/dev/null)" == *"$frag"* ]]; then
            printf '%s' "$i"; return 0
        fi
    done
    return 1
}
# 非空断言 —— 定位不到就是预置表本身缺了一档, 要报出来而不是让后面的用例连锁假红
assert_ne0() {
    [[ -n "$1" && "$1" != "0" ]] && ok "$2" || bad "$2 [得到 '${1:-空}']"
}
for proto in vless trojan vmess; do
    idx=$(preset_index_by_name "$proto" "CDN 友好")
    [[ -z "$idx" ]] && { bad "$proto 的 CDN 推荐档是 XHTTP (不是已弃用的 WS) [找不到 CDN 友好档]"; continue; }
    sec=$(bash -c "source '$LIB/preset.sh'; x_preset_field $proto $idx 2" 2>/dev/null)
    assert_eq "$sec" "xhttp" "$proto 的 CDN 推荐档是 XHTTP (不是已弃用的 WS)"
done
# 弃用的传输必须仍在表里 (兼容老节点), 但说明里要写明官方弃用
for proto_tr in "vless|ws" "vless|grpc" "vless|httpupgrade" "trojan|ws" "vmess|ws"; do
    pr="${proto_tr%%|*}"; tr="${proto_tr##*|}"
    body=$(grep -E "^\s*\"$pr\|$tr\|" "$LIB/preset.sh" | awk 'NR==1')
    echo "$body" | grep '弃用' >/dev/null \
        && ok "$pr + $tr 仍在表里且标注了官方弃用" \
        || bad "$pr + $tr 没标注官方弃用 (用户看不出它正在被淘汰)"
done
# 编号必须连续: 插档之后最容易出现的错就是两个 ③
for proto in vless trojan vmess shadowsocks; do
    nums=$(grep -oE "^\s*\"$proto\|[^|]*\|[^|]*\|[①②③④⑤⑥⑦⑧⑨]" "$LIB/preset.sh" | grep -oE '[①②③④⑤⑥⑦⑧⑨]$' | tr '\n' ' ')
    want=""
    i=0
    for c in ① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨; do
        want="$want$c "
    done
    n=$(echo "$nums" | wc -w)
    first=$(echo "$nums" | awk '{print $1}')
    assert_eq "$first" "①" "$proto 编号从 ① 开始"
    # 末尾编号应与条数一致
    last=$(echo "$nums" | awk '{print $NF}')
    idx=0; j=0
    for c in ① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨; do
        j=$((j+1)); [[ "$c" == "$last" ]] && idx=$j
    done
    assert_eq "$idx" "$n" "$proto 编号连续无重复 (共 $n 档, 末位 $last)"
done

# ---------------------------------------------------------------- 地址族批量切换
# 守的是"一键换对外地址时: 本机的换掉, 不是本机的一个字都不动"。
#
# ★★ 这组夹具是本项目最重要的一条回归线。
#   share_meta.host 是分享链接与客户端配置里"连哪个地址"的唯一来源。
#   旧实现是**无条件把所有 host 写成新地址**, 于是两件事会静默发生:
#     · 走 CDN 的节点 —— host 本来是 cdn.example.com, 被写成源站 IP,
#       CDN 白嫖没了, 而链接**看起来完全正常**, 用户只发现"好像没走 CDN";
#     · 中转/他机的地址 —— 被改成本机地址, 那个节点直接连不上。
#   这就是用户报的"换 IP 时会把 CDN 的域名也换成 IP"。
#   所以 n3 (他机 IP) / n4 (CDN 域名) / n5 (同族但非本机) 必须**保持原样**,
#   只有 n1/n2 (本机地址) 才允许被替换。
#   老断言要求"全部改成同一个值、host 收敛成一个" —— 守的正是上面这个 bug。
group "地址族批量切换 (share.sh)"
AF="$TMP/afam"; rm -rf "$AF"; mkdir -p "$AF/share"
python3 - "$LIB" "$AF/share" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import share_meta
d = sys.argv[2]
for t, h in (("n1", "2001:db8::1"),       # 本机 IPv6     -> 应改成 9.9.9.9
             ("n2", "2001:db8::1"),       # 同上, 验证"别漏节点"
             ("n3", "2.2.2.2"),           # 他机 IPv4     -> 必须原样不动
             ("n4", "cdn.example.com"),   # CDN 域名      -> 必须原样不动
             ("n5", "2001:db8::99")):     # 同族但非本机  -> 必须原样不动
    share_meta.save(d, t, {"host": h, "port": 443, "name": t, "tier": "cdn"})
PY
sed -n '/^x_switch_addr_family()/,/^}/p' "$ROOT/conf/share.sh" > "$AF/fn.sh"
[[ -s "$AF/fn.sh" ]] && ok "抽到 x_switch_addr_family ($(wc -l < "$AF/fn.sh") 行)" || bad "抽不到函数"
grep -q 'x_addr6_real' "$AF/fn.sh" && ok "IPv6 走 x_addr6_real (排除隧道)" \
    || bad "IPv6 没走 addr.sh —— 会拿到 WARP 地址"
# ★ 用 x_addr4_real 而不是 x_iface_public_addr: 后者优先给 v4, 但机器只有 v6 时
#   **会返回 v6**, 旧实现只好在后面补一句 `[[ "$newip" == *:* ]] && newip=""`
#   兜底。x_addr4_real 本身就按族过滤, 那句补丁可以去掉。
grep -q 'x_addr4_real' "$AF/fn.sh" && ok "IPv4 走 x_addr4_real (按族过滤, 不会拿到 IPv6)" \
    || bad "IPv4 没走 addr.sh"
# 白名单是这次修复的核心, 缺了就等于退回无条件替换
grep -q 'x_local_addrs' "$AF/fn.sh" && ok "改写走**本机地址白名单** (x_local_addrs)" \
    || bad "没有本机地址白名单 —— 会把 CDN 域名/他机地址一起改掉"
grep -q 'share_refresh_all' "$AF/fn.sh" && ok "切完刷新已发链接 (内容里嵌着地址)" \
    || bad "切完没刷新 —— 令牌里还是老地址而面板显示正常"

# 实跑: 桩掉地址函数与 addr.sh, 验证真的改了 share_meta。
# ★ 桩和被测函数都放在独立脚本文件里 —— 别内联进 `bash -c "…"`:
#   双引号里的 $(...) 与 {} 会被外层 bash 先解析一遍, 结果是
#   "syntax error near unexpected token" 加上一串 unbound variable,
#   而且**污染后面的测试** (实测: 分享链接生成那一组因此全部失败)。
cat > "$AF/drive.sh" <<'DRV'
set -u
SHARE_DIR="$1"; LIB_DIR="$2"; FN="$3"; WANT="$4"
# ★ 被测函数用的是 `python` 而不是 `python3` —— share.sh 顶部有一行
#   `python() { command python3 "$@"; }` 的包装, 而这里只抽了函数体,
#   没有那行包装。漏掉它的表现是 python: command not found 被 2>/dev/null
#   吞掉, 于是"切换 0 个节点"而看不出任何原因。
python() { command python3 "$@"; }
err()  { echo "ERR: $*"; }
# ★ info 必须真的打出来: "哪些节点没改、为什么没改" 是这次修复的重点之一,
#   桩成 `:` 就等于把这道断言自己废掉了 (测试全绿而功能没有)。
info() { echo "INFO: $*"; }
ok()   { echo "OK: $*"; }
warn() { :; }
share_refresh_all() { :; }
# 本机: v4=9.9.9.9, v6=2001:db8::1。白名单只认 2001:db8::1。
x_addr4_real()     { echo "9.9.9.9"; }
x_addr6_real()     { echo "2001:db8::1"; }
x_local_addrs()    { case "$1" in v6) echo "2001:db8::1" ;; v4) echo "9.9.9.9" ;; esac; }
x_addr_family_of() { case "$1" in *:*) echo IPv6 ;; *) echo IPv4 ;; esac; }
# shellcheck disable=SC1090
source "$FN"
x_switch_addr_family "$WANT"
SHARE_DIR="$SHARE_DIR" python3 - <<'PYP'
import glob, json, os
d = os.environ["SHARE_DIR"]
recs = {os.path.basename(f)[:-5]: json.load(open(f)).get("host")
        for f in glob.glob(os.path.join(d, "*.json"))}
for k in ("n1", "n2", "n3", "n4", "n5"):
    print("%s=%s" % (k, recs.get(k)))
PYP
DRV
AFR=$(bash "$AF/drive.sh" "$AF/share" "$LIB" "$AF/fn.sh" v4 2>&1)
# 切 v4: 白名单是本机 v6 侧, 所以 2001:db8::1 被换成 9.9.9.9; 其余三个一律不动。
assert_eq "$(echo "$AFR" | grep '^n1=')" "n1=9.9.9.9"         "v4 切换: 本机地址已改"
assert_eq "$(echo "$AFR" | grep '^n2=')" "n2=9.9.9.9"         "v4 切换: 同地址的第二个节点也改了 (没漏)"
assert_eq "$(echo "$AFR" | grep '^n3=')" "n3=2.2.2.2"         "v4 切换: 他机 IP 原样保留"
assert_eq "$(echo "$AFR" | grep '^n4=')" "n4=cdn.example.com" "v4 切换: CDN 域名原样保留 (这就是那个 bug)"
assert_eq "$(echo "$AFR" | grep '^n5=')" "n5=2001:db8::99"    "v4 切换: 同族但非本机的地址原样保留"
echo "$AFR" | grep '已切换 2 个节点' >/dev/null && ok "报告了改动的节点数 (2 个, 只数本机地址)" \
    || bad "改动条数不对: $(echo "$AFR" | grep 已切换 || echo 无输出)"
# 没动的那些要**逐条说清**, 否则用户以为"切了但没生效"
# ★ 不用 `grep -q`: 它会让上游 echo 吃 SIGPIPE(141), 在 pipefail 下炸掉整条断言。
echo "$AFR" | grep '保留未改' >/dev/null && ok "逐条报告了没改的节点及原因" || bad "没报告哪些节点没改"

# 反方向: 切 v6 时白名单换到 v4 侧 —— 这正是 RN 上的真实方向
# (节点默认发的是 v4 107.173.154.178, 用户想改发 he-ipv6)。
cat > "$AF/drive6.sh" <<'DRV'
set -u
SHARE_DIR="$1"; LIB_DIR="$2"; FN="$3"
python() { command python3 "$@"; }
err()  { echo "ERR: $*"; }
info() { :; }
ok()   { echo "OK: $*"; }
warn() { :; }
share_refresh_all() { :; }
x_addr4_real()     { echo "9.9.9.9"; }
x_addr6_real()     { echo "2001:db8::1"; }
x_local_addrs()    { case "$1" in v6) echo "2001:db8::1" ;; v4) echo "9.9.9.9" ;; esac; }
x_addr_family_of() { case "$1" in *:*) echo IPv6 ;; *) echo IPv4 ;; esac; }
# shellcheck disable=SC1090
source "$FN"
x_switch_addr_family v6
SHARE_DIR="$SHARE_DIR" python3 - <<'PYP'
import glob, json, os
d = os.environ["SHARE_DIR"]
recs = {os.path.basename(f)[:-5]: json.load(open(f)).get("host")
        for f in glob.glob(os.path.join(d, "*.json"))}
for k in ("n3", "n4", "n5"):
    print("%s=%s" % (k, recs.get(k)))
PYP
DRV
AF6=$(bash "$AF/drive6.sh" "$AF/share" "$LIB" "$AF/fn.sh" 2>&1)
# 白名单是本机 v4 (9.9.9.9): 上一轮已把它改成 9.9.9.9, 这一轮应换成 v6;
# 他机 IP、CDN 域名、同族非本机 三个仍然一动不动。
assert_eq "$(echo "$AF6" | grep '^n3=')" "n3=2.2.2.2"         "v6 切换: 他机 IP 原样保留"
assert_eq "$(echo "$AF6" | grep '^n4=')" "n4=cdn.example.com" "v6 切换: CDN 域名原样保留"
assert_eq "$(echo "$AF6" | grep '^n5=')" "n5=2001:db8::99"    "v6 切换: 同族但非本机的地址原样保留"

# 非法参数必须拒绝
cat > "$AF/drive2.sh" <<'DRV'
set -u
SHARE_DIR="$1"; LIB_DIR="$2"; FN="$3"
python() { command python3 "$@"; }
err()  { echo "ERR: $*"; }
info() { :; }
ok()   { echo "OK: $*"; }
warn() { :; }
share_refresh_all() { :; }
x_addr4_real()     { echo "9.9.9.9"; }
x_addr6_real()     { echo "2001:db8::1"; }
x_local_addrs()    { :; }
x_addr_family_of() { echo IPv4; }
# shellcheck disable=SC1090
# shellcheck disable=SC1090
source "$FN"
x_switch_addr_family bogus
echo "rc=$?"
DRV
AFB=$(bash "$AF/drive2.sh" "$AF/share" "$LIB" "$AF/fn.sh" 2>&1)
echo "$AFB" | grep 'rc=1' >/dev/null && ok "非法地址族返回非 0" || bad "非法地址族没被拒绝"


# ---------------------------------------------------------------- 分享默认值与有效期
# 用户原话: 「默认值，默认值为 1 和 24 个小时。你应该借鉴 SB 内核的方式」
# → max_uses 默认 1 次、ttl 默认 24 **小时**, 且有效期用编号预设而不是自由输入。
group "分享默认值与有效期 (1 次 / 24 小时, SB 式预设)"
SH="$ROOT/conf/share.sh"
# ★ 单位必须是小时。留一条"ttl_days 复活"的回归守卫: 单位一不小心改回天,
#   界面显示"24 小时"而实际发出去的是 24 天, 且**没有任何报错**。
if grep -q 'ttl_days' "$SH"; then bad "share.sh 里还有 ttl_days —— 单位被改回天了"; else
    ok "有效期统一用小时 (无 ttl_days 残留)"; fi
grep -q 'ttl_hours \* 3600' "$SH" && ok "ttl 按秒换算 (小时 × 3600)" \
    || bad "ttl 换算不是 小时 × 3600"

# 抽函数实跑: 每个编号 -> 期望小时数
sed -n '/^_share_ask_ttl()/,/^}/p' "$SH" > "$TMP/askttl.sh"
[[ -s "$TMP/askttl.sh" ]] && ok "抽到 _share_ask_ttl" || bad "抽不到 _share_ask_ttl"
cat > "$TMP/askttl_drv.sh" <<'DRV'
set -u
# ★ 颜色变量名带**前导下划线** (_CYN/_RST/_DIM …, 与 conf/lib/ui.sh 一致)。
#   写成 CYN= 的话 set -u 下直接 `unbound variable` —— 而它在 stderr 上,
#   命令替换照样把空值交出去, 断言于是变成"得到 empty=, 期望 empty=24"。
_CYN=""; _RST=""; _DIM=""; _YEL=""; _RED=""; _GRN=""; _BOLD=""
ui_invalid() { :; }
# ★ ui_ask 桩必须真的吃掉一行 —— 6) 自定义那档就靠它读第二个输入。
#   桩成"永远返回默认值"的话 custom 那条恒等于 24, 断言变成自证。
ui_ask() { local def="${2:-}" a=""; IFS= read -r a || a=""; printf '%s' "${a:-$def}"; }
# shellcheck disable=SC1090
source "$1"
printf 'empty=%s\n' "$(_share_ask_ttl </dev/null)"
for c in 1 2 3 4 5; do printf 'n%s=%s\n' "$c" "$(_share_ask_ttl <<<"$c")"; done
printf 'custom=%s\n' "$(_share_ask_ttl <<<$'6\n48')"
printf 'badthen=%s\n' "$(_share_ask_ttl <<<$'99\n2')"
DRV
TT=$(bash "$TMP/askttl_drv.sh" "$TMP/askttl.sh" 2>/dev/null)
assert_eq "$(echo "$TT" | grep '^empty=')" "empty=24"       "有效期: 直接回车 = 24 小时 (不是永久)"
assert_eq "$(echo "$TT" | grep '^n1=')"    "n1=1"           "有效期: 1) = 1 小时"
assert_eq "$(echo "$TT" | grep '^n2=')"    "n2=24"          "有效期: 2) = 24 小时"
assert_eq "$(echo "$TT" | grep '^n3=')"    "n3=168"         "有效期: 3) = 7 天 (不用心算 168)"
assert_eq "$(echo "$TT" | grep '^n4=')"    "n4=720"         "有效期: 4) = 30 天"
assert_eq "$(echo "$TT" | grep '^n5=')"    "n5=0"           "有效期: 5) = 永久"
assert_eq "$(echo "$TT" | grep '^custom=')" "custom=48"     "有效期: 6) 自定义小时数生效"
assert_eq "$(echo "$TT" | grep '^badthen=')" "badthen=24"   "有效期: 非法输入重问后仍能选 (不会退出)"

# 次数默认值 1 (原来 0 = 不限)
grep -q 'ui_ask "最多可拉取次数 (0=不限)" "1"' "$SH" \
    && ok "次数上限默认 1 次 (原来默认 0 = 不限)" \
    || bad "次数上限默认值不是 1"
# "改有效期" 菜单也必须换成小时 —— 否则新建按小时、修改按天, 单位又不一致了
if grep -q '新的有效期天数' "$SH"; then bad "「改有效期」还按天, 与新建的小时不一致"; else
    ok "「改有效期」也统一成小时"; fi

# ---------------------------------------------------------------- uTLS 指纹
group "uTLS 指纹 (10 个实测可用值)"
FP=$(bash -c 'source "'"$SH"'"; printf "%s " "${X_UTLS_FINGERPRINTS[@]}"' 2>/dev/null)
assert_eq "$FP" "chrome firefox edge safari 360 qq ios android random randomized " \
    "指纹取值与 Sing-box 实测通过的 10 个一致"
bash -c 'source "'"$SH"'"; printf "%s" "$X_DEFAULT_UTLS_FP"' 2>/dev/null | grep -qx chrome \
    && ok "默认指纹 chrome" || bad "默认指纹不是 chrome"
# 这 10 个是 sing-box 内核 check 实测过的; 被内核拒掉的那些**不许**混进来
# (混进去的症状: 面板一切正常, 客户端连不上)
for bad_fp in randomized-noalpn safari-ios ios_simulator firefox_mozilla opera chrome_v2; do
    case " $FP " in
        *" $bad_fp "*) bad "指纹列表里混进了内核不接受的 $bad_fp" ;;
        *) ok "未混入内核不接受的 $bad_fp" ;;
    esac
done

# 换指纹必须是**合并写入** —— 只改 fingerprint, 不能顺手抹掉 host / public_key。
# 抹掉 public_key 的后果: REALITY 链接立刻失效 (pbk= 没了), 而面板显示正常。
sed -n '/^share_set_fp()/,/^}/p' "$SH" > "$TMP/setfp.sh"
cat > "$TMP/setfp_drv.sh" <<'DRV'
set -u
SHARE_DIR="$1"; LIB_DIR="$2"; FN="$3"; TAG="$4"; FP="$5"
python() { command python3 "$@"; }
err()  { echo "ERR: $*"; }
ok()   { :; }
warn() { :; }
share_refresh_all() { :; }
# shellcheck disable=SC1090
source "$FN"
share_set_fp "$TAG" "$FP" >/dev/null 2>&1
SHARE_DIR="$SHARE_DIR" python3 - <<'PYP'
import json, os, sys
sys.path.insert(0, os.environ["SHARE_DIR"])
d = os.environ["SHARE_DIR"]
m = json.load(open(os.path.join(d, "t1.json")))
print("FP=" + str(m.get("fingerprint")))
print("HOST=" + str(m.get("host")))
print("PBK=" + str(m.get("public_key")))
print("PORT=" + str(m.get("port")))
PYP
DRV
FPD="$TMP/fpdata"; rm -rf "$FPD"; mkdir -p "$FPD"
python3 - "$LIB" "$FPD" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import share_meta
share_meta.save(sys.argv[2], "t1", {"host": "cdn.example.com", "port": 443,
    "public_key": "PBK-ORIGINAL", "fingerprint": "chrome", "tier": "cdn"})
PY
FPR=$(bash "$TMP/setfp_drv.sh" "$FPD" "$LIB" "$TMP/setfp.sh" t1 firefox 2>&1)
assert_eq "$(echo "$FPR" | grep '^FP=')"   "FP=firefox"          "换指纹写进了 share_meta"
assert_eq "$(echo "$FPR" | grep '^HOST=')" "HOST=cdn.example.com" "换指纹没有动 host (CDN 域名保住)"
assert_eq "$(echo "$FPR" | grep '^PBK=')"  "PBK=PBK-ORIGINAL"    "换指纹没有动 public_key (REALITY 链接不会失效)"
assert_eq "$(echo "$FPR" | grep '^PORT=')" "PORT=443"            "换指纹没有动 port"

# ★ 列数守卫: UI_PICK_ROWS 的格式是 key<TAB>字段1<TAB>…, 而 **key 不显示**,
#   所以 4 列表必须给 5 段 (key + 4 列)。少一段整张表左移一列 ——
#   节点名列显示成类型、端口列显示成指纹 —— 而表"看着有内容", 没人会发现。
#   这里按段数数一遍, 比肉眼比对渲染结果可靠。
cat > "$TMP/cols_drv.sh" <<'DRV'
set -u
_CYN=""; _RST=""; _DIM=""; _YEL=""; _RED=""; _GRN=""; _BOLD=""
SHARE_DIR="$1"; CONF_DIR="$2"; LIB_DIR="$3"; FN="$4"
python() { command python3 "$@"; }
ui_box()  { :; }; ui_pause() { :; }; ui_note() { :; }
ui_table_print() { :; }
ui_ask_num() { echo 0; return 1; }
ui_pick() { :; }
# shellcheck disable=SC1090
source "$FN"
_share_pick_node_fp
printf 'COLS=%s\n' "${#UI_PICK_COLS[@]}"
printf 'ROWS=%s\n' "$(printf '%s' "$UI_PICK_ROWS" | grep -c . )"
# 数每行的段数 (TAB 分隔)
printf '%s' "$UI_PICK_ROWS" | while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    n=1; rest="$l"
    while [[ "$rest" == *$'\t'* ]]; do n=$((n+1)); rest="${rest#*$'\t'}"; done
    printf 'FIELDS=%s\n' "$n"
done
DRV
sed -n '/^_share_pick_node_fp()/,/^}/p' "$SH" > "$TMP/pickfp.sh"
# 函数体里调用的辅助函数要一并抽出来
sed -n '/^_share_fp_rows()/,/^}/p' "$SH" >> "$TMP/pickfp.sh"
sed -n '/^_share_node_rows()/,/^}/p' "$SH" >> "$TMP/pickfp.sh"
# 夹具: 真实的 inbound 片段, 否则节点表是空的, 段数断言会假红
CFIX="$TMP/colnodes"; mkdir -p "$CFIX" "$TMP/colshare"
cat > "$CFIX/vless-01.json" <<'J'
{"inbounds":[{"tag":"vless-01","port":20001,"protocol":"vless",
  "settings":{"clients":[{"id":"u1","flow":"xtls-rprx-vision"}],"decryption":"none"},
  "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverNames":["a.com"]}}}]}
J
printf '{"inbounds":[{"tag":"ss-02","port":20002,"protocol":"shadowsocks","settings":{"method":"2022-blake3-aes-128-gcm","password":"p"},"streamSettings":{"network":"tcp","security":"none"}}]}\n' > "$CFIX/ss-02.json"
COLS=$(bash "$TMP/cols_drv.sh" "$TMP/colshare" "$CFIX" "$LIB" "$TMP/pickfp.sh" 2>/dev/null)
NC=$(echo "$COLS" | grep '^COLS=' | cut -d= -f2)
# ★ 用 `grep -m1` 而不是 `| head -1` —— 后者会让上游 grep 吃 SIGPIPE(141),
#   在 pipefail 下随机猝死 (本文件的门禁就是查这个)。
NF=$(echo "$COLS" | grep -m1 '^FIELDS=' | cut -d= -f2)
NR=$(echo "$COLS" | grep '^ROWS=' | cut -d= -f2)
assert_eq "$NR" "2"                "换指纹表格: 两个节点都进了表 (没漏行)"
assert_eq "$NF" "$(( ${NC:-0} + 1 ))" \
    "换指纹表格: 每行段数 = 列数+1 (key + 各列, 少了就整表左移)"

# ---------------------------------------------------------------- 菜单合并与交互层
group "分享服务菜单合并 + 统一交互层"
SVC="$ROOT/conf/share_service.sh"
# ui_ask_num 住在 conf/lib/ui.sh, 而 share_service.sh 原来只 source 了 print.sh
grep -q 'conf/lib/ui.sh\|/ui.sh' "$SVC" \
    && ok "share_service.sh 会加载 ui.sh (拿得到 ui_ask_num)" \
    || bad "share_service.sh 没加载 ui.sh —— ui_ask_num 不可用"
grep -q 'ui_ask_num "请选择" 0 6' "$SVC" \
    && ok "分享服务菜单收编号走 ui_ask_num" \
    || bad "分享服务菜单没收 ui_ask_num"
# ★ 必须接住 ui_ask_num 的返回值 —— 它把选择写到 stdout, 不接的话 case 永远
#   不匹配, 菜单会静默地什么都不做。
grep -q 'c=$(ui_ask_num "请选择" 0 6)' "$SVC" \
    && ok "ui_ask_num 的返回值被接住了 (不会静默空转)" \
    || bad "ui_ask_num 的返回值没接住 —— 菜单会按什么都没发生处理"
# 服务状态必须在分享菜单顶部, 且主菜单不再有独立的 5)
grep -q '_share_svc_status' "$SH" && ok "分享菜单顶部显示服务状态" \
    || bad "分享菜单顶部没有服务状态"
# 「改次数上限」默认值也要跟着变成 1
grep -q 'ui_ask "新的次数上限 (0=不限)" "1"' "$SH" \
    && ok "改次数上限的默认值也是 1" || bad "改次数上限的默认值没跟着改"

# ★ 状态判据是"拿到健康数据才算运行中" —— 于是 conf/share_client.py 必须
#   真的在 health 时吐东西。老桩是"退出 0 但什么都不吐", 于是沙盒恒显示
#   「分享服务 : 未运行」, 而真实服务明明跑着 (用户以为新状态显示坏了)。
#   真实客户端与修好的桩都通过这一条; 老桩会红。
_HEALTH_OUT=$(SHARE_PROVIDER=xray python3 "$ROOT/conf/share_client.py" health 2>/dev/null)
if [[ -n "$_HEALTH_OUT" ]]; then
    ok "share_client.py health 有输出 (状态判据依赖它)"
    echo "$_HEALTH_OUT" | grep 'status' >/dev/null \
        && ok "health 输出含 status 字段" || bad "health 输出不像健康响应"
else
    # ★ 没有 share_client.py 的干净检出也走这里 —— 那不算失败, 但要说明。
    if [[ -f "$ROOT/conf/share_client.py" ]]; then
        bad "share_client.py health 没有输出 —— 面板会把运行中的服务显示成「未运行」"
    else
        printf '  (跳过: conf/share_client.py 不存在)\n'
    fi
fi

# ---------------------------------------------------------------- 客户端产物菜单
group "客户端产物菜单 (换指纹 / 换连接 IP)"
CM="$ROOT/xray-panel.sh"
grep -q 'client_menu()' "$CM" && ok "面板有客户端产物菜单" || bad "面板没有客户端产物菜单"
grep -q 'conf/share.sh change-fp' "$CM" \
    && ok "客户端产物菜单接上了「换 uTLS 指纹」" || bad "客户端产物菜单没接换指纹"
grep -q 'conf/share.sh switch-family-menu' "$CM" \
    && ok "客户端产物菜单接上了「换连接 IP」" || bad "客户端产物菜单没接换连接 IP"
# switch-family-menu 必须在 share.sh 的 CLI 派发表里, 否则 xray_run 调它等于空跑
grep -q 'switch-family-menu) x_switch_addr_family_menu' "$SH" \
    && ok "switch-family-menu 在 CLI 派发表里" || bad "switch-family-menu 没进 CLI 派发表"

# ---- 「查看产物内容」的三个真缺陷 (都是"按下去才发现"的那一类) ----
#
# ★ 这几条用 `| grep PAT >/dev/null` 而不是 `| grep -q` —— 本文件带 pipefail,
#   grep -q 命中就早退, 上游 sed 会吃 SIGPIPE(141)。套件的 EARLY 门禁盯这个。
_SXC=$(sed -n "/^show_xray_configs()/,/^}/p" "$CM")
_PKF=$(sed -n "/^_pick_out_file()/,/^}/p" "$CM")
#
# ① 路径硬编码: show_xray_configs 曾写死 /root/catmi/xray/out, 而同一个文件的
#    _client_status 用 ${OUT_DIR:-…} —— 两处口径不一致, 换了 XRAY_BASE 的
#    环境 (沙箱 / 多套配置) 里"顶部说 N 个文件、点进去看的是另一个目录"。
if printf '%s\n' "$_SXC" | grep 'OUT_DIR' >/dev/null; then
    ok "查看产物用 OUT_DIR (与顶部计数同一口径)"
else
    bad "查看产物把 out 目录写死了 → 与 _client_status 口径不一致"
fi

# ② 没有 json 分支: Xray 客户端那份出站是 .json, 原来只列 txt/yaml/yml,
#    于是"自己生成的 Xray 客户端配置"在面板里根本看不到。
if printf '%s\n' "$_SXC" | grep 'json' >/dev/null; then
    ok "查看产物认得 Xray JSON (不只有 YAML/TXT)"
else
    bad "查看产物没有 json 分支 → Xray 客户端产物看不到"
fi

# ③ ui_pick 在 conf/lib/ui.sh 里, 而面板原来只 source print.sh ——
#    于是按下去报 "ui_pick: command not found", 菜单看着能进、一选就退回来。
if grep 'conf/lib/ui.sh' "$CM" >/dev/null; then
    ok "面板加载了 conf/lib/ui.sh (编号选择层)"
else
    bad "面板没加载 ui.sh → ui_pick 会是 command not found"
fi
if printf '%s\n' "$_PKF" | grep 'declare -F ui_pick' >/dev/null; then
    ok "选择层拿不到时有退化分支 (不是 command not found)"
else
    bad "_pick_out_file 没有退化分支"
fi
grep -q 'change-fp)          share_change_fp' "$SH" \
    && ok "change-fp 在 CLI 派发表里" || bad "change-fp 没进 CLI 派发表"
# 换连接 IP 必须能交互选族 (面板调不到带参数的子命令)
grep -q 'x_switch_addr_family_menu()' "$SH" \
    && ok "换连接 IP 有交互入口 (不用背 v4/v6 参数)" \
    || bad "换连接 IP 只有带参数的非交互子命令"

group "节点命名 (naming.sh)"
# 协议名规范化: 各处的写法收敛成一种
for pair in "vless:vless" "VLESS:vless" "SS:ss" "shadowsocks:ss" \
            "SS2022:ss2022" "hy2:hysteria2" "hysteria:hysteria2" "Hysteria2:hysteria2"; do
    a="${pair%%:*}"; want="${pair##*:}"
    got=$(bash -c "source '$LIB/naming.sh'; x_proto_slug '$a'")
    assert_eq "$got" "$want" "协议名规范化 $a"
done
# 安全等级: 大写
for pair in "tls:TLS" "TLS:TLS" "reality:REALITY" "none:none"; do
    a="${pair%%:*}"; want="${pair##*:}"
    got=$(bash -c "source '$LIB/naming.sh'; x_sec_slug '$a'")
    assert_eq "$got" "$want" "安全等级规范化 '$a'"
done
# 空串单独测 —— 不能写成 for 里的 "" 元素: 两个引号会把它后面整段吞掉
# (实测就是这么写出语法错误的: `"":none"` 被解析成一段引号字符串)
got=$(bash -c "source '$LIB/naming.sh'; x_sec_slug ''")
assert_eq "$got" "none" "安全等级规范化 空串"
# tag 形态
got=$(bash -c "source '$LIB/naming.sh'; x_node_tag vless 1 tls")
assert_eq "$got" "x-vless01-TLS" "tag 基本形态 (含 x 前缀 + 补零)"
got=$(bash -c "source '$LIB/naming.sh'; x_node_tag trojan 2 reality")
assert_eq "$got" "x-trojan02-REALITY" "REALITY 节点 tag"
got=$(bash -c "source '$LIB/naming.sh'; x_node_tag vmess 1 tls cdn")
assert_eq "$got" "x-vmess01-TLS-CDN" "CDN 节点带 -CDN 后缀"
got=$(bash -c "source '$LIB/naming.sh'; x_node_tag vless 12 tls")
assert_eq "$got" "x-vless12-TLS" "两位数编号不补零"
got=$(bash -c "source '$LIB/naming.sh'; x_node_tag vless 100 none")
assert_eq "$got" "x-vless100-none" "三位数编号原样"
# ★ x 前缀是硬要求: 三个内核共用一个服务器时要能认出这是 Xray 建的
got=$(bash -c "source '$LIB/naming.sh'; x_node_tag vless 1 tls")
[[ "$got" == x-* ]] && ok "tag 带 x- 前缀 (跨内核可辨认)" || bad "tag 缺 x- 前缀: $got"
# 显示名默认值不能为空 —— 空 fragment 会让客户端退化成用域名当名字,
# 同一域名下的节点在列表里全叫一个名
got=$(bash -c "source '$LIB/naming.sh'; x_default_name vless 1 tls")
[[ -n "$got" ]] && ok "显示名默认值非空 ($got)" || bad "显示名默认值为空"
# 编号自增: 从已有节点里取最大编号 +1
ND="$TMP/naming"; mkdir -p "$ND"
printf '{"inbounds":[{"tag":"x-vless01-TLS"}]}' > "$ND/a.json"
printf '{"inbounds":[{"tag":"x-vless07-TLS-CDN"}]}' > "$ND/b.json"
printf '{"inbounds":[{"tag":"x-trojan02-REALITY"}]}' > "$ND/c.json"
got=$(bash -c "source '$LIB/naming.sh'; x_next_index vless '$ND'")
assert_eq "$got" "8" "下一个 vless 编号 = 已有最大 + 1"
got=$(bash -c "source '$LIB/naming.sh'; x_next_index trojan '$ND'")
assert_eq "$got" "3" "下一个 trojan 编号"
got=$(bash -c "source '$LIB/naming.sh'; x_next_index ss '$ND'")
assert_eq "$got" "1" "没有同协议节点时从 1 开始"
# 坏文件不能让编号计算崩掉
printf 'not json' > "$ND/bad.json"
got=$(bash -c "source '$LIB/naming.sh'; x_next_index vless '$ND'")
assert_eq "$got" "8" "坏片段不影响编号计算"

group "Nginx 站点管理 (conf/nginx_site.sh 菜单)"
bash -n "$ROOT/conf/nginx_site.sh" 2>/dev/null && ok "nginx_site.sh 语法" || bad "nginx_site.sh 语法"

# source 不该弹菜单
NS=$(timeout 20 bash -c "source '$ROOT/conf/nginx_site.sh'; echo DONE" 2>&1 | grep -c '════')
assert_eq "$NS" "0" "source nginx_site.sh 不弹菜单"

NG="$TMP/ng"; mkdir -p "$NG"
printf 'server {\n    listen 443 ssl;\n    server_name t.example;\n    location / { return 444; }\n}\n' > "$NG/t.example.conf"
export NGINX_CONF_ROOTS="$NG"
ngmenu() { timeout 40 bash "$ROOT/conf/nginx_site.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

# config_roots 可被环境变量覆盖, 否则没法测, 非标准安装路径也找不到站点
CR=$(NGINX_CONF_ROOTS="$NG" python3 -c "
import sys; sys.path.insert(0,'$LIB'); import nginx_apply as N
print('|'.join(N.config_roots()))")
assert_eq "$CR" "$NG" "NGINX_CONF_ROOTS 覆盖配置根"

L1=$(printf '1\n0\n' | ngmenu | grep -c 't.example')
assert_eq "$L1" "1" "列出站点: 显示 server_name 与文件名"

# 插入 → 查看 → 幂等 → 摘除 的完整链路
# ★ 带 --path: 这个夹具站里**已经有** `location /` (真实站点几乎都有),
#   而同一个 server 块里出现两个 `location /` 会让 nginx 直接 emerg
#   (`duplicate location "/"` —— 真 nginx 1.26 实测)。所以插入必须单开前缀,
#   这也正是 nginx 档节点现在的默认做法 (deploy.py 传节点自己的 path)。
python3 "$LIB/nginx_apply.py" --domain t.example --path /node --port 23456 --transport ws --nginx none >/dev/null 2>&1
NB=$(grep -c 'xray-core BEGIN' "$NG/t.example.conf")
assert_eq "$NB" "1" "插入反代: 生成一个标记块"
python3 "$LIB/nginx_apply.py" --domain t.example --path /node --port 23456 --transport ws --nginx none >/dev/null 2>&1
NB2=$(grep -c 'xray-core BEGIN' "$NG/t.example.conf")
assert_eq "$NB2" "1" "重复插入仍只有一个标记块 (幂等)"

# ★ 站点选择从"手打域名"改成了"看表选编号"(这是本次 UX 改动的核心), 所以这里
#   不能写死域名, 得先从菜单 1 的输出里查出 t.example 是第几号。
#   写死的另一个坏处: 站点表按域名排序, 一旦夹具多一个站点, 编号就整体位移,
#   测试会以"功能坏了"的面貌失败, 实际功能是好的。
ng_idx() { printf '1\n0\n' | ngmenu | awk -v d="$1" '$0 ~ d && $1 ~ /^[0-9]+$/ {print $1; exit}'; }
TI=$(ng_idx 't\.example')
[[ -n "$TI" ]] && ok "站点表里能按编号找到 t.example (第 $TI 号)" || bad "站点表里找不到 t.example 的编号"

V2=$(printf '2\n%s\n\n0\n' "$TI" | ngmenu | grep -c 'proxy_pass')
assert_eq "$V2" "1" "查看站点: 显示插入的正文"

R1=$(printf '4\n%s\nnope\n\n0\n' "$TI" | ngmenu | grep -c '已取消')
assert_eq "$R1" "1" "摘除: 确认词不对则不动手"
NB3=$(grep -c 'xray-core BEGIN' "$NG/t.example.conf")
assert_eq "$NB3" "1" "摘除: 取消后标记块还在"

printf '4\n%s\nyes\n\n0\n' "$TI" | ngmenu >/dev/null 2>&1
NB4=$(grep -c 'xray-core BEGIN' "$NG/t.example.conf" || true)
assert_eq "$NB4" "0" "摘除: 确认后标记块消失"
KEEP=$(grep -c 'return 444' "$NG/t.example.conf")
assert_eq "$KEEP" "1" "摘除: 用户自己写的 location 未被动过"

# 预览插入: 站点也是编号选 (取消手填是给"还没建的站点"用的, 这里是已有站点);
# 传输方式从"手打 ws/grpc/..."改成了编号表, ws 是第 1 项
P1=$(printf '5\n%s\n23456\n1\n\n0\n' "$TI" | ngmenu | grep -c 'dry-run, 不落盘')
assert_eq "$P1" "1" "预览插入: 标明是 dry-run"
P2=$(printf '5\n%s\n23456\n1\n\n0\n' "$TI" | ngmenu | grep -c 'proxy_pass')
assert_eq "$P2" "1" "预览插入: 能看到将插入的内容"
# 取消编号选择 -> 走"手填还没建的域名"这条路 (预览本来就要能预览不存在的站点)
P3=$(printf '5\n0\nbrand.new\n23456\n1\n\n0\n' | ngmenu | grep -c 'brand.new')
assert_eq "$P3" "1" "预览插入: 取消后仍可手填未建站点"

# ---------------------------------------------------------------- 面板入口
# 目标里的能力清单要求每项都有用户能摸到的入口。之前 cert / nginx_site /
# share_service 都只有库没有入口, 用户要从源码里翻才知道它们存在。
group "面板入口 (目标清单逐项核对)"
PAN="$ROOT/xray-panel.sh"
# Server / Client / UI 由面板本身与 Client/ 目录承担, 不是独立菜单项
entry_ok() { grep -q "conf/$1" "$PAN" && ok "$2 有菜单入口" || bad "$2 无菜单入口"; }
entry_ok share.sh          "Share"
# ★ 分享服务不再是主菜单的独立项 —— 用户要求把它和「分享管理」并成一块:
#   状态提到 share_menu 顶部 (每轮刷新), 11) 保留为二级入口。
#   所以入口判定放宽成"面板直接引用, 或经 share.sh 引用";
#   并且**额外钉死二级入口还在**, 免得以后有人把 11) 删了这项测试还绿着。
if grep -q "conf/share_service.sh" "$PAN"; then
    ok "Pull (分享服务) 有菜单入口"
elif grep -q 'share_service.sh' "$ROOT/conf/share.sh"; then
    ok "Pull (分享服务) 有菜单入口 (经分享管理二级菜单)"
else
    bad "Pull (分享服务) 无菜单入口"
fi
grep -q 'share_service_menu' "$ROOT/conf/share.sh" \
    && ok "分享服务的二级入口仍挂在分享管理里" \
    || bad "分享服务的二级入口不见了"
# ★ 合并的另一半: 服务状态必须出现在分享菜单**顶部**。
#   老结构是主菜单 5) 与 share_menu 11) 各画一份状态, 两处还会不一致。
grep -q '_share_svc_status' "$ROOT/conf/share.sh" \
    && ok "分享菜单顶部显示分享服务状态" \
    || bad "分享菜单顶部没有服务状态 —— 用户还得再点一层才看得到"
grep -q 'share_service.sh menu' "$PAN" && bad "主菜单还留着独立的 5) 分享服务" \
    || ok "主菜单已去掉独立的 5) 分享服务"
entry_ok node.sh           "Node 管理"
entry_ok nginx_site.sh     "Nginx"
entry_ok cert.sh           "Cert"
entry_ok dns.sh            "DNS"
entry_ok logs.sh           "Logs"
entry_ok verify.sh         "Port (校验/自动改端口)"
grep -q 'systemctl status xrayls' "$PAN" && ok "Service 有菜单入口" || bad "Service 无菜单入口"
grep -q 'check_libs.sh' "$PAN" && ok "Validation 有菜单入口" || bad "Validation 无菜单入口"
grep -q 'run_xray_install' "$PAN" && ok "Install/Update 有菜单入口" || bad "Install 无菜单入口"
grep -q 'uninstall_xray.sh' "$PAN" && ok "Uninstall 有菜单入口" || bad "Uninstall 无菜单入口"
# Docker 能力不是独立菜单, 而是通过 cert/nginx 的容器感知暴露 —— 检查它真的在
grep -q 'docker' "$ROOT/conf/lib/cert.sh" && ok "Docker 能力: cert.sh 有容器感知" || bad "Docker: cert.sh 无容器感知"
grep -q 'docker' "$ROOT/conf/lib/nginx_apply.py" && ok "Docker 能力: nginx_apply.py 有容器感知" || bad "Docker: nginx_apply.py 无容器感知"
# 面板里每个菜单号都要有对应 case, 否则显示得出、按下去没反应
MISSING=""
for n in $(grep -oE '^\s+[0-9]+\)' "$PAN" | grep -oE '[0-9]+' | sort -n -u); do
  grep -qE "^\s+$n\)" "$PAN" || MISSING="$MISSING $n"
done
[[ -z "$MISSING" ]] && ok "面板菜单号连续无缺" || bad "面板菜单号缺失:$MISSING"
# 面板引用的每个远端脚本都要真实存在 (拼错 URL 的话运行时才 404)
BADURL=""
for u in $(grep -oE 'https://github.com/mi1314cat/xray--core/raw/refs/heads/main/[A-Za-z0-9_/.-]+' "$PAN" | sort -u); do
  p="${u#*main/}"
  [[ -f "$ROOT/$p" ]] || BADURL="$BADURL $p"
done
[[ -z "$BADURL" ]] && ok "面板引用的脚本都存在" || bad "面板引用了不存在的文件:$BADURL"

# ---------------------------------------------------------------- 面板取文件
group "面板取文件 (XRAY_RAW / 铺 lib / 404)"
PAN="$ROOT/xray-panel.sh"

# ★ 清单漂移守卫: 这个清单本可以提前发现 conf/lib/print.sh 漏登记。
#   漏一个的症状是"某个菜单项报 库加载失败", 而不是面板打不开 —— 很难查。
# 清单是数组, 一行里可能并排好几个 —— 必须按"词"取, 不能按行首匹配。
liblist=$(sed -n '/^_XRAY_LIB_FILES=(/,/^)/p' "$PAN" \
          | tr ' \t' '\n\n' | grep -oE '^[A-Za-z0-9_.]+\.(sh|py)$')
missing=""
for f in $(ls "$ROOT/conf/lib" | grep -v __pycache__); do
    printf '%s\n' "$liblist" | grep -x "$f" >/dev/null || missing="$missing $f"
done
[[ -z "$missing" ]] && ok "_XRAY_LIB_FILES 覆盖 conf/lib/ 全部文件" \
    || bad "_XRAY_LIB_FILES 漏了:$missing"

# 清单里写的文件必须真的存在 (反向: 写了仓库里没有的 → 每次都要等 404)
bogus=""
for f in $(sed -n '/^_XRAY_LIB_FILES=(/,/^)/p' "$PAN" | grep -oE '[A-Za-z0-9_.]+\.(sh|py)'); do
    [[ -f "$ROOT/conf/lib/$f" ]] || bogus="$bogus $f"
done
[[ -z "$bogus" ]] && ok "_XRAY_LIB_FILES 里没有不存在的文件" || bad "清单里有不存在的文件:$bogus"

# xray_run 必须铺 lib, 否则每个菜单项都会掉进脚本自己的 github 兜底
grep -q 'xray_ensure_lib' "$PAN" && ok "xray_run 会铺 lib" || bad "xray_run 没调 xray_ensure_lib"
# 而且要把可用的源交给子脚本
sed -n '/^xray_run()/,/^}/p' "$PAN" | grep 'XRAY_RAW="\$base" bash' >/dev/null \
    && ok "xray_run 把可用源通过 XRAY_RAW 交给子脚本" \
    || bad "xray_run 没有把可用源交给子脚本 (兜底仍会走写死的 github)"

# ★ 回归守卫: 这条警告必须在 stderr。打在 stdout 会被 $(xray_pick_source) 一起
#   捕获, 拼出的 URL 前面挂着一行带 ANSI 码的提示, curl 必然失败。
sed -n '/^xray_pick_source()/,/^}/p' "$PAN" | grep '已选用镜像.*>&2' >/dev/null \
    && ok "xray_pick_source 的警告走 stderr" \
    || bad "xray_pick_source 的警告又打到 stdout 了 —— 会污染 \$(...) 捕获"

# ★ 404 短路: 仓库只有一份, 这个源说没有别的源也不会有。
#   逐个重试既慢, 又把"文件不存在"报成"镜像链全不通"。
sed -n '/^xray_fetch_to()/,/^}/p' "$PAN" | grep '404' >/dev/null \
    && ok "xray_fetch_to 对 404 短路" || bad "xray_fetch_to 没有 404 短路 (会白试所有镜像)"

# 每个脚本内部的 github 兜底都要能被 XRAY_RAW 覆盖。
# 未设 XRAY_RAW 时展开结果与原 URL 逐字节相同 —— 独立运行行为不变。
badfb=""
for f in $(grep -rl '"https://github.com/mi1314cat/xray--core/raw/refs/heads/main' "$ROOT/conf" 2>/dev/null); do
    badfb="$badfb $(basename "$f")"
done
[[ -z "$badfb" ]] && ok "conf/ 下的兜底全部可被 XRAY_RAW 覆盖" \
    || bad "仍有写死 github 的兜底:$badfb"

# 展开式必须闭合 (上次漏了 } 直接把一个文件弄成语法错误)
unbalanced=""
for f in $(grep -rl 'XRAY_RAW:-https://github.com/mi1314cat' "$ROOT/conf" "$PAN" 2>/dev/null); do
    # 只数"被替换过的那一种"(默认值是 github.com 那条), 不数
    # XRAY_RAW="${XRAY_RAW:-https://raw.githubusercontent.com/...}" 这类别的默认值。
    n1=$(grep -o '\${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main' "$f" | wc -l)
    n2=$(grep -o '\${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}' "$f" | wc -l)
    [[ "$n1" = "$n2" ]] || unbalanced="$unbalanced $(basename "$f")($n1/$n2)"
done
[[ -z "$unbalanced" ]] && ok "所有 \${XRAY_RAW:-...} 都闭合" \
    || bad "有未闭合的展开:$unbalanced"

# 未设 XRAY_RAW 时展开必须与原值一致 —— 这是"独立运行行为不变"的依据
got=$(bash -c 'unset XRAY_RAW; printf "%s" "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/addr.sh"')
assert_eq "$got" "https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/lib/addr.sh" \
    "未设 XRAY_RAW 时展开结果与原 URL 一致"

# 兜底 URL 指向的文件必须真实存在 (拼错的话只在最需要它的那一刻才 404)
badurl=""
for u in $(grep -rhoE 'raw/refs/heads/main\}/?[A-Za-z0-9_/.-]+\.(sh|py)' "$ROOT/conf" "$PAN" 2>/dev/null | sort -u); do
    p="${u#*main\}/}"
    [[ -f "$ROOT/$p" ]] || badurl="$badurl $p"
done
[[ -z "$badurl" ]] && ok "兜底 URL 指向的文件都存在" || bad "兜底 URL 指向不存在的文件:$badurl"

# ---------------------------------------------------------------- 拨号菜单健壮性
# 这组来自一次**真实事故**（交互验证台在 CC 上抓到的）:
#
#   compat.py json 在"Xray 与浏览器两种模式都用不了"时**退出码为 1** ——
#   那是有效结论, 不是失败。而 xbd 顶部是 `set -euo pipefail`, 管道里
#   一个命令非零整条就非零, 于是
#       can=$(python3 compat.py json "$f" | python3 -c '...')
#   这个赋值把整个菜单当场杀掉。症状是"表格打得出来、选项一行不出、
#   rc=1、stderr 为空" —— 和另一个 `[ ... ] &` 的事故长得一模一样。
#
#   触发条件很现实: 节点列表里**有任意一个**两模式都用不了的节点就够。
#   CC 上有一个 ECH 节点(整份 Xray JSON 配置, 不是节点对象), 于是
#   浏览器拨号菜单在那儿一直是废的。
group "拨号菜单健壮性 (compat.py 退出码)"
DT="$(mktemp -d)"; DN="$DT/nodes"; mkdir -p "$DN"
python3 - "$DN" <<'PY'
import json, os, sys
d = sys.argv[1]
# 正常节点
json.dump({"protocol": "vless", "transport": "xhttp", "security": "tls",
           "address": "a.example", "port": 443,
           "uuid": "11111111-1111-1111-1111-111111111111"},
          open(os.path.join(d, "node-01.json"), "w"))
# 两模式都用不了的节点 —— compat.py 对它返回 1
json.dump({"protocol": "wireguard", "transport": "tcp", "security": "none",
           "address": "b.example", "port": 51820},
          open(os.path.join(d, "node-02.json"), "w"))
PY
# 先确认前提成立: 第二个节点确实让 compat.py 退出 1
bash -c "python3 '$ROOT/Client/lib/compat.py' json '$DN/node-02.json' >/dev/null 2>&1"
[[ "$?" = "1" ]] && ok "前提成立: 有一类节点让 compat.py 退出 1" \
    || bad "前提不成立: compat.py 没有返回 1, 这组测不到东西"
sed -n '/^_xbd_browser_table()/,/^}/p' "$ROOT/Client/lib/actions.sh" > "$DT/fn.sh"
out=$(XBD_NODES="$DN" XBD_LIBDIR="$ROOT/Client/lib" \
      bash -c "set -euo pipefail; source '$DT/fn.sh'; _xbd_browser_table" 2>&1)
rc=$?
assert_eq "$rc" "0" "节点两模式都不可用时 _xbd_browser_table 仍然返回 0 (set -e 不杀)"
n=$(printf '%s\n' "$out" | grep -c 'node-')
assert_eq "$n" "2" "表格把两个节点都列出来了 (一个都不少)"
# 逐个函数都要有 || true, 否则同样会踩
miss=""
for fn in _xbd_browser_table _xbd_browser_pick _xbd_browser_bulk; do
  body=$(sed -n "/^${fn}()/,/^}/p" "$ROOT/Client/lib/actions.sh")
  printf '%s' "$body" | grep 'compat.py" json' >/dev/null || continue
  printf '%s' "$body" | grep '2>/dev/null || true)' >/dev/null || miss="$miss $fn"
done
[[ -z "$miss" ]] && ok "三个拨号菜单函数都容忍 compat.py 的退出码 1" \
    || bad "这些函数没容错, 菜单会被 set -e 杀掉:$miss"
rm -rf "$DT"

# ---------------------------------------------------------------- apply 健康路径
# 这一组守的是"**成功的时候才炸**"那类 bug —— 最难发现的一种。
#
#   xbd 顶部是 `set -euo pipefail`, 而 cmd_apply 里有
#       printf '%s\n' "$_gen_out" | grep 'genconfig:' | while read -r l; do ...; done
#   genconfig 成功、没有任何警告行时 grep **无匹配返回 1**, pipefail 让整条管道
#   非零, set -e 当场杀掉脚本。
#
#   配置文件其实已经写好了(genconfig 自己成功了), 但脚本死在这一行 ——
#   后面的 systemctl restart 永远不执行: **改了配置不生效, 还不报错**。
#   实测 CC 上从 10-09 15:07 部署起就是坏的, 一直没人发现。
#
#   做法是抽**真实语句**来跑, 不是复刻一份 —— 复刻的测试只能证明"我知道怎么写对",
#   证明不了"文件里那行是对的"。
group "apply 健康路径 (set -e 与 pipefail)"
ACT="$ROOT/Client/lib/actions.sh"

# 语句 1: grep 无匹配时不能杀脚本
STMT=$(grep -n "printf '%s\\\\n' \"\$_gen_out\" | grep 'genconfig:'" "$ACT" | awk 'NR==1' | cut -d: -f2-)
[[ -n "$STMT" ]] && ok "找到 genconfig 警告输出那一行" || bad "找不到那一行(可能被改写, 请更新本测试)"
run_stmt() { # $1=语句  $2=喂给 _gen_out 的内容
  # 被抽出来的语句会调 warn/dim —— 它们是 actions.sh 里的函数, 独立夹具里没有。
  # 不给桩的话报 "command not found" (rc=127), 会把"夹具缺函数"误报成"代码有问题"。
  { printf 'set -euo pipefail\n'
    printf 'warn() { :; }; dim() { :; }; ok() { :; }; bad() { :; }\n'
    printf '_gen_out=%s\n' "$2"
    printf '%s\n' "$1"
    printf 'echo REACHED\n'
  } > "$TMP_A"
  bash "$TMP_A" >/dev/null 2>&1
}
TMP_A="$(mktemp)"
run_stmt "$STMT" "'{\"ok\": true, \"mode\": \"normal\"}'"
assert_eq "$?" "0" "genconfig 成功且无警告时, 脚本能走到最后 (不再被 grep 的退出码杀掉)"

# 语句 2: 循环体末命令遇空行不能杀脚本
# 用 awk 按标记行取到 done —— sed 的 \\n 在 BRE 里不表示换行，上一步就是这么抽空的。
STMT2=$(awk '/\| tail -3 \| while read/{f=1} f{print; if(/done/) exit}' "$ACT")
[[ -n "$STMT2" ]] && ok "找到 tail 输出那一段" || bad "找不到 tail 那一段"
# 必须喂一个**末尾带换行**的值: genconfig 的警告输出常以换行收尾,
# `printf '%s\n'` 之后就多出一个空行, 循环体会读到它。
# 喂 "a" 是测不出来的 —— 那样压根不会出现空行, 门禁会变成假的。
run_stmt "$STMT2" "\$'a\\n'"
assert_eq "$?" "0" "tail 循环遇到空行时不再中断"
rm -f "$TMP_A"

# 静态兜底: 同一类写法不该再出现(命令位置的裸 grep 管道, 结尾 while read)
BAD=$(grep -nE "^\s*[^#].*\| *grep [^|]*\| *while read" "$ACT" | grep -v '|| true' | wc -l)
assert_eq "$BAD" "0" "没有「grep 无匹配即杀脚本」的裸管道"

# ---------------------------------------------------------------- ECH / 指纹 / 地址族
# 这三项是同一轮加的，都围绕"服务端下发的值要被客户端**真正用上**"这个主题。
group "ECH 下发 (echConfigList)"
# 服务端 cdn 模式写的形状（官方 tlsSettings.echConfigList 的第二种格式：
# "从 DNS 服务器查询"，特殊写法 "example.com+https://1.1.1.1/dns-query"）
ech_node() {
  python3 - "$1" "$2" <<'PY'
import json, sys
json.dump({"protocol": "vless", "address": "a.example", "port": 443,
           "uuid": "11111111-2222-3333-4444-555555555555",
           "transport": "xhttp", "security": "tls", "sni": "a.example",
           "path": "/x", "ech": sys.argv[2]}, open(sys.argv[1], "w"))
PY
}
ECHT="$(mktemp -d)"
CDN_ECH='cloudflare-ech.com+https://dns.alidns.com/dns-query'
ech_node "$ECHT/n.json" "$CDN_ECH"
python3 "$ROOT/Client/lib/genconfig.py" --node "$ECHT/n.json" --output "$ECHT/normal.json" \
  --mode normal --listen 127.0.0.1 --port-normal 1080 --logs "$ECHT" >/dev/null 2>&1
got=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for o in d["outbounds"]:
    ts=(o.get("streamSettings") or {}).get("tlsSettings") or {}
    if ts.get("echConfigList"): print(ts["echConfigList"]); break
' "$ECHT/normal.json" 2>/dev/null || true)
assert_eq "$got" "$CDN_ECH" "普通模式把 ECHConfigList 原样下发（走 CDN 用的就是这条）"

python3 "$ROOT/Client/lib/genconfig.py" --node "$ECHT/n.json" --output "$ECHT/dialer.json" \
  --mode dialer --listen 127.0.0.1 --port-normal 1080 --port-dialer 18081 --logs "$ECHT" >/dev/null 2>&1
n=$(grep -c echConfigList "$ECHT/dialer.json" 2>/dev/null || true)
assert_eq "${n:-0}" "0" "拨号模式不写（那条路 TLS 由 Chromium 完成，写了也不会被读）"
rm -rf "$ECHT"

group "指纹白名单 (内核未知值会整份配置失败)"
fp_node() {
  python3 - "$1" "$2" <<'PY'
import json, sys
json.dump({"protocol": "vless", "address": "a.example", "port": 443,
           "uuid": "11111111-2222-3333-4444-555555555555",
           "transport": "tcp", "security": "tls", "sni": "a.example",
           "fingerprint": sys.argv[2]}, open(sys.argv[1], "w"))
PY
}
FPT="$(mktemp -d)"
for pair in "chrome:SUPPORTED" "Chrome:SUPPORTED" "random:SUPPORTED" \
            "hellochrome_131:SUPPORTED" "not-a-real-fp:NOT_SUPPORTED"; do
  fp="${pair%%:*}"; want="${pair##*:}"
  fp_node "$FPT/n.json" "$fp"
  got=$(python3 "$ROOT/Client/lib/compat.py" json "$FPT/n.json" 2>/dev/null \
        | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(next((c["verdict"] for c in d["xray"]["checks"] if c["item"]=="指纹"), "缺失"))' 2>/dev/null || true)
  # 注意是 `|| true` 不是 `|| echo ...`：compat.py 对"不可用"的节点**退出码为 1**
  # （那是有效结论），pipefail 下会把整条管道判失败 —— 用 echo 追加会把
  # "解析失败" 拼到结果后面，断言跟着错。
  assert_eq "$got" "$want" "指纹 $fp"
done
rm -rf "$FPT"

# ==========================================================================
group "导入分享链接 (X 自己的订阅链接 / percent-decode / ECH)"
# 这组守的是: 用户把面板「分享管理」发出来的那条 http://ip:port/share/<token>
# 贴进「新增出站 → 导入分享链接」时, 生成的出站必须是**对**的。
# 曾经有 4 个坑, 全是"看着配好了, 连不通"那一类:
#   1) path 不解码 → "%2FaVCR3P0A%2F" 原样进 JSON, 请求打空
#   2) 名字不解码 → 节点名是一串 %F0%9F%87%BA
#   3) ech 被丢掉 → 白挂 CDN, 真实 SNI 裸奔
#   4) 订阅是多条的, 单条解析器吃不了
SUBT="$(mktemp -d)"
sed -n '/^urldecode()/,/^}/p;/^_ob_name()/,/^}/p;/^get_param()/,/^}/p;
        /^parse_hysteria2()/,/^}/p;/^parse_vless()/,/^}/p;/^parse_trojan()/,/^}/p;
        /^parse_ss()/,/^}/p;/^parse_vmess()/,/^}/p;
        /^vless_json()/,/^}/p;/^trojan_json()/,/^}/p;/^hy2_json()/,/^}/p;
        /^ss_json()/,/^}/p' "$ROOT/conf/outbound.sh" > "$SUBT/fns.sh"

cat > "$SUBT/drv.sh" <<'DRV'
set -u
source "$1"; shift
eval "$1"
DRV

sub_eval() { bash "$SUBT/drv.sh" "$SUBT/fns.sh" "$1" 2>/dev/null; }

# --- 1) percent-decode ------------------------------------------------------
assert_eq "$(sub_eval 'get_param "path=%2FaVCR3P0A%2F&sni=a.example" path')" "/aVCR3P0A/" \
    "get_param 会 percent-decode (xhttp 的 path 是编码过的)"
assert_eq "$(sub_eval 'get_param "path=%2FaVCR3P0A%2F&sni=a.example" sni')" "a.example" \
    "没编码的值不受影响"
assert_eq "$(sub_eval 'urldecode "AGX%2BDQBh"')" "AGX+DQBh" \
    "ECH 配置里的 + 要还原 (base64 的 + 编码成 %2B)"

# --- 2) 节点名解码 ---------------------------------------------------------
assert_eq "$(sub_eval '_ob_name "%F0%9F%87%BA%F0%9F%87%B8%201-VLESS-WS_01" "x"')" "🇺🇸 1-VLESS-WS_01" \
    "分享链接的 #name 是编码过的, 名字要能还原"
assert_eq "$(sub_eval '_ob_name "" "VLESS"')" "VLESS" \
    "没有 #name 时回落到默认名"

# --- 3) 用 X 真实载荷里那条 xhttp 链接走一遍 --------------------------------
XLINK='vless://1fa7c981-16b4-4963-9ef6-9bb13ad25053@107.173.154.178:8443?encryption=none&security=tls&type=xhttp&sni=moontv.6896698.xyz&ech=AGX%2BDQBhAAAgACA%2FrOgHBypsWc%2FLDY%2FWZjmK8Gm5jpe876iY7AKFphHdAgAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAB%2Bmoontv%2Ejson%3D&path=%2FaVCR3P0A%2F#%F0%9F%87%BA%F0%9F%87%B8%201-vless-xhttp07'
assert_eq "$(sub_eval "OB_ECH=; parse_vless \"$XLINK\"; printf '%s' \"\$OB_XHTTP_PATH\"")" "/aVCR3P0A/" \
    "parse_vless 解出正确的 xhttp 路径"
assert_eq "$(sub_eval "OB_ECH=; parse_vless \"$XLINK\"; printf '%s' \"\$OB_NAME\"")" "🇺🇸 1-vless-xhttp07" \
    "parse_vless 解出正确的节点名"
assert_eq "$(sub_eval "OB_ECH=; parse_vless \"$XLINK\"; printf '%s' \"\${#OB_ECH}\"")" "123" \
    "parse_vless 取出 ech (静默丢掉就等于白挂 CDN)"

# --- 4) ech 必须真的进 JSON (字段名是 echConfigList, 服务端/客户端不同) -----
# ★ 这两条把 jq 程序**放进文件**再调用: 在 eval 字符串里再嵌一层引号必然转义错,
#   错出来的报错长得像产品坏了, 实际是自己写错。踩过一次。
cat > "$SUBT/len.jq" <<'JQ'
(.outbounds[0].streamSettings.tlsSettings // {}) | (.echConfigList // "") | length
JQ
cat > "$SUBT/nok.jq" <<'JQ'
.outbounds[0].streamSettings | has("tlsSettings")
JQ
# ★ 片段里只负责**准备 OB_\***, 生成由 sub_run 统一做 —— 片段里再调一次
#   vless_json 就会输出两份 (上面踩过)。另一个坑: 不先 parse_vless 就直接
#   vless_json, OB_NAME/OB_ADDR 这些还没设, set -u 下整个函数静默死掉,
#   表现出来是"断言拿到空", 看着像产品坏了。
export XLINK
cat > "$SUBT/with.sh" <<'RUN'
OB_ECH=""; parse_vless "$XLINK"
RUN
cat > "$SUBT/without.sh" <<'RUN'
OB_ECH=""; parse_vless "$XLINK"; OB_ECH=""; OB_SEC=none; OB_NET=tcp
RUN
sub_run() { # <片段文件> <jq文件>
    bash "$SUBT/drv.sh" "$SUBT/fns.sh" "source $1; vless_json ob-t" 2>/dev/null | jq -r -f "$2"
}
ECH_LEN=$(sub_run "$SUBT/with.sh" "$SUBT/len.jq")
assert_eq "$ECH_LEN" "123" "ech 写进了 tlsSettings.echConfigList (不是 echServerKeys —— 那是服务端字段)"
NO_ECH=$(sub_run "$SUBT/without.sh" "$SUBT/nok.jq")
assert_eq "$NO_ECH" "false" "没有 ech 时不会凭空长出 tlsSettings/echConfigList"

# --- 5) 订阅地址导入 -------------------------------------------------------
grep -q 'http|https) import_share_url' "$ROOT/conf/outbound.sh" \
    && ok "import_link 把 http(s) 交给订阅导入" || bad "import_link 不认订阅地址"
grep -q 'base64 -d' "$ROOT/conf/outbound.sh" \
    && ok "订阅导入会解 base64 (X 的载荷就是 base64 的订阅行)" || bad "订阅导入不解 base64"
grep -q 'case "\${ln%%://\*}" in' "$ROOT/conf/outbound.sh" \
    && ok "订阅导入只留认得的协议" || bad "订阅导入没过滤协议"
# Ctrl-D 不能被当成"全选" —— 那样误触一下就导进 8 个出站
grep -q 'if ! IFS= read -r pick; then' "$ROOT/conf/outbound.sh" \
    && ok "订阅导入把 EOF 与'确实要全选'分开 (ui_ask 做不到)" \
    || bad "订阅导入用 ui_ask 收选择 —— Ctrl-D 会变成全选"
# ECH 变量兜底: 走 wizard_* 手工新增时没设过 OB_ECH, jq 又无条件引用 $ech
grep -q '^OB_ECH=""' "$ROOT/conf/outbound.sh" \
    && ok "OB_ECH 有兜底初始化 (set -u 下手工新增不会炸)" \
    || bad "OB_ECH 没兜底 —— 手工新增出站时 jq 会引用未定义变量"
jq_ok=$(command -v jq >/dev/null && echo yes || echo no)
assert_eq "$jq_ok" "yes" "本组测试依赖 jq"

group "出站地址族 (--family)"
FAMT="$(mktemp -d)"
cat > "$FAMT/n.json" <<'EOF'
{"protocol":"vless","address":"a.example","port":443,
 "uuid":"11111111-2222-3333-4444-555555555555",
 "transport":"tcp","security":"tls","sni":"a.example"}
EOF
fam_check() { # <family> <期望 direct> <期望 dns>
  python3 "$ROOT/Client/lib/genconfig.py" --node "$FAMT/n.json" --output "$FAMT/$1.json" \
    --mode normal --listen 127.0.0.1 --port-normal 1080 --dns standard \
    --family "$1" --logs "$FAMT" >/dev/null 2>&1
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
ds=next((o["settings"]["domainStrategy"] for o in d["outbounds"] if o.get("tag")=="direct"), "?")
print(ds, (d.get("dns") or {}).get("queryStrategy","?"))
' "$FAMT/$1.json" 2>/dev/null || echo "生成失败 ?"
}
got=$(fam_check auto); assert_eq "$got" "UseIPv4 UseIP" "auto = 历史行为（不改存量用户的解析方式）"
got=$(fam_check v4);   assert_eq "$got" "UseIPv4 UseIPv4" "v4 强制只走 IPv4"
got=$(fam_check v6);   assert_eq "$got" "UseIPv6 UseIPv6" "v6 强制只走 IPv6"
# auto 必须是默认值，否则不传 --family 的调用方会被改行为
grep -q 'add_argument("--family".*default="auto"' "$ROOT/Client/lib/genconfig.py" \
  && ok "--family 默认 auto" || bad "--family 默认值不是 auto"

# ★ 回读校验本身必须真的读得到东西。
#   第一版用的是 `grep -o '"tag": *"direct"[^}]*}'` —— 而配置是**带换行的
#   格式化 JSON**，[^}]* 跨不了行，永远匹配不到，于是那条"回读校验"变成空跑：
#   开关看着生效了，其实没有任何东西在验。这类"假门禁"比没有门禁更糟。
_strategy_of() { # <配置文件>
  XBD_RUNTIME="$(dirname "$1")" bash -c "
    source <(sed -n '/^_xbd_direct_strategy()/,/^}/p' '$ROOT/Client/lib/actions.sh')
    _xbd_direct_strategy" 2>/dev/null || true
}
python3 "$ROOT/Client/lib/genconfig.py" --node "$FAMT/n.json" --output "$FAMT/rd6.json" \
  --mode normal --listen 127.0.0.1 --port-normal 1080 --family v6 --logs "$FAMT" >/dev/null 2>&1
# 读取器按 $XBD_RUNTIME/xray-client.json 找文件，这里造一个同名的
mkdir -p "$FAMT/rt" && cp "$FAMT/rd6.json" "$FAMT/rt/xray-client.json"
got=$(_strategy_of "$FAMT/rt/xray-client.json")
assert_eq "$got" "UseIPv6" "回读函数能从**格式化 JSON** 里读出 direct 的 domainStrategy"
# 反证：grep 那种写法在这份文件上确实读不到（保住这条注释的依据）
g=$(grep -o '"tag": *"direct"[^}]*}' "$FAMT/rt/xray-client.json" 2>/dev/null | awk 'NR==1' || true)
[[ -z "$g" ]] && ok "（反证）单纯的 grep 跨行读不到 —— 所以必须用解析" \
              || bad "（反证）grep 竟然读到了，注释里的理由需要更新"
rm -rf "$FAMT"

# ---------------------------------------------------------------- 分组整理
# 原来只有 group_create / group_delete —— 建完组就没法整理：
#   · 名字打错只能删掉重建，而删除会**连带删掉组内节点**（不可撤销）
#   · 节点归错组了没有任何办法挪走
# 合起来就是"组与组之间的交互不好"。这组守新加的三件事。
group "分组整理 (重命名 / 移动 / 排序)"
GT="$(mktemp -d)"; mkdir -p "$GT/nodes"
python3 - "$GT" <<'PY'
import json, os, sys
d = sys.argv[1]
for i in (1, 2):
    json.dump({"name": "n%d" % i, "protocol": "vless",
               "address": "a.example", "port": 443},
              open(os.path.join(d, "nodes", "node-%02d.json" % i), "w"))
PY
cat > "$GT/run.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "..", "..", "Client", "lib"))
PY
# 用真实 subs.py 跑一遍完整流程
out=$(python3 - "$ROOT" "$GT" <<'PY' 2>&1
import json, os, sys, shutil
root, d = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "Client", "lib"))
import subs as S
res = []
a = S.add_sub(d, "local:a", "组A", kind="local")
b = S.add_sub(d, "local:b", "组B", kind="local")
fa, fb = "node-01.json", "node-02.json"
S.set_nodes(d, a["id"], [fa]); S.set_nodes(d, b["id"], [fb])
S.stamp_group(d, a["id"], [fa]); S.stamp_group(d, b["id"], [fb])

res.append(("rename", S.rename_group(d, b["id"], "机场B")))
reg = S.load(d)["subs"]
res.append(("renamed", any(x["name"] == "机场B" for x in reg)))
res.append(("rename-bad-id", S.rename_group(d, "nope", "x")))

n = S.move_nodes_to_group(d, a["id"], [fb])
res.append(("moved-count", n))
reg = S.load(d)["subs"]
byid = {x["id"]: x for x in reg}
res.append(("in-target", fb in byid[a["id"]]["nodes"]))
res.append(("out-source", fb not in byid[b["id"]]["nodes"]))

# ★ 关键：文件里的 group 字段与注册表必须一致，否则节点会同时出现在两个组里
g = json.load(open(os.path.join(d, "nodes", fb))).get("group")
res.append(("stamped", g == a["id"]))

res.append(("reorder", S.reorder_group(d, b["id"], -1)))
res.append(("order-first", S.load(d)["subs"][0]["id"] == b["id"]))
res.append(("reorder-oob", S.reorder_group(d, b["id"], -1)))
for k, v in res:
    print("%s\t%r" % (k, v))
PY
)
chk() { printf '%s' "$out" | grep "^$1	$2$" >/dev/null && ok "$3" || bad "$3" "$(printf '%s' "$out" | grep "^$1	" | awk 'NR==1')"; }
chk rename        True  "分组可重命名"
chk renamed       True  "改名后注册表里是新名字"
chk rename-bad-id False "对不存在的分组改名返回 False（不是假装成功）"
chk moved-count   1     "移动 1 个节点"
chk in-target     True  "节点进了目标分组"
chk out-source    True  "节点从原分组摘掉了（否则会同时出现在两个组）"
chk stamped       True  "节点文件里的 group 字段也更新了（与注册表一致）"
chk reorder       True  "分组可上移"
chk order-first   True  "上移后确实排在前面"
chk reorder-oob   False "已经在最前时上移返回 False"
rm -rf "$GT"

# ---------------------------------------------------------------- 更新后生效
# 一次真实事故：客户端更新到 2.2.0 之后，浏览器里看到的还是旧界面，而磁盘上的
# panel.py 已经是新的。原因是 cmd_start 用
#
#     systemctl enable --now "$unit" || systemctl start "$unit"
#
# 而 `enable --now` 对**已经 active** 的单元是**空操作** —— 不报错也不重启。
# 面板进程把 PAGE 在启动时读进内存，于是永远服务旧界面。
# 表现是"装完了但什么都没变"，用户自己基本排查不出来。
group "更新后生效 (_xbd_up_unit)"
UP="$(mktemp)"
sed -n '/^_xbd_up_unit()/,/^}/p' "$ROOT/Client/lib/actions.sh" > "$UP"
[[ -s "$UP" ]] && ok "取到 _xbd_up_unit" || bad "取不到 _xbd_up_unit"

# 用桩记录 systemctl 被怎么调的
run_up() { # $1=unit_active 的返回值
  bash -c "
    set -uo pipefail
    CALLS=''
    systemctl() { CALLS=\"\$CALLS \$*\"; }
    unit_active() { return $1; }
    source '$UP'
    _xbd_up_unit demo.service
    printf '%s' \"\$CALLS\"
  " 2>/dev/null || true
}
# 注意 shell 惯例：unit_active 返回 **0 表示成功 = 正在运行**。
# 第一版把这两个值写反了，于是"函数明明是对的、测试报红"。
got=$(run_up 0)     # 0 = 运行中
case "$got" in
  *"restart demo.service"*) ok "已运行的单元 → restart（不是 enable --now 空操作）" ;;
  *) bad "已运行的单元没有 restart" "实际调用:$got" ;;
esac
got=$(run_up 1)     # 1 = 未运行
case "$got" in
  *"enable --now demo.service"*) ok "未运行的单元 → enable --now" ;;
  *) bad "未运行的单元没有 enable --now" "实际调用:$got" ;;
esac
rm -f "$UP"

# 静态兜底：更新路径上不该再有裸的 enable --now（Xray / 面板）
grep -q '_xbd_up_unit "\$XBD_U_XRAY"'  "$ROOT/Client/lib/actions.sh" \
  && ok "Xray 走 _xbd_up_unit" || bad "Xray 仍是裸 enable --now"
grep -q '_xbd_up_unit "\$XBD_U_PANEL"' "$ROOT/Client/lib/actions.sh" \
  && ok "面板走 _xbd_up_unit" || bad "面板仍是裸 enable --now"

# ---------------------------------------------------------------- 并发写
# 这三个模块都是 read-modify-write 或原子写。flock 锁的是打开的文件描述符而不是
# 进程, 所以同一进程的多线程不会被 flock 挡住 —— 必须另加 threading.Lock。
# 而临时文件名若只带 pid, 同进程多线程会算出同一个名字互相 os.replace 对方的
# 文件, 后一个直接抛 FileNotFoundError。
group "并发写 (share_meta / token_store / node_build)"
RC="$TMP/race"; mkdir -p "$RC"
CR=$(python3 - "$LIB" "$RC" <<'PY'
import sys, threading, os, json
sys.path.insert(0, sys.argv[1])
import share_meta as M, token_store as T, node_build as B
d = sys.argv[2]
out = []

def run(fn, check):
    errs = []
    def g(i):
        try: fn(i)
        except Exception as e: errs.append(repr(e))
    ts = [threading.Thread(target=g, args=(i,)) for i in range(30)]
    [t.start() for t in ts]; [t.join() for t in ts]
    return len(errs), (errs[0] if errs else ""), check()

M.save(d + "/sm", "n1", {})
e, _, ok = run(lambda i: M.save(d + "/sm", "n1", {"f%d" % i: i}),
               lambda: all((M.load(d + "/sm", "n1") or {}).get("f%d" % i) == i
                           for i in range(30)))
out.append("share_meta %d %s %s" % (e, "OK" if ok else "LOST", "" if not e else e[:40]))

e, _, ok = run(lambda i: T.write(d + "/tk", "tok1",
               {"tags": ["n%d" % i], "enabled": True, "used_count": 0,
                "max_uses": 99, "expires_at": 0}),
               lambda: T.read(d + "/tk", "tok1") is not None)
out.append("token_store %d %s %s" % (e, "OK" if ok else "BAD", "" if not e else e[:40]))

e, _, ok = run(lambda i: B.write(d + "/frag.json",
               B.build("vless", "ws", "tls", {"port": 9000 + i, "uuid": "u%d" % i})),
               lambda: bool(json.load(open(d + "/frag.json", encoding="utf-8"))))
out.append("node_build %d %s %s" % (e, "OK" if ok else "BAD", "" if not e else e[:40]))

left = [f for f in os.listdir(d) if ".tmp" in f or f.startswith((".frag", ".tok"))]
out.append("leftover %d" % len(left))
print("\n".join(out))
PY
)
assert_rc() { [[ "$2" == "0" ]] && ok "$1" || bad "$1 (异常 $2)"; }
SM=$(echo "$CR" | grep '^share_meta'); assert_rc "share_meta 30 线程并发写" "$(echo "$SM" | awk '{print $2}')"
[[ "$(echo "$SM" | awk '{print $3}')" == "OK" ]] && ok "share_meta 无改动丢失" || bad "share_meta 无改动丢失: $SM"
TS=$(echo "$CR" | grep '^token_store'); assert_rc "token_store 30 线程并发写" "$(echo "$TS" | awk '{print $2}')"
NB=$(echo "$CR" | grep '^node_build'); assert_rc "node_build 30 线程并发写" "$(echo "$NB" | awk '{print $2}')"
LF=$(echo "$CR" | grep '^leftover' | awk '{print $2}')
assert_eq "$LF" "0" "无临时文件残留"

# ---------------------------------------------------------------- 分享链接
group "分享链接生成 (nodes.build_share_link)"
python3 - "$LIB" "$CONF" <<'PY' > "$TMP/link_results"
import sys
sys.path.insert(0, sys.argv[1])
import nodes as N
conf = sys.argv[2]
n, _ = N.collect(conf)
by = {x['tag']: x for x in n}
r = {}

# REALITY 缺 pbk 必须不生成 (残缺链接会被 Client 静默丢弃)
r['reality_no_pbk'] = N.build_share_link(dict(by['vless-01']),
    {'host':'h.com','port':1,'name':'n1'}) or None
# 补上 pbk 应恢复
r['reality_ok'] = N.build_share_link(dict(by['vless-01']),
    {'host':'h.com','port':1,'name':'n1','public_key':'PK','short_id':'ab'})
# fragment 永不为空
r['no_name'] = N.build_share_link({'protocol':'vless','id':'u','network':'tcp','security':'none',
    'server_names':[],'port':1,'tag':''}, {'host':'h.com','port':1})
# 特殊字符转义
r['escape'] = N.build_share_link({'protocol':'vless','id':'u','network':'tcp','security':'reality',
    'server_names':['a.com'],'port':1,'tag':'t'},
    {'host':'h.com','port':1,'name':'x','public_key':'A+B/C=','short_id':'ab'})
# Shadowsocks SIP002
r['ss'] = N.build_share_link(dict(by['ss-02']), {'host':'h.com','port':20002,'name':'SS'})
for k, v in r.items():
    print(f"{k}\t{v if v is not None else ''}")
PY
L() { grep -m1 "^$1	" "$TMP/link_results" | cut -f2-; }
assert_eq "$(L reality_no_pbk)" "" "REALITY 缺 pbk 时不生成链接"
[[ -n "$(L reality_ok)" ]] && ok "REALITY 有 pbk 时正常生成" || bad "REALITY 有 pbk 时正常生成"
FRAG=$(L no_name); [[ "$FRAG" == *"#"* && "${FRAG##*#}" != "" ]] \
    && ok "无名称时 fragment 仍非空 (${FRAG##*#})" || bad "无名称时 fragment 仍非空"
ESC=$(L escape)
[[ "$ESC" == *"pbk=A%2BB%2FC%3D"* ]] && ok "公钥特殊字符已转义" || bad "公钥特殊字符已转义 (得到 $ESC)"
[[ "$(L ss)" == ss://* ]] && ok "Shadowsocks 生成 SIP002 链接" || bad "Shadowsocks 生成 SIP002 链接"

# ---------------------------------------------------------------- SNI / pin / hy2 参数
# 三条都是实机实证 (RN 真实节点 + CC 真客户端):
#   1. TLS 节点的分享链接里没有 sni= (旧代码只从 REALITY 的 serverNames 取),
#      客户端就拿连接地址(公网 IP)当 SNI →
#         x509: cannot validate certificate for <IP> because it doesn't
#         contain any IP SANs
#      实测: 同一条链接, sni=域名 HTTP 204 / sni=IP HTTP 000。
#   2. 只要证书文件存在就写 pinnedPeerCertSha256, 公网 CA 证书也写; 而 CDN
#      节点的边缘证书是另一张 (实测 RN 源站 Let's Encrypt 48165d74... / 边缘
#      Google Trust Services 601927a1...) →
#         peer cert is unrecognized (against pinnedPeerCertSha256)
#   3. hy2 链接丢 alpn/带宽: mihomo 认 up/down + alpn, sing-box 面板认
#      upmbps/downmbps + alpn。两种写法都要有 (名字写错是静默忽略)。
group "分享链接 SNI / 证书 pin / hy2 参数 (实机三证)"
if ! command -v openssl >/dev/null 2>&1; then
    printf '  - 本组需要 openssl 造证书 (本机没有, 已在实机跑过)\n'
else
SC="$TMP/sni"; mkdir -p "$SC/conf" "$SC/share" "$SC/certs"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SC/certs/self.key" -out "$SC/certs/self.crt" \
    -days 3650 -subj "/CN=tls.example.com" \
    -addext "subjectAltName=DNS:tls.example.com" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SC/certs/ca.key" -out "$SC/certs/ca.crt" \
    -days 3650 -subj "/CN=Test Root CA" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$SC/certs/leaf.key" -out "$SC/certs/leaf.csr" \
    -subj "/CN=leaf.example.com" >/dev/null 2>&1
openssl x509 -req -in "$SC/certs/leaf.csr" -CA "$SC/certs/ca.crt" -CAkey "$SC/certs/ca.key" \
    -CAcreateserial -out "$SC/certs/leaf.crt" -days 3650 \
    -extfile <(printf 'subjectAltName=DNS:leaf.example.com') >/dev/null 2>&1
# a) TLS 节点: 片段里没有 serverName, 只有证书 → 必须从证书 CN 取到 sni
cat > "$SC/conf/tls1.json" <<J
{"inbounds":[{"tag":"tls1","port":30001,"protocol":"vless","listen":"0.0.0.0",
 "settings":{"clients":[{"id":"u1"}],"decryption":"none"},
 "streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{
   "certificates":[{"certificateFile":"$SC/certs/self.crt","keyFile":"$SC/certs/self.key"}]},
   "xhttpSettings":{"path":"/p","mode":"auto"}}}]}
J
# b) 没有证书、没有域名 —— sni 只能"不写", 绝不允许写成 IP
cat > "$SC/conf/tls2.json" <<'J'
{"inbounds":[{"tag":"tls2","port":30002,"protocol":"vless","listen":"0.0.0.0",
 "settings":{"clients":[{"id":"u2"}],"decryption":"none"},
 "streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":""}}}]}
J
# c) hysteria2: 有证书 (CN=域名), 连接地址是 IP —— 旧代码把 IP 当 sni 写
cat > "$SC/conf/hy2.json" <<J
{"inbounds":[{"tag":"hy2","port":30003,"protocol":"hysteria","listen":"0.0.0.0",
 "settings":{"version":2,"clients":[{"auth":"AUTH"}]},
 "streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{
   "alpn":["h3"],
   "certificates":[{"certificateFile":"$SC/certs/self.crt","keyFile":"$SC/certs/self.key"}]}}}]}
J
# d) REALITY 必须保持原逻辑 (sni 取 serverNames[0])
printf '{"inbounds":[{"tag":"re1","port":30004,"protocol":"vless","listen":"0.0.0.0","settings":{"clients":[{"id":"u3"}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverNames":["re.example.com"]}}}]}\n' > "$SC/conf/re1.json"
python3 - "$LIB" "$SC" <<'PY' > "$SC/out.txt"
import json, sys, urllib.parse
sys.path.insert(0, sys.argv[1])
import nodes as N
SC = sys.argv[2]
nl, _ = N.collect(SC + "/conf")
by = {n["tag"]: n for n in nl}
res = {}
for tag, meta in (("tls1", {"host": "107.173.154.178", "port": 30001, "name": "t1"}),
                  ("tls2", {"host": "107.173.154.178", "port": 30002, "name": "t2"}),
                  ("hy2",  {"host": "107.173.154.178", "port": 30003, "name": "h2"}),
                  ("re1",  {"host": "107.173.154.178", "port": 30004, "name": "r1",
                            "public_key": "PK", "short_id": "ab"})):
    link = N.build_share_link(by[tag], dict(meta)) or ""
    q = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)
    res[tag] = {"link": link, "sni": (q.get("sni") or [""])[0],
                "up": (q.get("up") or [""])[0], "upmbps": (q.get("upmbps") or [""])[0],
                "alpn": (q.get("alpn") or [""])[0]}
print(json.dumps(res, ensure_ascii=False))
PY
S_GET() { python3 -c "
import json
d = json.load(open('$SC/out.txt'))
print(d['$1']['$2'])"; }
IPRE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
assert_eq "$(S_GET tls1 sni)" "tls.example.com" "TLS 节点的 sni 取自证书 (不是空)"
assert_eq "$(S_GET hy2 sni)"  "tls.example.com" "hysteria2 的 sni 取自证书 (不是连接地址)"
for t in tls1 tls2 hy2 re1; do
    v=$(S_GET "$t" sni)
    if [[ -n "$v" && "$v" =~ $IPRE ]]; then bad "$t 的 sni 是 IP ($v)"; else ok "$t 的链接没有把 IP 写成 sni"; fi
done
assert_eq "$(S_GET tls2 sni)" "" "拿不到域名时不写 sni (宁可省略也不写 IP)"
assert_eq "$(S_GET re1 sni)" "re.example.com" "REALITY 的 sni 仍取 serverNames"
assert_eq "$(S_GET hy2 alpn)" "h3" "hy2 链接带 alpn=h3"
# 值来自 ./conf/lib/nodes.py 的带宽口径 (默认 60/200, 可被 ${XRAY_BASE}/.hy2-bandwidth
# 覆盖) —— 这两条钉的是"两个名字都写", 不是那个常数; 常数另有一组断言钉住。
assert_eq "$(S_GET hy2 up)" "60" "hy2 链接带 up= (mihomo 认的名字)"
assert_eq "$(S_GET hy2 upmbps)" "60" "hy2 链接带 upmbps= (sing-box 面板认的名字)"

# ------------------------------------------------- 客户端链路: 链接参数不许丢
# 分享层补齐了参数, 客户端这一跳又丢 —— 实机现场: CC 上正在跑的 hysteria2
# 节点, mihomo YAML 里明明有 `up: "45 Mbps"` / `down: "150 Mbps"`, 解析出来的
# node JSON 里这两个键**一个都没有**。链路是
#     链接 → node.py → 节点 JSON → genconfig.py → 内核配置
# 任何一跳静默丢弃, 端到端就还是缺这一截, 而界面上什么提示都没有。
#
# ★ 字段名以**真内核**为准 (Xray 26.3.27 / CC 实测), 这条不能照抄文档:
#   `hysteriaSettings.up/down` 确实还在, 但 Build() 只对它打一行 Warning
#   就丢掉("congestion & up & down & udphop move to finalmask/quicParams"),
#   而 `xray run -test` 对它返回 **rc=0 / Configuration OK** ——
#   也就是说"配置能过 -test"完全不能证明带宽被采纳(本仓库吃过这个亏)。
#   真正生效的是 streamSettings.finalmask.quicParams.brutalUp/brutalDown。
#   反证(会报错才说明键真的被读了, 对照: 随便写 brutalUpXX → OK):
#     brutalUp:"50"    → rc=23 BrutalUp must be at least 65536 bytes per second
#     brutalUp:"bogus" → rc=23 strconv.ParseFloat: parsing "": invalid syntax
#   所以裸数字**绝不能**透传(内核当字节/秒, 且 50 < 65536 会让整份配置起不来),
#   必须补单位。
group "hy2 客户端链路: 链接参数不静默消失 (解析 → 生成)"
CL_HY2_LINK='hysteria2://AUTH@107.173.154.178:29604?sni=moontv.6896698.xyz&insecure=0&alpn=h3&up=50&down=200&upmbps=50&downmbps=200&mport=30000-31000&pin=694e89c0350e1c9c8c71c24cf0521c6147dee182a18ba0979b8e6bda67114e69#hysteria-04'
CL_HY2_NOBW='hysteria2://AUTH@107.173.154.178:29604?sni=moontv.6896698.xyz&insecure=0&alpn=h3#hysteria-04'
CLH=$(python3 - "$ROOT" "$CL_HY2_LINK" "$CL_HY2_NOBW" <<'PY'
import json, os, re, subprocess, sys, tempfile
root, link, nobw = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(root, "Client", "lib"))
import node as N

GEN = os.path.join(root, "Client", "lib", "genconfig.py")
res = {}

n = N.parse_node(link)
# 1) 解析这一跳: 字段必须在**顶层**, 只躺在 raw_params 里等于没保留
res["up"] = n.get("up")
res["down"] = n.get("down")
res["mport"] = n.get("mport")
res["alpn"] = n.get("alpn")
res["pin8"] = (n.get("pinned_cert_sha256") or "")[:8]


def gen(node):
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(node, f); f.close()
    o = tempfile.mktemp(suffix=".json")
    r = subprocess.run(["python3", GEN, "--node", f.name, "--output", o,
                        "--mode", "normal", "--listen", "127.0.0.1",
                        "--port-normal", "1080", "--dns", "standard",
                        "--family", "auto", "--logs", "/tmp"],
                       capture_output=True, text=True)
    os.unlink(f.name)
    if r.returncode != 0:
        return None
    ob = [x for x in json.load(open(o))["outbounds"] if x.get("tag") == "proxy"][0]
    os.unlink(o)
    return ob["streamSettings"]


def qp(ss):
    return ((ss or {}).get("finalmask") or {}).get("quicParams") or {}


ss = gen(n)
res["brutalUp"] = qp(ss).get("brutalUp")
res["brutalDown"] = qp(ss).get("brutalDown")
res["udphop"] = (qp(ss).get("udpHop") or {}).get("ports")
# 2) 已废弃的那条路一个字段都不许写: 它**能过 -test 但内核不采纳**,
#    写了等于拿"配置 OK"骗自己。
res["deprecated"] = any(k in (ss.get("hysteriaSettings") or {}) for k in ("up", "down"))
# 3) 内核语法: 必须带单位(裸数字会被当成字节/秒 → 整份配置起不来)
res["unit_ok"] = all(re.fullmatch(r"[0-9.]+ [kmgt]bps", qp(ss).get(k, ""))
                     for k in ("brutalUp", "brutalDown"))
# 4) 裸数字/带单位混写(旧节点文件、手写 JSON) 要补单位, 不能原样透传
ss2 = gen(dict(n, up=50, down="150 Mbps"))
res["bare_up"] = qp(ss2).get("brutalUp")
res["bare_down"] = qp(ss2).get("brutalDown")
# 5) 非法端口范围: 丢掉, 且不许把坏值写进内核(写进去 build 直接失败)
ss3 = gen(dict(n, mport="70000"))
res["bad_mport_hop"] = "udpHop" in qp(ss3)
res["bad_mport_keeps_bw"] = qp(ss3).get("brutalUp")
# 6) 认不出的带宽写法: 不猜、不硬塞
res["junk_up"] = qp(gen(dict(n, up="fast"))).get("brutalUp") or "SKIPPED"
# 7) 缺省: 链接没写带宽 → 配置里**不写** finalmask(不编默认值,
#    编了会让"没写"和"写了 50/200"变成同一件事)
res["nobw_has_finalmask"] = "finalmask" in (gen(N.parse_node(nobw)) or {})
# 8) 反向: 节点 → 链接 → 节点, up/down 也不能丢
back = N.parse_node(N.build_link(n))
res["rt_up"] = back.get("up")
res["rt_down"] = back.get("down")
print(json.dumps(res, ensure_ascii=False))
PY
)
CH_GET() { python3 -c "
import json,sys
print(json.loads(sys.argv[1]).get(sys.argv[2], '<无>'))" "$CLH" "$1"; }

assert_eq "$(CH_GET up)" "50 mbps" "解析: 链接的 up=50 落到节点 JSON 顶层 (不是只进 raw_params)"
assert_eq "$(CH_GET down)" "200 mbps" "解析: 链接的 down=200 落到节点 JSON 顶层"
assert_eq "$(CH_GET mport)" "30000-31000" "解析: 链接的 mport 落到节点 JSON 顶层"
assert_eq "$(CH_GET alpn)" "h3" "解析: 链接的 alpn 落到节点 JSON 顶层"
assert_eq "$(CH_GET pin8)" "694e89c0" "解析: 链接的 pin= 落到 pinned_cert_sha256 (自签节点唯一的信任来源)"
assert_eq "$(CH_GET brutalUp)" "50 mbps" "生成: 带宽写进 finalmask.quicParams.brutalUp (内核真正读的键)"
assert_eq "$(CH_GET brutalDown)" "200 mbps" "生成: 带宽写进 finalmask.quicParams.brutalDown"
assert_eq "$(CH_GET udphop)" "30000-31000" "生成: mport 写进 finalmask.quicParams.udpHop.ports"
assert_eq "$(CH_GET deprecated)" "False" "生成: 一个字段都不写已废弃的 hysteriaSettings.up/down (能过 -test 但内核丢掉)"
assert_eq "$(CH_GET unit_ok)" "True" "生成: 带宽值一律带单位 (裸数字会被内核当成字节/秒 → 整份配置起不来)"
assert_eq "$(CH_GET bare_up)" "50 mbps" "生成: 裸数字 50 (旧节点文件) 被补成 50 mbps, 不是原样透传"
assert_eq "$(CH_GET bare_down)" "150 mbps" "生成: \"150 Mbps\" 归一成内核语法"
assert_eq "$(CH_GET bad_mport_hop)" "False" "生成: 非法端口范围不写进内核 (写进去 build 直接失败)"
assert_eq "$(CH_GET bad_mport_keeps_bw)" "50 mbps" "生成: 端口范围非法不影响带宽照常下发"
assert_eq "$(CH_GET junk_up)" "SKIPPED" "生成: 认不出的带宽写法跳过 (不猜、不硬塞)"
assert_eq "$(CH_GET nobw_has_finalmask)" "False" "链接没写带宽时不编默认值 (不写 finalmask)"
assert_eq "$(CH_GET rt_up)" "50 mbps" "反向: 节点 → 链接 → 节点 的 up 不丢"
assert_eq "$(CH_GET rt_down)" "200 mbps" "反向: 节点 → 链接 → 节点 的 down 不丢"

# 服务端同一个节点自己的客户端产物也必须描述同一件事:
#   conf/hysteria2.sh 的 Xray 客户端 JSON 以前写 hysteriaSettings.up/down
#   (26.3.27 只警告就丢), 现在必须是 finalmask.quicParams。
grep -q '"finalmask": { "quicParams": { "brutalUp"' "$ROOT/conf/hysteria2.sh" \
    && ok "hysteria2.sh 的客户端 JSON 改用 finalmask.quicParams (内核真正读的键)" \
    || bad "hysteria2.sh 的客户端 JSON 还在写被丢弃的 hysteriaSettings.up/down"
grep -q '"up": "50mbps"' "$ROOT/conf/hysteria2.sh" \
    && bad "hysteria2.sh 仍在写已废弃的 hysteriaSettings.up/down" \
    || ok "hysteria2.sh 不再写已废弃的 hysteriaSettings.up/down"
grep -q 'up=$hy2_up&down=$hy2_down&upmbps=$hy2_up&downmbps=$hy2_down' "$ROOT/conf/hysteria2.sh" \
    && ! grep -q 'up=50&down=200' "$ROOT/conf/hysteria2.sh" \
    && ok "hysteria2.sh 的分享链接两种带宽名字都写 (mihomo 只认 up/down)" \
    || bad "hysteria2.sh 的分享链接少了 up=/down= (mihomo 会整条丢掉 upmbps=)"

# ---- Xray JSON 导入这一跳: 我们自己生成的产物必须能被自己读回 ----
#
# 现场: 把 RN 上真实的 /root/catmi/xray/out/hy2_client-04.xray.json 喂给
# `node.py parse` → "Xray 配置里没有可识别的出站"。原因是白名单里写的是
# "hysteria2", 而**内核与 conf/hysteria2.sh 写的都是 "hysteria"**(version 2)。
# 而且 hysteria 出站的 settings 是**扁平**的(address/port), 不是 servers[] ——
# 只加白名单会"解析成功"但 address 空、port=443。
#
# 下面两份 JSON 是从真机产物逐字抄下来的两个世代:
#   旧世代(本轮修复前, RN 上 hy2_client-02/03/04 全是这个形态):
#       带宽只在已废弃的 hysteriaSettings.up/down 里
#   新世代(conf/hysteria2.sh 现在写的): finalmask.quicParams + pin + udpHop
# 两份都必须能解析, 且带宽/跳跃/pin 一个不丢。
group "Xray JSON 导入: 自己生成的 hy2 客户端产物能被自己读回"
CLH2=$(python3 - "$ROOT" <<'PY'
import json, os, subprocess, sys, tempfile
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "Client", "lib"))
import node as N

GEN = os.path.join(root, "Client", "lib", "genconfig.py")
res = {}

# ---- 真机产物①: RN /root/catmi/xray/out/hy2_client-04.xray.json (逐字) ----
ART_OLD = """
{
  "outbounds": [
    {
      "tag": "hy2-04",
      "protocol": "hysteria",
      "settings": { "version": 2, "address": "107.173.154.178", "port": 29604 },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": { "serverName": "moontv.6896698.xyz", "alpn": ["h3"] },
        "hysteriaSettings": { "version": 2, "auth": "05615ce2-4bf4-4f4e-908e-c99a16a803e8",
                              "up": "50mbps", "down": "200mbps" }
      }
    }
  ]
}
"""
n = N.parse_xray_json(ART_OLD)
res["old_proto"] = n.get("protocol")
res["old_addr"] = n.get("address")
res["old_port"] = n.get("port")
res["old_auth"] = n.get("password")
res["old_sni"] = n.get("sni")
res["old_alpn"] = n.get("alpn")
res["old_transport"] = n.get("transport")
res["old_transport_raw"] = n.get("transport_raw")
res["old_up"] = n.get("up")
res["old_down"] = n.get("down")
res["old_src"] = n.get("bandwidth_source")


def qp(ss):
    return ((ss or {}).get("finalmask") or {}).get("quicParams") or {}


def gen(node, extra=()):
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(node, f); f.close()
    o = tempfile.mktemp(suffix=".json")
    r = subprocess.run(["python3", GEN, "--node", f.name, "--output", o,
                        "--mode", "normal", "--listen", "127.0.0.1",
                        "--port-normal", "1080", "--dns", "standard",
                        "--family", "auto", "--logs", tempfile.gettempdir()] + list(extra),
                       capture_output=True, text=True)
    os.unlink(f.name)
    if r.returncode != 0:
        return None
    ss = [x for x in json.load(open(o))["outbounds"] if x.get("tag") == "proxy"][0]["streamSettings"]
    os.unlink(o)
    return ss


# 旧世代的带宽**不能丢**: 内核不读那个位置, 但那是我们自己产物里唯一的数据源;
# 生成时必须把它搬到 finalmask。而"已废弃的位置"本身一个字段都不许再写。
ss_old = gen(n)
res["old_gen_up"] = qp(ss_old).get("brutalUp")
res["old_gen_down"] = qp(ss_old).get("brutalDown")
res["old_gen_deprecated"] = any(k in (ss_old.get("hysteriaSettings") or {}) for k in ("up", "down"))

# ---- 真机产物②: conf/hysteria2.sh 现在的自签档 (+ 端口跳跃) ----
ART_NEW = """
{
  "outbounds": [
    {
      "tag": "hy2-05",
      "protocol": "hysteria",
      "settings": { "version": 2, "address": "107.173.154.178", "port": 29605 },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": "moontv.6896698.xyz",
          "alpn": ["h3"],
          "pinnedPeerCertSha256": "694E89C0350E1C9C8C71C24CF0521C6147DEE182A18BA0979B8E6BDA67114E69"
        },
        "hysteriaSettings": { "version": 2, "auth": "05615ce2-4bf4-4f4e-908e-c99a16a803e8" },
        "finalmask": { "quicParams": { "brutalUp": "50 mbps", "brutalDown": "200 mbps",
                                       "udpHop": { "ports": "30000-31000" } } }
      }
    }
  ]
}
"""
m = N.parse_xray_json(ART_NEW)
res["new_up"] = m.get("up")
res["new_down"] = m.get("down")
res["new_src"] = m.get("bandwidth_source")
res["new_mport"] = m.get("mport")
res["new_pin"] = m.get("pinned_cert_sha256")
ss_new = gen(m)
res["new_gen_up"] = qp(ss_new).get("brutalUp")
res["new_gen_hop"] = (qp(ss_new).get("udpHop") or {}).get("ports")
res["new_gen_pin"] = ((ss_new.get("tlsSettings") or {}).get("pinnedPeerCertSha256") or "")[:8]

# ---- 权威性: 两个位置都有且冲突时, 以 finalmask 为准(旧位置只是回退) ----
both = json.loads(ART_OLD)
both["outbounds"][0]["streamSettings"]["finalmask"] = {"quicParams": {"brutalUp": "10 mbps"}}
nb = N.parse_xray_json(json.dumps(both))
res["prec_up"] = nb.get("up")            # finalmask 的 10 mbps, 不是旧位置的 50
res["prec_down"] = nb.get("down")        # 旧位置回退
res["prec_src"] = nb.get("bandwidth_source")

# ---- 单位语法: 内核的数量级(bps = bit/s)也要能原样搬运 ----
bits = json.loads(ART_NEW)
bits["outbounds"][0]["streamSettings"]["finalmask"]["quicParams"]["brutalUp"] = "800000"
res["bits_up"] = N.parse_xray_json(json.dumps(bits)).get("up")
res["bits_gen_up"] = qp(gen(N.parse_xray_json(json.dumps(bits)))).get("brutalUp")

# ---- 低于内核下限的源值: 丢弃, 不能搬进配置(搬进去内核拒收整份) ----
low = json.loads(ART_NEW)
low["outbounds"][0]["streamSettings"]["finalmask"]["quicParams"]["brutalUp"] = "40000"
res["low_up"] = N.parse_xray_json(json.dumps(low)).get("up") or "SKIPPED"
res["low_gen_hop"] = "udpHop" in qp(gen(N.parse_xray_json(json.dumps(low))))

# ---- 认不出的单位: 不猜 ----
junk = json.loads(ART_NEW)
junk["outbounds"][0]["streamSettings"]["finalmask"]["quicParams"]["brutalUp"] = "50 xyz"
res["junk_up"] = N.parse_xray_json(json.dumps(junk)).get("up") or "SKIPPED"

# ---- 没写带宽: 不许编默认值 ----
nobw = json.loads(ART_OLD)
del nobw["outbounds"][0]["streamSettings"]["hysteriaSettings"]["up"]
del nobw["outbounds"][0]["streamSettings"]["hysteriaSettings"]["down"]
res["nobw_up"] = N.parse_xray_json(json.dumps(nobw)).get("up") or "SKIPPED"
res["nobw_src"] = N.parse_xray_json(json.dumps(nobw)).get("bandwidth_source") or "SKIPPED"

# ---- 白名单没有变成"什么都收": 不认识的协议仍然要响着失败 ----
try:
    N.parse_xray_json(json.dumps({"outbounds": [{"protocol": "wireguard", "tag": "w"}]}))
    res["unknown_proto"] = "NO-RAISE"
except ValueError as e:
    res["unknown_proto"] = "raised"

# ---- 同一处共享改动: TLS 里的 pin 对非 hysteria 协议也得读 ----
ART_TROJAN = json.dumps({"outbounds": [{"tag": "t3", "protocol": "trojan",
    "settings": {"servers": [{"address": "1.2.3.4", "port": 29602, "password": "pw"}]},
    "streamSettings": {"network": "tcp", "security": "tls",
        "tlsSettings": {"serverName": "a.example", "pinnedPeerCertSha256": "ABCDEF01"}}}]})
res["trojan_pin"] = N.parse_xray_json(ART_TROJAN).get("pinned_cert_sha256")
print(json.dumps(res, ensure_ascii=False))
PY
)
CH2() { python3 -c "
import json,sys
print(json.loads(sys.argv[1]).get(sys.argv[2], '<无>'))" "$CLH2" "$1"; }

# 生成器崩了(比如解析直接抛异常) → 后面的断言会全部拿到 '<无>', 但那样只说明"值不对",
# 说不清是"生成器根本没跑完"。单独一条把这件事点出来(不静默跳过)。
if printf '%s' "$CLH2" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null; then
    ok "hy2 断言生成器跑完并产出合法 JSON（没有静默跳过）"
else
    bad "hy2 断言生成器没有产出合法 JSON（崩溃/被跳过）: $(printf '%s' "$CLH2" | tail -1)"
fi

assert_eq "$(CH2 old_proto)" "hysteria2" "真机产物① protocol:\"hysteria\" 被认出来(内核与脚本都写这个名字)"
assert_eq "$(CH2 old_addr)" "107.173.154.178" "扁平 settings.address 被读到(走 servers[] 分支会是空串)"
assert_eq "$(CH2 old_port)" "29604" "扁平 settings.port 被读到(走 servers[] 分支会是 443)"
assert_eq "$(CH2 old_auth)" "05615ce2-4bf4-4f4e-908e-c99a16a803e8" "认证从 hysteriaSettings.auth 读到"
assert_eq "$(CH2 old_sni)" "moontv.6896698.xyz" "sni 不丢"
assert_eq "$(CH2 old_alpn)" "h3" "alpn 不丢"
assert_eq "$(CH2 old_transport)" "quic" "hysteria 传输归一成 quic(与 parse_hysteria2 同一个模型)"
assert_eq "$(CH2 old_transport_raw)" "hysteria" "原始 network 写法留在 transport_raw 备查"
assert_eq "$(CH2 old_up)" "50 mbps" "旧位置(hysteriaSettings.up)的带宽按回退值收下, 不丢"
assert_eq "$(CH2 old_down)" "200 mbps" "旧位置的 down 同样收下"
assert_eq "$(CH2 old_src)" "hysteriaSettings" "并标明来源是已废弃位置(不是权威来源)"
assert_eq "$(CH2 old_gen_up)" "50 mbps" "旧世代产物 → 生成的配置把带宽搬进 finalmask.brutalUp"
assert_eq "$(CH2 old_gen_down)" "200 mbps" "旧世代产物 → brutalDown 同样搬过去"
assert_eq "$(CH2 old_gen_deprecated)" "False" "生成的配置不再写已废弃的 hysteriaSettings.up/down"
assert_eq "$(CH2 new_up)" "50 mbps" "新世代产物 finalmask.brutalUp 被读到"
assert_eq "$(CH2 new_src)" "finalmask" "来源标成 finalmask(权威位置)"
assert_eq "$(CH2 new_mport)" "30000-31000" "finalmask.quicParams.udpHop.ports 被读到"
assert_eq "$(CH2 new_pin)" "694e89c0350e1c9c8c71c24cf0521c6147dee182a18ba0979b8e6bda67114e69" "tlsSettings.pinnedPeerCertSha256 被读到(自签节点唯一的信任来源)"
assert_eq "$(CH2 new_gen_up)" "50 mbps" "新世代产物 → 生成回来带宽不丢"
assert_eq "$(CH2 new_gen_hop)" "30000-31000" "新世代产物 → 端口跳跃不丢"
assert_eq "$(CH2 new_gen_pin)" "694e89c0" "新世代产物 → 生成的配置带上 pin"
assert_eq "$(CH2 prec_up)" "10 mbps" "finalmask 与旧位置冲突时以 finalmask 为准(权威性)"
assert_eq "$(CH2 prec_down)" "200 mbps" "另一字段仍可回退到旧位置"
assert_eq "$(CH2 prec_src)" "mixed" "混合来源被如实标成 mixed"
assert_eq "$(CH2 bits_up)" "800000 bps" "内核的 bit/s 无数量级写法被原样保留(800000/8=100000 B/s)"
assert_eq "$(CH2 bits_gen_up)" "800000 bps" "这种写法也能下发回内核, 不被当成噪音丢掉"
assert_eq "$(CH2 low_up)" "SKIPPED" "低于内核下限 65536 B/s 的源值被丢弃(搬进去内核拒收整份配置)"
assert_eq "$(CH2 low_gen_hop)" "True" "丢弃低于下限的带宽不影响同节点的其它字段(udpHop 照常下发)"
assert_eq "$(CH2 junk_up)" "SKIPPED" "认不出的单位不猜(内核 Bps() 会直接报 unsupported unit)"
assert_eq "$(CH2 nobw_up)" "SKIPPED" "没写带宽时不编默认值"
assert_eq "$(CH2 nobw_src)" "SKIPPED" "没读到带宽时来源为空, 不冒充"
assert_eq "$(CH2 unknown_proto)" "raised" "没把白名单放宽成\"什么都收\": 不认识的协议仍然报错"
assert_eq "$(CH2 trojan_pin)" "abcdef01" "同一处共享改动: 非 hysteria 产物的 pin 也读到了(小写归一)"

# 内核在就用真内核把"旧世代产物 → 配置"这一条验穿: 带宽搬到了 finalmask, 配置起得来
XK2="${XRAY_BIN:-}"
[[ -z "$XK2" && -x /root/catmi/xray/xrayls ]] && XK2=/root/catmi/xray/xrayls
if [[ -n "$XK2" && -x "$XK2" ]]; then
    H2V="$TMP/hyv"; mkdir -p "$H2V"
    python3 - "$ROOT" "$H2V" <<'PY'
import os, subprocess, sys, json
root, work = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "Client", "lib"))
import node as N
art = json.dumps({"outbounds": [{"tag": "hy2-04", "protocol": "hysteria",
    "settings": {"version": 2, "address": "107.173.154.178", "port": 29604},
    "streamSettings": {"network": "hysteria", "security": "tls",
        "tlsSettings": {"serverName": "moontv.6896698.xyz", "alpn": ["h3"]},
        "hysteriaSettings": {"version": 2, "auth": "a", "up": "50mbps", "down": "200mbps"}}}]})
json.dump(N.parse_xray_json(art), open(os.path.join(work, "n.json"), "w"))
PY
    python3 "$ROOT/Client/lib/genconfig.py" --node "$H2V/n.json" --output "$H2V/out.json" \
        --mode normal --listen 127.0.0.1 --port-normal 1080 --dns standard \
        --family auto --logs "$H2V" >/dev/null 2>&1
    if "$XK2" run -test -c "$H2V/out.json" >"$H2V/test.log" 2>&1; then
        ok "真内核 xray run -test: 真机产物 → 生成的配置 Configuration OK"
    else
        bad "真机产物生成的配置过不了内核: $(tail -1 "$H2V/test.log")"
    fi
    # 反向: 低于下限的带宽不许写进去 —— 写了内核会拒收整份配置
    python3 -c "
import json,sys
n=json.load(open('$H2V/n.json')); n['up']='1 kbps'; n['down']='0.5 kbps'
json.dump(n, open('$H2V/n_low.json','w'))"
    python3 "$ROOT/Client/lib/genconfig.py" --node "$H2V/n_low.json" --output "$H2V/out_low.json" \
        --mode normal --listen 127.0.0.1 --port-normal 1080 --dns standard \
        --family auto --logs "$H2V" >/dev/null 2>&1
    if "$XK2" run -test -c "$H2V/out_low.json" >"$H2V/test_low.log" 2>&1; then
        ok "真内核: 低于下限的带宽被跳过, 配置照样起得来(写进去就是 rc=23 整份拒收)"
    else
        bad "低于下限的带宽还是写进去了: $(tail -1 "$H2V/test_low.log")"
    fi
else
    ok "（跳过内核校验用例：本机没有 xray 二进制）"
    ok "（跳过内核校验用例：本机没有 xray 二进制）"
fi


# ---- 证书 pin: 公网 CA 不写, 自签才写 ----
PIN_SELF=$(bash -c "source '$LIB/cert.sh'; x_cert_client_pin '$SC/certs/self.crt' 1 0")
PIN_CA=$(bash -c "source '$LIB/cert.sh'; x_cert_client_pin '$SC/certs/leaf.crt' 1 0")
PIN_EDGE=$(bash -c "source '$LIB/cert.sh'; x_cert_client_pin '$SC/certs/self.crt' 0 0")
PIN_FORCE=$(bash -c "source '$LIB/cert.sh'; x_cert_client_pin '$SC/certs/leaf.crt' 0 1")
[[ -n "$PIN_SELF" ]] && ok "自签证书 + TLS 终止于本节点 → 写 pin" || bad "自签证书没写 pin"
assert_eq "$PIN_CA" "" "公网 CA 证书不写 pin"
assert_eq "$PIN_EDGE" "" "TLS 不在本节点终结 (CDN/nginx) 不写 pin"
[[ -n "$PIN_FORCE" ]] && ok "显式要求 (force=1) 时公网 CA 也写 pin" || bad "显式要求时没写 pin"

# 产物级: 真跑 render_client 的"生产形态" —— CDN-ECH + 公网 CA 证书。
# 单测函数还不够: 出问题的是"函数返回值有没有被写进 JSON"。
RC="$TMP/rc"; mkdir -p "$RC"
awk '/^render_client\(\) \{/{f=1;print;next} f && /^[A-Za-z_][A-Za-z0-9_]*\(\) \{/{exit} f{print}' \
    "$ROOT/conf/vlessxhttpecn.sh" > "$RC/fn.sh"
if [[ -s "$RC/fn.sh" ]]; then
    cat > "$RC/run.sh" <<RSH
set -uo pipefail
source '$LIB/cert.sh'
print_info(){ :; }; print_ok(){ :; }; print_warn(){ :; }; print_error(){ :; }; print_title(){ :; }
urlencode(){ python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "\$1"; }
source '$RC/fn.sh'
OUT_DIR='$RC'; PROTO=vless-xhttp; PROTO_NAME=N; index=9; num2=9
VLESS_TRANSPORT=xhttp; XHTTP_MODE=auto; XHTTP_PATH=/p; WS_PATH=/p
UUID=u1; CLIENT_ENC=none; CERT_DOMAIN=cdn.example.com; XRAY_BASE='$RC'
XRAY_CLIENT_SOCKS_PORT=10899; VLESS_PORT=8443; NPORT=443; PUBLIC_IP_V4=1.2.3.4; PUBLIC_IP_V6=''
ECH_CONFIG_LIST=x; CLIENT_SNI=''
ACCESS_MODE=\$1; ECH_MODE=\$2; CERT_FILE=\$3
LINK_HOST=cdn.example.com; LINK_PORT=443
render_client >/dev/null 2>&1
python3 -c "
import json
d = json.load(open('$RC/vless-xhttp_client-9.json'))
t = d['outbounds'][0]['streamSettings']['tlsSettings']
print(t.get('pinnedPeerCertSha256', ''))"
RSH
    RCJ=$(bash "$RC/run.sh" cdn cdn "$SC/certs/leaf.crt" 2>/dev/null)
    assert_eq "$RCJ" "" "CDN-ECH + 公网 CA 证书 → 客户端 JSON 里没有 pin"
    RCJ2=$(bash "$RC/run.sh" cdn direct "$SC/certs/self.crt" 2>/dev/null)
    [[ -n "$RCJ2" ]] && ok "direct-ECH + 自签证书 → 客户端 JSON 里仍写 pin" \
        || bad "direct-ECH + 自签证书时 pin 丢了"
else
    bad "render_client 抽取失败 (无法做产物级断言)"
fi
fi

# ---------------------------------------------------------------- 令牌存储
group "令牌存储 (token_store.py)"
SH="$TMP/share"; mkdir -p "$SH/tokens"
python3 - "$LIB" "$SH" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import token_store as T
T.write(sys.argv[2], 't1', {'tags':['a'],'enabled':True,'used_count':0,'max_uses':2,'expires_at':0})
PY
python3 - "$LIB" "$SH" <<'PY' > "$TMP/consume"
import sys, threading; sys.path.insert(0, sys.argv[1])
import token_store as T
d = sys.argv[2]
ok_n = []; lk = threading.Lock()
def w():
    r, _ = T.consume_once(d, 't1')
    if r:
        with lk: ok_n.append(1)
ts = [threading.Thread(target=w) for _ in range(20)]
[t.start() for t in ts]; [t.join() for t in ts]
print(len(ok_n), T.read(d, 't1')['used_count'])
PY
read -r ALLOWED CNT < "$TMP/consume"
assert_eq "$ALLOWED" "2" "20 线程抢 2 次: 放行数精确"
assert_eq "$CNT" "2" "20 线程抢 2 次: 计数精确, 无超发"

python3 - "$LIB" "$SH" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import token_store as T
d=sys.argv[2]
T.write(d,'t2',{'enabled':False,'tags':['a'],'used_count':0,'max_uses':0,'expires_at':0})
T.write(d,'t3',{'enabled':True,'tags':['a'],'used_count':0,'max_uses':0,'expires_at':1})
T.write(d,'t4',{'enabled':True,'tags':['a'],'used_count':9,'max_uses':9,'expires_at':0})
PY
R=$(python3 -c "
import sys;sys.path.insert(0,'$LIB');import token_store as T
d='$SH'
print('|'.join([T.consume_once(d,'t2')[1], T.consume_once(d,'t3')[1], T.consume_once(d,'t4')[1]]))")
assert_eq "$R" "disabled|expired|used up" "三态判定与 410 文案一致"
S=$(python3 -c "
import sys;sys.path.insert(0,'$LIB');import token_store as T
print(T.status_of({'enabled':True,'max_uses':9,'used_count':9,'expires_at':0}))")
assert_eq "$S" "用尽" "列表状态与服务端共用 status_of"

# ---------------------------------------------------------------- 节点生成
group "节点生成 (node_build.py)"
python3 - "$LIB" <<'PY' > "$TMP/nb"
import sys; sys.path.insert(0, sys.argv[1])
import node_build as B
out=[]
try:
    B.build("vless","ws","reality",{"port":443,"uuid":"u","private_key":"k","sni":"a.com"}); out.append("ws_reality=NOT_REJECTED")
except B.NodeError: out.append("ws_reality=rejected")
try:
    B.build("trojan","ws","tls",{"port":443}); out.append("no_password=NOT_REJECTED")
except B.NodeError: out.append("no_password=rejected")
try:
    B.build("vless","ws","tls",{}); out.append("no_port=NOT_REJECTED")
except B.NodeError: out.append("no_port=rejected")
sp = B.build("trojan","ws","tls",{"port":8443,"password":"p","cert_file":"/c","key_file":"/k","sni":"d.com","path":"/t"})
out.append("trojan_ws_network="+sp["inbounds"][0]["streamSettings"]["network"])
out.append("trojan_ws_path="+sp["inbounds"][0]["streamSettings"]["wsSettings"]["path"])
print("\n".join(out))
PY
NB() { grep -m1 "^$1=" "$TMP/nb" | cut -d= -f2-; }
assert_eq "$(NB ws_reality)" "rejected" "非法组合 REALITY+WS 被拒绝"
assert_eq "$(NB no_password)" "rejected" "缺必填字段给出 NodeError 而非 KeyError"
assert_eq "$(NB no_port)" "rejected" "缺端口被拒绝 (无 443 默认值)"
assert_eq "$(NB trojan_ws_network)" "ws" "Trojan+WS 缺口已填补"
assert_eq "$(NB trojan_ws_path)" "/t" "WS path 正确写入"

# ---------------------------------------------------------------- 部署规划
group "部署规划 (deploy.py)"
python3 - "$LIB" <<'PY' > "$TMP/dp"
import sys; sys.path.insert(0, sys.argv[1])
import deploy as D
r = D.plan("trojan","ws","tls",{"port":8443,"domain":"d.com","tag":"t","password":"p","path":"/t"}, tier="nginx")
print("ng_listen=%s" % r["fragment"]["inbounds"][0]["listen"])
print("ng_public=%s" % r["meta"]["port"])
print("ng_proxy=%s" % r["nginx"]["port"])
r2 = D.plan("trojan","ws","tls",{"port":8443,"domain":"d.com","tag":"t2","password":"p"}, tier="cdn")
print("cdn_listen=%s" % r2["fragment"]["inbounds"][0]["listen"])
print("cdn_public=%s" % r2["meta"]["port"])
print("cdn_nginx=%s" % r2["nginx"])
r3 = D.plan("vless","tcp","none",{"port":443,"domain":"d.com","uuid":"u","tag":"t3"}, tier="cdn")
print("tcp_cdn_errors=%d" % len(r3["errors"]))
PY
DP() { grep -m1 "^$1=" "$TMP/dp" | cut -d= -f2-; }
assert_eq "$(DP ng_listen)" "127.0.0.1" "nginx 档位: Xray 只听本机"
assert_eq "$(DP ng_public)" "443" "nginx 档位: 对外端口是 443 而非 Xray 端口"
assert_eq "$(DP ng_proxy)" "8443" "nginx 档位: 反代指向 Xray 实际端口"
assert_eq "$(DP cdn_listen)" "0.0.0.0" "CDN 档位: Xray 听 0.0.0.0 (否则回源被拒)"
assert_eq "$(DP cdn_public)" "8443" "CDN 档位: 对外端口 = Xray 端口"
assert_eq "$(DP cdn_nginx)" "None" "CDN 档位: 不需要 nginx"
assert_eq "$(DP tcp_cdn_errors)" "1" "裸TCP+无加密+CDN 在规划阶段被拒"

# ---------------------------------------------------------------- nginx 幂等
# --block 与 --path: 反向代理要给一条隧道单开 location 前缀, 而不是抢占整个站点。
# 这两个参数此前一个是死参数(传进去从没被用过), 一个根本不存在。
RB="$TMP/rb.conf"
cat > "$RB" <<'EOF'
server {
    listen 443 ssl;
    server_name r.example;
    location / {
        return 444;
    }
}
EOF
cp "$RB" "$RB.orig"
# 不带 --block 时 --port 是必需的 (自动生成要拿它填 proxy_pass)
python3 "$LIB/nginx_apply.py" --file "$RB" --domain r.example --nginx none >/dev/null 2>&1
assert_eq "$?" "2" "既无 --port 也无 --block 时被拒"
python3 "$LIB/nginx_apply.py" --file "$RB" --domain r.example --remove --nginx none >/dev/null 2>&1

# --path: 自定义 location 前缀
python3 "$LIB/nginx_apply.py" --file "$RB" --domain r.example --port 8443 \
    --path /HCaVHO3U --nginx none >/dev/null 2>&1
grep -q 'location /HCaVHO3U {' "$RB" && ok "--path 写出自定义 location 前缀" \
    || bad "--path 没生效"
grep -qE '^    location / \{' "$RB" && ok "--path 不影响用户原有的 location /" \
    || bad "--path 破坏了原有 location"

# --block: 片段文件必须真的被读进去用, 而不是静默走自动生成
cat > "$TMP/rb.block" <<'EOF'
location /custom {
    proxy_pass http://127.0.0.1:9999;
    proxy_set_header Connection "upgrade";
}
EOF
python3 "$LIB/nginx_apply.py" --file "$RB" --domain r.example --remove --nginx none >/dev/null 2>&1
python3 "$LIB/nginx_apply.py" --file "$RB" --domain r.example \
    --block "$TMP/rb.block" --nginx none >/dev/null 2>&1
grep -q 'location /custom {' "$RB" && ok "--block 的自定义内容被写入" \
    || bad "--block 的自定义内容没写进去"
grep -q '127.0.0.1:9999' "$RB" && ok "--block 覆盖了自动生成的 proxy_pass" \
    || bad "--block 没覆盖自动生成"

# 片段内部必须保留相对缩进: location 里的指令不能和 location 平级, 否则 nginx -t
# 会报 unexpected "}"
IND=$(grep -A1 'location /custom {' "$RB" | sed -n '2p' | sed 's/[^ ].*//' | wc -c)
LOC=$(grep 'location /custom {' "$RB" | sed 's/[^ ].*//' | wc -c)
if [[ "$IND" -gt "$LOC" ]]; then ok "--block 保留了片段内部的相对缩进"
else bad "--block 抹平了相对缩进 (指令与 location 平级, nginx -t 会失败)"; fi

python3 "$LIB/nginx_apply.py" --file "$RB" --domain r.example --remove --nginx none >/dev/null 2>&1
if diff -q "$RB.orig" "$RB" >/dev/null 2>&1; then ok "--block 摘除后逐字节还原"
else bad "--block 摘除后有残留"; fi

# 没装 nginx 时不该抛 traceback —— 只跳过校验并说明
# "没装 nginx" 要靠 PATH 去掉它来模拟, 不能靠传一个不存在的参数 —— 后者在装了
# nginx 的机器上会真的执行 nginx, 于是走进另一条分支, 断言跟着变。
OUT=$(NGINX_CONF_ROOTS="$TMP/rbroot" PATH="/usr/bin:/bin" python3 -c "
import os, shutil, subprocess, sys
env = dict(os.environ); env['PATH'] = '$TMP/nopath'
os.makedirs('$TMP/nopath', exist_ok=True)
for t in ('python3', 'sh', 'grep', 'sed', 'cat', 'base64'):
    p = shutil.which(t, path='/usr/bin:/bin')
    if p:
        d = os.path.join('$TMP/nopath', t)
        if not os.path.exists(d): os.symlink(p, d)
r = subprocess.run([sys.executable, '$LIB/nginx_apply.py', '--file', '$RB',
                    '--domain', 'r.example', '--path', '/node', '--port', '8443'],
                   capture_output=True, text=True, env=env)
sys.stdout.write(r.stdout + r.stderr)")
case "$OUT" in
  *Traceback*) bad "nginx 二进制缺失时抛了 traceback" ;;
  *已写入*)    ok "nginx 二进制缺失时干净报错并说明" ;;
  *)           bad "nginx 缺失时的输出不符合预期: $OUT" ;;
esac
python3 "$LIB/nginx_apply.py" --file "$RB" --domain r.example --remove --nginx none >/dev/null 2>&1

group "nginx 幂等 (nginx_apply.py)"
SITE="$TMP/site.conf"
cat > "$SITE" <<'EOF'
server {
    listen 443 ssl http2;
    server_name d.example.com;
    location /admin {
        proxy_pass http://127.0.0.1:9000;
    }
    root /var/www/html;
}
EOF
cp "$SITE" "$SITE.orig"
for _ in 1 2 3; do
    python3 "$LIB/nginx_apply.py" --file "$SITE" --domain d.example.com --port 8443 --nginx none >/dev/null 2>&1
done
B1=$(grep -c 'xray-core BEGIN d.example.com' "$SITE")
assert_eq "$B1" "1" "连插 3 次仍只有 1 段 (幂等)"
grep -q 'location /admin' "$SITE" && ok "用户自己的 location 未被动" || bad "用户自己的 location 未被动"
python3 "$LIB/nginx_apply.py" --file "$SITE" --domain d.example.com --remove --nginx none >/dev/null 2>&1
if diff -q "$SITE.orig" "$SITE" >/dev/null 2>&1; then ok "移除后与原文件逐字节一致"; else bad "移除后与原文件逐字节一致"; fi

# 端口变更不留残留
python3 "$LIB/nginx_apply.py" --file "$SITE" --domain d.example.com --port 8443 --nginx none >/dev/null 2>&1
python3 "$LIB/nginx_apply.py" --file "$SITE" --domain d.example.com --port 9999 --nginx none >/dev/null 2>&1
OLD=$(grep -c '8443' "$SITE" || true); NEW=$(grep -c '9999' "$SITE" || true)
assert_eq "$OLD" "0" "换端口后旧端口号无残留"
assert_eq "$NEW" "1" "新端口号已写入"

# nginx -t 失败必须回滚
cp "$SITE.orig" "$SITE"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nginx" <<'EOF'
#!/bin/sh
[ "$1" = "-t" ] && { echo "nginx: [emerg] bad directive" >&2; exit 1; }
exit 0
EOF
chmod +x "$TMP/bin/nginx"
PATH="$TMP/bin:$PATH" python3 "$LIB/nginx_apply.py" --file "$SITE" --domain d.example.com --port 8443 >/dev/null 2>&1
if diff -q "$SITE.orig" "$SITE" >/dev/null 2>&1; then ok "nginx -t 失败已回滚"; else bad "nginx -t 失败已回滚"; fi

# ★ 写入前的前置校验: 站点**本来就是坏的**时, 一个字都不该改。
#   没有这一关, 我们会去动一个坏文件, 然后回滚, 把"配置坏了"这件事记在
#   这次操作头上 —— 用户看到"插入失败", 真正的原因 (本来就坏) 被掩盖。
cp "$SITE.orig" "$SITE"
rm -f "$SITE.xray-core-bak"
RC=0
PATH="$TMP/bin:$PATH" python3 "$LIB/nginx_apply.py" --file "$SITE" --domain d.example.com --port 8443 >/dev/null 2>&1 || RC=$?
assert_eq "$RC" "3" "现有配置不通过 nginx -t 时拒绝操作 (rc=3)"
if diff -q "$SITE.orig" "$SITE" >/dev/null 2>&1; then ok "拒绝时文件未被改动"; else bad "拒绝时文件被改动了"; fi
[[ -f "$SITE.xray-core-bak" ]] && bad "拒绝时仍留下了备份文件" || ok "拒绝时没有多余产物 (没写备份)"
# --skip-precheck 是给"就是来修这份坏配置"的场景留的出口: 这时才会走到
# 写入后的校验与回滚 (文件仍然要能恢复原样)
cp "$SITE.orig" "$SITE"
PATH="$TMP/bin:$PATH" python3 "$LIB/nginx_apply.py" --file "$SITE" --domain d.example.com \
    --port 8443 --skip-precheck >/dev/null 2>&1
if diff -q "$SITE.orig" "$SITE" >/dev/null 2>&1; then ok "--skip-precheck 走写入路径, 失败后照样回滚"; else bad "--skip-precheck 回滚失败"; fi

# ---------------------------------------------------------------- 精确生命周期
# 这一组守的是"删除/回收/插入"的**精确性**: 选对 server 块、认对自己那一段、
# 不碰别人的东西、回收有上限。每一条都对应一个真实踩过的形态, 见
# research/known-issues/x-nginx-and-ports.md 的三方对照表。
group "nginx 生命周期: 选块 / 精确删除 / 回收 (nginx_apply.py)"

# ① 站点文件里通常有两个同 server_name 的块: 80 的 301 跳转块在前, 443 的真站点
#    在后。取"第一个 server 块"会把片段插进跳转块 —— `return 301` 先命中,
#    location 永远到不了, 而 nginx -t 是绿的 (静默失效)。
TWO="$TMP/two.conf"
cat > "$TWO" <<'EOF'
server {
    listen 80;
    server_name node.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name node.example.com;
    ssl_certificate /tmp/fake.pem;
    ssl_certificate_key /tmp/fake.pem;
    # 注释里的大括号 { } 不该影响块识别
    location / { return 404; }
}
EOF
python3 "$LIB/nginx_apply.py" --file "$TWO" --domain node.example.com \
    --path /node --port 23456 --nginx none >/dev/null 2>&1
TL=$(grep -n 'xray-core BEGIN' "$TWO" | cut -d: -f1)
SL=$(grep -n 'listen 443' "$TWO" | cut -d: -f1)
if [[ -n "$TL" && "$TL" -gt "$SL" ]]; then ok "插进 443 的 server 块 (不是 80 跳转块)"
else bad "插错了 server 块: 标记在第 $TL 行, 443 在第 $SL 行"; fi

# ② 文件里还有**别人的**站点时, 只能插进自己域名那个块
MV="$TMP/multi.conf"
cat > "$MV" <<'EOF'
server {
    listen 443 ssl;
    server_name other.example.com;
    location / { return 444; }
}
server {
    listen 443 ssl;
    server_name mine.example.com;
    location / { return 445; }
}
EOF
python3 "$LIB/nginx_apply.py" --file "$MV" --domain mine.example.com \
    --path /node --port 23457 --nginx none >/dev/null 2>&1
# 标记必须出现在 mine 的块里: mine 的块从第 6 行开始
ML=$(grep -n 'xray-core BEGIN' "$MV" | cut -d: -f1)
if [[ -n "$ML" && "$ML" -gt 6 ]]; then ok "多站点文件里插进目标域名的块 (没插进别人的站)"
else bad "插进了别人的 server 块 (标记在第 $ML 行)"; fi

# ③ 域名在文件里根本不存在 -> 拒绝, 且一个字都不写 (绝不猜)
NT="$TMP/nothere.conf"
printf 'server { listen 443 ssl; server_name a.example.com; }\nserver { listen 443 ssl; server_name b.example.com; }\n' > "$NT"
cp "$NT" "$NT.orig"
RC=0
python3 "$LIB/nginx_apply.py" --file "$NT" --domain zzz.example.com --port 23456 --nginx none >/dev/null 2>&1 || RC=$?
assert_eq "$RC" "3" "域名不在文件里时拒绝写入 (rc=3)"
diff -q "$NT.orig" "$NT" >/dev/null 2>&1 && ok "拒绝时文件逐字节未动" || bad "拒绝时文件被改动"

# ④ 同名 location: 再插一个会让 nginx 直接 emerg (duplicate location)。
#    提前拒绝, 而不是"写进去 -> -t 失败 -> 回滚"给用户一条看不懂的日志。
DUP="$TMP/dup.conf"
printf 'server {\n    listen 443 ssl;\n    server_name c.example;\n    location / { return 444; }\n}\n' > "$DUP"
cp "$DUP" "$DUP.orig"
RC=0
python3 "$LIB/nginx_apply.py" --file "$DUP" --domain c.example --port 1234 --nginx none >/dev/null 2>&1 || RC=$?
assert_eq "$RC" "4" "同名 location 提前拒绝 (rc=4)"
diff -q "$DUP.orig" "$DUP" >/dev/null 2>&1 && ok "同名冲突时文件未动" || bad "同名冲突时文件被改了"
python3 "$LIB/nginx_apply.py" --file "$DUP" --domain c.example --port 1234 --nginx none --dry-run 2>/dev/null | grep 'proxy_pass' >/dev/null \
    && ok "--dry-run 仍可预览 (不因冲突拒绝)" || bad "--dry-run 被冲突拦住, 用户看不到会插什么"

# ⑤ 同一域名两条路径: 共存 + 精确删除 + 整域名收工 + 逐字节还原
ID="$TMP/idem.conf"
printf 'server {\n    listen 443 ssl;\n    server_name d.example;\n    location / { return 444; }\n}\n' > "$ID"
cp "$ID" "$ID.orig"
python3 "$LIB/nginx_apply.py" --file "$ID" --domain d.example --path /t1 --port 1111 --nginx none >/dev/null 2>&1
python3 "$LIB/nginx_apply.py" --file "$ID" --domain d.example --path /t2 --port 2222 --nginx none >/dev/null 2>&1
assert_eq "$(grep -c 'xray-core BEGIN' "$ID")" "2" "同域名两条路径各占一段 (不互相替换)"
python3 "$LIB/nginx_apply.py" --file "$ID" --domain d.example --path /t1 --remove --nginx none >/dev/null 2>&1
assert_eq "$(grep -c 'xray-core BEGIN' "$ID")" "1" "--path 只摘自己那一段 (另一条不动)"
grep -q '2222' "$ID" && ok "另一条路径的片段完好" || bad "另一条被连坐删掉了"
python3 "$LIB/nginx_apply.py" --file "$ID" --domain d.example --remove --nginx none >/dev/null 2>&1
diff -q "$ID.orig" "$ID" >/dev/null 2>&1 && ok "默认 --remove 整域名收工并逐字节还原" || bad "整域名摘除后有残留"

# ⑥ 删一个没插过的域名: 零副作用 —— 不写盘、不动备份、不 reload。
#    (以前照样走完整套: 覆盖备份槽, 把"插入前的原件"抹掉, 幂等只剩文件内容一致)
NZ="$TMP/noop.conf"
printf 'server {\n    listen 443 ssl;\n    server_name e.example;\n}\n' > "$NZ"
python3 "$LIB/nginx_apply.py" --file "$NZ" --domain e.example --path /x --port 1111 --nginx none >/dev/null 2>&1
NZ_SUM=$(md5sum "$NZ" | cut -d' ' -f1)
NZ_BAK=$(stat -c %Y "$NZ.xray-core-bak")
sleep 1
python3 "$LIB/nginx_apply.py" --file "$NZ" --domain nope.example --remove --nginx none >/dev/null 2>&1
assert_eq "$(md5sum "$NZ" | cut -d' ' -f1)" "$NZ_SUM" "无可摘内容时文件不变"
assert_eq "$(stat -c %Y "$NZ.xray-core-bak")" "$NZ_BAK" "无可摘内容时备份槽不被覆盖"

# ⑦ 备份回收: 只回收**本工具自己的命名**, 保留最新 N 份, 站点文件没了就不碰
BK="$TMP/bak.conf"
printf 'server {\n    listen 443 ssl;\n    server_name f.example;\n    location / { return 444; }\n}\n' > "$BK"
for i in 1 2 3 4 5 6; do
    python3 "$LIB/nginx_apply.py" --file "$BK" --domain f.example --path /p --port 2400$i --nginx none >/dev/null 2>&1
done
# 别的工具/用户自己的备份, 一个都不能被回收
touch "$BK.bak" "$BK.sbpanel-bak" "$BK.mihomo-core-cdn-bak"
python3 "$LIB/nginx_apply.py" --file "$BK" --prune-backups --keep 2 >/dev/null 2>&1
HIST=$(ls -1 "$BK.xray-core-bak".* 2>/dev/null | wc -l)
[[ "$HIST" -le 2 ]] && ok "历史备份有上限 (回收后 $HIST 份 ≤ keep=2)" || bad "历史备份没有回收 (还有 $HIST 份)"
[[ -f "$BK.xray-core-bak" ]] && ok "规范备份 (回滚依据) 永远保留" || bad "规范备份被回收了"
[[ -f "$BK.bak" && -f "$BK.sbpanel-bak" && -f "$BK.mihomo-core-cdn-bak" ]] \
    && ok "别人的备份一份都没动" || bad "回收碰了不属于自己的备份"
mv "$BK" "$BK.gone"
BEFORE=$(ls -1 "$BK.xray-core-bak".* 2>/dev/null | wc -l)
python3 "$LIB/nginx_apply.py" --file "$BK" --prune-backups --keep 1 >/dev/null 2>&1
AFTER=$(ls -1 "$BK.xray-core-bak".* 2>/dev/null | wc -l)
assert_eq "$AFTER" "$BEFORE" "站点文件已不在时不回收备份 (可能是唯一副本)"

# ⑧ 孤儿清理: 只删本工具的标记段, 用户手写的死反代必须原样留着
#    (sing-box 的 cdn_prune 按"顶层 location + proxy_pass 127.0.0.1:死端口"的
#     形状认领, 那个形状正是用户手写反代的样子 —— 判据是猜的就会误删)
OR="$TMP/orph.conf"
cat > "$OR" <<'EOF'
server {
    listen 443 ssl;
    server_name live.example;
    location /myapp {
        proxy_pass http://127.0.0.1:8080;
    }
    # >>> xray-core BEGIN live.example >>>
    location / { proxy_pass http://127.0.0.1:22401; }
    # <<< xray-core END live.example <<<
    # >>> xray-core BEGIN dead.example|/p >>>
    location /p { proxy_pass http://127.0.0.1:22402; }
    # <<< xray-core END dead.example|/p <<<
}
EOF
NGINX_CONF_ROOTS="$TMP" python3 "$LIB/nginx_apply.py" --file "$OR" --prune-orphans live.example --nginx none >/dev/null 2>&1
assert_eq "$(grep -c 'dead.example' "$OR")" "0" "孤儿片段被清掉"
assert_eq "$(grep -c 'BEGIN live.example' "$OR")" "1" "活着的片段保留"
assert_eq "$(grep -c 'myapp' "$OR")" "1" "用户手写的 location 一个字符都没动"

# ⑨ 旧标记 (只有域名) 升级: 用 --path 重插时不能留下两条同名 location
LG="$TMP/legacy.conf"
cat > "$LG" <<'EOF'
server {
    listen 443 ssl;
    server_name r.example;
    # >>> xray-core BEGIN r.example >>>
    location /HCaVHO3U {
        proxy_pass http://127.0.0.1:25333;
    }
    # <<< xray-core END r.example <<<
}
EOF
python3 "$LIB/nginx_apply.py" --file "$LG" --domain r.example --path /HCaVHO3U \
    --port 45630 --nginx none >/dev/null 2>&1
assert_eq "$(grep -c 'location /HCaVHO3U' "$LG")" "1" "旧标记升级后不留重复 location"
grep -q '45630' "$LG" && ok "旧标记升级后端口是新值" || bad "旧标记升级后端口还是旧的"

# ⑩ node.sh 删节点时按 path 精确摘除 (改回按域名整段删就会连坐同域名的隧道)
grep -q -- '--path "\$npath" --remove' "$ROOT/conf/node.sh" \
    && ok "node.sh 摘除带 --path (不连坐同域名别的段)" || bad "node.sh 仍按域名整段摘除"
grep -q -- '--prune-orphans' "$ROOT/conf/node.sh" \
    && ok "node.sh 孤儿检查给出安全清理命令" || bad "node.sh 没给出孤儿清理入口"

# ★ 容器探测: 只认容器名 nginx / nginx-proxy 会漏掉"名字叫 web、镜像却是 nginx"
#   的部署 —— 那时探测返回 None, 于是又去改宿主机上 nginx 根本不读的文件
#   (提示写入成功、reload 成功, 站点毫无变化)。
#   与 SB (cdn_probe_nginx) 同口径: 容器名或镜像名里带 nginx 就算。
DKP="$TMP/dkprobe"; mkdir -p "$DKP/bin"
cat > "$DKP/bin/docker" <<'EOF'
#!/bin/sh
printf 'web\tnginx:alpine\n'
EOF
chmod +x "$DKP/bin/docker"
PROBE=$(PATH="$DKP/bin:$PATH" python3 -c "
import sys; sys.path.insert(0,'$LIB'); import nginx_apply as N; print(N.probe_docker() or '')")
assert_eq "$PROBE" "web" "容器名不含 nginx 但镜像含 nginx 时也认得出来"
cat > "$DKP/bin/docker" <<'EOF'
#!/bin/sh
printf 'myprox\tnginx:alpine\nother\tredis:7\n'
EOF
chmod +x "$DKP/bin/docker"
PROBE=$(PATH="$DKP/bin:$PATH" python3 -c "
import sys; sys.path.insert(0,'$LIB'); import nginx_apply as N; print(N.probe_docker() or '')")
assert_eq "$PROBE" "myprox" "镜像名带 nginx 的容器挑得出来 (不选 redis)"

# ---------------------------------------------------------------- 证书
group "证书 (cert.sh)"
mkdir -p "$TMP/cc/conf" "$TMP/cc/nginx"
printf '{"inbounds":[{"tag":"t","streamSettings":{"tlsSettings":{"certificates":[{"certificateFile":"%s/live.crt"}]}}}]}\n' "$TMP/cc" > "$TMP/cc/conf/t.json"
printf 'server {\n  ssl_certificate %s/ng.crt;\n}\n' "$TMP/cc" > "$TMP/cc/nginx/s.conf"
touch "$TMP/cc/live.crt" "$TMP/cc/ng.crt" "$TMP/cc/old.crt"
CU=$(CONF_DIR="$TMP/cc/conf" X_CERT_NGINX_DIRS="$TMP/cc/nginx" bash -c \
  "source '$LIB/cert.sh'; x_cert_in_use '$TMP/cc/live.crt' && echo Y || echo N")
assert_eq "$CU" "Y" "检测出被 Xray 片段引用的证书"
CU=$(CONF_DIR="$TMP/cc/conf" X_CERT_NGINX_DIRS="$TMP/cc/nginx" bash -c \
  "source '$LIB/cert.sh'; x_cert_in_use '$TMP/cc/ng.crt' && echo Y || echo N")
assert_eq "$CU" "Y" "检测出被 nginx 引用的证书"
CU=$(CONF_DIR="$TMP/cc/conf" X_CERT_NGINX_DIRS="$TMP/cc/nginx" bash -c \
  "source '$LIB/cert.sh'; x_cert_in_use '$TMP/cc/old.crt' && echo Y || echo N")
assert_eq "$CU" "N" "无人引用的证书判为空闲"
GC=$(CONF_DIR="$TMP/cc/conf" X_CERT_NGINX_DIRS="$TMP/cc/nginx" bash -c \
  "source '$LIB/cert.sh'; x_cert_gc '$TMP/cc/live.crt' '$TMP/cc/ng.crt' '$TMP/cc/old.crt'" 2>&1)
[[ -f "$TMP/cc/live.crt" ]] && ok "GC 未删被引用的证书" || bad "GC 未删被引用的证书"
[[ -f "$TMP/cc/ng.crt" ]] && ok "GC 未删被 nginx 引用的证书" || bad "GC 未删被 nginx 引用的证书"
[[ ! -f "$TMP/cc/old.crt" ]] && ok "GC 删除了无人引用的证书" || bad "GC 删除了无人引用的证书"

# ---------------------------------------------------------------- DNS
group "DNS (dns_edit.py)"
DNSF="$TMP/dn"; mkdir -p "$DNSF"
printf '{"log":{"loglevel":"warning"},"inbounds":[{"tag":"keep-me","port":443}],"outbounds":[{"tag":"direct"}]}' > "$DNSF/config.json"
python3 "$LIB/dns_edit.py" --config "$DNSF/config.json" --add-server --server-address 1.1.1.1 --no-reload >/dev/null 2>&1
S1=$(python3 "$LIB/dns_edit.py" --config "$DNSF/config.json" --get 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("servers",[])))')
assert_eq "$S1" "1" "追加 DNS 服务器"
python3 "$LIB/dns_edit.py" --config "$DNSF/config.json" --del-server 1.1.1.1 --no-reload >/dev/null 2>&1
# 删完最后一条后 --get 输出一行提示而不是 JSON, 所以直接查文件而不是解析输出
S2=$(python3 -c "
import json
try: d=json.load(open('$DNSF/config.json'))
except Exception: d={}
print('servers' in (d.get('dns') or {}))")
assert_eq "$S2" "False" "删除最后一条后 servers 键消失 (不留空数组)"
D1=$(python3 -c "
import json;d=json.load(open('$DNSF/config.json'))
print('ok' if d['inbounds'][0]['tag']=='keep-me' and 'outbounds' in d else 'lost')")
assert_eq "$D1" "ok" "编辑 dns 不动其余键"
BAD=0
for b in '{"queryStrategy":"UseIPv5"}' '{"servers":[{"noAddress":1}]}' '{"unknownField":1}' '{"servers":"x"}' '{"disableCache":"yes"}'; do
    python3 "$LIB/dns_edit.py" --config "$DNSF/config.json" --set-json "$b" --no-reload >/dev/null 2>&1 || BAD=$((BAD+1))
done
assert_eq "$BAD" "5" "5 类非法 schema 全部被拦下"
# 校验失败必须回滚且不留备份
cp "$DNSF/config.json" "$DNSF/before.json"
mkdir -p "$TMP/bin2"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin2/xray"; chmod +x "$TMP/bin2/xray"
PATH="$TMP/bin2:$PATH" python3 "$LIB/dns_edit.py" --config "$DNSF/config.json" --set-json '{"queryStrategy":"UseIPv6"}' --test --no-reload >/dev/null 2>&1
if diff -q "$DNSF/before.json" "$DNSF/config.json" >/dev/null 2>&1; then ok "xray -test 失败已回滚"; else bad "xray -test 失败已回滚"; fi
if compgen -G "$DNSF/*.dns-bak" >/dev/null; then bad "回滚后无备份残留"; else ok "回滚后无备份残留"; fi

# ---------------------------------------------------------------- 日志
group "日志 (logs.sh / service.sh)"
# 用假 journalctl 验证 x_svc_explain_errors 真的把内核报错翻成人话
mkdir -p "$TMP/jbin"
cat > "$TMP/jbin/journalctl" <<'EOF'
#!/bin/sh
cat <<'LOG'
xray: failed to read config file: /root/catmi/xray/config.json
xray: unknown field "sockopt" in streamSettings
xray: listen tcp 0.0.0.0:443: bind: address already in use
LOG
EOF
chmod +x "$TMP/jbin/journalctl"
EX=$(PATH="$TMP/jbin:$PATH" bash -c "source '$LIB/service.sh'; x_svc_explain_errors" 2>&1)
[[ -n "$EX" ]] && ok "报错解释有输出" || bad "报错解释有输出"
echo "$EX" | grep -i 'port\|端口' >/dev/null && ok "识别出端口冲突" || bad "识别出端口冲突"
echo "$EX" | grep -i 'unknown field\|字段' >/dev/null && ok "识别出未知字段" || bad "识别出未知字段"
echo "$EX" | grep -i 'config' >/dev/null && ok "识别出配置文件问题" || bad "识别出配置文件问题"
# logs.sh 各入口在无 systemd 时不得挂死
T0=$(date +%s%N)
timeout 15 bash -c "source '$ROOT/conf/logs.sh'; log_status >/dev/null 2>&1; log_explain >/dev/null 2>&1; log_lines 5 >/dev/null 2>&1"
RC=$?; MS=$(( ($(date +%s%N) - T0) / 1000000 ))
[[ "$RC" != "124" ]] && ok "无 systemd 时三个入口均正常返回 (${MS}ms)" || bad "日志入口挂死 (${MS}ms)"
for fn in log_lines log_explain log_follow log_status log_menu; do
    grep -q "^${fn}()" "$ROOT/conf/logs.sh" && ok "日志入口存在: $fn" || bad "日志入口存在: $fn"
done

# ---------------------------------------------------------------- 容器共处
# nginx 跑在容器里时, 站点的查找与写入必须落到容器内部。之前 config_roots(docker)
# 收了参数却从没用过, 于是改的是宿主机的文件 —— 而容器里的 nginx 从不读它们。
# 表现不是报错, 是"已写入"之后站点毫无变化, 排查起来毫无线索。
CD="$TMP/cdk"; mkdir -p "$CD/ctr/conf.d" "$CD/bin"
cat > "$CD/ctr/conf.d/c.example.conf" <<'SITE'
server {
    listen 443 ssl;
    server_name c.example;
    location / {
        return 444;
    }
}
SITE
printf 'server {\n    listen 443 ssl;\n    server_name host.example;\n}\n' > "$CD/host-only.conf"
# 假的 docker: 把容器内 /etc/nginx 映射到 $CD/ctr
#
# 三个细节都是踩出来的, 少一个测试就会假绿:
#   · 映射目标不能含 "/etc/nginx" —— 替换结果自身又有这个子串, 再扫一遍会套两层
#   · sh -c 后面的 $@ 必须一起传下去, 否则 'test -f "$1"' 里的 $1 是空的
#   · exec -i (stdin 透传) 必须先摘掉, 否则后面的参数全部错位
cat > "$CD/bin/docker" <<EOF
#!/bin/bash
[[ "\$1" == "exec" ]] || exit 1
shift
while [[ "\$1" == "-i" ]]; do shift; done
ctr="\$1"; shift
if [[ "\$1" == "sh" && "\$2" == "-c" ]]; then
  script="\$3"; shift 3
  exec sh -c "\$(printf '%s' "\$script" | sed 's#/etc/nginx#$CD/ctr#g')" "\$@"
fi
if [[ "\$1" == "cat" ]]; then exec cat "\${2//\/etc\/nginx/$CD/ctr}"; fi
if [[ "\$1" == "cp" ]]; then cp "\${2//\/etc\/nginx/$CD/ctr}" "\${3//\/etc\/nginx/$CD/ctr}"; exit \$?; fi
exec "\$@"
EOF
chmod +x "$CD/bin/docker"

SF=$(PATH="$CD/bin:$PATH" python3 -c "
import sys; sys.path.insert(0,'$LIB'); import nginx_apply as N
print('|'.join(N.site_files('nginx')))")
case "$SF" in
  *c.example.conf*) ok "容器模式的 site_files 找到容器里的站点" ;;
  *) bad "容器模式的 site_files 找不到容器站点 (得到 $SF)" ;;
esac
LS=$(PATH="$CD/bin:$PATH" python3 -c "
import sys; sys.path.insert(0,'$LIB'); import nginx_apply as N
print(len(N.list_sites('nginx')))")
assert_eq "$LS" "1" "容器模式能读出 server_name"

PATH="$CD/bin:$PATH" python3 "$LIB/nginx_apply.py" --docker nginx \
  --domain c.example --path /node --port 34567 --transport ws --nginx none >/dev/null 2>&1
CB=$(grep -c 'xray-core BEGIN' "$CD/ctr/conf.d/c.example.conf")
assert_eq "$CB" "1" "容器模式插入写到了容器里的文件"
PATH="$CD/bin:$PATH" python3 "$LIB/nginx_apply.py" --docker nginx \
  --domain c.example --remove --nginx none >/dev/null 2>&1
CB2=$(grep -c 'xray-core BEGIN' "$CD/ctr/conf.d/c.example.conf" || true)
assert_eq "$CB2" "0" "容器模式摘除干净"
CK=$(grep -c 'return 444' "$CD/ctr/conf.d/c.example.conf")
assert_eq "$CK" "1" "容器模式摘除不动用户自己写的 location"

# 去重: /etc/nginx 与它的子目录都在搜索根里时不能重复列
DD="$TMP/ddup"; mkdir -p "$DD/sites-enabled" "$DD/sites-available"
printf 'server {\n    server_name d.example;\n}\n' > "$DD/sites-available/d.conf"
printf 'server {\n    server_name e.example;\n}\n' > "$DD/sites-enabled/e.conf"
# 只挂夹具目录, 不挂真实的 /etc/nginx —— 否则在真的装了 nginx 的机器上
# (比如实机) 会把真站点一起数进来, 断言从"验证去重"变成"验证本机装了什么"。
DDUP=$(NGINX_CONF_ROOTS="$DD:$DD/none" python3 -c "
import sys; sys.path.insert(0,'$LIB'); import nginx_apply as N
fs=N.site_files(); print('%d %d' % (len(fs), len(set(fs))))")
assert_eq "$DDUP" "2 2" "site_files 去重 (递归根不重复列)"

group "容器感知 (cert.sh / nginx_apply.py)"
mkdir -p "$TMP/nodocker" "$TMP/nopath"   # 模拟"本机没装 docker/nginx"
DK="$TMP/dk"; mkdir -p "$DK/hostcerts" "$DK/bin" "$DK/fakeconf"
touch "$DK/hostcerts/contained.crt"
cat > "$DK/fakeconf/nginx.conf" <<'EOF'
server {
    ssl_certificate     /etc/nginx/certs/contained.crt;
    ssl_certificate_key /etc/nginx/certs/contained.crt.key;
    ssl_certificate     /etc/nginx/certs/other_key.pem;
}
EOF
cat > "$DK/bin/docker" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "ps --format") echo "nginx-proxy" ;;
  "inspect nginx-proxy") echo "$DK/hostcerts" ;;
  "exec nginx-proxy") cat $DK/fakeconf/nginx.conf ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$DK/bin/docker"
OUT=$(PATH="$DK/bin:$PATH" bash -c "source '$LIB/cert.sh'; x_cert_container_certs" 2>/dev/null)
assert_eq "$(echo "$OUT" | grep -c 'contained.crt')" "1" "发现容器内证书"
assert_eq "$(echo "$OUT" | grep -cE '\.key |_key\.pem')" "0" "容器内私钥被排除 (.key 与 _key.pem 两种后缀)"
assert_eq "$(PATH="$DK/bin:$PATH" bash -c "source '$LIB/cert.sh'; x_cert_search_dirs" 2>/dev/null | grep -c "$DK/hostcerts")" "1" "容器挂载路径进入扫描目录"
# 无 docker 时不得挂死。
# 用清空的 PATH 来模拟"没装 docker", 而不是指望本机没装 —— 在装了 docker 的机器
# (比如实机) 上这条会真的去问 docker, 拿到的是另一个返回值, 断言就变成测环境了。
# PATH 要在 bash 起来之后才改。写成 `PATH=... timeout ...` 或 `env PATH=... bash`
# 时, 连 timeout / bash 自身都用新 PATH 去找, 返回 127 —— 那测的是"命令找不到",
# 不是"没有 docker"。
timeout 10 bash -c "PATH='$TMP/nodocker'; source '$LIB/cert.sh'; x_cert_container_certs" \
    >/dev/null 2>&1
assert_eq "$?" "1" "无 docker 时返回非 0 而非挂死"

# ---------------------------------------------------------------- 预置
group "协议预置 (preset.sh)"
PV=$(bash -c "source '$LIB/preset.sh'; x_preset_validate" 2>&1)
RV=$?
assert_eq "$RV" "0" "整表校验通过 (字段数/传输白名单/加密白名单/组合合法性)"
PS=$(bash -c "source '$LIB/preset.sh'; x_preset_protocols" 2>/dev/null | tr '\n' ' ')
for p in vless trojan vmess shadowsocks hysteria2 socks http; do
    [[ "$PS" == *"$p"* ]] && ok "预置覆盖协议: $p" || bad "预置覆盖协议: $p"
done
# 逐列提取不得错位。取样值随预置表调整而变 —— 这条的意图是**列对齐**,
# 不是"第 2 档必须是某个传输"。当前 vless 第 2 档是 XHTTP + TLS (CDN 推荐档,
# 见下面「预置推荐档」一组)。
# 同样按名字定位, 免得每次重排编号都要改这两条。
_i=$(preset_index_by_name vless "CDN 友好")
TR=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless $_i 2" 2>/dev/null)
SE=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless $_i 3" 2>/dev/null)
assert_eq "$TR/$SE" "xhttp/tls" "逐列提取不错位"
# 第一个预置 = 面板的推荐首选。这里断言的是**安全层**, 不是传输名 ——
# tcp 与 raw 是等价别名, 写死哪一个都会在下次调整时误报。
SE1=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 1 3" 2>/dev/null)
assert_eq "$SE1" "reality" "第一个预置提取正确 (推荐首选是 REALITY)"
# 末尾空字段场景 —— read 会少给一个字段, cut 不会
OUT=$(bash -c "source '$LIB/preset.sh'; echo \"a|b||\" | cut -d'|' -f3" 2>/dev/null)
assert_eq "$OUT" "" "cut 对末尾空字段返回空串 (read 会少给一个字段)"
# REALITY 的传输白名单必须与官方源码一致
#   源码 infra/conf/transport_internet.go:107 的报错原文:
#       "REALITY only supports RAW, XHTTP and gRPC for now."
#   原来这里的实现是 `[[ "$tr" == "tcp" ]]` —— **挡掉了 xhttp 与 grpc 两个
#   合法组合**, 用户想建 "官方主推传输 + 最强安全层" 会被无理由拒绝。
for pair in "raw:Y" "tcp:Y" "xhttp:Y" "grpc:Y" "ws:N" "httpupgrade:N" "mkcp:N"; do
    t="${pair%%:*}"; want="${pair##*:}"
    got=$(bash -c "source '$LIB/preset.sh'; _preset_security_allows reality $t && echo Y || echo N")
    assert_eq "$got" "$want" "REALITY 传输白名单 $t"
done
# 反向: 非 REALITY 一律不拦 (白名单只管 reality, 别把 tls/none 也拦掉)
for t in raw xhttp ws httpupgrade grpc; do
    got=$(bash -c "source '$LIB/preset.sh'; _preset_security_allows tls $t && echo Y || echo N")
    assert_eq "$got" "Y" "tls 不被 REALITY 白名单误拦 ($t)"
done

# 预置表里的 REALITY 组合必须与 node_build.py 的限制一致
NBREAL=$(python3 -c "import sys;sys.path.insert(0,'$LIB');import node_build as B;print('|'.join(sorted(B.SECURITY_TRANSPORTS['reality'])))")
# asort 是 gawk 扩展, Debian 默认的 mawk 没有 —— 排序走 sort, 不依赖 awk 方言
NBREALITY_SORTED=$(printf '%s' "$NBREAL" | tr '|' '\n' | sort | sed 's/$/|/' | tr -d '\n')
PBAD=0
for p in vless trojan vmess shadowsocks hysteria2 socks http; do
    cnt=$(bash -c "source '$LIB/preset.sh'; x_preset_count $p" 2>/dev/null)
    for i in $(seq 1 "$cnt" 2>/dev/null); do
        t=$(bash -c "source '$LIB/preset.sh'; x_preset_field $p $i 2" 2>/dev/null)
        s2=$(bash -c "source '$LIB/preset.sh'; x_preset_field $p $i 3" 2>/dev/null)
        # 判据直接取 node_build 的白名单 —— 不在它里面才算不一致。
        # 原来这里写死 `!= "tcp"`, 于是白名单一旦按内核放宽 (raw/xhttp/grpc),
        # 这条门禁会把**正确**的组合判成违规, 逼着代码退回错的那个。
        if [[ "$s2" == "reality" ]]; then
            case "|$NBREALITY_SORTED|" in
                *"|$t|"*) : ;;
                *) PBAD=$((PBAD+1)) ;;
            esac
        fi
    done
done
assert_eq "$PBAD" "0" "预置表与 node_build 的 REALITY 限制一致"
# 无预置协议必须明确报错而非静默
NU=$(bash -c "source '$LIB/preset.sh'; x_preset_ask tuic </dev/null" 2>&1 | awk 'NR==1')
[[ "$NU" == *"没有预置"* ]] && ok "无预置协议明确报错" || bad "无预置协议明确报错"

# ------------------------------------------------- 后量子 / X 特有能力 (X 内核独有)
group "后量子与 X 特有能力"

# ★ 回归 1: mknode.sh 里重写 opts_json 的那段 python 曾经**漏 import os**,
#   于是 NameError → 命令替换拿到空串 → deploy.py 报
#   「缺少必填参数: --protocol, --transport, --security」。
#   现象指向"规格拼错", 实际是少一个 import, 而这条路径就是"用预置建 REALITY
#   节点" —— 也就是说该组合从来没成功过 (面板菜单 7 的 Reality.sh 是另一条路)。
#   这条断言直接跑那段 python, 比比对源码字符串可靠: 源码改了字面量也照样过。
RK=$(python3 - <<'PYX'
import json, os, subprocess, sys
spec = '{"protocol":"vless","transport":"raw","security":"reality"}'
env = dict(os.environ, MK_PK="a"*43, MK_PB="b"*43)
# 与 mknode.sh 里那一行同构
snippet = """
import json,sys,os
o=json.loads(sys.argv[1]); o['private_key']=os.environ['MK_PK']; o['public_key']=os.environ['MK_PB']
print(json.dumps(o,ensure_ascii=False))"""
r = subprocess.run([sys.executable, "-c", snippet, spec], env=env,
                   capture_output=True, text=True)
print("OK" if r.returncode == 0 and r.stdout.strip() else "ERR")
PYX
)
assert_eq "$RK" "OK" "REALITY 密钥拼装 (mknode 的 opts 重写不返回空串)"

# ★ 回归 2: mknode.sh 必须对重写结果做非空守卫, 否则同类失败仍然静默传播
G=$(grep -c '拼装 REALITY 密钥对时出错' "$ROOT/conf/mknode.sh" 2>/dev/null)
assert_eq "$G" "1" "REALITY 密钥拼装有非空守卫 (不拿空串往下走)"

# Vision flow 是**调用方**的事: node_build 只按传入的写, 加不加由 mknode 决定。
# 所以这里断言的是 mknode 那条判据 (只有裸 TCP 才加), 而不是 node_build。
FF=$(grep -c 'opts\["transport"\] in ("raw", "tcp")' "$ROOT/conf/mknode.sh" 2>/dev/null)
assert_eq "$FF" "1" "mknode 只对裸 TCP 加 Vision flow"

# ★ kcp 的拦截点不在 _preset_security_allows —— 那个函数只看 REALITY 的传输
#   白名单, 对 security=none 一律放行。真正的闸门是 _P_TRANSPORTS
#   (预置表自检 x_preset_validate 用它), 而 mknode 只能从预置表建节点,
#   所以"表里没有 kcp" 就等于用户选不到它。
#   内核 26.3.27 实测: kcpSettings 的 header/seed 已移除, 报错原文
#     "The feature mkcp header & seed has been removed and migrated to ..."。
#   只写个空 kcpSettings{} 能过 xray run -test, 但运行期照样连不通 ——
#   面板显示一切正常, 用户查不出原因。所以要在生成之前就挡掉。
KK=$(bash -c "source '$LIB/preset.sh'; case \" \$_P_TRANSPORTS \" in *kcp*) echo Y;; *) echo N;; esac" 2>/dev/null)
assert_eq "$KK" "N" "kcp 已从传输白名单移除 (内核已不支持 header/seed)"
KK2=$(bash -c "source '$LIB/preset.sh'; x_preset_validate" 2>&1 | grep -c "kcp")
assert_eq "$KK2" "0" "预置表里没有任何 kcp 档位"

# ML-DSA-65 / ECH 字段能落到配置里
ML=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import node_build as B
r = B.build("vless","raw","reality", dict(tag="t", port=34567, private_key="a"*43,
          public_key="b"*43, sni="x.com", dest="x.com:443",
          mldsa65_seed="SEED", mldsa65_verify="VER"))
rs = r["inbounds"][0]["streamSettings"]["realitySettings"]
print("%s/%s" % (rs.get("mldsa65Seed","-"), rs.get("mldsa65Verify","-")))
PYX
)
assert_eq "$ML" "SEED/VER" "ML-DSA-65 写进 realitySettings"
EC=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import node_build as B
r = B.build("vless","xhttp","tls", dict(tag="t", port=34567,
          cert_file="/tmp/c", key_file="/tmp/k", sni="x.com",
          ech_server_keys="ECHKEYS"))
ss = r["inbounds"][0]["streamSettings"]
print("%s/%s" % (ss["tlsSettings"].get("echServerKeys","-"),
                 "no-mode" if "mode" not in ss["xhttpSettings"] else ss["xhttpSettings"]["mode"]))
PYX
)
assert_eq "$EC" "ECHKEYS/no-mode" "ECH 服务端公钥写进 tlsSettings; 服务端不写 xhttp mode (接受三种)"

# 预置第 6 列 (加密增强) 能被取到, 且没有的档位兜成 none
EN=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 1 6" 2>/dev/null)
case "$EN" in *mlkem*) ok "第 6 列: 推荐首选带 ML-KEM" ;; *) bad "第 6 列: 推荐首选带 ML-KEM [得到 '$EN']" ;; esac
EN2=$(bash -c "source '$LIB/preset.sh'; x_preset_ask vless </dev/null 2>/dev/null | wc -l")
assert_eq "$EN2" "0" "x_preset_ask 取消时不输出"

# ------------------------------------------------- XHTTP 上下行分离
group "XHTTP 上下行分离"

# 内核只认这四个 mode, 其余硬报错。这里提前拦, 好给一句人话。
NM3=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import node_build as B
base = dict(tag="t", port=34567, private_key="a"*43, public_key="b"*43,
            sni="www.cloudflare.com", dest="www.cloudflare.com:443", short_id="abcd")
out = []
# ★ 服务端**不该**写 mode —— 官方文档: 「服务端默认同时接受三种模式,
#   若设为具体的模式就是仅接受它」。所以这里断言"选了 mode 也不落到服务端",
#   只有显式要求钉死 (xhttp_server_mode) 时才写。
for m in ("stream-up","packet-up","stream-one","auto"):
    try:
        r = B.build("vless","xhttp","reality", dict(base, xhttp_mode=m))
        xh = r["inbounds"][0]["streamSettings"]["xhttpSettings"]
        out.append("no-mode" if "mode" not in xh else xh["mode"])
    except Exception:
        out.append("ERR")
# 显式钉死时要写得进去 (给"我就只接受一种"的用法留口子)
try:
    r = B.build("vless","xhttp","reality", dict(base, xhttp_server_mode="packet-up"))
    out.append(r["inbounds"][0]["streamSettings"]["xhttpSettings"]["mode"])
except Exception:
    out.append("ERR")
bad = ""
for m in ("bogus","","packet_up"):
    try:
        B.build("vless","xhttp","reality", dict(base, xhttp_mode=m))
        bad = m
    except Exception:
        pass
print(",".join(out) + "|bad=" + (bad or "none"))
PYX
)
assert_eq "${NM3%|bad=*}" "no-mode,no-mode,no-mode,no-mode,packet-up" \
    "服务端默认不写 xhttp mode (接受三种); 显式 xhttp_server_mode 才钉死"
assert_eq "${NM3##*bad=}" "none" "非法 xhttp mode 在生成前就被拦 (不必等 xray -test)"

# ★ Vision(XTLS) + 非裸TCP: xray run -test **放行**, 真连立刻失败
#   ("XTLS only supports TLS and REALITY directly for now.")。必须在生成前拦。
XV=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import node_build as B
base = dict(tag="t", port=34567, private_key="a"*43, public_key="b"*43,
            sni="www.cloudflare.com", dest="www.cloudflare.com:443", short_id="abcd")
res = []
for tr in ("xhttp","grpc"):
    try:
        B.build("vless",tr,"reality", dict(base, flow="xtls-rprx-vision")); res.append("LEAK")
    except Exception: res.append("blocked")
# 裸 TCP 必须仍然放行 —— 这条要防的是"拦过头"
try:
    B.build("vless","raw","reality", dict(base, flow="xtls-rprx-vision")); res.append("ok")
except Exception: res.append("BLOCKED-VALID")
print(",".join(res))
PYX
)
assert_eq "$XV" "blocked,blocked,ok" "Vision 与非裸TCP 在生成前被拦, 裸TCP 不受影响"

# REALITY + xHTTP 必须是合法组合 (内核: "REALITY only supports RAW, XHTTP and gRPC")
RL=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import node_build as B
base = dict(tag="t", port=34567, private_key="a"*43, public_key="b"*43,
            sni="www.cloudflare.com", dest="www.cloudflare.com:443", short_id="abcd",
            xhttp_mode="stream-up")
try:
    B.build("vless","xhttp","reality", dict(base)); print("ok")
except Exception as e: print("ERR:" + str(e)[:50])
PYX
)
assert_eq "$RL" "ok" "REALITY + xHTTP (上下行分离) 能生成"

# 预置表里必须有这一档, 且不能带 flow (XTLS 与 xhttp 冲突)
PX=$(bash -c "source '$LIB/preset.sh'; x_preset_count vless" 2>/dev/null)
PXE=""
for ((i=1;i<=PX;i++)); do
    if [[ "$(bash -c "source '$LIB/preset.sh'; x_preset_field vless $i 4" 2>/dev/null)" == *"上下行分离"* ]]; then
        PXE="$(bash -c "source '$LIB/preset.sh'; x_preset_field vless $i 2")/$(bash -c "source '$LIB/preset.sh'; x_preset_field vless $i 3")"
    fi
done
assert_eq "$PXE" "xhttp/reality" "预置表含「REALITY + XHTTP 上下行分离」档"

# ------------------------------------------------- 上下行分离全链路
group "上下行分离 (downloadSettings)"

CDL="$TMP/cdl"; mkdir -p "$CDL"

# ---- 1) 服务端生成 ----
DS=$(python3 - "$LIB" <<'PYX'
import sys, json; sys.path.insert(0, sys.argv[1])
import node_build as B
R=dict(private_key="a"*43, public_key="b"*43, sni="www.cloudflare.com",
       dest="www.cloudflare.com:443", short_id="ab", fingerprint="chrome")
base=dict(tag="t", port=18443)
def build(**kw):
    return B.build("vless","xhttp","reality", dict(base, **R, **kw))
# ★ 下行 REALITY 的公钥字段是 **password**, 不是 publicKey。
#   下行 REALITY 是服务端**扮演客户端**连出去, 所以那是一份客户端配置,
#   客户端侧内核要的字段名就是 password。实测写 publicKey 时内核报:
#       Failed to build REALITY config. > empty "password"
#   报错里没有半个字提 publicKey, 照着报错查会绕很大一圈。
#   (上行入站那侧仍然是 publicKey —— 那边是服务端角色, 别一起改。)
a=build(xhttp_mode="stream-up", dl_address="203.0.113.9", dl_security="reality",
        dl_public_key="b"*43, dl_short_id="ab", dl_sni="www.cloudflare.com")
d=a["inbounds"][0]["streamSettings"]["xhttpSettings"]["downloadSettings"]
rs=d["realitySettings"]
out=[d["address"], str(d["port"]), d["security"], rs["serverName"],
     str(rs["password"][:4])]
b=build(xhttp_mode="stream-up")            # 不配 = 不该有 downloadSettings
out.append("no-dl" if "downloadSettings" not in b["inbounds"][0]["streamSettings"]["xhttpSettings"] else "LEAK")
print(",".join(out))
PYX
)
assert_eq "$DS" "203.0.113.9,18443,reality,www.cloudflare.com,bbbb,no-dl" \
    "downloadSettings 落进服务端配置 (地址/端口/密钥/SNI), 不配时不出现"

# ---- 2) 硬约束: 下行 path 必须等于上行 (RN 真连实测) ----
DPATH=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import node_build as B
R=dict(private_key="a"*43, public_key="b"*43, sni="www.cloudflare.com",
       dest="www.cloudflare.com:443", short_id="ab")
res=[]
for name,kw in (("same", dict(dl_address="b.com")),
                ("diff", dict(dl_address="b.com", dl_path="/down"))):
    try:
        c=B.build("vless","xhttp","reality",
                  dict(R, tag="t", port=18443, xhttp_mode="stream-up", path="/up", **kw))
        d=c["inbounds"][0]["streamSettings"]["xhttpSettings"]["downloadSettings"]
        top=c["inbounds"][0]["streamSettings"]["xhttpSettings"]["path"]
        res.append(name+":"+("OK" if d["xhttpSettings"]["path"]==top else "MISMATCH"))
    except Exception: res.append(name+":blocked")
print(",".join(res))
PYX
)
assert_eq "$DPATH" "same:OK,diff:blocked" \
    "下行 path 必须等于上行 (服务端只认顶层 path, hub.go:461)"

# ---- 3) 硬约束: 端口必须与本 inbound 相同 ----
DP=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import node_build as B
R=dict(private_key="a"*43, public_key="b"*43, sni="www.cloudflare.com",
       dest="www.cloudflare.com:443", short_id="ab")
res=[]
# ★ 每个用例都必须带 dl_address —— 没有下行地址时本来就不该拦,
#   那样写出来的期望值会把"测错了"伪装成"代码没生效"。
for name,kw in (("stream-one", dict(xhttp_mode="stream-one", dl_address="b.com")),
                ("wrong-port", dict(xhttp_mode="stream-up", dl_address="b.com", dl_port=9999)),
                ("ok", dict(xhttp_mode="stream-up", dl_address="b.com"))):
    try:
        B.build("vless","xhttp","reality", dict(R, tag="t", port=18443, **kw)); res.append(name+":LEAK")
    except Exception: res.append(name+":blocked")
print(",".join(res))
PYX
)
assert_eq "$DP" "stream-one:blocked,wrong-port:blocked,ok:LEAK" \
    "stream-one+dl 与 下行端口不一致 都在生成前被拦, 合法组合放行"

# ---- 3) 分享链接: 上下行参数 + mode + path ----
SP=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import nodes as N
meta={"public_key":"b"*43,"short_id":"abcd","fingerprint":"chrome","name":"n","enabled":True}
n=dict(tag="t",protocol="vless",id="u",port=443,network="xhttp",address="a.example.com",
       sni="www.cloudflare.com",path="/real-x",security="reality",mode="stream-up",
       published=True, dl_address="1.2.3.4", dl_port=443, dl_security="reality",
       dl_sni="www.cloudflare.com", dl_public_key="b"*43, dl_short_id="abcd")
l=N.build_share_link(n, meta) or ""
out=["dlad" if "dlad=1.2.3.4" in l else "-",
     "dlport" if "dlport=443" in l else "-",
     "mode" if "mode=stream-up" in l else "-",
     "path" if "path=" in l else "-"]
n2=dict(n); [n2.pop(k,None) for k in ("dl_address","dl_port","dl_security","dl_sni",
                                     "dl_public_key","dl_short_id")]
l2=N.build_share_link(n2, meta) or ""
out.append("clean" if "dlad=" not in l2 else "NOISE")
print(",".join(out))
PYX
)
assert_eq "$SP" "dlad,dlport,mode,path,clean" \
    "分享链接带 dl*/mode/path, 且不配上下行时不添噪声"

# ---- 4) path 曾在 tls 分支里 => REALITY + 路径型传输会丢 (回归) ----
PT=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import nodes as N
meta={"public_key":"b"*43,"short_id":"abcd","fingerprint":"chrome","name":"n","enabled":True}
miss=[]
for sec in ("reality","tls"):
    for net in ("xhttp","ws","grpc","httpupgrade"):
        n=dict(tag="t",protocol="vless",id="u",port=443,network=net,address="a.example.com",
               sni="www.cloudflare.com",path="/real-x",security=sec,published=True)
        if "path=" not in (N.build_share_link(n, meta) or ""): miss.append(sec+"/"+net)
print(",".join(miss) if miss else "none")
PYX
)
assert_eq "$PT" "none" "REALITY/TLS × xhttp/ws/grpc/httpupgrade 的分享链接都带 path"

# ---- 5) 客户端产物 (genconfig) ----
GC=$(python3 - "$ROOT" <<'PYX'
import sys, json, subprocess, tempfile, os
root=sys.argv[1]
sys.path.insert(0, os.path.join(root,"Client","lib"))
import node as ND
n={"address":"a.example.com","port":443,"protocol":"vless","transport":"xhttp",
   "uuid":"11111111-1111-1111-1111-111111111111","security":"reality",
   "sni":"www.cloudflare.com","fingerprint":"chrome","reality_public_key":"b"*43,
   "reality_short_id":"abcd","path":"/x","mode":"stream-up",
   "dl_address":"1.2.3.4","dl_port":443,"dl_security":"reality",
   "dl_sni":"www.cloudflare.com","dl_public_key":"b"*43,"dl_short_id":"abcd"}
d=tempfile.mkdtemp()
np=os.path.join(d,"n.json"); json.dump(n,open(np,"w"))
op=os.path.join(d,"o.json")
subprocess.run([sys.executable,"lib/genconfig.py","--node",np,"--output",op,
                "--mode","normal"],cwd=os.path.join(root,"Client"),
               capture_output=True)
c=json.load(open(op))
xh=c["outbounds"][0]["streamSettings"]["xhttpSettings"]
dl=xh.get("downloadSettings")
if not dl: print("NO-DL"); raise SystemExit
mp=os.path.join(d,"m.json")
json.dump({"inbounds":[{"tag":"s","port":13999,"listen":"127.0.0.1","protocol":"socks",
                        "settings":{"auth":"noauth"}}],
           "outbounds":[c["outbounds"][0]]}, open(mp,"w"))
k=subprocess.run(["/usr/local/bin/xray","run","-test","-config",mp],capture_output=True,text=True)
print(",".join([dl["address"], str(dl["port"]), dl["security"],
                str(dl["realitySettings"]["publicKey"][:4]),
                dl["xhttpSettings"]["path"],
                "OK" if "Configuration OK" in (k.stdout+k.stderr) else "KERNEL-REJECT"]))
PYX
)
assert_eq "$GC" "1.2.3.4,443,reality,bbbb,/x,OK" \
    "客户端产物带 downloadSettings (客户端侧用公钥) 且内核接受, 下行 path 与上行一致"

# ---- 6) 客户端解析 dl_port 必须是 int ----
PT2=$(python3 - "$ROOT" <<'PYX'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1],"Client","lib"))
import node as ND
l=("vless://u@a.example:443?encryption=none&security=tls&type=xhttp&path=%2Fx"
   "&dlad=1.2.3.4&dlport=443&dlsec=tls")
n=ND.parse_node(l)
print(type(n.get("dl_port")).__name__)
PYX
)
assert_eq "$PT2" "int" "分享链接里的 dlport 解析成 int (内核要数字, 字符串会 unmarshal 失败)"

# ------------------------------------------------- nginx 双域名 + 连带清理
group "nginx 双域名与连带清理"

NG="$TMP/ngroot"; rm -rf "$NG"; mkdir -p "$NG"
printf 'server {\n    listen 443 ssl;\n    server_name up.example.com;\n    location /myapp { proxy_pass http://127.0.0.1:3000; }\n}\n' > "$NG/a.conf"
printf 'server {\n    listen 443 ssl;\n    server_name down.example.com;\n}\n' > "$NG/b.conf"
NGA="$NG/a.conf"; NGB="$NG/b.conf"

na() { NGINX_CONF_ROOTS="$NG" python3 "$LIB/nginx_apply.py" "$@" 2>&1; }
nrc() { NGINX_CONF_ROOTS="$NG" python3 "$LIB/nginx_apply.py" "$@" >/dev/null 2>&1; echo $?; }

# ---- 1) 双域名插入 ----
# ★ 两次插入的参数必须**完全一致** —— 少传一个 --origin-sni 就会让生成的
#   proxy_ssl_name 从具体域名变成 $host, 内容真的变了, 那不是幂等性坏掉。
nrc --domain up.example.com,down.example.com --port 8443 --transport xhttp \
    --cdn --origin-tls --origin-sni up.example.com --nginx none >/dev/null
NA_C=$(cat "$NGA"); NB_C=$(cat "$NGB")
assert_eq "$(grep -c 'xray-core BEGIN up.example.com' "$NGA")" "1" "双域名: 上行域名插进 a.conf"
assert_eq "$(grep -c 'xray-core BEGIN down.example.com' "$NGB")" "1" "双域名: 下行域名插进 b.conf (各自找站点文件)"
# ★ 双层 TLS (照 SB): xray inbound 自带 TLS 时, 回源必须是 https://,
#   否则 nginx 向期待 TLS 的 xray 发明文 -> 502 / connection reset, xray 侧无日志。
assert_eq "$(grep -c 'proxy_pass https://127.0.0.1:8443' "$NGA" "$NGB" | grep -c ':1')" "2" \
    "双域名两段都用 https:// 回源 (双层 TLS)"
assert_eq "$(grep -c 'proxy_ssl_server_name on' "$NGA" "$NGB" | grep -c ':1')" "2" "两段都带回源 SNI"
assert_eq "$(grep -c 'proxy_buffering off' "$NGA" "$NGB" | grep -c ':1')" "2" \
    "xhttp 关缓冲 (下行是长连接 GET, 缓冲了就不流式)"

# ---- 2) 幂等 ----
# 存的是"两文件各自的内容", 比较时逐份比 —— cat 拼接和 printf 拼接的
# 分隔符不同, 比哈希会得到一个与幂等性无关的假失败。
na --domain up.example.com,down.example.com --port 8443 --transport xhttp \
   --cdn --origin-tls --origin-sni up.example.com --nginx none >/dev/null
assert_eq "$(cat "$NGA")$(cat "$NGB")" "$NA_C$NB_C" \
    "双域名重复插入是幂等的 (不产生第二份)"

# ---- 3) 只删一个域名 ----
nrc --domain up.example.com --port 8443 --transport xhttp --cdn --nginx none --remove >/dev/null
assert_eq "$(grep -c 'xray-core BEGIN up.example.com' "$NGA")" "0" "删上行域名: 该段已摘"
assert_eq "$(grep -c 'xray-core BEGIN down.example.com' "$NGB")" "1" "删上行域名: 下行域名的那段**保留**"
assert_eq "$(grep -c '/myapp' "$NGA")" "1" "站点自有 location 没被误伤"

# ---- 4) 删干净后逐字还原 ----
nrc --domain down.example.com --port 8443 --transport xhttp --cdn --nginx none --remove >/dev/null
assert_eq "$(grep -c 'xray-core BEGIN' "$NGA" "$NGB" | grep -c ':0')" "2" "两域名都删后无任何残留标记"

# ---- 5) 删不存在的域名 = 干净 no-op ----
NGSNAP=$(md5sum "$NGA" "$NGB" | md5sum)
nrc --domain nope.example.com --port 8443 --nginx none --remove >/dev/null
assert_eq "$(md5sum "$NGA" "$NGB" | md5sum)" "$NGSNAP" "删不存在的域名: 站点一个字节都没动"

# ---- 6) 删节点/清空全部 必须调用 nginx 清理 ----
CB=$(grep -c 'prune_nginx_after_wipe' "$ROOT/conf/batch.sh" 2>/dev/null)
assert_ne0 "$CB" "清空全部/重建 会调用 nginx 片段清理"
# 1 次定义 + 2 次调用 (clear_all_nodes / rebuild_all)
assert_eq "$(grep -c '< <(_collect_nginx_targets)' "$ROOT/conf/batch.sh" 2>/dev/null)" "2" \
    "清空与重建都在**删除前**收集要摘的片段 (删完就读不出域名了)"
# 收集器必须把双域名的下行域名也算进去
assert_eq "$(grep -c 'dl_domain' "$ROOT/conf/batch.sh" 2>/dev/null)" "1" \
    "收集器认双域名的下行域名 (两段都要摘)"
# node.sh 的单节点删除也要认双域名
assert_eq "$(grep -c "get('dl_domain'" "$ROOT/conf/node.sh" 2>/dev/null)" "1" \
    "删单个节点时也读 share_meta 的 dl_domain (下行域名)"
assert_eq "$(grep -c 'domain="\$domain,\$dl_domain"' "$ROOT/conf/node.sh" 2>/dev/null)" "1" \
    "删单个节点时把两个域名一起交给 nginx_apply 摘"

# ------------------------------------------------- mihomo YAML 产物
group "mihomo YAML (上下行分离)"

MH=$(python3 - "$LIB" "$ROOT" <<'PYX'
import sys, os
sys.path.insert(0, sys.argv[1])
sys.path.insert(0, os.path.join(sys.argv[2], "Client", "lib"))
import to_mihomo as M
import node as ND

N = dict(protocol="vless", address="cdn.example.com", port=443,
         id="11111111-1111-1111-1111-111111111111", network="xhttp",
         security="reality", sni="www.cloudflare.com", fingerprint="chrome",
         reality_public_key="b"*43, reality_short_id="abcd",
         path="/x", mode="stream-up",
         dl_address="203.0.113.9", dl_port=8443, dl_security="reality",
         dl_sni="www.cloudflare.com", dl_public_key="c"*43, dl_short_id="ef01")

# 1) 生成: 官方形状 = download-settings 里同时有 xhttp 部分与 proxy 部分
p = M.proxy(N)
ds = (p.get("xhttp-opts") or {}).get("download-settings") or {}
out = ["server" if ds.get("server") == "203.0.113.9" else "-",
       "port" if ds.get("port") == 8443 else "-",
       "reality" if (ds.get("reality-opts") or {}).get("public-key") == "c"*43 else "-",
       "sni" if ds.get("servername") == "www.cloudflare.com" else "-",
       "tls" if ds.get("tls") is True else "-",
       "path" if ds.get("path") == "/x" else "-",
       "mode" if ds.get("mode") == "stream-up" else "-"]

# 2) 不配下行就没有 download-settings
N2 = {k: v for k, v in N.items() if not k.startswith("dl_")}
out.append("clean" if "download-settings" not in (M.proxy(N2).get("xhttp-opts") or {}) else "NOISE")

# 3) 往返: 我们生成的 YAML 我们自己读得回来
back = ND.parse_mihomo_yaml(M._dump({"proxies": [p]}))
out += ["rt" if back.get("dl_address") == "203.0.113.9" else "-",
        str(back.get("dl_port", "?")),
        "rt-sec" if back.get("dl_security") == "reality" else "-"]

# 4) 必须拒绝的两种
N3 = dict(N); N3["reality_public_key"] = ""; N3.pop("dl_public_key")
out.append("nopbk" if M.proxy(N3) is None else "LEAK")
N4 = dict(N, protocol="trojan", password="pw")
out.append("vless-only" if M.proxy(N4) is None else "LEAK")
print(",".join(out))
PYX
)
assert_eq "$MH" \
  "server,port,reality,sni,tls,path,mode,clean,rt,8443,rt-sec,nopbk,vless-only" \
  "mihomo YAML 带 download-settings (xhttp 部分 + proxy 部分), 可往返, 缺公钥/非 VLESS 被拒"

# 下行公钥缺省沿用上行 (双域名/同端口是同一把密钥) —— 必须与 node_build 同规则
MH2=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import to_mihomo as M
N = dict(protocol="vless", address="a.com", port=443,
         id="11111111-1111-1111-1111-111111111111", network="xhttp",
         security="reality", sni="s.com", reality_public_key="b"*43,
         path="/x", mode="stream-up", dl_address="1.2.3.4", dl_security="reality")
ds = (M.proxy(N).get("xhttp-opts") or {}).get("download-settings") or {}
a = (ds.get("reality-opts") or {}).get("public-key") == "b"*43
N2 = dict(N, dl_public_key="c"*43)
ds2 = (M.proxy(N2).get("xhttp-opts") or {}).get("download-settings") or {}
b = (ds2.get("reality-opts") or {}).get("public-key") == "c"*43
print(("inherit" if a else "BROKEN") + "," + ("override" if b else "BROKEN"))
PYX
)
assert_eq "$MH2" "inherit,override" \
    "mihomo 下行公钥: 缺省沿用上行 (同服务器双域名), 显式给值则覆盖"

# ------------------------------------------------- 预置路径的客户端产物
group "预置路径 (菜单 13/14/15) 也要产出 mihomo YAML"

# ★ 这一组盯的是"建节点的那一步有没有真的产出客户端产物"。
#   以前预置路径只写 conf/<tag>.json + 分享元数据 —— 用户建完节点手上没有
#   任何客户端文件, 得自己按文档拼; 而 xhttp 的 download-settings 是两段式、
#   逐项覆盖语义, 手拼必错。上下行分离更糟: 它**只存在于服务端配置里**,
#   不落成产物就没人记得这个节点是分离的。
PR=$(mktemp -d)
mkdir -p "$PR/conf"
KP=$(python3 - <<'PYX'
import base64, os
print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))
PYX
)
python3 - "$PR" "$KP" <<'PYX'
import json, sys, os
d, pub = sys.argv[1], sys.argv[2]
spec = {"protocol": "vless", "transport": "xhttp", "security": "tls",
        "tag": "x-vless01-TLS", "port": 29601, "tier": "cdn",
        "domain": "up.example.com", "sni": "up.example.com",
        "path": "/sp-probe", "uuid": "22222222-2222-2222-2222-222222222222",
        "dl_address": "203.0.113.9", "dl_security": "reality",
        "dl_mode": "stream-up", "dl_sni": "www.cloudflare.com",
        "dl_public_key": pub, "dl_short_id": "abcd1234",
        "split_mode": "cdn-reality"}
json.dump(spec, open(os.path.join(d, "spec.json"), "w"))
PYX
(cd "$ROOT" && XRAY_BASE="$PR" python3 conf/lib/deploy.py \
    --config-json "@$PR/spec.json" --conf-dir "$PR/conf" \
    --share-dir "$PR/out/share" --apply >/dev/null 2>&1)
if [[ -f "$PR/out/x-vless01-TLS.yaml" ]]; then
    ok "预置路径建节点时产出了 out/<tag>.yaml"
else
    bad "预置路径没产出 mihomo YAML → 用户建完节点手上只有服务端片段"
fi
# 分离信息必须**进到产物里**, 不能只留在服务端片段
if grep -q 'download-settings' "$PR/out/x-vless01-TLS.yaml" 2>/dev/null; then
    ok "产出的 YAML 带 download-settings (上下行分离进了客户端产物)"
else
    bad "产出的 YAML 没有 download-settings → 分离节点在 mihomo 侧退化成合流"
fi
if grep -qE '^ *server: 203\.0\.113\.9$' "$PR/out/x-vless01-TLS.yaml" 2>/dev/null \
   && grep -qE '^ *mode: stream-up$' "$PR/out/x-vless01-TLS.yaml" 2>/dev/null; then
    ok "下行目的地与 mode 都写进了 download-settings"
else
    bad "download-settings 缺下行目的地或 mode"
fi
# 片段里的服务端字段不能漏进客户端产物 (privateKey 之类)
if grep -q 'privateKey' "$PR/out/x-vless01-TLS.yaml" 2>/dev/null; then
    bad "客户端产物里出现了服务端字段 privateKey"
else
    ok "客户端产物没有混入服务端字段"
fi

# 真内核校验: 有 mihomo 就跑, 没有就**如实跳过** (不假装通过)
MH_BIN=""
for _c in "$(command -v mihomo 2>/dev/null)" /root/catmi/mihomo/mihomo; do
    [[ -n "$_c" && -x "$_c" ]] && { MH_BIN="$_c"; break; }
done
if [[ -n "$MH_BIN" ]]; then
    { echo "mixed-port: 17890"; echo "log-level: warning"; \
      cat "$PR/out/x-vless01-TLS.yaml"; } > "$PR/mh.yaml"
    if "$MH_BIN" -t -f "$PR/mh.yaml" -d "$PR" >/dev/null 2>&1; then
        # ★ 取第一行的方式: 先整段取回再用 ${v%%$'\n'*} 切。
        #   写成 `... | head -1` 会让上游吃 SIGPIPE —— 套件自己的 EARLY
        #   门禁就是盯这个的, 写新断言时踩过。
        _mh_v=$("$MH_BIN" -v 2>/dev/null)
        _mh_v="${_mh_v%%$'\n'*}"
        ok "产出物过真 mihomo -t (${_mh_v:0:24})"
    else
        _mh_out=$("$MH_BIN" -t -f "$PR/mh.yaml" -d "$PR" 2>&1)
        _mh_err=$(printf '%s\n' "$_mh_out" | grep -i -m1 'level=error')
        bad "产出物被真 mihomo 拒绝: ${_mh_err:-未知原因}"
    fi
else
    ok "本机没有 mihomo 二进制, 产物未过真内核校验 (如实跳过, 不是通过)"
fi

# 生成不出来的时候**必须给出原因**, 不能静默少一个文件
WU=$(python3 - "$LIB" <<'PYX'
import sys; sys.path.insert(0, sys.argv[1])
import to_mihomo as M
n = M.node_from_fragment({"network": "xhttp", "security": "tls",
                          "protocol": "trojan"}, {"host": "a.com"})
print("reason" if M._why_unsupported(n) else "EMPTY")
PYX
)
assert_eq "$WU" "reason" "生成不出 YAML 时给得出原因 (而不是静默少一个文件)"
rm -rf "$PR"

# ------------------------------------------------- 预置向导: 交互验证抓到的四个
group "预置向导 (菜单 13): pty 真按键才发现的四个缺陷"

# ★ 这一组全部来自**真按键走一遍** (tools/pty_journey.py), 静态检查抓不到。
MK="$ROOT/conf/mknode.sh"
UI="$ROOT/conf/lib/ui.sh"

# ① 不落盘: 调 deploy.py 时漏了 --apply, 于是走 _print_plan 预演分支 ——
#    屏幕上有完整 JSON、有「完成」、没有报错, 磁盘上一个文件都没有。
if grep -A3 'python3 "$plan_py" --config-json' "$MK" | grep -- '--apply' >/dev/null; then
    ok "mknode 调 deploy.py 带 --apply (否则只预演、不落盘)"
else
    bad "mknode 没给 --apply → 菜单13 建节点只打印方案, 一个文件都不写, 还说「完成」"
fi
# 退出码 0 不等于写成了: 落盘后必须回头 stat 一次
if sed -n '/--apply/,/^}/p' "$MK" | grep -- '-f "$_frag"' >/dev/null; then
    ok "落盘后回查片段文件 (不拿退出码当成功)"
else
    bad "落盘后没有回查文件 → 「退出码 0 但没写成」会再次瞒过去"
fi

# ② 回车静默中止: 提示写「回车=<默认>」, 而 ui_ask_num 回车一律 return 1,
#    调用方 `|| return 0` 让整条流程以**成功**退出 —— 提示与行为相反。
if grep -E '^ui_ask_num\(\)' "$UI" >/dev/null \
   && sed -n '/^ui_ask_num()/,/^}/p' "$UI" | grep -- 'def="${4:-}"' >/dev/null; then
    ok "ui_ask_num 支持可选默认值 (回车取默认, 不再静默取消)"
else
    bad "ui_ask_num 没有默认值参数 → 回车仍然会静默中止调用方"
fi
# 行为验证: 回车 + 默认值 必须返回 0 且给出默认; 不给默认时仍然取消
UAD=$(bash -c "
source '$UI' 2>/dev/null
a=\$(printf '\n' | ui_ask_num '测试' 1 4 3 2>/dev/null) && echo \"def=\$a\" || echo 'def=RC1'
printf '0\n' | ui_ask_num '测试' 1 4 3 >/dev/null 2>&1 && echo 'zero=RC0' || echo 'zero=RC1'
" 2>/dev/null | tr '\n' ',')
assert_eq "$UAD" "def=3,zero=RC1," \
    "回车取默认值(3) 且返回 0; 输 0 仍是取消"

# ③ 菜单数字写死: 「25 个预置」而表里已经 27 个
if grep -E 'ui_menu 13 ' "$ROOT/xray-panel.sh" | grep -E '\$\(_xray_preset_total\)' >/dev/null; then
    ok "预置总数由 _xray_preset_total 算出来 (不写死)"
else
    bad "菜单里的预置总数是写死的 → 表一变就对不上"
fi
PT2=$(bash -c "source '$ROOT/conf/lib/preset.sh'; t=0; for p in \$(x_preset_protocols); do t=\$((t+\$(x_preset_count \$p))); done; echo \$t" 2>/dev/null)
if [[ -n "$PT2" && "$PT2" =~ ^[0-9]+$ ]]; then
    ok "预置总数算得出来 ($PT2 个)"
else
    bad "预置总数算不出来"
fi

# ④ TLS 入站没有证书: 内核 -test 放行、真启动成功、**每次握手都失败**
#    (tls: no certificates configured)。建 TLS 节点前必须找到证书或明确拒绝。
if grep -F 'x_cert_find_for_domain' "$MK" >/dev/null; then
    ok "建 TLS 节点时会去找匹配的证书"
else
    bad "mknode 只收域名不找证书 → 生成的 TLS 入站没有 certificates, 永远连不上"
fi
if sed -n '/没找到/,/return 1/p' "$MK" | grep -F 'return 1' >/dev/null; then
    ok "找不到证书时明确拒绝 (不生成必然连不上的节点)"
else
    bad "找不到证书时没有拒绝"
fi
# 证书查找函数本身要在, 且能按域名命中
if grep -E '^x_cert_find_for_domain\(\)' "$ROOT/conf/lib/cert.sh" >/dev/null; then
    ok "x_cert_find_for_domain 在 conf/lib/cert.sh 里"
else
    bad "x_cert_find_for_domain 不存在"
fi
CFD=$(CD=$(mktemp -d) bash -c '
CD=$CD
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$CD/a.example.com.key" -out "$CD/a.example.com.crt" \
  -subj "/CN=a.example.com" -addext "subjectAltName=DNS:a.example.com" 2>/dev/null
source "'"$ROOT"'/conf/lib/cert.sh" 2>/dev/null
X_CERT_EXTRA_DIRS="$CD"
hit=$(X_CERT_EXTRA_DIRS="$CD" x_cert_find_for_domain a.example.com 2>/dev/null)
[[ -n "$hit" ]] && echo HIT || echo MISS
X_CERT_EXTRA_DIRS="$CD" x_cert_find_for_domain other.example.com >/dev/null 2>&1 && echo BAD || echo NOMATCH
rm -rf "$CD"' 2>/dev/null | tr '\n' ',')
assert_eq "$CFD" "HIT,NOMATCH," \
    "证书按域名命中 (a.example.com 命中, other.example.com 不误配)"

# ------------------------------------------------- 证书方案 (对标 sing-box-core)
group "证书方案: 三条路都通 + CDN 准入 + 自签 pin"

CT="$ROOT/conf/lib/cert.sh"
DP="$ROOT/conf/lib/deploy.py"

# ① 关键 helper 必须在 —— 少一个就是 "command not found", 而报错出现在
#    建节点流程的中间, 用户看到的是一句与证书无关的话。
for _f in x_cert_key_for x_cert_not_expired x_cert_selfgen x_cert_list_domains x_cert_find_for_domain; do
    grep -E "^${_f}\(\)" "$CT" >/dev/null \
        && ok "cert.sh 有 $_f" || bad "cert.sh 缺 $_f"
done

# ② 私钥命名要挨个试 (acme.sh / certbot / KPanel / nginx 落盘命名都不一样)。
#    只试一种的症状是"明明有证书却判成没有私钥"。
_NK=$(grep -A 8 '^x_cert_key_for()' "$CT" | grep -c 'privkey.pem\|_key.pem\|\.key')
[[ "$_NK" -ge 3 ]] && ok "私钥命名候选 >= 3 种 (跨工具兼容)" \
    || bad "x_cert_key_for 只试 $_NK 种命名 → 别的工具落的证书会判成缺私钥"

# ③ 域名去重 + 状态标记 (重复列同一张证书会让编号对不上号)
grep -E '^x_cert_list_domains\(\)' "$CT" >/dev/null \
    && ok "证书列表按域名去重" || bad "没有按域名去重"

# ④ CDN 档 + 自签必须被拦住 —— Cloudflare 不接受自签证书。
#    不拦的症状是用户配完 nginx 才发现 526, 而我方一句提示都没有。
MK="$ROOT/conf/mknode.sh"
if sed -n '/CDN, 但证书是自签/,/return 1/p' "$MK" | grep -F 'return 1' >/dev/null; then
    ok "CDN 档 + 自签被拦住 (Cloudflare 不接受自签)"
else
    bad "CDN 档允许自签证书 → 回源必然失败"
fi

# ⑤ 自签必须带 pin: 不算 pin 的后果是客户端做正常校验必然失败,
#    表现是"配置全对、服务在跑、就是连不上"。
if grep -F 'x_cert_client_pin' "$MK" >/dev/null \
   && grep -F 'cert_pin' "$DP" >/dev/null; then
    ok "自签证书带 pin 且进了分享元数据"
else
    bad "自签证书没有 pin → 客户端连不上, 而产物看起来完全正常"
fi

# ⑥ nginx 档建节点必须**顺手配好反代**。
#    只写片段 + 打印一行"提示: 还需配置反代"的后果: 节点监听 127.0.0.1,
#    却没人转发流量 —— 客户端连域名:443 打不到任何东西, 面板显示节点已建好。
# ★ 断言要看**代码**, 不看注释: 注释里为了说明坑, 常常把错误写法原样写出来
#   (「写成 ["--nginx", "-t"] 会报错」), 直接把源码喂给 grep 会把注释也命中,
#   于是"修好了"反而报红。这里先把注释行去掉再看。
_DEP_NG=$(sed -n '/^def _configure_nginx/,/^def _write_plan/p' "$DP" | grep -v '^[[:space:]]*#')
if printf '%s\n' "$_DEP_NG" | grep -F -- '--origin-tls' >/dev/null; then
    bad "回源带了 --origin-tls → 对明文端口说 TLS (nginx 档 xray 是 security:none)"
else
    ok "nginx 档回源不带 --origin-tls (与 security:none 一致)"
fi
# --nginx 必须**不传**: 它的默认值就是 "-t", 而 ["--nginx","-t"] 会被 argparse
# 当成另一个选项, 报 "expected one argument"。
if printf '%s\n' "$_DEP_NG" | grep -F -- '--nginx' >/dev/null; then
    bad "传了 --nginx → argparse 会把 -t 当选项 (nginx_apply.py:1359 记过这个坑)"
else
    ok "没有 --nginx 分开写法的坑"
fi
# nginx 档建节点必须真的去配反代 (不能只打印一行"还需配置反代")
if sed -n '/^def _write_plan/,/^def _emit_products/p' "$DP" | grep -F '_configure_nginx(r)' >/dev/null; then
    ok "nginx 档建节点时自动配反代"
else
    bad "nginx 档只写片段不配反代 → 节点监听回环但没人转发"
fi
# 配不上时**保留节点**并把原因与出路说清楚 (发布侧会拒发回环节点, 所以安全)
if sed -n '/^def _configure_nginx/,/^def _write_plan/p' "$DP" | grep -F '返回 (ok, 原因)' >/dev/null \
   && grep -F '它不会被发到订阅里' "$DP" >/dev/null; then
    ok "nginx 配不上时保留节点 + 说明出路 (不静默留一个转发不到的节点)"
else
    bad "nginx 配不上时的处理没说清楚"
fi

# ------------------------------------------------- 本轮: 回落 / 混淆 / 路径一致性
group "回落 (fallbacks) · Hysteria2 混淆 · 两条建节点路径一致"

NB="$ROOT/conf/lib/node_build.py"
MK="$ROOT/conf/mknode.sh"
PB="$ROOT/tools/preset_batch.sh"

# ① 回落: 只在 TLS 上有意义, 且内核只对 VLESS/Trojan 实现了它。
#    内核实测: 普通 HTTPS 打 VLESS 端口拿到回落目标的网页, 真客户端仍 200。
if grep -F '_fallbacks(opts' "$NB" >/dev/null; then
    ok "node_build 支持回落 (fallbacks)"
else
    bad "node_build 没有回落支持"
fi
_FB=$(R="$ROOT" python3 - <<'PYX' 2>/dev/null
import sys, os
sys.path.insert(0, os.path.join(os.environ["R"], "conf", "lib"))
import node_build as NB
out = []
# TLS 应该写得出来
f = NB.build("vless","tcp","tls", {"listen":"0.0.0.0","port":443,"uuid":"u",
      "cert_file":"/tmp/c","key_file":"/tmp/k","sni":"a.com","fallback_port":"8080"})
out.append("tls=" + str(f["inbounds"][0]["settings"].get("fallbacks")))
# REALITY 应该被拒 (它有自己的 target, 两套不混)
try:
    NB.build("vless","tcp","reality", {"listen":"0.0.0.0","port":443,"uuid":"u",
        "private_key":"a"*43,"short_id":"ab","sni":"a.com","public_key":"b"*43,
        "fallback_port":"8080"})
    out.append("reality=NOTBLOCKED")
except Exception:
    out.append("reality=blocked")
print(",".join(out))
PYX
)
if [[ "$_FB" == *"tls=[{'dest': 8080, 'xver': 0}]"* && "$_FB" == *"reality=blocked"* ]]; then
    ok "回落: TLS 写得出来, REALITY 被拒 (不与 target 混用)"
else
    bad "回落行为不对: $_FB"
fi
# 交互里要问得到, 且默认是不回落
if grep -F '回落 (fallbacks)' "$MK" >/dev/null; then
    ok "mknode 交互里有回落这一问"
else
    bad "mknode 里问不到回落 → 这个选配用户够不着"
fi

# ② Hysteria2 salamander 混淆 —— 走内核的 finalmask 体系, 字段名**全小写**。
#    写错大小写内核不报错、也不生效, 直接静默失效。
if grep -F 'finalmask' "$NB" >/dev/null && grep -F 'salamander' "$NB" >/dev/null; then
    ok "node_build 支持 Hysteria2 salamander 混淆 (finalmask)"
else
    bad "Hysteria2 混淆没实现"
fi
if grep -v '^[[:space:]]*#' "$NB" | grep -F 'finalMask' >/dev/null; then
    bad "用了 finalMask (大写 M) —— 内核只认全小写的 finalmask, 写错是静默失效"
else
    ok "字段名是全小写 finalmask (大写不生效且不报错)"
fi
_HY=$(R="$ROOT" python3 - <<'PYX' 2>/dev/null
import sys, os
sys.path.insert(0, os.path.join(os.environ["R"], "conf", "lib"))
import node_build as NB, to_mihomo as M
f = NB.build("hysteria2","hysteria","tls", {"listen":"0.0.0.0","port":443,"password":"pw",
      "cert_file":"/tmp/c","key_file":"/tmp/k","sni":"a.com","hy2_obfs_password":"sec"})
fm = (f["inbounds"][0]["streamSettings"].get("finalmask") or {}).get("udp") or []
srv = "finalmask-ok" if fm and fm[0]["type"] == "salamander" else "finalmask-BAD"
n = M.node_from_fragment(f, {"host":"1.2.3.4","port":443}, name="h")
p = M.proxy(n) or {}
# ★ obfs 与 obfs-password 必须成对; 只写 obfs 会让 mihomo **整批**报
#   "missing obfs password" (项目自己踩过)
pair = "pair-ok" if p.get("obfs") == "salamander" and p.get("obfs-password") == "sec" else "pair-BAD"
f2 = NB.build("hysteria2","hysteria","tls", {"listen":"0.0.0.0","port":443,"password":"pw",
      "cert_file":"/tmp/c","key_file":"/tmp/k","sni":"a.com"})
p2 = M.proxy(M.node_from_fragment(f2, {"host":"1.2.3.4","port":443}, name="h")) or {}
clean = "clean-ok" if "obfs" not in p2 else "clean-NOISE"
# hysteria2 以前**永远**生成不出 mihomo YAML (network=hysteria 落到 else 分支被拒)
was = "hy2-yaml-ok" if p2.get("type") == "hysteria2" else "hy2-yaml-BROKEN"
print(srv + "," + pair + "," + clean + "," + was)
PYX
)
assert_eq "$_HY" "finalmask-ok,pair-ok,clean-ok,hy2-yaml-ok" \
    "Hysteria2 混淆: 服务端 finalmask / mihomo 成对字段 / 不开时干净 / hy2 能出 YAML"

# ③ 两条建节点路径必须给**同一个** xhttp mode。
#    实测过的缺陷: 菜单 13 (mknode) 给 stream-up, 菜单 14/15 (preset_batch)
#    给 auto —— 而 REALITY 下 auto = stream-one = 合流, 与预置⑥的说明相反。
if grep -F 'xhttp_mode' "$PB" >/dev/null; then
    ok "preset_batch 也会设 xhttp mode (不再是 auto)"
else
    bad "preset_batch 不设 xhttp mode → 与菜单13 走出不同配置"
fi

# ③b 服务端**不写** xhttp mode; nginx 侧靠 grpc_pass 支持全部三种
#
#     ★ 这里纠正的是我自己上一版写错的判据。当时的实测是对的 (stream-up 过不了
#       nginx), 但结论下错了 —— 真正的原因是 nginx 用了 proxy_pass, 而官方
#       文档的快速上手第 5 条写得很清楚:
#         「无法穿透 Nginx 的话, 把 Nginx 的 proxy_pass 改为 grpc_pass」
#       改成 grpc_pass 之后, 三种模式**全部**能过 (RN 上真连实测):
#         proxy_pass → packet-up 204 / stream-up 000 / stream-one 000
#         grpc_pass  → packet-up 204 / stream-up 204 / stream-one 204
#       而"把服务端 mode 钉死成 packet-up"会把 stream-up/stream-one 一起废掉
#       (实测: 服务端写 packet-up + nginx grpc_pass → 仍然只有 packet-up 通),
#       连浏览器拨号那条路也一起废 —— 它的 HTTP 版本与 mode 由浏览器决定。
_MODGATE=$(XRAY_ROOT="$ROOT" python3 - <<'PYX'
import sys, os, io, contextlib
sys.path.insert(0, os.path.join(os.environ["XRAY_ROOT"], "conf", "lib"))
import deploy as D
base = {"port": 30810, "uuid": "u", "domain": "a.com", "sni": "a.com",
        "cert_file": "/tmp/c", "key_file": "/tmp/k", "tag": "t"}
def settings(tier, **kw):
    with contextlib.redirect_stderr(io.StringIO()):
        r = D.plan("vless", "xhttp", "tls", dict(base, **kw), tier)
    f = r.get("fragment") or {}
    ib = (f.get("inbounds") or [{}])[0]
    return (ib.get("streamSettings") or {}).get("xhttpSettings", {})
def m(tier, mode=None, **kw):
    if mode:
        kw["xhttp_mode"] = mode
    xh = settings(tier, **kw)
    return "no-mode" if "mode" not in xh else xh["mode"]
out = []
out.append("up->nginx=%s" % m("nginx", "stream-up"))
out.append("one->nginx=%s" % m("nginx", "stream-one"))
out.append("pu->nginx=%s" % m("nginx", "packet-up"))
out.append("up->cdn=%s" % m("cdn", "stream-up"))
out.append("auto->nginx=%s" % m("nginx", "auto"))
out.append("pin->nginx=%s" % m("nginx", xhttp_server_mode="packet-up"))
# 选什么 mode 都要能在**客户端产物**里找到它 (那才是 mode 该出现的地方)
with contextlib.redirect_stderr(io.StringIO()):
    r = D.plan("vless", "xhttp", "tls", dict(base, xhttp_mode="stream-up"), "nginx")
out.append("meta.mode=%s" % (r["meta"].get("mode") or r["meta"].get("xhttp_mode") or "-"))
print(",".join(out))
PYX
)
assert_eq "$_MODGATE" \
    "up->nginx=no-mode,one->nginx=no-mode,pu->nginx=no-mode,up->cdn=no-mode,auto->nginx=no-mode,pin->nginx=packet-up,meta.mode=stream-up" \
    "服务端不写 xhttp mode (三种都接受); 显式钉死才写; mode 落在客户端产物里"

# ③b2 nginx 片段里 xhttp 必须用 grpc_pass —— 官方快速上手第 5 条
if grep -F 'grpc_pass grpc://127.0.0.1:{port};' "$ROOT/conf/lib/nginx_apply.py" >/dev/null \
   && sed -n '/elif transport in ("xhttp", "grpc"):/,/L.append(f"{ind}}}")/p' \
        "$ROOT/conf/lib/nginx_apply.py" | grep -F 'grpc_pass' >/dev/null; then
    ok "nginx 片段对 xhttp/gRPC 用 grpc_pass (官方第 5 条, 三种 mode 都能过)"
else
    bad "nginx 用 proxy_pass 转 xhttp → stream-up/stream-one 过不去, 只能退化成 packet-up"
fi
# ③b3 非 xhttp 的传输层**不能**改成 grpc_pass (ws/httpupgrade 走 HTTP/1.1 升级)
if sed -n '/^    else:$/,/L.append(f"{ind}}}")/p' "$ROOT/conf/lib/nginx_apply.py" \
     | grep -F 'proxy_pass http://127.0.0.1:{port};' >/dev/null; then
    ok "ws / httpupgrade 仍是 proxy_pass (grpc_pass 只适用于 xhttp/gRPC)"
else
    bad "把 ws/httpupgrade 也改成 grpc_pass 了 → 那两种会整体坏掉"
fi

# ③c 取消"静默纠正 mode"这件事本身 —— 现在没有纠正可做了, 但要防它回来
if sed -n '/^def plan/,/^def adopt/p' "$ROOT/conf/lib/deploy.py" \
     | grep -F '已自动改为 packet-up' >/dev/null; then
    bad "plan() 又在自动改写 xhttp mode → 服务端被限死, 另两种模式会连不上"
else
    ok "plan() 不再自动改写 xhttp mode (服务端接受三种)"
fi

# ③d 路径 B 的默认值: 跟着 Xray 的 auto 口径走, 不再按档位硬塞 packet-up
#     (实测依据见 conf/lib/node_build.py 里 xhttp 那一段)
if grep -F 'tier == "nginx"' "$PB" >/dev/null \
   && sed -n '/tier == "nginx"/,+2p' "$PB" | grep -F 'packet-up' >/dev/null; then
    bad "preset_batch 仍对 nginx 档默认 packet-up → 把 stream-up/stream-one 一起废掉"
else
    ok "preset_batch 不再按档位硬塞 packet-up"
fi

# ③e 菜单 13 的模式默认值同理
if sed -n '/XHTTP 的上下行模式/,/ui_ask_num "上下行模式"/p' "$ROOT/conf/mknode.sh" \
     | grep -F 'def_i=2' >/dev/null; then
    bad "mknode 仍对 nginx 档默认选中 packet-up → 与服务端口径不一致"
else
    ok "mknode 不再按档位硬塞 packet-up"
fi

# ③e2 mode 必须**落在客户端产物**里 (服务端不写它了, 别把它弄丢)
if grep -F 'meta["mode"] = _m' "$ROOT/conf/lib/deploy.py" >/dev/null \
   && grep -F '(meta or {}).get("mode")' "$ROOT/conf/lib/nodes.py" >/dev/null \
   && grep -F 'meta.get("mode")' "$ROOT/conf/lib/to_mihomo.py" >/dev/null; then
    ok "mode 写进元数据, 链接与 YAML 都从元数据兜底取 (不会丢)"
else
    bad "服务端不写 mode 之后没人接住它 → 用户选的那一项会凭空消失"
fi

# ③e3 分享链接要有官方 extra (GUI 只认 host/path/mode/extra 四项)
if grep -F 'def xhttp_extra' "$ROOT/conf/lib/nodes.py" >/dev/null \
   && grep -F 'q["extra"] = _json.dumps' "$ROOT/conf/lib/nodes.py" >/dev/null; then
    ok "分享链接带官方 extra (别人家的 GUI 也认)"
else
    bad "链接只有自定义的 dl* 参数 → 其它客户端导入后配置被忽略"
fi
# mihomo 的 XMUX: 官方 wiki 说它没有默认值, 不写就每次新连接
if grep -F 'reuse-settings' "$ROOT/conf/lib/to_mihomo.py" >/dev/null \
   && grep -F 'h-max-reusable-secs' "$ROOT/conf/lib/to_mihomo.py" >/dev/null; then
    ok "mihomo 产物带 reuse-settings (XMUX) —— 它没有默认值, 不写就是每个请求新连接"
else
    bad "mihomo 产物缺 reuse-settings → 连接复用完全没开"
fi

# ③f nginx 档的 path 不能默认落在 "/"。
#     ★ 这是"按用户的操作路径走一遍"抓到的**端到端死活不通**的根因:
#       mknode 从不问 path → nginx_apply 拿到 "/" → 往真站点里插 `location /`
#       → 站点已经有首页 location / → 正确地拒绝 (duplicate location)
#       → 没人转发 → 客户端连过去看到的是网站首页。
#       全链路每一环单独看都"正常", 面板只多一行警告。
_PATHGATE=$(XRAY_ROOT="$ROOT" python3 - <<'PYX'
import sys, os
sys.path.insert(0, os.path.join(os.environ["XRAY_ROOT"], "conf", "lib"))
import deploy as D
base = {"port": 31501, "uuid": "u", "domain": "a.com", "sni": "a.com",
        "cert_file": "/tmp/c", "key_file": "/tmp/k", "tag": "t", "xhttp_mode": "packet-up"}
a = D.plan("vless", "xhttp", "tls", dict(base), "nginx")
b = D.plan("vless", "xhttp", "tls", dict(base, path="/keep"), "nginx")
c = D.plan("vless", "xhttp", "tls", dict(base), "cdn")
pa = a["fragment"]["inbounds"][0]["streamSettings"]["xhttpSettings"].get("path", "/")
pb = b["fragment"]["inbounds"][0]["streamSettings"]["xhttpSettings"].get("path", "/")
pc = c["fragment"]["inbounds"][0]["streamSettings"]["xhttpSettings"].get("path", "/")
# 片段与 nginx 段必须是**同一个** path —— 不一致 = 客户端走一条、nginx 转发另一条
same = "same" if a["nginx"]["path"] == pa else "MISMATCH"
uniq = "uniq" if (pa not in ("/", "") and len(pa) > 8) else "short"
print("auto=%s,keep=%s,cdn=%s,nginx-consist=%s,rand=%s"
      % ("ok" if pa.startswith("/") and pa != "/" else "BAD", pb, pc, same, uniq))
PYX
)
assert_eq "$_PATHGATE" "auto=ok,keep=/keep,cdn=/,nginx-consist=same,rand=uniq" \
    "nginx 档自动分配唯一 path; 显式 path 尊重; CDN 档不变; 片段与 nginx 段一致"

# ③g nginx 反代失败时, 理由必须是**完整的一段**, 不能只截最后一行。
#     实测缺陷: 取 detail[-1] → 屏幕上出现 "nginx 反代没配上 (       办法二: ...)"
#     —— 左括号配不上一句话, 真正的原因 (同名冲突) 和首选出路 (办法一) 全丢了。
# 只看**代码**, 不看注释 —— 注释里正解释着"以前写的是 detail[-1]",
# 不排掉注释的话这条门禁会把解释文字当成违规。
_CFG_CODE=$(sed -n '/def _configure_nginx/,/^def /p' "$ROOT/conf/lib/deploy.py" \
            | grep -v '^[[:space:]]*#')
if printf '%s' "$_CFG_CODE" | grep -F 'join(detail)' >/dev/null \
   && ! printf '%s' "$_CFG_CODE" | grep -F 'detail[-1]' >/dev/null; then
    ok "nginx 反代失败理由带整段 (不再只取最后一行)"
else
    bad "nginx 反代失败理由仍被截断 → 用户看不懂为什么没配上"
fi
# 多行理由不能塞进括号 (换行会把括号撑成"左括号 + 半句话")
if sed -n '/nginx 反代没配上/,/textwrap.indent/p' "$ROOT/conf/lib/deploy.py" \
     | grep -F 'textwrap.indent' >/dev/null; then
    ok "多行理由按缩进贴出, 没塞进括号"
else
    bad "多行理由被塞进括号 → 显示成半句话"
fi

# ④ 全协议 (菜单12) 要像 SB 一样自动配 nginx
if grep -F 'resolve_cdn_auto' "$ROOT/conf/batch.sh" >/dev/null \
   && grep -F 'x_cdn_autosetup' "$ROOT/conf/batch.sh" >/dev/null; then
    ok "全协议一键生成会自动配 nginx 反代 (照 SB)"
else
    bad "全协议一键生成不配 nginx → nginx 档节点建完没人转发"
fi
# cdn_auto.sh 加载不上时必须出声
if sed -n '/resolve_cdn_auto/,/^fi/p' "$ROOT/conf/batch.sh" | grep -F 'print_warn' >/dev/null; then
    ok "cdn_auto.sh 加载不上时会告警 (不静默跳过)"
else
    bad "cdn_auto.sh 加载失败是静默的"
fi

# ⑤ VMess + HTTPUpgrade 预置 (用户问"没有吗")
if grep -E '^\s*"vmess\|httpupgrade\|' "$ROOT/conf/lib/preset.sh" >/dev/null; then
    ok "VMess 有 HTTPUpgrade 预置"
else
    bad "VMess 没有 HTTPUpgrade 预置"
fi

# ------------------------------------------------- nginx 档客户端视角
group "nginx 档: 客户端加密层 ≠ 片段里的加密层"

# ★ 这一条是"真连才发现"的: 片段里的 security 是 **xray 入站**用的
#   (nginx 档 = none, 因为 TLS 由 nginx 终结), 而客户端连的是 nginx 的 443,
#   必须走 TLS。照搬片段里那个, 客户端就用明文去连 HTTPS 端口 ——
#   实测 mihomo 先发明文 HTTP/2 前言再发 TLS, Cloudflare 直接关连接,
#   客户端 000 而服务端一个字节都收不到。
#   本机自测看不出来 (nginx 自己会 400), 所以两处都要有专门断言。
_NGC=$(R="$ROOT" python3 - <<'PYX' 2>/dev/null
import sys, os
sys.path.insert(0, os.path.join(os.environ["R"], "conf", "lib"))
import nodes as N, to_mihomo as M
frag = {"inbounds": [{"tag": "t", "port": 443, "protocol": "vless",
        "settings": {"clients": [{"id": "u"}], "decryption": "none"},
        "streamSettings": {"network": "xhttp", "security": "none",
                           "xhttpSettings": {"path": "/p", "mode": "stream-up"}}}]}
meta_ng = {"host": "a.example.com", "port": 443, "tier": "nginx"}
meta_cdn = {"host": "a.example.com", "port": 443, "tier": "cdn"}
out = []
# nginx 档 → 客户端必须是 tls
n1 = M.node_from_fragment(frag, meta_ng, name="t")
p1 = M.proxy(n1) or {}
out.append("yaml-nginx=" + str(p1.get("tls")))
# cdn 档 → 片段说 none 就是 none (客户端直连源站)
n2 = M.node_from_fragment(frag, meta_cdn, name="t")
p2 = M.proxy(n2) or {}
out.append("yaml-cdn=" + str(p2.get("tls")))
# 分享链接同理
def link(meta):
    n = N.extract(frag["inbounds"][0], "t.json")
    return N.build_share_link(n, meta) or ""
import urllib.parse as U
q1 = dict(U.parse_qsl(U.urlparse(link(meta_ng)).query))
q2 = dict(U.parse_qsl(U.urlparse(link(meta_cdn)).query))
out.append("link-nginx=" + str(q1.get("security")))
out.append("link-cdn=" + str(q2.get("security")))
# REALITY 档不能被这条规则改掉
frag2 = {"inbounds": [{"tag": "t", "port": 443, "protocol": "vless",
         "settings": {"clients": [{"id": "u"}], "decryption": "none"},
         "streamSettings": {"network": "xhttp", "security": "reality",
                            "realitySettings": {"serverNames": ["s.com"]},
                            "xhttpSettings": {"path": "/p", "mode": "stream-up"}}}]}
m2 = {"host": "a.example.com", "port": 443, "tier": "nginx",
      "public_key": "b" * 43, "short_id": "ab"}
n3 = M.node_from_fragment(frag2, m2, name="t")
out.append("reality-untouched=" + str((M.proxy(n3) or {}).get("tls")))
print(",".join(out))
PYX
)
assert_eq "$_NGC" "yaml-nginx=True,yaml-cdn=False,link-nginx=tls,link-cdn=none,reality-untouched=True" \
    "nginx 档客户端走 tls / cdn 档照搬片段 / REALITY 不受影响 (YAML 与链接两处)"

# ------------------------------------------------- 上传前验证
assert_ne0 "$(grep -c '而不是' "$ROOT/tools/prepush_check.sh" 2>/dev/null)" \
    "上传前验证脚本在仓库里 (tools/prepush_check.sh)"

# ------------------------------------------------- 服务器标识 (借鉴 SB)
group "服务器标识 (旗帜 + 默认值)"

NM="$TMP/nm"; mkdir -p "$NM"

# ★ 默认值必须是 **旗帜 + hostname**, 不能是光一个 "X"。
#   两台机器都跑同一个 Xray 面板, 前缀都是 "X" 时, 用户什么都没做也分不出
#   哪个节点属于哪台 —— 是默认值让他分不出来的, 所以默认值本身要带区分度。
DN=$(XRAY_BASE="$NM" python3 "$LIB/naming.py" default 2>/dev/null)
HN=$(hostname 2>/dev/null | tr -d '\r\n')
[[ -z "$HN" ]] && HN=$(tr -d '\r\n' < /proc/sys/kernel/hostname 2>/dev/null)
if [[ -n "$HN" ]]; then
    case "$DN" in
        *"$HN"*) ok "默认服务器标识含主机名: $DN" ;;
        *) bad "默认服务器标识应含主机名 (得到 '$DN', 主机名 '$HN')" ;;
    esac
else
    ok "默认服务器标识可生成: ${DN:-(空)}"
fi

# 改名字时旗帜不能丢 —— 旗帜是**服务器的属性**, 不是名字的一部分
# (SB 在这条上踩过一次: 提示里写着 🇺🇸 myserver, 用户输入短名字后旗帜就没了)
A=$(XRAY_BASE="$NM" python3 "$LIB/naming.py" set "HK1" 2>/dev/null)
B=$(XRAY_BASE="$NM" python3 "$LIB/naming.py" set "HK-relay" 2>/dev/null)
AF=$(printf '%s' "$A" | grep -om1 -P '[\x{1F1E6}-\x{1F1FF}]{2}' || true)
BF=$(printf '%s' "$B" | grep -om1 -P '[\x{1F1E6}-\x{1F1FF}]{2}' || true)
if [[ -n "$AF" && "$AF" == "$BF" ]]; then
    ok "改名后旗帜仍在: $A -> $B"
else
    # 查不到旗帜 (离线) 时至少不能变成两个不同的旗帜
    if [[ -z "$AF" && -z "$BF" ]]; then ok "改名后旗帜一致 (本次无旗帜, 离线)"
    else bad "改名丢了旗帜: '$A' -> '$B'" ; fi
fi

# prefix 必须是纯 ASCII —— tag 要进配置文件和文件路径
PFX=$(XRAY_BASE="$NM" python3 "$LIB/naming.py" prefix 2>/dev/null)
case "$PFX" in
    *[!a-zA-Z0-9_-]*) bad "prefix 含非 ASCII (tag 不安全): $PFX" ;;
    *) ok "prefix 是纯 ASCII: $PFX" ;;
esac

# 显示名必须非空 —— 空 fragment 会让客户端退化成用域名当名字
DN2=$(XRAY_BASE="$NM" python3 "$LIB/naming.py" display "x-vless01-TLS" 2>/dev/null)
[[ -n "$DN2" ]] && ok "显示名非空: $DN2" || bad "显示名为空"
DN3=$(XRAY_BASE="$NM" python3 "$LIB/naming.py" display "" 2>/dev/null)
[[ -n "$DN3" ]] && ok "空 tag 也有非空名字: $DN3" || bad "空 tag 拿到空名字"

# ★ batch 的"服务器标识"必须落在 naming.py 那一份缓存上, 不能自己另存一份。
#   原来 batch.sh 写的是 $XRAY_BASE/.server-name, 而单协议建节点走 naming.py 的
#   NAME_CACHE —— 两个位置、两个答案, 于是同一个客户端里前缀忽有忽无。
BS=$(grep -c 'naming.py" set' "$ROOT/conf/batch.sh" 2>/dev/null)
assert_eq "$BS" "1" "batch 的服务器标识落到 naming.py 缓存 (不另存一份)"

# ---------------------------------------------------------------- 预置建节点
group "预置建节点 (mknode → deploy)"
MK="$TMP/mk"; mkdir -p "$MK/conf" "$MK/share"
python3 "$LIB/deploy.py" --config-json \
  '{"protocol":"vless","transport":"ws","security":"tls","tag":"v-ws-1","port":8443,"domain":"a.com","uuid":"u1","tier":"cdn"}' \
  --conf-dir "$MK/conf" --share-dir "$MK/share" --apply >/dev/null 2>&1
python3 "$LIB/deploy.py" --config-json \
  '{"protocol":"trojan","transport":"tcp","security":"reality","tag":"t-re-1","port":8444,"domain":"a.com","password":"PW","private_key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","public_key":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tier":"cdn"}' \
  --conf-dir "$MK/conf" --share-dir "$MK/share" --apply >/dev/null 2>&1
assert_eq "$(ls "$MK/conf"/*.json 2>/dev/null | wc -l)" "2" "JSON 路径落盘片段"
assert_eq "$(ls "$MK/share"/*.json 2>/dev/null | wc -l)" "2" "JSON 路径落盘分享元数据"
MK1=$(python3 "$LIB/deploy.py" --protocol trojan --transport ws --security tls --port 8555 --domain b.com --password p 2>/dev/null | grep -c 'TROJAN + WebSocket + TLS')
assert_eq "$MK1" "1" "命令行路径仍可用"
MK2=$(python3 "$LIB/deploy.py" --port 8443 2>&1 | grep -c '缺少必填参数')
assert_eq "$MK2" "1" "缺参数明确报错"
# 预演与落盘必须给出一致的呈现
PV=$(python3 "$LIB/deploy.py" --config-json '{"protocol":"vless","transport":"ws","security":"tls","tag":"pv","port":9001,"domain":"c.com","uuid":"u","tier":"cdn"}' 2>/dev/null | grep 'Xray 监听' | sed 's/^ *//')
assert_eq "$PV" "Xray 监听: 0.0.0.0:9001" "预演呈现与落盘一致"
# 落盘的节点必须能被注册表与 Client 吃下
python3 - "$LIB" "$MK" > "$TMP/mksub.txt" <<'PY'
import sys, base64; sys.path.insert(0, sys.argv[1])
import nodes as N, share_meta
nl, _ = N.collect(sys.argv[2] + "/conf")
links = []
for n in nl:
    m = share_meta.load(sys.argv[2] + "/share", n["tag"]) or {}
    l = N.build_share_link(n, m)
    if l: links.append(l)
print(base64.b64encode("\n".join(links).encode()).decode())
PY
MKN=$(python3 "$ROOT/Client/lib/node.py" subscription "$TMP/mksub.txt" 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
assert_eq "$MKN" "2" "预置建出的节点 Client 全部接受"
bash -n "$ROOT/conf/mknode.sh" 2>/dev/null && ok "mknode.sh 语法" || bad "mknode.sh 语法"

# ---------------------------------------------------------------- 分享链接覆盖
# 内核实机跑出 18 个节点, 6 个生成分享链接失败, 两个不同原因:
#   REALITY (4 个) — meta 里没有 host。REALITY 不要证书, 于是域名没被传进去,
#                    而分享链接的 host 字段来自那里 —— 节点能跑却分享不出去,
#                    而分享链接是它唯一的存在理由。
#   socks/http (2) — Client 的 scheme 白名单里没有它们。这是有意的, 不是缺陷。
group "分享链接覆盖 (REALITY 也要能分享)"
PK=$(python3 -c "print('a'*43)"); PB=$(python3 -c "print('b'*43)")
LN="$TMP/links"; mkdir -p "$LN"
XRAY_CONF_DIR="$LN/c" XRAY_SHARE_DIR="$LN/s" X_BATCH_DOMAIN=e.com \
X_BATCH_REALITY_PRIVATE_KEY="$PK" X_BATCH_REALITY_PUBLIC_KEY="$PB" X_BATCH_PORT_START=25000 \
  bash "$ROOT/tools/preset_batch.sh" vless:1 trojan:1 >/dev/null 2>&1
RL=$(python3 - "$LIB" "$LN" <<'PYX'
import sys
sys.path.insert(0, sys.argv[1])
import nodes as N, share_meta
nl, _ = N.collect(sys.argv[2] + "/c")
ok = 0
for n in nl:
    m = share_meta.load(sys.argv[2] + "/s", n["tag"]) or {}
    if N.build_share_link(n, m):
        ok += 1
print("%d/%d" % (ok, len(nl)))
PYX
)
assert_eq "$RL" "2/2" "REALITY 节点也能生成分享链接"
RHL=$(python3 - "$LIB" "$LN" <<'PYX'
import sys, glob, os
sys.path.insert(0, sys.argv[1])
import share_meta as M
cands = [x for x in glob.glob(os.path.join(sys.argv[2], "s", "*.json"))
         if "reality" in x]
if not cands:
    print("无")
else:
    print(M.load(os.path.join(sys.argv[2], "s"),
                 os.path.basename(cands[0])[:-5]).get("host") or "")
PYX
)
assert_eq "$RHL" "e.com" "REALITY 的 meta 里带上了 host"

# 内核的 inbound id 是 hysteria (version 2), 分享 scheme 却是 hysteria2://。
# 匹配时漏了 "hysteria" 的话, 内核实机跑出来的 hysteria2 节点一个都生成不出
# 分享链接 —— 而 hysteria2 是预置表里唯一的 QUIC 协议。
AL2="$TMP/all"; mkdir -p "$AL2"
python3 "$LIB/deploy.py" --config-json '{"protocol":"hysteria2","transport":"hysteria","security":"tls","tag":"hy2","port":28000,"domain":"a.com","password":"AUTH1","tier":"cdn"}' --conf-dir "$AL2/c" --share-dir "$AL2/s" --apply >/dev/null 2>&1
python3 "$LIB/deploy.py" --config-json '{"protocol":"shadowsocks","transport":"tcp","security":"tls","tag":"ss","port":28001,"domain":"a.com","method":"aes-256-gcm","password":"PW1","tier":"cdn"}' --conf-dir "$AL2/c" --share-dir "$AL2/s" --apply >/dev/null 2>&1
ALR=$(python3 - "$LIB" "$AL2" <<'PYX'
import sys
sys.path.insert(0, sys.argv[1])
import nodes as N, share_meta
nl, _ = N.collect(sys.argv[2] + "/c")
res = {}
for n in nl:
    m = share_meta.load(sys.argv[2] + "/s", n["tag"]) or {}
    res[n["protocol"]] = N.build_share_link(n, m) or ""
print(res.get("hysteria", "")[:12] + "|" + res.get("shadowsocks", "")[:5])
PYX
)
assert_eq "$ALR" 'hysteria2://|ss://' "hysteria2 与 shadowsocks 都能生成分享链接"

# settings.auth 是 "noauth"/"password" 这种模式名, 不是用户名。当成用户名会
# 生成 socks5://noauth@host:443, 客户端拿 "noauth" 当密码, 认证必然失败。
python3 "$LIB/deploy.py" --config-json '{"protocol":"socks","transport":"tcp","security":"none","tag":"sk","port":28002,"domain":"a.com","tier":"nginx"}' --conf-dir "$AL2/c2" --share-dir "$AL2/s2" --apply >/dev/null 2>&1
SK=$(python3 - "$LIB" "$AL2/c2" "$AL2/s2" <<'PYX'
import sys
sys.path.insert(0, sys.argv[1])
import nodes as N, share_meta
nl, _ = N.collect(sys.argv[2])
print((N.build_share_link(nl[0], share_meta.load(sys.argv[3], nl[0]["tag"]) or {}) or "")[:30])
PYX
)
case "$SK" in
  *"noauth@"*) bad "socks 无认证: 把 noauth 当成了用户名" ;;
  socks5://*)  ok "socks 无认证: 不带 userinfo" ;;
  *)           bad "socks 链接异常: $SK" ;;
esac

# ---------------------------------------------------------------- 实机查出的三处
# 这一组全部来自 RN 实机跑 21 个预置时内核的真实反馈, 不是推测。
group "实机反馈 (SS2022 / hysteria2 / REALITY)"
SS16='eHh4eHh4eHh4eHh4eHh4eA=='; SS32='eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHg='
sschk() { python3 -c "
import sys; sys.path.insert(0,'$LIB'); import node_build as B
try:
    B.build('shadowsocks','tcp','$3',{'port':9000,'method':'$1','password':'$2'}); print('OK')
except B.NodeError: print('ERR')
except Exception: print('OTHER')"; }
assert_eq "$(sschk 2022-blake3-aes-128-gcm "$SS16" none)" "OK" "SS2022 aes-128: 24 字符通过"
assert_eq "$(sschk 2022-blake3-aes-256-gcm "$SS32" none)" "OK" "SS2022 aes-256: 44 字符通过"
assert_eq "$(sschk 2022-blake3-aes-128-gcm "$SS32" none)" "ERR" "SS2022 aes-128 收到 44 字符: 拒绝"
assert_eq "$(sschk 2022-blake3-aes-256-gcm "$SS16" none)" "ERR" "SS2022 aes-256 收到 24 字符: 拒绝"
assert_eq "$(sschk 2022-blake3-aes-128-gcm 'abcdefghijklmnop' none)" "ERR" "SS2022 非 base64 密码: 拒绝"
assert_eq "$(sschk aes-256-gcm '任意长度' none)" "OK" "传统 SS 加密不限长度"
assert_eq "$(sschk bogus-method x none)" "ERR" "未知加密方式: 拒绝"

# hysteria2: 内核的 inbound id 是 "hysteria" + version 2, 不是 "hysteria2"
HY=$(python3 -c "
import sys,json; sys.path.insert(0,'$LIB'); import node_build as B
i=B.build('hysteria2','hysteria','tls',{'port':9000,'password':'pw'})['inbounds'][0]
print(i['protocol'], i['settings']['version'], 'auth' in i['settings']['clients'][0],
      (i['streamSettings']['tlsSettings'].get('alpn') or ['-'])[0])")
assert_eq "$HY" "hysteria 2 True h3" "hysteria2: protocol 名/version/auth 字段/alpn 全对"
HY2=$(python3 -c "
import sys; sys.path.insert(0,'$LIB'); import node_build as B
i=B.build('trojan','ws','tls',{'port':9001,'password':'p','domain':'a.com'})['inbounds'][0]
print(i['streamSettings']['tlsSettings'].get('alpn','none'))")
assert_eq "$HY2" "none" "alpn=h3 只对 hysteria 生效"

# REALITY 非交互: read 会读到脏数据, 校验必须拦下来
RK=$(python3 -c "
import sys; sys.path.insert(0,'$LIB'); import node_build as B
try:
    B.build('vless','tcp','reality',{'port':9000,'private_key':'echo \"  ═══ 校验 ═══\"','public_key':'x'}); print('OK')
except B.NodeError: print('ERR')
except Exception: print('OTHER')")
assert_eq "$RK" "ERR" "REALITY 收到非密钥内容: 拒绝"
PBN="$TMP/pbn"; mkdir -p "$PBN"
RT=$(XRAY_CONF_DIR="$PBN/c" XRAY_SHARE_DIR="$PBN/s" bash "$ROOT/tools/preset_batch.sh" vless:1 < /dev/null 2>&1 | grep -c '不是终端')
assert_eq "$RT" "1" "非交互下 REALITY 明确拒绝 (不读脏数据)"
RT2=$(XRAY_CONF_DIR="$PBN/c2" XRAY_SHARE_DIR="$PBN/s2" \
  X_BATCH_REALITY_PRIVATE_KEY="$PBN" X_BATCH_REALITY_PUBLIC_KEY="$PBN" \
  bash "$ROOT/tools/preset_batch.sh" vless:1 < /dev/null 2>&1 | grep -c '不是终端')
assert_eq "$RT2" "0" "给了环境变量就不再要求终端"

# ---------------------------------------------------------------- 域名按需
# 域名只在两处真正需要: TLS 要证书, nginx 档要挂站点。之前无条件要求, 于是
# "无加密 + CDN" 这个组合永远建不出来, 而且报错说的是"缺少域名" —— 与用户
# 实际遇到的问题无关。
group "域名按需 (deploy.plan)"
D0=$(python3 "$LIB/deploy.py" --config-json '{"protocol":"shadowsocks","transport":"tcp","security":"none","tag":"t","port":19001,"tier":"cdn","method":"2022-blake3-aes-128-gcm","password":"eHh4eHh4eHh4eHh4eHh4eA=="}' 2>&1 | grep -c '裸 TCP + 无加密')
assert_eq "$D0" "1" "无加密+CDN: 报裸 TCP 限制 (不是报缺域名)"
D1=$(python3 "$LIB/deploy.py" --config-json '{"protocol":"shadowsocks","transport":"tcp","security":"none","tag":"t","port":19001,"tier":"nginx","method":"2022-blake3-aes-128-gcm","password":"eHh4eHh4eHh4eHh4eHh4eA=="}' 2>&1 | grep -c '缺少域名')
assert_eq "$D1" "1" "无加密+nginx: 仍要求域名 (要挂站点)"
D2=$(python3 "$LIB/deploy.py" --config-json '{"protocol":"shadowsocks","transport":"tcp","security":"tls","tag":"t","port":19001,"tier":"cdn","domain":"a.com","method":"2022-blake3-aes-128-gcm","password":"eHh4eHh4eHh4eHh4eHh4eA=="}' 2>&1 | grep -c 'SHADOWSOCKS + TCP + TLS')
assert_eq "$D2" "1" "TLS+CDN: 正常生成"
D3=$(python3 "$LIB/deploy.py" --config-json '{"protocol":"shadowsocks","transport":"tcp","security":"tls","tag":"t","port":19001,"tier":"nginx","domain":"a.com","method":"2022-blake3-aes-128-gcm","password":"eHh4eHh4eHh4eHh4eHh4eA=="}' 2>&1 | grep -c '监听: 127.0.0.1')
assert_eq "$D3" "1" "TLS+nginx: 监听本机"
# 裸 WS 无证书也不该要域名 (无证书 = 不需要 TLS 参数)
D4=$(python3 "$LIB/deploy.py" --config-json '{"protocol":"trojan","transport":"ws","security":"none","tag":"t","port":19002,"tier":"cdn","password":"p"}' 2>&1 | grep -c 'TROJAN + WebSocket')
assert_eq "$D4" "1" "无加密+WS+CDN: 无需域名即可生成"

# ---------------------------------------------------------------- 预置批量
# ---------------------------------------------------------------- 从零安装
# 菜单 1 (安装/更新) 此前只在"已经装好的机器"上跑过, 真正的从零路径没验证过:
# 新机器上没有内核, 没有 conf/, 没有 systemd 条目, 全靠这段脚本建起来。
# 用 XRAY_INSTALL_DIR 指到临时目录, 不碰真实安装, 也不装 systemd。
group "从零安装 (bin/xray_install.sh)"
INST="$ROOT/bin/xray_install.sh"
bash -n "$INST" 2>/dev/null && ok "安装脚本语法" || bad "安装脚本语法"
grep -q 'XRAY_INSTALL_DIR' "$INST" && ok "支持自定义安装目录 (可在临时目录里测)" \
    || bad "不支持自定义安装目录, 无法在不影响生产的前提下测试"
grep -q '测试模式' "$INST" && ok "临时目录下会跳过 systemd 安装" \
    || bad "临时目录下仍会装 systemd"

X=""
command -v xray >/dev/null 2>&1 && X=$(command -v xray)
[[ -z "$X" && -x /root/catmi/xray/xrayls ]] && X=/root/catmi/xray/xrayls
if [[ -z "$X" ]]; then
    printf '  - 从零安装需要 Xray 内核 (本机没有, 已在实机跑过)\n'
else
    IT="$TMP/inst"; rm -rf "$IT"; mkdir -p "$IT"
    # 把内核先放好, 让脚本跳过下载 —— 测试要能离线重跑, 每次联网拉一遍内核既慢
    # 又会在 GitHub API 限流时变成随机失败
    cp "$X" "$IT/xrayls" 2>/dev/null || true
    OUT=$(XRAY_INSTALL_DIR="$IT" timeout 300 bash "$INST" 2>&1)
    [[ -f "$IT/conf/00-base.json" ]] && ok "从零安装建出了基础配置" \
        || bad "从零安装没建出基础配置"
    if "$IT/xrayls" run -test -confdir "$IT/conf" >/dev/null 2>&1; then
        ok "基础配置通过内核校验 (零节点即可运行)"
    else
        bad "基础配置未通过内核校验"
    fi
    # 幂等: 再装一次不应重复下载, 也不应把已有节点文件清掉
    printf 'keepme' > "$IT/conf/10-user-node.json"
    XRAY_INSTALL_DIR="$IT" timeout 300 bash "$INST" >/dev/null 2>&1
    [[ -f "$IT/conf/10-user-node.json" ]] && ok "重装不删除已有节点文件" \
        || bad "重装把已有节点文件删了"
    NC=$(ls "$IT/conf"/*.json 2>/dev/null | wc -l)
    [[ "$NC" -ge 2 ]] && ok "重装后配置目录没有重复生成" || bad "重装后配置目录只剩 $NC 个文件"
fi
group "预置批量 (preset_batch.sh)"
# ★ 这组测试要的是 **TLS 档** (域名/监听/nginx 档位都是 TLS 才有的语义),
#   原来写死 `vless:2 trojan:3`。预置表一重排编号, vless:2 就从
#   "xhttp+tls" 变成了 "raw+reality", 于是这几条测的已经不是它们想测的东西 ——
#   nginx 档断言 listen=127.0.0.1 而 REALITY 档根本不听本机, 于是假红。
#   按显示名定位, 编号随便怎么排都对。
VL_TLS=$(preset_index_by_name vless  "CDN 友好")
TJ_TLS=$(preset_index_by_name trojan "CDN 友好")
assert_ne0 "$VL_TLS" "vless 有 TLS 档"
assert_ne0 "$TJ_TLS" "trojan 有 TLS 档"
PB="$TMP/pb"; mkdir -p "$PB"
XRAY_CONF_DIR="$PB/conf" XRAY_SHARE_DIR="$PB/share" X_BATCH_DOMAIN=a.example.com \
  bash "$ROOT/tools/preset_batch.sh" "vless:$VL_TLS" "trojan:$TJ_TLS" >/dev/null 2>&1
assert_eq "$(ls "$PB/conf"/*.json 2>/dev/null | wc -l)" "2" "批量落盘 2 个片段"
assert_eq "$(ls "$PB/share"/*.json 2>/dev/null | wc -l)" "2" "批量落盘 2 份元数据"
PD=$(python3 -c "
import json,glob
d=json.load(open(sorted(glob.glob('$PB/conf/*.json'))[0]))
print(d['inbounds'][0]['listen'])")
assert_eq "$PD" "0.0.0.0" "默认 CDN 档位: Xray 听 0.0.0.0"
# 基础域名 + 序号: 每个 TLS 节点一个不同域名
PB2="$TMP/pb2"; mkdir -p "$PB2"
XRAY_CONF_DIR="$PB2/conf" XRAY_SHARE_DIR="$PB2/share" X_BATCH_DOMAIN_BASE=b.example.com \
  bash "$ROOT/tools/preset_batch.sh" "vless:$VL_TLS" "trojan:$TJ_TLS" >/dev/null 2>&1
HOSTS=$(python3 -c "
import json,glob
hs=sorted(json.load(open(f))['host'] for f in glob.glob('$PB2/share/*.json'))
print(','.join(hs))")
assert_eq "$HOSTS" "b.example.com-1,b.example.com-2" "基础域名按序号递增"
# nginx 档位
PB3="$TMP/pb3"; mkdir -p "$PB3"
XRAY_CONF_DIR="$PB3/conf" XRAY_SHARE_DIR="$PB3/share" X_BATCH_DOMAIN=a.com \
  bash "$ROOT/tools/preset_batch.sh" "vless:$VL_TLS:nginx" >/dev/null 2>&1
NG=$(python3 -c "
import json,glob
d=json.load(open(sorted(glob.glob('$PB3/conf/*.json'))[0], encoding='utf-8'))
m=json.load(open(sorted(glob.glob('$PB3/share/*.json'))[0], encoding='utf-8'))
print(d['inbounds'][0]['listen'], m['port'])")
assert_eq "$NG" "127.0.0.1 443" "nginx 档: 听本机, 对外 443"
# TLS 缺域名必须明确报错
PB4="$TMP/pb4"; mkdir -p "$PB4"
E=$(XRAY_CONF_DIR="$PB4/conf" XRAY_SHARE_DIR="$PB4/share" bash "$ROOT/tools/preset_batch.sh" "vless:$VL_TLS" 2>&1 | grep -c '需要域名')
assert_eq "$E" "1" "TLS 缺域名明确报错 (不静默跳过)"
# 非法预置序号
E2=$(XRAY_CONF_DIR="$PB4/conf" XRAY_SHARE_DIR="$PB4/share" bash "$ROOT/tools/preset_batch.sh" vless:99 2>&1 | grep -c '预置序号')
assert_eq "$E2" "1" "非法预置序号明确报错"
bash -n "$ROOT/tools/preset_batch.sh" 2>/dev/null && ok "preset_batch.sh 语法" || bad "preset_batch.sh 语法"

# ---------------------------------------------------------------- 端口归属
group "端口归属 (ports.sh)"
# x_port_holder 的 /proc 回退: 本容器 /proc/net/tcp 是空的 (网络命名空间未暴露),
# 所以用夹具验证解析逻辑本身
mkdir -p "$TMP/pf/net"
printf '  sl  local_address rem_address   st tx rx tr tm->when retrnsmt uid timeout inode\n' > "$TMP/pf/net/tcp"
printf '   0: 0100007F:9807 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 12345 1 0000 100 0 0 10 0\n' >> "$TMP/pf/net/tcp"
# 覆盖路径要在子 shell 内部设置: VAR=x bash -c "..." 不会让 x 进入
# 那个 shell (只对简单命令有效, 对 bash -c 里的 source 无效)。
IN=$(bash -c "_X_PROC_NET='$TMP/pf/net'; source '$LIB/ports.sh'; _x_proc_inodes 38919" 2>/dev/null)
assert_eq "$IN" "12345" "从 /proc/net 提取出 socket inode"
# 端口范围: 0 与越界必须拒绝, 否则会建议 1/2/3 这种要特权且已被占的端口
for bad in 0 70000 -1 abc; do
    S=$(bash -c "source '$LIB/ports.sh'; x_port_suggest '$bad' 3" 2>/dev/null | tr -d '\n')
    assert_eq "$S" "" "非法端口 '$bad' 不给建议"
done
S=$(bash -c "source '$LIB/ports.sh'; x_port_suggest 443 3" 2>/dev/null | wc -l)
assert_eq "$S" "3" "合法端口给出 3 个替代"
H=$(bash -c "source '$LIB/ports.sh'; x_port_holder abc" 2>&1)
[[ "$H" == *"1-65535"* ]] && ok "非法端口的提示说明范围" || bad "非法端口的提示说明范围"
# 五种绑定形式的端口提取
mkdir -p "$TMP/pb"
cat > "$TMP/pb/journalctl" <<'EOF'
#!/bin/sh
echo 'xray: listen tcp 0.0.0.0:8443: bind: address already in use'
echo 'xray: listen tcp [::]:443: bind: address already in use'
echo 'xray: listen tcp 127.0.0.1:2052: bind: address already in use'
echo 'xray: listen tcp :::9443: bind: address already in use'
echo 'xray: listen tcp *:2087: bind: address already in use'
EOF
chmod +x "$TMP/pb/journalctl"
EXT=$(PATH="$TMP/pb:$PATH" bash -c "source '$LIB/service.sh'; x_svc_explain_errors" 2>&1 | grep -c '→.*端口 [0-9]* 被占用')
assert_eq "$EXT" "5" "五种绑定形式的端口都能提取 (v4/v6/无括号/Go 通配)"

# ---------------------------------------------------------------- 服务
group "服务管理 (service.sh)"
RC=$(bash -c "source '$LIB/service.sh'; x_svc_resolve >/dev/null; echo \$X_SVC_RESOLVED" 2>/dev/null)
[[ "$RC" == "1" || "$RC" == "2" ]] && ok "服务名探测返回明确状态 (1=找到 2=没有)" || bad "服务名探测 ($RC)"
T0=$(date +%s%N)
bash -c "source '$LIB/service.sh'; x_svc_resolve >/dev/null; x_svc_status_text >/dev/null; x_svc_installed || true" >/dev/null 2>&1
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
[[ "$MS" -lt 3000 ]] && ok "完整探测耗时 ${MS}ms (<3s, 无 systemd 时不卡死)" || bad "完整探测耗时 ${MS}ms 过长"

# ---------------------------------------------------------------- 幽灵函数
# 从用户入口出发的可达性分析。只看"文件内出现次数"对库不成立 —— 库里的
# 函数互相调用是正常的。真正要问的是从任何入口能不能走到它。
group "幽灵函数 (check_wiring.py)"
WG=$(timeout 60 python3 "$ROOT/tools/check_wiring.py" 2>&1)
WRC=$?
if [[ "$WRC" == "0" ]]; then
    ok "$(echo "$WG" | awk 'NR==1')"
else
    bad "存在不可达的库函数:"
    echo "$WG" | sed 's/^/       /'
fi
# 检查器本身必须能抓到幽灵 —— 用一棵有两个库的测试树: 一个被 entry source,
# 一个完全孤立。如果检查器永远返回 0, 它就是个摆设。
_cw="$TMP/cwtest"; mkdir -p "$_cw/conf/lib" "$_cw/tools"
cp "$ROOT/tools/check_wiring.py" "$_cw/tools/"
{
  printf '#!/bin/bash\n'
  printf 'x_reachable_fn() { echo ok; }\n'
} > "$_cw/conf/lib/uselib.sh"
{
  printf '#!/bin/bash\n'
  printf 'x_ghost_fn() { echo ghost; }\n'
} > "$_cw/conf/lib/orphan.sh"
{
  printf '#!/bin/bash\n'
  printf 'source %s/conf/lib/uselib.sh\n' "$_cw"
  printf 'x_reachable_fn\n'
} > "$_cw/conf/entry.sh"
printf 'bash %s/conf/entry.sh\n' "$_cw" > "$_cw/xray-panel.sh"
CWO=$(cd "$_cw" && timeout 30 python3 tools/check_wiring.py 2>&1)
CWR=$(cd "$_cw" && timeout 30 python3 tools/check_wiring.py >/dev/null 2>&1; echo $?)
assert_eq "$CWR" "1" "检查器能抓到幽灵函数 (不是永远返回 0)"
echo "$CWO" | grep 'x_ghost_fn' >/dev/null && ok "幽灵函数被点名" || bad "幽灵函数被点名"
# 可达函数绝不能出现在幽灵名单里 —— 误报比漏报更烦人, 会逼人去删活代码
if echo "$CWO" | grep '幽灵:' | grep 'x_reachable_fn' >/dev/null; then
    bad "可达函数被误报为幽灵"
else
    ok "可达函数未被误报"
fi

# ---------------------------------------------------------------- Client 兼容
group "Client 兼容性"
if [[ -f "$ROOT/Client/lib/node.py" ]]; then
    mkdir -p "$TMP/cc2"
    cat > "$TMP/cc2/vless-01.json" <<'J'
{"inbounds":[{"tag":"vless-01","port":20001,"protocol":"vless",
  "settings":{"clients":[{"id":"u1"}],"decryption":"none"},
  "streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":"a.com"},"wsSettings":{"path":"/v"}}}]}
J
    python3 - "$LIB" "$TMP/cc2" <<'PY' > "$TMP/sub.txt"
import sys, base64; sys.path.insert(0, sys.argv[1])
import nodes as N
n, _ = N.collect(sys.argv[2])
links = [N.build_share_link(x, {'host':'a.com','port':443,'name':'x-'+x['tag'],'public_key':'PK','short_id':'ab'}) for x in n]
print(base64.b64encode("\n".join(l for l in links if l).encode()).decode())
PY
    P=$(python3 "$ROOT/Client/lib/node.py" subscription "$TMP/sub.txt" 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
    assert_eq "$P" "1" "Client 真实解析器能吃下本项目输出"
else
    printf '  (跳过: Client/ 不存在)\n'
fi

# ---------------------------------------------------------------- 局域网分享 / 预设
# 「功能存在」和「用户点得到」是两件事。这一组盯的是后者：
# 分享本来只有 `xbd share`（命令行）能做，面板上没有入口就等于没有；
# 预设按钮点下去要真的把字段填好，而不是只画几个好看的方块。
group "分享与预设 (面板 · 与用户点得到的入口)"
PANEL_PY="$ROOT/Client/lib/web/panel.py"
# ★ 自带 helper，不借别处的：上一版这里写了个不存在的 assert_has，
#   结果每一行都"command not found"、检查全跳过，而总数还是绿的 ——
#   不会失败的守卫比没有守卫更糟（它让人以为查过了）。
panel_has() { # <文件> <字面串> <说明>
    if grep -qF -- "$2" "$1" 2>/dev/null; then
        ok "$3"
    else
        bad "$3（面板里找不到: $2）"
    fi
}
if [[ -f "$PANEL_PY" ]]; then
    for pair in "分享页在侧栏|data-view=\"share\"" \
                "分享页有服务状态|id=\"sh-state\"" \
                "分享页有链接表|id=\"tb-share\"" \
                "新建分享接线|shareNew(" \
                "停用/启用接线|shareToggle(" \
                "删除接线|shareRemove(" \
                "预览接线|sharePreview(" \
                "面板动作 share_status|\"share_status\"" \
                "面板动作 share_new|\"share_new\"" \
                "面板动作 share_toggle|\"share_toggle\"" \
                "面板动作 share_remove|\"share_remove\"" \
                "面板动作 share_preview|\"share_preview\"" \
                "节点页常驻快速添加|id=\"quick-in\"" \
                "弹窗预置容器|id=\"preset-list\"" \
                "预设数据来自后端|act_add_meta" \
                "面板动作 add_meta|\"add_meta\""; do
        panel_has "$PANEL_PY" "${pair#*|}" "${pair%%|*}"
    done

    # 分享的单元名只许有一处定义：面板里的 U_SHARE 必须与 core.sh 一致，
    # 写错就是"按钮点了、服务没动"，而且报错看起来像服务本身有问题。
    cs_unit=$(grep -m1 '^XBD_U_SHARE=' "$ROOT/Client/lib/core.sh" | cut -d'"' -f2)
    pn_unit=$(grep -m1 '^U_SHARE = ' "$PANEL_PY" | cut -d'"' -f2)
    assert_eq "$pn_unit" "$cs_unit" "面板与 core.sh 用的是同一个分享单元名"

    # 预设必须是**合法组合**：拿 compat.check_xray 逐个验，
    # 和导入一条真实节点走的是同一套判定。写错一个组合，这里会红。
    PREOUT=$(python3 "$ROOT/Client/tools/check-presets.py" 2>/dev/null)
    assert_eq "$PREOUT" "OK" "面板预设全部是内核认的合法组合"

    # 生成→解析往返：解析器认识的字段，build_link 必须写回去。
    # 这条以前是漏的（fp/encryption/ech 只解析不生成，表单填了等于没填）。
    RT=$(python3 "$ROOT/Client/lib/node.py" selftest 2>&1 | grep -c "往返不丢字段")
    assert_eq "$RT" "1" "build_link 往返不丢字段（fp/encryption/ech/alpn）"
else
    printf '  (跳过: Client/lib/web/panel.py 不存在)\n'
fi

# 镜像顺序：实时回源的必须在 CDN 前面。
# 理由不是"谁快"，而是 raw.githubusercontent.com 有 max-age=300 —— 刚发布时
# 它会把**上一版的包和上一版的 .sha256 一起**给你，两个文件自洽、校验通过，
# 于是"更新成功但版本没变"。实测踩到过（2.5.0 → 2.5.1 更新完还是 2.5.0）。
group "镜像顺序 (实时源优先于 CDN)"
# shellcheck disable=SC2066  # 故意的: 这个 for 现在只跑一个文件 (以后可能加),
#   引号是为了路径里有空格也不散 —— 不是为了分词。
for f in "$ROOT/Client/l.sh"; do
    [[ -f "$f" ]] || continue
    first=$(sed -n '/^MIRROR_DIRS=(/,/^)/p' "$f" | grep -oE '"[^"]+"' | awk 'NR==1')
    assert_has_mirror() { # <说明> <期望子串>
        if printf '%s' "$first" | grep "$2" >/dev/null; then ok "$1"; else bad "$1（首个镜像: $first）"; fi
    }
    assert_has_mirror "第一个镜像走实时回源的代理" "ghproxy"
    # 只数"裸的" raw 入口（代理形式里也含 raw.githubusercontent.com，
    # 第一版按子串数，数出 3 个，差点把自己写成假失败）
    both=$(sed -n '/^MIRROR_DIRS=(/,/^)/p' "$f" | grep -cE '^\s*"https://raw\.githubusercontent\.com/\$REPO')
    assert_eq "$both" "1" "原始 CDN 仍在链里（只是不再排第一）"
    if grep -q 'XBD_ARCHIVE=' "$f"; then ok "支持 XBD_ARCHIVE 指定实时源"; else bad "支持 XBD_ARCHIVE 指定实时源"; fi
    if grep -q '发布包版本' "$f"; then ok "安装时打印包内版本（更新成功但没变版本看得出来）"; else bad "安装时打印包内版本"; fi
    # --ref 分支必须用**同一套**顺序，否则换分支时又踩回旧的坑
    n=$(sed -n '/--ref)/,/shift 2/p' "$f" | grep -c 'ghproxy')
    assert_eq "$n" "1" "--ref 分支用同一套镜像顺序"
done

# ---------------------------------------------------------------- 入口与文档
# "能装"和"用户知道怎么装"是两件事。用户的原话：
#   "SB 和 M 都是用一个脚本进服务端或客户端，我们项目在 GitHub 上写着只有一个能进服务端"
#   "客户端这边，它的链接还是指向我的老项目"
# 两条都是文档/入口层面的，但后果是用户拿到的是**另一个仓库的安装包**。
group "入口与文档一致性"
OLD_REPO="mi1314cat/xary-core"

# 1) 指向老仓库的链接：只查"会被执行/被下载"的地方。
#    docs/audit/ 是当时的审计记录，写的就是那个仓库，属于历史证据，不能改。
stale=""
for f in README.md install.sh xray-panel.sh Client/README.md Client/RUN.md Client/l.sh \
         Client/uninstall-xray-client.sh; do
    [[ -f "$ROOT/$f" ]] || continue
    if grep -q "$OLD_REPO" "$ROOT/$f" 2>/dev/null; then
        stale="$stale $f"
    fi
done
# conf/*.sh 会 curl 仓库里的东西，也一并查
for f in "$ROOT"/conf/*.sh; do
    [[ -f "$f" ]] || continue
    grep -q "$OLD_REPO" "$f" 2>/dev/null && stale="$stale conf/$(basename "$f")"
done
if [[ -z "$stale" ]]; then
    ok "安装/下发路径里没有指向老仓库 ($OLD_REPO) 的链接"
else
    bad "还有指向老仓库的链接:$stale"
fi

# 2) 客户端文档的链接必须指向**本**仓库（换个名字就失效的那种错误）
if [[ -f "$ROOT/Client/README.md" ]]; then
    # ★ 不能 `$(grep -c … || echo 0)`: 没命中时 grep -c 也会打印 0 并返回非 0,
    #   `|| echo 0` 再补一个 → 变量成了 "0\n0", 后面的算术比较直接报
    #   syntax error in expression。拿输出, 只用退出码兜底。
    n=$(grep -c 'mi1314cat/xray--core' "$ROOT/Client/README.md" 2>/dev/null) || n=0
    [[ "$n" -ge 3 ]] && ok "Client/README.md 的安装链接指向本仓库 ($n 处)" \
                     || bad "Client/README.md 指本仓库的链接只有 $n 处"
fi

# 3) README 必须写明"一个入口、两种角色"——SB/M 都是这个形态，
#    只写服务端会让人以为没有客户端。
if [[ -f "$ROOT/README.md" ]]; then
    for pair in "README 里有一键入口|install.sh" \
                "README 里写了服务端|服务端" \
                "README 里写了客户端|客户端" \
                "README 里有 server 参数|install.sh) server" \
                "README 里有 client 参数|install.sh) client"; do
        pat="${pair#*|}"
        if grep -qF -- "$pat" "$ROOT/README.md"; then ok "${pair%%|*}"; else bad "${pair%%|*}（README 里找不到: $pat）"; fi
    done
fi

# 4) 引导脚本确实有两种角色（不是 README 吹的）
if [[ -f "$ROOT/install.sh" ]]; then
    install_has() { grep -q -- "$2" "$ROOT/install.sh" && ok "$1" || bad "$1"; }
    install_has "install.sh 有服务端分支" "server)"
    install_has "install.sh 有客户端分支" "client)"
    install_has "install.sh 有菜单（不传参数时选角色）" "main_menu"
    install_has "install.sh 客户端分支会取 Client/l.sh" "Client/l.sh"
    install_has "install.sh 服务端分支会取 xray-panel.sh" "xray-panel.sh"
    install_has "install.sh 支持 --status（只看不改）" "--status"
fi

# ---------------------------------------------------------------- 节点命名
# 用户的要求（对照 sing-box-core 的 sb_server_name / sb_flag_emoji）：
#   "旗帜是必须要有的，然后在节点名称前面，我可以自定义一个名称"
# 也就是 <旗帜> <服务器前缀>-<节点名>。这一组盯住三件事：
#   1. 旗帜真的拼得出来（ISO → emoji），且查不到时不会把名字变成空的
#   2. 前缀可自定义、不同前缀产生不同名字（多服务器防覆盖）
#   3. 分享链接的 fragment 真的带上了它 —— 前面两点再对，
#      没接到生成路径上也是白搭
group "节点显示名 (旗帜 + 服务器前缀)"
if [[ -f "$ROOT/conf/lib/naming.py" ]]; then
    NAMING_PY="$ROOT/conf/lib/naming.py"
    assert_eq "$(python3 "$NAMING_PY" --check >/dev/null 2>&1; echo $?)" "0" "naming.py 自检通过"

    ISO_OUT=$(python3 - "$NAMING_PY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("nm", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.iso_to_flag("US"), m.iso_to_flag("HK"), m.iso_to_flag("ZZZ"))
PY
)
    assert_eq "$ISO_OUT" "🇺🇸 🇭🇰 " "ISO → 旗帜（非法值给空串，不瞎猜）"

    # 显示名组合：默认前缀 / 自定义前缀 / 老形态 tag / 用户自带旗帜
    NAME_OUT=$(python3 - "$NAMING_PY" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("nm", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tmp = "/tmp/xbd-name-check"; os.system("rm -rf " + tmp); os.makedirs(tmp, exist_ok=True)
m.FLAG_CACHE = os.path.join(tmp, "flag"); m.NAME_CACHE = os.path.join(tmp, "server-name")
m._write(m.FLAG_CACHE, "🇺🇸")
out = [m.display_name("x-vless01-TLS"), m.display_name("REALITY-01"),
       m.display_name("🇯🇵 我自己起的"), m.display_name("")]
m._write(m.NAME_CACHE, "HK1")
out.append(m.display_name("x-vless01-TLS"))
os.system("rm -rf " + tmp)
print(" | ".join(out))
PY
)
    assert_eq "$NAME_OUT" \
      "🇺🇸 X-vless01-TLS | 🇺🇸 X-REALITY-01 | 🇯🇵 我自己起的 | 🇺🇸 X-node | 🇺🇸 HK1-vless01-TLS" \
      "显示名 = 旗帜 + 前缀 + 节点名（含自带旗帜与空名两种边界）"

    # bash 侧包装必须能拿到同一份实现
    BASH_NAME=$(bash -c "source '$ROOT/conf/lib/naming.sh'; XRAY_BASE=/tmp/xbd-name-check2 XRAY_SERVER_NAME=HK9 x_server_id; echo; XRAY_SERVER_NAME=HK9 x_display_name x-vless01-TLS" 2>/dev/null)
    [[ "$BASH_NAME" == *"HK9-vless01-TLS" ]] && ok "naming.sh 包装与实际实现一致" \
        || bad "naming.sh 包装与实际实现一致 (得到 $BASH_NAME)"

    # ---- 端到端：分享链接的 fragment 必须带上旗帜与前缀 ----
    # 这是"做对了但没接上"的典型位置：naming.py 全绿, 生成出来还是老样子。
    FRAG=$(python3 - "$ROOT" <<'PY'
import os, sys, tempfile, json, base64
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "conf", "lib"))
tmp = tempfile.mkdtemp(prefix="xbd-frag-")
conf = os.path.join(tmp, "conf"); share = os.path.join(tmp, "share")
os.makedirs(conf, exist_ok=True); os.makedirs(share, exist_ok=True)
json.dump({"inbounds": [{"tag": "x-vless01-TLS", "port": 8443, "protocol": "vless",
    "settings": {"clients": [{"id": "u-1"}], "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "tls",
                       "tlsSettings": {"serverName": "a.example"}}}]},
    open(os.path.join(conf, "vless-01.json"), "w"))
json.dump({"host": "a.example", "port": 8443, "name": "x-vless01-TLS"},
          open(os.path.join(share, "x-vless01-TLS.json"), "w"))
os.environ["XRAY_CONF_DIR"] = conf
os.environ["XRAY_SHARE_DIR"] = share
os.environ["XRAY_BASE"] = tmp
# 旗帜缓存写死, 不联网 —— 门禁必须离线可跑
os.makedirs(os.path.join(tmp, "share-state"), exist_ok=True)
open(os.path.join(tmp, "share-state", "flag"), "w").write("🇺🇸")
import importlib.util
spec = importlib.util.spec_from_file_location("sp", os.path.join(root, "conf", "lib", "share_payload.py"))
sp = importlib.util.module_from_spec(spec); spec.loader.exec_module(sp)
payload, missing, nometa, bad = sp.build_payload(["x-vless01-TLS"])
line = base64.b64decode(payload).decode() if payload else ""
import urllib.parse
print(urllib.parse.unquote(line.rsplit("#", 1)[1]) if "#" in line else "")
PY
)
    assert_eq "$FRAG" "🇺🇸 X-vless01-TLS" "分享链接 fragment 带上了旗帜与默认前缀 (X)"

    # 前缀改了，fragment 跟着变（否则"自定义"是假的）
    FRAG2=$(XRAY_SERVER_NAME=HK1 python3 - "$ROOT" <<'PY'
import os, sys, tempfile, json, base64, urllib.parse
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "conf", "lib"))
tmp = tempfile.mkdtemp(prefix="xbd-frag2-")
conf = os.path.join(tmp, "conf"); share = os.path.join(tmp, "share")
os.makedirs(conf, exist_ok=True); os.makedirs(share, exist_ok=True)
json.dump({"inbounds": [{"tag": "x-vless01-TLS", "port": 8443, "protocol": "vless",
    "settings": {"clients": [{"id": "u-1"}], "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "tls",
                       "tlsSettings": {"serverName": "a.example"}}}]},
    open(os.path.join(conf, "vless-01.json"), "w"))
json.dump({"host": "a.example", "port": 8443, "name": "x-vless01-TLS"},
          open(os.path.join(share, "x-vless01-TLS.json"), "w"))
os.environ["XRAY_CONF_DIR"] = conf; os.environ["XRAY_SHARE_DIR"] = share
os.environ["XRAY_BASE"] = tmp
os.makedirs(os.path.join(tmp, "share-state"), exist_ok=True)
open(os.path.join(tmp, "share-state", "flag"), "w").write("🇺🇸")
import importlib.util
spec = importlib.util.spec_from_file_location("sp2", os.path.join(root, "conf", "lib", "share_payload.py"))
sp = importlib.util.module_from_spec(spec); spec.loader.exec_module(sp)
payload, *_ = sp.build_payload(["x-vless01-TLS"])
line = base64.b64decode(payload).decode() if payload else ""
print(urllib.parse.unquote(line.rsplit("#", 1)[1]) if "#" in line else "")
PY
)
    assert_eq "$FRAG2" "🇺🇸 HK1-vless01-TLS" "前缀可自定义（XRAY_SERVER_NAME）并体现在 fragment 里"

    # 关掉旗帜也要有名字（离线机器不该连名字都没了）
    FRAG3=$(XRAY_SKIP_FLAG=1 python3 - "$ROOT" <<'PY'
import os, sys, tempfile, json, base64, urllib.parse
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "conf", "lib"))
tmp = tempfile.mkdtemp(prefix="xbd-frag3-")
conf = os.path.join(tmp, "conf"); share = os.path.join(tmp, "share")
os.makedirs(conf, exist_ok=True); os.makedirs(share, exist_ok=True)
json.dump({"inbounds": [{"tag": "x-vless01-TLS", "port": 8443, "protocol": "vless",
    "settings": {"clients": [{"id": "u-1"}], "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "tls",
                       "tlsSettings": {"serverName": "a.example"}}}]},
    open(os.path.join(conf, "vless-01.json"), "w"))
json.dump({"host": "a.example", "port": 8443, "name": "x-vless01-TLS"},
          open(os.path.join(share, "x-vless01-TLS.json"), "w"))
os.environ["XRAY_CONF_DIR"] = conf; os.environ["XRAY_SHARE_DIR"] = share
os.environ["XRAY_BASE"] = tmp
import importlib.util
spec = importlib.util.spec_from_file_location("sp3", os.path.join(root, "conf", "lib", "share_payload.py"))
sp = importlib.util.module_from_spec(spec); spec.loader.exec_module(sp)
payload, *_ = sp.build_payload(["x-vless01-TLS"])
line = base64.b64decode(payload).decode() if payload else ""
print(urllib.parse.unquote(line.rsplit("#", 1)[1]) if "#" in line else "")
PY
)
    assert_eq "$FRAG3" "X-vless01-TLS" "关掉旗帜时仍带前缀（不是空名字）"
else
    bad "conf/lib/naming.py 不存在"
fi

# ---------------------------------------------------------------- 客户端排版
# 客户端菜单的排版统一到 core.sh 的 ui_* 上。
#
# 为什么值得一条闸门: 原来是每个菜单各写各的 printf + 各带一套颜色转义,
# 于是同一个客户端里分隔线两种、字号三种、颜色漏了非 TTY 判断（管道里全是
# 转义乱码）。改成统一出口之后, 只要有人再手写 printf 就会红。
group "客户端排版 (ui_* 统一出口)"
CL_ACT="$ROOT/Client/lib/actions.sh"
CL_CORE="$ROOT/Client/lib/core.sh"
if [[ -f "$CL_CORE" ]]; then
    for pair in "排版函数齐|ui_rule" \
                "菜单行统一|ui_menu()" \
                "分组标题统一|ui_sec()" \
                "键值对齐（中文按显示宽度）|ui_pad()" \
                "说明行统一|ui_hint()" \
                "无效输入回显|ui_invalid()" \
                "暂停行统一|ui_pause()"; do
        panel_has "$CL_CORE" "${pair#*|}" "${pair%%|*}"
    done
    # 颜色必须受 TTY 判断保护（否则日志里全是 \033[36m）
    if grep -q "if \[ -t 1 \]" "$CL_CORE"; then ok "颜色受 TTY 判断保护"; else bad "颜色受 TTY 判断保护"; fi
fi
if [[ -f "$CL_ACT" ]]; then
    # 硬编码的菜单样式（自己写 printf 带颜色）不许再出现
    # ★ 不能写 `|| echo 0`: grep -c 无匹配时**先打印 0 再返回 1**, 于是
    #   `||` 又补一个 0, 值变成 "0\n0" —— 永远不等于 "0"。
    #   （这个 || echo 的坑本项目踩过好几次, 记在这里省得下次再踩。）
    hard=$(grep -c 'printf .*\\033\[36m' "$CL_ACT" 2>/dev/null || true)
    hard=${hard:-0}
    assert_eq "$hard" "0" "菜单里没有手写的颜色转义（全走 ui_*）"
    # 主菜单必须给出状态块的三项 + 面板地址
    for pair in "主菜单显示服务状态|ui_kv \"服务状态\"" \
                "主菜单显示内核版本|ui_kv \"内核版本\"" \
                "主菜单显示节点数量|ui_kv \"节点数量\"" \
                "主菜单显示当前节点|ui_kv \"当前节点\"" \
                "主菜单显示网页面板|ui_kv \"网页面板\"" \
                "菜单项带说明|列出 / 添加 / 切换 / 测速"; do
        panel_has "$CL_ACT" "${pair#*|}" "${pair%%|*}"
    done
    # 直接敲 xbd 在终端里应当进面板（脚本/管道里仍给用法）
    if grep -q 'if \[ -t 0 \] && \[ -t 1 \]; then cmd_menu' "$CL_ACT"; then
        ok "xbd 无参数在终端里进面板"
    else
        bad "xbd 无参数在终端里进面板"
    fi
fi

# ---------------------------------------------------------------- 客户端新增能力
# 简易出站（把别的内核当上游）+ 浏览器运行时 + 面板自管理。
# 三件都是"功能存在但用户点不到/装不上"的那一类，所以要真的验到路径上。
group "简易出站 / 浏览器运行时"
CL_NODE="$ROOT/Client/lib/node.py"
CL_GEN="$ROOT/Client/lib/genconfig.py"
CL_CMP="$ROOT/Client/lib/compat.py"
if [[ -f "$CL_NODE" ]]; then
    # 1) 三种防护：监听地址、非法端口、类型 —— 都给拦住（M/SB 都是这些坑）
    GUARD=$(python3 - "$ROOT" <<'PY'
import importlib.util, sys, os
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "Client", "lib"))
import node as N
out = []
for args in (("ftp", "h", 1), ("socks", "0.0.0.0", 1), ("socks", "h", 0),
             ("socks", "h", 70000), ("socks", "", 1080)):
    try:
        N.simple_node(*args); out.append("MISS:" + str(args))
    except ValueError:
        pass
n = N.simple_node("socks", "127.0.0.1", 1080)
print("OK" if not out else "BAD " + " ".join(out))
print(n["name"], n["protocol"], n["security"], n["transport"])
PY
)
    assert_eq "$(printf '%s' "$GUARD" | awk 'NR==1')" "OK" "简易出站拦住非法输入（类型/监听地址/端口）"
    assert_eq "$(printf '%s' "$GUARD" | tail -1)" "SOCKS5-127.0.0.1-1080 socks none tcp" \
        "简易出站默认名与字段（对齐 M/SB 的 SOCKS5-地址-端口）"

    # 2) 生成配置里真的是 socks/http 出站，且**不带** streamSettings
    GEN=$(python3 - "$ROOT" <<'PY'
import json, os, subprocess, sys, tempfile
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "Client", "lib"))
import node as N
out = []
for proto, port, u, p in (("socks", 1080, "", ""), ("http", 7890, "u", "p")):
    n = N.simple_node(proto, "127.0.0.1", port, u, p)
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(n, f); f.close()
    o = tempfile.mktemp(suffix=".json")
    r = subprocess.run(["python3", os.path.join(root, "Client", "lib", "genconfig.py"),
                        "--node", f.name, "--output", o, "--mode", "normal",
                        "--listen", "127.0.0.1", "--port-normal", "1080", "--dns",
                        "standard", "--family", "auto", "--logs", "/tmp"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        out.append(proto + ":FAIL"); continue
    ob = [x for x in json.load(open(o))["outbounds"] if x.get("tag") == "proxy"][0]
    ok = (ob["protocol"] == proto and "servers" in ob["settings"]
          and "streamSettings" not in ob)
    out.append(proto + (":OK" if ok else ":BAD"))
    os.unlink(o); os.unlink(f.name)
print(" ".join(out))
PY
)
    assert_eq "$GEN" "socks:OK http:OK" "简易出站生成的是 socks/http 出站（无 streamSettings）"

    # 3) 能力判定：认它可用，且浏览器拨号的说明是"不适用"而不是通用那句
    CAP=$(python3 - "$ROOT" <<'PY'
import os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "Client", "lib"))
import compat
r = compat.check_all({"protocol": "socks", "address": "127.0.0.1", "port": 1080})
items = {c["item"]: c["verdict"] for c in r["xray"]["checks"]}
dialer = [c["detail"] for c in r["dialer"]["checks"] if c["item"] == "浏览器拨号"]
print(r.get("can_use_xray"), items.get("传输"), items.get("安全"),
      "不适用" if dialer and "不适用" in dialer[0] else "通用原因")
PY
)
    assert_eq "$CAP" "True SUPPORTED SUPPORTED 不适用" "能力判定：简易出站可用、拨号原因专门说明"
fi

if [[ -f "$ROOT/Client/lib/actions.sh" ]]; then
    for pair in "CLI 有 node simple|cmd_node_simple" \
                "分发接线 node simple|simple|local)" \
                "自环检查认本机 LAN IP|就是本客户端自己的入口" \
                "监听地址被拦|是**监听**地址" \
                "浏览器状态命令|xbd_browser_status" \
                "浏览器安装命令|xbd_browser_install" \
                "面板子命令（重启/停）|xbd_panel_service" \
                "落盘路径与导入共用|_xbd_node_save_json"; do
        panel_has "$ROOT/Client/lib/actions.sh" "${pair#*|}" "${pair%%|*}"
    done
    # 面板里也要有入口（点得到才算有）
    panel_has "$ROOT/Client/lib/web/panel.py" 'id="add-simple"' "面板弹窗有简易出站表单"
    panel_has "$ROOT/Client/lib/web/panel.py" '"node_simple"' "面板有 node_simple 动作"
    panel_has "$ROOT/Client/lib/web/panel.py" '"browser_install"' "面板有安装浏览器动作"
    panel_has "$ROOT/Client/lib/web/panel.py" '"panel_restart"' "面板能重启自己"
    panel_has "$ROOT/Client/lib/web/panel.py" 'id="p-url"' "配置页有网页面板卡片"
fi

# ---------------------------------------------------------------- 管道早退
# 两种症状, 同一个根因: 管道末尾用了"早退读取器"（head / grep -q / grep -m）,
# 它拿到想要的东西就退出, 产出方还在写就吃 SIGPIPE（退出码 141）。
#
#   1. 开着 `set -e` 时 —— **随机猝死**。实测 `ver=$(xray version | head -1)`
#      12 次里死 4 次: 菜单只闪一下版本号就回到命令行, 时好时坏没法复现。
#   2. 开着 `pipefail` 时 —— **判断反了**。`if cmd | grep -q X` 明明命中,
#      管道整体却是 141, if 走"没命中"的分支。实测复现（`NOMATCH`）。
#
# 注意触发条件是 pipefail, 不是 -e: 只有 pipefail 才会把 141 变成"整条管道
# 失败"。所以判据按 pipefail 走。
#
# 修法: 换掉早退的读取方, 别动产出方。
#   `| grep -q PAT`  →  `| grep PAT >/dev/null`（不带 -q 会读完输入）
#   `| head -1`      →  先 out=$(cmd), 再切行（见 core.sh 的 first_line / xray_ver）
group "管道早退 (pipefail 下不许让产出方吃 SIGPIPE)"
SIGPIPE_HITS=$(python3 - "$ROOT" <<'PYEOF'
import os, re, sys
root = sys.argv[1]
# 早退读取器: 前面是单个 `|`（不是 `||`, 那是产出方位置）
EARLY = re.compile(r"(?<!\|)\|(?!\|)\s*(?:head\b|grep\s+-[A-Za-z]*[qm]\b)")
FILES = []
for dp, dn, fn in os.walk(root):
    dn[:] = [d for d in dn if d not in (".git", "node_modules", "out",
                                        "xbd-dist", "dist", "archive")]
    for f in fn:
        if f.endswith(".sh") or f == "xbd":
            FILES.append(os.path.join(dp, f))
hits = []
for p in sorted(FILES):
    try:
        lines = open(p, encoding="utf-8").read().splitlines()
    except Exception:
        continue
    head40 = "\n".join(lines[:40])
    if "pipefail" not in head40:
        continue
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        if "|| true" in line:
            continue
        if EARLY.search(line):
            hits.append(f"{os.path.relpath(p, root)}:{i}")
print(" ".join(hits))
PYEOF
)
if [[ -n "$SIGPIPE_HITS" ]]; then
    bad "pipefail 脚本里没有早退管道" "$SIGPIPE_HITS —— 产出方会吃 SIGPIPE(141): 有 set -e 就随机猝死, 没有就判断反; grep 去掉 -q 加 >/dev/null 即可"
else
    ok "pipefail 脚本里没有早退管道（不会猝死、不会判断反）"
fi

# ---------------------------------------------------------------- TLS 握手判据
# OpenSSL 3.x 起 s_client **不再打印** "CONNECTION ESTABLISHED"（只有 1.1.1 打）。
# 按它判断的话, 3.x 上握手成功也一律报"握手失败" —— 实测 cloudflare:443 命中 0 次,
# 而同一台机器 "BEGIN CERTIFICATE" / "Verify return code" 都在。
#
# 这类"判据依赖某个版本的输出文案"的坑值得钉住: 代码看起来完全正常,
# 失败时也只打印一句含糊的"握手失败", 没人会怀疑判据本身。
group "TLS 握手判据 (不能只认 1.1.1 的输出文案)"
_tlsbad=$(grep -rn 'CONNECTION ESTABLISHED' "$ROOT/conf" "$ROOT/xray-panel.sh" \
          "$ROOT/tools" 2>/dev/null | grep -v 'BEGIN CERTIFICATE' \
          | grep -v '^\S*:\s*#' | grep -v 'check_libs.sh' || true)
if [[ -n "$_tlsbad" ]]; then
    bad "TLS 判据没有只认 CONNECTION ESTABLISHED" \
        "$(printf '%s' "$_tlsbad" | awk 'NR<=3' | tr '\n' ' ') —— OpenSSL 3.x 不打印它, 会一律报握手失败"
else
    ok "TLS 判据没有只认 CONNECTION ESTABLISHED（3.x 上也能判对）"
fi

# ---------------------------------------------------------------- 面板覆盖面
# 用户的要求: "客户端面板（TUI/CLI）的功能，最好都能接进我们自研的这个 UI"。
#
# 这类"两边功能表"最靠不住的就是人记得对齐 —— 加了命令行忘了面板，用户就会
# 觉得"面板不好用"。这条闸门把**命令行顶层命令**与**面板动作**列出来做差集:
# 命令行有、面板没有的, 必须出现在白名单里（带理由）。
group "面板覆盖面 (命令行 vs 网页 UI)"
MISS=$(python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
cli = open(os.path.join(root, "Client/lib/actions.sh"), encoding="utf-8").read()
panel = open(os.path.join(root, "Client/lib/web/panel.py"), encoding="utf-8").read()
m = re.search(r"xbd_main\(\) \{(.*?)\n\}", cli, re.S)
cmds = set()
for name in re.findall(r"^\s{4}([a-z][\w|-]*)\)", m.group(1), re.M):
    cmds.update(name.split("|"))
acts = set(re.findall(r'"([a-z_]+)":\s*lambda', panel))
MAP = {"status": "state", "apply": "apply_config", "cert": "cert_fix",
       "export": "export_all", "selftest": "selftest", "browser": "browser_install",
       "panel": "panel_restart", "node": "node_use", "port": "port",
       "ports": "ports_check", "share": "share_status", "xray": "xray_version",
       "dialer": "mode", "proxy": "takeover"}
# status 走的是 GET /api/state（面板每次轮询就调它），不是 action
if "api/state" in panel:
    acts.add("state")
ALLOW = {"install", "uninstall", "menu", "update", "start", "stop", "restart",
         "family", "multi", "diagnose", "ech"}
miss = [c for c in sorted(cmds)
        if c not in ALLOW and c not in acts and MAP.get(c) not in acts]
print(" ".join(miss))
PY
)
if [[ -z "$MISS" ]]; then
    ok "命令行能做的事，面板上都有入口"
else
    bad "面板缺这些命令的入口: $MISS（要么补上，要么加进白名单并写理由）"
fi

# 四个"维护动作"必须真的在界面上有按钮（不是只有后端动作）
for pair in "应用配置按钮|applyConfig" \
            "批量补指纹按钮|certFix" \
            "导出按钮|doExport" \
            "自检按钮|runSelftest" \
            "更新脚本按钮|updateScripts" \
            "简易出站进 TUI 菜单|xbd node simple" \
            "TUI 节点菜单有分组|ui_sec \"添加\""; do
    if [[ "${pair#*|}" == "xbd node simple" || "${pair#*|}" == 'ui_sec "添加"' ]]; then
        panel_has "$ROOT/Client/lib/actions.sh" "${pair#*|}" "${pair%%|*}"
    else
        panel_has "$ROOT/Client/lib/web/panel.py" "${pair#*|}" "${pair%%|*}"
    fi
done

# ---------------------------------------------------------------- 测试导航
# 验证台是靠"往菜单里敲数字"来点的。菜单一重排, 这些数字就指向别的项:
# 客户端那边实测过 —— 节点子菜单重排后, 测试里的 8) 从「浏览器拨号」
# 变成了「删除节点」, 只读模式救了一命, 全量跑就真删了。
#
# 所以: 不许出现**多级**硬编码导航（'1\n8\n...' 这种写死两层编号的）。
# 单级的 '0\n'（退出）、'99\n0\n'（非法输入）这类不涉及"点哪一项",
# 不受排版影响, 放行。
group "测试导航不硬编码菜单编号"
# 真正的"硬编码"长这样: printf '1\n8\n0\n0\n' —— 第一层写死 1, 第二层写死 8。
# 第二层的 0 不算: 0 在所有菜单里都是"返回/退出"（进哪一层都一样）, 不受
# 排版影响。`99\n0\n`（非法输入后退出）同理放行。
# 变量版（"$M_SVC\n0\n0\n"、printf "1\n%s\n..."）也放行 —— 那正是我们要的写法。
_hard=$(python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for rel in ("Client/tools/interactive-test.sh", "tools/server-interactive-test.sh"):
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        continue
    for i, line in enumerate(open(p, encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):
            continue          # 注释里引用旧 bug 的写法不算
        for lit in re.findall(r"'([^']*)'|\"([^\"]*)\"", line):
            s = lit[0] or lit[1]
            if "\\n" not in s:
                continue
            parts = s.split("\\n")
            # 找"第一层是数字、紧接着第二层也是数字且非 0"的写法
            for a, b in zip(parts, parts[1:]):
                if a.isdigit() and b.isdigit() and b != "0":
                    bad.append(f"{rel}:{i}: '{s}'")
print(" ".join(bad))
PY
)
if [[ -n "$_hard" ]]; then
    bad "验证台没有写死的多级菜单导航" "写死: $_hard —— 菜单一重排就会点到别的项（客户端实测: 8) 从「浏览器拨号」变成「删除节点」）"
else
     ok "验证台没有写死的多级菜单导航（编号都从菜单文本现查）"
fi
for f in "$ROOT/Client/tools/interactive-test.sh" "$ROOT/tools/server-interactive-test.sh"; do
    [[ -f "$f" ]] || continue
    # 反向: 必须能从菜单文本里现查编号, 否则上面的检查无从落地
    for helper in menu_idx menu_block; do
        if grep -q "^$helper() {" "$f" 2>/dev/null; then
             ok "$(basename "$f") 有 $helper（编号现查）"
        else
            bad "$(basename "$f") 有 $helper（编号现查）" "缺了它就只能回去写死编号"
        fi
    done
    # menu_block 必须真的被用来截块。主菜单和子菜单有同名项
    # （客户端主菜单也有「浏览器拨号」；服务端主菜单把子菜单三项的名字写进了
    # 说明列），不对着截出来的块查就会命中主菜单的编号, 敲进去等于没进子菜单。
    if grep -qE 'menu_block [^>]*>"\$[A-Z_]+"' "$f" 2>/dev/null; then
         ok "$(basename "$f") 子菜单编号在截出的块里查（不会被主菜单同名项带偏）"
    else
        bad "$(basename "$f") 子菜单编号在截出的块里查" "只见 menu_block 定义, 没见拿它截块给 menu_idx 用"
    fi
done

# ================================================================ 本轮 4 个真 bug
# 见 research/known-issues/x-kernel-fixes-round1.md（proxy-node-compat 仓库）。
# 每条都先复现过、再修、再在这里锁住 —— 门禁只锁"修好的性质", 不复刻实现。

# ---------------------------------------------------------------- P0-1 mux 策略
#
# 改动前：genconfig **无条件**给每个出站写 `mux:{enabled:true,concurrency:8}`，
# 唯一开关是 `--no-mux`（默认 False=开）。后果：节点 JSON 里的 `mux:false` 被
# 吞掉；XHTTP 节点也被开上 mux.cool（官方明确不建议），实测 CC 回环
# mux 关 204 / mux 开 000。
#
# 现在三层：① --mux/--no-mux ② 节点 mux 字段 ③ 默认关；XHTTP/QUIC 一律拒绝。
group "mux 策略 (P0-1: 默认关 / 节点字段生效 / XHTTP 拒开)"
MX="$TMP/mux"; mkdir -p "$MX"
mux_node() { # <文件> <transport> <mux 值>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
json.dump({"protocol": "vless", "address": "a.example", "port": 443,
           "uuid": "11111111-2222-3333-4444-555555555555", "transport": sys.argv[2],
           "security": "tls", "sni": "a.example", "path": "/x",
           "mux": sys.argv[3] == "true"}, open(sys.argv[1], "w"))
PY
}
mux_gen() { # <节点文件> <输出> [额外参数...] -> 打印 mux 字段 (null 表示没写)
  local nf="$1" out="$2"; shift 2
  python3 "$ROOT/Client/lib/genconfig.py" --node "$nf" --output "$out" --mode normal \
      --listen 127.0.0.1 --port-normal 1080 --logs "$MX" "$@" > "$MX/log-$(basename "$out").txt" 2>&1
  python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print("GEN_FAIL"); raise SystemExit
print(json.dumps(next(o for o in d["outbounds"] if o.get("tag")=="proxy").get("mux")))
' "$out" 2>/dev/null || echo "GEN_FAIL"
}
MUXT="$MX/t"; mkdir -p "$MUXT"
mux_node "$MUXT/xhttp-nomux.json" xhttp false
mux_node "$MUXT/xhttp-mux.json"   xhttp true
mux_node "$MUXT/tcp-nomux.json"   tcp   false
mux_node "$MUXT/tcp-mux.json"     tcp   true

assert_eq "$(mux_gen "$MUXT/tcp-nomux.json" "$MUXT/o1.json")" "null" \
    "节点 mux:false + 不给 --mux → 不写 mux（默认关，节点意图生效）"
assert_eq "$(mux_gen "$MUXT/xhttp-nomux.json" "$MUXT/o2.json")" "null" \
    "XHTTP 节点默认不写 mux"
assert_eq "$(mux_gen "$MUXT/tcp-mux.json" "$MUXT/o3.json")" '{"enabled": true, "concurrency": 8}' \
    "节点 mux:true（非 XHTTP）→ 真的开（不能一刀切砍功能）"
assert_eq "$(mux_gen "$MUXT/xhttp-mux.json" "$MUXT/o4.json")" "null" \
    "XHTTP + 节点 mux:true → 拒开（官方明确不建议同开）"
grep -q 'mux' "$MX/log-o4.json.txt" && ok "拒开时在 stderr 说明原因" \
    || bad "拒开时没吭声（用户会以为'我明明开了'）"
assert_eq "$(mux_gen "$MUXT/tcp-nomux.json" "$MUXT/o5.json" --mux)" '{"enabled": true, "concurrency": 8}' \
    "--mux 显式开（覆盖节点的 mux:false）"
assert_eq "$(mux_gen "$MUXT/tcp-mux.json" "$MUXT/o6.json" --no-mux)" "null" \
    "--no-mux 显式关（覆盖节点的 mux:true）"
# 开的时候必须说风险（用户要求：要能开，但要在 stderr 说明风险）
grep -q 'concurrency=8' "$MX/log-o3.json.txt" && ok "开 mux 时 stderr 给出风险提示" \
    || bad "开 mux 时没有风险提示"

# 节点生成侧：mihomo 的 smux 是另一套协议，不能冒充 mux.cool
python3 - "$ROOT" <<'PY' > "$MX/smux.txt"
import importlib.util, json, os, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("nd", os.path.join(root, "Client/lib/node.py"))
nd = importlib.util.module_from_spec(spec); spec.loader.exec_module(nd)
off = nd.parse_mihomo_yaml(json.dumps({"proxies": [{"name": "n", "type": "vless", "server": "a.example",
    "port": 443, "uuid": "u", "network": "xhttp", "tls": True,
    "smux": {"enabled": False, "protocol": "smux"}}]}))
on = nd.parse_mihomo_yaml(json.dumps({"proxies": [{"name": "n", "type": "vless", "server": "a.example",
    "port": 443, "uuid": "u", "network": "xhttp", "tls": True,
    "smux": {"enabled": True, "protocol": "smux"}}]}))
print("smux_off_mux=%s smux_off_smux=%s" % (off["mux"], off["smux"]))
print("smux_on_mux=%s smux_on_smux=%s" % (on["mux"], on["smux"]))
PY
grep -q 'smux_off_mux=False smux_off_smux=False' "$MX/smux.txt" \
    && ok "mihomo smux:{enabled:false} 不再被读成'要开 mux'（字典恒真的老坑）" \
    || bad "smux:{enabled:false} 被读成了要开 mux"
grep -q 'smux_on_mux=False smux_on_smux=True' "$MX/smux.txt" \
    && ok "mihomo smux:{enabled:true} 记进 smux 字段，不冒充 mux.cool" \
    || bad "smux 仍被当成 mux.cool（另一个协议的字段）"

# ---------------------------------------------------------------- P0-2 gen_psk + batch 退出码
group "SS2022 PSK 与 batch 退出码 (P0-2)"
grep -q '^gen_psk()' "$ROOT/conf/lib/random.sh" && ok "gen_psk 在 conf/lib/random.sh 里（被误删过一次）" \
    || bad "gen_psk 又不见了 —— batch 会再次生成不出 SS2022"
grep -q 'lib/random.sh' "$ROOT/conf/Shadowsocks.sh" && ok "Shadowsocks.sh 加载随机值库" \
    || bad "Shadowsocks.sh 没有加载 random.sh"
# 注意：**不能**写成 `echo "$PSKO" | grep -q ...` —— 本文件带 pipefail,
# grep -q 命中即退出会让产出方吃 SIGPIPE(141)（本文件末尾那条门禁就抓这个）。
# 落成文件再按行读, 判断才稳。
PSKO=$(bash -c 'source "$1/conf/lib/random.sh"
for m in 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
  p=$(gen_psk "$m"); printf "%s %s %s\n" "$m" "${#p}" "$(printf "%s" "$p" | openssl base64 -d -A 2>/dev/null | wc -c)"
done' _ "$ROOT")
printf '%s\n' "$PSKO" > "$TMP/psk.txt"
psk_line() { awk -v m="$1" '$1==m {print $2" "$3}' "$TMP/psk.txt"; }
assert_eq "$(psk_line 2022-blake3-aes-128-gcm)" "24 16" "gen_psk(aes-128-gcm) = 24 字符 / 16 字节"
assert_eq "$(psk_line 2022-blake3-aes-256-gcm)" "44 32" "gen_psk(aes-256-gcm) = 44 字符 / 32 字节"
assert_eq "$(psk_line 2022-blake3-chacha20-poly1305)" "44 32" "gen_psk(chacha20) = 44 字符 / 32 字节"

# batch：**任何一个协议失败都要以非零退出码收尾**（原来无条件 return 0，
# SS2022 明明失败了，汇总里印着 [失败]，脚本却还是 exit 0）。
BT="$TMP/batch"; rm -rf "$BT"; mkdir -p "$BT/conf" "$BT/out"
cp "$ROOT/conf/batch.sh" "$BT/batch.sh"
for p in Reality Trojan Shadowsocks hysteria2; do
    printf '#!/bin/bash\necho "stub $p fail" >&2\nexit 3\n' > "$BT/$p.sh"
done
printf '#!/bin/bash\ncase "${1:-}" in check) exit 0;; restart) exit 0;; esac\nexit 0\n' > "$BT/verify.sh"
BOUT=$(XRAY_BASE_DIR="$BT" X_BATCH_LOG_DIR="$BT" bash "$BT/batch.sh" --auto 2>&1); BRC=$?
assert_eq "$BRC" "1" "4 个协议全失败时 batch 退出码非 0（不再掩盖失败）"
printf '%s\n' "$BOUT" > "$BT/out.txt"
grep '失败(详情在日志末尾)' "$BT/out.txt" >/dev/null && ok "失败清单被打印" || bad "失败清单没有打印"
grep '退出码 1' "$BT/out.txt" >/dev/null && ok "批量收尾明确指出退出码非 0" || bad "收尾没有指出退出码"
# 反证：全部成功时必须是 0（不能为了非零把成功也判失败）
for p in Reality Trojan Shadowsocks hysteria2; do
    printf '#!/bin/bash\nexit 0\n' > "$BT/$p.sh"
done
printf '#!/bin/bash\necho "{\\"inbounds\\":[{\\"tag\\":\\"x\\",\\"port\\":1,\\"protocol\\":\\"vless\\"}]}" > "%s/conf/stub.json"\nexit 0\n' "$BT" > "$BT/Reality.sh"
cp "$BT/Reality.sh" "$BT/Trojan.sh"; cp "$BT/Reality.sh" "$BT/Shadowsocks.sh"; cp "$BT/Reality.sh" "$BT/hysteria2.sh"
XRAY_BASE_DIR="$BT" X_BATCH_LOG_DIR="$BT" bash "$BT/batch.sh" --auto >/dev/null 2>&1
assert_eq "$?" "0" "全部成功时 batch 退出码仍是 0"

# ---------------------------------------------------------------- P0-3 分享链接发布
#
# 生产 vless-xhttp-01/02/03 三条死链：入站只绑 127.0.0.1，分享链接却写
# `公网IP:节点端口` —— 那个端口外部没人听。根因是 build_share_link **从来没看过
# listen**。现在：绑回环 + 没有 nginx 档 → 拒绝发布并说明；有 nginx 档 → 按
# 前端端口（默认 443）发布；元数据端口与片段不一致 → 提示（换了端口没重建）。
group "分享链接发布 (P0-3: 回环节点不得按公网 host:port 发布)"
python3 - "$LIB" <<'PY' > "$TMP/link_pub.txt"
import sys
sys.path.insert(0, sys.argv[1])
import nodes as N
def show(tag, n, meta):
    notes = []
    link = N.build_share_link(n, meta, notes=notes)
    tgt = "-"
    if link and "@" in link:
        tgt = link.split("@", 1)[1].split("?", 1)[0].split("#", 1)[0]
    print("%s\t%s\t%s" % (tag, tgt, " | ".join(notes)))
base = {"protocol": "vless", "id": "u", "network": "xhttp", "security": "tls",
        "server_names": [], "sni": "node.example", "path": "/x", "tag": "t"}
show("loopback_nofront", dict(base, listen="127.0.0.1", port=45630),
     {"host": "1.2.3.4", "port": 45630, "name": "n"})
show("loopback_nginx", dict(base, listen="127.0.0.1", port=45630),
     {"host": "node.example", "port": 45630, "name": "n", "tier": "nginx"})
show("public_stale_meta", dict(base, listen="0.0.0.0", port=45630),
     {"host": "1.2.3.4", "port": 25333, "name": "n"})
show("public_ok", dict(base, listen="0.0.0.0", port=45630),
     {"host": "1.2.3.4", "port": 45630, "name": "n"})
PY
LP() { grep -m1 "^$1	" "$TMP/link_pub.txt" | cut -f2; }
LPN() { grep -m1 "^$1	" "$TMP/link_pub.txt" | cut -f3; }
assert_eq "$(LP loopback_nofront)" "-" "只绑回环 + 没有 nginx 档 → 不发布（死链的根因）"
[[ "$(LPN loopback_nofront)" == *"回环"* || "$(LPN loopback_nofront)" == *"127.0.0.1"* ]] \
    && ok "拒发时说明原因（不是静默少一个节点）" || bad "拒发时没说原因: $(LPN loopback_nofront)"
assert_eq "$(LP loopback_nginx)" "node.example:443" "回环 + nginx 档 → 按前端域名:443 发布"
[[ "$(LPN loopback_nginx)" == *"回环端口"* ]] && ok "元数据拿回环端口当对外端口时给出提示" \
    || bad "元数据陈旧却不吭声: $(LPN loopback_nginx)"
assert_eq "$(LP public_ok)" "1.2.3.4:45630" "公网节点按元数据发布（原有行为不变）"
[[ "$(LPN public_stale_meta)" == *"不一致"* ]] && ok "元数据端口与片段端口不一致时提示（换端口没重建）" \
    || bad "端口不一致没有提示"
# 老四元组接口仍然可用（share_service / 旧调用方不能被打断）
python3 - "$LIB" "$TMP" <<'PY' > "$TMP/link_legacy.txt"
import os, sys
sys.path.insert(0, sys.argv[1]); d = sys.argv[2]
os.environ.update(XRAY_CONF_DIR=os.path.join(d, "conf"), XRAY_SHARE_DIR=os.path.join(d, "share"))
import share_payload as P
print("four=%d" % len(P.build_payload(["good1"])))
print("full=%d" % len(P.build_payload(["good1"], full=True)))
PY
grep -q 'four=4' "$TMP/link_legacy.txt" && ok "build_payload 老四元组接口未变（兼容旧调用方）" \
    || bad "老接口被破坏: $(cat "$TMP/link_legacy.txt")"
grep -q 'full=7' "$TMP/link_legacy.txt" && ok "full=True 才多出 refused/notes/inconsistent（新增细分）" \
    || bad "full 接口不对: $(cat "$TMP/link_legacy.txt")"

# ---------------------------------------------------------------- P0-4 旧格式字段
#
# 旧节点文件里 `"ech": true`（bool）被写进 tlsSettings.echConfigList，内核拒收
# **整份**配置；而单节点模式此前不跑 --validate-with → 切到该节点整个实例起不来。
# ech 已单独修（跳过 + 告知）；这里同时锁住"同类路径"：类型不对**明确报错**、
# 数字字符串/数组这些旧写法要能正常走、写出前跑一次内核 -test。
group "旧格式字段与新校验 (P0-4)"
VT="$TMP/valid"; mkdir -p "$VT"
python3 - "$VT" <<'PY'
import json, sys
d = sys.argv[1]
def w(name, **kw):
    n = {"protocol": "vless", "address": "a.example", "port": 443,
         "uuid": "11111111-2222-3333-4444-555555555555", "transport": "xhttp",
         "security": "tls", "sni": "a.example", "path": "/x"}
    n.update(kw); json.dump(n, open("%s/%s.json" % (d, name), "w"))
w("ech_bool", ech=True)
w("ech_str", ech="cloudflare-ech.com+https://dns.alidns.com/dns-query")
w("sni_bool", sni=True)
w("legacy_ok", port="443", alpn=["h2", "http/1.1"])
w("ws_ed_str", transport="websocket", ws_ed="2048")
PY
gen_try() { # <名字> -> 打印 rc
  python3 "$ROOT/Client/lib/genconfig.py" --node "$VT/$1.json" --output "$VT/out-$1.json" \
      --mode normal --listen 127.0.0.1 --port-normal 1080 --logs "$VT" \
      > "$VT/log-$1.txt" 2>&1
  echo $?
}
assert_eq "$(gen_try ech_bool)" "0" "ech:true（旧 bool）不再让生成失败"
grep -q 'ech' "$VT/log-ech_bool.txt" && ok "跳过 ECH 时明确告知（不是静默丢）" || bad "跳过 ECH 没吭声"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
ts=(d["outbounds"][0].get("streamSettings") or {}).get("tlsSettings") or {}
print("no_ech_field=%s" % ("echConfigList" not in ts))' "$VT/out-ech_bool.json" > "$VT/ech_check.txt"
grep -q 'no_ech_field=True' "$VT/ech_check.txt" && ok "bool 没有被写进 echConfigList（内核会拒收整份配置）" \
    || bad "bool 仍被写进 echConfigList"
assert_eq "$(gen_try ech_str)" "0" "ech 是合法字符串时照常生成"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print("ech=%s" % (((d["outbounds"][0]["streamSettings"]).get("tlsSettings") or {}).get("echConfigList")))' \
  "$VT/out-ech_str.json" > "$VT/ech_str_check.txt"
grep -q '^ech=cloudflare-ech.com' "$VT/ech_str_check.txt" && ok "ECHConfigList 原样下发" || bad "ECHConfigList 丢了"
assert_eq "$(gen_try sni_bool)" "2" "sni:true（同类旧格式）→ 明确报错，不照写"
[[ -f "$VT/out-sni_bool.json" ]] && bad "类型不符却还是写了配置（内核会因此起不来）" \
    || ok "类型不符时不落盘（旧配置得以保留）"
grep -q 'sni' "$VT/log-sni_bool.txt" && ok "报错里点名是哪个字段" || bad "报错没说是哪个字段"
assert_eq "$(gen_try legacy_ok)" "0" "旧写法（port 字符串 + alpn 数组）能正常生成"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
ts=d["outbounds"][0]["streamSettings"]["tlsSettings"]
print("alpn=%s port=%s" % (ts.get("alpn"), d["outbounds"][0]["settings"]["vnext"][0]["port"]))' \
  "$VT/out-legacy_ok.json" > "$VT/legacy_check.txt"
grep -q "alpn=\['h2', 'http/1.1'\] port=443" "$VT/legacy_check.txt" \
    && ok "alpn 数组没有被 str() 成 ['h2'] 垃圾值" || bad "alpn 处理不对: $(cat "$VT/legacy_check.txt")"
assert_eq "$(gen_try ws_ed_str)" "0" "ws_ed 是数字字符串时不再 TypeError（旧文件常见）"
grep -q 'ed=2048' "$VT/out-ws_ed_str.json" && ok "ws_ed 数字字符串被正确用上" || bad "ws_ed 没生效"
# 单节点也跑内核校验：坏配置**不覆盖**已有文件（这是'切过去整个实例起不来'的防线）
XK="${XRAY_BIN:-}"
[[ -z "$XK" && -x /root/catmi/xray/xrayls ]] && XK=/root/catmi/xray/xrayls
if [[ -n "$XK" && -x "$XK" ]]; then
    python3 -c '
import json,sys
json.dump({"protocol":"vless","address":"a.example","port":443,
  "uuid":"11111111-2222-3333-4444-555555555555","transport":"tcp","security":"reality",
  "sni":"a.example","reality_public_key":"SHORT","reality_short_id":"aa",
  "fingerprint":"chrome"}, open(sys.argv[1],"w"))' "$VT/bad_reality.json"
    echo "PRESERVE" > "$VT/out-bad_reality.json"
    python3 "$ROOT/Client/lib/genconfig.py" --node "$VT/bad_reality.json" \
        --output "$VT/out-bad_reality.json" --mode normal --listen 127.0.0.1 \
        --port-normal 1080 --logs "$VT" --validate-with "$XK" > "$VT/log-bad.txt" 2>&1
    assert_eq "$?" "2" "单节点模式下内核校验失败 → 生成失败（不再照写）"
    assert_eq "$(cat "$VT/out-bad_reality.json")" "PRESERVE" "失败时**不覆盖**已有配置"
    grep -q '未覆盖' "$VT/log-bad.txt" && ok "明确说明没有覆盖旧配置" || bad "没说清楚有没有覆盖"
else
    ok "（跳过内核校验用例：本机没有 xray 二进制）"
fi


# ---------------------------------------------------------------- 孤儿链已移除
# v2ray 早期的**独立部署套件**曾在仓库根和 conf/ 下各留一份实现:
#
#   入口: VEVLRE.sh / VEVLRE6.sh / Conversion.sh / ngcadall.sh
#   叶子: nginx.sh / caddy.sh / conf/cconf.sh / conf/nconf.sh (只被上面 4 个入口引用)
#
# 它与现行体系 (xray-panel.sh + conf/*.sh + conf/lib/*.py) **不是一条线**:
# 4 个入口自己零外部引用, 叶子只被这几个入口引用, 而且入口跑起来是
# `bash <(curl -Ls .../conf/nconf.sh)` 从 GitHub 现拉 —— 文件一旦离开仓库,
# 这条路就不再自洽。conf/nconf.sh 硬编码 9998/9999/9997, 与现行
# conf/XRevise.sh + 节点体系无关; caddy 那条路也已确认不作为主路径。
#
# 处置: 2026-10-10 整体删除 (决策依据 docs/audit/AUDIT-04.md:78 与
# docs/audit/AUDIT-05-deadcode-matrix.md:88-98 的"孤儿链必须作为决策单元整体
# 处理"; 处置记录 docs/legacy/README.md)。删除前的实现在 git 历史与旧仓库里
# 可查, 需要时去那边取, 不在本仓库复活。
#
# 这组守两件事, 缺一不可:
#   ① 8 个文件真的不在仓库里了 (防 revert / 从旧 tag 拷回);
#   ② 现行脚本里没有**代码**再引用它们 —— 注释里的历史叙述不算,
#      与上面"菜单编号不硬编码"那组同一条判据: 注释不是调用。
group "孤儿链已移除 (防回归)"
ORPHAN_FILES=(
    VEVLRE.sh VEVLRE6.sh Conversion.sh ngcadall.sh
    nginx.sh caddy.sh conf/cconf.sh conf/nconf.sh
)
for _of in "${ORPHAN_FILES[@]}"; do
    if [[ -e "$ROOT/$_of" ]]; then
        bad "已删除: $_of" "文件又回来了 —— 旧实现见 git 历史/旧仓库, 不要在主线复活"
    elif command -v git >/dev/null 2>&1 && [[ -d "$ROOT/.git" ]] \
         && git -C "$ROOT" ls-files --error-unmatch -- "$_of" >/dev/null 2>&1; then
        bad "已删除: $_of" "工作区没有但 git 索引里还在 (git rm --cached 忘了提交?)"
    else
        ok "已删除: $_of"
    fi
done

# 引用扫描: 全仓库 .sh/.py 的**非注释行**, 跳过本文件 (名单就写在这里) 与
# docs/ (审计与历史记录里的提及是证据, 不是调用)。
_orphan_ref=$(python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
names = ["VEVLRE.sh", "VEVLRE6.sh", "Conversion.sh", "ngcadall.sh",
         "nginx.sh", "caddy.sh", "cconf.sh", "nconf.sh"]
pat = re.compile(r"(?<![A-Za-z0-9_.-])(" + "|".join(re.escape(n) for n in names)
                 + r")(?![A-Za-z0-9_-])")
hits = []
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d not in (".git", "docs")]
    for fn in fns:
        if not fn.endswith((".sh", ".py")):
            continue
        rel = os.path.relpath(os.path.join(dp, fn), root)
        if rel == "tools/check_libs.sh":      # 本文件: 名单写在这里, 不算引用
            continue
        try:
            lines = open(os.path.join(dp, fn), encoding="utf-8",
                         errors="replace").read().splitlines()
        except OSError:
            continue
        for i, ln in enumerate(lines, 1):
            if ln.lstrip().startswith("#"):   # 注释: 历史叙述, 不是调用
                continue
            if pat.search(ln):
                hits.append("%s:%d" % (rel, i))
print(" ".join(hits))
PY
)
if [[ -n "$_orphan_ref" ]]; then
    bad "没有现行脚本引用孤儿链" "还有引用(非注释行): $_orphan_ref"
else
    ok "没有现行脚本引用孤儿链 (.sh/.py 非注释行)"
fi

# 门禁脚本自己也会骗人: 之前有两条检查调了根本**不存在**的断言函数
# （assert_has / pass），bash 只往 stderr 丢一句 "command not found",
# 检查项既不通过也不失败 —— 看起来全绿, 其实什么都没验。
#
# 静态扫源码抓不准（本文件里嵌着一堆给别的检查用的 shell/python 片段）,
# 所以改成运行时兜: bash 找不到命令时会走 command_not_found_handle,
# 谁被静默跳过当场就记账。子 shell 里加的 FAIL 会丢, 所以落一份文件,
# 最后按文件判定。
group "订阅解析: 不认的链接不许静默丢（M 的 # 注释方言也要吃）"
# 现场: M 的普通话发 19 条（明文 + 头两行 `#` 注释）, xbd 只说"解析出 15 个" ——
# anytls×3 + tuic×1 被 `except: continue` 静默吃掉; SB 13 条只出 8 条
# （anytls×2 + naive+https + shadowtls + tuic）。注释行是**合法方言**（不算未识别）,
# 但"不认的链接"必须有账。这一组钉住三件事: 注释被正确跳过 / 不认的落盘可查 /
# 调用方（订阅抓取）真的用了这个开关。
SUBF="$TMP/sub-dialects.txt"
cat > "$SUBF" <<'SUBEOF'
# mihomo--core 自动生成的分享链接 (URI 列表, tag=all)
# 共 4 条; 与原生 YAML 产品同一批节点
vless://aaaaaaaa-1111-2222-3333-444444444444@1.2.3.4:443?encryption=none&security=tls&type=ws&sni=a.example&path=/x#n1
anytls://pw@1.2.3.4:8443?sni=c.example#anytls1
tuic://uuuu:pw@1.2.3.4:8443?sni=d.example#tuic1
vless://bbbbbbbb-1111-2222-3333-444444444444@1.2.3.4:443?encryption=none#n2
SUBEOF
SUBREP="$TMP/sub-rep.json"
SUBN=$(python3 "$ROOT/Client/lib/node.py" subscription - --report "$SUBREP" < "$SUBF" 2>/dev/null \
       | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(-1)' 2>/dev/null)
assert_eq "$SUBN" "2" "注释行(#)不产生节点、也不影响解析数（M/SB 的明文方言都吃）"
SUBUN=$(python3 - "$SUBREP" <<'PYU'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("missing"); raise SystemExit
print(",".join(sorted(str(x.get("scheme", "")) for x in d if isinstance(x, dict))))
PYU
)
assert_eq "$SUBUN" "anytls,tuic" \
    "解析器不认的链接逐条落盘（scheme 可查; 注释行不在清单里）—— 修复前这里是 missing"
grep -q -- '--report' "$ROOT/Client/lib/actions.sh" \
    && ok "订阅抓取路径接上了 --report（不认的链接会打给用户，不再只有一个数字）" \
    || bad "订阅抓取没有接 --report —— 清单没人看，等于没修"

group "hysteria2 带宽口径与产物只重建 (60/200 · .hy2-bandwidth · 无损拒绝)"
# 两件事一起钉:
#  ① 带宽口径只有一条 —— 默认 60/200 (用户偏好), 显式设置走
#     ${XRAY_BASE}/.hy2-bandwidth (与 mihomo 侧同名文件同格式)。
#     旧实现两头都不对: 默认 50/200 且两处硬编码, "用户设过"无处可设。
#  ② hy2_share-<NN>.txt 有**只重建**路径 (不新建节点、不碰内核), 而且
#     **无损**: 旧产物里有、新链接里没有的安全参数 (sni/pin/…) 一律拒绝写。
#     实测: RN 上 hysteria-04 的证书文件被续期流程删掉后, 新推导拿不到 sni,
#     而"没有 sni"的 hy2 链接在 CC 上实测 000 (有 sni → 204)。
HY2T="$TMP/hy2t"; rm -rf "$HY2T"; mkdir -p "$HY2T/conf" "$HY2T/out/share"
hy2_fixture() {   # <idx> <auth> <port> [declared-domain]
    local extra=""
    [[ -n "${4:-}" ]] && extra="\"_serverName\": \"$4\","
    cat > "$HY2T/conf/hysteria-$1.json" <<EOF
{${extra}
  "inbounds": [{"listen": "0.0.0.0", "port": $3, "protocol": "hysteria",
    "settings": {"version": 2, "clients": [{"auth": "$2"}]},
    "streamSettings": {"network": "hysteria", "security": "tls",
      "tlsSettings": {"alpn": ["h3"],
        "certificates": [{"certificateFile": "/nonexistent/c$1_cert.pem", "keyFile": "/nonexistent/c$1_key.pem"}]}},
    "tag": "hysteria-$1"}]}
EOF
    echo "{\"host\": \"1.2.3.4\", \"port\": $3, \"name\": \"hysteria-$1\", \"tag\": \"hysteria-$1\"}" \
        > "$HY2T/out/share/hysteria-$1.json"
}
hy2_fixture 02 auth-02 29602 hy2.example   # 域名可从片段声明推出 → 可重建
hy2_fixture 04 auth-04 29604 ""            # 推不出 → 必须拒绝 (旧产物有 sni)
printf 'hysteria2://auth-02@1.2.3.4:29602?obfs=none&sni=hy2.example&insecure=0&alpn=h3&up=50&down=200&upmbps=50&downmbps=200#hysteria-02\n' > "$HY2T/out/hy2_share-02.txt"
printf 'hysteria2://auth-04@1.2.3.4:29604?obfs=none&sni=moontv.6896698.xyz&insecure=0&alpn=h3&up=50&down=200&upmbps=50&downmbps=200#hysteria-04\n' > "$HY2T/out/hy2_share-04.txt"
cp "$HY2T/out/hy2_share-04.txt" "$HY2T/04.orig"
hy2_sync() {   # [--apply]
    XRAY_BASE_DIR="$HY2T" XRAY_BASE="$HY2T" XRAY_CONF_DIR="$HY2T/conf" \
    XRAY_OUT_DIR="$HY2T/out" XRAY_SHARE_DIR="$HY2T/out/share" \
    bash "$ROOT/conf/hysteria2.sh" sync-products "$@" 2>&1
}
assert_eq "$(LIB="$LIB" python3 -c 'import os,sys
sys.path.insert(0, os.environ["LIB"])
import nodes
print(nodes.DEFAULT_HY2_UP, nodes.DEFAULT_HY2_DOWN)' 2>/dev/null)" "60 200" \
    "默认带宽 = 上行 60 / 下行 200（旧实现是 50/200）"
OUT1=$(hy2_sync)
printf '%s\n' "$OUT1" | grep -E 'NODE|SUMMARY' | sed 's/^/      /'
printf '%s' "$OUT1" | grep 'NODE hysteria-02 verdict=ok changed=up:50->60' >/dev/null \
    && ok "无覆盖文件时按默认 60/200 重建（并报出改了哪几个参数）" \
    || bad "默认口径没生效（期望 up:50->60）"
printf '%s' "$OUT1" | grep 'NODE hysteria-04 verdict=refused lost=sni' >/dev/null \
    && ok "无损拒绝: 推不出 sni 的节点拒绝重建（不写一份没 sni 的产物）" \
    || bad "hysteria-04 没有被无损拒绝 —— 会把'客户端必然校验失败'的链接写进产物"
cmp -s "$HY2T/out/hy2_share-04.txt" "$HY2T/04.orig" \
    && ok "被拒绝的节点产物一字未动" || bad "被拒绝的节点产物被改了"
printf '45 170\n' > "$HY2T/.hy2-bandwidth"
OUT2=$(hy2_sync)
printf '%s' "$OUT2" | grep 'NODE hysteria-02 verdict=ok changed=up:50->45,down:200->170' >/dev/null \
    && ok "显式覆盖 .hy2-bandwidth=45 170 生效（up/down/upmbps/downmbps 四个字段一起）" \
    || bad "覆盖文件没生效: $(printf '%s' "$OUT2" | grep NODE | sed -n 1p)"
# ★ 两个消费者一个口径: 覆盖文件在时, 链接(URI) 与 脚本产物(hysteria2.sh sync-products)
#   必须都是 45/170。两者漂移会出现"链接 45/170、产物 60/200"的产物不一致。
#   （原为三个消费者, 第三个是 native.py 的原生文档 —— 原生路径随三家互通回退一并移除。）
CONSIST=$(XRAY_BASE_DIR="$HY2T" XRAY_BASE="$HY2T" python3 - "$ROOT" "$HY2T" <<'PYC'
import os, sys
root, T = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "conf", "lib"))
import nodes, share_meta
ns, _b = nodes.collect(T + "/conf")
by = {n["tag"]: n for n in ns}
n, meta = by["hysteria-02"], (share_meta.load(T + "/out/share", "hysteria-02") or {})
link = nodes.build_share_link(n, meta)
ok = ("up=45&down=170" in link and "upmbps=45&downmbps=170" in link)
print("1" if ok else "0 link=%s" % link[-90:])
PYC
)
assert_eq "$CONSIST" "1" "URI 链接读 .hy2-bandwidth 覆盖（up=45&down=170&upmbps=45&downmbps=170）"
hy2_sync --apply >/dev/null 2>&1
grep -q 'up=45&down=170&upmbps=45&downmbps=170' "$HY2T/out/hy2_share-02.txt" \
    && ok "--apply 真的写盘了（45/170, sni 保留, obfs 已去掉）" \
    || bad "--apply 没写盘或内容不对: $(cat "$HY2T/out/hy2_share-02.txt")"
# 产物与订阅载荷必须**逐字节相同** —— 链接只有 nodes.build_share_link() 一处实现
SAME=$(XRAY_BASE_DIR="$HY2T" XRAY_BASE="$HY2T" python3 - "$ROOT" "$HY2T" <<'PYX'
import os, sys
root, T = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "conf", "lib"))
import nodes, share_meta
ns, _b = nodes.collect(T + "/conf")
by = {n["tag"]: n for n in ns}
link = nodes.build_share_link(by["hysteria-02"],
                             share_meta.load(T + "/out/share", "hysteria-02") or {})
print("1" if link == open(T + "/out/hy2_share-02.txt").read().strip() else "0")
PYX
)
assert_eq "$SAME" "1" "重建出来的产物与订阅载荷逐字节相同（链接只有一处实现）"
rm -f "$HY2T/.hy2-bandwidth"
OUT3=$(hy2_sync)
printf '%s' "$OUT3" | grep 'NODE hysteria-02 verdict=ok changed=up:45->60,down:170->200' >/dev/null \
    && ok "删掉覆盖文件 → 回到默认 60/200（覆盖不是单向的）" \
    || bad "删掉覆盖文件后没有回到默认: $(printf '%s' "$OUT3" | grep NODE | sed -n 1p)"
grep -q 'sync-products' "$ROOT/conf/hysteria2.sh" && ok "非交互的产物重建入口存在" \
    || bad "hysteria2.sh 没有 sync-products 入口（产物无法在不新建节点的前提下重建）"

# ---------------------------------------------------------------- 证书丢失
# 用户报告: "X 内核有时候会将我们那个证书库里面的证书莫名其妙的就少了一些
# 东西, 另外两个内核就从来没有发生过。"
#
# 真因 (RN, 2026-10-12 查实): lib/cert.sh 里的 x_cert_sync() 定义了却**从来没
# 被调用过** —— 全项目零调用点。于是 10-08 设计的保护 (复制一份到项目目录、
# 配置只引用项目目录) 从来没接上线, 片段至今指向 /home/web/certs, 那个目录
# 归 KPanel 管, 续签时先删 lineage 再重新签发, 中途失败磁盘上就只剩私钥。
#
# 所以这里测三件事, 少一件都不够:
#   1. sync 真的会把证书搬进项目目录 (当初就是没接上, 不能只有函数存在);
#   2. 证书没了以后能自己补回来 (而不是等重启炸);
#   3. 补不回来时返回非 0 且点名是哪张证书 —— 静默放过等于没做。
group "证书丢失防护 (2026-10-12 事故回归)"
CERT_T=$(mktemp -d)
CT_PROJ="$CERT_T/project"; CT_LE="$CERT_T/le"; CT_LIN="$CT_LE/ct.test.local"; CT_CONF="$CERT_T/conf"
mkdir -p "$CT_PROJ" "$CT_LIN" "$CT_CONF"
# 目录结构照抄 letsencrypt: <src>/<域名>/{fullchain,privkey}.pem
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CT_LIN/privkey.pem" \
    -out "$CT_LIN/fullchain.pem" -days 30 -subj "/CN=ct.test.local" >/dev/null 2>&1
cat > "$CT_CONF/f.json" <<CTEOF
{"certificateFile":"$CT_PROJ/ct.test.local_cert.pem","keyFile":"$CT_PROJ/ct.test.local_key.pem"}
CTEOF

(
    export X_CERT_DIR="$CT_PROJ"
    # 直接 source 整个文件 —— 用 sed 截取函数段看着省事, 但 x_cert_ensure 依赖
    # x_cert_sync/x_cert_project_dir, 截漏任何依赖都表现为"功能失效",
    # 测出来的是**测试自己造的问题**, 不是产品问题 (这轮已经踩过一次)。
    source "$ROOT/conf/lib/cert.sh" 2>/dev/null || true
    # lib 里的告警走 print_*。**必须真的输出到 stderr** —— 下面要断言
    # "补不回时点名了是哪张证书", 而我把 print_error 写成空函数的话,
    # 断言永远失败, 而失败原因是我自己把话说没了 (第二轮踩的同一个坑:
    # 测试自己造的问题长得像产品问题)。
    print_info() { printf '[Info] %s\n' "$1" >&2; }
    print_warn() { printf '[Warn] %s\n' "$1" >&2; }
    print_error() { printf '[Error] %s\n' "$1" >&2; }
    declare -F x_cert_sync >/dev/null || { echo "NO_SYNC" > "$CERT_T/.r"; exit 0; }

    x_cert_sync "$CT_LE" >/dev/null 2>&1
    [[ -f "$CT_PROJ/ct.test.local_cert.pem" ]] || { echo "NO_POPULATE" > "$CERT_T/.r"; exit 0; }

    rm -f "$CT_PROJ/ct.test.local_cert.pem"
    x_cert_ensure "$CT_CONF/f.json" "$CT_LE" >/dev/null 2>&1
    [[ -f "$CT_PROJ/ct.test.local_cert.pem" ]] || { echo "NO_RECOVER" > "$CERT_T/.r"; exit 0; }

    rm -f "$CT_PROJ/ct.test.local_cert.pem"; rm -rf "$CT_LE"
    x_cert_ensure "$CT_CONF/f.json" "$CT_LE" >"$CERT_T/.out" 2>&1
    [[ $? -eq 0 ]] && { echo "SILENT_OK" > "$CERT_T/.r"; exit 0; }
    grep -q 'ct.test.local_cert.pem' "$CERT_T/.out" || { echo "VAGUE" > "$CERT_T/.r"; exit 0; }
    echo "PASS" > "$CERT_T/.r"
) 2>/dev/null
CERT_R=$(cat "$CERT_T/.r" 2>/dev/null || echo NORUN)
case "$CERT_R" in
    PASS)   ok "证书丢失 → 自动补回; 补不回时报名并返回非 0" ;;
    NO_SYNC)   bad "lib/cert.sh 里没有 x_cert_sync (当初就是它没接上)" ;;
    NO_POPULATE) bad "x_cert_sync 没把证书搬进项目目录" ;;
    NO_RECOVER) bad "证书被删后 x_cert_ensure 没补回来" ;;
    SILENT_OK)  bad "证书彻底没了 x_cert_ensure 仍返回 0 —— 会静默写坏配置" ;;
    VAGUE)      bad "补不回时没有点名是哪张证书 (只该报人话, 不该报内核栈)" ;;
    *)          bad "证书丢失防护回归用例没跑起来" ;;
esac
# 这个事故的直接成因: sync 有定义但没人调用。
CALLS=$(grep -rl 'x_cert_sync\|x_cert_ensure' "$ROOT/conf" "$ROOT/tools" 2>/dev/null \
        | grep -v 'lib/cert\.sh$' | wc -l)
[[ "$CALLS" -ge 2 ]] && ok "sync/ensure 有真实调用点 ($CALLS 个文件), 不是死函数" \
                     || bad "x_cert_sync / x_cert_ensure 仍然没有调用点 (死函数 = 保护没生效)"
grep -q 'x_cert_migrate' "$ROOT/conf/cert.sh" \
    && ok "证书菜单里能迁到项目目录 (新节点以外的存量也能改)" \
    || bad "证书菜单没有迁移入口 —— 存量片段会一直指着会被删的目录"
rm -rf "$CERT_T"

# ---------------------------------------------------------------- 沙箱
# ★ 这条来自一次真实的翻车。
#
#   10-12 我跑 E2E, 设了 XRAY_BASE=/tmp/e2e, 以为在沙箱里, 结果批量生成
#   直接跑到了 /root/catmi/xray/conf 上 —— 因为脚本认的是 XRAY_BASE_DIR,
#   XRAY_BASE 会被那一行原样覆盖掉。而屏幕上一切正常: 没有报错, 生成成功,
#   汇总照打。只因为"节点已存在, 全部跳过"才没写坏东西。
#
#   静默忽略环境变量比报错危险得多 —— 它让你以为自己测的是沙箱。
group "沙箱变量真的生效 (XRAY_BASE 曾被静默丢弃)"
SBX_OUT=$(XRAY_BASE=/tmp/sbx-probe bash -c "
  cd '$ROOT'
  source conf/batch.sh >/dev/null 2>&1
  printf '%s|%s|%s' \"\${XRAY_BASE:-}\" \"\${CONF_DIR:-}\" \"\${X_IS_SANDBOX:-unset}\"" 2>/dev/null)
SBX_BASE=${SBX_OUT%%|*}
[[ "$SBX_BASE" == "/tmp/sbx-probe" ]] && ok "XRAY_BASE 会被采纳 (沙箱名对得上)" \
    || bad "XRAY_BASE 被静默丢弃 → 测试会跑在生产上 (实际: '${SBX_OUT:-空}')"
case "$SBX_OUT" in
    /root/catmi/*) bad "CONF_DIR 仍指向生产目录" ;;
    *) [[ "$SBX_OUT" == *"|true" ]] && ok "沙箱标志 X_IS_SANDBOX=true, CONF_DIR 不指生产" \
                                 || ok "CONF_DIR 不指生产" ;;
esac
rm -rf /tmp/sbx-probe

# ---------------------------------------------------------------- CDN 自动配
# 借鉴 sing-box-core 的 cdn_autosetup / batch_next_port。三个 bug 值得钉住,
# 它们的共同点是**静默失败**: 屏幕上一切正常, 功能从来没发生过。
# ---------------------------------------------------- 上下行分离的三个组合
group "xHTTP 上下行分离 (上行CDN/下行CDN, 上行CDN/下行REALITY, 上行REALITY/下行CDN)"
source "$ROOT/conf/lib/preset.sh"

# ① 三个模式都在, 且字段对得上
if x_split_modes 2>/dev/null | grep -qx cdn-cdn \
   && x_split_modes 2>/dev/null | grep -qx cdn-reality \
   && x_split_modes 2>/dev/null | grep -qx reality-cdn
then ok "三个分离模式都在"
else bad "分离模式表缺项"
fi

check_split() { # <模式> <上行> <下行> <下行挂nginx> <ECH> <监听档位>
    local m="$1" ul="$2" dl="$3" ngnx="$4" ech="$5" tier="$6"
    # 五项拼成一串比。别用 "$ul $(...)" 这种插值写法 —— 变量名后面跟 $( )
    # 时 bash 会把 ${ul_ul_sec} 那类名字也吃掉, 实测 got 变成
    # "tls tls tls tls yes yes yes yes nginx nginx" (每个值出现两次)。
    # 一行行拼。用 printf 一次成型, 避开 bash 的变量名边界坑:
    #   "$m" 后面紧跟 $( 时, bash 会接着找 $m_ul_sec 这种更长的名字,
    #   实测 got 变成 "tls tls tls tls yes yes yes yes nginx nginx"
    #   (每个值出现两次) —— 而报错只说"字段不对", 完全看不出是断言写坏了。
    local got
    printf -v got '%s %s %s %s %s' \
        "$(x_split_ul_sec "$m" 2>/dev/null)" \
        "$(x_split_dl_sec "$m" 2>/dev/null)" \
        "$(x_split_dl_cdn "$m" 2>/dev/null)" \
        "$(x_split_ech "$m" 2>/dev/null)" \
        "$(x_split_tier "$m" 2>/dev/null)"
    local want="$ul $dl $ngnx $ech $tier"
    if [[ "$got" == "$want" ]]; then ok "$m → $ul / $dl"
    else bad "$m 字段不对: 期望 [$want] 实得 [$got]"; fi
}
check_split cdn-cdn     tls      tls      yes yes nginx
check_split cdn-reality tls      reality  no  yes cdn
check_split reality-cdn reality  tls      yes no  cdn

# ② 监听档位: 有任一段直连就必须 0.0.0.0 (cdn), 全经 nginx 才 127.0.0.1 (nginx)
#    判错的后果很隐蔽 —— 档位选 nginx 时 xray 只监听 127.0.0.1, 客户端直连
#    那一段永远连不上, 而内核不报错。
if [[ "$(x_split_tier cdn-reality)" == "cdn" && "$(x_split_tier reality-cdn)" == "cdn" \
   && "$(x_split_tier cdn-cdn)" == "nginx" ]]
then ok "有直连段就监听 0.0.0.0 (cdn), 全经 nginx 才收窄 (nginx)"
else bad "监听档位不对: 直连段必须 cdn(0.0.0.0), 选成 nginx(127.0.0.1) 时直连段连不上"
fi

# ③ 未知模式要报错而不是默默当直连
if x_split_ul_sec nosuchmode >/dev/null 2>&1; then
    bad "未知分离模式没被拒绝 (会照直生成一个普通节点)"
else ok "未知分离模式被拒绝"; fi

# ④ 扫描器用 | 而不是 tab —— tab 是 IFS 空白, `a\t\tb` 里那个空字段
#    会被折叠掉, 后面所有列前移一位。实测踩过: path 跑进"下行域名"列,
#    nginx_apply 于是去找一个叫 "/cdn-cdn-20000" 的 server_name。
if grep -qF "IFS=" "$ROOT/tools/cdn_auto.sh" \
   && grep -qF "join(r) for r in rows)" "$ROOT/tools/cdn_auto.sh" \
   && grep -qF '"|".join(r)' "$ROOT/tools/cdn_auto.sh" \
   && ! grep -qF "IFS=\$'\\t' read" "$ROOT/tools/cdn_auto.sh"
then ok "扫描结果用 | 分隔 (tab 会让空字段消失导致列错位)"
else bad "扫描还用 tab 分隔 → 中间空字段被折叠, path 跑进域名列"
fi

# ⑤ 下行 REALITY 的字段名是 password, 不是 publicKey。
#    服务端扮演客户端去连, 内核要 password; 写 publicKey 时内核报的是
#    `empty "password"` —— 报错里没有半个字提 publicKey, 照着查会绕远路。
if grep -qF '"password": _rpw' "$ROOT/conf/lib/node_build.py"
then ok "下行 REALITY 用 password 字段"
else bad "下行 REALITY 还在用 publicKey → 内核报 empty \"password\""
fi

# ⑥ 下行 REALITY 缺凭据要当场点名缺哪个, 不能让内核报 empty "password"
if grep -qF "下行 REALITY 缺少参数" "$ROOT/conf/lib/node_build.py"
then ok "缺凭据时点名 serverName/password/shortId"
else bad "缺凭据时只有内核那句 empty password, 用户不知道要补什么"
fi

# ⑦ 每个分离节点要有自己的 path —— nginx 一个 server 只有一条 location /,
#    同域名跑两个分离节点 (不同端口) 会互相覆盖, 流量全打到先插的端口,
#    而两个节点都显示"生成成功"。
if grep -qF '"/%s-%s" % (split, port)' "$ROOT/tools/preset_batch.sh"
then ok "分离节点按 模式-端口 生成各自的 path"
else bad "分离节点共用一个 path → 同域名多节点在 nginx 里互相覆盖"
fi

# ⑧ 端到端: 三个模式各自生成, downloadSettings 存在, 下行加密层正确
SPT=$(mktemp -d); mkdir -p "$SPT/conf"
cat > "$SPT/dnsplit.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import node_build as B

out = {}
for mode, ul, dl in (("cdn-cdn", "tls", "tls"),
                     ("cdn-reality", "tls", "reality"),
                     ("reality-cdn", "reality", "tls")):
    o = {"port": 20001, "path": "/" + mode,
         "dl_address": "d.example.com", "dl_security": dl, "dl_mode": "stream-up"}
    if ul == "reality":
        # 上行 REALITY: 入站那侧要私钥/公钥/短id/伪装地址, 缺一个
        # _check_reality 就会先拦下来 —— 连 downloadSettings 都还没生成。
        # (这三个模式里只有 reality-cdn 的上行是 REALITY。)
        o["private_key"] = "a" * 43
        o["public_key"] = "b" * 43
        o["short_id"] = "ab"
        o["dest"] = "www.cloudflare.com:443"
    if dl == "reality":
        # 下行 REALITY 是服务端扮演客户端 —— 三个凭据一个都不能少
        o["dl_sni"] = "s.example.com"
        o["dl_public_key"] = "k" * 43
        o["dl_short_id"] = "0123456789abcdef"
    node = B.build("vless", "xhttp", ul, o)
    d = (node.get("inbounds") or [{}])[0]
    xh = (d.get("streamSettings") or {}).get("xhttpSettings") or {}
    got = xh.get("downloadSettings") or {}
    out[mode] = {"sec": got.get("security"),
                 "mode": (got.get("xhttpSettings") or {}).get("mode"),
                 "path": (got.get("xhttpSettings") or {}).get("path"),
                 "port": got.get("port"), "addr": got.get("address")}
print(json.dumps(out))
PYEOF
SPT_OUT=$(LIB="$ROOT/conf/lib" python3 "$SPT/dnsplit.py" 2>&1)
# ★ 用 grep >/dev/null 而不是 grep -q: 产出方 (printf) 会因为 -q 提前退出而
#   吃 SIGPIPE(141), 套件自己的门禁 (EARLY) 就是盯这个的。写新断言时踩了自己
#   的门禁 —— 门禁本身是对的, 所以是断言该改。
if printf '%s' "$SPT_OUT" | grep 'cdn-cdn' >/dev/null \
   && printf '%s' "$SPT_OUT" | grep '"sec": "reality"' >/dev/null \
   && printf '%s' "$SPT_OUT" | grep '"sec": "tls"' >/dev/null; then
    ok "三个模式的 downloadSettings 生成正确 (含下行 reality)"
else
    bad "downloadSettings 不对: $(printf '%s' "$SPT_OUT" | tr -d '\n' | cut -c1-160)"
fi

# ⑨ mode 必须是 stream-up —— auto 在 REALITY 下退化成 stream-one (合流),
#    用户以为分离了, 实际是一条连接上双工。
if printf '%s' "$SPT_OUT" | grep '"mode": "stream-up"' >/dev/null; then
    ok "下行 mode 显式 stream-up (auto 在 REALITY 下会退化成合流)"
else bad "下行 mode 不是 stream-up"; fi

# ⑩ 上下行端口必须一致 —— 会话表 per-inbound, 不同端口下行直接断
if printf '%s' "$SPT_OUT" | grep '"port": 20001' >/dev/null; then
    ok "下行端口与 inbound 一致 (会话表 per-inbound)"
else bad "下行端口与 inbound 不一致 → 下行会话查不到"; fi
rm -rf "$SPT"

# --------------------------------------------------------- 端口不会被重复领走
# 两种分配路径都要守住, 因为各自防的是不同场景:
#   preset_batch.sh 的 cd_batch_take_port  → 同一批/多次调用的**顺序**分配
#   mknode.sh 的 x_random_free_port         → 向导单建节点的**随机**分配
#
# 判错的后果特别难查: 同协议+同传输+同安全层的两个节点会领到同一个端口、
# 写出**同一个文件名**, 后者覆盖前者 —— 而两边日志都写"成功"。
# --------------------------------------------------------- 证书自愈
# 这台机器上证书会**突然只剩私钥**, 证书文件没了。而 nginx 启动时只要有一个
# ssl_certificate 读不到就 [emerg] 退出 → 容器重启循环 → Cloudflare 回源 521
# → 所有 CDN 节点一起挂。已在 RN 上实测复现 (CC 侧确认 521)。
group "证书自愈 (nginx 起不来 = 全部 CDN 节点挂)"
CG=$(mktemp -d); mkdir -p "$CG/certs" "$CG/conf.d"
# 夹具自己必须先站住: 上一版 openssl 失败没检查, 结果后面拿一个**不存在的**
# 私钥去自签, 报的是 openssl 的错 —— 而套件被那个 stderr 带走, 整轮判失败。
mk_crt() {
    openssl req -x509 -nodes -newkey rsa:2048 -days 3 \
        -keyout "$1" -out "$2" -subj "/CN=t" >/dev/null 2>&1
}
mk_crt "$CG/certs/a.key" "$CG/certs/a.crt"
mk_crt "$CG/certs/default_server.key" "$CG/certs/default_server.crt"
printf 'server {\n listen 443 ssl;\n ssl_certificate /etc/nginx/certs/a.crt;\n ssl_certificate_key /etc/nginx/certs/a.key;\n}\n' > "$CG/conf.d/a.conf"
printf 'server {\n listen 443 ssl;\n ssl_certificate /etc/nginx/certs/default_server.crt;\n ssl_certificate_key /etc/nginx/certs/default_server.key;\n}\n' > "$CG/conf.d/d.conf"
if [[ ! -f "$CG/certs/a.key" || ! -f "$CG/certs/default_server.key" ]]; then
    bad "夹具没生成出来 (openssl 不可用?), 跳过证书自愈测试"
else
    KEY_MD5=$(openssl rsa -noout -modulus -in "$CG/certs/a.key" 2>/dev/null | openssl md5)
    # 复现现场: 证书没了, 私钥还在 —— 与线上观察到的现象一致
    rm -f "$CG/certs/a.crt" "$CG/certs/default_server.crt"
    X_CERT_DIR="$CG/certs" X_NGINX_CONF_DIR="$CG/conf.d" X_NGINX_CTR=nonexistent-ctr \
        bash "$ROOT/tools/cert_guard.sh" >/dev/null 2>&1
    [[ -f "$CG/certs/a.crt" ]] \
        && ok "缺签发记录的证书能自签补上" \
        || bad "有 letsencrypt 也没有的证书补不回来 → nginx 永远起不来"
    [[ -f "$CG/certs/default_server.crt" ]] \
        && ok "兜底站点 (server_name _) 的证书也补上了" \
        || bad "兜底站点证书补不上 → default.conf 一直 [emerg]"
    # ★ 必须用**现有私钥**签: 换私钥等于动了用户的东西, 而且会 key values mismatch
    NEW_MD5=$(openssl x509 -noout -modulus -in "$CG/certs/a.crt" 2>/dev/null | openssl md5)
    [[ -n "$KEY_MD5" && "$KEY_MD5" == "$NEW_MD5" ]] \
        && ok "补出来的证书与**原来的私钥**配套 (没换用户的私钥)" \
        || bad "补出来的证书与现有私钥不配套 → nginx 报 key values mismatch"
    # 干跑不许改东西
    rm -f "$CG/certs/a.crt"
    CG_DRY=$(X_CERT_DIR="$CG/certs" X_NGINX_CONF_DIR="$CG/conf.d" X_NGINX_CTR=nonexistent-ctr \
        bash "$ROOT/tools/cert_guard.sh" --dry-run 2>&1)
    # ★ 不要 `... | grep -q`: grep -q 命中就立刻退出, 另一头收到 SIGPIPE,
    #   而套件开着 `set -o pipefail` —— "匹配成功"会被判成"整条命令失败"。
    if grep -qF '缺证书' <<<"$CG_DRY"; then
        ok "干跑只报不补"
    else
        bad "干跑连缺什么都不报"
    fi
    [[ ! -f "$CG/certs/a.crt" ]] \
        && ok "干跑之后文件确实没动" || bad "干跑却写了证书"
fi
rm -rf "$CG"

group "端口分配 (同名覆盖是最难查的一种)"
PORTT=$(mktemp -d); mkdir -p "$PORTT/conf"
PT_OUT=$(CONF_DIR="$PORTT/conf" XRAY_BASE="$PORTT" bash -c '
  source "'"$ROOT"'/conf/lib/ports.sh" 2>/dev/null
  x_port_taken(){ [[ -f "'"$PORTT"'/conf/.taken" ]] && grep -qx "$1" "'"$PORTT"'/conf/.taken"; }
  for i in 1 2 3 4 5 6; do p=$(x_random_free_port); echo "$p"; done
' 2>/dev/null)
PT_N=$(printf '%s' "$PT_OUT" | grep -c '[0-9]')
PT_U=$(printf '%s' "$PT_OUT" | grep '[0-9]' | sort -u | grep -c '[0-9]')
if [[ "${PT_N:-0}" -ge 6 && "${PT_N:-0}" == "${PT_U:-x}" ]]; then
    ok "向导的随机分配连领 6 次都不同 (领了 $PT_N 个, 不重复 $PT_U 个)"
else
    bad "随机分配重复了: 领 $PT_N 次但只有 $PT_U 个不同端口"
fi

# 账本: 领过的端口要被记下, 换个进程再领不该重复
PB_OUT=$(cd "$ROOT" && XRAY_BASE="$PORTT" bash -c '
  source conf/lib/ports.sh 2>/dev/null
  source tools/cdn_auto.sh 2>/dev/null
  x_port_taken(){ [[ -f "'"$PORTT"'/conf/.taken" ]] && grep -qx "$1" "'"$PORTT"'/conf/.taken"; }
  cd_batch_take_port; echo
  cd_batch_take_port; echo
  cd_batch_take_port; echo
' 2>/dev/null)
PB_N=$(printf '%s' "$PB_OUT" | grep -c '[0-9]')
PB_U=$(printf '%s' "$PB_OUT" | grep '[0-9]' | sort -u | grep -c '[0-9]')
if [[ "${PB_N:-0}" -ge 3 && "${PB_N:-0}" == "${PB_U:-x}" ]]; then
    ok "批量账本连领 3 次都不同 (跨调用也记着)"
else
    bad "批量账本重复了: 领 $PB_N 次只有 $PB_U 个不同端口 → 同名覆盖"
fi

# 账本文件确实落盘了 —— 不落盘就等于没记
if [[ -s "$PORTT/.batch-used" ]] || grep -qF 'printf .%s.\n. "$n" >> "$used"' "$ROOT/tools/cdn_auto.sh"; then
    ok "账本落在 \$XRAY_BASE/.batch-used (换一次调用也不重发)"
else
    bad "账本没落盘 → 换个终端再跑一次就重发同样的端口"
fi
rm -rf "$PORTT"

# xHTTP 必须两个方向都关缓冲。只关响应是不够的。
# 这份诊断结论是**实测**出来的, 不是猜的:
#   直连 xray 端口            → 200
#   经 Cloudflare → nginx     → invalid Read on closed Body
# 写进工具是为了让用户自己分清, 而不是照着"重装一遍"乱试。
# 老脚本 (菜单 5/6/7) 是自己 heredoc 拼片段的, 一直**没有分享元数据** ——
# 建出来的节点没有分享链接、不进订阅, 而且 CDN 档位下没人给它挂 nginx。
# 三个节点脚本以前各抄了一份共用函数, 而且**已经漂移**: Reality.sh 的
# safe_read 带 batch 守卫, 另外两个不带。今天不出事只因为那两个只从菜单进;
# 一旦有人非交互地调用, 它就永远卡在 read 上 —— 前面的日志全正常, 只是不动。
# 这两条是被"用户旅程验收" (tools/e2e_journey.sh) 逮到的, 都不是理论问题:
#
#  1) --apply 只在 `if a.config_json:` 里面被认。走 CLI 参数那条路时它被**静默
#     忽略**: 传了 --apply, 什么都不写, 而且一句错都不报。调用方以为建好了。
#  2) nginx 档位把证书清掉了, 却没把 security 一起置空, 产出"要 TLS 却没证书"
#     的入站 —— 过得了 xray -test, 面板也正常, 只有真连才炸。而 nginx 是 WS 类
#     节点的默认档位, 等于菜单 13/14 建出来的 nginx 节点一个都连不上。
#     根因更深一层: security 是 build() 的**位置参数**, opts["security"] 它不看,
#     所以原来那句赋值从头到尾没起过作用。
group "建节点 (菜单 13/14 走的那条路)"
J="$ROOT/tools/e2e_journey.sh"
if [[ -r "$J" ]]; then ok "用户旅程验收脚本在"
else bad "缺 e2e_journey.sh —— 用户那条路就没人在测了"; fi

# --apply 必须在**两条**路上都认。少一条就是"传了参数什么也没发生, 且不报错"。
_dp="$ROOT/conf/lib/deploy.py"
_apply=$(grep -c "_write_plan(r, a.conf_dir, a.share_dir)" "$_dp" 2>/dev/null) || _apply=0
if [[ "${_apply:-0}" -ge 2 ]]; then
    ok "--apply 在 JSON 路径和 CLI 参数路径都落盘"
else
    bad "--apply 只在一条路上生效 (另一条静默什么都不做) —— 实测 ${_apply:-0} 处"
fi

# nginx 档位必须把 security 一起置空: 证书被 nginx 拿走了, xray 再要 TLS 就没证书
grep -qE 'eff_security = "none" if \(tier == ACCESS_NGINX and security == "tls"\)' "$_dp" \
    && ok "nginx 档位 + tls 会把 security 置空 (不会生成无证书的 TLS 入站)" \
    || bad "nginx 档位仍保留 security=tls 而证书已被清掉 → tls: no certificates configured"

# 而且必须**按位置**传给 build —— 放进 opts 是不生效的 (build 不看它)
grep -qE 'node_build\.build\(protocol, transport, eff_security, nopts\)' "$_dp" \
    && ok "解析后的 security 按位置传给 build (放进 opts 是不生效的)" \
    || bad "security 没按位置传给 build —— 改动会静默失效"

group "节点脚本收敛 (共用层只有一份)"
[[ -r "$ROOT/conf/lib/proto_ui.sh" ]] \
    && ok "conf/lib/proto_ui.sh 在" || bad "共用层不存在"
# ★ 共用函数绝不能在脚本里再定义一遍 —— 定义了就等于各走各的, 收敛白做
_dup=0
for _f in conf/vlessecn.sh conf/vlessxhttpecn.sh conf/Reality.sh; do
    if grep -qE '^(safe_read|safe_read_port|clean_input|get_next_index|print_(info|ok|warn|error|title))\(\)' "$ROOT/$_f" 2>/dev/null; then
        _dup=$((_dup+1))
    fi
done
if [[ "$_dup" -eq 0 ]]; then
    ok "三个脚本里都没有再定义共用函数 (只有一份实现)"
else
    bad "$_dup 个脚本还在自己定义共用函数 → 又各走各的了"
fi
# batch 守卫必须在那**唯一一份**里
if grep -qF 'X_BATCH:-0' "$ROOT/conf/lib/proto_ui.sh"; then
    ok "batch 守卫在共用层里 (三个脚本都受保护)"
else
    bad "共用层里没有 batch 守卫 → 非交互调用会卡在 read 上"
fi
# 缺库时批处理必须拒绝, 而不是带着未定义函数往下跑
if grep -qE 'X_BATCH.*==.*1.*\n?.*exit 1' "$ROOT/conf/vlessxhttpecn.sh" || grep -qF '拒绝继续' "$ROOT/conf/vlessxhttpecn.sh"; then
    ok "缺共用层时批处理会明确拒绝 (而不是 undefined function 一路跑)"
else
    bad "缺共用层时没有拒绝逻辑 → set -u 下报一堆 unbound variable"
fi
# stdout 是数据通道: 共用层绝不能往 stdout 写
if grep -E '^[^#]*\}\s*;\s*echo ' "$ROOT/conf/lib/proto_ui.sh" | grep -qvF '>&2'; then
    _so=$(grep -nE '^(print_info|print_ok|print_warn|print_error|print_title)\(\)' "$ROOT/conf/lib/proto_ui.sh" >/dev/null; grep -A3 -E '^(print_info|print_ok|print_warn|print_error)\(\)' "$ROOT/conf/lib/proto_ui.sh" | grep -cF '>&2')
    [[ "$_so" -ge 4 ]] && ok "共用层的打印全部 >&2 (stdout 留给分享链接)" || bad "共用层有打印没走 >&2"
else
    ok "共用层的打印全部 >&2 (stdout 留给分享链接)"
fi
# 语法
for _f in conf/vlessecn.sh conf/vlessxhttpecn.sh conf/Reality.sh conf/lib/proto_ui.sh; do
    bash -n "$ROOT/$_f" 2>/dev/null || bad "$_f 语法错"
done
ok "四个脚本语法都正常"

group "老脚本建出来的节点也要能分享 (菜单 5/6/7)"
# ★ 夹具目录必须与**全项目读取方**的口径一致: <root>/conf + <root>/out/share。
#   这里原先是 "$AD/conf" + "$AD/share/tokens" —— 而 share/tokens 正是
#   deploy.py 写错的那个目录 (内核读 conf, 分享读 out/share)。
#   夹具照着错的口径建, 于是这条用例**替 bug 背书**: 它在旧口径上一直绿,
#   而真机上预置路径建的节点在 out/share 里根本找不到元数据、发不出链接。
#   现在夹具走正确口径, 并把"元数据落在读取方会看的地方"单独断言一条。
AD=$(mktemp -d); mkdir -p "$AD/conf" "$AD/out/share"
python3 - "$AD" <<'PYX'
import json,sys,os
d=sys.argv[1]
frag={"inbounds":[{"tag":"vless-xhttp01","listen":"0.0.0.0","port":39314,
  "protocol":"vless","settings":{"clients":[{"id":"749021fe-aa92-4bbd-91c5-33b4e8123cef"}],"decryption":"none"},
  "streamSettings":{"network":"xhttp","security":"tls",
    "tlsSettings":{"serverName":"d.example.com","minVersion":"1.3"},
    "xhttpSettings":{"path":"/abc/","mode":"auto"}}}]}
json.dump(frag,open(os.path.join(d,"conf","vless-xhttp01.json"),"w"),indent=1)
PYX
AD_OUT=$(cd "$ROOT" && python3 conf/lib/deploy.py --adopt "$AD/conf/vless-xhttp01.json" --domain d.example.com 2>&1)
# ★ 路径口径回归: --adopt 补出来的元数据必须落在**读取方**会看的地方
#   (share_meta / node.sh / share.sh / share_payload 统一读 <root>/out/share)。
#   写错目录的症状是"补发布报了 OK、链接还是发不出来", 且没有任何报错。
if [[ -f "$AD/out/share/vless-xhttp01.json" ]] && [[ ! -f "$AD/share/tokens/vless-xhttp01.json" ]]; then
    ok "--adopt 落在 out/share (与全项目读取方同一口径)"
else
    bad "--adopt 没落在 out/share → 补发布报 OK 但分享仍然读不到 (路径口径又漂了)"
fi
if [[ -f "$AD/out/share/vless-xhttp01.json" ]]; then
    ok "--adopt 给老片段补上了分享元数据"
else
    bad "--adopt 没补元数据 → 老脚本建的节点仍然没有分享链接"; fi
# 元数据里的域名/端口必须来自片段本身, 不能要调用方再报一遍
AD_META="$AD/out/share/vless-xhttp01.json"
grep -qF '"host": "d.example.com"' "$AD_META" && ok "域名取对了" || bad "域名错了"
grep -qF '"port": 39314' "$AD_META" && ok "端口取自片段" || bad "端口错了"
# 片段里的 tag 才是唯一真相 —— 文件名可能和它对不上
grep -qF '"tag": "vless-xhttp01"' "$AD_META" && ok "tag 以片段为准" || bad "tag 取错了"
# 老节点也必须能出链接
AD_LINK=$(cd "$ROOT" && python3 -c "
import sys; sys.path.insert(0,'conf/lib')
import nodes as N, share_meta
nl,bad=N.collect('$AD/conf')
for n in nl:
    m=share_meta.load('$AD/out/share', n['tag']) or {}
    l=N.build_share_link(n,m)
    if l and l.startswith('vless://'): print('OK')
" 2>/dev/null)
grep -qF 'OK' <<<"$AD_LINK" && ok "老节点现在能出分享链接" || bad "老节点仍出不了链接"
rm -rf "$AD"
# 三个老脚本都要接上这一刀, 少一个就漏一条入口
_missing=0
for _f in conf/vlessecn.sh conf/vlessxhttpecn.sh conf/Reality.sh; do
    grep -q 'lib/deploy.py' "$ROOT/$_f" 2>/dev/null || { _missing=$((_missing+1)); }
done
if [[ "$_missing" -eq 0 ]]; then
    ok "三个老脚本都接上了补发布"
else
    bad "$_missing 个老脚本没接补发布 → 那条入口建的节点仍然不可分享"
fi

# reality-cdn 走不通是**实测**出来的 (裸 REALITY+tcp 环回 200、REALITY+xhttp
# 环回 200, 唯独"上行 REALITY + 下行普通 TLS"不通), 不是猜测。菜单必须在生成
# 之前说出来 —— 否则用户建完、分享出去、客户端导入了才发现连不上。
# reality-reality 是**实测通**的第四个组合: 上下行都 REALITY 直连同一端口。
# 环回跑通, RN↔CC 连打 5 次全 200。它不在此列, 别再笼统跳过后所有 REALITY。
group "四个分离组合都在, 且 reality-reality 各项正确"
PS="$ROOT/conf/lib/preset.sh"
bash -c 'source "'"$PS"'"; x_split_modes' >/tmp/_sm.$$ 2>/dev/null
if grep -qF 'reality-reality' /tmp/_sm.$$ >/dev/null 2>&1; then
    ok "reality-reality 在模式表里"
else
    bad "缺少 reality-reality —— 只剩三个组合, 其中一个还已知不通"
fi
rm -f /tmp/_sm.$$
for pair in "reality-reality:reality:reality" "cdn-cdn:tls:tls" "cdn-reality:tls:reality"; do
    m=${pair%%:*}; rest=${pair#*:}; ul=${rest%%:*}; dl=${rest##*:}
    _u=$(bash -c 'source "'"$PS"'"; x_split_ul_sec '"$m" 2>/dev/null)
    _d=$(bash -c 'source "'"$PS"'"; x_split_dl_sec '"$m" 2>/dev/null)
    if [ "$_u" = "$ul" ] && [ "$_d" = "$dl" ]; then
        ok "$m 上下行安全层 = $_u / $_d"
    else
        bad "$m 上下行安全层不对 (期望 $ul/$dl, 实得 $_u/$_d)"
    fi
done
# reality-reality 上下行都直连 → 不能挂 nginx, 且没有 ECH 可开
_c=$(bash -c 'source "'"$PS"'"; x_split_dl_cdn reality-reality' 2>/dev/null)
_e=$(bash -c 'source "'"$PS"'"; x_split_ech reality-reality' 2>/dev/null)
_t=$(bash -c 'source "'"$PS"'"; x_split_tier reality-reality' 2>/dev/null)
[ "$_c" = no ] && ok "reality-reality 不挂 nginx (上下行都直连)" || bad "reality-reality 挂CDN=$_c, 应为 no"
[ "$_e" = no ] && ok "reality-reality 不开 ECH (REALITY 无 TLS)" || bad "reality-reality ECH=$_e, 应为 no"
[ "$_t" = cdn ] && ok "reality-reality 档位=cdn (直连 → 必须 0.0.0.0)" || bad "reality-reality 档位=$_t, 应为 cdn"

group "已知不通的组合要提前说 (reality-cdn)"
SM="$ROOT/tools/split_menu.sh"
warn_line=$(awk '/SPLIT. = reality-cdn/{print NR; exit}' "$SM")
gen_line=$(awk '/确认生成/{print NR; exit}' "$SM")
if [ -n "${warn_line:-}" ]; then
    ok "菜单对 reality-cdn 有专门提示"
else
    bad "菜单没有提示 reality-cdn 已知不通 → 用户会建完才发现连不上"
fi
# 注意: 这一段刻意不写 `| head` / `| grep -q`。pipefail 下产出方会吃 SIGPIPE(141),
# 判断会反过来 —— 项目自己的 lint 就会拦下来。这里一律用 awk 全量读取。
if grep -qF 'per-inbound' "$SM" >/dev/null 2>&1; then
    ok "提示里写清了为什么不通 (会话表 per-inbound vs 普通 TLS)"
else
    bad "提示里没说明原因, 用户无法判断该不该用"
fi
if grep -qF 'cdn-reality' "$SM" >/dev/null 2>&1; then
    ok "提示里指了可靠的替代组合"
else
    bad "提示里没说该用哪个替代组合"
fi
if [ -n "${warn_line:-}" ] && [ -n "${gen_line:-}" ] && [ "${warn_line:-0}" -lt "${gen_line:-0}" ]; then
    ok "提示在生成之前 (第 $warn_line 行 < 第 $gen_line 行)"
else
    bad "提示不在生成之前 —— 等于没用 (提示 $warn_line / 生成 $gen_line)"
fi
bash -n "$SM" 2>/dev/null && ok "split_menu.sh 语法正常" || bad "split_menu.sh 语法错"

group "分离节点自检工具 (把实测结论交给用户)"
grep -qF 'invalid Read on closed Body' "$ROOT/tools/xhttp_doctor.sh" \
    && ok "认得那句唯一的线索" || bad "认不出 invalid Read on closed Body"
grep -qF 'Origin HTTP Protocol' "$ROOT/tools/xhttp_doctor.sh" \
    && ok "给出了 Cloudflare 侧要改哪一项" || bad "没告诉用户去 Cloudflare 改哪一项"
grep -qF 'HTTP/1.1' "$ROOT/tools/xhttp_doctor.sh" \
    && ok "明确说要改成 HTTP/1.1" || bad "没说清改成什么"
# 直连 vs 经 CDN 的判据必须在, 否则用户还是分不清
grep -qF '直连通' "$ROOT/tools/xhttp_doctor.sh" \
    && ok "给出了怎么分辨是节点坏还是 CDN 坏" || bad "没给判据"
bash -n "$ROOT/tools/xhttp_doctor.sh" 2>/dev/null \
    && ok "自检脚本语法正常" || bad "自检脚本语法错"

group "xHTTP 上行缓冲 (只关 proxy_buffering 是不够的)"
NG=$(mktemp -d); mkdir -p "$NG"
NG_OUT=$(cd "$ROOT" && python3 -c "
import sys; sys.path.insert(0,'conf/lib')
import nginx_apply as N
b=N.render_block('d.example.com', 24101, None, True, 'xhttp',
                 origin_tls=True, origin_sni='d.example.com', ind='    ', path='/x')
print(b)
" 2>/dev/null)
if grep -qF 'proxy_request_buffering off' <<<"$NG_OUT"; then
    ok "xHTTP 关了上行缓冲 (proxy_request_buffering off)"
else
    bad "xHTTP 没关上行缓冲 → nginx 先收完整个请求体再转, 上行永远等不到下行"
fi
grep -qF 'proxy_buffering off' <<<"$NG_OUT" \
    && ok "xHTTP 也关了下行缓冲" || bad "xHTTP 没关下行缓冲 → 下行长连接被 nginx 卡住"
# 别的协议不该跟着关 —— 关了只是白白多几次转发
NG_WS=$(cd "$ROOT" && python3 -c "
import sys; sys.path.insert(0,'conf/lib')
import nginx_apply as N
print(N.render_block('d.example.com', 80, None, True, 'ws', ind='    ', path='/x'))
" 2>/dev/null)
if grep -qF 'proxy_request_buffering off' <<<"$NG_WS"; then
    bad "ws 也被关了上行缓冲 —— 不该波及别的协议"
else
    ok "只影响 xHTTP, 别的协议没被波及"
fi
rm -rf "$NG"

group "CDN 自动配 nginx (三个静默失败)"
NGT=$(mktemp -d); mkdir -p "$NGT/nginx" "$NGT/conf"
cat > "$NGT/nginx/a.example.com.conf" <<'NGEOF'
server {
    listen 443 ssl;
    server_name a.example.com;
    ssl_certificate /tmp/x.pem;
    ssl_certificate_key /tmp/y.key;
}
NGEOF
cat > "$NGT/nginx/b.example.com.conf" <<'NGEOF'
server {
    listen 443 ssl;
    server_name b.example.com;
    ssl_certificate /tmp/x.pem;
    ssl_certificate_key /tmp/y.key;
}
NGEOF
cat > "$NGT/conf/v-xhttp.json" <<'NGEOF'
{"inbounds":[{"port":24888,"protocol":"vless",
 "streamSettings":{"network":"xhttp","security":"tls",
  "xhttpSettings":{"path":"/t"}}}]}
NGEOF
# ① --nginx 默认值是 "-t", 以 - 开头。只在双域名那条路上 (_run_insert
#    重建 argv) 暴露, 单域名不走 —— 所以历史上一直没人碰到。
if python3 - "$ROOT/conf/lib/nginx_apply.py" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"def _run_insert\(args\):(.*?)\n\ndef ", src, re.S)
body = m.group(1) if m else ""
sys.exit(0 if ('flag, str(v)' in body and 'startswith("-")' in body) else 1)
PYEOF
then ok "argv 重建时处理了以 - 开头的值 (--nginx=-t), 双域名不再炸"
else bad "argv 重建没处理以 - 开头的值 → 双域名报 argument --nginx: expected one argument"
fi

# ② 片段里**没有** _domain 字段 (域名是生成时入参)。扫描器还去找它的话,
#    永远扫不到东西, 自动配置就永远静默跳过。
if python3 - "$ROOT/tools/cdn_auto.sh" <<'PYEOF'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
#   判据不是"文件里不能出现 _domain", 而是**它不能是主要来源**。
#   上行域名现在按这个顺序取: _meta.domain → 环境变量(生成时入参) → _domain。
#   把 _meta 和入参拿掉、只剩 _domain 才是最坏情况 (片段里真没有它,
#   于是永远扫不到 → 自动配置静默跳过)。所以查的是**前两路还在不在**。
sys.exit(0 if ('UL_DOMAINS' in s and 'meta.get("domain")' in s) else 1)
PYEOF
then ok "上行域名从 _meta / 生成时入参取, 不再只指望片段里的 _domain"
else bad "上行域名只靠 _domain → 片段里本来就没有 → 永远扫不到"
fi

# ③ --dry-run 不能写死在参数里: 写了就只是预演, 磁盘上一个字没改,
#    还会打印完整的 server 块, 看着像成功了。
if grep -q 'local -a a=(--domain "$dom_arg" --port "$port" --transport "$tr")' "$ROOT/tools/cdn_auto.sh" \
   && ! grep -q 'a=(--domain "$dom_arg" --port "$port" --transport "$tr" --dry-run)' "$ROOT/tools/cdn_auto.sh"
then ok "--dry-run 不再写死 (否则自动配置只是预演, 看着成功其实没写)"
else bad "--dry-run 写死在参数里 → 自动配置从不落盘"
fi

# ④ 片段一个都没有时 prune 也要动手 —— 那正是"节点全删了"的时候。
# 用 grep -F 固定串: 正则里那一堆 [ ] { } $ 转义后基本没法维护,
# 而断言本身只要看"有没有这一句"就够了。
if grep -qF '[[ ${#frags[@]} -gt 0 ]] && live=' "$ROOT/tools/cdn_auto.sh"
then ok "conf/ 空时 prune 不会早退 (节点全删正是最该收拾的时刻)"
else bad "conf/ 空时 prune 直接返回 → 站点 location 留着反代到不存在的端口"
fi

# ⑤ 端到端: 单域名与双域名都要真的写进站点文件
CDOUT=$(cd "$ROOT" && XRAY_BASE="$NGT" NGINX_CONF_ROOTS="$NGT/nginx" bash -c '
  source tools/cdn_auto.sh >/dev/null 2>&1
  _e(){ printf "%s\n" "$1" >&2; }
  x_cdn_autosetup --domain a.example.com --downlink-domain b.example.com '"$NGT"'/conf/v-xhttp.json >/dev/null 2>&1
  echo "a=$(grep -c location '"$NGT"'/nginx/a.example.com.conf)"
  echo "sn=$(grep -c "server_name a.example.com" '"$NGT"'/nginx/a.example.com.conf)"' 2>/dev/null)
CE_A=$(printf '%s' "$CDOUT" | sed -n 's/^a=//p')
CE_SN=$(printf '%s' "$CDOUT" | sed -n 's/^sn=//p')
[[ "${CE_A:-0}" -ge 1 ]] && ok "双域名真的写进了站点文件 (a 域名 location 数=$CE_A)" \
                         || bad "双域名没写进站点文件 (location 数=${CE_A:-无})"
[[ "${CE_SN:-0}" -ge 1 ]] && ok "插入 location 没有动整站的 server_name" \
                         || bad "插入把 server_name 也弄没了 —— 会把整个站点搞坏"
rm -rf "$NGT"

group "面板自身更新 (进门自动比对 + 备份 + 回退)"

# ★ 这一组对应一次**线上真实故障** (2026-10-15):
#   用户从 GitHub 一键进来, 点菜单报
#       [X] 取不到 /tmp/.xray-panel.XXXXXX/lib/print.sh —— 提示函数不可用
#   仓库是好的, 网络也是好的 —— 坏的是他机器上那份 10-10 的旧面板:
#   run_server 走 _get, 而 _get 是"本地优先", 在 /root 找到了那份旧的直接用,
#   一次网络都不发。旧面板里那个已修掉的缓存 bug 于是又被跑了一遍。
#   而取下来的面板落在 $TMP 里, 退出即删 —— 什么都不会留下, 下次还这样。
_INST="$ROOT/install.sh"
_PAN="$ROOT/xray-panel.sh"

# ① 面板脚本必须**远端优先比对**, 不能沿用 _get 的本地优先
if sed -n '/^run_server()/,/^}/p' "$_INST" | grep -F 'panel_autoupdate' >/dev/null; then
    ok "进门会先比对远端 (不再直接吃本地那份旧的)"
else
    bad "进门仍然直接用本地副本 → 面板永远不更新"
fi
# ② 跑的是**托管副本**, 不是某个躺在 /root 下的历史遗留
if sed -n '/^run_server()/,/^}/p' "$_INST" | grep -F 'PANEL_MANAGED' >/dev/null; then
    ok "跑的是托管副本 \$SRV_ROOT/.panel/xray-panel.sh"
else
    bad "跑的仍可能是任意本地副本 → 用户那份 10-10 的还会被选中"
fi
# ③ 更新必须留退路: 备份 + 语法检查 + 回滚
for _pair in "先备份再覆盖|panel_backup" \
             "更新前语法检查|panel_sane" \
             "落地后再验一次并在不过时回滚|已回滚到更新前的版本"; do
    _k="${_pair%%|*}"; _p="${_pair##*|}"
    if grep -F "$_p" "$_INST" >/dev/null; then ok "$_k"
    else bad "$_k (找不到 $_p)"; fi
done
# ④ **任何情况下都不能把人挡在面板外面** (SB auto_update 的铁律)
if sed -n '/^panel_autoupdate()/,/^}/p' "$_INST" | grep -E '\bdie\b|exit 1' >/dev/null; then
    bad "更新失败会终止 → 网络一抖就进不去面板"
else
    ok "更新失败绝不终止 (连不上就用本机这份继续)"
fi
# ⑤ 进门检查有时限, 且**不能**跟着"有没有 tty"变行为。
#    第一版加过 [[ -t 0 ]], 结果是"交互式进来会更新、管道进来永远不更新"。
if sed -n '/^run_server()/,/^}/p' "$_INST" | grep -F -- '-t 0' >/dev/null; then
    bad "进门检查跟着 tty 判定 → 同一台机器两种行为"
else
    ok "进门检查与 tty 无关 (该查就查)"
fi
if grep -F 'XRAY_UPDATE_BUDGET' "$_INST" >/dev/null \
   && grep -F 'XRAY_NO_UPDATE' "$_INST" >/dev/null; then
    ok "进门检查有时限也有开关 (XRAY_UPDATE_BUDGET / XRAY_NO_UPDATE)"
else
    bad "进门检查没有时限/开关 → 只能干等或者没法跳过"
fi
# ⑥ 回退入口必须能在面板里点到 (SB 也没有这一条)
if grep -F 'panel_rollback' "$_INST" >/dev/null \
   && grep -F 'panel-rollback' "$_PAN" >/dev/null; then
    ok "回退在面板里有入口 (不用 SSH 手抄命令)"
else
    bad "回退只能命令行做 → 用户点不到"
fi
# ⑦ 回退/查看版本要**离线可用**: 本地那份 install.sh 优先
if sed -n '/^_panel_self_run()/,/^}/p' "$_PAN" | grep -F '.panel/install.sh' >/dev/null; then
    ok "回退走本地那份 install.sh (断网也能回退)"
else
    bad "回退也要现从 GitHub 取 → 最需要它的时候用不了"
fi
# ⑧ 版本号只能有一个来源: 托管副本旁边那份 VERSION。
#    实测缺陷: 原来会"到处找 VERSION", 于是从仓库检出更新远端旧面板时
#    打出 "已更新面板脚本 → v3.0.0" —— 而实际落地的是没有 VERSION 的旧版。
#    报错的版本号比不报更糟。
if [[ "$(sed -n '/^panel_ver()/,/^}/p' "$_INST" | grep -c 'panel_ver_dir "\$PANEL_DIR"')" == "1" ]] \
   && ! sed -n '/^panel_ver()/,/^}/p' "$_INST" | grep -F '_SELF_DIR' >/dev/null; then
    ok "版本号只认托管目录 (不会把别处的版本号报成当前版本)"
else
    bad "版本号会跨目录借 → 屏幕上的版本与实际跑的这份可能不是一回事"
fi
# ⑨ 取不到 VERSION 时不能显示成光秃秃一个 "v"
if grep -F 'panel_self_label' "$_PAN" >/dev/null \
   && grep -F '身份' "$_PAN" >/dev/null; then
    ok "没有版本号时报文件身份, 不显示成裸 'v'"
else
    bad "没有版本号时显示裸 'v' → 像渲染坏了"
fi
# ⑩ 仓库根要有 VERSION, 否则永远只能显示"身份"
if [[ -s "$ROOT/VERSION" ]]; then
    ok "仓库根有 VERSION ($(head -1 "$ROOT/VERSION"))"
else
    bad "仓库根缺 VERSION → 面板没有版本号可显示"
fi
# ⑪ 新旧 install.sh 的子命令都要认 (面板调的就是这些)
for _sub in update-panel panel-rollback panel-status; do
    if grep -qE "^ *${_sub}\|" "$_INST"; then ok "install.sh 认子命令 $_sub"
    else bad "install.sh 不认 $_sub → 面板里点了没反应"; fi
done
# ⑫ 主菜单要能看见版本, 而且要有一项能点进去
if grep -F 'ui_kv "面板版本"' "$_PAN" >/dev/null; then
    ok "主菜单显示面板版本"
else
    bad "主菜单看不到面板版本 → 用户分不清自己跑的是哪一份"
fi
if grep -F '12) panel_self_menu' "$_PAN" >/dev/null \
   && grep -F '请选择 [0-12]' "$_PAN" >/dev/null; then
    ok "主菜单 12) 进更新面板脚本 (提示范围已同步)"
else
    bad "菜单项 12 与提示范围 [0-1x] 不一致 → 用户以为没有这一项"
fi

group "沙箱隔离 (脚本不能无视 XRAY_BASE 写生产)"

# ★ 这一组对应一次**我自己闯的祸** (2026-10-16), 而且它已经在同一台机器上
#   发生过两次 —— 上一次是 10-12, 靠"节点已存在全部跳过"侥幸没写坏东西。
#
#   现场: 用 XRAY_BASE=/tmp/xxx 跑「全协议一键生成」, 批量脚本自己是认
#   XRAY_BASE 的, 但它用 `bash conf/<proto>.sh add` 起**子进程** ——
#   而 hysteria2.sh 那一行写的是 `BASE_DIR="${XRAY_BASE_DIR:-/root/catmi/xray}"`,
#   只认 XRAY_BASE_DIR (从没设过) → 回落到生产目录。
#   结果: 沙箱里空空如也, 生产 conf 上多了 hysteria-48/49/50 三个节点,
#   而屏幕上一切正常。三个 ui_probe 用例各跑了一次批量, 所以正好三个。
#
#   两个层面的检查都要有:
#     静态 —— 不许再把生产路径写死 (写死就必然回落);
#     动态 —— 真的在沙箱里跑一遍, 再回头看生产目录有没有被动过。
#   静态只能挡住"已知的写法", 动态才挡得住"下一个人换了个写法"。

# ① 静态: conf/ 下 (legacy 除外) 不许把 /root/catmi/xray 写死成基础目录
_HARD=$(grep -rnE '^[[:space:]]*(BASE_DIR|XRAY_BASE|CONF_DIR|OUT_DIR)="/root/catmi' \
        "$ROOT/conf" --include='*.sh' 2>/dev/null | grep -v '/fd/legacy/' || true)
if [[ -z "$_HARD" ]]; then
    ok "没有脚本把生产目录写死成基础目录 (都会收 XRAY_BASE)"
else
    bad "这些脚本无视 XRAY_BASE, 会写到生产目录" "$(printf '%s' "$_HARD" | sed 's|^|          |')"
fi

# ② 静态: batch.sh 必须把 XRAY_BASE **export** 出去
#    各协议是独立子进程, 靠继承拿这个值; 只赋值不 export 等于没传。
if sed -n '/^XRAY_BASE="\${XRAY_BASE_DIR/,+6p' "$ROOT/conf/batch.sh" | grep '^export XRAY_BASE' >/dev/null; then
    ok "batch.sh 把 XRAY_BASE export 给子进程"
else
    bad "batch.sh 只赋值不 export → 子进程收不到, 各自回落生产目录"
fi

# ③ 动态: 沙箱里跑一遍 hysteria2, 生产目录必须一个字节都没动
#    (hysteria2 是漏网的那个; 这条测试用**只设 XRAY_BASE** 的方式复现它,
#     不设 XRAY_BASE_DIR —— 老测试两个都设, 所以永远看不见这个缺陷。)
# ★ 快照必须是**整个 conf 目录**, 不能只数某一类。
#   第一版只数 hysteria-*.json —— 于是"门禁自己往生产里写了一个 reality 节点"
#   这件事它完全看不见 (实测踩到)。判据窄一寸, 漏掉的就是一整类。
_PROD="${XRAY_PROD_DIR:-/root/catmi/xray}"
_prod_snap_before=$(ls -1 "$_PROD/conf"/*.json 2>/dev/null | sort | md5sum | cut -d' ' -f1)
_prod_n_before=$(ls -1 "$_PROD/conf"/*.json 2>/dev/null | wc -l | tr -d ' ')
_prod_mtime_before=$(stat -c %Y "$_PROD/conf" 2>/dev/null || echo none)
_HYB="$TMP/hyb_iso"; rm -rf "$_HYB"; mkdir -p "$_HYB/conf" "$_HYB/out"
( cd "$ROOT" && XRAY_BASE="$_HYB" X_BATCH=1 X_NO_RELOAD=1 \
    timeout 90 bash conf/hysteria2.sh add </dev/null ) >/dev/null 2>&1
_hyb_n=$(ls -1 "$_HYB/conf"/hysteria-*.json 2>/dev/null | wc -l | tr -d ' ')
_prod_snap_after=$(ls -1 "$_PROD/conf"/*.json 2>/dev/null | sort | md5sum | cut -d' ' -f1)
_prod_n_after=$(ls -1 "$_PROD/conf"/*.json 2>/dev/null | wc -l | tr -d ' ')
_prod_mtime_after=$(stat -c %Y "$_PROD/conf" 2>/dev/null || echo none)

if [[ "$_hyb_n" -ge 1 ]]; then
    ok "沙箱里跑 hysteria2 落到了沙箱 (只给 XRAY_BASE)"
else
    bad "沙箱里跑 hysteria2 什么也没落 —— 说明它根本没认 XRAY_BASE"
fi
if [[ "$_prod_snap_before" == "$_prod_snap_after" && "$_prod_mtime_before" == "$_prod_mtime_after" ]]; then
    ok "生产 conf 一个字节没动 (共 $_prod_n_before 个片段, 目录 mtime 未变)"
else
    bad "沙箱运行写到了生产目录" \
        "片段 $_prod_n_before → $_prod_n_after; 目录 mtime $_prod_mtime_before → $_prod_mtime_after"
fi
rm -rf "$_HYB"

# ④ 自动化测试绝不能在生产分享服务上建订阅
#    现场: 生产分享服务里堆了 20 条「全协议订阅」, 引用的是沙箱里并不存在的
#    tag —— 每跑一轮测试就多几条, 而本地一切正常。
for _h in "tools/check_libs.sh" "tools/ui_probe.py" "tools/pty_journey.py"; do
    if grep -F 'X_NO_SHARE_SUBSCRIBE' "$ROOT/$_h" >/dev/null; then
        ok "$(basename "$_h") 关掉了自动订阅 (不碰生产分享服务)"
    else
        bad "$(basename "$_h") 没关自动订阅 → 每跑一次测试就在生产分享服务里留一条记录"
    fi
done
if sed -n '/^share_ensure_subscription()/,/^}/p' "$ROOT/conf/share.sh" \
     | grep -F 'X_NO_SHARE_SUBSCRIBE' >/dev/null; then
    ok "share.sh 认这个开关"
else
    bad "share.sh 不认开关 → 测试没法关掉它"
fi

# ⑤ 调用别处私有定义的输出函数 —— 会打印 "command not found" 而不是报错停下
#    现场: share.sh 里调了 batch.sh 私有定义的 print_info, 而 share.sh 自己
#    没定义、也没 source 到任何一个定义了它的库。表现是屏幕上出现一行
#          conf/share.sh: line 1500: print_info: command not found
#    而流程照常"成功"结束 —— 它不是 set -e 下的致命错误。
#    (本地测试看不见: 那条路径要"批量建完节点收尾"才会走到。)
#
#    ★ 判据必须算**可见集**, 不能只 grep 一个文件里有没有定义:
#      print_info 这批名字在 X 里不是全局的, 它由 proto_ui.sh 提供,
#      谁 source 了才看得见。只查"本文件有没有定义"会把
#      Reality.sh / vlessecn.sh / vlessxhttpecn.sh (都 source 了 proto_ui.sh)
#      一起冤枉进去 —— 假红的门禁比没有门禁更糟, 因为没人再看它。
_BADFN=$(XRAY_ROOT="$ROOT" python3 - <<'PYX'
import os, re, sys, pathlib
root = pathlib.Path(os.environ["XRAY_ROOT"])
libd = root / "conf" / "lib"

def defines(text):
    return set(re.findall(r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)\(\)', text, re.M))

lib_defs = {}
for f in libd.glob("*.sh"):
    try:
        lib_defs[f.name] = defines(f.read_text(encoding="utf-8", errors="ignore"))
    except OSError:
        pass

bad = []
for f in sorted((root / "conf").glob("*.sh")):
    try:
        t = f.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    calls = set(re.findall(r'\b(print_[a-z_]+)\b', t))
    if not calls:
        continue
    visible = defines(t)
    # 能看见的库: 文本里提到过的 lib/<名>.sh, 以及 proto_ui.sh (常用别名 _PUI)
    for name, d in lib_defs.items():
        if name in t:
            visible |= d
    if "_PUI" in t or "proto_ui" in t:
        visible |= lib_defs.get("proto_ui.sh", set())
    missing = {c for c in calls if c not in visible
               and not re.search(r'^[ \t]*%s\(\)' % re.escape(c), t, re.M)}
    if missing:
        bad.append("%s (%s)" % (f.name, ", ".join(sorted(missing))))
print(" | ".join(bad))
PYX
)
if [[ -z "$_BADFN" ]]; then
    ok "没有脚本调用自己看不见的输出函数 (print_* 可见集算过)"
else
    bad "这些脚本调用了未定义/取不到的 print_* 函数" "$_BADFN"
fi

group "ECH (客户端产物必须带得动它)"

# ★ 这一组对应 2026-10-16 的实测。原来预置⑤「CDN + ECH + 后量子」在 plan()
#   这条路上**完全没有 ECH**: 说明里写着, 产物里没有, 屏幕上看不出来。
#   而界面上另外那条路 (`ech-opts: {enable: true}` 不给配置) 更糟 ——
#   实测 mihomo 会自己去查 DNS, 查不到就整条节点连不上:
#       resolve ECH config error: no ECH config found in DNS records  (HTTP=000)
#   也就是说"开了 ECH"变成一个比不开还糟的状态。

# ① 预置⑤ 必须真的带 ech 标记 (不能只在说明里写)
if grep -E '⑤ CDN \+ ECH[^|]*\|[^|]*\|mlkem,ech"?' "$ROOT/conf/lib/preset.sh" >/dev/null; then
    ok "预置⑤ 的标记列真的带 ech (说明与配置一致)"
else
    bad "预置⑤ 只在说明里写了 ECH, 标记列没有 → 建出来的节点没有 ECH"
fi

# ② plan() 必须真的把 ech_config 写进元数据 (而不是只写个布尔)
#    实测过: 只写 `meta["ech"] = True` 时, to_mihomo 落到"只 enable 不给配置"，
#    那正是会把节点打死的那条路。
if sed -n '/^def plan/,/^def adopt/p' "$ROOT/conf/lib/deploy.py" \
     | grep -F 'meta["ech_config"] = _cl' >/dev/null; then
    ok "plan() 会把 ECH 配置串写进分享元数据"
else
    bad "plan() 只声明开了 ECH 而没写配置串 → 客户端产物拿不到能用的配置"
fi
# ③ 取不到配置时必须出声 (静默降级是这条链路上最难查的形态)
if sed -n '/^def plan/,/^def adopt/p' "$ROOT/conf/lib/deploy.py" \
     | grep -F '取不到 ECH 配置' >/dev/null; then
    ok "取不到 ECH 配置时会明确告警"
else
    bad "取不到 ECH 配置是静默的"
fi

# ④ **绝不能**产出"只 enable 不给配置"的 ech-opts
#    实测后果: mihomo 整条节点连不上。
if grep -nE 'ech-opts' "$ROOT/conf/lib/to_mihomo.py" | grep -v '^[0-9]*: *#' \
     | grep -F '"enable": True}' >/dev/null; then
    bad "to_mihomo 仍会产出只带 enable 的 ech-opts → 那条节点在 mihomo 上必挂"
else
    ok "to_mihomo 不会产出只带 enable 的 ech-opts (要么带配置, 要么不写)"
fi

# ⑤ ECH 发现要能真拿到值, 且拿不到时安静返回空
_ECHG=$(X_NO_ECH_DISCOVER= XRAY_ROOT="$ROOT" python3 - <<'PYX'
import os, sys
sys.path.insert(0, os.path.join(os.environ["XRAY_ROOT"], "conf", "lib"))
import nodes
a = nodes.ech_discover("cloudflare.com", timeout=5)
b = nodes.ech_discover("1.2.3.4", timeout=3)
c = nodes.ech_discover("no-such-host-xyz.invalid", timeout=3)
print("real=%s,ip=%s,bad=%s" % ("ok" if (a and len(a) > 20) else "MISS",
                                  "empty" if not b else "LEAK",
                                  "empty" if not c else "LEAK"))
PYX
)
# 网络不可达时 a 会是 MISS —— 那是环境, 不是代码。所以只要不崩、IP 与坏域名不吃亏。
if [[ "$_ECHG" == "real=ok,ip=empty,bad=empty" ]]; then
    ok "ECH 发现: 真域名拿到配置, IP / 坏域名安静返回空"
elif [[ "$_ECHG" == "real=MISS,ip=empty,bad=empty" ]]; then
    # 本机取不到 HTTPS RR 是**环境** (无外网 / DNS 被劫持), 不是代码问题 ——
    # 门禁在这里不该假红, 但也不能假装通过, 所以照实说清是哪一种。
    ok "ECH 发现: IP / 坏域名安静返回空 (本机取不到 HTTPS RR, 属网络环境)"
else
    bad "ECH 发现行为不对: $_ECHG"
fi

# ⑥ VLESS 会话加密: 服务端用 decryption, 客户端用 encryption, **一对, 不能混**
#
#    ★ 这一条纠正的是我上一版写错的判据。当时看到 mihomo 报
#        proxy 0: invaild vless encryption value: mlkem768x25519plus.native.600s.…
#      就下结论"mihomo 不支持 Xray 的后量子会话加密", 于是让产物一律拒绝。
#      实测追问下去才发现: mihomo **支持**, 它只认客户端那一种形态
#          mlkem768x25519plus.native.0rtt.<客户端公钥>   → 接受
#          mlkem768x25519plus.native.600s.<服务端私钥>   → 拒绝
#      而面板把**服务端那一半**写进了客户端产物 —— 真正该修的是这个。
#      错误判据的代价是把本来能用的节点拒之门外。
_ENCG=$(XRAY_ROOT="$ROOT" python3 - <<'PYX'
import os, sys
sys.path.insert(0, os.path.join(os.environ["XRAY_ROOT"], "conf", "lib"))
import to_mihomo as M
def u(**kw):
    kw.setdefault("protocol", "vless")
    return bool(M.enc_unsupported(kw))
cases = [
    ("none",            u(encryption="none"), False),
    ("0rtt(客户端形态)",  u(encryption="mlkem768x25519plus.native.0rtt.CLIENT"), False),
    ("600s(服务端形态)",  u(encryption="mlkem768x25519plus.native.600s.SERVER"), True),
    ("其它形态",         u(encryption="xorpub"), True),
    ("服务端要/客户端无",  u(encryption="none", vless_srv_decryption="mlkem768x25519plus.native.600s.X"), True),
    ("非 vless",         u(protocol="trojan", encryption="whatever"), False),
]
bad = [n for n, got, want in cases if got != want]
print("bad=%s" % (",".join(bad) if bad else "none"))
PYX
)
assert_eq "$_ENCG" "bad=none" \
    "会话加密判据: 放过 0rtt 客户端形态, 挡住 600s 服务端形态与'服务端要、客户端无'"

# ⑥b 客户端那一半只能来自元数据 —— 不能拿服务端 decryption 顶上
if grep -F 'node["encryption"] = (meta.get("encryption") or "").strip() or "none"' \
     "$ROOT/conf/lib/to_mihomo.py" >/dev/null; then
    ok "客户端 encryption 只取自元数据 (不再回落到服务端 decryption)"
else
    bad "客户端 encryption 仍会回落到服务端 decryption → 拿服务端私钥去握手"
fi
# ⑥c 一次 vlessenc 要同时取到两半
if grep -F '"encryption"[[:space:]]*:[[:space:]]*"[^"]*"' "$ROOT/conf/mknode.sh" >/dev/null \
   && grep -F '"decryption"[[:space:]]*:[[:space:]]*"[^"]*"' "$ROOT/conf/mknode.sh" >/dev/null; then
    ok "菜单 13 一次 vlessenc 同时取 decryption 与 encryption"
else
    bad "菜单 13 只取了服务端那一半 → 客户端产物拿不到可用的密钥"
fi
# ⑥d 服务端片段里的 decryption 仍必须是服务端那一半
if grep -F 'out = {"clients": [client], "decryption": opts["encryption"]}' \
     "$ROOT/conf/lib/node_build.py" >/dev/null; then
    ok "服务端片段写的是 decryption (服务端那一半)"
else
    bad "服务端片段的 decryption 取值被改动了 —— 那会让服务端自己握手失败"
fi

# ⑦ 菜单 13 要能**独立**选 ECH (不绑在后量子预置上)
if sed -n '/ECH (加密 ClientHello/,/ECH: 不开/p' "$ROOT/conf/mknode.sh" | grep -c . >/dev/null \
   && grep -F 'ECH (加密 ClientHello' "$ROOT/conf/mknode.sh" >/dev/null; then
    ok "菜单 13 有独立的 ECH 选项 (不和 ML-KEM 绑死)"
else
    bad "ECH 只能靠预置⑤ 带出来 → 不用后量子的用户没法单开 ECH"
fi

group "卸载脚本 (不能删错)"

# ★ 这一组对应一次实测。仓库里原来那份 uninstall_xray.sh 只有五行, 用诱饵
#   目录跑过之后的结论是:
#     · 只删固定路径, 邻居没动 —— 这方面是干净的;
#     · 但 rm -rf 前面**没有确认、没有备份**;
#     · 单元文件没删 → 卸完 systemctl 还认得它;
#     · nginx 里我们插的 location 不摘 → 那些路径继续 502。
_UN="$ROOT/uninstall_xray.sh"

# ① 不许"看一眼路径就 rm -rf" —— 动手前必须证明这个目录是我们的
if grep -F 'dir_is_ours' "$_UN" >/dev/null \
   && grep -F '看不出是 xrayls 的安装目录' "$_UN" >/dev/null; then
    ok "卸载前会先确认目标目录是本工具的 (不是就拒绝)"
else
    bad "卸载脚本不做归属确认 → 路径被别的东西占用时会删错"
fi
# ② 符号链接必须拒绝 (rm -rf 一个指向别处的链接, 删的是什么就说不清了)
if grep -F '是一个符号链接' "$_UN" >/dev/null; then
    ok "符号链接会被拒绝 (不跟随)"
else
    bad "卸载脚本会跟符号链接删 → 可能删到别处"
fi
# ③ 要确认 + 有预演
if grep -F -- '--dry-run' "$_UN" >/dev/null && grep -F '确认请输入 yes' "$_UN" >/dev/null; then
    ok "要输 yes 才动手, 且有 --dry-run 预演"
else
    bad "卸载没有确认/预演 → 一条命令就没了"
fi
# ④ 先备份, 而且备份必须落在**被删目录外面**
if grep -F 'tar czf "$BACKUP"' "$_UN" >/dev/null \
   && grep -F 'BACKUP="$(dirname "$SRV_ROOT")' "$_UN" >/dev/null; then
    ok "删除前会备份, 且备份放在被删目录之外"
else
    bad "卸载不备份, 或备份放在被删目录里 (会跟着一起没)"
fi
# ⑤ 单元文件必须真的删掉 + daemon-reload
if grep -F 'rm -f "$UNIT"' "$_UN" >/dev/null \
   && grep -F 'daemon-reload' "$_UN" >/dev/null; then
    ok "会删除 systemd 单元文件并 daemon-reload"
else
    bad "只 stop+disable 不删单元文件 → 卸完 systemctl 还认得它"
fi
# ⑥ nginx 里我们插的段要摘掉 (否则站点上留下指向死端口的入口)
if grep -F 'xray-core BEGIN' "$_UN" >/dev/null \
   && grep -F 'xray-core END' "$_UN" >/dev/null; then
    ok "会按标记摘除自己插入的 nginx 段"
else
    bad "卸载不摘 nginx 段 → 站点上留一堆 502 的入口"
fi

# ⑦ 真跑一遍 (沙箱里, 用一个不存在的服务名, 不碰任何真东西)
_UNS="$TMP/un-install"; rm -rf "$_UNS"; mkdir -p "$_UNS/xray/conf" "$_UNS/xray/out" "$_UNS/xray/.panel" "$_UNS/nginx" "$_UNS/sibling/certs"
echo '{"inbounds":[{"tag":"n1","port":1}]}' > "$_UNS/xray/conf/n1.json"
echo meta > "$_UNS/xray/out/n1.json"
echo '{"k":1}' > "$_UNS/xray/config.json"
touch "$_UNS/xray/xrayls"; chmod +x "$_UNS/xray/xrayls"
echo cert > "$_UNS/sibling/certs/keep.pem"
cat > "$_UNS/nginx/site.conf" <<'NGXEOF'
server {
    server_name a.com;
    location / { root /var/www; }
    # >>> xray-core BEGIN a.com|/abc >>>
    location /abc { proxy_pass http://127.0.0.1:31510; }
    # <<< xray-core END a.com|/abc <<<
    location /keepme { proxy_pass http://127.0.0.1:8080; }
}
NGXEOF

# ⑦a 不是我们的目录 → 必须拒绝, 且一个文件都不动
mkdir -p "$_UNS/foreign/important"; echo x > "$_UNS/foreign/important/f"
_out=$(NGINX_CONF_ROOTS="$_UNS/nginx" XRAY_BASE="$_UNS/foreign" XRAY_SERVICE=no-such-svc \
       bash "$_UN" --yes 2>&1)
if [[ -f "$_UNS/foreign/important/f" ]] && printf '%s' "$_out" | grep -F '一个文件都没有动' >/dev/null; then
    ok "拿一个不属于它的目录去卸 → 拒绝且没动文件"
else
    bad "卸载脚本会删一个不属于它的目录"
fi

# ⑦b 符号链接 → 拒绝
ln -sfn "$_UNS/foreign" "$_UNS/link"
_out=$(XRAY_BASE="$_UNS/link" XRAY_SERVICE=no-such-svc bash "$_UN" --yes 2>&1)
if [[ -f "$_UNS/foreign/important/f" ]] && printf '%s' "$_out" | grep -F '符号链接' >/dev/null; then
    ok "符号链接 → 拒绝"
else
    bad "符号链接没被拦住"
fi

# ⑦c 正常卸载: 备份 / 摘 nginx / 保留邻居
_out=$(NGINX_CONF_ROOTS="$_UNS/nginx" XRAY_BASE="$_UNS/xray" XRAY_SERVICE=no-such-svc \
       bash "$_UN" --yes 2>&1)
_bk=$(ls -1 "$_UNS"/xray-uninstall-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
_kept=0
if grep -F 'location / {' "$_UNS/nginx/site.conf" >/dev/null \
   && grep -F 'location /keepme' "$_UNS/nginx/site.conf" >/dev/null; then _kept=1; fi
_marked=$(grep -c 'xray-core BEGIN' "$_UNS/nginx/site.conf" || true)
_bkin=$(tar tzf "$_UNS"/xray-uninstall-backup-*.tar.gz 2>/dev/null | grep -c 'conf/n1.json' || true)
assert_eq "$([ -d "$_UNS/xray" ] && echo gone || echo removed)/$_bk/$_kept/$_marked/$_bkin" \
          "removed/1/1/0/1" \
          "沙箱卸载: 目录已删 / 有 1 份备份(含 conf) / 站点自有 location 保留 / 标记段摘净"
if [[ -f "$_UNS/sibling/certs/keep.pem" ]]; then
    ok "同级的证书目录完好 (没被连坐)"
else
    bad "卸载把同级的证书目录也删了"
fi
rm -rf "$_UNS"

group "全协议: 批量铺共用层 (Reality 曾经永远失败)"

# ★ 实测 (全新安装上跑全协议): Reality 失败, 日志里只有一行
#     "缺少 conf/lib/proto_ui.sh, 且是批处理调用 —— 拒绝继续"
#   而 Trojan / SS2022 / Hysteria2 三个都正常 —— 面板上看起来"大部分成功"。
#
#   原因: batch.sh 的 resolve_scripts_dir 把协议脚本**平铺**下载到
#   /tmp/x-batch-scripts/, 却没铺 lib/。而协议脚本按 `dirname $0/lib/` 找
#   proto_ui.sh —— 找不到, 批处理模式下直接拒绝继续 (守卫本身是对的)。
#   从**仓库检出目录**跑时走的是另一条分支 (lib/ 就在旁边), 所以开发时看不见。

# ① 静态: 下载那条分支必须**照仓库形状**摆 (conf/ + conf/lib/ + tools/)
_RSC=$(sed -n '/^resolve_scripts_dir()/,/^}/p' "$ROOT/conf/batch.sh")
if printf '%s' "$_RSC" | grep -F 'confdir/lib' >/dev/null \
   && printf '%s' "$_RSC" | grep -F 'tooldir' >/dev/null \
   && printf '%s' "$_RSC" | grep -F 'SCRIPT_DIR="$confdir"' >/dev/null; then
    ok "批量下载按仓库形状摆 (conf/ + conf/lib/ + tools/), SCRIPT_DIR 指 conf/"
else
    bad "批量把脚本平铺下载 → 相对路径全断 (Reality 与 上下行分离 会一起失败)"
fi
# ② 两条腿要的同伴文件都必须在下载清单里
#    .py 那几个尤其重要: deploy.py 里是 `import node_build` / `import to_mihomo`,
#    逐个下到临时文件就 import 不到兄弟模块 (实测报 No module named 'node_build',
#    症状是全协议的上下行分离两个组合全失败, 而日志里是一段 Python traceback)。
for _need in proto_ui.sh preset.sh print.sh preset_batch.sh cdn_auto.sh \
             deploy.py node_build.py to_mihomo.py nodes.py share_meta.py \
             share_payload.py token_store.py; do
    if printf '%s' "$_RSC" | grep -F "$_need" >/dev/null; then
        ok "下载清单含 $_need"
    else
        bad "下载清单缺 $_need → 依赖它的那一段会失败"
    fi
done
# ②a1 share.sh 在 conf/ 下, 不在 conf/lib/ 下 —— URL 用错会报"下载失败",
#     而人只会去怀疑网络 (实测踩到)
if grep -F '"$GH_RAW/conf/share.sh"' "$ROOT/conf/batch.sh" >/dev/null \
   && ! grep -F 'share.sh \' "$ROOT/conf/batch.sh" >/dev/null; then
    ok "share.sh 取的是 conf/share.sh (不是 conf/lib/share.sh)"
else
    bad "share.sh 的下载 URL 写错了 (会报下载失败, 但其实是路径不对)"
fi

# ②a2 share.sh 必须下到 conf/ 那一层 —— 它按 dirname($0)/lib/ 找依赖,
#     下到 $tmp/share.sh 的话那边没有 lib/, 症状是"订阅链接没有自动生成"
#     而 curl 明明是通的 (实测)。
if sed -n '/^resolve_share_sh()/,/^}/p' "$ROOT/conf/batch.sh" | grep -F 'confdir/share.sh' >/dev/null; then
    ok "share.sh 下到 conf/ 那一层 (它自己的 lib/ 才找得到)"
else
    bad "share.sh 下到没有 lib/ 的地方 → 订阅链接永远生成不出来"
fi

# ②a3 分离那一段要用 REALITY 密钥对; 有内核就该自己生成, 不逼用户手填
if sed -n '/REALITY 密钥对: \*\*有内核就自己生成/,/^        fi$/p' "$ROOT/conf/batch.sh" \
     | grep -F 'x25519' >/dev/null; then
    ok "全协议会自己生成 REALITY 密钥对 (三个分离组合都跑得起来)"
else
    bad "分离组合要靠手设 X_BATCH_REALITY_*, 否则 cdn-reality 必失败"
fi

# ②a4 解析 x25519 输出必须容忍内核的真实写法 —— 26.x 打的是
#     "Password (PublicKey):", 只认 "^Password:" 会取到空公钥, 于是
#     cdn-reality / reality-reality 被静默跳过, 汇总却写"三个组合已生成"
#     (实测: 屏幕上只有 1 个节点, 还显示成功)。
#     这里把 batch.sh 里**真正那两行** awk 抠出来喂内核的真实输出, 行为验证,
#     而不是 grep 关键字 —— 关键字对了、正则以写错照样取空。
_PA="$TMP/x25519-parse.sh"
{
  printf '%s\n' '_kp=$(cat <<"EOK"'
  printf '%s\n' 'PrivateKey: uLX22Cx-uPwqBKf83VPrGwtkzaS7piASPzClsA4v91w'
  printf '%s\n' 'Password (PublicKey): Fci5CbGLzth1VHVYqupvgVytngRPmN0AiIQN3qFmRjw'
  printf '%s\n' 'Hash32: ZTznqado8ELL9dUs-3eLKOL0sjCSIjVgymIfG9WJUio'
  printf '%s\n' 'EOK'
  printf '%s\n' ')'
  grep -F '_pk=$(printf' "$ROOT/conf/batch.sh" | awk 'NR==1'
  grep -F '_pub=$(printf' "$ROOT/conf/batch.sh" | awk 'NR==1'
  printf '%s\n' 'printf "%s|%s" "$_pk" "$_pub"'
} > "$_PA"
_RES=$(bash "$_PA" 2>/dev/null || true)
_EXP='uLX22Cx-uPwqBKf83VPrGwtkzaS7piASPzClsA4v91w|Fci5CbGLzth1VHVYqupvgVytngRPmN0AiIQN3qFmRjw'
if [ "$_RES" = "$_EXP" ]; then
    ok "x25519 输出解析对得上内核真实写法 (Password (PublicKey) 也认)"
else
    bad "x25519 输出解析取不到公钥 (实得: ${_RES:-空}) → 两个 REALITY 组合会被静默跳过"
fi

# ②a5 汇总不许写死"三个组合" —— 真建了几个就报几个
_cnt_msg=$(awk '/printf/ && /已生成 %d 个组合/' "$ROOT/conf/batch.sh")
_hard_msg=$(awk '!/^[[:space:]]*#/ && /三个组合已生成/' "$ROOT/conf/batch.sh")
if [ -n "$_cnt_msg" ] && [ -z "$_hard_msg" ]; then
    ok "分离组合的汇总按实际数量报 (不写死三个)"
else
    bad "汇总写死'三个组合已生成' → 只建了一个也报成功"
fi

# ②b 下下来的每个文件都要验语法, 而且**按类型用对工具** ——
#     一视同仁 bash -n 会对 .py 报 "syntax error near unexpected token `0,'",
#     看起来像"下载损坏", 其实是拿错工具验它了。
if printf '%s' "$_RSC" | grep -F 'ast.parse' >/dev/null \
   && printf '%s' "$_RSC" | grep -F 'bash -n "$confdir/lib/$l"' >/dev/null; then
    ok "共用层按类型验语法 (.sh 用 bash -n, .py 用 ast)"
else
    bad "共用层没按类型验语法 → .py 会被 bash -n 误判成损坏"
fi

# ③ 行为: 平铺目录 (只有协议脚本 + lib/) 里跑 Reality.sh,
#    不许再出现"缺少 conf/lib/proto_ui.sh"
_FLAT="$TMP/flat-batch"; rm -rf "$_FLAT"; mkdir -p "$_FLAT/lib" "$_FLAT/conf"
cp "$ROOT/conf/Reality.sh" "$_FLAT/" 2>/dev/null
for _l in proto_ui.sh ports.sh addr.sh; do cp "$ROOT/conf/lib/$_l" "$_FLAT/lib/" 2>/dev/null; done
# ★ XRAY_BASE 必须一起给。这条门禁第一版只给了 XRAY_CONF_DIR —— 而协议脚本
#   当时只认 XRAY_BASE, 于是它**在生产上凭空建了一个节点** (实测: 跑一遍门禁,
#   /root/catmi/xray/conf 多出 reality-03.json)。写门禁的人踩了自己正在防的坑。
_FLAT_OUT=$(XRAY_BASE="$_FLAT" XRAY_CONF_DIR="$_FLAT/conf" XRAY_OUT_DIR="$_FLAT/out" \
            XRAY_INSTALL_DIR="$ROOT/.." X_BATCH=1 X_NO_RELOAD=1 \
            timeout 40 bash "$_FLAT/Reality.sh" add </dev/null 2>&1 || true)
if printf '%s' "$_FLAT_OUT" | grep -F '缺少 conf/lib/proto_ui.sh' >/dev/null; then
    bad "平铺目录下 Reality.sh 仍报缺少共用层"
else
    ok "平铺目录下 Reality.sh 能找到共用层 (不再拒绝继续)"
fi
rm -rf "$_FLAT"

# ⑬ 装了没有, 不能盯着一个老安装器才会写的文件
#     实测: 全新装完之后 install.sh 仍报"服务端未安装" —— 因为它判的是
#     $SRV_ROOT/config.json, 而现在写的是 conf/00-base.json。
if grep -F '[[ -f "$SRV_ROOT/config.json" ]]' "$ROOT/install.sh" >/dev/null; then
    bad "install.sh 仍用 config.json 判断装没装 → 刚装完也报未安装"
else
    ok "install.sh 按内核/conf 判断装没装 (不再盯 config.json)"
fi
# ⑭ 提示要指向**真实存在的**菜单项: 装内核在主菜单 7, 不是 1
if grep -F '进入面板后选第 1 项' "$ROOT/install.sh" >/dev/null; then
    bad "install.sh 提示点「第 1 项」→ 那是添加节点, 装内核在 7)"
else
    ok "install.sh 的安装提示指向 7) 安装 / 更新内核"
fi

# ⑤ 只给 XRAY_CONF_DIR 时, 协议脚本也必须写到那儿去
#    实测: 门禁给了 XRAY_CONF_DIR, 协议脚本只认 XRAY_BASE → 写到生产,
#    生产 conf 里凭空多出一个 reality 节点, 而屏幕上一切正常。
_SBX="$TMP/sbx-confdir"; rm -rf "$_SBX"; mkdir -p "$_SBX/conf" "$_SBX/out"
_OVR=""
for _f in Reality.sh Trojan.sh Shadowsocks.sh hysteria2.sh vlessxhttpecn.sh vlessecn.sh; do
    _v=$(XRAY_CONF_DIR="$_SBX/conf" XRAY_OUT_DIR="$_SBX/out" \
         bash -c "cd '$ROOT' && source conf/$_f >/dev/null 2>&1; printf '%s|%s' \"\$CONF_DIR\" \"\${X_IS_SANDBOX:-unset}\"" 2>/dev/null)
    case "$_v" in
        "$_SBX/conf|true") ;;
        *) _OVR="$_OVR $_f($_v)" ;;
    esac
done
if [[ -z "$_OVR" ]]; then
    ok "只给 XRAY_CONF_DIR 时, 六个协议脚本都写到那儿且认作沙箱"
else
    bad "这些脚本无视 XRAY_CONF_DIR (会写到生产)" "$_OVR"
fi
rm -rf "$_SBX"

# ⑥ 沙箱标志的判据里用到 CONF_DIR, 而脚本是 set -u —— 顺序写反就直接退出
#    实测: `CONF_DIR: unbound variable` (batch.sh 的判据被挪到赋值之前)。
#    这条只有**在 set -u 下真的 source 一遍**才看得出来, 静态看字符串是看不出的。
_ORD=""
# 只挑**可以直接 source 做这件事**的脚本: vlessxhttpecn.sh 在 source 时会往下
# 执行到别的地方 (实测 line 473: CERT_FILE: unbound variable), 那是它自己的
# 顶层级代码, 与这里的顺序问题无关 —— 拿它做这个判据只会假红。它改用静态判。
for _f in batch.sh Reality.sh Trojan.sh Shadowsocks.sh hysteria2.sh vlessecn.sh; do
    _o=$(env -u CONF_DIR -u OUT_DIR XRAY_BASE=/tmp/ordprobe bash -c \
         "set -u; cd '$ROOT' && source conf/$_f >/dev/null 2>&1; printf '%s' \"\$CONF_DIR\"" 2>&1 | tail -1)
    [[ "$_o" == "/tmp/ordprobe/conf" ]] || _ORD="$_ORD $_f($_o)"
done
if [[ -z "$_ORD" ]]; then
    ok "set -u 下六个脚本都能正常算出 CONF_DIR (判据顺序没写反)"
else
    bad "这些脚本在 set -u 下算 CONF_DIR 就挂了" "$_ORD"
fi
# vlessxhttpecn.sh: 静态查行号 —— CONF_DIR 的赋值必须早于用到它的那句
# 用 awk 自己取第一行号, 不接管道 —— `grep | head` 会让 grep 吃 SIGPIPE,
# 而那正是本套门禁里另一条规则明令禁止的写法。
_vx_conf=$(awk '/^CONF_DIR=/{print NR; exit}' "$ROOT/conf/vlessxhttpecn.sh")
_vx_use=$(awk '/\$CONF_DIR" != \/root\/catmi\/xray\/conf/{print NR; exit}' "$ROOT/conf/vlessxhttpecn.sh")
if [[ -n "$_vx_conf" && -n "$_vx_use" && "$_vx_conf" -lt "$_vx_use" ]]; then
    ok "vlessxhttpecn.sh 里 CONF_DIR 先赋值后使用"
else
    bad "vlessxhttpecn.sh 里判据用到了尚未赋值的 CONF_DIR (set -u 下直接退出)"
fi

# ⑦ 订阅里必须有**协议脚本建的节点**, 不能只有预置体系的
#    现场: 全协议建完, 汇总里每个节点都有自己的分享链接, 而订阅载荷里
#    只有预置那条路 (走 deploy 的) 的节点 —— 协议脚本建的一个都没进。
#    原因: 元数据只认 out/share/, 而协议脚本要么不写、要么把**伪装域名**
#    当成对外地址写进去 (Reality 原来给的是 --domain "$DEST", DEST=go.dev)。
if grep -F 'backfill_share_meta' "$ROOT/conf/batch.sh" >/dev/null; then
    ok "批量会补发布 (缺元数据的片段逐个 adopt)"
else
    bad "协议脚本建的节点永远不会进订阅 → 「全协议订阅」名不副实"
fi
# 补发布必须在**分离那一段之前** —— 订阅链接是在那段里建的, 补晚了那条订阅
# 就只包含"当时有元数据"的几个节点 (实测 9 个里只进了 5 个, 屏幕上看不出来)
_bk_line=$(awk '/^[[:space:]]*backfill_share_meta "/{print NR; exit}' "$ROOT/conf/batch.sh")
_split_line=$(awk '/xHTTP 上下行分离 \(/{print NR; exit}' "$ROOT/conf/batch.sh")
if [[ -n "$_bk_line" && -n "$_split_line" && "$_bk_line" -lt "$_split_line" ]]; then
    ok "补发布跑在订阅创建之前 (订阅才会覆盖全部节点)"
else
    bad "补发布跑在订阅创建之后 → 订阅里少掉协议脚本建的节点"
fi
# 伪装域名不能当对外地址
if sed -n '/--adopt/,+2p' "$ROOT/conf/Reality.sh" | grep -F 'link_ip' >/dev/null; then
    ok "Reality 补发布用的是对外入口地址, 不是伪装域名"
else
    bad "Reality 把 REALITY 伪装域名当成了节点地址 → 订阅里指向别人的服务器"
fi
# 分享元数据目录口径: 只能是 out/share (与 share_meta.py 一致)
_badshare=$(grep -nE '\$XRAY_BASE\}/share"|XRAY_BASE}/share"' "$ROOT/conf/batch.sh" 2>/dev/null || true)
if [[ -z "$_badshare" ]]; then
    ok "batch 里的分享目录口径与读取方一致 (out/share)"
else
    bad "batch 里有地方把分享目录写成了 \$XRAY_BASE/share (少一层 out/)" "$_badshare"
fi

# ⑧ 脚本里用到的变量/函数必须先有定义
#    现场: batch.sh 里 LIB_DIR 与 py 被用了多处 (补发布找 deploy.py、摘 nginx
#    找 nginx_apply.py), 却**从来没有定义过** —— 那几处的路径都是 "/deploy.py"
#    这类, 判断一律为假, 而且大多在 `|| true` / 2>/dev/null 后面, 报错被吞掉:
#    功能静默不生效, 屏幕上一切正常。
#    实测代价: "订阅里只有预置体系的节点" 与 "清空/重建时记不下要摘的 location"。
_UNDEF=""
for _f in "$ROOT"/conf/*.sh "$ROOT"/tools/*.sh; do
    [[ -f "$_f" ]] || continue
    grep -qE '\bLIB_DIR\b' "$_f" 2>/dev/null || continue
    grep -qE '^[[:space:]]*(LIB_DIR=|LIB_DIR:)' "$_f" 2>/dev/null && continue
    grep -qE 'LIB_DIR=' "$_f" 2>/dev/null && continue
    _UNDEF="$_UNDEF $(basename "$_f")"
done
if [[ -z "$_UNDEF" ]]; then
    ok "用到 LIB_DIR 的脚本都给它赋了值"
else
    bad "这些脚本用了 LIB_DIR 却没定义 (路径会变成 /deploy.py 这类)" "$_UNDEF"
fi
_UNDEF2=""
for _f in "$ROOT"/conf/*.sh; do
    grep -qE '(^|[^a-z_])py (-c|"|\$)' "$_f" 2>/dev/null || continue
    grep -qE '^[[:space:]]*py\(\)' "$_f" 2>/dev/null && continue
    _UNDEF2="$_UNDEF2 $(basename "$_f")"
done
if [[ -z "$_UNDEF2" ]]; then
    ok "用到 py 的脚本都定义了它"
else
    bad "这些脚本调了 py 却没定义 (command not found, 且常被 2>/dev/null 吞掉)" "$_UNDEF2"
fi

# ⑨ REALITY 的公钥必须能补出来
#    现场: 服务端片段里只有 privateKey 与 shortIds(列表), **没有公钥**;
#    而分享链接必须有 pbk。以前 adopt 读的是 publicKey/password —— 都不存在,
#    补出来是空串 → 那两个 REALITY 系的节点进不了订阅 (实测 10 个里漏 2 个),
#    而屏幕上一切正常 (协议脚本自己写的链接是对的, 与订阅无关)。
if grep -F '_reality_pubkey_from_private' "$ROOT/conf/lib/deploy.py" >/dev/null \
   && grep -F 'x25519' "$ROOT/conf/lib/deploy.py" >/dev/null; then
    ok "adopt 会用 x25519 由私钥推出 REALITY 公钥"
else
    bad "adopt 补不出 REALITY 公钥 → 那两个节点永远进不了订阅"
fi
if grep -F 'rs.get("shortIds")' "$ROOT/conf/lib/deploy.py" >/dev/null; then
    ok "adopt 会从 shortIds 列表里取 shortId (服务端存的是列表)"
else
    bad "adopt 没处理 shortIds 列表 → shortId 补不出来"
fi
# ★ 顺序: 老那句 `meta["short_id"] = rs.get("shortId") or ""` 在服务端片段上
#   永远是空串, 如果排在"从 shortIds 列表取"之后, 就会把它**覆盖掉** ——
#   实测就是这样 (public_key 补上了, short_id 仍是空)。
# 判据: 那句 `= rs.get("shortId") or ""` 必须落在 else 分支里 —— 否则它会
# 无条件覆盖上面从 shortIds 列表取到的值 (实测就是这样)。
_sp_block=$(sed -n '/shortId: 服务端存的是/,/meta\["fingerprint"\]/p' "$ROOT/conf/lib/deploy.py")
if printf '%s' "$_sp_block" | grep -F 'meta["short_id"] = _sids[0]' >/dev/null \
   && printf '%s' "$_sp_block" | grep -F 'else' >/dev/null; then
    ok "short_id 的取值顺序对 (列表优先, 空串那句在 else 分支里)"
else
    bad "从 shortIds 取到的 short_id 会被后面那句空串无条件覆盖"
fi

# ⑩ 补发布时的对外地址要按"这个节点怎么被访问"给
#    现场: 10 个节点只进了 1 个订阅, 两个原因都是地址给错导致的**拒发**:
#      · 直连节点给了域名 → 与协议脚本自己写的产物端点不一致, 判"不一致"拒发;
#      · nginx 档给了 IP  → 判"只绑回环外部访问不到"拒发。
#    屏幕上完全看不出来: 每个节点自己的分享链接都在, 只有订阅里是空的。
if sed -n '/^backfill_share_meta()/,/^}/p' "$ROOT/conf/batch.sh" \
     | grep -F '127.0.0.1|::1)' >/dev/null; then
    ok "补发布会按监听地址选对外地址 (直连给 IP / nginx 档给域名)"
else
    bad "补发布一刀切给地址 → 一半节点会被发布侧拒发"
fi
# --adopt 的 --tier 默认值不能强行给 cdn, 否则会覆盖 adopt 自己的判断
if grep -F 'ap.add_argument("--tier", default=None' "$ROOT/conf/lib/deploy.py" >/dev/null; then
    ok "--adopt 的 --tier 默认是 None (adopt 才能按片段自己判档位)"
else
    bad "--tier 默认写死 cdn → nginx 档节点被补成 cdn, 发布侧拒发"
fi

# ⑪ 客户端那一半会话加密必须传进 adopt
#    现场: 订阅里 REALITY 那条链接写的是 encryption=none, 而服务端要求 ML-KEM,
#    客户端连上去必然失败 ("延时测试失败 tls")。而协议脚本**自己**写的那份
#    share-NN.txt 带着正确的 encryption —— 两条生成链接的路径又漂了。
#    这一半推不出来 (由 vlessenc 成对生成), 只能由脚本递给 adopt。
if grep -F -- '--client-encryption' "$ROOT/conf/lib/deploy.py" >/dev/null \
   && grep -F 'client_encryption=a.client_encryption' "$ROOT/conf/lib/deploy.py" >/dev/null \
   && grep -F 'if client_encryption:' "$ROOT/conf/lib/deploy.py" >/dev/null; then
    ok "adopt 收得下客户端那一半会话加密 (--client-encryption)"
else
    bad "adopt 收不下客户端会话加密 → 订阅里的链接会是 encryption=none"
fi
_miss=""
for _f in Reality.sh vlessecn.sh; do
    grep -F -- '--client-encryption' "$ROOT/conf/$_f" >/dev/null || _miss="$_miss $_f"
done
if [[ -z "$_miss" ]]; then
    ok "Reality / VLESS-ECN 都会把客户端会话加密交给补发布"
else
    bad "这些脚本没把客户端会话加密交出去 → 订阅里那条链接连不上" "$_miss"
fi

# ⑫ nginx 片段必须给跨源预检放行 (客户端 Browser Dialer 要用)
#    现场: 客户端切到 xhttp 节点, Xray 在跑、配置全对, 就是上不了网;
#    Chromium 控制台原文:
#      Access to fetch at 'https://<域名>/<path>/...' from origin
#      'http://127.0.0.1:18081' has been blocked by CORS policy:
#      Response to preflight request doesn't pass access control check:
#      No 'Access-Control-Allow-Origin' header is present
#    而**服务端一个请求都没收到** —— 浏览器根本没把请求发出去。
if grep -F 'Access-Control-Allow-Origin' "$ROOT/conf/lib/nginx_apply.py" >/dev/null \
   && grep -F 'if ($request_method = OPTIONS)' "$ROOT/conf/lib/nginx_apply.py" >/dev/null; then
    ok "nginx 片段带 CORS 头与 OPTIONS 就地 204 (Browser Dialer 能跨源)"
else
    bad "nginx 片段没有 CORS 处理 → 客户端的浏览器拨号被浏览器自己拦掉"
fi
# ★ 但**不能**再给被代理的响应补一个 ACAO: xray 自己会回那个头 (它本来就支持
#   跨源), 补第二个就变成"多值 ACAO", 而浏览器对多值是直接拒绝的
#   ("contains multiple values"), 比没有还糟。实测过响应里出现两个。
# ★ 别写 `grep -c ... || echo 0`: grep -c 匹配不到时**自己会打印 0 并返回 1**,
#   `||` 再补一个就成了 "0\n0", 后面那句算术比较直接语法错误 —— 于是门禁永远
#   走 else 分支 (假红)。这个坑本套件里已经修过 5 处, 这次是我自己又写了一遍。
_cors_uncond=$(grep -c '^        L.append(f"{inner}add_header Access-Control-Allow-Origin' \
               "$ROOT/conf/lib/nginx_apply.py" 2>/dev/null) || true
_cors_uncond=${_cors_uncond:-0}
if [[ "${_cors_uncond:-0}" -eq 0 ]]; then
    ok "没有给被代理的响应重复补 ACAO (避免多值被浏览器拒绝)"
else
    bad "被代理的响应上补了第二个 ACAO → 浏览器会以'多值'拒绝"
fi

# ③e4 浏览器拨号只支持 packet-up —— 选模式时必须说出这个代价
#     内核侧依据: splithttp 的 BD 路径对 stream-up/stream-one 返回
#     "bidirectional streaming for browser dialer not implemented yet"。
#     客户端里会如实显示"不支持", 但用户会以为是面板配错了。
if sed -n '/XHTTP 的上下行模式/,/上下行模式 \[1-4/p' "$ROOT/conf/mknode.sh" \
     | grep -F '浏览器拨号' >/dev/null; then
    ok "选 xhttp mode 时说明了浏览器拨号的限制"
else
    bad "没说清 stream-up/stream-one 会让浏览器拨号不可用 → 用户以为配错了"
fi

# ③e5 客户端启动脚本在 set -e 下不能因为"取不到 sidecar"就整体退出
#     单节点模式没有 runtime/xray-gen.json, 裸赋值里的命令替换失败会让
#     set -e 直接杀掉脚本 —— 服务起不来, 日志里却一句错都没有。
if sed -n '/CTAG=\$(python3/,+1p' "$ROOT/Client/scripts/run-xray.sh" \
     | grep -F '|| CTAG=""' >/dev/null; then
    ok "客户端启动脚本对缺失的 sidecar 有兜底 (不会因 set -e 整个退出)"
else
    bad "CTAG 赋值失败会让 set -e 杀掉启动脚本 → 单节点模式服务起不来且无报错"
fi

# ③e6 ECH 必须**两段都标**, 否则链接里没有 ech= (预置表写着"默认开"却一格都没有)
if sed -n '/o\["ech"\] = (ech_on/,+1p' "$ROOT/tools/preset_batch.sh" | grep -c . >/dev/null \
   && grep -F 'o["ech"] = (ech_on == "yes")' "$ROOT/tools/preset_batch.sh" >/dev/null; then
    ok "分离预置把 ECH 标到了上行 (链接里才会有 ech=)"
else
    bad "只标了下行 dl_ech → 分享链接里没有 ech=, 而预置说明写着'默认开'"
fi

# ③e7 四个分离组合：三个能用, reality-cdn 是设计冲突, 不能在批量里悄悄建
if grep -F 'for _sp in cdn-cdn cdn-reality reality-reality; do' "$ROOT/conf/batch.sh" >/dev/null \
   && grep -F 'reality-cdn 不生成' "$ROOT/conf/batch.sh" >/dev/null; then
    ok "全协议建三个可用的分离组合, 并说明 reality-cdn 为什么不建"
else
    bad "全协议仍在建 reality-cdn (连不通) 或漏掉 reality-reality"
fi
# 分离菜单要能选到 reality-reality
if grep -F '4) SPLIT=reality-reality ;;' "$ROOT/tools/split_menu.sh" >/dev/null; then
    ok "菜单 15 能选到 reality-reality (四个组合齐)"
else
    bad "菜单 15 只有三个组合 → 用户点不到 reality-reality"
fi
# 上行是 REALITY 时, 问法不能是"Cloudflare 橙云指向这里"
if grep -F '上行 REALITY 伪装域名' "$ROOT/tools/split_menu.sh" >/dev/null; then
    ok "上行 REALITY 的域名问法跟着组合变 (不再问成 CDN 域名)"
else
    bad "上行 REALITY 仍问成 CDN 域名 → 只做 REALITY 的人被挡在门外"
fi

group "门禁自检 (没有静默跳过的检查)"
if [[ -s "$GHOST_LOG" ]]; then
    bad "门禁没有调用不存在的命令"         "$(sort -u "$GHOST_LOG" | tr '\n' ' ') —— 这些检查被静默跳过, 全绿是假的"
else
    ok "门禁没有调用不存在的命令（没有检查被静默跳过）"
fi

# ---------------------------------------------------------------- 汇总
printf '\n\033[36m═══ 结果: %d 通过, %d 失败 ═══\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
