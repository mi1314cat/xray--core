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
# per-node 产物目录 —— 一致性校验的参照物 (out/<proto>_share-<NN>.txt)。
OUT_DIR="${XRAY_OUT_DIR:-$XRAY_BASE/out}"
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

# 统一交互层 (编号选择 / 确认 / 提问)。拿不到就退化成老样子, 不让菜单点不动。
if [[ -r "$LIB_DIR/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/ui.sh"
elif [[ -r "$LIB_DIR/print.sh" ]]; then
    ui_box() { ui_title "$@"; }
    ui_note() { printf '  %s\n' "$1" >&2; }
    UI_PICK_KEY=""
    ui_pick() {   # 兜底: 仍编号化, 只是没有方框
        local title="$1" empty="$2" verb="$3" -a keys=() labels=()
        local k v i idx
        while IFS=$'\t' read -r k v; do
            [[ -n "$k" ]] || continue; keys+=("$k"); labels+=("$v")
        done <<< "${UI_PICK_ROWS:-}"
        if (( ${#keys[@]} == 0 )); then warn "$empty"; return 2; fi
        while :; do
            ui_title "$title"
            for (( i = 0; i < ${#keys[@]}; i++ )); do
                printf '   %2d) %s\n' "$((i+1))" "${labels[$i]}" >&2
            done
            printf '    0) 返回\n\n' >&2
            read -r -p "  $verb [1-${#keys[@]}, 0=取消]: " idx || return 1
            [[ -z "$idx" || "$idx" == "0" ]] && return 1
            [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#keys[@]} )) || { ui_invalid "$idx"; continue; }
            UI_PICK_KEY="${keys[$((idx-1))]}"; return 0
        done
    }
    ui_confirm() { local q="$1" a
        read -r -p "  $q 输入 yes 确认: " a || return 1
        [[ "$a" == "yes" || "$a" == "y" || "$a" == "Y" ]]; }
    ui_ask_num() { local p="$1" lo="$2" hi="$3" a
        while :; do read -r -p "  $p [$lo-$hi, 0=取消]: " a || return 1
            [[ -z "$a" || "$a" == 0 ]] && return 1
            [[ "$a" =~ ^[0-9]+$ ]] && (( a >= lo && a <= hi )) && { printf '%s' "$a"; return 0; }
            ui_invalid "$a"; done; }
fi
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
    if ! python - "$LIB_DIR" "$CONF_DIR" "$SHARE_DIR" "$OUT_DIR" "$out" "$@" <<'PY' 2>/tmp/.xshare.err
import sys, os
lib_dir, conf_dir, share_dir, out_dir, out = sys.argv[1:6]
tags = sys.argv[6:]
os.environ["XRAY_CONF_DIR"] = conf_dir
os.environ["XRAY_SHARE_DIR"] = share_dir
os.environ["XRAY_OUT_DIR"] = out_dir
sys.path.insert(0, lib_dir)
import share_payload
payload, missing, nometa, bad, refused, notes, inconsistent = \
    share_payload.build_payload(tags, full=True)
if payload is None:
    print("无可分发内容 (片段没了? 缺对外地址? 只绑了回环?)", file=sys.stderr)
    raise SystemExit(1)
with open(out, "w", encoding="utf-8") as fh:
    fh.write(payload)
print("payload_schema=%d" % share_payload.PAYLOAD_SCHEMA, file=sys.stderr)
# 五类"没发出去"分开报 —— 合并成一条就查不出是哪一种
for label, items in (("节点已删", missing), ("缺分享元数据", nometa),
                     ("载荷与产物不一致", [t for t, _ in inconsistent])):
    if items:
        print("%s: %s" % (label, ",".join(items)), file=sys.stderr)
# ★ 「不该发布」是**新分开的一类**, 最要命的一类:
#   节点在、元数据也在, 但按它的监听地址外部根本连不上 (只绑回环又没有 nginx)。
#   以前它会照样生成一条链接, 用户拿到手里才发觉连不通 —— 生产
#   vless-xhttp-01/02/03 三条死链就是这么发出去的。
for t, why in refused:
    print("不该对外发布: %s —— %s" % (t, why), file=sys.stderr)
# ★ 「载荷与产物不一致」: 同一个节点有两条生成链接的路径, 它们漂移了。
#   实测事故 = 产物有 sni/ech、载荷没有, 三家客户端同时连不上而面板全绿。
#   这一条**必须拒发**, 而且必须把差在哪个字段、跟哪个产物文件说出来。
for t, why in inconsistent:
    print("载荷与产物不一致, 已拒发: %s —— %s" % (t, why), file=sys.stderr)
for n in notes:
    print("提示: %s" % n, file=sys.stderr)
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
# 列出节点 (表格形式), 结果进 _SH_NODES
_SH_NODES=(); _SH_ROWS=()
_share_node_rows() {
    _SH_NODES=()
    [[ -d "$CONF_DIR" ]] || return 0
    local t rest
    _SH_ROWS=()
    while IFS=$'\t' read -r t rest; do
        [[ -n "$t" ]] || continue
        _SH_NODES+=("$t"); _SH_ROWS+=("$rest")   # 原样保留 TAB, 交给 ui_table_print 切分
    done < <(python -c "
import sys; sys.path.insert(0,'$LIB_DIR'); import nodes
n,_=nodes.collect('$CONF_DIR')
rows=[(x['tag'], x.get('protocol') or '-', x.get('port') or '-') for x in n if x.get('tag')]
rows.sort(key=lambda r: r[0].lower())
# ★ 每列都要 str(): nodes.py 的 port 是 **int**, 直接拼会 TypeError,
#   而 TypeError 发生在 print 循环里 -> 一条都不输出 -> 面板以为"没有节点"。
for tag,p,po in rows: print('\t'.join(str(v) for v in (tag,p,po)))
" 2>/dev/null)
}

node_count_for_share() { _share_node_rows; printf '%s' "${#_SH_NODES[@]}"; }

# ---------------------------------------------------------------- 有效期提问
# 编号预设, 不让用户自己换算单位 —— 借鉴 Sing-box 的 ttl_prompt。
#
# ★ 原来是 `ui_ask "有效期天数 (0=永久)" "0"`。两个毛病:
#   1) **默认永久**。链接发给别人的那一刻就永远有效, 泄露了只能自己想起来去撤;
#      而"用完即焚"恰恰是分享链接最常见的用途。
#   2) **单位是天**。"只想让他试一小时"根本表达不出来 (填 0 天 = 永久, 不是
#      一小时); 而"7 天"要用户心算 168。
#   Sing-box 的做法是 ttl 默认 24 **小时** 且用编号预设, 现在对齐:
#   默认 1 次 / 24 小时, 要 7 天就按 3, 不用记 168。
#
# 返回**小时数** (0=永久) 到 stdout。
_share_ask_ttl() {
    local c
    printf '  %s有效期%s %s(回车=24 小时)%s\n' "$_CYN" "$_RST" "$_DIM" "$_RST" >&2
    printf '    1) 1 小时       2) 24 小时 (默认)   3) 7 天\n' >&2
    printf '    4) 30 天        5) 永久            6) 自定义小时数\n' >&2
    while :; do
        printf '  %s选择%s: ' "$_CYN" "$_RST" >&2
        IFS= read -r c || c=""
        c="${c// /}"
        case "$c" in
            1)   printf '1';   return ;;
            2|"") printf '24';  return ;;
            3)   printf '168'; return ;;
            4)   printf '720'; return ;;
            5)   printf '0';   return ;;
            6)
                local h
                h=$(ui_ask "自定义有效期 (小时, 0=永久)" "24")
                [[ "$h" =~ ^[0-9]+$ ]] || { ui_invalid "$h —— 要整数小时"; continue; }
                printf '%s' "$h"; return
                ;;
            *) ui_invalid "${c:-（空）}" ;;
        esac
    done
}

# 小时数 -> 人话。确认页与提示都用它, 免得"168 小时"这种数看着费解。
_share_ttl_human() {
    local h="${1:-0}"
    case "$h" in
        ''|*[!0-9]*) printf '永久'; return ;;
        0)   printf '永久' ;;
        24)  printf '24 小时 (1 天)' ;;
        168) printf '7 天' ;;
        720) printf '30 天' ;;
        *)
            if (( h % 24 == 0 )); then printf '%s 天' "$(( h / 24 ))"
            else printf '%s 小时' "$h"; fi
            ;;
    esac
}

# 建一条分享。tags 为空 = 全部节点 (「全协议分享」走这条路)。
share_create() {
    local name="" max_uses=1 ttl_hours=24
    local -a tags=()
    local mode="${1:-pick}"        # pick | --all

    ui_box "生成分享链接"

    _share_node_rows
    local n=${#_SH_NODES[@]}
    if (( n == 0 )); then
        warn "还没有任何节点 —— 先用「添加节点」建一个"
        ui_pause; return 1
    fi

    # ★ 原来这里调 list_nodes, 那是 nodes.py 的裸调试表 (截断的 UUID、列不对齐、
    #   没有编号), 而且选节点靠一行自由输入的 "编号, 空格分隔" —— 输错一位就
    #   选到别的节点, 报错信息还只有 "编号 X 超出范围", 列表已经滚上去了。
    UI_PICK_COLS=(节点名 类型 端口)
    UI_PICK_ROWS=""
    local i
    for (( i = 0; i < n; i++ )); do
        UI_PICK_ROWS+="${_SH_NODES[$i]}"$'\t'"${_SH_NODES[$i]}"$'\t'"${_SH_ROWS[$i]:-}"$'\n'
    done
    ui_table_print "共 $n 个节点"
    printf '\n' >&2

    if [[ "$mode" == "--all" ]]; then
        tags=("${_SH_NODES[@]}")            # 全协议分享: 已在确认页报过总数, 不再问一遍
    else
        local sel
        sel=$(ui_ask "要分享哪几个 (编号, 空格分隔; 回车=全部)" "全部") || true
        if [[ -z "${sel// /}" || "$sel" == "全部" ]]; then
            tags=("${_SH_NODES[@]}")
        else
            for i in $sel; do
                [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= n )) || {
                    printf '  %s无效编号: %s —— 范围 1-%s%s\n' "$_RED" "$i" "$n" "$_RST" >&2
                    die "没有选中任何节点"
                }
                tags+=("${_SH_NODES[$((i-1))]}")
            done
        fi
    fi
    ((${#tags[@]} > 0)) || die "没有选中任何节点"
    printf '  %s已选 %s 个节点%s\n' "$_DIM" "${#tags[@]}" "$_RST" >&2

    # ★ SHARE_AUTO=1 = 批量建完节点后由脚本自己调 (见 share_ensure_subscription)。
    #   不问名称/次数/有效期 —— 但**默认值不是**交互那套 1 次 / 24 小时:
    #   交互那套的前提是"发给人、用完即焚"; 而订阅是**要反复拉取**的
    #   (电脑、手机、路由器各拉一次), 1 次就废等于没建。
    #   所以自动订阅用 0 次 (不限) / 永久, 并把这句写在屏幕上让用户知道。
    if [[ "${SHARE_AUTO:-0}" == "1" ]]; then
        name="全协议订阅"
        max_uses=0
        ttl_hours=0
        printf '  %s自动订阅: 不限次数 / 永久有效 (批量建节点后自动生成)%s\n' "$_DIM" "$_RST" >&2
    else
    name=$(ui_ask "分享名称" "分享")

    # ★ 默认 **1 次 / 24 小时** (对齐 Sing-box)。原来默认 0 次 0 天 = 不限 + 永久:
    #   链接发出去就等于长期有效, 而分享链接最常见的用途恰恰是"用完即焚"。
    max_uses=$(ui_ask "最多可拉取次数 (0=不限)" "1")
    [[ "$max_uses" =~ ^[0-9]+$ ]] || max_uses=1

    ttl_hours=$(_share_ask_ttl)
    fi

    # 公共服务不在就装 (幂等; 已有则空操作)
    local port; port=$(x_share_ensure)
    [[ -n "$port" ]] || die "公共分享服务不可用 —— 分享链接暂时发不出去"

    local payload; payload=$(x_share_build_payload "${tags[@]}") \
        || die "生成订阅内容失败 (看上面对应原因)"

    # tags / name 存进 meta —— 刷新时要靠它重建内容。
    # 公共服务只存不读, 这是"内核用它记自己的东西"的正当用法。
    #
    # ★ payload_schema 也写进去: 载荷生成逻辑的版本号。它让"服务端修好了
    #   分享层, 但用户手里还是旧订阅"这件事**从静默变成可检测** ——
    #   刷新时版本不同就重建, 列表里也直接标出来。实测事故 (2026-10-10):
    #   conf/lib/nodes.py 的 SNI 修复在 22:33 落地, 而 20:47 建的那条分享
    #   到 23:28 还在发 `sni=<IP>` / 无 sni 无 ech 的旧内容, 三家客户端
    #   同时连不上, 而面板上一切正常。
    local meta
    meta=$(LIB="$LIB_DIR" python -c '
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import share_payload
tags = sys.argv[1:]
print(json.dumps({"name": tags[0], "tags": tags[1:],
                  "payload_schema": share_payload.PAYLOAD_SCHEMA},
                 ensure_ascii=False))
' "$name" "${tags[@]}")

    local rec token
    rec=$(_x_share_api create --type node --content-file "$payload" \
            --ttl $((ttl_hours * 3600)) --max-uses "$max_uses" --meta "$meta" 2>&1) || {
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
        # 退一步: 网卡上第一个**客户端连得上**的地址 (排除 warp/tun/docker/私网,
        # 默认路由网卡优先)。依然不问外部服务 —— 那是出站出口。
        host=$(x_iface_public_addr 2>/dev/null || true)
    fi
    if [[ -z "$host" ]]; then
        # 最后兜底: 连私网接口地址也比什么都没有强 (NAT 机器需要自己端口转发)
        host=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
               grep -vE '^127\.' | awk 'NR==1')
    fi
    [[ -n "$host" ]] || host="<服务器IP>"
    local url="http://$host:$port/share/$token"

    ok "分享已生成"
    printf "\n    ${_GRN}%s${_RST}\n\n" "$url" >&2
    printf "    节点: %s\n" "${tags[*]}" >&2
    printf "    %s次数: %s${_RST}   %s有效期: %s%s${_RST}\n" \
        "$_DIM" "$([[ "$max_uses" == 0 ]] && echo 不限 || echo "$max_uses")" \
        "$_DIM" "$(_share_ttl_human "$ttl_hours")" >&2
}

# ---------------------------------------------------------------- 列表
share_list() {
    printf "\n${_CYN}=== 分享列表 ===${_RST}\n" >&2
    # ★ 先分清"没有分享"和"服务不可达"。
    #   适配器在服务挂掉时返回空 —— 直接当成"没有分享"是在说谎: 用户会以为
    #   自己没建过链接 (或者以为被谁删了), 而真实原因是服务没跑。
    if ! _x_share_api health >/dev/null 2>&1; then
        err "公共分享服务不可达 —— 看不到列表, 不代表没有分享"
        info "用菜单 11) 分享服务管理 -> 1) 确保在位 来修复"
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
    #
    # ★ 「陈旧」必须显示出来。实测事故: 分享层修好之后 (SNI/ECH), 20:47 建的
    #   那条分享到 23:28 还在发旧内容 —— 面板列表里一切正常, 链接也打得开,
    #   唯一的现象是"客户端连不上"。判据是 meta.payload_schema 与当前
    #   生成器版本不一致 (老记录没有这个字段 = 旧版建的)。
    local want; want=$(LIB="$LIB_DIR" python -c '
import os, sys
sys.path.insert(0, os.environ["LIB"])
import share_payload
print(share_payload.PAYLOAD_SCHEMA)' 2>/dev/null)
    XJS="$js" XWANT="$want" python -c '
import os, sys, json, time
recs = json.loads(os.environ["XJS"])
want = os.environ.get("XWANT", "")
fmt = "  %-5s%-20s%-16s%-11s%-12s%-8s%-7s%s"
print(fmt % ("编号", "TOKEN", "名称", "已用/上限", "过期", "状态", "内容", "节点"), file=sys.stderr)
stale = []
for i, r in enumerate(recs, 1):
    m = r.get("meta") or {}
    exp = int(r.get("expires_at", 0))
    exps = "永久" if not exp else time.strftime("%Y-%m-%d", time.localtime(exp))
    used = int(r.get("used_count", 0)); maxu = int(r.get("max_uses", 0))
    uses = "%d/%s" % (used, maxu if maxu else "∞")
    tags = m.get("tags") or []
    if isinstance(tags, str): tags = [tags]
    sch = m.get("payload_schema", "")
    fresh = "最新" if (want and str(sch) == str(want)) else "陈旧!"
    if fresh != "最新":
        stale.append((str(r.get("token", ""))[:12], sch or "无", want or "?"))
    print(fmt % (i, str(r.get("token", ""))[:18], str(m.get("name", ""))[:15],
                 uses, exps, r.get("state", ""), fresh, ",".join(tags)[:40]),
                 file=sys.stderr)
for tok, got, w in stale:
    print(file=sys.stderr)
    print("  [陈旧] %s… 的内容是旧版生成器建的 (schema=%s, 现为 %s) —— "
          "里面可能带着已经修掉的缺陷 (丢 sni / 丢 ech / sni 写成 IP)。"
          % (tok, got, w), file=sys.stderr)
    print("         客户端拉到的是老内容, 而列表/链接看起来一切正常; "
          "跑一次 `conf/share.sh refresh` 即可原地重建 (token 与地址不变)。",
          file=sys.stderr)
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
#
# ★ 判据有**两个**, 缺一个就会漏掉一整类:
#   ① 内容哈希不同 —— 节点增删改了内容;
#   ② payload_schema 不同 —— 节点没变, 但**生成载荷的代码变了**
#      (2026-10-10 事故: SNI/ECH 修复落地后, 旧分享继续发老内容, 哈希
#      当然也不同, 但没人跑过刷新; 有 schema 之后 list 会直接标陈旧)。
share_refresh_all() {
    local js; js=$(_x_share_list)
    [[ -z "$js" || "$js" == "[]" ]] && return 0

    # 刷新是"尽力而为": 绝不为了刷新去装服务 (节点生成路径不能被网络安装阻塞),
    # 但服务不可达时必须**说出来** —— 否则已有链接会一直发旧内容而无人察觉。
    if ! _x_share_api health >/dev/null 2>&1; then
        warn "公共分享服务不可达, 已有分享链接的内容未刷新"
        return 0
    fi

    local want; want=$(LIB="$LIB_DIR" python -c '
import os, sys
sys.path.insert(0, os.environ["LIB"])
import share_payload
print(share_payload.PAYLOAD_SCHEMA)' 2>/dev/null)

    local n=0 nstale=0 tok name tags schema newh curh payload newmeta
    while IFS=$'\t' read -r tok name tags schema; do
        [[ -n "$tok" ]] || continue
        [[ -n "$tags" ]] || continue
        # shellcheck disable=SC2086
        payload=$(x_share_build_payload $(printf '%s' "$tags" | tr ',' ' ')) || continue
        newh=$(sha256sum "$payload" | awk '{print $1}')
        curh=$(_x_share_api get --token "$tok" 2>/dev/null \
               | python -c 'import sys,json
try: print(json.load(sys.stdin).get("content_sha256",""))
except Exception: print("")' 2>/dev/null)
        if [[ -n "$want" && "$schema" != "$want" ]]; then
            nstale=$((nstale + 1))
            info "分享 ${tok:0:12}… 是旧版生成器建的 (schema=${schema:-无}, 现为 $want), 重建内容"
        fi
        if [[ "$newh" != "$curh" || ( -n "$want" && "$schema" != "$want" ) ]]; then
            # ★ meta 是**整体替换**不是 merge (share_service.py: `rec["meta"] = data["meta"]`),
            #   所以这里必须把 name/tags 一起带上 —— 只发 payload_schema 会把
            #   刷新用的 tags 抹掉, 下一次刷新就再也重建不出内容了。
            newmeta=$(python -c '
import json, sys
name, tags, sch = sys.argv[1], sys.argv[2].split(","), sys.argv[3]
m = {"name": name, "tags": tags}
if sch:
    m["payload_schema"] = int(sch)
print(json.dumps(m, ensure_ascii=False))' "$name" "$tags" "${want:-$schema}")
            if _x_share_api update --token "$tok" --content-file "$payload" \
                   --meta "$newmeta" >/dev/null 2>&1; then
                n=$((n + 1))
            fi
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
        print("%s\t%s\t%s\t%s" % (r.get("token",""), m.get("name",""),
                                  ",".join(tags), m.get("payload_schema","")))
' 2>/dev/null)

    (( n > 0 )) && info "已刷新 ${n} 条分享链接的内容 (token 与地址未变)"
    (( nstale > 0 && n == 0 )) && warn "有 ${nstale} 条是旧版生成器建的, 但内容没能更新 —— 见上面的报错"
    return 0
}

# ---------------------------------------------------------------- 服务管理
# 菜单第 11 项。以前这里管的是**本机自己的** xray-share 服务端 (端口 9443);
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

# 分享服务端口 —— **不起 python 进程**。
#
# share_client.py 的 actual_port() 只是"读端口文件 → 读 env → 兜底 9443",
# 纯文件读。这里照抄那三级, 省掉一个进程 —— 菜单每轮都要刷新状态, 每次省 40ms
# 是实打实的 (mihomo 首屏 1.3 秒就是这么攒出来的)。
_share_svc_port() {
    local pf="${SHARE_PORT_FILE:-/run/proxy-share-service/port}"
    local etc="${SHARE_ETC:-/etc/proxy-share-service}" p=""
    [[ -r "$pf" ]] && read -r p < "$pf" 2>/dev/null || p=""
    if [[ ! "$p" =~ ^[0-9]+$ && -r "$etc/env" ]]; then
        local l
        while IFS= read -r l; do
            [[ "$l" == SHARE_PORT=* ]] && { p="${l#SHARE_PORT=}"; break; }
        done < "$etc/env"
    fi
    [[ "$p" =~ ^[0-9]+$ ]] || p="${SHARE_PORT:-9443}"
    printf '%s' "$p"
}

# 分享菜单顶部的服务状态 —— **每轮重画都刷新**。
#
# ★ 用户要的是"点进分享管理就能看见服务状态", 而不是状态藏在二级菜单里。
#   停在菜单上不动时服务可能已经挂了, 所以不能只进来算一次。
#
# ★ 一轮只有两次 python (health + list), 且都是一次性拿全量, 不按节点起进程。
_share_svc_status() {
    local port st="未运行" ver="" nsh=0 ndis=0 js h
    port=$(_share_svc_port)
    if h=$(_x_share_api health 2>/dev/null) && [[ -n "$h" ]]; then
        st="运行中"
        ver=$(printf '%s' "$h" | python -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
print(d.get("version") or "")
' 2>/dev/null)
    fi
    if [[ "$st" == "运行中" ]]; then
        printf '  %s分享服务%s : %s%s运行中%s%s\n' "$_DIM" "$_RST" "$_GRN" "$_BOLD" "$_RST" \
            "${ver:+  (v$ver)}" >&2
    else
        printf '  %s分享服务%s : %s%s未运行%s  —— 用下面 11) 安装 / 修复\n' \
            "$_DIM" "$_RST" "$_YEL" "$_BOLD" "$_RST" >&2
    fi
    printf '  %s服务端口%s : %s\n' "$_DIM" "$_RST" "$port" >&2
    if js=$(_x_share_list 2>/dev/null) && [[ -n "$js" && "$js" != "[]" ]]; then
        read -r nsh ndis <<<"$(printf '%s' "$js" | python -c '
import sys, json
try: recs = json.loads(sys.stdin.read())
except Exception: recs = []
off = sum(1 for r in recs if not (r.get("enabled", True)))
print("%d %d" % (len(recs), off))
' 2>/dev/null)"
    fi
    [[ "$nsh" =~ ^[0-9]+$ ]] || nsh=0
    [[ "$ndis" =~ ^[0-9]+$ ]] || ndis=0
    if (( nsh == 0 )); then
        printf '  %s我的分享%s : 还没有\n' "$_DIM" "$_RST" >&2
    elif (( ndis == 0 )); then
        printf '  %s我的分享%s : %s 条\n' "$_DIM" "$_RST" "$nsh" >&2
    else
        printf '  %s我的分享%s : %s 条 (%s 条已停用)\n' "$_DIM" "$_RST" "$nsh" "$ndis" >&2
    fi
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
    # 单引号 printf 不展开变量 —— ${_YEL} 会原样打到屏幕上, 而这一行恰恰
    # 出现在删节点前的最后确认处, 用户看到的是 ${_YEL}受影响分享: 5 条${_RST}。
    # 要么双引号, 要么直接用变量 (下面用的是后者, 与文件里其它提示一致)。
    printf '  %s受影响分享: %s 条 (删除成功后将自动吊销)%s\n' "${_YEL:-}" "$n" "${_RST:-}" >&2
    printf '%s\n' "$toks" | awk 'NR<=5' | while IFS= read -r t; do
        printf '    %s\n' "$t" >&2
    done
    (( n > 5 )) && printf '    ... 还有 %s 条\n' "$((n - 5))" >&2
    return 0
}

# ---------------------------------------------------------------- uTLS 指纹
# 换的是分享链接里的 ClientHello 伪装 (fp=), 存在 share_meta.fingerprint。
#
# ★ 取值不是抄文档, 是 Sing-box 用 sing-box 1.14.2 内核逐个 `check` 实测过的
#   10 个: 另外那些 (randomized-noalpn / safari-ios / ios_simulator /
#   firefox_mozilla / opera / chrome_v2) 会被内核拒掉, 链接发出去客户端直接
#   连不上。mihomo 的 -t 不校验这个字段 (连乱写都放行), 所以以实测为准。
X_UTLS_FINGERPRINTS=(chrome firefox edge safari 360 qq ios android random randomized)
X_DEFAULT_UTLS_FP="chrome"

# 节点列表 + 每个节点当前的指纹。指纹只对 REALITY / TLS 节点有意义,
# 其它协议显示 '-' (改了也不会写进链接)。
_share_fp_rows() {
    _share_node_rows
    local i n=${#_SH_NODES[@]}
    # ★ _SH_FPS 必须**无条件**初始化: SHARE_DIR 不存在时下面的读档整段跳过,
    #   而调用方 share_change_fp 紧接着就索引 _SH_FPS —— set -u 下"数组未定义"
    #   直接中止, 菜单会以一个看不懂的 unbound variable 崩掉。
    _SH_FPS=()
    for (( i = 0; i < n; i++ )); do _SH_FPS+=("-"); done
    [[ -d "$SHARE_DIR" ]] || return 0
    local fps=""
    fps=$(SHARE_DIR="$SHARE_DIR" LIB="$LIB_DIR" python -c '
import glob, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import share_meta
d = os.environ["SHARE_DIR"]
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    try: tag = (json.load(open(f, encoding="utf-8")).get("tag")
               or os.path.basename(f)[:-5])
    except Exception: continue
    m = share_meta.load(d, tag) or {}
    # 只报元数据里真实存下来的值, 没设过就报 "-" ——
    # "没设过" (内核默认 chrome) 与"显式设成 chrome" 在面板上应该看得出区别。
    print("%s\t%s" % (tag, m.get("fingerprint") or "-"))
' 2>/dev/null)
    local t fp
    while IFS=$'\t' read -r t fp; do
        [[ -n "$t" ]] || continue
        for (( i = 0; i < n; i++ )); do
            [[ "${_SH_NODES[$i]}" == "$t" ]] && { _SH_FPS[$i]="${fp:--}"; break; }
        done
    done <<< "$fps"
    return 0
}

# 挑一个节点 (表格里带当前指纹)
_share_pick_node_fp() {
    _share_fp_rows
    local n=${#_SH_NODES[@]}
    if (( n == 0 )); then
        ui_box "更换 uTLS 指纹"
        printf '  %s还没有任何节点 —— 先用「添加节点」建一个%s\n' "$_YEL" "$_RST" >&2
        ui_pause; return 1
    fi
    UI_PICK_COLS=(节点名 类型 端口 当前指纹)
    UI_PICK_ROWS=""
    local i
    # ★ 行格式是 key<TAB>字段1<TAB>… —— **key 不显示**, 所以第一列要自己再放一次
    #   节点名。少放一次的话整张表左移一列 (节点名列显示成类型、端口列显示成
    #   指纹、指纹列永远空), 而且表看着"有内容", 不会有人发现它错位了。
    #   与 share_create 里的写法保持一致。
    for (( i = 0; i < n; i++ )); do
        UI_PICK_ROWS+="${_SH_NODES[$i]}"$'\t'"${_SH_NODES[$i]}"$'\t'"${_SH_ROWS[$i]:-}"$'\t'"${_SH_FPS[$i]:--}"$'\n'
    done
    ui_pick "更换 uTLS 指纹" "还没有任何节点" "选择要换指纹的节点"
}

# 指纹选择 (编号预设 + 默认标记), 对齐 Sing-box 的 ask_utls_fingerprint
_share_ask_fp() { # <当前值> -> stdout 指纹
    local cur="${1:--}" i=1 v mark n=${#X_UTLS_FINGERPRINTS[@]}
    printf '  %suTLS 指纹%s %s(客户端握手伪装, 回车=chrome)%s\n' \
        "$_CYN" "$_RST" "$_DIM" "$_RST" >&2
    for v in "${X_UTLS_FINGERPRINTS[@]}"; do
        mark=" "; [[ "$v" == "$cur" ]] && mark="*"
        printf '   %s%s) %s%s\n' "$mark" "$i" "$v" "$_DIM" >&2
        i=$(( i + 1 ))
    done
    printf '    %s* = 当前用的; 直接回车 = %s%s\n' "$_DIM" "$X_DEFAULT_UTLS_FP" "$_RST" >&2
    # ui_ask_num 自己就会在输错时留在同一行重问, 这里不必再套一层循环。
    local idx
    idx=$(ui_ask_num "选择指纹" 1 "$n") || return 1
    printf '%s' "${X_UTLS_FINGERPRINTS[$((idx-1))]}"
}

# 改单个节点的指纹, 然后刷新已发链接 (不刷新的话老链接还是旧指纹)。
share_set_fp() { # <tag> <新指纹>
    local tag="$1" fp="$2" old
    old=$(SHARE_DIR="$SHARE_DIR" LIB="$LIB_DIR" TAG="$tag" python -c '
import os, sys
sys.path.insert(0, os.environ["LIB"])
import share_meta
m = share_meta.load(os.environ["SHARE_DIR"], os.environ["TAG"]) or {}
print(m.get("fingerprint") or "")
' 2>/dev/null)

    # share_meta.save 是**合并写入** (_save_locked 里 cur.update(…)):
    # 只传 fingerprint 不会抹掉 host / public_key / 开关 / 次数。
    if ! SHARE_DIR="$SHARE_DIR" LIB="$LIB_DIR" TAG="$tag" FP="$fp" python -c '
import os, sys
sys.path.insert(0, os.environ["LIB"])
import share_meta
share_meta.save(os.environ["SHARE_DIR"], os.environ["TAG"],
                {"fingerprint": os.environ["FP"]})
' 2>/dev/null; then
        err "写入 $tag 的分享元数据失败"; return 1
    fi
    ok "$tag: 指纹 ${old:-$X_DEFAULT_UTLS_FP} -> $fp"
    # 内容里嵌着 fp=, 不刷新的话令牌还是旧指纹而面板显示一切正常。
    share_refresh_all
}

share_change_fp() {
    _share_pick_node_fp || return 0
    local tag="$UI_PICK_KEY" fp=""
    # 当前值从刚才那张表里取回 (ui_pick 把行号留在 UI_PICK_IDX)。
    # 不用再读一次 share_meta —— 画表时已经读过了, 重读是白付一次 python。
    local cur="${_SH_FPS[$((UI_PICK_IDX-1))]:--}"
    fp=$(_share_ask_fp "$cur") || { ui_note "已取消"; return 0; }
    [[ "$fp" == "$cur" ]] && { ui_note "没变, 不必重写"; return 0; }
    share_set_fp "$tag" "$fp"
}

# ---------------------------------------------------------------- 地址族切换
# 把节点里"指向本机的对外地址"在 IPv4 / IPv6 之间批量切换。
#
# ★ 为什么需要: 本机可能同时有 IPv4 与 IPv6 (实测 RN: eth0 107.173.154.178
#   + he-ipv6 2001:470:c:cf::2)。节点建好之后想换一族对外, 原来只能一个一个
#   改 —— 而 share_meta.host 是分享链接与客户端配置里"连哪个地址"的唯一来源,
#   漏改一个就是那个节点谁都连不上。
#
# ★★★ 白名单, 不是无条件替换 (这是旧实现真正的病根):
#   旧实现把所有 share_meta.host 一律写成新 IP。于是
#     · 走 CDN 的节点 —— host 本来是 cdn.example.com, 被写成源站 IP,
#       CDN 白嫖没了, 而且**看起来完全正常**, 用户只发现"好像没走 CDN";
#     · 中转 / 他机的地址 —— 被改成本机地址, 那个节点直接连不上。
#   现在只有落进「本机地址白名单」的 IP 才会被替换:
#     白名单 = 探测到的旧地址 + 本机该族全部公网地址 (多 IP 机器)。
#   域名 / 他机 IP / 私网 / 隧道地址**一律不动**, 并逐条告诉用户"哪些没动",
#   否则用户会以为"切了但没生效"。
#
# ★ 地址一律走 addr.sh 取: 它会排除隧道/虚拟网卡 (warp / docker / awg …)。
#   直接 `ip -6 addr` 取第一个很容易拿到 WARP 的地址, 而那个地址客户端连不上
#   —— 这个坑本轮已经在分享链接上踩过一次。
#
# ★ 切完**必须刷新已发链接**: 内容里嵌着地址, 不刷新的话令牌还是老地址,
#   而面板显示一切正常。
x_switch_addr_family() { # v4|v6
    local want="${1:-}" newip="" fam_old="" old=""
    case "$want" in
        v4|4|ipv4) want=v4 ;;
        v6|6|ipv6) want=v6 ;;
        *) err "用法: 切换地址族 v4|v6"; return 1 ;;
    esac

    if [[ "$want" == v6 ]]; then
        newip=$(x_addr6_real 2>/dev/null) || newip=""
        [[ -n "$newip" ]] || { err "本机没有可用的真实 IPv6 (隧道地址已排除)"; return 1; }
        fam_old=v4
    else
        newip=$(x_addr4_real 2>/dev/null) || newip=""
        [[ -n "$newip" ]] || { err "本机没有可用的真实 IPv4"; return 1; }
        fam_old=v6
    fi

    # ★ "旧地址"必须按**被替换的那一族**取, 不能走"当前状态判断"。
    #   状态此刻可能已经是 want (建节点时就写过), 再据此判断会取反:
    #   切 IPv6 时把 IPv4 填进去, 却报"已切换为 IPv6"。
    local old
    if [[ "$want" == v6 ]]; then old=$(x_addr4_real 2>/dev/null || true)
    else old=$(x_addr6_real 2>/dev/null || true); fi
    [[ -n "$old" ]] || warn "本机没有 $fam_old 地址, 只改写能确认属于本机的那部分"

    info "目标地址: $newip ($(x_addr_family_of "$newip"))"

    # 白名单: 探测到的旧地址 + 本机该族全部公网地址 (多 IP 机器)。
    # 只有落在这个集合里的 host 才会被替换。
    local -a ours=()
    [[ -n "$old" ]] && ours+=("$old")
    local a
    while IFS= read -r a; do
        [[ -n "$a" ]] && ours+=("$a")
    done < <(x_local_addrs "$fam_old" 2>/dev/null)

    if (( ${#ours[@]} == 0 )); then
        err "没能确定本机的 $fam_old 地址, 已放弃改写"
        err "宁可什么都不改, 也不要把 CDN 域名 / 他机地址改成本机地址"
        return 1
    fi
    info "本机 $fam_old 地址白名单: ${ours[*]}"

    # OURS 走环境变量: 白名单是任意多条, 拼进 argv 不可靠。
    local n=0 kept=""
    kept=$(SHARE_DIR="$SHARE_DIR" LIB="$LIB_DIR" NEW="$newip" \
           OURS="$(printf '%s\n' "${ours[@]}")" python -c '
import glob, json, os, sys
sys.path.insert(0, os.environ["LIB"])
import share_meta
d, new = os.environ["SHARE_DIR"], os.environ["NEW"]
ours = {x.strip() for x in os.environ.get("OURS", "").splitlines() if x.strip()}
n = 0; kept = []
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    try:
        tag = json.load(open(f, encoding="utf-8")).get("tag") or os.path.basename(f)[:-5]
    except Exception:
        continue
    m = share_meta.load(d, tag)
    if not m:
        continue
    host = str(m.get("host") or "")
    if host == new:
        continue                       # 已经是目标地址
    if not host:
        continue                       # 没写对外地址, 不猜
    # ★ 白名单之外的**一律不动**, 并记下来告诉用户为什么没动。
    #   域名 (CDN / 手工填写) 与地址族无关; 他机 / 私网 / 隧道地址更不该碰。
    if host not in ours:
        kept.append("%s(%s)" % (tag, host))
        continue
    # host 换了但 tag 不变 -> 原地合并写入 (save 是 merge, 不碰其它字段)。
    share_meta.save(d, tag, {"host": new})
    n += 1
print("%d\t%s" % (n, ",".join(kept)))
' 2>/dev/null)
    n="${kept%%$'\t'*}"
    kept="${kept#*$'\t'}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0

    if (( n == 0 )); then
        info "没有需要改的节点 (可能已经是 $newip)"
    else
        ok "已切换 $n 个节点的对外地址 -> $newip"
    fi
    # 没动的那些要**逐条说清**, 否则用户以为"切了但没生效"。
    if [[ -n "$kept" ]]; then
        local k
        for k in ${kept//,/ }; do
            info "保留未改: $k  (不是本机地址 —— 域名/他机/私网不该动)"
        done
    fi
    # 内容里嵌着地址, 必须刷新 —— 不刷新的后果是令牌还是老地址而面板一切正常
    share_refresh_all
    return 0
}

# 交互入口: 先报两边各自有没有, 再让用户挑。
#
# ★ 不能只看"当前是哪个族"就把另一族写成"已切换" —— 状态此刻可能已经是目标族
#   (建节点时就写过), 据此判断会取反: 切 IPv6 时把 IPv4 填进去却报"已切换"。
#   两边都实测一遍, 用户看到的是事实而不是推断。
x_switch_addr_family_menu() {
    local v4 v6
    v4=$(x_addr4_real 2>/dev/null || true)
    v6=$(x_addr6_real 2>/dev/null || true)

    ui_box "更换连接 IP"
    echo >&2
    if [[ -n "$v4" ]]; then
        printf '   1) IPv4   %s%s%s\n' "$_BOLD" "$v4" "$_RST" >&2
    else
        printf '   1) IPv4   %s本机不可用%s\n' "$_YEL" "$_RST" >&2
    fi
    if [[ -n "$v6" ]]; then
        printf '   2) IPv6   %s%s%s\n' "$_BOLD" "$v6" "$_RST" >&2
    else
        printf '   2) IPv6   %s本机不可用%s\n' "$_YEL" "$_RST" >&2
    fi
    echo >&2
    ui_note "只替换指向本机的 IP; CDN 域名、他机地址一律不动"
    ui_note "切完自动刷新已发链接 (内容里嵌着地址, 不刷新老链接还是旧地址)"
    echo >&2

    local idx
    if idx=$(ui_ask_num "改用哪一族" 1 2); then
        if (( idx == 1 )); then
            x_switch_addr_family v4
        else
            x_switch_addr_family v6
        fi
    fi
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

# 分享的编号选择器 —— 32 位 token 没有人手打得出来。
#
# ★ 旧交互是 share_list 之后问 "token: ", 而 share_list 上一屏刚把
#   「编号」那一列打在最左边 —— 编号已经在屏幕上, 却还要用户手抄 token。
#   (底层 _x_share_find 本来就同时认编号与 token, 差的只是菜单这一层。)
#
# ★ 一次 python 读全部, 不按令牌起进程 —— 那是 Mihomo 首屏卡顿的成因。
share_list_rows() {
    local js; js=$(_x_share_list)
    [[ -z "$js" || "$js" == "[]" ]] && return 0
    XJS="$js" python -c '
import os, sys, json, time
try: recs = json.loads(os.environ["XJS"])
except Exception: recs = []
for r in recs:
    m = r.get("meta") or {}
    exp = int(r.get("expires_at", 0) or 0)
    exps = "永久" if not exp else time.strftime("%Y-%m-%d", time.localtime(exp))
    used = int(r.get("used_count", 0) or 0); maxu = int(r.get("max_uses", 0) or 0)
    uses = "%d/%s" % (used, maxu if maxu else "无限")
    tags = m.get("tags") or []
    if isinstance(tags, str): tags = [tags]
    st = r.get("state") or ("启用" if r.get("enabled", True) else "已停用")
    name = str(m.get("name") or "-")[:16]
    line = "%-16s %-8s %-7s %-10s %s" % (
        name, uses, exps, st, (",".join(tags) or "-")[:34])
    print("\t".join([r.get("token", ""), line]))
' 2>/dev/null
}

share_pick_token() { # <动作名>
    local -a toks=() metas=()
    local t m
    while IFS=$'\t' read -r t m; do
        [[ -n "$t" ]] || continue
        toks+=("$t"); metas+=("$m")
    done < <(share_list_rows)
    if (( ${#toks[@]} == 0 )); then
        warn "还没有任何分享 —— 先用「1) 生成分享链接」建一条"
        ui_pause; return 2
    fi
    UI_PICK_ROWS=""
    local i
    for (( i = 0; i < ${#toks[@]}; i++ )); do
        UI_PICK_ROWS+="${toks[$i]}"$'\t'"${metas[$i]}"$'\n'
    done
    ui_pick "分享管理 —— $1" "还没有任何分享" "$1"
}

# ---------------------------------------------------------------- 菜单
share_menu() {
    while :; do
        printf '\n' >&2
        ui_title "分享管理"
        # ★ 状态在菜单顶部, 每轮刷新 —— 用户要的是"进分享管理就看得见服务状态",
        #   而不是状态藏在二级菜单里 (原来主菜单 5) 与本菜单 11) 各写一份,
        #   两处还会互相不一致)。
        _share_svc_status
        echo >&2
        ui_menu 1 "生成分享链接    挑几个节点 → 生成一条订阅地址"
        ui_menu 2 "全协议分享      全部节点打成一条订阅 (加节点后刷新即可)"
        ui_menu 3 "刷新分享内容    加/删/改节点后, 把已发的链接更新到最新"
        ui_menu 4 "分享列表        已发出的链接：次数 / 有效期 / 状态"
        ui_menu 5 "查看链接地址    直接打印订阅 URL, 方便复制"
        ui_menu 6 "启停 / 撤销     立刻失效, 节点本身不受影响"
        ui_menu 7 "改次数上限      默认 1 次 (0=不限)"
        ui_menu 8 "改有效期        默认 24 小时 (0=永久)"
        ui_menu 9 "重新生成 Token  换一条新地址, 旧的立即作废"
        ui_menu 10 "删除分享链接"
        ui_menu 11 "分享服务管理    公共基础服务：安装 / 升级 / 统计 / 防火墙"
        ui_menu 0 "返回"
        echo >&2
        if ! read -r -p "  ${_CYN}请选择 [0-11, 回车=返回]${_RST}: " c; then return 0; fi
        case "$c" in
            1) share_create ;;
            2) share_create_all ;;
            3) share_refresh_all; ui_pause ;;
            4) share_list ;;
            5)
                if share_pick_token "查看地址"; then
                    share_show_url "$UI_PICK_KEY"
                    ui_pause
                fi
                ;;
            6)
                # 旧交互: 先 share_list 再问 "token: " —— 而编号那一列就在
                # 屏幕上第一列。现在改成列表选编号 (与节点管理同一套)。
                if share_pick_token "启停 / 撤销"; then
                    printf '  %s[t]停用·启用 / [r]撤销%s [t]: ' "${_DIM:-}" "${_RST:-}" >&2
                    read -r a || true
                    [[ "$a" == "r" ]] && share_revoke "$UI_PICK_KEY" || share_toggle "$UI_PICK_KEY"
                    ui_pause
                fi
                ;;
            7)
                if share_pick_token "改次数上限"; then
                    local v; v=$(ui_ask "新的次数上限 (0=不限)" "1")
                    [[ "$v" =~ ^[0-9]+$ ]] || { ui_invalid "$v —— 要整数"; ui_pause; continue; }
                    share_set "$UI_PICK_KEY" max_uses "$v"
                    ui_pause
                fi
                ;;
            8)
                # 单位统一成**小时** (与新建一致, 见 _share_ask_ttl):
                # 原来这里还按天, 于是"新建填 24 天"和"改有效期填 1 天"单位不一致。
                if share_pick_token "改有效期"; then
                    local v; v=$(_share_ask_ttl)
                    share_set "$UI_PICK_KEY" expires_at "$(( $(date +%s) + v * 3600 ))"
                    ui_pause
                fi
                ;;
            9)
                if share_pick_token "重新生成 Token"; then
                    share_regen_token "$UI_PICK_KEY"
                    ui_pause
                fi
                ;;
            10)
                if share_pick_token "删除"; then
                    share_delete_link "$UI_PICK_KEY"
                    ui_pause
                fi
                ;;
            11) share_service_menu ;;
            0|"") return 0 ;;
            *) warn "无效选择"; ui_pause ;;
        esac
    done
}

# ---------------------------------------------------------------- 新增动作
#
# 这三个动作 Mihomo 有、Xray 原来没有, 而它们是**分享日常使用里最常点的**:
#   拿到地址去客户端粘贴、地址泄露后换一条、换完把旧的删掉。
# 原来只有"启停/撤销" —— 想换地址只能撤销重建, 名字/次数/有效期全丢。

_share_url() { # <token> -> 订阅 URL
    local base
    base=$(_x_share_field "$1" base_url)
    [[ -n "$base" ]] && base="${base%/}"
    [[ -z "$base" ]] && base="${XRAY_PANEL_ADDR:-http://127.0.0.1}"
    printf '%s/sub/%s' "$base" "$1"
}

share_show_url() {
    local tok="$1" url; url=$(_share_url "$tok")
    ui_box "分享链接地址"
    printf '  %s%s%s\n\n' "$_BOLD" "$url" "$_RST" >&2
    ui_note "把整行复制到客户端的「订阅」里即可"
    ui_note "地址泄露了? 用「重新生成 Token」换一条"
}

# 换一条新地址: 用同一份内容/名字/次数/有效期建新记录, 再删旧记录。
# ★ 顺序是"先建后删" —— 反过来的话, 建新失败就等于把旧地址也弄没了,
#   用户手里就什么都没有了。
share_regen_token() {
    local old="$1" name max exp new
    name=$(_x_share_field "$old" meta.name); [[ -n "$name" ]] || name="分享"
    max=$(_x_share_field "$old" max_uses);  [[ "$max"  =~ ^[0-9]+$ ]] || max=0
    exp=$(_x_share_field "$old" expires_at); [[ "$exp" =~ ^[0-9]+$ ]] || exp=0

    # ★ 内容走临时文件 + --content-file, 不走 --content。
    #   订阅是整份 base64 (节点多时几十 KB), 塞进 argv 会撞 ARG_MAX,
    #   到那时才报 "Argument list too long", 完全看不出是哪一步撑爆的。
    local tf; tf=$(mktemp /tmp/.xshare-regen.XXXXXX) || { die "建临时文件失败"; }
    if ! _x_share_api get --token "$old" 2>/dev/null | python -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(1)
sys.stdout.write(d.get("content") or "")
' >"$tf" 2>/dev/null; then
        rm -f "$tf"; die "读不到旧链接内容 —— **旧地址未动**, 可继续使用"
    fi
    if [[ ! -s "$tf" ]]; then
        rm -f "$tf"
        die "旧链接内容为空 —— **旧地址未动**。多半是内容已过期, 建议用「刷新分享内容」后再换"
    fi

    # tags 必须按 JSON 取 —— _x_share_field 走的是 python print(), 数组出来是
    # ['a', 'b'] (单引号), 喂给 json.loads 直接炸。
    local tags_json
    tags_json=$(_x_share_api get --token "$old" 2>/dev/null | python -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
m = d.get("meta") or {}
print(json.dumps(m.get("tags") or [], ensure_ascii=False))
' 2>/dev/null)
    [[ "$tags_json" == "["* ]] || tags_json="[]"

    ui_box "重新生成 Token"
    ui_kv "名称" "$name"
    ui_kv "次数上限" "$max"
    ui_kv "到期" "$(( exp > 0 ? exp : 0 ))"
    echo >&2
    ui_note "新地址生成后, 旧地址立刻失效 (已导入的客户端要重新拉一次)"
    ui_confirm "确认换一条新地址?" || { rm -f "$tf"; ui_note "已取消"; return 0; }

    local meta
    meta=$(python -c '
import json, sys
print(json.dumps({"name": sys.argv[1], "tags": json.loads(sys.argv[2])}, ensure_ascii=False))' \
        "$name" "$tags_json")

    # 先建 —— 建不出来就什么都不动
    local out; out=$(_x_share_api create --type node --content-file "$tf" \
        --ttl 0 --max-uses "$max" --meta "$meta" 2>&1)
    local rc=$?
    if (( rc != 0 )); then
        rm -f "$tf"
        die "新令牌创建失败: $(printf '%s' "$out" | tail -1) —— **旧地址未动**, 可继续使用"
    fi
    new=$(printf '%s' "$out" | python -c '
import sys, json
try: print(json.load(sys.stdin).get("token") or "")
except Exception: print("")' 2>/dev/null)
    rm -f "$tf"
    [[ -n "$new" ]] || die "新令牌创建失败 (没拿到 token) —— **旧地址未动**, 可继续使用"

    # 建成功了才动旧的
    if ! _x_share_api delete --token "$old" >/dev/null 2>&1; then
        warn "新地址已生成, 但旧记录删除失败 —— 旧地址仍然可用, 建议手动清理"
    fi
    if (( exp > 0 )); then
        _x_share_api update --token "$new" --expires-at "$exp" >/dev/null 2>&1 \
            || warn "到期时间没带上 (新地址变成永久)"
    fi

    ok "新地址已生成, 旧地址已作废"
    share_show_url "$new"
}

share_delete_link() {
    local tok="$1" name; name=$(_x_share_field "$tok" meta.name)
    ui_box "删除分享链接"
    printf '  将删除 %s%s%s (令牌 %s...)\n' "$_BOLD" "${name:-分享}" "$_RST" "${tok:0:8}" >&2
    ui_note "删除的是**分享链接**, 节点本身完全不受影响"
    ui_confirm "确认删除?" || { ui_note "已取消"; return 0; }
    _x_share_api delete --token "$tok" >/dev/null 2>&1 || die "删除失败"
    # 回读确认 —— 旧实现里"撤销"静默失败过
    _x_share_api get --token "$tok" >/dev/null 2>&1 && die "删除未生效 (记录还在)"
    ok "已删除分享链接 (节点未受影响)"
}

# 全协议分享: 把**全部**节点打成一条订阅。
#
# ★ 为什么值得单列一个菜单项:
#   原来的 share_create 只能靠"选择那行括号里写的『留空=全部』"来选全部 ——
#   一个隐藏约定, 而且要先手打一串编号再留空, 手滑就是选错几个节点。
#   日常用法几乎总是"全都要", 所以给它一个名字、一个编号、零输入。
#   以后加/删节点, 走 share_refresh_all 就会把内容刷新到这条链接里。
share_create_all() {
    local n
    n=$(node_count_for_share)
    (( n > 0 )) || { warn "还没有任何节点 —— 先用「添加节点」建一个"; ui_pause; return 1; }
    ui_box "全协议分享"
    printf '  将把 **全部 %s 个节点** 打成一条订阅地址。\n' "$n" >&2
    ui_note "以后加节点/改节点, 跑一次「刷新分享内容」这条链接就会自动更新"
    ui_confirm "生成?" || { ui_note "已取消"; return 0; }
    share_create --all
}

# ---------------------------------------------------------------- 自动订阅
#
# 批量建完节点之后由脚本调用 (batch.sh / preset_batch.sh):
#   已有覆盖全部节点的分享 → **刷新它**(链接不变, 内容更新)
#   一条都没有            → 建一条 (不限次数 / 永久)
#
# ★ 为什么需要它: 在这之前 X **不会**自动生成任何订阅链接 —— 协议脚本只写
#   一个 per-node 的 out/<proto>-share-NN.txt, 而"一条能导进客户端的订阅地址"
#   必须用户自己去 菜单 4 → 2) 全协议分享 里点一遍。SB 那边是批量生成完
#   直接给一条链接, 用户复制走就能用 —— 这是实打实的体验差距。
#
# ★ 只在"一条都没有"时创建, 之后永远走刷新: 否则每跑一次全协议就多一条
#   订阅, 用户的客户端里会堆一串内容重复的地址。
share_ensure_subscription() {
    # ★ 测试/沙箱里**必须**能关掉这一步。
    #
    #   这一条是 2026-10-16 在生产上数出来的: 分享服务里堆了 20 条叫
    #   「全协议订阅」的记录, 引用的是**沙箱里那些并不存在的 tag** ——
    #   时间戳正好对着几轮自动化测试。原因: 批量建节点跑完会自动确保一条
    #   覆盖全部节点的订阅, 而分享服务是一个**远端服务**, 它不知道也不关心
    #   调用方是不是在沙箱里。于是每跑一次测试, 生产分享服务就多一条垃圾记录,
    #   而本地一切正常。
    #
    #   为什么不在 share.sh 里按"是不是沙箱"自动判断: 判断依据只能是路径
    #   (XRAY_BASE 是不是生产那样), 而有人本来就把面板装在别处, 那种情况下
    #   他要的就是自动订阅。**显式开关**比猜测可靠。
    if [[ "${X_NO_SHARE_SUBSCRIBE:-0}" == "1" ]]; then
        info "已按 X_NO_SHARE_SUBSCRIBE=1 跳过自动订阅 (节点照常建好)"
        return 0
    fi

    local -a tags=()
    _share_node_rows
    tags=("${_SH_NODES[@]}")
    ((${#tags[@]} == 0)) && return 0      # 还没节点, 不吭声 (批量里已报过)

    # 服务不可达就安静退出 —— 批量建节点是主流程, 不能被分享服务拖住。
    # 但要说一句, 否则"链接没生成"和"没尝试生成"长得一模一样。
    if ! _x_share_api health >/dev/null 2>&1; then
        warn "分享服务不可达 —— 订阅链接没有生成/刷新 (节点本身已建好)"
        return 0
    fi

    # 找一条已经覆盖全部节点的分享
    local tok="" pyf
    pyf=$(mktemp -t share-find.XXXXXX.py)
    cat > "$pyf" <<'PYEOF'
import json, os, subprocess, sys
sys.path.insert(0, os.environ["LIB"])
want = set(json.loads(os.environ["TAGS"]))
try:
    raw = subprocess.run([os.environ["CLIENT"], "list"], capture_output=True,
                         text=True, timeout=20,
                         env={**os.environ, "SHARE_PROVIDER": "xray"}).stdout
    recs = json.loads(raw or "[]")
except Exception:
    recs = []
for r in (recs if isinstance(recs, list) else []):
    meta = r.get("meta") or {}
    t = meta.get("tags") or ([meta["name"]] if meta.get("name") else [])
    if isinstance(t, str):
        t = [t]
    if want and want.issubset(set(t)) and r.get("enabled", True):
        print(r.get("token", ""))
        break
PYEOF
    tok=$(LIB="$LIB_DIR" CLIENT="$SHARE_CLIENT"           TAGS="$(printf '%s
' "${tags[@]}" | python3 -c 'import json,sys;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))' 2>/dev/null || echo '[]')"           python3 "$pyf" 2>/dev/null)
    rm -f "$pyf"

    if [[ -n "$tok" ]]; then
        share_refresh_all >/dev/null 2>&1 || true
        local url; url=$(_share_url "$tok" 2>/dev/null)
        ok "订阅已刷新 (含全部 ${#tags[@]} 个节点): ${url:-（地址读取失败）}"
        return 0
    fi

    printf '  %s还没有订阅链接, 自动建一条 (不限次数 / 永久)%s\n' "$_DIM" "$_RST" >&2
    # ★ 输出**不能吞掉**: share_create 结尾会把订阅地址打在屏幕上, 而那正是
    #   用户唯一需要复制的东西。第一版把 stdout/stderr 一起重定向掉了,
    #   结果屏幕上只有"自动建一条", 地址一个字都没有 —— 等于白建。
    local out
    out=$(SHARE_AUTO=1 share_create --all 2>&1)
    local rc=$?
    printf '%s\n' "$out" | grep -E '^\s*http' | sed 's/^/  /' >&2
    if (( rc == 0 )); then
        # 兜底: 万一上面没抓到, 从服务里把刚建的那条查出来再打一次
        if ! printf '%s\n' "$out" | grep -qE '^\s*http'; then
            local tok2
            tok2=$(LIB="$LIB_DIR" python - <<'PYEOF' 2>/dev/null
import json, os, subprocess, sys
sys.path.insert(0, os.environ["LIB"])
want = json.loads(os.environ["TAGS"])
try:
    recs = json.loads(subprocess.run([os.environ["CLIENT"], "list"], capture_output=True,
                                     text=True, timeout=20,
                                     env={**os.environ, "SHARE_PROVIDER": "xray"}).stdout or "[]")
except Exception:
    recs = []
for r in (recs if isinstance(recs, list) else []):
    m = r.get("meta") or {}
    if (m.get("tags") or []) == want and r.get("enabled", True):
        print(r.get("token", "")); break
PYEOF
)
            [[ -n "$tok2" ]] && ok "订阅地址: $(_share_url "$tok2" 2>/dev/null)"
        fi
        return 0
    fi
    warn "自动建订阅失败 —— 去 菜单 4) 分享管理 → 2) 全协议分享 手工建一条"
    return 0
}

# ---------------------------------------------------------------- 直跑
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-menu}" in
        create)  share_create ;;
        list)    share_list ;;
        refresh) share_refresh_all ;;
        ensure-subscription) share_ensure_subscription ;;
        migrate) share_migrate ;;
        switch-family)      x_switch_addr_family "${2:-}" ;;
        switch-family-menu) x_switch_addr_family_menu ;;
        change-fp)          share_change_fp ;;
        retag)   share_retag "${2:-}" "${3:-}" ;;
        affected) share_affected "${2:-}" ;;
        menu)    share_menu ;;
        *) die "用法: share.sh [menu|create|list|refresh|migrate|retag <旧> <新>|affected <tag>|switch-family v4|v6|switch-family-menu|change-fp]" ;;
    esac
fi
