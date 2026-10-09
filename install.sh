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
    if ! srv_installed; then
        say "服务端未安装 —— 进入面板后选第 1 项「安装/更新 xray」"
    fi
    TMP="${TMP:-$(mktemp -d)}"
    local p="$TMP/xray-panel.sh"
    _fetch "xray-panel.sh" "$p" || die "取不到面板脚本 (镜像链全不通?)"
    exec bash "$p"
}

# ---------------------------------------------------------------- 客户端
run_client() {
    TMP="${TMP:-$(mktemp -d)}"
    local l="$TMP/l.sh"
    _fetch "Client/l.sh" "$l" || die "取不到客户端安装器 (镜像链全不通?)"
    exec bash "$l" "$@"
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
        printf '\n  1) 服务端面板 (节点 / 分享 / 证书 / Nginx / 诊断)\n'
        printf '  2) 客户端 (装内核 + 面板 + Web UI)\n'
        printf '  3) 卸载\n'
        printf '  0) 退出\n'
        printf '  选择: '
        local c; read -r c || return 0
        case "$c" in
            1) run_server ;;
            2) run_client ;;
            3) run_uninstall ;;
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
