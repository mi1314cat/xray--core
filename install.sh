#!/usr/bin/env bash
# =============================================================
# xray--core 安装引导
#
#   bash <(curl -fsSL <仓库>/install.sh)              # 选择 服务端 / 客户端
#   bash <(curl -fsSL <仓库>/install.sh) server       # 直接进服务端面板
#   bash <(curl -fsSL <仓库>/install.sh) client       # 直接装/进客户端
#   bash <(curl -fsSL <仓库>/install.sh) uninstall    # 卸载(服务端 / 客户端 二选一)
#   bash <(curl -fsSL <仓库>/install.sh) --status     # 只报告状态
#
# ★ 为什么要有这个入口 (借鉴 mihomo--core / sing-box-core):
#
#   X 原来有两个入口, 互不知道对方存在:
#       服务端   xray-panel.sh
#       客户端   Client/l.sh
#   用户拿到一个仓库地址, 得先知道"我要装哪个、该跑哪个脚本"。两个内核
#   都是**一个引导脚本 + 角色参数**, 这里对齐。
#
# ★ 取文件走 conf/lib/fetch.sh 的镜像链 —— 国内机器连 github.com 经常是
#   连接超时而不是拒绝, 单个源不通就整个卡死; 而且 raw 有 CDN 缓存,
#   刚推的版本可能拿不到 (实测约 5 分钟)。
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

REPO_RAW_DEFAULT="https://raw.githubusercontent.com/mi1314cat/xray--core/main"
SRV_ROOT="${XRAY_BASE:-/root/catmi/xray}"
CLI_PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 取文件
# 用一个"就地取一份"的最小实现, 不依赖仓库里任何文件 —— 引导脚本自己
# 必须能独立启动 (它是第一个被 curl 下来的东西)。
_fetch() { # <仓库相对路径> <本地路径>
    local rel="$1" dest="$2" base i
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    for base in "$REPO_RAW_DEFAULT" \
                "https://ghproxy.net/$REPO_RAW_DEFAULT" \
                "https://gh-proxy.com/$REPO_RAW_DEFAULT" \
                "https://cdn.jsdelivr.net/gh/mi1314cat/xray--core@main" ; do
        for i in 1 2; do
            # 25 秒 × 2: 12 秒会把"首包慢但其实能通"的镜像误判成不通
            # (两个内核的注释里都记着这一条)
            if curl -fsSL --max-time 25 "$base/$rel" -o "$dest.tmp" 2>/dev/null; then
                mv -f "$dest.tmp" "$dest"
                [[ "$base" == "$REPO_RAW_DEFAULT" ]] || say "主站不通, 用了镜像 $(printf '%s' "$base" | cut -d/ -f3)"
                return 0
            fi
        done
    done
    rm -f "$dest.tmp"
    return 1
}

# 远端版本 (用于提示"你本地是什么、远端是什么")
_remote_version() {
    local f="$TMP/.version"
    _fetch "Client/VERSION" "$f" >/dev/null 2>&1 || return 1
    head -1 "$f" 2>/dev/null | tr -d '[:space:]'
}

# ---------------------------------------------------------------- 状态
srv_installed() { [[ -d "$SRV_ROOT" && -f "$SRV_ROOT/config.json" ]]; }
cli_installed() { [[ -d "$CLI_PREFIX" ]]; }
srv_service()   { systemctl is-active xrayls 2>/dev/null || echo "inactive"; }

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
    local rv; rv=$(_remote_version) && say "远端版本: $rv"
}

# ---------------------------------------------------------------- 服务端
run_server() {
    if srv_installed; then
        # 服务端面板本身就是管理界面 —— 进来直接进, 不重装。
        say "已安装: $SRV_ROOT (xrayls: $(srv_service)) —— 直接进面板"
    else
        say "服务端未安装 —— 进入面板后选第 1 项「安装/更新 xray」"
    fi
    TMP="${TMP:-$(mktemp -d)}"
    local p="$TMP/xray-panel.sh"
    _fetch "xray-panel.sh" "$p" || die "取不到面板脚本 (镜像链全不通?)"
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
    local args=("$@") force=0 a
    for a in "$@"; do
        case "$a" in update|--update|-u|upgrade) force=1 ;; esac
    done
    if [[ "$force" -eq 0 ]] && cli_installed && [[ -x "$CLI_PREFIX/bin/xbd" ]]; then
        # 已经是客户端了 —— 直接进面板
        exec "$CLI_PREFIX/bin/xbd" menu
    fi
    if [[ "$force" -eq 0 ]] && cli_installed; then
        say "检测到客户端目录 $CLI_PREFIX, 但没有可用的 xbd —— 走安装器修复"
    fi
    [[ "$force" -eq 1 ]] && say "按要求执行更新（不进入面板）"
    # 面板不认 update 这个参数, 传下去会被 l.sh 当成未知参数
    local pass=()
    for a in "$@"; do
        case "$a" in update|--update|-u|upgrade) ;; *) pass+=("$a") ;; esac
    done
    TMP="${TMP:-$(mktemp -d)}"
    local l="$TMP/l.sh"
    _fetch "Client/l.sh" "$l" || die "取不到客户端安装器 (镜像链全不通?)"
    exec bash "$l" ${pass[@]+"${pass[@]}"}
}

# ---------------------------------------------------------------- 更新
#
# 「更新」= 走安装器把脚本与内核同步到最新（等价于在客户端面板里选更新）。
# 单独拎出来是因为它和"进入面板"现在是两件事: 进面板不重装, 更新才下载。
run_update() {
    printf '\n  更新哪一个?\n'
    printf '    1) 服务端 (xray-panel.sh + conf/ + 内核不动)\n'
    printf '    2) 客户端 (xbd 全套 + 面板 + Web UI)\n'
    printf '    0) 返回\n'
    printf '  选择: '
    local c; read -r c || return 0
    case "$c" in
        1) run_server ;;
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
            TMP="${TMP:-$(mktemp -d)}"
            local u="$TMP/uninstall_xray.sh"
            _fetch "uninstall_xray.sh" "$u" || die "取不到卸载脚本"
            printf '  确认卸载服务端? 输入 yes: '
            local a; read -r a || true
            [[ "$a" == "yes" ]] || { say "已取消"; return 0; }
            bash "$u"
            ;;
        2)
            if [[ -x "$CLI_PREFIX/uninstall-xray-client.sh" ]]; then
                bash "$CLI_PREFIX/uninstall-xray-client.sh"
            else
                TMP="${TMP:-$(mktemp -d)}"
                local u="$TMP/uninstall-client.sh"
                _fetch "Client/uninstall-xray-client.sh" "$u" || die "取不到客户端卸载脚本"
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
            printf '\n  1) 服务端面板   %s(已安装 · 直接进入)%s\n' "$(tty_dim)" "$(tty_off)"
        else
            printf '\n  1) 服务端面板   %s(安装 + 进面板)%s\n' "$(tty_dim)" "$(tty_off)"
        fi
        if cli_installed; then
            printf '  2) 客户端面板   %s(已安装 · 直接进入)%s\n' "$(tty_dim)" "$(tty_off)"
        else
            printf '  2) 客户端       %s(装内核 + 面板 + Web UI)%s\n' "$(tty_dim)" "$(tty_off)"
        fi
        printf '  3) 更新到最新版本\n'
        printf '  4) 卸载\n'
        printf '  0) 退出\n'
        printf '  选择: '
        local c; read -r c || return 0
        case "$c" in
            1) run_server ;;
            2) run_client ;;
            3) run_update ;;
            4) run_uninstall ;;
            0|"") return 0 ;;
            *) warn "无效选择" ;;
        esac
        printf '\n  回车继续...'
        read -r _ || return 0
    done
}

# ---------------------------------------------------------------- 入口
case "${1:-}" in
    server)          run_server ;;
    client)          shift; run_client "$@" ;;
    uninstall)       run_uninstall ;;
    --status|status) show_status ;;
    -h|--help)
        sed -n '2,20p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
        ;;
    "")              main_menu ;;
    *)               die "未知参数: $1 (可用: server | client | uninstall | --status)" ;;
esac
