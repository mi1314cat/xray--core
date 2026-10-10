#!/usr/bin/env bash
# =============================================================
# 节点命名 —— 单一实现
#
# ★ 为什么要统一:
#
#   项目里的 tag 原来是各处随手拼的 (mknode.sh 是 `proto-tr-sec-port`,
#   协议脚本各写各的), 实测同一台机器上并存这些形态:
#
#       VLESS-WS_01   TROJAN-01   vless-xhttp01   hysteria-01   SS2022-01
#
#   大小写混用、`_` 与 `-` 混用、编号位数不一 (01 / 1 / 无编号)。后果:
#     · 按前缀筛节点写不准 (''VLESS-*'' 与 ''vless-*'' 是两拨)
#     · 分享链接的 fragment 跟着乱, 客户端列表里认不出谁是谁
#     · 三个内核混用同一台机器时, 看不出哪个节点是哪个内核建的
#
# ★ 采用的约定 (对照 sing-box-core 的 `vmess01-TLS-CDN` 形态, 加 x 前缀):
#
#       x-<协议><两位编号>-<安全>[-CDN]
#
#       x-vless01-TLS        x-trojan02-REALITY
#       x-vmess01-TLS-CDN    x-hysteria201-TLS
#
#   · 全小写协议名 + 两位编号: 排序稳定, 前缀筛选准确
#   · 安全等级大写: 一眼看出 TLS / REALITY / none
#   · CDN 后缀: 表明这个节点是走 CDN 的 (与直连节点区分)
#   · **x- 前缀**: 三个内核共用一个服务器时能认出这是 Xray 建的
# =============================================================

# 协议名规范化 —— 把各处写法收敛成一种
x_proto_slug() {
    local p="${1:-node}"
    p="${p,,}"                       # 全小写
    p="${p//[^a-z0-9]/}"             # 去掉分隔符与其它字符
    case "$p" in
        ss|shadowsocks)          printf 'ss' ;;
        ss2022|shadowsocks2022)  printf 'ss2022' ;;
        hy2|hysteria)            printf 'hysteria2' ;;
        *)                       printf '%s' "$p" ;;
    esac
}

# 安全等级规范化: 大写, 认不出的原样大写
x_sec_slug() {
    local s="${1:-none}"
    s="${s,,}"
    case "$s" in
        tls)            printf 'TLS' ;;
        reality)        printf 'REALITY' ;;
        none|"")        printf 'none' ;;
        *)              printf '%s' "${s^^}" ;;
    esac
}

# x_node_tag <协议> <编号> [安全] [cdn]
#
# 编号补零到两位 (1 -> 01); 已经两位以上的原样 (100 -> 100)。
x_node_tag() {
    local proto; proto=$(x_proto_slug "${1:-node}")
    local idx="${2:-1}"
    local sec;   sec=$(x_sec_slug "${3:-none}")
    local cdn="${4:-}"

    [[ "$idx" =~ ^[0-9]+$ ]] || idx=1
    (( idx < 10 )) && idx="0$idx"

    local tag="x-${proto}${idx}-${sec}"
    [[ "$cdn" == "cdn" || "$cdn" == "1" ]] && tag="${tag}-CDN"
    printf '%s' "$tag"
}

# 下一个可用编号 —— 让同一协议的节点编号连续, 而不是每次从 1 开始撞。
#
# 扫 conf 目录里已有的 tag, 找出 `x-<协议><编号>-…` 形态的最大编号 +1。
# 认不出就返回 1。
x_next_index() { # <协议> [conf 目录]
    local proto; proto=$(x_proto_slug "${1:-node}")
    local dir="${2:-${CONF_DIR:-${XRAY_CONF_DIR:-/root/catmi/xray/conf}}}"
    local n
    n=$(PROTO="$proto" DIR="$dir" python3 - <<'PY' 2>/dev/null
import glob, json, os, re, sys
proto = os.environ["PROTO"]; d = os.environ["DIR"]
pat = re.compile(r"^x-" + re.escape(proto) + r"(\d+)-", re.I)
best = 0
for f in glob.glob(os.path.join(d, "*.json")):
    try:
        j = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    for ib in (j.get("inbounds") or []):
        m = pat.match(str(ib.get("tag", "")))
        if m:
            best = max(best, int(m.group(1)))
print(best + 1)
PY
)
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && printf '%s' "$n" || printf '1'
}

# 显示名默认值 —— 用户在"显示名称"那一栏直接回车时用的。
#
# ★ 原来 8 处都是 `safe_read "显示名称" ""`: 默认值是**空串**。用户回车之后
#   节点就没有名字, 而分享链接的 fragment 为空会让客户端退化成用域名当名字
#   (Client/lib/node.py 的 `name = fragment or hostname`) —— 同一域名下的节点
#   在列表里全叫一个名, 分不清谁是谁。
x_default_name() { # <协议> [编号] [安全] [cdn]
    x_node_tag "$@"
}

# ---------------------------------------------------------------- 显示名
#
# ★ 旗帜 + 服务器前缀 + 节点名（对照 sing-box-core 的 sb_server_name）。
#   实现只有一份, 在 conf/lib/naming.py 里 —— 分享载荷是 python 拼的,
#   两边各写一套必然漂移, 而漂移的表现是"面板里显示 🇺🇸 X-… ,
#   客户端拿到的是 X-…", 很难查。
#
#   tag（内部标识）一个字都不改: 它要进配置、当文件名、进分享链接的
#   fragment —— 必须是稳定 ASCII。旗帜只出现在**给人看的地方**。

# 找一下 naming.py: 脚本旁边 → 安装目录 → 现拉（与其它 lib 同一套三级查找）
_x_naming_py() {
    local d self
    self=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)
    for d in "$self" "${XRAY_CONF_DIR:-${CONF_DIR:-/root/catmi/xray/conf}}/lib" \
             /root/catmi/xray/conf/lib; do
        [[ -f "$d/naming.py" ]] && { printf '%s' "$d/naming.py"; return 0; }
    done
    printf '%s' "$self/naming.py"
}

_x_naming() { # <子命令> [参数…]
    local py; py=$(_x_naming_py)
    [[ -f "$py" ]] || return 1
    XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}" python3 "$py" "$@" 2>/dev/null
}

# 当前旗帜（可能是空串 —— 查不到就不带旗帜, 功能不受影响）
x_flag() { _x_naming flag; }

# 服务器前缀（环境变量 XRAY_SERVER_NAME → 缓存 → 默认 X）
x_server_prefix() { _x_naming prefix; }

# 给人看的完整服务器标识: 旗帜 + 前缀
x_server_id() { _x_naming server; }

# 节点显示名 = <旗帜> <前缀>-<节点名（去掉 x-）>
x_display_name() { # <tag>
    _x_naming display "${1:-}"
}

# 交互式问一次服务器标识。默认值就是当前值（旗帜 + 前缀）,
# 用户只改名字时**旗帜要保住** —— 那是服务器的属性, 不该被改名顺带弄丢。
#
# 只在真的建节点时问, 且非交互（批量/管道）不打扰 —— 用默认值。
x_ask_server_name() {
    [[ -n "${XRAY_SERVER_NAME:-}" ]] && { export XRAY_SERVER_NAME; return 0; }
    [[ -n "${XRAY_NO_NAME_PROMPT:-}" ]] && return 0
    [[ -t 0 ]] || return 0
    local cur def v
    cur=$(_x_naming server)
    def="${cur:-X}"
    printf '\n  服务器标识（节点名前缀，多台服务器用它区分，避免客户端互相覆盖）\n' >&2
    printf '  直接回车即用默认值。当前: %s\n' "$def" >&2
    printf '  服务器标识 (默认: %s): ' "$def" >&2
    if ! IFS= read -r v; then
        printf '\n' >&2
        return 0
    fi
    v="${v:-$def}"
    v=$(_x_naming set "$v")
    XRAY_SERVER_NAME="$v"
    export XRAY_SERVER_NAME
    printf '  节点名将是: %s\n' "$(x_display_name "x-vless01-TLS")" >&2
}

# ---------------------------------------------------------------- 直跑
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-demo}" in
        tag)     shift; x_node_tag "$@" ;;
        next)    shift; x_next_index "$@" ;;
        name)    shift; x_default_name "$@" ;;
        flag)    x_flag ;;
        prefix)  x_server_prefix ;;
        server)  x_server_id ;;
        display) shift; x_display_name "${1:-}" ;;
        ask)     x_ask_server_name ;;
        pycheck) python3 "$(_x_naming_py)" --check ;;
        demo)
            printf '  内部 tag: x-<协议><两位编号>-<安全>[-CDN]\n'
            printf '  显示名  : <旗帜> <服务器前缀>-<节点名>\n'
            printf '  当前服务器标识: %s   （例如显示名: %s）\n\n' \
                "$(x_server_id)" "$(x_display_name x-vless01-TLS)"
            for a in "vless 1 tls" "vless 12 tls cdn" "trojan 2 reality" \
                     "vmess 1 tls cdn" "ss 3 none" "hysteria2 1 tls" "SS2022 4 none"; do
                # shellcheck disable=SC2086
                printf '    %-24s %s\n' "$a" "$(x_node_tag $a)"
            done
            ;;
        *) echo "用法: naming.sh [demo|tag <协议> <编号> [安全] [cdn]|next <协议> [conf目录]]" >&2; exit 1 ;;
    esac
fi
