#!/usr/bin/env bash

# 颜色输出
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

print_warn() {
    echo -e "${YELLOW}[Warn]${PLAIN} $1"
}

INSTALL_DIR="/root/catmi/xray"
ENV_FILE="$INSTALL_DIR/install_info.env"
xrayls_DTR="$INSTALL_DIR/xrayls"

update_env() {
    local key="$1"
    local value="$2"

    # 校验 key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        print_error "Invalid key: $key"
        return 1
    }

    # 确保目录 & 文件
    mkdir -p "$(dirname "$ENV_FILE")"
    [ -f "$ENV_FILE" ] || touch "$ENV_FILE"

    # 获取权限 & 属主（兼容 Linux / BSD）
    local mode owner group
    if mode=$(stat -c "%a" "$ENV_FILE" 2>/dev/null); then
        owner=$(stat -c "%u" "$ENV_FILE")
        group=$(stat -c "%g" "$ENV_FILE")
    else
        mode=$(stat -f "%Lp" "$ENV_FILE")
        owner=$(stat -f "%u" "$ENV_FILE")
        group=$(stat -f "%g" "$ENV_FILE")
    fi

    # 转义 value
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"

    # 加锁 + 自动释放
    (
        flock 200

        local tmp_file
        tmp_file=$(mktemp "$(dirname "$ENV_FILE")/.env.tmp.XXXXXX")

        # 先设置权限
        chmod "$mode" "$tmp_file"
        chown "$owner":"$group" "$tmp_file" 2>/dev/null || true

        # 精确删除旧 key（严格匹配 key=）
        awk -v k="$key" 'index($0, k"=") != 1' "$ENV_FILE" > "$tmp_file"

        # 写入新值
        printf '%s="%s"\n' "$key" "$value" >> "$tmp_file"

        # 原子替换
        mv "$tmp_file" "$ENV_FILE"

    ) 200>"$ENV_FILE.lock"
}

# 随机生成 WS 路径
generate_ws_path() {
    echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
}

# 随机生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# ---------------------------------------------------------------- 地址库
# 对外地址探测: 单一实现, 见 conf/lib/addr.sh 顶部 (为什么不问外部"我的 IP")。
# 本脚本常以 `bash <(curl ...)` 直接跑, 旁边没有 lib/ —— 三级查找:
# 脚本旁边 -> 安装目录 -> 从仓库现取。都取不到就退化成"只读网卡"的内置实现,
# 不让一个库取不到就打断整条安装流程。
_x_addr_loaded=0
for _addr_cand in "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/lib/addr.sh" \
                  "$INSTALL_DIR/lib/addr.sh"; do
    if [ -r "$_addr_cand" ]; then
        # shellcheck source=/dev/null
        if source "$_addr_cand" 2>/dev/null; then _x_addr_loaded=1; break; fi
    fi
done
if [ "$_x_addr_loaded" -eq 0 ]; then
    _addr_tmp=$(mktemp)
    if curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/addr.sh" \
            -o "$_addr_tmp" 2>/dev/null; then
        # shellcheck source=/dev/null
        source "$_addr_tmp" 2>/dev/null && _x_addr_loaded=1
    fi
    rm -f "$_addr_tmp"
fi
if [ "$_x_addr_loaded" -eq 0 ]; then
    # 退化实现 (不问外部服务, 但也不排除隧道网卡 —— 只保证流程能走完)
    x_addr4_real() {
        ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
            grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1
    }
    x_addr6_real() {
        ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
    }
    print_warn "地址库 conf/lib/addr.sh 取不到, 用内置退化实现（不排除 warp/tun 网卡）"
fi

usid() {
    # 生成短 id
    short_id=$(openssl rand -hex 4)

    # 生成端口与路径
    WS_PATH1=$(generate_ws_path)
    WS_PATH=$(generate_ws_path)
    WS_PATH2=$(generate_ws_path)
    UUID=$(generate_uuid)
    UUID2=$(generate_uuid)

    print_info "UUID: $UUID"
    print_info "UUID2: $UUID2"
    print_info "WS_PATH1: $WS_PATH1"
    print_info "WS_PATH: $WS_PATH"
    print_info "WS_PATH2: $WS_PATH2"
    print_info "short_id: $short_id"

    # ---- 对外地址 ----
    #
    # ★ 这里原来是 `curl -s4 https://api.ipify.org`: 问的是"世界看到的我",
    #   也就是**出站出口**。套了 WARP 时答案是 WARP 的地址 (RN 实测
    #   104.28.201.80), 而客户端只连得上真实网卡地址 (107.173.154.178)。
    #   这个值写进 install_info.env 之后, 所有分享链接 (Reality / Trojan /
    #   转换脚本 / CDN 脚本) 全部跟着错 —— 链接看起来完全正常, 连上去必失败。
    #
    #   现在一律先读网卡 (conf/lib/addr.sh: 排除 warp/tun/docker/私网,
    #   默认路由所在网卡优先); 网卡上确实没有才退回外部探测, 且外部答案
    #   必须落在本机网卡上才采信 —— 与 SB 的 default_server_ip_real 同源。
    if [ -n "${XRAY_PUBLIC_IP:-}" ]; then
        PUBLIC_IP="$XRAY_PUBLIC_IP"
        print_info "使用 XRAY_PUBLIC_IP 指定的对外地址: $PUBLIC_IP"
    else
        PUBLIC_IP_V4=$(x_addr4_real 2>/dev/null || true)
        PUBLIC_IP_V6=$(x_addr6_real 2>/dev/null || true)

        if [ -z "$PUBLIC_IP_V4" ] && [ -z "$PUBLIC_IP_V6" ]; then
            # 网卡上没有可直连地址 (NAT / 全走隧道): 退回外部服务, 但要说清
            # 这是"世界看到的我", 需要用户自己核对。
            PUBLIC_IP_V4=$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)
            PUBLIC_IP_V6=$(curl -s6 --max-time 8 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]' || true)
            if [ -z "$PUBLIC_IP_V4" ] && [ -z "$PUBLIC_IP_V6" ]; then
                print_error "无法检测公网 IP（网卡与外部服务都没给出地址），请检查网络或用 XRAY_PUBLIC_IP 指定"
                exit 1
            fi
            print_warn "网卡上没有找到可直连的地址（NAT/隧道?），暂用外部服务返回的: ${PUBLIC_IP_V4:-$PUBLIC_IP_V6}"
        fi

        if [ -n "$PUBLIC_IP_V4" ] && [ -n "$PUBLIC_IP_V6" ]; then
            echo "请选择要使用的公网 IP 地址:"
            echo "1. IPv4: $PUBLIC_IP_V4"
            echo "2. IPv6: $PUBLIC_IP_V6"
            read -p "请输入对应的数字选择 [默认1，若不可用则选择可用项]: " IP_CHOICE
            IP_CHOICE=${IP_CHOICE:-1}
        else
            # 只有一族可用就不问了 —— 问了也只有那一个答案
            [ -n "$PUBLIC_IP_V4" ] && IP_CHOICE=1 || IP_CHOICE=2
        fi

        # 选择公网 IP 地址
        if [ "$IP_CHOICE" -eq 2 ] && [ -n "$PUBLIC_IP_V6" ]; then
            PUBLIC_IP="$PUBLIC_IP_V6"
        else
            PUBLIC_IP="${PUBLIC_IP_V4:-$PUBLIC_IP_V6}"
        fi
    fi

    # 自检: 选中的地址客户端连不连得上 (WARP/隧道/私网地址 → 只警告, 不拦)
    if declare -F x_addr_is_reachable >/dev/null 2>&1; then
        x_addr_is_reachable "$PUBLIC_IP" || \
            print_warn "选中的地址 $PUBLIC_IP 不在本机可直连的网卡上（WARP/隧道/私网?）—— 客户端可能连不上"
    fi

    # IPv6 需要中括号，IPv4 不需要
    if [[ "$PUBLIC_IP" =~ : ]]; then
        link_ip="[$PUBLIC_IP]"
    else
        link_ip="$PUBLIC_IP"
    fi

    update_env link_ip "$link_ip"

    print_info "选定公网 IP: $PUBLIC_IP"

    update_env PUBLIC_IP "$PUBLIC_IP"
    update_env IP_CHOICE "$IP_CHOICE"
    update_env UUID "$UUID"
    update_env UUID2 "$UUID2"
    update_env WS_PATH1 "$WS_PATH1"
    update_env WS_PATH "$WS_PATH"
    update_env WS_PATH2 "$WS_PATH2"
    update_env PRIVATE_KEY "$(tr -d '\n' < /usr/local/etc/xray/privatekey)"
    update_env PUBLIC_KEY "$(tr -d '\n' < /usr/local/etc/xray/publickey)"
    update_env PASSWORD "$(tr -d '\n' < /usr/local/etc/xray/password)"
    update_env short_id "$short_id"
}

getkey() {
    print_info "正在生成 Reality 密钥对，请耐心等待..."

    mkdir -p /usr/local/etc/xray

    XRAY_BIN="$xrayls_DTR"
    if [ ! -x "$XRAY_BIN" ]; then
        print_error "未找到 xrayls 可执行文件：$XRAY_BIN"
        exit 1
    fi

    # 生成 PrivateKey、Password、Hash32
    key_output=$("$XRAY_BIN" x25519)
    private_key=$(echo "$key_output" | awk -F': ' '/PrivateKey/ {print $2}')
    password=$(echo "$key_output" | awk -F': ' '/Password/ {print $2}')
    hash32=$(echo "$key_output" | awk -F': ' '/Hash32/ {print $2}')

    if [ -z "$private_key" ] || [ -z "$password" ]; then
        print_error "未生成 privateKey 或 password，退出"
        exit 1
    fi

    # publicKey 就等于 password
    public_key="$password"

    # 保存到 /usr/local/etc/xray
    echo "$private_key" > /usr/local/etc/xray/privatekey
    echo "$public_key" > /usr/local/etc/xray/publickey
    echo "$password" > /usr/local/etc/xray/password
    echo "$hash32" > /usr/local/etc/xray/hash32
    chmod 600 /usr/local/etc/xray/*
}

generate_mlkem() {
    print_info "正在生成 ML-KEM（后量子加密 PQ）参数..."

    if [ ! -x "$xrayls_DTR" ]; then
        print_error "未找到 xrayls 可执行文件：$xrayls_DTR"
        exit 1
    fi

    VLESSENC_OUTPUT=$("$xrayls_DTR" vlessenc 2>/dev/null || true)

    if [ -z "$VLESSENC_OUTPUT" ]; then
        print_error "xrayls vlessenc 无输出，无法生成 ML-KEM PQ 加密串"
        exit 1
    fi

    # 换行 → 空格（避免串黏连）
    CLEAN_OUTPUT=$(echo "$VLESSENC_OUTPUT" | tr '\n' ' ')

    # 取最后一个 decryption（ML-KEM-768）
    SERVER_DEC=$(echo "$CLEAN_OUTPUT" | grep -oP '"decryption"\s*:\s*"\K[^"]+' | tail -n 1)

    # 取最后一个 encryption（ML-KEM-768）
    CLIENT_ENC=$(echo "$CLEAN_OUTPUT" | grep -oP '"encryption"\s*:\s*"\K[^"]+' | tail -n 1)

    if [[ -z "$SERVER_DEC" || -z "$CLIENT_ENC" ]]; then
        print_error "无法解析 ML-KEM-768 加密串"
        echo "$VLESSENC_OUTPUT"
        exit 1
    fi

    print_info "ML-KEM 服务端 decryption: $SERVER_DEC"
    print_info "ML-KEM 客户端 encryption: $CLIENT_ENC"

    update_env SERVER_DEC "$SERVER_DEC"
    update_env CLIENT_ENC "$CLIENT_ENC"
}


generate_all_env() {
    # 检查 openssl 是否存在
    if ! command -v openssl >/dev/null 2>&1; then
        print_info "openssl 未安装，正在自动安装..."

        if command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y openssl
        elif command -v yum >/dev/null 2>&1; then
            yum install -y openssl
        elif command -v apk >/dev/null 2>&1; then
            apk add openssl
        else
            print_error "无法自动安装 openssl，请手动安装"
            exit 1
        fi
    fi

    getkey
    usid
    generate_mlkem
}

generate_all_env
