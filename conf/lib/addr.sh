#!/usr/bin/env bash
# =============================================================
# 对外地址探测 —— 单一实现
#
# ★ 为什么必须收成一处:
#
#   项目里原来有 **6 处**各自读"本机 IP": conf/outbound.sh 读网口、
#   conf/hysteria2.sh 问 ip.sb、conf/Shadowsocks.sh 用 hostname -I、
#   conf/fd/legacy/server-reverse.sh 问 api.ipify.org……
#   各写各的, 于是同一个坑要修 6 遍, 而且总有一两处漏掉。
#   实测漏掉的那次: 分享链接里下发的是 **WARP 出口地址**
#   (104.28.201.80), 而服务器入站是 107.173.154.178 —— 客户端照着连
#   必然不通, 而链接看起来完全正常。
#
# ★ 核心判据 (与 SB / M 两个内核同源):
#
#   这台机器可能同时有 真实网卡 / WARP / HE-IPv6 隧道 / docker / wireguard,
#   而**只有真实网卡上的那个地址**是客户端能直连的。
#
#     eth0    203.0.113.7                 <- 正解 (真实网卡)
#     he-ipv6 2001:db8:...                <- 隧道内层 (不可对外)
#     warp    172.16.0.2 / 2606:4700:...  <- WARP 出口
#     docker0 / br-* / awg0               <- 私网
#
#   所以顺序是: **先读网口(排除隧道与私网) -> 外部探测 + 自检 -> 网口(含私网)**。
#   绝大多数 VPS 上第一步就给出正解, **一次网络请求都不需要** —— 也就不会
#   出现"问了一圈、全是 WARP、全丢掉、再退回本机"那种噪音。
#
#   反过来写 (先问外部服务再自检) 的问题: 套了 WARP 时那条查询本身走隧道,
#   拿回来的必然是 WARP 地址, 然后自检把它丢掉 —— 每次白跑一趟网络还刷一堆警告。
# =============================================================

# 隧道 / 虚拟接口名 —— 这些接口上的地址是代理出口或隧道地址, 不能给客户端连。
#
# ⚠ he-ipv6 与 he-ipv6-tun 要分清: 前者是用户**主动配的**真实 IPv6
#   (HE 隧道服务商给的公网地址, 对外可路由), 必须保留; 后者是隧道内层口。
#   写成 `he-ipv6.*` 会把 HE 的真实地址一起排掉 —— 于是明明有 IPv6 却判成"无"。
X_TUNNEL_IFACE_RE='^(warp|wg[0-9]*|awg[0-9]*|tun[0-9]*|tap[0-9]*|utun[0-9]*|tailscale|ts[0-9]*|ppp[0-9]*|zt[0-9]*|meta|he-ipv6-tun|sit[0-9]*|docker[0-9]*|br-[0-9a-f]+|veth.*|virbr[0-9]*)$'

# 不可路由 / 保留 / 会被内核自己占用的地址。
#
# 除了常规私网, 额外排除几段**实战踩得到的**:
#   198.18.0.0/15  RFC 2544 基准测试段。mihomo/Clash 默认拿 198.18.0.1/16
#                  做 fake-ip —— 机器上跑着 TUN 时网口扫描会挑中它, 那是个
#                  假地址, 客户端拿去连必然失败。(实测本机就有 eth5 198.18.0.1)
#   100.64.0.0/10  CGNAT, Tailscale 也用这段
#   192.0.2.0/24 / 198.51.100.0/24 / 203.0.113.0/24   TEST-NET, 文档示例地址
#   240.0.0.0/4    保留段
x_addr_is_private() {
    local a="${1:-}"
    case "$a" in
        10.*|127.*|192.168.*|169.254.*|0.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        198.1[89].*|198.51.100.*|192.0.2.*|203.0.113.*) return 0 ;;
        2[4-5][0-9].*) return 0 ;;
        fc*:*|fd*:*|fe80:*|::1|2001:db8:*) return 0 ;;
    esac
    return 1
}

# 这个地址是不是真的挂在**本机某个接口**上。
#
# ★ 这是把"外部服务告诉我的地址"变成可信的关键一步: api.ipify.org 答的是
#   **出站出口**, 套了 WARP/代理时拿回来的地址根本不在本机接口上。
x_addr_is_local() {
    local a="${1:-}"
    [[ -n "$a" ]] || return 1
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$a"
}

# 本机真实对外地址 —— 读接口, 排除隧道/虚拟网卡与私网。
# 输出第一个可用的地址 (优先 IPv4), 没有则返回 1。
x_iface_public_addr() {
    local dev cidr first6=""
    while read -r dev cidr; do
        [[ -n "$dev" && -n "$cidr" ]] || continue
        [[ "$dev" =~ $X_TUNNEL_IFACE_RE ]] && continue
        x_addr_is_private "$cidr" && continue
        case "$cidr" in
            *:*) [[ -z "$first6" ]] && first6="$cidr"; continue ;;   # 记住, 但 v4 优先
            *)   printf '%s' "$cidr"; return 0 ;;
        esac
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $2, $4}' | sed 's|/[0-9]*$||')
    [[ -n "$first6" ]] && { printf '%s' "$first6"; return 0; }
    return 1
}

# 真实 IPv6 (排除隧道接口)。没有则返回 1。
x_addr6_real() {
    local dev cidr
    while read -r dev cidr; do
        [[ -n "$dev" && -n "$cidr" ]] || continue
        [[ "$dev" =~ $X_TUNNEL_IFACE_RE ]] && continue
        case "$cidr" in *:*) printf '%s' "$cidr"; return 0 ;; esac
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $2, $4}' | sed 's|/[0-9]*$||')
    return 1
}

# 本机是否有**客户端连得上的** IPv4 / IPv6。
#
# ★ 两者必须对称地排除隧道网卡。原来 x_has_v4 是直接
#   `ip -4 addr show scope global | grep -q "inet "` —— 那台只有 awg0
#   (10.66.66.1) 的机器会被判成"有 IPv4", 而那个地址客户端根本连不上。
#   而 x_has_v6 早就排除了隧道, 两者判定口径不一致。
#   实测场景: 机器只有 WARP 的 IPv6 时, 旧写法说"有 IPv6", 于是向导会
#   引导用户去建 IPv6 节点 —— 建出来的节点谁也连不上。
x_has_v4() {
    local dev cidr
    while read -r dev cidr; do
        [[ "$dev" =~ $X_TUNNEL_IFACE_RE ]] && continue
        case "$cidr" in *:*) continue ;; esac
        return 0
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2, $4}' | sed 's|/[0-9]*$||')
    return 1
}
x_has_v6() {
    local dev cidr
    while read -r dev cidr; do
        [[ "$dev" =~ $X_TUNNEL_IFACE_RE ]] && continue
        case "$cidr" in *:*) return 0 ;; esac
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $2, $4}' | sed 's|/[0-9]*$||')
    return 1
}

# 本机是否正在走 WARP / 隧道 (给"为什么读到的地址不对"提供线索)
x_tunnel_active() {
    ip -o addr show scope global 2>/dev/null | awk '{print $2}' | grep -qE "$X_TUNNEL_IFACE_RE"
}

# ---------------------------------------------------------------- 主入口
# x_public_addr [已保存的地址]
#
# 顺序:
#   1. 显式传参 (调用方已知答案)
#   2. 已保存的地址 —— **必须过 x_addr_is_local 自检**
#   3. 本机接口地址 (排除隧道与私网)      <- 绝大多数 VPS 在这里就出结果
#   4. 外部探测 + 自检                    <- 给 NAT 后的机器兜底
#   5. 本机接口地址 (含私网)              <- 最后的兜底
#
# 降噪: 正常路径完全静默。只有"最终答案是私网地址(NAT)"这种用户真的需要
# 动手的情况才打警告并给修复命令。
x_public_addr() {
    local given="${1:-}" saved="${2:-}" a=""

    # 1. 传参
    if [[ -n "$given" ]]; then printf '%s' "$given"; return 0; fi

    # 2. 已保存的 —— 关键是自检。
    #    ★ 不加这一关, 修复前存进去的 WARP 地址会被**一直沿用**下去,
    #      自检形同虚设 (这是踩过的: 存的是 WARP 出口, 写进配置 13/13 全连不上)。
    if [[ -n "$saved" ]] && x_addr_is_local "$saved"; then
        printf '%s' "$saved"; return 0
    fi

    # 3. 本机接口 (排除隧道与私网)
    a=$(x_iface_public_addr 2>/dev/null) || a=""
    if [[ -n "$a" ]]; then printf '%s' "$a"; return 0; fi

    # 4. 外部探测 —— 只在第 3 步彻底失败时才走, 而且仍然要自检
    local url out
    for url in "https://ip.sb" "https://api.ipify.org" "https://ifconfig.me/ip"; do
        out=$(curl -4 -s --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && x_addr_is_local "$out"; then
            printf '%s' "$out"; return 0
        fi
        # 自检不过说明这台机器在 NAT 后面(或者走了隧道), 把外部答案当候选 ——
        # 它至少是"世界看到的我", 比什么都没有强; 但要提醒用户核对。
        [[ -n "$out" && -z "${_X_ADDR_EXT:-}" ]] && _X_ADDR_EXT="$out"
    done
    if [[ -n "${_X_ADDR_EXT:-}" ]]; then
        printf '%s' "$_X_ADDR_EXT"
        printf '  [注意] 读到的外部地址 %s 不在本机任何接口上 (NAT/隧道?)。\n' "$_X_ADDR_EXT" >&2
        printf '         如果客户端连不上, 用 XRAY_PUBLIC_IP 明确指定对外地址。\n' >&2
        return 0
    fi

    # 5. 含私网的接口地址 (NAT 内网机器)
    a=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [[ -n "$a" ]]; then
        printf '%s' "$a"
        printf '  [注意] 只找到私网地址 %s —— 需要端口转发, 或手工指定对外地址。\n' "$a" >&2
        printf '         指定方式: XRAY_PUBLIC_IP=<公网地址>\n' >&2
        return 0
    fi

    return 1
}

# 地址族标签 —— 产物/提示里显示"客户端会用哪个地址连回来"
x_addr_family_of() {
    local a="${1:-}"
    case "$a" in *:*) printf 'IPv6' ;; *) printf 'IPv4' ;; esac
}

# URL 里的主机: IPv6 必须加方括号, 否则端口会被当成地址的一部分。
#   错误: http://2001:db8::1:9443/share/xxx
#   正确: http://[2001:db8::1]:9443/share/xxx
# 客户端 (浏览器/curl/内核) 把前者解析成非法 host, 直接失败。
x_url_host() {
    local h="${1:-}"
    case "$h" in
        *:*) [[ "$h" == \[*\] ]] && printf '%s' "$h" || printf '[%s]' "$h" ;;
        *)   printf '%s' "$h" ;;
    esac
}

# ---------------------------------------------------------------- 直跑自检
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-show}" in
        show)     x_public_addr ;;
        v4)       x_has_v4 && echo yes || echo no ;;
        v6)       x_has_v6 && echo yes || echo no ;;
        v6addr)   x_addr6_real || true ;;
        tunnel)   x_tunnel_active && echo "有隧道/WARP 接口" || echo "无" ;;
        ifaces)   ip -o addr show scope global 2>/dev/null |
                      awk '{print $2, $4}' | sed 's|/[0-9]*$||' |
                      while read -r d a; do
                          printf '  %-16s %-40s %s\n' "$d" "$a" \
                              "$( [[ "$d" =~ $X_TUNNEL_IFACE_RE ]] && echo '隧道/虚拟 (排除)' || { x_addr_is_private "$a" && echo '私网 (排除)' || echo '★ 可用'; } )"
                      done ;;
        check)    # 自检: 给定地址在不在本机接口上
                  if x_addr_is_local "${2:-}"; then echo "本机接口上 ✅"; else echo "不在本机接口上 ❌"; fi ;;
        *) echo "用法: addr.sh [show|v4|v6|v6addr|tunnel|ifaces|check <地址>]" >&2; exit 1 ;;
    esac
fi
