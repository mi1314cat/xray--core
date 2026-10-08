#!/usr/bin/env bash
# 通用能力验证套件
#
# 覆盖 conf/lib/ 下每个模块的核心契约。这些都是"看起来成功、实际静默失效"
# 高发的地方, 所以断言的不是"跑通了", 而是具体那些容易悄悄失效的性质。
#
# 用法: bash tools/check_libs.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
LIB="$ROOT/conf/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
group(){ printf '\n\033[36m%s\033[0m\n' "$*"; }

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

# ---------------------------------------------------------------- 节点注册表
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
echo "$EX" | grep -qi 'port\|端口' && ok "识别出端口冲突" || bad "识别出端口冲突"
echo "$EX" | grep -qi 'unknown field\|字段' && ok "识别出未知字段" || bad "识别出未知字段"
echo "$EX" | grep -qi 'config' && ok "识别出配置文件问题" || bad "识别出配置文件问题"
# logs.sh 各入口在无 systemd 时不得挂死
T0=$(date +%s%N)
timeout 15 bash -c "source '$ROOT/conf/logs.sh'; log_status >/dev/null 2>&1; log_explain >/dev/null 2>&1; log_lines 5 >/dev/null 2>&1"
RC=$?; MS=$(( ($(date +%s%N) - T0) / 1000000 ))
[[ "$RC" != "124" ]] && ok "无 systemd 时三个入口均正常返回 (${MS}ms)" || bad "日志入口挂死 (${MS}ms)"
for fn in log_lines log_explain log_follow log_status log_menu; do
    grep -q "^${fn}()" "$ROOT/conf/logs.sh" && ok "日志入口存在: $fn" || bad "日志入口存在: $fn"
done

# ---------------------------------------------------------------- 容器共处
group "容器感知 (cert.sh / nginx_apply.py)"
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
# 无 docker 时不得挂死
timeout 10 bash -c "source '$LIB/cert.sh'; x_cert_container_certs >/dev/null 2>&1"
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
# 逐列提取不得错位: vless 第 2 个应是 ws/tls
TR=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 2 2" 2>/dev/null)
SE=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 2 3" 2>/dev/null)
assert_eq "$TR/$SE" "ws/tls" "逐列提取不错位"
TR=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 1 2" 2>/dev/null)
assert_eq "$TR" "tcp" "第一个预置提取正确"
# 末尾空字段场景 —— read 会少给一个字段, cut 不会
OUT=$(bash -c "source '$LIB/preset.sh'; echo \"a|b||\" | cut -d'|' -f3" 2>/dev/null)
assert_eq "$OUT" "" "cut 对末尾空字段返回空串 (read 会少给一个字段)"
# 预置表里的 REALITY 组合必须与 node_build.py 的限制一致
NBREAL=$(python3 -c "import sys;sys.path.insert(0,'$LIB');import node_build as B;print('|'.join(sorted(B.SECURITY_TRANSPORTS['reality'])))")
PBAD=0
for p in vless trojan vmess shadowsocks hysteria2 socks http; do
    cnt=$(bash -c "source '$LIB/preset.sh'; x_preset_count $p" 2>/dev/null)
    for i in $(seq 1 "$cnt" 2>/dev/null); do
        t=$(bash -c "source '$LIB/preset.sh'; x_preset_field $p $i 2" 2>/dev/null)
        s2=$(bash -c "source '$LIB/preset.sh'; x_preset_field $p $i 3" 2>/dev/null)
        if [[ "$s2" == "reality" && "$t" != "tcp" ]]; then PBAD=$((PBAD+1)); fi
    done
done
assert_eq "$PBAD" "0" "预置表与 node_build 的 REALITY 限制一致"
# 无预置协议必须明确报错而非静默
NU=$(bash -c "source '$LIB/preset.sh'; x_preset_ask tuic </dev/null" 2>&1 | head -1)
[[ "$NU" == *"没有预置"* ]] && ok "无预置协议明确报错" || bad "无预置协议明确报错"

# ---------------------------------------------------------------- 预置建节点
group "预置建节点 (mknode → deploy)"
MK="$TMP/mk"; mkdir -p "$MK/conf" "$MK/share"
python3 "$LIB/deploy.py" --config-json \
  '{"protocol":"vless","transport":"ws","security":"tls","tag":"v-ws-1","port":8443,"domain":"a.com","uuid":"u1","tier":"cdn"}' \
  --conf-dir "$MK/conf" --share-dir "$MK/share" --apply >/dev/null 2>&1
python3 "$LIB/deploy.py" --config-json \
  '{"protocol":"trojan","transport":"tcp","security":"reality","tag":"t-re-1","port":8444,"domain":"a.com","password":"PW","private_key":"PK","public_key":"PUB","tier":"cdn"}' \
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

# ---------------------------------------------------------------- 预置批量
group "预置批量 (preset_batch.sh)"
PB="$TMP/pb"; mkdir -p "$PB"
XRAY_CONF_DIR="$PB/conf" XRAY_SHARE_DIR="$PB/share" X_BATCH_DOMAIN=a.example.com \
  bash "$ROOT/tools/preset_batch.sh" vless:2 trojan:3 >/dev/null 2>&1
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
  bash "$ROOT/tools/preset_batch.sh" vless:2 trojan:3 >/dev/null 2>&1
HOSTS=$(python3 -c "
import json,glob
hs=sorted(json.load(open(f))['host'] for f in glob.glob('$PB2/share/*.json'))
print(','.join(hs))")
assert_eq "$HOSTS" "b.example.com-1,b.example.com-2" "基础域名按序号递增"
# nginx 档位
PB3="$TMP/pb3"; mkdir -p "$PB3"
XRAY_CONF_DIR="$PB3/conf" XRAY_SHARE_DIR="$PB3/share" X_BATCH_DOMAIN=a.com \
  bash "$ROOT/tools/preset_batch.sh" vless:2:nginx >/dev/null 2>&1
NG=$(python3 -c "
import json,glob
d=json.load(open(sorted(glob.glob('$PB3/conf/*.json'))[0], encoding='utf-8'))
m=json.load(open(sorted(glob.glob('$PB3/share/*.json'))[0], encoding='utf-8'))
print(d['inbounds'][0]['listen'], m['port'])")
assert_eq "$NG" "127.0.0.1 443" "nginx 档: 听本机, 对外 443"
# TLS 缺域名必须明确报错
PB4="$TMP/pb4"; mkdir -p "$PB4"
E=$(XRAY_CONF_DIR="$PB4/conf" XRAY_SHARE_DIR="$PB4/share" bash "$ROOT/tools/preset_batch.sh" vless:2 2>&1 | grep -c '没给域名')
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
    ok "$(echo "$WG" | head -1)"
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
echo "$CWO" | grep -q 'x_ghost_fn' && ok "幽灵函数被点名" || bad "幽灵函数被点名"
# 可达函数绝不能出现在幽灵名单里 —— 误报比漏报更烦人, 会逼人去删活代码
if echo "$CWO" | grep '幽灵:' | grep -q 'x_reachable_fn'; then
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

# ---------------------------------------------------------------- 汇总
printf '\n\033[36m═══ 结果: %d 通过, %d 失败 ═══\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
