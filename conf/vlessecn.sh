#!/bin/bash

# ================================
# 依赖检查
# ================================
if ! command -v jq &>/dev/null; then
    echo -e "\e[31m[ERROR]\e[0m 需要安装 jq，请执行: apt install -y jq 或 yum install -y jq"
    exit 1
fi

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
# 打印函数（全部输出到 stderr，避免污染变量）
# ================================
print_info()  { echo -e "${CYAN}[Info]${RESET} $1" >&2; }
print_ok()    { echo -e "${GREEN}[OK]${RESET}  $1" >&2; }
print_error() { echo -e "${RED}[Error]${RESET} $1" >&2; }

print_title() {
    echo -e "${MAGENTA}${BOLD}" >&2
    echo "╔══════════════════════════════════════════════╗" >&2
    printf "║ %-42s ║\n" "$1" >&2
    echo "╚══════════════════════════════════════════════╝" >&2
    echo -e "${RESET}" >&2
}

# ================================
# 基础变量
# ================================
PROTO="vless-tcp-mlkem"
PROTO_NAME="VLESS-TCP-ML-KEM"
CONF_DIR="/root/catmi/xray/conf"
XRAYLS_BIN="/root/catmi/xray/xrayls"   # 必需，用于生成 ML-KEM 密钥

# ★ 这里原来有一行备用固定密钥 (FALLBACK_ENC="mlkem768x25519plus...")。
#   已删除。两个理由, 第二个更要命:
#
#   1) 这个文件在**公开仓库**里。等于把服务端的解密密钥印在报纸上 ——
#      拿到仓库的人就能解所有人的流量, 而 ML-KEM-768 那套后量子加密
#      提供的机密性正好归零。原注释还写着"功能不受影响", 这句是错的。
#
#   2) 更严重: 原来的兜底把 SERVER_DEC 和 CLIENT_ENC **赋成同一个值**。
#      但这两个是 vlessenc 一次生成的**配对**值, 服务端 decryption 与客户端
#      encryption 本来就不同。把两者填成同一个字符串, 建出来的节点连不上。
#      "兜底"本身是坏的, 只是没人走到过那条路 (xrayls 一直在) 所以没暴露。
#
#   现在取不到密钥就**明确失败**并说清怎么办 —— 宁可建不出节点,
#   也不能建出一个密钥公开、且握手就失败的节点。

mkdir -p "$CONF_DIR"

# ================================
# 随机生成函数
# ================================
# 端口分配: 统一从 conf/lib/ports.sh 取, 本脚本不再自带副本。
# 副本时代改一处漏一处 —— 批量区间分配只进了 4 个脚本, 另外 5 个的批量
# 生成仍在用随机端口, 同一批节点端口散落在 10000-60000。
_x_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -r "$_x_lib_dir/lib/ports.sh" ]]; then
    source "$_x_lib_dir/lib/ports.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/ports.sh") \
        || { print_error "端口库加载失败"; exit 1; }
fi

# 对外地址探测库 (单一实现) —— 分享链接里的地址一律从这里取。
# 见 conf/lib/addr.sh 顶部: 为什么不能问外部"我的 IP"、为什么要排除隧道网卡。
if [[ -r "$_x_lib_dir/lib/addr.sh" ]]; then
    source "$_x_lib_dir/lib/addr.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/addr.sh") \
        || { print_error "地址库加载失败"; exit 1; }
fi
# ================================
# 安全输入（过滤控制字符）
# ================================
clean_input() { echo "$1" | tr -d '\000-\037'; }

safe_read() {
    local prompt="$1" default="$2" input
    printf "%s (默认: %s): " "$prompt" "$default" >&2
    read input
    input=$(clean_input "$input")
    echo "${input:-$default}"
}

safe_read_port() {
    local default="$1" input port
    while true; do
        printf "请输入监听端口 (1-65535, 默认: %s): " "$default" >&2
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
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done
    printf "%02d\n" "$i"
}

# ================================
# IPv4 / IPv6 自动检测
# ================================
detect_listen_ip() {
    local has_ipv4=false has_ipv6=false
    ip -4 addr show scope global | grep -q "inet " && has_ipv4=true
    ip -6 addr show scope global | grep -q "inet6 [2-9a-fA-F]" && has_ipv6=true

    if $has_ipv4 && ! $has_ipv6; then echo "ipv4"
    elif ! $has_ipv4 && $has_ipv6; then echo "ipv6"
    elif $has_ipv4 && $has_ipv6; then echo "dual"
    else echo "none"
    fi
}

# ================================
# 监听地址选择
# ================================
choose_listen_ip() {
    local detect="$1" choice
    print_info "自动检测结果："
    [[ "$detect" == "ipv4" ]] && echo "  - 检测到 IPv4" >&2
    [[ "$detect" == "ipv6" ]] && echo "  - 检测到 IPv6" >&2
    [[ "$detect" == "dual" ]] && echo "  - 检测到 IPv4 + IPv6" >&2
    [[ "$detect" == "none" ]] && echo "  - 未检测到公网 IP" >&2

    echo >&2
    echo "请选择监听地址：" >&2
    echo "1) IPv4 (0.0.0.0)" >&2
    echo "2) IPv6 (::)" >&2
    echo "3) 本机回环 (127.0.0.1)" >&2

    printf "选择 (默认 1): " >&2
    read choice
    choice=$(clean_input "$choice")

    case "$choice" in
        2) echo "::" ;;
        3) echo "127.0.0.1" ;;
        *) echo "0.0.0.0" ;;
    esac
}

# ================================
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 ${PROTO_NAME} 配置列表"

    echo -e "${CYAN}编号 | 监听地址 | 端口 | UUID | Tag${RESET}" >&2
    echo "--------------------------------------------------------------------------------" >&2

    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" .json | cut -d'-' -f2)
        if ! jq empty "$f" 2>/dev/null; then
            echo -e "${RED}[损坏]${RESET} $num (无法解析 JSON)" >&2
            continue
        fi
        lport=$(jq -r '.inbounds[0].port' "$f")
        listen=$(jq -r '.inbounds[0].listen' "$f")
        uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$f")
        tag=$(jq -r '.inbounds[0].tag' "$f")
        echo -e "${GREEN}$num${RESET}) ${YELLOW}$listen${RESET} | ${CYAN}$lport${RESET} | ${MAGENTA}$uuid${RESET} | Tag: ${WHITE}$tag${RESET}" >&2
    done
    echo "--------------------------------------------------------------------------------" >&2
}

# ================================
# 公网 IP 获取（支持手动输入）
# ================================
get_public_ip() {
    local ipv4 ipv6 choice manual_ip
    # ★ 先读网卡 (排除 warp/tun/docker, 默认路由网卡优先), 网卡上没有才问外部服务。
    #   原来一上来就问 api.ipify.org —— 那答的是**出站出口**: 套了 WARP 的机器
    #   上拿到的是 WARP 地址, 客户端照着连必然不通。见 conf/lib/addr.sh 顶部。
    ipv4=$(x_addr4_real 2>/dev/null || true)
    ipv6=$(x_addr6_real 2>/dev/null || true)
    if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
        ipv4=$(curl -s4 --connect-timeout 3 https://api.ipify.org 2>/dev/null || true)
        ipv6=$(curl -s6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || true)
    fi

    if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
        print_error "无法自动检测公网 IP，请手动输入"
        while true; do
            printf "请输入服务器公网 IP（IPv4 或 IPv6）: " >&2
            read manual_ip
            manual_ip=$(clean_input "$manual_ip")
            if [[ "$manual_ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
                echo "$manual_ip"
                return
            fi
            print_error "IP 格式无效"
        done
    fi

    echo "请选择对外 IP:" >&2
    [ -n "$ipv4" ] && echo "1) IPv4: $ipv4" >&2
    [ -n "$ipv6" ] && echo "2) IPv6: $ipv6" >&2
    echo "3) 手动输入" >&2

    while true; do
        printf "选择 (默认 1): " >&2
        read choice
        choice=$(clean_input "${choice:-1}")
        case $choice in
            1) [ -n "$ipv4" ] && { echo "$ipv4"; return; } || print_error "IPv4 不可用" ;;
            2) [ -n "$ipv6" ] && { echo "$ipv6"; return; } || print_error "IPv6 不可用" ;;
            3) printf "输入 IP: " >&2; read manual_ip
               manual_ip=$(clean_input "$manual_ip")
               if [[ "$manual_ip" =~ ^[0-9a-fA-F:.]+$ ]]; then echo "$manual_ip"; return; fi
               print_error "格式无效" ;;
            *) print_error "选项无效" ;;
        esac
    done
}

# ================================
# UUID 生成 + 校验
# ================================
generate_uuid() {
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$uuid"
    else
        print_error "UUID 生成失败，请检查系统环境"
        exit 1
    fi
}

# ================================
# ML-KEM 参数生成（核心优化）
# ================================
generate_mlkem() {
    if [ ! -x "$XRAYLS_BIN" ]; then
        print_error "未找到 xrayls 可执行文件: $XRAYLS_BIN"
        print_info "VLESS-ECN 必须用内核现生成 ML-KEM-768 密钥, 没有安全的替代方案"
        print_info "请先修好内核 (面板: 安装/修复内核), 再建这个节点"
        return 1
    fi

    print_info "正在通过 xrayls 生成 ML-KEM 参数..."
    local output
    output=$("$XRAYLS_BIN" vlessenc 2>/dev/null || true)
    if [ -z "$output" ]; then
        print_error "xrayls vlessenc 无输出 (内核需 >= 26.3.27 才有这个子命令)"
        print_info "请升级内核后重试; 不会用固定密钥兜底 —— 那个密钥是公开的"
        return 1
    fi

    SERVER_DEC=$(echo "$output" | grep -oP '"decryption"\s*:\s*"\K[^"]+' | tail -1)
    CLIENT_ENC=$(echo "$output" | grep -oP '"encryption"\s*:\s*"\K[^"]+' | tail -1)

    if [ -z "$SERVER_DEC" ] || [ -z "$CLIENT_ENC" ]; then
        # 同样不再兜底。另外这两个值必须来自**同一次** vlessenc 输出 ——
        # 原来若只解析出一个, 另一个会留空, 同样建出连不上的节点。
        print_error "没能从 xrayls vlessenc 输出里同时解析出 decryption 与 encryption"
        print_error "请升级内核 (>= 26.3.27) 后重试; 已中止, 未创建任何文件"
        SERVER_DEC=""; CLIENT_ENC=""
        return 1
    fi

    print_info "服务端 decryption: $SERVER_DEC"
    print_info "客户端 encryption: $CLIENT_ENC"
    return 0
}

# ================================
# 新增配置（使用 jq 动态生成 JSON）
# ================================
add_config() {
    print_title "新增 ${PROTO_NAME} 配置"

    # 1. 监听地址
    local detect=$(detect_listen_ip)
    local listen_ip=$(choose_listen_ip "$detect")

    # 2. 端口
    local default_port=$(random_free_port)
    local lport=$(safe_read_port "$default_port")

    # 3. 公网 IP
    local PUBLIC_IP=$(get_public_ip)
    local link_ip
    if [[ "$PUBLIC_IP" =~ : ]]; then
        link_ip="[$PUBLIC_IP]"
    else
        link_ip="$PUBLIC_IP"
    fi

    # 4. UUID
    local UUID=$(generate_uuid)

    # 5. ML-KEM 密钥
    #   ★ 必须检查返回值。generate_mlkem 现在取不到密钥时返回 1 (不再兜底),
    #   而原来这里是裸调用 —— 于是失败会被静默吞掉, 接着拿**空**的 SERVER_DEC
    #   去写配置文件, 产出一个密钥为空、握手必失败的节点, 而且面板显示成功。
    generate_mlkem || { print_error "没有 ML-KEM 密钥, 已中止 (未创建任何文件)"; return 1; }

    # 6. 索引与文件名
    local next=$(get_next_index)
    local tag_name="${PROTO}-${next}"
    local file="$CONF_DIR/$PROTO-$next.json"

    # 7. 使用 jq 生成 JSON
    jq -n \
        --arg listen "$listen_ip" \
        --argjson port "$lport" \
        --arg tag "$tag_name" \
        --arg uuid "$UUID" \
        --arg dec "$SERVER_DEC" \
        '{
            inbounds: [{
                listen: $listen,
                port: $port,
                tag: $tag,
                protocol: "vless",
                settings: {
                    clients: [{id: $uuid}],
                    decryption: $dec
                },
                streamSettings: {
                    network: "tcp"
                }
            }]
        }' > "$file"

    # 8. 验证 JSON
    if ! jq empty "$file" 2>/dev/null; then
        print_error "生成的 JSON 无效，请检查！文件：$file"
        cat "$file" >&2
        exit 1
    fi

    print_ok "新增 ${PROTO_NAME} 配置成功"
    echo -e "编号: $next\n监听地址: $listen_ip\n端口: $lport\nUUID: $UUID\nTag: $tag_name" >&2
    echo >&2

    # ============================
    #   保存客户端文件（优化版）
    # ============================

    mkdir -p /root/catmi/xray/out

    # 客户端链接
    local link="vless://${UUID}@${link_ip}:${lport}?type=tcp&encryption=${CLIENT_ENC}#vless-tcp-mlkem"

    # ① 保存链接（按协议分类）
    echo "[$next] $link" >> /root/catmi/xray/out/${PROTO}.txt

    # ② 保存 YAML（按协议分类）
cat >> /root/catmi/xray/out/${PROTO}.yaml <<EOF

# [$next] vless-tcp-mlkem-$next
- name: vless-tcp-mlkem-$next
  type: vless
  server: $PUBLIC_IP
  port: $lport
  uuid: $UUID
  encryption: $CLIENT_ENC
  network: tcp
  flow: ""
EOF

    # ============================
    #   控制台输出
    # ============================

    print_info "=== 客户端链接 ==="
    echo "$link" >&2
    echo >&2

    print_info "=== YAML 客户端配置示例 ==="
    cat >&2 <<EOF
- name: vless-tcp-mlkem-$next
  type: vless
  server: $PUBLIC_IP
  port: $lport
  uuid: $UUID
  encryption: $CLIENT_ENC
  network: tcp
  flow: ""
EOF
    echo >&2
}


# ================================
# 删除配置
# ================================
delete_config() {
    list_configs

    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")
    local num_fmt=$(printf "%02d" "$num")
    local file="$CONF_DIR/$PROTO-$num_fmt.json"

    if [[ -f "$file" ]]; then
        rm -f "$file"
        print_ok "已删除编号 $num_fmt 的 ${PROTO_NAME} 配置"
    else
        print_error "编号 $num_fmt 不存在"
    fi
}

# ================================
# 主菜单
# ================================
config_menu() {
    while true; do
        print_title "${PROTO_NAME} 配置管理"

        echo "1) 查看所有配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "0) 退出" >&2

        printf "请选择: " >&2
        # ★ stdin 关闭 (EOF) 时 read 返回非 0 且不修改 $c, case 落到 *) 后回到
        #   循环顶再读一次 —— 菜单空转刷屏, 永不退出。实测修前:
        #   timeout 10 bash conf/vlessecn.sh </dev/null → rc=124 (10 秒 299 行)。
        #   EOF 等同"用户退出", 直接返回。
        read c || return 0
        c=$(clean_input "$c")

        case $c in
            1)
                list_configs
                printf "按回车继续..." >&2
                read || return 0
            ;;
            2)
                add_config
                printf "按回车继续..." >&2
                read || return 0
            ;;
            3)
                delete_config
                printf "按回车继续..." >&2
                read || return 0
            ;;
            0)
                return
            ;;
            *)
                print_error "无效选项"
                printf "按回车继续..." >&2
                read || return 0
            ;;
        esac
    done
}

# ================================
# 程序入口
# ================================
config_menu
