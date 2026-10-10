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
  # 只取函数体。扫描范围由 NGINX_CONF_ROOTS 指定 —— 函数内部走 nginx_apply.py
  # 的探测 (与插入/摘除同一口径), 不再靠 sed 替换目录字符串。
  source <(sed -n '/^check_orphan_nginx()/,/^}/p' '$ROOT/conf/node.sh')
  py() { python3 \"\$@\"; }
  info() { :; }; ok() { echo OK:\$*; }; warn() { echo WARN:\$*; }; err() { echo ERR:\$*; }
  check_orphan_nginx" 2>&1)
echo "$NO" | grep 'orphan.example.com' >/dev/null && ok "查出孤儿片段 (会报出域名)" || bad "没查出孤儿片段"
echo "$NO" | grep '502' >/dev/null && ok "告警里说明了后果 (CDN 回源 502)" || bad "告警没说清后果"
echo "$NO" | grep '没有发现' >/dev/null && bad "明明有孤儿却报'没有发现'" || ok "没有误报"
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
for proto in vless trojan vmess; do
    # 该协议的第 2 档 (vless/trojan 是 CDN 档; vmess 的第 1 档)
    sec=$(bash -c "source '$LIB/preset.sh'; x_preset_field $proto 2 2" 2>/dev/null)
    if [[ "$proto" == "vmess" ]]; then
        sec=$(bash -c "source '$LIB/preset.sh'; x_preset_field $proto 1 2" 2>/dev/null)
    fi
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
# 守的是"一键换对外地址时不能漏节点、也不能换成隧道地址"。
# share_meta.host 是分享链接与客户端配置里"连哪个地址"的唯一来源 ——
# 漏改一个就是那个节点谁都连不上, 而面板显示一切正常。
group "地址族批量切换 (share.sh)"
AF="$TMP/afam"; mkdir -p "$AF/share"
python3 - "$LIB" "$AF/share" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import share_meta
d = sys.argv[2]
for t, h in (("n1", "1.1.1.1"), ("n2", "1.1.1.1"), ("n3", "2.2.2.2")):
    share_meta.save(d, t, {"host": h, "port": 443, "name": t, "tier": "cdn"})
PY
sed -n '/^x_switch_addr_family()/,/^}/p' "$ROOT/conf/share.sh" > "$AF/fn.sh"
[[ -s "$AF/fn.sh" ]] && ok "抽到 x_switch_addr_family ($(wc -l < "$AF/fn.sh") 行)" || bad "抽不到函数"
grep -q 'x_addr6_real' "$AF/fn.sh" && ok "IPv6 走 x_addr6_real (排除隧道)" \
    || bad "IPv6 没走 addr.sh —— 会拿到 WARP 地址"
grep -q 'x_iface_public_addr' "$AF/fn.sh" && ok "IPv4 走 x_iface_public_addr" \
    || bad "IPv4 没走 addr.sh"
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
info() { :; }
ok()   { echo "OK: $*"; }
warn() { :; }
share_refresh_all() { :; }
x_addr6_real()        { echo "2001:db8::1"; }
x_iface_public_addr() { echo "9.9.9.9"; }
x_addr_family_of()    { case "$1" in *:*) echo IPv6 ;; *) echo IPv4 ;; esac; }
# shellcheck disable=SC1090
source "$FN"
x_switch_addr_family "$WANT"
SHARE_DIR="$SHARE_DIR" python3 - <<'PYP'
import glob, json, os
d = os.environ["SHARE_DIR"]
hosts = sorted({json.load(open(f)).get("host") for f in glob.glob(os.path.join(d, "*.json"))})
print("HOSTS=" + ",".join(hosts))
PYP
DRV
AFR=$(bash "$AF/drive.sh" "$AF/share" "$LIB" "$AF/fn.sh" v4 2>&1)
echo "$AFR" | grep 'HOSTS=9.9.9.9' >/dev/null && ok "v4 切换把全部节点改到目标地址" \
    || bad "v4 切换结果不对: $(echo "$AFR" | grep HOSTS || echo 无输出)"
echo "$AFR" | grep '已切换 3 个节点' >/dev/null && ok "报告了改动的节点数 (3 个)" || bad "没报告改动条数"
# 全表只有两个旧地址且都指向 1.1.1.1, 切完必须只剩一个值
echo "$AFR" | grep ',' >/dev/null && bad "切换后仍存在多个不同 host —— 有节点被漏改" \
    || ok "切换后 host 唯一 (没有漏改的节点)"

# 非法参数必须拒绝
cat > "$AF/drive2.sh" <<'DRV'
set -u
SHARE_DIR="$1"; LIB_DIR="$2"; FN="$3"
python() { command python3 "$@"; }
err()  { echo "ERR: $*"; }
info() { :; }
ok()   { :; }
warn() { :; }
share_refresh_all() { :; }
x_addr6_real()        { echo "2001:db8::1"; }
x_iface_public_addr() { echo "9.9.9.9"; }
x_addr_family_of()    { echo IPv4; }
# shellcheck disable=SC1090
# shellcheck disable=SC1090
source "$FN"
x_switch_addr_family bogus
echo "rc=$?"
DRV
AFB=$(bash "$AF/drive2.sh" "$AF/share" "$LIB" "$AF/fn.sh" 2>&1)
echo "$AFB" | grep 'rc=1' >/dev/null && ok "非法地址族返回非 0" || bad "非法地址族没被拒绝"

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
# 逐列提取不得错位。取样值随预置表调整而变 —— 这条的意图是**列对齐**,
# 不是"第 2 档必须是某个传输"。当前 vless 第 2 档是 XHTTP + TLS (CDN 推荐档,
# 见下面「预置推荐档」一组)。
TR=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 2 2" 2>/dev/null)
SE=$(bash -c "source '$LIB/preset.sh'; x_preset_field vless 2 3" 2>/dev/null)
assert_eq "$TR/$SE" "xhttp/tls" "逐列提取不错位"
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
NU=$(bash -c "source '$LIB/preset.sh'; x_preset_ask tuic </dev/null" 2>&1 | awk 'NR==1')
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
    n=$(grep -c 'mi1314cat/xray--core' "$ROOT/Client/README.md" 2>/dev/null || echo 0)
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

# ---------------------------------------------------------------- 自检
# 门禁脚本自己也会骗人: 之前有两条检查调了根本**不存在**的断言函数
# （assert_has / pass），bash 只往 stderr 丢一句 "command not found",
# 检查项既不通过也不失败 —— 看起来全绿, 其实什么都没验。
#
# 静态扫源码抓不准（本文件里嵌着一堆给别的检查用的 shell/python 片段）,
# 所以改成运行时兜: bash 找不到命令时会走 command_not_found_handle,
# 谁被静默跳过当场就记账。子 shell 里加的 FAIL 会丢, 所以落一份文件,
# 最后按文件判定。
group "门禁自检 (没有静默跳过的检查)"
if [[ -s "$GHOST_LOG" ]]; then
    bad "门禁没有调用不存在的命令"         "$(sort -u "$GHOST_LOG" | tr '\n' ' ') —— 这些检查被静默跳过, 全绿是假的"
else
    ok "门禁没有调用不存在的命令（没有检查被静默跳过）"
fi

# ---------------------------------------------------------------- 汇总
printf '\n\033[36m═══ 结果: %d 通过, %d 失败 ═══\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
