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

_ng() { printf '%s%s%s\n' "${_CYN:-}" "$*" "${_RST:-}" >&2; }
_gn() { printf '%s%s%s\n' "${_GRN:-}" "$*" "${_RST:-}" >&2; }
_yl() { printf '%s%s%s\n' "${_YEL:-}" "$*" "${_RST:-}" >&2; }
_rd() { printf '%s%s%s\n' "${_RED:-}" "$*" "${_RST:-}" >&2; }
# ★ 上面四个一律写 stderr, 而且颜色取自 print.sh 的变量 (它只在 stderr 是终端
#   时才给值)。原来它们写 stdout —— 其中 _rd 是在 _ng_resolve 里被调用的, 而
#   _ng_resolve 的**正常返回值就是打到 stdout 的文件路径**:
#       _NG_PY="$(_ng_resolve nginx_apply.py)"
#   于是报错那一行会和路径粘成一个字符串, _NG_PY 变成
#   "[错误] 获取 nginx_apply.py 失败/tmp/tmp.XXXX" —— 后面每条 python 命令都
#   报"找不到文件", 而真正的原因 (下载失败) 只在错误里出现过一次。
#   另外: 本脚本的 stdout 不承载数据, 但和项目其它入口一样保持单一约定 ——
#   面板把菜单输出与结果输出分开收集, UI 混进 stdout 迟早会被当成结果解析。

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
    if ! curl -fsSL "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/$name" -o "$f"; then
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

# 菜单排版用 conf/lib/print.sh 的 ui_*（与面板同一套）。
_ng_source print.sh 2>/dev/null || true
# ★ ui.sh 必须在 print.sh **之后** source: ui_box 内部要调 ui_title, ui_pause
#   也直接来自 print.sh, 顺序反了就是 "command not found", 菜单整个点不动。
_ng_source ui.sh 2>/dev/null || true
# ★ 原来这里还有一份自己写的 ui_* 兜底 (旧的 54-61 行), 已删。两个理由:
#     1) 那份兜底只画菜单, 没有编号选择器 —— 于是"交互库没取到"的表现是
#        「菜单照常显示, 但每个列表都要用户凭记忆手打名字」, 而不是任何报错。
#        而这个脚本里**每一个**列表 (站点 / 传输方式 / 备份) 都必须是编号的,
#        退化之后那条约定直接失效, 且无从察觉。
#     2) 它不写 stderr (与上面的 _ng/_gn 同一个毛病)。
#   需要 ui.sh 的入口自己过 _ng_ui_need 这道门, 退化时报错而不是悄悄换交互。

# ★ 需要 ui.sh 的入口先过这道门: 交互库取不到时明确说清楚缺什么, 而不是让
#   ui_pick 未定义把菜单炸掉 —— 排版库取不到不该等于菜单点不动。
_ng_ui_need() { # <函数名>
    declare -F "$1" >/dev/null 2>&1 && return 0
    _rd "[错误] 交互库 conf/lib/ui.sh 取不到, 缺 $1"
    return 1
}

_ng_cleanup() { [[ ${#_NGMENU_TMP[@]} -gt 0 ]] && rm -f "${_NGMENU_TMP[@]}"; }
trap _ng_cleanup EXIT

_ng_load() { _NG_PY="$(_ng_resolve nginx_apply.py)" || exit 1; }

# 把 nginx_apply 的只读查询暴露成可调用的函数。查询都要支持 --docker,
# 否则容器化 nginx 的站点一张都列不出来。
_ng_py() { python3 "$_NG_PY" "$@"; }

# ---------------------------------------------------------------- 输出呈现
# 程序输出统一加方框 + 缩进。
# ★ 为什么不再 `| sed 's/^/    /'`: 那只是把每行往前挪四格, 十几行
#   nginx -t / 摘除 / 预览日志就平铺在屏幕上, 读的人分不清哪一段是**哪一次
#   操作**的结果 —— 尤其"摘除"后面紧跟着的正是判断依据 (校验有没有通过),
#   两段混在一起时最容易看错成"摘除失败"。
_ng_dump() { # <标题> ; 从 stdin 读程序输出
    local t="$1" line n=0
    ui_box "$t"
    while IFS= read -r line; do
        printf '    %s\n' "$line" >&2
        n=$((n + 1))
    done
    (( n == 0 )) && printf '    %s(没有输出)%s\n' "${_DIM:-}" "${_RST:-}" >&2
    printf '\n' >&2
}

# ---------------------------------------------------------------- 站点表
# 一次 python 扫全部站点, 结果喂给 ui.sh 的统一渲染器。
#
# ★ 必须**一次**进程扫全部: ui.sh 开头写着"不允许按行起进程" —— Mihomo 首屏
#   给每个节点文件起一个 python3, 20 个文件就是 1.3 秒, 那正是用户说的"卡"。
#   下面这一段把"站点 / server_name / 每个文件里本工具插了几段"一次问完。
_NG_WHERE=""
_ng_sites_query() {
    # 查询走 python -c 而不是给 nginx_apply.py 加子命令 —— 它是库, CLI 只
    # 服务于插入/摘除。列站点、查标记块这些只读操作由菜单自己驱动。
    python3 - "$_NG_PY" <<'PY'
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
    try:
        raw = na.c_read(path, dk).decode("utf-8", "replace")
        n = len(na.find_all_marked_spans_all(raw.split("\n")))
    except OSError:
        n = 0
    # ★ 一个 server_name 里可能有多个域名, 必须**一个域名一行**:
    #   find_site() 比的是 sn.split() 里的**单个元素**, 所以表格若显示
    #   "a.com b.com" 整串, 用户选中它之后 find_site("a.com b.com")
    #   永远返回 None —— "站点明明在列表里, 一点就说找不到"。
    for name in sn.split():
        print("SITE\t%s\t%s\t%d" % (name, path, n))
PY
}

# 把查询结果铺成编号表 (UI_PICK_ROWS), 并记下 nginx 跑在主机还是容器。
# 返回 1 = 一个站点都没有。
_NG_COUNT=0
_ng_sites_load() {
    local kind a b c st
    _NG_SITES=$(_ng_sites_query) || return 1
    _NG_WHERE=""; _NG_COUNT=0
    UI_PICK_COLS=(域名 配置文件 片段 状态)
    UI_PICK_ROWS=""
    while IFS=$'\t' read -r kind a b c; do
        c="${c:-0}"
        case "$kind" in
            NONE)   UI_PICK_ROWS=""; return 1 ;;
            DOCKER) _NG_WHERE="nginx 跑在容器里: $a" ;;
            HOST)   _NG_WHERE="nginx 跑在主机上" ;;
            SITE)
                st="无标记段 (手工配置)"
                (( c > 0 )) && st="本工具插入过"
                # ★ 空字段必须写 "-" 而不是留空: ui.sh 的 _ui_rows_to_arrays
                #   用 `IFS=$'\t' read -r k rest` 切第一刀, 而 TAB 属于 IFS
                #   空白字符, 连续分隔符会被折叠成一个 —— 中间的空字段连同它
                #   自己的 TAB 一起消失, 后面所有列整体左移 (实测过)。
                UI_PICK_ROWS+="${a}"$'\t'"${a}"$'\t'"${b##*/}"$'\t'"$c"$'\t'"$st"$'\n'
                _NG_COUNT=$(( _NG_COUNT + 1 ))
                ;;
        esac
    done <<< "$_NG_SITES"
    [[ -n "$UI_PICK_ROWS" ]]
}

# 一个站点都没有时的"找过哪里"说明。指定了 NGINX_CONF_ROOTS 却没找到, 要说
# 清楚找的是哪里 —— 照常打印默认搜索范围会让人以为去那几个目录找过, 而实际
# 一次都没去过; 这种"说了但没做"的提示比不说更容易把人引到错方向。
_ng_no_sites_hint() {
    if [[ -n "${NGINX_CONF_ROOTS:-}" ]]; then
        _yl "  搜索范围 (NGINX_CONF_ROOTS 指定): ${NGINX_CONF_ROOTS//:/, }"
    else
        _yl "  搜索范围: /etc/nginx/sites-enabled, /etc/nginx/conf.d,"
        _yl "            /usr/local/nginx/conf, 以及容器里的同名目录"
    fi
}

# ★ 菜单 1/2/4 走**同一个** _ng_sites_load: "列站点"那张表上的编号和"选域名"
#   这张表上的编号来自同一份解析的同一次序, 不可能对不上。
#   返回: 0=选中了 (UI_PICK_KEY), 1=用户取消, 2=列表为空。
_ng_pick_site() { # <标题> <空列表提示> <动词>
    _ng_ui_need ui_pick || return 1
    if ! _ng_sites_load; then
        _ng_no_sites_hint
        ui_pick "$1" "$2" "$3"     # 空列表分支: 方框 + 提示 + 暂停, 返回 2
        return 2
    fi
    [[ -n "$_NG_WHERE" ]] && _gn "  $_NG_WHERE"
    ui_pick "$1" "$2" "$3"
    return $?
}

# ---------------------------------------------------------------- 1 列站点
_ng_do_list() {
    _ng_ui_need ui_table_print || return 1
    # ★ 空列表不再自己拼一套 (原来是 95-107 那段手写分支): 方框 / 提示 / 暂停
    #   全部交给 ui_pick 的空分支统一渲染, 这里只补上"到底找过哪里"。
    #   返回 2 表示"ui_pick 已经替我暂停过了", 菜单据此不再暂停第二次。
    if ! _ng_sites_load; then
        _ng_no_sites_hint
        ui_pick "Nginx 站点列表" "没有找到任何 server 块" "查看"
        return 2
    fi
    [[ -n "$_NG_WHERE" ]] && _gn "  $_NG_WHERE"
    # ★ 原来是 `printf '    %-34s %s\n'` —— **一个编号都没有**。而菜单 2 (查看)
    #   和菜单 4 (摘除) 紧接着就要用户手打域名, 于是这张表形同摆设: 用户只能
    #   把域名从屏幕上抄下来, 再一字不差地敲回去; 打错一个字符只得到一句
    #   "找不到域名 xx 的站点文件", 还得回头自己比。%-34s 还按**字节**算宽度,
    #   域名一长整张表就歪。现在交给 ui_table_print: 编号 + 按显示宽度对齐,
    #   而且这张表的编号与菜单 2/4 里那张来自同一次解析 (_ng_sites_load)。
    ui_table_print "共 $_NG_COUNT 个域名"
    return 0
}

# ---------------------------------------------------------------- 2 看某个站点
_ng_do_show() {
    _ng_ui_need ui_pick || return 1
    local dom
    # ★ 原来是 `read -rp "  域名: " dom` —— 要用户把菜单 1 刚打印出来的域名
    #   从屏幕抄下来再敲一遍。域名敲错一个字符不会当场发现, 而是等下面那次
    #   python 查完才回一句"找不到域名 xxx 的站点文件", 用户根本不知道错在哪
    #   一个字。现在编号选: 画出来的编号就是输入的编号。
    #   (于是这里不再有"提示语默认值"可言 —— 原来的 :122 提示整条消失。)
    _ng_pick_site "查看站点" "还没有任何 server 块, 先确认 nginx 配置在预期路径下" \
                  "查看" || return $?
    dom="$UI_PICK_KEY"
    printf '\n' >&2
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
# 一个域名下可能有多段 (按 location 路径区分, tag 是 `域名` 或 `域名|/路径`),
# 全部列出来 —— 只显示第一段会让人以为"就这一段", 删的时候更糊涂。
spans = na.find_all_marked_spans(lines, sys.argv[2])
if spans:
    for (a, b, tag) in spans:
        print("MARK\t%s\t%d\t%d" % (tag, a, b))
        for l in lines[a:b + 1]:
            print("BODY\t%s" % l)
else:
    print("MARK\t-\t-1\t-1")
PY
)
    if [[ "$out" == "NONE" ]]; then
        _rd "  找不到域名 $dom 的站点文件"
        _yl "  用菜单 1 看看实际有哪些 server_name"
        return 1
    fi
    local path="" n=0
    while IFS=$'\t' read -r k a b _; do
        case "$k" in
            PATH) path="$a" ;;
            MARK)
                if [[ "$a" == "-" ]]; then
                    _yl "  本工具没有在这里插入过内容"
                    _yl "  (配置可能是手工写的, 或由更早的脚本插入)"
                else
                    n=$((n + 1))
                    _gn "  本工具插入的段 [$a] 第 $b 行起:"
                    # ★ 每一段各自加框: 一个域名下有多段时 (按 location 路径
                    #   分的), 平铺在一起根本分不清哪几行属于哪一段 —— 而这正是
                    #   接下来"要摘哪一段"的依据。
                    ui_box "插入的片段 [$a]"
                fi
                ;;
            # 块内容里没有制表符分隔, read 会把整行放进第一个变量 ——
            # 所以这里打印 $a 而不是 $b, 否则正文一行都不出来。
            # ★ 一律写 stderr (原来走 stdout): 面板把菜单这一层的输出单独收集,
            #   混进 stdout 的东西会被当成结果解析。
            BODY) printf '    %s\n' "$a" >&2 ;;
        esac
    done <<< "$out"
    _gn "  站点文件: $path"
    (( n > 0 )) || _yl "  (共 0 段)"
}

# ---------------------------------------------------------------- 3 校验配置
_ng_do_check() {
    printf '\n' >&2
    local out
    if command -v nginx >/dev/null 2>&1; then
        # ★ 判断依据必须是 nginx **自己**的退出码。原来的
        #   `if nginx -t 2>&1 | sed 's/^/    /'; then`
        #   测的是管道最后一个命令 (sed) 的退出码 —— 而 sed 永远是 0。
        #   也就是说配置明明有问题, 这里也照样打 "✓ 主机 nginx 配置正常":
        #   假绿灯比不检查更糟, 用户会拿着这份结论去改别的地方。
        #   现在先收下输出, 再用 nginx 自己的状态判断。
        if out=$(nginx -t 2>&1); then
            _ng_dump "主机 nginx 配置" <<< "$out"
            _gn "  ✓ 主机 nginx 配置正常"
        else
            _ng_dump "主机 nginx 配置 (有问题)" <<< "$out"
            _rd "  ✗ 主机 nginx 配置有问题"
        fi
    else
        _yl "  主机没有 nginx 命令"
    fi
    local c rc=0
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx); do
        if out=$(docker exec "$c" nginx -t 2>&1); then rc=0; else rc=$?; fi
        _ng_dump "容器 $c" <<< "$(printf '%s' "$out" | tail -1)"
        (( rc == 0 )) || _rd "  ✗ 容器 $c 的 nginx 配置有问题"
    done
    return 0
}

# ---------------------------------------------------------------- 4 摘除反代
_ng_do_remove() {
    # scope/path 必须给初值: 脚本是 set -u, 而"只有一段"时下面那段赋值不会执行,
    # 后面 `[[ "$scope" == "2" ]]` 就会直接报 unbound variable 退出。
    _ng_ui_need ui_pick || return 1
    local dom scope="" path="" tags nspans=0 tag
    local -a taglist=()
    # ★ 原来是 `read -rp "  要摘除的域名: " dom` —— 让用户把菜单 1 刚列出来的
    #   域名重新敲一遍。摘除是不可逆操作, 却要靠"抄屏幕"来指定对象: 敲错一个
    #   字符的后果是"什么都没摘" (python 按域名精确匹配, 找不到就报一句
    #   "找不到域名"), 用户会以为摘过了。现在编号选。
    #   (于是这里不再有"提示语默认值"可言 —— 原来的 :203 提示整条消失。)
    _ng_pick_site "摘除反代" "还没有任何 server 块, 没有可摘的对象" "摘除" || return $?
    dom="$UI_PICK_KEY"
    printf '\n' >&2
    _yl "  这只删除本工具插入的标记块, 不会动你自己写的 server 块。"
    # 有几段? 一个域名下可能按 location 路径分了多段 (tag 是 `域名` 或 `域名|/路径`)。
    # 只有一段时不再多问, 默认全摘 —— 交互越短越好, 而"删一半留一半"是
    # 最糟的结果 (站点里留下指向已删端口的 location)。
    #
    # ★ tag 现在走 stdout (段数 = 行数), 不再"数打到 stdout、tag 打到
    #   stderr": 原来那句 2>/dev/null 把 tag 直接丢进了垃圾桶 —— tag 被算出来
    #   却不给任何人看, 于是下一步只能让用户凭记忆手敲路径。现在 tag 进编号表。
    tags=$(python3 - "$_NG_PY" "$dom" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("na", sys.argv[1])
na = importlib.util.module_from_spec(spec); spec.loader.exec_module(na)
dk = None if os.environ.get("NGINX_CONF_ROOTS") else na.probe_docker()
hit = na.find_site(sys.argv[2], dk)
if not hit:
    print("NONE"); raise SystemExit
raw = na.c_read(hit, dk).decode("utf-8", "replace")
for (_a, _b, tag) in na.find_all_marked_spans(raw.split("\n"), sys.argv[2]):
    print(tag)
PY
)
    [[ "$tags" == "NONE" ]] && { _rd "  站点文件在列举之后变了, 找不到域名 $dom"
        _yl "  用菜单 1 重新列一次站点"
        return 1; }
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        taglist+=("$tag"); nspans=$((nspans + 1))
    done <<< "$tags"
    if (( nspans > 1 )); then
        _yl "  该域名下有 $nspans 段 (按 location 路径区分)"
        ui_menu 1 "全部摘掉         该域名的标记段都删 (默认)"
        ui_menu 2 "只摘一条路径     同域名别的段不动"
        # ★ ui_ask_num 自带 [1-2, 0=取消] 提示和越界重画, 不再自己 printf 一行
        #   `选择 [1]: ` 然后 read 一个什么都可能收的字符串。
        #   行为上有一处**故意的**变化: 空回车原来是"全摘" (落到 else 分支),
        #   现在是"取消" —— 不可逆操作不该由一次空回车触发。
        scope=$(ui_ask_num "选择" 1 2) || return 1
        if [[ "$scope" == "2" ]]; then
            # ★ 原来让用户手打 location 路径 (如 /HCaVHO3U)。路径就在上面那几行
            #   tag 里, 编号选: 显示列把 tag 和路径都摆出来, key 用 tag 本身
            #   (必须非空, ui.sh 的 _ui_rows_to_arrays 会跳过空 key), 再由 tag
            #   还原出 --path 的值。
            local t p
            UI_PICK_COLS=(标记 tag 路径)
            UI_PICK_ROWS=""
            for t in "${taglist[@]}"; do
                # ★ tag 形如 `域名` 或 `域名|/路径` (分隔符就是 "|", 见
                #   nginx_apply.TAG_SEP)。切路径要**连分隔符一起去掉**:
                #   ${t#"$dom"} 留下的是 "|/api", 原样交给 --path 就一条都
                #   摘不掉、却还报成功 —— 这里按 *| 切, 与 tag_path() 一致。
                if [[ "$t" == "$dom" ]]; then p="整站 (无路径)"; else p="${t#*|}"; fi
                UI_PICK_ROWS+="$t"$'\t'"$t"$'\t'"$p"$'\n'
            done
            ui_pick "选择要摘除的段" "没有可摘的段" "摘除" || return 1
            tag="$UI_PICK_KEY"
            # ★ tag == 域名 的那一段必须还原成 **"/"**, 不能还原成空串:
            #   nginx_apply 的 path_wanted = norm_path(args.path) if args.path
            #   else None —— 传空 = "整域名收工", 会把用户没选的那些段一起摘掉;
            #   传 "/" 则正好只命中 tag_for(domain, "/") == 域名 这一段。
            #   这里传错的后果是"删多了", 而不是"删少了"。
            if [[ "$tag" == "$dom" ]]; then path="/"; else path="${tag#*|}"; fi
        fi
    fi
    printf '\n' >&2
    # ui_confirm 自带"输入 yes (回车=取消)", 顶格拼提示的那行 read -rp 去掉。
    ui_confirm "确认摘除 $dom 的反代?" || { _yl "  已取消"; return 0; }
    printf '\n' >&2
    local out rc=0
    # scope=2 时 path 一定非空 (见上面), 所以这里不再加 -n 判断 ——
    # 漏掉判断的后果是"选择了单条却摘掉整域名"。
    if [[ "$scope" == "2" ]]; then
        out=$(_ng_py --domain "$dom" --path "$path" --remove 2>&1) || rc=$?
    else
        out=$(_ng_py --domain "$dom" --remove 2>&1) || rc=$?
    fi
    _ng_dump "摘除 $dom 的反代" <<< "$out"
    # 退出码不能只看成功与否: --remove 摘干净了也返回 0, 而"摘了但 nginx -t
    # 没通过"会先回滚再返回 1 —— 那种情况下配置文件其实没变。判断依据是输出。
    if grep -q '校验不通过\|reload 失败' <<< "$out"; then
        _rd "  ✗ nginx 校验/reload 失败, 已自动回滚, 配置未改动"
        _yl "    上面的 [错误] 是 nginx 自己说的; 先修好 nginx 再重试"
    elif grep -q '已恢复到' <<< "$out"; then
        _yl "  已回滚到修改前的版本"
    elif grep -q '本次摘除' <<< "$out"; then
        _gn "  ✓ 已摘除, 同目录留了 .xray-core-bak 备份 (菜单 6 可回收)"
    elif grep -q '没有找到' <<< "$out"; then
        _yl "  没有可摘除的标记块 (可能被手工改过)"
    elif (( rc == 0 )); then
        _yl "  没有需要改动的内容"
    else
        _rd "  摘除失败 (退出码 $rc)"
    fi
}

# ---------------------------------------------------------------- 5 预览插入
_ng_do_preview() {
    _ng_ui_need ui_pick || return 1
    local dom port tr out
    # ★ 预览的确实是"还没建"的节点, 站点表里不会有它 —— 所以光靠选号不够。
    #   但只留"手打域名"就和菜单 2/4 不一致了: 同一份脚本里, 看站点和摘除
    #   都是编号选, 到了预览就变成凭记忆敲域名, 而敲错一个字的表现是后面
    #   一句"找不到域名 xxx 的站点文件" —— 用户不知道自己错在哪一个字。
    #   两条路都给: 先编号选现有站点; 取消则说明是要预览还没建的站点, 再手填。
    if _ng_pick_site "预览插入 (选现有站点)" "还没有任何 server 块" "选" ; then
        dom="$UI_PICK_KEY"
        ui_note "  要预览一个还没建的站点? 重新跑一次并直接回车即可手填"
    else
        dom=$(ui_ask "域名 (还没建的站点直接填, 只影响预览输出)" "t.example")
        printf '\n' >&2
    fi
    port=$(ui_ask "回源端口 (xray 节点监听的端口)")
    [[ -n "$dom" && -n "$port" ]] || { _yl "  域名与端口都要填"; return 1; }
    # ★ 原来是 `read -rp "传输方式 ws/grpc/h2/httpupgrade/xhttp [ws]: "` ——
    #   五个值全塞进提示里让用户凭记忆敲。写错一个字母不会当场发现, 而是在
    #   下面 nginx_apply.py 里解析失败 (或更糟: 悄悄按别的传输方式生成预览),
    #   用户看到的只是一段对不上的 nginx 配置。现在编号选, ws 标成默认。
    #   空回车 = 取消 (ui_ask_num 的约定), 不再"静默按 ws 继续"。
    UI_PICK_COLS=(传输方式 说明)
    UI_PICK_ROWS="ws"$'\t'"ws"$'\t'"最通用, 面板/客户端默认都支持  ← 推荐 (默认)"$'\n'
    UI_PICK_ROWS+="grpc"$'\t'"grpc"$'\t'"HTTP/2, 需要后端支持"$'\n'
    UI_PICK_ROWS+="h2"$'\t'"h2"$'\t'"HTTP/2, 老面板用这个"$'\n'
    UI_PICK_ROWS+="httpupgrade"$'\t'"httpupgrade"$'\t'"可穿透部分 CDN"$'\n'
    UI_PICK_ROWS+="xhttp"$'\t'"xhttp"$'\t'"Xray 新传输, 需要较新内核"$'\n'
    ui_pick "传输方式" "没有可选的传输方式" "选" || return $?
    tr="$UI_PICK_KEY"
    printf '\n' >&2
    _yl "  下面是将会插入的内容 (--dry-run, 不落盘):"
    out=$(_ng_py --domain "$dom" --port "$port" --transport "$tr" --dry-run --nginx none 2>&1)
    _ng_dump "$tr 反代预览 (端口 $port)" <<< "$out"
}

# ---------------------------------------------------------------- 6 备份与孤儿
# 备份"只增不减"是 mihomo 那边的反面教材: 每次改动都留一份 `-bak`, 从不回收。
# 这边的口径是: 规范备份一份 (回滚用) + 历史备份若干 (默认 3), 超出就回收;
# 回收范围**只限本工具自己的命名**, 站点文件已经不在的备份一律不碰 —— 那可能
# 是那份配置的最后一份副本。
_ng_do_backups() {
    _ng_ui_need ui_table_print || return 1
    printf '\n' >&2
    _yl "  本工具留下的备份 (规范一份 + 历史若干):"
    local raw out f="" line bfile ts
    raw=$(_ng_py --list-backups 2>&1)
    # ★ 原来是 `--list-backups | sed 's/^/    /'`: 那是 nginx_apply.py 的调试
    #   输出, 靠"每行前导空格"当层级 (文件顶格 / 备份缩进四格), 而且**没有列**。
    #   三个站点各留两份备份时, 三段输出长得一模一样, 眼睛只能靠数缩进来分
    #   "哪几行属于哪个文件"。这里解析成对齐的表: 站点 / 备份 / 备份文件 / 时间。
    #   ★ 空字段一律写 "-" (见 _ng_sites_load 里那条: _ui_rows_to_arrays 会把
    #     连续 TAB 折成一个, 空格子连同 TAB 一起消失, 后面所有列整体左移)。
    UI_PICK_COLS=(站点 备份 备份文件 时间)
    UI_PICK_ROWS=""
    while IFS= read -r line; do
        if [[ "$line" != ' '* ]]; then
            f="${line##*/}"; continue          # 顶格的是站点文件路径
        fi
        if [[ "$line" =~ ^[[:space:]]*历史备份:[[:space:]]+(.*)[[:space:]]+\((.*)\)$ ]]; then
            bfile="${BASH_REMATCH[1]}"; ts="${BASH_REMATCH[2]}"
            UI_PICK_ROWS+="$bfile"$'\t'"$f"$'\t'"历史"$'\t'"${bfile##*/}"$'\t'"$ts"$'\n'
        elif [[ "$line" =~ ^[[:space:]]*最新备份:[[:space:]]+(.*)$ ]]; then
            bfile="${BASH_REMATCH[1]}"
            # nginx_apply 不给"最新备份"打时间戳, 这里如实留 '-' 而不是猜一个
            UI_PICK_ROWS+="$bfile"$'\t'"$f"$'\t'"最新"$'\t'"${bfile##*/}"$'\t'"-"$'\n'
        elif [[ "$line" == *"本工具没有留下备份"* ]]; then
            UI_PICK_ROWS+="$f"$'\t'"$f"$'\t'"-"$'\t'"(本工具没有留下备份)"$'\t'"-"$'\n'
        fi
    done <<< "$raw"
    if [[ -n "$UI_PICK_ROWS" ]]; then
        ui_table_print
    else
        # 一条备份都没解析出来 (比如 python 直接报错了): 原样摆出来, 别把
        # 报错吃掉 —— "没有备份"和"没查到"是两回事。
        _ng_dump "备份清单" <<< "$raw"
    fi
    printf '\n' >&2
    # y/N 默认否, 用 ui_confirm 统一呈现 (它接受 yes/y/Y, 原来的 y 仍然有效)
    ui_confirm "回收历史备份 (保留最新 3 份)?" || { _yl "  已取消"; return 0; }
    printf '\n' >&2
    out=$(_ng_py --prune-backups --keep 3 2>&1)
    _ng_dump "回收历史备份的结果" <<< "$out"
}

_ng_do_orphans() {
    _ng_ui_need ui_ask || return 1
    printf '\n' >&2
    _yl "  扫描站点里已无对应节点的标记段"
    _yl "  (只认本工具的 BEGIN/END 标记; 你手写的 location 一个都不碰)"
    # 存活域名由 node.sh 在删节点时判断; 这里让用户输入"当前活着的域名",
    # 留空 = 站点里所有标记段都算孤儿 (先 dry-run 看一眼再决定)。
    # ★ 默认值写进提示本身 (原来只有 "留空=全部视为孤儿" 半句, 没说什么算存活)。
    local live out
    live=$(ui_ask "当前存活的域名 (逗号分隔; 回车=留空, 站点里所有标记段都算孤儿)")
    printf '\n' >&2
    _yl "  预演 (不会写盘):"
    out=$(_ng_py --prune-orphans "$live" --dry-run 2>&1)
    _ng_dump "孤儿片段预演清单" <<< "$out"
    ui_confirm "按上面的清单清理?" || { _yl "  已取消"; return 0; }
    printf '\n' >&2
    out=$(_ng_py --prune-orphans "$live" 2>&1)
    _ng_dump "孤儿片段清理结果" <<< "$out"
}

# ---------------------------------------------------------------- 菜单
_ng_menu() {
    local c rc
    while :; do
        printf '\n' >&2
        ui_title "Nginx 站点管理"
        ui_menu 1 "列出所有站点     server_name 与所在文件"
        ui_menu 2 "查看某个站点     含本工具插入的内容"
        ui_menu 3 "校验配置         nginx -t（主机与容器）"
        ui_menu 4 "摘除反代         只删标记块，不动自写的 server"
        ui_menu 5 "预览插入         --dry-run 看会插什么"
        ui_menu 6 "备份与回收       列出/回收本工具的历史备份"
        ui_menu 7 "孤儿片段清理     站点里已无对应节点的标记段"
        ui_menu 0 "返回"
        printf '\n' >&2
        # ★ 原来是 `printf '  %s请选择%s: ' ; read -r c`:
        #     1) 提示只写到 **stdout** (read -r c 自己读 stdin, 提示靠 printf
        #        打到 stdout) —— 于是菜单和结果混在同一个流里, 面板收集时
        #        分不开;
        #     2) stdin 关闭 (EOF) 时 read 返回非 0 且**不修改** c, 脚本是
        #        set -u, 下一行 `case "$c"` 直接报 unbound variable 退出 ——
        #        面板经 curl 执行、stdin 是空的时候就是这个下场。
        #   ui_ask_num 一次解决两个: 提示走 stderr、自带 [0-7, 0=取消] 范围、
        #   非数字/越界重画同一个菜单, EOF 返回 1 = 取消 (等同原来的 0 和 "")。
        c=$(ui_ask_num "请选择" 0 7) || return 0
        case "$c" in
            1) _ng_do_list ;;
            2) _ng_do_show ;;
            3) _ng_do_check ;;
            4) _ng_do_remove ;;
            5) _ng_do_preview ;;
            6) _ng_do_backups ;;
            7) _ng_do_orphans ;;
            0) return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        # ★ 每个动作之后停一下 (原来一次都没有): 站点表 / 摘除结果 / 校验输出
        #   都是十几行往上, 不停的话回到菜单时已经被顶上滚没了 —— 用户看到
        #   的只有菜单, 还以为"点了没反应", 于是再点一次。
        #   ★ 返回 2 的那几家 (站点表为空时 ui_pick 自己已经暂停过, 它得解释
        #   "为什么没有列表") 不再暂停第二次 —— 否则一次操作要按两下回车。
        rc=$?
        if (( rc != 2 )); then ui_pause; fi
    done
}

# 只在直接执行时跑菜单。库被 source 就自己弹菜单会把调用方的 stdin 吃掉。
[[ "${BASH_SOURCE[0]:-$0}" == "$0" ]] || return 0 2>/dev/null || exit 0

_ng_load
_ng_menu