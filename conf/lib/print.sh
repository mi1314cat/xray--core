#!/usr/bin/env bash
# =============================================================
# 提示函数 —— 单一实现
#
# ★ 为什么必须收成一处:
#
#   conf/node.sh / conf/share.sh / conf/share_service.sh 原来各自抄了一份
#   **逐字节相同**的四行 ok/info/warn/err（`md5` 完全一致）。
#
#   抄三遍的代价不是多占 12 行，而是"改一处漏两处"。已知会踩的坑就有两个：
#
#     1) 颜色没在非终端时关掉 —— 重定向到日志时每行都带 ^[[32m 这类转义
#        序列, grep 起来全是噪音, 而且看起来像"颜色坏了", 却查不到原因。
#     2) 输出到了 stdout 而不是 stderr —— 见下。
#
# ★ 一律写 stderr, 这不是风格问题:
#
#   这些脚本的 stdout 是**数据通道**。node.sh 把自己的结果交给
#   xray_run / 订阅生成去解析, share.sh 把分享链接打到 stdout。提示一旦
#   混进 stdout, 下游就会把 "[OK] 已创建" 当成链接去解析 —— 症状是
#   "分享出来的链接偶尔是中文", 极难定位。
#
# ★ 颜色变量只在调用方没设时兜底:
#
#   有的脚本（install.sh 等）用另一套变量名（GRN/RST）。强行统一会打断
#   它们自己的配色, 所以这里只补空缺, 不覆盖已有值。
# =============================================================

if [[ -z "${_GRN+x}" ]]; then
    _RED=$'\033[31m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'
    _CYN=$'\033[36m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
    # 只有写终端时颜色才有意义。
    if [[ ! -t 2 ]]; then
        _RED=""; _GRN=""; _YEL=""; _CYN=""; _DIM=""; _RST=""
    fi
fi

ok()   { printf "  ${_GRN}[OK]${_RST} %s\n" "$*" >&2; }
info() { printf "  ${_CYN}[--]${_RST} %s\n" "$*" >&2; }
warn() { printf "  ${_YEL}[!]${_RST} %s\n" "$*" >&2; }
err()  { printf "  ${_RED}[X]${_RST} %s\n" "$*" >&2; }

# die 是 err + 退出。放在这里而不是各脚本里, 因为"退出码是多少"必须一致 ——
# 调用方（面板 xray_run）靠退出码判断成功与否, 各处自己写就容易有的 1 有的 2。
die()  { err "$*"; exit 1; }

# 供调用方自检: `declare -F ok >/dev/null` 比 `command -v ok` 可靠 ——
# 后者会把外部可执行文件也算进来。
__x_print_ready=1

# ------------------------------------------------------------ 面板排版 ----
# 与客户端 (Client/lib/core.sh) 和另外两个内核同名的 ui_* 一套。
#
# ★ 全部写 stderr。服务端这些脚本的 stdout 是**数据通道**（分享链接、订阅
#   内容、ID 列表），把菜单画到 stdout 会把下游解析搞坏 —— 见文件开头。
#
# ★ 颜色同样只在 stderr 是终端时给：菜单重定向到日志时不该带转义序列。
ui_w() {
    local w; w=$(tput cols 2>/dev/null || true)
    case "$w" in ''|*[!0-9]*) w=44 ;; esac
    (( w > 100 )) && w=100
    printf '%s' "$w"
}
ui_rule() {
    local n i line=""
    n=$(ui_w)
    for (( i = 0; i < n; i++ )); do line+="─"; done
    printf '%s%s%s\n' "$_CYN" "$line" "$_RST" >&2
}
ui_title() {
    ui_rule
    printf ' %s%s%s\n' "$_CYN" "$1" "$_RST" >&2
    ui_rule
}
ui_sec()  { printf ' %s%s%s\n' "$_DIM" "$1" "$_RST" >&2; }
ui_menu() { printf '  %s%2s%s) %s\n' "$_CYN" "$1" "$_RST" "$2" >&2; }
ui_hint() { printf '  %s%s%s\n' "$_DIM" "$1" "$_RST" >&2; }
ui_tip()  { printf '  %s提示%s: %s\n' "$_CYN" "$_RST" "$1" >&2; }
ui_invalid() { printf '  %s无效选项: %s%s\n' "$_RED" "$1" "$_RST" >&2; }
ui_pause() { printf '\n' >&2; read -r -p "  按回车返回..." _ || true; }

# 中文按显示宽度补齐（printf 的 %-Ns 按字节, 中文标签必错位）
ui_pad() {
    local t="$1" w=0 i ch
    for (( i = 0; i < ${#t}; i++ )); do
        ch="${t:i:1}"
        if [[ "$ch" == [$'\u4e00'-$'\u9fff'] ]]; then w=$((w + 2)); else w=$((w + 1)); fi
    done
    printf '%s%*s' "$t" $(( $2 - w )) ""
}
ui_kv() { printf '   %s : %s\n' "$(ui_pad "$1" 10)" "$2" >&2; }

# 横幅。默认是 X 的那只猫 —— 与 xray-panel.sh 里原来手写的一致。
ui_banner() { # [标题]
    printf '\n                       |\__/,|   (\\\n' >&2
    printf '                     _.|o o  |_   ) )\n' >&2
    printf '       -------------(((---(((-------------------\n' >&2
    printf '                   %s\n' "${1:-catmi.xrayls}" >&2
    printf '       -----------------------------------------\n\n' >&2
}
