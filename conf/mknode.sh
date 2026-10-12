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
    if ! curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/$name" \
         -o "$dest"; then
        printf '\033[31m[错误] 获取 %s 失败\033[0m\n' "$name" >&2
        rm -f "$dest"
        return 1
    fi
    printf '%s' "$dest"
}

# 找面板自己的内核二进制。后量子那三个子命令 (vlessenc / mlkem768 / mldsa65)
# 要用它来生成密钥对, 所以找不到可执行文件时要**说清楚为什么降级**,
# 而不是让用户以为"最高配置档"已经生效了。
_mk_xray_bin() {
    local c
    for c in "${XRAY_BIN:-}" \
             "$CONF_DIR/../xrayls" \
             "$XRAY_BASE/xrayls" \
             "$XRAY_BASE/bin/xray" \
             /usr/local/bin/xray \
             /usr/bin/xray; do
        [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
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

# ★ 一律 >&2。
#   下面每个 mk_ask_* 都是 `local p; p=$(mk_ask_xxx)` 这样用的 ——
#   命令替换会吃掉 stdout, 界面写 stdout 等于**用户什么都看不见**,
#   而 read 照样在等输入 (表现为"面板卡住了, 光标在那闪")。
_o() { printf '\033[34m%s\033[0m\n' "$*" >&2; }
_g() { printf '\033[32m%s\033[0m\n' "$*" >&2; }
_y() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
_e() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ui.sh 拉不到时的兜底 —— 远程用户不该因为少一个库就建不出节点。
# 这里只补 ui.sh 的公共接口, 样式退化成朴素编号, 交互语义不变。
if ! declare -F ui_pick >/dev/null 2>&1; then
    ui_note() { printf '  %s\n' "$1" >&2; }
    ui_pad_w() { printf '%s' "$1"; }
    ui_rule2() { printf '  ---\n' >&2; }
    ui_ask_num() {
        local p="$1" lo="$2" hi="$3" a
        while :; do
            read -r -p "  $p [$lo-$hi, 0=取消]: " a || return 1
            [[ -z "$a" || "$a" == 0 ]] && return 1
            [[ "$a" =~ ^[0-9]+$ ]] && (( a >= lo && a <= hi )) && { printf '%s' "$a"; return 0; }
            printf '  \033[31m无效选项: %s —— 范围 %s-%s\033[0m\n' "$a" "$lo" "$hi" >&2
        done
    }
    ui_pick() {
        local title="$1" empty="${2:-没有可选项}" verb="${3:-选择}"
        local -a keys=() labels=(); local k v i idx
        while IFS=$'\t' read -r k v; do
            [[ -n "$k" ]] || continue; keys+=("$k"); labels+=("$v")
        done <<< "${UI_PICK_ROWS:-}"
        if (( ${#keys[@]} == 0 )); then printf '  %s\n' "$empty" >&2; return 2; fi
        printf '  %s\n' "$title" >&2
        for (( i = 0; i < ${#keys[@]}; i++ )); do
            printf '   %2d) %s\n' "$((i+1))" "${labels[$i]}" >&2
        done
        printf '    0) 返回\n\n' >&2
        read -r -p "  $verb [1-${#keys[@]}, 0=取消]: " idx || return 1
        [[ -z "$idx" || "$idx" == 0 ]] && return 1
        [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#keys[@]} )) || { printf '  无效选项\n' >&2; return 1; }
        UI_PICK_KEY="${keys[$((idx-1))]}"; return 0
    }
fi

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
CONF_DIR="${CONF_DIR:-$XRAY_BASE/configs}"
SHARE_DIR="${SHARE_DIR:-$XRAY_BASE/share/tokens}"

mk_ask_protocol() {
    local p
    UI_PICK_COLS=(协议 预置档位 用途)
    UI_PICK_ROWS=""
    while read -r p; do
        [[ -n "$p" ]] || continue
        UI_PICK_ROWS+="$p"$'\t'"$p"$'\t'"$(x_preset_count "$p")"$'\t'"$(_mk_proto_hint "$p")"$'\n'
    done < <(x_preset_protocols)
    ui_pick "选择协议" "预置表是空的 —— 检查 conf/lib/preset.sh" "选择" || return 1
    printf '%s' "$UI_PICK_KEY"
}

# 协议行的"用途"注解 —— 让用户在编号之外还能一眼区分
_mk_proto_hint() {
    case "$1" in
        vless)   printf '抗 DPI 首选, 配 Reality' ;;
        vmess)   printf '兼容性最广, 老客户端可用' ;;
        trojan)  printf '像 TLS 一样隐蔽' ;;
        shadowsocks) printf '最简单, 性能损耗低' ;;
        hysteria2)  printf 'UDP, 弱网表现好' ;;
        tuic)    printf 'UDP + QUIC, 自带拥塞控制' ;;
        *)       printf '' ;;
    esac
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
    # ★ 原来 `*) printf 'cdn'` —— 敲错 / 敲 9 / 直接回车, 一律当"CDN"。
    #   用 ui_ask_num: 越界会重画列表问一遍, 回车才走默认 1。
    ui_note "  1) CDN 直连    Xray 监听 0.0.0.0, Cloudflare 回源到端口"
    ui_note "  2) Nginx 转发   Xray 监听 127.0.0.1, 由 nginx 统一入口转发"
    local c; c=$(ui_ask_num "接入方式" 1 2) || { printf 'cdn'; return 0; }
    [[ "$c" == "2" ]] && printf 'nginx' || printf 'cdn'
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
            # 原来把 5 个算法用顿号串成一行让用户手打 —— 敲错一个字要到
            # 内核启动失败才看得出来。编号选择, 顺带说明各自动态。
            UI_PICK_COLS=(加密方式 说明)
            UI_PICK_ROWS=""
            UI_PICK_ROWS+=$'2022-blake3-aes-128-gcm\t推荐 · SS2022, 抗探测最好, 密码需 16 字节原文\n'
            UI_PICK_ROWS+=$'2022-blake3-aes-256-gcm\tSS2022 强版, 密码需 32 字节原文\n'
            UI_PICK_ROWS+=$'aes-128-gcm\t通用, 任何客户端都支持\n'
            UI_PICK_ROWS+=$'aes-256-gcm\t通用, 更强但略慢\n'
            UI_PICK_ROWS+=$'chacha20-ietf-poly1305\t移动端 CPU 友好\n'
            ui_pick "Shadowsocks 加密方式" "" "选择" || return 1
            # ui_pick 的界面重画一次即可; 选中结果在 UI_PICK_KEY
            [[ -n "$UI_PICK_KEY" ]] && v1="$UI_PICK_KEY"
            [[ -z "$v1" ]] && v1="2022-blake3-aes-128-gcm"
            read -rp "  密码 (回车=自动生成): " v2
            # SS2022 要精确长度: aes-128 → 16 字节原文 (base64 24 字符),
            # aes-256/chacha → 32 字节 (44 字符)。截断 tr -d '/+=' 会破坏长度,
            # 内核报 illegal base64 时完全看不出是这里。
            local n=16
            case "$v1" in
                2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) n=32 ;;
                aes-256-*|chacha20-ietf-poly1305|xchacha20-ietf-poly1305) n=32 ;;
            esac
            [[ -z "$v2" ]] && v2="$(head -c "$n" /dev/urandom | base64 -w0)"
            printf '%s|%s' "$v1" "$v2" ;;
        socks|http)
            _y "    注意: 无认证的本地代理暴露到公网等于开放代理"
            read -rp "  认证用户名 (回车=不认证): " v1
            printf '%s' "$v1" ;;
    esac
}

mk_run() {
    # print.sh 要先来 —— ui.sh 的 ui_box/ui_pick 会调它的 ui_title / ui_pause
    _mk_source print.sh 2>/dev/null || true
    _mk_source ui.sh    2>/dev/null || true
    _mk_source preset.sh || return 1
    _mk_source ports.sh  || return 1
    _mk_source naming.sh 2>/dev/null || true   # 显示名（旗帜 + 前缀）
    _mk_source deploy.sh 2>/dev/null || true   # 无 shell 版, 走 python

    _o "════════ 用预置创建节点 ════════"

    # ★ 这里**不**问服务器标识。
    #   原来这里"面板问过一遍, 这里是第二道口子" —— 面板那一处早已删掉,
    #   于是每次建节点都要为一个程序本来就知道的值按一次回车; 更糟的是它会
    #   吃掉管道/PTY 的第一个输入, 后面的选择整个错位 (协议选了"1", 实际是标识)。
    #   默认值 (自动探测的旗帜 + X) 由 naming.py 生成, 想改去「节点管理 → 6)。
    #   原则: 能让程序自动获取的信息, 不要让用户手动输入。
    local proto; proto=$(mk_ask_protocol) || return 1
    echo

    # 选预置, 输出 传输/加密/显示名/说明 四行
    local picked
    picked=$(x_preset_ask "$proto") || { _y "已取消"; return 1; }
    local IFS=$'\n'
    local tr sec disp desc enh
    # 第 6 行是"加密增强"标记 (见 preset.sh)。老表没有这列时 x_preset_ask
    # 也会补一行 none, 所以这里不会少读。
    { read -r tr; read -r sec; read -r disp; read -r desc; read -r enh; } <<< "$picked"
    unset IFS
    enh="${enh:-none}"

    _g "  已选: $disp"
    _y "        $desc"
    echo

    local port; port=$(mk_ask_port) || return 1
    local tier; tier=$(mk_ask_tier)
    echo

    local cred; cred=$(mk_ask_credential "$proto") || return 1

    # ---- XHTTP 的上下行模式 (mode) ----
    #
    # ★ 这是 XHTTP 最容易被误解的一个旋钮, 所以必须让用户看见:
    #
    #   内核 dialer.go 的解析顺序:
    #       auto + 非 REALITY        -> packet-up  (上下行分开)
    #       auto + REALITY           -> stream-one  (**合流**, 不分!)
    #       stream-up                -> 上下行分开 (下行独立 GET / 上行独立 POST)
    #       packet-up                -> 上下行分开 (每个上行包一个 POST)
    #
    #   也就是说: 选了 REALITY 又不管 mode, 得到的**恰恰是不分离**的那一种。
    #   用户以为"我用了 XHTTP 所以上下行分开了", 实际上没有。
    local xhttp_mode=""
    if [[ "$tr" == "xhttp" ]]; then
        local def_m="auto"
        # REALITY + auto = 合流, 这不是用户以为的那回事 —— 默认改成 stream-up
        [[ "$sec" == "reality" ]] && def_m="stream-up"
        echo
        _y "  XHTTP 的上下行模式:"
        printf "    %s 1) stream-up    上下行分开: 下行独立 GET, 上行独立 POST (推荐)%s\n" "$_CYN" "$_RST"
        printf "    %s 2) packet-up    上下行分开, 每个上行包一个 POST (更碎, 请求更多)%s\n" "$_CYN" "$_RST"
        printf "    %s 3) stream-one   合流: 双向都走同一条 POST%s\n" "$_CYN" "$_RST"
        printf "    %s 4) auto         让内核决定%s\n" "$_CYN" "$_RST"
        if [[ "$sec" == "reality" ]]; then
            _y "        注意: REALITY 下 auto 会退化成 stream-one (合流), 所以这里默认不是 auto"
        fi
        local mc
        mc=$(ui_ask_num "上下行模式 [1-4, 回车=$def_m]" 1 4) || return 0
        case "${mc:-1}" in
            1) xhttp_mode="stream-up" ;;
            2) xhttp_mode="packet-up" ;;
            3) xhttp_mode="stream-one" ;;
            *) xhttp_mode="auto" ;;
        esac
        # 回车 = 走默认值: REALITY 下默认分离, 其余默认 auto
        [[ -z "${mc:-}" ]] && xhttp_mode="$def_m"
        _g "    上下行模式: $xhttp_mode"
    fi

    # ---- 组装规格 ----
    #
    # ★ 命名统一走 conf/lib/naming.sh, 不再各处随手拼。
    #   原来这里是 `proto-tr-sec-port` (如 vless-xhttp-tls-45630), 而协议脚本
    #   各写各的, 于是同一台机器上并存 VLESS-WS_01 / vless-xhttp01 /
    #   hysteria-01 三种形态 —— 大小写混用、`_` 与 `-` 混用、编号位数不一。
    #   后果: 按前缀筛节点写不准, 分享链接的 fragment 跟着乱, 客户端列表里
    #   认不出谁是谁; 三个内核共用一个服务器时也看不出节点归属。
    #
    #   新约定: x-<协议><两位编号>-<安全>[-CDN]  (x 前缀表明是 Xray 建的)
    local _n; _n=$(x_next_index "$proto" "$CONF_DIR" 2>/dev/null || echo 1)
    local tag; tag=$(x_node_tag "$proto" "$_n" "$sec" "$([[ "$tier" == *cdn* ]] && echo cdn)")
    local domain=""
    if [[ "$sec" == "tls" ]]; then
        read -rp "  申请证书的域名: " domain
        [[ -z "$domain" ]] && { _e "  TLS 需要域名"; return 1; }
    fi

    # ---- 加密增强: 现调内核生成成对密钥 ----
    #
    # ★ 密钥必须**在这一刻生成**, 不能预置进表里。
    #   每台服务器的密钥必须独一无二; 预置等于把一把所有用户共用的私钥
    #   写进公开仓库。
    local XBIN; XBIN=$(_mk_xray_bin)
    local mk_dec="" mldsa_seed="" mldsa_verify=""
    if [[ ",$enh," == *",mlkem,"* || "$enh" == "mlkem" ]]; then
        if [[ -n "$XBIN" ]]; then
            mk_dec=$("$XBIN" vlessenc 2>/dev/null \
                     | grep -o '"decryption"[[:space:]]*:[[:space:]]*"[^"]*"' | tail -1 | cut -d'"' -f4)
        fi
        if [[ -n "$mk_dec" ]]; then
            _g "  已生成 ML-KEM-768 会话密钥对 (xray vlessenc)"
        else
            _e "  要 ML-KEM-768 但取不到密钥对 —— 降级为普通 VLESS"
            _y "        vlessenc 需要内核 >= 26.3.27; 面板的 xrayls 太旧就没有这个子命令"
        fi
    fi
    # ★ mldsa65 **只调一次**。它每次都生成一整套新密钥 —— 分两次调 Seed 和
    #   Verify 会拿到两对**不同**的密钥, 而它们必须出自同一次生成。
    #   第一版就是这么写的, 配置能过 -test, 握手时签名对不上, 节点静默失效。
    if [[ ",$enh," == *",mldsa65,"* || "$enh" == "mldsa65" ]]; then
        local _ml=""
        [[ -n "$XBIN" ]] && _ml=$("$XBIN" mldsa65 2>/dev/null)
        mldsa_seed=$(printf '%s\n' "$_ml"   | sed -n 's/^Seed:[[:space:]]*//p'   | head -1)
        mldsa_verify=$(printf '%s\n' "$_ml" | sed -n 's/^Verify:[[:space:]]*//p' | head -1)
        if [[ -n "$mldsa_seed" && -n "$mldsa_verify" ]]; then
            _g "  已生成 ML-DSA-65 签名密钥对 (xray mldsa65)"
        else
            _e "  要 ML-DSA-65 但取不到密钥对 —— 降级为普通 REALITY"
            mldsa_seed=""; mldsa_verify=""
        fi
    fi

    # python 侧拼 opts, 避免在 bash 里拼 JSON (引号地狱)
    local opts_json
    opts_json=$(MK_PROTOCOL="$proto" MK_TRANSPORT="$tr" MK_SECURITY="$sec" \
                MK_TAG="$tag" MK_PORT="$port" MK_CRED="$cred" \
                MK_DOMAIN="$domain" MK_TIER="$tier" \
                MK_DECRYPTION="$mk_dec" MK_MLDSA_SEED="$mldsa_seed" MK_MLDSA_VERIFY="$mldsa_verify" \
                MK_XHTTP_MODE="$xhttp_mode" \
                python3 - <<'PY'
import json, os
proto = os.environ["MK_PROTOCOL"]; cred = os.environ.get("MK_CRED", "")
opts = {"protocol": proto, "transport": os.environ["MK_TRANSPORT"],
        "security": os.environ["MK_SECURITY"], "tag": os.environ["MK_TAG"],
        "port": int(os.environ["MK_PORT"]), "tier": os.environ["MK_TIER"]}
d = os.environ.get("MK_DOMAIN", "")
if d: opts["domain"] = d
# 后量子/签名密钥对 (由 mknode 在建节点那一刻用 xray vlessenc / mldsa65 生成)
_d = os.environ.get("MK_DECRYPTION", "")
if _d: opts["encryption"] = _d
_ms = os.environ.get("MK_MLDSA_SEED", "")
if _ms: opts["mldsa65_seed"] = _ms
_mv = os.environ.get("MK_MLDSA_VERIFY", "")
if _mv: opts["mldsa65_verify"] = _mv
_xm = os.environ.get("MK_XHTTP_MODE", "")
if _xm: opts["xhttp_mode"] = _xm
if proto in ("vless", "vmess"):
    opts["uuid"] = cred
    # ★ flow 只在**裸 TCP** 上加。
    #   原来是对任何 security==reality 的档位一律塞 xtls-rprx-vision,
    #   于是 reality+xhttp / reality+grpc 也带上了它。而 Vision 的意义在于
    #   "TCP 全流量直接透传", 套在 HTTP 类传输上自相矛盾 —— 内核 -test **不拦**
    #   (它只查 flow 这个名字合不合法), 于是用户拿到一个"配好了、校验通过、
    #   就是慢/连不上"的节点。sing-box 面板专门写了 sb_flow_conflict() 拦这个
    #   组合, 这里对齐。
    if (proto == "vless" and opts["security"] == "reality"
            and opts["transport"] in ("raw", "tcp")):
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
        # ★ 这里原来写的是 `import json,sys`, 下一行却用了 os.environ ——
        #   NameError, python 非零退出, 命令替换拿到**空串**, 于是 opts_json
        #   被静默清空。接着 deploy.py 报的却是:
        #       缺少必填参数: --protocol, --transport, --security
        #   看着像规格拼错了, 实际是少一个 import。而这条路径是"用预置创建
        #   REALITY 节点", 也就是说**从预置向导建 REALITY 节点从来没成功过**
        #   (面板菜单 7 的 Reality.sh 是另一条路, 所以一直没被发现)。
        local _new_opts
        _new_opts=$(MK_PK="$pk" MK_PB="$pb" python3 -c "
import json,sys,os
o=json.loads(sys.argv[1]); o['private_key']=os.environ['MK_PK']; o['public_key']=os.environ['MK_PB']
print(json.dumps(o,ensure_ascii=False))" "$opts_json") || _new_opts=""
        # 非空校验: 同理, 这类"重写整份规格"的步骤失败时必须显式报错,
        # 不能拿着空串往下走 —— 那样报错信息会指向完全无关的地方。
        if [[ -z "$_new_opts" ]]; then
            _e "  拼装 REALITY 密钥对时出错, 已中止 (没有创建任何文件)"
            return 1
        fi
        opts_json="$_new_opts"
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