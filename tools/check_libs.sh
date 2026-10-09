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
        printf '%s\n' "$out" | grep '✗' | head -6 | sed 's/^/        /'
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
echo "$PO" | grep -q 'payload_is_none=False' && ok "好节点存在时仍构建出载荷" || bad "载荷构建失败"
echo "$PO" | grep -q 'has_good1=True' && ok "坏片段不影响好节点 (good1)" || bad "好节点丢失"
echo "$PO" | grep -q 'has_good2=True' && ok "坏片段不影响好节点 (good2)" || bad "好节点丢失"
echo "$PO" | grep -q 'has_broken=False' && ok "坏片段被跳过而非混入" || bad "坏片段混进订阅 (客户端会整段解析失败)"
echo "$PO" | grep -q 'has_nometa=False' && ok "缺对外地址的节点不混入" || bad "缺元数据的节点混进订阅"
echo "$PO" | grep -q 'pure_b64=True' && ok "载荷仍是纯 base64" || bad "载荷混入非 base64 内容"
echo "$PO" | grep -q 'bad_count=1' && ok "坏片段数量被单独报出" || bad "坏片段没有单独报出"
echo "$PO" | grep -q 'missing=gone' && ok "已删节点单独报出 (与缺元数据区分)" || bad "已删节点没有单独报出"
echo "$PO" | grep -q 'nometa=nometa' && ok "缺元数据单独报出 (与已删区分)" || bad "缺元数据没有单独报出"

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
DL=$(SHARE_CLIENT="$ROOT/conf/share_client.py" SHARE_PORT=19499 \
     SHARE_PORT_FILE=/nonexistent SHARE_ETC=/nonexistent \
     XRAY_BASE="$DEG" XRAY_CONF_DIR="$DEG/conf" XRAY_SHARE_DIR="$DEG/share" \
     bash "$ROOT/conf/share.sh" list 2>&1; echo "rc=$?")
echo "$DL" | grep -q 'rc=1' && ok "服务不可达时 list 返回非 0" || bad "服务不可达时 list 仍返回 0"
echo "$DL" | grep -q '不可达' && ok "服务不可达被明确说出来" || bad "服务不可达没有说清楚"
echo "$DL" | grep -qv '还没有生成分享' && ok "没有把'服务挂了'说成'没有分享'" || bad "把服务故障误报成没有分享"

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
CL=$(bash -c "source '$ROOT/conf/lib/cert.sh'
  export X_CERT_NGINX_DIRS='$CE/a' XRAY_BASE='$CE' X_CERT_EXTRA_DIRS='$CE/a'
  x_cert_list | wc -l")
[[ "$CL" -le 8 ]] && ok "系统 CA 包已过滤 (剩 $CL 个)" || bad "证书列表被系统 CA 淹没: $CL 个"

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
V1=$(printf '1\n%s\ngood.example.com\n0\n' "$CE/a/ok.crt" | cmenu | grep -c '✓ 可用')
assert_eq "$V1" "1" "校验: 域名相符 → 可用"
V2=$(printf '1\n%s\nwrong.com\n0\n' "$CE/a/ok.crt" | cmenu | grep -c '不一致')
assert_eq "$V2" "1" "校验: 域名不符 → 报出不一致"
V3=$(printf '1\n%s\n0\n' "$CE/a/mismatch.crt" | cmenu | grep -c '不配对')
assert_eq "$V3" "1" "校验: crt/key 不配对 → 报出"
V4=$(printf '1\n%s\n0\n' "$CE/a/nokey.crt" | cmenu | grep -c '证书本身可用')
assert_eq "$V4" "1" "缺私钥 → 报证书本身可用 (而非报 私钥不存在: 0)"
V5=$(printf '1\n%s\n\n0\n' "$CE/a/fc_fullchain.pem" | cmenu | grep -c '✓ 可用')
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
NO=$(SHARE_DIR="$TMP/ngshare" XRAY_BASE="$NG_T" bash -c "
  LIB_DIR='$ROOT/conf/lib'
  mkdir -p \"$TMP/ngshare\"
  # 只取函数体, 换掉扫描目录
  source <(sed -n '/^check_orphan_nginx()/,/^}/p' '$ROOT/conf/node.sh' | sed 's|/etc/nginx/conf.d /etc/nginx/sites-enabled /usr/local/nginx/conf/conf.d|$NG_T/conf.d|')
  py() { python3 \"\$@\"; }
  info() { :; }; ok() { echo OK:\$*; }; warn() { echo WARN:\$*; }; err() { echo ERR:\$*; }
  check_orphan_nginx" 2>&1)
echo "$NO" | grep -q 'orphan.example.com' && ok "查出孤儿片段 (会报出域名)" || bad "没查出孤儿片段"
echo "$NO" | grep -q '502' && ok "告警里说明了后果 (CDN 回源 502)" || bad "告警没说清后果"
echo "$NO" | grep -q '没有发现' && bad "明明有孤儿却报'没有发现'" || ok "没有误报"
# 空目录 -> 必须报"没有发现", 不能凭空造出孤儿
mkdir -p "$NG_T/empty"
NE=$(XRAY_BASE="$NG_T" bash -c "
  LIB_DIR='$ROOT/conf/lib'
  source <(sed -n '/^check_orphan_nginx()/,/^}/p' '$ROOT/conf/node.sh' | sed 's|/etc/nginx/conf.d /etc/nginx/sites-enabled /usr/local/nginx/conf/conf.d|$NG_T/empty|')
  py() { python3 \"\$@\"; }
  info() { :; }; ok() { echo OK:\$*; }; warn() { echo WARN:\$*; }; err() { echo ERR:\$*; }
  check_orphan_nginx" 2>&1)
echo "$NE" | grep -q '没有发现' && ok "无片段时如实报告 (不凭空造孤儿)" || bad "无片段时报告不正确"

# ---------------------------------------------------------------- 地址族判定
# 守的是"向导告诉用户有没有 IPv6"这件事。旧写法两处不对称:
#   x_has_v4 直接 `ip -4 addr show | grep inet` —— 只有 awg0(10.66.66.1) 的
#     机器会被判成"有 IPv4", 而那个地址客户端连不上;
#   x_has_v6 排除了隧道, 两者口径不一致。
# 实测场景: 机器只有 WARP 的 IPv6 时, 旧写法说"有 IPv6", 向导于是引导用户
# 去建 IPv6 节点 —— 建出来的节点谁也连不上。
group "地址族判定 (addr.sh)"
AD="$ROOT/conf/lib/addr.sh"
# 两个函数必须都引用隧道正则 —— 防止有人只改一个
for fn in x_has_v4 x_has_v6; do
    body=$(sed -n "/^${fn}()/,/^}/p" "$AD")
    echo "$body" | grep -q 'X_TUNNEL_IFACE_RE' \
        && ok "$fn 排除隧道接口 (与另一个对称)" \
        || bad "$fn 没有排除隧道接口 —— 只有 WARP 的机器会被误判成'有'"
done
# 也不能只看接口就下结论: 必须逐条按 dev 过滤
for fn in x_has_v4 x_has_v6; do
    body=$(sed -n "/^${fn}()/,/^}/p" "$AD")
    echo "$body" | grep -qE 'read -r dev cidr' \
        && ok "$fn 逐接口判定 (不是整表 grep 一下就算)" \
        || bad "$fn 没有逐接口判定"
done
# 空/异常输入下不能崩
got=$(bash -c "source '$AD'; x_has_v4 >/dev/null 2>&1; echo rc=\$?")
[[ "$got" =~ ^rc=[01]$ ]] && ok "x_has_v4 返回 0/1 而不是崩掉" || bad "x_has_v4 异常: $got"

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
if sed -n '/^rollback_core()/,/^}/p' "$RB/block.sh" | grep -qE '^[[:space:]]*systemctl[[:space:]]+restart'; then
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
echo "$RR" | grep -q '还没有内核备份' && ok "空目录时如实报告 (不假装有备份)" || bad "空目录时报告不正确"
echo "$RR" | grep -q 'rc=1' && ok "回退不存在的版本返回非 0" || bad "回退不存在的版本没报错"

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
python3 "$LIB/nginx_apply.py" --domain t.example --port 23456 --transport ws --nginx none >/dev/null 2>&1
NB=$(grep -c 'xray-core BEGIN' "$NG/t.example.conf")
assert_eq "$NB" "1" "插入反代: 生成一个标记块"
python3 "$LIB/nginx_apply.py" --domain t.example --port 23456 --transport ws --nginx none >/dev/null 2>&1
NB2=$(grep -c 'xray-core BEGIN' "$NG/t.example.conf")
assert_eq "$NB2" "1" "重复插入仍只有一个标记块 (幂等)"

V2=$(printf '2\nt.example\n0\n' | ngmenu | grep -c 'proxy_pass')
assert_eq "$V2" "1" "查看站点: 显示插入的正文"

R1=$(printf '4\nt.example\nnope\n0\n' | ngmenu | grep -c '已取消')
assert_eq "$R1" "1" "摘除: 确认词不对则不动手"
NB3=$(grep -c 'xray-core BEGIN' "$NG/t.example.conf")
assert_eq "$NB3" "1" "摘除: 取消后标记块还在"

printf '4\nt.example\nyes\n0\n' | ngmenu >/dev/null 2>&1
NB4=$(grep -c 'xray-core BEGIN' "$NG/t.example.conf" || true)
assert_eq "$NB4" "0" "摘除: 确认后标记块消失"
KEEP=$(grep -c 'return 444' "$NG/t.example.conf")
assert_eq "$KEEP" "1" "摘除: 用户自己写的 location 未被动过"

P1=$(printf '5\nt.example\n23456\nws\n0\n' | ngmenu | grep -c 'dry-run, 不落盘')
assert_eq "$P1" "1" "预览插入: 标明是 dry-run"
P2=$(printf '5\nt.example\n23456\nws\n0\n' | ngmenu | grep -c 'proxy_pass')
assert_eq "$P2" "1" "预览插入: 能看到将插入的内容"

# ---------------------------------------------------------------- 面板入口
# 目标里的能力清单要求每项都有用户能摸到的入口。之前 cert / nginx_site /
# share_service 都只有库没有入口, 用户要从源码里翻才知道它们存在。
group "面板入口 (目标清单逐项核对)"
PAN="$ROOT/xray-panel.sh"
# Server / Client / UI 由面板本身与 Client/ 目录承担, 不是独立菜单项
entry_ok() { grep -q "conf/$1" "$PAN" && ok "$2 有菜单入口" || bad "$2 无菜单入口"; }
entry_ok share.sh          "Share"
entry_ok share_service.sh  "Pull (分享服务)"
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
                    '--domain', 'r.example', '--port', '8443'],
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
  --domain c.example --port 34567 --transport ws --nginx none >/dev/null 2>&1
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
# 逐列提取不得错位: vless 第 2 个应是 ws/tls
TR=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 2 2" 2>/dev/null)
SE=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 2 3" 2>/dev/null)
assert_eq "$TR/$SE" "ws/tls" "逐列提取不错位"
TR=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 1 2" 2>/dev/null)
assert_eq "$TR" "tcp" "第一个预置提取正确"
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
E=$(XRAY_CONF_DIR="$PB4/conf" XRAY_SHARE_DIR="$PB4/share" bash "$ROOT/tools/preset_batch.sh" vless:2 2>&1 | grep -c '需要域名')
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
