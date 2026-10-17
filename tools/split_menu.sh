#!/usr/bin/env bash
# split_menu.sh — xHTTP 上下行分离 交互菜单
#
# 为什么单独一个脚本, 不塞进 preset_batch.sh:
#   preset_batch.sh 是**批量**入口 (参数驱动, 给脚本和 cron 用), 里面塞
#   交互问答会让它没法被非交互地调用。而这是用户日常手点的入口, 需要的
#   恰恰是问答: 域名、下行域名、直连地址、REALITY 密钥对, 少一个都建不出。
#
# ★ 三个组合 (用户定的):
#     1) 上行 CDN + 下行 CDN       两段都走橙云, ECH 默认开, 藏得最深
#     2) 上行 CDN + 下行 REALITY   上行藏进 CDN, 下行直连 + REALITY 握手
#     3) 上行 REALITY + 下行 CDN   上行不经过第三方
#
# ★ 只有一个域名**不是**缺配置:
#   上下行照样分开 (独立 GET / 独立 POST), 只是共用一个入口。两个域名是
#   **加出来的能力**。所以下行域名默认留空 = 复用上行那个。
set -u

_er() { printf "\e[31m[Error]\e[0m %s\n" "$*" >&2; }
_wn() { printf "\e[33m[Warn]\e[0m %s\n" "$*" >&2; }
_in() { printf "\e[36m[Info]\e[0m %s\n" "$*" >&2; }
_ok() { printf "\e[32m[OK]\e[0m %s\n" "$*" >&2; }
_cy() { printf "\e[36m%s\e[0m\n" "$*" >&2; }
_bo() { printf "\e[1m%s\e[0m\n" "$*" >&2; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_repo="$(cd "$_here/.." 2>/dev/null && pwd)"

# ---------------------------------------------------------------- 依赖定位
#
# ★ 这个脚本会被两种方式启动, 两者看到的目录结构**完全不同**:
#
#   仓库检出   bash tools/split_menu.sh
#              → $_here = <repo>/tools, preset.sh 在 <repo>/conf/lib/,
#                兄弟脚本在 <repo>/tools/
#   面板运行   xray_run 把脚本**扁平化**成 $CACHE/tools_split_menu.sh
#              → $_here = $CACHE。里面只有 lib/ (xray_ensure_lib 铺的),
#                **既没有 conf/ 也没有 preset_batch.sh**
#
#   原来只按 "$_here/.." 找 preset.sh, 于是第二种情况下直接
#   「找不到 conf/lib/preset.sh (/tmp/conf/lib/preset.sh)」退出 ——
#   而面板正是用户**唯一**的安装方式。也就是说: 菜单 15 (上下行分离)
#   对用户全死, 只在 git 检出里活着。沙箱实测复现过。
#
#   现在按 仓库 → 缓存 → 现拉 三级找, 与 conf/batch.sh 的
#   resolve_scripts_dir / conf/mknode.sh 的 _mk_lib 是同一条思路,
#   不另造机制。
_RAW_BASE="${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}"
_CACHE="$(mktemp -d /tmp/.x-split.XXXXXX 2>/dev/null)" || _CACHE=""
_cleanup() { [[ -n "$_CACHE" ]] && rm -rf "$_CACHE"; }
trap _cleanup EXIT

_fetch() { # <仓库相对路径> <目标文件>
    local rel="$1" dest="$2"
    curl -fsSL --max-time 30 "$_RAW_BASE/$rel" -o "$dest" 2>/dev/null \
        && [[ -s "$dest" ]] && return 0
    rm -f "$dest"; return 1
}

# 找 <仓库相对路径>: 仓库检出 → 扁平化缓存 → 现拉 (拉到 $_CACHE 后再找一次)
_resolve() { # <仓库相对路径>
    # ★ local 的多个赋值是**先全部展开再赋值** —— 写成
    #   `local rel="$1" base="$(basename "$rel")"` 时 base 读到的是外层
    #   (未定义的) rel, set -u 下当场 unbound variable。
    #   这个坑项目里已经踩过一次 (交接文档 5.4), 一行一个 local 才对。
    local rel="$1"
    local base
    base="$(basename "$rel")"
    local c d
    for c in "$_repo/$rel" "$_here/$rel" "$_here/$base" "$_here/lib/$base"; do
        [[ -r "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    [[ -n "$_CACHE" ]] || return 1
    d="$_CACHE/$base"
    _fetch "$rel" "$d" || return 1
    printf '%s' "$d"
}

_psh="$(_resolve conf/lib/preset.sh)" || {
    _er "取不到 conf/lib/preset.sh —— 仓库检出里没有, 镜像链也下不来"
    _in "  试过的位置: $_repo/conf/lib/ 与 $_here/lib/"
    exit 1
}
# shellcheck source=/dev/null
source "$_psh"

if ! declare -F x_split_modes >/dev/null 2>&1; then
    _er "这个版本的 preset.sh 里没有分离模式表, 请更新后再试"
    exit 1
fi

# preset_batch.sh 及其同目录依赖 cdn_auto.sh —— 一并解析好, 否则面板运行下
# 会出现"菜单能进、一按生成就说找不到 preset_batch.sh"。
# ★ 两个文件必须落在**同一个目录**: preset_batch.sh 是按
#   "$(dirname "$BASH_SOURCE")/cdn_auto.sh" 找它的。
_PBATCH="$(_resolve tools/preset_batch.sh)" || {
    _er "取不到 tools/preset_batch.sh"
    exit 1
}
# preset_batch.sh 内部的 _lib() 兜底会按 $_XD/conf/lib/ 找, 扁平化时找不到
# 就去 curl —— 那条路要 XRAY_RAW 指向一个能通的源, 面板已经把它传下来了。
export XRAY_RAW="$_RAW_BASE"
if [[ -n "$_CACHE" && "$(dirname "$_PBATCH")" != "$_CACHE" ]]; then
    cp -f "$_PBATCH" "$_CACHE/preset_batch.sh" 2>/dev/null && _PBATCH="$_CACHE/preset_batch.sh"
fi
if [[ -n "$_CACHE" && ! -r "$_CACHE/cdn_auto.sh" ]]; then
    _fetch tools/cdn_auto.sh "$_CACHE/cdn_auto.sh" || true
fi

echo >&2
_bo "════ xHTTP 上下行分离 ════"
_cy "  上下行真正分开: 下行走独立 GET、上行走独立 POST —— 不是一条连接上双工"
echo >&2
_in "  1) 上行 CDN + 下行 CDN        两段都走 Cloudflare 橙云, ECH 默认开, 藏得最深"
_in "  4) 上行 REALITY + 下行 REALITY 两段都直连 + REALITY, 抗 DPI 最强, 不依赖 CDN"
_wn "  ⚠ 2) 上行 CDN + 下行 REALITY 与 3) 上行 REALITY + 下行 CDN 连不上, 已不提供。"
_wn "     原因在内核结构: xHTTP 的会话表挂在**每个 inbound 自己**上"
_wn "     (splithttp/hub.go 的 sessions), 下行的 GET 必须落到同一个 inbound 才拿得到"
_wn "     上行的 uploadQueue; 而一个 inbound 只有一个安全层 —— 上行是 CDN 回源时"
_wn "     它已经是明文, 同一个端口没法再做 REALITY 握手; 换个端口下行只会连到"
_wn "     一个空会话 (下行 000)。所以上下行必须同一个安全层。"
echo >&2
_wn "  只有一个域名也可以 —— 上下行仍然分开, 只是共用同一个入口。"
_wn "  两个域名是**加出来的能力**, 不是前提。"
echo >&2

printf '  选哪个组合 [1-4, 回车=1, 0=退出]: '
read -r pick || { echo >&2; exit 0; }
pick="${pick:-1}"
case "$pick" in
    0|q|Q) exit 0 ;;
    1) SPLIT=cdn-cdn ;;
    4) SPLIT=reality-reality ;;
    2|3)
        if [ "$pick" = 2 ]; then _sp_pick=cdn-reality; else _sp_pick=reality-cdn; fi
        _er "这个组合连不上, 不生成 —— 不是配置问题, 是内核结构限制"
        _er "  $(x_split_why "$_sp_pick")"
        _in "  xHTTP 的会话表是 per-inbound 的, 而一个 inbound 只能有一个安全层;"
        _in "  上下行跨安全层时, 下行要么握不上手, 要么落进一个空会话 (下行 000),"
        _in "  上层看起来「连上了」, 实际一个字节都收不到。"
        _in "  要上下行分离, 请用 1) CDN+CDN 或 4) REALITY+REALITY。"
        exit 1 ;;
    *) _er "看不懂 (只有 1 和 4 能选)"; exit 1 ;;
    *) _er "看不懂"; exit 1 ;;
esac

# ---------------------------------------------------------------- 域名
# ★ 上行的域名/地址在两个组合里是两件事, 问法必须跟着变:
#   · 上行走 CDN → 是**节点域名** (Cloudflare 橙云指向它, TLS 要证书);
#   · 上行是 REALITY → 不经 CDN、也不需要证书, 它只是**握手伪装用的 SNI**
#     (客户端发这个 SNI, 服务端拿它当目标去借证书)。问成"Cloudflare 橙云
#     指向这里"会把只做 REALITY 的人挡在门外, 他既没有 CDN 也不想配证书。
if [ "$(x_split_ul_sec "$SPLIT")" = reality ]; then
    _up_hint="上行 REALITY 伪装域名 (不必解析到本机, 只是握手时对外声称的 SNI)"
else
    _up_hint="上行域名 (Cloudflare 橙云指向这里, TLS 要证书)"
fi
read -rp "  $_up_hint: " UP_DOM
UP_DOM="${UP_DOM// /}"
if [[ -z "$UP_DOM" ]]; then
    _er "上行域名是必填的 —— 没有它就没有证书, CDN 也无从谈起"
    exit 1
fi

if [ "$(x_split_dl_cdn "$SPLIT")" = yes ]; then
    echo >&2
    _in "下行也走 CDN。回车 = 与上行**同一个域名** (上下行仍分开, 共用入口)"
    read -rp "  下行域名: " DL_DOM
else
    echo >&2
    _in "下行是**直连**的 (不过 Cloudflare)"
    _in "  填服务器 IP 或一个直连域名。回车 = 与上行同一个入口。"
    read -rp "  下行直连地址: " DL_ADDR
    DL_DOM="${DL_ADDR// /}"
fi
DL_DOM="${DL_DOM:-$UP_DOM}"

# ---------------------------------------------------------------- REALITY 密钥
if [ "$(x_split_dl_sec "$SPLIT")" = reality ] || [ "$(x_split_ul_sec "$SPLIT")" = reality ]; then
    echo >&2
    # 密钥对: 上行 REALITY 要私钥+公钥; 只有下行 REALITY 时只要公钥 (客户端侧)
    _in "这个组合要用 REALITY 密钥对。"
    printf '  REALITY 私钥 (留空=自动生成): '
    read -r RK
    RK="${RK// /}"
    if [[ -z "$RK" ]]; then
        if ! command -v xray >/dev/null 2>&1; then
            _er "没装 xray, 不能自动生成密钥对。装好 xray 或自己提供。"
            exit 1
        fi
        _gen=$(xray x25519 2>/dev/null) || {
            _er "xray x25519 执行失败"; exit 1; }
        RK=$(printf '%s\n' "$_gen"  | awk -F': ' '/PrivateKey/{print $2}')
        RPUB=$(printf '%s\n' "$_gen" | awk -F': ' '/Password|PublicKey/{print $2}')
        _in "  已生成: 私钥 ${RK:0:12}… / 公钥 ${RPUB:0:12}…"
    else
        printf '  REALITY 公钥: '
        read -r RPUB
        RPUB="${RPUB// /}"
    fi
    if [[ -z "$RK" || -z "$RPUB" ]]; then
        _er "REALITY 需要成对的私钥+公钥, 缺一个就建不出"
        exit 1
    fi
    # 私钥只在上行是 REALITY 时需要 —— 下行 REALITY 是服务端扮演客户端, 只要公钥。
    # 直接 export, 别用 `env -e K=V`: env 没有 -e 这个选项 (只有 -i/-u),
    # 实测直接报 "env: invalid option -- 'e'" 然后什么都没建。
    export X_BATCH_REALITY_PUBLIC_KEY="$RPUB"
    [ "$(x_split_ul_sec "$SPLIT")" = reality ] && export X_BATCH_REALITY_PRIVATE_KEY="$RK"
fi

echo >&2
_bo "════ $(x_split_title "$SPLIT") ════"
_in "  $(x_split_desc "$SPLIT")"
_in "  上行: $(x_split_ul_sec "$SPLIT") → $UP_DOM"
_in "  下行: $(x_split_dl_sec "$SPLIT") → $DL_DOM"
[ "$(x_split_ech "$SPLIT")" = yes ] && _in "  ECH: 开 (默认)"
if [ "$(x_split_dl_cdn "$SPLIT")" = yes ]; then
    _in "  nginx: 会给上行/下行域名各挂一段; 端口与节点同一个 (会话表 per-inbound)"
else
    _in "  nginx: 下行直连, **不挂站点**; 端口会对公网开放 (客户端要直连)"
fi

# ★ reality-cdn 已知不通, 生成之前就说清楚。
#   上行 REALITY 的 inbound 只认 REALITY 握手, 而下行要走 Cloudflare/nginx,
#   那是**普通 TLS** —— 两条要求互相冲突, nginx 代理过去对不上, 服务端
#   一行 inbound 都不会有。实测记录见 docs/HANDOVER-known-issues.md 第二节。
#   在这里提示, 好过让人建完、分享出去、客户端导入了才发现连不上。
if [ "$SPLIT" = reality-cdn ]; then
    echo >&2
    _wn "  ⚠ 这个组合实测不通, 请先读完再决定:"
    _in "    · 上行 REALITY + 下行走 CDN 两条要求互相冲突"
    _in "    · 上下行必须同一个 inbound 同端口 (会话表 per-inbound),"
    _in "      而那个 inbound 是 REALITY 的, nginx 用普通 TLS 代理过去对不上"
    _in "    · 想用上下行分离, 现在可靠的是 cdn-cdn 与 cdn-reality"
    _in "    · 详情: docs/HANDOVER-known-issues.md 第二节"
    printf '  仍然生成? [y/N]: '
    read -r go2
    case "$go2" in
        [yY]*) ;;
        *) echo >&2; echo "  已取消"; exit 0 ;;
    esac
fi
echo >&2
printf '  确认生成? [y/N]: '
read -r go
case "$go" in
    y|Y|yes|YES) ;;
    *) _in "已取消"; exit 0 ;;
esac

# ---------------------------------------------------------------- 建
export X_BATCH_DOMAIN="$UP_DOM"
export X_BATCH_DL_DOMAIN="$DL_DOM"
[ -n "${DL_ADDR:-}" ] && export X_BATCH_DL_ADDRESS="$DL_ADDR"
export X_NO_RELOAD=1

echo >&2
bash "$_PBATCH" "vless:4:split:$SPLIT" < /dev/null
rc=$?
echo >&2
if [[ $rc -eq 0 ]]; then
    _ok "已生成。重启服务后生效: 菜单 8) 服务与配置"
else
    _er "没建成 —— 上面有具体原因"
fi
exit $rc