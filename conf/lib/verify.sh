#!/usr/bin/env bash
# Xray 项目配置核对公共库
#
# 目前只有绑定核对。写这个是因为"生成完说成功"和"端口真的绑上了"是两件事,
# 而后者不问就永远不知道。

# x_verify_bound —— 核对 conf/ 里配置的入站端口是否真的绑上了
#
# 两个坑:
#
# ① `systemctl restart` 返回只代表**进程起来了**, listener 是异步绑的。
#    紧接着查 ss 会看到"一个都没绑上", 于是报"22 个节点的端口没有绑上"。
#    误报比不报更糟: 用户会以为整批节点都废了, 实际一个都没问题。
#    所以这里轮询到全绑上为止, 或者等够了为止。
#
# ② 不能在这里**再起一个 xray** 去拿报错 —— 服务正占着那些端口, 第二个实例
#    必然满屏 "bind: address already in use", 把真正的错误挤掉。之前就是
#    这么把自己绕进去的: 明明是证书路径问题, 输出里却全是端口冲突。
#    服务在跑就读它自己的日志。
x_verify_bound() {
    local -a badlist=()
    local f p bad=0 tot=0 dump waited=0
    local -a ports=() tags=()

    [[ -d "$CONF_DIR" ]] || return 0

    # 收集所有片段声明的端口
    shopt -s nullglob
    for f in "$CONF_DIR"/*.json; do
        p=$(jq -r '.inbounds[0].port // empty' "$f" 2>/dev/null) || p=""
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        ports+=("$p")
        tags+=("$(basename "$f" .json)")
    done
    shopt -u nullglob
    ((${#ports[@]} == 0)) && return 0

    # 轮询等绑定完成
    while :; do
        bad=0
        dump=$(ss -tulnH 2>/dev/null)
        for p in "${ports[@]}"; do
            x_port_in_use "$p" || bad=$((bad + 1))
        done
        (( bad == 0 )) && break
        (( waited >= 8 )) && break
        sleep 1; waited=$((waited + 1))
    done
    (( bad == 0 )) && return 0

    # ss 不可用时不要报错 —— 是核对不了, 不是核对失败。
    # 静默返回 0 而不是报"全部失败": 那会让一个没装 ss 的机器永远看到
    # "N 个端口没绑上", 而实际一个都没问题。误报比不报更糟。
    x_ss_works || return 0

    for i in "${!ports[@]}"; do
        p="${ports[$i]}"
        tot=$((tot + 1))
        x_port_in_use "$p" || badlist+=("${tags[$i]}:$p")
    done
    # 上面循环没累加 tot, 这里补
    tot=${#ports[@]}

    print_error "${#badlist[@]} 个节点的端口没有绑上 (共 $tot 个): ${badlist[*]}"

    # 把内核真实报错翻出来, 这是唯一能说清原因的地方
    local err=""
    if systemctl is-active --quiet "${XRAY_SERVICE:-xrayls}" 2>/dev/null; then
        err=$(journalctl -u "${XRAY_SERVICE:-xrayls}" -n 60 --no-pager 2>/dev/null \
              | grep -iE 'failed to listen|address already in use|invalid' | tail -3)
        [[ -n "$err" ]] || err=$(timeout 12 "$XRAY_BIN" run -test -c "$XRAY_BASE/config.json" 2>&1 \
              | grep -iE 'failed to listen|address already in use|invalid' | tail -3)
    else
        err=$(timeout 12 "$XRAY_BIN" run -test -c "$XRAY_BASE/config.json" 2>&1 \
              | grep -iE 'failed to listen|address already in use|invalid' | tail -3)
    fi
    if [[ -n "$err" ]]; then
        print_error "内核报错:"
        printf '  %s\n' "$err" >&2
    fi
    print_info "常见原因: 端口被别的进程占用 / 证书路径不对 / 片段 JSON 损坏" >&2
    return 1
}