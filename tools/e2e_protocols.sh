#!/usr/bin/env bash
# 全协议端到端验证
#
# 验证什么
# --------
# 预置生成器能过 `xray run -test` 只说明配置被内核接受了, 不说明流量真能通。
# 这里对每一种协议/传输组合搭一条完整链路并实际请求一次:
#
#   源站 (本地 HTTP)  <-  Xray 客户端 (socks5 入口)  <-  Xray 服务端 (测试入站)
#
# curl 通过 socks 入口访问源站, 拿到源站放的那个 token 才算过。链路里任何一段
# 不通, 表现都是超时或连接重置, 而不是"配置报错" —— 这正是 -test 覆盖不到的部分。
#
# 为什么每种组合都要独立起两个进程
# ----------------------------------
# 一个进程同时装入站和出站, 两端会在同一个进程里直接握手, 配置写错也可能通。
# 拆成两个进程才能保证真的经过了 socket、TCP 和 TLS 握手。
#
# 配置由 tools/e2e_configs.py 生成。TLS 证书要塞 PEM 原文 (含换行), 用 shell
# 拼字符串必然要在转义上翻车, 交给 json.dumps 就没有这个问题。
#
# 用法: bash tools/e2e_protocols.sh [--keep]

set -u

XRAY_BIN="${XRAY_BIN:-$(command -v xray || echo /root/catmi/xray/xrayls)}"
WORK="${WORK:-/tmp/xray-e2e}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

ORIGIN_PORT=39111          # 源站 (纯 python, 不占 Xray)
SRV_PORT=39200            # 服务端入站端口, 按组合递增
CLI_SOCK_PORT=39300       # 客户端 socks 入口端口, 按组合递增

UUID="11111111-2222-3333-4444-555555555555"

PASS=0; FAIL=0; FAILED_NAMES=""

log() { printf '%s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES|$1"; }

CFG_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/e2e_configs.py"
[[ -r "$CFG_HELPER" ]] || { log "找不到 $CFG_HELPER"; exit 2; }

# gen <目标文件> <python 表达式>
# 表达式在 python 里求值。可用的名字: cfgs (配置模块)、p/sock (本用例端口)、
# CERT_PEM/KEY_PEM/CERT_PIN (证书)、U (UUID, 已带引号)。
gen() {
    local out="$1" expr="$2"
    python3 - "$CFG_HELPER" "$out" "$p" "$sock" "$CERT_PEM" "$KEY_PEM" "$CERT_PIN" "$U" \
        "$expr" <<'PY'
import importlib.util, json, sys
(helper, out, p, sock, cert, key, pin, uuid, expr) = sys.argv[1:10]
spec = importlib.util.spec_from_file_location("cfgs", helper)
cfgs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cfgs)
obj = eval(expr, {"cfgs": cfgs, "json": json,
                  "p": int(p), "sock": int(sock),
                  "CERT_PEM": cert, "KEY_PEM": key, "CERT_PIN": pin, "U": uuid})
open(out, "w").write(json.dumps(obj, ensure_ascii=False))
PY
}

# ---------------------------------------------------------------- 证书
make_certs() {
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$WORK/certs/key.pem" -out "$WORK/certs/cert.pem" \
        -days 2 -subj "/CN=e2e.test" \
        -addext "subjectAltName=DNS:e2e.test,DNS:localhost,IP:127.0.0.1" \
        >/dev/null 2>&1
    CERT_PEM=$(cat "$WORK/certs/cert.pem")
    KEY_PEM=$(cat "$WORK/certs/key.pem")
    # 客户端固定服务端证书: leaf 证书 DER 的 sha256 小写 hex, 取法与
    # hysteria2.sh / Client 探针一致。26.x 移除了 allowInsecure, 只能这么干。
    CERT_PIN=$(openssl x509 -in "$WORK/certs/cert.pem" -outform der 2>/dev/null \
               | sha256sum | awk '{print $1}')
}

# ---------------------------------------------------------------- 源站
TOKEN="E2E-OK-$(date +%s)"
start_origin() {
    mkdir -p "$WORK/www"
    printf '%s' "$TOKEN" > "$WORK/www/probe.txt"
    ( cd "$WORK/www" && exec python3 -m http.server "$ORIGIN_PORT" --bind 127.0.0.1 ) \
        >/dev/null 2>&1 &
    ORIGIN_PID=$!
    for _ in $(seq 1 40); do
        curl -fsS -m 1 "http://127.0.0.1:$ORIGIN_PORT/probe.txt" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

cleanup() {
    [[ -n "${ORIGIN_PID:-}" ]] && kill "$ORIGIN_PID" 2>/dev/null
    wait 2>/dev/null
    [[ $KEEP -eq 1 ]] || rm -rf "$WORK"
}

# ---------------------------------------------------------------- 判定
i=0
run_case() {
    local name="$1" srv="$WORK/srv.json" cli="$WORK/cli.json" got rc

    i=$((i+1))
    p=$((SRV_PORT + i)); sock=$((CLI_SOCK_PORT + i))

    gen "$srv" "$2" || { bad "$name — 配置生成失败"; return 1; }
    gen "$cli" "$3" || { bad "$name — 配置生成失败"; return 1; }

    # 先用 -test 卡一道: 配置不合法就没必要起进程
    if ! "$XRAY_BIN" run -test -c "$srv" >"$WORK/srv.test.log" 2>&1; then
        bad "$name — 服务端配置未通过 -test"
        grep -aiE 'failed|error' "$WORK/srv.test.log" | head -2 | cut -c1-240 | sed 's/^/        /'
        return 1
    fi
    if ! "$XRAY_BIN" run -test -c "$cli" >"$WORK/cli.test.log" 2>&1; then
        bad "$name — 客户端配置未通过 -test"
        grep -aiE 'failed|error' "$WORK/cli.test.log" | head -2 | cut -c1-240 | sed 's/^/        /'
        return 1
    fi

    "$XRAY_BIN" run -c "$srv" >"$WORK/srv.log" 2>&1 & local spid=$!
    "$XRAY_BIN" run -c "$cli" >"$WORK/cli.log" 2>&1 & local cpid=$!
    sleep 0.8

    kill -0 "$spid" 2>/dev/null || { bad "$name — 服务端进程起不来"; head -3 "$WORK/srv.log" | sed 's/^/        /'; kill "$cpid" 2>/dev/null; return 1; }
    kill -0 "$cpid" 2>/dev/null || { bad "$name — 客户端进程起不来"; head -3 "$WORK/cli.log" | sed 's/^/        /'; kill "$spid" 2>/dev/null; return 1; }

    got=$(curl -fsS -m 12 --socks5-hostname "127.0.0.1:$sock" \
              "http://127.0.0.1:$ORIGIN_PORT/probe.txt" 2>"$WORK/curl.err")
    rc=$?
    kill "$spid" "$cpid" 2>/dev/null; wait "$spid" "$cpid" 2>/dev/null

    if [[ $rc -eq 0 && "$got" == "$TOKEN" ]]; then
        ok "$name — 链路打通, 拿到源站 token"
        return 0
    fi
    bad "$name — 未拿到 token (curl rc=$rc)"
    [[ $rc -ne 0 ]] && head -2 "$WORK/curl.err" | cut -c1-150 | sed 's/^/        /'
    grep -aiE 'reject|failed|invalid|handshake|timeout|not exist' "$WORK/srv.log" 2>/dev/null \
        | head -2 | cut -c1-240 | sed 's/^/        srv: /'
    return 1
}

rm -rf "$WORK"; mkdir -p "$WORK/certs"
make_certs
log "源站 127.0.0.1:$ORIGIN_PORT   内核: $("$XRAY_BIN" version 2>/dev/null | head -1)"
log ""
start_origin || { log "源站起不来"; exit 1; }
trap cleanup EXIT

# U 直接给裸 UUID: 表达式在 python 里求值, 引号由 json.dumps 负责。早先按 shell
# 的习惯预先加引号, 结果 UUID 变成带引号字符的字符串, 内核按格式非法拒绝 ——
# 看起来像协议配错, 其实是引号多了一层。
U="$UUID"

# ---- 无 TLS
run_case "vless+tcp" \
 "cfgs.server('vless', p, {'network':'tcp'}, [{'id':U}])" \
 "cfgs.client('vless', sock, p, {'network':'tcp'}, [{'id':U,'encryption':'none'}])"

run_case "vmess+tcp" \
 "cfgs.server('vmess', p, {'network':'tcp'}, [{'id':U}])" \
 "cfgs.client('vmess', sock, p, {'network':'tcp'}, [{'id':U,'security':'auto'}])"

# SS2022 的密钥长度必须精确对应算法: aes-128 要 16 字节。长度不对时内核报
# decode psk: illegal base64 data, 或者更糟 —— 不报错但静默不通。
SK=$(head -c 16 /dev/urandom | base64 -w0)
run_case "shadowsocks2022+aes-128-gcm" \
 "cfgs.ss_server(p, '2022-blake3-aes-128-gcm', '$SK')" \
 "cfgs.client_ss(sock, p, '2022-blake3-aes-128-gcm', '$SK')"

# ---- VLESS + TLS 四种传输
tls_case() {
    run_case "$1" \
     "cfgs.server('vless', p, {'network':'$2'${3}}, [{'id':U${4}}], cert=CERT_PEM, key=KEY_PEM)" \
     "cfgs.client('vless', sock, p, {'network':'$2'${3}}, [{'id':U,'encryption':'none'${4}}], pin=CERT_PIN)"
}

V_FLOW=",'flow':'xtls-rprx-vision'"
tls_case "vless+tcp+tls"    "tcp"   ""                        "$V_FLOW"
tls_case "vless+ws+tls"     "ws"    ",'path':'/e2e','host':'e2e.test'" ""
tls_case "vless+grpc+tls"   "grpc"  ",'serviceName':'e2eSvc'"       ""
tls_case "vless+xhttp+tls"  "xhttp" ",'path':'/xh','host':'e2e.test','mode':'auto'" ""

# ---- Trojan 三种
trojan_case() {
    run_case "$1" \
     "cfgs.server('trojan', p, {'network':'$2'${3}}, [{'password':'TrojanPass123'}], cert=CERT_PEM, key=KEY_PEM)" \
     "cfgs.client_trojan(sock, p, {'network':'$2'${3}}, 'TrojanPass123', pin=CERT_PIN)"
}

trojan_case "trojan+tcp+tls"  "tcp"  ""
trojan_case "trojan+ws+tls"   "ws"   ",'path':'/tj','host':'e2e.test'"
trojan_case "trojan+grpc+tls" "grpc" ",'serviceName':'tjSvc'"

# ---- VMess + WS + TLS
run_case "vmess+ws+tls" \
 "cfgs.server('vmess', p, {'network':'ws','path':'/vm','host':'e2e.test'}, [{'id':U}], cert=CERT_PEM, key=KEY_PEM)" \
 "cfgs.client('vmess', sock, p, {'network':'ws','path':'/vm','host':'e2e.test'}, [{'id':U,'security':'auto'}], pin=CERT_PIN)"

# ---- VLESS + REALITY (Xray 自有)
# dest 指向一个真实可访问的 TLS 站点: REALITY 由服务端去取它的证书, serverNames
# 必须与该证书对得上, 否则握手必失败。26.3.27 的 x25519 把公钥那行标成
# "Password (PublicKey)", 只匹配 '^PublicKey:' 取不到, 于是密钥对判空、整个
# 用例被静默跳过 —— 要按"取到两行"判, 不能按"匹配到 PublicKey"判。
KEYS=$("$XRAY_BIN" x25519 2>/dev/null)
PBK=$(printf '%s\n' "$KEYS" | sed -n 's/^PrivateKey: *//p' | head -1)
PUB=$(printf '%s\n' "$KEYS" | sed -n 's/^.*PublicKey)\?: *//p' | head -1)
SID="0123456789abcdef"
if [[ -n "$PBK" && -n "$PUB" ]]; then
    run_case "vless+tcp+reality" \
     "cfgs.reality_server(p, U, '$PBK', 'www.cloudflare.com:443', ['www.cloudflare.com'], '$SID')" \
     "cfgs.reality_client(sock, p, U, '$PUB', 'www.cloudflare.com', '$SID')"
else
    bad "vless+tcp+reality — xray x25519 取不到密钥对"
fi

log ""
log "═══ 结果: $PASS 通过, $FAIL 失败 ═══"
[[ -n "$FAILED_NAMES" ]] && log "失败项:${FAILED_NAMES}"
exit $(( FAIL > 0 ? 1 : 0 ))