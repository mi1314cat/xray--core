#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"  # 修复缺失的闭合引号

# =============================================================
# 取仓库文件 —— 镜像链 + 重试
#
# ★ 面板是用户**第一个** curl 下来的东西, 所以这里必须自带一套, 不能去
#   source 仓库里的 conf/lib/fetch.sh (那还得先下载)。
#
# ★ 为什么需要: 19/20 个菜单项都是 curl 出去跑的。国内机器连 github.com
#   经常是**连接超时**而不是拒绝 —— 单个源不通就整个菜单项卡死, 用户看到的
#   是"点了没反应"。而且实测 push 之后约 5 分钟内 raw 仍返回**旧内容**
#   (GitHub CDN 缓存), 于是"改了不生效"又添一层。
#
# 镜像顺序照抄 mihomo--core 的实战结论:
#   · ghproxy / gh-proxy 是**实时回源**的, 能立刻拿到刚推上去的版本 → 排前
#   · jsdelivr 是 CDN **带缓存**的, 推完 commit 后它仍返回旧文件,
#     加时间戳也绕不过去 → 只能放最后兜底
# =============================================================
XRAY_RAW="${XRAY_RAW:-https://raw.githubusercontent.com/mi1314cat/xray--core/main}"
XRAY_MIRRORS=(
    "https://ghproxy.net/https://raw.githubusercontent.com/mi1314cat/xray--core/main"
    "https://gh-proxy.com/https://raw.githubusercontent.com/mi1314cat/xray--core/main"
    "${XRAY_REPO_PROXY:-https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/xray--core/raw/refs/heads/main}"
    "https://cdn.jsdelivr.net/gh/mi1314cat/xray--core@main"
    "https://fastly.jsdelivr.net/gh/mi1314cat/xray--core@main"
)
# 探测目标必须是**确认存在**的文件。首版曾用 src/VERSION, 而本仓库没有
# 这个文件 —— 每个源都探不通, 整条链直接全废。
XRAY_PROBE="README.md"

_XRAY_CACHE=""
_XRAY_SRC=""

# 选一个可用源 (结果缓存到 _XRAY_SRC, 避免每个菜单项都重探一遍)
xray_pick_source() {
    [[ -n "$_XRAY_SRC" ]] && { printf '%s' "$_XRAY_SRC"; return 0; }
    local base i
    for base in "$XRAY_RAW" "${XRAY_MIRRORS[@]}"; do
        for i in 1 2; do
            # 25 秒 × 2: 12 秒会把"首包慢但其实能通"的镜像误判成不通,
            # 整条链全废 (两个内核的注释里都记着这一条)
            if curl -fsSL --max-time 25 "$base/$XRAY_PROBE" -o /dev/null 2>/dev/null; then
                _XRAY_SRC="$base"
                # ★ 这条警告必须走 stderr。调用处是 `base=$(xray_pick_source)`,
                #   打到 stdout 会被一起捕获 —— 拼出来的 URL 前面挂着一行
                #   带 ANSI 码的提示, curl 必然失败, 于是"切到镜像后的第一次
                #   取文件"要白等一个 30 秒超时, 靠后面的重试循环才救回来。
                [[ "$base" == "$XRAY_RAW" ]] || echo -e "${YELLOW}[!] 主站不通, 已选用镜像 $(printf '%s' "$base" | cut -d/ -f3)${PLAIN}" >&2
                printf '%s' "$_XRAY_SRC"; return 0
            fi
        done
    done
    return 1
}

# _xray_curl_to <base> <仓库相对路径> <目标文件> —— 打印 HTTP 码
# 不用 -f: 需要把 404 和"网络不通"分开。二者都让 -f 返回非 0, 但处理方式
# 完全相反 —— 404 是文件在仓库里不存在, 换多少个镜像都一样; 网络不通才该换源。
_xray_curl_to() {
    curl -sSL --max-time 30 -o "$3.tmp" -w '%{http_code}' "$1/$2" 2>/dev/null
}

# xray_fetch_to <仓库相对路径> <目标文件> —— 按镜像链取到指定位置
xray_fetch_to() {
    local rel="$1" dest="$2" base code
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    base=$(xray_pick_source) || return 1
    code=$(_xray_curl_to "$base" "$rel" "$dest")
    if [[ "$code" = "200" ]]; then
        mv -f "$dest.tmp" "$dest"; return 0
    fi
    rm -f "$dest.tmp"
    # ★ 404 直接放弃, 不要换源。仓库只有一份, 这个源说没有, 别的源也不会有;
    #   逐个试一遍既慢, 又会把"文件不存在"报成"镜像链全不通" —— 后者会把
    #   人往网络问题上带, 而真正的原因是清单里写了个不存在的文件。
    if [[ "$code" = "404" ]]; then
        echo -e "${RED}[Error]${PLAIN} 仓库里没有 $rel (404) —— 清单写错了?" >&2
        return 2
    fi
    # 选中的源这次抽风 —— 换一个再试, 别让整条链白探
    for base in "$XRAY_RAW" "${XRAY_MIRRORS[@]}"; do
        code=$(_xray_curl_to "$base" "$rel" "$dest")
        if [[ "$code" = "200" ]]; then
            mv -f "$dest.tmp" "$dest"; _XRAY_SRC="$base"; return 0
        fi
        rm -f "$dest.tmp"
        [[ "$code" = "404" ]] && return 2
    done
    return 1
}

# 确保会话缓存目录存在，并把它**留在父 shell 里**。
#
# ★ 这个函数存在的唯一理由是一个踩过的坑（2026-10-11 线上复现）:
#   `f=$(xray_fetch "$rel")` 是**命令替换 = 子 shell**，而 xray_fetch 里唯一
#   给 `_XRAY_CACHE` 赋值的地方就在那里面 —— 赋值出了子 shell 就没了。
#   后果不是"少个缓存"，是**两级坏**:
#     ① `xray_ensure_lib` 开头 `[[ -n "$_XRAY_CACHE" ]] || return 0` 直接返回，
#        `$CACHE/lib/` **从来没被铺过**；
#     ② 子脚本是从 `$CACHE/conf_node.sh` 跑的，它按 `dirname $BASH_SOURCE/lib`
#        找依赖 → 落在空目录上 → `[X] 取不到 /tmp/.xray-panel.XXXX/lib/print.sh
#        —— 提示函数不可用`，整个子菜单点不动。
#   而且每次 fetch 都新开一个 mktemp 目录（缓存等于没有，/tmp 里越堆越多）。
#   从**仓库检出目录**跑（也就是 `self/$rel` 命中那一路）永远看不到这个 ——
#   所以它是"本地开发一切正常、用户用公网一键安装就坏"的那类缺陷。
#   建目录必须在**调 xray_fetch 之前**做，否则 $f 和 lib/ 会落在两个不同目录。
xray_cache_dir() {
    [[ -n "$_XRAY_CACHE" ]] || _XRAY_CACHE="$(mktemp -d /tmp/.xray-panel.XXXXXX 2>/dev/null)"
    printf '%s' "$_XRAY_CACHE"
}

# xray_fetch <仓库相对路径> -> stdout 打印本地路径; 失败非 0
xray_fetch() {
    local rel="$1" self dest
    # 1) 从仓库检出目录直接跑 (开发时最常用)
    self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    [[ -f "$self/$rel" ]] && { printf '%s' "$self/$rel"; return 0; }
    # 2) 本次会话的缓存 (同一个菜单项反复进时不重复下载)
    [[ -n "$_XRAY_CACHE" ]] || _XRAY_CACHE="$(mktemp -d /tmp/.xray-panel.XXXXXX 2>/dev/null)"
    dest="$_XRAY_CACHE/$(printf '%s' "$rel" | tr '/' '_')"
    [[ -s "$dest" ]] && { printf '%s' "$dest"; return 0; }
    # 3) 镜像链
    xray_fetch_to "$rel" "$dest" || return 1
    printf '%s' "$dest"
}

# conf/lib/ 下需要在场的东西。改 conf/lib/ 时这里要跟着加 ——
# 漏一个的症状是"某个菜单项报 库加载失败", 而不是面板打不开。
_XRAY_LIB_FILES=(
    addr.sh cert.sh fetch.sh naming.sh ports.sh preset.sh print.sh
    random.sh read.sh service.sh verify.sh
    # ui.sh = 统一交互层 (编号选择/确认/提问/排版)。漏了它不会报"缺依赖",
    # 而是节点管理走 ui.sh 的兜底分支 —— 菜单还在, 交互却退回旧的手打
    # 名字, 而现象是"改了没生效", 极难定位。
    # (注意: 这段注释里不要写出别的库文件名 —— 清单校验会按正则把块里出现的
    #  每个 .sh/.py 都当成清单项去 conf/lib 下找存在性, 注释里写一个就报
    #  "清单里有不存在的文件"。)
    ui.sh
    deploy.py dns_edit.py nginx_apply.py naming.py node_build.py nodes.py
    share_meta.py share_payload.py token_store.py
    hy2_products.py
)

# 把 conf/lib/ 铺到"脚本旁边", 也就是 $_XRAY_CACHE/lib/。
#
# ★ 为什么面板要管这件事:
#   各协议脚本按 `dirname $BASH_SOURCE/lib` 找依赖, 而 xray_fetch 把
#   conf/http.sh 落成 $CACHE/conf_http.sh —— 那个 dirname 是 $CACHE,
#   脚本要的是 $CACHE/lib/。不铺这一层, 每个菜单项都会掉进
#      "本地没有 -> curl github.com"
#   这条兜底分支, 而它正是国内网络取不到的那条路。全新安装时 install.sh
#   只取面板和卸载脚本, conf/ 树由面板按需取 —— 也就是说首次安装走的
#   必定是这条分支。
#
# ★ 一律返回 0: 有的菜单项本来就不需要依赖, 不能因为铺不上就让整个菜单点不动;
#   缺了什么由脚本自己报"库加载失败", 定位更准。
xray_ensure_lib() {
    local dest="$_XRAY_CACHE/lib" self
    [[ -n "$_XRAY_CACHE" ]] || return 0
    [[ -s "$dest/nodes.py" ]] && return 0
    mkdir -p "$dest" 2>/dev/null || return 0
    # 1) 本地检出目录最优先: 快, 而且就是当前这份代码
    self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [[ -d "$self/conf/lib" ]]; then
        cp -an "$self/conf/lib/." "$dest/" 2>/dev/null
        [[ -s "$dest/nodes.py" ]] && return 0
    fi
    # 2) 镜像链补齐 (只补缺的)。rc=2 表示仓库里根本没有这个文件 ——
    #    那是清单写错了, 不是网络问题, 要分开报, 否则会把人往网络上带。
    local f rc failed=0 bogus=0
    for f in "${_XRAY_LIB_FILES[@]}"; do
        [[ -s "$dest/$f" ]] && continue
        xray_fetch_to "conf/lib/$f" "$dest/$f"; rc=$?
        if [[ "$rc" = "2" ]]; then
            bogus=$((bogus + 1))
        elif [[ "$rc" != "0" ]]; then
            failed=$((failed + 1))
        fi
    done
    [[ "$bogus" -gt 0 ]] && echo -e "${RED}[Error]${PLAIN} _XRAY_LIB_FILES 里有 $bogus 个文件仓库中不存在 —— 清单要跟着 conf/lib/ 一起改" >&2
    [[ "$failed" -gt 0 ]] && echo -e "${YELLOW}[!] $failed 个依赖库没取到 —— 相关菜单项可能报「库加载失败」${PLAIN}" >&2
    return 0
}

# xray_run <仓库相对路径> [参数...] —— 取到就执行, 取不到给明确原因
xray_run() {
    local rel="$1"; shift
    local f base
    # ★ 缓存目录必须**先**在父 shell 里建好（见 xray_cache_dir 的注释）：
    #   晚一行，$f 与 $CACHE/lib/ 就会落在两个不同的 mktemp 目录里，
    #   症状是子脚本报 "取不到 .../lib/print.sh"。
    xray_cache_dir >/dev/null
    if ! f=$(xray_fetch "$rel"); then
        echo -e "${RED}[Error]${PLAIN} 取不到 $rel —— 镜像链全不通 (检查网络, 或设 XRAY_REPO_PROXY)"
        return 1
    fi
    # 让脚本的 dirname/lib 找得到依赖。不铺的话每个菜单项都会去 curl github.com。
    xray_ensure_lib
    # 把**本次实际可用的源**交给子脚本: 它们自己的兜底分支写成
    # ${XRAY_RAW:-<主站>}, 于是兜底也跟着走这条通的镜像而不是写死的 github.com。
    base=$(xray_pick_source 2>/dev/null) || base="$XRAY_RAW"
    XRAY_RAW="$base" bash "$f" "$@"
}

# 节点增删之后刷新"已发出去的分享链接"的内容。
#
# 为什么挂在面板层: 协议脚本各写各的收尾 (各自 restart xrayls), 没有统一的
# 收口点; 而**面板是唯一的用户入口** —— 增删节点都得从这几项菜单走。
# 这是真正的收口点, 比去 20 多个脚本尾部各插一行可靠得多。
#
# ★ 失败一律不报错 (|| true)。删节点/加节点是主流程, 不能因为分享服务那边
#   的问题而失败; 刷新本身是"尽力而为", 服务不可达时 share.sh 会自己说一声。
share_refresh_hook() {
    xray_run conf/share.sh refresh >/dev/null 2>&1 || true
}

# 主菜单
# clear 在没有 TERM 的环境（cron、管道、部分 SSH）会报
# "TERM environment variable not set" 并刷一堆错。
_srv_clear() {
  if [ -t 1 ] && [ -n "${TERM:-}" ]; then clear; fi
}

# 面板排版用的 ui_* 在 conf/lib/print.sh 里（与子菜单脚本共用一套）。
# 拿不到就退化成朴素输出 —— 排版失败不该让整个面板打不开。
_xray_load_ui() {
    local self f
    self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [[ -r "$self/conf/lib/print.sh" ]]; then
        # shellcheck source=/dev/null
        source "$self/conf/lib/print.sh"
        return 0
    fi
    f=$(xray_fetch "conf/lib/print.sh" 2>/dev/null) && source "$f" && return 0
    return 1
}
if ! _xray_load_ui || ! declare -F ui_menu >/dev/null 2>&1; then
    # 兜底：只有最朴素的版本，但菜单不会因此消失
    ui_rule() { printf '%s\n' "----------------------------------------" >&2; }
    ui_title() { ui_rule; printf ' %s\n' "$1" >&2; ui_rule; }
    ui_sec()  { printf '\n %s\n' "$1" >&2; }
    ui_menu() { printf '  %2s) %s\n' "$1" "$2" >&2; }
    ui_hint() { printf '  %s\n' "$1" >&2; }
    ui_tip()  { printf '  提示: %s\n' "$1" >&2; }
    ui_invalid() { printf '  无效选项: %s\n' "$1" >&2; }
    ui_pause() { printf '\n'; read -r -p "  按回车返回..." _ || true; }
    ui_banner() { printf '\n   catmi.xrayls\n\n' >&2; }
    ui_kv() { printf '   %s: %s\n' "$1" "$2" >&2; }
    ui_pad() { printf '%s' "$1"; }
fi

# 建节点之前问一次"服务器标识（节点名前缀）"（旗帜由 naming 负责）。
#
# ★ 原来整个调用包在 ( ) 子 shell 里, x_ask_server_name export 的
#   XRAY_SERVER_NAME 随之丢失 —— 于是每进一次「添加节点」或「节点管理」
#   就把同一个问题重新问一遍, 而它与当前要做的事毫无关系。
#   子脚本 (xray_run 起的那批) 各自认这个变量, 所以要在**父 shell** 取到值
#   并 export 出去: 本次会话只问一次, 子菜单也因为认得它而直接跳过。
_SRV_NAME_ASKED=""
_srv_ask_name() {
    [[ -n "$_SRV_NAME_ASKED" ]] && return 0
    _SRV_NAME_ASKED=1
    xray_cache_dir >/dev/null
    xray_ensure_lib >/dev/null 2>&1
    local lib="$_XRAY_CACHE/lib/naming.sh"
    [[ -f "$lib" ]] || return 0
    local v
    # 只捕获 stdout (取值); **不要重定向 stderr** —— 提示全部写在 stderr,
    # 压掉它就等于把这个提示整个藏起来了 (踩过一次: 加了 2>/dev/null 之后
    # 服务器标识再也没问过, 而它本该在本次会话第一次进入时问一次)。
    v=$( ( source "$lib" && x_ask_server_name; printf '%s' "${XRAY_SERVER_NAME:-}" ) ) || true
    [[ -n "$v" ]] && { XRAY_SERVER_NAME="$v"; export XRAY_SERVER_NAME; }
    return 0
}

# ---------------------------------------------------------------- 状态取值
# 菜单每操作一步都会重画, 这三个值必须**便宜**: 不走网络、不调 python。
xray_panel_version() {   # 内核版本（拿不到就空）
    local bin="${INSTALL_DIR:-/root/catmi/xray}/xrayls"
    [[ -x "$bin" ]] || bin="/root/catmi/xray/xrayls"
    [[ -x "$bin" ]] || return 0
    "$bin" version 2>/dev/null | head -1 | awk '{print $2}'
}
xray_node_count() {      # 节点数 (inbound 条数, 与节点管理里那张表同口径)
    local dir="${CONF_DIR:-/root/catmi/xray/conf}"
    [[ -d "$dir" ]] || { printf '0'; return 0; }
    # ★ 必须数 **inbound 条数**, 不能数文件数 —— 一个片段可以含多个 inbound,
    #   于是主菜单报 22、点进节点管理报 25, 同一台机器两个数对不上。
    #   实测 RN: 22 个片段 / 25 个 inbound。
    #
    # ★ 用 jq 一次吃全部文件而不是 nodes.py: nodes.py 要 0.30 秒, 每重画一次
    #   菜单付一次 —— 那正是 Mihomo 被嫌"卡"的同款毛病。jq 实测 0.01 秒。
    #   没有 jq 时退回数文件, 至少不会让菜单打不开。
    local n
    n=$(jq -s '[.[].inbounds[]?] | length' "$dir"/*.json 2>/dev/null)
    if [[ "$n" =~ ^[0-9]+$ ]]; then printf '%s' "$n"; return 0; fi
    grep -l '"inbounds"' "$dir"/*.json 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------- 子菜单
# 把 21 项平铺收成 5 组。用户的原话是"这一列太多了, 那两个内核都把功能分开"。
# 每组里的项仍是原来那些脚本, 只是不再堆在同一列里。
_route_menu_dispatch() {
    case "$1" in
        1) xray_run conf/outbound.sh ;;
        2) xray_run conf/split.sh ;;
        3) reverse_menu ;;
        *) return 1 ;;
    esac
}

route_menu() {
    local c
    while :; do
        _srv_clear; ui_title "路由与出站"
        ui_menu 1 "出站管理        自建/外部出站（direct / reject / socks5 / http）"
        ui_menu 2 "分流规则管理    按域名 / IP 决定走哪个出站"
        ui_menu 3 "反向代理管理    家宽落地与回连侧"
        ui_menu 0 "返回"
        echo >&2
        printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2
        read -r c || return 0
        case "$c" in
            0|"") return 0 ;;
            *) _route_menu_dispatch "$c" || ui_invalid "$c" ;;
        esac
        ui_pause
    done
}

kernel_menu() {
    local c
    while :; do
        _srv_clear; ui_title "安装 / 更新内核"
        local v; v=$(xray_panel_version)
        ui_kv "当前版本" "${v:-未安装}"
        echo >&2
        ui_menu 1 "安装 / 更新     自动检测版本：旧版升级，已是最新则跳过"
        ui_menu 2 "回退内核        列出版本备份并切换（更新失败时的退路）"
        ui_menu 3 "卸载内核        只删本工具装的那一份，不动系统其它 xray"
        ui_menu 0 "返回"
        echo >&2
        printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2
        read -r c || return 0
        case "$c" in
            0|"") return 0 ;;
            1) run_xray_install ;;
            2) run_xray_rollback ;;
            3) xray_run uninstall_xray.sh ;;
            *) ui_invalid "$c" ;;
        esac
        ui_pause
    done
}

service_menu() {
    local c
    while :; do
        _srv_clear; ui_title "服务与配置"
        ui_menu 1 "查询服务状态    systemctl status xrayls"
        ui_menu 2 "校验配置并重载  合并 → 字段 → 内核三道关，过了才重启"
        ui_menu 3 "客户端产物      查看内容 / 换指纹 / 换连接 IP"
        ui_menu 0 "返回"
        echo >&2
        printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2
        read -r c || return 0
        case "$c" in
            0|"") return 0 ;;
            1) systemctl status xrayls --no-pager ;;
            2) xray_run conf/verify.sh ;;
            3) client_menu ;;
            *) ui_invalid "$c" ;;
        esac
        ui_pause
    done
}

maint_menu() {
    local c
    while :; do
        _srv_clear; ui_title "自检与体检"
        ui_menu 1 "能力自检        通用能力校验（有内核时另跑协议链路）"
        ui_menu 2 "端口体检        占用 / 冲突 / 放行建议"
        ui_menu 3 "配置片段体检    逐个片段 JSON 合法性"
        ui_menu 0 "返回"
        echo >&2
        printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2
        read -r c || return 0
        case "$c" in
            0|"") return 0 ;;
            1) xray_run tools/check_libs.sh ;;
            2) xray_run tools/port-check.sh ;;
            3) _srv_check_fragments ;;
            *) ui_invalid "$c" ;;
        esac
        ui_pause
    done
}

# 片段体检：坏一个片段 xrayls 就起不来, 而这在面板上完全看不出来。
_srv_check_fragments() {
    local dir="${CONF_DIR:-/root/catmi/xray/conf}" f bad=0 n=0
    [[ -d "$dir" ]] || { warn "配置目录不存在: $dir"; return 1; }
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
        if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
            :
        else
            bad=$((bad + 1)); err "$(basename "$f") 不是合法 JSON"
        fi
    done
    (( bad == 0 )) && ok "全部 $n 个片段都是合法 JSON" || err "$bad / $n 个片段有问题"
    return $(( bad > 0 ))
}

show_menu() {
    local st st_txt xver nnodes
    st=$(systemctl is-active xrayls.service 2>/dev/null || echo inactive)
    if [[ "$st" == "active" ]]; then st_txt="${_GRN}● 启动${_RST}"; else st_txt="${_RED}○ 未启动（$st）${_RST}"; fi
    xver=$(xray_panel_version 2>/dev/null || true)
    nnodes=$(xray_node_count 2>/dev/null || echo 0)

    _srv_clear
    ui_banner "catmi.xrayls"
    ui_title "xrayls 管理脚本"
    ui_kv "服务状态" "$st_txt"
    ui_kv "内核版本" "${xver:-未知}"
    ui_kv "节点数量" "$nnodes"
    echo >&2

    ui_sec "节点"
    ui_menu 1 "添加节点        单协议 / 全协议一键生成 / 预置档位"
    ui_menu 2 "节点管理        列出 / 查看 / 改名 / 删除 / 改端口"
    ui_menu 3 "路由与出站      出站 / 分流规则 / 反向代理"
    echo >&2
    ui_sec "分享"
    # ★ 原来这里是两项: 4) 分享管理 与 5) 分享服务。
    #   用户的原话是"点进分享管理时更想看见分享服务的状态，这两个能不能放在一起"
    #   —— 服务状态已经提到 share_menu 顶部 (每轮刷新), 11) 保留为二级入口,
    #   所以主菜单的 5) 去掉, 后面的项整体前移一位 (保持编号连续)。
    ui_menu 4 "分享管理        生成 / 列表 / 启停 / 改次数 / 改有效期 / 服务状态"
    echo >&2
    ui_sec "站点与证书"
    ui_menu 5 "证书管理        申请 / 续期 / 同步 / 信任链体检"
    ui_menu 6 "Nginx 站点管理  列出 / 校验 / 摘除 / CDN 回源"
    echo >&2
    ui_sec "内核与服务"
    ui_menu 7 "安装 / 更新内核  含回退到旧版本、卸载"
    ui_menu 8 "服务与配置      查询状态 / 校验并重载 / 客户端产物"
    echo >&2
    ui_sec "维护"
    ui_menu 9 "DNS 管理        解析模式 / 加密 DNS / 防泄漏"
    ui_menu 10 "日志            实时 / 错误 / 清空 / 最近"
    ui_menu 11 "自检与体检      通用能力自检 / 端口体检"
    ui_menu 0 "退出"
    echo >&2
    ui_hint "回车 = 退出；每一项都能单独跑: bash conf/<名字>.sh"

    # 同理: 按键用尽时退出, 不要拿空 choice 反复重画。
    # ★ 这里**只能有一个提示** —— 原来上面 printf 一次、read -p 又一次,
    #   用户看到的是 `请选择: 请输入选项 [0-9]:`, 像坏了两遍。
    read -r -p "  ${_CYN}请选择 [0-11]${_RST}: " choice || exit 0

    case "${choice}" in
        0|"") _srv_clear; exit 0 ;;
        # ★ 这里**不再**调 _srv_ask_name。
        #   服务器标识 (节点名前缀) 只影响分享链接里给人看的名字, tag 一个字
        #   不改 —— 而「节点管理」做的查看/改名/删除, 三个动作一个都用不到它。
        #   原来两处都挂着 _srv_ask_name, 于是进节点管理先要答一遍与当前操作
        #   无关的问题, 而且提示里已经写着「当前: 🇺🇸 1」(值早就落盘), 看着
        #   更像是白问。Sing-box 把这个 hook 挂进每个协议的建节点流程,
        #   Mihomo 做成独立菜单项「补地区旗帜」, 两边都不在节点管理里拦人。
        #   现在改成: 节点管理 -> 6) 服务器标识, 想改随时去改。
        1) add_node_menu; share_refresh_hook ;;
        2) xray_run conf/node.sh; share_refresh_hook ;;
        3) route_menu ;;
        4) xray_run conf/share.sh ;;
        5) xray_run conf/cert.sh ;;
        6) xray_run conf/nginx_site.sh ;;
        7) kernel_menu ;;
        8) service_menu ;;
        9) xray_run conf/dns.sh ;;
        10) xray_run conf/logs.sh ;;
        11) maint_menu ;;
        *) echo -e "${RED}无效的选项 ${choice}${PLAIN}" ;;
    esac

    # 回车返回。**EOF 必须当作退出**。
    #
    # read 在 stdin 用尽时返回非 0, 而这一行原来只是 `read ... && echo`,
    # 后面无条件回到 while 顶部 —— 于是脚本无限重画菜单, 刷屏到天荒地老,
    # 自动化里表现就是"卡死到超时"。
    # 触发路径很常见: `bash xray-panel.sh < /dev/null`、管道喂完按键、
    # 从别的脚本里调用。交互时看不出来, 一进自动化就挂。
    echo
    read -r -p "按回车键返回主菜单..." _ || exit 0
    echo
}

# 反向代理管理子菜单（reverse）
reverse_menu() {
    local c
    while :; do
        _srv_clear
        ui_title "反向代理管理"
        ui_hint "把家宽/内网的入口侧与回连侧接起来，两个脚本各跑在对应那一端"
        echo >&2
        ui_menu 1 "服务端管理    xrayserver-reverse（跑在家宽 / 入口侧）"
        ui_menu 2 "客户端管理    xrayclient-reverse（跑在回连侧）"
        ui_menu 0 "返回"
        echo >&2
        printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2
        read -r c || return 0
        case "$c" in
            1) xray_run conf/fd/xrayserver-reverse.sh ;;
            2) xray_run conf/fd/xrayclient-reverse.sh ;;
            0|"") return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        ui_pause
    done
}

load_env() {
    if [ -f "$ENV_FILE" ]; then
        # 检查 env 文件格式是否正确
        if grep -qEv '^[A-Za-z_][A-Za-z0-9_]*=".*"$' "$ENV_FILE"; then
            echo "⚠ env 文件格式异常：$ENV_FILE"
            return 1
        fi

        # 安全加载
        set -a
        source "$ENV_FILE"
        set +a
        echo "已加载 env：$ENV_FILE"
    else
        echo "env 文件不存在：$ENV_FILE"
    fi
}
# 统一安装/更新入口：bin/xray_install.sh
# 幂等：已安装且为最新版本时跳过下载；旧版本自动升级；并重建基础配置、验证并重启 xrayls
XRAY_INSTALL_URL="${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/bin/xray_install.sh"

# 回退内核 —— 转给 bin/xray_install.sh 的 rollback 模式。
# 单独给一个菜单入口的理由: 更新失败时人往往已经连不上服务,
# 这时"回退"必须是**一眼能找到**的一项, 而不是自己记住一条命令。
run_xray_rollback() {
  local py
  py=$(xray_fetch bin/xray_install.sh) || {
    echo -e "${RED}取不到安装脚本（镜像链全不通）${PLAIN}"; return 1; }
  bash "$py" list-backups
  bash "$py" rollback
  return $?
}

run_xray_install() {
    xray_run bin/xray_install.sh || {
        echo -e "${RED}xrayls 安装/更新失败，请查看上方错误信息${PLAIN}"
        return 1
    }
}
# 客户端产物 —— 「客户端最终拿到的东西」的总入口。
#
# ★ 原来这里只有一个 show_xray_configs(), 把 out/ 下的 txt / yaml **直接 cat
#   出来**: 几十屏 base64, 没有文件名以外的任何结构, 更没有任何"改"的动作。
#   用户看完既不知道哪些节点没被收进去, 也不知道指纹 / 对外地址是哪来的,
#   想改只能删了重建 (端口、REALITY 密钥、分享历史全丢)。
#
#   现在这里给四个动作: 看内容 / 换指纹 / 换连接 IP / 刷新分享内容。
#   换指纹与换地址都只改 share_meta 里对应的字段 (nodes.py 的链接就是从那儿
#   取 fp= 与 host 的), 不碰任何协议脚本, 也不动 Xray 片段本身。
client_menu() {
    local c
    while :; do
        _srv_clear; ui_title "客户端产物"
        _client_status
        echo >&2
        ui_menu 1 "查看产物内容    out/ 下的订阅文件 (TXT / YAML)"
        ui_menu 2 "更换 uTLS 指纹  客户端握手伪装，10 种可选"
        ui_menu 3 "更换连接 IP     IPv4 / IPv6 切换，CDN 域名不动"
        ui_menu 4 "刷新分享内容    换完指纹/地址后把已发链接更新到最新"
        ui_menu 0 "返回"
        echo >&2
        printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2
        read -r c || return 0
        case "$c" in
            1) show_xray_configs ;;
            2) xray_run conf/share.sh change-fp ;;
            3) xray_run conf/share.sh switch-family-menu ;;
            4) xray_run conf/share.sh refresh; ui_pause ;;
            0|"") return 0 ;;
            *) ui_invalid "$c" ;;
        esac
        ui_pause
    done
}

# 客户端产物顶部状态 —— 三个值都必须是**便宜**的 (菜单每步都重画):
# 节点数复用 xray_node_count (jq), 产物文件数是 glob, 对外地址走 share_meta。
_client_status() {
    local nn nfile dir="${OUT_DIR:-/root/catmi/xray/out}"
    nn=$(xray_node_count 2>/dev/null || echo 0)
    nfile=0
    [[ -d "$dir" ]] && nfile=$(find "$dir" -maxdepth 1 \( -name '*.txt' -o -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | wc -l)
    ui_kv "节点数量" "$nn"
    ui_kv "产物文件" "$nfile 个"
    _client_addr_line
}

# 当前客户端会连的地址 —— 直接从 share_meta 读, 与链接里那个 host 同源。
# ★ 不问外部 ipify 服务: 那是**出站出口**, 本机走 WARP/代理时会答出 WARP 的 IP,
#   而客户端连的是入站地址 —— 面板显示的必须是产物里真实会写的那个值。
_client_addr_line() {
    xray_cache_dir >/dev/null
    xray_ensure_lib >/dev/null 2>&1
    local lib="$_XRAY_CACHE/lib"
    [[ -f "$lib/addr.sh" ]] || { ui_kv "对外地址" "读取失败"; return 0; }
    # ★ 一个子shell 出两个值 —— 分两次 source 是白付两遍解析。
    #   addr.sh 里只有 ip 命令, 没有网络调用, 所以静默 stderr 是安全的。
    local v4 v6
    v4=$( ( source "$lib/addr.sh" 2>/dev/null; x_addr4_real 2>/dev/null ) ) || v4=""
    v6=$( ( source "$lib/addr.sh" 2>/dev/null; x_addr6_real 2>/dev/null ) ) || v6=""
    local s=""
    [[ -n "$v4" ]] && s="$v4"
    [[ -n "$v6" ]] && s="${s:+$s  }$v6"
    ui_kv "本机地址" "${s:-无可用公网地址}"
    if [[ -n "$v4" && -n "$v6" ]]; then
        ui_hint "两种地址族都可用 —— 用 3) 切产物用哪一族"
    fi
}

# 看产物内容。
#
# ★ 一律写 stderr: stdout 是数据通道 (分享链接/订阅内容都从那儿出)。
#   这里原来 echo -e "${GREEN}…${PLAIN}" 全走 stdout —— 标题混进数据流,
#   下游任何解析都会把 "===== TXT 配置文件 =====" 当成内容的一部分。
show_xray_configs() {
    local out_dir="/root/catmi/xray/out"

    if [[ ! -d "$out_dir" ]]; then
        printf '  %s目录不存在：%s%s\n' "$RED" "$out_dir" "$PLAIN" >&2
        return
    fi

    _show_out_files "$out_dir" "TXT 配置文件" "$GREEN" txt
    _show_out_files "$out_dir" "YAML 配置文件" "$GREEN" yaml yml
}

_show_out_files() { # <目录> <标题> <颜色> <扩展名...>
    local dir="$1" title="$2" color="$3"; shift 3
    printf '\n%s===== %s =====%s\n' "$color" "$title" "$PLAIN" >&2
    local ext f found=0
    for ext in "$@"; do
        for f in "$dir"/*."$ext"; do
            [[ -f "$f" ]] || continue
            found=1
            printf '\n%s===== %s =====%s\n' "$color" "$f" "$PLAIN" >&2
            cat "$f" >&2          # ★ 内容也走 stderr
        done
    done
    (( found )) || printf '  无%s文件\n' "$title" >&2
    return 0
}

add_node_menu() {
    local c
    while :; do
        _srv_clear
        ui_title "添加节点"
        ui_sec "单协议"
        ui_menu 1 "Tunnel"
        ui_menu 2 "Hysteria2"
        ui_menu 3 "SOCKS5（无加密，接其它内核/本机代理用）"
        ui_menu 4 "HTTP（无加密，同上）"
        ui_menu 5 "VLESS-ECN（tcp 传输 + ML-KEM-768）"
        ui_menu 6 "VLESS-xHTTP（TLS，走 CDN 首选）"
        ui_menu 7 "Reality（vision + ML-KEM-768，最高配置）"
        ui_menu 8 "Shadowsocks-2022（aes-256-gcm，最高配置）"
        ui_menu 9 "Trojan（REALITY 安全层，最高配置）"
        echo >&2
        ui_sec "Argo 隧道"
        ui_menu 10 "固定 Argo（域名固定，推荐）"
        ui_menu 11 "临时 Argo（每次随机域名）"
        echo >&2
        ui_sec "批量与预置"
        ui_menu 12 "全协议一键生成    自动分配端口，统一校验，只重载一次"
        ui_menu 13 "预置档位建节点    25 个预置（协议 × TLS × 传输）任选"
        ui_menu 14 "预置批量生成      一次生成多个（支持 vless:2 trojan:3）"
        ui_menu 0 "返回主菜单"
        echo >&2
        printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2
        read -r nchoice || return 0
        case "${nchoice}" in

        0) return ;;

        1)
            xray_run conf/tunnel.sh
            systemctl restart xrayls.service
            ;;

        2)
            xray_run conf/hysteria2.sh
            systemctl restart xrayls.service
            ;;

        3)
            xray_run conf/sock5.sh
            systemctl restart xrayls.service
            ;;

        4)
            # ★ 原来这里跑的是 conf/vlessecn.sh —— 与 3) 撞车 (两个菜单项建出
            #   同一种节点), 而标签写着「HTTP」。用户选 HTTP 拿到 VLESS-ECN,
            #   面板全程无任何提示。3) 与 4) 是当时加 SOCKS5 时整体错位了一格。
            xray_run conf/http.sh
            systemctl restart xrayls.service
            ;;

        5)
            xray_run conf/vlessecn.sh
            systemctl restart xrayls.service
            ;;

        6)
            xray_run conf/vlessxhttpecn.sh
            systemctl restart xrayls.service
            ;;

        7)
            xray_run conf/Reality.sh
            systemctl restart xrayls.service
            ;;

        8)
            xray_run conf/Shadowsocks.sh
            systemctl restart xrayls.service
            ;;

        9)
            xray_run conf/Trojan.sh
            systemctl restart xrayls.service
            ;;

        10)
            xray_run conf/GDargo.sh
            systemctl restart xrayls.service
            ;;

        11)
            xray_run conf/lsargo.sh
            systemctl restart xrayls.service
            ;;

        12)
            # Batch Generator 收尾自带统一校验+一次重启, 这里不再 restart
            xray_run conf/batch.sh
            ;;

        13) xray_run conf/mknode.sh ;;
        14) xray_run tools/preset_batch.sh --help ;;
        *)
            ui_invalid "$nchoice"
            ;;
        esac
        ui_pause
    done
}

# 主程序循环。show_menu 内部在 EOF 时 exit, 所以不会无限刷屏。
while true; do
    show_menu
done
