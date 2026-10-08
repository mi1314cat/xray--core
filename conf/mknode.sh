#!/usr/bin/env bash
# =============================================================
# mknode.sh — 用预置创建节点 (Xray 内核版)
#
# 为什么有这一条路径:
#   现有 7 个协议脚本各自问一堆参数, 每个都默认"最高配置"。但"最高配置"
#   不一定对当前场景 —— 要走 Cloudflare 就得用 WS, 局域网内用 SS+none 就
#   够了, 为此去读某个脚本的源码找参数名不现实。
#
#   这里反过来: 先挑一个预置 (传输 + 加密 + 为什么选它), 再问最少的问题。
#
# 落地三样产物, 且保证互相指向正确 —— 由 conf/lib/deploy.py 保证:
#   conf/<tag>.json        Xray 真正加载的
#   分享元数据             对外地址/端口/公钥
#   nginx 站点 (nginx 档)  让 CDN 回源打到正确的端口
# =============================================================

_MK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# 本脚本可能经 curl 执行 (临时文件, 同目录没有 lib/), 所以逐个按需取。
_mk_lib() {
    local name="$1" dest
    dest="$(mktemp -t "${name}.XXXXXX")"
    if ! curl -fsSL "https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/lib/$name" \
         -o "$dest"; then
        printf '\033[31m[错误] 获取 %s 失败\033[0m\n' "$name" >&2
        rm -f "$dest"
        return 1
    fi
    printf '%s' "$dest"
}

_mk_source() {
    local name="$1" f
    if [[ -r "$_MK_DIR/lib/$name" ]]; then
        source "$_MK_DIR/lib/$name"
        return 0
    fi
    f="$(_mk_lib "$name")" || return 1
    source "$f"
    _MK_TMP+=("$f")
}
_MK_TMP=()

_o() { printf '\033[34m%s\033[0m\n' "$*"; }
_g() { printf '\033[32m%s\033[0m\n' "$*"; }
_y() { printf '\033[33m%s\033[0m\n' "$*"; }
_e() { printf '\033[31m%s\033[0m\n' "$*"; }

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
CONF_DIR="${CONF_DIR:-$XRAY_BASE/configs}"
SHARE_DIR="${SHARE_DIR:-$XRAY_BASE/share/tokens}"

mk_ask_protocol() {
    _o "  可选协议:"
    local p
    while read -r p; do
        printf '    %-14s %s 个预置\n' "$p" "$(x_preset_count "$p")"
    done < <(x_preset_protocols)
    printf "  选择协议: "
    read -r p
    [[ -z "$p" ]] && return 1
    [[ "$(x_preset_count "$p")" -gt 0 ]] || { _e "  协议 $p 没有预置"; return 1; }
    printf '%s' "$p"
}

mk_ask_port() {
    local p
    read -rp "  监听端口 (回车=自动选空闲端口): " p
    if [[ -z "$p" ]]; then
        p="$(x_random_free_port 2>/dev/null)"
        [[ -z "$p" ]] && { _e "  找不到空闲端口"; return 1; }
        _o "    分配到端口 $p"
    fi
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || {
        _e "  端口不合法"; return 1; }
    if x_port_taken "$p" 2>/dev/null; then
        _y "    端口 $p 已被占用: $(x_port_holder "$p" 2>/dev/null)"
        _y "    可用: $(x_port_suggest "$p" 3 2>/dev/null | paste -sd' ' -)"
        read -rp "  换一个端口 (回车=自动): " p
        [[ -z "$p" ]] && p="$(x_random_free_port)"
    fi
    printf '%s' "$p"
}

mk_ask_tier() {
    _o "  接入方式:"
    _y "    1) CDN 直连   Xray 监听 0.0.0.0, Cloudflare 回源到端口"
    _y "    2) Nginx 转发 Xray 监听 127.0.0.1, 由 nginx 统一入口转发"
    printf "  选择 (默认1): "
    read -r c
    case "$c" in 2) printf 'nginx' ;; *) printf 'cdn' ;; esac
}

mk_ask_credential() {
    local proto="$1" v1 v2
    case "$proto" in
        vless|vmess)
            read -rp "  UUID (回车=自动生成): " v1
            [[ -z "$v1" ]] && v1="$(python3 -c 'import uuid;print(uuid.uuid4())')"
            printf '%s' "$v1" ;;
        trojan|hysteria2)
            read -rp "  密码 (回车=自动生成): " v1
            [[ -z "$v1" ]] && v1="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
            printf '%s' "$v1" ;;
        shadowsocks)
            _o "    加密方式: 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm / aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305"
            read -rp "  加密方式 (默认 2022-blake3-aes-128-gcm): " v1
            [[ -z "$v1" ]] && v1="2022-blake3-aes-128-gcm"
            read -rp "  密码 (回车=自动生成): " v2
            [[ -z "$v2" ]] && v2="$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 22)"
            printf '%s|%s' "$v1" "$v2" ;;
        socks|http)
            _y "    注意: 无认证的本地代理暴露到公网等于开放代理"
            read -rp "  认证用户名 (回车=不认证): " v1
            printf '%s' "$v1" ;;
    esac
}

mk_run() {
    _mk_source preset.sh || return 1
    _mk_source ports.sh  || return 1
    _mk_source deploy.sh 2>/dev/null || true   # 无 shell 版, 走 python

    _o "════════ 用预置创建节点 ════════"
    local proto; proto=$(mk_ask_protocol) || return 1
    echo

    # 选预置, 输出 传输/加密/显示名/说明 四行
    local picked
    picked=$(x_preset_ask "$proto") || { _y "已取消"; return 1; }
    local IFS=$'\n'
    local tr sec disp desc
    { read -r tr; read -r sec; read -r disp; read -r desc; } <<< "$picked"
    unset IFS

    _g "  已选: $disp"
    _y "        $desc"
    echo

    local port; port=$(mk_ask_port) || return 1
    local tier; tier=$(mk_ask_tier)
    echo

    local cred; cred=$(mk_ask_credential "$proto") || return 1

    # ---- 组装规格 ----
    local tag="${proto}-${tr}-${sec}-${port}"
    local domain=""
    if [[ "$sec" == "tls" ]]; then
        read -rp "  申请证书的域名: " domain
        [[ -z "$domain" ]] && { _e "  TLS 需要域名"; return 1; }
    fi

    # python 侧拼 opts, 避免在 bash 里拼 JSON (引号地狱)
    local opts_json
    opts_json=$(MK_PROTOCOL="$proto" MK_TRANSPORT="$tr" MK_SECURITY="$sec" \
                MK_TAG="$tag" MK_PORT="$port" MK_CRED="$cred" \
                MK_DOMAIN="$domain" MK_TIER="$tier" \
                python3 - <<'PY'
import json, os
proto = os.environ["MK_PROTOCOL"]; cred = os.environ.get("MK_CRED", "")
opts = {"protocol": proto, "transport": os.environ["MK_TRANSPORT"],
        "security": os.environ["MK_SECURITY"], "tag": os.environ["MK_TAG"],
        "port": int(os.environ["MK_PORT"]), "tier": os.environ["MK_TIER"]}
d = os.environ.get("MK_DOMAIN", "")
if d: opts["domain"] = d
if proto in ("vless", "vmess"):
    opts["uuid"] = cred
    if proto == "vless" and opts["security"] == "reality":
        opts["flow"] = "xtls-rprx-vision"
elif proto in ("trojan", "hysteria2"):
    opts["password"] = cred
elif proto == "shadowsocks":
    m, _, pw = cred.partition("|")
    opts["method"] = m; opts["password"] = pw
elif proto in ("socks", "http"):
    if cred: opts["auth"] = "password"
print(json.dumps(opts, ensure_ascii=False))
PY
    ) || { _e "  组装规格失败"; return 1; }

    # ---- REALITY 需要的公钥/私钥 ----
    if [[ "$sec" == "reality" ]]; then
        _y "  REALITY 需要密钥对。公钥必须与私钥配对, 且会写进分享链接。"
        read -rp "  私钥 (私钥文件路径或直接粘贴): " pk
        [[ -z "$pk" ]] && { _e "  REALITY 需要私钥"; return 1; }
        local pb
        read -rp "  公钥 (对应公钥, 分享链接要用): " pb
        [[ -z "$pb" ]] && { _e "  REALITY 需要公钥, 否则分享链接会被客户端静默丢弃"; return 1; }
        opts_json=$(MK_PK="$pk" MK_PB="$pb" python3 -c "
import json,sys
o=json.loads(sys.argv[1]); o['private_key']=os.environ['MK_PK']; o['public_key']=os.environ['MK_PB']
print(json.dumps(o,ensure_ascii=False))" "$opts_json")
    fi

    # ---- 落盘 ----
    local plan_py
    if [[ -r "$_MK_DIR/lib/deploy.py" ]]; then plan_py="$_MK_DIR/lib/deploy.py"
    else plan_py="$(_mk_lib deploy.py)" || return 1
              _MK_TMP+=("$plan_py"); fi

    python3 "$plan_py" --config-json "$opts_json" \
            --conf-dir "$CONF_DIR" --share-dir "$SHARE_DIR" 2>&1 | sed 's/^/  /'
    local rc=${PIPESTATUS[0]}
    (( rc == 0 )) && _g "  完成。菜单 6 重启服务后生效。" || _e "  未创建"
    return "$rc"
}

cleanup() { [[ ${#_MK_TMP[@]} -gt 0 ]] && rm -f "${_MK_TMP[@]}"; }
trap cleanup EXIT

[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] && mk_run