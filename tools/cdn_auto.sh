#!/usr/bin/env bash
# CDN 自动配置 nginx + 批量端口账本 —— 借鉴 sing-box-core
#
# ★ 为什么现在才接
#
#   SB 和 M 早就有了: 建完走 CDN 的节点就顺手把 nginx 站点配好。我们这边
#   preset_batch.sh 里 9 处提到 nginx, 却从不调 nginx_apply.py —— nginx 只是
#   它知道的一个档位标签。于是"选了 CDN 档"只把域名记进节点元数据 (分享链接
#   的 SNI/Host 用), 真正的反代段还得自己走菜单 6。
#
#   那边有四点值得照抄 —— 不是照抄代码, 是照抄**取舍**:
#
#   1. 没有走 CDN 的节点就**安静返回**, 不刷屏。自动插入最招人烦的就是
#      "我建了个直连节点, 它凭什么跟我说 nginx"。
#   2. 域名从**配置里的字段**读, 不从注释读。SB 那边原来匹配注释行, 配置
#      头部一改版注释没了, 自动插入直接报错退出 —— 注释会被人改。
#   3. 回源必须开 TLS (proxy_pass https://)。xhttp 入站自己带证书, 用 http://
#      回源会 400/502, 而 nginx 本身不报错, 只表现为"配好了但连不上"。
#   4. 删节点要收拾干净。清理侧我们早就有, 创建侧补上之后这一对才对称。
#
# ★ 关于 XHTTP 的两个域名
#
#   用户的要求: "考虑到如果只有一个域名的情况, 这个时候其实也可以, 只是
#   我们的配置用的是同一个域名而已。这其实就是多了一个功能, 就是两个域名。"
#
#   所以这里**不把"只有一个域名"当错误**。下行域名等于上行域名是完全正常的
#   用法: 上下行照样分开 (独立 GET / 独立 POST), 只是共用一个域名。
#   两个域名是**加出来的能力**, 不是前提条件 —— 判据写成"两个域名时才处理"
#   的话, 单域名用户就什么都拿不到。

_CDLIB_DIR=""
_cdlib_resolve() {
    local d c
    d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    # 候选路径逐个试。nginx_apply.py 在 conf/lib/ 下, 而本文件在 tools/ 下,
    # 所以要往 **上一级** 找 conf/lib。
    #
    # ★ 这已经是同一轮里第三次栽在"路径不对 + 失败就静默 return 0"上了:
    #   一次是 preset_batch.sh 里 CD_AUTO 写成 $_lib_dir/cdn_auto.sh;
    #   一次是这个函数的 $d/../lib (少了一级 conf);
    #   每次的表现都是"功能从来没发生过, 而屏幕上没有任何提示"。
    #   所以这里: 找不到就**喊出来**, 绝不安静返回。
    for c in "$d/../conf" "$d/.." "$d" "$REPO/conf"; do
        if [[ -r "$c/lib/nginx_apply.py" ]]; then
            _CDLIB_DIR="$(cd "$c" && pwd)"
            return 0
        fi
    done
    printf '[Error] 找不到 nginx_apply.py (在 %s 附近找过了) —— nginx 自动配置不生效\n' "$d" >&2
    return 1
}

# 从片段读出 (域名, 端口, 传输, 是否CDN, 下行域名)。
# 用 python 解析 JSON, 不用 grep —— 正则去猜字段迟早猜错, 而猜错的表现是
# "配了 nginx 但域名是空的", 用户看不出来。
_cd_scan() {                      # <file>... → 每行 5 个字段, TAB 分隔
    python3 - "$@" <<'PY' 2>/dev/null
import json, sys

out, seen = [], set()
for f in sys.argv[1:]:
    try:
        d = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    for i in (d.get("inbounds") or []):
        ss = i.get("streamSettings") or {}
        tr = ss.get("network") or "raw"
        if tr not in ("ws", "grpc", "h2", "httpupgrade", "xhttp"):
            continue
        sec = ss.get("security") or "none"
        # 片段里**没有** _domain / _meta —— 生成时域名是入参, 写在分享元数据里,
        # 不进内核配置。所以这里只吐 (端口, 传输, 安全层), 域名由调用方给。
        # 我原来在这里找 `_domain`, 找了半天全是 None, 于是"没有走 CDN 的
        # 节点" → 静默返回 0 → 自动配置从来没发生过, 而没有任何报错。
        k = (str(i.get("port") or ""), tr, sec)
        if not k[0] or k in seen:
            continue
        seen.add(k)
        out.append("\t".join(k))
print("\n".join(out))
PY
}

_cd_apply() {                     # <dom> <port> <tr> <cdn> <dl> [dry]
    local dom="$1" port="$2" tr="$3" cdn="$4" dl="$5" dry="${6:-}"
    _cdlib_resolve || return 1
    local apy="$_CDLIB_DIR/lib/nginx_apply.py"
    [[ -r "$apy" ]] || { printf '[Error] 找不到 nginx_apply.py\n' >&2; return 1; }
    # ★ XHTTP 上下行分离的域名, 走 nginx_apply.py **已有的**双域名机制:
    #   --domain 收逗号分隔的多个域名, _per_domain() 会为每个域名各自找站点
    #   文件并各插一段 (两个域名很可能在两个不同文件里)。
    #
    #   我一开始想加个 --downlink-domain 参数, 查了一下发现那个参数**不存在**
    #   —— 用了就是"未识别的参数", 而 argparse 会直接报错退出, 表现为
    #   "nginx 没配上", 很容易被误判成工具坏了。已有的机制够用, 不另造。
    #
    #   ★ 单域名 (dl 为空, 或 dl == dom) 就只传一个 —— 这是**正常用法**,
    #     不是退化: 上下行照样分开 (独立 GET / 独立 POST), 只是共用一个域名。
    local dom_arg="$dom"
    if [[ "$tr" == "xhttp" && -n "$dl" && "$dl" != "$dom" ]]; then
        dom_arg="$dom,$dl"
    fi
    # ★ --dry-run 只在显式预演时加。之前我把它**写死在参数数组里**, 于是
    #   x_cdn_autosetup 每次都只是"预演, 未写入" —— 功能看着跑通了
    #   (还打印了完整的 server 块), 实际磁盘上一个字都没改。
    #   自动配置的核心就是"真的写进去", 预演必须由调用方显式要。
    local -a a=(--domain "$dom_arg" --port "$port" --transport "$tr")
    [[ -n "$dry" ]] && a+=(--dry-run)
    [[ "$cdn" == "1" ]] && a+=(--cdn)
    # 回源 SNI 用**上行**那个域名 —— 下行域名是给客户端用的, 源站证书
    # 签的是上行域名, 用下行域名做 SNI 会证书不匹配。
    a+=(--origin-tls --origin-sni "$dom")
    python3 "$apy" "${a[@]}" 2>&1
}

# ---------------------------------------------------------------- 建完自动配
x_cdn_autosetup() {
    # 找不到就报错退出 —— 以前是 return 0, 于是"没配 nginx"和"没找到工具"
    # 在屏幕上一模一样, 用户只能猜。
    _cdlib_resolve || return 1
    local dry="" dom="" dl=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) dry="--dry-run"; shift ;;
            --domain) dom="$2"; shift 2 ;;
            --downlink-domain) dl="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    local rows; rows=$(_cd_scan "$@")
    [[ -z "$rows" ]] && return 0                       # 照抄 SB: 没 CDN 就安静

    # 只有传了域名才谈得上 CDN 档 —— REALITY 直连节点没有域名概念。
    # 没域名就安静返回, 但要说一句, 免得用户以为"配过了"。
    if [[ -z "$dom" ]]; then
        printf '  (没有域名, 跳过 nginx 自动配置 —— 这几个是直连节点)\n' >&2
        return 0
    fi

    local n=0 port tr sec
    while IFS=$'\t' read -r port tr sec; do
        [[ "$sec" != "reality" ]] && n=$((n+1))
    done <<< "$rows"
    [[ $n -eq 0 ]] && return 0

    printf '  自动配置 Nginx (CDN) —— %s 个节点\n' "$n" >&2
    local ok=0 bad=0
    while IFS=$'\t' read -r port tr sec; do
        # REALITY 是直连的, 不该挂 nginx
        [[ "$sec" == "reality" ]] && continue
        if _cd_apply "$dom" "$port" "$tr" "1" "$dl" "$dry"; then
            ok=$((ok+1))
        else
            bad=$((bad+1))
        fi
    done <<< "$rows"
    if [[ $bad -gt 0 ]]; then
        printf '[Error] %s 个站点的 nginx 配置没写成功 —— 节点已生成, 但走 CDN 连不上\n' "$bad" >&2
        printf '[Warn]   请用菜单 6) Nginx 站点管理 手工补\n' >&2
        return 1
    fi
    printf '  ✓ %s 个 CDN 站点的 nginx 配置已就绪\n' "$ok" >&2
}

# ---------------------------------------------------------------- 删完收拾
x_cdn_prune_stale() {
    _cdlib_resolve || return 1
    local apy="$_CDLIB_DIR/lib/nginx_apply.py"
    [[ -r "$apy" ]] || return 0
    local -a frags=() f
    shopt -s nullglob
    for f in "${XRAY_CONF_DIR:-$XRAY_BASE/conf}"/*.json; do frags+=("$f"); done
    shopt -u nullglob
    # ★ 一个片段都没有时**不能直接返回**。
    #   原来这里是 `[[ ${#frags[@]} -eq 0 ]] && return 0` —— 可"一个节点都
    #   没了"恰恰是最需要收拾的时刻, 却是唯一会被跳过的情况。实测: 清空
    #   conf/ 后 prune 什么都不做, 两个站点的 location 原样留着, 节点已经
    #   没了却还反代到不存在的端口 → Cloudflare 回源 502。
    #   所以这里继续往下走, 让 live 为空 = 全部都是孤儿。
    local live=""
    [[ ${#frags[@]} -gt 0 ]] && live=$(_cd_scan "${frags[@]}" | cut -f1 | sort -u | tr '\n' ',' | sed 's/,$//')
    [[ -z "$live" ]] && live="__none__"
    python3 "$apy" --prune-orphans "$live" 2>&1 || true
}

# ---------------------------------------------------------------- 端口账本
# ★ 借鉴 SB 的 batch_next_port: 用 .batch-used 记下**已经领过的端口**。
#
#   原来的问题: 每次调用 preset_batch.sh 都从 X_BATCH_PORT_START 重新开始,
#   于是同协议+同传输+同安全层的两个预置 (vless:4 与 vless:5 都是 xhttp+tls)
#   拿到同一个端口、写出**同一个文件名**, 后者覆盖前者 —— 而日志两行都写
#   "成功"。这种"看着成功、实际少了一个节点"最难查。
#
#   账本放 XRAY_BASE 下而不是 /tmp: 换一次调用不丢, 也不误伤别人。
cd_batch_take_port() {
    local used="$XRAY_BASE/.batch-used"
    local s="${X_BATCH_PORT_START:-20000}" e="${X_BATCH_PORT_END:-50000}"
    mkdir -p "$XRAY_BASE" 2>/dev/null || true
    local n=$s
    [[ -s "$used" ]] && n=$(( $(tail -1 "$used" 2>/dev/null || echo 0) + 1 ))
    while (( n <= e )); do
        if ! ss -tuln 2>/dev/null | grep -qE "[:.]$n\$" \
           && ! x_port_taken "$n" 2>/dev/null \
           && ! grep -qx "$n" "$used" 2>/dev/null; then
            printf '%s\n' "$n" >> "$used"
            echo "$n"; return 0
        fi
        ((n++))
    done
    printf '[Warn] 批量端口范围 %s-%s 已耗尽, 回落随机空闲端口\n' "$s" "$e" >&2
    cd_random_free_port
}

cd_random_free_port() {
    local p
    while true; do
        p=$(shuf -i 20000-60000 -n 1 2>/dev/null || echo $((20000 + RANDOM % 40000)))
        ss -tuln 2>/dev/null | grep -qE "[:.]$p\$" && continue
        x_port_taken "$p" 2>/dev/null && continue
        printf '%s\n' "$p" >> "$XRAY_BASE/.batch-used"
        echo "$p"; return 0
    done
}