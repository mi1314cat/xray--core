#!/bin/bash

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
RESET="\e[0m"

# ================================
# 打印函数（全部输出到 stderr）
# ================================
print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET}  %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-42s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ================================
# 基础变量
# ================================
PROTO="hysteria"
BASE_DIR="${XRAY_BASE_DIR:-/root/catmi/xray}"
CONF_DIR="$BASE_DIR/conf"
OUT_DIR="$BASE_DIR/out"
mkdir -p "$CONF_DIR" "$OUT_DIR"

# 自签证书专用目录（仅有自签时写入，外部证书不复制）
CERT_DIR="$BASE_DIR/Hysteria2"
mkdir -p "$CERT_DIR"

# 全局变量: 空 = 未选择
CERT_MODE=""
CERT_FILE=""
KEY_FILE=""
CERT_DOMAIN=""
CERT_TRUSTED=false   # true = CA可信真证书, false = 自签

# 自签证书域名候选（fallback 时用）
SIGN_DOMAINS=("cloudflare.com" "bing.com" "addons.mozilla.org")

# ================================
# 输入清理
# ================================
clean_input() {
    echo "$1" | tr -d '\000-\037'
}

# ================================
# 安全输入（不会污染 JSON）
# ================================
safe_read() {
    local prompt="$1"
    local default="$2"
    local input

    if [[ "${X_BATCH:-0}" == "1" ]]; then
        print_info "Batch 模式: ${prompt} = ${default}"
        echo "$default"
        return
    fi

    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

# ================================
# 随机生成工具
# ================================
random_domain() {
    local total=${#SIGN_DOMAINS[@]}
    echo "${SIGN_DOMAINS[$((RANDOM % total))]}"
}
# 端口分配: 统一从 conf/lib/ports.sh 取, 本脚本不再自带副本。
# 副本时代改一处漏一处 —— 批量区间分配只进了 4 个脚本, 另外 5 个的批量
# 生成仍在用随机端口, 同一批节点端口散落在 10000-60000。
_x_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -r "$_x_lib_dir/lib/ports.sh" ]]; then
    source "$_x_lib_dir/lib/ports.sh"
else
    source <(curl -fsSL "https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/lib/ports.sh") \
        || { print_error "端口库加载失败"; exit 1; }
fi
# ================================
# 自动修复 uuidgen 缺失
# ================================
ensure_uuidgen() {
    if ! command -v uuidgen >/dev/null 2>&1; then
        print_info "uuidgen 未安装，正在自动安装..."
        apt update -y >/dev/null 2>&1
        apt install uuid-runtime -y >/dev/null 2>&1
        print_ok "uuidgen 安装完成"
    fi
}

# ================================
# IP 检测
# ================================
detect_listen_ip() {
    local has_ipv4=false
    local has_ipv6=false

    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true

    if $has_ipv4 && ! $has_ipv6; then echo "ipv4"
    elif ! $has_ipv4 && $has_ipv6; then echo "ipv6"
    elif $has_ipv4 && $has_ipv6; then echo "dual"
    else echo "none"
    fi
}

safe_read_port() {
    local default="$1"
    local input

    if [[ "${X_BATCH:-0}" == "1" ]]; then
        default=$(batch_alloc_port)
        if [[ -z "$default" ]]; then
            print_error "批量端口范围 $X_BATCH_PORT_START-$X_BATCH_PORT_END 已耗尽，回退随机空闲端口"
            default=$(random_free_port)
        fi
        print_info "Batch 模式: 自动分配端口 = $default"
        echo "$default"
        return
    fi

    while true; do
        printf "请输入本地监听端口 (默认: %s): " "$default" >&2
        read input
        input=$(clean_input "$input")
        port="${input:-$default}"

        [[ "$port" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字"; continue; }
        (( port >= 1 && port <= 65535 )) || { print_error "端口范围错误"; continue; }
        port_in_use "$port" && { print_error "端口已占用"; continue; }

        echo "$port"
        return
    done
}

# ================================
# 监听地址选择
# ================================
choose_listen_ip() {
    local detect="$1"

    print_info "自动检测结果："
    [[ "$detect" == "ipv4" ]] && echo "  - 检测到 IPv4" >&2
    [[ "$detect" == "ipv6" ]] && echo "  - 检测到 IPv6" >&2
    [[ "$detect" == "dual" ]] && echo "  - 检测到 IPv4 + IPv6" >&2
    [[ "$detect" == "none" ]] && echo "  - 未检测到公网 IP" >&2

    echo >&2
    echo "请选择监听地址：" >&2
    echo "1) IPv4 (0.0.0.0)" >&2
    echo "2) IPv6 (::)" >&2
    echo "3) 自动推荐" >&2

    printf "选择 (默认 1): " >&2
    read choice
    choice=$(clean_input "$choice")

    case "$choice" in
        2) echo "::" ;;
        3)
            case "$detect" in
                ipv4) echo "0.0.0.0" ;;
                ipv6) echo "::" ;;
                dual) echo "0.0.0.0" ;;
                none) echo "0.0.0.0" ;;
            esac
            ;;
        *) echo "0.0.0.0" ;;
    esac
}

# ================================
# 从证书中提取域名（借鉴 vlessxhttpecn.sh extract_cert_domain）
# 三级回退: SAN 第一个 DNS → subject CN → 文件名
# ================================
# 证书校验公共库: x_cert_domain / x_cert_check
_x_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -r "$_x_lib_dir/lib/cert.sh" ]]; then
    source "$_x_lib_dir/lib/cert.sh"
else
    source <(curl -fsSL "https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/lib/cert.sh") \
        || { print_error "证书库加载失败"; exit 1; }
fi

# 对外地址探测库 (单一实现) —— 本地优先, 否则从仓库取。
# 见 conf/lib/addr.sh 顶部: 为什么不能问外部"我的 IP"、为什么要排除隧道网卡。
if [[ -r "$_x_lib_dir/lib/addr.sh" ]]; then
    source "$_x_lib_dir/lib/addr.sh"
else
    source <(curl -fsSL "https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/lib/addr.sh") \
        || { print_error "地址库加载失败"; exit 1; }
fi

extract_cert_domain() {
    local crt="$1"
    if [[ -z "$crt" ]]; then echo ""; return 0; fi
    x_cert_domain "$crt"
}

# 证书有效期检查: 未过期返回 0
cert_not_expired() {
    [[ -f "$1" ]] || return 1
    openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1
}

# key 配对: 给定 crt 尽力找到对应 key
# 证书与私钥是不是**真的**一对 —— 比公钥, 不比文件名。
_cert_key_match() {
    local crt="$1" key="$2" a b
    [[ -f "$crt" && -f "$key" ]] || return 1
    a=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
    b=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null)
    [[ -n "$a" && -n "$b" && "$a" == "$b" ]]
}

# ★ 名字对得上**不等于**真是一对。
#
#   原来这里只按命名约定取 key, 一次都不验证: 目录里有多张证书、或者换过
#   证书但旧的 .key 还留着时, 取到的是**别人的私钥**。配置照样"生成成功",
#   服务端监听也起得来, 只有握手时才炸 —— 而报错 (bad decrypt / key values
#   mismatch) 离真正原因很远, 面板这边一切正常。
#   实测过的同类现场: 5 张证书按名字配到 0 对, 于是静默退化成"用第一把 key"。
#
#   现在逐个候选**验配对**, 全都不配对就返回空 —— 让调用方按"没有可用证书"
#   处理, 而不是拿着一对错的往下走。
find_key_for_cert() {
    local crt="$1" k
    local -a cands=(
        "${crt%.crt}.key"
        "${crt%.pem}.key"
        "${crt%_cert.pem}_key.pem"
        "$(dirname "$crt")/server.key"
    )
    for k in "${cands[@]}"; do
        [[ -f "$k" ]] || continue
        if _cert_key_match "$crt" "$k"; then echo "$k"; return; fi
    done
    # acme.sh 目录: domain.crt 同目录 <domain>.key 由调用方处理
    echo ""
}

# ================================
# 证书扫描（借鉴 vlessxhttpecn.sh ask_cert 默认分支）
# 输出到 FOUND_CERTS 数组: "crt_path|key_path|来源"
# ================================
scan_certs() {
    FOUND_CERTS=()
    local f k dir
    shopt -s nullglob
    local -a search_dirs=()
    local -a labels=()

    # 1) catmi 证书目录 + 根目录
    if [[ -d /root/catmi/cloudflare/certs ]]; then
        search_dirs+=(/root/catmi/cloudflare/certs); labels+=(catmi/cloudflare-certs)
    fi
    search_dirs+=(/root/catmi); labels+=(catmi-root)

    # 2) v2ray-agent TLS 目录
    if [[ -d /etc/v2ray-agent/tls ]]; then
        search_dirs+=(/etc/v2ray-agent/tls); labels+=(v2ray-agent)
    fi

    # 3) acme.sh 默认证书目录
    if [[ -d /root/.acme.sh ]]; then
        search_dirs+=(/root/.acme.sh); labels+=(acme.sh)
    fi

    # 4) 宿主机 nginx
    [[ -d /etc/nginx/certs ]] && search_dirs+=(/etc/nginx/certs) && labels+=(nginx-certs)
    if [[ -d /etc/nginx/ssl ]]; then
        search_dirs+=(/etc/nginx/ssl); labels+=(nginx-ssl)
    fi

    # nginx 容器规范目录 (web/certs 布局: *o_cert.pem + *_key.pem)
    if [[ -d /home/web/certs ]]; then
        search_dirs+=(/home/web/certs); labels+=(web-certs)
    fi

    # 5) Docker nginx 容器挂载的证书源目录
    if command -v docker >/dev/null 2>&1; then
        local cid src
        cid=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx | head -1)
        if [[ -n "$cid" ]]; then
            src=$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/certs"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
            [[ -z "$src" && -d /etc/nginx/certs ]] && src="/etc/nginx/certs"
            if [[ -n "$src" && -d "$src" ]]; then
                search_dirs+=("$src"); labels+=("docker-nginx($cid)")
            fi
        fi
    fi

    # 扫描并配对，去重
    local seen_crt=()
    local d i
    for ((i=0; i<${#search_dirs[@]}; i++)); do
        d="${search_dirs[$i]}"
        for f in "$d"/*.pem "$d"/*.crt; do
            [[ -f "$f" ]] || continue
            # 跳过明显是 key 的文件
            [[ "$f" == *key*.pem || "$f" == *_key.pem ]] && continue

            # 跳过 acme.sh 文件名中不含域名的辅助文件
            case "$(basename "$f")" in
                ca.cer|fullchain.cer|*.issuer.cer|chain.cer|key.pem) continue ;;
            esac

            # 去重：同一路径只收录一次
            local dup=false
            for seen_crt in "${SEEN_CERTS[@]:-}"; do
                [[ "$seen_crt" == "$f" ]] && dup=true && break
            done
            if $dup; then continue; fi
            SEEN_CERTS+=("$f")

            # 排除 CA 证书 (有 certificate 属性而非叶子证书且主题与签发者相同)
            if openssl x509 -in "$f" -noout -text 2>/dev/null | grep -q "CA:TRUE"; then
                continue
            fi

            k=$(find_key_for_cert "$f")
            FOUND_CERTS+=("$f|$k|${labels[$i]}")
        done
    done
    shopt -u nullglob
    return 0
}

# ================================
# 生成自签证书（ECDSA P-256，10 年）
# 输出: CERT_FILE, KEY_FILE, CERT_DOMAIN, CERT_TRUSTED=false
# ================================
# 校验用户手填的证书对, 通过则设好 CERT_DOMAIN / CERT_TRUSTED。
#
# ★ 以前这里只判断 `[[ -f crt && -f key ]]` —— 文件存在就算通过, 然后把
#   CERT_TRUSTED 置 true。三个后果, 全是"配置全对但连不上":
#     1. crt 与 key **不配对**也照用 (握手失败, 而且报错离原因很远)
#     2. 内容根本不是 PEM (下到了 HTML 错误页) 也照用
#     3. **自签证书被当成 CA 可信真证书** —— 客户端于是做正常校验, 必然失败;
#        反过来真证书被当成自签, 客户端带着错误的钉扎去连, 同样失败
#   现在走公共校验库 x_cert_check (PEM 可解析 / 私钥可解析 / 未过期 /
#   **配对正确** / 域名对得上) + x_cert_trusted (实测信任, 不靠猜)。
use_manual_cert() {
    if ! x_cert_check "$CERT_FILE" "$KEY_FILE" "${CERT_DOMAIN:-}"; then
        print_error "证书校验不通过 (原因见上), 退回自签"
        return 1
    fi
    CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE")
    if x_cert_trusted "$CERT_FILE"; then
        CERT_TRUSTED=true
    else
        CERT_TRUSTED=false
    fi
    print_ok "使用证书: $CERT_DOMAIN ($([[ "$CERT_TRUSTED" == true ]] && echo CA可信真证书 || echo 自签) crt=$CERT_FILE key=$KEY_FILE)"
    return 0
}

generate_cert() {
    local dom
    dom=$(safe_read "自签证书域名(伪装域名)" "$(random_domain)")
    domain=$(clean_input "$dom")
    [[ -z "$domain" ]] && domain=$(random_domain)

    CERT_FILE="$CERT_DIR/cert-$domain.crt"
    KEY_FILE="$CERT_DIR/key-$domain.key"

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_ok "已有自签证书: $domain"
        CERT_TRUSTED=false
        return 0
    fi

    print_info "生成自签证书 (ECDSA P-256, 10年): $domain"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve -nodes \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
        -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        CERT_TRUSTED=false
        print_ok "自签证书生成成功: $domain"
        return 0
    fi
    print_error "自签证书生成失败"
    exit 1
}

# ================================
# 证书选择主入口（借鉴 vlessxhttpecn.sh ask_cert）
# 两个方案: 真证书 (ACME/nginx/文件系统) 或 自签
# 输出: CERT_FILE, KEY_FILE, CERT_DOMAIN, CERT_TRUSTED
# ================================
ask_cert() {
    local choice f k lbl dom pair

    echo "  证书方案：" >&2
    echo "  1) 扫描本机已有证书 (ACME/nginx/CF Origin CA, CA可信)" >&2
    echo "  2) 手动输入证书路径" >&2
    echo "  3) 生成自签证书 (无需域名)" >&2
    printf "  选择 (默认1): " >&2
    read -r choice
    choice=$(clean_input "$choice")

    case "$choice" in
        2)
            printf "  证书 crt 路径: " >&2; read -r f
            CERT_FILE=$(clean_input "$f")
            printf "  证书 key 路径: " >&2; read -r f
            KEY_FILE=$(clean_input "$f")
            if use_manual_cert; then return 0; fi
            generate_cert
            return 0
            ;;
        3)
            generate_cert
            return 0
            ;;
    esac

    # 默认分支: 自动扫描
    SEEN_CERTS=()
    scan_certs

    if ((${#FOUND_CERTS[@]} > 0)); then
        echo "  检测到已有证书:" >&2
        local i=1 default_choice=""
        local usable=()
        for pair in "${FOUND_CERTS[@]}"; do
            f="${pair%%|*}"; k="${pair#*|}"; k="${k%%|*}"; lbl="${pair##*|}"
            if [[ -n "$k" && -f "$k" ]] && cert_not_expired "$f"; then
                echo "    $i) $(extract_cert_domain "$f") (有密钥, 来源: $lbl)" >&2
                [[ -z "$default_choice" ]] && default_choice="$i"
                usable+=("$i|${f%%|*}|$k")
            else
                echo "    $i) $(extract_cert_domain "$f") (无密钥或已过期, 忽略)" >&2
            fi
            ((i++))
        done
        echo "    $i) 手动输入路径" >&2
        echo "    $((i+1))) 生成自签证书" >&2
        printf "  选择 (默认 ${default_choice:-自签}): " >&2
        read -r choice
        choice=$(clean_input "$choice")

        # 回车或无效 → 默认第一个可用
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
            :
        elif [[ -n "$default_choice" ]]; then
            choice="$default_choice"
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
            for pair in "${usable[@]}"; do
                if [[ "${pair%%|*}" == "$choice" ]]; then
                    CERT_FILE="${pair#*|}"; CERT_FILE="${CERT_FILE%%|*}"
                    KEY_FILE="${pair##*|}"
                    CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE")
                    # ★ 这里原来无条件写 CERT_TRUSTED=true —— 但扫描目录里
                    #   **包含项目自己的自签证书目录** (/root/catmi/xray/certs),
                    #   而 scan_certs 只排除 CA 包、不排除自签叶子证书。
                    #   选中一张自签 => 被当成"CA 可信真证书" => 客户端做正常
                    #   校验 => 必然连不上。信任必须实测。
                    if x_cert_trusted "$CERT_FILE"; then
                        CERT_TRUSTED=true
                    else
                        CERT_TRUSTED=false
                        print_warn "这张是自签证书, 客户端将使用证书钉扎 (不是 CA 校验)"
                    fi
                    print_ok "使用证书: $CERT_DOMAIN (crt=$CERT_FILE key=$KEY_FILE)"
                    return 0
                fi
            done
        fi

        # 手动路径
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice == i )); then
            printf "  证书 crt 路径: " >&2; read -r f
            CERT_FILE=$(clean_input "$f")
            printf "  证书 key 路径: " >&2; read -r f
            KEY_FILE=$(clean_input "$f")
            if use_manual_cert; then return 0; fi
            generate_cert
            return 0
        fi
        # 自签或未知选择
        generate_cert
        return 0
    fi

    print_warn "未扫描到任何可用证书"
    generate_cert
    return 0
}

# ================================
# 获取下一个编号（01、02、03…）
# ================================
get_next_index() {
    local used=() i=1
    shopt -s nullglob
    for f in "$CONF_DIR"/${PROTO}-*.json; do
        local base
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
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done
    printf "%02d\n" "$i"
}

# ================================
# 端口跳跃（借鉴 v2ray-agent addPortHopping, iptables 实现）
# 默认不开启
# 输出: HOP_RANGE (如 30000-31000), 空字符串 = 不启用
# ================================
ask_port_hopping() {
    HOP_RANGE=""
    local yn range start end

    printf "是否开启 UDP 端口跳跃? (默认: 否, y/N): " >&2
    read -r yn
    case "$(clean_input "$yn")" in
        y|Y) ;;
        *) return 0 ;;
    esac

    # 防呆: 收集本机所有已监听 UDP 端口
    local used_ports
    used_ports=$(ss -ulHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)

    while true; do
        printf "跳跃范围 (默认: 30000-31000): " >&2
        if ! read -r range; then echo >&2; return 1; fi   # EOF 退出
        range=$(clean_input "$range")
        [[ -z "$range" ]] && range="30000-31000"

        # ---- 防呆 1: 格式 ----
        if ! echo "$range" | grep -qE '^[0-9]+-[0-9]+$'; then
            print_error "范围格式应为 起始-结束, 例如 30000-31000, 请重新输入"
            continue
        fi
        start="${range%-*}"; end="${range#*-}"

        # ---- 防呆 2: 数值合法性 (避开系统端口 <1024) ----
        (( start >= 1024 && start <= end && end <= 65535 )) || {
            print_error "范围不合法: $range (要求 1024 ≤ 起始 ≤ 结束 ≤ 65535)"
            continue
        }

        # ---- 防呆 3: 跨度提示 ----
        (( end - start > 10000 )) && \
            print_warn "跨度 $((end-start)) 个端口偏大, 建议缩小到 1-2 千 (防火墙规则性能)"

        # ---- 防呆 4: 冲突检测 (范围内端口已被本机 UDP 服务监听) ----
        local conflicts
        conflicts=$(seq "$start" "$end" | grep -xF -f <(echo "$used_ports") | head -5 | paste -sd' ')
        if [[ -n "$conflicts" ]]; then
            print_error "范围 $range 与已监听 UDP 服务冲突: $conflicts"
            print_warn "请换一段范围 (冲突端口不会重定向, 尝试继续会完全丢包)"
            continue
        fi

        # ---- 防呆 5: 已存在相同的跳跃规则 ----
        if iptables -t nat -S PREROUTING 2>/dev/null | grep -q "dport $start:$end"; then
            print_error "PREROUTING 已存在 $start:$end 的 REDIRECT 规则 (重复添加会覆盖)"
            print_warn "请先模拟: iptables -t nat -D PREROUTING ... (或换范围)"
            continue
        fi

        # ---- 防呆 6: 包含本配置自身端口 (REDIRECT 到自身, 无实际意义) ----
        if (( start <= $1 && $1 <= end )); then
            print_warn "范围 $range 包含本配置端口 $1 (REDIRECT 回自身会空转)"
            continue
        fi

        break
    done

    HOP_RANGE="$range"

    # iptables DNAT: UDP 端口段 → 本配置端口
    if command -v iptables >/dev/null; then
        iptables -t nat -C PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$1" 2>/dev/null || \
            iptables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$1"
        # 本机出站回环方向也放行
        iptables -t nat -C OUTPUT -p udp --dport "$start:$end" -j REDIRECT --to-ports "$1" 2>/dev/null || \
            iptables -t nat -A OUTPUT -p udp --dport "$start:$end" -j REDIRECT --to-ports "$1"
        print_ok "iptables 端口跳跃规则已添加: $range (udp → $1)"
        print_warn "规则重启后不保留, 如需持久化请安装 iptables-persistent (netfilter-persistent save)"
    else
        print_error "未找到 iptables, 端口跳跃无法生效"
        HOP_RANGE=""
    fi
}

remove_port_hopping() {
    local range="$1" start end
    if [[ -z "$range" ]]; then return 0; fi
    start="${range%-*}"; end="${range#*-}"
    if command -v iptables >/dev/null; then
        iptables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$2" 2>/dev/null
        iptables -t nat -D OUTPUT -p udp --dport "$start:$end" -j REDIRECT --to-ports "$2" 2>/dev/null
        print_ok "端口跳跃规则已移除: $range"
    fi
}


add_config() {
    print_title "新增 Hysteria2 配置"

    ensure_uuidgen

    # 对外地址交给 addr.sh (单一实现)。
    #
    # ★ 原来这里自己拼了一套: 手写私网前缀过滤 + 问 ip.sb + 两者不一致时警告。
    #   三个都不够:
    #     · 过滤只认 172/10/192.168 —— **不排除隧道虚拟网卡**, 也不排除
    #       mihomo/Clash 的 fake-ip 段 198.18.0.0/15 (机器上跑着 TUN 时会挑中它)
    #     · 问 ip.sb 拿到的是**出站出口**; 套了 WARP 时必然与网卡 IP 不同,
    #       于是每次建节点都刷一条警告, 而结论本来就该用网卡 IP
    #     · 没有"这个地址真在本机接口上吗"的自检
    default_ip=$(x_public_addr "${XRAY_PUBLIC_IP:-}")
    server_ip=$(safe_read "服务器 IP" "$default_ip")
    [[ -z "$server_ip" ]] && { print_error "服务器 IP 不能为空"; return 1; }

    detect=$(detect_listen_ip)
    listen_ip=$(choose_listen_ip "$detect")
    default_port=$(random_free_port)
    hysteria_port=$(safe_read_port "$default_port")
    uuid=$(uuidgen | tr 'A-Z' 'a-z')

    # ---- 端口跳跃（默认不开启）----
    ask_port_hopping "$hysteria_port"

    # ---- 证书选择（真证书 or 自签）----
    ask_cert
    domain="$CERT_DOMAIN"

    # ---- 生成服务端 JSON（jq 校验后再写盘）----
    next=$(get_next_index)
    local index="$next"

    local srv_json
    srv_json=$(cat <<EOF
{
  "inbounds": [
    {
      "listen": "$listen_ip",
      "port": $hysteria_port,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [{ "auth": "$uuid" }]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [{ "certificateFile": "$CERT_FILE", "keyFile": "$KEY_FILE" }]
        }
      },
      "tag": "$PROTO-$index"
    }
  ]
}
EOF
)
    # 校验 JSON，坏配置直接拒绝落盘
    if ! echo "$srv_json" | jq -e . >/dev/null 2>&1; then
        print_error "JSON 校验失败，未写入"
        echo "$srv_json" >&2
        return 1
    fi
    echo "$srv_json" | jq . > "$CONF_DIR/$PROTO-$index.json"

    # ---- 计算证书指纹 ----
    cert_hex_pin=$(openssl x509 -in "$CERT_FILE" -outform der 2>/dev/null | sha256sum | awk '{print tolower($1)}')
    
    # ---- 生成分享链接（考虑 Xray 2026-06-01 移除 allowInsecure）----
    local link mport=""
    [[ -n "$HOP_RANGE" ]] && mport="mport=$HOP_RANGE&"
    if [[ "$CERT_TRUSTED" == "true" ]]; then
        # 真 CA 证书 → 正常校验，无 insecure
        link="hysteria2://$uuid@$server_ip:$hysteria_port?${mport}sni=$domain&insecure=0&alpn=h3&obfs=none&upmbps=50&downmbps=200#hysteria-$index"
    else
        # 自签 → 用 pin (hex, URI规范)，不再使用 insecure= 参数（兼容新Xray内核）
        link="hysteria2://$uuid@$server_ip:$hysteria_port?${mport}sni=$domain&alpn=h3&obfs=none&pin=$cert_hex_pin&upmbps=50&downmbps=200#hysteria-$index"
    fi

    # ---- Xray 客户端 JSON 片段 (pinnedPeerCertSha256 用 hex, v26.3.27 实测) ----
    local xray_client_file="$OUT_DIR/hy2_client-$index.xray.json"
    if [[ "$CERT_TRUSTED" == "true" ]]; then
        cat <<EOF > "$xray_client_file"
{
  "outbounds": [
    {
      "tag": "hy2-$index",
      "protocol": "hysteria",
      "settings": { "version": 2, "address": "$server_ip", "port": $hysteria_port },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": { "serverName": "$domain", "alpn": ["h3"] },
        "hysteriaSettings": { "version": 2, "auth": "$uuid", "up": "50mbps", "down": "200mbps" }
      }
    }
  ]
}
EOF
    else
        cat <<EOF > "$xray_client_file"
{
  "outbounds": [
    {
      "tag": "hy2-$index",
      "protocol": "hysteria",
      "settings": { "version": 2, "address": "$server_ip", "port": $hysteria_port },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$domain",
          "alpn": ["h3"],
          "pinnedPeerCertSha256": "$cert_hex_pin"
        },
        "hysteriaSettings": { "version": 2, "auth": "$uuid", "up": "50mbps", "down": "200mbps" }
      }
    }
  ]
}
EOF
    fi

    # ---- mihomo (Clash Meta) 客户端 YAML ----
    local MIHOMO_HOP_LINES=""
    [[ -n "$HOP_RANGE" ]] && MIHOMO_HOP_LINES="    ports: $HOP_RANGE"$'\n'"    hop-interval: 10"
    local mihomo_file="$OUT_DIR/hy2_client-$index.yaml"
    if [[ "$CERT_TRUSTED" == "true" ]]; then
        cat <<EOF > "$mihomo_file"
proxies:
  - name: Hysteria2-$index
    type: hysteria2
    server: $server_ip
    port: $hysteria_port
    up: "50 Mbps"
    down: "200 Mbps"
    password: $uuid
    sni: $domain
    alpn:
      - h3
$MIHOMO_HOP_LINES
EOF
    else
        # mihomo 自签场景用 fingerprint 锁定证书, 不再需要 skip-cert-verify
        cat <<EOF > "$mihomo_file"
proxies:
  - name: Hysteria2-$index
    type: hysteria2
    server: $server_ip
    port: $hysteria_port
    up: "50 Mbps"
    down: "200 Mbps"
    password: $uuid
    sni: $domain
    fingerprint: $cert_hex_pin
    alpn:
      - h3
$MIHOMO_HOP_LINES
EOF
    fi

    # ---- 持久化元数据 (端口跳跃范围等, 用于删除配置时清理) ----
    echo "{\"index\": \"$index\", \"hop_range\": \"$HOP_RANGE\", \"port\": $hysteria_port}" | jq . > "$OUT_DIR/hy2_meta-$index.json"

    # ---- 分享链接去重写入 ----
    grep -vF "$link" "$OUT_DIR/hysteria.txt" 2>/dev/null > "$OUT_DIR/hysteria.txt.tmp" || true
    mv "$OUT_DIR/hysteria.txt.tmp" "$OUT_DIR/hysteria.txt"
    echo "$link" >> "$OUT_DIR/hysteria.txt"
    echo "$link" > "$OUT_DIR/hy2_share-$index.txt"

    print_ok "配置生成成功"
    echo -e "编号: $index\n端口: $hysteria_port\nUUID: $uuid\n域名: $domain\n证书: $CERT_FILE $([[ "$CERT_TRUSTED" == "true" ]] && echo "CA可信真证书" || echo "自签")\n监听: $listen_ip\n服务端配置: $CONF_DIR/$PROTO-$index.json\nXray客户端片段: $xray_client_file\nmihomo客户端: $mihomo_file\n分享链接: $OUT_DIR/hy2_share-$index.txt" >&2
    echo "$link" >&2
}

# ================================
# 显示配置（读取持久化信息）
# ================================
list_configs() {
    print_title "Hysteria2 配置列表"

    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue

        num=$(basename "$f" .json | cut -d'-' -f2)
        port=$(jq -r '.inbounds[0].port' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].auth' "$f")
        cert=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$f")
        domain=$(extract_cert_domain "$cert")

        printf "${GREEN}%s${RESET}) 端口:${BLUE}%s${RESET}  UUID:${MAGENTA}%s${RESET}  域名:${YELLOW}%s${RESET}  证书:${CYAN}%s${RESET}\n" \
        "$num" "$port" "$uuid" "$domain" "$cert" >&2
    done
}

# ================================
# 删除配置（自签证书才删；外部证书只删配置不删证书）
# ================================
delete_config() {
    list_configs
    printf "输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    local pad
    pad=$(printf "%02d" "$num" 2>/dev/null)
    [[ -z "$pad" ]] && { print_error "编号必须是数字"; return 1; }

    local file="$CONF_DIR/$PROTO-$pad.json"

    if [[ -f "$file" ]]; then
        local cert
        cert=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$file")

        rm -f "$file"

        # 只删除本脚本生成的自签证书，不动外部证书
        if [[ "$cert" == "$CERT_DIR"/cert-* ]]; then
            local domain
            domain=$(extract_cert_domain "$cert")
            rm -f "$CERT_DIR/cert-$domain.crt" "$CERT_DIR/key-$domain.key"
            print_ok "已删除配置 $num（含自签证书）"
        else
            print_ok "已删除配置 $num（外部证书保留: $cert）"
        fi

        # 撤销端口跳跃规则
        if [[ -f "$OUT_DIR/hy2_meta-$pad.json" ]]; then
            local hop
            hop=$(jq -r '.hop_range // empty' "$OUT_DIR/hy2_meta-$pad.json")
            local p
            p=$(jq -r '.port // empty' "$OUT_DIR/hy2_meta-$pad.json")
            remove_port_hopping "$hop" "$p"
        fi

        # 同步删除客户端产物
        rm -f "$OUT_DIR/hy2_client-$pad.yaml" "$OUT_DIR/hy2_client-$pad.xray.json" "$OUT_DIR/hy2_share-$pad.txt" "$OUT_DIR/hy2_meta-$pad.json"
    else
        print_error "编号不存在"
    fi
}

# ================================
# 主菜单（增加防火墙放行 UDP）
# ================================
open_udp_port() {
    local port="$1"
    local opened_any=true
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port/udp" >/dev/null 2>&1 || opened_any=false
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        firewall-cmd --zone=public --add-port="$port/udp" --permanent >/dev/null 2>&1 || opened_any=false
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null; then
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    fi
    local output
    if $opened_any; then
        print_ok "UDP 端口 $port 已放行"
    else
        print_warn "未检测到防火墙插件，请手动放行 UDP 端口 $port"
    fi
}

main_menu() {
    while true; do
        print_title "Hysteria2 管理面板"

        echo "1) 查看配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        if ! read -r c; then echo >&2; exit 0; fi   # EOF(管道结束/Ctrl-D)时退出
        c=$(clean_input "$c")

        case $c in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac

        printf "按回车继续..." >&2
        read
    done
}

# 直跑入口: add = 由 Batch Generator (conf/batch.sh) 无交互调用 add_config;
# 不带参数 = 原有交互菜单 (单协议行为不变)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == "add" ]]; then
        add_config
    else
        main_menu
    fi
fi
