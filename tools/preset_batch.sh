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

# 仓库里 conf/ 的位置。cdn_auto.sh 用它定位 nginx_apply.py
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/conf"

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
# CDN 自动配 nginx + 端口账本 (借鉴 sing-box-core 的 cdn_autosetup / batch_next_port)
# ★ cdn_auto.sh 与本脚本**同目录** (tools/)。我原来写 $_lib_dir/cdn_auto.sh,
#   而 _lib_dir 指的是 conf/ —— 于是 [[ -r ]] 判断一直为假, 文件从没被
#   source, 端口账本和 nginx 自动配置两个功能**都静默没生效**, 而屏幕上
#   一切正常。加载失败必须看得见。
CD_AUTO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/cdn_auto.sh"
if [[ ! -r "$CD_AUTO" ]]; then
    _y "  找不到 cdn_auto.sh, nginx 自动配置与端口账本不生效"
else
    # shellcheck source=/dev/null
    source "$CD_AUTO"
    declare -F x_cdn_autosetup >/dev/null \
        || _y "  cdn_auto.sh 加载了但函数不在 (版本不匹配?)"
fi

PORTS_SH="$(_lib ports.sh)" || exit 1
# shellcheck source=/dev/null
source "$PRESET_SH"
# shellcheck source=/dev/null
source "$PORTS_SH"

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
CONF_DIR="${XRAY_CONF_DIR:-$XRAY_BASE/conf}"
# ★ 同 conf/mknode.sh: 分享元数据目录必须与读取方一致 ($XRAY_BASE/out/share)。
#   完整说明见 conf/lib/deploy.py 文件头的「路径口径」。
SHARE_DIR="${XRAY_SHARE_DIR:-$XRAY_BASE/out/share}"

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
if [[ "${1:-}" == "--recommended" || "${1:-}" == "--default" ]]; then
    # ★ --recommended: 展开成"默认全协议"那几档 (core + cdn)。
    #
    #   这里只认 preset.sh 的档位表, 不在这里另抄一份清单 —— 两处各写一份,
    #   迟早对不上, 而对不上的后果是"菜单说会带、实际没带", 静默少几个节点。
    #
    #   注意别和本脚本原来的 tier 混淆: 原来的 tier 是**接入档**
    #   (cdn = 走 Cloudflare / nginx = 走 nginx), 这里的 core/cdn 是
    #   **推荐度**。两个都叫 tier, 所以这里只读不写, 原变量名一个字没动。
    shift
    for _p in vless trojan vmess shadowsocks hysteria2; do
        for _i in $(_p_default_indexes "$_p"); do
            printf '%s:%s ' "$_p" "$_i"
        done
    done
    echo
fi
[[ $# -eq 0 && -z "${SPECS[*]:-}" ]] && { usage; exit 1; }
[[ $# -gt 0 ]] && SPECS=("$@")

mkdir -p "$CONF_DIR" "$SHARE_DIR"

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

  # ★ 上下行分离: 档位位置写 split:<模式>, 于是 tier 里带的是模式名。
  #   xHTTP 才有"下行"这一段 —— 别的传输没有, 所以先卡住, 而不是把一个
  #   没人认的 tier 传下去 (那会生成一个普通节点, 看着成功, 但完全不是
  #   用户要的形态)。
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

  SPLIT=""; DL_DOMAIN=""; ECH_ON="no"; SPLIT_DLSEC=""
  if [[ "$tier" == split:* ]]; then
    SPLIT="${tier#split:}"
    if ! declare -F x_split_ul_sec >/dev/null; then
      _e "  $spec: 读不到分离模式表 (preset.sh 没加载?)"; fail=$((fail+1)); continue; fi
    if ! x_split_ul_sec "$SPLIT" >/dev/null 2>&1; then
      _e "  $spec: 未知分离模式 $SPLIT (可选: $(x_split_modes | tr '\n' ' '))"
      fail=$((fail+1)); continue; fi
    if [[ "$tr" != "xhttp" ]]; then
      _e "  $spec: 上下行分离只对 xhttp 有意义, $tr 没有下行这一段"
      fail=$((fail+1)); continue; fi
    # 覆盖预置里写死的安全层 (预置 ① 自己是 REALITY, 但 cdn-cdn 的上行是 TLS)
    sec=$(x_split_ul_sec "$SPLIT")
    # 监听档位由模式表给 (第 5 列)。判据是"有没有哪一段是客户端直连的":
    # 有就必须监听 0.0.0.0, 全经 nginx 才收窄到 127.0.0.1。
    # 顺带: 下行是直连时不挂 nginx —— 给它挂站点只会在 nginx 里留一段
    # 指向不存在路径的反代。
    tier=$(x_split_tier "$SPLIT")
    ECH_ON=$(x_split_ech "$SPLIT")
    _y "    $(x_split_title "$SPLIT") — $(x_split_desc "$SPLIT")"
    [[ "$ECH_ON" == yes ]] && _y "    ECH: 默认开"
  fi

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

  # 端口: 走 .batch-used 账本 (借鉴 SB 的 batch_next_port)。
  #
  # 原来这里是 `while x_port_taken; do port=$((port+1)); done`, 而 $port 每次
  # 进来都重置成 START_PORT —— 于是同形态的两个预置 (vless:4 与 vless:5 都是
  # xhttp+tls) 领到同一个端口、写出**同一个文件名**, 后者覆盖前者, 而日志
  # 两行都写"成功"。现在领过的端口记进 $XRAY_BASE/.batch-used, 换一次调用
  # 也不会重发同一个端口。
  if declare -F cd_batch_take_port >/dev/null 2>&1; then
    port=$(cd_batch_take_port) || port=$START_PORT
  else
    while x_port_taken "$port" 2>/dev/null; do port=$((port+1)); done
  fi
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

    # 上下行分离的下行地址。
    #
    # ★ 只有一个域名**不是**错误 —— 用户原话: "如果只有一个域名的情况, 这个
    #   时候其实也可以, 只是我们的配置用的是同一个域名而已。这其实就是多
    #   了一个功能, 就是两个域名。"
    #   所以默认 DL_DOMAIN 就是上行那个域名, 而 cdn-reality 这类"下行直连"
    #   的模式默认用**服务器自己的地址** (没有下行域名时, 连回同一个入口
    #   也对 —— 上下行仍然分开, 只是都从同一个地址进)。
    if [[ -n "$SPLIT" ]]; then
      SPLIT_DLSEC=$(x_split_dl_sec "$SPLIT")
      if [ "$(x_split_dl_cdn "$SPLIT")" = yes ]; then
        # 下行也走 CDN: 可以是另一个域名, 也可以就是同一个 (最常见)
        DL_DOMAIN="${X_BATCH_DL_DOMAIN:-$domain}"
        if [[ "$DL_DOMAIN" != "$domain" ]]; then
          _y "    下行域名: $DL_DOMAIN (与上行不同)"
        else
          _y "    下行域名: $DL_DOMAIN (与上行同一个 —— 上下行仍分开, 共用入口)"
        fi
      else
        # 下行直连: 用 X_BATCH_DL_ADDRESS 给的地址, 默认与上行同一个入口
        DL_DOMAIN="${X_BATCH_DL_ADDRESS:-${X_BATCH_DL_DOMAIN:-$domain}}"
        _y "    下行: 直连 $DL_DOMAIN ($SPLIT_DLSEC) —— 不挂 nginx"
      fi
    fi
  fi

  opts_json=$(python3 - "$proto" "$tr" "$sec" "$tag" "$use_port" "$tier" "$cred_json" "$extra_json" "$domain" "$SPLIT" "$DL_DOMAIN" "$ECH_ON" "${SPLIT_DLSEC:-}" "${DL_SNI:-$domain}" "${DL_PUBLIC_KEY:-${X_BATCH_REALITY_PUBLIC_KEY:-}}" "${DL_SHORT_ID:-${X_BATCH_REALITY_SHORT_ID:-}}" "${X_BATCH_SPLIT_PATH:-}" <<'PY'
import json, os, sys
# ★ import 一定要配齐: 这个 heredoc 原来只有 json, sys, 而下面用了
#   os.environ —— NameError 被 2>/dev/null 吞掉, 命令替换拿到空串,
#   表现是'规格拼装失败'或干脆静默不生成。项目在 mknode 上踩过一次
#   (交接文档 10.3), 这里又踩了一次。
proto,tr,sec,tag,port,tier,cred,extra,domain,split,dl_dom,ech_on,dlsec,dlsni,dlpub,dlsid,node_path = sys.argv[1:18]
o = {"protocol":proto,"transport":tr,"security":sec,"tag":tag,
     "port":int(port),"tier":tier}
# ★ xhttp 的 mode 必须显式给, 否则内核按 `auto` 解析 —— 而 **REALITY 下 auto
#   解析成 stream-one (上下行合流)**。这正是预置 ⑥「REALITY + XHTTP 上下行分离」
#   的说明里写着要避免的那件事: 从菜单 13 (mknode) 建出来是 stream-up,
#   从菜单 14/15 (本脚本) 建出来却变成 auto ⇒ 与说明相反, 而屏幕上一切正常。
#   实测: 同一条 vless:6, 菜单 13 给 "stream-up", 本脚本给 "auto"。
#   默认口径与 mknode.sh 对齐 (REALITY → stream-up; 其余 → auto),
#   可用 X_BATCH_XHTTP_MODE 覆盖。
# ★ 但**过 nginx 档位**例外: stream-up / stream-one 的上行是一条长连接 POST 流,
#   nginx 转发时会被卡死 (实测: 直连 200, 经 nginx/Cloudflare 必超时),
#   只有 packet-up 行得通。deploy.plan() 里还会再兜一次底并打印说明。
_mode = os.environ.get("X_BATCH_XHTTP_MODE", "").strip()
if tr == "xhttp":
    if _mode:
        o["xhttp_mode"] = _mode
    else:
        o["xhttp_mode"] = "stream-up" if sec == "reality" else "auto"
if domain: o["domain"] = domain
o.update(json.loads(cred))
o.update(json.loads(extra))

if split:
    # ★ 上下行分离要三样, 少一样就退化成"看着分离、其实合流":
    #   dl_address   下行连到哪 (域名或 IP)
    #   dl_security  下行那一段用什么加密层
    #   dl_mode      xhttp mode —— auto 在 REALITY 下会退化成 stream-one
    #               (合流), 所以**必须显式指定**; 用户以为分离了, 实际
    #               是一条连接上双工。
    # ★ 每个分离节点要**自己的** path。同一个域名上跑两个分离节点
    #   (比如 cdn-cdn 与 reality-cdn 共用下行域名) 时, nginx 一个 server
    #   只有一条 location /, 两条节点会互相覆盖 —— 流量全打到先插的端口,
    #   而节点都显示"生成成功"。
    #   path 同时也是 xHTTP 的真实路由, 一节点一个正合适。
    #   要共用 path (真要那么干) 就设 X_BATCH_SPLIT_PATH=/x。
    o["path"] = node_path or ("/%s-%s" % (split, port))
    o["dl_address"] = dl_dom
    o["dl_security"] = dlsec or sec
    o["dl_mode"] = "stream-up"
    # ★ ECH 要**两段都标**。
    #   以前只写了 dl_ech (下行), 于是:
    #     · 分享链接里没有 ech= (那个参数取的是 meta["ech"], 只有 uplink 才会写);
    #     · 预置表里写着"ECH 默认开", 而实际产物里一格 ECH 都没有 —— 屏幕上
    #       看不出来, 只有抓包才知道 ClientHello 里根本没有 65037。
    #   uplink 走 CDN 的组合 (cdn-cdn / cdn-reality), ECH 是 Cloudflare 边缘终结的,
    #   客户端要拿的是域名的 ECHConfigList —— 由 deploy.plan 从 HTTPS RR 取。
    o["ech"] = (ech_on == "yes")
    o["dl_ech"] = (ech_on == "yes")
    if (dlsec or sec) == "reality":
        # 下行 REALITY 需要自己的 serverName / 公钥 / 短 ID。
        # 优先用 dl_* 专用的, 没给就回落到上行那组 —— 上下行打同一个
        # inbound 时其实可以是同一组凭据。
        o["dl_sni"] = dlsni
        o["dl_public_key"] = dlpub
        o["dl_short_id"] = dlsid
o["split_mode"] = split if split else ""
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

# ★ 建完顺手把 CDN 站点配好 (借鉴 SB: 建完 CDN 节点自动插 nginx)。
#   放在"完成"汇总**之前**: 汇总要如实反映 nginx 到底配没配上, 放在后面
#   就成了"先报成功、再报失败"。
if [[ "$ok" -gt 0 ]] && declare -F x_cdn_autosetup >/dev/null 2>&1; then
    shopt -s nullglob
    _all=("$CONF_DIR"/*.json)
    shopt -u nullglob
    if [[ ${#_all[@]} -gt 0 ]]; then
        x_cdn_autosetup --domain "${X_BATCH_DOMAIN:-${X_BATCH_DOMAIN_BASE:-}}" "${_all[@]}" \
            || _y "  nginx 有站点没配上, 节点本身已生成"
    fi
    echo
fi

_o "════════ 完成: $ok 成功, $fail 失败 ════════"
(( ok > 0 )) && _y "  片段与分享元数据已写入 $CONF_DIR 与 $SHARE_DIR"

# ---- 自动生成/刷新订阅链接 (照 SB: 批量建完直接给一条能用的地址) ----
# 在这之前 X 不会自动建订阅 —— 用户得自己去 菜单 4 → 2) 全协议分享 点一遍。
# 失败一律不阻断: 节点本身已经建好了。
_share_sh="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/conf/share.sh"
if [[ -r "$_share_sh" ]]; then
    XRAY_BASE="$XRAY_BASE" XRAY_CONF_DIR="$CONF_DIR" XRAY_SHARE_DIR="$SHARE_DIR" \
        bash "$_share_sh" ensure-subscription 2>&1 | sed 's/^/  /' || true
else
    _y "  找不到 conf/share.sh —— 订阅链接没有自动生成"
fi
_y "  重启服务后生效: 菜单 6, 或 systemctl restart xrayls"
[[ "$fail" -eq 0 ]]
