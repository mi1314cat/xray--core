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
_repo="$(cd "$_here/.." && pwd)"
_psh="$_repo/conf/lib/preset.sh"

if [[ ! -r "$_psh" ]]; then
    _er "找不到 conf/lib/preset.sh ($_psh)"
    exit 1
fi
# shellcheck source=/dev/null
source "$_psh"

if ! declare -F x_split_modes >/dev/null 2>&1; then
    _er "这个版本的 preset.sh 里没有分离模式表, 请更新后再试"
    exit 1
fi

echo >&2
_bo "════ xHTTP 上下行分离 ════"
_cy "  上下行真正分开: 下行走独立 GET、上行走独立 POST —— 不是一条连接上双工"
echo >&2
_in "  1) 上行 CDN + 下行 CDN        两段都走 Cloudflare 橙云, ECH 默认开, 藏得最深"
_in "  2) 上行 CDN + 下行 REALITY    上行藏进 CDN, 下行直连 + REALITY 握手伪装"
_in "  3) 上行 REALITY + 下行 CDN    上行不经过第三方, 最常见的折中"
echo >&2
_wn "  只有一个域名也可以 —— 上下行仍然分开, 只是共用同一个入口。"
_wn "  两个域名是**加出来的能力**, 不是前提。"
echo >&2

printf '  选哪个组合 [1-3, 回车=1, 0=退出]: '
read -r pick || { echo >&2; exit 0; }
pick="${pick:-1}"
case "$pick" in
    0|q|Q) exit 0 ;;
    1) SPLIT=cdn-cdn ;;
    2) SPLIT=cdn-reality ;;
    3) SPLIT=reality-cdn ;;
    *) _er "看不懂"; exit 1 ;;
esac

# ---------------------------------------------------------------- 域名
_up_hint="上行域名 (Cloudflare 橙云指向这里, TLS 要证书)"
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
bash "$_here/preset_batch.sh" "vless:4:split:$SPLIT" < /dev/null
rc=$?
echo >&2
if [[ $rc -eq 0 ]]; then
    _ok "已生成。重启服务后生效: 菜单 8) 服务与配置"
else
    _er "没建成 —— 上面有具体原因"
fi
exit $rc