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

_cr() { printf '\033[34m%s\033[0m\n' "$*"; }
_gr() { printf '\033[32m%s\033[0m\n' "$*"; }
_yl() { printf '\033[33m%s\033[0m\n' "$*"; }
_rd() { printf '\033[31m%s\033[0m\n' "$*"; }

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

# 菜单排版用 conf/lib/print.sh 的 ui_*（与面板同一套）；取不到就用朴素版。
_cr_source print.sh 2>/dev/null || true
if ! declare -F ui_menu >/dev/null 2>&1; then
    ui_rule() { printf '%s\n' "----------------------------------------"; }
    ui_title() { ui_rule; printf ' %s\n' "$1"; ui_rule; }
    ui_sec()  { printf '\n %s\n' "$1"; }
    ui_menu() { printf '  %2s) %s\n' "$1" "$2"; }
    ui_hint() { printf '  %s\n' "$1"; }
    ui_kv()   { printf '   %s: %s\n' "$1" "$2"; }
    ui_invalid() { printf '  无效选项: %s\n' "$1"; }
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
_cr_pick_one() {
    local prompt="$1"; shift
    local -a items=("$@")
    _CR_PICK=""
    [[ ${#items[@]} -eq 0 ]] && { _yl "  没有候选"; return 1; }
    local i
    for i in "${!items[@]}"; do
        printf '    %2d) %s\n' "$((i+1))" "${items[$i]}"
    done
    printf '    ) 直接输入路径\n'
    local ans
    read -rp "  $prompt: " ans
    [[ -z "$ans" ]] && return 1
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#items[@]} )); then
        _CR_PICK="${items[$((ans-1))]}"
    else
        _CR_PICK="$ans"
    fi
    return 0
}

# ---------------------------------------------------------------- 1 校验一对
_cr_do_check() {
    local crt
    _cr_pick_one "证书路径 (.crt)" $(x_cert_list) || return 1
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
    local dom=""
    read -rp "  期望域名 (回车=不校验): " dom
    echo
    if x_cert_check "$crt" ${key:+"$key"} ${dom:+"$dom"}; then
        _gr "  ✓ 可用"
    else
        _rd "  ✗ 不可用 —— 上面是具体原因"
        _yl "  提示: 服务能起但握手失败, 通常就是这一步没过"
    fi
}

# ---------------------------------------------------------------- 2 列出全部
_cr_do_list() {
    local -a all
    mapfile -t all < <(x_cert_list)
    if [[ ${#all[@]} -eq 0 ]]; then
        _yl "  没找到任何证书"
        _yl "  搜索范围: Xray 片段与主配置、nginx 站点目录、分享目录、"
        _yl "            以及容器挂载进来的目录"
        return 0
    fi
    _cr "  共 ${#all[@]} 个证书:"
    local f
    for f in "${all[@]}"; do
        local st="?"
        if x_cert_in_use "$f" 2>/dev/null; then st="使用中"; else st="未引用"; fi
        printf '    %-56s %s\n' "$(basename "$f")" "$st"
    done
}

# ---------------------------------------------------------------- 3 谁在用
_cr_do_who() {
    local crt
    _cr_pick_one "证书路径 (.crt)" $(x_cert_list) || return 1
    crt="$_CR_PICK"
    echo
    if x_cert_in_use "$crt" 2>/dev/null; then
        _yl "  在使用中:"
        x_cert_referenced_by "$crt" 2>/dev/null | sed 's/^/    /'
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
    echo
    _cr "  逐个检查:"
    local -a orphans=()
    local f
    for f in "${all[@]}"; do
        if x_cert_in_use "$f" 2>/dev/null; then
            printf '    %-52s 使用中, 保留\n' "$(basename "$f")"
        else
            printf '    %-52s 未引用, 可删\n' "$(basename "$f")"
            orphans+=("$f")
        fi
    done
    echo
    if [[ ${#orphans[@]} -eq 0 ]]; then
        _gr "  没有孤儿证书, 无需操作"
        return 0
    fi
    _yl "  候选 ${#orphans[@]} 个:"
    printf '    %s\n' "${orphans[@]}"
    echo
    # 删除不可逆, 而且证书可能在快照/备份/别的机器上还有用 —— 即便当前
    # 没有任何片段引用。所以默认不删, 要删必须显式打全字。
    read -rp "  真的删除这 ${#orphans[@]} 个? 输入 DELETE 确认: " ans
    [[ "$ans" == "DELETE" ]] || { _yl "  已取消"; return 0; }
    echo
    x_cert_gc "${orphans[@]}"
}

# ---------------------------------------------------------------- 5 容器里的
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
        printf '    %-56s %s\n' "${line%%  (容器*}" "${line##*(容器}"
    done
}

# ---------------------------------------------------------------- 6 搜索范围
_cr_do_where() {
    _cr "  证书搜索范围:"
    x_cert_search_dirs | sed 's/^/    /'
    echo
    _cr "  容器里额外能看到的:"
    docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | sed 's/^/    /' || \
        _yl "    (docker 不可用或无权限)"
}

# ---------------------------------------------------------------- 菜单
_cr_menu() {
    while :; do
        echo
        ui_title "证书管理"
        ui_menu 1 "校验一对证书   路径 / 有效性 / crt-key 配对 / 域名"
        ui_menu 2 "列出全部证书   标注"使用中"还是"未引用""
        ui_menu 3 "谁在用这张     引用它的片段与 nginx 配置"
        ui_menu 4 "回收未引用     只删没有任何引用的（需确认）"
        ui_menu 5 "容器里的证书   主机 GC 看不到的那部分"
        ui_menu 6 "搜索范围       证书会从哪些目录被发现"
        ui_menu 0 "返回"
        _gr "  1) 校验一对证书   路径/有效性/crt-key 配对/域名"
        _gr "  2) 列出全部证书   标注使用中还是未引用"
        _gr "  3) 谁在用这张     引用它的片段与 nginx 配置"
        _gr "  4) 回收未引用     只删没有任何引用的 (需确认)"
        _gr "  5) 容器里的证书   主机 GC 看不到的那部分"
        _gr "  6) 搜索范围       证书会从哪些目录被发现"
        _gr "  0) 返回"
        printf "\n  选择: "
        read -r c
        case "$c" in
            1) _cr_do_check ;;
            2) _cr_do_list ;;
            3) _cr_do_who ;;
            4) _cr_do_gc ;;
            5) _cr_do_container ;;
            6) _cr_do_where ;;
            0|"") return 0 ;;
            *) _rd "  无效选项: $c" ;;
        esac
    done
}

_cr_load
# 只在直接执行时跑菜单。被 source 时只定义函数 —— 库被 source 就自己弹菜单,
# 会把调用方的 stdin 吃掉并进入死循环 (菜单在等输入, 而调用方在等菜单返回)。
[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] || return 0 2>/dev/null || exit 0

_cr_load
_cr_menu