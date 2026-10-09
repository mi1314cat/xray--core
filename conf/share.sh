#!/usr/bin/env bash
# Xray 分享管理 —— 生成 / 列表 / 启停撤销 / 改次数 / 改有效期 / 服务管理
#
# ==============================================================
# 分享的**存储与生命周期** (Token / TTL / max_uses / 次数 / 过期) 归
# **公共基础服务** proxy-share-service —— 它是服务器上的公共基础服务,
# M / SB / X 三个内核共用, 不是 Xray 的子服务。
#
# Xray 只负责两件事:
#   1. **生成内容** —— 把 conf/ 片段变成 base64 订阅 (这是内核自己的知识)
#   2. **决定何时创建与刷新** —— 节点增删后要把新内容推上去
#
# 面板怎么展示也是我们自己的事。
#
# provider 固定 `xray` —— 公共服务的列表/删除接口**强制**要求 provider,
# 所以 X 在结构上看不到、也删不掉 M / SB 的记录。
#
# 载荷格式**一字未改**: base64 的订阅行。已发出去的链接、已经导入过的
# 客户端都按这个格式解析, 改格式等于把所有人踢下线。
#
# ⚠ 路径变了: 本地服务端原来发 `/sub/<token>`, 公共基础服务发
#   `/share/<token>` (与 M/SB 统一)。老链接失效 —— 那台本地服务已经不存在了,
#   保留旧路径没有任何意义。
# ==============================================================

set -uo pipefail

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
CONF_DIR="${XRAY_CONF_DIR:-$XRAY_BASE/conf}"
SHARE_DIR="${XRAY_SHARE_DIR:-$XRAY_BASE/out/share}"
XRAY_RAW="${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}"

# ---------------------------------------------------------------- 依赖定位
# ★ 面板里每一项都是 `bash <(curl -Ls .../conf/xxx.sh)` 跑的 —— $BASH_SOURCE
#   指向 /dev/fd/63, 于是 `dirname $BASH_SOURCE` = /dev/fd, 拼出来的
#   /dev/fd/lib 永远不存在。实测原话:
#       python3: can't open file '/dev/fd/lib/nodes.py': [Errno 2] ...
#   这是**既有问题, 不只影响分享** —— 菜单 11 的 node.sh 同样报这个错。
#
#   所以依赖一律三级查找: 脚本旁边 (从仓库直接跑) -> 安装目录 -> 现拉。
#   现拉用**本次运行的临时目录**, 不做长期缓存: 脚本本身每次都是新拉的,
#   缓存住的库会和它版本不一致, 那种错更难查。
_x_self_dir() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd; }

_x_fetch() { # <仓库相对路径> <目标文件>
    mkdir -p "$(dirname "$2")" 2>/dev/null || return 1
    curl -fsSL --max-time 20 "$XRAY_RAW/$1" -o "$2.tmp" 2>/dev/null || { rm -f "$2.tmp"; return 1; }
    mv -f "$2.tmp" "$2"
}

# 打印一个可用的 lib 目录 (含 nodes.py / share_payload.py 等)
_x_ensure_lib() {
    local d self; self=$(_x_self_dir)
    for d in "$self/lib" "$XRAY_BASE/conf/lib" /root/catmi/xray/conf/lib; do
        [[ -f "$d/nodes.py" && -f "$d/share_payload.py" && -f "$d/share_meta.py" ]] \
            && { printf '%s' "$d"; return 0; }
    done
    local tmp; tmp=$(mktemp -d /tmp/.xshare-lib.XXXXXX) || return 1
    local f
    for f in nodes.py share_meta.py share_payload.py token_store.py; do
        _x_fetch "conf/lib/$f" "$tmp/$f" || { rm -rf "$tmp"; return 1; }
    done
    printf '%s' "$tmp"
}

# 打印可用的 share_client.py
_x_ensure_client() {
    local d self; self=$(_x_self_dir)
    for d in "$self" "$XRAY_BASE/conf" /root/catmi/xray/conf; do
        [[ -f "$d/share_client.py" ]] && { printf '%s' "$d/share_client.py"; return 0; }
    done
    local tmp; tmp=$(mktemp -d /tmp/.xshare-cli.XXXXXX) || return 1
    _x_fetch "conf/share_client.py" "$tmp/share_client.py" || { rm -rf "$tmp"; return 1; }
    printf '%s' "$tmp/share_client.py"
}

LIB_DIR="$(_x_ensure_lib)" || LIB_DIR="$(_x_self_dir)/lib"

# 提示函数 —— 与 addr.sh 同一套三级查找：脚本旁边 -> 安装目录 -> 现拉。
if [[ -r "$LIB_DIR/print.sh" ]]; then
    source "$LIB_DIR/print.sh"
else
    _x_fetch "conf/lib/print.sh" "$LIB_DIR/print.sh" 2>/dev/null \
        && source "$LIB_DIR/print.sh" \
        || { printf '  [X] 提示函数库加载失败\n' >&2; exit 1; }
fi

# 对外地址探测库 —— 地址族切换要用 (x_addr6_real / x_iface_public_addr)。
# 与其它脚本同一套三级查找: 脚本旁边 -> 安装目录 -> 现拉。
if [[ -r "$LIB_DIR/addr.sh" ]]; then
    source "$LIB_DIR/addr.sh"
else
    _x_fetch "conf/lib/addr.sh" "$LIB_DIR/addr.sh" 2>/dev/null && source "$LIB_DIR/addr.sh" \
        || warn "地址库加载失败 —— 地址族切换不可用"
fi
SHARE_ADDR="${XRAY_SHARE_ADDR:-127.0.0.1}"


python() { command python3 "$@"; }

# ---------------------------------------------------------------- 节点列表
list_nodes() {
    python "$LIB_DIR/nodes.py" "$CONF_DIR"
}

# ==============================================================
# 公共分享服务适配层
# ==============================================================
SHARE_CLIENT="${SHARE_CLIENT:-$(_x_ensure_client)}"

# 公共服务实际端口 —— 它可能因端口回避而不是 9443, 绝不能写死。
x_share_port() {
    local p=""
    [[ -f "$SHARE_CLIENT" ]] && p=$(python "$SHARE_CLIENT" port 2>/dev/null)
    printf '%s' "${p:-9443}"
}

# 确保公共服务在位 (不存在则从独立项目装)。装有检验、幂等, 多内核共用。
#
# 返回约定: 成功时 **stdout 输出端口** + 退出码 0; 失败退出码非 0。
# (SB 那边踩过: 只返回退出码而调用方写 port=$(...) 再判空, 于是服务
#  明明活着也永远判成"不可用"。端口只在这一处吐。)
x_share_ensure() {
    [[ -f "$SHARE_CLIENT" ]] || return 1
    local p
    p=$(SHARE_PROVIDER=xray python "$SHARE_CLIENT" ensure 2>/dev/null) || return 1
    printf '%s' "${p:-$(x_share_port)}"
}

# 适配器透传。适配器的 stdout 只放数据, 所以可以直接接。
_x_share_api() { SHARE_PROVIDER=xray python "$SHARE_CLIENT" "$@"; }

_x_share_list() { _x_share_api list 2>/dev/null; }

# 编号 / token / 前缀 / 名称 -> 完整 token
_x_share_find() {
    local c="${1:-}" js
    js=$(_x_share_list)
    [[ -z "$js" || "$js" == "[]" ]] && return 1
    printf '%s' "$js" | python -c '
import sys, json
c = sys.argv[1]
try: recs = json.load(sys.stdin)
except Exception: recs = []
if c.isdigit():
    i = int(c)
    if 1 <= i <= len(recs):
        print(recs[i-1]["token"]); raise SystemExit
for r in recs:
    t = r.get("token",""); m = r.get("meta") or {}
    if t == c or t.startswith(c) or str(m.get("name","")) == c:
        print(t); raise SystemExit
raise SystemExit(1)
' "$c"
}

# 读一条记录里的某个字段 (meta 里的用 meta.xxx)
_x_share_field() {
    _x_share_api get --token "$1" 2>/dev/null | python -c '
import sys, json
k = sys.argv[1]
try: r = json.load(sys.stdin)
except Exception: raise SystemExit(1)
if k.startswith("meta."):
    v = (r.get("meta") or {}).get(k[5:], "")
else:
    v = r.get(k, "")
print(v if v is not None else "")
' "$2" 2>/dev/null
}

# ---------------------------------------------------------------- 载荷构建
# 按 tag 列表重建 base64 订阅, 写到临时文件。成功打印临时文件路径。
#
# ★ 走 conf/lib/share_payload.py —— 与"刷新已发链接"用的是**同一份**实现。
#   抄一遍必然漂移, 表现是"新建的链接对、刷新过的链接少个节点"。
x_share_build_payload() {
    local out; out=$(mktemp /tmp/.xshare.XXXXXX) || return 1
    if ! python - "$LIB_DIR" "$CONF_DIR" "$SHARE_DIR" "$out" "$@" <<'PY' 2>/tmp/.xshare.err
import sys, os
lib_dir, conf_dir, share_dir, out = sys.argv[1:5]
tags = sys.argv[5:]
os.environ["XRAY_CONF_DIR"] = conf_dir
os.environ["XRAY_SHARE_DIR"] = share_dir
sys.path.insert(0, lib_dir)
import share_payload
payload, missing, nometa, bad = share_payload.build_payload(tags)
if payload is None:
    print("无可分发内容 (片段没了? 缺对外地址?)", file=sys.stderr)
    raise SystemExit(1)
with open(out, "w", encoding="utf-8") as fh:
    fh.write(payload)
# 三类"没发出去"分开报 —— 合并成一条就查不出是哪一种
for label, items in (("节点已删", missing), ("缺分享元数据", nometa)):
    if items:
        print("%s: %s" % (label, ",".join(items)), file=sys.stderr)
if bad:
    print("片段解析失败: %d 个" % len(bad), file=sys.stderr)
PY
    then
        rm -f "$out"; sed 's/^/    /' /tmp/.xshare.err >&2 2>/dev/null
        return 1
    fi
    sed 's/^/    /' /tmp/.xshare.err >&2 2>/dev/null
    printf '%s' "$out"
}

# ---------------------------------------------------------------- 生成
share_create() {
    local name="" max_uses=0 ttl_days=0
    local -a tags=()

    printf "\n${_CYN}=== 生成分享链接 ===${_RST}\n" >&2

    info "当前节点:"
    list_nodes >&2 || true
    printf '\n' >&2

    printf "  选择要分享的节点 (编号, 空格分隔; 留空=全部): " >&2
    read -r sel || true
    local -a all
    mapfile -t all < <(python -c "
import sys; sys.path.insert(0,'$LIB_DIR'); import nodes
n,_=nodes.collect('$CONF_DIR')
print('\n'.join(x['tag'] for x in n))")
    if [[ -z "${sel// /}" ]]; then
        tags=("${all[@]}")
        info "已选择全部 ${#tags[@]} 个节点"
    else
        local i idx
        for i in $sel; do
            idx=$((i - 1))
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

    # 公共服务不在就装 (幂等; 已有则空操作)
    local port; port=$(x_share_ensure)
    [[ -n "$port" ]] || die "公共分享服务不可用 —— 分享链接暂时发不出去"

    local payload; payload=$(x_share_build_payload "${tags[@]}") \
        || die "生成订阅内容失败 (看上面对应原因)"

    # tags / name 存进 meta —— 刷新时要靠它重建内容。
    # 公共服务只存不读, 这是"内核用它记自己的东西"的正当用法。
    local meta
    meta=$(python -c '
import json, sys
tags = sys.argv[1:]
print(json.dumps({"name": tags[0], "tags": tags[1:]}, ensure_ascii=False))
' "$name" "${tags[@]}")

    local rec token
    rec=$(_x_share_api create --type node --content-file "$payload" \
            --ttl $((ttl_days * 86400)) --max-uses "$max_uses" --meta "$meta" 2>&1) || {
        rm -f "$payload"; die "公共服务创建分享失败: $rec"; }
    rm -f "$payload"
    token=$(printf '%s' "$rec" | python -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    [[ -n "$token" ]] || die "公共服务没有返回 token"

    # 链接里的主机名必须是**客户端连得上的入站地址**。
    #
    # ★ 不能用 api.ipify.org 这类"我的 IP"服务: 它答的是**出站出口**。
    #   本机走了 WARP / 代理时, 问出来的是 WARP 的 IP —— 实测 RN 上
    #   WARP 开着, 生成出来是 104.28.201.80, 而服务器入站是 107.173.154.178,
    #   客户端照着连必然不通, 而且链接看起来完全正常。
    #
    #   最可靠的来源是节点自己的 share_meta.host —— 那正是客户端连这个节点
    #   用的地址 (deploy 时写进去的), 与节点能不能连是同一个事实。
    local host=""
    host=$(LIB="$LIB_DIR" SHARE_DIR="$SHARE_DIR" TAG="${tags[0]}" python -c '
import os, sys
sys.path.insert(0, os.environ["LIB"])
import share_meta
m = share_meta.load(os.environ["SHARE_DIR"], os.environ["TAG"]) or {}
print(m.get("host", ""))
' 2>/dev/null)
    if [[ -z "$host" ]]; then
        # 退一步: 本机第一个非回环地址。依然不问外部服务。
        host=$(hostname -I 2>/dev/null | tr " " "\n" | grep -vE "^(127\.|::1|$)" | head -1)
    fi
    [[ -n "$host" ]] || host="<服务器IP>"
    local url="http://$host:$port/share/$token"

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
    # ★ 先分清"没有分享"和"服务不可达"。
    #   适配器在服务挂掉时返回空 —— 直接当成"没有分享"是在说谎: 用户会以为
    #   自己没建过链接 (或者以为被谁删了), 而真实原因是服务没跑。
    if ! _x_share_api health >/dev/null 2>&1; then
        err "公共分享服务不可达 —— 看不到列表, 不代表没有分享"
        info "用菜单 6) 分享服务管理 -> 1) 确保在位 来修复"
        printf '\n' >&2
        return 1
    fi
    local js; js=$(_x_share_list)
    if [[ -z "$js" || "$js" == "[]" ]]; then
        info "(还没有生成分享)"
        printf '\n' >&2
        return 0
    fi
    # ★ 数据不能用 `<<'PY'` + `< <(...)` 两条 stdin 重定向同时喂 ——
    #   后一条会把前一条覆盖掉, 于是 python 拿到的是 **JSON 当脚本**,
    #   报 `name 'true' is not defined` 这种跟业务毫无关系的错。
    #   走环境变量最稳。
    XJS="$js" python -c '
import os, sys, json, time
recs = json.loads(os.environ["XJS"])
fmt = "  %-5s%-20s%-16s%-11s%-12s%-7s%s"
print(fmt % ("编号", "TOKEN", "名称", "已用/上限", "过期", "状态", "节点"), file=sys.stderr)
for i, r in enumerate(recs, 1):
    m = r.get("meta") or {}
    exp = int(r.get("expires_at", 0))
    exps = "永久" if not exp else time.strftime("%Y-%m-%d", time.localtime(exp))
    used = int(r.get("used_count", 0)); maxu = int(r.get("max_uses", 0))
    uses = "%d/%s" % (used, maxu if maxu else "∞")
    tags = m.get("tags") or []
    if isinstance(tags, str): tags = [tags]
    print(fmt % (i, str(r.get("token", ""))[:18], str(m.get("name", ""))[:15],
                 uses, exps, r.get("state", ""), ",".join(tags)[:40]), file=sys.stderr)
'
    printf '\n' >&2
    info "拉取地址: http://<服务器IP>:$(x_share_port)/share/<token>"
}

# ---------------------------------------------------------------- 启停 / 撤销
share_toggle() {
    local tok; tok=$(_x_share_find "$1") || die "找不到: $1"
    local cur want
    cur=$(_x_share_field "$tok" enabled)
    [[ "$cur" == "True" ]] && want=false || want=true
    _x_share_api update --token "$tok" --enabled "$want" >/dev/null 2>&1 \
        || die "切换失败"
    # 回读确认 —— 静默失败在旧实现里踩过
    [[ "$(_x_share_field "$tok" enabled)" == "$([[ "$want" == true ]] && echo True || echo False)" ]] \
        || die "切换未生效"
    ok "$([[ "$want" == true ]] && echo 已启用 || echo 已停用) $tok"
}

share_revoke() {
    local tok; tok=$(_x_share_find "$1") || die "找不到: $1"
    _x_share_api delete --token "$tok" >/dev/null 2>&1 || die "撤销失败"
    _x_share_api get --token "$tok" >/dev/null 2>&1 && die "撤销未生效 (记录还在)"
    ok "已撤销 $tok"
}

share_set() {
    local tok; tok=$(_x_share_find "$1") || die "找不到: $1"
    case "$2" in
        max_uses)   _x_share_api update --token "$tok" --max-uses "${3:-0}" >/dev/null 2>&1 \
                        || die "设置失败" ;;
        expires_at) # 公共服务用 ttl(相对秒) 或 expires_at(绝对)。
                    # 这里给的是绝对时间戳, 直接透传 —— 用 ttl 反推会算错,
                    # 而且"已经过期"的时间点用 ttl 表达不出来 (负数非法)。
                    _x_share_api update --token "$tok" --expires-at "${3:-0}" >/dev/null 2>&1 \
                        || die "设置失败" ;;
        *) die "未知字段: $2" ;;
    esac
    ok "已更新 $tok"
}

# ---------------------------------------------------------------- 内容保鲜
# 节点增删/改动之后, 已发出去的链接内容会变旧 —— 客户端再拉还是老的订阅。
# 这里按记录里的 tags 重建内容, 变了才 PUT (token/URL 不变)。
#
# ★ 不做这件事的后果是静默的: 面板显示一切正常, 链接也能打开,
#   只是少了一个节点 / 还留着已删的节点, 没人会发现。
share_refresh_all() {
    local js; js=$(_x_share_list)
    [[ -z "$js" || "$js" == "[]" ]] && return 0

    # 刷新是"尽力而为": 绝不为了刷新去装服务 (节点生成路径不能被网络安装阻塞),
    # 但服务不可达时必须**说出来** —— 否则已有链接会一直发旧内容而无人察觉。
    if ! _x_share_api health >/dev/null 2>&1; then
        warn "公共分享服务不可达, 已有分享链接的内容未刷新"
        return 0
    fi

    local n=0 tok name tags newh curh payload
    while IFS=$'\t' read -r tok name tags; do
        [[ -n "$tok" ]] || continue
        [[ -n "$tags" ]] || continue
        # shellcheck disable=SC2086
        payload=$(x_share_build_payload $(printf '%s' "$tags" | tr ',' ' ')) || continue
        newh=$(sha256sum "$payload" | awk '{print $1}')
        curh=$(_x_share_api get --token "$tok" 2>/dev/null \
               | python -c 'import sys,json
try: print(json.load(sys.stdin).get("content_sha256",""))
except Exception: print("")' 2>/dev/null)
        if [[ "$newh" != "$curh" ]]; then
            _x_share_api update --token "$tok" --content-file "$payload" >/dev/null 2>&1 \
                && n=$((n + 1))
        fi
        rm -f "$payload"
    done < <(printf '%s' "$js" | python -c '
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    m = r.get("meta") or {}
    tags = m.get("tags") or []
    if isinstance(tags, list) and tags:
        print("%s\t%s\t%s" % (r.get("token",""), m.get("name",""), ",".join(tags)))
' 2>/dev/null)

    (( n > 0 )) && info "已刷新 ${n} 条分享链接的内容 (token 与地址未变)"
    return 0
}

# ---------------------------------------------------------------- 服务管理
# 菜单第 6 项。以前这里管的是**本机自己的** xray-share 服务端 (端口 9443);
# 那个服务已经不存在了 —— 存储与生命周期归公共基础服务。
# 文案与菜单项保持不变, 内容改成管公共服务。
svc_script() {
    printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/share_service.sh"
}

service_running() {
    [[ -f "$SHARE_CLIENT" ]] && _x_share_api health >/dev/null 2>&1
}

# 兼容旧调用点: 没在跑就装 + 起。
ensure_service() {
    service_running && return 0
    info "公共分享服务未运行, 正在确保它在位"
    x_share_ensure >/dev/null || { warn "公共分享服务启动失败"; return 1; }
    service_running
}

share_service_menu() {
    local svc; svc=$(svc_script)
    [[ -f "$svc" ]] || { err "找不到 share_service.sh"; return 1; }
    XRAY_BASE="$XRAY_BASE" XRAY_SHARE_DIR="$SHARE_DIR" \
        XRAY_SHARE_ADDR="$SHARE_ADDR" \
        bash "$svc" menu
}

# ---------------------------------------------------------------- 节点改名/删除的联动
# 列出 tags 里含指定节点的分享 token (每行一个)。给"删除前预告"和
# "改名联动"共用 —— 两处各写一遍必然漂移。
share_tokens_for_tag() {
    local tag="${1:-}" js
    [[ -n "$tag" ]] || return 1
    js=$(_x_share_list)
    [[ -z "$js" || "$js" == "[]" ]] && return 0
    printf '%s' "$js" | python -c '
import sys, json
tag = sys.argv[1]
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    m = r.get("meta") or {}
    tags = m.get("tags") or []
    if isinstance(tags, str): tags = [tags]
    if tag in tags:
        print(r.get("token", ""))
' "$tag" 2>/dev/null
}

# 节点改名 -> 分享里的 tag 引用跟着改。
#
# ★ 改漏了的后果是**静默少一个节点**: 令牌本身没报错, 客户端拉到的订阅里
#   就是少了一个, 而面板显示一切正常。
share_retag() {
    local old="${1:-}" new="${2:-}"
    [[ -n "$old" && -n "$new" ]] || die "用法: share.sh retag <旧名> <新名>"
    local toks n=0 tok _cur
    toks=$(share_tokens_for_tag "$old")
    if [[ -z "$toks" ]]; then
        info "没有分享引用 $old, 无需联动"
        return 0
    fi
    while IFS= read -r tok; do
        [[ -n "$tok" ]] || continue
        # 取回原 meta, 只替换 tags 里那一个, 其余字段原样保留
        _cur=$(_x_share_api get --token "$tok" 2>/dev/null | python -c '
import sys, json
old, new = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
m = d.get("meta") or {}
tags = m.get("tags") or []
if isinstance(tags, str): tags = [tags]
m["tags"] = [new if x == old else x for x in tags]
print(json.dumps(m, ensure_ascii=False))
' "$old" "$new" 2>/dev/null)
        [[ -n "$_cur" ]] || continue
        _x_share_api update --token "$tok" --meta "$_cur" >/dev/null 2>&1 && n=$((n + 1))
    done <<< "$toks"
    ok "已联动更新 $n 条分享的节点引用: $old -> $new"
    # 内容也变了 (链接里的名字/tag), 刷一次
    share_refresh_all
}

# 删除节点前的预告: 会影响到哪几条分享。
share_affected() {
    local tag="${1:-}" toks
    toks=$(share_tokens_for_tag "$tag")
    if [[ -z "$toks" ]]; then
        return 0
    fi
    local n; n=$(printf '%s\n' "$toks" | grep -c . )
    printf '  ${_YEL}受影响分享: %s 条 (删除成功后将自动吊销)${_RST}\n' "$n" >&2
    printf '%s\n' "$toks" | head -5 | while IFS= read -r t; do
        printf '    %s\n' "$t" >&2
    done
    (( n > 5 )) && printf '    ... 还有 %s 条\n' "$((n - 5))" >&2
    return 0
}

# ---------------------------------------------------------------- 地址族切换
# 把所有节点的"对外地址"在 IPv4 / IPv6 之间批量切换。
#
# ★ 为什么需要: 本机可能同时有 IPv4 与 IPv6 (实测 RN: eth0 107.173.154.178
#   + he-ipv6 2001:470:c:cf::2)。节点建好之后想换一族对外, 原来只能一个一个
#   改 —— 而 share_meta.host 是分享链接与客户端配置里"连哪个地址"的唯一来源,
#   漏改一个就是那个节点谁都连不上。
#
# ★ 地址一律走 addr.sh 取: 它会排除隧道/虚拟网卡 (warp / docker / awg …)。
#   直接 `ip -6 addr` 取第一个很容易拿到 WARP 的地址, 而那个地址客户端连不上
#   —— 这个坑本轮已经在分享链接上踩过一次。
#
# ★ 切完**必须刷新已发链接**: 内容里嵌着地址, 不刷新的话令牌还是老地址,
#   而面板显示一切正常。
x_switch_addr_family() { # v4|v6
    local want="${1:-}" newip=""
    case "$want" in
        v4|4|ipv4) want=v4 ;;
        v6|6|ipv6) want=v6 ;;
        *) err "用法: 切换地址族 v4|v6"; return 1 ;;
    esac

    if [[ "$want" == v6 ]]; then
        newip=$(x_addr6_real 2>/dev/null) || newip=""
        [[ -n "$newip" ]] || { err "本机没有可用的真实 IPv6 (隧道地址已排除)"; return 1; }
    else
        newip=$(x_iface_public_addr 2>/dev/null) || newip=""
        # x_iface_public_addr 优先给 v4, 但机器只有 v6 时它会返回 v6 —— 要拦
        [[ "$newip" == *:* ]] && newip=""
        [[ -n "$newip" ]] || { err "本机没有可用的真实 IPv4"; return 1; }
    fi

    info "目标地址: $newip ($(x_addr_family_of "$newip"))"

    local n=0
    n=$(SHARE_DIR="$SHARE_DIR" LIB="$LIB_DIR" NEW="$newip" python -c '
import glob, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import share_meta
d, new = os.environ["SHARE_DIR"], os.environ["NEW"]
n = 0
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    try:
        m = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    tag = m.get("tag") or os.path.basename(f)[:-5]
    m = share_meta.load(d, tag)
    if not m or m.get("host") == new:
        continue
    # 换 host 后 tag 不变, 所以是原地改; 但旧文件是按旧 tag 命名的, 保险起见
    # 写新再删旧 (share_meta 的键就是 tag/host 组合)
    m["host"] = new
    share_meta.save(d, tag, m)
    n += 1
print(n)
' 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0

    if (( n == 0 )); then
        info "没有需要改的节点 (可能已经是 $newip)"
    else
        ok "已切换 $n 个节点的对外地址 -> $newip"
    fi
    # 内容里嵌着地址, 必须刷新 —— 不刷新的后果是令牌还是老地址而面板一切正常
    share_refresh_all
    return 0
}

# ---------------------------------------------------------------- 迁移
# 本地 token (out/share/tokens/*.json) 搬进公共基础服务。
#
# ★ 已过期 / 已用尽的**直接删掉**, 不搬。搬过去也只是占地方, 而且公共服务
#   的自动清理器下一轮就会把它删掉 —— 用户看到的是"迁移了又在几分钟后
#   自己消失", 比不搬更费解。
#
# ★ 保留原 token: 虽然链接路径从 /sub/ 变成 /share/ (老链接本来就会失效,
#   那台本地服务已经不存在了), 但保留 token 能让人对得上"哪条是哪条"。
#
# 跑完把原目录改名成 .migrated 备份, 不直接删 —— 出问题还能回看。
share_migrate() {
    local tdir="$SHARE_DIR/tokens"
    if [[ ! -d "$tdir" ]]; then
        info "没有本地 token 目录, 无需迁移"
        return 0
    fi

    # 读旧格式用 token_store —— 它是那份格式的规范读取器 (且处理损坏记录),
    # 比在这里手搓 json.load 可靠, 那份格式的解析规则也有测试覆盖。
    local rows
    rows=$(LIB="$LIB_DIR" SHARE_DIR="$SHARE_DIR" python -c '
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import token_store as T
for t in T.list_all(os.environ["SHARE_DIR"]):
    if t.get("_broken"):
        continue
    tags = t.get("tags") or ([t["tag"]] if t.get("tag") else [])
    if isinstance(tags, str): tags = [tags]
    print("\t".join([
        str(t.get("token", "")), str(t.get("name", "")),
        str(int(t.get("max_uses", 0) or 0)), str(int(t.get("expires_at", 0) or 0)),
        str(int(t.get("used_count", 0) or 0)), str(bool(t.get("enabled", True))),
        json.dumps(tags, ensure_ascii=False),
    ]))
' 2>/dev/null)
    if [[ -z "$rows" ]]; then
        info "本地没有可迁移的分享记录"
        return 0
    fi

    local port; port=$(x_share_ensure) || { err "公共分享服务不可用, 迁移中止"; return 1; }

    printf "\n${_CYN}=== 迁移本地分享到公共基础服务 ===${_RST}\n" >&2
    local now; now=$(date +%s)
    local n_ok=0 n_dead=0 n_skip=0 tok name maxu exp used en tags_json
    while IFS=$'\t' read -r tok name maxu exp used en tags_json; do
        [[ -n "$tok" ]] || continue

        # 已过期 / 已用尽 -> 不搬, 直接算作清理。
        # 搬过去也只是占地方: 公共服务的自动清理器下一轮就会删掉它,
        # 用户看到的是"迁移了又自己消失", 比不搬更费解。
        if [[ "$exp" != "0" && "$now" -gt "$exp" ]]; then
            info "过期, 不迁移: ${tok:0:12}…"; n_dead=$((n_dead+1)); continue
        fi
        if [[ "$maxu" != "0" && "$used" -ge "$maxu" ]]; then
            info "已用尽, 不迁移: ${tok:0:12}…"; n_dead=$((n_dead+1)); continue
        fi

        # 重建内容 (节点可能早就变了, 直接搬旧内容反而是错的)
        local -a tarr=()
        mapfile -t tarr < <(python -c 'import json,sys
for t in json.loads(sys.argv[1]): print(t)' "$tags_json")
        (( ${#tarr[@]} > 0 )) || { n_skip=$((n_skip+1)); continue; }
        local payload; payload=$(x_share_build_payload "${tarr[@]}") || {
            warn "内容重建失败, 跳过: ${tok:0:12}…"; n_skip=$((n_skip+1)); continue; }

        local meta ttl=0
        [[ "$exp" != "0" ]] && ttl=$((exp - now))
        meta=$(python -c '
import json, sys
print(json.dumps({"name": sys.argv[1], "tags": json.loads(sys.argv[2])}, ensure_ascii=False))' "$name" "$tags_json")

        local -a extra=()
        [[ "$ttl" -gt 0 ]] && extra+=(--ttl "$ttl")
        [[ "$en" == "False" ]] && extra+=(--enabled false)
        if _x_share_api create --type node --content-file "$payload" --token "$tok" \
               --max-uses "$maxu" --used-count "$used" --meta "$meta" "${extra[@]}" >/dev/null 2>&1; then
            ok "已迁移 ${tok:0:12}… (${name:-无名}, 节点 ${#tarr[@]} 个)"
            n_ok=$((n_ok+1))
        else
            warn "迁移失败, 跳过: ${tok:0:12}…"; n_skip=$((n_skip+1))
        fi
        rm -f "$payload"
    done <<< "$rows"

    printf '\n' >&2
    ok "迁移完成: 成功 $n_ok, 已过期/用尽未搬 $n_dead, 跳过 $n_skip"
    if (( n_dead > 0 )); then
        info "已过期/用尽的记录**没有**搬过去 —— 按惯例它们本来就该被清理"
    fi
    local bak="$SHARE_DIR/tokens.migrated-$(date +%Y%m%d-%H%M%S)"
    mv "$tdir" "$bak" 2>/dev/null && info "原目录已改名备份: $bak"
    info "新链接形如 http://<服务器IP>:$port/share/<token>"
    info "注意: 路径由 /sub/ 变成 /share/ (与 M/SB 统一), 老链接已失效"
    return 0
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
                if [[ -n "$t" ]]; then
                    printf "  [t]停用·启用 / [r]撤销 [t]: " >&2; read -r a || true
                    [[ "$a" == "r" ]] && share_revoke "$t" || share_toggle "$t"
                fi
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
        create)  share_create ;;
        list)    share_list ;;
        refresh) share_refresh_all ;;
        migrate) share_migrate ;;
        switch-family) x_switch_addr_family "${2:-}" ;;
        retag)   share_retag "${2:-}" "${3:-}" ;;
        affected) share_affected "${2:-}" ;;
        menu)    share_menu ;;
        *) die "用法: share.sh [menu|create|list|refresh|migrate|retag <旧> <新>|affected <tag>|switch-family v4|v6]" ;;
    esac
fi
