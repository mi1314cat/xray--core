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
# DIM 之前漏在这里定义, 而下面 "${DIM}逐项确认…" 用到它。
# 后果不是"颜色没上" —— 脚本带 set -u, 未定义变量会直接终止:
#   batch.sh: line 585: DIM: unbound variable
# 于是用户点进「全协议一键生成」**当场报错**, 菜单都还没画出来。
# 这正是"一进去就报错"最典型的一种: 逻辑没走错, 是变量名对不上。
DIM="\e[2m"
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

# ★ 变量名是 XRAY_BASE_DIR, **不是** XRAY_BASE
#
#   之前这里只认 XRAY_BASE_DIR —— 于是外面
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
# ★ 必须 export: 各协议是 `bash conf/<proto>.sh add` 独立**子进程**, 靠继承
#   拿这个值。上面这行只是在本进程里赋值 —— 本进程里它是 shell 变量;
#   调用方若没 export 过, 子进程就什么也收不到, 然后各自回落生产目录。
export XRAY_BASE
# 沙箱标志: 两个变量任意一个指离生产就算沙箱
X_IS_SANDBOX=false
# 判定要跟着**真正生效的那个目录**走: 只给 XRAY_CONF_DIR 时 XRAY_BASE
# 仍是生产值, 但写的已经不是生产目录了 —— 那种情况必须也算沙箱,
# 否则"配置写到别处、systemd 照样重启生产服务"。
[[ "$XRAY_BASE" != /root/catmi/xray || "$CONF_DIR" != /root/catmi/xray/conf ]] \
    && X_IS_SANDBOX=true
CONF_DIR="${_XRAY_CONF_OVERRIDE:-$XRAY_BASE/conf}"
OUT_DIR="${_XRAY_OUT_OVERRIDE:-$XRAY_BASE/out}"
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
    # ★ 下载之后必须**照着仓库的目录形状**摆, 不能平铺。
    #
    #   协议脚本与 tools/ 下的脚本都是按**相对自身**的位置找同伴的:
    #       Reality.sh     → $(dirname $0)/lib/proto_ui.sh
    #       preset_batch.sh→ $(dirname $0)/cdn_auto.sh 与 ../conf/lib/*.py
    #   所以布局必须是
    #       $tmp/conf/<协议>.sh   $tmp/conf/lib/*   $tmp/tools/<工具>.sh
    #   而 SCRIPT_DIR 指向 $tmp/conf —— 这样上面那些相对路径才成立。
    #
    #   平铺过一版, 结果是**真实安装上两条腿同时瘸**, 而且症状都不像"路径问题":
    #     · Reality: 日志一行"缺少 conf/lib/proto_ui.sh" → 只有它失败;
    #     · 上下行分离: "bash: /tmp/x-batch-scripts/../tools/preset_batch.sh:
    #       No such file or directory" → 三个组合一个都没有。
    #   从**仓库检出目录**跑永远看不到 (那边 conf/ 与 tools/ 本来就在位),
    #   所以开发时一路绿灯。
    local tmp="${X_BATCH_TMP_DIR:-/tmp/x-batch-scripts}"
    local confdir="$tmp/conf" tooldir="$tmp/tools"
    mkdir -p "$confdir/lib" "$tooldir"
    local f
    for f in "${BATCH_PROTOS[@]}"; do
        if [[ ! -s "$confdir/$f.sh" ]]; then
            curl -fsSL "$GH_RAW/conf/$f.sh" -o "$confdir/$f.sh" \
                || { print_error "下载 conf/$f.sh 失败"; return 1; }
            bash -n "$confdir/$f.sh" || { print_error "conf/$f.sh 语法错误(下载损坏)"; return 1; }
        fi
    done

    # 共用层。两类都在这里:
    #   · 协议脚本按 dirname($0)/lib/ 找的 .sh (找不到时批处理模式直接拒绝继续);
    #   · preset_batch.sh → deploy.py 这条链要的 .py。
    #     ★ .py 必须**整组一起下到同一个目录**: deploy.py 里是
    #       `import node_build` / `import to_mihomo` / `import nodes`,
    #       而 preset_batch.sh 的 _lib 是**逐个下到临时文件**的
    #       (/tmp/deploy.py.XXXXXX) —— 那样 sys.path[0] 是 /tmp,
    #       兄弟模块一个都 import 不到, 报的是
    #           ModuleNotFoundError: No module named 'node_build'
    #       从仓库检出目录跑不会出现 (conf/lib/ 本来就在一起)。
    #       实测症状: 全协议里「xHTTP 上下行分离」两个组合全失败, 而日志里
    #       是一段 Python traceback, 看起来像代码坏了, 其实是文件没摆在一起。
    local l
    for l in proto_ui.sh ports.sh addr.sh preset.sh \
             deploy.py node_build.py to_mihomo.py nodes.py share_meta.py \
             naming.py nginx_apply.py; do
        if [[ ! -s "$confdir/lib/$l" ]]; then
            curl -fsSL "$GH_RAW/conf/lib/$l" -o "$confdir/lib/$l" \
                || { print_error "下载 conf/lib/$l 失败 (协议脚本的共用层)"; return 1; }
            bash -n "$confdir/lib/$l" || { print_error "conf/lib/$l 语法错误(下载损坏)"; return 1; }
        fi
    done

    # 上下行分离走 preset_batch.sh; 它又会按 dirname($0)/cdn_auto.sh 找同伴
    local t
    for t in preset_batch.sh cdn_auto.sh; do
        if [[ ! -s "$tooldir/$t" ]]; then
            curl -fsSL "$GH_RAW/tools/$t" -o "$tooldir/$t" \
                || { print_error "下载 tools/$t 失败 (上下行分离要用)"; return 1; }
            bash -n "$tooldir/$t" || { print_error "tools/$t 语法错误(下载损坏)"; return 1; }
        fi
    done

    # 组装写的是 SCRIPT_DIR/../tools/... , 所以 SCRIPT_DIR 必须是 conf/ 那一层
    SCRIPT_DIR="$confdir"
    return 0
}

# ---------------------------------------------------------- CDN 自动配置
# cdn_auto.sh 与 preset_batch.sh 同目录 (tools/)。
#
# ★ 这里原来**完全没加载它** —— 于是"建完节点顺手配 nginx"这件事在全协议
#   一键生成里根本不存在: `declare -F x_cdn_autosetup` 永远为假。
#   加载失败必须**看得见**(打印告警), 因为"没配上"和"根本没尝试"
#   在屏幕上一模一样 —— 这正是本项目既往缺陷最常见的形态。
_BATCH_CDN_AUTO=""
resolve_cdn_auto() {
    local here f
    here="$(dirname "${BASH_SOURCE[0]:-$0}")"
    for f in "$here/../tools/cdn_auto.sh" "$here/cdn_auto.sh" \
             "$XRAY_BASE/../tools/cdn_auto.sh"; do
        [[ -r "$f" ]] && { _BATCH_CDN_AUTO="$f"; return 0; }
    done
    local tmp="${X_BATCH_TMP_DIR:-/tmp/x-batch-scripts}/cdn_auto.sh"
    mkdir -p "$(dirname "$tmp")"
    curl -fsSL "$GH_RAW/tools/cdn_auto.sh" -o "$tmp" 2>/dev/null \
        && [[ -s "$tmp" ]] && { _BATCH_CDN_AUTO="$tmp"; return 0; }
    return 1
}
if resolve_cdn_auto; then
    # shellcheck source=/dev/null
    source "$_BATCH_CDN_AUTO"
    declare -F x_cdn_autosetup >/dev/null 2>&1 \
        || print_warn "cdn_auto.sh 加载了但函数不在 (版本不匹配?) —— nginx 不会自动配置"
else
    print_warn "找不到 tools/cdn_auto.sh —— nginx 反代不会自动配置"
fi

resolve_share_sh() {
    local here f
    here="$(dirname "${BASH_SOURCE[0]:-$0}")"
    for f in "$here/share.sh" "$XRAY_BASE/../conf/share.sh"; do
        [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    local tmp="${X_BATCH_TMP_DIR:-/tmp/x-batch-scripts}/share.sh"
    mkdir -p "$(dirname "$tmp")"
    curl -fsSL "$GH_RAW/conf/share.sh" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]] \
        && { printf '%s' "$tmp"; return 0; }
    return 1
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
    # 读取顺序: 环境变量 → 上次答过的 → conf/lib/naming.py 的默认值 (旗帜+hostname)
    local n="${X_SERVER_NAME:-}"
    if [[ -z "$n" && -r "$XRAY_BASE/.server-name" ]]; then
        n=$(head -1 "$XRAY_BASE/.server-name" 2>/dev/null | tr -d '[:space:]')
    fi
    if [[ -z "$n" ]]; then
        n=$(XRAY_BASE="${XRAY_BASE}" python3 "$CONF_DIR/lib/naming.py" default 2>/dev/null) || n=""
        [[ -z "$n" ]] && n=$(hostname 2>/dev/null || echo "")
    fi
    printf '%s' "$n"
}

# ★ 一律问, 回车即默认 (对齐 SB 的 sb_ask_server_name)。
#
#   原来这里只在 batch.sh 自己问一次, 而命名权威在 conf/lib/naming.py ——
#   于是同一个"服务器标识"有两套落盘位置 (本函数的 .server-name 与
#   naming.py 的 NAME_CACHE), 两边可能答得不一样, 单协议建的节点用 A、
#   批量建的用 B, 同一个客户端里前缀忽有忽无。
#   现在两边都以 naming.py 为准。
ask_server_name() {
    local cur def n
    cur=$(_bt_server_name)
    def="${cur:-server}"
    echo >&2
    printf "${CYAN}服务器标识 (节点名前缀)。${RESET}\n" >&2
    printf "${DIM}  同一个人在多台服务器上各跑一份, 客户端里靠它区分; 默认值是 旗帜+主机名。${RESET}\n" >&2
    printf "${DIM}  只影响分享链接里给人看的名字, 节点 tag 不变 —— 所以改它随时可以。${RESET}\n" >&2
    read -r -p "  服务器标识 [回车=$def]: " n || n=""
    n=$(clean_input "${n:-}")
    n="${n:-$def}"
    # 走 naming.py 落盘, 与单协议建节点共用同一份缓存 (含"补旗帜"逻辑:
    # 用户只输入短名字时, 旗帜是**服务器的属性**, 不该由改名这个动作弄丢)
    local via_py
    via_py=$(XRAY_BASE="${XRAY_BASE}" python3 "$CONF_DIR/lib/naming.py" set "$n" 2>/dev/null) || via_py=""
    [[ -n "$via_py" ]] && n="$via_py"
    X_SERVER_NAME="$n"
    export X_SERVER_NAME XRAY_SERVER_NAME="$n"
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

    # ---------------------------------------------------- 上下行分离 (xHTTP)
    #
    # ★ 用户要求: "全协议脚本里面一定要有这个"。
    #
    #   全协议 = 全**传输与加密形态**, 少了上下行分离这一类就名不副实 ——
    #   它是 X 内核这代最有价值的能力之一, 而且是三个内核里我们独有的
    #   (SB/M 那边没有 xHTTP 上下行分离这个形态)。
    #
    #   三个组合 (用户点的):
    #     split:cdn-cdn      上行 CDN + 下行 CDN      (ECH 默认开)
    #     split:cdn-reality  上行 CDN + 下行 REALITY  (ECH 默认开)
    #     split:reality-cdn  上行 REALITY + 下行 CDN
    #
    #   走 preset_batch.sh 而不是各协议脚本: 分离模式要 dl_* 一整套参数,
    #   各协议脚本的 add 入口接不住, 而 preset_batch.sh 已经是它们的统一
    #   入口 (借鉴 SB: 批量走统一入口, 别每处自己拼一遍)。
    #
    #   域名: 上下行共用 X_BATCH_DOMAIN 是**正常用法**, 不是缺配置 ——
    #   上下行照样分开, 只是同一个入口。两个域名由 X_BATCH_DL_DOMAIN 给。
    # preset.sh 里有分离模式表, 而 batch.sh **没加载它** —— 被面板 source
    # 时可能碰巧已经在了, 单独 `bash conf/batch.sh --auto` 时一定不在。
    # 跟下面 cert.sh 一样的处理: 按需补载, 加载不了就**说清楚**, 不静默跳过
    # (静默跳过的话"全协议"里就悄悄少了三个组合, 而汇总照样显示成功)。
    if [[ "${X_BATCH_SPLIT:-1}" == "1" ]] && ! declare -F x_split_modes >/dev/null 2>&1; then
        local _sdir _sf
        _sdir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
        for _sf in "$_sdir/lib/preset.sh" "$_sdir/preset.sh"; do
            [[ -r "$_sf" ]] && { source "$_sf"; break; }
        done
        if ! declare -F x_split_modes >/dev/null 2>&1; then
            print_warn "读不到分离模式表 (lib/preset.sh), 跳过 xHTTP 上下行分离"
            print_warn "  用 X_BATCH_SPLIT=0 可以确定性地关掉这一段"
        fi
    fi
    if [[ "${X_BATCH_SPLIT:-1}" == "1" ]] && declare -F x_split_modes >/dev/null 2>&1; then
        local -a _split_specs=()
        local _sp
        for _sp in cdn-cdn cdn-reality reality-cdn; do
            # reality-cdn 的上行是 REALITY, 需要密钥对; 没给就跳过这一个,
            # 而不是让整批失败 —— 另外两个组合不需要。
            if [[ "$_sp" == reality-cdn && -z "${X_BATCH_REALITY_PRIVATE_KEY:-}" ]]; then
                print_warn "跳过 $_sp (需要 REALITY 密钥对; 设 X_BATCH_REALITY_PRIVATE_KEY 与 X_BATCH_REALITY_PUBLIC_KEY)"
                continue
            fi
            # 有 CDN 段的才需要域名; 两个域名都由 X_BATCH_DOMAIN / _DL_DOMAIN 给
            _split_specs+=("vless:4:split:$_sp")
        done

        if [[ ${#_split_specs[@]} -gt 0 ]]; then
            echo >&2
            print_title "xHTTP 上下行分离 (三个组合)"
            print_info "  域名: ${X_BATCH_DOMAIN:-未设置}${X_BATCH_DL_DOMAIN:+ / 下行 ${X_BATCH_DL_DOMAIN}}"
            print_info "  直连下行地址: ${X_BATCH_DL_ADDRESS:-未设置}"
            printf "${CYAN}• %-12s${RESET} %s\n" "xhttp-split" "${_split_specs[*]}" >&2
            X_BATCH_NO_RELOAD=1 X_NO_RELOAD=1 \
                timeout "$BATCH_PROTO_TIMEOUT" bash "$SCRIPT_DIR/../tools/preset_batch.sh" \
                    "${_split_specs[@]}" </dev/null \
                    >"$LOG_DIR/x-batch-split.log" 2>&1
            local src=$?
            sed 's/^/    /' "$LOG_DIR/x-batch-split.log" >&2 || true
            if [[ $src -eq 0 ]]; then
                printf "${GREEN}[OK]${RESET} 三个组合已生成\n" >&2
                BATCH_OK+=("xhttp-split")
            else
                printf "${RED}[失败]${RESET} (详见 $LOG_DIR/x-batch-split.log)\n" >&2
                BATCH_FAIL+=("xhttp-split")
            fi
        fi
    fi

    # 本批新生成的服务端碎片(收尾失败清理用)
    local -a new_files=() f
    for f in "$CONF_DIR"/*.json; do
        local old
        for old in "${new_files_before[@]}"; do
            [[ "$old" == "$f" ]] && continue 2
        done
        new_files+=("$f")
    done

    # ---- 先补证书, 再统一验证 ----
    #
    # ★ 顺序不能反。证书没了的时候, verify.sh 会报一长串
    #   "failed to build TLS config > failed to parse certificate",
    #   没人看得出真因是文件不在磁盘上。先跑 x_cert_ensure: 能补就补上,
    #   补不上就明确告诉用户是哪张证书、去哪张卡, 再交给内核校验。
    #
    #   没有这一步, "证书莫名丢失"就是一个只在重启时才炸的静默故障 ——
    #   10-08 和 10-12 都是这样发现的, 两次都是别人的续签顺手删的,
    #   不是我们删的, 但最后是我们这边的节点起不来。
    # batch.sh 既能被面板 source (库已加载), 也能 `bash conf/batch.sh --auto`
    # 单独跑 (库没加载)。所以这里按需补载一次 cert.sh —— 用 declare -F 直接
    # 判断的话, 单独跑那条路会**静默跳过**证书检查, 恰好是最需要它的场景。
    if ! declare -F x_cert_ensure >/dev/null 2>&1; then
        local _cdir _cf
        _cdir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
        for _cf in "$_cdir/lib/cert.sh" "$_cdir/cert.sh"; do
            [[ -r "$_cf" ]] && { source "$_cf"; break; }
        done
    fi
    if declare -F x_cert_ensure >/dev/null 2>&1; then
        if ! x_cert_ensure "$CONF_DIR"/*.json; then
            print_error "有证书缺失且无法自动恢复, 已中止 (不写坏配置)"
            return 1
        fi
    else
        print_warn "证书自检不可用 (未找到 lib/cert.sh), 跳过证书缺失检查"
    fi

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

    # ---- 建完顺手把 CDN/nginx 站点配好 (照 sing-box-core 的做法) ----
    #
    # ★ 这一段原来**没有**。后果与菜单 13/14/15 是一样的: nginx 档的节点
    #   监听在 127.0.0.1, 却没人给它配反代 —— 客户端连 域名:443 打不到任何
    #   东西, 而汇总里一切正常。
    #   SB 在同一位置是建完就自动配 (batch.sh:739 → sb_cdn_autosetup)。
    #
    #   放在 batch_summary **之前**: 汇总要如实反映 nginx 到底配没配上,
    #   放到后面就成了"先报成功、再报失败"。
    local _ng_ok=0 _ng_fail=0
    if declare -F x_cdn_autosetup >/dev/null 2>&1; then
        shopt -s nullglob
        local -a _frags=("$CONF_DIR"/*.json)
        shopt -u nullglob
        if ((${#_frags[@]} > 0)); then
            echo >&2
            if x_cdn_autosetup "${_frags[@]}" >/dev/null 2>&1; then
                _ng_ok=1
            else
                _ng_fail=1
            fi
        fi
    else
        # cdn_auto.sh 没加载上时**要说出来** —— 静默跳过会让"nginx 没配"
        # 和"根本没尝试配"在屏幕上长得一模一样。
        print_warn "cdn_auto.sh 没加载上 —— nginx 反代没有自动配置"
    fi
    if (( _ng_ok )); then
        print_ok "已尝试自动配置 nginx 反代 (见上面的站点明细)"
    elif (( _ng_fail )); then
        print_warn "nginx 有站点没配上 —— 节点本身已生成, 去 菜单 8→6 Nginx 站点管理 补"
    fi

    batch_summary "$reloaded"

    # ---- 自动生成/刷新订阅链接 (照 SB: 批量建完直接给一条能用的地址) ----
    # 在这之前 X 不会自动建订阅 —— 用户得自己去 菜单 4 → 2) 全协议分享 点一遍,
    # 而"我刚建了 4 个节点, 现在该干什么"在屏幕上没有答案。
    # 失败一律不阻断: 节点本身已经建好了。
    if declare -F share_ensure_subscription >/dev/null 2>&1 || [[ -n "${_BATCH_SHARE_SH:-}" ]]; then
        echo >&2
        local _shf
        _shf=$(resolve_share_sh 2>/dev/null || true)
        if [[ -n "$_shf" ]]; then
            XRAY_BASE="$XRAY_BASE" XRAY_CONF_DIR="$CONF_DIR" \
            bash "$_shf" ensure-subscription 2>&1 | sed 's/^/  /' >&2 || true
        fi
    fi
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
# ---------- 清空/重建时的 nginx 连带清理 ----------
#
# ★ 用户明确要求: 删节点或「清空全部」都要把 nginx 上对应的配置一起摘掉
#   (对齐 sing-box-core 的做法: 先删节点产物, 再清理指向已删端口的
#   反代段, 最后 reload nginx)。
#
# 为什么不能只靠"事后孤儿巡检": 孤儿巡检只**报**不**删**。用户清空全部
# 之后, 站点里还留着一堆指向已删端口的 location —— 它们不报任何错, 但
# Cloudflare 回源会一直打到不存在的后端, 表现为 502。
#
# 做法是**删除前先把 (域名, path) 记下来**, 删完再逐个精确摘除 —— 比事后
# 按"端口是否存活"反推更可靠, 也不会误伤站点自有的 location。

_collect_nginx_targets() {   # → 打印 "域名<TAB>路径" 每行一个
    local share_dir="${XRAY_BASE:-/root/catmi/xray}/share"
    [[ -d "$share_dir" ]] || return 0
    SHARE_DIR="$share_dir" LIB="$LIB_DIR" py -c "
import os, sys
sys.path.insert(0, os.environ['LIB'])
try:
    import share_meta
except Exception:
    raise SystemExit(0)
d = os.environ['SHARE_DIR']
out = []
try:
    names = os.listdir(d)
except OSError:
    raise SystemExit(0)
seen = set()
for n in names:
    m = share_meta.load(d, n)
    if not m or m.get('tier') != 'nginx':
        continue
    dom = m.get('host') or ''
    if not dom:
        continue
    p = m.get('path') or '/'
    # 双域名 (上下行分离): 上行域名与下行域名各自有一段, **两段都要摘**;
    # 两个域名可能各自在不同站点文件里, 所以按域名逐个摘。
    for x in (dom, m.get('dl_domain') or m.get('dl_host') or ''):
        if x and x not in seen:
            seen.add(x)
            print('%s\t%s' % (x, p))
" 2>/dev/null
}

prune_nginx_after_wipe() {   # <"域名<TAB>路径" 清单>
    local pyf line dom path n=0
    local -a targets=("$@")
    (( ${#targets[@]} )) || return 0
    pyf="$LIB_DIR/nginx_apply.py"
    [[ -f "$pyf" ]] || { print_warn "拿不到 nginx_apply.py, 请手工清理 nginx 片段"; return 0; }
    for line in "${targets[@]}"; do
        dom="${line%%$'	'*}"
        path="${line#*$'	'}"
        [[ -n "$dom" ]] || continue
        py "$pyf" --domain "$dom" --path "$path" --remove >/dev/null 2>&1 || true
        # 老版本可能按 / 插入的, 带 path 摘不到再按 / 试一次
        if [[ "$path" != "/" ]]; then
            py "$pyf" --domain "$dom" --path / --remove >/dev/null 2>&1 || true
        fi
        n=$(( n + 1 ))
    done
    (( n )) && print_ok "nginx 片段已摘除 $n 段 (对应节点已删除)"
    return 0
}

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
    # ★ 先记住要摘哪些 nginx 片段 —— 删完就再也读不出域名了
    local -a ng_targets=()
    while IFS= read -r _l; do [[ -n "$_l" ]] && ng_targets+=("$_l"); done < <(_collect_nginx_targets)

    local p del=0
    for p in "${BATCH_PROTOS[@]}"; do
        del=$(( del + $(wipe_proto "$p") ))
    done
    prune_nginx_after_wipe "${ng_targets[@]}"
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
    local -a ng_targets=()
    while IFS= read -r _l; do [[ -n "$_l" ]] && ng_targets+=("$_l"); done < <(_collect_nginx_targets)
    prune_nginx_after_wipe "${ng_targets[@]}"
    for p in "${BATCH_PROTOS[@]}"; do wipe_proto "$p" >/dev/null; done
    print_ok "已清掉旧节点, 开始重新生成"
    return 0
}

########## 入口 ##########
# 回车默认走哪一项。放在这里而不是写死在 case 里, 是为了:
#   · 批量/自动化 (X_BATCH_DEF=1) 时可以只问最少的问题;
#   · 交互测试可以把它固定住, 断言"回车会走到哪一步"而不是靠猜。
BATCH_DEF="${X_BATCH_DEF:-2}"

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
        echo -e "${CYAN}2)${RESET} 全协议快速生成  ${DIM}只问端口范围${RESET} ${DIM}← 回车默认${RESET}"
        echo -e "${CYAN}3)${RESET} 全协议重建      ${YELLOW}强制覆盖已有节点 (端口/UUID 会换新)${RESET}"
        echo -e "${CYAN}4)${RESET} 清空全部节点    ${RED}(破坏性)${RESET}"
        echo -e "${CYAN}0)${RESET} 返回"
        # ★ 每个菜单项的回车都要有意义 —— 这是 sing-box-core 的做法, 也是
        #   "按回车就能往下走" 的前提。
        #
        #   原来直接回车落到 `*)` 打一句 [Error] 无效选项 就重来。用户刚点进来、
        #   手还在回车上, 先看见的是一句报错 —— 脚本没坏, 但观感上跟坏了没区别。
        #   这里让回车 = 推荐动作 (2 快速生成), 并且**在提示里写明**,
        #   免得用户以为脚本自己动了。
        read -r -p "  ${CYAN}请输入选项 [0-4, 回车=${BATCH_DEF}]:${RESET} " c || { echo; exit 0; }
        c=$(clean_input "$c")
        c="${c:-$BATCH_DEF}"
        case "$c" in
            1) ask_all && batch_main ;;
            2) X_SERVER_NAME=$(_bt_server_name); ask_port_range && batch_main ;;
            3) if rebuild_all; then X_SERVER_NAME=$(_bt_server_name); ask_port_range && batch_main; fi ;;
            4) clear_all_nodes ;;
            0|q|Q) return ;;
            # 破坏性操作绝不猜: 只有明确打了 4 才清空, 回车绝不会落到这儿。
            *) print_error "无效选项 $c —— 回车=${BATCH_DEF} (快速生成), 0 返回" ;;
        esac
        [[ "$c" == "0" ]] || { read -r -p "按回车键返回..." _ || { echo; exit 0; }; }
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
