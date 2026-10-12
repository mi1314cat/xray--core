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

# 颜色统一取 print.sh 的变量: 它只在 stderr 是终端时才给值, 于是菜单重定向到
# 日志时不会带 ^[[32m 这类转义序列 (原来这里写死转义, 每行都带)。
# ★ 四个提示函数一律写 **stderr**: 本文件的 stdout 是数据通道 (--get 的 JSON
#   要被命令替换读走), 提示混进去会让 JSON 解析在半路撞上一行中文。
_g()  { printf '%s%s%s\n' "${_GRN:-}" "$*" "${_RST:-}" >&2; }
_y()  { printf '%s%s%s\n' "${_YEL:-}" "$*" "${_RST:-}" >&2; }
_e()  { printf '%s%s%s\n' "${_RED:-}" "$*" "${_RST:-}" >&2; }
_i()  { printf '%s%s%s\n' "${_CYN:-}" "$*" "${_RST:-}" >&2; }

# 取仓库里的一个 lib 文件, 路径打到 stdout 交给调用方 source。
# 优先同目录 (面板经 curl 执行时本脚本是临时文件, 同目录不存在, 这时从
# 安装目录/远端取)。与项目其它入口一致: 远程取, 不 vendor。
_x_lib() {
    local self f
    self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    for f in "$self/lib/$1" "${XRAY_BASE:-/root/catmi/xray}/conf/lib/$1"; do
        [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    f=$(mktemp -t "${1%.sh}".XXXXXX) && curl -fsSL \
        "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/$1" \
        -o "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
    rm -f "$f"; return 1
}

f=$(_x_lib print.sh) && source "$f" 2>/dev/null || true
# ★ ui.sh 必须在 print.sh **之后** source: 它自己会调 ui_box→ui_title, ui_pause
#   也直接来自 print.sh。顺序反了就是"command not found", 菜单整个点不动。
f=$(_x_lib ui.sh) && source "$f" 2>/dev/null || true
# ★ 原来这里还有一份自己写的 ui_* 兜底 (旧的 34-42 行), 已删, 两个理由:
#     1) 那份兜底**不写 stderr** —— 一旦触发, 菜单就重新开始污染数据通道;
#     2) 它没有编号选择器、没有 ui_ask_num, 于是"库没取到"表现为"交互整个
#        换成另一种样子", 比直接报错更难排查。交互现在只有一套实现。
#   需要 ui.sh 的入口自己过 _dns_ui_need 这道门, 退化时报错而不是崩。

# ★ 需要 ui.sh 的入口先过这道门: 交互库取不到时明确说清楚缺什么, 而不是让
#   ui_pick 未定义把菜单炸掉 —— 排版/交互库取不到不该等于菜单点不动。
_dns_ui_need() { # <函数名>
    declare -F "$1" >/dev/null 2>&1 && return 0
    _e "交互库 conf/lib/ui.sh 取不到, 缺 $1"
    return 1
}

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
# ★ 子进程 (dns_edit.py) 的输出转 stderr: 它打印的是"已更新 xxx"这类提示,
#   属于 UI。只有 --get 的 JSON 是数据, 走 stdout。
dns_apply() {
    if command -v xray >/dev/null 2>&1; then
        dns_run --config "$MAIN_CONFIG" "$@" --test >&2
    else
        _y "提示: 未找到 xray 可执行文件, 只做 schema 校验, 跳过内核校验"
        dns_run --config "$MAIN_CONFIG" "$@" --no-reload >&2
    fi
}

# 把 dns 段的 servers 铺成编号表。
# ★ --get 的 JSON 是本文件里唯一走 stdout 的东西 (数据通道), 因此这里的
#   管道两端必须严格分开: JSON 进 python, 表格行进 UI_PICK_ROWS (变量),
#   任何一句提示都不许回到 stdout。
# ★ 按 address 去重: --del-server 是 x["address"] != a 一次性滤掉**所有**同名项,
#   所以同一个地址列出两行的话, 选哪一行效果都一样 —— 那是骗人的编号。
# ★ 空格位必须写 "-" 而不是留空: ui.sh 的 _ui_rows_to_arrays 用
#   `IFS=$'\t' read -r k rest` 切第一段, 而 TAB 属于 IFS 空白字符, 连续的
#   分隔符会被当成一个 —— 中间那个空"端口"字段连同它的 TAB 一起消失, 后面
#   所有列整体左移 (实测: 地址列显示成 "1" 和 "53")。_ui_split_tabs 逐个吃 TAB
#   所以没事, 但第一刀会中招。node_print_table 用 '-' 占位也是同一个原因。
_dns_servers_rows() {
    local raw
    raw=$(dns_run --config "$MAIN_CONFIG" --get) || raw=""
    UI_PICK_COLS=(地址 端口 域名数)
    UI_PICK_ROWS=""
    [[ -z "$raw" ]] && return 1
    UI_PICK_ROWS=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)          # 没 dns 段时 --get 打印的是一句提示, 不是 JSON
seen = set()
for s in (d.get("servers") or []):
    a = (s.get("address") or "").strip()
    if not a or a in seen:
        continue
    seen.add(a)
    doms = s.get("domains") or []
    print("%s\t%s\t%d" % (a, s.get("port") or "-", len(doms)))
')
    [[ -n "$UI_PICK_ROWS" ]]
}

dns_show() {
    _i "当前 DNS 配置 ($MAIN_CONFIG):"
    # ★ 不吞 stderr: 配置读不出来时 dns_edit.py 的报错必须露出来, 否则上面
    #   只会得到一张空表 + "没有可删的服务器", 用户会以为真的没配过 DNS。
    dns_run --config "$MAIN_CONFIG" --get | sed 's/^/  /' >&2
    printf '\n' >&2
    _i "说明:"
    _y "  未配置 dns 段时内核用内置解析: 明文、无 fallback。"
    _y "  服务端解析被劫持会污染分流判断 —— 配置分流前先确认这一段。"
}

dns_add() {
    local addr port domains
    # ★ 全部走 ui_ask: 提示自动缩进 2 列 (原来 read -rp 顶格, 与缩进 2 的菜单
    #   错开一格), 并且 EOF 也当默认值 —— 面板经 curl 跑时 stdin 可能直接是空的。
    addr=$(ui_ask "DNS 服务器地址 (如 1.1.1.1 或 tls://1.1.1.1)")
    [[ -n "$addr" ]] || { _e "地址不能为空"; return 1; }
    # ★ 默认值写在提示里而不是当 ui_ask 的**字面**默认值: 留空时 dns_edit.py
    #   根本不写 port 字段, 由内核取 53; 传 "53" 进去会把 "port": "53" 写进
    #   config.json, 配置从此与原来不一样 (--del-server 的表格里也会多出一列)。
    #   所以这里只把"默认是什么"讲清楚, 值仍然留空。
    port=$(ui_ask "端口 (留空=不写 port, 内核默认 53)")
    domains=$(ui_ask "只用于这些域名 (逗号分隔, 留空=对全部域名生效)")

    local args=(--add-server --server-address "$addr")
    [[ -n "$port"    ]] && args+=(--server-port "$port")
    [[ -n "$domains" ]] && args+=(--server-domains "$domains")
    dns_apply "${args[@]}"
}

dns_del() {
    _dns_ui_need ui_pick || return 1
    # ★ 原来让用户把刚打印过的地址**再打一遍** (read -rp "要删除的 DNS 服务器地址")。
    #   地址不是短词, 打错一个字符不会报错, 而是 dns_edit.py 找不到那条、只回一句
    #   "没有找到 address=xxx" —— 用户得自己回去比。于是改成编号选择:
    #   画出来的编号就是输入的编号, 打错只会重画, 不可能对不上。
    _dns_servers_rows
    ui_pick "删除 DNS 服务器" \
            "dns 段里还没有任何 servers —— 没有可删的服务器" \
            "删除" || return $?
    dns_run --config "$MAIN_CONFIG" --del-server "$UI_PICK_KEY" >&2
}

dns_strategy() {
    _dns_ui_need ui_ask_num || return 1
    local s
    _i "queryStrategy:"
    # ★ 列宽按显示宽度对齐 (printf %-Ns 按字节, 中文必歪): 原来的手写空格让
    #   三条说明落在三个不同的列上, 竖着看过去是锯齿。
    # ★ 提示里的 [1-3, 0=取消] 是 ui_ask_num 自带的, 这里不再自己拼提示行。
    printf '  %s%s%s\n' "${_CYN:-}" \
        "$(ui_pad_w '1) UseIP' 16)双栈, IPv4/IPv6 都试" "${_RST:-}" >&2
    printf '  %s%s%s\n' "${_CYN:-}" \
        "$(ui_pad_w '2) UseIPv4' 16)只用 IPv4 (国内机器最常用)${_DIM:-}← 默认${_RST:-}" "${_RST:-}" >&2
    printf '  %s%s%s\n' "${_CYN:-}" \
        "$(ui_pad_w '3) UseIPv6' 16)只用 IPv6" "${_RST:-}" >&2
    # ★ 原来没有范围校验: 输入 9 或 usipv4 会静默落到 *) 分支, 把策略写成
    #   UseIPv4 —— 打错一个字符却"成功"了, 而且看不出是哪一步错的。
    #   现在越界重画同一个列表。空回车 = 取消 (原来空回车会**直接**写 UseIPv4)。
    s=$(ui_ask_num "选择解析策略" 1 3) || return 0
    case "$s" in
        1) dns_apply --query-strategy UseIP ;;
        2) dns_apply --query-strategy UseIPv4 ;;
        3) dns_apply --query-strategy UseIPv6 ;;
    esac
}

dns_hosts() {
    local dom ip
    dom=$(ui_ask "静态解析 域名")
    ip=$(ui_ask "        指向 IP")
    [[ -n "$dom" && -n "$ip" ]] || { _e "域名与 IP 都要填"; return 1; }
    dns_apply --host "$dom=$ip"
}

dns_nofallback() {
    _y "禁用 fallback 意味着所有 DNS 服务器都失败时不再用默认值兜底,"
    _y "解析会直接失败而不是悄悄返回一个错的地址。"
    # ui_confirm 自己带提示和"回车=取消", 不用再 read -rp 顶格拼一行。
    # 它接受 yes/y/Y —— 原来的 y/Y 仍然有效。
    ui_confirm "确认禁用 fallback?" || { _y "已取消"; return 0; }
    dns_apply --no-fallback
}

dns_reset() {
    _e "这会删除整个 dns 段, 内核退回内置默认解析 (明文、无 fallback)。"
    # ★ 这里保留"手打 RESET"而不是换成 ui_confirm: 这是唯一一处打错代价是
    #   整段配置没了的动作, 确认词必须是用户**看得见自己要打什么**的那几个字。
    local s
    s=$(ui_ask "输入 RESET 确认 (回车=取消)")
    [[ "$s" == "RESET" ]] || { _y "已取消"; return 0; }
    if command -v xray >/dev/null 2>&1; then
        dns_run --config "$MAIN_CONFIG" --set-json '{}' --test >&2
    else
        dns_run --config "$MAIN_CONFIG" --set-json '{}' --no-reload >&2
    fi
}

dns_menu() {
    local c rc
    while :; do
        printf '\n' >&2
        ui_title "DNS 管理"
        ui_menu 1 "查看当前配置"
        ui_menu 2 "添加/更新 DNS 服务器"
        ui_menu 3 "删除 DNS 服务器"
        ui_menu 4 "设置解析策略 (queryStrategy)"
        ui_menu 5 "添加静态解析 (hosts)"
        ui_menu 6 "禁用 fallback"
        ui_menu 7 "清空整个 dns 段"
        ui_menu 0 "返回"
        # ★ 删掉了紧跟着的**第二份**菜单 (原来的 148-155 行): ui_menu 已经画过
        #   一模一样的 8 行, 裸 echo 又画一遍, 于是每轮循环 16 行菜单 —— 用户
        #   要在两份重复的列表里对号入座, 屏幕还白占一半。
        #
        # ★ 收编号交给 ui_ask_num: 自带 [0-7, 0=取消] 范围提示、非数字与越界都
        #   重画, 并且 EOF 直接返回 1。
        #   ★ EOF 处理: 原来 `read -r c || return 0` 那条注释仍然成立 —— stdin
        #     关闭时 ui_ask_num 同样返回 1, 所以下面 `|| return 0` 就是"EOF 等同
        #     用户返回", 菜单不会空转刷屏。实测修前:
        #     timeout 10 bash conf/dns.sh </dev/null → rc=124 (10 秒 275 行菜单)。
        c=$(ui_ask_num "请选择" 0 7) || return 0
        case "$c" in
            1) dns_show ;;
            2) dns_add ;;
            # ★ 删服务器是唯一一个会先画**编号表**的入口 (dns_del): ui_pick 的
            #   空列表分支已经自己暂停过 (它得解释"为什么没有列表"), 外面再暂停
            #   一次等于让用户按两下回车 —— 所以用返回值 2 把它交出去。
            3) dns_del; rc=$?; (( rc == 2 )) || ui_pause; continue ;;
            4) dns_strategy ;;
            5) dns_hosts ;;
            6) dns_nofallback ;;
            7) dns_reset ;;
            0) return 0 ;;
            *) _e "无效选项" ;;
        esac
        # ★ 每个动作之后停一下: dns_show / dns_del 会打十几行表格, 不停的话
        #   回到菜单时结果已经被顶上滚没了 —— 用户只能往上翻, 或者干脆重跑一次。
        ui_pause
    done
}

[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] && dns_menu