#!/usr/bin/env bash
# 服务管理 —— 解析服务名 / 重启 / 状态 / 日志
#
# 为什么需要
# ----------
# 历史上有两代安装留下两个服务名: xrayls (当前) 和 xray (早期)。多数脚本
# 里散落着 "优先 xrayls, 回退 xray" 的判断, 两三个文件各写一遍, 新脚本
# 又各写一遍 —— 每份都是同样的 if/elif, 改一处漏两处的概率很高。
#
# 这里收敛成单一真源: 先探测一次并缓存, 后面所有操作都用同一个名字。

# 各协议脚本的打印函数命名不统一 (print_ok / ok / _green), 所以这里自带一套,
# 不复用调用方的 —— 否则本库换个宿主就用不了。
_x_svc_red=""; _x_svc_grn=""; _x_svc_yel=""; _x_svc_rst=""
if [[ -t 2 ]]; then
    _x_svc_red=$'\033[31m'; _x_svc_grn=$'\033[32m'
    _x_svc_yel=$'\033[33m'; _x_svc_rst=$'\033[0m'
fi
x_svc_print_ok()   { printf "  ${_x_svc_grn}[OK]${_x_svc_rst} %s\n" "$*" >&2; }
x_svc_print_error(){ printf "  ${_x_svc_red}[X]${_x_svc_rst} %s\n"  "$*" >&2; }
x_svc_print_warn() { printf "  ${_x_svc_yel}[!]${_x_svc_rst} %s\n"  "$*" >&2; }

# systemctl 在容器/精简环境里可能挂死 (实测 list-unit-files 在无 dbus 的
# 容器里不返回)。脚本会跟着卡到用户按 Ctrl-C —— 一个"查服务名"的辅助调用
# 不该有能力挂住整个面板。所有 systemctl 调用都带超时。
X_SVC_TIMEOUT="${X_SVC_TIMEOUT:-5}"
_x_svc() { timeout "$X_SVC_TIMEOUT" systemctl "$@" 2>/dev/null; }

X_SVC_NAME=""
X_SVC_RESOLVED=0

_x_lib_dir_svc="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -r "$_x_lib_dir_svc/lib/verify.sh" ]]; then
    source "$_x_lib_dir_svc/lib/verify.sh"
fi

# 解析服务名。结果缓存, 避免同一脚本里反复跑 systemctl。
#
# 缓存靠全局变量而不是返回值: 命令替换 $(...) 会在子 shell 里执行, 子 shell
# 里给 X_SVC_RESOLVED 赋值传不回父 shell, 于是"缓存"永远不生效, 每次调用
# 都重跑 systemctl。带超时的 systemctl 每次要几秒, 反复调用就把面板卡住了。
# 所以 x_svc_name 写全局变量, 取值直接读 $X_SVC_NAME。
x_svc_resolve() {
    # 命中缓存 —— "找到了"(1) 和 "探测过但没有"(2) 都要缓存。
    # 只缓存 1 的话, 没装 xray 的机器上每次调用都重试一遍带超时的
    # systemctl, 反而是最该缓存的场合没缓存住。
    if [[ "$X_SVC_RESOLVED" == "1" ]]; then
        return 0
    elif [[ "$X_SVC_RESOLVED" == "2" ]]; then
        return 1
    fi

    # 候选去重。XRAY_SERVICE 默认就是 xrayls, 写进列表会重复试一遍 ——
    # 每次多花一次 systemctl 超时。
    # 前置判断: 这台机器到底有没有 systemd。
    #
    # 没有的话, list-unit-files 要么报错要么挂住到超时 (实测在容器里会挂),
    # 逐个候选试一遍就是几十秒。/run/systemd/system 是 systemd 引导成功后
    # 才创建的那个目录, 比问 systemctl 快得多也不需要等它返回。
    if [[ ! -d /run/systemd/system ]]; then
        X_SVC_NAME="${XRAY_SERVICE:-xrayls}"
        X_SVC_RESOLVED=2
        return 1
    fi

    local -a cands=()
    local c seen=" "
    for c in "${XRAY_SERVICE:-xrayls}" xrayls xray; do
        [[ "$seen" == *" $c "* ]] && continue
        seen="$seen$c "; cands+=("$c")
    done

    for c in "${cands[@]}"; do
        if _x_svc list-unit-files | grep -qw "${c}.service"; then
            X_SVC_NAME="$c"; X_SVC_RESOLVED=1
            return 0
        fi
    done

    # 都没有 —— 可能 systemctl 不可用 (容器), 也可能真的没装。
    # 记为已探测过, 否则每次调用都要重试一遍超时。
    X_SVC_NAME="${XRAY_SERVICE:-xrayls}"
    X_SVC_RESOLVED=2      # 2 = 探测过但没找到 (区别于 1=找到了)
    return 1
}

x_svc_installed() {
    x_svc_resolve >/dev/null
    [[ "$X_SVC_RESOLVED" == "1" ]]
}

x_svc_active() {
    x_svc_resolve >/dev/null
    _x_svc is-active --quiet "$X_SVC_NAME"
}

x_svc_status_text() {
    x_svc_resolve >/dev/null
    local n="$X_SVC_NAME"
    local st
    st=$(_x_svc is-active "$n" || echo "unknown")
    if [[ "$X_SVC_RESOLVED" != "1" ]]; then
        printf '%s (未检测到, systemd 不可用或未安装)' "$st"
    else
        printf '%s' "$st"
    fi
}

# 重启并确认真的起来了。
#
# systemctl restart 返回 0 只说明进程被拉起来了, listener 是异步绑定的。
# 所以这里轮询而不是直接报成功 —— "重启失败"的误报比不报更糟: 用户会去查
# 一根本不存在的故障。
x_svc_restart() {
    x_svc_resolve >/dev/null
    local n="$X_SVC_NAME"
    if [[ "$X_SVC_RESOLVED" != "1" ]]; then
        x_svc_print_error "未找到 xray 服务 (试过 xrayls / xray), 请手动重启"
        return 1
    fi
    if ! _x_svc restart "$n"; then
        x_svc_print_error "$n 重启失败"
        x_svc_print_error "最近的错误:"
        timeout 10 journalctl -u "$n" -n 15 --no-pager 2>/dev/null | sed 's/^/    /' >&2
        return 1
    fi

    for _ in $(seq 1 20); do
        if _x_svc is-active --quiet "$n"; then
            x_svc_print_ok "$n 已重启 (active)"
            # 端口绑定核对。查不了就跳过 —— 不能确认不等于失败。
            if declare -F x_verify_bound >/dev/null 2>&1; then
                x_verify_bound || x_svc_print_warn "部分端口未确认在监听, 见上"
            fi
            return 0
        fi
        sleep 0.25
    done

    x_svc_print_error "$n 重启后未能进入 active 状态"
    timeout 10 journalctl -u "$n" -n 15 --no-pager 2>/dev/null | sed 's/^/    /' >&2
    return 1
}

x_svc_start() { x_svc_resolve >/dev/null
                _x_svc start "$X_SVC_NAME" && x_svc_print_ok "已启动" || x_svc_print_error "启动失败"; }
x_svc_stop()  { x_svc_resolve >/dev/null
                _x_svc stop  "$X_SVC_NAME" && x_svc_print_ok "已停止" || x_svc_print_error "停止失败"; }

x_svc_logs() {
    x_svc_resolve >/dev/null
    local n="$X_SVC_NAME"
    local lines="${1:-50}"
    timeout 10 journalctl -u "$n" -n "$lines" --no-pager 2>/dev/null
}

# 内核报错翻译 —— 用户看到 "listen tcp: address already in use" 不知道该
# 查端口还是查配置。把常见错误说成人话。
x_svc_explain_errors() {
    x_svc_resolve >/dev/null
    local n="$X_SVC_NAME"
    local out
    # 预过滤只用来压掉启动成功的那些行。但它的关键词必须覆盖下面 case 里
    # 能识别的每一条 —— 否则映射认识的那行被这里先滤掉, 解释永远不会出现。
    # 之前就漏了 unknown field 与 no such file or directory: 这两个短语
    # 不含任何通用关键词, 于是"配置字段不被版本接受"和"引用的文件不存在"
    # 两条解释是死代码。
    # 用单个交替式而不是两个 grep 串联: 串联是求交集, 而这两组关键词是并集 ——
    # "unknown field" 行不含任何通用关键词, 第一个 grep 就把它滤掉了, 第二个
    # grep 再滤一遍只会得到空集, 于是所有解释都不出现。
    local pat
    pat='error|failed|emerg|panic|warn'
    pat+='|address already in use|permission denied|certificate'
    pat+='|no such file|unknown field|invalid character'
    out=$(timeout 10 journalctl -u "$n" -n 200 --no-pager 2>/dev/null \
          | grep -iE "$pat" || true)
    [[ -n "$out" ]] || { x_svc_print_ok "日志里没有错误"; return 0; }

    printf '\n' >&2
    while IFS= read -r ln; do
        local why=""
        case "$ln" in
            *"address already in use"*)  why="端口被占用 —— 换端口或停掉占用进程 (ss -tulnp | grep <端口>)" ;;
            *"permission denied"*)        why="权限不足 —— 端口低于 1024 需要 root, 或证书文件不可读" ;;
            *"failed to read certificate"*|*"invalid certificate"*) why="证书有问题 —— 检查路径、有效期、证书私钥是否配对" ;;
            *"no such file or directory"*) why="引用的文件不存在 —— 常见于证书路径写错" ;;
            *"invalid character"*|*"unknown field"*) why="配置字段不被这个 Xray 版本接受 —— 确认版本与字段匹配" ;;
            *"failed to build"*)           why="配置构建失败 —— 先跑校验看具体是哪一段" ;;
            *"panic"*)                     why="内核崩溃 —— 通常是配置结构错误, 跑校验定位" ;;
        esac
        printf '  %s\n' "$ln" >&2
        [[ -n "$why" ]] && printf '    → %s\n' "$why" >&2
    done <<< "$out"
}

_x_lib_dir_svc=""