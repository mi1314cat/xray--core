#!/usr/bin/env bash
# Xray 项目证书校验公共库
#
# 只管"能不能用"这件事: 路径存不存在、文件是不是有效证书、证书有没有过期、
# key 和 crt 配不配对。
#
# 为什么单独做: 证书问题在现场的表现是"节点配好了但连不上", 而配置校验
# (xray run -test) 对一个不存在的证书文件并不总是报错 —— 校验通过、启动
# 失败, 或者更糟, 启动成功但握手永远失败。必须在生成阶段就拦住。

# 依赖外部环境的路径。给默认值不是为了"支持自定义", 而是因为在 set -u
# 下未定义会**直接终止整个 shell** —— 表现为菜单执行到一半静默退出, 没有任何
# 报错。库不该指望调用方一定先设好这些。
: "${XRAY_BASE:=/root/catmi/xray}"
: "${CONF_DIR:=$XRAY_BASE/conf}"
: "${MAIN_CONFIG:=$XRAY_BASE/config.json}"
: "${SHARE_DIR:=$XRAY_BASE/out/share}"

# x_cert_check <crt> <key> [期望域名]
#
# 返回 0 可用; 非 0 时错误信息已打到 stderr。
x_cert_check() {
    local crt="$1" key="$2" want="${3:-}"
    local err=""
    if [[ -z "$crt" || -z "$key" ]]; then
        printf '证书路径为空 (crt=%s key=%s)\n' "$crt" "$key" >&2
        return 1
    fi
    [[ -f "$crt" ]] || { printf '证书不存在: %s\n' "$crt" >&2; return 1; }
    [[ -f "$key" ]] || { printf '私钥不存在: %s\n' "$key" >&2; return 1; }
    [[ -r "$crt" ]] || { printf '证书不可读: %s\n' "$crt" >&2; return 1; }
    [[ -r "$key" ]] || { printf '私钥不可读: %s\n' "$key" >&2; return 1; }

    command -v openssl >/dev/null 2>&1 || {
        printf '缺 openssl, 无法校验证书\n' >&2
        return 1
    }

    # 是不是真的 PEM 证书 (而不是空文件 / HTML 错误页 / 别的文本)
    if ! openssl x509 -in "$crt" -noout >/dev/null 2>&1; then
        err=$(head -c 60 "$crt" | tr -d '\0' | tr '\n' ' ')
        printf '证书无法解析 (可能下载到了错误页): %s\n' "${err:0:60}" >&2
        return 1
    fi
    # 私钥是不是真的私钥
    if ! openssl pkey -in "$key" -noout >/dev/null 2>&1; then
        err=$(head -c 60 "$key" | tr -d '\0' | tr '\n' ' ')
        printf '私钥无法解析: %s\n' "${err:0:60}" >&2
        return 1
    fi

    # 过期检查。只看 notAfter —— notBefore 过期的情况罕见但存在。
    # -checkend 0 的语义是"再过 0 秒是否还有效", 即已过期则非 0。
    if ! openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then
        printf '证书已过期: %s (到期 %s)\n' \
            "$crt" "$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)" >&2
        return 1
    fi
    # 30 天内到期要提醒 —— 过期当天才发现, 通常已经忘了节点在哪台机器上。
    # -checkend N 返回 0 的意思是"再过 N 秒仍然有效"。所以返回**非 0**
    # 才是临期。写反了会对每一张正常证书都报临期, 报多了就等于没报。
    if ! openssl x509 -in "$crt" -noout -checkend $((30*86400)) >/dev/null 2>&1; then
        printf '证书将在 30 天内过期: %s (到期 %s)\n' \
            "$crt" "$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)" >&2
    fi

    # crt 和 key 是不是一对
    local a b
    a=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
    b=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null)
    if [[ -n "$a" && -n "$b" && "$a" != "$b" ]]; then
        printf '证书与私钥不配对 (crt=%s key=%s)\n' "$crt" "$key" >&2
        return 1
    fi

    # 期望域名对不上是最难查的一类: 配置全对、服务在跑、客户端就是握手失败
    if [[ -n "$want" ]]; then
        local got san
        got=$(x_cert_domain "$crt")
        san=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null)
        if [[ -n "$got" && "$got" != "$want" ]]; then
            if grep -qE "DNS:${want}\b" <<< "$san" || grep -qE "DNS:\*\." <<< "$san"; then
                :   # 通配符或 SAN 里确实有期望域名, 以 openssl 判定为准
            else
                printf '证书域名与使用域名不一致: 证书=%s 使用=%s\n' "$got" "$want" >&2
                printf '  证书 SAN: %s\n' "$(grep -oE 'DNS:[^,]+' <<< "$san" | tr '\n' ' ' | sed 's/^/DNS:/' | cut -c1-120)" >&2
                return 1
            fi
        fi
    fi
    return 0
}

# x_cert_domain <crt> —— 从证书取真实域名
#
# 优先 SAN (现代签发方都在 SAN 里), 回退 CN。取不到再用文件名猜 —— 文件名
# 猜出来的域名是**猜测**, 调用方若要拿它去核对, 必须知道这一点。
x_cert_domain() {
    local crt="$1" dom=""
    if command -v openssl >/dev/null 2>&1 && [[ -f "$crt" ]]; then
        dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null |
            grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
        [[ -z "$dom" ]] && dom=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null |
            grep -oE "CN *= *[^,]+" | head -1 | sed 's/.*CN *= *//' | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi
    if [[ -z "$dom" && -n "$crt" ]]; then
        # 拿不到就按文件名猜, 并在 stderr 说明这是猜的
        dom=$(basename "$crt" | sed -E 's/\.(crt|pem|cer)$//; s/_cert$//; s/^cert-//')
        printf '证书里读不到域名, 按文件名猜: %s\n' "$dom" >&2
    fi
    printf '%s' "$dom"
}


# x_cert_trusted <crt> —— 这张证书是不是"有独立签发者的真证书"
#
# ★ 为什么不能靠"文件存在"来判断: 自签证书也是两个文件。
#   判错的后果是**客户端连不上** —— 自签被当成真证书 => 客户端做正常校验
#   => 校验失败; 反过来真证书被当成自签 => 客户端带着错误的钉扎去连。
#   两个方向都是"配置全对、服务在跑、就是握手失败"。
#
# 判据: subject != issuer。自签证书自己给自己签, 两者相同。
# 不拿"是不是已知公共 CA"当必要条件 —— 那会漏判小众 CA。
x_cert_trusted() {
    local crt="${1:-}" subj issuer
    [[ -f "$crt" ]] || return 1
    subj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    [[ -z "$subj" || -z "$issuer" ]] && return 1
    [[ "$subj" == "$issuer" ]] && return 1
    return 0
}


# x_cert_client_pin <crt> <TLS 是否终止于本节点: 0|1> [强制: 0|1]
#
# 输出该写进客户端配置的 pinnedPeerCertSha256 (证书 DER 的 hex sha256);
# **不该写时输出空**, 返回 0。
#
# ★ 钉扎的指纹必须与"客户端真的会看到的那张证书"一致, 否则连接必然失败:
#     tls: failed to verify certificate:
#         peer cert is unrecognized (against pinnedPeerCertSha256)
#   实测 (RN 生产 vless-xhttp07, 2026-10): 源站证书是 Let's Encrypt 签的
#   moontv.6896698.xyz (DER sha256 48165d74...), 而客户端经 CDN-ECH 连的是
#   Cloudflare 边缘, 边缘出示的是 Google Trust Services 签的另一张证书
#   (DER sha256 601927a1...) —— 两个指纹天然不同, 挂了 pin 就永远连不上,
#   而节点本身完全正常。
#
# 所以判据是三条, 不是"证书文件存在":
#   1. TLS 由本节点终结 —— 走 nginx 或 CDN 时边缘出示的是别的证书
#   2. 证书不是公网 CA 签的 (x_cert_trusted 为假) —— 真证书走正常校验,
#      钉扎只会"证书一续期就连不上"
#   3. 算得出指纹
# 与 SB 的 CERT_TRUSTED / M 的 cert_is_trusted 是同一套判据 (自签才 pin,
# 真证书不 pin)。用户显式要求 (强制=1) 时跳过 1、2 两条。
x_cert_client_pin() {
    local crt="${1:-}" here="${2:-0}" force="${3:-0}"
    if [[ "$force" != "1" ]]; then
        [[ "$here" = "1" ]] || return 0
        x_cert_trusted "$crt" && return 0
    fi
    [[ -f "$crt" ]] || return 0
    openssl x509 -in "$crt" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}


# 输出用的颜色。cert.sh 是独立库, 不假设宿主脚本定义了 print_ok 之类。
_CERT_GRN=""; _CERT_YEL=""; _CERT_RED=""; _CERT_RST=""
if [[ -t 2 ]]; then
    _CERT_GRN=$'\033[32m'; _CERT_YEL=$'\033[33m'
    _CERT_RED=$'\033[31m'; _CERT_RST=$'\033[0m'
fi

# ================================================================ 在用检测
# 删证书前必须确认没人引用。
#
# 证书被 conf/ 片段、nginx 站点、分享元数据任一处引用着就删不得 —— 引用是
# 按绝对路径字符串匹配的, 而这些路径散落在多个地方。只扫 conf/*.json 会漏掉
# nginx 那一份, 而漏掉的后果是"证书删了, nginx 起不来", 且现场早就没了。

x_cert_in_use() {
    local want="$1" f
    [[ -n "$want" ]] || return 1
    want=$(readlink -f "$want" 2>/dev/null || printf '%s' "$want")
    local base; base=$(basename "$want")
    # 文件名匹配必须带边界。纯子串匹配会让 nginxused.crt 里命中 used.crt ——
    # 结果是每张证书都显示"仍在使用", GC 一个也删不掉。
    # 文件名匹配必须带边界。纯子串匹配会让 nginxused.crt 里命中 used.crt ——
    # 结果是每张证书都显示"仍在使用", GC 一个也删不掉。
    # 字符类只取路径与 nginx 指令里实际出现的分隔符, 不含引号, 免得在
    # 双引号字符串里还要转义单引号。
    local esc=${base//./\\.}
    local pat="(^|[^A-Za-z0-9._-])${esc}([^A-Za-z0-9._-]|$)"

    # 1) Xray 片段与主配置
    # 逐个目录处理, 不用 "${roots[@]}"/"$pat" 这种"数组 + 带引号的通配"写法。
    # 那写法里引号会把 * 变成字面量, 于是循环体拿到的是目录本身而不是
    # 目录里的文件 —— grep 目录永远不命中, 每张证书都被判成"没人引用",
    # GC 于是把正在用的证书删掉。方向反过来: 先让通配展开, 再逐个比对。
    local d
    for d in "$CONF_DIR" "$(dirname "${MAIN_CONFIG:-$CONF_DIR/config.json}")"; do
        local f
        for f in "$d"/*.json; do
            [[ -f "$f" ]] || continue
            grep -qF -- "$want" "$f" 2>/dev/null && return 0
            grep -qE -- "$pat" "$f" 2>/dev/null && return 0
        done
    done

    # 2) nginx 站点 —— Xray 部署里证书常常也签给 nginx 用
    # 路径可被 X_CERT_NGINX_DIRS 覆盖 (测试用)。
    local d
    for d in ${X_CERT_NGINX_DIRS:-/etc/nginx/conf.d /etc/nginx/sites-enabled /usr/local/nginx/conf}; do
        [[ -d "$d" ]] || continue
        if grep -rqF -- "$want" "$d" 2>/dev/null; then return 0; fi
        grep -rqE -- "$pat" "$d" 2>/dev/null && return 0
    done

    # 3) 分享元数据 (可能存了证书路径)
    if [[ -n "${SHARE_DIR:-}" && -d "$SHARE_DIR" ]]; then
        grep -rqE -- "$pat" "$SHARE_DIR" 2>/dev/null && return 0
    fi
    return 1
}

# 列出仍在引用的位置, 供删除前告知用户。
x_cert_referenced_by() {
    local want="$1" f base
    want=$(readlink -f "$want" 2>/dev/null || printf '%s' "$want")
    base=$(basename "$want")
    # 文件名匹配必须带边界。纯子串匹配会让 nginxused.crt 里命中 used.crt ——
    # 结果是每张证书都显示"仍在使用", GC 一个也删不掉。
    # 字符类只取路径与 nginx 指令里实际出现的分隔符, 不含引号, 免得在
    # 双引号字符串里还要转义单引号。
    local esc=${base//./\\.}
    local pat="(^|[^A-Za-z0-9._-])${esc}([^A-Za-z0-9._-]|$)"
    local d
    for f in "$CONF_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        { grep -qF -- "$want" "$f" || grep -qE -- "$pat" "$f"; } 2>/dev/null \
            && printf '  Xray 配置: %s\n' "$f"
    done
    for d in ${X_CERT_NGINX_DIRS:-/etc/nginx/conf.d /etc/nginx/sites-enabled /usr/local/nginx/conf}; do
        [[ -d "$d" ]] || continue
        grep -rlE -- "$pat" "$d" 2>/dev/null | while read -r f; do
            printf '  nginx 站点: %s\n' "$f"
        done
    done
}

# ================================================================ GC
# 只删真正没人用的证书, 有引用的跳过并告警。
#
# 不静默删: 用户以为自己清理干净了, 第二天节点全挂, 而证书已经在垃圾桶里。
# ★ 最后一道闸: nginx 站点里有没有提到这个文件。
#
#   x_cert_in_use 只认 X 内核自己那套 (片段 / 进程 / XRAY_BASE), 而 nginx
#   站点里的 ssl_certificate 是**另一批引用** —— 而且nginx 跑在容器里时,
#   里面写的是 /etc/nginx/certs/xxx, 宿主上却是 /home/web/certs/xxx,
#   两边路径根本对不上。于是"没被 X 用到" → 当垃圾删掉。
#
#   后果不是难看: nginx 启动时只要有一个 ssl_certificate 读不到就 [emerg]
#   退出 → 容器进重启循环 → Cloudflare 回源 521 → **所有 CDN 节点一起挂**。
#   实测在 RN 上被这套逻辑清空了整个 /home/web/certs/。
#
#   所以这里按 **basename** 再查一遍站点文件 —— 路径写法不同没关系,
#   同名就是同一张证书。宁可多留一个文件, 也不能删掉还在用的。
x_cert_referenced_by_nginx() {
    local f="$1" base d
    base=$(basename "$f")
    for d in /home/web/conf.d /etc/nginx/conf.d /etc/nginx/sites-enabled "$XRAY_BASE"/nginx; do
        [[ -d "$d" ]] || continue
        grep -rlF "$base" "$d"/*.conf 2>/dev/null | grep -q . && return 0
    done
    return 1
}

x_cert_gc() {
    local c base removed=0 kept=0
    for c in "$@"; do
        [[ -e "$c" ]] || continue
        base=$(basename "$c")
        if x_cert_referenced_by_nginx "$c"; then
            printf '  %s%s%s 被 nginx 站点引用, 跳过\n' "$_CERT_YEL" "$base" "$_CERT_RST" >&2
            kept=$((kept + 1))
        elif x_cert_in_use "$c"; then
            printf '  %s%s%s 仍在使用, 跳过\n' "$_CERT_YEL" "$base" "$_CERT_RST" >&2
            x_cert_referenced_by "$c" >&2
            kept=$((kept+1))
        else
            rm -f -- "$c" && { printf '  %s%s%s 已删除\n' "$_CERT_GRN" "$base" "$_CERT_RST" >&2; removed=$((removed+1)); }
        fi
    done
    printf '  清理完成: 删除 %s 个, 保留 %s 个\n' "$removed" "$kept" >&2
    [[ "$kept" -eq 0 ]]
}

# ================================================================ 容器感知
#
# "Docker 能力"在本项目里不是"把 Xray 部署进容器", 而是与容器共处:
# 配套服务 (nginx) 跑在容器里时, 命令必须打向容器而不是宿主。
#
# 证书这一层最容易踩: 容器化 nginx 常把证书挂进容器, 宿主对应目录是空的。
# 只扫宿主目录的结果是"一张证书都找不到", 而证书明明就在 nginx 正在用的
# 地方 —— 表现是续期脚本报告"没有可续期的证书", 实际是扫描路径错了。

# 列出应扫描的证书目录: 宿主的常规路径 + Docker 挂载进来的路径。
x_cert_search_dirs() {
    local d
    # 注意: 不含 /etc/ssl/certs —— 那是系统信任库, 里面一百多张全是 CA,
    # 没有一张是用户的证书。把它当搜索范围, "列出我的证书"会列出 120 个
    # 无关文件, 把用户自己那两三张淹掉。用户的证书在 letsencrypt 的 live/
    # 或项目自己的 certs 目录。
    # 这几个目录的取舍对齐 sing-box-core 的 sb_scan_certs —— 它是被实机
    # 打过的: RN 上用户的证书就在 /home/web/certs, 而我们原来没扫它,
    # 于是面板"找不到证书", 站点其实一直在用。
    #
    #   /home/web/certs         KPanel / 容器化 nginx 的宿主证书目录
    #   /root/catmi/cloudflare/certs  本项目 catmi 体系的证书目录
    #   /root/.acme.sh           acme.sh 默认落盘位置, 和 letsencrypt 并列
    for d in /etc/letsencrypt/live /root/catmi/xray/certs \
             /root/catmi/certs /usr/local/share/letsencrypt/live \
             /home/web/certs /root/catmi/cloudflare/certs /root/.acme.sh \
             ${X_CERT_EXTRA_DIRS:-/nonexistent}; do
        [[ -d "$d" ]] && printf '%s\n' "$d"
    done

    command -v docker >/dev/null 2>&1 || return 0
    # docker ps 在没有守护进程时是瞬时返回的, 但给个超时防止卡住面板 ——
    # 与 service.sh 同样的理由: 辅助查询不该有能力挂住整个面板。
    local cid src
    for cid in $(timeout 5 docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx); do
        # 从挂载关系反推宿主路径。只认真的挂进证书目录的, 不猜。
        src=$(timeout 5 docker inspect "$cid" \
              --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/certs"}}{{.Source}}{{end}}{{if eq .Destination "/etc/nginx/ssl"}}{{.Source}}{{end}}{{end}}' \
              2>/dev/null | head -1)
        [[ -n "$src" && -d "$src" ]] && printf '%s\n' "$src"
    done
}

# 在所有已知目录里找证书文件。
#
# 与 mihomo 版一致的排除规则: 私钥不算证书。*_key.pem / *key*.pem 会被
# 混进 .pem 扫描结果, 而把私钥当成"待续期证书"会导致续期脚本对着一把
# 私钥申请续期。
# 系统信任库不算"用户的证书"。判据看内容: 装的是 CA 集合而不是一张叶子
# 证书。按文件名排除不保险 —— ca-certificates.crt 在 /etc/pki/tls/certs
# (RHEL 系) 和 /usr/local/share/certs (FreeBSD) 里名字都不一样, 而用户
# 也可能把自己的证书就叫 ca.crt。
_x_skip_bundle() {
    local f="$1" n
    n=$(grep -c 'BEGIN CERTIFICATE' "$f" 2>/dev/null) || return 1
    # 一张叶子证书 vs 一整包 CA。16 是个凭经验取的界: 自签根证书包里
    # 通常十几到几十个, 单张证书加一两条中间链不会到这个量。
    (( n > 16 ))
}


x_cert_list() {
    local d f
    while read -r d; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.pem "$d"/*.crt; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *_key.pem || "$f" == *key*.pem ]] && continue
              # 系统 CA 包要排除。/etc/ssl/certs 里有一百多个, 全列出来
              # 会把用户自己那两三张证书淹掉 —— 而"列出我的证书"这个
              # 需求里 ca-certificates.crt 显然不是用户的证书。
              _x_skip_bundle "$f" && continue
            printf '%s\n' "$f"
        done
    done < <(x_cert_search_dirs)
}

# x_cert_find_for_domain <域名> -> stdout "crt<TAB>key", 找不到返回 1
#
# ★ 为什么需要它: 建 TLS 节点时用户只给了**域名**, 而 TLS 入站真正需要的是
#   一对 `certificates`。这两者不是一回事 —— 只写 serverName 不带证书的内核
#   **启动完全成功**, 但每一次握手都失败:
#
#       http: TLS handshake error from …: tls: no certificates configured
#
#   实测 (接手审计, RN 真内核): 菜单 13 建出来的 vless+xhttp+tls 节点
#   `xray run -test` → Configuration OK, 真启动 → "started",
#   然后 `openssl s_client` → unrecognized name / no peer certificate,
#   curl https → 000。**每一项检查都过, 节点就是连不上。**
#   面板里没有任何一处能看出缺证书 —— 只有服务端日志里有。
x_cert_find_for_domain() { # <域名>
    local want; want=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [[ -n "$want" ]] || return 1
    local f dom key
    while read -r f; do
        [[ -f "$f" ]] || continue
        dom=$(x_cert_domain "$f" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [[ -n "$dom" ]] || continue
        # 完全相等, 或者证书是通配 `*.example.com` 而域名是它的子域。
        # 只在这两种情况下算命中 —— 不做"包含"匹配, 那会让
        # `a.example.com` 误配到 `b.example.com` 的证书上。
        case "$dom" in
            "$want") ;;
            "*.$want") ;;
            *)
                case "$want" in
                    *."${dom#\*.}") ;;
                    *) continue ;;
                esac ;;
        esac
        key=$(x_cert_key_for "$f") || continue
        printf '%s\t%s\n' "$f" "$key"
        return 0
    done < <(x_cert_list)
    return 1
}

# ---------------------------------------------------------------- 证书方案
#
# 下面这几个是照 sing-box-core 的 cert 那一层设计的 (sb_has_key_for /
# cert_not_expired / sb_selfgen_cert / pick_trusted_cert_verbose)。
# 学的是**交互与流程**, 不是配置 —— Xray 与 sing-box 的证书字段完全不同。
#
# 为什么值得学: SB 在这一层的核心设计是「**永远有出路**」——
#   扫描不到 → 手动输入 → 输入无效 → 自签。
#   每一条失败路径都有下一步, 用户不会被堵在"没有证书"上。
# X 原来只有"找不到就拒绝", 于是没有证书的机器**根本建不出 TLS 节点**。

# 私钥可能在的方向 —— 各家工具落盘命名不一样, 挨个试。
#
# ★ 为什么不是"同名换后缀"一条: acme.sh 落 `x.pem` + `x.key`,
#   certbot 落 `fullchain.pem` + `privkey.pem`, KPanel 落 `x.crt` + `x.key`,
#   nginx 常见 `x.crt` + `x_key.pem`。只试一种, 明明有的证书会判成"没有私钥",
#   用户看到的是"证书存在但用不了"。
x_cert_key_for() { # <crt> -> stdout 私钥路径
    local crt="${1:-}" k
    [[ -f "$crt" ]] || return 1
    for k in "${crt%.crt}.key" "${crt%.pem}.key" "${crt%.cer}.key" \
             "${crt%.pem}_key.pem" "${crt%_cert.pem}_key.pem" \
             "$(dirname "$crt")/privkey.pem" \
             "$(dirname "$crt")/$(basename "${crt%.crt}").key"; do
        [[ -f "$k" ]] && { printf '%s' "$k"; return 0; }
    done
    return 1
}

# 证书还有没有效 —— 留 24 小时余量。
# 用 openssl 的 -checkend 而不是自己解析日期: 后者要处理时区/格式, 而
# 判断反了的后果是"过期证书被当成好的", 客户端握手全挂且看不出原因。
x_cert_not_expired() { # <crt>
    [[ -f "${1:-}" ]] || return 1
    openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1
}

# 自签证书 —— 客户端用 pin (Xray 的 pinnedPeerCertSha256) 锁定。
#
# ★ 伪装域名不是随便取的: 自签证书会**明文写在握手**里发给客户端,
#   用 `localhost` / `example.com` 这种一眼假的 CN, 等于主动暴露。
#   借用 Reality 的随机大站域名 (取不到才退回随机串)。
#
# ★ 有效期 200 天: 与 SB 一致。自签没有续期流程, 太长会让"过期"变成
#   一颗定时炸弹; 太短又会频繁重建。
# 伪装域名 —— 优先用项目**自己已经在维护**的那个。
# install_info.env 里的 dest_server 是 Reality 一直在用的伪装备选域名
# (由 domains.sh 维护并持久化)。自签证书借它, 与 Reality 档口径一致,
# 也不会凭空造一个谁都没验证过能握手的域名。
# 取不到才退回随机串 —— 那只是"不像 example.com 那么一眼假"的兜底。
x_cert_camo_domain() {
    local f="${XRAY_BASE:-/root/catmi/xray}/install_info.env" d=""
    if [[ -r "$f" ]]; then
        d=$(sed -n 's/^dest_server=["'"'"']*\?\([^"'"'"']*\)["'"'"']*.*/\1/p' "$f" | tail -1)
        d="${d%%:*}"
    fi
    if [[ -z "$d" ]]; then
        d="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8).com"
    fi
    printf '%s' "$d"
}

x_cert_selfgen() { # [伪装域名] -> stdout "crt<TAB>key"
    local dir="${XRAY_CERT_DIR:-${XRAY_BASE:-/root/catmi/xray}/certs}"
    mkdir -p "$dir" 2>/dev/null || return 1
    local d="${1:-}"
    [[ -z "$d" ]] && d=$(x_cert_camo_domain)
    local crt="$dir/self-$d.crt" key="$dir/self-$d.key"
    # EC P-256: 比 RSA 快得多 (握手 CPU), 且体积小。Xray 与客户端都支持。
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$key" -out "$crt" -days 200 \
        -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
    [[ -s "$crt" && -s "$key" ]] || return 1
    printf '%s\t%s' "$crt" "$key"
}

# 列出证书 —— **按域名去重**。
#
# ★ 同一张证书在磁盘上常有两份 (acme.sh 的 certs/x.pem 与 letsencrypt 的
#   live/x/fullchain.pem), 按路径列会把它们都列出来, 用户看着像两张、
#   编号也对不上号。SB 为这个专门写了 sb_dedup_certs_by_domain。
# 输出: 每行 "域名<TAB>crt<TAB>key<TAB>标记"
x_cert_list_domains() {
    local f dom key seen=" " mark
    while read -r f; do
        [[ -f "$f" ]] || continue
        dom=$(x_cert_domain "$f" 2>/dev/null)
        [[ -n "$dom" ]] || dom="未知域名"
        case "$seen" in *" $dom "*) continue ;; esac
        seen="$seen$dom "
        key=$(x_cert_key_for "$f") || key=""
        mark=""
        [[ -z "$key" ]] && mark="缺私钥"
        [[ -n "$key" ]] && { x_cert_not_expired "$f" || mark="已过期"; }
        [[ -z "$mark" ]] && { x_cert_trusted "$f" || mark="自签"; }
        printf '%s\t%s\t%s\t%s\n' "$dom" "$f" "$key" "$mark"
    done < <(x_cert_list)
}


# 列出容器化的 nginx 正在用的证书 —— 宿主页面上看不到的那一批。
x_cert_container_certs() {
    command -v docker >/dev/null 2>&1 || return 1
    local cid found=0
    for cid in $(timeout 5 docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx); do
        # 容器里 nginx 配置引用的证书路径
        local refs
        refs=$(timeout 5 docker exec "$cid" sh -c \
            'cat /etc/nginx/conf.d/*.conf /etc/nginx/nginx.conf 2>/dev/null' 2>/dev/null \
            | grep -oE 'ssl_certificate(_key)?[[:space:]]+[^;]+' | awk '{print $2}')
        while read -r r; do
            [[ -n "$r" ]] || continue
            # 私钥排除。nginx 的证书链常见 xxx.crt + xxx.crt.key 两件套,
            # 只挡 *_key.pem / *key*.pem 会漏掉 .key 后缀, 于是私钥被当成
            # "待续期证书"列给用户 —— 续期脚本对着一把私钥申请续期。
            [[ "$r" == *_key.pem || "$r" == *key*.pem || "$r" == *.key ]] && continue
            printf '%s  (容器 %s)\n' "$r" "$cid"
            found=1
        done <<< "$refs"
    done
    [[ "$found" == "1" ]]
}

# ================================================================
# 项目证书目录 (/root/catmi/certs) —— 与 KPanel 的 /home/web/certs 解耦
#
# 为什么要有这个目录:
#
#   KPanel 的 /root/auto_cert_renewal.sh (cron, 每天午夜) 会在续签时
#   **先删** letsencrypt lineage, 再重新签发, 最后才 cp 回
#   /home/web/certs/。三步里任何一步失败, 磁盘上的 *_cert.pem 就没了。
#
#   实测踩过: 2026-10-08 那次续签没走完, /home/web/certs 只剩 *_key.pem,
#   私钥在、证书没了。而 nginx 因为已经把证书加载进内存, 网站照常能开,
#   直到重启才会暴露 —— 静默故障, 极难发现。
#
#   当时 sing-box 7 个配置 + Xray 5 个片段全部引用这个路径, 内核直接
#   起不来。mihomo 没事, 因为它用的是 /root/catmi/mihomo/conf/certs/。
#
# 所以: 证书从 letsencrypt 复制一份到本项目目录, 配置只引用本项目目录。
# KPanel 那边被删、被改、被续签, 都不影响我们。
#
# 实测验证 (RN, 2026-10-08): 把 /home/web/certs/*_cert.pem 全部移走,
# sing-box check / xray run -test / mihomo -t 三个全部通过。
# ================================================================
x_cert_project_dir() {
    echo "${X_CERT_DIR:-/root/catmi/certs}"
}

# 从 letsencrypt lineage 同步证书到项目目录。
#
# 只在源文件更新时才复制 —— 靠 mtime 比较, 不看内容, 免得每次都重写
# 导致 mihomo/nginx 认为证书变了而 reload。
#
# 返回 0 = 至少同步了一张; 返回 1 = 没有可同步的源。
x_cert_sync() {
    local src="${1:-/etc/letsencrypt/live}"
    local dst; dst="$(x_cert_project_dir)"
    local copied=0 n f s

    [[ -d "$src" ]] || return 1
    mkdir -p "$dst" || return 1

    for d in "$src"/*/; do
        [[ -d "$d" ]] || continue
        n=$(basename "$d")
        [[ "$n" == "README" ]] && continue
        s="$d/fullchain.pem"
        [[ -f "$s" ]] || continue

        f="$dst/${n}_cert.pem"
        if [[ ! -f "$f" || "$s" -nt "$f" ]]; then
            cp "$s" "$f" || continue
            cp "$d/privkey.pem" "$dst/${n}_key.pem" 2>/dev/null || true
            chmod 600 "$dst/${n}_key.pem" 2>/dev/null || true
            echo "    同步: ${n}_cert.pem"
            copied=1
        fi
    done

    [[ "$copied" == "1" ]]
}

# ★ 兜底: 片段引用的证书不见了, 先试着从 letsencrypt 拉回来, 再报错。
#
# 为什么要有这道: 证书丢失的故障形态太安静了 ——
#   · nginx 已经把证书读进内存, 网站照常能开;
#   · xray 服务还活着 (启动时证书还在);
#   · 只有**重启**才炸, 而报错是一大串 infra/conf 栈, 没人看得出是证书没了。
#   10-08 和这次 10-12 都是这样。所以不能等到内核报错才发现, 得在
#   **校验配置之前**自己先查一遍。
#
# 用法: x_cert_ensure <配置文件...>  [letsencrypt源目录]  → 返回 0 = 全都齐了
#
# 第二个参数是给测试/别的 CA 布局用的 —— 写死 /etc/letsencrypt/live 的话,
# 在用 acme.sh 或别的目录的机器上补不回来, 而且测试根本没法隔离
# (我第一版就踩了: 场景三想模拟"证书彻底没了", 结果它从真的
# /etc/letsencrypt/live 里又捞回来一张, 场景直接测废了)。
x_cert_ensure() {
    local dir proj f want base restored=0 missing=0
    local le_src="${2:-/etc/letsencrypt/live}"
    proj="$(x_cert_project_dir)"

    # 先照常同步一次 (多数"丢失"其实是没同步, 这一步就好了)
    x_cert_sync "$le_src" >/dev/null 2>&1 || true

    for dir in "$@"; do
        [[ -f "$dir" ]] || continue
        # 把片段里所有 *_cert.pem 引用挖出来
        while IFS= read -r f; do
            want=$(clean_cert_path "$f")
            [[ -f "$want" ]] && continue
            base=$(basename "$want")
            base=${base%_cert.pem}
            # 缺的是证书还是私钥, 两种都试
            if [[ -f "$proj/${base}_cert.pem" && -f "$proj/${base}_key.pem" ]]; then
                if [[ ! -f "$want" ]] || ! cmp -s "$proj/${base}_cert.pem" "$want"; then
                    cp -f "$proj/${base}_cert.pem" "$want" 2>/dev/null && \
                    { restored=$((restored+1)); continue; }
                fi
            fi
            # 直接从 letsencrypt 恢复
            if [[ -f "${le_src}/${base}/fullchain.pem" ]]; then
                if cp -f "${le_src}/${base}/fullchain.pem" "$want" 2>/dev/null; then
                    print_info "证书已从 letsencrypt 恢复: $base"
                    restored=$((restored+1)); continue
                fi
            fi
            missing=$((missing+1))
            print_error "证书缺失且无法恢复: $want"
            print_error "  这个片段引用的证书不在磁盘上, 内核重启时会起不来。"
            print_error "  重新签发: 菜单 5) 证书管理 → 申请/续期; 或手动"
            print_error "  cp /etc/letsencrypt/live/<域名>/fullchain.pem $want"
        done < <(grep -ohE '[A-Za-z0-9_./-]*_cert\.pem|[A-Za-z0-9_./-]*cert-[A-Za-z0-9.-]+\.crt' "$dir" 2>/dev/null | sort -u)
    done
    [[ "$missing" -eq 0 ]]
}

# ★ 迁移: 把已有片段里指向"别人家目录"的证书路径改到项目目录
#
#   为什么必须迁: x_cert_ensure 只能在**文件确实不见了**的时候救。
#   而现在生产里的片段写的是 /home/web/certs/... —— 那个目录归 KPanel 管,
#   它的续签脚本先删后签, 中途失败磁盘上就只剩私钥。只要还指着那个目录,
#   我们就永远处在"等它被删"的状态里, 救火只是最后一道。
#
#   迁完之后的差别: 别人续签/删文件 → 我们无感; 我们自己的续签走
#   x_cert_sync, 有 let's encrypt 做底, 而且改动只在自己目录里。
#
#   用法: x_cert_migrate <片段...>  → 返回 0 = 没有需要迁的 (或全迁完)
x_cert_migrate() {
    local f proj from to n_changed=0 n_skip=0
    proj="$(x_cert_project_dir)"
    mkdir -p "$proj"

    # 候选来源目录: 这些都是"不归我们管"的目录
    local -a foreign=(
        /home/web/certs
        /etc/nginx/certs /etc/nginx/ssl
        /etc/letsencrypt/live
        /root/catmi/cloudflare/certs /root/.acme.sh
    )

    for f in "$@"; do
        [[ -f "$f" ]] || continue
        for from in "${foreign[@]}"; do
            [[ -d "$from" ]] || continue
            to="$proj"
            # 逐个域名找对应的 fullchain / *.crt
            while IFS= read -r path; do
                base=$(basename "$path")
                base=${base%_cert.pem}; base=${base%_key.pem}
                # cert-*.<domain>.crt 这种 nginx 命名
                base=${base#cert-}; base=${base%.crt}; base=${base%.pem}
                [[ -z "$base" ]] && continue
                srcc=""
                [[ -f "$from/${base}_cert.pem" ]] && srcc="$from/${base}_cert.pem"
                [[ -z "$srcc" && -f "$from/${base}.crt" ]] && srcc="$from/${base}.crt"
                [[ -z "$srcc" && -f "$from/$base/fullchain.pem" ]] && srcc="$from/$base/fullchain.pem"
                [[ -z "$srcc" ]] && continue
                # 先落到项目目录, 再改引用
                cp -f "$srcc" "$proj/${base}_cert.pem" 2>/dev/null || continue
                [[ -f "$from/${base}_key.pem" ]] && cp -f "$from/${base}_key.pem" "$proj/${base}_key.pem" 2>/dev/null
                chmod 600 "$proj/${base}_key.pem" 2>/dev/null
            done < <(grep -ohE "${from}/[A-Za-z0-9_./-]+\.pem" "$f" 2>/dev/null | sort -u)

            if grep -q "$from" "$f" 2>/dev/null; then
                cp -p "$f" "$f.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null
                sed -i "s#${from}/#${proj}/#g" "$f" 2>/dev/null && n_changed=$((n_changed+1)) \
                    || n_skip=$((n_skip+1))
            fi
        done
    done
    [[ "$n_changed" -gt 0 ]] && printf '  已迁移 %s 个片段的证书路径 → %s\n' "$n_changed" "$proj" >&2
    [[ "$n_skip" -eq 0 ]]
}

# 从 JSON 里取出的证书路径去掉引号和逗号尾巴
clean_cert_path() {
    printf '%s' "${1//[\",]}"
}

# 项目目录里某张证书是否可用。
# 不只看文件在不在 —— 从 letsencrypt 同步过来的可能已经过期, 而内核
# 不检查有效期, 只会在握手时把客户端拒掉。
x_cert_project_ok() {
    local name="$1" dir f
    dir="$(x_cert_project_dir)"
    f="$dir/${name}_cert.pem"
    [[ -f "$f" ]] || return 1
    openssl x509 -in "$f" -noout -checkend $((30*86400)) >/dev/null 2>&1
}
