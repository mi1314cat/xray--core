#!/usr/bin/env bash
# =============================================================
# nginx.sh — Nginx 站点管理 (面板 18)
#
# 为什么要有这个入口
# ------------------
# nginx_apply.py 早就做完了 (幂等插入、标记块、upstream 段、缩进跟随、
# Docker 感知), deploy.py 也接上了, 但用户只能通过"建节点"间接用到它 ——
# 想看一眼有哪些站点、想单独摘掉一个域名的反代、想确认插入的内容对不对,
# 都没有入口。而 nginx.sh (旧脚本) 里的 nginxsl() 是整包安装并**直接覆盖
# /etc/nginx/nginx.conf**, 拿它当入口等于把用户现有配置冲掉。
#
# 所以这个菜单只做"查看 + 摘除 + 预览", 插入仍由建节点流程负责 —— 插入需要
# 知道回源端口和传输方式, 而那正是建节点时才知道的信息。
# =============================================================

set -u

_NGMENU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_NGMENU_TMP=()

_ng() { printf '\033[34m%s\033[0m\n' "$*"; }
_gn() { printf '\033[32m%s\033[0m\n' "$*"; }
_yl() { printf '\033[33m%s\033[0m\n' "$*"; }
_rd() { printf '\033[31m%s\033[0m\n' "$*"; }

# 记录 lib 文件的路径。shell 库用 source, python 库只记路径 —— 把 .py 当
# bash 脚本 source 会执行它的文档字符串, 表现为屏幕上刷出几行说明然后什么
# 都没发生。
_ng_resolve() {
    local name="$1" f
    if [[ -r "$_NGMENU_DIR/lib/$name" ]]; then
        printf '%s' "$_NGMENU_DIR/lib/$name"
        return 0
    fi
    f="$(mktemp -t "${name%.py}.XXXXXX")"
    if ! curl -fsSL "https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/lib/$name" -o "$f"; then
        _rd "[错误] 获取 $name 失败"
        rm -f "$f"
        return 1
    fi
    _NGMENU_TMP+=("$f")
    printf '%s' "$f"
}

_ng_source() {
    # shellcheck source=/dev/null
    source "$(_ng_resolve "$1")"
}

_ng_cleanup() { [[ ${#_NGMENU_TMP[@]} -gt 0 ]] && rm -f "${_NGMENU_TMP[@]}"; }
trap _ng_cleanup EXIT

_ng_load() { _NG_PY="$(_ng_resolve nginx_apply.py)" || exit 1; }

# 把 nginx_apply 的只读查询暴露成可调用的函数。查询都要支持 --docker,
# 否则容器化 nginx 的站点一张都列不出来。
_ng_py() { python3 "$_NG_PY" "$@"; }

# ---------------------------------------------------------------- 1 列站点
_ng_do_list() {
    local out
    # 查询走 python -c 而不是给 nginx_apply.py 加子命令 —— 它是库, CLI 只
    # 服务于插入/摘除。列站点、查标记块这些只读操作由菜单自己驱动。
    out=$(python3 - "$_NG_PY" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("na", sys.argv[1])
na = importlib.util.module_from_spec(spec)
spec.loader.exec_module(na)
# 调用方已经用 NGINX_CONF_ROOTS 指定了在哪找配置时, 不要再探容器 ——
# 探测会盖掉这个指定, 于是在 nginx 跑在容器里的机器上, 菜单列出来的是容器里
# 的真实站点而不是调用方指定的那套。自检就靠这个变量把测试钉在夹具目录上。
dk = None if os.environ.get("NGINX_CONF_ROOTS") else na.probe_docker()
sites = list(na.list_sites(dk))
if not sites:
    print("NONE")
    sys.exit(0)
print("DOCKER\t%s" % dk if dk else "HOST\t-")
for path, sn in sites:
    print("SITE\t%s\t%s" % (sn or "(无 server_name)", path))
PY
)
    if [[ "$out" == "NONE" ]]; then
        _yl "  没有找到任何 server 块"
        _yl "  搜索范围: /etc/nginx/sites-enabled, /etc/nginx/conf.d,"
        _yl "            /usr/local/nginx/conf, 以及容器里的同名目录"
        return 0
    fi
    local first=1
    while IFS=$'\t' read -r kind a b; do
        if [[ "$kind" == "DOCKER" ]]; then
            [[ $first -eq 1 ]] && _gn "  nginx 跑在容器里: $a"
            first=0
        elif [[ "$kind" == "SITE" ]]; then
            printf '    %-34s %s\n' "$a" "${b##*/}"
        fi
    done <<< "$out"
    [[ $first -eq 1 ]] && _gn "  nginx 跑在主机上"
}

# ---------------------------------------------------------------- 2 看某个站点
_ng_do_show() {
    local dom; read -rp "  域名: " dom
    [[ -z "$dom" ]] && return 1
    echo
    local out
    out=$(python3 - "$_NG_PY" "$dom" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("na", sys.argv[1])
na = importlib.util.module_from_spec(spec); spec.loader.exec_module(na)
dk = None if os.environ.get("NGINX_CONF_ROOTS") else na.probe_docker()
hit = na.find_site(sys.argv[2], dk)
if not hit:
    print("NONE"); sys.exit(0)
print("PATH\t%s" % hit)
# 必须经 c_read 读: 容器部署时 hit 是容器内的路径, 直接 open() 宿主机上
# 没有这个文件 —— 于是"列站点"能看到, "查看站点"却报文件不存在。
raw = na.c_read(hit, dk).decode("utf-8", "replace")
lines = raw.split("\n")
span = na.find_marked_span(lines, sys.argv[2])
if span:
    a, b = span
    print("MARK\t%d\t%d" % (a, b))
    print("BODY")
    for l in lines[a:b + 1]:
        print(l)
else:
    print("MARK\t-1\t-1")
PY
)
    if [[ "$out" == "NONE" ]]; then
        _rd "  找不到域名 $dom 的站点文件"
        _yl "  用菜单 1 看看实际有哪些 server_name"
        return 1
    fi
    local path="" mark="-" body=0
    while IFS=$'\t' read -r k a _; do
        case "$k" in
            PATH) path="$a" ;;
            MARK) mark="$a" ;;
            BODY) body=1 ;;
            # 块内容里没有制表符分隔, read 会把整行放进第一个变量 ——
            # 所以这里打印 $k 而不是 $a, 否则正文一行都不出来。
            *) [[ $body -eq 1 ]] && printf '    %s\n' "$k" ;;
        esac
    done <<< "$out"
    _gn "  站点文件: $path"
    if [[ "$mark" == "-1" ]]; then
        _yl "  本工具没有在这里插入过内容"
        _yl "  (配置可能是手工写的, 或由更早的脚本插入)"
    else
        _gn "  本工具插入的内容 (第 $mark 行起):"
    fi
}

# ---------------------------------------------------------------- 3 校验配置
_ng_do_check() {
    echo
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t 2>&1 | sed 's/^/    /'; then
            _gn "  ✓ 主机 nginx 配置正常"
        else
            _rd "  ✗ 主机 nginx 配置有问题"
        fi
    else
        _yl "  主机没有 nginx 命令"
    fi
    local c
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx); do
        printf '    容器 %s: ' "$c"
        docker exec "$c" nginx -t 2>&1 | tail -1 | sed 's/^/  /'
    done
    return 0
}

# ---------------------------------------------------------------- 4 摘除反代
_ng_do_remove() {
    local dom; read -rp "  要摘除的域名: " dom
    [[ -z "$dom" ]] && return 1
    echo
    _yl "  这只删除本工具插入的标记块, 不会动你自己写的 server 块。"
    read -rp "  确认摘除 $dom 的反代? 输入 yes: " a
    [[ "$a" == "yes" ]] || { _yl "  已取消"; return 0; }
    echo
    local out rc=0
    out=$(_ng_py --domain "$dom" --remove 2>&1) || rc=$?
    printf '%s\n' "$out" | sed 's/^/    /'
    # 退出码不能只看成功与否: --remove 摘干净了也返回 0, 而"摘了但 nginx -t
    # 没通过"会先回滚再返回 1 —— 那种情况下配置文件其实没变。判断依据是输出。
    if grep -q '校验不通过\|reload 失败' <<< "$out"; then
        _rd "  ✗ nginx 校验/reload 失败, 已自动回滚, 配置未改动"
        _yl "    上面的 [错误] 是 nginx 自己说的; 先修好 nginx 再重试"
    elif grep -q '已恢复到' <<< "$out"; then
        _yl "  已回滚到修改前的版本"
    elif grep -q '已移除' <<< "$out"; then
        _gn "  ✓ 已摘除, 同目录留了 .xray-core-bak 备份"
    elif (( rc == 0 )); then
        _yl "  没有可摘除的标记块 (可能被手工改过)"
    else
        _rd "  摘除失败 (退出码 $rc)"
    fi
}

# ---------------------------------------------------------------- 5 预览插入
_ng_do_preview() {
    local dom port tr
    read -rp "  域名: " dom
    read -rp "  回源端口: " port
    read -rp "  传输方式 ws/grpc/h2/httpupgrade/xhttp [ws]: " tr
    [[ -z "$dom" || -z "$port" ]] && return 1
    [[ -z "$tr" ]] && tr=ws
    echo
    _yl "  下面是将会插入的内容 (--dry-run, 不落盘):"
    _ng_py --domain "$dom" --port "$port" --transport "$tr" --dry-run --nginx none 2>&1 | sed 's/^/    /'
}

# ---------------------------------------------------------------- 菜单
_ng_menu() {
    while :; do
        echo
        _ng "════════ Nginx 站点管理 ════════"
        _gn "  1) 列出所有站点     server_name 与所在文件"
        _gn "  2) 查看某个站点     含本工具插入的内容"
        _gn "  3) 校验配置         nginx -t (主机与容器)"
        _gn "  4) 摘除反代         只删标记块, 不动自写的 server"
        _gn "  5) 预览插入         --dry-run 看会插什么"
        _gn "  0) 返回"
        printf "\n  选择: "
        read -r c
        case "$c" in
            1) _ng_do_list ;;
            2) _ng_do_show ;;
            3) _ng_do_check ;;
            4) _ng_do_remove ;;
            5) _ng_do_preview ;;
            0|"") return 0 ;;
            *) _rd "  无效选项: $c" ;;
        esac
    done
}

# 只在直接执行时跑菜单。库被 source 就自己弹菜单会把调用方的 stdin 吃掉。
[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] || return 0 2>/dev/null || exit 0

_ng_load
_ng_menu