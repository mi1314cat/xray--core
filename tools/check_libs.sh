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

# ---------------------------------------------------------------- 服务
group "服务管理 (service.sh)"
RC=$(bash -c "source '$LIB/service.sh'; x_svc_resolve >/dev/null; echo \$X_SVC_RESOLVED" 2>/dev/null)
[[ "$RC" == "1" || "$RC" == "2" ]] && ok "服务名探测返回明确状态 (1=找到 2=没有)" || bad "服务名探测 ($RC)"
T0=$(date +%s%N)
bash -c "source '$LIB/service.sh'; x_svc_resolve >/dev/null; x_svc_status_text >/dev/null; x_svc_installed || true" >/dev/null 2>&1
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
[[ "$MS" -lt 3000 ]] && ok "完整探测耗时 ${MS}ms (<3s, 无 systemd 时不卡死)" || bad "完整探测耗时 ${MS}ms 过长"

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
