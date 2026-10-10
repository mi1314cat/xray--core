#!/bin/bash
# ================================
# 端口体检 —— 全局端口冲突排查
#
# 端口冲突这件事的表现极具误导性: 服务 active、面板显示"运行中"、
# 配置 check 全过, 但客户端就是连不上 —— 因为代理内核**根本没监听**
# 那个端口, 或者那个端口被**别的程序**占着, 内核起来就退出。
#
# 踩过的坑: conf/lib/ports.sh 的注释记着"服务停了 ss 就查不到, 于是同一个
# 端口被再次分配, 两个片段撞在一起, 第二个启动即 bind 失败"。分配时我们
# 查了, 但那只是一次性快照 —— 用户事后手动改端口、装了别的程序、或从
# 别的机器拷配置过来, 都会再次撞上。
#
# 所以这里做的是**全局体检**, 不是分配时的检查。覆盖四类问题:
#
#   1. 冲突   两个片段监听同一端口 —— 第二个必然 bind 失败
#   2. 悬空   nginx/stream 转发到某个端口, 但没有任何片段监听它
#   3. 缺失   片段声明的端口没人监听 —— 内核可能没起来, 或被别的占了
#   4. 占用   端口被非代理进程占用 —— 最难查, 因为面板全绿
#
# 对齐 M 的 port_check_show (src/lib/portcheck.sh) 与 SB 的 port_check_menu,
# 但覆盖面更大: 它们只看自己的一两个端口, 我们要扫全部片段 + nginx。
#
# 用法:
#   bash tools/port-check.sh            # 体检并打印报告
#   bash tools/port-check.sh --quiet    # 只在发现问题时输出 (供 cron 用)
# ================================
set -uo pipefail

CONF_DIR="${X_CONF_DIR:-/root/catmi/xray/conf}"
NGINX_CONF_DIR="${X_NGINX_CONF:-/home/web/conf.d}"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

_color() { [[ -t 1 ]] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
ok()   { _color 32 "$1"; }
warn() { _color 33 "$1"; }
bad()  { _color 31 "$1"; }
dim()  { _color 90 "$1"; }

PROBLEMS=0
say() { ((QUIET)) || echo "$@"; }
flag() { PROBLEMS=$((PROBLEMS+1)); }

# ---------------------------------------------------------------- 采集
# 正在监听的端口 -> 占用它的进程名
declare -A LISTENER
listeners() {
    local line port proc
    while read -r line; do
        [[ -z "$line" ]] && continue
        port=$(awk '{print $4}' <<<"$line" | sed 's/.*://')
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        proc=$(sed -n 's/.*users:((\"\{0,1\}\([^",]*\).*/\1/p' <<<"$line")
        [[ -z "$proc" ]] && proc=$(sed -n 's/.*users:((\([^,]*\).*/\1/p' <<<"$line")
        [[ -n "$proc" ]] || proc="?"
        # 同端口多协议(TCP+UDP)会出现两次, 合并即可
        LISTENER[$port]="${LISTENER[$port]:-$proc}"
    done < <({ ss -tlnp 2>/dev/null; ss -ulnp 2>/dev/null; } | sed 's/^ *//')
}

# 片段声明的端口 -> 声明它的文件
declare -A DECLARED
declared_ports() {
    local f p
    [[ -d "$CONF_DIR" ]] || return 0
    for f in "$CONF_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        while read -r p; do
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            DECLARED[$p]="${DECLARED[$p]:-}$(basename "$f") "
        done < <(jq -r '.inbounds[]?.port // empty' "$f" 2>/dev/null)
    done
}

# nginx 转发到的端口 -> location
declare -A PROXIED
proxy_targets() {
    local f
    [[ -d "$NGINX_CONF_DIR" ]] || return 0
    for f in "$NGINX_CONF_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        # proxy_pass http(s)://127.0.0.1:PORT  以及 stream 的 proxy_pass
        while read -r p; do
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            PROXIED[$p]="${PROXIED[$p]:-}$(basename "$f") "
        done < <(grep -ohE 'proxy_pass[^;]*127\.0\.0\.1:[0-9]+' "$f" 2>/dev/null \
                 | grep -oE '[0-9]+$')
    done
}

# ---------------------------------------------------------------- 报告
report() {
    say "========================================"
    say "端口体检  ($CONF_DIR)"
    say "========================================"

    local listening=${#LISTENER[@]} declared=${#DECLARED[@]} proxied=${#PROXIED[@]}
    say "  正在监听: $listening    片段声明: $declared    nginx 转发: $proxied"
    say ""

    # ---- 1. 片段之间端口冲突 ----
    local conflicts=0 p owners
    for p in "${!DECLARED[@]}"; do
        # 声明次数 = owners 里的文件名个数
        owners=$(wc -w <<<"${DECLARED[$p]}")
        if ((owners > 1)); then
            bad "  [冲突] 端口 $p 被 $(($owners)) 个片段同时声明:"
            for f in ${DECLARED[$p]}; do say "           - $f"; done
            conflicts=1; flag
        fi
    done
    ((conflicts)) || ok "  [冲突] 无 —— 没有两个片段抢同一端口"

    # ---- 2. 片段声明但没人监听 ----
    local missing=0
    for p in "${!DECLARED[@]}"; do
        if [[ -z "${LISTENER[$p]:-}" ]]; then
            # 可能是这个片段自己没跑起来, 也可能是端口被别人抢了
            local occupied
            occupied=$(grep -l ":${p}[[:space:]]" /proc/net/tcp /proc/net/udp 2>/dev/null | awk 'NR==1')
            if [[ -n "$occupied" ]]; then
                bad "  [缺失] 端口 $p 被声明 (${DECLARED[$p]}) 但未监听, 且被其它程序占用"
            else
                warn "  [缺失] 端口 $p 被声明 (${DECLARED[$p]}) 但无人监听 —— 内核可能没起"
            fi
            missing=1; flag
        fi
    done
    ((missing)) || ok "  [缺失] 无 —— 每个片段声明的端口都在监听"

    # ---- 3. nginx 悬空转发 ----
    local dangling=0
    for p in "${!PROXIED[@]}"; do
        if [[ -z "${LISTENER[$p]:-}" ]]; then
            bad "  [悬空] nginx 转发到 $p (${PROXIED[$p]}) 但无进程监听"
            dim "           客户端走这个路径会 502/连不上, 但 nginx 自己不报错"
            dangling=1; flag
        fi
    done
    ((dangling)) || ok "  [悬空] 无 —— nginx 转发的端口都有东西在听"

    # ---- 4. 被非代理进程占用 ----
    local squatted=0 proc
    for p in "${!DECLARED[@]}"; do
        proc="${LISTENER[$p]:-}"
        case "$proc" in
            *xray*|*sing-box*|*mihomo*|*nginx*|"") ;;
            *)
                bad "  [占用] 端口 $p 被 '$proc' 占用, 不是代理内核 (声明者: ${DECLARED[$p]})"
                squatted=1; flag
                ;;
        esac
    done
    ((squatted)) || ok "  [占用] 无 —— 声明的端口都由代理内核或 nginx 持有"

    # ---- 汇总 ----
    say ""
    say "----------------------------------------"
    if ((PROBLEMS)); then
        bad "发现 $PROBLEMS 类问题"
        return 1
    fi
    ok "端口体检通过, 未发现问题"
    return 0
}

main() {
    [[ -d "$CONF_DIR" ]] || { bad "配置目录不存在: $CONF_DIR"; return 2; }
    command -v jq >/dev/null 2>&1 || { bad "缺少 jq, 无法解析片段"; return 2; }
    listeners
    declared_ports
    proxy_targets
    report
}

main
exit $?
