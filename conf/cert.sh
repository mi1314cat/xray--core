#!/usr/bin/env bash
# =============================================================
# cert.sh — 证书管理 (面板 17)
#
# 为什么要有这个入口
# ------------------
# cert.sh 里的 8 个函数从建库起就只被 source, 没有用户入口。实际现场里
# 证书问题恰恰是最难自查的一类:
#
#   · 路径写错了 —— `xray run -test` 对不存在的证书文件**不一定**报错,
#     因为校验可能发生在握手阶段
#   · crt 与 key 不是一对 —— 服务能起, 握手永远失败
#   · 证书过期 —— 服务照跑, 只有客户端连不上, 日志里只有一句
#     "remote error: tls: bad certificate"
#
# 这些的表现都是"节点配好了但连不上", 而配置本身看着完全正常。所以把
# "证书到底行不行"做成一个能直接问的入口, 比让用户自己读配置猜要可靠。
#
# 危险操作 (GC 删除) 一律二次确认, 且默认只列不删。
# =============================================================

set -u

_CERTMENU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_CERTMENU_TMP=()

# ★ 一律 >&2。本文件由面板用 xray_run 执行, stdout 是下游的数据通道
#   (分享链接 / 订阅内容) —— 界面字符混进去会被当成链接解析 (见 lib/print.sh)。
_cr() { printf '\033[34m%s\033[0m\n' "$*" >&2; }
_gr() { printf '\033[32m%s\033[0m\n' "$*" >&2; }
_yl() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
_rd() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 面板 curl 执行时同目录没有 lib/, 所以按需取。
_cr_source() {
    local name="$1" f
    if [[ -r "$_CERTMENU_DIR/lib/$name" ]]; then
        # shellcheck source=/dev/null
        source "$_CERTMENU_DIR/lib/$name"
        return 0
    fi
    f="$(mktemp -t "${name}.XXXXXX")"
    if ! curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/$name" -o "$f"; then
        _rd "[错误] 获取 $name 失败"
        rm -f "$f"
        return 1
    fi
    _CERTMENU_TMP+=("$f")
    # shellcheck source=/dev/null
    source "$f"
}

# 菜单排版用 conf/lib/print.sh 的 ui_*（与面板同一套）。
_cr_source print.sh 2>/dev/null || true
# ★ print.sh 拉不到时的兜底: 排版失败不该让菜单点不动。有真库时绝不用这里的
#   朴素版覆盖样式 —— 所以判据是"函数在不在", 不是"文件在不在"。
if ! declare -F ui_menu >/dev/null 2>&1; then
    ui_rule() { printf '%s\n' "----------------------------------------" >&2; }
    ui_title() { ui_rule; printf ' %s\n' "$1" >&2; ui_rule; }
    ui_sec()  { printf '\n %s\n' "$1" >&2; }
    ui_menu() { printf '  %2s) %s\n' "$1" "$2" >&2; }
    ui_hint() { printf '  %s\n' "$1" >&2; }
    ui_kv()   { printf '   %s: %s\n' "$1" "$2" >&2; }
    ui_invalid() { printf '  无效选项: %s\n' "$1" >&2; }
    ui_pause() { printf '\n' >&2; read -r -p "  按回车返回..." _ || true; }
fi

# ★ 统一交互层 (编号选择 / 提问 / 按显示宽度补齐) —— 紧跟在 print.sh 之后。
#   顺序不能换: ui.sh 的 ui_pick / ui_table_print 会调 print.sh 的
#   ui_title / ui_pause, 反过来就是 "command not found"。
#   原来这个位置只有一份**无色排版**兜底: 颜色全无, 更要紧的是它没有编号
#   选择器 —— 于是 cert.sh 自己手搓了 _cr_pick_one (画列表 + read, 还混进
#   一行编号为空的假菜单项)。库在就用库, 下面那套只在库不在时兜底。
_cr_source ui.sh 2>/dev/null || true
if ! declare -F ui_pick >/dev/null 2>&1; then
    # ★ ui.sh 缺失时的最小兜底 —— 只补**交互**, 样式交给上面的 print.sh 兜底。
    ui_note()  { printf '  %s\n' "$1" >&2; }
    ui_rule2() { printf '  %s\n' "----------------------------------------" >&2; }
    ui_pad_w() { printf '%s' "$1"; }
    ui_box()   { ui_title "$@"; }
    ui_ask() {   # <提示> [默认值] -> stdout
        local p="$1" d="${2-}" a=""
        if [[ -n "$d" ]]; then
            read -r -p "  $p (回车=$d): " a || a=""
        else
            read -r -p "  $p: " a || a=""
        fi
        printf '%s' "${a:-$d}"
    }
    ui_ask_num() {  # <提示> <最小> <最大>; 0/空 = 取消
        local p="$1" lo="$2" hi="$3" a
        while :; do
            read -r -p "  $p [$lo-$hi, 0=取消]: " a || return 1
            [[ -z "$a" || "$a" == "0" ]] && return 1
            if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= lo && a <= hi )); then
                printf '%s' "$a"; return 0
            fi
            ui_invalid "$a"
        done
    }
    ui_pick() {    # 画编号表 + 收一个编号 (无方框版)
        local title="$1" empty="${2:-没有可选项}" verb="${3:-选择}"
        local -a keys=() rows=()
        local k r i idx
        while IFS=$'\t' read -r k r; do
            [[ -n "$k" ]] || continue
            keys+=("$k"); rows+=("$r")
        done <<< "${UI_PICK_ROWS:-}"
        if (( ${#keys[@]} == 0 )); then
            printf '  %s\n' "$empty" >&2
            return 2
        fi
        ui_box "$title"
        for (( i = 0; i < ${#keys[@]}; i++ )); do
            printf '   %2d) %s\n' "$((i+1))" "${rows[$i]//$'\t'/  }" >&2
        done
        printf '    0) 返回\n\n' >&2
        read -r -p "  $verb [1-${#keys[@]}, 0=取消]: " idx || return 1
        [[ -z "$idx" || "$idx" == "0" ]] && return 1
        UI_PICK_KEY="${keys[$((idx-1))]}"; UI_PICK_IDX="$idx"
        return 0
    }
fi

_cr_cleanup() { [[ ${#_CERTMENU_TMP[@]} -gt 0 ]] && rm -f "${_CERTMENU_TMP[@]}"; }
trap _cr_cleanup EXIT

_cr_load() { _cr_source cert.sh || exit 1; _cr_source verify.sh 2>/dev/null || true; }

# 结果放全局 _CR_PICK, 不走 stdout。
#
# 为什么不能用 $(_cr_pick_one ...): 那是子 shell, 它的 read 会把调用方 stdin
# 里的后续输入一起消费掉, 而调用方本来是打算接着问下一个问题的。表现是
# 菜单执行到一半静默跳回主菜单 —— 用户看到的是"我明明输入了路径却什么都没发生"。
# 子 shell 里还改不了全局变量, 所以只能用全局变量回传。
_CR_PICK=""
_cr_pick_one() {   # <动作名, 如 "校验一对证书">; 候选来自 x_cert_list
    local prompt="$1"
    local -a items=()
    _CR_PICK=""
    # ★ 用 mapfile 而不是 `$(x_cert_list)` 展开。
    #   原调用点写的是 _cr_pick_one "…" $(x_cert_list) —— **不加引号**, 于是
    #   路径里有空格时 (站点目录带空格是常事) 一个词变成两个词, 列表里全是
    #   半截路径, 用户看到的是"明明有证书却选不出来"。
    mapfile -t items < <(x_cert_list)

    # 显示列是 basename + 目录: basename 才是人能认的, 目录用来区分"两张
    # 同名证书分别在哪个站点下"。key 仍是完整路径 —— 取回来要能直接喂 openssl。
    UI_PICK_COLS=(证书名 目录)
    UI_PICK_ROWS=""
    local f
    for f in "${items[@]}"; do
        UI_PICK_ROWS+="$f"$'\t'"$(basename "$f")"$'\t'"$(dirname "$f")"$'\n'
    done

    ui_pick "$prompt" "没找到任何证书 —— 只能直接输入路径" "选择"
    local rc=$?
    if (( rc == 0 )); then
        _CR_PICK="$UI_PICK_KEY"
        return 0
    fi

    # ★ "直接输入路径"从一行**编号为空、看着能点其实点不了**的假菜单,
    #   变成取消之后的明确一条路 —— 原来那行既不能选 (编号是空的), 用户输
    #   路径又得靠"把路径塞进编号框"这种没任何提示的碰运气, 输错就静默当成
    #   一个不存在的路径。列表为空时也只有这一条路 (原实现此时直接 return 1,
    #   是个死胡同 —— 而证书恰恰最可能就在列表外, 否则不用查了)。
    if (( rc == 2 )); then
        ui_note "没有可选项, 只能直接输入路径。搜索范围:"
        x_cert_search_dirs | sed 's/^/    /' >&2
    else
        ui_note "已取消编号选择 —— 可以直接输入路径 (回车=放弃)"
    fi
    local p
    p=$(ui_ask "$prompt (直接输入路径, 回车=放弃)" "")
    [[ -n "$p" ]] || return 1
    _CR_PICK="$p"
    return 0
}

# ---------------------------------------------------------------- 1 校验一对
_cr_do_check() {
    local crt
    _cr_pick_one "校验一对证书 (.crt)" || return 1
    crt="$_CR_PICK"
    [[ -f "$crt" ]] || { _rd "  文件不存在: $crt"; return 1; }
    # 私钥路径的推导要覆盖现场真实的几种命名 (xxx.key / xxx_privkey.pem /
    # xxx_crt.pem …), 而且剥扩展名时只能剥 basename —— ${x%.*} 剥的是路径里
    # 最后一个点, 目录名里带点时 (mktemp 的 /tmp/tmp.ABCD 就是) 会把目录
    # 一起剥掉, 于是所有候选路径都指向别处, 表现为"明明有私钥却说找不到"。
    local dir base_n
    dir="$(dirname "$crt")"
    base_n="$(basename "${crt%_fullchain.pem}")"   # 先剥 fullchain 后缀
    base_n="${base_n%.*}"                           # 再剥这一段的扩展名
    local base="$dir/$base_n" key=""
    local cand
    for cand in "${base}_privkey.pem" "${base}.key" "${crt%.crt}.key" \
               "${crt%.crt}_key.pem" "${base%.pem}.key"; do
        if [[ -f "$cand" ]]; then key="$cand"; break; fi
    done
    if [[ -z "$key" ]]; then
        _yl "  没找到配套私钥 (试过 ${base}_privkey.pem / .key / _key.pem), 只查证书本身"
        # x_cert_check 要求 crt 与 key 都非空, 没私钥时只能借 openssl 单独查
        # 证书 —— 前面已经确认过文件存在, 所以这里只查有效期。
        if openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then
            _gr "  ✓ 证书本身可用 (有效期 OK, 未校验私钥配对)"
            local exp
            exp=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2-)
            [[ -n "$exp" ]] && _cr "    到期: $exp"
            if ! openssl x509 -in "$crt" -noout -checkend $((30*86400)) >/dev/null 2>&1; then
                _yl "    30 天内到期 —— 该续期了"
            fi
        else
            _rd "  ✗ 证书已过期或无法解析"
        fi
        return 0
    fi
    # ★ 走 ui_ask: 原来是一句 read -rp "  期望域名 (回车=不校验): ", 提示写在
    #   提示语里而且和 read 的冒号叠在一起; ui_ask 把提问与结果分开 (答案走
    #   stdout, 界面走 stderr), "回车=不校验" 单独一行说明 —— 默认值是空, 所以
    #   没法像有默认值那样印在提示后面, 但**必须**说清回车会发生什么。
    local dom=""
    printf '\n' >&2
    ui_note "回车 = 不校验域名, 只看有效期与 crt-key 配对"
    dom=$(ui_ask "期望域名" "")
    if x_cert_check "$crt" ${key:+"$key"} ${dom:+"$dom"}; then
        _gr "  ✓ 可用"
    else
        _rd "  ✗ 不可用 —— 上面是具体原因"
        _yl "  提示: 服务能起但握手失败, 通常就是这一步没过"
    fi
}

# ---------------------------------------------------------------- 2 列出全部
# 证书路径 → 一个短、但**能区分同名文件**的目录标签。
#
# ★ 原来只打印 basename, 于是"8 个证书"里三组同名文件长得一模一样
#   (同一张证书被发现在多个搜索目录里各存了一份)。后来改成"只留最后两段",
#   仍然不够 —— /opt/a/web/certs 和 /srv/b/web/certs 的最后两段都是 web/certs,
#   于是两行还是一模一样, 用户照样挑不出来。
#
#   所以这里剥掉几个已知的公共前缀, 再短到足够区分为止:
#   同名文件之间只剩前缀差异时, 退回完整路径 (宁可长, 也不能挑错)。
_cr_short_dir() {
    # ★ 必须拆成两句: `local d="..." s="$d"` 里的 $d 是在 local 生效**之前**
    #   展开的 —— 读到的是外层的 d, 而 cert.sh 开着 set -u, 于是每行都报
    #   "d: unbound variable" 并且整列变成空的。
    local d="${1%/*}"
    local s="$d"
    case "$d" in
        "$XRAY_BASE"/*)                       s="X:${d#"$XRAY_BASE"/}" ;;
        /etc/letsencrypt/archive/*)           s="LE归档:${d#/etc/letsencrypt/archive/}" ;;
        /etc/letsencrypt/live/*)              s="LElive:${d#/etc/letsencrypt/live/}" ;;
        /etc/nginx/*)                         s="nginx:${d#/etc/nginx/}" ;;
        /root/catmi/cert-backup-*/*)          s="备份:${d##*/cert-backup-*/}" ;;
        /root/catmi/certs/*)                  s="catmi:${d#/root/catmi/certs/}" ;;
        /home/web/certs/*)                    s="web:${d#/home/web/certs/}" ;;
    esac
    # 还是太长 / 还是可能被别的条目顶掉 → 只留最后两段
    if (( $(ui_cjk_w "$s") > 28 )); then
        s="$(printf '%s' "$d" | awk -F/ '{ if (NF<=2) print $0; else print $(NF-1)"/"$NF }')"
    fi
    printf '%s' "$s"
}

_cr_do_list() {
    local -a all raw
    mapfile -t raw < <(x_cert_list)
    # ★ x_cert_list 会因为搜索目录互相重叠而返回**同一个文件的重复条目**
    #   (这台机器上 8 条里只有 5 个不同的路径)。列表里两行一模一样地排着,
    #   用户会以为是两张不同的证书, 数出来的个数也对不上。
    #   这里按完整路径去重, 并把被折叠掉的条数明确说出来。
    local -A seen=()
    all=()
    for _f in ${raw[@]+"${raw[@]}"}; do
        [[ -n "$_f" && -z "${seen[$_f]:-}" ]] || continue
        seen[$_f]=1; all+=("$_f")
    done
    local dupcount=$(( ${#raw[@]} - ${#all[@]} ))
    if [[ ${#all[@]} -eq 0 ]]; then
        _yl "  没找到任何证书"
        _yl "  搜索范围: Xray 片段与主配置、nginx 站点目录、分享目录、"
        _yl "            以及容器挂载进来的目录"
        return 0
    fi
    # ★ 光看 basename 会看到"8 个证书"其实只有 3 个不同文件名 ——
    #   同一张证书被发现在多个搜索目录里各存了一份 (容器挂载目录 + 站点目录
    #   + 分享目录), 而原来只打印 basename, 于是列表里三行长得一模一样,
    #   用户既判断不了该动哪一个, 也看不出重名意味着"重复投放"。
    #   所以这里补一列**所在目录** (取相对搜索根的短路径), 重名立刻可辨。
    _cr "  共 ${#all[@]} 个证书:"
    (( dupcount > 0 )) && _yl "  (搜索目录有重叠, 已折叠 $dupcount 条重复项)"
    local f dir
    UI_PICK_COLS=(证书名 所在目录 状态)
    UI_PICK_ROWS=""
    local i=0
    for f in "${all[@]}"; do
        i=$((i+1))
        local st="?"
        if x_cert_in_use "$f" 2>/dev/null; then st="使用中"; else st="未引用"; fi
        dir=$(_cr_short_dir "$f")
        UI_PICK_ROWS+="$f"$'\t'"$(basename "$f")"$'\t'"$dir"$'\t'"$st"$'\n'
    done
    ui_table_print

    # 重名是这里最常见的坑, 直接说出来, 免得用户以为是重复显示
    local dup
    dup=$(printf '%s\n' "${all[@]}" | xargs -n1 basename 2>/dev/null | sort | uniq -d)
    if [[ -n "$dup" ]]; then
        printf '\n' >&2
        _yl "  注意: 下列文件名在多个目录里各有一份 —— 改一处不会影响另一处:"
        printf '    %s\n' $dup >&2
        _yl "  需要删重复的那份, 请用「4) 回收未引用」"
    fi
}

# ---------------------------------------------------------------- 3 谁在用
_cr_do_who() {
    local crt
    _cr_pick_one "谁在用这张证书 (.crt)" || return 1
    crt="$_CR_PICK"
    printf '\n' >&2
    if x_cert_in_use "$crt" 2>/dev/null; then
        _yl "  在使用中:"
        x_cert_referenced_by "$crt" 2>/dev/null | sed 's/^/    /' >&2
        _cr "  → 不能删"
    else
        _gr "  没有任何片段、nginx 配置或容器引用它"
        _cr "  → 可以删 (菜单 4)"
    fi
}

# ---------------------------------------------------------------- 4 回收
_cr_do_gc() {
    local -a all
    mapfile -t all < <(x_cert_list)
    [[ ${#all[@]} -eq 0 ]] && { _yl "  没有可回收的证书"; return 0; }
    printf '\n' >&2
    _cr "  逐个检查:"
    local -a orphans=()
    local f
    for f in "${all[@]}"; do
        if x_cert_in_use "$f" 2>/dev/null; then
            printf '    %s %s\n' "$(ui_pad_w "$(basename "$f")" 52)" "使用中, 保留" >&2
        else
            printf '    %s %s\n' "$(ui_pad_w "$(basename "$f")" 52)" "未引用, 可删" >&2
            orphans+=("$f")
        fi
    done
    printf '\n' >&2
    if [[ ${#orphans[@]} -eq 0 ]]; then
        _gr "  没有孤儿证书, 无需操作"
        return 0
    fi
    _yl "  候选 ${#orphans[@]} 个:"
    printf '    %s\n' "${orphans[@]}" >&2
    printf '\n' >&2
    # 删除不可逆, 而且证书可能在快照/备份/别的机器上还有用 —— 即便当前
    # 没有任何片段引用。所以默认不删, 要删必须显式打全字。
    #
    # ★ 走 ui_ask 而不是 read -rp: 提示与答案分开 (界面 >&2, 答案走 stdout),
    #   DELETE 的大写原样保留 —— 确认词必须是"不可手滑"的, 这里不改。
    local ans
    ans=$(ui_ask "真的删除这 ${#orphans[@]} 个? 输入 DELETE 确认" "")
    [[ "$ans" == "DELETE" ]] || { _yl "  已取消"; return 0; }
    printf '\n' >&2
    x_cert_gc "${orphans[@]}"
}

# ---------------------------------------------------------------- 5 容器里的
# ★ 迁移到项目目录 —— 修"证书被别人的续签顺手删掉"的根治动作。
_cr_do_migrate() {
    local dir="${XRAY_CONF_DIR:-$XRAY_BASE/conf}"
    local -a frags=()
    local f
    shopt -s nullglob
    for f in "$dir"/*.json; do [[ -f "$f" ]] && frags+=("$f"); done
    shopt -u nullglob
    if [[ ${#frags[@]} -eq 0 ]]; then
        _yl "  $dir 下没有片段"
        return 0
    fi
    printf '\n' >&2
    _cr "  将把片段里指向外部目录的证书路径改到: $(x_cert_project_dir)"
    _yl "  外部目录 = KPanel / nginx / acme.sh / letsencrypt —— 那些不归我们管,"
    _yl "  它们的续签会先删后签, 中途失败磁盘上就只剩私钥。"
    _yl "  每个被改的片段都会留一份 .bak-时间戳。"
    printf '\n' >&2
    local ans
    ans=$(ui_ask "开始迁移这 ${#frags[@]} 个片段?" "")
    [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]] || { _yl "  已取消"; return 0; }
    printf '\n' >&2
    x_cert_migrate "${frags[@]}" || { _rd "  有片段没能改写, 请人工看一眼"; return 1; }
    printf '\n' >&2
    _gr "  迁移完成。建议接着跑 1) 体检 确认内核还能加载。"
    printf '  %s' >&2
}

_cr_do_container() {
    local -a cs
    mapfile -t cs < <(x_cert_container_certs)
    if [[ ${#cs[@]} -eq 0 ]]; then
        _yl "  没有容器里的证书"
        _cr "  说明: 没查到运行中的容器, 或容器没挂载证书目录"
        _cr "  这里查得到很关键 —— 容器挂进来的证书不在主机任何配置里,"
        _cr "  主机的 GC 会把它们当孤儿删掉"
        return 0
    fi
    # x_cert_container_certs 的每行是 "<路径>  (容器 <名>)" —— 拆开显示,
    # 否则整行当路径就没法复制粘贴去 openssl 看。
    _cr "  容器里的证书 ${#cs[@]} 个:"
    local line
    for line in "${cs[@]}"; do
        printf '    %s %s\n' "$(ui_pad_w "${line%%  (容器*}" 56)" "${line##*(容器}" >&2
    done
}

# ---------------------------------------------------------------- 6 搜索范围
_cr_do_where() {
    _cr "  证书搜索范围:"
    x_cert_search_dirs | sed 's/^/    /' >&2
    printf '\n' >&2
    _cr "  容器里额外能看到的:"
    docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | sed 's/^/    /' >&2 || \
        _yl "    (docker 不可用或无权限)"
}

# ---------------------------------------------------------------- 菜单
_cr_menu() {
    while :; do
        printf '\n' >&2
        ui_title "证书管理"
        ui_menu 1 "校验一对证书   路径 / 有效性 / crt-key 配对 / 域名"
        # ★ 原来这里是 ui_menu 2 "列出全部证书   标注"使用中"还是"未引用"" ——
        #   字符串在中途就闭合了, 后面两段是**独立参数**, 于是 ui_menu 只拿到
        #   截断的一半 (后半句被当作编号/颜色之类的废参数丢掉)。整串改用单引号,
        #   引号原样显示, 不再依赖"不引号=词边界"那套拼接。
        ui_menu 2 '列出全部证书   标注"使用中"还是"未引用"'
        ui_menu 3 "谁在用这张     引用它的片段与 nginx 配置"
        ui_menu 4 "回收未引用     只删没有任何引用的（需确认）"
        ui_menu 5 "容器里的证书   主机 GC 看不到的那部分"
        ui_menu 6 "搜索范围       证书会从哪些目录被发现"
        ui_menu 7 "迁到项目目录   改掉指向外部目录的证书路径 (根治丢失)"
        ui_menu 0 "返回"
        # ★ 上面 ui_menu 画一遍就够了。原来这后面还跟着七行 _gr "  2) …" 的
        #   原样复刻, 于是每轮循环菜单都出现两遍 (值还各不相同: 这里的
        #   "标注使用中还是未引用" 与上面那条不是同一句话) —— 用户根本分不清
        #   哪一份才是菜单。已删除。
        printf '\n  选择: ' >&2
        # ★ EOF 直接退出菜单: 少了这个, 面板 / cron 把 stdin 关掉时 read 一直
        #   返回非 0 且不改 $c, 菜单会空转刷屏永不退出 (日志菜单早就踩过这个)。
        read -r c || return 0
        case "$c" in
            # ★ 每个动作后都 ui_pause: 「列出全部」/「回收未引用」能刷出几十行,
            #   结果 (✓ 可用 / 已取消) 直接就顶掉了, 用户根本没机会看见。
            1) _cr_do_check; ui_pause ;;
            2) _cr_do_list; ui_pause ;;
            3) _cr_do_who; ui_pause ;;
            4) _cr_do_gc; ui_pause ;;
            5) _cr_do_container; ui_pause ;;
            6) _cr_do_where; ui_pause ;;
            7) _cr_do_migrate; ui_pause ;;
            0|"") return 0 ;;
            *) _rd "  无效选项: $c" ;;
        esac
    done
}

# ★ _cr_load 只调一次 —— 原来它在下面菜单前还紧接着调了第二次, 等于把
#   lib/cert.sh 与 lib/verify.sh 重新 source 一遍, 白白重跑它们的初始化。
_cr_load
# 只在直接执行时跑菜单。被 source 时只定义函数 —— 库被 source 就自己弹菜单,
# 会把调用方的 stdin 吃掉并进入死循环 (菜单在等输入, 而调用方在等菜单返回)。
[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] || return 0 2>/dev/null || exit 0

_cr_menu
