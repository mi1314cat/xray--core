#!/usr/bin/env bash
# =============================================================
# preset.sh — 协议推荐配置预置 (Xray 内核版)
#
# 为什么有这一层:
#   每个协议的"该用哪种传输 + 加密"其实是产品知识, 不是用户每次都要重新想
#   的问题。VLESS 用户答错一次的表现是"配好了但连不上", 而他不知道自己
#   答错了 —— REALITY 配 WS 是最常见的一种, 握手必然失败但配置校验通过。
#   预置把这层知识固化下来, 用户挑一个能用的, 而不是每次面对空白选项。
#
# ★ 取值一律用 cut 逐列取。
#   实测 IFS='|' + read -ra 本身不会折叠中间的空字段, 但**末尾**的空字段
#   会丢: 对 "a|b||" read 给 2 个字段而 cut 给 3 个。表格里的空字段一旦
#   落在末尾 (比如某协议暂时不填 flow), 按序号取值就会取到空或越界,
#   而现象是"读到了错的列"而不是报错 —— 排查起来最费时间。
#   cut 逐列取, 字段缺失就是空串, 行为可预测。
#
# 字段: 协议|传输|加密|显示名|说明[|加密增强]
#   协议 vless / trojan / vmess / shadowsocks / socks / http / hysteria2
#   传输 raw tcp / ws / xhttp / grpc / httpupgrade / hysteria
#   加密 none / tls / reality
#   第 6 列 (可选, 可留空) = VLESS 会话加密增强。
#     留空 或 "none" → 普通 VLESS (settings.decryption = "none")
#     "mlkem"        → 建节点时现调 `xray vlessenc` 生成 ML-KEM-768 后量子配对
#                       (xray 独有; sing-box 没有这层)
#     "mldsa65"      → REALITY 握手签名换 ML-DSA-65 后量子 (xray 独有)
#
# ★ 为什么第 6 列写标记而不直接写密钥:
#   密钥**不能预置**。密钥必须成对且每台机器独一无二, 预置进表里等于
#   把一把所有人的服务器共用的私钥写进公开仓库。(conf/vlessecn.sh 原来有
#   一个硬编码 FALLBACK_ENC 兜底, 那把密钥会跟着仓库发到每一台机器上。)
#   这里只写"要哪一档", 真正的值由调用方在建节点那一刻生成。
# =============================================================

# 传输与加密的合法组合在这里先拦一道, 不让非法组合进到生成环节。
#
# ★ REALITY 的传输白名单**照官方源码**, 不是照直觉:
#
#   原来这里写的是 `reality) [[ "$tr" == "tcp" ]]`, 注释还写着"REALITY 只能跑
#   裸 TCP" —— 那是**错的**, 而且错的方向是"挡掉合法组合":
#
#     源码 infra/conf/transport_internet.go:107 的报错原文:
#         "REALITY only supports RAW, XHTTP and gRPC for now."
#
#   即 REALITY 支持 raw / xhttp / grpc 三种。原实现把 xhttp 与 grpc 也拦了,
#   用户想建 REALITY + XHTTP (官方主推传输 + 最强安全层) 会被无理由拒绝。
#
#   反过来, REALITY + ws / httpupgrade 是真不行: 握手伪装要求客户端直连目标
#   站点, 而这两种的封装层会破坏握手 —— 那不是"慢一点", 是永远连不上, 而
#   `xray run -test` **不会报错**。所以这道拦截必须留在生成之前。
#
#   `tcp` 是 `raw` 的别名, 两者等价 (官方文档: raw 为默认值, tcp 仍兼容)。
#
# hysteria 是 Hysteria2 自己的传输名 (UDP), 不是 Xray 的标准 network 值,
# 但 hysteria2.sh 一直在用, 所以留在白名单里。
# ★ kcp 已从白名单删除 (2026-10-12)。
#   内核 26.3.27 实测: `kcpSettings: {header, seed}` 直接被拒, 原文
#     "The feature mkcp header & seed has been removed and migrated to
#      finalmask/udp header-* & mkcp-original & mkcp-aes128gcm."
#   只有**空对象** `kcpSettings: {}` 能过配置校验 —— 而那样建出来的节点
#   运行期一样连不通。`xray run -test` 会放行, 所以这种节点会安静地死在
#   服务器上: 面板显示一切正常, 用户连不上却查不出原因。
#   白名单里留着它 = 允许用户造出这种死节点。
_P_TRANSPORTS="raw tcp ws xhttp grpc httpupgrade hysteria"
_P_SECURITY="none tls reality"

# REALITY 允许的传输 (官方源码白名单)
_P_REALITY_TRANSPORTS="raw tcp xhttp grpc"

_preset_security_allows() {
    local sec="$1" tr="$2"
    case "$sec" in
        reality)
            local t
            for t in $_P_REALITY_TRANSPORTS; do
                [[ "$tr" == "$t" ]] && return 0
            done
            return 1 ;;
        *) return 0 ;;
    esac
}

X_PRESETS=(
    # ---------- VLESS ----------
    # REALITY 预设挂在本段。抗 DPI 最强, 不需要域名和证书。
    "vless|raw|reality|① 隐匿优先 · REALITY + Vision + 后量子|裸 TCP + XTLS Vision + ML-KEM-768 会话加密 + ML-DSA-65 握手签名; 全套后量子, 不需要域名和证书, 抗 DPI 最强, 新装首选|mlkem,mldsa65"
    "vless|tcp|reality|② 隐匿优先 · REALITY + Vision|裸 TCP + XTLS Vision; 不需要域名和证书。tcp 是 raw 的别名, 与 ① 等价|none|none"
    "vless|raw|none|③ 最轻 · 后量子裸 TCP|裸 TCP + ML-KEM-768 会话加密, 不套 TLS/REALITY。延迟最低, 但没有 REALITY 的握手伪装|mlkem"
    "vless|xhttp|tls|④ CDN 友好 · XHTTP + TLS|★ 官方主推传输, 也是**新的 CDN 推荐档**: 没有 WS 那种 \"ALPN 是 http/1.1\" 的显著特征, 上下行分离可走 Cloudflare 橙云. 官方称其出现后其它基于 HTTP 的传输层都黯然失色|none|none"
    "vless|xhttp|tls|⑤ CDN + ECH + 后量子|XHTTP + TLS + ECH (ClientHello 加密, 真实 SNI 不外泄) + ML-KEM-768; 走 Cloudflare 橙云时防止域名字面被探测到, 需要一张可信证书|mlkem"
    "vless|ws|tls|⑥ WS + TLS（官方已弃用）|⚠ 官方文档顶部已挂 danger: \"推荐换用 XHTTP\". 迁移目标 XHTTP H2 & H3 — 只有在服务端/CDN 明确只吃 WS 时才选它"
    "vless|grpc|tls|⑦ gRPC + TLS|gRPC 走 HTTP/2. ⚠ 官方已标为**弃用**(非移除), 迁移目标 XHTTP stream-up — 新装优先选 ④"
    "vless|httpupgrade|tls|⑧ HTTPUpgrade + TLS|比 WS 更轻的 HTTP 升级. ⚠ 官方已标为**弃用**(非移除), 迁移目标 XHTTP — 新装优先选 ④"
    "vless|tcp|tls|⑨ 裸 TCP + TLS|最简单但最易被识别; 只在确认不需要抗 DPI 时用"

    # ---------- Trojan ----------
    "trojan|tcp|reality|① 隐匿优先 · REALITY + Vision|裸 TCP + REALITY; Trojan 侧最抗 DPI 的组合"
    "trojan|xhttp|tls|② CDN 友好 · XHTTP + TLS|★ 官方主推传输; 可走 Cloudflare 橙云 (与 VLESS 口径一致)"
    "trojan|ws|tls|③ WS + TLS（官方已弃用）|⚠ 官方推荐换用 XHTTP; 只在服务端只吃 WS 时选它"
    "trojan|grpc|tls|④ gRPC + TLS|gRPC 走 HTTP/2. ⚠ 官方已弃用(非移除), 迁移目标 XHTTP"
    "trojan|tcp|tls|⑤ 裸 TCP + TLS|最常见的默认选择"

    # ---------- VMess ----------
    "vmess|xhttp|tls|① CDN 友好 · XHTTP + TLS|★ 官方主推传输 (与 VLESS/Trojan 口径一致)"
    "vmess|ws|tls|② WS + TLS（官方已弃用）|⚠ 官方推荐换用 XHTTP"
    "vmess|grpc|tls|③ gRPC + TLS|gRPC 走 HTTP/2. ⚠ 官方已弃用(非移除), 迁移目标 XHTTP"
    "vmess|tcp|tls|④ 裸 TCP + TLS|改连 TCP 伪装, 需要 VMess 自身配置"

    # ---------- Shadowsocks ----------
    "shadowsocks|tcp|reality|① 隐匿优先 · REALITY|裸 TCP + REALITY; 协议本身简单, 靠 REALITY 补抗识别"
    "shadowsocks|tcp|tls|② 裸 TCP + TLS|标准用法"
    "shadowsocks|tcp|none|③ 裸 TCP · 无加密|仅在同一局域网内使用; 跨公网务必换前两个"

    # ---------- Hysteria2 ----------
    # hysteria2 走 UDP, 传输固定, 只有 TLS 一档。
    "hysteria2|hysteria|tls|① 标准 (UDP + TLS)|Hysteria2 只支持 UDP; 抗弱网能力来自协议本身, 不靠传输伪装"

    # ---------- 本地代理 (无加密) ----------
    "socks|tcp|none|① SOCKS5 · 无认证|仅本机或可信内网; 暴露到公网等于开放代理"
    "socks|tcp|tls|② SOCKS5 + TLS|需要认证能力时仍建议另加认证"
    "http|tcp|none|① HTTP 代理 · 无认证|仅本机或可信内网"
    "http|tcp|tls|② HTTP 代理 + TLS|需要认证能力时仍建议另加认证"
)

# 某一协议有几个预置
x_preset_count() {
    local p="$1" n=0 row
    for row in "${X_PRESETS[@]}"; do [[ "${row%%|*}" == "$p" ]] && n=$((n+1)); done
    printf '%s' "$n"
}

# 取第 n 个 (1 起) 的某一列
#
# cut 而不是 read: 见文件头说明。字段缺失时返回空串, 不会把后面的列顶上来。
x_preset_field() {
    local p="$1" i="$2" col="$3" row n=0
    for row in "${X_PRESETS[@]}"; do
        [[ "${row%%|*}" == "$p" ]] || continue
        n=$((n+1))
        [[ "$n" -eq "$i" ]] || continue
        printf '%s' "$row" | cut -d'|' -f"$col"
        return 0
    done
    return 1
}

# 列出某协议的预置 (交互式选择用)
x_preset_list() {
    local p="$1" row n=0 cnt
    cnt=$(x_preset_count "$p")
    [[ "$cnt" -gt 0 ]] || { printf '协议 %s 没有预置\n' "$p" >&2; return 1; }
    for row in "${X_PRESETS[@]}"; do
        [[ "${row%%|*}" == "$p" ]] || continue
        n=$((n+1))
        printf '  %s) %s\n' "$n" "$(printf '%s' "$row" | cut -d'|' -f4)" >&2
        printf '     %s\n'     "$(printf '%s' "$row" | cut -d'|' -f5)" >&2
    done
    return 0
}

# 挑一个预置, 输出 "传输 加密 显示名 说明" 供调用方用
#
# ★ 界面一律 >&2, **只有最后那 4 行值走 stdout**。
#   调用方是 `picked=$(x_preset_ask "$proto")` —— 命令替换会吃掉 stdout,
#   所以预置列表和"选择"提示必须走 stderr, 否则用户既看不见列表也看不见提示,
#   而 read 回来的前 4 行全是菜单文字, 于是 MK_TRANSPORT 变成
#   "  1) ① 隐匿优先 · REALITY + Vision" 这种垃圾, 直接生成坏配置。
#
# 挑完先验组合合法 —— 表是手维护的, 加错一行不该等到生成配置时才炸。
x_preset_ask() {
    local p="$1" cnt i tr sec disp desc
    cnt=$(x_preset_count "$p")
    [[ "$cnt" -gt 0 ]] || { printf '协议 %s 没有预置\n' "$p" >&2; return 1; }

    x_preset_list "$p"
    while :; do
        printf '  选择 (1-%s, 0=返回): ' "$cnt" >&2
        read -r i
        [[ "$i" == "0" || -z "$i" ]] && return 1
        if [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= cnt )); then break; fi
        printf '\033[33m  请输入 1-%s 之间的数字\033[0m\n' "$cnt" >&2
    done

    tr=$(x_preset_field "$p" "$i" 2)
    sec=$(x_preset_field "$p" "$i" 3)
    disp=$(x_preset_field "$p" "$i" 4)
    desc=$(x_preset_field "$p" "$i" 5)
    # 第 6 列: 可选, 缺省 none (cut 缺列时给空串, 所以兜成 none)
    enh=$(x_preset_field "$p" "$i" 6); enh=${enh:-none}

    # 表里非法组合要在这里就报错, 而不是照传
    if ! _preset_security_allows "$sec" "$tr"; then
        printf '\033[31m[错误] 预置表有误: %s 不支持 %s (只能 tcp)\033[0m\n' \
            "$sec" "$tr" >&2
        printf '      %s\n' "$disp" >&2
        return 2
    fi

    printf '%s\n%s\n%s\n%s\n%s\n' "$tr" "$sec" "$disp" "$desc" "$enh"
    return 0
}

# 校验整张表 —— 自检用。字段数不对或组合非法的行会被列出来。
x_preset_validate() {
    local row proto tr sec err=0 n=0
    for row in "${X_PRESETS[@]}"; do
        n=$((n+1))
        proto=$(printf '%s' "$row" | cut -d'|' -f1)
        tr=$(printf '%s' "$row" | cut -d'|' -f2)
        sec=$(printf '%s' "$row" | cut -d'|' -f3)
        # 5 段是应有字段数 (末段说明里可能没有 |)
        local fields; fields=$(printf '%s' "$row" | awk -F'|' '{print NF}')
        if [[ "$fields" -lt 5 ]]; then
            printf '  第 %s 行字段数不足 (%s, 应 5): %s\n' "$n" "$fields" "$proto" >&2
            err=1; continue
        fi
        [[ " $_P_TRANSPORTS " == *" $tr "* ]] || {
            printf '  第 %s 行传输未知: %s\n' "$n" "$tr" >&2; err=1; }
        [[ " $_P_SECURITY " == *" $sec "* ]] || {
            printf '  第 %s 行加密未知: %s\n' "$n" "$sec" >&2; err=1; }
        _preset_security_allows "$sec" "$tr" || {
            printf '  第 %s 行组合非法: %s + %s\n' "$n" "$sec" "$tr" >&2; err=1; }
    done
    [[ "$err" -eq 0 ]] && printf '  预置表 %s 行全部合法\n' "$n"
    return "$err"
}

# 有预置的协议清单
x_preset_protocols() {
    printf '%s\n' "${X_PRESETS[@]}" | cut -d'|' -f1 | awk '!seen[$0]++'
}