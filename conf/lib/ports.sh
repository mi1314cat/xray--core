#!/usr/bin/env bash
# Xray 项目端口分配公共库
#
# 被各协议脚本 source, 提供端口占用判定、空闲端口分配和批量区间分配。
# 每个协议脚本自己复制一份的年代已经过去了 —— 9 处副本改一处漏一处,
# 批量区间分配只加进了 4 个脚本, 另外 5 个的批量生成仍在用随机端口,
# 导致同一批节点端口散落在 10000-60000 而不是连续区间。

# 端口占用表缓存。collect_used_ports 会重建它。
X_USED_PORTS=""

# 批量端口游标的存放位置。各协议脚本原来各自写死这一行, 副本删掉后
# 由这里兜底。tunnel.sh 的 CONF_DIR 在 source 本库之后才赋值, 所以
# 取不到时按项目默认路径兜。
X_BATCH_PORT_STATE="${X_BATCH_PORT_STATE:-${CONF_DIR:-/root/catmi/xray/conf}/.batch-ports}"

# x_collect_used_ports —— 收集三类已占用端口
#
# 只查 ss 会漏掉"片段里已经写了但服务没在跑"的端口: 服务停了 ss 就看不到,
# 于是同一个端口被再次分配, 两个片段撞在一起, 第二个启动即 bind 失败,
# 而现场报错是"端口占用", 跟根因没有任何关联。
x_collect_used_ports() {
    local tmp; tmp=$(mktemp)
    local f
    {
        # ① conf/ 片段里已配置的入站端口
        #
        # 必须逐个文件调用 jq。jq 一次喂多个文件时, 只要有一个解析失败,
        # 它会整体中止并且什么都不输出 —— 端口表直接变空。
        # 后果不是"少扫一个文件", 而是: 已配置的端口全被当成空闲 → 新节点
        # 分配到同一个端口 → 启动即 bind 失败, 而报错是"端口占用",
        # 跟根因(某个文件写坏了)没有任何关联。
        if [[ -d "$CONF_DIR" ]]; then
            for f in "$CONF_DIR"/*.json; do
                [[ -f "$f" ]] || continue
                jq -r '.inbounds[]?.port // empty' "$f" 2>/dev/null || true
            done
        fi
        # ② 主 config.json
        if [[ -f "$XRAY_BASE/config.json" ]]; then
            jq -r '.inbounds[]?.port // empty' "$XRAY_BASE/config.json" 2>/dev/null || true
        fi
        # ③ 本机正在监听的 TCP + UDP
        #
        # UDP 必须一起扫: hysteria2 是 QUIC, 只监听 UDP。只看 ss -tln 会
        # 把已经占用的 UDP 端口当成空闲。
        ss -tulnH 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$'
    } | sort -un > "$tmp"
    X_USED_PORTS="$tmp"
}

# x_ss_works —— ss 是否真的能给出监听列表
#
# 只判 "[[ -n $dump ]]" 是不够的: 某些环境(容器里没有 NETLINK)下 ss 会
# 报 "Cannot open netlink socket"。目前这个错误走 stderr, 被 2>/dev/null
# 吃掉后 dump 为空, 守卫能生效 —— 但守卫的正确性依赖 ss 的实现细节。
# 所以这里判的是"内容像不像监听列表", 不是"有没有输出"。
X_SS_OK=""
x_ss_works() {
    [[ -n "$X_SS_OK" ]] && { [[ "$X_SS_OK" == "1" ]]; return; }
    local out; out=$(ss -tulnH 2>/dev/null)
    if [[ "$out" =~ [:.]\?[0-9]{2,5}[[:space:]] ]]; then
        X_SS_OK=1; return 0
    fi
    # 只有一行输出时那行可能是 "Netid State Recv-Q Send-Q Local Peer" 表头
    if (( $(wc -l <<< "$out") > 1 )) && grep -qE 'LISTEN|UNCONN' <<< "$out"; then
        X_SS_OK=1; return 0
    fi
    X_SS_OK=0; return 1
}

# x_port_in_use <端口>
#
# 只查实时监听 —— 判断"这个端口此刻能不能立刻 bind"。
x_port_in_use() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ss -tulnH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$"
}

# x_port_taken <端口>
#
# 实时监听 + 已配置片段。比 x_port_in_use 严, 分配新节点时用这个。
x_port_taken() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    x_port_in_use "$p" && return 0
    [[ -n "$X_USED_PORTS" ]] || return 1
    grep -qx "$p" "$X_USED_PORTS"
}

# x_random_free_port
#
# 区间用尽时的回落。用户选的区间是偏好, 不是硬约束, 所以这里静默回落
# 而不是报错 —— 和 M / SB 的行为一致。
x_random_free_port() {
    local p i
    [[ -n "$X_USED_PORTS" ]] || x_collect_used_ports
    for (( i = 0; i < 500; i++ )); do
        p=$(( 10000 + RANDOM % 50000 ))
        x_port_taken "$p" && continue
        echo "$p" >> "$X_USED_PORTS"
        printf '%s' "$p"
        return 0
    done
    return 1
}

# x_next_range_port —— 从区间游标处顺序取一个空闲端口
#
# 游标持久化在 $X_BATCH_PORT_STATE, 保证同一批多协议之间端口互不重复,
# 哪怕每个协议脚本是独立进程跑的 (batch.sh 就是这么调的)。
x_next_range_port() {
    local start="${X_BATCH_PORT_START:-}" end="${X_BATCH_PORT_END:-}" p
    if [[ ! "$start" =~ ^[0-9]+$ ]] || [[ ! "$end" =~ ^[0-9]+$ ]]; then
        x_random_free_port
        return
    fi
    (( start < 1 )) && start=1
    (( end > 65535 )) && end=65535
    [[ -n "$X_USED_PORTS" ]] || x_collect_used_ports
    for (( p = start; p <= end; p++ )); do
        x_port_taken "$p" && continue
        printf '%s\n' "$p" >> "$X_BATCH_PORT_STATE"
        echo "$p" >> "$X_USED_PORTS"
        printf '%s' "$p"
        return 0
    done
    # 区间满了 —— 回落而不是失败, 并说明原因
    printf '端口区间 %s-%s 已用完, 回落到随机空闲端口\n' "$start" "$end" >&2
    x_random_free_port
}

# x_alloc_port —— 统一入口
#
# 批量模式且给了区间 -> 顺序分配; 否则随机。
x_alloc_port() {
    if [[ "${X_BATCH:-0}" == "1" \
       && -n "${X_BATCH_PORT_START:-}" && -n "${X_BATCH_PORT_END:-}" ]]; then
        x_next_range_port
    else
        x_random_free_port
    fi
}

# x_reset_batch_ports —— 清空批量游标
x_reset_batch_ports() {
    : > "$X_BATCH_PORT_STATE"
}
# ------------------------------------------------------------------
# 兼容别名
#
# 9 个协议脚本原本各自复制了一份同名实现, 调用点有 60+ 处
# (port_in_use 31 / random_free_port 26 / random_port 18 / batch_alloc_port 8)。
# 改名要动 60 多处, 出错就是"端口分配悄悄退化成随机"这种不会报错的错,
# 所以这里保留原名, 调用点一行不用改 —— 副本删掉, 定义集中到这里。
# ------------------------------------------------------------------
random_port() { local p i
    [[ -n "$X_USED_PORTS" ]] || x_collect_used_ports
    for (( i = 0; i < 500; i++ )); do
        p=$(( 10000 + RANDOM % 50000 ))
        x_port_taken "$p" && continue
        echo "$p" >> "$X_USED_PORTS"
        printf '%s' "$p"
        return 0
    done
    return 1
}

port_in_use() { x_port_in_use "$1"; }
random_free_port() { x_random_free_port; }
batch_alloc_port() { x_alloc_port; }
