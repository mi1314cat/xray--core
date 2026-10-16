#!/usr/bin/env bash
# =============================================================
# 统一交互层 —— 编号选择 / 确认 / 提问 / 排版
#
# ★ 为什么要这一层 (三家内核对标的结论)
#
#   提问全面度 → 学 Sing-box:
#     · 每个问题带默认值, 直接回车就能走
#     · 说清"这一步会发生什么", 不让用户猜后果
#     · 选项摆出来, 不要求用户凭记忆敲名字
#
#   提示美观度 → 学 Mihomo:
#     · 方框标题、彩色编号、灰色补充说明、列对齐
#     · 中文按**显示宽度**补齐 (printf 的 %-Ns 按字节, 中文标签必错位)
#
#   ★ 明确**不学** Mihomo 的卡顿:
#     M 的首屏 node_count() 给**每个节点文件起一个 python3 进程**
#     (单是 import yaml 就要 60ms), 20 个文件 = 1.3 秒, 每重画一次付一次。
#     本层所有取值必须是「一次进程扫全部」或纯 shell, 不允许按文件起进程。
#
# ★ 一律写 stderr: 服务端脚本的 stdout 是数据通道 (分享链接 / 订阅内容),
#   提示混进 stdout 会被下游当成链接解析 (见 conf/lib/print.sh 开头)。
# =============================================================

if [[ -z "${_GRN+x}" ]]; then
    _RED=$'\033[31m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'
    _CYN=$'\033[36m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
    if [[ ! -t 2 ]]; then
        _RED=""; _GRN=""; _YEL=""; _CYN=""; _DIM=""; _RST=""
    fi
fi
[[ -n "${_BOLD+x}" ]] || { [[ -t 2 ]] && _BOLD=$'\033[1m' || _BOLD=""; }

# ------------------------------------------------------------ 宽度 --------

# 中文/全角按 2 列算, 与终端实际渲染一致。
ui_cjk_w() {
    local t="$1" w=0 i ch
    for (( i = 0; i < ${#t}; i++ )); do
        ch="${t:i:1}"
        # 用 case 而不是 `[[ ... == [区间] ]]`: 后者让 shellcheck 报 error 级
        # 解析错误并停止检查整个文件。区间一字未改。
        case "$ch" in
            [$'\u1100'-$'\u115f']|[$'\u2e80'-$'\ua4cf']|[$'\uac00'-$'\ud7a3']|\
            [$'\uf900'-$'\ufaff']|[$'\ufe30'-$'\ufe4f']|[$'\uff01'-$'\uff60'])
                w=$((w + 2)) ;;
            *)
                w=$((w + 1)) ;;
        esac
    done
    printf '%s' "$w"
}

# 按显示宽度左对齐补齐。替代 printf %-Ns。
ui_pad_w() { # <文本> <目标显示宽度>
    local t="$1" want="$2" w
    w=$(ui_cjk_w "$t")
    if (( w >= want )); then printf '%s' "$t"; return; fi
    printf '%s%*s' "$t" $(( want - w )) ""
}

ui_term_w() { # <缺省> <上限>
    local d="$1" cap="$2" n
    n=$(tput cols 2>/dev/null || true)
    case "$n" in ''|*[!0-9]*) n="$d" ;; esac
    (( n > cap )) && n="$cap"
    printf '%s' "$n"
}

# ------------------------------------------------------------ 排版 --------

# 方框标题 (Mihomo 风格) —— 子屏用。
# 主菜单仍用 conf/lib/print.sh 的 ui_title (横线版): 主菜单一改,
# 整套脚本的对齐假设都要跟着复核, 收益不抵风险。
ui_box() { # <标题> [宽度]
    local t="$1" w="${2:-}" i line inner
    [[ -z "$w" ]] && w=$(ui_term_w 52 72)
    (( w < 20 )) && w=20
    for (( i = 0; i < w - 2; i++ )); do line+="─"; done
    inner=$(( w - 3 - $(ui_cjk_w "$t") ))
    (( inner < 1 )) && inner=1
    printf '  %s╭%s╮%s\n' "$_CYN" "$line" "$_RST" >&2
    printf '  %s│%s %s%s%s %*s%s│%s\n' \
        "$_CYN" "$_RST" "$_BOLD" "$t" "$_RST" "$inner" "" "$_CYN" "$_RST" >&2
    printf '  %s╰%s╯%s\n' "$_CYN" "$line" "$_RST" >&2
}

ui_rule2() { # 分隔线
    local n i d=""
    n=$(ui_term_w 52 76)
    for (( i = 0; i < n; i++ )); do d+="─"; done
    printf '  %s%s%s\n' "$_DIM" "$d" "$_RST" >&2
}

ui_note() { printf '  %s%s%s\n' "$_DIM" "$1" "$_RST" >&2; }

# ------------------------------------------------------------ 提问 --------

# 带默认值的提问 (SB 风格)。
#   直接回车 → 默认值。EOF 也当默认值 —— EOF 返回空串会让"端口留空"这类
#   操作拿到空值, 后面才炸, 极难定位。
ui_ask() { # <提示> [默认值] -> stdout
    local prompt="$1" def="${2-}" ans
    if [[ -n "$def" ]]; then
        printf '  %s%s%s %s(回车=%s)%s: ' \
            "$_CYN" "$prompt" "$_RST" "$_DIM" "$def" "$_RST" >&2
    else
        printf '  %s%s%s: ' "$_CYN" "$prompt" "$_RST" >&2
    fi
    IFS= read -r ans || ans=""
    ans="${ans#"${ans%%[![:space:]]*}"}"; ans="${ans%"${ans##*[![:space:]]}"}"
    [[ -z "$ans" ]] && ans="$def"
    printf '%s' "$ans"
}

# 收编号。0 与空 = 取消。越界/非数字 → 重画同一个列表 (不退出)。
ui_ask_num() { # <提示> <最小> <最大> [默认值]
    # ★ 第 4 个参数 (默认值) 是后加的, 且**必须可选** —— 老调用点一个字不用改。
    #
    #   为什么要它: 原来回车一律 `return 1` (= 取消), 而调用方普遍写成
    #       c=$(ui_ask_num "选择" 1 4) || return 0
    #   于是**回车 = 静默中止整个流程**。
    #
    #   实测事故 (接手审计, pty 真按键): mknode 建节点走到 xhttp 模式那一问,
    #   提示写着「回车=auto」, 用户照做 —— ui_ask_num 返回 1, `|| return 0`
    #   让 mknode 以**成功**退出, 节点没建成、一句错都不报, 直接回到菜单。
    #   屏幕上的提示与真实行为**相反**, 这是最坏的一种交互缺陷。
    #
    #   现在: 给了默认值 → 回车取默认值并返回 0; 没给 → 保持原语义 (回车取消)。
    #   提示里的默认值也由这里统一渲染, 避免调用方自己在 prompt 里再拼一遍
    #   (拼了就会渲染成 "[1-4, 回车=auto] [1-4, 0=取消]" 这种重复)。
    local prompt="$1" lo="$2" hi="$3" def="${4:-}" ans hint=""
    [[ -n "$def" ]] && hint=", 回车=$def"
    while :; do
        printf '  %s%s%s %s[%s-%s%s, 0=取消]%s: ' \
            "$_CYN" "$prompt" "$_RST" "$_DIM" "$lo" "$hi" "$hint" "$_RST" >&2
        IFS= read -r ans || ans=""
        ans="${ans// /}"
        if [[ -z "$ans" ]]; then
            [[ -n "$def" ]] && { printf '%s' "$def"; return 0; }
            return 1
        fi
        [[ "$ans" == "0" ]] && return 1
        [[ "$ans" =~ ^[0-9]+$ ]] || { ui_invalid "$ans —— 要数字"; continue; }
        if (( ans < lo || ans > hi )); then
            ui_invalid "$ans —— 范围 $lo-$hi"
            continue
        fi
        printf '%s' "$ans"; return 0
    done
}

# 确认 (默认否)。确认词用 yes, **不是重打名字** ——
# 手打名字正是 Xray 旧交互的毛病来源 (SB/M 都已改成 yes)。
ui_confirm() { # <问题> [yes 表示默认确定]
    local q="$1" def="${2:-no}" ans hint
    [[ "$def" == "yes" ]] && hint="回车=确定" || hint="回车=取消"
    # 问题与确认分两行: 挤在一行时 "(回车=取消)输入 yes 确认:" 两段贴死,
    # 最需要看清的那句反而最难读。
    printf '  %s%s%s\n' "$_YEL" "$q" "$_RST" >&2
    printf '    %s输入 yes 确认 (%s)%s: ' "$_DIM" "$hint" "$_RST" >&2
    IFS= read -r ans || ans=""
    ans="${ans// /}"
    [[ "$ans" == "yes" || "$ans" == "YES" || "$ans" == "y" || "$ans" == "Y" ]]
}

# ------------------------------------------------------------ 编号选择器 --

# 用法:
#     UI_PICK_ROWS=$'tagA\tVLESS   50330  0.0.0.0  REALITY-01\ntagB\t...'
#     ui_pick "删除节点" "还没有节点" "删除" || return
#     echo "$UI_PICK_KEY"          # 选中的 tag
#
# ★ 一次画完整列表 + 收一个编号。
#   旧交互是「先画列表 → 再问名字」: 输错之后列表已滚出屏幕, 错误信息里又没有
#   合法值, 用户只能退出去重进。编号选择天生没有这个问题 —— 输错只是重画。
# ------------------------------------------------------------ 编号表格 ----

# 全项目共用的**唯一**列表渲染器。节点 / 证书 / nginx 站点 / 分享 / DNS
# 全部走这里 —— 这样"某个列表忘了编号"或"某个列表没对齐"就不可能再发生。
#
#   UI_PICK_COLS=(列名1 列名2 …)          # 不含序号列
#   UI_PICK_ROWS=$'key\t字段1\t字段2\n…'  # 第一列是取回用的 key, 不显示
#
# 列宽按**显示宽度**自适应 (中文记 2 列), 所以中文标签不会错位 ——
# printf 的 %-Ns 是按字节算的, 中文一列必歪。
UI_PICK_KEY=""      # 选中的 key
UI_PICK_IDX=""      # 选中的序号 (1 起)
UI_PICK_COLS=()
UI_PICK_ROWS=""

_ui_rows_to_arrays() {
    _UI_KEYS=(); _UI_FIELDS=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # ★ 必须精确地"只切第一个 TAB"。不能用 `IFS=$'\t' read -r k rest`:
        #   TAB 属于 IFS 的空白字符, 于是连续/前导 TAB 会被当成一个分隔符,
        #   空字段被吃掉, 后面每一列整体左移 (地址列显示成端口、端口列显示成
        #   状态…)。实测 UI_PICK_ROWS=$'1.1.1.1\t\t1\n' 会渲染成三列只剩两列。
        if [[ "$line" == *$'\t'* ]]; then
            _UI_KEYS+=("${line%%$'\t'*}")
            _UI_FIELDS+=("${line#*$'\t'}")
        else
            _UI_KEYS+=("$line"); _UI_FIELDS+=("")
        fi
    done <<< "${UI_PICK_ROWS:-}"
}

# 空字段显示成 '-', 免得表格里出现一段空白看起来像没加载出来
_ui_cell() { local v="$1"; printf '%s' "${v:--}"; }

# 按 TAB 精确切分。
# ★ 不用 `IFS=$'\t' read -r -a`: TAB 属于空白字符, IFS 规则会把**连续**的
#   TAB 当成一个分隔符, 空字段被吃掉 —— 于是"端口为空"的行整行左移,
#   协议名显示在节点名列上。分隔符必须逐个吃掉。
_ui_split_tabs() { # <字符串> -> _UI_SPLIT 数组
    _UI_SPLIT=()
    local rest="$1"
    while [[ "$rest" == *$'\t'* ]]; do
        _UI_SPLIT+=("${rest%%$'\t'*}")
        rest="${rest#*$'\t'}"
    done
    _UI_SPLIT+=("$rest")
}

ui_table_print() { # [计数行文案, 如 "共 N 个节点"]
    _ui_rows_to_arrays
    local n=${#_UI_KEYS[@]} nc=${#UI_PICK_COLS[@]}
    if (( n == 0 )); then
        printf '  %s(空)%s\n' "$_DIM" "$_RST" >&2
        return 1
    fi

    # 每列显示宽度
    local -a w=() i c
    for (( c = 0; c < nc; c++ )); do
        w[$c]=$(ui_cjk_w "${UI_PICK_COLS[$c]}")
    done
    local line f field
    for (( i = 0; i < n; i++ )); do
        _ui_split_tabs "${_UI_FIELDS[$i]}"
        for (( c = 0; c < nc; c++ )); do
            field=$(_ui_cell "${_UI_SPLIT[$c]-}")
            local lw; lw=$(ui_cjk_w "$field")
            (( lw > w[$c] )) && w[$c]=$lw
        done
    done

    # 表头
    local out="  $_DIM$(ui_pad_w '序号' 4)"
    for (( c = 0; c < nc; c++ )); do out+="  $(ui_pad_w "${UI_PICK_COLS[$c]}" "${w[$c]}")"; done
    printf '%s%s\n' "$out" "$_RST" >&2
    ui_rule2

    # 数据行
    for (( i = 0; i < n; i++ )); do
        _ui_split_tabs "${_UI_FIELDS[$i]}"
        out="  $_CYN$(printf '%3d' $((i+1)))$_RST"
        for (( c = 0; c < nc; c++ )); do
            out+="  $_BOLD$(ui_pad_w "$(_ui_cell "${_UI_SPLIT[$c]-}")" "${w[$c]}")$_RST"
        done
        printf '%s\n' "$out" >&2
    done

    local cnt="${1:-}"
    [[ -z "$cnt" ]] && cnt="共 $n 项"
    printf '\n  %s%s%s\n' "$_DIM" "$cnt" "$_RST" >&2
    return 0
}

# 画表 + 收一个编号 (不重画第二遍 —— 用户看到的编号就是输入的编号)
ui_pick() { # <标题> <空列表提示> [动作动词]
    local title="$1" empty="${2:-没有可选项}" verb="${3:-选择}"
    _ui_rows_to_arrays
    if (( ${#_UI_KEYS[@]} == 0 )); then
        ui_box "$title"
        printf '  %s%s%s\n' "$_YEL" "$empty" "$_RST" >&2
        printf '\n' >&2
        ui_pause
        return 2
    fi
    local idx
    ui_box "$title"
    ui_table_print
    printf '\n' >&2
    if idx=$(ui_ask_num "$verb" 1 "${#_UI_KEYS[@]}"); then
        UI_PICK_IDX="$idx"; UI_PICK_KEY="${_UI_KEYS[$((idx-1))]}"
        return 0
    fi
    printf '\n' >&2
    ui_note "已取消"
    UI_PICK_KEY=""; UI_PICK_IDX=""
    return 1
}

# 只收编号, 表已经在上面画过了 (菜单首屏那种)
ui_pick_from_shown() { # <动作动词> <总数>
    local verb="$1" n="$2" idx
    idx=$(ui_ask_num "$verb (对应上面列表)" 1 "$n") || { UI_PICK_KEY=""; return 1; }
    UI_PICK_IDX="$idx"
    return 0
}

__x_ui_ready=1