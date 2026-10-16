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

# ================================================================ 证书方案
#
# 照 sing-box-core 的 sb_ask_cert 的形状设计 (学交互与流程, 不抄配置):
#
#     证书方案：
#       1) 扫描本机已有证书 (certbot/acme/nginx; CA 可信)
#       2) 手动输入路径
#       3) 生成自签 (200 天, 客户端经 pin 锁定)
#
# 三条路都通往"能建出节点", 且每条都把**代价**写在屏幕上:
# 真证书=任何客户端都能连; 自签=只有支持 pin 的客户端能连。
#
# 为什么必须这样: 原来 X 只有"找到就带、找不到就拒绝", 于是**没有证书的
# 机器完全建不出 TLS 节点**。SB 的设计是每一条失败路径都有下一步。
#
# 输出 (全局): MK_CERT_FILE / MK_CERT_KEY / MK_CERT_DOMAIN / MK_CERT_TRUSTED
MK_CERT_FILE=""; MK_CERT_KEY=""; MK_CERT_DOMAIN=""; MK_CERT_TRUSTED=""

_mk_ask_cert_scheme() {
    MK_CERT_FILE=""; MK_CERT_KEY=""; MK_CERT_DOMAIN=""; MK_CERT_TRUSTED=""

    # 环境变量直给 (脚本化 / 复用已有证书)
    if [[ -n "${XRAY_NODE_CERT:-}" ]]; then
        local k="${XRAY_NODE_CERT_KEY:-}"
        [[ -n "$k" ]] || k=$(x_cert_key_for "$XRAY_NODE_CERT" 2>/dev/null) || k=""
        if [[ -f "$k" ]]; then
            MK_CERT_FILE="$XRAY_NODE_CERT"; MK_CERT_KEY="$k"
            MK_CERT_DOMAIN=$(x_cert_domain "$XRAY_NODE_CERT" 2>/dev/null)
            x_cert_trusted "$XRAY_NODE_CERT" && MK_CERT_TRUSTED="yes" || MK_CERT_TRUSTED="no"
            _g "  证书 (来自 XRAY_NODE_CERT): $MK_CERT_FILE"
            return 0
        fi
        _e "  XRAY_NODE_CERT 没有可用私钥: ${XRAY_NODE_CERT}"
        return 1
    fi

    local ncert=0
    declare -F x_cert_list_domains >/dev/null 2>&1 && \
        ncert=$(x_cert_list_domains 2>/dev/null | grep -c . )
    echo >&2
    _y "  证书方案 —— 这个节点用什么证书对外服务:"
    if (( ncert > 0 )); then
        printf "    %s 1) 扫描本机已有证书%s (检测到 %s 张 CA 可信证书)\n" "$_CYN" "$_RST" "$ncert" >&2
    else
        printf "    %s 1) 扫描本机已有证书%s  —— 本机没检测到任何证书\n" "$_CYN" "$_RST" >&2
    fi
    printf "    %s 2) 手动输入路径%s (crt / key)\n" "$_CYN" "$_RST" >&2
    printf "    %s 3) 生成自签证书%s (200 天; 客户端用 pin 锁定)\n" "$_CYN" "$_RST" >&2
    printf "    真证书 = 任何客户端都能连; 自签 = 只有支持 pin 的客户端能连\n" >&2

    local c=""
    if [[ "${X_BATCH:-0}" == "1" || ! -t 0 ]]; then
        c=$(( ncert > 0 )) && c=1 || c=3
        _o "  非交互: 证书方案 = $c"
    else
        read -rp "  选择 [1-3, 回车=1]: " c || c=""
        c="${c:-1}"
    fi
    case "$c" in
        2) _mk_ask_cert_manual ;;
        3) _mk_ask_cert_selfgen ;;
        *) _mk_ask_cert_scan ;;
    esac
}

# 方案 1: 扫描并挑选。一项都没有时**自动退到自签**, 不把用户堵在这里。
_mk_ask_cert_scan() {
    local rows
    rows=$(x_cert_list_domains 2>/dev/null)
    if [[ -z "$rows" ]]; then
        _y "  本机没检测到任何证书, 改用自签 (客户端用 pin 锁定)"
        _mk_ask_cert_selfgen
        return $?
    fi
    local -a doms=() crts=() keys=() marks=()
    local d f k m
    while IFS=$'\t' read -r d f k m; do
        doms+=("$d"); crts+=("$f"); keys+=("$k"); marks+=("$m")
    done <<< "$rows"
    echo >&2
    # ★ 逐行打印时**先把数组元素取进普通变量**再用。
    #   原来写的是 "${marks[$i]:+[$marks[$i]] }" —— ${var:+word} 里的
    #   `$marks[$i]` 没有花括号, bash 读成"$marks 的值"再接字面量 "[$i]",
    #   于是屏幕上出现的是 "[[2]]" 这种谁也不认识的东西, 而域名的列宽
    #   也被它挤歪。实测 (RN): 第三行渲染成 `localhost  [[2]] /home/web/...key`。
    local i _d _k _m
    for (( i=0; i<${#doms[@]}; i++ )); do
        _d="${doms[$i]}"; _k="${keys[$i]}"; _m="${marks[$i]}"
        [[ -n "$_k" ]] || _m="${_m:-缺私钥}"
        printf "    %2d) %-34s %s\n" "$((i+1))" "$_d" "${_m:+[$_m]}" >&2
    done
    printf "    %2d) 手动输入路径\n" "$(( ${#doms[@]}+1 ))" >&2
    printf "    %2d) 生成自签\n" "$(( ${#doms[@]}+2 ))" >&2
    echo >&2
    local pick=""
    read -rp "  选择 [1-$((${#doms[@]}+2)), 回车=1]: " pick || pick=""
    pick="${pick:-1}"
    if [[ "$pick" == "$(( ${#doms[@]}+1 ))" ]]; then
        _mk_ask_cert_manual; return $?
    fi
    if [[ "$pick" == "$(( ${#doms[@]}+2 ))" ]]; then
        _mk_ask_cert_selfgen; return $?
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#doms[@]} )); then
        _e "  选择无效"; return 1
    fi
    local idx=$((pick-1))
    if [[ -z "${keys[$idx]}" ]]; then
        _e "  ${crts[$idx]} 没有对应私钥 —— 换个证书, 或走方案 3 (自签)"
        return 1
    fi
    if ! x_cert_not_expired "${crts[$idx]}"; then
        _y "  ${crts[$idx]} 已过期 (或 24 小时内到期)"
        _mk_ask_cert_selfgen; return $?
    fi
    MK_CERT_FILE="${crts[$idx]}"; MK_CERT_KEY="${keys[$idx]}"
    MK_CERT_DOMAIN="${doms[$idx]}"
    _o "    证书: $MK_CERT_FILE"
    _o "    私钥: $MK_CERT_KEY"
    x_cert_trusted "$MK_CERT_FILE" && MK_CERT_TRUSTED="yes" || MK_CERT_TRUSTED="no"
    _g "  证书: $MK_CERT_DOMAIN ($MK_CERT_FILE)"
    [[ "$MK_CERT_TRUSTED" == "yes" ]] || _y "  这是自签证书 —— 客户端需要 pin 才能连"
    return 0
}

# 方案 2: 手动路径。路径无效时不直接失败, 退到自签 (SB 的做法)。
_mk_ask_cert_manual() {
    local f k
    read -rp "  crt 路径: " f || f=""
    read -rp "  key 路径: " k || k=""
    f="${f// /}"; k="${k// /}"
    if [[ ! -f "$f" ]]; then
        _y "  证书路径无效, 改用自签"
        _mk_ask_cert_selfgen; return $?
    fi
    [[ -n "$k" && -f "$k" ]] || k=$(x_cert_key_for "$f" 2>/dev/null) || k=""
    if [[ -z "$k" || ! -f "$k" ]]; then
        _y "  没找到对应私钥, 改用自签"
        _mk_ask_cert_selfgen; return $?
    fi
    if ! x_cert_not_expired "$f"; then
        _y "  证书已过期, 改用自签"
        _mk_ask_cert_selfgen; return $?
    fi
    MK_CERT_FILE="$f"; MK_CERT_KEY="$k"
    MK_CERT_DOMAIN=$(x_cert_domain "$f" 2>/dev/null)
    [[ -n "$MK_CERT_DOMAIN" ]] || MK_CERT_DOMAIN="$(basename "${f%.crt}")"
    x_cert_trusted "$f" && MK_CERT_TRUSTED="yes" || MK_CERT_TRUSTED="no"
    _g "  证书: $MK_CERT_DOMAIN ($MK_CERT_FILE)"
    return 0
}

# 方案 3: 自签。伪装域名向用户确认 —— 它会明文出现在握手与分享链接里。
_mk_ask_cert_selfgen() {
    local d=""
    declare -F x_cert_camo_domain >/dev/null 2>&1 && d=$(x_cert_camo_domain 2>/dev/null)
    [[ -z "$d" ]] && d="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8).com"
    _y "  自签证书的伪装域名: $d"
    _o "    (它会明文出现在 TLS 握手与分享链接里, 所以借一个真实大站的域名)"
    local inp=""
    read -rp "  伪装域名 [回车=$d]: " inp || inp=""
    [[ -n "${inp// /}" ]] && d="${inp// /}"
    local pair
    pair=$(x_cert_selfgen "$d") || { _e "  自签证书生成失败 (openssl 在不在?)"; return 1; }
    MK_CERT_FILE="${pair%%$'\t'*}"
    MK_CERT_KEY="${pair#*$'\t'}"
    MK_CERT_DOMAIN="$d"
    MK_CERT_TRUSTED="no"
    _g "  自签证书已生成: $MK_CERT_FILE"
    _o "    客户端需要 pin (Xray 的 pinnedPeerCertSha256) 才能连 —— 已写进产物"
    return 0
}

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
# ★ 路径口径必须与全项目一致 —— 这两行曾经是 $XRAY_BASE/configs 与
#   $XRAY_BASE/share/tokens, 而内核 -confdir 读的是 $XRAY_BASE/conf、
#   分享载荷读的是 $XRAY_BASE/out/share。后果是**菜单 13 建的节点内核
#   根本不加载、且拿不到分享链接**, 而屏幕上一路 [OK]。
#   口径的完整说明见 conf/lib/deploy.py 文件头的「路径口径」。
CONF_DIR="${XRAY_CONF_DIR:-${CONF_DIR:-$XRAY_BASE/conf}}"
SHARE_DIR="${XRAY_SHARE_DIR:-${SHARE_DIR:-$XRAY_BASE/out/share}}"

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
    # cert.sh = 证书查找 (x_cert_find_for_domain / x_cert_search_dirs)。
    # ★ TLS 档必须加载它: 建 TLS 节点时要给入站配一对证书, 否则内核启动成功
    #   但每次握手都失败 (tls: no certificates configured)。加载不到时
    #   x_cert_find_for_domain 会是未定义命令 —— 所以下面的调用点必须
    #   先 declare -F 判存在, 不能直接调。
    _mk_source cert.sh  2>/dev/null || true
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
        # 默认档换成**编号** —— ui_ask_num 只认数字, 提示里也就不能再写
        # "回车=auto" (那是与真实行为相反的说明), 见下面的注释。
        local def_m="auto" def_i=4
        # REALITY + auto = 合流, 这不是用户以为的那回事 —— 默认改成 stream-up
        [[ "$sec" == "reality" ]] && { def_m="stream-up"; def_i=1; }
        # nginx 档位下 stream-up / stream-one 一律过不去 (实测), 只有 packet-up 行。
        # 默认直接落在 packet-up 上, 别让用户先选错再被"自动纠正"。
        if [[ "$tier" == *nginx* ]]; then def_m="packet-up"; def_i=2; fi
        echo
        _y "  XHTTP 的上下行模式:"
        printf "    %s 1) stream-up    上下行分开: 下行独立 GET, 上行独立 POST (推荐)%s\n" "$_CYN" "$_RST"
        printf "    %s 2) packet-up    上下行分开, 每个上行包一个 POST (更碎, 请求更多)%s\n" "$_CYN" "$_RST"
        printf "    %s 3) stream-one   合流: 双向都走同一条 POST%s\n" "$_CYN" "$_RST"
        printf "    %s 4) auto         让内核决定%s\n" "$_CYN" "$_RST"
        if [[ "$sec" == "reality" ]]; then
            _y "        注意: REALITY 下 auto 会退化成 stream-one (合流), 所以这里默认不是 auto"
        fi
        if [[ "$tier" == *nginx* ]]; then
            _y "        注意: 过 nginx/CDN 时 stream-up 与 stream-one 都必失败 (上行是长连接 POST 流,"
            _y "              会被 nginx 卡住; 实测直连可用、经 nginx/Cloudflare 超时), 默认已选 packet-up。"
            _y "              选了别的也会在生成时自动改成 packet-up。"
        fi
        # ★ 这里原来是:
        #      mc=$(ui_ask_num "上下行模式 [1-4, 回车=$def_m]" 1 4) || return 0
        #   两个缺陷叠在一起:
        #   ① 提示写「回车=$def_m」(auto), 而 ui_ask_num 回车一律 return 1
        #      (= 取消) —— 提示与真实行为**相反**;
        #   ② `|| return 0` 让 mknode 以**成功**退出, 于是节点没建成、一句错都
        #      不报就回到菜单。用户只会以为自己点错了。
        #   现在默认值交给 ui_ask_num 的第 4 个参数, 回车就是真的取默认值。
        local mc
        mc=$(ui_ask_num "上下行模式" 1 4 "$def_i") || { _y "  已取消, 没有创建任何文件"; return 1; }
        case "$mc" in
            1) xhttp_mode="stream-up" ;;
            2) xhttp_mode="packet-up" ;;
            3) xhttp_mode="stream-one" ;;
            *) xhttp_mode="auto" ;;
        esac
        _g "    上下行模式: $xhttp_mode"
    fi

    # ---- ECH: 独立可选项 ----
    #
    # ★ 为什么独立问, 而不是跟着预置⑤走:
    #   预置⑤ 把 "ECH" 和 "后量子 (ML-KEM)" 绑在一起。而实测 mihomo v1.19.32
    #   直接拒绝 Xray 的 VLESS 会话加密串 (invaild vless encryption value,
    #   整份配置都不加载) —— 于是"想用 ECH"的 mihomo 用户点⑤ 反而什么都拿不到。
    #   ECH 和会话加密是**两层**, 本来就该分开选。
    #
    # ★ 只在 TLS 档问: ECH 是 TLS 层的东西, REALITY 有自己的机制(不需要也不兼容)。
    local mk_ech=""
    if [[ "$sec" == "tls" && "$tr" =~ ^(xhttp|ws|httpupgrade|h2|grpc)$ ]]; then
        echo >&2
        _y "  ECH (加密 ClientHello, 真实 SNI 不外泄):"
        _o "    作用: 链路上看不到你连的是哪个域名, 只看到 CDN 的对外名字。"
        _o "    前提: 这条节点**经 Cloudflare 橙云** —— ECH 由 CDN 边缘终结,"
        _o "          源站不需要、也不该有那份私钥。"
        _o "    取值: 从域名的 HTTPS RR 自动取, 取不到会明确告警(并让节点先能用)。"
        local _ec=""
        read -rp "  选择 [1-2, 回车=2 开]: " _ec || _ec=""
        case "${_ec:-2}" in
            1) mk_ech="" ;;
            *) mk_ech="1" ;;
        esac
        [[ -n "$mk_ech" ]] && _g "    ECH: 开" || _g "    ECH: 不开"
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
    # 域名与证书 —— 证书方案是一等公民 (照 sing-box-core 的 sb_ask_cert 形状)
    #
    # ★ 原来这里只收一个域名, 从不给 cert_file/key_file → 生成的 TLS 入站
    #   **没有 certificates**。内核的表现最难查:
    #     xray run -test → Configuration OK; 真启动 → "started";
    #     而每次握手都失败: tls: no certificates configured
    #   实测 openssl s_client → no peer certificate available, curl https → 000。
    #   每一项面板做的检查都过, 节点永远连不上, 而屏幕上看不出缺什么。
    #
    # ★ 也不能只是"找不到就拒绝" —— 那会让没有证书的机器完全建不出 TLS 节点。
    #   SB 在这一层的设计是「永远有出路」: 扫描 → 手动 → 自签。
    #   三条路都通, 且每条都把**代价**说清楚 (自签=只有支持 pin 的客户端能连)。
    local domain="" cert_file="" key_file="" cert_trusted="" cert_pin=""
    if [[ "$sec" == "tls" ]]; then
        _mk_ask_cert_scheme || return 1
        domain="$MK_CERT_DOMAIN"
        cert_file="$MK_CERT_FILE"
        key_file="$MK_CERT_KEY"
        cert_trusted="$MK_CERT_TRUSTED"
        # 自签证书必须带 pin —— 否则客户端做正常校验必然失败 (自签不被信任),
        # 而表现是"配置全对、服务在跑、就是连不上"。
        if [[ "$cert_trusted" != "yes" ]]; then
            cert_pin=$(x_cert_client_pin "$cert_file" 1 1 2>/dev/null)
            if [[ -z "$cert_pin" ]]; then
                _e "  算不出自签证书的 pin —— 客户端将无法连接, 已中止"
                return 1
            fi
            _g "  客户端 pin (pinnedPeerCertSha256): ${cert_pin:0:16}…"
        fi

        # ★ CDN 档 + 自签 = 走不通。Cloudflare 回源时校验源站证书,
        #   自签会被拒 (与 SB 的 cdn_menu.sh 同一条判据)。
        #   在这里说清楚, 而不是等用户配完 nginx 发现 526。
        if [[ "$tier" == *cdn* && "$cert_trusted" != "yes" ]]; then
            echo >&2
            _e "  接入方式选了 CDN, 但证书是自签的 —— Cloudflare 不接受自签证书"
            _o "    CDN 回源要求源站证书由受信任 CA 签发 (Let's Encrypt 或 CF Origin)"
            _o "    可选:"
            _o "      ① 先在 菜单 5) 证书管理 里申请一张 $domain 的真证书, 再来建"
            _o "      ② 改用直连档 (自签 + 客户端 pin 是可行的, 只有 CDN 不行)"
            _o "      ③ 改用 REALITY 档 (不需要证书)"
            read -rp "  仍要按自签继续 (CDN 回源会失败)? [y/N]: " _go || _go=""
            case "$_go" in
                y|Y|yes|YES) _y "  已按你的要求继续 —— 这条节点 CDN 回源大概率不通" ;;
                *) _o "  已取消, 没有创建任何文件"; return 1 ;;
            esac
        fi
    fi


    # ---- 加密增强: 现调内核生成成对密钥 ----
    #
    # ★ 密钥必须**在这一刻生成**, 不能预置进表里。
    #   每台服务器的密钥必须独一无二; 预置等于把一把所有用户共用的私钥
    #   写进公开仓库。
    local XBIN; XBIN=$(_mk_xray_bin)
    local mk_dec="" mk_cli_enc="" mldsa_seed="" mldsa_verify=""
    if [[ ",$enh," == *",mlkem,"* || "$enh" == "mlkem" ]]; then
        local _ve=""
        [[ -n "$XBIN" ]] && _ve=$("$XBIN" vlessenc 2>/dev/null)
        # ★ 这两行是**一对**, 必须来自同一次生成, 而且**不能混用**:
        #
        #     "decryption": "mlkem768x25519plus.native.600s.<服务端私钥>"  → 服务端用
        #     "encryption": "mlkem768x25519plus.native.0rtt.<客户端公钥>"  → 客户端用
        #
        #   以前只取了 decryption, 然后把**同一个串**写进客户端产物 ——
        #   客户端拿服务端私钥去握手, 必然连不上。客户端那一侧的两种表现:
        #       mihomo:  proxy 0: invaild vless encryption value: …600s.…
        #                (它只认 0rtt 那种客户端形态)
        #       Xray  :  握手失败
        #   而服务端片段是对的, 面板上也一片正常 —— 典型"配好了就是连不上"。
        #   取的时候两个都取, 谁用谁的那一份。
        if [[ -n "$_ve" ]]; then
            mk_dec=$(printf '%s\n' "$_ve" \
                     | grep -o '"decryption"[[:space:]]*:[[:space:]]*"[^"]*"' | tail -1 | cut -d'"' -f4)
            mk_cli_enc=$(printf '%s\n' "$_ve" \
                     | grep -o '"encryption"[[:space:]]*:[[:space:]]*"[^"]*"' | tail -1 | cut -d'"' -f4)
        fi
        if [[ -n "$mk_dec" && -n "$mk_cli_enc" ]]; then
            _g "  已生成 ML-KEM-768 会话密钥对 (服务端 decryption + 客户端 encryption, 一次生成)"
        else
            _e "  要 ML-KEM-768 但取不到密钥对 —— 降级为普通 VLESS"
            _y "        vlessenc 需要内核 >= 26.3.27; 面板的 xrayls 太旧就没有这个子命令"
            mk_dec=""; mk_cli_enc=""
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

    # ---- 回落 (fallbacks) ----
    #
    # ★ 只在 **TLS** 入站上有意义, 所以 REALITY 档不问 —— REALITY 有自己的
    #   回落机制 (realitySettings.target), 两套混用没有意义。
    #
    # ★ 屏幕上的说明必须写清"它到底解决什么": 开了回落之后, **任何**能过
    #   TLS 握手的连接都会被看成一个正常访客 —— 长得像 VLESS 的走代理,
    #   不像的 (浏览器、扫描器) 转去你的网站。所以那个网站**必须真的在跑**,
    #   否则探测者会拿到一个 502 的"网站", 比不开还显眼。
    local fallback_port=""
    if [[ "$sec" == "tls" && ( "$proto" == "vless" || "$proto" == "trojan" ) ]]; then
        echo >&2
        _y "  回落 (fallbacks) —— 不像本协议的流量转到哪?"
        _o "    效果: 普通浏览器/扫描器打这个端口, 看到的是你的**真实网站**;"
        _o "          只有真客户端才走代理。抗主动探测最有效的一招。"
        _o "    前提: 那个网站必须真的在跑, 否则探测者会拿到 502 —— 比不开还显眼。"
        printf "    %s 1) 不回落%s (默认, 最省事)\n" "$_CYN" "$_RST" >&2
        printf "    %s 2) 转到一个本机端口%s (例如网站跑在 8080)\n" "$_CYN" "$_RST" >&2
        local _fbc=""
        if [[ "${X_BATCH:-0}" == "1" || ! -t 0 ]]; then
            _fbc="${MK_FALLBACK_PORT:+2}"
        else
            read -rp "  选择 [1-2, 回车=1]: " _fbc || _fbc=""
        fi
        case "${_fbc:-1}" in
            2)
                if [[ -n "${MK_FALLBACK_PORT:-}" ]]; then
                    fallback_port="$MK_FALLBACK_PORT"
                else
                    read -rp "  回落端口 (如 8080): " fallback_port || fallback_port=""
                    fallback_port="${fallback_port// /}"
                fi
                if [[ -n "$fallback_port" ]]; then
                    if [[ "$fallback_port" =~ ^[0-9]+$ ]] && \
                       ! ss -lnt 2>/dev/null | grep -qE "[:.]${fallback_port}[[:space:]]"; then
                        _y "  注意: 本机 127.0.0.1:$fallback_port 上**现在没有服务在听**"
                        _o "        (如果网站用 systemd/docker 跑在别的命名空间, 这条可能误报)"
                        read -rp "  仍然使用这个端口? [y/N]: " _go || _go=""
                        case "$_go" in y|Y|yes|YES) ;; *) fallback_port=""; _o "  已改为不回落";; esac
                    fi
                    _g "  回落: 非本协议流量 → 127.0.0.1:$fallback_port"
                fi
                ;;
        esac
    fi

    # python 侧拼 opts, 避免在 bash 里拼 JSON (引号地狱)
    local opts_json
    [[ ",$enh," == *",ech,"* ]] && mk_ech="1"   # 预置自带 (如预置⑤) 也算
    opts_json=$(MK_PROTOCOL="$proto" MK_TRANSPORT="$tr" MK_SECURITY="$sec" \
                MK_TAG="$tag" MK_PORT="$port" MK_CRED="$cred" \
                MK_DOMAIN="$domain" MK_TIER="$tier" \
                MK_CERT_FILE="$cert_file" MK_KEY_FILE="$key_file" MK_CERT_PIN="$cert_pin" \
                MK_FALLBACK_PORT="$fallback_port" \
                MK_CERT_TRUSTED="$cert_trusted" \
                MK_DECRYPTION="$mk_dec" MK_CLIENT_ENC="$mk_cli_enc" \
                MK_MLDSA_SEED="$mldsa_seed" MK_MLDSA_VERIFY="$mldsa_verify" \
                MK_XHTTP_MODE="$xhttp_mode" MK_ECH="$mk_ech" \
                python3 - <<'PY'
import json, os
proto = os.environ["MK_PROTOCOL"]; cred = os.environ.get("MK_CRED", "")
opts = {"protocol": proto, "transport": os.environ["MK_TRANSPORT"],
        "security": os.environ["MK_SECURITY"], "tag": os.environ["MK_TAG"],
        "port": int(os.environ["MK_PORT"]), "tier": os.environ["MK_TIER"]}
d = os.environ.get("MK_DOMAIN", "")
if d: opts["domain"] = d
# ★ TLS 入站的证书必须一起传下去。只给域名不给证书 = 入站没有 certificates,
#   内核启动成功但每次握手都失败 (tls: no certificates configured)。
#   没有这两个字段时 node_build 不会写 tlsSettings.certificates。
_cf = os.environ.get("MK_CERT_FILE", ""); _kf = os.environ.get("MK_KEY_FILE", "")
if _cf and _kf:
    opts["cert_file"] = _cf; opts["key_file"] = _kf
# 自签: pin 只发给**客户端** (分享链接 / mihomo YAML), 不写进服务端片段的
# tlsSettings —— 那里没有这个语义, 写了是噪音。
_fb = os.environ.get("MK_FALLBACK_PORT", "").strip()
if _fb:
    opts["fallback_port"] = _fb
_pin = os.environ.get("MK_CERT_PIN", "")
if _pin:
    opts["cert_pin"] = _pin
    opts["self_signed"] = (os.environ.get("MK_CERT_TRUSTED", "") != "yes")
# 后量子/签名密钥对 (由 mknode 在建节点那一刻用 xray vlessenc / mldsa65 生成)
# 服务端用 decryption, 客户端用 encryption —— 一对, 不能混
_d = os.environ.get("MK_DECRYPTION", "")
if _d: opts["encryption"] = _d
_ce = os.environ.get("MK_CLIENT_ENC", "")
if _ce: opts["client_encryption"] = _ce
_ms = os.environ.get("MK_MLDSA_SEED", "")
if _ms: opts["mldsa65_seed"] = _ms
_mv = os.environ.get("MK_MLDSA_VERIFY", "")
if _mv: opts["mldsa65_verify"] = _mv
_xm = os.environ.get("MK_XHTTP_MODE", "")
if _xm: opts["xhttp_mode"] = _xm
# ECH 标记 (预置⑤)。注意它**不是**"给服务端生成一对 ECH 密钥" ——
# 走橙云时 ECH 由 Cloudflare 边缘终结, 源站不该有那份私钥。
# 这个标记的作用是: 让客户端产物带上可用的 ECHConfigList (见 deploy.plan)。
if os.environ.get("MK_ECH", "") == "1":
    opts["ech"] = True
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
    #
    # ★ `--apply` 必须给。这一段原来挂着"落盘"的注释, 实际**没有 --apply** ——
    #   于是 deploy.py 走的是 `_print_plan()` 预演分支: 把片段打印到屏幕上,
    #   退出码 0, mknode 接着打印「完成。菜单 6 重启服务后生效。」
    #   **而磁盘上一个文件都没写。**
    #
    #   现象最难查: 屏幕上有完整的 JSON、有"完成"、没有任何报错, 用户回到菜单
    #   却发现节点不存在 —— 只会以为是自己哪一步点错了, 再走一遍。
    #   (接手审计时用 pty 真按键走到最后一步才发现: 沙箱产物 0 个。)
    local plan_py
    if [[ -r "$_MK_DIR/lib/deploy.py" ]]; then plan_py="$_MK_DIR/lib/deploy.py"
    else plan_py="$(_mk_lib deploy.py)" || return 1
              _MK_TMP+=("$plan_py"); fi

    python3 "$plan_py" --config-json "$opts_json" \
            --conf-dir "$CONF_DIR" --share-dir "$SHARE_DIR" --apply 2>&1 | sed 's/^/  /'
    local rc=${PIPESTATUS[0]}
    if (( rc != 0 )); then
        _e "  未创建"
        return "$rc"
    fi

    # ★ 落盘之后**回头看一眼文件在不在** —— 不拿退出码当成功。
    #   "退出码 0 但什么都没写"正是上面那个缺陷的形态, 而它骗过了所有人。
    #   片段写没写成, 只有 stat 说了算。
    local _tag _frag
    _tag=$(printf '%s' "$opts_json" | python3 -c \
           'import json,sys; print(json.load(sys.stdin).get("tag",""))' 2>/dev/null)
    _frag="$CONF_DIR/${_tag:-?}.json"
    if [[ -n "$_tag" && -f "$_frag" ]]; then
        _g "  完成。片段: $_frag"
        _g "  重启服务后生效: 菜单 8) 服务与配置 → 2) 校验配置并重载"
    else
        _e "  deploy.py 报了成功, 但片段不在: $_frag"
        _e "  没有创建成功 —— 请把上面几行完整贴出来"
        return 1
    fi
    return 0
}

cleanup() { [[ ${#_MK_TMP[@]} -gt 0 ]] && rm -f "${_MK_TMP[@]}"; }
trap cleanup EXIT

[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] && mk_run