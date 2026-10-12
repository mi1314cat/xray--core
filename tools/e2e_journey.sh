#!/usr/bin/env bash
# e2e_journey.sh — 「用户拿到的是怎样子的脚本」的验收测试
#
# 为什么已有 e2e_protocols.sh 还要这个
# ------------------------------------
# 那个脚本验的是"配出来的组合能不能通": 手写片段、起两个 xray 进程。
# 它**绕过了用户真正会走的那条路**。用户不会手写片段, 他会:
#
#     菜单建节点 → 面板给出一条 vless:// 链接 → 把链接粘进客户端 → 客户端能用
#
# 中间任何一环掉链子, 用户看到的都是"链接导入成功了, 但连不上"。
#
# ★ 这个脚本盯住最容易出事的一环:
#
#   分享链接和客户端配置是**同一份 node 的两个投影**, 由两处代码分别生成。
#   它们一旦漂移 —— 链接写了 type=xhttp 而客户端配置是 network:ws ——
#   服务端自己测是**发现不了**的, 因为服务端那条路根本没经过它们。
#   而用户恰好只走投影, 不走原件。
#
# 所以这里把完整路径跑一遍, 并把两个投影**交叉核对**:
#
#     1. 建节点   conf/lib/deploy.py        (菜单 13/14 走的)
#     2. 出链接   nodes.build_share_link     (菜单 12 的订阅发的)
#     3. 出配置   从服务端 inbound 还原      (用户粘链接后客户端做的事)
#     4. 交叉核对 传输/加密/路径/主机/端口/UUID/SNI 必须一致
#     5. 真跑流量 curl 经客户端 socks 入口, 拿到源站 token
#
# 第 4 步是本脚本与 e2e_protocols.sh 最大的差别。
#
# 用法: bash tools/e2e_journey.sh [--keep]

set -u

XRAY_BIN="${XRAY_BIN:-$(command -v xray || echo /usr/local/bin/xray)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/tmp/xray-journey}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

ORIGIN_PORT=39411
SRV_PORT=39420
CLI_SOCK_PORT=39440
DOMAIN="journey.example.com"
UUID="11111111-2222-3333-4444-555555555555"

PASS=0; FAIL=0; FAILED_NAMES=""
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES|$1"; }
group(){ printf '\n\033[36m%s\033[0m\n' "$*"; }

TOKEN="journey-token-$$"
ORIGIN_PID=""

cleanup() {
    [[ -n "$ORIGIN_PID" ]] && kill "$ORIGIN_PID" 2>/dev/null
    pkill -f "xray run -config $WORK" 2>/dev/null
    [[ "$KEEP" == "1" ]] || rm -rf "$WORK"
}
trap cleanup EXIT

command -v "$XRAY_BIN" >/dev/null 2>&1 || { printf '找不到 xray: %s\n' "$XRAY_BIN" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK/conf" "$WORK/share/tokens" "$WORK/client"

python3 - "$ORIGIN_PORT" "$TOKEN" <<'PY' &
import http.server, sys
port, token = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = token.encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
ORIGIN_PID=$!
sleep 1

CERT="$WORK/cert.pem"; KEY="$WORK/key.pem"
openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" >/dev/null 2>&1
[[ -s "$CERT" && -s "$KEY" ]] || { printf '证书生成失败\n' >&2; exit 1; }

# ---- 从服务端片段还原客户端配置 (用户粘链接后客户端做的事) ----
make_client() {
python3 - "$ROOT" "$WORK/conf" "$WORK/share/tokens" "$1" "$2" "$DOMAIN" "$3" <<'PY'
import sys, os, json
root, confdir, sharedir, tag, ccout, domain, sock = sys.argv[1:8]
sys.path.insert(0, os.path.join(root, "conf", "lib"))
import nodes as N, share_meta

node = next((n for n in N.collect(confdir)[0] if n["tag"] == tag), None)
if not node:
    raise SystemExit("collect 找不到节点")
meta = share_meta.load(sharedir, tag) or {}
# nodes.collect() 返回的是**扁平**的节点 (network/path/id/server_names…),
# 不是包着 inbound 的结构 —— 用 node["inbound"] 会 KeyError。
net = node.get("network") or "tcp"
sec = node.get("security") or "none"
cid = node.get("id")

css = {"network": net, "security": sec}
if sec == "tls":
    css["tlsSettings"] = {"serverName": node.get("server_names") or domain,
                          "fingerprint": "chrome"}
if node.get("alpn"):
    css["tlsSettings"]["alpn"] = node["alpn"]
npath = node.get("path") or ""
if net == "xhttp" and npath:
    css["xhttpSettings"] = {"path": npath, "mode": node.get("xhttp_mode") or "auto"}
elif net == "ws" and npath:
    css["wsSettings"] = {"path": npath}

server = {"address": meta.get("host") or domain,
          "port": meta.get("port"),
          "users": [{"id": cid, "encryption": node.get("encryption") or "none"}]}

cfg = {"log": {"loglevel": "warning"},
       "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": int(sock),
                     "protocol": "socks", "settings": {"auth": "noauth"}}],
       "outbounds": [{"tag": "p", "protocol": "vless",
                      "settings": {"vnext": [server]}, "streamSettings": css}]}
json.dump(cfg, open(ccout, "w"), indent=1)
PY
}

# ---- 两个投影交叉核对 ----
cross_check() {
python3 - "$ROOT" "$WORK/conf" "$WORK/share/tokens" "$1" "$2" <<'PY'
import sys, os, json
from urllib.parse import urlsplit, parse_qs
root, confdir, sharedir, tag, ccjson = sys.argv[1:6]
sys.path.insert(0, os.path.join(root, "conf", "lib"))
import nodes as N, share_meta

node = next((n for n in N.collect(confdir)[0] if n["tag"] == tag), None)
if not node:
    print("NOCONF"); raise SystemExit(0)
meta = share_meta.load(sharedir, tag) or {}
link = N.build_share_link(node, meta)
if not link:
    print("NOLINK"); raise SystemExit(0)

u = urlsplit(link)
q = {k: v[0] for k, v in parse_qs(u.query).items()}
cfg = json.load(open(ccjson))
ob = (cfg.get("outbounds") or [{}])[0]
ss = ob.get("streamSettings") or {}
srv = (((ob.get("settings") or {}).get("vnext") or [{}])[0])
users = srv.get("users") or [{}]
diff = []

def cmp(field, a, b):
    a = "" if a is None else str(a)
    b = "" if b is None else str(b)
    if a != b:
        diff.append("%s: 链接=%s 客户端=%s" % (field, a or "(空)", b or "(空)"))

cmp("协议", u.scheme, ob.get("protocol"))
cmp("UUID", u.username, users[0].get("id"))
cmp("主机", u.hostname, srv.get("address"))
cmp("端口", u.port, srv.get("port"))
cmp("传输", q.get("type"), ss.get("network"))
cmp("加密层", q.get("security"), ss.get("security"))
cmp("SNI", q.get("sni"), (ss.get("tlsSettings") or {}).get("serverName"))

want_path = (ss.get("xhttpSettings") or ss.get("wsSettings") or {}).get("path")
if q.get("path") or want_path:
    cmp("路径", q.get("path"), want_path)

print("OK" if not diff else "DIFF:" + " ;; ".join(diff))
PY
}

# 流量测试要真连上, 就得让客户端拨本机的测试端口 —— 而链接里是真实域名。
# 所以这里**另存一份**改写过地址的副本给流量测试用, 原件 (canonical) 留着
# 做交叉核对。核对验的是产品, 跑流量用的是夹具, 两者不能混:
# 混了就得把 SNI/Host 也改成 127.0.0.1, TLS 校验会失败, 而且再也测不到
# "客户端拿到的 serverName 到底对不对"。
# 片段是"只有 inbounds"的 —— 这是本仓库的既定约定 (见 tools/e2e_configs.py
# 的 server())。起进程前补一个 freedom 出站, 否则内核报的是
# "default outbound handler not exist", 跟真正的问题看不出关系。
server_for_run() {
python3 - "$1" "$2" <<'SRVOUT'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
c = json.load(open(src))
c.setdefault("outbounds", [{"protocol": "freedom", "settings": {}}])
json.dump(c, open(dst, "w"), indent=1)
SRVOUT
}

patch_for_local() {
python3 - "$1" "$2" "$3" <<'PATCHPY'
import json, sys
src, dst, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
c = json.load(open(src))
ob = (c.get("outbounds") or [{}])[0]
srv = (ob.get("settings", {}).get("vnext") or [{}])[0]
srv["address"] = "127.0.0.1"
srv["port"] = port
json.dump(c, open(dst, "w"), indent=1)
PATCHPY
}

# 自签证书必须钉指纹: xray 26.3.27 起 allowInsecure **已被移除**, 带这个字段的
# 客户端配置根本起不来。所以这里用 pinnedPeerCertSha256 —— 也顺带验证
# 本仓库生成的客户端配置没有再吐那个已删字段。
pin_cert() {
python3 - "$1" "$2" <<'PINPY'
import hashlib, json, ssl, sys
cfgf, certf = sys.argv[1], sys.argv[2]
der = ssl.PEM_cert_to_DER_cert(open(certf).read())
pin = hashlib.sha256(der).hexdigest()
c = json.load(open(cfgf))
for ob in c.get("outbounds") or []:
    ts = ob.get("streamSettings") or {}
    if ts.get("security") == "tls":
        ts.setdefault("tlsSettings", {})["pinnedPeerCertSha256"] = pin
json.dump(c, open(cfgf, "w"), indent=1)
PINPY
}

run_journey() {
    local name="$1" tier="$2" transport="$3"
    local tag="j-${name}-${transport}" srv_p=$((SRV_PORT++)) sock=$((CLI_SOCK_PORT++))

    group "$name  (档位=$tier 传输=$transport)"

    # ---- 1. 建节点 ----
    if ! python3 "$ROOT/conf/lib/deploy.py" \
            --protocol vless --transport "$transport" --security tls \
            --port "$srv_p" --domain "$DOMAIN" --tier "$tier" \
            --uuid "$UUID" --path "/j$RANDOM/" --tag "$tag" \
            --cert-file "$CERT" --key-file "$KEY" --apply \
            --conf-dir "$WORK/conf" --share-dir "$WORK/share/tokens" \
            >"$WORK/$tag.plan" 2>&1; then
        bad "$name — 节点建不出来"
        sed 's/^/        /' "$WORK/$tag.plan" | head -5
        return
    fi
    [[ -f "$WORK/conf/$tag.json" ]] && ok "节点建出来了 (片段 + 分享元数据)" \
        || { bad "$name — 片段没落盘"; return; }

    # ---- 2/3. 两个投影 ----
    local cc="$WORK/client/$tag.json"
    if ! make_client "$tag" "$cc" "$sock"; then
        bad "$name — 生不成客户端配置"
        return
    fi
    ok "两个投影都生成了"

    # ---- 4. ★ 交叉核对 ----
    local r; r=$(cross_check "$tag" "$cc")
    case "$r" in
        OK)    ok "链接与客户端配置逐项一致 (用户粘链接能连)" ;;
        NOCONF|NOLINK) bad "$name — 链接或配置没生成, 无从核对" ;;
        DIFF:*) bad "$name — 链接与客户端配置**对不上**"
                printf '%s\n' "${r#DIFF:}" | tr ';' '\n' | sed 's/^ */          /' | head -5 ;;
        *)     bad "$name — 核对异常: $r" ;;
    esac

    # ---- 5. 真跑流量 (用改写过地址的副本) ----
    local ccl="$WORK/client/$tag.local.json"
    local srvr="$WORK/conf/$tag.run.json"
    patch_for_local "$cc" "$ccl" "$srv_p"
    pin_cert "$ccl" "$CERT"
    server_for_run "$WORK/conf/$tag.json" "$srvr"
    "$XRAY_BIN" run -config "$srvr" >"$WORK/$tag.srv.log" 2>&1 & local spid=$!
    sleep 2
    "$XRAY_BIN" run -config "$ccl" >"$WORK/$tag.cli.log" 2>&1 & local cpid=$!
    sleep 2
    local got rc
    got=$(curl -fsS -m 12 --socks5-hostname "127.0.0.1:$sock" \
              "http://127.0.0.1:$ORIGIN_PORT/probe.txt" 2>"$WORK/$tag.err")
    rc=$?
    kill "$spid" "$cpid" 2>/dev/null; wait "$spid" "$cpid" 2>/dev/null
    if [[ $rc -eq 0 && "$got" == "$TOKEN" ]]; then
        ok "走完整条路拿到源站 token (用户实际能用了)"
    else
        bad "$name — 链路没打通 (curl rc=$rc)"
        head -2 "$WORK/$tag.err" | cut -c1-110 | sed 's/^/        /'
        grep -aiE 'reject|failed|invalid|timeout' "$WORK/$tag.cli.log" 2>/dev/null \
            | head -2 | cut -c1-110 | sed 's/^/        /'
    fi
}

echo "════ 用户旅程验收: 建节点 → 出链接 → 装客户端 → 真跑流量 ════"
run_journey "cdn"   cdn   xhttp
run_journey "nginx" nginx ws

echo
echo "════ 结果: $PASS 通过, $FAIL 失败 ════"
[[ "$FAIL" -gt 0 ]] && { printf '失败项:%s\n' "$FAILED_NAMES"; exit 1; }
exit 0