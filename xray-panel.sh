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
    deploy.py dns_edit.py nginx_apply.py naming.py node_build.py nodes.py
    share_meta.py share_payload.py token_store.py
    interop.py native.py
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
_srv_ask_name() {
    xray_ensure_lib >/dev/null 2>&1
    local lib="$_XRAY_CACHE/lib/naming.sh"
    [[ -f "$lib" ]] || return 0
    # shellcheck disable=SC1090
    ( source "$lib" && x_ask_server_name ) || true
}

# ---------------------------------------------------------------- 状态取值
# 菜单每操作一步都会重画, 这三个值必须**便宜**: 不走网络、不调 python。
xray_panel_version() {   # 内核版本（拿不到就空）
    local bin="${INSTALL_DIR:-/root/catmi/xray}/xrayls"
    [[ -x "$bin" ]] || bin="/root/catmi/xray/xrayls"
    [[ -x "$bin" ]] || return 0
    "$bin" version 2>/dev/null | head -1 | awk '{print $2}'
}
xray_node_count() {      # 节点片段数（含 inbounds 的 JSON）
    local dir="${CONF_DIR:-/root/catmi/xray/conf}"
    [[ -d "$dir" ]] || { printf '0'; return 0; }
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
        ui_menu 3 "查看客户端配置  当前生效的入站、端口与分享内容"
        ui_menu 0 "返回"
        echo >&2
        printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2
        read -r c || return 0
        case "$c" in
            0|"") return 0 ;;
            1) systemctl status xrayls --no-pager ;;
            2) xray_run conf/verify.sh ;;
            3) show_xray_configs ;;
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
    ui_menu 4 "分享管理        生成 / 列表 / 启停 / 改次数 / 改有效期"
    ui_menu 5 "分享服务        公共基础服务（安装 / 升级 / 状态）"
    echo >&2
    ui_sec "站点与证书"
    ui_menu 6 "证书管理        申请 / 续期 / 同步 / 信任链体检"
    ui_menu 7 "Nginx 站点管理  列出 / 校验 / 摘除 / CDN 回源"
    echo >&2
    ui_sec "内核与服务"
    ui_menu 8 "安装 / 更新内核  含回退到旧版本、卸载"
    ui_menu 9 "服务与配置      查询状态 / 校验并重载 / 查看客户端配置"
    echo >&2
    ui_sec "维护"
    ui_menu 10 "DNS 管理        解析模式 / 加密 DNS / 防泄漏"
    ui_menu 11 "日志            实时 / 错误 / 清空 / 最近"
    ui_menu 12 "自检与体检      通用能力自检 / 端口体检"
    ui_menu 0 "退出"
    echo >&2
    ui_hint "回车 = 退出；每一项都能单独跑: bash conf/<名字>.sh"
    printf '  %s请选择%s: ' "$_CYN" "$_RST" >&2

    # 同理: 按键用尽时退出, 不要拿空 choice 反复重画
    read -r -p "请输入选项 [0-9]: " choice || exit 0

    case "${choice}" in
        0|"") _srv_clear; exit 0 ;;
        1) _srv_ask_name; add_node_menu; share_refresh_hook ;;
        2) _srv_ask_name; xray_run conf/node.sh; share_refresh_hook ;;
        3) route_menu ;;
        4) xray_run conf/share.sh ;;
        5) xray_run conf/share_service.sh menu ;;
        6) xray_run conf/cert.sh ;;
        7) xray_run conf/nginx_site.sh ;;
        8) kernel_menu ;;
        9) service_menu ;;
        10) xray_run conf/dns.sh ;;
        11) xray_run conf/logs.sh ;;
        12) maint_menu ;;
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
show_xray_configs() {
    local out_dir="/root/catmi/xray/out"

    if [[ ! -d "$out_dir" ]]; then
        echo -e "${RED}目录不存在：$out_dir${PLAIN}"
        return
    fi

    echo -e "${GREEN}===== TXT 配置文件 =====${PLAIN}"
    for f in "$out_dir"/*.txt; do
        [[ -e "$f" ]] || { echo "无 TXT 文件"; break; }
        echo -e "\n===== $f ====="
        cat "$f"
    done

    echo -e "\n${GREEN}===== YAML 配置文件 =====${PLAIN}"
    for f in "$out_dir"/*.yaml "$out_dir"/*.yml; do
        [[ -e "$f" ]] || { echo "无 YAML 文件"; break; }
        echo -e "\n===== $f ====="
        cat "$f"
    done
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
            xray_run conf/vlessecn.sh
            systemctl restart xrayls.service
            ;;

        5)
            xray_run conf/http.sh
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
