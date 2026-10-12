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

# ---------------------------------------------------------------- 档位
#
# ★ 为什么给预置分档
#
# 「预置总数」和「全协议该默认带哪些」是两件事。分不清就会得到一个
# 27 项的大列表, 用户挑花眼 —— 而其中相当一部分**根本不该默认出现在
# 全协议一键生成里**:
#
#   socks / http     本地代理档 (无认证的 SOCKS5/HTTP 暴露到公网等于开代理),
#                    只在同一局域网或本机用;
#   裸 TCP + TLS     隧道用法。没有 REALITY 的握手伪装, TLS ClientHello
#                    特征明显, 抗 DPI 最差的一档;
#   WS / gRPC        官方已在文档顶部标了 danger / 弃用, 迁移目标是 XHTTP,
#                    留着是为了兼容老客户端, 不是为了新装;
#   裸 TCP 无加密    仅限内网。
#
# 用户的要求原话: 「全协议一定要是适合于现在的网络环境, 适合于客户端能
# 稳定地、隐蔽地去连接到服务端」。
#
# 所以分四档, 全协议一键生成只取 core + cdn:
#   core    直连, 抗 DPI 最强, 不依赖域名/证书
#   cdn     走 Cloudflare 橙云, 有 CDN + ECH
#   compat  官方已弃用, 只为兼容老客户端保留
#   special 特殊用法 (本地代理 / 隧道 / 内网), 不进默认全协议


# 每个档位在菜单里的一句话说明
_p_tier_desc() {
    case "$1" in
        core)    printf '直连 · 抗 DPI 最强 · 不依赖域名和证书' ;;
        cdn)     printf '走 Cloudflare 橙云 · 可开 ECH · 适合被墙与限速环境' ;;
        compat)  printf '官方已弃用 · 仅供兼容老客户端 · 新装不建议' ;;
        special) printf '特殊用法 (本地代理 / 隧道 / 内网) · 不进默认全协议' ;;
        *)       printf '' ;;
    esac
}

# 全协议一键生成只取这两档
_P_TIERS_DEFAULT="core cdn"

# ---------------------------------------------------- 上下行分离的三个组合
#
# ★ 为什么单独一张表, 不塞进 X_PRESETS
#
#   X_PRESETS 描述的是"一个节点长什么样"(协议|传输|加密层|名字|说明|extras),
#   而上下行分离描述的是**两段各自怎么走**。一个节点有两组安全层, 一行放不下。
#   硬塞进去会让 protocol|transport|security 这一列含义漂移 —— 那一列现在
#   被 REALITY 白名单 (_P_REALITY_TRANSPORTS) 和各处判断依赖着。
#
# 字段: 上行安全层|下行安全层|下行是否挂 nginx|默认开 ECH|监听档位
#
# ★ 监听档位 (第 5 列) 不是"哪段走 CDN", 而是"**谁直连 xray 端口**":
#
#     cdn    → xray 监听 0.0.0.0   (公网可达)
#     nginx  → xray 监听 127.0.0.1 (只有本机 nginx 能连)
#
#   判据只有一条: **只要有任何一段是客户端直连的, 就必须监听 0.0.0.0**。
#   0.0.0.0 是包含 127.0.0.1 的, 所以 nginx 反代照样能连上 —— 反过来不行,
#   监听 127.0.0.1 时直连的那一段永远连不上, 而且内核不报错。
#
#     cdn-cdn     两段都经 nginx → nginx
#     cdn-reality 下行直连       → cdn
#     reality-cdn 上行直连       → cdn
#
#   我原来按"下行是否挂 nginx"推档位, 于是 cdn-reality 推成"直连" —— 但
#   **直连不是一个档位**, deploy.py 只认 cdn / nginx, 直接报
#   "未知接入档位: direct"。档位名和"直连"这个概念被混在一起了。
#
#   cdn-cdn     上行 CDN(Cloudflare TLS) + 下行 CDN
#               —— 两段都走橙云, 藏得最深; 默认开 ECH, 否则真实 SNI 会外泄,
#                  域名字面可探测。**最稳, 但多一跳且吃 CF 的限制。**
#   cdn-reality 上行 CDN(Cloudflare TLS) + 下行 REALITY
#               —— 上行藏进 CDN, 下行直连并用 REALITY 握手伪装。上行被封时
#                  下行仍可能通 (反向不行: CF 被封则两段一起废)。
#   reality-cdn 上行 REALITY + 下行 CDN
#               —— 现成的预置 ⑥ 就是这个形态。
#
# ★ 两条硬约束 (实测, 不是风格问题)
#
#   1. 上下行**端口必须相同**: 会话表 h.sessions 挂在每个 inbound 自己身上
#      (hub.go:39/464), 下行 GET 到别的端口就查不到会话。CDN 与直连的差别
#      只能体现在**网络路径**上 —— 所以两段 nginx 都要 proxy_pass 到同一个
#      xray 端口。
#   2. 上下行**path 必须相同**: 服务端只用顶层 xhttpSettings.path 校验下行
#      请求 (hub.go:461), 入站那份 downloadSettings 不参与校验。差异要
#      体现在域名上, 不是路径上。
#
_P_SPLIT_MODES="cdn-cdn cdn-reality reality-reality reality-cdn"

_p_split_field() { # <模式> <第几列>
    case "$1:$2" in
        cdn-cdn:1)      echo "tls"     ;;
        cdn-cdn:2)      echo "tls"     ;;
        cdn-cdn:3)      echo "yes"     ;;   # 两段都挂 nginx
        cdn-cdn:4)      echo "yes"     ;;   # ★ 默认开 ECH
        cdn-cdn:5)      echo "nginx"   ;;   # 两段都经 nginx → 127.0.0.1
        cdn-reality:1)  echo "tls"     ;;
        cdn-reality:2)  echo "reality" ;;
        cdn-reality:3)  echo "no"      ;;   # 下行直连, 不挂 nginx
        cdn-reality:4)  echo "yes"     ;;
        cdn-reality:5)  echo "cdn"     ;;   # 下行直连 → 必须 0.0.0.0
        reality-reality:1) echo "reality" ;;
        reality-reality:2) echo "reality" ;;
        reality-reality:3) echo "no"      ;;   # 上下行都直连, 不挂 nginx
        reality-reality:4) echo "no"      ;;   # REALITY 无 TLS, 没 ECH 可开
        reality-reality:5) echo "cdn"     ;;   # 直连 → 必须 0.0.0.0
        reality-cdn:1)  echo "reality" ;;
        reality-cdn:2)  echo "tls"     ;;
        reality-cdn:3)  echo "yes"     ;;   # 只有上行不挂, 下行走 CDN
        reality-cdn:4)  echo "no"      ;;   # 上行 REALITY 无 TLS, 没 ECH 可开
        reality-cdn:5)  echo "cdn"     ;;   # 上行直连 → 必须 0.0.0.0
        *) return 1 ;;
    esac
}

x_split_modes() { printf '%s\n' $_P_SPLIT_MODES; }

x_split_ul_sec() { _p_split_field "$1" 1; }
x_split_dl_sec() { _p_split_field "$1" 2; }
x_split_dl_cdn() { _p_split_field "$1" 3; }
x_split_ech()    { _p_split_field "$1" 4; }
x_split_tier()   { _p_split_field "$1" 5; }

x_split_title() {
    case "$1" in
        cdn-cdn)     printf '上行 CDN + 下行 CDN' ;;
        cdn-reality) printf '上行 CDN + 下行 REALITY' ;;
        reality-reality) printf '上行 REALITY + 下行 REALITY' ;;
        reality-cdn) printf '上行 REALITY + 下行 CDN' ;;
        *) printf '%s' "$1" ;;
    esac
}

x_split_desc() {
    case "$1" in
        cdn-cdn)
            printf '两段都走 Cloudflare 橙云, 默认开 ECH。藏得最深, 域名字面不外泄; 代价是多一跳 + 受 CF 限制。' ;;
        cdn-reality)
            printf '上行藏进 CDN, 下行直连并用 REALITY 握手伪装。上行被打时下行可能仍通 (反过来不行: CF 挂了两段一起废)。' ;;
        reality-reality)
            printf '两段都用 REALITY 直连, 不经任何第三方。抗 DPI 最强, 也不受 Cloudflare 限制; 代价是完全没有 CDN 掩护, 客户端必须能直连服务器。' ;;
        reality-cdn)
            printf '上行用 REALITY 直连伪装, 下行走 CDN。⚠ 实测不通 —— 见交接文档第二节。' ;;
        *) printf '' ;;
    esac
}

# ---------------------------------------------------------------- 档位表
#
# ★ 为什么用独立表, 不把档位塞进 X_PRESETS 那一行
#
#   X_PRESETS 每一行的字段数**本来就不统一**: VLESS 的行尾部带 extras
#   (mlkem,mldsa65 / none|none), 别的协议不带。而读取方 (x_preset_list /
#   preset_batch) 是按位置 cut -f4/-f5 取名字和说明的 —— 在行尾追加一个
#   字段, 就会让"有的行多一个尾字段"这件事变成"有的行多两个", 迟早有人
#   按位置读错。所以档位单独一张表, 按 "协议:序号" 索引, 零风险。
#
# 分档标准 (对应用户的要求「适合于现在的网络环境, 适合于客户端能稳定地、
# 隐蔽地去连接到服务端」):
#   core    直连 · 抗 DPI 最强 · 不依赖域名/证书      → 进默认全协议
#   cdn     走 Cloudflare 橙云 · 可开 ECH             → 进默认全协议
#   compat  官方已弃用 (WS/gRPC), 只为兼容老客户端    → 不进
#   special 特殊用法 (本地代理/隧道/内网/裸 TCP)      → 不进

_P_TIER_DEFAULT="core cdn"

_P_TIERS_table() {
    # 协议:序号  格式
    cat <<'TIERS'
vless:1 core
vless:2 core
vless:3 special
vless:4 cdn
vless:5 cdn
vless:6 core
vless:7 compat
vless:8 compat
vless:9 compat
vless:10 special
trojan:1 core
trojan:2 cdn
trojan:3 compat
trojan:4 compat
trojan:5 special
vmess:1 cdn
vmess:2 compat
vmess:3 compat
vmess:4 special
shadowsocks:1 core
shadowsocks:2 special
shadowsocks:3 special
hysteria2:1 core
socks:1 special
socks:2 special
http:1 special
http:2 special
TIERS
}

# 该协议第 n 个预置的档位; 查不到一律按 special (宁可不默认推, 也不误推)
_p_tier_of() { # <协议> <序号>
    local t
    # 表里是 "协议:序号 档位" (冒号在第一段里, 空格分隔两段), 所以按空格切,
    # 再把第一段按冒号拆。之前用 -F: 切全行, 结果 $1 是 "vless:1"、
    # $2 是 "core", 与协议/序号完全对不上 —— 查不到就走了 special 兜底,
    # 于是**所有**预置都被当成特殊用途, 默认全协议一个都没有 (静默为空)。
    t=$(_P_TIERS_table | awk -v key="$1:$2" '$1==key {print $2; exit}')
    printf '%s' "${t:-special}"
}

# 该协议里属于默认全协议 (core+cdn) 的序号, 空格分隔
_p_default_indexes() { # <协议>
    local d t i n out=""
    d=" $_P_TIER_DEFAULT "
    n=$(x_preset_count "$1" 2>/dev/null) || n=0
    for i in $(seq 1 "$n"); do
        t=$(_p_tier_of "$1" "$i")
        case "$d" in *" $t "*) out="$out $i";; esac
    done
    printf '%s' "${out# }"
}

_p_tier_desc() {
    case "$1" in
        core)    printf '直连 · 抗 DPI 最强 · 不依赖域名和证书' ;;
        cdn)     printf '走 Cloudflare 橙云 · 可开 ECH · 适合被墙与限速环境' ;;
        compat)  printf '官方已弃用 · 仅供兼容老客户端 · 新装不建议' ;;
        special) printf '特殊用法 (本地代理 / 隧道 / 内网) · 不进默认全协议' ;;
        *)       printf '' ;;
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
    "vless|xhttp|reality|⑥ REALITY + XHTTP 上下行分离|★ **上下行真正分开**: 下行走独立 GET、上行走独立 POST —— 不是一条连接上双工。内核里 mode=stream-up。注意 REALITY 下 auto 会退化成 stream-one (合流), 要分离**必须显式选这一档**。不加 Vision (XTLS 只支持裸 TCP 直连)|none|none"
    "vless|ws|tls|⑦ WS + TLS（官方已弃用）|⚠ 官方文档顶部已挂 danger: \"推荐换用 XHTTP\". 迁移目标 XHTTP H2 & H3 — 只有在服务端/CDN 明确只吃 WS 时才选它"
    "vless|grpc|tls|⑧ gRPC + TLS|gRPC 走 HTTP/2. ⚠ 官方已标为**弃用**(非移除), 迁移目标 XHTTP stream-up — 新装优先选 ④"
    "vless|httpupgrade|tls|⑨ HTTPUpgrade + TLS|比 WS 更轻的 HTTP 升级. ⚠ 官方已标为**弃用**(非移除), 迁移目标 XHTTP — 新装优先选 ④"
    "vless|tcp|tls|⑩ 裸 TCP + TLS|最简单但最易被识别; 只在确认不需要抗 DPI 时用|"
    # ---------- Trojan ----------
    "trojan|tcp|reality|① 隐匿优先 · REALITY + Vision|裸 TCP + REALITY; Trojan 侧最抗 DPI 的组合"
    "trojan|xhttp|tls|② CDN 友好 · XHTTP + TLS|★ 官方主推传输; 可走 Cloudflare 橙云 (与 VLESS 口径一致)"
    "trojan|ws|tls|③ WS + TLS（官方已弃用）|⚠ 官方推荐换用 XHTTP; 只在服务端只吃 WS 时选它"
    "trojan|grpc|tls|④ gRPC + TLS|gRPC 走 HTTP/2. ⚠ 官方已弃用(非移除), 迁移目标 XHTTP"
    "trojan|tcp|tls|⑤ 裸 TCP + TLS|最常见的默认选择|"
    # ---------- VMess ----------
    "vmess|xhttp|tls|① CDN 友好 · XHTTP + TLS|★ 官方主推传输 (与 VLESS/Trojan 口径一致)"
    "vmess|ws|tls|② WS + TLS（官方已弃用）|⚠ 官方推荐换用 XHTTP"
    "vmess|grpc|tls|③ gRPC + TLS|gRPC 走 HTTP/2. ⚠ 官方已弃用(非移除), 迁移目标 XHTTP"
    "vmess|tcp|tls|④ 裸 TCP + TLS|改连 TCP 伪装, 需要 VMess 自身配置|"
    # ---------- Shadowsocks ----------
    "shadowsocks|tcp|reality|① 隐匿优先 · REALITY|裸 TCP + REALITY; 协议本身简单, 靠 REALITY 补抗识别"
    "shadowsocks|tcp|tls|② 裸 TCP + TLS|标准用法"
    "shadowsocks|tcp|none|③ 裸 TCP · 无加密|仅在同一局域网内使用; 跨公网务必换前两个|"
    # ---------- Hysteria2 ----------
    # hysteria2 走 UDP, 传输固定, 只有 TLS 一档。
    "hysteria2|hysteria|tls|① 标准 (UDP + TLS)|Hysteria2 只支持 UDP; 抗弱网能力来自协议本身, 不靠传输伪装|"
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
    # $2 = "all"(默认) | "default"(只列 core+cdn)
    local p="$1" only="${2:-all}" row n=0 cnt tier tdesc mark
    cnt=$(x_preset_count "$p")
    [[ "$cnt" -gt 0 ]] || { printf '协议 %s 没有预置\n' "$p" >&2; return 1; }
    if [[ "$only" == "default" ]]; then
        # 编号会**跳号** (如 1,2,4,5) —— 这是故意的: 编号就是预置序号,
        # 用户在命令行里敲的 `vless:4` 必须指同一项。重新编号的话,
        # 菜单里看到的 3 和实际生效的第 4 项会对不上, 而这种错不会报错,
        # 只会让用户拿到一个自己没点的配置。
        printf '  \033[2m(★ = 默认全协议会带; 编号有跳号是正常的, 它就是预置序号)\033[0m\n' >&2
    fi
    for row in "${X_PRESETS[@]}"; do
        [[ "${row%%|*}" == "$p" ]] || continue
        n=$((n+1))
        tier=$(_p_tier_of "$p" "$n")
        if [[ "$only" == "default" ]]; then
            case " $_P_TIER_DEFAULT " in *" $tier "*) ;; *) continue ;; esac
        fi
        # 默认全协议会带的那几项标 ★, 其余说清为什么不用 ——
        # 只写"不推荐"而不说理由, 用户会当成脚本有偏好而不是有依据。
        case "$tier" in
            core|cdn) mark='★' ;;
            *)        mark=' ' ;;
        esac
        printf '  %s) %s%s\n' "$n" "$mark" "$(printf '%s' "$row" | cut -d'|' -f4)" >&2
        printf '     %s\n'     "$(printf '%s' "$row" | cut -d'|' -f5)" >&2
        tdesc=$(_p_tier_desc "$tier")
        [[ -n "$tdesc" ]] && printf '     \033[2m[%s] %s\033[0m\n' "$tier" "$tdesc" >&2
    done
    return 0
}

# 某个协议默认全协议用哪几项 —— 批量生成与菜单显示共用这一处口径,
# 免得"菜单里写着默认"与"实际生成了什么"两处对不上。
x_preset_default_list() { # <协议>
    local p="$1" idx
    for idx in $(_p_default_indexes "$p"); do
        printf '%s ' "$idx"
    done
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