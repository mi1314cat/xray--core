#!/bin/bash
# ==============================================================
# batch.sh — X 内核 全协议一键生成 (Batch Generator)
# 设计思想对齐 sing-box-core 的 src/conf/batch.sh (Batch = Orchestrator):
#   * 不重新实现任何协议: 逐个调用现有 conf/<proto>.sh 的 add_config 流程
#   * 批量上下文: X_BATCH=1 (协议脚本问询走各自默认"最高配置") +
#                 X_BATCH_PORT_START/END (批量连续端口分配, 游标在 conf/.batch-ports)
#   * 幂等: conf/<proto>-NN.json 已存在 → 该协议跳过
#   * 失败隔离: 每个协议独立执行, 单协议失败不影响后续, 汇总时明确列出
#   * 统一验证+reload: 全部生成 → 复用 conf/verify.sh check → 通过后仅 reload 一次
#     (协议脚本本身从不 reload; reload 语义只属于 Batch 收尾)
#   * 复用输出: 节点信息 / 分享链接全部来自各协议脚本产出的 out/*-share-*.txt
# 批量协议列表(需新增协议时在此登记, 须与 conf/ 下脚本和其 PROTO 碎片名一一对应):
#   PROTO_LIST          -> conf/<name>.sh
#   PROTO_FRAGMENT_PFX  -> 该协议服务端碎片 conf/<pfx>-NN.json (幂等判断用)
# 注: 当前 OpenX 支持的全部交互式协议中, Argo 类(tunnel/固定/临时)依赖隧道交互流程,
#     SOCKS5/HTTP/VLESS 等裸协议按需由用户单发; Batch 默认只编排 4 个"最高配置"安全协议
# ==============================================================
set -u

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; MAGENTA="\e[35m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"
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
clean_input() { echo "$1" | tr -d '\000-\037'; }

GH_RAW="${X_BATCH_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}"

# 协议登记表: 批量协议脚本名 | 服务端碎片前缀(幂等判断) | 展示名
BATCH_PROTOS=(Reality Trojan Shadowsocks hysteria2)
BATCH_FRAG_PREFIX=(reality trojan ss2022 hysteria)

XRAY_BASE="${XRAY_BASE_DIR:-/root/catmi/xray}"
X_IS_SANDBOX=false
[[ "${XRAY_BASE_DIR:-/root/catmi/xray}" != "/root/catmi/xray" ]] && X_IS_SANDBOX=true
CONF_DIR="$XRAY_BASE/conf"
OUT_DIR="$XRAY_BASE/out"
LOG_DIR="${X_BATCH_LOG_DIR:-/tmp}"

########## 脚本目录解析 ##########
# 就近使用 batch.sh 同目录下的协议脚本 (仓库内/服务器临时部署);
# 否则(curl|bash 场景)从 GitHub 下载到临时目录再执行, 与面板其余选项一致
SCRIPT_DIR=""
resolve_scripts_dir() {
    local here
    here="$(dirname "${BASH_SOURCE[0]:-$0}")"
    if [[ -f "$here/Reality.sh" && -f "$here/Trojan.sh" ]]; then
        SCRIPT_DIR="$here"
        return 0
    fi
    local tmp="${X_BATCH_TMP_DIR:-/tmp/x-batch-scripts}"
    mkdir -p "$tmp"
    local f
    for f in "${BATCH_PROTOS[@]}"; do
        if [[ ! -s "$tmp/$f.sh" ]]; then
            curl -fsSL "$GH_RAW/conf/$f.sh" -o "$tmp/$f.sh" \
                || { print_error "下载 conf/$f.sh 失败"; return 1; }
            bash -n "$tmp/$f.sh" || { print_error "conf/$f.sh 语法错误(下载损坏)"; return 1; }
        fi
    done
    SCRIPT_DIR="$tmp"
    return 0
}

resolve_verify_sh() {
    if [[ -f "$XRAY_BASE/verify.sh" ]]; then echo "$XRAY_BASE/verify.sh"; return 0; fi
    local here
    here="$(dirname "${BASH_SOURCE[0]:-$0}")"
    if [[ -f "$here/verify.sh" ]]; then echo "$here/verify.sh"; return 0; fi
    local tmp="${X_BATCH_TMP_DIR:-/tmp/x-batch-scripts}/verify.sh"
    curl -fsSL "$GH_RAW/conf/verify.sh" -o "$tmp" 2>/dev/null || { print_error "下载 conf/verify.sh 失败"; return 1; }
    echo "$tmp"
}

fragment_prefix() {
    local i
    for i in "${!BATCH_PROTOS[@]}"; do
        [[ "${BATCH_PROTOS[$i]}" == "$1" ]] && { echo "${BATCH_FRAG_PREFIX[$i]}"; return; }
    done
    echo "$1"
}

latest_fragment() { ls "$CONF_DIR""/$(fragment_prefix "$1")"-*.json 2>/dev/null | sort | tail -1; }

########## 备份 ##########
backup_conf_out() {
    local ts tarball
    ts=$(date +%Y%m%d-%H%M%S)
    tarball="$XRAY_BASE/conf-backup-batch-$ts.tar.gz"
    tar czf "$tarball" -C "$XRAY_BASE" conf out 2>/dev/null || true
    [[ -f "$tarball" ]] && print_info "已备份 conf/out → $tarball"
}

########## 交互: 分级, 按需才问 ##########
# ★ 借鉴 SB 的 batch 设计, 但**不照抄它的项数**:
#   SB 有 5 组交互。这里只加 2 组 (服务器标识 / 证书思路), 端口范围保留。
#
#   加的依据是"不问会后悔"还是"不问无所谓":
#     · 端口范围 —— 不问就得挨个进协议菜单改十几轮, 值得问 (原来就有)
#     · 服务器标识 —— 不问会在多台机器上撞 tag, 是真 bug, 值得问
#     · 监听地址 / 伪装目标 / 每个协议的密码 UUID —— 程序能自己算或用户改起来
#       不费事, 问了纯粹增加输入负担。SB 把监听地址也不问掉, 正是这个道理:
#       "没有理由让用户为一个更差的选项做选择。"
#
#   开场先把"会问什么、失败了会怎样"说清楚 —— 用户能据此决定是逐项问
#   还是走快速模式, 而不是被一堆问句淹没。
ask_port_range() {
    local r
    echo >&2
    printf "${CYAN}接下来问端口范围。其余全部沿用各协议默认值（最高配置，自动生成密码/UUID/PSK/Reality 伪装域名）。${RESET}\n" >&2
    printf "${CYAN}批内多协议端口自动连续分配，收尾统一 check + 仅 reload 一次。${RESET}\n" >&2
    read -r -p "端口范围 (如 20000-25000, 回车=自动选择): " r >&2
    r=$(clean_input "$r")
    choose_port_range "$r"
}

# 一次问完 (逐项模式)。顺序与 SB 一致: 标识 → 端口。
ask_all() {
    print_title "批量生成 · 逐项确认"
    printf "${CYAN}交互项: 服务器标识 → 端口范围。其余沿用各协议默认值。${RESET}\n" >&2
    printf "${CYAN}端口被占用或配置失败会自动跳过该协议并写日志；收尾统一 check + 仅 reload 一次。${RESET}\n" >&2
    ask_server_name
    ask_port_range
}

choose_port_range() {
    local r="$1"
    if [[ -z "$r" ]]; then
        # 随机起点 + 2000 宽。随机是为了让多台机器/多批次分布不同,
        # 撞车概率比固定 20000 起低。
        X_BATCH_PORT_START=$(( 20000 + RANDOM % 20000 ))
        X_BATCH_PORT_END=$(( X_BATCH_PORT_START + 2000 ))
    elif [[ "$r" =~ ^[0-9]+$ ]]; then
        # 只给起点 -> 往后 2000 个
        X_BATCH_PORT_START="$r"
        X_BATCH_PORT_END=$(( r + 2000 ))
    elif [[ "$r" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        X_BATCH_PORT_START="${BASH_REMATCH[1]}"
        X_BATCH_PORT_END="${BASH_REMATCH[2]}"
    else
        print_error "无法识别: $r  (格式: 20000-25000, 或只写起点 30000)" >&2
        return 1
    fi
    # 用户可能写成 25000-20000
    if (( X_BATCH_PORT_END < X_BATCH_PORT_START )); then
        local t=$X_BATCH_PORT_START
        X_BATCH_PORT_START=$X_BATCH_PORT_END
        X_BATCH_PORT_END=$t
    fi
    # 两端都要钳 —— 只钳 END 会出现 99999-65535 这种倒挂区间,
    # 区间循环一次都不进, 于是悄悄回落到随机端口, 用户选什么都是随机。
    if (( X_BATCH_PORT_START < 1 ));      then X_BATCH_PORT_START=1; fi
    if (( X_BATCH_PORT_START > 65535 ));   then X_BATCH_PORT_START=65535; fi
    if (( X_BATCH_PORT_END   > 65535 ));   then X_BATCH_PORT_END=65535; fi
    if (( X_BATCH_PORT_END   < X_BATCH_PORT_START )); then X_BATCH_PORT_END=65535; fi
    # 回显实际选中的结果。只说"回车=自动"而不回显, 用户不知道到底挑了哪段
    # —— 而这段区间后面要写进防火墙规则, 是要能对得上的。
    print_ok "批量端口区间: $X_BATCH_PORT_START - $X_BATCH_PORT_END" \
             "($(( X_BATCH_PORT_END - X_BATCH_PORT_START + 1 )) 个, 每个节点一个)" >&2
    return 0
}

########## 为什么没生成节点 ##########
# ★ "有结果但不理想"的时候, 把前置条件讲出来 —— 借鉴 SB 的 CDN 汇总。
#   只打一行「无节点」的话, 用户只能自己去翻日志猜。
_no_node_reason() {
    local proto="$1" frag="$2" pf
    pf=$(fragment_prefix "$proto")
    if [[ -n "$frag" ]] || ls "$CONF_DIR"/"$pf"-*.json >/dev/null 2>&1; then
        return 0        # 其实有碎片, 上面那行只是没匹配到排序, 不用多说
    fi
    case "$proto" in
        Reality)
            printf "     %s提示%s REALITY 需要一个可连的伪装目标域名, 且服务端要有 X25519/ML-DSA 密钥对。\n" "$CYAN" "$RESET" >&2 ;;
        hysteria2)
            printf "     %s提示%s Hysteria2 走 UDP, 需要一张可信证书; 证书缺失或端口被占用都会失败。\n" "$CYAN" "$RESET" >&2 ;;
        *)
            printf "     %s提示%s 端口 %s-%s 可能已被占用, 或该协议默认凭据生成失败。\n" \
                "$CYAN" "$RESET" "${X_BATCH_PORT_START:-?}" "${X_BATCH_PORT_END:-?}" >&2 ;;
    esac
}

BATCH_OK=(); BATCH_SKIP=(); BATCH_FAIL=()

# ★ timeout 不是所有精简系统都装 (busybox 有, 但极少见的裁剪镜像没有)。
#   没有就退化成直接调用, 不能因为缺个 coreutils 工具就让整批跑不了。
BATCH_PROTO_TIMEOUT="${X_BATCH_PROTO_TIMEOUT:-240}"
if ! command -v timeout >/dev/null 2>&1; then
    BATCH_PROTO_TIMEOUT=""
    print_info "系统没有 timeout, 单协议不再限时 (脚本本身已用 </dev/null 防止等待输入)"
fi

########## 服务器标识 ##########
# ★ 为什么单独问一次 (借鉴 SB):
#   各协议是独立子进程 (`bash conf/<proto>.sh add`), 子进程里问的东西
#   传不回主进程, 而节点名前缀是要给**所有**协议用的。所以只能在这里问一遍,
#   再通过环境变量传下去。
#   不问的后果: 同一个人两台服务器各跑一次批量, 产出的 tag 完全一样
#   (x-vless01-tls), 两个订阅导进同一个客户端会互相覆盖, 面板还报 [OK]。
_bt_server_name() {
    local n="${X_SERVER_NAME:-}"
    if [[ -z "$n" && -r "$XRAY_BASE/.server-name" ]]; then
        n=$(head -1 "$XRAY_BASE/.server-name" 2>/dev/null | tr -d '[:space:]')
    fi
    printf '%s' "$n"
}

ask_server_name() {
    local cur; cur=$(_bt_server_name)
    local def="${cur:-$(hostname 2>/dev/null || echo server)}"
    echo >&2
    printf "${CYAN}服务器标识: 会写进每个节点的 tag 与分享链接名。${RESET}\n" >&2
    printf "${DIM}  同一个人在多台服务器上跑批量时, 它能防止两个订阅在同一个客户端里互相覆盖。${RESET}\n" >&2
    local n
    read -r -p "  服务器标识 [回车=$def]: " n || n=""
    n=$(clean_input "${n:-}")
    n="${n:-$def}"
    X_SERVER_NAME="$n"
    mkdir -p "$XRAY_BASE" 2>/dev/null || true
    printf '%s\n' "$n" > "$XRAY_BASE/.server-name" 2>/dev/null || true
    print_ok "服务器标识: $n"
}

# 清掉本协议已有的服务端碎片 —— 重建模式用。
wipe_proto() {
    local pfx f n=0
    pfx=$(fragment_prefix "$1")
    for f in "$CONF_DIR"/"$pfx"-*.json; do
        [[ -e "$f" ]] || continue
        rm -f "$f" && n=$((n+1))
    done
    printf '%s' "$n"
}

# 列出将被清掉的节点碎片, 让用户先看见再决定。
list_will_wipe() {
    local pfx f
    for pfx in "${BATCH_FRAG_PREFIX[@]}"; do
        for f in "$CONF_DIR"/"$pfx"-*.json; do
            [[ -e "$f" ]] && printf "    %s\n" "$(basename "$f")"
        done
    done
}

########## 主流程 ##########
batch_main() {
    mkdir -p "$CONF_DIR" "$OUT_DIR" "$LOG_DIR"
    resolve_scripts_dir || return 1

    print_title "X 内核 全协议一键生成"

    backup_conf_out
    rm -f "$CONF_DIR/.batch-ports"

    # 每协议: 已有节点 → 跳过(幂等); 否则 X_BATCH=1 调用现有协议脚本
    local proto frag file
    local -a ok_list=() skip_list=() fail_list=() new_files_before=()
    new_files_before=("$CONF_DIR"/*.json)

    echo >&2
    print_title "批量生成开始"
    for proto in "${BATCH_PROTOS[@]}"; do
        printf "${CYAN}• %-12s${RESET} " "$proto" >&2
        if [[ -n "$(latest_fragment "$proto")" ]]; then
            printf "${YELLOW}[已存在]${RESET} 跳过 (幂等)\n" >&2
            skip_list+=("$proto") && BATCH_SKIP+=("$proto")
            continue
        fi
        # ★ 必须加 timeout —— 协议脚本内部有 read, 万一 </dev/null 没生效
        #   (某些 wrapper 会把 stdin 接回 tty) 就挂死, 一个协议能拖死整批。
        #   借鉴 SB: 每协议子进程 timeout 240。
        X_BATCH=1 X_NO_RELOAD=1 SB_BATCH=1 \
        X_BATCH_PORT_START="${X_BATCH_PORT_START:-}" X_BATCH_PORT_END="${X_BATCH_PORT_END:-}" \
            timeout "$BATCH_PROTO_TIMEOUT" bash "$SCRIPT_DIR/$proto.sh" add </dev/null \
            >"$LOG_DIR/x-batch-$proto.log" 2>&1
        local rc=$?
        if [[ $rc -eq 0 ]]; then
            printf "${GREEN}[OK]${RESET} 生成\n" >&2
            ok_list+=("$proto") && BATCH_OK+=("$proto")
        else
            printf "${RED}[失败]${RESET} (详见 $LOG_DIR/x-batch-$proto.log)\n" >&2
            fail_list+=("$proto") && BATCH_FAIL+=("$proto")
        fi
    done

    # 本批新生成的服务端碎片(收尾失败清理用)
    local -a new_files=() f
    for f in "$CONF_DIR"/*.json; do
        local old
        for old in "${new_files_before[@]}"; do
            [[ "$old" == "$f" ]] && continue 2
        done
        new_files+=("$f")
    done

    # ---- 统一验证 (复用 conf/verify.sh 的 check, 不自行假设检查命令) ----
    echo >&2
    print_title "统一配置校验"
    local verify_sh
    verify_sh=$(resolve_verify_sh) || return 1

    local check_ok=false
    if VERIFY_INSTALL_DIR="$XRAY_BASE" bash "$verify_sh" check; then
        check_ok=true
    fi

    if [[ "$check_ok" != "true" ]]; then
        # 只回滚本批新增碎片, 不动既有节点; 协议脚本自身在生成时已做过单文件 -test
        print_error "统一校验失败，回滚本批新增节点碎片（原有节点不动）"
        local nf
        for nf in "${new_files[@]}"; do
            print_warn "回滚: $nf"
            rm -f "$nf"
        done
        rm -f "$CONF_DIR/.batch-ports"
        if VERIFY_INSTALL_DIR="$XRAY_BASE" bash "$verify_sh" check >/dev/null 2>&1; then
            print_ok "回滚后配置恢复可用"
        else
            print_error "回滚后统一校验仍失败，请用菜单「校验配置/重启服务」人工处理"
        fi
        batch_summary false
        return 1
    fi

    # ---- 仅一次统一 reload (非沙箱 XRAY_BASE_DIR 才操作 systemd) ----
    local reloaded=false
    if [[ "$X_IS_SANDBOX" != "true" && "${X_BATCH_TEST_SKIP_RESTART:-0}" != "1" ]]; then
        echo >&2
        print_title "统一重启 xrayls (仅此一次)"
        if bash "$verify_sh" restart; then
            reloaded=true
        fi
        systemctl is-active xrayls.service >/dev/null 2>&1 \
            && print_ok "xrayls 服务状态: active (运行中)" \
            || print_error "xrayls 服务状态异常, 请检查 journalctl -u xrayls"
    else
        print_info "沙箱/测试模式 (XRAY_BASE_DIR=$XRAY_BASE): 只校验不重启 systemd 服务"
        print_info "正式 reload: 请在正式环境重新执行 batch (或运行 verify.sh restart)"
    fi

    batch_summary "$reloaded"
    # ★ 失败必须以非零退出码收尾 —— 这是"一键全协议"最重要的一条契约。
    #
    #   原来这里无条件 return 0: SS2022 因为 gen_psk 未定义生成失败, 汇总里
    #   老老实实印着 [失败], 但脚本退出码是 0。任何自动化(面板、install.sh、
    #   CI、`bash batch.sh --auto && 下一步`)都把这一批当成成功 ——
    #   "四个协议里少了一个"要等到用户导入客户端才发现。
    #   失败清单在 batch_summary 里已经逐条打印(含日志末尾 3 行), 这里只补退出码。
    if ((${#fail_list[@]} > 0)); then
        print_error "本批有 ${#fail_list[@]} 个协议失败: ${fail_list[*]} —— 退出码 1"
        print_info "失败详情: $LOG_DIR/x-batch-<协议>.log"
        return 1
    fi
    print_ok "全协议一键生成流程结束"
    return 0
}

########## 统一输出 (复用各协议已有产物, 不重造第二套格式) ##########
batch_summary() {
    local reloaded="${1:-false}"
    local -a ok_list=("${BATCH_OK[@]}") skip_list=("${BATCH_SKIP[@]}") fail_list=("${BATCH_FAIL[@]}")
    local proto frag num port tag share
    echo >&2
    print_title "全协议生成完成 · 汇总"
    for proto in "${BATCH_PROTOS[@]}"; do
        frag=$(latest_fragment "$proto")
        if [[ -z "$frag" ]]; then
            printf " ✗ %-14s (无节点; 失败详情见 $LOG_DIR/x-batch-%s.log)\n" "$proto" "$proto" >&2
            _no_node_reason "$proto" "$frag"
            continue
        fi
        num=$(basename "$frag" | sed -E "s/^$(fragment_prefix "$proto")-([0-9]+)\.json$/\1/")
        port=$(jq -r '.inbounds[0].port' "$frag" 2>/dev/null)
        tag=$(jq -r '.inbounds[0].tag' "$frag" 2>/dev/null)
        # ★ 形态**从生成的 JSON 里读回来**, 而不是从"我以为生成了什么"推断 ——
        #   面板说的 ≠ 实际写进文件的, 是这类面板最难查的一类 bug。
        local form
        form=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$frag" 2>/dev/null)
        local net
        net=$(jq -r '.inbounds[0].streamSettings.network // "raw"' "$frag" 2>/dev/null)
        printf " ✓ %-14s 编号=%-3s 端口=%-6s Tag=%-18s %s/%s\n" \
            "$proto" "$num" "$port" "$tag" "$net" "$form" >&2
        # REALITY 公钥 / ShortID 是用户配客户端唯一要手抄的东西, 必须打出来;
        # 密码截断显示, 不全打 (日志里已经有了, 刷屏没意义)。
        local pk sid pw
        pk=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey // empty' "$frag" 2>/dev/null)
        sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortId // empty' "$frag" 2>/dev/null)
        [[ -n "$pk" ]] && printf "     Reality 公钥=%s\n" "${pk:0:12}…  ShortID=${sid:-无}" >&2
        pw=$(jq -r '.inbounds[0].settings.clients[0].password // empty' "$frag" 2>/dev/null)
        [[ -n "$pw" ]] && printf "     password=%.24s…\n" "$pw" >&2
        # 分享链接直接读取协议脚本生成的现有文件
        local pre share
        pre="$(fragment_prefix "$proto")"
        case "$proto" in
            hysteria2) share="$OUT_DIR/hy2_share-$num.txt" ;;
            *)         share="$OUT_DIR/$pre-share-$num.txt" ;;
        esac
        [[ -f "$share" ]] && sed 's/^/     /' "$share" >&2
    done
    echo >&2
    ((${#ok_list[@]}   > 0)) && printf "${GREEN}生成成功: %s${RESET}\n" "${ok_list[*]}" >&2
    ((${#skip_list[@]} > 0)) && printf "${YELLOW}已存在(跳过): %s${RESET}\n" "${skip_list[*]}" >&2
    ((${#fail_list[@]} > 0)) && {
        printf "${RED}失败(详情在日志末尾): %s${RESET}\n" "${fail_list[*]}" >&2
        local p
        for p in "${fail_list[@]}"; do
            echo "  --- $p ---" >&2
            tail -3 "$LOG_DIR/x-batch-$p.log" 2>/dev/null >&2
        done
    }
    [[ "$reloaded" == "true" ]] || print_info "服务未重启/沙箱模式: 配置已校验, reload 需在正式目录执行 batch 或手动 verify"
}

########## 清空全部节点 (破坏性) ##########
# ★ 破坏性操作的三段式 (借鉴 SB):
#   1) 先把**要删什么逐条列出来** —— 用户看着文件名才能判断"里面有没有我
#      手写的东西"。只说"将删除 8 个节点"是不够的。
#   2) 明说**保留什么** —— 否则用户会怕连基础配置一起没了而不敢确认。
#   3) 必须输入 yes, 提示语自带"其它任何输入=取消"。
clear_all_nodes() {
    print_title "清空全部节点"
    local n; n=$(list_will_wipe | wc -l)
    if [[ "$n" -eq 0 ]]; then
        print_info "本来就没有节点, 没什么可清"
        return 0
    fi
    printf "${RED}将删除以下 %d 个服务端碎片:${RESET}\n" "$n" >&2
    list_will_wipe >&2
    echo >&2
    printf "${DIM}会保留: 00-base.json 等基础骨架、出站、路由、证书。${RESET}\n" >&2
    printf "${DIM}会删除: 上面这些节点碎片, 以及它们的分享链接会随之失效。${RESET}\n" >&2
    printf "${DIM}之后可以随时用 1) 重新一键生成。${RESET}\n\n" >&2

    local w
    read -r -p "确认清空? 输入 yes (其它任何输入=取消): " w || { echo; return 0; }
    if [[ "$(clean_input "$w")" != "yes" ]]; then
        print_warn "已取消, 未做任何改动"
        return 0
    fi
    local p del=0
    for p in "${BATCH_PROTOS[@]}"; do
        del=$(( del + $(wipe_proto "$p") ))
    done
    print_ok "已删除 $del 个节点碎片 (conf/out 已备份, 分享令牌需手动重建)"
    return 0
}

# 重建 = 先确认再删本协议已有碎片, 然后正常跑一遍。
rebuild_all() {
    print_title "全协议重建 · 将覆盖已有节点"
    local n; n=$(list_will_wipe | wc -l)
    if [[ "$n" -eq 0 ]]; then
        print_info "没有已有节点, 直接生成即可"
        return 1
    fi
    printf "${YELLOW}将先删除以下 %d 个已有节点碎片, 再重新生成 (端口/UUID/密码都会换新的):${RESET}\n" "$n" >&2
    list_will_wipe >&2
    echo >&2
    printf "${DIM}REALITY 长期密钥对、证书、基础骨架保留不动。${RESET}\n" >&2
    printf "${DIM}已发出的分享链接会立即失效 —— 重建后需要重新分发。${RESET}\n\n" >&2
    local w
    read -r -p "确认重建? 输入 yes (其它任何输入=取消): " w || { echo; return 1; }
    [[ "$(clean_input "$w")" == "yes" ]] || { print_warn "已取消"; return 1; }
    local p
    for p in "${BATCH_PROTOS[@]}"; do wipe_proto "$p" >/dev/null; done
    print_ok "已清掉旧节点, 开始重新生成"
    return 0
}

########## 入口 ##########
main() {
    if [[ "${1:-}" == "--auto" ]]; then
        : $(( X_BATCH_PORT_START = 20000 + RANDOM % 20000 ))
        : $(( X_BATCH_PORT_END = X_BATCH_PORT_START + 2000 ))
        X_SERVER_NAME=$(_bt_server_name)
        batch_main
        return $?
    fi
    while true; do
        print_title "全协议一键生成 (Batch Generator)"
        echo -e "${CYAN}协议:${RESET} Reality / Trojan / SS2022 / Hysteria2"
        echo -e "${CYAN}1)${RESET} 全协议生成      ${DIM}逐项确认 (服务器标识 + 端口范围)${RESET}"
        echo -e "${CYAN}2)${RESET} 全协议快速生成  ${DIM}只问端口范围${RESET}"
        echo -e "${CYAN}3)${RESET} 全协议重建      ${YELLOW}强制覆盖已有节点 (端口/UUID 会换新)${RESET}"
        echo -e "${CYAN}4)${RESET} 清空全部节点    ${RED}(破坏性)${RESET}"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请输入选项 [0-4]: " c || { echo; exit 0; }
        c=$(clean_input "$c")
        case "$c" in
            1) ask_all && batch_main ;;
            2) X_SERVER_NAME=$(_bt_server_name); ask_port_range && batch_main ;;
            3) if rebuild_all; then X_SERVER_NAME=$(_bt_server_name); ask_port_range && batch_main; fi ;;
            4) clear_all_nodes ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        [[ "$c" == "0" ]] || { read -r -p "按回车键返回..." _ || { echo; exit 0; }; }
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
