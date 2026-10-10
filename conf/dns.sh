#!/usr/bin/env bash
# DNS 管理 —— 编辑 config.json 的 dns 段
#
# 为什么单独做: Xray 的 dns 段是严格 schema, 手改 config.json 改错了要等到
# 下次重启才发现内核拒。这里把增删改做成命令, 每次写入前先做 schema 校验,
# 写入后立刻 xray run -test, 不通过就回滚。
#
# 操作实际由 conf/lib/dns_edit.py 完成 —— 本文件只负责交互与呈现。

_DNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MAIN_CONFIG="${XRAY_BASE:-/root/catmi/xray}/config.json"
[[ -z "${MAIN_CONFIG:-}" ]] && MAIN_CONFIG="/root/catmi/xray/config.json"

_g()  { printf '\033[32m%s\033[0m\n' "$*"; }
_y()  { printf '\033[33m%s\033[0m\n' "$*"; }
_e()  { printf '\033[31m%s\033[0m\n' "$*"; }
_i()  { printf '\033[36m%s\033[0m\n' "$*"; }

# 优先用同目录的 dns_edit.py; 面板经 curl 执行时本脚本是临时文件,
# 同目录不存在, 这时从仓库取。与项目其它入口一致: 远程取, 不 vendor。
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

dns_run() {
    local script="$_DNS_DIR/lib/dns_edit.py"
    if [[ ! -r "$script" ]]; then
        script="$(mktemp -t dns_edit.XXXXXX.py)"
        trap 'rm -f "$script"' RETURN
        curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/dns_edit.py" \
            -o "$script" || { _e "获取 dns_edit.py 失败"; return 1; }
    fi
    python3 "$script" "$@"
}

# 写入并校验。xray 不在 PATH 时 (容器/最小安装) 跳过校验但仍做 schema 校验 ——
# 跳过要说明, 不能让用户以为验过了。
dns_apply() {
    if command -v xray >/dev/null 2>&1; then
        dns_run --config "$MAIN_CONFIG" "$@" --test
    else
        _y "提示: 未找到 xray 可执行文件, 只做 schema 校验, 跳过内核校验"
        dns_run --config "$MAIN_CONFIG" "$@" --no-reload
    fi
}

dns_show() {
    _i "当前 DNS 配置 ($MAIN_CONFIG):"
    dns_run --config "$MAIN_CONFIG" --get | sed 's/^/  /'
    echo
    _i "说明:"
    _y "  未配置 dns 段时内核用内置解析: 明文、无 fallback。"
    _y "  服务端解析被劫持会污染分流判断 —— 配置分流前先确认这一段。"
}

dns_add() {
    local addr port domains
    read -rp "DNS 服务器地址 (如 1.1.1.1 或 tls://1.1.1.1): " addr
    [[ -n "$addr" ]] || { _e "地址不能为空"; return 1; }
    read -rp "端口 (回车用默认): " port
    read -rp "只用于这些域名 (逗号分隔, 回车=全部): " domains

    local args=(--add-server --server-address "$addr")
    [[ -n "$port"    ]] && args+=(--server-port "$port")
    [[ -n "$domains" ]] && args+=(--server-domains "$domains")
    dns_apply "${args[@]}"
}

dns_del() {
    local addr
    read -rp "要删除的 DNS 服务器地址: " addr
    [[ -n "$addr" ]] || { _e "地址不能为空"; return 1; }
    dns_run --config "$MAIN_CONFIG" --del-server "$addr"
}

dns_strategy() {
    local s
    _i "queryStrategy:"
    _y "  1) UseIP    双栈, 都试"
    _y "  2) UseIPv4  只用 IPv4 (国内机器最常用)"
    _y "  3) UseIPv6  只用 IPv6"
    read -rp "选择 (默认2): " s
    case "$s" in
        1) dns_apply --query-strategy UseIP ;;
        3) dns_apply --query-strategy UseIPv6 ;;
        *) dns_apply --query-strategy UseIPv4 ;;
    esac
}

dns_hosts() {
    local dom ip
    read -rp "静态解析 域名: " dom
    read -rp "        指向 IP: " ip
    [[ -n "$dom" && -n "$ip" ]] || { _e "域名与 IP 都要填"; return 1; }
    dns_apply --host "$dom=$ip"
}

dns_nofallback() {
    _y "禁用 fallback 意味着所有 DNS 服务器都失败时不再用默认值兜底,"
    _y "解析会直接失败而不是悄悄返回一个错的地址。"
    read -rp "确认禁用? (y/N): " s
    [[ "$s" == "y" || "$s" == "Y" ]] || return 0
    dns_apply --no-fallback
}

dns_reset() {
    _e "这会删除整个 dns 段, 内核退回内置默认解析 (明文、无 fallback)。"
    read -rp "输入 RESET 确认: " s
    [[ "$s" == "RESET" ]] || { _y "已取消"; return 0; }
    if command -v xray >/dev/null 2>&1; then
        dns_run --config "$MAIN_CONFIG" --set-json '{}' --test
    else
        dns_run --config "$MAIN_CONFIG" --set-json '{}' --no-reload
    fi
}

dns_menu() {
    while :; do
        echo
        ui_title "DNS 管理"
        ui_menu 1 "查看当前配置"
        ui_menu 2 "添加/更新 DNS 服务器"
        ui_menu 3 "删除 DNS 服务器"
        ui_menu 4 "设置解析策略 (queryStrategy)"
        ui_menu 5 "添加静态解析 (hosts)"
        ui_menu 6 "禁用 fallback"
        ui_menu 7 "清空整个 dns 段"
        ui_menu 0 "返回"
        echo "  1) 查看当前配置"
        echo "  2) 添加/更新 DNS 服务器"
        echo "  3) 删除 DNS 服务器"
        echo "  4) 设置解析策略 (queryStrategy)"
        echo "  5) 添加静态解析 (hosts)"
        echo "  6) 禁用 fallback"
        echo "  7) 清空整个 dns 段"
        echo "  0) 返回"
        printf "  请选择: "
        # ★ stdin 关闭 (EOF) 时 read 返回非 0 且不修改 $c, case 落到 *) 后回到
        #   循环顶再读一次 —— 菜单空转刷屏, 永不退出。实测修前:
        #   timeout 10 bash conf/dns.sh </dev/null → rc=124 (10 秒 275 行菜单)。
        #   EOF 等同"用户返回", 直接退出菜单。
        read -r c || return 0
        case "$c" in
            1) dns_show ;;
            2) dns_add ;;
            3) dns_del ;;
            4) dns_strategy ;;
            5) dns_hosts ;;
            6) dns_nofallback ;;
            7) dns_reset ;;
            0) return 0 ;;
            *) _e "无效选项" ;;
        esac
    done
}

[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] && dns_menu