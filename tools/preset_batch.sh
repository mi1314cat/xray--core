#!/usr/bin/env bash
# 预置批量生成 —— 走 conf/mknode.sh 的 preset→deploy 链路
#
# 为什么不直接给 batch.sh 加这个能力: batch.sh 编排的是"逐个调用现有协议脚本"
# (X_BATCH=1, 各自走最高配置), 那条路径假定每个脚本自己知道该问什么、要什么。
# 预置表把"传输+加密"的选择提到统一的一层, 与单个协议脚本的交互式流程是两种
# 不同的 UX, 混进 batch.sh 会让它既不像 batch 也不像单协议脚本。
#
# 所以这里做成独立的批量入口: 一次生成多种协议×预置的节点, 全部用 deploy.py
# 落盘 (片段 + 分享元数据), 端口连续分配, 单个失败不影响其他, 收尾统一校验。
#
# 与 batch.sh 的区别:
#   batch.sh      调各协议脚本的交互式流程, 各自"最高配置", 假定直连
#   本脚本        调统一预置, 可指定 CDN/nginx 档位, 可混合多预置

set -u
_o() { printf '\033[34m%s\033[0m\n' "$*"; }
_g() { printf '\033[32m%s\033[0m\n' "$*"; }
_y() { printf '\033[33m%s\033[0m\n' "$*"; }
_e() { printf '\033[31m%s\033[0m\n' "$*"; }

_XD="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

_lib() {
  local n="$1" f="$_XD/conf/lib/$1"
  [[ -r "$f" ]] && { printf '%s' "$f"; return; }
  f="$(mktemp -t "${n}.XXXXXX")"
  curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/$n" -o "$f" \
    || { _e "获取 $n 失败"; return 1; }
  printf '%s' "$f"
}

PRESET_SH="$(_lib preset.sh)" || exit 1
DEPLOY_PY="$(_lib deploy.py)" || exit 1
PORTS_SH="$(_lib ports.sh)" || exit 1
# shellcheck source=/dev/null
source "$PRESET_SH"
# shellcheck source=/dev/null
source "$PORTS_SH"

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
CONF_DIR="${XRAY_CONF_DIR:-$XRAY_BASE/conf}"
SHARE_DIR="${XRAY_SHARE_DIR:-$XRAY_BASE/share/tokens}"

# 规范 = 协议:预置序号[:档位]   档位省略即 cdn
# 例:  "vless:1 trojan:2:nginx vless:2" → REALITY/CDN, WS+TLS/nginx, WS+TLS/CDN
SPECS=()
TIER_DEFAULT="cdn"

# ★ 这里用**带引号的** heredoc (<<'EOF'), 不是 <<EOF。
#
#   原来是 <<EOF (不引用) + 一行 `$( "${0##*/}" )/vless:3`。不引用的 heredoc
#   会做命令替换 —— 于是**打印帮助的那一下, 真的去执行了 preset_batch.sh**:
#       tools/preset_batch.sh: line 51: preset_batch.sh: command not found
#   那行本来是想写 "bash tools/preset_batch.sh vless:3", 被搜索替换成了
#   `$( "${0##*/}" )/` —— 结果既不是路径, 又会被 shell 执行。
#
#   帮助文本里**永远不要留 $(...)**: 要么照原样输出, 要么引号 heredoc。
#   引号 heredoc 里只有 $0 和协议列表需要展开, 那就单独取出来再拼。
usage() {
  local progs
  progs=$(x_preset_protocols 2>/dev/null | tr '\n' ' ')
  cat >&2 <<EOF
用法: bash <本脚本> <协议:预置序号[:档位]> ...

例:
  bash $(basename "$0") vless:1 trojan:2          # VLESS REALITY + Trojan WS (均 CDN)
  bash $(basename "$0") vless:2 trojan:2:nginx    # 走 nginx 转发
  bash $(basename "$0") vless:3                   # VLESS XHTTP+TLS

可选档位: cdn (默认) | nginx
可用协议: ${progs:-（读不到 preset.sh）}
每个协议的预置: 用 bash $(basename "$0") --list 查看
EOF
}

show_list() {
  local p
  for p in $(x_preset_protocols); do
    _o "  [$p]"
    x_preset_list "$p" 2>&1 | sed 's/^/  /'
  done
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
if [[ "${1:-}" == "--list" ]]; then show_list; exit 0; fi
[[ $# -eq 0 ]] && { usage; exit 1; }
SPECS=("$@")

mkdir -p "$CONF_DIR" "$(dirname "$SHARE_DIR")"

# 域名: TLS 节点必需 (分享链接与 nginx 配置都要用)。两种给法:
#   环境变量 X_BATCH_DOMAIN        全部 TLS 节点用同一个域名
#   环境变量 X_BATCH_DOMAIN_BASE   基础域名, 第 n 个节点用 <base>-<n>
BATCH_DOMAIN="${X_BATCH_DOMAIN:-}"
BATCH_DOMAIN_BASE="${X_BATCH_DOMAIN_BASE:-}"

START_PORT="${X_BATCH_PORT_START:-}"
if [[ -z "$START_PORT" ]]; then
  START_PORT="$(x_random_free_port 2>/dev/null)"
  [[ -z "$START_PORT" ]] && { _e "找不到起始空闲端口"; exit 1; }
fi

_o "════════ 预置批量生成 ════════"
_y "  起始端口: $START_PORT    档位默认: $TIER_DEFAULT"
[[ -n "$BATCH_DOMAIN" ]] && _y "  域名: $BATCH_DOMAIN (全部 TLS 节点共用)"
[[ -n "$BATCH_DOMAIN_BASE" ]] && _y "  域名: $BATCH_DOMAIN_BASE-<序号> (每个 TLS 节点一个)"
echo

ok=0; fail=0
port=$START_PORT
node_no=0

for spec in "${SPECS[@]}"; do
  IFS=':' read -r proto idx tier <<< "$spec"
  tier="${tier:-$TIER_DEFAULT}"

  cnt=$(x_preset_count "$proto" 2>/dev/null || echo 0)
  if [[ "$cnt" -eq 0 ]]; then
    _e "  $spec: 协议 $proto 没有预置"; fail=$((fail+1)); continue
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > cnt )); then
    _e "  $spec: 预置序号需在 1-$cnt 之间"; fail=$((fail+1)); continue
  fi

  tr=$(x_preset_field "$proto" "$idx" 2)
  sec=$(x_preset_field "$proto" "$idx" 3)
  disp=$(x_preset_field "$proto" "$idx" 4)

  # 预置表合法性由 x_preset_ask 兜底, 这里再查一次组合。
  #
  # ★ 不在这里重抄一份白名单。原来写死 `[[ "$tr" != "tcp" ]]`, 而内核的
  #   REALITY 白名单是 {raw, tcp, xhttp, grpc} (tcp 与 raw 是等价别名),
  #   预置表里 vless 第 ① 档用的正是 raw —— 于是这个脚本会把**自己表里的
  #   第一档**判成"预置表有误"并跳过, 一条节点都建不出来, 而且报错写着
  #   "预置表有误", 指向完全错误的方向。
  #   判据统一走 preset.sh 的 _preset_security_allows, 一处说了算。
  if ! _preset_security_allows "$sec" "$tr"; then
    _e "  $spec: $sec 不支持 $tr (预置表有误)"; fail=$((fail+1)); continue
  fi

  # 端口: 连续分配, 跳过已占
  while x_port_taken "$port" 2>/dev/null; do port=$((port+1)); done
  use_port=$port; port=$((port+1))

  node_no=$((node_no+1))
  tag="${proto}-${tr}-${sec}-${use_port}"

  # 凭据: 非交互自动生成
  cred_json=$(MK_PROTO="$proto" python3 - <<'PY'
import base64, json, os, uuid, secrets
p = os.environ["MK_PROTO"]
o = {}
if p in ("vless","vmess"): o["uuid"] = str(uuid.uuid4())
elif p in ("trojan","hysteria2"): o["password"] = secrets.token_urlsafe(16)
elif p == "shadowsocks":
    # SS2022 的密码必须是精确长度的 base64: aes-128 用 16 字节原文,
    # aes-256/chacha 用 32 字节。随手 token_urlsafe(16) 出来的是 22 个
    # url-safe 字符, 长度不对 —— 内核要到 run -test 才报 illegal base64。
    o["method"] = "2022-blake3-aes-128-gcm"
    o["password"] = base64.b64encode(os.urandom(16)).decode()
print(json.dumps(o))
PY
)
  creds=$(python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('uuid') or d.get('password') or '')" <<< "$cred_json")

  # REALITY 走交互: 私钥+公钥必须配对, 批量里无法自动造一对可用密钥
  extra_json="{}"
  if [[ "$sec" == "reality" ]]; then
    # 非交互时 (管道/重定向) read 不会等输入, 而是把脚本自己的 stdin
    # 剩余内容甚至下一行命令当成答案 —— 实测拿到过 "echo \"  ═══ 校验 ═══\""
    # 这种东西, 然后原样写进配置。内核报 invalid privateKey, 而配置里躺着
    # 一句 shell 片段。所以这里先判定能不能交互, 不能就明确拒绝并说清替代。
    # 环境变量优先 —— 批量场景里最常用的就是同一对密钥反复用, 与其让
    # 人每次手输, 不如给个变量。
    pk="${X_BATCH_REALITY_PRIVATE_KEY:-}"
    pb="${X_BATCH_REALITY_PUBLIC_KEY:-}"
    if [[ -n "$pk" && -n "$pb" ]]; then
      _y "  $disp 用 X_BATCH_REALITY_* 提供的密钥对"
    elif [[ ! -t 0 ]]; then
      _e "  $disp 是 REALITY, 需要交互输入密钥对, 但当前不是终端"
      _y "      设 X_BATCH_REALITY_PRIVATE_KEY 与 X_BATCH_REALITY_PUBLIC_KEY;"
      _y "      或改用菜单 15 (单个建节点) / conf/Reality.sh"
      fail=$((fail+1)); continue
    fi
    if [[ -z "$pk" || -z "$pb" ]]; then
      _y "  $disp 需要 REALITY 密钥对 —— 请输入 (留空跳过该节点)"
      read -rp "    私钥: " pk
      read -rp "    公钥: " pb
    fi
    if [[ -z "$pk" || -z "$pb" ]]; then
      _y "    跳过 (缺密钥)"; fail=$((fail+1)); continue
    fi
    # 长度与字符集先验一遍 —— 内核只说 invalid privateKey, 不会说是哪里不对
    if [[ ! "$pk" =~ ^[A-Za-z0-9_-]{40,}$ ]]; then
      _e "      私钥格式不对 (需 base64url, 43-44 字符): $pk"
      fail=$((fail+1)); continue
    fi
    if [[ ! "$pb" =~ ^[A-Za-z0-9_-]{40,}$ ]]; then
      _e "      公钥格式不对 (需 base64url, 43-44 字符): $pb"
      fail=$((fail+1)); continue
    fi
    extra_json=$(python3 -c "import json,sys;print(json.dumps({'private_key':sys.argv[1],'public_key':sys.argv[2]}))" "$pk" "$pb")
  fi

  # TLS 节点要域名。同域名会让所有节点共享 SNI, 不同域名需要分别指向同一
  # 服务器 —— 两种都常见, 所以两种给法都支持, 默认复用同域名。
  # 域名在两处真正需要: TLS 要证书, nginx 档要挂站点。REALITY 是第三处 ——
  # 它不需要证书, 但分享链接的 host 字段来自这里, 缺了 build_share_link 就
  # 返回 None, 节点能跑却分享不出去 (分享链接是它唯一的存在理由)。
  # 无加密的 CDN 档则两处都不需要。
  domain=""
  if [[ "$sec" == "tls" || "$tier" == "nginx" || "$sec" == "reality" ]]; then
    if [[ -n "$BATCH_DOMAIN" ]]; then
      domain="$BATCH_DOMAIN"
    elif [[ -n "$BATCH_DOMAIN_BASE" ]]; then
      domain="${BATCH_DOMAIN_BASE}-${node_no}"
    else
      _e "  $disp 需要域名 (TLS 要证书 / nginx 档要挂站点)。设 X_BATCH_DOMAIN 或 X_BATCH_DOMAIN_BASE"
      fail=$((fail+1)); continue
    fi
  fi

  opts_json=$(python3 - "$proto" "$tr" "$sec" "$tag" "$use_port" "$tier" "$cred_json" "$extra_json" "$domain" <<'PY'
import json, sys
proto,tr,sec,tag,port,tier,cred,extra,domain = sys.argv[1:10]
o = {"protocol":proto,"transport":tr,"security":sec,"tag":tag,
     "port":int(port),"tier":tier}
if domain: o["domain"] = domain
o.update(json.loads(cred))
o.update(json.loads(extra))
print(json.dumps(o))
PY
)

  printf "  %-28s " "$disp"
  if out=$(python3 "$DEPLOY_PY" --config-json "$opts_json" \
             --conf-dir "$CONF_DIR" --share-dir "$SHARE_DIR" --apply 2>&1); then
    _g "端口 $use_port ✓"
    ok=$((ok+1))
  else
    _e "端口 $use_port 失败"
    echo "$out" | sed 's/^/      /' >&2
    fail=$((fail+1))
  fi
done

echo
_o "════════ 完成: $ok 成功, $fail 失败 ════════"
(( ok > 0 )) && _y "  片段与分享元数据已写入 $CONF_DIR 与 $SHARE_DIR"
_y "  重启服务后生效: 菜单 6, 或 systemctl restart xrayls"
[[ "$fail" -eq 0 ]]
