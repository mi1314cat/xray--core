#!/bin/bash

# 交互输入统一走 conf/lib/read.sh —— EOF 会被当成退出, 否则会无限刷屏。
_x_read_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib"
if [[ -r "$_x_read_lib_dir/read.sh" ]]; then
    source "$_x_read_lib_dir/read.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/read.sh") \
        || { printf '输入库加载失败\n' >&2; exit 1; }
fi

# ================================
# outbound.sh — Xray 出站节点管理脚本
# hysteria2.sh（入站脚本）的孪生版本：
#   - 同样的彩色输出 / print_* / print_title / safe_read 风格
#   - 同样以 conf 目录 JSON 片段为数据载体（Xray -confdir 合并）
#   - 每出站一个 conf/out-NN.json，tag = out-NN
#   - 入站→出站映射写入 conf/out-routing.json（与 nginx.json 的 routing 追加共存）
#   - 支持 VLESS / VMess / Trojan / Shadowsocks / Hysteria2 / Freedom
#   - 交互极简：只填 IP / 端口 / 密钥等核心字段，其余默认；也可直接粘贴分享链接导入
# 用法： bash outbound.sh   （测试时可 OUTBOUND_BASE_DIR=... 覆盖基础目录）
# ================================

# ================================
# 统一 UI 层 —— conf/lib/print.sh + conf/lib/ui.sh
#
# ★ 本文件原先**自带一份** RED/GREEN/… 与 print_title / print_* / menu_item /
#   say。抄一份的代价不是多占十几行，而是"改一处漏两处" —— 而且已经踩中两条：
#     1) print_title 把标题塞进 `printf "║ %-42s ║"`。%-42s 按**字节**算宽度，
#        而本文件的标题全是中文（一个字 3 字节）。于是
#        「双栈智能落地（IPv4站走IPv4 + IPv6站走IPv6）」(55 字节) 与
#        「落地自检（配置 · 绑定 · 服务 · IPv6出口 · MTU）」(65 字节)
#        都会把右边框顶出屏幕, 少一列就看不出那是标题还是正文。
#     2) say() 的 %-18s 同理: 中文标签（源IP / 出口IPv6 / 出口IPv4 / 代理）
#        与 ASCII 标签（DNS / TCP / TLS）混排, 整列歪 2 格。
#   现在标题统一走 ui_box（按终端宽度 + 显示宽度算）, 对齐统一走 ui_pad_w。
#
# ★ 旧函数名全部保留为**薄包装** —— 下面几百个调用点一行都不用改。
# ★ 提示一律写 stderr: stdout 是数据通道（分享链接 / 节点数据）。
# ================================
if [[ -r "$_x_read_lib_dir/print.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_x_read_lib_dir/print.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/print.sh") \
        || { printf '  [X] 提示库 print.sh 加载失败\n' >&2; exit 1; }
fi

# 统一交互层（编号选择 / 确认 / 提问 / 方框排版）。
# ★ 取不到不致命: 退化成"只有排版的老样子" —— 菜单点得动比排版好看重要。
if [[ -r "$_x_read_lib_dir/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_x_read_lib_dir/ui.sh"
else
    printf '  [!] 交互库 ui.sh 取不到, 降级为无编号选择\n' >&2
    UI_PICK_KEY=""; UI_PICK_IDX=""; UI_PICK_COLS=(); UI_PICK_ROWS=""
    ui_box()   { ui_title "$@"; }
    ui_menu()  { printf '  %2s) %s\n' "$1" "$2" >&2; }
    ui_note()  { printf '  %s\n' "$1" >&2; }
    ui_pad_w() { printf '%s' "$1"; }
    ui_rule2() { printf '  --------------------------------\n' >&2; }
    ui_pause() { printf '\n' >&2; read -r _ || true; }
    ui_ask() { # <提示> [默认值]
        local q="$1" d="${2-}" a
        if [[ -n "$d" ]]; then
            printf '  %s (回车=%s): ' "$q" "$d" >&2
        else
            printf '  %s: ' "$q" >&2
        fi
        read -r a || a=""; [[ -z "$a" ]] && a="$d"; printf '%s' "$a"
    }
    ui_confirm() {
        local q="$1" a
        printf '  %s\n' "$q" >&2
        printf '    输入 yes 确认 (回车=取消): ' >&2
        read -r a || a=""
        [[ "$a" == "yes" || "$a" == "YES" || "$a" == "y" || "$a" == "Y" ]]
    }
    ui_table_print() { # 无库兜底: 退化成逐行 dump
        local k rest i=0
        while IFS=$'\t' read -r k rest; do
            [[ -n "$k" ]] || continue
            i=$((i + 1)); printf '  %2d) %s  %s\n' "$i" "$k" "$rest" >&2
        done <<< "${UI_PICK_ROWS:-}"
        (( i == 0 )) && printf '  (空)\n' >&2
        printf '\n  %s\n' "${1:-共 $i 项}" >&2
        return 0
    }
    ui_ask_num() {
        local p="$1" lo="$2" hi="$3" a
        while :; do
            read -r -p "  $p [$lo-$hi, 0=取消]: " a || return 1
            [[ -z "$a" || "$a" == 0 ]] && return 1
            [[ "$a" =~ ^[0-9]+$ ]] && (( a >= lo && a <= hi )) && { printf '%s' "$a"; return 0; }
            printf '  无效选项: %s\n' "$a" >&2
        done
    }
    ui_pick() {   # 无库时的兜底: 仍然编号化, 只是没有方框
        local title="$1" empty="$2" verb="$3" -a keys=() labels=()
        local k v i
        while IFS=$'\t' read -r k v; do
            [[ -n "$k" ]] || continue
            keys+=("$k"); labels+=("$v")
        done <<< "${UI_PICK_ROWS:-}"
        if ((${#keys[@]} == 0)); then printf '  %s\n' "$empty" >&2; return 2; fi
        ui_title "$title"
        for (( i = 0; i < ${#keys[@]}; i++ )); do ui_menu $((i+1)) "${labels[$i]}"; done
        ui_menu 0 "取消"
        i=$(ui_ask_num "$verb" 1 "${#keys[@]}") || { UI_PICK_KEY=""; return 1; }
        UI_PICK_KEY="${keys[$((i-1))]}"; return 0
    }
fi

# ---------- 颜色: 引用共享层, 不再自己声明一份 ----------
# ★ 非终端时 print.sh 会把颜色关掉（重定向到日志时不该带 ^[[32m 转义序列）,
#   这里跟着共享层走, 不再无条件写死转义序列。
RED="${_RED-}"; GREEN="${_GRN-}"; YELLOW="${_YEL-}"; CYAN="${_CYN-}"
GRAY="${_DIM-}"; BOLD="${_BOLD-}"; RESET="${_RST-}"
# 共享层没有这三个（用得少）, 保留字面量免得调用点找不到变量
BLUE="\e[34m"; MAGENTA="\e[35m"; WHITE="\e[97m"

# ================================
# 打印函数（全部输出到 stderr，与入站脚本一致）
# ================================
print_info()  { info "$*"; }
print_ok()    { ok "$*"; }
print_warn()  { warn "$*"; }
print_error() { err "$*"; }

# ★ 标题改走 ui_box: 按终端宽度 + 显示宽度画, `%-42s`（字节）的溢出消失。
print_title() { ui_box "$1"; }

# ---------- 统一菜单控件 ----------
menu_item() { ui_menu "$1" "$2"; }
menu_hint() { ui_hint "$1"; }
menu_quit() { ui_menu 0 "${1:-返回上级}"; }
# EOF 标志。menu_ask 只能 return —— 它基本都在 $(...) 子 shell 里被调用,
# 直接 exit 只结束子 shell。标志位让外层的 while 能看到"该退出了"。
#
# 不设默认值而是显式初始化: set -u 的脚本里读未定义变量会直接报错。
XR_EOF=0
xr_eof() { return "$XR_EOF"; }

menu_ask() { # $1=提示语 -> 输出到stdout（接收返回值）
    printf "  ${CYAN}${BOLD}▸${RESET} %s " "$1" >&2
    local v
    # EOF 必须往外传。
    #
    # 不能在这里 exit: 调用方几乎都写成 `c=$(menu_ask "...") || { XR_EOF=1; return; }`, 在子 shell 里,
    # exit 只结束子 shell, 外层的 while 照样拿着空串继续下一轮。
    # 实测过: `printf '7\n' | bash conf/outbound.sh` 会刷出 9.9MB / 18 万行
    # "无效选项", 直到超时被 kill。
    #
    # 所以这里用返回值传递 —— 调用方在 case 里认 XR_EOF 就能干净退出。
    if ! read -r v; then
        printf '\n' >&2
        return 1
    fi
    clean_input "$v"
}

# ================================
# 基础变量
# ================================
BASE_DIR="${OUTBOUND_BASE_DIR:-/root/catmi/xray}"
CONF_DIR="$BASE_DIR/conf"
OB_PREFIX="out"
ROUTING_FILE="$CONF_DIR/out-routing.json"
DEFAULT_OUTBOUND="direct"

# ★ OB_* 的兜底初始化。走"导入分享链接"的解析器会设 OB_ECH, 但走 wizard_* 手工
#   新增的不会 —— jq 那边又无条件引用 $ech, 于是 set -u 下整个菜单在选完协议后
#   才炸。同理, 批量导入时上一条链接的 ech 会漏给下一条 (VLESS 有 ECH、下一条
#   Trojan 没有 → Trojan 出站凭空长出 echConfigList)。
OB_ECH=""; OB_POOL=""; OB_SEND=""

# Xray 二进制（配置校验用）
XRAY_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_BIN" ]]; then
    for c in /root/catmi/xray/xrayls /usr/local/bin/xray xrayls; do
        command -v "$c" >/dev/null 2>&1 && { XRAY_BIN=$(command -v "$c"); break; }
    done
fi

mkdir -p "$CONF_DIR"

# ================================
# 输入清理
# ================================

# ================================
# 安全输入（不会污染 JSON）
# ================================

# 数字输入（1-65535，出站端口不检查本机占用）
safe_read_int() {
    local prompt="$1"
    local default="$2"
    local input

    while [[ "$XR_EOF" == "0" ]]; do
        # ★ 原来这里 `printf "%s (默认: %s): "` 紧跟 `xr_read "请输入"` ——
        #   屏幕上真的会出现 "端口 (默认: 443): 请输入: "（问题问两遍）。
        #   xr_read 自己就会带 "(默认: …)"，所以提示只留一份。
        xr_read "$prompt" "$default" input || { XR_EOF=1; return; }
        input=$(clean_input "$input")
        input="${input:-$default}"
        [[ "$input" =~ ^[0-9]+$ ]] || { print_error "必须是数字"; continue; }
        (( input >= 1 && input <= 65535 )) || { print_error "范围 1-65535"; continue; }
        echo "$input"
        return
    done
}

# 单选输入（默认值直接回车）
#
# ★ 原来这里是 `printf "%s (默认: %s): " "传输: 1)tcp 2)ws 3)grpc"` ——
#   选项只存在于**提示串里**（用户要自己数第几个）而且**完全不校验**：
#   敲个 "5" 落进调用方的 `*)` 分支，静默变成 tcp，用户却以为自己选了别的。
#   现在选项先用 ui_menu 画出来，再收编号；0/EOF = 取消（返回 1）。
safe_choose() { # <提示> <默认序号> <选项…> -> stdout 选中的序号
    local prompt="$1" default="${2:-1}"
    shift 2 || true
    local -a opts=("$@")
    ((${#opts[@]} == 0)) && return 1
    local i
    for (( i = 0; i < ${#opts[@]}; i++ )); do
        ui_menu $((i + 1)) "${opts[$i]}"
    done
    if [[ "$default" =~ ^[0-9]+$ ]] && (( default >= 1 && default <= ${#opts[@]} )); then
        ui_hint "默认: ${default}) ${opts[$((default - 1))]}（输入序号，0=取消）"
    else
        ui_hint "输入序号，0=取消"
    fi
    ui_ask_num "$prompt" 1 "${#opts[@]}"
}

# 随机 UUID（缺 uuidgen 自动安装，与入站脚本一致）
ensure_uuidgen() {
    if ! command -v uuidgen >/dev/null 2>&1; then
        print_info "uuidgen 未安装，正在自动安装..."
        apt update -y >/dev/null 2>&1
        apt install uuid-runtime -y >/dev/null 2>&1
        print_ok "uuidgen 安装完成"
    fi
}

# ================================
# 获取下一个出站编号（01、02、03…）
# ================================
get_next_index() {
    local used=() i=1
    shopt -s nullglob
    for f in "$CONF_DIR"/${OB_PREFIX}-*.json; do
        local base
        base=$(basename "$f")
        if [[ "$base" =~ ^${OB_PREFIX}-([0-9]+)\.json$ ]]; then
            used+=("${BASH_REMATCH[1]}")
        fi
    done
    if ((${#used[@]} == 0)); then
        printf "%02d\n" 1
        return
    fi
    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done
    printf "%02d\n" "$i"
}

# ================================
# 出站文件工具
# ================================
out_file() { printf "%s/%s-%02d.json" "$CONF_DIR" "$OB_PREFIX" "$1"; }
out_tag()  { printf "%s-%02d" "$OB_PREFIX" "$1"; }

# 列出 out-*.json 编号（已排序）
out_numbers() {
    local f n
    shopt -s nullglob
    for f in "$CONF_DIR"/${OB_PREFIX}-*.json; do
        n=$(basename "$f" .json | sed "s/^${OB_PREFIX}-//")
        [[ "$n" =~ ^[0-9]+$ ]] && echo "$n"
    done | sort -n
}

# ================================
# 全部入站 tag（扫描 conf 目录非出站片段）
# ================================
inbound_tags() {
    local f t
    shopt -s nullglob
    for f in "$CONF_DIR"/*.json; do
        [[ "$(basename "$f")" == ${OB_PREFIX}-*.json ]] && continue
        [[ "$(basename "$f")" == out-routing.json ]] && continue
        while IFS= read -r t; do
            [[ -n "$t" ]] && echo "$t"
        done < <(jq -r '.inbounds[]?.tag // empty' "$f" 2>/dev/null)
    done | sort -u
}

# ================================
# 分享链接解析（极简导入：只问粘贴，不问字段）
# ================================
# 读取 URL 查询参数： get_param "k=v&k2=v2" key
# ★ 必须做 percent-decode —— 分享链接里的值是**编码过**的, 最常见的是 path:
#   X 自己的分享载荷里 xhttp 节点写的是 `path=%2FaVCR3P0A%2F`。
#   不解开就原样丢进 Xray JSON 的 path, 请求会打到一个不存在的路径上,
#   而面板上这个出站看着配得好好的 —— 连不通却查不出原因。
#   `+` 还原成空格, 与 Client 的 urllib.parse.parse_qs 保持一致:
#   同一条链接在服务端和客户端必须解析出同一个值。
get_param() {
    local qs="$1" key="$2" pair val
    IFS='&' read -ra pairs <<< "$qs"
    for pair in "${pairs[@]}"; do
        if [[ "${pair%%=*}" == "$key" ]]; then
            val="${pair#*=}"
            urldecode "$val"
            return
        fi
    done
}

# percent-decode。
# ★ `printf %b` 对非法转义是**无害**的 (实测): `%zz` 原样输出 `%zz`、
#   裸 `%` 原样输出 —— 不会把值改坏, 所以用它比逐字符起子 shell 快得多
#   (ECH 配置有 500+ 字符, 逐字符解要起 500 次进程)。
#   唯一的副作用是遇到裸 `%` 时 bash 会往 stderr 报一句 missing hex digit,
#   这里一并丢掉 —— 那不是用户该看见的东西。
urldecode() {
    local s="${1//+/ }"
    [[ "$s" != *%* ]] && { printf '%s' "$s"; return; }
    printf '%b' "${s//%/\\x}" 2>/dev/null
}

# 分享链接的 #name 段也是编码过的 (🇺🇸 1-VLESS-WS_01 会变成
# %F0%9F%87%BA%F0%9F%87%B8%201-VLESS-WS_01)。不解开的话节点名就是一串百分号。
_ob_name() { # <frag> <默认名>
    local frag="$1" def="$2" n
    [[ -n "$frag" ]] || { printf '%s' "$def"; return; }
    n=$(urldecode "$frag")
    printf '%s' "${n:-$def}"
}

# hysteria2://pass@host:port?sni=..&insecure=1&pin=sha256hex#name
parse_hysteria2() {
    local url="$1" rest frag qs base userinfo hostport
    rest=${url#hysteria2://}
    frag=${rest##*#}; [[ "$frag" == "$rest" ]] && frag=""
    rest=${rest%%#*}
    qs=${rest#*\?}; [[ "$qs" == "$rest" ]] && qs=""
    base=${rest%%\?*}
    userinfo=${base%%@*}; hostport=${base##*@}
    OB_NAME=$(_ob_name "$frag" "Hysteria2")
    OB_PASS=$userinfo
    # 支持 [IPv6]:port 形式（分享链接里的 v6 节点地址）
    if [[ "${hostport:0:1}" == "[" && "$hostport" == *"]"* ]]; then
        OB_ADDR="${hostport%%]:*}"
        OB_ADDR="${OB_ADDR#[}"          # 去掉开头的 [
        OB_PORT="${hostport##*]}"       # 剩下 ":port"
        OB_PORT="${OB_PORT#:}"
        [[ -z "$OB_PORT" || "$OB_ADDR" == "$OB_PORT" ]] && OB_PORT=443
    else
        OB_ADDR=${hostport%%:*}
        OB_PORT=${hostport##*:}
        [[ -z "$OB_PORT" || "$OB_PORT" == "$OB_ADDR" ]] && OB_PORT=443
    fi
    OB_SNI=$(get_param "$qs" sni); [[ -z "$OB_SNI" ]] && OB_SNI=$(get_param "$qs" peer)
    [[ -z "$OB_SNI" ]] && OB_SNI=$OB_ADDR
    OB_PIN=$(get_param "$qs" pin)
    [[ -z "$OB_PIN" ]] && OB_PIN=$(get_param "$qs" pinnedPeerCertSha256)
    [[ -z "$OB_PIN" ]] && OB_PIN=$(get_param "$qs" sha256)
    # 老版分享链接带 hpkp=AA:BB:..:FF 的证书指纹（去冒号转小写 hex 即可）
    if [[ -z "$OB_PIN" ]]; then
        local hpkp
        hpkp=$(get_param "$qs" hpkp)
        if [[ -n "$hpkp" ]]; then
            OB_PIN=$(echo "$hpkp" | tr -d ':' | tr 'A-F' 'a-f')
            [[ "$OB_PIN" =~ ^[0-9a-f]{64}$ ]] && print_ok "已从 hpkp 提取证书指纹"
        fi
    fi
    [[ -n "$OB_PIN" ]] && ! [[ "$OB_PIN" =~ ^[0-9a-f]{64}$ ]] && OB_PIN=""
    # ★ ech 是 **ECHConfigList 原文**(base64), 不是开关。
    #   X 自己的分享载荷里 xhttp 节点带 ech= —— 不取就是静默丢掉,
    #   出站会绕过 ECH 直连真实 SNI, 等于白挂 CDN。
    OB_ECH=$(get_param "$qs" ech)
    OB_POOL=""; OB_SEND=""
}

# vless://uuid@host:port?type=&security=&sni=&fp=&pbk=&sid=&spx=&flow=&path=&host=#name
parse_vless() {
    local url="$1" rest frag qs base userinfo hostport
    rest=${url#vless://}
    frag=${rest##*#}; [[ "$frag" == "$rest" ]] && frag=""
    rest=${rest%%#*}
    qs=${rest#*\?}; [[ "$qs" == "$rest" ]] && qs=""
    base=${rest%%\?*}
    userinfo=${base%%@*}; hostport=${base##*@}
    OB_NAME=$(_ob_name "$frag" "VLESS")
    OB_UUID=$userinfo
    OB_ADDR=${hostport%%:*}
    OB_PORT=${hostport##*:}
    [[ -z "$OB_PORT" || "$OB_PORT" == "$OB_ADDR" ]] && OB_PORT=443
    OB_NET=$(get_param "$qs" type);        [[ -z "$OB_NET" ]] && OB_NET=tcp
    OB_SEC=$(get_param "$qs" security);    [[ -z "$OB_SEC" ]] && OB_SEC=none
    OB_SNI=$(get_param "$qs" sni)
    OB_FP=$(get_param "$qs" fp);           [[ -z "$OB_FP" ]] && OB_FP=chrome
    OB_PUB=$(get_param "$qs" pbk)
    OB_SID=$(get_param "$qs" sid)
    OB_SPX=$(get_param "$qs" spx);         [[ -z "$OB_SPX" ]] && OB_SPX=/
    OB_FLOW=$(get_param "$qs" flow)
    OB_WS_PATH=$(get_param "$qs" path);    [[ -z "$OB_WS_PATH" ]] && OB_WS_PATH=/
    OB_WS_HOST=$(get_param "$qs" host)
    OB_GRPC=$(get_param "$qs" serviceName);[[ -z "$OB_GRPC" ]] && OB_GRPC=grpc
    OB_XHTTP_PATH=$(get_param "$qs" path); [[ -z "$OB_XHTTP_PATH" ]] && OB_XHTTP_PATH=/
    OB_XHTTP_HOST=$(get_param "$qs" host)
    OB_ALPN=$(get_param "$qs" alpn)
    # ★ ech 是 **ECHConfigList 原文**(base64), 不是开关。
    #   X 自己的分享载荷里 xhttp 节点带 ech= —— 不取就是静默丢掉,
    #   出站会绕过 ECH 直连真实 SNI, 等于白挂 CDN。
    OB_ECH=$(get_param "$qs" ech)
    OB_POOL=""; OB_SEND=""
}

# trojan://pass@host:port?sni=..#name
parse_trojan() {
    local url="$1" rest frag qs base userinfo hostport
    rest=${url#trojan://}
    frag=${rest##*#}; [[ "$frag" == "$rest" ]] && frag=""
    rest=${rest%%#*}
    qs=${rest#*\?}; [[ "$qs" == "$rest" ]] && qs=""
    base=${rest%%\?*}
    userinfo=${base%%@*}; hostport=${base##*@}
    OB_NAME=$(_ob_name "$frag" "Trojan")
    OB_PASS=$userinfo
    OB_ADDR=${hostport%%:*}
    OB_PORT=${hostport##*:}
    [[ -z "$OB_PORT" || "$OB_PORT" == "$OB_ADDR" ]] && OB_PORT=443
    OB_SNI=$(get_param "$qs" sni); [[ -z "$OB_SNI" ]] && OB_SNI=$OB_ADDR
    OB_INSECURE=$(get_param "$qs" allowInsecure); [[ -z "$OB_INSECURE" ]] && OB_INSECURE=0
    # ★ ech 是 **ECHConfigList 原文**(base64), 不是开关。
    #   X 自己的分享载荷里 xhttp 节点带 ech= —— 不取就是静默丢掉,
    #   出站会绕过 ECH 直连真实 SNI, 等于白挂 CDN。
    OB_ECH=$(get_param "$qs" ech)
    OB_POOL=""; OB_SEND=""
}

# ss://BASE64(method:pass)@host:port 或 ss://method:pass@host:port#name
parse_ss() {
    local url="$1" rest frag qs base userinfo hostport decoded
    rest=${url#ss://}
    frag=${rest##*#}; [[ "$frag" == "$rest" ]] && frag=""
    rest=${rest%%#*}
    base=${rest%%\?*}
    userinfo=${base%%@*}; hostport=${base##*@}
    OB_NAME=$(_ob_name "$frag" "Shadowsocks")
    if [[ "$userinfo" == *:* ]]; then
        OB_METHOD=${userinfo%%:*}; OB_PASS=${userinfo#*:}
    else
        decoded=$(echo "$userinfo" | base64 -d 2>/dev/null)
        if [[ "$decoded" == *:* ]]; then
            OB_METHOD=${decoded%%:*}; OB_PASS=${decoded#*:}
        else
            print_error "无法解析 ss:// 链接（需要 base64 的 method:password）"; return 1
        fi
    fi
    OB_ADDR=${hostport%%:*}
    OB_PORT=${hostport##*:}
    [[ -z "$OB_PORT" || "$OB_PORT" == "$OB_ADDR" ]] && OB_PORT=8388
    OB_POOL=""; OB_SEND=""
}

# vmess://BASE64(JSON)#name
parse_vmess() {
    # ★ tls 原来没 local —— 每次导入都会把它泄漏成全局变量。
    local url="$1" b64 json tls
    b64=${url#vmess://}
    b64=${b64%%#*}
    # 尾部 #name 在截断后丢失，单独取
    json=$(echo "$b64" | base64 -d 2>/dev/null) || { print_error "vmess 链接解析失败"; return 1; }
    OB_NAME=$(echo "$json" | jq -r '.ps // "VMess"' 2>/dev/null)
    OB_UUID=$(echo "$json" | jq -r '.id // empty' 2>/dev/null)
    OB_ADDR=$(echo "$json" | jq -r '.add // empty' 2>/dev/null)
    OB_PORT=$(echo "$json" | jq -r '.port // 443' 2>/dev/null)
    OB_NET=$(echo "$json" | jq -r '.net // "tcp"' 2>/dev/null)
    OB_WS_PATH=$(echo "$json" | jq -r '.path // "/"' 2>/dev/null)
    [[ "$OB_WS_PATH" == none ]] && OB_WS_PATH=/
    OB_WS_HOST=$(echo "$json" | jq -r '.host // empty' 2>/dev/null)
    OB_GRPC=$(echo "$json" | jq -r '.path // "grpc"' 2>/dev/null)
    tls=$(echo "$json" | jq -r '.tls // "none"' 2>/dev/null)
    if [[ "$tls" == "tls" ]]; then OB_SEC=tls; OB_SNI=$(echo "$json" | jq -r '.sni // .host // empty' 2>/dev/null); else OB_SEC=none; OB_SNI=""; fi
    OB_FP=chrome; OB_POOL=""; OB_SEND=""
}

# 统一导入入口
import_link() {
    print_title "导入分享链接"
    # ★ url 原来没 local: 泄漏到全局, 还会和后面的同名变量打架。
    local url proto
    # ★ 原来 `printf "粘贴链接 …: " ` 紧跟 `xr_read "请输入地址"`，**问了两遍**。
    # ★ 提示必须印在 ui_ask **之前** —— ui_ask 会阻塞等输入, 印在后面等于
#   用户已经粘完链接才告诉他支持什么格式 (第一版就写反了, 回放才看出来)。
printf '    %s单条%s: hysteria2:// vless:// vmess:// trojan:// ss://\n' "$GRAY" "$RESET" >&2
printf '    %s订阅%s: http://ip:9443/share/<token>   ←「分享管理」发出来的那条\n' "$GRAY" "$RESET" >&2
url=$(ui_ask "粘贴链接或订阅地址" "")
    url=$(clean_input "$url")
    [[ -z "$url" ]] && { print_error "未输入链接"; return 1; }

    proto=${url%%://*}
    case "$proto" in
        hysteria2) parse_hysteria2 "$url" ;;
        vless)     parse_vless "$url" ;;
        vmess)     parse_vmess "$url" || return 1 ;;
        trojan)    parse_trojan "$url" ;;
        ss)        parse_ss "$url" || return 1 ;;
        # ★ X 自己的分享链接是**订阅地址** (http://ip:9443/share/<token>),
        #   内容是 base64 的多行节点 —— 单条链接的解析器吃不了。
        #   用户提的需求: "增加出站的方式, 能不能也加上我们自己的这种分享链接"
        http|https) import_share_url "$url"; return $? ;;
        *) print_error "不支持的协议: $proto"; return 1 ;;
    esac

    local name wproto
    name=$(safe_read "显示名称" "$OB_NAME")
    OB_NAME=${name:-$OB_NAME}

    wproto=$proto
    [[ "$proto" == "ss" ]] && wproto=shadowsocks
    write_outbound "$wproto"
    print_ok "已导入 $proto 出站：$OB_NAME → $OB_ADDR:$OB_PORT"
}

# ================================
# 订阅地址 (X 自己的分享链接) 导入
# ================================
# X 面板「分享管理」发出去的链接长这样:
#     http://<服务器IP>:<端口>/share/<token>
# 服务端返回的是 **base64 的订阅行**, 一行一个节点:
#     hysteria2://pass@host:port?sni=..&alpn=h3#name
#     vless://uuid@host:port?..&path=%2Fxxx%2F&ech=..#name
#     ss://base64(method:pass)@host:port#name
#     trojan://pass@host:port?security=reality&pbk=..#name
# 所以是**多条**, 不是一条 —— 必须让用户挑, 不能一股脑全导。
#
# ★ 为什么不用 Client/lib/node.py 的 parse_subscription:
#   那是**客户端**的库, 依赖客户端的状态文件与目录约定; 服务端面板这边
#   拿不到也不该拿。这里只用本文件已经有的 parse_* —— 同一套解析器,
#   单条导入和订阅导入行为完全一致, 不会各写一份慢慢漂移。

# 把一条链接解析成 OB_* 并写盘。$2=1 时不再问名字 (订阅里的名字已经够用,
# 批量导入逐条再问一遍是折磨)。返回 0 成功。
import_one() {
    local url="$1" ask="$2" name wproto
    OB_ECH=""; OB_POOL=""; OB_SEND=""
    wproto=${url%%://*}
    case "$wproto" in
        hysteria2|hy2) parse_hysteria2 "$url" || return 1; wproto=hysteria2 ;;
        vless)         parse_vless "$url" || return 1 ;;
        vmess)         parse_vmess "$url" || return 1 ;;
        trojan)        parse_trojan "$url" || return 1 ;;
        ss)            parse_ss "$url" || return 1; wproto=shadowsocks ;;
        *) return 1 ;;
    esac
    # 万一解析器自己没清干净 (比如换协议时残留), 这里兜底
    OB_ECH=${OB_ECH:-}

    if [[ "$ask" == "1" ]]; then
        name=$(safe_read "显示名称" "$OB_NAME")
        OB_NAME=${name:-$OB_NAME}
    fi
    write_outbound "$wproto"
    print_ok "已导入 $OB_NAME → $OB_ADDR:$OB_PORT"
}

import_share_url() {
    local url="$1" raw text
    print_title "从订阅地址导入"
    print_info "地址: $url"

    # ★ 只发一个 GET, 不带任何认证头。
    #   X 的分享服务是公开订阅 (token 在 URL 里), 这一点与 Client/lib/subs.py 一致。
    raw=$(curl -fsSL --max-time 25 "$url" 2>/dev/null) || {
        print_error "取不到订阅内容 —— 地址打不开、令牌失效、或者被防火墙挡了"
        return 1
    }
    [[ -n "${raw//[[:space:]]/}" ]] || { print_error "订阅内容是空的"; return 1; }

    # X 的载荷是 base64。也有客户端直接吐明文多行的 —— 两种都要吃:
    # 含 "://" 就说明已经是明文, 再解一次只会解出乱码。
    if [[ "$raw" != *"://"* ]]; then
        text=$(printf '%s' "$raw" | base64 -d 2>/dev/null)
        if [[ -z "${text//[[:space:]]/}" || "$text" != *"://"* ]]; then
            text=$raw   # 不是 base64, 当明文再看一遍
        fi
    else
        text=$raw
    fi

    # 只留本文件认得的协议; 顺带把 M 的 "# 注释"方言和空行扫掉。
    local -a links=()
    local ln
    while IFS= read -r ln; do
        ln=${ln%$'\r'}                       # CRLF 订阅很常见
        ln=$(printf '%s' "$ln" | sed 's/^[[:space:]]*#.*$//')
        ln=${ln#"${ln%%[![:space:]]*}"}      # 去行首空白
        [[ "$ln" == *"://"* ]] || continue
        case "${ln%%://*}" in
            hysteria2|hy2|vless|vmess|trojan|ss) links+=("$ln") ;;
        esac
    done <<< "$text"

    local total=${#links[@]}
    if (( total == 0 )); then
        print_error "订阅里没有本面板认得的节点 (只支持 hysteria2 / vless / vmess / trojan / ss)"
        return 1
    fi

    # 先把表打出来 —— 用户要能看着名字挑, 而不是回一串编号
    print_info "取到 $total 个节点："
    local i=1 p nm
    for ln in "${links[@]}"; do
        p=${ln%%://*}
        case "$p" in ss) p=shadowsocks;; hy2) p=hysteria2;; esac
        nm=${ln##*#}; [[ "$nm" == "$ln" ]] && nm="(无名字)"
        nm=$(urldecode "$nm")
        printf '  %2d) %-12s %s\n' "$i" "$p" "$nm" >&2
        (( i++ ))
    done
    echo >&2

    local pick
    # ★ 这里**不能**用 ui_ask —— 它把"回车"和"Ctrl-D"都变成空串, 而空串在这里
    #   的含义是"全选"。于是误触 Ctrl-D 就会一口气导进 8 个出站。
    #   自己 read 才能把 EOF 和"确实想全选"分开。
    printf '  %s要导入哪几个%s (编号, 空格/逗号分隔; 回车=全选 %d 个): ' \
        "$CYAN" "$RESET" "$total" >&2
    if ! IFS= read -r pick; then
        print_info "已取消"
        return 1
    fi
    local -a want=()
    if [[ -z "${pick// /}" ]]; then
        for (( i = 1; i <= total; i++ )); do want+=("$i"); done
    else
        pick=${pick//,/ }
        for i in $pick; do
            if [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= total )); then
                want+=("$i")
            else
                print_error "跳过无效编号: $i"
            fi
        done
    fi
    (( ${#want[@]} == 0 )) && { print_info "没有可导入的节点"; return 0; }

    local ok_n=0 fail_n=0
    for i in "${want[@]}"; do
        # ★ 不问名字: 订阅里每个节点都自带名字, 再逐条问一遍纯属折磨。
        #   想改名去「节点管理」里改。
        if import_one "${links[$((i-1))]}" 0; then
            (( ok_n++ ))
        else
            (( fail_n++ ))
        fi
    done

    echo >&2
    if (( fail_n == 0 )); then
        print_ok "已导入 $ok_n 个出站"
    else
        print_warn "导入完成: 成功 $ok_n, 失败 $fail_n"
    fi
    return 0
}

# ================================
# 协议 JSON 生成器（纯输出，供测试直接调用）
# 使用全局 OB_* 变量
# ================================
# VLESS 出站
vless_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg uuid "$OB_UUID" --arg flow "$OB_FLOW" \
        --arg net "$OB_NET" --arg sec "$OB_SEC" --arg sni "$OB_SNI" \
        --arg fp "$OB_FP" --arg pub "$OB_PUB" --arg sid "$OB_SID" --arg spx "$OB_SPX" \
        --arg wsp "$OB_WS_PATH" --arg wsh "$OB_WS_HOST" --arg grpc "$OB_GRPC" \
        --arg xp "$OB_XHTTP_PATH" --arg xh "$OB_XHTTP_HOST" --arg send "$OB_SEND" \
        --arg ech "$OB_ECH" \
        --arg pool "$OB_POOL" \
        '
        def settings:
          {network: $net}
          + (if $net == "ws" then {wsSettings: ({path: $wsp}
              + (if $wsh != "" then {headers: {Host: $wsh}} else {} end))} else {} end)
          + (if $net == "grpc" then {grpcSettings: {serviceName: $grpc}} else {} end)
          + (if $net == "xhttp" then {xhttpSettings: ({path: $xp}
              + (if $xh != "" then {host: $xh} else {} end))} else {} end)
          + (if $net == "tcp" then {tcpSettings: {}} else {} end)
          + (if $sec == "none" then {security: "none"} else {} end)
          + (if $sec == "tls" then {security: "tls", tlsSettings: ({serverName: $sni, fingerprint: $fp, allowInsecure: false} + (if $ech != "" then {echConfigList: $ech} else {} end))} else {} end)
          + (if $sec == "reality" then {security: "reality", realitySettings: ({serverName: $sni, fingerprint: $fp, publicKey: $pub, shortId: $sid, spiderX: $spx} + (if $ech != "" then {echConfigList: $ech} else {} end))} else {} end)
        ;
        {_meta: ({name:$name, proto:"vless"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
         outbounds: [{protocol:"vless", tag:$tag,
                      settings:{vnext:[{address:$addr, port:($port|tonumber),
                                        users:[{id:$uuid, encryption:"none", flow:$flow}]}]},
                      streamSettings: settings}
                     + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# VMess 出站
vmess_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg uuid "$OB_UUID" \
        --arg net "$OB_NET" --arg sec "$OB_SEC" --arg sni "$OB_SNI" --arg fp "$OB_FP" \
        --arg wsp "$OB_WS_PATH" --arg wsh "$OB_WS_HOST" --arg grpc "$OB_GRPC" \
        --arg send "$OB_SEND" --arg pool "$OB_POOL" --arg ech "$OB_ECH" \
        '
        def settings:
          {network: $net}
          + (if $net == "ws" then {wsSettings: ({path: $wsp}
              + (if $wsh != "" then {headers: {Host: $wsh}} else {} end))} else {} end)
          + (if $net == "grpc" then {grpcSettings: {serviceName: $grpc}} else {} end)
          + (if $net == "tcp" then {tcpSettings: {}} else {} end)
          + (if $sec == "none" then {security: "none"} else {} end)
          + (if $sec == "tls" then {security: "tls", tlsSettings: ({serverName: $sni, fingerprint: $fp, allowInsecure: false} + (if $ech != "" then {echConfigList: $ech} else {} end))} else {} end)
        ;
        {_meta: ({name:$name, proto:"vmess"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
         outbounds: [{protocol:"vmess", tag:$tag,
                      settings:{vnext:[{address:$addr, port:($port|tonumber),
                                        users:[{id:$uuid, alterId:0, security:"auto"}]}]},
                      streamSettings: settings}
                     + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# Trojan 出站
trojan_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg pass "$OB_PASS" \
        --arg net "$OB_NET" --arg sec "$OB_SEC" --arg sni "$OB_SNI" --arg fp "$OB_FP" \
        --arg wsp "$OB_WS_PATH" --arg wsh "$OB_WS_HOST" \
        --arg send "$OB_SEND" --arg pool "$OB_POOL" --arg ech "$OB_ECH" \
        '
        def settings:
          {network: $net}
          + (if $net == "ws" then {wsSettings: ({path: $wsp}
              + (if $wsh != "" then {headers: {Host: $wsh}} else {} end))} else {} end)
          + (if $net == "tcp" then {tcpSettings: {}} else {} end)
          + (if $sec == "none" then {security: "none"} else {} end)
          + (if $sec == "tls" then {security: "tls", tlsSettings: ({serverName: $sni, fingerprint: $fp, allowInsecure: false} + (if $ech != "" then {echConfigList: $ech} else {} end))} else {} end)
        ;
        {_meta: ({name:$name, proto:"trojan"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
         outbounds: [{protocol:"trojan", tag:$tag,
                      settings:{servers:[{address:$addr, port:($port|tonumber), password:$pass, level:0}]},
                      streamSettings: settings}
                     + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# Shadowsocks 出站
ss_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg method "$OB_METHOD" --arg pass "$OB_PASS" \
        --arg send "$OB_SEND" --arg pool "$OB_POOL" \
        '{_meta: ({name:$name, proto:"shadowsocks"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
          outbounds: [{protocol:"shadowsocks", tag:$tag,
                       settings:{servers:[{address:$addr, port:($port|tonumber), method:$method, password:$pass, level:0}]}}
                      + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# Hysteria2 出站（原生 QUIC）
# 协议标识 "hysteria" + settings.version=2（官方 Xray 模型）
# 关键：必须配 streamSettings.network="hysteria" 激活 QUIC 传输，否则默认走 TCP！
# 结构：settings 只放 version/address/port；auth 放 hysteriaSettings；TLS 放 tlsSettings
# pinnedPeerCertSha256 = 节点证书 SHA256（allowInsecure 已被官方移除）
#   获取方式: xrayls tls ping 或 QUIC 握手抓取，也可用 serve_cert_hash 辅助
hy2_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" --arg addr "$OB_ADDR" \
        --arg port "$OB_PORT" --arg pass "$OB_PASS" --arg sni "$OB_SNI" \
        --arg pin "$OB_PIN" --arg send "$OB_SEND" --arg pool "$OB_POOL" \
        '{_meta: ({name:$name, proto:"hysteria2"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
          outbounds: [{protocol:"hysteria", tag:$tag,
                       settings:{version:2, address:$addr, port:($port|tonumber)},
                       streamSettings:{network:"hysteria", security:"tls",
                         tlsSettings:{serverName:$sni, alpn:["h3"], pinnedPeerCertSha256:$pin},
                         hysteriaSettings:{version:2, auth:$pass}}}
                      + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# --- Hysteria2 pin 自动补全 --------------------------------------------------
# Xray 26.x 已移除 outbound 的 allowInsecure：
#   hy2 outbound 无法校验自签/错误域名证书链 -> QUIC 建链后静默超时
#   ("RoundTrip err > timeout: no recent network activity")
# 因此 pin 必填。这里尽可能自动获取：
#   1) 目标 sni 与本机 Hysteria2 证书目录匹配 -> 直接算 sha256
#   2) 其余情况引导用户给出 pin 或 pem 文件（可用 openssl x509 ... | sha256sum）
hy2_autopin() { # $1=addr $2=sni ; 直接修改全局 OB_PIN
    local addr="$1" sni="${2:-$1}"
    local cert="$BASE_DIR/Hysteria2/cert-$sni.crt"
    [[ -f "$cert" ]] || cert="$BASE_DIR/Hysteria2/cert-$addr.crt"
    if [[ -f "$cert" ]]; then
        local h
        h=$(openssl x509 -in "$cert" -outform der 2>/dev/null | sha256sum | awk '{print tolower($1)}')
        if [[ -n "$h" ]]; then
            OB_PIN="$h"
            print_ok "自动取到本机证书指纹: $h"
            return 0
        fi
    fi
    print_warn "hysteria2 出站必须提供 pinnedPeerCertSha256 (Xray 26.x 已移除 allowInsecure,"
    print_info "不填会导致 QUIC 握手后静默无响应: RoundTrip err > timeout: no recent network activity)"
    print_info "获取方式：优先使用带 pin= 的分享链接；或在该 VPS 上执行:"
    print_info "  openssl x509 -in <cert路径> -outform der | sha256sum | awk '{print tolower(\$1)}'"
    while :; do
        OB_PIN=$(safe_read "证书 SHA256(直接回车=放弃添加)" "")
        [[ -z "$OB_PIN" ]] && { print_error "无 pin 已放弃写入，未生成节点文件"; return 1; }
        OB_PIN=$(echo "$OB_PIN" | tr 'A-F' 'a-f')
        [[ "$OB_PIN" =~ ^[0-9a-f]{64}$ ]] && return 0
        print_error "格式无效（应为 64 位 hex），请重试"
    done
}

# Freedom 出站（本机直连，可指定源IPv4/IPv6）
freedom_json() { # $1=tag
    local tag="$1"
    jq -n \
        --arg tag "$tag" --arg name "$OB_NAME" \
        --arg send "$OB_SEND" --arg pool "$OB_POOL" \
        '{_meta: ({name:$name, proto:"freedom"}
                  + (if $pool != "" then {pool: {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])}} else {} end)),
          outbounds: [{protocol:"freedom", tag:$tag, settings:{}}
                      + (if $send != "" then {sendThrough:$send} else {} end)]}'
}

# 统一写文件
write_outbound() { # $1=proto
    local proto="$1" next tag json
    next=$(get_next_index)
    tag=$(out_tag "$next")
    case "$proto" in
        vless)       json=$(vless_json "$tag") ;;
        vmess)       json=$(vmess_json "$tag") ;;
        trojan)      json=$(trojan_json "$tag") ;;
        shadowsocks) json=$(ss_json "$tag") ;;
        hysteria2)   json=$(hy2_json "$tag") ;;
        freedom)     json=$(freedom_json "$tag") ;;
        *) print_error "未知协议 $proto"; return 1 ;;
    esac
    [[ -n "$json" ]] || { print_error "JSON 生成失败"; return 1; }
    echo "$json" | jq . > "$CONF_DIR/$OB_PREFIX-$next.json"
    print_ok "已写入 $CONF_DIR/$OB_PREFIX-$next.json (tag=$tag)"

    # ---- 加入后自检（默认 3 次；全失败则自动回退并禁用该出站）----
    if [[ "${OUTBOUND_SELFTEST:-1}" == "1" ]]; then
        selftest_outbound "$CONF_DIR/$OB_PREFIX-$next.json" "$tag"
    fi
}

# ============ 入站→出站 一键绑定（供自检成功后自动调用） ================
bind_inbound_to_tag() { # $1=inboundTag $2=outboundTag
    local inbound="$1" tag="$2"
    [[ -z "$inbound" || -z "$tag" ]] && return 1
    if [[ -f "$ROUTING_FILE" ]]; then
        jq --arg k "$inbound" --arg v "$tag" '._meta.bindings[$k]=$v' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" \
            && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    else
        jq -n --arg k "$inbound" --arg v "$tag" '{_meta:{bindings:{($k):$v}}}' > "$ROUTING_FILE"
    fi
    write_routing || return 1
    print_ok "$inbound → $tag (路由已写入并持久化)"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active xrayls >/dev/null 2>&1; then
        systemctl restart xrayls && print_ok "xrayls 已重启，新绑定即刻生效"
    fi
}

# ============ 出站自检 + 失败自动回退 ================
# 用 xrayls 单实例 + socks 入站直连该出站，连续 3 次请求
# https://www.gstatic.com/generate_204；全部失败则：
#   1) 把该出站文件移入 $CONF_DIR/.quarantine/（不再加载）
#   2) 路由中所有指向它的入站绑定改回默认出站(direct)
#   3) 重启 xrayls 使路由生效
selftest_outbound() { # $1=out_file_path $2=tag
    local file="$1" tag="$2" port try ok=0 code
    [[ "${XRAYLS_BIN:-}" == "" ]] && XRAYLS_BIN=$(find "$CONF_DIR/.." -maxdepth 2 -type f -name xrayls 2>/dev/null | head -1)
    [[ -z "$XRAYLS_BIN" || ! -x "$XRAYLS_BIN" ]] && { print_warn "找不到 xrayls 可执行文件，跳过自检"; return 0; }
    for try in 1 2 3; do
        port=$((10321+RANDOM%200))
        python3 - "$file" tag "$port" <<PY
import json,sys
fin,tag,port=sys.argv[1],sys.argv[2],int(sys.argv[3])
o=json.load(open(fin))["outbounds"][0]
json.dump({"inbounds":[{"port":port,"protocol":"socks","listen":"127.0.0.1"}],
           "outbounds":[o],"log":{"loglevel":"error"}}, open("/tmp/.selftest-cfg.json","w"))
PY
        ( timeout 8 "$XRAYLS_BIN" run -c /tmp/.selftest-cfg.json 2>/dev/null & echo $! > /tmp/.selftest-pid )
        sleep 2
        code=$(curl -m 6 -x socks5h://127.0.0.1:$port -s -o /dev/null -w "%{http_code}" https://www.gstatic.com/generate_204 2>/dev/null)
        kill "$(cat /tmp/.selftest-pid)" 2>/dev/null; sleep 1
        if [[ "$code" != "200" && "$code" != "204" ]]; then
            print_warn "自检第 $try/3 次: HTTP=$code (未通过)"
        else
            print_ok "自检第 $try/3 次: HTTP=$code 通过"
            ok=$((ok+1)); break
        fi
    done
    if (( ok > 0 )); then
        print_ok "自检通过 ($ok/1)，出站已保留"
        # 自动绑定流程：提供一键绑定机会（回车跳过则保持现路由）
        if [[ "${OUTBOUND_AUTOBIND:-1}" == "1" ]]; then
            local -a ins
            local f2 itag
            for f2 in "$CONF_DIR"/*.json; do
                [[ "$(basename "$f2")" == "$OB_PREFIX-"* || "$(basename "$f2")" == "out-routing.json" ]] && continue
                itag=$(jq -r '.inbounds[0].tag // empty' "$f2" 2>/dev/null)
                [[ -n "$itag" ]] && ins+=("$itag")
            done
            if ((${#ins[@]} > 0)); then
                echo "自检通过，是否把某个入站绑定到此出站？（直接回车=跳过绑定，沿用当前路由）" >&2
                local i
                for i in "${!ins[@]}"; do menu_item $((i + 1)) "${ins[$i]}"; done
                # ★ 原来这里是裸 `read -r sel`：**没有 EOF 保护**。
                #   被 source 调用 / 管道喂输入 / Ctrl-D 时 read 直接失败，
                #   sel 保持空串 → 落进 else 分支"跳过绑定" —— 看起来像是用户
                #   自己选了跳过，其实是没读进来。这里收编号：取消(含 EOF) = 跳过。
                local sel
                if sel=$(ui_ask_num "绑定入站（对应上面列表，0=跳过）" 1 "${#ins[@]}"); then
                    bind_inbound_to_tag "${ins[$((sel - 1))]}" "$tag"
                else
                    print_info "跳过绑定，请稍后用菜单 7 手工绑定"
                fi
            fi
        fi
        return 0
    fi
    print_warn "N 次自检全部失败 → 自动回退到默认出站并禁用此出站"
    local qdir="$CONF_DIR/.quarantine"
    mkdir -p "$qdir"
    mv "$file" "$qdir/$(basename "$file")" 2>/dev/null
    print_ok "出站已移出: $CONF_DIR/.quarantine/$(basename "$file") （以后确认可用再手动移回）"
    # 路由内所有引用此 tag 的绑定改回默认
    if [[ -f "$ROUTING_FILE" ]]; then
        jq --arg tag "$tag" '._meta.bindings = (._meta.bindings // {} | to_entries \
            | map(.value = (if .value == $tag then "direct" else .value end)) \
            | map(.key as $k | {(.key): .value}) | add // {})' \
            "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" 2>/dev/null && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
        rebuild_routing_rules "$ROUTING_FILE" | jq '.routing' >/tmp/newr.json 2>/dev/null
        if jq -e '.routing.rules' /dev/null >/dev/null 2>&1 </dev/null && [[ -s /tmp/newr.json ]]; then
            jq --argjson nr "$(cat /tmp/newr.json 2>/dev/null)" '.routing=$nr' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
        fi
        rm -f /tmp/newr.json
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active xrayls >/dev/null 2>&1; then
        systemctl restart xrayls && print_ok "xrayls 已重启，路由回到默认出站"
    fi
}

# ================================
# IPv6 /64 地址池
# ================================
# 自动检测本机 /64 前缀（2409:8a20:1c93:5460::/64 形式）
# 注意：/64 子网 = 地址前 4 组（后 4 组是接口标识，不属前缀）
detect_v6_prefix() {
    local line net
    line=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 .*\/64/ && !/temporary/ {print $2; exit}')
    [[ -z "$line" ]] && line=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 .*\/64/ {print $2; exit}')
    [[ -z "$line" ]] && return 1
    net=$(echo "$line" | tr 'A-F' 'a-f' | awk -F: '{printf "%s:%s:%s:%s::/64", $1,$2,$3,$4}')
    echo "$net"
}

# 当前已分配池地址（扫描所有出站片段 _meta.pool.address）
used_v6_addresses() {
    local f
    shopt -s nullglob
    for f in "$CONF_DIR"/${OB_PREFIX}-*.json; do
        jq -r '._meta.pool.address // empty' "$f" 2>/dev/null
    done
}

# 规范化 IPv6：小写、展开 ::、逐组去前导零（与内核 ip addr 显示格式对齐）
# 例：2001:470:c:cf:0c00:04be:5753:2d2b → 2001:470:c:cf:c00:4be:5753:2d2b
#     2001:470:c:cf::2 → 2001:470:c:cf:0:0:0:2
canon6() {
    echo "$1" | awk -F: '
    {
        n = split($0, g, ":")
        zi = 0
        for (i=1; i<=n; i++) if (g[i]=="") { zi=i; break }
        delete ng; k=0
        if (zi>0) {
            for (i=1; i<zi; i++) ng[++k]=g[i]
            for (i=1; i<=9-n; i++) ng[++k]="0"
            for (i=zi+1; i<=n; i++) ng[++k]=g[i]
        } else {
            for (i=1; i<=n; i++) ng[++k]=g[i]
        }
        out=""
        for (i=1; i<=k; i++) {
            v=tolower(ng[i]); sub(/^0+/, "", v); if (v=="") v="0"
            out = out (i==1 ? "" : ":") v
        }
        print out
    }'
}

# 地址是否已在本机接口上（规范格式比对，容忍前导零省略 / :: 压缩）
addr_on_iface() {
    local want addr
    want=$(canon6 "$1" 2>/dev/null) || return 1
    [[ -n "$want" ]] || return 1
    while read -r addr; do
        [[ "$(canon6 "$addr")" == "$want" ]] && return 0
    done < <(ip -6 addr show 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="inet6"){a=$(i+1); sub(/\/.*/,"",a); print a}}')
    return 1
}

# 默认出口网卡（优先 IPv6 默认路由——HE 隧道等场景 v4/v6 默认口不同）
iface_name() {
    local v6 v4
    v6=$(ip -6 route show default 2>/dev/null | head -1 | awk '{print $5}')
    [[ -n "$v6" ]] && { echo "$v6"; return; }
    v4=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    [[ -n "$v4" ]] && { echo "$v4"; return; }
    echo ""
}

# 在指定前缀内生成一个未使用的随机 IPv6（全小写、无 ::、非全零、不重复、8 组合法）
# 用法: gen_v6_address "2409:8a20:1c93:5460::/64"
gen_v6_address() {
    local prefix="$1" net iid cand i
    prefix=$(echo "$prefix" | tr 'A-F' 'a-f')
    net=$(echo "$prefix" | sed 's/::\/64$//')
    [[ -z "$net" ]] && { print_error "前缀格式错误: $prefix"; return 1; }
    # 网段必须是恰好 4 组
    [[ "$net" =~ ^[0-9a-f]{1,4}(:[0-9a-f]{1,4}){3}$ ]] || { print_error "不是合法 /64 前缀: $prefix"; return 1; }
    for i in $(seq 1 50); do
        iid=$(printf '%04x:%04x:%04x:%04x' \
            $((RANDOM % 65536)) $((RANDOM % 65536)) \
            $((RANDOM % 65536)) $((RANDOM % 65536)))
        # 避免生成 :: （不允许四个组全零）
        [[ "$iid" == "0000:0000:0000:0000" ]] && continue
        cand="$net:$iid"
        # 必须为 8 组合法 IPv6（每组允许 1-4 位，如 2001:470:c:cf 前缀）
        [[ "$cand" =~ ^[0-9a-f]{1,4}(:[0-9a-f]{1,4}){7}$ ]] || continue
        # 避免重复 / 避免已在网卡
        used_v6_addresses | grep -qix "$cand" && continue
        addr_on_iface "$cand" && continue
        echo "$cand"
        return 0
    done
    print_error "50 次尝试后仍无法分配不重复的 IPv6"
    return 1
}

# 找到持有该 IPv6 前缀地址的接口（HE 隧道等：v6 地址在隧道口，与 v4 默认口不同）
# 注意去壳：隧道接口在 ip addr 里显示为 he-ipv6@NONE，必须剥掉 @ 后缀
prefix_iface() { # $1 = 2001:470:c:cf::/64
    local net="$1"
    [[ -z "$net" ]] && return 1
    net=${net%::/*}
    ip -6 addr show 2>/dev/null | awk -v n="$net" '
        /^[0-9]+: / { dev=$2; sub(/:$/, "", dev); sub(/@.*/, "", dev) }
        /inet6 /    { if ($2 ~ "^" n ":") { print dev; exit } }'
}

# 把地址挂到网卡（/128 源地址，nodad 跳过 DAD 避免 tentative 不可用；已存在则跳过）
# 返回 0=确认已在网卡上；返回 1=挂载失败（调用方必须中止，避免写出"假配置"）
# 网卡选择优先级：前缀所属接口 > v6 默认路由口 > v4 默认路由口
assign_v6() {
    local addr="$1" prefix="$2" iface addout rc
    # 防呆开关：仅当显式设置 OUTBOUND_NO_ASSIGN=1（自动化测试）时才跳过真实挂载
    [[ -n "$OUTBOUND_NO_ASSIGN" ]] && return 0
    addr_on_iface "$addr" && return 0
    if [[ -n "$prefix" ]]; then
        iface=$(prefix_iface "$prefix")
    fi
    [[ -z "$iface" ]] && iface=$(iface_name)
    if [[ -z "$iface" ]]; then
        print_error "找不到可挂载网卡（无默认路由且前缀内无地址），源IP: $addr"
        return 1
    fi
    # 防御：去 @ 后缀（隧道口显示 he-ipv6@NONE，实际设备名 he-ipv6）
    iface=${iface%%@*}
    print_info "挂载: ip -6 addr add $addr/128 dev $iface nodad"
    addout=$(ip -6 addr add "$addr/128" dev "$iface" nodad 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        print_error "挂载失败(exit=$rc): ip -6 addr add $addr/128 dev $iface nodad"
        [[ -n "$addout" ]] && printf "  └─ 内核/工具报错: %s\n" "$addout" >&2
        return 1
    fi
    # 等 1 秒再复查（避免内核异步时序）
    sleep 1
    if addr_on_iface "$addr"; then
        print_ok "源IPv6 已挂载: $addr/128 dev $iface"
        return 0
    fi
    # --- 诊断转储：add 成功但复查不到，把现场完整打出来 ---
    print_error "挂载后复查未通过: $addr 不在任何网卡上"
    printf "  └─ add 输出(exit=0): %s\n" "${addout:-（无输出）}" >&2
    printf "  └─ ip -6 addr show 中含该前缀的行:\n" >&2
    ip -6 addr show 2>/dev/null | grep -iE "inet6|$(echo "${prefix:-$addr}" | cut -d: -f1-4)" | head -25 | sed 's/^/      /' >&2
    printf "  └─ 目标接口状态: " >&2
    ip link show dev "$iface" 2>&1 | head -2 | sed 's/^/      /' >&2
    return 1
}

# 出口自检：用指定源 IPv6 访问公网并核对出口地址（HE 隧道等环境可即时发现不通）
egress_check() { # $1 = 源IPv6（可选；为空则用默认源）
    local addr="$1" got
    if [[ -n "$addr" ]]; then
        got=$(curl -6 --interface "$addr" -s --max-time 10 https://ipv6.icanhazip.com 2>/dev/null)
        [[ -z "$got" ]] && got=$(curl -6 --interface "$addr" -s --max-time 10 https://api6.ipify.org 2>/dev/null)
    else
        got=$(curl -6 -s --max-time 10 https://ipv6.icanhazip.com 2>/dev/null)
    fi
    got=$(echo "$got" | head -1)
    if [[ -n "$got" ]]; then
        if [[ -n "$addr" && "$(canon6 "$got")" == "$(canon6 "$addr")" ]]; then
            print_ok "出口自检✓ 出口IP = $got（与分配地址一致）"
        elif [[ -n "$addr" ]]; then
            print_info "出口自检: 出口=$got ≠ 分配地址=$addr（NAT 或运营商改写源地址）"
        else
            print_ok "IPv6 出口正常: $got"
        fi
    else
        print_info "出口自检未通过：该源IPv6 暂不通公网（若 HE 隧道未配置/未启动则属预期）"
    fi
}

# 移除网卡上的池地址（删除出站时调用；按实际持有地址的接口删除）
release_v6() {
    local addr="$1" dev
    addr_on_iface "$addr" || return 0
    dev=$(ip -6 addr show 2>/dev/null | awk -v a="$addr/" '
        /^[0-9]+: / { d=$2; sub(/:$/, "", d); sub(/@.*/, "", d) }
        /inet6 /    { if ($2 ~ "^" a) { print d; exit } }')
    [[ -n "$dev" ]] && ip -6 addr del "$addr/128" dev "$dev" 2>/dev/null
}

# 读取/设置池前缀（持久化在 out-routing.json 的 _meta.ipv6Pool）
pool_prefix() {
    jq -r '._meta.ipv6Pool // empty' "$ROUTING_FILE" 2>/dev/null
}
set_pool_prefix() {
    local prefix="$1"
    if [[ -f "$ROUTING_FILE" ]]; then
        jq --arg p "$prefix" '._meta.ipv6Pool=$p' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    else
        echo "{\"_meta\": {\"ipv6Pool\": \"$prefix\"}}" > "$ROUTING_FILE"
    fi
}

# ================================
# 入站→出站绑定（routing 生成）
# ================================
# 读取当前绑定表 bindings（入站tag -> 出站tag）
read_bindings() {
    jq -r '._meta.bindings // {} | to_entries[] | "\(.key)=\(.value)"' "$ROUTING_FILE" 2>/dev/null
}

# 统一的 rules 重组：分流规则(splitRules)在前 → 绑定规则(bindings) → ads→block
# 供 outbound.sh / split.sh 共用（fork 的 routing 后读覆盖先读，故全写进同一文件）
rebuild_routing_rules() {
    local file="$1"
    # 分流规则数组（split.sh 管理的，含全局规则和按入站规则）
    # 兼容旧数据：文件缺失/损坏时按空数组处理（避免 --argjson 收到空串导致整条路由被清空写入）
    local splits
    splits=$(jq -c '._meta.splitRules // []' "$file" 2>/dev/null)
    [[ "$splits" == "null" || -z "$splits" ]] && splits='[]'
    # 绑定表
    local -A B=()
    local entry k v
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        k=${entry%%=*}; v=${entry#*=}
        B[$k]=$v
    done < <(jq -r '._meta.bindings // {} | to_entries[] | "\(.key)=\(.value)"' "$file" 2>/dev/null)

    # 组装绑定规则
    local jrules='[]'
    for k in "${!B[@]}"; do
        jrules=$(jq --arg k "$k" --arg v "${B[$k]}" \
            '. + [{inboundTag: [$k], outboundTag: $v}]' <<< "$jrules")
    done

    # 最终 rules = 分流 + 绑定 + ads→block
    jq -n --argjson splits "$splits" --argjson binds "$jrules" \
        '{routing: {rules: ($splits + $binds + [{domain:["geosite:category-ads-all"], outboundTag:"block"}])}}'
}

# 写入绑定表并重新生成 routing.rules（保留 splitRules 与 dualStack 元信息）
# ============ 默认出站（direct）自动实体化 ================
# 以前的坑：DEFAULT_OUTBOUND="direct" 只是个"字面量"，conf 里并不存在 tag=direct 的出站。
# 用户在菜单7绑定到"默认出站"后，路由规则写着 outboundTag:"direct"，
# 而 xrayls 的合并结果里没有这个出站 -> 木有效果，"保存重启仍然连不上"。
# 修复：写路由前保证 tag=direct 的 freedom 出站真实存在。
ensure_direct_outbound() {
    local f="$CONF_DIR/out-direct.json"
    [[ -f "$f" ]] && return 0
    mkdir -p "$CONF_DIR" 2>/dev/null
    jq -n '{_meta:{name:"默认直连", proto:"freedom"},
            outbounds:[{protocol:"freedom", tag:"direct", settings:{domainStrategy:"UseIP"}}]}' > "$f" 2>/dev/null
    print_ok "已自动创建默认出站文件: $f (tag=direct)"
}

write_routing() {
    local newmeta
    ensure_direct_outbound
    newmeta=$(rebuild_routing_rules "$ROUTING_FILE")
    # 保护：重组结果若为空说明 jq 阶段出错，直接中止，绝不把 0 字节内容覆盖回路由文件
    if [[ -z "$newmeta" ]] || ! echo "$newmeta" | jq -e '.routing.rules' >/dev/null 2>&1; then
        print_error "路由重组失败（routing 未写入，原文件保持不动），请检查 splitRules/bindings 数据"
        return 1
    fi
    if [[ -f "$ROUTING_FILE" ]]; then
        # 保留 _meta 其余字段（bindings/splitRules/dualStack），仅替换 routing
        jq --argjson nr "$(jq '.routing' <<< "$newmeta")" \
            '.routing = $nr' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    else
        # 全新文件：从绑定表重建 _meta.bindings
        local bb
        bb=$(jq -r '._meta.bindings // {}' <<< '{}')
        jq -n --argjson bbind "$bb" --argjson nr "$(jq '.routing' <<< "$newmeta")" \
            '{_meta: {bindings: $bbind}, routing: $nr}' > "$ROUTING_FILE"
    fi
    print_ok "已写入 $ROUTING_FILE"
}

# ================================
# CRUD
# ================================
add_outbound() {
    print_title "新增出站"
    menu_item 1 "VLESS"
    menu_item 2 "VMess"
    menu_item 3 "Trojan"
    menu_item 4 "Shadowsocks"
    menu_item 5 "Hysteria2"
    menu_item 6 "Freedom（本机直连 / 指定源IP）"
    menu_item 7 "导入分享链接"
    menu_quit
    print_info "请选择协议"
    local c; c=$(menu_ask "选择") || { XR_EOF=1; return; }
    case "$c" in
        1) wizard_vless ;;
        2) wizard_vmess ;;
        3) wizard_trojan ;;
        4) wizard_ss ;;
        5) wizard_hy2 ;;
        6) wizard_freedom ;;
        7) import_link ;;
        0) return ;;
        *) print_error "无效选项" ;;
    esac
}

wizard_vless() {
    ensure_uuidgen
    OB_NAME=$(safe_read "显示名称" "$(x_default_name vless 1)")
    OB_ADDR=$(safe_read "服务器 IP/域名" "")
    [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
    OB_PORT=$(safe_read_int "端口" 443)
    OB_UUID=$(safe_read "UUID" "$(uuidgen | tr 'A-Z' 'a-z')")
    local net_choice
    net_choice=$(safe_choose "传输" 1 tcp ws grpc xhttp) || { print_info "已取消"; return; }
    case "$net_choice" in
        2) OB_NET=ws ;;
        3) OB_NET=grpc ;;
        4) OB_NET=xhttp ;;
        *) OB_NET=tcp ;;
    esac
    local sec_choice
    sec_choice=$(safe_choose "安全" 1 none tls reality) || { print_info "已取消"; return; }
    case "$sec_choice" in
        2)
            OB_SEC=tls
            OB_SNI=$(safe_read "SNI" "$OB_ADDR")
            OB_FP=chrome
            ;;
        3)
            OB_SEC=reality
            OB_SNI=$(safe_read "SNI(伪装域名)" "www.microsoft.com")
            OB_PUB=$(safe_read "PublicKey" "")
            [[ -z "$OB_PUB" ]] && { print_error "Reality 需要 PublicKey"; return 1; }
            OB_SID=$(safe_read "ShortID" "036cbb71")
            OB_FP=chrome
            OB_SPX=/
            ;;
        *) OB_SEC=none ;;
    esac
    OB_FLOW=$(safe_read "Flow(可空, 默认不填)" "")
    OB_WS_PATH=/; OB_WS_HOST=""; OB_GRPC=grpc; OB_XHTTP_PATH=/; OB_XHTTP_HOST=""
    case "$OB_NET" in
        ws)    OB_WS_PATH=$(safe_read "WS Path" "/"); OB_WS_HOST=$(safe_read "WS Host(可空)" "") ;;
        grpc)  OB_GRPC=$(safe_read "gRPC serviceName" "grpc") ;;
        xhttp) OB_XHTTP_PATH=$(safe_read "XHTTP Path" "/") ;;
    esac
    OB_SEND=$(safe_read "源IP绑定(可空)" "")
    write_outbound vless
}

wizard_vmess() {
    ensure_uuidgen
    OB_NAME=$(safe_read "显示名称" "$(x_default_name vmess 1)")
    OB_ADDR=$(safe_read "服务器 IP/域名" "")
    [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
    OB_PORT=$(safe_read_int "端口" 443)
    OB_UUID=$(safe_read "UUID" "$(uuidgen | tr 'A-Z' 'a-z')")
    local net_choice
    net_choice=$(safe_choose "传输" 1 tcp ws grpc) || { print_info "已取消"; return; }
    case "$net_choice" in
        2) OB_NET=ws ;;
        3) OB_NET=grpc ;;
        *) OB_NET=tcp ;;
    esac
    local sec_choice
    sec_choice=$(safe_choose "TLS" 1 关闭 开启) || { print_info "已取消"; return; }
    if [[ "$sec_choice" == "2" ]]; then
        OB_SEC=tls
        OB_SNI=$(safe_read "SNI" "$OB_ADDR")
        OB_FP=chrome
    else
        OB_SEC=none; OB_SNI=""; OB_FP=chrome
    fi
    OB_WS_PATH=/; OB_WS_HOST=""; OB_GRPC=grpc
    case "$OB_NET" in
        ws)    OB_WS_PATH=$(safe_read "WS Path" "/"); OB_WS_HOST=$(safe_read "WS Host(可空)" "") ;;
        grpc)  OB_GRPC=$(safe_read "gRPC serviceName" "grpc") ;;
    esac
    OB_SEND=$(safe_read "源IP绑定(可空)" "")
    write_outbound vmess
}

wizard_trojan() {
    OB_NAME=$(safe_read "显示名称" "$(x_default_name trojan 1)")
    OB_ADDR=$(safe_read "服务器 IP/域名" "")
    [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
    OB_PORT=$(safe_read_int "端口" 443)
    OB_PASS=$(safe_read "密码" "")
    local net_choice
    net_choice=$(safe_choose "传输" 1 tcp ws) || { print_info "已取消"; return; }
    [[ "$net_choice" == "2" ]] && OB_NET=ws || OB_NET=tcp
    local sec_choice
    sec_choice=$(safe_choose "TLS" 1 开启 关闭) || { print_info "已取消"; return; }
    if [[ "$sec_choice" == "1" ]]; then
        OB_SEC=tls; OB_SNI=$(safe_read "SNI" "$OB_ADDR"); OB_FP=chrome
    else
        OB_SEC=none; OB_SNI=""; OB_FP=chrome
    fi
    OB_WS_PATH=/; OB_WS_HOST=""
    [[ "$OB_NET" == "ws" ]] && { OB_WS_PATH=$(safe_read "WS Path" "/"); OB_WS_HOST=$(safe_read "WS Host(可空)" ""); }
    OB_SEND=$(safe_read "源IP绑定(可空)" "")
    write_outbound trojan
}

wizard_ss() {
    OB_NAME=$(safe_read "显示名称" "$(x_default_name ss 1)")
    OB_ADDR=$(safe_read "服务器 IP/域名" "")
    [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
    OB_PORT=$(safe_read_int "端口" 8388)
    OB_METHOD=$(safe_read "加密方式" "aes-256-gcm")
    OB_PASS=$(safe_read "密码" "")
    OB_SEND=$(safe_read "源IP绑定(可空)" "")
    write_outbound shadowsocks
}

wizard_hy2() {
    print_title "新增 Hysteria2 出站"
    menu_item 1 "从分享链接导入（推荐）"
    menu_item 2 "手动填写"
    menu_quit
    local m; m=$(menu_ask "选择导入方式") || { XR_EOF=1; return; }
    if [[ "$m" == "1" ]]; then
        local link
        link=$(menu_ask "粘贴 hysteria2:// 分享链接") || { XR_EOF=1; return; }
        [[ -z "$link" ]] && { print_error "链接不能为空"; return 1; }
        parse_hysteria2 "$link"
        OB_PIN=${OB_PIN:-}
        if [[ -z "$OB_PIN" ]]; then
            print_info "链接中无证书hash(pin)。"
            hy2_autopin "$OB_ADDR" "$OB_SNI" || return 1
        fi
        [[ ! "$OB_PIN" =~ ^[0-9a-f]{64}$ ]] && { print_error "pin 格式无效，请重试"; return 1; }
    else
        OB_NAME=$(safe_read "显示名称" "$(x_default_name hysteria2 1)")
        OB_ADDR=$(safe_read "服务器 IP/域名" "")
        [[ -z "$OB_ADDR" ]] && { print_error "服务器地址不能为空"; return 1; }
        OB_PORT=$(safe_read_int "端口" 443)
        OB_PASS=$(safe_read "密钥/密码" "")
        [[ -z "$OB_PASS" ]] && { print_error "密钥不能为空"; return 1; }
        OB_SNI=$(safe_read "SNI(默认=地址)" "$OB_ADDR")
        OB_PIN=""
        hy2_autopin "$OB_ADDR" "$OB_SNI" || return 1
    fi
    OB_POOL=""; OB_SEND=""
    [[ -z "$OB_SNI" ]] && OB_SNI=$OB_ADDR
    write_outbound hysteria2
}

wizard_freedom() {
    # ★ ftype 原来没 local —— 泄漏到全局。
    local ftype
    OB_NAME=$(safe_read "显示名称" "$(x_default_name freedom 1)")
    OB_SEND=""; OB_POOL=""
    # ★ 这里原来用裸 echo 画菜单（与其余菜单不对齐），收号用 xr_read。
    ui_menu 1 "默认直连（无指定源IP）"
    ui_menu 2 "指定 IPv4 源IP"
    ui_menu 3 "自动分配 IPv6（/64 池）"
    ui_menu 4 "双栈智能落地（IPv4站走IPv4 + IPv6站走IPv6）"
    ui_menu 0 "返回上级"
    ftype=$(ui_ask_num "请选择类型" 1 4) || { ui_note "已取消"; return; }
    case "$ftype" in
        2)
            # ★ 原来把本机 IPv4 一行行 echo 出来，然后让用户**照着抄**一个 ——
            #   "输入源IPv4" 的值必须和上面列表里的某个**一模一样"。
            #   列表里有 WARP/HE/docker 的地址时哪一个才是想要的，只能靠猜；
            #   打错一个字符不报错, 直接写进 sendThrough, 出站静默不通。
            #   现在一次 `ip -4 -o addr` 扫出全部, **编号 + 网卡 + CIDR** 一起列出来,
            #   用户选序号, 值由程序取 —— 不存在"抄错"这件事。
            UI_PICK_COLS=(源IPv4 接口 CIDR)
            UI_PICK_ROWS=""
            local _iface _cidr
            while read -r _iface _cidr; do
                [[ -z "${_cidr:-}" ]] && continue
                # ★ UI_PICK_ROWS 的**第一列是 key, 不显示**（与 node.sh 同一个约定）。
                #   所以地址要出现两次: 一次当 key（选中后直接就是 OB_SEND）,
                #   一次当显示列, 否则列表里根本看不到选了哪个地址。
                UI_PICK_ROWS+="${_cidr%%/*}"$'\t'"${_cidr%%/*}"$'\t'"${_iface%%@*}"$'\t'"$_cidr"$'\n'
            done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')
            if ! ui_pick "指定 IPv4 源IP" "本机没有 scope global 的 IPv4 地址" "选择源IP"; then
                print_error "未选择源IPv4，已放弃"
                return 1
            fi
            OB_SEND="$UI_PICK_KEY"
            [[ -n "$OB_SEND" ]] || { print_error "源IPv4 不能为空"; return 1; }
            ;;
        3)
            local prefix detected
            prefix=$(pool_prefix) || true
            if [[ -n "$prefix" ]]; then
                print_info "使用已保存的 IPv6 前缀: $prefix"
                prefix=$(safe_read "IPv6 前缀" "$prefix")
            else
                detected=$(detect_v6_prefix) || true
                if [[ -n "$detected" ]]; then
                    print_info "已自动检测到 IPv6 /64 子网: $detected（直接回车即使用）"
                    prefix=$(safe_read "IPv6 前缀" "$detected")
                else
                    print_info "未自动检测到 IPv6 /64（该服务器可能没有 SLAAC /64）"
                    prefix=$(safe_read "IPv6 前缀" "")
                fi
            fi
            [[ -z "$prefix" ]] && { print_error "前缀不能为空（如 2001:db8:abcd:1234::/64）"; return 1; }
            # 持久化
            set_pool_prefix "$prefix"
            local addr
            addr=$(gen_v6_address "$prefix") || return 1
            assign_v6 "$addr" "$prefix" || return 1
            egress_check "$addr"
            OB_SEND=$addr
            OB_POOL="${prefix}|${addr}"
            print_ok "已分配源IPv6: $addr"
            ;;
        4)
            wizard_dualstack
            return $?
            ;;
        *) ;;
    esac
    write_outbound freedom
}

# 节点命名约定 (单一实现) —— 本地优先, 否则从仓库取。
#
# ★ 这里原来写的是 `$_lib_dir/lib/naming.sh`, 而 `$_lib_dir` 这个变量在整份文件里
#   **从来没有被赋值** —— 于是 `-r` 恒为假, naming.sh 每次都从 GitHub 现拉。
#   后果不是"慢一点": 本地 conf/lib/naming.sh 里改的东西(节点命名规则)根本不生效,
#   跑的是仓库 main 分支的版本; 断网时整个出站管理直接 exit 1。
#   正确变量是文件顶部 `_x_read_lib_dir`(已经含 lib), 所以后面**不能再加 /lib**。
if [[ -r "$_x_read_lib_dir/naming.sh" ]]; then
    source "$_x_read_lib_dir/naming.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/naming.sh") \
        || { print_error "命名库加载失败"; exit 1; }
fi

# 对外地址探测库 (单一实现) —— 本地优先, 否则从仓库取。
# 见 conf/lib/addr.sh 顶部: 为什么不能问外部"我的 IP"、为什么要排除隧道网卡。
# ★ 同上: `$_x_lib_dir` 未赋值 + 多了一层 /lib, 一并修正。
if [[ -r "$_x_read_lib_dir/addr.sh" ]]; then
    source "$_x_read_lib_dir/addr.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/addr.sh") \
        || { print_error "地址库加载失败"; exit 1; }
fi

# 检测本机对外 IPv4。
#
# ★ 以前这里只做"私网过滤", **不排除隧道/虚拟网卡** —— 而本机可能同时有
#   WARP / HE-IPv6 / docker / awg, 只有真实网卡上的地址是客户端能直连的。
#   也不校验"这个地址是不是真在本机接口上"。两件事现在都交给 addr.sh 统一做。
detect_public_ipv4() {
    x_iface_public_addr 2>/dev/null || ip -4 -o addr show scope global 2>/dev/null |
        awk '{print $4}' | cut -d/ -f1 | head -1
}

# 取/建 v4域名名单出站（只建一个，复用），返回 tag
# 双栈：v4域名单 → v4freedom出站；其余 → v6freedom出站
# 一次调用创建 v4出站 + v6出站 两个，并把信息记入 routing._meta.dualStack
wizard_dualstack() {
    print_title "双栈智能落地（IPv4站走IPv4 + IPv6站走IPv6）"
    # 1) 确定前缀
    local prefix detected
    prefix=$(pool_prefix) || true
    if [[ -z "$prefix" ]]; then
        detected=$(detect_v6_prefix) || true
        if [[ -n "$detected" ]]; then
            print_info "已自动检测到 IPv6 /64: $detected"
            prefix=$(safe_read "IPv6 前缀" "$detected")
        else
            print_info "未检测到 IPv6 /64"
            prefix=$(safe_read "IPv6 前缀" "")
        fi
        [[ -z "$prefix" ]] && { print_error "前缀不能为空"; return 1; }
        set_pool_prefix "$prefix"
    else
        print_info "使用已保存的 IPv6 前缀: $prefix"
    fi

    # 2) 本机公网 IPv4 作为 v4 落地
    local v4
    v4=$(detect_public_ipv4)
    if [[ -z "$v4" ]]; then
        print_info "未检测到公网 IPv4，请输入（或直接回车让 v4 站也走默认双栈）:"
        v4=$(safe_read "公网IPv4" "")
    else
        print_info "检测到公网 IPv4: $v4"
        local v4in
        v4in=$(safe_read "IPv4落地地址" "$v4")
        [[ -n "$v4in" ]] && v4=$v4in
    fi

    # 3) 创建 v6 出站
    local v6addr
    v6addr=$(gen_v6_address "$prefix") || return 1
    assign_v6 "$v6addr" "$prefix" || return 1
    egress_check "$v6addr"

    # 4) 取编号，写两个出站（先写 v6，再取 v4 编号，避免重复）
    local n6 n4 tag6 tag4
    n6=$(get_next_index)
    tag6=$(out_tag "$n6")
    # v6 出站
    jq -n --arg t "$tag6" --arg a "$v6addr" --arg p "$prefix" --arg nm "双栈IPv6" \
        '{_meta:{name:$nm, proto:"freedom", pool:{prefix:$p, address:$a}}, outbounds:[{protocol:"freedom",tag:$t,settings:{},sendThrough:$a}]}' \
        > "$CONF_DIR/$OB_PREFIX-$n6.json"
    # v6 文件已写入，此时取 v4 编号必然不同
    n4=$(get_next_index)
    tag4=$(out_tag "$n4")
    # v4 出站（若 v4 地址为空，则用默认 direct 语义=不带 sendThrough，走本机默认）
    if [[ -n "$v4" ]]; then
        jq -n --arg t "$tag4" --arg a "$v4" --arg nm "双栈IPv4" \
            '{_meta:{name:$nm, proto:"freedom"}, outbounds:[{protocol:"freedom",tag:$t,settings:{},sendThrough:$a}]}' \
            > "$CONF_DIR/$OB_PREFIX-$n4.json"
    else
        jq -n --arg t "$tag4" --arg nm "双栈IPv4" \
            '{_meta:{name:$nm, proto:"freedom"}, outbounds:[{protocol:"freedom",tag:$t,settings:{}}]}' \
            > "$CONF_DIR/$OB_PREFIX-$n4.json"
    fi
    print_ok "已创建: $tag4 (IPv4落地=$v4) + $tag6 (IPv6落地=$v6addr)"

    # 5) 写入分流规则：v4域名名单(全局) → v4出站；其余走绑定
    #    统一写 _meta.splitRules（分流规则数组，与 split.sh 共用）
    local dss
    dss=$(jq -n --arg v4 "$tag4" \
        '[{type:"field", domain:["domain:browserleaks.com","domain:matrix.tencent.com","domain:baidu.com","domain:douyin.com","domain:taobao.com"], outboundTag:$v4}]')
    if [[ -f "$ROUTING_FILE" ]]; then
        jq --argjson ds "$dss" '._meta.splitRules = ((._meta.splitRules // []) + $ds)' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    else
        jq -n --argjson ds "$dss" '{_meta:{bindings:{}, splitRules:$ds}}' > "$ROUTING_FILE"
    fi
    write_routing
    print_ok "双栈智能落地完成：纯IPv4站→$tag4（全局分流），IPv6站→$tag6"
    print_info "提示：把该入站通过菜单7绑定到 $tag6，即可让该入站获得双栈能力（v4站自动走IPv4）"
    return 0
}

# 把当前 v4 名单填进 UI_PICK_ROWS（key = 完整 domain:xxx）并画出来
dual_domains_rows() { # $1 = splitRules 下标
    local idx="$1" d
    UI_PICK_COLS=(域名)
    UI_PICK_ROWS=""
    while IFS= read -r d; do
        [[ -n "$d" ]] && UI_PICK_ROWS+="$d"$'\t'"${d#domain:}"$'\n'
    done < <(jq -r "._meta.splitRules[$idx].domain[]?" "$ROUTING_FILE" 2>/dev/null)
}

# 查看/编辑双栈 v4 域名名单（操作 _meta.splitRules 里的全局规则）
dual_domains() {
    print_title "双栈 v4 域名名单"
    if [[ ! -f "$ROUTING_FILE" ]] || [[ "$(jq '._meta.splitRules // [] | length' "$ROUTING_FILE" 2>/dev/null)" == "0" ]]; then
        print_info "尚未配置双栈落地（菜单2→6 Freedom→4）或无分流规则"
        return 0
    fi
    # 找到 v4 站分流的规则（含 browserleaks 的全局规则）
    local idx nd rmd ob
    idx=$(jq -r '._meta.splitRules | to_entries | map(select(.value.domain // [] | index("domain:browserleaks.com"))) | .[0].key // empty' "$ROUTING_FILE" 2>/dev/null)
    if [[ -z "$idx" ]]; then
        print_info "未找到双栈 v4 分流规则（含 browserleaks.com 的那条）"
        return 0
    fi
    ob=$(jq -r "._meta.splitRules[$idx].outboundTag" "$ROUTING_FILE")
    ui_note "以下域名走 IPv4 落地: $ob"
    # ★ 列表改为**编号**渲染: 原来是一行行 sed 's/^/  /', 没有序号,
    #   紧接着又要用户"输完整域名" —— 等于凭记忆抄一遍刚打印的东西。
    dual_domains_rows "$idx"
    ui_table_print "当前名单"

    # ★ 原来 `printf "新增域名…: " ` 紧跟 `xr_read "新增域名…"`, 同一个问题**问了两遍**。
    nd=$(ui_ask "新增域名（如 example.com，回车跳过）" "")
    if [[ -n "$nd" ]]; then
        nd=${nd#domain:}
        jq --argjson i "$idx" --arg d "domain:$nd" '._meta.splitRules[$i].domain += [$d] | ._meta.splitRules[$i].domain |= unique' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
        write_routing
        print_ok "已加入: $nd"
        # ★ 刚加过一行, 旧的行号/内容已经不准了 —— 重新编号再让用户选。
        dual_domains_rows "$idx"
    fi

    # ★ 移除: 编号选择, 值由 UI_PICK_KEY 给, 不再手打。
    if ! ui_pick "移除 v4 域名" "名单为空，无需移除" "移除域名"; then
        return 0
    fi
    rmd="$UI_PICK_KEY"
    # ★ 原来**不做任何核对**: 域名是字符串全等匹配, 打错一个字符 → jq 什么都没删,
    #   却照样打印 "已移除: xxx"。用户以为规则删掉了, 实际那条站还在走 IPv4 落地。
    #   所以先确认它在名单里, 删完再确认它真的没了, 两头都不通过就明说失败。
    if [[ -z "$(jq -r --arg d "$rmd" "._meta.splitRules[$idx].domain // [] | index(\$d) // empty" "$ROUTING_FILE" 2>/dev/null)" ]]; then
        print_error "名单里没有 $rmd —— 未做任何修改"
        return 0
    fi
    jq --argjson i "$idx" --arg d "$rmd" '._meta.splitRules[$i].domain |= map(select(. != $d))' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    write_routing
    if [[ -n "$(jq -r --arg d "$rmd" "._meta.splitRules[$idx].domain // [] | index(\$d) // empty" "$ROUTING_FILE" 2>/dev/null)" ]]; then
        print_error "移除失败: $rmd 仍在名单里（未写入或被占用）"
    else
        print_ok "已移除: ${rmd#domain:}"
    fi
}

# 出站表: 填 UI_PICK_ROWS / UI_PICK_COLS（key = 文件编号 n）
# 出站行数 → OB_ROWS_COUNT（list_outbounds 画"共 N 个出站"要用）
OB_ROWS_COUNT=0
#
# ★ 原来每个出站起 6 次 jq, 而且第 7 项"被绑定入站数"还要把 read_bindings
#   在循环体内重跑一遍（N 个出站 = 7N 次进程）。这里改成**每个文件一次 jq**
#   拿全部字段, 绑定表在循环外读一次。
# ★ 顺带解决一个更难受的问题: 原来的编号是**文件号**（03、04…）, 而删除文件
#   后编号会留空洞, 用户看到的"3"和"03"指的不是同一行。现在序号由渲染器统一
#   生成（连续 1..N）, 文件号单独成一列 —— 序号和文件号不会再混。
outbound_rows() {
    local n f tag name proto addr port src cnt binds
    OB_ROWS_COUNT=0
    binds=$(read_bindings)
    UI_PICK_COLS=(名称 协议 文件 tag 地址 端口 源IP 绑定数)
    UI_PICK_ROWS=""
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        f=$(out_file "$n")
        # @tsv 一次吐出 6 个字段; 空值统一落成 '-'（渲染器也会兜底）
        IFS=$'\t' read -r name proto tag addr port src < <(jq -r \
            '[._meta.name // "-",
              ._meta.proto // "?",
              .outbounds[0].tag // "-",
              (.outbounds[0].settings.vnext[0].address // .outbounds[0].settings.servers[0].address // .outbounds[0].settings.address // "直连"),
              (((.outbounds[0].settings.vnext[0].port // .outbounds[0].settings.servers[0].port // .outbounds[0].settings.port) // "-") | tostring),
              (.outbounds[0].sendThrough // "-")] | @tsv' "$f" 2>/dev/null)
        [[ -n "$tag" ]] || tag="-"
        cnt=$(grep -c "=${tag}$" <<< "$binds" || true)
        [[ -n "$cnt" ]] || cnt=0
        UI_PICK_ROWS+="$n"$'\t'"${name:--}"$'\t'"${proto:-?}"$'\t'"out-$n"$'\t'"$tag"$'\t'"${addr:--}"$'\t'"${port:--}"$'\t'"${src:--}"$'\t'"$cnt"$'\n'
        OB_ROWS_COUNT=$((OB_ROWS_COUNT + 1))
    done < <(out_numbers)
}

list_outbounds() {
    print_title "出站列表"
    outbound_rows
    if (( OB_ROWS_COUNT == 0 )); then
        ui_note "暂无出站，请先新增"
        return 0
    fi
    ui_table_print "共 $OB_ROWS_COUNT 个出站"
}

# 选择一个出站（收的是**列表序号**，不是文件号）
pick_outbound() {
    local -a nums=()
    local n idx
    mapfile -t nums < <(out_numbers)
    if ((${#nums[@]} == 0)); then
        print_info "暂无出站，请先新增"
        return 1
    fi
    # ★ 原来 `printf "输入出站编号: " ` 紧跟 `xr_read "请输入"` —— 问题**问了两遍**
    #   （屏幕上真的会是 "输入出站编号: 请输入: "）, 而且问的是"编号"却允许任意
    #   字符串, 校验失败后只能从头再输一遍。
    if ! idx=$(ui_ask_num "选择出站（对应上面列表的序号）" 1 "${#nums[@]}"); then
        print_info "已取消"
        return 1
    fi
    n=${nums[$((idx - 1))]}
    [[ -f "$(out_file "$n")" ]] || { print_error "出站 $n 不存在"; return 1; }
    echo "$n"
}

show_outbound() {
    local n f
    # ★ 这里原来直接收编号, 但调用链上没画列表 —— 让用户对着一句"输入出站编号"
    #   凭空猜。先画一次, 序号才有意义。
    list_outbounds
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    print_title "出站详情 $n"
    jq . "$f" >&2
}

edit_outbound() {
    list_outbounds
    local n f c
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    print_title "修改出站 $n"
    # ★ 原来用裸 echo 画菜单 + xr_read 收号（且 c 没 local, 会泄漏）。
    ui_menu 1 "向导修改（重新填写核心信息）"
    ui_menu 2 "直接编辑原始 JSON（自由定制）"
    ui_menu 3 "重新分配 IPv6 源地址"
    ui_menu 0 "返回"
    c=$(ui_ask_num "请选择" 1 3) || { ui_note "已取消"; return; }
    case "$c" in
        1)
            # 向导修改：只更新核心字段，其余（传输/安全等）保留原 JSON 原样，尊重自由定制
            local oldname oldaddr oldport proto
            oldname=$(jq -r '._meta.name // empty' "$f")
            oldaddr=$(jq -r '.outbounds[0].settings.vnext[0].address // .outbounds[0].settings.servers[0].address // .outbounds[0].settings.address // empty' "$f")
            oldport=$(jq -r '.outbounds[0].settings.vnext[0].port // .outbounds[0].settings.servers[0].port // .outbounds[0].settings.port // empty' "$f")
            proto=$(jq -r '._meta.proto' "$f")
            OB_NAME=$(safe_read "显示名称" "$oldname")
            OB_ADDR=$(safe_read "服务器 IP/域名" "$oldaddr")
            OB_PORT=$(safe_read_int "端口" "$oldport")
            OB_SEND=$(safe_read "源IP绑定(当前: $(jq -r '.outbounds[0].sendThrough // "无"' "$f"))" "$(jq -r '.outbounds[0].sendThrough // empty' "$f")")

            local nu
            case "$proto" in
                vless|vmess)
                    nu=$(safe_read "UUID" "$(jq -r '.outbounds[0].settings.vnext[0].users[0].id' "$f")")
                    jq --arg name "$OB_NAME" --arg addr "$OB_ADDR" --arg port "$OB_PORT" \
                       --arg uuid "$nu" --arg send "$OB_SEND" \
                       '._meta.name=$name |
                        .outbounds[0].settings.vnext[0].address=$addr |
                        .outbounds[0].settings.vnext[0].port=($port|tonumber) |
                        .outbounds[0].settings.vnext[0].users[0].id=$uuid |
                        .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
                trojan)
                    nu=$(safe_read "密码" "$(jq -r '.outbounds[0].settings.servers[0].password' "$f")")
                    jq --arg name "$OB_NAME" --arg addr "$OB_ADDR" --arg port "$OB_PORT" \
                       --arg pass "$nu" --arg send "$OB_SEND" \
                       '._meta.name=$name |
                        .outbounds[0].settings.servers[0].address=$addr |
                        .outbounds[0].settings.servers[0].port=($port|tonumber) |
                        .outbounds[0].settings.servers[0].password=$pass |
                        .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
                shadowsocks)
                    nu=$(safe_read "密码" "$(jq -r '.outbounds[0].settings.servers[0].password' "$f")")
                    local mm
                    mm=$(safe_read "加密方式" "$(jq -r '.outbounds[0].settings.servers[0].method' "$f")")
                    jq --arg name "$OB_NAME" --arg addr "$OB_ADDR" --arg port "$OB_PORT" \
                       --arg pass "$nu" --arg method "$mm" --arg send "$OB_SEND" \
                       '._meta.name=$name |
                        .outbounds[0].settings.servers[0].address=$addr |
                        .outbounds[0].settings.servers[0].port=($port|tonumber) |
                        .outbounds[0].settings.servers[0].password=$pass |
                        .outbounds[0].settings.servers[0].method=$method |
                        .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
                hysteria2)
                    nu=$(safe_read "密钥/密码" "$(jq -r '.outbounds[0].settings.password' "$f")")
                    local sni2
                    sni2=$(safe_read "SNI" "$(jq -r '.outbounds[0].settings.tls.serverName' "$f")")
                    jq --arg name "$OB_NAME" --arg addr "$OB_ADDR" --arg port "$OB_PORT" \
                       --arg pass "$nu" --arg sni "$sni2" --arg send "$OB_SEND" \
                       '._meta.name=$name |
                        .outbounds[0].settings.address=$addr |
                        .outbounds[0].settings.port=($port|tonumber) |
                        .outbounds[0].settings.password=$pass |
                        .outbounds[0].settings.tls.serverName=$sni |
                        .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
                freedom)
                    jq --arg name "$OB_NAME" --arg send "$OB_SEND" \
                       '._meta.name=$name | .outbounds[0].sendThrough=$send' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                    ;;
            esac
            print_ok "已更新 out-$n"
            ;;
        2)
            nano "$f"
            print_ok "已保存（注意保持 JSON 合法，运行菜单 9 校验）"
            ;;
        3)
            local prefix addr
            prefix=$(jq -r '._meta.pool.prefix // empty' "$f")
            if [[ -z "$prefix" ]]; then
                prefix=$(pool_prefix) || true
                if [[ -z "$prefix" ]]; then
                    prefix=$(detect_v6_prefix) || true
                    [[ -n "$prefix" ]] && print_info "已自动检测到 IPv6 前缀: $prefix"
                fi
                [[ -z "$prefix" ]] && { print_error "未找到 IPv6 前缀，请先在池菜单中设置"; return 1; }
            fi
            addr=$(gen_v6_address "$prefix") || return 1
            assign_v6 "$addr" "$prefix" || return 1
            # 释放旧的
            local old
            old=$(jq -r '._meta.pool.address // empty' "$f")
            [[ -n "$old" ]] && release_v6 "$old"
            jq --arg pa "$prefix" --arg aa "$addr" \
                '._meta.pool = {prefix:$pa, address:$aa} | .outbounds[0].sendThrough = $aa' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
            print_ok "新源IPv6: $addr（注意：如需更换网卡地址请先删旧）"
            ;;
        0) return ;;
        *) print_error "无效选项" ;;
    esac
}

copy_outbound() {
    list_outbounds
    local n f nn proto tag name
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    nn=$(get_next_index)
    tag=$(out_tag "$nn")
    proto=$(jq -r '._meta.proto' "$f")
    name=$(jq -r '._meta.name // empty' "$f")
    name=$(safe_read "新显示名称" "${name}-副本")
    OB_POOL=""
    # 若源是 freedom v6，分配新地址
    if [[ "$proto" == "freedom" && -n "$(jq -r '._meta.pool.address // empty' "$f")" ]]; then
        local prefix addr
        prefix=$(jq -r '._meta.pool.prefix' "$f")
        addr=$(gen_v6_address "$prefix") || return 1
        assign_v6 "$addr" "$prefix" || return 1
        OB_POOL="${prefix}|${addr}"
        print_ok "为副本分配新源IPv6: $addr"
    fi
    jq --arg tag "$tag" --arg name "$name" \
       --arg pool "$OB_POOL" \
       '.outbounds[0].tag=$tag | ._meta.name=$name |
        if $pool != "" then ._meta.pool = {prefix:($pool|split("|")[0]), address:($pool|split("|")[1])} | .outbounds[0].sendThrough = ($pool|split("|")[1]) else ._meta.pool = null | del(.outbounds[0].sendThrough) end' \
       "$f" > "$(out_file "$nn")"
    print_ok "已复制为 out-$nn (tag=$tag)"
}

delete_outbound() {
    list_outbounds
    local n f tag deps
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    tag=$(out_tag "$n")

    # 保护 direct / block（它们属于 nginx.json）
    if [[ "$tag" == "direct" || "$tag" == "block" ]]; then
        print_error "$tag 是基础出站，不允许删除"
        return 1
    fi

    deps=$(read_bindings | grep "=${tag}$" | cut -d= -f1)
    # ★ 原来这里是 `printf "…是否继续? [y/N]: " ` 紧跟 `xr_read "确认? (y/N)"`,
    #   同一个确认**问了两遍**; 而且 yn 没 local。统一走 ui_confirm（只问一次）。
    if [[ -n "$deps" ]]; then
        print_error "警告：$tag 当前被以下入站使用："
        echo "$deps" | sed 's/^/  /' >&2
        if ! ui_confirm "删除后这些入站将自动恢复为默认出站(${DEFAULT_OUTBOUND})。是否继续?"; then
            print_info "已取消"
            return
        fi
        # 移除绑定
        if [[ -f "$ROUTING_FILE" ]]; then
            jq --arg t "$tag" '._meta.bindings |= with_entries(select(.value != $t))' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
        fi
    else
        if ! ui_confirm "确认删除出站 $n ($tag) ?"; then
            print_info "已取消"
            return
        fi
    fi

    # 释放 IPv6
    local old
    old=$(jq -r '._meta.pool.address // empty' "$f")
    [[ -n "$old" ]] && release_v6 "$old"

    rm -f "$f"
    write_routing
    print_ok "已删除出站 $n ($tag)"
}

# ================================
# 出站测试
# ================================
# ★ 按**显示宽度**补齐, 不用 printf %-18s。
#   %-18s 按**字节**算: "出口IPv6" 是 10 字节 / 12 列, "DNS" 是 3 列 ——
#   同一个 %-18s 让中文标签那一整列比 ASCII 标签多占 2 格, 冒号全部对不齐。
#   这里走共享层的 ui_pad_w（ui_cjk_w 判定，中文记 2 列）。
say() { printf "${CYAN}%s${RESET} %s\n" "$(ui_pad_w "$1" 18)" "$2" >&2; }

test_outbound() {
    list_outbounds
    # ★ out / got / msg 原来没 local —— 跑一次测试就把它们泄漏到全局,
    #   下一个协议分支（乃至别的脚本 source 进来）会读到上一次的残留。
    local n f proto addr port sni send v6 out got msg
    n=$(pick_outbound) || return 1
    f=$(out_file "$n")
    proto=$(jq -r '._meta.proto' "$f")
    addr=$(jq -r '.outbounds[0].settings.vnext[0].address // .outbounds[0].settings.servers[0].address // .outbounds[0].settings.address // empty' "$f")
    port=$(jq -r '.outbounds[0].settings.vnext[0].port // .outbounds[0].settings.servers[0].port // .outbounds[0].settings.port // empty' "$f")
    sni=$(jq -r '.outbounds[0].settings.tls.serverName // .outbounds[0].streamSettings.tlsSettings.serverName // .outbounds[0].streamSettings.realitySettings.serverName // empty' "$f")
    send=$(jq -r '.outbounds[0].sendThrough // empty' "$f")

    print_title "测试出站 out-$n ($proto)"

    # 1. DNS
    if [[ "$addr" =~ ^[0-9a-fA-F:]+$ && "$addr" != *"."* ]]; then
        say "DNS" "地址是纯 IPv6，跳过 DNS 解析"
    elif [[ "$addr" =~ ^[0-9.]+$ ]]; then
        say "DNS" "地址是纯 IPv4，跳过 DNS 解析"
    else
        if getent ahosts "$addr" >/dev/null 2>&1; then
            say "DNS" "解析成功: $(getent ahosts "$addr" | head -1 | awk '{print $1}')"
        else
            say "DNS" "解析失败"
        fi
    fi

    # 2. TCP 连接
    if timeout 5 bash -c "echo > /dev/tcp/$addr/$port" 2>/dev/null; then
        say "TCP" "$addr:$port 连通"
    else
        say "TCP" "$addr:$port 连接失败（可能被墙或端口不通）"
    fi

    # 3. TLS 握手（tls/reality/hy2/trojan）
    if [[ -n "$sni" && -x "$(command -v openssl)" ]]; then
        # 判据用 "BEGIN CERTIFICATE"（1.1.1 和 3.x 都会打）:
        #   * OpenSSL 3.x 起**不再打印** "CONNECTION ESTABLISHED"（只有 1.1.1 打）,
        #     原来按它判断 —— 在 3.x 上握手成功也一律报"握手失败"（实测命中 0 次）。
        #   * 也不再走管道: `... | grep -q` 会让 s_client 吃 SIGPIPE(141),
        #     本脚本开着 pipefail, 明明成功也会判成失败。
        local tls_out="" tls_rc=0
        tls_out=$(echo | timeout 8 openssl s_client -connect "$addr:$port" -servername "$sni" 2>/dev/null) || tls_rc=$?
        if [[ "$tls_out" == *"BEGIN CERTIFICATE"* || "$tls_out" == *"CONNECTION ESTABLISHED"* ]]; then
            say "TLS" "握手成功 (sni=$sni)"
        elif [[ "$tls_rc" -eq 0 && -n "$tls_out" ]]; then
            say "TLS" "握手成功 (sni=$sni, 未取到证书)"
        else
            say "TLS" "握手失败（Reality 或证书校验属正常，以实际流量为准）"
        fi
    fi

    # 4. 代理握手 / 出口验证：Freedom 有源IP时实测出口
    if [[ "$proto" == "freedom" ]]; then
        if [[ -n "$send" ]]; then
            if [[ "$send" == *":"* ]]; then
                # 源IPv6：先确认已挂载到网卡，未挂载则尝试补救并明示
                if ! addr_on_iface "$send"; then
                    say "源IP" "地址 $send 未挂载到任何网卡！正在尝试挂载..."
                    assign_v6 "$send" "$(jq -r '._meta.pool.prefix // empty' "$f")" || say "源IP" "⚠️ 挂载失败：该出站当前不可用，请检查 IPv6 路由/隧道"
                fi
                out=$(curl -6 --interface "$send" -s --max-time 12 https://api6.ipify.org 2>/dev/null; curl -6 --interface "$send" -s --max-time 12 https://ipv6.icanhazip.com 2>/dev/null)
                got=$(echo "$out" | head -1)
                if [[ -n "$got" ]]; then
                    say "出口IPv6" "出口=$got (期望=$send) $([[ "$got" == "$send" ]] && echo -e "${GREEN}一致✓${RESET}" || echo -e "${YELLOW}不一致!${RESET}")"
                else
                    say "出口IPv6" "无法通过该源IP访问公网（检查 IPv6 路由/隧道/防火墙）"
                fi
            else
                got=$(curl -4 --interface "$send" -s --max-time 12 https://api.ipify.org 2>/dev/null)
                if [[ -n "$got" ]]; then
                    say "出口IPv4" "出口=$got (期望=$send) $([[ "$got" == "$send" ]] && echo -e "${GREEN}一致✓${RESET}" || echo -e "${YELLOW}不一致!${RESET}")"
                else
                    say "出口IPv4" "无法通过该源IP访问公网"
                fi
            fi
        else
            msg=$(curl -4 -s --max-time 12 https://api.ipify.org 2>/dev/null)
            say "出口IPv4" "默认出口 IPv4: ${msg:-未知}"
        fi
    else
        say "代理" "远程节点连通性已测（完整代理路径需通过入站映射后访问验证）"
    fi
}

# ================================
# 一键更换落地 IPv6（手动按需"用完即换"，每次换一个全新随机源IP）
# 单出站方案：生成新IP → 挂载 → 写回 → 释放旧IP → 重启
# ================================
rotate_out6() {
    # ★ sel / c / rr 原来都没 local —— 泄漏到全局。
    local n f prefix old tag sel addr rr i
    print_title "更换落地 IPv6（手动按需）"
    # 只处理 Freedom 带源IPv6 的出站
    local -a v6n=()
    for n in $(out_numbers); do
        f=$(out_file "$n")
        [[ "$(jq -r '.outbounds[0].protocol' "$f")" == "freedom" ]] || continue
        [[ "$(jq -r '.outbounds[0].sendThrough // empty' "$f")" == *":"* ]] && v6n+=("$n")
    done
    if ((${#v6n[@]} == 0)); then
        print_error "没有带源IPv6 的 Freedom 出站。请先在 菜单2→6 Freedom→3 自动分配IPv6 创建一个。"
        return 1
    fi
    if ((${#v6n[@]} == 1)); then
        n=${v6n[0]}
        print_info "将更换 Freedom 出站 $(out_tag "$n")"
    else
        # ★ 原来 `printf "请选择: " ` 紧跟 `xr_read "请输入"`, 问题问两遍;
        #   而且列表用 `echo "  $((i+1))) $ot"`（右括号都多打了一个）。
        #   现在列表用 ui_menu, 收号用 ui_ask_num —— 取消 = 不换, 回到调用菜单。
        for i in "${!v6n[@]}"; do
            ui_menu $((i + 1)) "$(out_tag "${v6n[$i]}")"
        done
        sel=$(ui_ask_num "选择要更换落地IP的出站" 1 "${#v6n[@]}") || { ui_note "已取消"; return 1; }
        n=${v6n[$((sel - 1))]}
    fi
    f=$(out_file "$n")
    tag=$(out_tag "$n")
    old=$(jq -r '.outbounds[0].sendThrough' "$f")
    # 前缀：优先出站 _meta.pool.prefix，其次池前缀，再次自动检测
    prefix=$(jq -r '._meta.pool.prefix // empty' "$f")
    [[ -z "$prefix" ]] && prefix=$(pool_prefix)
    [[ -z "$prefix" ]] && prefix=$(detect_v6_prefix) || true
    [[ -z "$prefix" ]] && { print_error "无法确定 IPv6 池前缀（请先在池菜单设置）"; return 1; }
    print_info "新IP将取自前缀: $prefix"
    # ★ 原来 `printf "确认更换 … y/N: " ` 紧跟 `xr_read "请选择"`, 确认问了两遍。
    ui_confirm "确认更换 ${tag} 的落地IPv6 (当前 $old)?" || { print_info "已取消"; return 1; }

    addr=$(gen_v6_address "$prefix") || return 1
    # 挂载新地址（失败则中止，绝不留假配置）
    assign_v6 "$addr" "$prefix" || return 1
    # 写回（更新 _meta.pool 与 sendThrough）
    if ! jq --arg pa "$prefix" --arg aa "$addr" \
        '._meta.pool = {prefix:$pa, address:$aa} | .outbounds[0].sendThrough = $aa' "$f" > "${f}.tmp" 2>/dev/null; then
        release_v6 "$addr"; print_error "写回配置失败，已撤销新IP"; return 1
    fi
    mv "${f}.tmp" "$f"
    # 释放旧地址（新IP已用，若冲突释放旧IP）
    [[ -n "$old" && "$old" != "$addr" ]] && release_v6 "$old"
    print_ok "已更换: ${tag} 落地IPv6 = $addr"
    egress_check "$addr"
    # 提示重启使 live 进程加载
    [[ -n "$1" ]] && return 0
    # ★ 同样是 printf + xr_read 的双提示。
    if ui_confirm "重启 xrayls 使新IP生效?"; then
        restart_xrayls
    else
        print_info "未重启。新IP已挂载并写入配置，但 xrayls 仍用旧出站。请稍后菜单9 重启。"
    fi
    return 0
}

# 批量预生成多个 IPv6（不写配置，只挂载+显示，供手动挑选/备用）
gen_pool_batch() {
    print_title "批量生成落地 IPv6（备用池）"
    local prefix cnt i a
    prefix=$(pool_prefix) || true
    [[ -z "$prefix" ]] && prefix=$(detect_v6_prefix) || true
    [[ -z "$prefix" ]] && { print_error "无法确定前缀（请先在池菜单设置）"; return 1; }
    # ★ 原来 `printf "前缀 %s；生成数量(默认8): " ` 紧跟 `xr_read "请输入"` ——
    #   同一个问题问两遍, 而且前半句在前半行、后半句在后半行, 读起来像两句话。
    ui_note "前缀 $prefix"
    cnt=$(ui_ask "生成数量" 8)
    [[ "$cnt" =~ ^[0-9]+$ ]] || { print_error "数量非法"; return 1; }
    (( cnt > 200 )) && cnt=200
    echo "已生成(已挂载到网卡，可任选一个写进出站):" >&2
    for i in $(seq 1 "$cnt"); do
        a=$(gen_v6_address "$prefix") || continue
        assign_v6 "$a" "$prefix" 2>/dev/null
        echo "  $a" >&2
    done
    echo "提示: 通过 菜单3 修改出站→填写源IP 使用；不想要的可手动删除: ip -6 addr del <ip>/128 dev <网卡>" >&2
}

# ================================
# 绑定管理
# ================================
# 判断出站是否 v6-only（freedom + sendThrough 为 IPv6）——绑定到它会打不开 v4-only 站
is_v6only_outbound() {
    local f="$1"
    local proto send
    proto=$(jq -r '.outbounds[0].protocol' "$f" 2>/dev/null)
    send=$(jq -r '.outbounds[0].sendThrough // empty' "$f" 2>/dev/null)
    [[ "$proto" == "freedom" && "$send" == *":"* ]]
}

bind_menu() {
    print_title "入站 → 出站绑定管理"
    [[ -f "$ROUTING_FILE" ]] || echo '{"_meta":{"bindings":{}}}' > "$ROUTING_FILE"
    local -a ins outs
    mapfile -t ins < <(inbound_tags)
    mapfile -t outs < <(out_numbers)

    if ((${#ins[@]} == 0)); then
        print_info "未发现任何入站（conf 目录里没有 inbounds 片段）"
        return
    fi
    if ((${#outs[@]} == 0)); then
        print_info "尚无出站，请先新增"
        return
    fi

    # ★ i / x / y / z 原来都没 local —— 循环变量漏到全局, 外面同名循环会被串味。
    local i inbound ot otname yk z
    while [[ "$XR_EOF" == "0" ]]; do
        # ★ 两个动态列表改成 ui_pick: 原来用 `printf "  %d) %s"` 手画序号,
        #   紧接着又是 `printf "选择: " ` + `xr_read "请输入"` 的双提示,
        #   越界只报一句"无效入站"（连列表一起重画都没有）。
        #   ★「默认出站」那一行原来只是"列表末尾多一个数字", key 和真实 tag 混在
        #     同一个序号空间里; 现在给它独立 key __default__, 不可能和真 tag 混淆。
        UI_PICK_COLS=(入站)
        UI_PICK_ROWS=""
        for i in "${!ins[@]}"; do
            UI_PICK_ROWS+="${ins[$i]}"$'\t'"${ins[$i]}"$'\n'
        done
        # 取消（含 0/EOF）= 退出绑定菜单, 与原来的 "0) 退出" 同一层
        ui_pick "选择入站" "未发现任何入站" "选择入站" || break
        inbound="$UI_PICK_KEY"

        UI_PICK_COLS=(出站 名称)
        UI_PICK_ROWS=""
        for i in "${!outs[@]}"; do
            ot=$(out_tag "${outs[$i]}")
            otname=$(jq -r '._meta.name // empty' "$(out_file "${outs[$i]}")")
            UI_PICK_ROWS+="$ot"$'\t'"$ot"$'\t'"${otname:--}"$'\n'
        done
        UI_PICK_ROWS+="__default__"$'\t'"默认出站"$'\t'"$DEFAULT_OUTBOUND"$'\n'
        # 取消 = 这一轮不绑, 回到入站选择（与原来 "回车 → continue" 同一层）
        ui_pick "选择出站（${inbound} 将绑定到）" "尚无出站" "选择出站" || continue
        yk="$UI_PICK_KEY"

        if [[ "$yk" == "__default__" ]]; then
            # 绑定到默认 → 移除绑定
            jq --arg k "$inbound" '._meta.bindings |= del(.[$k])' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" 2>/dev/null && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE" 2>/dev/null
            print_ok "$inbound → 默认出站($DEFAULT_OUTBOUND)"
        else
            ot="$yk"
            local onum="${ot#out-}"
            if [[ -f "$ROUTING_FILE" ]]; then
                jq --arg k "$inbound" --arg v "$ot" '._meta.bindings[$k]=$v' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
            else
                jq -n --arg k "$inbound" --arg v "$ot" '{_meta:{bindings:{($k):$v}}}' > "$ROUTING_FILE"
            fi
            print_ok "$inbound → $ot"
            # v6-only 出站警示：纯IPv6落地打不开纯IPv4网站
            if is_v6only_outbound "$(out_file "$onum")"; then
                print_error "⚠ 警告：$ot 是纯IPv6落地（sendThrough=IPv6），纯IPv4网站（browserleaks/matrix/github等）将无法访问！"
                print_info "建议：用 split.sh 给这些站加分流规则指到 direct/v4 落地；或改用菜单7绑定默认出站(direct，双栈自动)。"
            fi
        fi
        write_routing
        # ★ 同样是 printf + xr_read 的双提示; 空/0 结束, 与原来一致。
        z=$(ui_ask "继续绑定其它入站（回车继续，0 结束）" "")
        [[ "$z" == "0" ]] && break
    done
    validate_config
}

# ================================
# 查看映射
# ================================
view_mapping() {
    print_title "Inbound → Outbound"
    echo "==================================================" >&2
    # ★ 表头和数据行原来**用两套宽度**：表头是 `%-16s %-14s`（按字节），数据行
    #   也是 —— 但表头写的是中文"入站/出站/类型"（各 6 字节 / 4 列），数据行的
    #   $tag 是纯 ASCII。于是"出站"这一列表头在第 17 列起，而数据行的出站名
    #   （含 `默认(direct)` 这种中文混排）按字节补齐 —— 两列**必然**对不上。
    #   这里先按显示宽度算出真实列宽，表头和数据行共用 ui_pad_w。
    local -a tags=() c1=() c2=() c3=()
    local tag bind bname bproto
    while IFS= read -r tag; do
        [[ -n "$tag" ]] && tags+=("$tag")
    done < <(inbound_tags)
    local binds; binds=$(read_bindings)
    for tag in "${tags[@]}"; do
        bind=$(grep "^${tag}=" <<< "$binds" | cut -d= -f2)
        if [[ -n "$bind" ]]; then
            local bf
            bf="$CONF_DIR/out-$(printf "%02d" "${bind#out-}").json"
            bname=$(jq -r '._meta.name // empty' "$bf" 2>/dev/null)
            [[ -z "$bname" ]] && bname="$bind"
            bproto=$(jq -r '._meta.proto // "?"' "$bf" 2>/dev/null)
            [[ -z "$bproto" ]] && bproto="?"
        else
            bname="默认(${DEFAULT_OUTBOUND})"
            bproto="freedom"
        fi
        c1+=("$tag"); c2+=("$bname"); c3+=("$bproto")
    done
    # ★ `默认(...)` 原来被塞进 `%-14s` 里, 中文和括号按字节补齐 → 实际宽度随机
    #   变化, 每次刷新列都错。现在列宽按 ui_cjk_w 统一算, 表格自然对齐。
    local w1 w2 i t1 t2
    w1=$(ui_cjk_w "入站"); w2=$(ui_cjk_w "出站")
    for (( i = 0; i < ${#c1[@]}; i++ )); do
        t1=$(ui_cjk_w "${c1[$i]}"); (( t1 > w1 )) && w1=$t1
        t2=$(ui_cjk_w "${c2[$i]}"); (( t2 > w2 )) && w2=$t2
    done
    printf "${BOLD}%s  %s  %s${RESET}\n" \
        "$(ui_pad_w "入站" "$w1")" "$(ui_pad_w "出站" "$w2")" "类型" >&2
    for (( i = 0; i < ${#c1[@]}; i++ )); do
        printf "%s  %s  %s\n" \
            "$(ui_pad_w "${c1[$i]}" "$w1")" "$(ui_pad_w "${c2[$i]}" "$w2")" "${c3[$i]}" >&2
    done
    echo "--------------------------------------------------" >&2
    echo "带源IP的出站：" >&2
    local n f
    for n in $(out_numbers); do
        f=$(out_file "$n")
        local src pool
        src=$(jq -r '.outbounds[0].sendThrough // empty' "$f")
        pool=$(jq -r '._meta.pool.address // empty' "$f")
        if [[ -n "$pool" || -n "$src" ]]; then
            printf "  %s  SourceIP: %s\n" "$(out_tag "$n")" "${pool:-$src}" >&2
        fi
    done
}

# ================================
# IPv6 地址池菜单
# ================================
pool_menu() {
    while [[ "$XR_EOF" == "0" ]]; do
        print_title "IPv6 地址池管理"
        # ★ c 原来没 local; 菜单用裸 echo（与其余菜单不齐平）; 收号走 xr_read。
        local cur c
        cur=$(pool_prefix)
        ui_note "当前池前缀: ${cur:-未设置}"
        ui_menu 1 "检测/设置前缀"
        ui_menu 2 "查看已分配地址"
        ui_menu 3 "分配一个新地址并写入出站"
        ui_menu 0 "返回"
        c=$(ui_ask_num "请选择" 1 3) || { ui_note "已返回"; return; }
        case "$c" in
            1)
                local detected=""
                detected=$(detect_v6_prefix) || true
                [[ -n "$detected" ]] && print_info "自动检测到 IPv6 /64: $detected（回车使用）"
                local p
                p=$(safe_read "IPv6 前缀(/64)" "${cur:-$detected}")
                [[ -n "$p" ]] && { set_pool_prefix "$p"; print_ok "前缀已设置: $p"; }
                ;;
            2)
                local n f ad
                for n in $(out_numbers); do
                    f=$(out_file "$n")
                    ad=$(jq -r '._meta.pool.address // empty' "$f")
                    [[ -n "$ad" ]] && printf "  %s → %s\n" "$(out_tag "$n")" "$ad" >&2
                done
                ;;
            3)
                local prefix addr
                prefix=$(pool_prefix) || true
                if [[ -z "$prefix" ]]; then
                    prefix=$(detect_v6_prefix) || true
                    [[ -n "$prefix" ]] && print_info "已自动检测到 IPv6 前缀: $prefix"
                fi
                [[ -z "$prefix" ]] && { print_error "未检测到 IPv6 /64，请先在选项 1 手动设置前缀"; continue; }
                addr=$(gen_v6_address "$prefix") || continue
                assign_v6 "$addr" "$prefix" || continue
                print_ok "新地址: $addr（已挂载；可在 修改出站 → 3. 重新分配IPv6 写入某出站）"
                ;;
        esac
        # ★ 裸 `read` 在 EOF 时立刻返回 —— 管道喂完输入会在这里**空转刷屏**。
        ui_pause
    done
}

# ================================
# 校验 / 重启
# ================================
validate_config() {
    if [[ -z "$XRAY_BIN" ]]; then
        print_error "未找到 xray 二进制，无法校验"
        return 1
    fi
    print_title "校验 Xray 配置"
    local out
    out=$("$XRAY_BIN" run -test -confdir "$CONF_DIR" 2>&1)
    if [[ "$out" == *"Configuration OK."* ]]; then
        print_ok "Configuration OK."
    else
        print_error "配置校验失败："
        echo "$out" | tail -8 >&2
    fi
}

# 服务名解析 (xrayls / xray 双代兼容) 与重启逻辑收敛到 conf/lib/service.sh。
# 这里曾各写一份 if/elif, 新脚本再写一份, 改一处漏两处的概率很高。
_x_svc_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib"
if [[ -r "$_x_svc_lib_dir/service.sh" ]]; then
    source "$_x_svc_lib_dir/service.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/service.sh") \
        || { print_error "服务库加载失败"; return 1; }
fi

restart_xrayls() {
    x_svc_restart
}

# ================================
# 落地自检：配置 / 绑定完整性 / 服务 / IPv6 出口 / MTU 一体体检
# ================================
out_tag_exists() { # $1 = 出站 tag，扫描全部片段（含 nginx.json 的 direct/block）
    local f c
    shopt -s nullglob
    for f in "$CONF_DIR"/*.json; do
        [[ "$(basename "$f")" == "${OB_PREFIX}-routing.json" ]] && continue
        c=$(jq -r --arg t "$1" '([.outbounds[]? | select(.tag==$t)] | length)' "$f" 2>/dev/null)
        [[ "$c" == "1" ]] && return 0
    done
    return 1
}

# 单个落地地址的出口/MTU 实测
diag_egress() { # $1 = 源IPv6
    local a="$1" got res
    local -a pcmd=()
    command -v ping6 >/dev/null 2>&1 && pcmd=(ping6)
    command -v ping6 >/dev/null 2>&1 || { command -v ping >/dev/null 2>&1 && pcmd=(ping -6); }

    # ICMP 源地址绑定能力探测（inetutils 版 ping6 不支持 -I，自动降级）
    if ((${#pcmd[@]} == 0)); then
        res="invalid option"
    else
        res=$("${pcmd[@]}" -c 1 -w 1 -I ::1 ::1 2>&1)
    fi
    if [[ "$res" == *"invalid option"* || "$res" == *"unrecognized"* ]]; then
        printf "  [ICMP] 本机 ping 工具不支持指定源地址，已跳过 ICMP/MTU 探测（以 HTTP/HTTPS 判定为准）\n" >&2
    else
        printf "  [ICMP] %s %s ... " "${pcmd[*]}" "$a" >&2
        res=$("${pcmd[@]}" -c 2 -w 3 -I "$a" ipv6.icanhazip.com 2>&1)
        if [[ "$res" == *"received"* && "$res" != *"0 received"* && "$res" != *"100% packet loss"* ]]; then echo "通 ✓" >&2
        else echo "不通 ✗（若 HTTP/HTTPS 均通 → 多为 ISP 过滤 ICMPv6，可忽略）" >&2; fi

        printf "  [MTU]  1200B 包: " >&2
        res=$("${pcmd[@]}" -c 2 -w 3 -s 1200 -I "$a" ipv6.icanhazip.com 2>&1)
        if [[ "$res" == *"received"* && "$res" != *"0 received"* && "$res" != *"100% packet loss"* ]]; then echo "通" >&2
        else echo "不通 ✗（隧道疑似异常）" >&2; fi
        printf "  [MTU]  1400B 包(总1448<1480): " >&2
        res=$("${pcmd[@]}" -c 2 -w 3 -s 1400 -I "$a" ipv6.icanhazip.com 2>&1)
        if [[ "$res" == *"received"* && "$res" != *"0 received"* && "$res" != *"100% packet loss"* ]]; then echo "通" >&2
        else
            echo "不通 ✗" >&2
            printf "  └─ 修复建议: %s\n" "ip -6 route replace ::/0 dev <隧道口> mtu 1280" >&2
        fi
    fi

    got=$(curl -6 --interface "$a" -s --max-time 8 http://ipv6.icanhazip.com 2>/dev/null | head -1)
    if [[ -n "$got" ]]; then
        if [[ "$(canon6 "$got")" == "$(canon6 "$a")" ]]; then printf "  [HTTP ] 通，出口=%s ✓\n" "$got" >&2
        else printf "  [HTTP ] 通，出口=%s（≠ 本地址，运营商改写/NAT）\n" "$got" >&2; fi
    else printf "  [HTTP ] 不通 ✗（已挂载但出不去 → 隧道路由或防火墙）\n" >&2; fi

    got=$(curl -6 --interface "$a" -s --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | head -1)
    if [[ -n "$got" ]]; then
        if [[ "$(canon6 "$got")" == "$(canon6 "$a")" ]]; then printf "  [HTTPS] 通，出口=%s ✓\n" "$got" >&2
        else printf "  [HTTPS] 通，出口=%s（≠ 本地址）\n" "$got" >&2; fi
    else printf "  [HTTPS] 不通 ✗（HTTP通而HTTPS不通 → 典型 PMTU 黑洞，建议压 MTU: ip -6 route replace ::/0 dev <隧道口> mtu 1280）\n" >&2; fi
}

diag_landing() {
    print_title "落地自检（配置 · 绑定 · 服务 · IPv6出口 · MTU）"
    local n f tag proto send pp vout v4got dev
    local -a nr outs ins
    local -a v6_outs=()

    # 1) 出站配置现状
    echo "[1] 出站片段:" >&2
    mapfile -t nr < <(out_numbers)
    if ((${#nr[@]} == 0)); then
        echo "    （无 out-*.json）" >&2
    else
        for n in "${nr[@]}"; do
            f=$(out_file "$n")
            tag=$(out_tag "$n")
            proto=$(jq -r '.outbounds[0].protocol // "?"' "$f")
            send=$(jq -r '.outbounds[0].sendThrough // empty' "$f")
            if [[ "$proto" == "freedom" && -n "$send" && "$send" == *":"* ]]; then
                v6_outs+=("$tag|$send")
                printf "    %s (%s) 源IPv6=%s\n" "$tag" "$proto" "$send" >&2
            else
                printf "    %s (%s) 无源IP绑定\n" "$tag" "$proto" >&2
            fi
        done
    fi

    # 2) 绑定完整性（映射指向不存在的出站 = xrayls 可能起不来）
    echo "[2] 入站→出站绑定表:" >&2
    if [[ ! -f "$ROUTING_FILE" ]]; then
        echo "    out-routing.json 不存在（尚未做任何绑定）" >&2
    elif [[ -z "$(jq -r '._meta.bindings // empty | keys[]' "$ROUTING_FILE" 2>/dev/null)" ]]; then
        echo "    绑定表为空" >&2
    else
        mapfile -t ins < <(inbound_tags)
        while IFS='=' read -r ib ob; do
            [[ -z "$ib" || -z "$ob" ]] && continue
            printf "    %s → %s" "$ib" "$ob" >&2
            if ! out_tag_exists "$ob"; then
                printf "   ★ 找不到出站 %s（xrayls -test 会失败/起不来！）\n" "$ob" >&2
            else
                echo "" >&2
            fi
            if ! [[ " ${ins[*]} " == *" $ib "* ]]; then
                print_info "    （提示）入站 $ib 在 conf 中无对应 inbounds 片段"
            fi
        done < <(jq -r '._meta.bindings | to_entries[] | "\(.key)=\(.value)"' "$ROUTING_FILE" 2>/dev/null)
    fi

    # 3) 服务状态 + 二进制
    echo "[3] 服务 / 二进制:" >&2
    printf "    xrayls 服务: " >&2
    if declare -F x_svc_installed >/dev/null 2>&1 && x_svc_installed; then
        echo "$(x_svc_status_text)" >&2
    elif pgrep -f "xrayls|xray " >/dev/null 2>&1; then
        echo "运行中(pgrep)" >&2
    else
        echo "未运行" >&2
    fi
    printf "    xray 二进制: %s\n" "${XRAY_BIN:-未找到}" >&2

    # 4) 全配置校验（-test）
    if [[ -n "$XRAY_BIN" ]]; then
        echo "[4] 配置校验 (run -test -confdir):" >&2
        vout=$("$XRAY_BIN" run -test -confdir "$CONF_DIR" 2>&1)
        if [[ "$vout" == *"Configuration OK."* ]]; then
            printf "    "; print_ok "Configuration OK."
        else
            print_error "    校验失败："
            echo "$vout" | tail -6 | sed 's/^/    /' >&2
        fi
    fi

    # 5) 池前缀
    pp=$(pool_prefix)
    printf "[5] IPv6 池前缀: %s\n" "${pp:-（未设置）}" >&2

    # 6) 逐落地地址实测
    if ((${#v6_outs[@]} == 0)); then
        echo "[6] 无带源IPv6 的 Freedom 出站（跳过出口实测；可在菜单 2→6→3 创建）" >&2
    else
        local o tag2 a
        for o in "${v6_outs[@]}"; do
            tag2=${o%%|*}; a=${o##*|}
            echo "[6] 落地出站 $tag2 源IPv6=$a:" >&2
            if addr_on_iface "$a"; then
                printf "    "; print_ok "已挂载到网卡"
                diag_egress "$a"
            else
                print_error "    ★ 未挂载到任何网卡！此出站必然不可用"
                printf "    └─ 修复: 菜单 3 修改出站 → 3.重新分配IPv6，或手动\n" >&2
                printf "       ip -6 addr add %s/128 dev <网卡> nodad\n" "$a" >&2
            fi
        done
    fi

    # 7) IPv4 基线（排除整机断网干扰；多端点回退，避免单个 API 误报）
    echo "[7] IPv4 出口基线:" >&2
    local v4got v4ep
    for v4ep in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
        v4got=$(curl -4 -s --max-time 8 "$v4ep" 2>/dev/null | head -1)
        [[ -n "$v4got" ]] && break
    done
    printf "    出口IPv4: %s\n" "${v4got:-无法连通（多端点全失败 → 整机 v4 网络异常，与落地IP无关，先修服务器）}" >&2

    printf "\n诊断结束：把以上输出发出来即可定位问题\n" >&2
}

# ================================
# 主菜单
# ================================
main_menu() {
    while [[ "$XR_EOF" == "0" ]]; do
        print_title "Xray 出站管理面板"
        menu_item 1  "查看出站"
        menu_item 2  "新增出站"
        menu_item 3  "修改出站"
        menu_item 4  "删除出站"
        menu_item 5  "复制出站"
        menu_item 6  "测试出站"
        menu_item 7  "入站→出站绑定管理"
        menu_item 8  "查看入站→出站映射"
        menu_item 9  "校验配置 / 重启服务"
        menu_item 10 "IPv6 地址池管理"
        menu_item 11 "落地自检（IPv6出口/MTU/配置体检）"
        menu_item 12 "一键更换落地 IPv6（用完即换）"
        menu_item 13 "批量生成落地 IPv6（备用池）"
        menu_item 14 "双栈 v4 域名名单管理"
        menu_quit "退出"
        local c; c=$(menu_ask "请输入菜单序号") || { XR_EOF=1; return; }

        case $c in
            1) list_outbounds ;;
            2) add_outbound ;;
            3) edit_outbound ;;
            4) delete_outbound ;;
            5) copy_outbound ;;
            6) test_outbound ;;
            7) bind_menu ;;
            8) view_mapping ;;
            9)
                print_title "校验 / 重启"
                validate_config
                ui_confirm "重启 xrayls 服务?" && restart_xrayls
                ;;
            10) pool_menu ;;
            11) diag_landing ;;
            12) rotate_out6 ;;
            13) gen_pool_batch ;;
            14) dual_domains ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        # ★ 原来是 `printf "(按回车继续)"` + 裸 `read`：EOF 时立刻返回，
        #   while 循环会**空转刷屏**（和 inbound.sh 当年刷 18 万行同一个成因）。
        ui_pause
    done
}

# 支持被 source 后直接调用内部函数做自动化测试
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_menu
fi
