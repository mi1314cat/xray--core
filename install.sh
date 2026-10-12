#!/usr/bin/env bash
# =============================================================
# xray--core 安装引导
#
#   bash <(curl -fsSL <仓库>/install.sh)              # 选择 服务端 / 客户端
#   bash <(curl -fsSL <仓库>/install.sh) server       # 直接进服务端面板
#   bash <(curl -fsSL <仓库>/install.sh) client       # 直接装/进客户端
#   bash <(curl -fsSL <仓库>/install.sh) uninstall    # 卸载(服务端 / 客户端 二选一)
#   bash <(curl -fsSL <仓库>/install.sh) --status     # 只报告状态
#   bash <(curl -fsSL <仓库>/install.sh) server update   # 强制取远端最新版再进
#
# ★ 为什么要有这个入口 (借鉴 mihomo--core / sing-box-core):
#
#   X 原来有两个入口, 互不知道对方存在:
#       服务端   xray-panel.sh
#       客户端   Client/l.sh
#   用户拿到一个仓库地址, 得先知道"我要装哪个、该跑哪个脚本"。两个内核
#   都是**一个引导脚本 + 角色参数**, 这里对齐。
#
# =============================================================
# ★ 取文件的策略: **本地优先, 远端兜底, 且整条链有总时限**。
#
#   原来的写法是"只走远端": 4 个镜像 × 每源重试 2 次 × 25 秒 = 最坏 **200 秒**
#   停在那儿不动, 失败就直接 die。用户的要求是:
#
#       「如果连接不上, GitHub 更新不了的时候, 它应该就用自己的,
#         不应该停在那边」
#
#   所以改成三条规矩:
#     1. 本机已经有能用的那份 → 直接用它, **一次网络都不发**。
#        进面板是"进已有的东西", 不该顺带联网。
#     2. 本地没有才去下载; 远端挂了且本地有 → 退回本地, 明确告诉用户
#        "这是本地那份, 更新没成功", 但**照常进面板**。
#     3. 远端拿到的文件先验一下是不是真脚本 —— 404 的 HTML 页存成 .sh,
#        后面报的是语法错误, 跟网络八竿子打不着, 极难查。
#
#   更新是另一件事, 显式做: `install.sh server update` 或菜单里的「更新」。
# =============================================================

set -uo pipefail

# 颜色
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'
DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=""; GRN=""; YEL=""; CYN=""; DIM=""; RST=""; }

say()  { printf "  ${CYN}[--]${RST} %s\n" "$*"; }
tty_dim() { printf '%s' "$DIM"; }
tty_off() { printf '%s' "$RST"; }
ok()   { printf "  ${GRN}[OK]${RST} %s\n" "$*"; }
warn() { printf "  ${YEL}[!]${RST} %s\n" "$*"; }
err()  { printf "  ${RED}[X]${RST} %s\n" "$*"; }
die()  { err "$*"; exit 1; }

REPO_RAW_DEFAULT="${XRAY_RAW:-https://raw.githubusercontent.com/mi1314cat/xray--core/main}"
SRV_ROOT="${XRAY_BASE:-/root/catmi/xray}"
CLI_PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"

# 整条镜像链的总时限(秒)。到点就放弃去本地 —— "停在那边"比"慢一点"糟得多。
FETCH_BUDGET="${XRAY_FETCH_BUDGET:-75}"
FORCE_REMOTE=0

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 本地副本
# 从仓库检出跑 (bash install.sh) 时, 脚本旁边就是全套 —— 这种情况下根本
# 不该联网。生产上装好的那份在 /root/xray-panel.sh 与 $SRV_ROOT 下。
# 存成**变量**而不是函数 —— 函数名当变量引用, 在 set -u 下是 unbound variable。
# 从仓库检出跑时它就是仓库根, 于是 xray-panel.sh / conf/ 全都在本地。
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" \
    || _SELF_DIR="$(dirname "${BASH_SOURCE[0]:-$0}")"

# 本地副本在哪: 越靠前越权威。
# 生产上装好的面板落在 **/root/xray-panel.sh** —— 那是 SRV_ROOT (/root/catmi/xray)
# 的**祖父**目录, 只取一层 dirname 会落到 /root/catmi, 找不到它 (第一版就错在这)。
_local_roots() {
    local p1 p2 r seen=" "
    p1=$(dirname "$SRV_ROOT"); p2=$(dirname "$p1")
    for r in "$_SELF_DIR" "$SRV_ROOT" "$p1" "$p2" /root "$CLI_PREFIX"; do
        [[ -n "$r" && "$r" == "/" ]] && continue
        # 去重: 默认布局下这��目录会重合
        [[ "$seen" == *" $r "* ]] && continue
        seen="$seen$r "
        printf '%s\n' "$r"
    done
}

# <仓库相对路径> -> 打印本地绝对路径; 没有就返回 1
_local_find() {
    local rel="$1" r
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        [[ -s "$r/$rel" ]] && { printf '%s' "$r/$rel"; return 0; }
    done < <(_local_roots)
    return 1
}

# 下回来的东西是不是真脚本。GitHub 的 404 / 反代拦截页都是 HTML,
# 存成 .sh 之后报的是 "syntax error near unexpected token", 看着像代码坏了。
_looks_like_script() {
    local f="$1" h
    [[ -s "$f" ]] || return 1
    h=$(head -c 200 "$f" 2>/dev/null)
    # 网页 / 404 / 反代拦截页。
    # ★ GitHub 的 404 返回的是纯文本 "404: Not Found" **不是 HTML** (实测),
    #   只挡 HTML 挡不住它 —— 存下一个 11 字节的 .sh, 后面报语法错误,
    #   跟网络八竿子打不着, 极难查。
    printf '%s' "$h" | grep -qiE '^[[:space:]]*(<!doctype|<html)' && return 1
    printf '%s' "$h" | grep -qiE '^[[:space:]]*(404:|403:|502:|error:|proxy error)' && return 1
    # 整个文件没有换行 —— 正常脚本不可能
    [[ "$(wc -l < "$f" 2>/dev/null)" -eq 0 ]] && return 1
    return 0
}

# ---------------------------------------------------------------- 取文件
_fetch() { # <仓库相对路径> <本地路径>
    local rel="$1" dest="$2" base i start now left
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    start=$(date +%s)
    for base in "$REPO_RAW_DEFAULT" \
                "https://ghproxy.net/$REPO_RAW_DEFAULT" \
                "https://gh-proxy.com/$REPO_RAW_DEFAULT" \
                "https://cdn.jsdelivr.net/gh/mi1314cat/xray--core@main" ; do
        # 整条链的总时限。到点立刻收手, 不再往下试。
        now=$(date +%s); left=$((FETCH_BUDGET - (now - start)))
        (( left <= 0 )) && break
        # 主站值得多试一次 (12 秒会把"首包慢但其实能通"的镜像误判成不通);
        # 镜像只试一次, 而且越靠后给的时间越短。
        local tries=1 to=12
        [[ "$base" == "$REPO_RAW_DEFAULT" ]] && tries=2
        (( $(echo "$base" | grep -c 'ghproxy\|gh-proxy\|jsdelivr') )) && to=8
        (( left < to )) && to=$left
        for (( i = 0; i < tries; i++ )); do
            if curl -fsSL --max-time "$to" "$base/$rel" -o "$dest.tmp" 2>/dev/null \
               && _looks_like_script "$dest.tmp"; then
                mv -f "$dest.tmp" "$dest"
                [[ "$base" == "$REPO_RAW_DEFAULT" ]] \
                    || say "主站不通, 用了镜像 $(printf '%s' "$base" | cut -d/ -f3)"
                return 0
            fi
        done
    done
    rm -f "$dest.tmp"
    return 1
}

# 取一份来用: 本地优先 → 远端 → 再退回本地。**任何情况下都不静默卡住。**
_get() { # <仓库相对路径> <目标路径>
    local rel="$1" dest="$2" src
    if [[ "$FORCE_REMOTE" == "0" ]] && src=$(_local_find "$rel"); then
        cp -f "$src" "$dest" 2>/dev/null && return 0
    fi
    if _fetch "$rel" "$dest"; then
        return 0
    fi
    # 远端没成 —— 回本地, 并明说这次没更新上
    if src=$(_local_find "$rel"); then
        cp -f "$src" "$dest" 2>/dev/null && {
            warn "远端取不到, 改用本机已有的那份: $src"
            return 0
        }
    fi
    return 1
}

# ---------------------------------------------------------------- 状态
srv_installed() { [[ -d "$SRV_ROOT" && -f "$SRV_ROOT/config.json" ]]; }
cli_installed() { [[ -d "$CLI_PREFIX" ]]; }
srv_service()   { systemctl is-active xrayls 2>/dev/null || echo "inactive"; }

# ★ 远端版本**只在用户显式要看时**去问。
#   原来它在主菜单每一轮重画都跑一遍 —— 那就是 4×2×25 秒的挂起,
#   用户表现为"菜单打出来就卡住, 什么都点不动"。菜单必须能离线用。
_remote_version() {
    local f; f=$(mktemp) || return 1
    _fetch "Client/VERSION" "$f" >/dev/null 2>&1 || { rm -f "$f"; return 1; }
    head -1 "$f" 2>/dev/null | tr -d '[:space:]'
    rm -f "$f"
}

check_update() {
    local rv
    printf '\n'
    if rv=$(_remote_version) && [[ -n "$rv" ]]; then
        ok "远端版本: $rv"
    else
        warn "查不到远端版本 (镜像链不通或超时) —— 本机已有的功能不受影响"
    fi
}

show_status() {
    printf '\n%s\n' "════ 当前状态 ════"
    if srv_installed; then
        ok "服务端已安装: $SRV_ROOT (xrayls: $(srv_service))"
    else
        say "服务端未安装"
    fi
    if cli_installed; then
        ok "客户端已安装: $CLI_PREFIX"
        [[ -x "$CLI_PREFIX/l.sh" ]] && say "  入口: $CLI_PREFIX/l.sh"
    else
        say "客户端未安装"
    fi
}

# ---------------------------------------------------------------- 服务端
run_server() {
    if srv_installed; then
        say "已安装: $SRV_ROOT (xrayls: $(srv_service)) —— 直接进面板"
    else
        say "服务端未安装 —— 进入面板后选第 1 项「安装/更新 xray」"
    fi
    TMP="${TMP:-$(mktemp -d)}"
    local p="$TMP/xray-panel.sh"
    _get "xray-panel.sh" "$p" \
        || die "本机没有面板、远端也取不到 (镜像链全不通?)。网络恢复后重跑, 或手动放置 xray-panel.sh"
    exec bash "$p"
}

# ---------------------------------------------------------------- 客户端
#
# ★ 已经装过的机器上, `client` **直接进面板**, 不再重装。
#
#   原来的行为是"每次进来都跑一遍安装器": 用户想看一眼客户端, 却看到
#   "检测到已安装 → 将执行更新 → 下载发布包 → 校验 → 安装" 一整套 ——
#   既慢又吓人（看起来像要覆盖掉他的配置）。M / SB 那边进来就是面板,
#   这里对齐。
#
#   要更新得**明说**: `install.sh client update`（或 --update / -u）。
#   面板里也有「更新脚本」入口。
run_client() {
    local force=0 a
    for a in "$@"; do
        case "$a" in update|--update|-u|upgrade) force=1 ;; esac
    done
    [[ "$force" == "1" ]] && { FORCE_REMOTE=1; say "按要求取远端最新版（不进入面板）"; }

    if [[ "$force" == "0" ]] && cli_installed && [[ -x "$CLI_PREFIX/bin/xbd" ]]; then
        # 已经是客户端了 —— 直接进面板
        exec "$CLI_PREFIX/bin/xbd" menu
    fi
    if [[ "$force" == "0" ]] && cli_installed; then
        say "检测到客户端目录 $CLI_PREFIX, 但没有可用的 xbd —— 走安装器修复"
    fi
    # 面板不认 update 这个参数, 传下去会被 l.sh 当成未知参数
    local pass=()
    for a in "$@"; do
        case "$a" in update|--update|-u|upgrade) ;; *) pass+=("$a") ;; esac
    done
    TMP="${TMP:-$(mktemp -d)}"
    local l="$TMP/l.sh"
    _get "Client/l.sh" "$l" \
        || die "本机没有客户端安装器、远端也取不到 (镜像链全不通?)"
    exec bash "$l" ${pass[@]+"${pass[@]}"}
}

# ---------------------------------------------------------------- 更新
#
# 「更新」= 走安装器把脚本与内核同步到最新（等价于在客户端面板里选更新）。
# 单独拎出来是因为它和"进入面板"现在是两件事: 进面板不联网, 更新才下载。
run_update() {
    printf '\n  更新哪一个?\n'
    printf '    1) 服务端 (xray-panel.sh + conf/ + 内核不动)\n'
    printf '    2) 客户端 (xbd 全套 + 面板 + Web UI)\n'
    printf '    0) 返回\n'
    printf '  选择: '
    local c; read -r c || return 0
    case "$c" in
        1) FORCE_REMOTE=1; run_server ;;
        2) run_client update ;;
        0|"") return 0 ;;
        *) warn "无效选择" ;;
    esac
}

# ---------------------------------------------------------------- 卸载
run_uninstall() {
    printf '\n  卸载哪一个?\n'
    printf '    1) 服务端面板 (停 xrayls, 配置目录保留)\n'
    printf '    2) 客户端\n'
    printf '    0) 返回\n'
    printf '  选择: '
    local c; read -r c || return 0
    case "$c" in
        1)
            printf '  确认卸载服务端? 输入 yes: '
            local a; read -r a || true
            [[ "$a" == "yes" ]] || { say "已取消"; return 0; }
            TMP="${TMP:-$(mktemp -d)}"
            local u="$TMP/uninstall_xray.sh"
            _get "uninstall_xray.sh" "$u" \
                || die "本机没有卸载脚本、远端也取不到 (镜像链全不通?)"
            bash "$u"
            ;;
        2)
            if [[ -x "$CLI_PREFIX/uninstall-xray-client.sh" ]]; then
                bash "$CLI_PREFIX/uninstall-xray-client.sh"
            else
                TMP="${TMP:-$(mktemp -d)}"
                local u="$TMP/uninstall-client.sh"
                _get "Client/uninstall-xray-client.sh" "$u" \
                    || die "本机没有客户端卸载脚本、远端也取不到 (镜像链全不通?)"
                bash "$u"
            fi
            ;;
        0|"") return 0 ;;
        *) warn "无效选择" ;;
    esac
}

# ---------------------------------------------------------------- 菜单
banner() {
    cat <<'EOF'

                       |\__/,|   (\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.xray-core
       -----------------------------------------

EOF
}

main_menu() {
    while :; do
        banner
        show_status
        # 菜单本身先说清"进去是面板还是安装" —— 这一行差别就是用户
        # 上一次的困惑:"我明明装过了, 为什么又装一遍"。
        if srv_installed; then
            printf '\n  1) 服务端面板   %s(已安装 · 直接进入 · 不联网)%s\n' "$(tty_dim)" "$(tty_off)"
        else
            printf '\n  1) 服务端面板   %s(安装 + 进面板)%s\n' "$(tty_dim)" "$(tty_off)"
        fi
        if cli_installed; then
            printf '  2) 客户端面板   %s(已安装 · 直接进入)%s\n' "$(tty_dim)" "$(tty_off)"
        else
            printf '  2) 客户端       %s(装内核 + 面板 + Web UI)%s\n' "$(tty_dim)" "$(tty_off)"
        fi
        printf '  3) 更新到最新版本\n'
        printf '  4) 检查是否有新版本\n'
        printf '  5) 卸载\n'
        printf '  0) 退出\n'
        printf '  选择: '
        local c; read -r c || return 0
        case "$c" in
            1) run_server ;;
            2) run_client ;;
            3) run_update ;;
            4) check_update ;;
            5) run_uninstall ;;
            0|"") return 0 ;;
            *) warn "无效选择" ;;
        esac
        printf '\n  回车继续...'
        read -r _ || return 0
    done
}

# ---------------------------------------------------------------- 入口
case "${1:-}" in
    server)
        shift || true
        for a in "$@"; do
            case "$a" in update|--update|-u|upgrade) FORCE_REMOTE=1 ;; esac
        done
        run_server ;;
    client)          shift; run_client "$@" ;;
    uninstall)       run_uninstall ;;
    --status|status) show_status; check_update ;;
    --check-update)  check_update ;;
    -h|--help)
        sed -n '2,22p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
        ;;
    "")              main_menu ;;
    *)               die "未知参数: $1 (可用: server | client | uninstall | --status | --check-update)" ;;
esac