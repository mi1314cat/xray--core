#!/usr/bin/env bash
# 公共分享服务管理 —— 确保在位 / 状态 / 统计 / 升级 / 防火墙
#
# ==============================================================
# ★ 这个脚本以前管的是**本机自己的** xray-share 服务端 (conf/lib/share_server.py,
#   端口 9443)。那个服务已经不存在了 —— 分享的存储与生命周期归**公共基础服务**
#   proxy-share-service, 它被 M / SB / X 三个内核共用。
#
# ★ 菜单里**故意没有"停止"和"卸载"**。
#
#   公共服务的生命周期属于它自己, 不属于任何一个内核: 从 X 的面板把它停掉,
#   M 和 SB 已经发出去的链接会一起断, 而且现场看不出是谁干的。
#   它自己的仓库才有卸载入口:
#
#       git clone https://github.com/mi1314cat/Share-Service
#       bash Share-Service/install.sh uninstall --force   # 保留数据
#       bash Share-Service/install.sh uninstall --purge   # 连数据一起删
#
#   这里只做"确保它好好跑着"以及只读的查看。
# ==============================================================

set -uo pipefail

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
SHARE_DIR="${XRAY_SHARE_DIR:-$XRAY_BASE/out/share}"
SHARE_ADDR="${XRAY_SHARE_ADDR:-127.0.0.1}"
XRAY_RAW="${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}"

# ★ 本脚本在面板里是 `bash <(curl -Ls .../conf/share_service.sh) menu` 跑的 ——
#   $BASH_SOURCE 指向 /dev/fd/63, "脚本旁边"永远是空的, 于是适配器找不到,
#   状态一律显示"未运行" (而服务其实跑得好好的)。必须三级查找, 最后现拉。
#   现拉用本次运行的临时目录, 不做长期缓存 —— 脚本每次都是新拉的, 缓存住的
#   适配器会和它版本不一致。
_resolve_client() {
    local self d
    self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    for d in "$self" "$XRAY_BASE/conf" /root/catmi/xray/conf; do
        [[ -f "$d/share_client.py" ]] && { printf '%s' "$d/share_client.py"; return 0; }
    done
    local tmp; tmp=$(mktemp -d /tmp/.xshare-cli.XXXXXX) || return 1
    if curl -fsSL --max-time 20 "$XRAY_RAW/conf/share_client.py" -o "$tmp/share_client.py" 2>/dev/null; then
        printf '%s' "$tmp/share_client.py"; return 0
    fi
    rm -rf "$tmp"; return 1
}

SHARE_CLIENT="${SHARE_CLIENT:-$(_resolve_client)}"

# 提示函数 —— 本脚本在面板里是 `bash <(curl …)` 跑的，$BASH_SOURCE 指向
# /dev/fd/63，"脚本旁边"永远是空的。所以和 _resolve_client 一样三级查找，
# 最后现拉（XRAY_RAW 已在上面定义）。
if [[ -r "$XRAY_BASE/conf/lib/print.sh" ]]; then
    source "$XRAY_BASE/conf/lib/print.sh"
else
    _self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [[ -n "$_self" && -r "$_self/lib/print.sh" ]]; then
        source "$_self/lib/print.sh"
    else
        _ptmp="$(mktemp -d /tmp/.xprint.XXXXXX)" \
            && curl -fsSL --max-time 20 "$XRAY_RAW/conf/lib/print.sh" \
                   -o "$_ptmp/print.sh" 2>/dev/null \
            && source "$_ptmp/print.sh"
        if ! declare -F ok >/dev/null; then
            printf '  [X] 取不到 conf/lib/print.sh —— 提示函数不可用\n' >&2
            exit 1
        fi
    fi
fi

python() { command python3 "$@"; }

xapi() { SHARE_PROVIDER=xray python "$SHARE_CLIENT" "$@"; }

share_port() {
    local p=""
    [[ -f "$SHARE_CLIENT" ]] && p=$(xapi port 2>/dev/null)
    printf '%s' "${p:-9443}"
}

# 端口在不在听。ss 可能不可用 (容器缺 NETLINK) —— 分不清"没在听"和"查不了",
# 这时不能报"未监听"。
port_listening() {
    local port="$1" dump
    dump=$(ss -tulnH 2>/dev/null | grep -cE "[:.]${port}[[:space:]]") || dump=0
    [[ "$dump" -gt 0 ]]
}

# ---------------------------------------------------------------- 动作
ensure_share() {
    [[ -f "$SHARE_CLIENT" ]] || { err "找不到 share_client.py, 先确认 conf/ 已部署"; return 1; }
    info "确保公共分享服务在位 (幂等; 已有则空操作)"
    local p; p=$(xapi ensure 2>/dev/null) || { err "公共服务不可用"; return 1; }
    ok "公共分享服务运行中 (端口 ${p:-$(share_port)})"
}

status_share() {
    local port; port=$(share_port)
    local h; h=$(xapi health 2>/dev/null)
    if [[ -n "$h" ]]; then
        ok "proxy-share-service 运行中"
        info "端口 $port"
        port_listening "$port" && info "端口 $port 在监听" \
            || warn "服务在跑但 $port 看不到监听 (ss 可能不可用)"
        printf '%s' "$h" | python -c '
import sys, json
d = json.load(sys.stdin)
print("  版本: %s (api v%s)" % (d.get("version","?"), d.get("api_version","?")))
ps = d.get("providers", {})
print("  各内核分享: %s" % (", ".join("%s=%d" % (k, v["total"]) for k, v in sorted(ps.items())) or "（无）"))
' 2>/dev/null >&2
    else
        warn "proxy-share-service 未运行或不可达"
        info "可用菜单 1) 确保在位 来安装/修复它"
    fi
    info "Xray 分享目录(仅存分享元数据): $SHARE_DIR"
}

show_providers() {
    local h; h=$(xapi health 2>/dev/null)
    [[ -n "$h" ]] || { err "公共服务不可达"; return 1; }
    printf '%s' "$h" | python -c '
import sys, json
ps = json.load(sys.stdin).get("providers", {})
if not ps:
    print("  （还没有任何内核登记过分享）"); raise SystemExit
print("  %-12s %6s %6s %6s %6s %6s" % ("PROVIDER", "总数", "活跃", "node", "config", "file"))
for k, v in sorted(ps.items()):
    print("  %-12s %6d %6d %6d %6d %6d" % (
        k, v["total"], v.get("active", 0), v.get("node", 0),
        v.get("config", 0), v.get("file", 0)))
' >&2
    info "provider 是隔离边界: X 只看得到 xray 那一行, 也删不掉别人的记录"
}

upgrade_share() {
    # 升级走公共服务自己的 install.sh —— 这里不重复实现一套
    local tmp; tmp=$(mktemp -d) || return 1
    info "从 GitHub 取 Share-Service 的安装器"
    if ! curl -fsSL --max-time 30 \
        https://raw.githubusercontent.com/mi1314cat/Share-Service/main/install.sh \
        -o "$tmp/install.sh"; then
        rm -rf "$tmp"; err "下载失败 (网络?)"; return 1
    fi
    bash "$tmp/install.sh" upgrade
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

# 防火墙只提示不擅改 —— 擅自改规则可能把用户其它放行弄丢,
# 而"外网连不上"十有八九确实是这里, 但决定权在用户。
check_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status 2>/dev/null | grep -qE "^${port}\b"; then
            ok "ufw 已放行 $port"
        else
            warn "ufw 未放行 $port, 外网会连不上。手动放行: ufw allow ${port}/tcp"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --list-ports 2>/dev/null | grep -qE "(^| )${port}/tcp( |$)"; then
            ok "firewalld 已放行 $port/tcp"
        else
            warn "firewalld 未放行 $port/tcp。手动放行: firewall-cmd --add-port=${port}/tcp --permanent && firewall-cmd --reload"
        fi
    fi
}

share_service_menu() {
    while :; do
        printf "\n${_CYN}===== 分享服务 =====${_RST}\n" >&2
        local port st="未运行"
        port=$(share_port)
        xapi health >/dev/null 2>&1 && st="运行中"
        cat >&2 <<EOF
  当前状态: $st    端口 $port
  说明: 这是 **M/SB/X 共用的公共基础服务**, 本面板只能确保它在位, 不能停它
        (停掉会连带打断另外两个内核已经发出去的链接)

  1) 确保在位 (安装 / 修复)
  2) 启动 / 重启      (仅当未运行; 不动数据)
  3) 查看状态
  4) 各内核分享统计
  5) 升级服务代码
  6) 检查防火墙放行
  0) 返回
EOF
        printf "  选择: " >&2
        read -r c || return 0
        case "$c" in
            1) ensure_share ;;
            2)
                if xapi health >/dev/null 2>&1; then
                    info "已经在运行 —— 不做任何改动 (重启会瞬断另外两个内核的链接)"
                else
                    systemctl restart proxy-share-service 2>/dev/null \
                        && ok "已重启" || { warn "systemctl 重启失败, 改用确保在位"; ensure_share; }
                fi
                ;;
            3) status_share ;;
            4) show_providers ;;
            5) upgrade_share ;;
            6) check_firewall "$port" ;;
            0|"") return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-menu}" in
        ensure)  ensure_share ;;
        status)  status_share ;;
        port)    share_port; echo ;;
        health)  xapi health >/dev/null 2>&1 && echo ok || { echo down; exit 1; } ;;
        menu)    share_service_menu ;;
        *) echo "用法: share_service.sh [menu|ensure|status|port|health]" >&2; exit 1 ;;
    esac
fi
