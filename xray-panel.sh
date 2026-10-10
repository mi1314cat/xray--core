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

show_menu() {
    # 获取服务状态
    xrayls_server_status=$(systemctl is-active xrayls.service 2>/dev/null || echo "inactive")

    # 生成状态文本
    if [[ "$xrayls_server_status" == "active" ]]; then
        xrayls_server_status_text="${GREEN}启动${PLAIN}"
    else
        xrayls_server_status_text="${RED}未启动${PLAIN}"
    fi

    # 使用单引号和here-doc格式避免转义问题
    _srv_clear
    cat << "EOF"

                       |\__/,|   (\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.xrayls
       -----------------------------------------

EOF
    echo -e "
${GREEN}xrayls 管理脚本${PLAIN}
----------------------
${GREEN}1.${PLAIN} 安装/更新 xray（自动检测版本：旧版升级、最新则跳过）
${GREEN}1b.${PLAIN} 回退内核（列出版本备份并切换）
${GREEN}2.${PLAIN} 卸载 xray
${GREEN}3.${PLAIN} 查看客户端配置
${GREEN}4.${PLAIN} 查询服务状态
${GREEN}5.${PLAIN} 添加节点
${GREEN}6.${PLAIN} 校验配置/重启服务
${GREEN}7.${PLAIN} 出站管理（outbound）
${GREEN}8.${PLAIN} 分流规则管理（split）
${GREEN}9.${PLAIN} 反向代理管理（reverse）
${GREEN}10.${PLAIN} 分享管理（share）
${GREEN}11.${PLAIN} 节点管理（node）
${GREEN}12.${PLAIN} 自检（校验通用能力）
${GREEN}13.${PLAIN} DNS 管理（dns）
${GREEN}14.${PLAIN} 日志（logs）
${GREEN}15.${PLAIN} 预置建节点（mknode）
${GREEN}16.${PLAIN} 预置批量生成（preset_batch）
${GREEN}17.${PLAIN} 证书管理（cert）
${GREEN}18.${PLAIN} Nginx 站点管理（nginx_site）
${GREEN}19.${PLAIN} 分享服务（share_service）
    ${GREEN}20.${PLAIN} 端口体检（port_check）
${GREEN}0.${PLAIN} 退出脚本
----------------------
xrayls 服务状态: ${xrayls_server_status_text}
----------------------"

    # 同理: 按键用尽时退出, 不要拿空 choice 反复重画
    read -r -p "请输入选项 [0-9]: " choice || exit 0

    case "${choice}" in
        0) _srv_clear; exit 0 ;;
        1) run_xray_install ;;
        1b|1B) run_xray_rollback ;;
        2) xray_run uninstall_xray.sh ;;
        3) show_xray_configs ;;
        4) systemctl status xrayls --no-pager ;;
        5) _xray_ask_server_name; add_node_menu; share_refresh_hook ;;
        6) xray_run conf/verify.sh ;;
        7) xray_run conf/outbound.sh ;;
        8) xray_run conf/split.sh ;;
        9) reverse_menu ;;
        10) xray_run conf/share.sh ;;
        11) _xray_ask_server_name; xray_run conf/node.sh; share_refresh_hook ;;
        12) xray_run tools/check_libs.sh ;;
        13) xray_run conf/dns.sh ;;
        14) xray_run conf/logs.sh ;;
        15) _xray_ask_server_name; xray_run conf/mknode.sh; share_refresh_hook ;;
        16) xray_run tools/preset_batch.sh --help; share_refresh_hook ;;
        17) xray_run conf/cert.sh ;;
        18) xray_run conf/nginx_site.sh ;;
        19) xray_run conf/share_service.sh menu ;;
        20) xray_run tools/port-check.sh ;;

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
    while true; do
        _srv_clear
        echo -e "
${GREEN}反向代理管理 (reverse)${PLAIN}
----------------------
${GREEN}1.${PLAIN} 服务端管理（xrayserver-reverse，运行在家/入口侧）
${GREEN}2.${PLAIN} 客户端管理（xrayclient-reverse，运行在RN/回连侧）
${GREEN}0.${PLAIN} 返回主菜单
----------------------"
        # EOF 当退出, 否则按键用尽后无限重画子菜单
        read -r -p "请输入选项 [0-2]: " rc || return
        case "${rc}" in
            1) xray_run conf/fd/xrayserver-reverse.sh ;;
            2) xray_run conf/fd/xrayclient-reverse.sh ;;
            0) return ;;
            *) echo -e "${RED}无效的选项 ${rc}${PLAIN}" ;;
        esac
        echo
        read -r -p "按回车键返回子菜单..." _ || return
        echo
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

# 建节点之前问一次"服务器标识（节点名前缀）"。
#
# ★ 为什么挂在这里: 菜单 5 / 11 / 15 是三个不同的建节点入口, 各自是一堆
#   独立脚本。在每个协议脚本里问一遍要改十几个文件, 而且用户会被反复问;
#   挂在菜单入口上就是"每台机器问一次", 答案落盘到 share-state/server-name,
#   之后所有节点(含批量)都用它。
#
#   对照 sing-box-core: 它的 sb_ask_server_name_hook 挂在 ask_server_addr
#   后面, 同样是一次接入全覆盖。
_xray_ask_server_name() {
    xray_ensure_lib >/dev/null 2>&1
    local lib="$_XRAY_CACHE/lib/naming.sh"
    [[ -f "$lib" ]] || return 0
    # shellcheck disable=SC1090
    ( source "$lib" && x_ask_server_name ) || true
}

add_node_menu() {
    _srv_clear
    echo -e "
${GREEN}添加节点${PLAIN}
----------------------
${GREEN}1.${PLAIN} 添加 Tunnel 节点
${GREEN}2.${PLAIN} 添加 Hysteria2 节点
${GREEN}3.${PLAIN} 添加 SOCKS5 节点（无加密）
${GREEN}4.${PLAIN} 添加 VLESS-ECN 节点（tcp传输）
${GREEN}5.${PLAIN} 添加 HTTP 节点（无加密）
${GREEN}6.${PLAIN} 添加 VLESS-xHTTP TLS 节点
${GREEN}7.${PLAIN} 添加 Reality 节点（vision + ML-KEM-768，最高配置）
${GREEN}8.${PLAIN} 添加 Shadowsocks-2022 节点（aes-256-gcm，最高配置）
${GREEN}9.${PLAIN} 添加 Trojan 节点（Reality 安全层，最高配置）

---------------------- Argo 节点 ----------------------
${GREEN}10.${PLAIN} 添加 固定 Argo 节点
${GREEN}11.${PLAIN} 添加 临时 Argo 节点

------------- Batch Generator -------------
${GREEN}12.${PLAIN} 全协议一键生成（自动端口，统一校验，仅 reload 一次）

${GREEN}0.${PLAIN} 返回主菜单
----------------------"

    read -r -p "请输入选项 [0-12]: " nchoice || return

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

        *)
            echo -e "${RED}无效的选项${PLAIN}"
            ;;
    esac

    return
}

# 主程序循环。show_menu 内部在 EOF 时 exit, 所以不会无限刷屏。
while true; do
    show_menu
done
