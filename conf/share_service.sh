#!/usr/bin/env bash
# 分享服务管理 —— 安装 / 启停 / 查看状态
#
# 分享链接生成出来就必须能拉取。token 落盘了但服务没跑, 面板一切正常,
# 客户端一律 connection refused, 而且排查会被引向防火墙。
# 所以安装/启停这块是分享功能可用性的前提, 不是附加项。

set -uo pipefail

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib"
SHARE_DIR="${XRAY_SHARE_DIR:-$XRAY_BASE/out/share}"
SHARE_PORT="${XRAY_SHARE_PORT:-9443}"
SHARE_ADDR="${XRAY_SHARE_ADDR:-127.0.0.1}"
XRAY_SERVICE="${XRAY_SERVICE:-xrayls}"
UNIT="xray-share"

_RED=$'\033[31m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _CYN=$'\033[36m'; _RST=$'\033[0m'
[[ -t 2 ]] || { _RED=""; _GRN=""; _YEL=""; _CYN=""; _RST=""; }
ok()   { printf "  ${_GRN}[OK]${_RST} %s\n" "$*" >&2; }
info() { printf "  ${_CYN}[--]${_RST} %s\n" "$*" >&2; }
warn() { printf "  ${_YEL}[!]${_RST} %s\n" "$*" >&2; }
err()  { printf "  ${_RED}[X]${_RST} %s\n" "$*" >&2; }

# 找 share_server.py —— 本地找不到就拉仓库里那份。
# 自解析脚本自身目录: 被 curl 到临时路径运行时, $0 指向的是临时副本,
# ExecStart 必须指向真正的安装位置。
resolve_server() {
    local d
    for d in "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib" "$LIB_DIR" "/root/catmi/xray/conf/lib"; do
        [[ -f "$d/share_server.py" ]] && { printf '%s' "$d/share_server.py"; return 0; }
    done
    return 1
}

server_running() { systemctl is-active --quiet "$UNIT" 2>/dev/null; }

# 端口在不在听。注意 ss 可能不可用 (容器缺 NETLINK) —— 分不清"没在听"和
# "查不了", 这时不能报"未监听"。
port_listening() {
    local dump
    dump=$(ss -tulnH 2>/dev/null | grep -cE "[:.]${SHARE_PORT}[[:space:]]") || dump=0
    [[ "$dump" -gt 0 ]]
}

install_share() {
    local srv; srv=$(resolve_server) || {
        err "找不到 share_server.py, 先确认 conf/lib/ 已部署"; return 1; }

    info "写入 systemd 单元 $UNIT.service"
    cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Xray Share Server (订阅分发)
After=network.target $XRAY_SERVICE.service

[Service]
Type=simple
Environment="XRAY_CONF_DIR=$XRAY_BASE/conf"
Environment="XRAY_SHARE_DIR=$SHARE_DIR"
Environment="XRAY_SHARE_ADDR=$SHARE_ADDR"
Environment="XRAY_SHARE_PORT=$SHARE_PORT"
Environment="XRAY_SERVICE=$XRAY_SERVICE"
ExecStart=$(command -v python3) $srv
Restart=on-failure
RestartSec=3
# 只读令牌和片段。分享服务没有任何理由写配置。
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    ok "单元已写入 /etc/systemd/system/$UNIT.service"
    info "配置: conf=$XRAY_BASE/conf share=$SHARE_DIR listen=$SHARE_ADDR:$SHARE_PORT"
}

start_share() {
    systemctl restart "$UNIT" 2>/dev/null
    # 监听是异步绑定的, restart 返回不等于已经在听。
    for _ in $(seq 1 15); do
        if port_listening; then
            curl -fsS --max-time 3 "http://$SHARE_ADDR:$SHARE_PORT/status" >/dev/null 2>&1 && {
                ok "分享服务已启动 (http://$SHARE_ADDR:$SHARE_PORT)"; return 0; }
        fi
        sleep 0.3
    done

    err "分享服务没能起来, 看日志: journalctl -u $UNIT -n 30 --no-pager"
    # 已经在跑但端口没动 —— 大概率是端口被占, 这时把占用的进程报出来,
    # 否则用户只能自己 ss 去猜。
    local who; who=$(ss -tulnpH 2>/dev/null | grep -E "[:.]${SHARE_PORT}[[:space:]]" | head -1)
    [[ -n "$who" ]] && warn "端口 $SHARE_PORT 被占用: $who"
    return 1
}

stop_share() {
    systemctl stop "$UNIT" 2>/dev/null && ok "分享服务已停止" || err "停止失败"
}

restart_share() { systemctl restart "$UNIT" && ok "分享服务已重启" || err "重启失败"; }

status_share() {
    if server_running; then
        ok "$UNIT 运行中"
        port_listening && info "端口 $SHARE_PORT 在监听" || warn "服务在跑但 $SHARE_PORT 看不到监听"
        curl -fsS --max-time 3 "http://$SHARE_ADDR:$SHARE_PORT/status" 2>/dev/null | sed 's/^/  /' \
            || warn "健康检查无响应"
    else
        warn "$UNIT 未运行"
    fi
    info "分享目录: $SHARE_DIR"
}

# 防火墙只提示不擅改 —— 擅自改防火墙规则可能把用户其它放行弄丢,
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
        local st="未运行"
        server_running && st="运行中"
        cat >&2 <<EOF
  当前状态: $st    监听 $SHARE_ADDR:$SHARE_PORT

  1) 安装并启动
  2) 启动 / 重启
  3) 停止
  4) 查看状态
  5) 检查防火墙放行
  0) 返回
EOF
        printf "  选择: " >&2
        read -r c || return 0
        case "$c" in
            1) install_share && start_share && check_firewall "$SHARE_PORT" ;;
            2) start_share ;;
            3) stop_share ;;
            4) status_share ;;
            5) check_firewall "$SHARE_PORT" ;;
            0|"") return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-menu}" in
        install) install_share && start_share ;;
        start)   start_share ;;
        stop)    stop_share ;;
        restart) restart_share ;;
        status)  status_share ;;
        menu)    share_service_menu ;;
        *) echo "用法: share_service.sh [menu|install|start|stop|restart|status]" >&2; exit 1 ;;
    esac
fi