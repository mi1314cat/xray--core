#!/usr/bin/env bash
# 日志 —— 查看 xray 服务日志并把报错翻成人话
#
# 为什么不做成普通的 journalctl 转调: 内核日志里出现的是
#   "failed to read config file" / "unknown field: xxx" / "address already in use"
# 用户看到这些时不知道该去做什么 —— 打开的是配置语法错误, 实际要改的是
# 某个已废弃的字段。x_svc_explain_errors 把这些映射成"哪个文件、哪个字段、
# 怎么改"。
#
# 实际日志读取在 conf/lib/service.sh, 本文件负责交互与分页。

_LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_x_lib_dir_log=""

# 优先同目录的 service.sh; 经 curl 执行时本脚本是临时文件, 同目录不存在。
if [[ -r "$_LOG_DIR/lib/service.sh" ]]; then
    source "$_LOG_DIR/lib/service.sh"
else
    svc="$(mktemp -t service.XXXXXX.sh)"
    trap 'rm -f "$svc"' RETURN
    curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/service.sh" \
        -o "$svc" || { printf '\033[31m[错误] 获取 service.sh 失败\033[0m\n'; return 1; }
    source "$svc"
fi

_lg()  { printf '\033[36m%s\033[0m\n' "$*"; }
# 菜单排版用 conf/lib/print.sh 的 ui_*；取不到就用朴素版（排版失败不该让菜单打不开）
_x_ui_lib() {
    local self f
    self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    for f in "$self/lib/print.sh" "${XRAY_BASE:-/root/catmi/xray}/conf/lib/print.sh"; do
        [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    f=$(mktemp -t print.XXXXXX) && curl -fsSL \
        "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/print.sh" \
        -o "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
    rm -f "$f"; return 1
}
f=$(_x_ui_lib) && source "$f" 2>/dev/null || true
if ! declare -F ui_menu >/dev/null 2>&1; then
    ui_rule() { printf '%s\n' "----------------------------------------"; }
    ui_title() { ui_rule; printf ' %s\n' "$1"; ui_rule; }
    ui_sec()  { printf '\n %s\n' "$1"; }
    ui_menu() { printf '  %2s) %s\n' "$1" "$2"; }
    ui_hint() { printf '  %s\n' "$1"; }
    ui_kv()   { printf '   %s: %s\n' "$1" "$2"; }
    ui_invalid() { printf '  无效选项: %s\n' "$1"; }
fi

_lgy() { printf '\033[33m%s\033[0m\n' "$*"; }

log_lines() {
    local n="${1:-100}"
    x_svc_resolve >/dev/null
    [[ "$X_SVC_RESOLVED" == "1" ]] || {
        printf '  未检测到 xray 服务 (%s)\n' "$X_SVC_NAME"; return 1; }
    timeout 15 journalctl -u "$X_SVC_NAME" -n "$n" --no-pager 2>/dev/null
}

log_explain() {
    x_svc_resolve >/dev/null
    [[ "$X_SVC_RESOLVED" == "1" ]] || {
        printf '  未检测到 xray 服务 (%s)\n' "$X_SVC_NAME"; return 1; }
    x_svc_explain_errors
}

log_follow() {
    x_svc_resolve >/dev/null
    [[ "$X_SVC_RESOLVED" == "1" ]] || {
        printf '  未检测到 xray 服务 (%s)\n' "$X_SVC_NAME"; return 1; }
    _lgy "跟随 $X_SVC_NAME 日志, Ctrl-C 退出"
    timeout 300 journalctl -u "$X_SVC_NAME" -f --no-pager 2>/dev/null
}

log_status() {
    x_svc_resolve >/dev/null
    _lg "服务: $X_SVC_NAME"
    printf '  状态: %s\n' "$(x_svc_status_text)"
    _lg "端口占用:"
    ss -tulnp 2>/dev/null | grep -E "xray|:443 |:8443 " | head -8 | sed 's/^/  /' \
        || printf '    (无法读取, 本机 ss 可能不支持)\n'
}

log_menu() {
    while :; do
        echo
        ui_title "日志"
        ui_menu 1 "最近 100 行"
        ui_menu 2 "最近 300 行"
        ui_menu 3 "自定义行数"
        ui_menu 4 "报错解释       把内核报错翻成人话"
        ui_menu 5 "跟随输出"
        ui_menu 6 "服务状态与端口占用"
        ui_menu 0 "返回"
        echo "  1) 最近 100 行"
        echo "  2) 最近 300 行"
        echo "  3) 自定义行数"
        echo "  4) 报错解释 (把内核报错翻成人话)"
        echo "  5) 跟随输出"
        echo "  6) 服务状态与端口占用"
        echo "  0) 返回"
        printf "  请选择: "
        read -r c
        case "$c" in
            1) log_lines 100 ;;
            2) log_lines 300 ;;
            3) read -rp "  行数: " n; n="${n:-100}"; log_lines "$n" ;;
            4) log_explain ;;
            5) log_follow ;;
            6) log_status ;;
            0) return 0 ;;
            *) printf '\033[31m  无效选项\033[0m\n' ;;
        esac
    done
}

[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] && log_menu