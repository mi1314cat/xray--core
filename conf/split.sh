#!/bin/bash

# 交互输入统一走 conf/lib/read.sh —— EOF 会被当成退出, 否则会无限刷屏。
_x_read_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib"
if [[ -r "$_x_read_lib_dir/read.sh" ]]; then
    source "$_x_read_lib_dir/read.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/read.sh") \
        || { printf '输入库加载失败\n' >&2; exit 1; }
fi

# ================================
# split.sh — Xray 分流规则管理脚本
# outbound.sh（出站脚本）的姊妹版本，专管"分流规则"：
#   - 同样的彩色输出 / print_* / print_title / safe_read 风格
#   - 数据载体 conf/out-routing.json（与 outbound.sh 的绑定表同文件，
#     由 _meta.splitRules 存分流规则、_meta.bindings 存绑定表）
#   - 每条规则 = {type:field, [inboundTag], domain:[...], outboundTag}
#       · 不带 inboundTag → 全局分流（所有入站命中域名都走该出站）
#       · 带 inboundTag   → 按入站分流（只对该入站生效）
#   - 生成 routing.rules 顺序：分流规则(splitRules)在最前 → 绑定规则 → ads→block
#     （本 xrayls fork 对 routing 是"后读文件覆盖前读"，故全部集中在同一文件，
#       分流在前先匹配，优先于绑定）
# 用法： bash split.sh   （测试时可 SPLIT_BASE_DIR=... 覆盖基础目录）
# ================================

# ================================
# 统一 UI 层 —— conf/lib/print.sh + conf/lib/ui.sh
#
# ★ 与 outbound.sh 一样, 这里原先**自带一份**颜色 + print_title + print_*。
#   抄一份的代价不是多占十几行，而是"改一处漏两处"：
#     · print_title 的 `printf "║ %-42s ║"` 按**字节**算宽度, 而标题全是中文
#       （一个字 3 字节）, 稍长一点的标题就把右边框顶没了；
#     · 交互全部走裸 `read` —— 9 处, **没有一处有 EOF 处理**:
#       被 source 调用 / 管道喂完 / Ctrl-D 时 read 直接失败, 变量保持空串,
#       后面拿着空值一路走下去（表现为"什么都没删, 却说删好了"或无限刷屏）。
#   现在统一走共享层: 提示一律写 stderr（stdout 是数据通道）,
#   列表一律编号 + 列按**显示宽度**对齐。
#
# ★ 旧函数名保留为薄包装, 调用点不变。
# ================================
if [[ -r "$_x_read_lib_dir/print.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_x_read_lib_dir/print.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/print.sh") \
        || { printf '  [X] 提示库 print.sh 加载失败\n' >&2; exit 1; }
fi

# ★ 取不到 ui.sh 不致命: 退化成"只有排版的老样子", 菜单点得动最重要。
if [[ -r "$_x_read_lib_dir/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_x_read_lib_dir/ui.sh"
else
    printf '  [!] 交互库 ui.sh 取不到, 降级为无编号选择\n' >&2
    UI_PICK_KEY=""; UI_PICK_IDX=""; UI_PICK_COLS=(); UI_PICK_ROWS=""
    ui_box()   { ui_title "$@"; }
    ui_menu()  { printf '  %2s) %s\n' "$1" "$2" >&2; }
    ui_note()  { printf '  %s\n' "$1" >&2; }
    ui_pad_w() { printf '%s' "$1"; }
    ui_cjk_w() { printf '%s' "${#1}"; }
    ui_rule2() { printf '  --------------------------------\n' >&2; }
    ui_pause() { printf '\n' >&2; read -r _ || true; }
    ui_ask() { local q="$1" d="${2-}" a
        [[ -n "$d" ]] && printf '  %s (回车=%s): ' "$q" "$d" >&2 || printf '  %s: ' "$q" >&2
        read -r a || a=""; [[ -z "$a" ]] && a="$d"; printf '%s' "$a"; }
    ui_confirm() { local q="$1" a
        printf '  %s\n' "$q" >&2; printf '    输入 yes 确认 (回车=取消): ' >&2
        read -r a || a=""; [[ "$a" == "yes" || "$a" == "YES" || "$a" == "y" || "$a" == "Y" ]]; }
    ui_ask_num() { local p="$1" lo="$2" hi="$3" a
        while :; do
            read -r -p "  $p [$lo-$hi, 0=取消]: " a || return 1
            [[ -z "$a" || "$a" == 0 ]] && return 1
            [[ "$a" =~ ^[0-9]+$ ]] && (( a >= lo && a <= hi )) && { printf '%s' "$a"; return 0; }
            printf '  无效选项: %s\n' "$a" >&2
        done; }
    ui_pick() { local title="$1" empty="$2" verb="$3" -a keys=() labels=()
        local k v i
        while IFS=$'\t' read -r k v; do [[ -n "$k" ]] || continue; keys+=("$k"); labels+=("$v"); done <<< "${UI_PICK_ROWS:-}"
        if ((${#keys[@]} == 0)); then printf '  %s\n' "$empty" >&2; return 2; fi
        ui_title "$title"
        for (( i = 0; i < ${#keys[@]}; i++ )); do ui_menu $((i+1)) "${labels[$i]}"; done
        ui_menu 0 "取消"
        i=$(ui_ask_num "$verb" 1 "${#keys[@]}") || { UI_PICK_KEY=""; return 1; }
        UI_PICK_KEY="${keys[$((i-1))]}"; return 0; }
fi

# ---------- 颜色: 引用共享层, 不再自己声明一份 ----------
# ★ 非终端时 print.sh 会把颜色关掉（重定向到日志不该带 ^[[32m 转义序列）。
RED="${_RED-}"; GREEN="${_GRN-}"; YELLOW="${_YEL-}"; CYAN="${_CYN-}"
WHITE="${_BOLD-}"; BOLD="${_BOLD-}"; RESET="${_RST-}"

# ================================
# 打印函数（全部输出到 stderr，与兄弟脚本一致）
# ================================
print_info()  { info "$*"; }
print_ok()    { ok "$*"; }
print_error() { err "$*"; }
print_warn()  { warn "$*"; }

# ★ 标题改走 ui_box: 按终端宽度 + 显示宽度画, `%-42s`（字节）的溢出消失。
print_title() { ui_box "$1"; }

# ---------- 菜单控件 ----------
menu_item() { ui_menu "$1" "$2"; }
menu_quit() { ui_menu 0 "${1:-返回上级}"; }

# ★ 按**显示宽度**截断, 不用 `cut -c1-60`。
#   cut -c 是**字节**索引: 域名里只要有一个中文/全角字符, 就在它中间劈开,
#   显示成乱码 —— 用户认不出自己那条规则, 也就无从下手。
#   而且原来无条件截断, 短域名后面也挂着一段没来由的残缺观感;
#   现在**只在真的超宽时**才补省略号。
#
# ★ 宽度用 printf -v 回写而不是 $(ui_cjk_w): 每个字符 fork 一次子 shell,
#   一屏 50 条规则就是几千次 fork, 菜单会明显卡一下。
_ui_width() { # <文本> <变量名> —— 把显示宽度写进变量
    # ★ 累加器叫 __w 而不是 w: printf -v 写的是**调用方**的变量, 万一调用方
    #   传进来的名字正好撞上这里的局部变量, 宽度就会被写进自己的临时变量,
    #   调用方永远读到空值。
    local t="$1" __var="$2" __w=0 i ch
    for (( i = 0; i < ${#t}; i++ )); do
        ch="${t:i:1}"
        # case 而不是 `[[ ... == [区间] ]]` —— 见 conf/lib/ui.sh 的说明。
        case "$ch" in
            [$'\u1100'-$'\u115f']|[$'\u2e80'-$'\ua4cf']|[$'\uac00'-$'\ud7a3']|\
            [$'\uf900'-$'\ufaff']|[$'\ufe30'-$'\ufe4f']|[$'\uff01'-$'\uff60'])
                __w=$((__w + 2)) ;;
            *)
                __w=$((__w + 1)) ;;
        esac
    done
    printf -v "$__var" '%s' "$__w"
}

trunc_w() { # <文本> <目标显示宽度>
    local t="$1" w="${2:-60}" acc out i ch cw
    _ui_width "$t" acc
    (( acc <= w )) && { printf '%s' "$t"; return 0; }
    acc=0; out=""
    for (( i = 0; i < ${#t}; i++ )); do
        ch="${t:i:1}"
        _ui_width "$ch" cw
        # 留一列给省略号, 不然补上 "…" 就超宽了
        (( acc + cw > w - 1 )) && break
        out+="$ch"; acc=$((acc + cw))
    done
    printf '%s…' "$out"
}

# ================================
# 基础变量
# ================================
BASE_DIR="${SPLIT_BASE_DIR:-/root/catmi/xray}"
CONF_DIR="$BASE_DIR/conf"
ROUTING_FILE="$CONF_DIR/out-routing.json"

# Xray 二进制（配置校验用）
XRAY_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_BIN" ]]; then
    for c in /root/catmi/xray/xrayls /usr/local/bin/xray xrayls; do
        command -v "$c" >/dev/null 2>&1 && { XRAY_BIN=$(command -v "$c"); break; }
    done
fi

mkdir -p "$CONF_DIR"

# ================================
# 输入清理
# ================================

# ================================
# 安全输入（不会污染 JSON）
# ================================

# ================================
# 出站 tag 列表（direct/block + conf/out-NN.json 的 tag）
# ================================
outbound_tags() {
    echo "direct"
    echo "block"
    local f t
    shopt -s nullglob
    for f in "$CONF_DIR"/out-*.json; do
        [[ "$(basename "$f")" == out-routing.json ]] && continue
        t=$(jq -r '.outbounds[0].tag // empty' "$f" 2>/dev/null)
        [[ -n "$t" ]] && echo "$t"
    done
}

# ================================
# 入站 tag 列表（conf 目录里非 out-* 片段中的 inbounds tag）
# ================================
inbound_tags() {
    local f t
    shopt -s nullglob
    for f in "$CONF_DIR"/*.json; do
        [[ "$(basename "$f")" == out-*.json ]] && continue
        while IFS= read -r t; do
            [[ -n "$t" ]] && echo "$t"
        done < <(jq -r '.inbounds[]?.tag // empty' "$f" 2>/dev/null)
    done | sort -u
}

# ================================
# 读/写分流规则集合（_meta.splitRules）
# ================================
read_rules() {
    jq -c '._meta.splitRules // []' "$ROUTING_FILE" 2>/dev/null
}

ensure_split_file() {
    if [[ ! -f "$ROUTING_FILE" ]]; then
        echo '{"_meta":{"bindings":{},"splitRules":[]},"routing":{"rules":[]}}' > "$ROUTING_FILE"
        print_ok "已创建 $ROUTING_FILE"
    fi
}

# 统一重组 routing.rules：分流(splitRules) + 绑定(bindings) + ads→block
# 与 outbound.sh 的 rebuild 逻辑一致（两边各自实现，保证结果相同）
rebuild_and_write() {
    if [[ ! -f "$ROUTING_FILE" ]]; then
        ensure_split_file
    fi
    local splits binds
    splits=$(jq -c '._meta.splitRules // []' "$ROUTING_FILE" 2>/dev/null)
    # 绑定表 → 绑定规则数组
    binds=$(jq -c '[._meta.bindings // {} | to_entries[] | {inboundTag:[.key], outboundTag:.value}]' "$ROUTING_FILE" 2>/dev/null)
    [[ -z "$binds" || "$binds" == "null" ]] && binds='[]'
    # 只更新 routing 字段，保留 _meta
    jq --argjson splits "$splits" --argjson binds "$binds" \
        '.routing.rules = ($splits + $binds + [{domain:["geosite:category-ads-all"], outboundTag:"block"}])' \
        "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    print_ok "已更新 $ROUTING_FILE（分流在前，绑定在后）"
}

# ================================
# 查看分流规则
# ================================
# 分流规则表: 填 UI_PICK_ROWS / UI_PICK_COLS（key = 序号, 1 起）
#
# ★ 原来每条规则起 4 次 jq（ib / ob / cnt / doms 各一次）= 4N 次进程, 现在
#   一次 jq 出 TSV 整行, shell 侧切。
# ★ `cut -c1-60` 是**按字节**截断, 中文域名会被劈成乱码 —— 改用按显示宽度
#   的 trunc_w（见上）, 并且只在真的截断时补省略号。
# ★ 域名字段绝不能为空: UI_PICK_ROWS 用 TAB 分隔, 空字段会让渲染器把该行
#   整体左移（协议名显示到域名列上）。所以 jq 侧统一给兜底值。
split_rows() {
    local d ib ob cnt doms n=0
    SPLIT_ROWS_N=0
    UI_PICK_COLS=(范围 出站 域名数 域名)
    UI_PICK_ROWS=""
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        n=$((n + 1))
        IFS=$'\t' read -r ib ob cnt doms < <(jq -r \
            '(.inboundTag? // null) as $ib
             | [(if $ib == null then "全局"
                 else "按入站 " + ($ib | if type == "array" then join(",") else . end) end),
                (.outboundTag // "?"),
                ((.domain? // [] | length) | tostring),
                ((.domain? // [] | join(" ")) // "-")] | @tsv' <<< "$d")
        UI_PICK_ROWS+="$n"$'\t'"${ib:--}"$'\t'"${ob:--}"$'\t'"${cnt:-0}"$'\t'"$(trunc_w "${doms:--}" 56)"$'\n'
        SPLIT_ROWS_N=$((SPLIT_ROWS_N + 1))
    done < <(read_rules | jq -c '.[]')
}

list_splits() {
    print_title "分流规则列表"
    ensure_split_file
    split_rows
    if (( SPLIT_ROWS_N == 0 )); then
        print_info "当前无分流规则（所有入站都走绑定/默认出口）"
        return 0
    fi
    # ★ 走共享渲染器: 列按显示宽度自适应（中文列名不再歪）+ 结尾给出"共 N 条"。
    ui_table_print "共 $SPLIT_ROWS_N 条规则"
}

# 选一条分流规则（菜单 / ui_pick 一体）
# 返回 0=选中（UI_PICK_KEY = 序号）；1=用户取消；2=一条规则都没有
pick_split() { # <方框标题> <动作动词>
    split_rows
    ui_pick "$1" "当前无分流规则（所有入站都走绑定/默认出口）" "$2"
}

# ================================
# 出站 / 入站 候选（编号选择，带上能认出来的列）
# ================================
# ★ 原来两个选择器都只打印 `  $i) $t` —— 一个**裸 tag**。
#   一屏 out-01/out-02/out-03 分不出协议和用途, 用户只能凭记忆认, 或者干脆猜。
#   现在补上协议 / 名称 / 地址（入站则是 tag / 协议 / 端口）,
#   并且元数据用**一次 jq 扫全部片段**取回（不是每个文件起一个进程）。
pick_outbound() { # -> stdout: 选中的 tag；1=取消；2=没有候选
    local tag proto name addr
    local -A M_proto=() M_name=() M_addr=()
    while IFS=$'\t' read -r tag proto name addr; do
        [[ -n "$tag" ]] || continue
        M_proto[$tag]="$proto"; M_name[$tag]="$name"; M_addr[$tag]="$addr"
    done < <(jq -r '
        . as $root
        | (.outbounds // [])[]
        | [ (.tag // "-"),
            (.protocol // "-"),
            ($root._meta.name // "-"),
            (.settings.vnext[0].address // .settings.servers[0].address // .settings.address // "-")
          ] | @tsv' "$CONF_DIR"/*.json 2>/dev/null)
    UI_PICK_COLS=(tag 协议 名称 地址)
    UI_PICK_ROWS=""
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        UI_PICK_ROWS+="$tag"$'\t'"$tag"$'\t'"${M_proto[$tag]:--}"$'\t'"${M_name[$tag]:--}"$'\t'"${M_addr[$tag]:--}"$'\n'
    done < <(outbound_tags | sort -u)
    ui_pick "选择出口（分流命中后的去向）" "没有任何可用出站，请先运行 outbound.sh 创建" "选择出口" || return $?
    # ★ ui_pick 只往 stderr 画界面, 值在 UI_PICK_KEY —— 必须自己吐到 stdout,
    #   否则 `ob=$(pick_outbound)` 永远拿到空串（"静默按默认处理"的老毛病）。
    printf '%s' "$UI_PICK_KEY"
}

pick_inbound() { # -> stdout: 选中的 tag；1=取消；2=没有候选
    local tag proto port
    local -A M_proto=() M_port=()
    while IFS=$'\t' read -r tag proto port; do
        [[ -n "$tag" ]] || continue
        M_proto[$tag]="$proto"; M_port[$tag]="$port"
    done < <(jq -r '
        (.inbounds // [])[]
        | [ (.tag // "-"), (.protocol // "-"), ((.port // "-") | tostring) ] | @tsv' \
        "$CONF_DIR"/*.json 2>/dev/null)
    UI_PICK_COLS=(tag 协议 端口)
    UI_PICK_ROWS=""
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        UI_PICK_ROWS+="$tag"$'\t'"$tag"$'\t'"${M_proto[$tag]:--}"$'\t'"${M_port[$tag]:--}"$'\n'
    done < <(inbound_tags)
    ui_pick "选择入站（分流只对这条入站生效）" "未发现任何入站（conf 里没有 inbounds 片段）" "选择入站" || return $?
    printf '%s' "$UI_PICK_KEY"
}

# ================================
# 新增分流规则
# ================================
add_split() {
    print_title "新增分流规则"
    ensure_split_file
    # ★ scope / it / isel 原来都没 local —— 泄漏到全局。
    local ob inbound scope d
    local -a darr=()

    # 选择出口（编号 + 协议/名称/地址，原来只有一个裸 tag）
    ob=$(pick_outbound) || { print_info "已取消"; return 1; }
    [[ -n "$ob" ]] || { print_error "没有任何可用出站，请先运行 outbound.sh 创建"; return 1; }

    # 全局 or 按入站
    ui_menu 1 "全局（所有入站生效）"
    ui_menu 2 "指定入站（只对某入站生效）"
    # ★ 原来裸 `read scope`：EOF 时拿着空串继续, 于是**静默落到"全局"**。
    #   这里收编号, 0/EOF = 取消。
    scope=$(ui_ask_num "分流范围" 1 2) || { ui_note "已取消"; return 1; }
    inbound=""
    if [[ "$scope" == "2" ]]; then
        inbound=$(pick_inbound) || { print_info "已取消"; return 1; }
        [[ -n "$inbound" ]] || { print_error "未发现任何入站（conf 里没有 inbounds 片段）"; return 1; }
    fi

    # 域名名单（支持逗号/空格分隔，或 geosite: 前缀）
    local doms
    doms=$(safe_read "域名名单（多个用空格或逗号分隔，如 browserleaks.com matrix.tencent.com）" "")
    [[ -n "$doms" ]] || { print_error "至少需要一个域名"; return 1; }
    for d in $doms; do
        d=${d%,}
        [[ -z "$d" ]] && continue
        [[ "$d" == geosite:* || "$d" == domain:* ]] || d="domain:$d"
        darr+=("$d")
    done
    ((${#darr[@]} == 0)) && { print_error "域名解析失败"; return 1; }

    # 构造规则并写入 _meta.splitRules
    local rule
    if [[ -n "$inbound" ]]; then
        rule=$(jq -n --arg ib "$inbound" --arg ob "$ob" --argjson ds "$(printf '%s\n' "${darr[@]}" | jq -R . | jq -s .)" \
            '{type:"field", inboundTag:[$ib], domain:$ds, outboundTag:$ob}')
    else
        rule=$(jq -n --arg ob "$ob" --argjson ds "$(printf '%s\n' "${darr[@]}" | jq -R . | jq -s .)" \
            '{type:"field", domain:$ds, outboundTag:$ob}')
    fi
    jq --argjson r "$rule" '._meta.splitRules = ((._meta.splitRules // []) + [$r])' "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    rebuild_and_write
    local scope_txt="全局"
    [[ -n "$inbound" ]] && scope_txt="入站 $inbound"
    print_ok "已新增分流规则：[$scope_txt] → $ob  (域名 ${#darr[@]} 个)"
}

# ================================
# 删除分流规则
# ================================
del_split() {
    ensure_split_file
    # ★ 原来先 list_splits 再问 "输入要删除的规则序号 (0=取消)"，
    #   可下一行 `[[ "$dn" =~ ^[0-9]+$ ]] || 无效序号` 把 **0 判成无效** ——
    #   提示承诺的"取消"根本不存在, 用户输 0 只会被弹回主菜单。
    #   ui_pick/ui_ask_num 的契约正是 0 与空 = 取消; 越界也不再一次性报错退出,
    #   而是重画列表让用户改（与全项目一致）。
    pick_split "删除分流规则" "选择要删除的规则" || return 0
    local dn="$UI_PICK_KEY"
    jq "._meta.splitRules |= del(.[$((dn-1))])" "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
    rebuild_and_write
    print_ok "已删除规则 $dn"
}

# ================================
# 给规则增删域名
# ================================
edit_domains() {
    ensure_split_file
    # ★ 同上: "选择规则序号 (0=取消)" 的 0 过去被判成"无效序号"。
    # ★ sn / op / d / idx 原来也没 local（d 只在 1) 分支里 local, 2) 分支直接用）。
    pick_split "维护分流规则域名" "选择规则" || return 0
    local sn="$UI_PICK_KEY" idx op d
    idx=$((sn - 1))

    ui_menu 1 "添加域名"
    ui_menu 2 "移除域名"
    op=$(ui_ask_num "操作" 1 2) || { ui_note "已取消"; return 0; }
    local ds
    case "$op" in
        1)
            ds=$(safe_read "要添加的域名（多个可空格分隔）" "")
            [[ -n "$ds" ]] || { print_error "不能为空"; return 1; }
            local -a addarr=()
            for d in $ds; do
                d=${d%,}
                [[ -z "$d" ]] && continue
                [[ "$d" == geosite:* || "$d" == domain:* ]] || d="domain:$d"
                addarr+=("$d")
            done
            ((${#addarr[@]} == 0)) && { print_error "没有有效域名"; return 1; }
            local addjson
            addjson=$(printf '%s\n' "${addarr[@]}" | jq -R . | jq -s .)
            jq --argjson idx "$idx" --argjson add "$addjson" \
                '._meta.splitRules[$idx].domain = ((._meta.splitRules[$idx].domain // []) + $add) | ._meta.splitRules[$idx].domain |= unique' \
                "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
            rebuild_and_write
            print_ok "已添加域名到规则 $sn"
            ;;
        2)
            # ★ 原来把这条规则的域名 join 成**一长行**甩出来（还 cut -c1-60 截成乱码）,
            #   然后要用户"输完整域名", 拿字符串全等去匹配:
            #   打错一个字符 → jq 一条都没删 → 却照样打印 "已从规则 N 移除域名"。
            #   用户以为规则生效了, 那条站其实还在走分流。
            #   现在: 一个域名一行、**编号**, 值由 UI_PICK_KEY 给（不存在抄错）,
            #   删完再回头核对一次, 没真删掉就明说失败。
            #   （一次只能移除一条；要删多条就重复一次这个操作。）
            UI_PICK_COLS=(域名)
            UI_PICK_ROWS=""
            local rmd
            while IFS= read -r d; do
                [[ -z "$d" ]] && continue
                UI_PICK_ROWS+="$d"$'\t'"${d#domain:}"$'\n'
            done < <(jq -r "._meta.splitRules[$idx].domain[]?" "$ROUTING_FILE" 2>/dev/null)
            ui_pick "从规则 $sn 移除域名" "规则 $sn 的域名列表为空，无需移除" "移除域名" || return 0
            rmd="$UI_PICK_KEY"
            if [[ -z "$(jq -r --arg d "$rmd" "._meta.splitRules[$idx].domain // [] | index(\$d) // empty" "$ROUTING_FILE" 2>/dev/null)" ]]; then
                print_error "规则 $sn 的域名里没有 $rmd —— 未做任何修改"
                return 0
            fi
            local rmjson
            rmjson=$(jq -Rn --arg x "$rmd" '[$x]')
            jq --argjson idx "$idx" --argjson rm "$rmjson" \
                '._meta.splitRules[$idx].domain = ((._meta.splitRules[$idx].domain // []) - $rm)' \
                "$ROUTING_FILE" > "${ROUTING_FILE}.tmp" && mv "${ROUTING_FILE}.tmp" "$ROUTING_FILE"
            rebuild_and_write
            if [[ -n "$(jq -r --arg d "$rmd" "._meta.splitRules[$idx].domain // [] | index(\$d) // empty" "$ROUTING_FILE" 2>/dev/null)" ]]; then
                print_error "移除失败: $rmd 仍在规则 $sn 的域名列表里"
            else
                print_ok "已从规则 $sn 移除域名: ${rmd#domain:}"
            fi
            ;;
    esac
}

# ================================
# 校验配置 / 重启
# ================================
validate_config() {
    if [[ -z "$XRAY_BIN" ]]; then
        print_error "未找到 xray 二进制，无法校验"
        return 1
    fi
    print_title "校验 Xray 配置"
    local out
    out=$("$XRAY_BIN" run -test -confdir "$CONF_DIR" 2>&1)
    if [[ "$out" == *"Configuration OK."* ]]; then
        print_ok "Configuration OK."
    else
        print_error "配置校验失败："
        echo "$out" | tail -8 >&2
    fi
}

# 服务名解析 (xrayls / xray 双代兼容) 与重启逻辑收敛到 conf/lib/service.sh。
# 这里曾各写一份 if/elif, 新脚本再写一份, 改一处漏两处的概率很高。
_x_svc_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib"
if [[ -r "$_x_svc_lib_dir/service.sh" ]]; then
    source "$_x_svc_lib_dir/service.sh"
else
    source <(curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/service.sh") \
        || { print_error "服务库加载失败"; return 1; }
fi

restart_xrayls() {
    x_svc_restart
}

# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "Xray 分流规则管理"

        # ★ 原来用裸 `echo "1) …"` 画菜单 —— **没有前导缩进**, 与项目里其余
        #   每一个菜单（两格缩进 + 彩色序号）都不齐平。统一走 ui_menu。
        ui_menu 1 "查看分流规则"
        ui_menu 2 "新增分流规则"
        ui_menu 3 "删除分流规则"
        ui_menu 4 "维护规则域名（增删）"
        ui_menu 5 "校验配置 / 重启服务"
        ui_menu 0 "退出"

        local c
        # ★ 原来裸 `read -r c`：EOF 时 c 保持**上一次**的值（或空串）继续跑，
        #   自动化里就是拿空串一路问下去。改成收编号, 0/EOF = 退出（同原来）,
        #   越界重画菜单而不是刷"无效选项"。
        c=$(ui_ask_num "请选择" 1 5) || exit 0

        case $c in
            1) list_splits ;;
            2) add_split ;;
            3) del_split ;;
            4) edit_domains ;;
            5)
                print_title "校验 / 重启"
                validate_config
                # ★ 原来裸 `read rr`：EOF 时拿着空串, 等价于"不重启" —— 靠运气。
                ui_confirm "重启 xrayls 服务?" && restart_xrayls
                ;;
        esac

        # ★ 原来 `printf "按回车继续…" ; read` —— 同样没有 EOF 保护,
        #   管道喂完输入时这里是**空转刷屏**。ui_pause 内部 `|| true`, EOF 即过。
        ui_pause
    done
}

# 支持被 source 后直接调用内部函数做自动化测试
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_menu
fi