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
#
# ★ 本文件自己写的每一句都是**界面** → 一律 >&2。
#   stdout 留空是刻意的: journalctl 的输出是**数据** (用户要看的东西本身),
#   保留在 stdout 才能 `source logs.sh; log_lines 200 > /tmp/x.log`。
#   混在数据里的提示会让下游拿到一堆中文垃圾 —— 参见 conf/lib/print.sh 开头。

_LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_x_lib_dir_log=""

# ★ 现拉的库要有地方放、退出时要删掉。
#   面板每开一次菜单就是一个新进程, 现拉一次就留一个 mktemp 文件在 /tmp ——
#   加了 ui.sh 之后是每开一次菜单漏两个 (print.sh + ui.sh)。
_LOG_TMPDIR="$(mktemp -d -t xraylogs.XXXXXX 2>/dev/null || true)"
trap '[[ -n "${_LOG_TMPDIR:-}" ]] && rm -rf "$_LOG_TMPDIR"' EXIT

# 优先同目录的 service.sh; 经 curl 执行时本脚本是临时文件, 同目录不存在。
if [[ -r "$_LOG_DIR/lib/service.sh" ]]; then
    source "$_LOG_DIR/lib/service.sh"
else
    svc="$(mktemp -t service.XXXXXX.sh)"
    trap 'rm -f "$svc"' RETURN
    curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/service.sh" \
        -o "$svc" || { printf '\033[31m[错误] 获取 service.sh 失败\033[0m\n' >&2; return 1; }
    source "$svc"
fi

_lg()  { printf '\033[36m%s\033[0m\n' "$*" >&2; }
_lgy() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

# ★ 排版 (print.sh) 与交互 (ui.sh) 都要取, 而且顺序是 print.sh 在前:
#   ui.sh 的 ui_pick / ui_table_print / ui_ask_num 会调 print.sh 的
#   ui_title / ui_pause, 反过来 source 就是 command not found。
#   原来只取了 print.sh —— 于是"行数"只能 read -rp, "服务状态"只能 sed 一层
#   缩进 —— 库明明就在旁边。
_x_ui_lib() {   # <库名> -> 打印一个可读路径
    local name="${1:-print.sh}" self f
    self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    for f in "$self/lib/$name" "${XRAY_BASE:-/root/catmi/xray}/conf/lib/$name"; do
        [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    [[ -n "$_LOG_TMPDIR" ]] || return 1
    f="$_LOG_TMPDIR/$name"
    curl -fsSL \
        "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/$name" \
        -o "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
    rm -f "$f"; return 1
}
f=$(_x_ui_lib print.sh) && source "$f" 2>/dev/null || true
f=$(_x_ui_lib ui.sh)     && source "$f" 2>/dev/null || true

# ★ 库拉不到时的兜底 (排版/交互都不能缺, 缺一个菜单就点不动)。
#   有真库时绝不用这两段覆盖样式, 所以判据是函数在不在。
if ! declare -F ui_menu >/dev/null 2>&1; then
    ui_rule() { printf '%s\n' "----------------------------------------" >&2; }
    ui_title() { ui_rule; printf ' %s\n' "$1" >&2; ui_rule; }
    ui_sec()  { printf '\n %s\n' "$1" >&2; }
    ui_menu() { printf '  %2s) %s\n' "$1" "$2" >&2; }
    ui_hint() { printf '  %s\n' "$1" >&2; }
    ui_kv()   { printf '   %s: %s\n' "$1" "$2" >&2; }
    ui_invalid() { printf '  无效选项: %s\n' "$1" >&2; }
    ui_pause() { printf '\n' >&2; read -r -p "  按回车返回..." _ || true; }
fi
if ! declare -F ui_pad_w >/dev/null 2>&1; then
    ui_note()  { printf '  %s\n' "$1" >&2; }
    ui_pad_w() { printf '%s' "$1"; }
    ui_ask() {   # <提示> [默认值] -> stdout
        local p="$1" d="${2-}" a=""
        if [[ -n "$d" ]]; then
            read -r -p "  $p (回车=$d): " a || a=""
        else
            read -r -p "  $p: " a || a=""
        fi
        printf '%s' "${a:-$d}"
    }
fi

log_lines() {
    local n="${1:-100}"
    x_svc_resolve >/dev/null
    [[ "$X_SVC_RESOLVED" == "1" ]] || {
        printf '  未检测到 xray 服务 (%s)\n' "$X_SVC_NAME" >&2; return 1; }
    timeout 15 journalctl -u "$X_SVC_NAME" -n "$n" --no-pager 2>/dev/null
}

log_explain() {
    x_svc_resolve >/dev/null
    [[ "$X_SVC_RESOLVED" == "1" ]] || {
        printf '  未检测到 xray 服务 (%s)\n' "$X_SVC_NAME" >&2; return 1; }
    x_svc_explain_errors
}

log_follow() {
    x_svc_resolve >/dev/null
    [[ "$X_SVC_RESOLVED" == "1" ]] || {
        printf '  未检测到 xray 服务 (%s)\n' "$X_SVC_NAME" >&2; return 1; }
    _lgy "跟随 $X_SVC_NAME 日志, Ctrl-C 退出"
    timeout 300 journalctl -u "$X_SVC_NAME" -f --no-pager 2>/dev/null
}

log_status() {
    x_svc_resolve >/dev/null
    ui_kv "服务" "$X_SVC_NAME"
    ui_kv "状态" "$(x_svc_status_text)"
    ui_sec "端口占用"
    # ★ 原来是把 ss -tulnp 整行原样 sed 两格缩进。那是给机器看的格式:
    #   列宽由 ss 自己按最长那一行撑, users:(("xray",pid=1234,fd=6)) 一长就
    #   折行, 混进别的进程时右边参差不齐 —— 用户要看的其实只有
    #   「哪个协议 / 哪个地址 / 谁的进程」。这里用 awk 拆成三列, 列宽交给
    #   ui_pad_w 按显示宽度自适应 (conf/lib/ui.sh)。
    if ! command -v ss >/dev/null 2>&1; then
        ui_note "(本机没有 ss, 读不到端口占用)"
        return 0
    fi
    local rows
    rows=$(ss -tulnpH 2>/dev/null \
           | grep -E 'xray|:(443|8443)[[:space:]]' | head -8 \
           | awk '{ proto=$1; addr=$5; proc=""
                   for (i=1; i<=NF; i++) if ($i ~ /^users:/) proc=$i
                   gsub(/users:\(\(/, "", proc); sub(/,pid=.*/, "", proc)
                   gsub(/"/, "", proc)
                   printf "%s\t%s\t%s\n", proto, addr, proc }')
    if [[ -z "$rows" ]]; then
        ui_note "(没有匹配的监听 —— 可能确实没起, 或 ss 读不到别人的进程)"
        return 0
    fi
    printf '  %s %s %s\n' "$(ui_pad_w 协议 6)" "$(ui_pad_w 本地地址 24)" "进程" >&2
    printf '  %s\n' "----------------------------------------" >&2
    local proto addr proc
    while IFS=$'\t' read -r proto addr proc; do
        [[ -n "$proto" ]] || continue
        printf '  %s %s %s\n' \
            "$(ui_pad_w "$proto" 6)" "$(ui_pad_w "${addr:--}" 24)" "${proc:--}" >&2
    done <<< "$rows"
}

log_menu() {
    while :; do
        printf '\n' >&2
        ui_title "日志"
        ui_menu 1 "最近 100 行"
        ui_menu 2 "最近 300 行"
        ui_menu 3 "自定义行数"
        ui_menu 4 "报错解释       把内核报错翻成人话"
        ui_menu 5 "跟随输出"
        ui_menu 6 "服务状态与端口占用"
        ui_menu 0 "返回"
        # ★ 删掉原来紧跟其后的七行 echo 原样复刻 —— 菜单每轮画两遍, 而且两遍
        #   措辞还不一样 (第 4 项一处带括号对齐、一处不带), 用户没法判断哪
        #   一份才是菜单。ui_menu 那一份就够了。
        printf '  请选择: ' >&2
        # ★ stdin 关闭 (EOF) 时 read 返回非 0 且不修改 $c, case 落到 *) 后回到
        #   循环顶再读一次 —— 菜单空转刷屏, 永不退出。实测修前:
        #   timeout 10 bash conf/logs.sh </dev/null → rc=124 (10 秒 390 行菜单)。
        #   EOF 等同"用户返回", 直接退出菜单。
        read -r c || return 0
        case "$c" in
            # ★ 每个动作后都 ui_pause —— 「跟随输出」跑满 300 秒回来, 「报错
            #   解释」能刷几十行, 没有暂停的话最后那行结论直接被顶出屏幕。
            1) log_lines 100; ui_pause ;;
            2) log_lines 300; ui_pause ;;
            3)
                # ★ 默认值 100 原来只活在代码里 (`n="${n:-100}"`), 屏幕上从来
                #   没出现过 —— 用户不知道回车会发生什么。ui_ask 会把
                #   "(回车=100)" 印在提示后面。
                #   顺带挡一下非数字: journalctl -n abc 只会吐一句 usage,
                #   用户会以为"这台机器没日志"。
                local n
                while :; do
                    n=$(ui_ask "行数" 100)
                    [[ "$n" =~ ^[0-9]+$ ]] && break
                    ui_invalid "$n —— 行数要是数字"
                done
                log_lines "$n"
                ui_pause
                ;;
            4) log_explain; ui_pause ;;
            5) log_follow; ui_pause ;;
            6) log_status; ui_pause ;;
            0) return 0 ;;
            # ★ 这里原来手写了 '\033[31m 无效选项 \033[0m' —— 和同文件 47 行
            #   已经定义好的 ui_invalid 一字不差, 只是没人调用过。
            *) ui_invalid "$c" ;;
        esac
    done
}

[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] && log_menu
