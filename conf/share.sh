#!/usr/bin/env bash
# Xray 分享管理 —— 生成 token / 启停 / 改次数 / 改有效期 / 列出 / 撤销
#
# 设计原则 (与 SB/M 一致, 但载荷是 Xray 自己的分享链接):
#   · 一个 token = 一份订阅 = 若干节点
#   · token 可以有 max_uses 和 TTL
#   · 节点被删时, 关联 token 要能看出"少了个节点"而不是静默少发

set -uo pipefail

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
CONF_DIR="${XRAY_CONF_DIR:-$XRAY_BASE/conf}"
SHARE_DIR="${XRAY_SHARE_DIR:-$XRAY_BASE/out/share}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib"
SHARE_PORT="${XRAY_SHARE_PORT:-9443}"
SHARE_ADDR="${XRAY_SHARE_ADDR:-127.0.0.1}"

_RED=$'\033[31m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _CYN=$'\033[36m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
[[ -t 2 ]] || { _RED=""; _GRN=""; _YEL=""; _CYN=""; _DIM=""; _RST=""; }

ok()   { printf "  ${_GRN}[OK]${_RST} %s\n" "$*" >&2; }
info() { printf "  ${_CYN}[--]${_RST} %s\n" "$*" >&2; }
warn() { printf "  ${_YEL}[!]${_RST} %s\n" "$*" >&2; }
err()  { printf "  ${_RED}[X]${_RST} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

python() { command python3 "$@"; }

# ---------------------------------------------------------------- 节点列表
list_nodes() {
    python "$LIB_DIR/nodes.py" "$CONF_DIR"
}

# ---------------------------------------------------------------- token 生成
gen_token() {
    mkdir -p "$SHARE_DIR/tokens"
    # token 用 secrets 而不是 $RANDOM —— 分享链接是访问凭证, 可预测的随机数
    # 等于没有随机数。
    local tok
    tok=$(python3 -c "import secrets;print(secrets.token_urlsafe(18))")
    tok=$(printf '%s' "$tok" | tr -d '=+/' | cut -c1-24)
    [[ -f "$SHARE_DIR/tokens/$tok.json" ]] && die "token 撞号, 重试"
    printf '%s' "$tok"
}

share_create() {
    local name="" max_uses=0 ttl_days=0
    local -a tags=()

    printf "\n${_CYN}=== 生成分享链接 ===${_RST}\n" >&2

    info "当前节点:"
    list_nodes >&2 || true
    printf '\n' >&2

    printf "  选择要分享的节点 (编号, 空格分隔; 留空=全部): " >&2
    read -r sel || true
    if [[ -z "${sel// /}" ]]; then
        mapfile -t tags < <(python -c "
import sys; sys.path.insert(0,'$LIB_DIR'); import nodes
n,_=nodes.collect('$CONF_DIR')
print('\n'.join(x['tag'] for x in n))")
        info "已选择全部 ${#tags[@]} 个节点"
    else
        local all; mapfile -t all < <(python -c "
import sys; sys.path.insert(0,'$LIB_DIR'); import nodes
n,_=nodes.collect('$CONF_DIR')
print('\n'.join(x['tag'] for x in n))")
        for i in $sel; do
            local idx=$((i - 1))
            [[ $idx -ge 0 && $idx -lt ${#all[@]} ]] || die "编号 $i 超出范围"
            tags+=("${all[$idx]}")
        done
    fi
    ((${#tags[@]} > 0)) || die "没有选中任何节点"

    printf "  分享名称 [分享-${_RST}]: " >&2; read -r name || true
    [[ -n "$name" ]] || name="分享"

    printf "  最多可拉取次数 [0=不限]: " >&2; read -r max_uses || true
    [[ "$max_uses" =~ ^[0-9]+$ ]] || max_uses=0

    printf "  有效期天数 [0=永久]: " >&2; read -r ttl_days || true
    [[ "$ttl_days" =~ ^[0-9]+$ ]] || ttl_days=0

    local tok; tok=$(gen_token)
    local url="http://$SHARE_ADDR:$SHARE_PORT/sub/$tok"
    if [[ "$SHARE_ADDR" == "0.0.0.0" ]]; then
        local ip; ip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "<服务器IP>")
        url="http://$ip:$SHARE_PORT/sub/$tok"
    fi

    python - "$LIB_DIR" "$SHARE_DIR" "$tok" "$name" "$max_uses" "$ttl_days" "${tags[@]}" <<'PY' || die "写入 token 失败"
import sys, time
sys.path.insert(0, sys.argv[1])
import token_store as T
share_dir, tok, name, max_uses, ttl_days = sys.argv[2:7]
now = int(time.time())
meta = {
    "schema": 1, "token": tok, "name": name,
    "tags": sys.argv[7:],
    "enabled": True, "used_count": 0,
    "max_uses": int(max_uses),
    "expires_at": (now + int(ttl_days) * 86400) if int(ttl_days) else 0,
    "created_at": now,
}
T.write(share_dir, tok, meta)
PY

    # 链接生成成功但服务没跑的话, 面板显示一切正常, 客户端一律连不上,
    # 而且排查会被引向防火墙。所以在这里就确认服务可用。
    ensure_service || warn "分享服务未就绪, 链接已保存但现在拉不动 —— 服务起来后立刻可用"

    ok "分享已生成"
    printf "\n    ${_GRN}%s${_RST}\n\n" "$url" >&2
    printf "    节点: %s\n" "${tags[*]}" >&2
    printf "    %s次数: %s${_RST}   %s有效期: %s 天${_RST}\n" \
        "$_DIM" "$([[ "$max_uses" == 0 ]] && echo 不限 || echo "$max_uses")" \
        "$_DIM" "$([[ "$ttl_days" == 0 ]] && echo 永久 || echo "$ttl_days")" >&2
}

# ---------------------------------------------------------------- 列表
share_list() {
    printf "\n${_CYN}=== 分享列表 ===${_RST}\n" >&2
    python - "$LIB_DIR" "$SHARE_DIR" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import token_store as T
share_dir = sys.argv[2]
items = T.list_all(share_dir)
if not items:
    print("  (还没有生成分享)", file=sys.stderr); raise SystemExit(0)
now = int(time.time())
print(f"  {'TOKEN':<26} {'名称':<16} {'已用/上限':<10} {'过期':<12} {'状态':<6} 节点", file=sys.stderr)
for d in items:
    tok = d.get("token", "")
    if d.get("_broken"):
        print(f"  {tok:<26} {'!文件损坏':<16} {'-':<10} {'-':<12} {'损坏':<6} ", file=sys.stderr)
        continue
    # 状态判定与服务端共用 status_of —— 列表说"有效"而服务端发 410,
    # 是最难查的一类不一致。
    st = T.status_of(d, now)
    used, maxu = d.get("used_count", 0), d.get("max_uses", 0)
    exp = d.get("expires_at", 0)
    exps = "永久" if not exp else time.strftime("%Y-%m-%d", time.localtime(exp))
    tags = d.get("tags") or d.get("tag") or []
    if isinstance(tags, str): tags = [tags]
    print(f"  {tok:<26} {str(d.get('name',''))[:15]:<16} "
          f"{f'{used}/{maxu if maxu else chr(8734)}':<10} {exps:<12} {st:<6} {','.join(tags)[:40]}", file=sys.stderr)
PY
    printf '\n' >&2
}

# ---------------------------------------------------------------- 启停 / 撤销
share_toggle() {
    local tok="$1"
    python - "$LIB_DIR" "$SHARE_DIR" "$tok" <<'PY' || die "操作失败"
import sys
sys.path.insert(0, sys.argv[1])
import token_store as T
share_dir, tok = sys.argv[2:4]
res = {}
def _flip(m):
    if m.get("_broken"):
        print(f"token 文件损坏: {tok}", file=sys.stderr); return False
    m["enabled"] = not m.get("enabled", True)
    res["v"] = m["enabled"]
T.update(share_dir, tok, _flip)
if "v" not in res:
    print(f"找不到 token: {tok}", file=sys.stderr); raise SystemExit(1)
print("已启用" if res["v"] else "已停用", file=sys.stderr)
PY
}

share_revoke() {
    local tok="$1"
    python - "$LIB_DIR" "$SHARE_DIR" "$tok" <<'PY' || die "撤销失败"
import sys, time
sys.path.insert(0, sys.argv[1])
import token_store as T
share_dir, tok = sys.argv[2:4]
def _rev(m):
    if m.get("_broken"): return False
    m["enabled"] = False; m["revoked_at"] = int(time.time())
T.update(share_dir, tok, _rev) or print(f"找不到 token: {tok}", file=sys.stderr)
PY
    ok "已撤销 $tok"
}

share_set() {
    local tok="$1" field="$2" value="$3"
    python - "$LIB_DIR" "$SHARE_DIR" "$tok" "$field" "$value" <<'PY' || die "设置失败"
import sys
sys.path.insert(0, sys.argv[1])
import token_store as T
share_dir, tok, field, value = sys.argv[2:6]
def _set(m):
    if m.get("_broken"): return False
    if field == "max_uses":   m["max_uses"] = int(value or 0)
    elif field == "expires_at": m["expires_at"] = int(value or 0)
T.update(share_dir, tok, _set) or print(f"找不到 token: {tok}", file=sys.stderr)
PY
    ok "已更新 $tok"
}

# ---------------------------------------------------------------- 服务
svc_script() {
    printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/share_service.sh"
}

service_running() {
    local url="http://$SHARE_ADDR:$SHARE_PORT/status"
    curl -fsS --max-time 3 "$url" >/dev/null 2>&1
}

# 没在跑就装 + 起。已经是运行的, 什么都不做。
ensure_service() {
    service_running && return 0
    local svc; svc=$(svc_script)
    if [[ ! -f "$svc" ]]; then
        warn "找不到 share_service.sh, 分享服务无法自动启动"
        return 1
    fi
    info "分享服务未运行, 正在启动"
    XRAY_BASE="$XRAY_BASE" XRAY_SHARE_DIR="$SHARE_DIR"         XRAY_SHARE_PORT="$SHARE_PORT" XRAY_SHARE_ADDR="$SHARE_ADDR"         bash "$svc" install >/dev/null 2>&1         || { warn "分享服务启动失败"; return 1; }
    service_running
}

share_service_menu() {
    local svc; svc=$(svc_script)
    [[ -f "$svc" ]] || { err "找不到 share_service.sh"; return 1; }
    XRAY_BASE="$XRAY_BASE" XRAY_SHARE_DIR="$SHARE_DIR"         XRAY_SHARE_PORT="$SHARE_PORT" XRAY_SHARE_ADDR="$SHARE_ADDR"         bash "$svc" menu
}

# ---------------------------------------------------------------- 菜单
share_menu() {
    while :; do
        printf "\n${_CYN}===== 分享管理 =====${_RST}\n" >&2
        cat >&2 <<EOF
  1) 生成分享链接
  2) 分享列表
  3) 启停 / 撤销
  4) 改次数上限
  5) 改有效期
  6) 分享服务管理
  0) 返回
EOF
        printf "  选择: " >&2
        read -r c || return 0
        case "$c" in
            1) share_create ;;
            2) share_list ;;
            3)
                share_list
                printf "  token: " >&2; read -r t || true
                [[ -n "$t" ]] && share_toggle "$t"
                ;;
            4)
                share_list
                printf "  token: " >&2; read -r t || true
                printf "  新的次数上限 [0=不限]: " >&2; read -r v || true
                [[ -n "$t" ]] && share_set "$t" max_uses "$v"
                ;;
            5)
                share_list
                printf "  token: " >&2; read -r t || true
                printf "  新的有效期天数 [0=永久]: " >&2; read -r v || true
                [[ -n "$t" ]] && share_set "$t" expires_at "$(( $(date +%s) + ${v:-0} * 86400 ))"
                ;;
            6) share_service_menu ;;
            0|"") return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------- 直跑
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-menu}" in
        create) share_create ;;
        list)   share_list ;;
        menu)   share_menu ;;
        *) die "用法: share.sh [menu|create|list]" ;;
    esac
fi