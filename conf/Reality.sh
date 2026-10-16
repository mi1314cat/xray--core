#!/bin/bash

# ---- 共用那一层 (打印/读输入/编号/端口) ----
#
# 这几个函数以前在本文件里各抄了一份, 而且**已经开始漂移**:
# Reality.sh 的 safe_read 带 batch 守卫, 另外两个不带 —— 只从菜单进时
# 看不出来, 但只要哪天有人非交互地调用后两个, 它就会永远卡在 read 上。
# 抽成一份之后就不可能再各走各的了。详见 conf/lib/proto_ui.sh。
_PUI="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/proto_ui.sh"
if [[ -r "$_PUI" ]]; then
    # shellcheck source=/dev/null
    source "$_PUI"
elif [[ "${X_BATCH:-0}" == "1" ]]; then
    echo "缺少 conf/lib/proto_ui.sh, 且是批处理调用 —— 拒绝继续" >&2
    exit 1
fi

# ================================
# Reality 节点配置管理（X 内核 / xrayls）
# 输出为 xray--core 碎片式配置：conf/reality-NN.json
# 格式与 conf/http.sh 完全一致（list / add / delete 菜单式节点脚本）
#
# 伪装域名 dest_server 由专职维护脚本 domains.sh 负责：
#   https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh
#   （自动从 TLS1.3+h2 安全域名池现场优选，并写入 catmi.env / install_info.env）
#
# 默认「最高配置」：
#   - flow: xtls-rprx-vision            （Xray 官方唯一推荐的 Reality flow）
#   - 加密: ML-KEM-768 后量子 VLESS Encryption（SERVER_DEC，来自 xrayls vlessenc）
#   - realitySettings.maxTimeDiff = 40000（默认 0=不限时，最高配启用 40s 防重放）
#   - sniffing          = 开启（destOverride http,tls,quic）
# 可选项（默认均为最高配置，回车即可）：
#   - 端口（默认随机高位空闲端口）
#   - 伪装域名（默认 domains.sh 优选结果）
#   - 纯 X25519 / ML-KEM-768（默认 ML-KEM）
# ================================

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


# ================================
# 基础变量
# ================================
PROTO="reality"
# ★ 变量名是 XRAY_BASE_DIR, **不是** XRAY_BASE
#
#   之前写成 `XRAY_BASE="${XRAY_BASE_DIR:-/root/catmi/xray}"` —— 于是外面
#   `XRAY_BASE=/tmp/sandbox bash conf/batch.sh` 会被**这一行原样覆盖掉**,
#   紧接着的 CONF_DIR 指向生产目录。测试在生产上跑, 而屏幕上一切正常。
#   我 10-12 那次 E2E 就是这么把批量生成跑到了 /root/catmi/xray/conf 上,
#   只因为"节点已存在, 全部跳过"才没写坏东西 —— 属于运气, 不是设计。
#
#   两个都收, 并且把"设错了却被忽略"这件事**说出来**: 静默忽略最贵, 因为
#   它让你以为自己测的是沙箱。
# ★ 三个变量都要收, 而且**互相不能顶掉**:
#     XRAY_BASE_DIR  安装器/老脚本用的名字
#     XRAY_BASE      面板与 install.sh 用的名字
#     XRAY_CONF_DIR  只指配置目录时的覆盖 (mknode / node.sh / share.sh 都认它)
#
#   只认前两个的后果是**静默写生产**: 有人(包括我自己的门禁)写
#       XRAY_CONF_DIR=/tmp/x/conf bash conf/Reality.sh add
#   以为在沙箱里, 而这一行把它原样丢掉、CONF_DIR 仍指 /root/catmi/xray/conf,
#   于是在生产上凭空多出一个节点。实测踩到过: 跑一遍门禁, 生产 conf 里
#   多出一个 reality-03.json。
#
#   静默忽略环境变量比报错危险得多 —— 它让你以为自己测的是沙箱。
XRAY_BASE="${XRAY_BASE_DIR:-${XRAY_BASE:-/root/catmi/xray}}"
_XRAY_CONF_OVERRIDE="${XRAY_CONF_DIR:-}"
_XRAY_OUT_OVERRIDE="${XRAY_OUT_DIR:-}"
CONF_DIR="${_XRAY_CONF_OVERRIDE:-$XRAY_BASE/conf}"
# ★ 判定要跟着**真正生效的那个目录**走: 只给 XRAY_CONF_DIR 时 XRAY_BASE 仍是
#   生产值, 但写的已经不是生产目录了 —— 那种情况必须也算沙箱, 否则会变成
#   "配置写到别处、systemd 照样重启生产服务"。
X_IS_SANDBOX=false
if [[ "$XRAY_BASE" != /root/catmi/xray || "$CONF_DIR" != /root/catmi/xray/conf ]]; then
    X_IS_SANDBOX=true
fi
OUT_DIR="${_XRAY_OUT_OVERRIDE:-$XRAY_BASE/out}"
# 安装目录: 生产默认 /root/catmi/xray; 可用 XRAY_INSTALL_DIR 指到别处
# (与 install.sh / verify.sh 同一个变量名), 也可跟随 XRAY_BASE_DIR 沙箱化 ——
# 否则沙箱里生成的片段永远过不了 -test(找不到 xrayls), 而失败原因看起来是"配置错"。
INSTALL_DIR="${XRAY_INSTALL_DIR:-${XRAY_BASE_DIR:-/root/catmi/xray}}"
XRAY_BIN="$INSTALL_DIR/xrayls"
mkdir -p "$CONF_DIR" "$OUT_DIR"

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

# 对外地址探测库 —— 分享链接/客户端产物里的地址一律从这里取。
# 见 conf/lib/addr.sh 顶部: 为什么不能问外部"我的 IP"、为什么要排除隧道网卡。
if [[ -r "$_x_lib_dir/lib/addr.sh" ]]; then
    source "$_x_lib_dir/lib/addr.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/addr.sh") \
        || { print_error "地址库加载失败"; exit 1; }
fi

# 该写进分享链接的那个地址。
#
# ★ 为什么不能直接用 install_info.env 里的 PUBLIC_IP:
#   那是**安装时**写进去的。修复前那版脚本问的是 api.ipify.org (出站出口),
#   套了 WARP 的机器上存的就是 WARP 地址 (RN 实测 104.28.201.80), 而服务器
#   入站是 107.173.154.178 —— 分享链接发出去即死, 且链接本身看起来完全正常。
#   所以每次生成都现场算: 存的值只有"落在客户端连得上的网卡上"才沿用。
#   优先级: XRAY_PUBLIC_IP > 存的值(过自检) > 网卡地址 > 外部探测(仍要自检)。
resolve_public_ip() {
    x_link_addr "${1:-}"
}
# ================================
# 安全输入（过滤控制字符）
# ================================



# ================================
# 编号系统（reality-NN.json）
# ================================

# ================================
# 环境准备：伪装域名(domains.sh) + 密钥(xrayls/XRevise.sh)
# · 伪装域名维护脚本：domains.sh 生成并持久化 dest_server
# · 密钥脚本：conf/XRevise.sh 生成 x25519 密钥对 / UUID / short_id / ML-KEM 串
# ================================
prepare_env() {
    local CATMIENV_FILE="/root/catmi/catmi.env"
    if [[ ! -x "$XRAY_BIN" ]]; then
        print_error "未找到 xrayls（$XRAY_BIN），请先运行安装脚本（面板选项 1）"
        return 1
    fi
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
    update_env "$CATMIENV_FILE" mode xray

    print_info "正在检测/更新 Reality 伪装域名（domains.sh）..."
    bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh) \
        || { print_error "domains.sh 执行失败"; return 1; }

    print_info "正在生成 Reality 密钥与节点参数（conf/XRevise.sh）..."
    bash <(curl -fsSL ${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/XRevise.sh) \
        || { print_error "XRevise.sh 执行失败"; return 1; }

    load_env "$INSTALL_DIR/install_info.env"   || return 1
    load_env "/root/catmi/catmi.env"           || return 1

    local v
    for v in UUID PRIVATE_KEY PUBLIC_KEY short_id dest_server SERVER_DEC CLIENT_ENC PUBLIC_IP link_ip; do
        [[ -n "${!v}" ]] || { print_error "缺少必要变量：$v"; return 1; }
    done

    # ★ 现场校正对外地址 (见 resolve_public_ip 注释):
    #   env 里存的可能是修复前写进去的 WARP 出口地址, 直接用它 = 分享链接死链。
    local ip_now
    ip_now=$(resolve_public_ip "$PUBLIC_IP")
    if [[ -n "$ip_now" && "$ip_now" != "$PUBLIC_IP" ]]; then
        print_warn "install_info.env 里的地址 $PUBLIC_IP 客户端连不上（WARP/隧道/不在本机?），本次改用 $ip_now"
        print_warn "  如需长期修正: 重跑安装(面板选项 1) 或用 XRAY_PUBLIC_IP=<真实入口地址> 生成节点"
        PUBLIC_IP="$ip_now"
    fi
    if [[ "$PUBLIC_IP" == *:* ]]; then link_ip="[$PUBLIC_IP]"; else link_ip="$PUBLIC_IP"; fi
    return 0
}

# ================================
# 显示所有配置
# ================================
list_configs() {
    print_title "当前 Reality 配置列表"

    shopt -s nullglob
    local files=("$CONF_DIR"/$PROTO-*.json)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "没有找到任何 Reality 配置"
        return 1
    fi

    echo -e "${CYAN}编号 | 端口 | UUID | flow | SNI${RESET}" >&2
    echo "--------------------------------------------------------" >&2

    local f num port flow sni
    for f in "${files[@]}"; do
        num=$(basename "$f" | sed -E "s/^${PROTO}-([0-9]+)\.json$/\1/")
        port=$(jq -r '.inbounds[0].port' "$f" 2>/dev/null)
        uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$f" 2>/dev/null)
        flow=$(jq -r '.inbounds[0].settings.clients[0].flow' "$f" 2>/dev/null)
        sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$f" 2>/dev/null)
        echo -e "${GREEN}${num}${RESET}) 端口: ${YELLOW}${port}${RESET} | UUID: ${MAGENTA}${uuid}${RESET} | flow: ${CYAN}${flow}${RESET} | SNI: ${BLUE}${sni}${RESET}" >&2
    done

    echo "--------------------------------------------------------" >&2
    return 0
}

# ================================
# 新增配置（默认最高配置）
# ================================
add_config() {
    print_title "新增 Reality 配置"

    prepare_env || return 1

    # ---- 端口（默认：随机高位空闲端口）----
    default_port=$(random_free_port)
    lport=$(safe_read_port "监听端口" "$default_port")

    # ---- 伪装域名（默认：domains.sh 优选的 dest_server）----
    DEST=$(safe_read "请输入 Reality 伪装域名 (SNI/dest)" "$dest_server")

    # ---- 可选降级询问（默认全部最高配置）----
    local encryption_mode="mldsa"
    printf "默认使用最高配置：ML-KEM-768 后量子 VLESS Encryption。\n" >&2
    printf "回车=最高配置；选择降级为纯 X25519 (decryption none) 请输入 1: " >&2
    read yn
    yn=$(clean_input "$yn")
    [[ "$yn" == "1" ]] && encryption_mode="plain"

    local flow="xtls-rprx-vision"
    printf "flow 默认 xtls-rprx-vision（官方唯一推荐）。输入 1 降级为无 flow: " >&2
    read yn
    yn=$(clean_input "$yn")
    [[ "$yn" == "1" ]] && flow="none" && encryption_mode="plain"

    next=$(get_next_index)
    tag_name="REALITY-${next}"

    # ---- decryption 字段（服务端）----
    local decryption="none"
    [[ "$encryption_mode" == "mldsa" ]] && decryption="$SERVER_DEC"

    # ---- 客户端 encryption参数（分享链接用）----
    local link_enc=""
    [[ "$encryption_mode" == "mldsa" ]] && link_enc="&encryption=${CLIENT_ENC}"

    file="$CONF_DIR/$PROTO-$next.json"

cat <<EOF > "$file"
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $lport,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "$flow"
          }
        ],
        "decryption": "$decryption"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "${DEST}:443",
          "serverNames": ["$DEST"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$short_id"],
          "maxTimeDiff": 40000,
          "xver": 0
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "tag": "$tag_name"
    }
  ]
}
EOF

    # 配置自检（碎片文件单独测试）；失败则清理，不留坏文件
    if ! "$XRAY_BIN" -test -config "$file" >/dev/null 2>&1; then
        print_error "生成的配置无法通过内核测试：$file（已清理，原因如下）"
        "$XRAY_BIN" -test -config "$file" 2>&1 | tail -5
        rm -f "$file"
        return 1
    fi

    # ---- X 内核客户端出站配置（out/ 目录，必须使用 vnext 结构）----
    cat > "$OUT_DIR/$PROTO-$next.json" <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "${link_ip}",
        "port": ${lport},
        "users": [
          {
            "id": "$UUID",
            "encryption": "$([ "$encryption_mode" = "mldsa" ] && echo "$CLIENT_ENC" || echo none)",
            "flow": "$flow"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$DEST",
      "fingerprint": "chrome",
      "publicKey": "$PUBLIC_KEY",
      "shortId": "$short_id",
      "spiderX": "/"
    }
  },
  "tag": "out-reality-$next"
}
EOF

    # ---- mihomo (Clash.Meta) YAML 客户端文件（M 内核）----
    cat > "$OUT_DIR/$PROTO-client-$next.yaml" <<EOF
# mihomo (Clash.Meta) 客户端配置 —— Reality-$next
# M 内核需为支持 VLESS Encryption（mlkem768）的新版本；旧版 M 内核请选纯 X25519 模式重新生成
proxies:
  - name: Reality-$next
    type: vless
    server: $PUBLIC_IP
    port: $lport
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: $flow
    servername: $DEST
    encryption: $([ "$encryption_mode" = "mldsa" ] && echo "$CLIENT_ENC" || echo none)
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $short_id
    client-fingerprint: chrome
EOF

    # ---- 分享链接 ----
    echo "vless://${UUID}@${link_ip}:${lport}?flow=${flow}&security=reality&sni=${DEST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${short_id}&type=tcp${link_enc}#Reality-${next}" \
        > "$OUT_DIR/$PROTO-share-$next.txt"

    
    # ---- 12. 补发布: 分享元数据 + (CDN 档位) nginx ----
    #
    # ★ 这个脚本是自己拿 heredoc 拼片段的, 所以一直**绕过了** plan()/
    #   apply_plan()。后果是建出来的节点:
    #     · 没有分享元数据 → **没有分享链接、不进订阅**
    #     · 没有 nginx 段  → CDN 档位下回源直接 502, 而面板上一片正常
    # 这里在写完片段之后补上这一步, 让菜单 7 出来的节点和新预置
    # 体系的节点**待遇一致**。不动它建节点的逻辑 —— 那是它自己的交互流程,
    # 重写风险大得多。
    _ad="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/lib/deploy.py"
    if [[ -r "$_ad" ]]; then
        # ★ 这里必须给**对外入口地址**, 不能给伪装域名。
        #   以前写的是 --domain "$DEST" —— DEST 是 REALITY 的伪装目标
        #   (go.dev 这类), 它只是握手时给对方看的 SNI, **根本不是本机地址**。
        #   后果: 补出来的分享元数据里 host=go.dev, 于是订阅里这个节点指向
        #   go.dev:<端口> —— 客户端连过去当然是别人的服务器, 而这个节点在
        #   面板上、在分享链接里都"正常"。实测 (全协议建完之后订阅里只有
        #   预置体系的节点, 协议脚本建的四个一个都没进去) 才查到这一层。
        #   vlessecn.sh 那边给的是 link_ip (对的), 这里跟着它改。
        # ★ 把**客户端那一半**会话加密也带过去。不带的话订阅里这条链接会写成
        #   encryption=none, 而服务端要求 ML-KEM —— 客户端连上去必失败,
        #   而脚本自己写的那份 share-NN.txt 是好的 (两条路径不一致, 实测踩到)。
        _ce_arg=()
        [[ "$encryption_mode" == "mldsa" && -n "$CLIENT_ENC" ]] && _ce_arg=(--client-encryption "$CLIENT_ENC")
        if ! python3 "$_ad" --adopt ""$file"" --domain ""$link_ip"" "${_ce_arg[@]}" >&2; then
            print_warn "  分享元数据没补上 —— 这个节点暂时没有分享链接"
            print_warn "  面板的其它功能正常; 需要链接时用菜单 13 (预置档位) 重建一个"
        fi
    else
        print_warn "  找不到 lib/deploy.py, 跳过补发布 (本节点无分享链接)"
    fi

print_ok "新增 Reality 配置成功（最高配置）"
    echo -e "编号: $next\n监听: 0.0.0.0:$lport\nUUID: $UUID\nflow: $flow\n加密: $([ "$encryption_mode" = "mldsa" ] && echo 'ML-KEM-768 (PQ 量子抗性)' || echo '纯 X25519 (无 PQ)')\nSNI/target: ${DEST}:443\nmaxTimeDiff: 40000\nTag: $tag_name\n入站碎片: $file\n客户端文件(X内核): $OUT_DIR/$PROTO-$next.json\n客户端文件(M内核YAML): $OUT_DIR/$PROTO-client-$next.yaml\n分享链接: $OUT_DIR/$PROTO-share-$next.txt" >&2
}

# ================================
# 删除配置
# ================================
delete_config() {
    list_configs || return

    printf "请输入要删除的编号: " >&2
    read num
    num=$(clean_input "$num")

    file="$CONF_DIR/$PROTO-$(printf "%02d" $num).json"

    if [[ -f "$file" ]]; then
        rm -f "$file" "$OUT_DIR/$PROTO-$num.json" "$OUT_DIR/$PROTO-client-$num.yaml" "$OUT_DIR/$PROTO-share-$num.txt"
        print_ok "已删除编号 $num 的 Reality 配置（含客户端文件与分享链接）"
    else
        print_error "编号 $num 不存在"
    fi
}

# ================================
# 显示客户端配置（复用 out/ 文件）
# ================================
show_client() {
    shopt -s nullglob
    local files=("$OUT_DIR"/$PROTO-share-*.txt)
    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "当前没有 Reality 分享链接文件"
        return
    fi
    for f in "${files[@]}"; do
        echo -e "\n===== $f ====="
        cat "$f"
    done
}

# ================================
# 主菜单
# ================================
config_menu() {
    if ! command -v jq >/dev/null 2>&1; then
        print_error "缺少 jq（列表解析需要），请先安装：apt install -y jq"
        return
    fi

    while true; do
        print_title "Reality 配置管理"

        echo "1) 查看所有配置" >&2
        echo "2) 新增配置（默认最高配置：vision + ML-KEM-768 + maxTimeDiff）" >&2
        echo "3) 删除配置" >&2
        echo "4) 查看客户端链接" >&2
        echo "0) 返回主菜单" >&2

        printf "请选择: " >&2
        read c || exit 0  # EOF 时退出，避免无限菜单循环
        c=$(clean_input "$c")

        case $c in
             1)
                list_configs
                printf "按回车继续..." >&2
                read
            ;;
            2)
                add_config
                printf "按回车继续..." >&2
                read
            ;;
            3)
                delete_config
                printf "按回车继续..." >&2
                read
            ;;
            4)
                show_client
                printf "按回车继续..." >&2
                read
            ;;
            0)
                return
            ;;
            *)
                print_error "无效选项"
                printf "按回车继续..." >&2
                read
            ;;
        esac
    done
}

# 直跑入口: add = 由 Batch Generator (conf/batch.sh) 无交互调用;
# 不带参数 = 原有交互菜单 (单协议行为不变)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == "add" ]]; then
        add_config
    else
        config_menu
    fi
fi
