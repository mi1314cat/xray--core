#!/usr/bin/env bash
# proto_ui.sh — 节点脚本共用的那一层: 打印、读输入、编号、端口
#
# 抽这个库的理由不是"看着重复", 是那三份复制**已经开始漂移**:
#
#   Reality.sh         的 safe_read 里有 batch 守卫 (X_BATCH=1 时直接取默认值)
#   vlessecn.sh        没有
#   vlessxhttpecn.sh   没有
#
# 今天没出事, 因为那两个只从菜单进 (交互), 而 batch.sh 走的是 Reality.sh。
# 但只要哪天有人给它们加一条非交互的调用路径 —— 比如"全协议一键生成"里多带
# 一个 VLESS —— 它就会**永远卡在 read 上**, 而且是那种没人会去查的卡法:
# 前面的日志都正常, 只是进程不动了。
#
# 所以收敛的重点不是少几行, 是让三份**不可能再各走各的**。
#
# 用法: source 这个文件, 不要直接执行。
#
# 铁律: 所有输出走 >&2。stdout 是数据通道 (分享链接 / 订阅载荷)。

# ---- 颜色 ----
# 用 ${VAR:-} 兜底: 面板与 batch 调用可能已经定义过同名变量, 覆盖会重置颜色。
[[ -n "${RED:-}"    ]] || RED="\e[31m"
[[ -n "${GREEN:-}"  ]] || GREEN="\e[32m"
[[ -n "${YELLOW:-}" ]] || YELLOW="\e[33m"
[[ -n "${BLUE:-}"   ]] || BLUE="\e[34m"
[[ -n "${CYAN:-}"   ]] || CYAN="\e[36m"
[[ -n "${RESET:-}"  ]] || RESET="\e[0m"

# ---- 打印 ----
# 全部 >&2 —— stdout 要留给分享链接/订阅载荷。
print_title() {
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${RESET}" >&2
    echo -e "${CYAN}║$(printf "%-50s" "$1")║${RESET}" >&2
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${RESET}" >&2
    echo >&2
}
print_info()  { echo -e "${CYAN}[Info]${RESET} $*" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}  $*" >&2; }
print_warn()  { echo -e "${YELLOW}[Warn]${RESET} $*" >&2; }
print_error() { echo -e "${RED}[Error]${RESET} $*" >&2; }

# ---- 输入清洗 ----
# 去掉控制字符: 用户从别的终端粘贴进来时经常带着 ANSI 尾巴, 不清掉会一路
# 写进 JSON 片段, 表现是"配置看起来建好了, 内核说不认"。
clean_input() { echo "$1" | tr -d '\000-\037'; }

# ---- 带默认值的读取 ----
# ★ batch 守卫在**这里**: 非交互调用时直接取默认值, 绝不 read。
#   这是三个脚本里最容易漂移的一处, 所以放在库里只有一份。
safe_read() {
    local prompt="$1" default="$2" input
    if [[ "${X_BATCH:-0}" == "1" || ! -t 0 ]]; then
        print_info "Batch 模式: ${prompt} = ${default}"
        echo "$default"
        return
    fi
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read -r input || input=""
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

# 端口: 只收 1-65535 的整数, 收不合法就一直问 —— 直到拿到能用的为止。
# 非交互时退回默认值而不是死循环, 否则 batch 会永远转下去。
safe_read_port() {
    local prompt="$1" default="$2" input
    if [[ "${X_BATCH:-0}" == "1" || ! -t 0 ]]; then
        echo "$default"
        return
    fi
    while true; do
        printf "%s (默认: %s): " "$prompt" "$default" >&2
        read -r input || input=""
        input=$(clean_input "$input")
        input="${input:-$default}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
            echo "$input"
            return
        fi
        print_warn "端口必须是 1-65535 的整数"
    done
}

# ---- 编号 ----
# 找**第一个空缺** (01,02,03 删掉 02 → 下次发 02), 而不是 max+1。
#
# ★ 行为照搬现有实现, 收敛时不改语义。
#   我第一版写的是 max+1, 顺手"修正"成不回收空号 —— 这是**自作主张**:
#   编号是用户脚本里天天看着的东西, 收敛任务里改它等于夹带需求。
#   差异只在"删掉中间一个之后"的编号, 但那是用户会注意到的地方。
get_next_index() {
    local used=() i=1 f base
    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.json; do
        base=$(basename "$f")
        if [[ "$base" =~ ^${PROTO}-([0-9]+)\.json$ ]]; then
            used+=("${BASH_REMATCH[1]}")
        fi
    done
    if ((${#used[@]} == 0)); then
        printf "%02d\n" 1
        return
    fi
    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        [[ $((10#$n)) -ne "$i" ]] && break
        ((i++))
    done
    printf "%02d\n" "$i"
}

# ---- 监听地址 ----
# 有 IPv4 就绑 0.0.0.0 (双栈由内核处理); 纯 IPv6 环境绑 ::。
detect_listen_ip() {
    local v4 v6
    v4=$(ip -4 addr show scope global 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)
    v6=$(ip -6 addr show scope global 2>/dev/null | grep -oE 'inet6 [0-9a-fA-F:]+' | head -1 | cut -d' ' -f2)
    if [[ -n "$v4" ]]; then echo "0.0.0.0"
    elif [[ -n "$v6" ]]; then echo "::"
    else echo "0.0.0.0"; fi
}