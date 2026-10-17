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
    # ${REPO:-} : 脚本跑在 set -u 下, 直接写 $REPO 会因未绑定而整段崩 ——
    # 而崩在这里等于"整个自动配置不生效", 且报错跟真实原因毫无关系。
    for c in "$d/../conf" "$d/.." "$d" "${REPO:-}/conf"; do
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
_cd_scan() {                      # <file>... → 每行 5 字段, 用 | 分隔
    # ★ 分隔符必须是**非空白**字符。tab 算 IFS 空白, 于是
    #   `a		b`(中间是空字段) 会被折叠成 `a	b` —— 空字段消失, 后面所有列
    #   往前挪一位。实测踩过: path 跑进了"下行域名"列, nginx_apply 于是去找
    #   一个叫 "/cdn-cdn-20000" 的 server_name, 报"找不到域名 /cdn-cdn-20000"。
    #   报错里那个"域名"一眼就能看出不对劲 —— 是路径不是域名。
    python3 - "$@" <<'PY'
import json, os, sys

UL_DOMAINS = os.environ.get("_CD_UL_DOMAINS", "")   # 上行域名, 生成时的入参

def site_for(sec):
    """这一段要不要挂 nginx 站点。
    reality 是直连握手 (没有 TLS, nginx 根本接不了), 其余都要。"""
    return (sec or "none") != "reality"

rows, seen = [], set()
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
        port = str(i.get("port") or "")
        if not port:
            continue
        # ★ 只绑回环的入站是 nginx 档节点 —— 它由 deploy 自己配反代
        #   (grpc_pass + 明文回源), 这里再配一遍只会把那段**覆盖**掉:
        #   cdn_auto 以前无条件传 --origin-tls, 于是给我们刚配好的
        #   grpc_pass/明文 段换成 proxy_pass https:// 明文端口 —— 上行
        #   立刻 502, 而节点显示"生成成功"。
        # ★ 只在**配置站点**这一趟里跳过回环; prune 那一趟必须看到它们 ——
        #   否则"实时节点清单"里少了这些域名, 清空节点时会把它们正在用的
        #   nginx 段当成孤儿删掉 (节点还在, 但没人转发了)。
        _lsn = (i.get("listen") or ss.get("listen") or "")
        if os.environ.get("_CD_SKIP_LOOPBACK") == "1" \
           and _lsn in ("127.0.0.1", "::1", "localhost"):
            continue
        xh = ss.get("xhttpSettings") or {}
        dl = xh.get("downloadSettings") or {}
        path = (xh.get("path") or "/")

        # ★ 直接读**生成出来的 downloadSettings**, 不再从外部变量推。
        #
        #   原来我只看上行: sec != reality 才算数。于是 reality-cdn 那种
        #   "上行 REALITY + 下行 CDN" 被整体跳过 —— 而它的**下行**正要走
        #   Cloudflare, 恰恰最需要站点。结果是三个分离节点只认出两个,
        #   少配的那个到运行时才 502。
        #
        #   下行的地址与加密层就写在片段里, 不用猜, 也不会漏。
        ups = [(i.get("_domain") or ss.get("security") or "", site_for(ss.get("security")))]
        downs = []
        if dl.get("address"):
            downs.append((dl.get("address"), site_for(dl.get("security"))))

        # ★ 上行域名**不在片段里** —— 它是生成时的入参, 实测三份片段的
        #   _meta.domain 全是 None。所以上行走环境变量传进来。
        #   下行则**在片段里** (downloadSettings.address), 直接读 —— 读生成
        #   出来的配置比重新推导可靠: 它就是内核最后会用的那个值。
        meta = i.get("_meta") if isinstance(i.get("_meta"), dict) else {}
        dom = meta.get("domain") or i.get("_domain") or (UL_DOMAINS.split(",")[0] if UL_DOMAINS else "")
        dl_dom = meta.get("dl_domain") or dl.get("address") or ""

        want = []
        if dom:
            want.append((dom, site_for(ss.get("security"))))
        if dl_dom:
            want.append((dl_dom, site_for(dl.get("security"))))
        for d_, needs in want:
            if not needs:
                continue
            k = (d_, port, tr)
            if k in seen:
                continue
            seen.add(k)
            # ★ 第四列 (同组下行域名) **只在下行也是 TLS 时**填。
            #   下行是 REALITY 时填了它, _cd_apply 会把它当成"第二个 CDN
            #   域名"交给 nginx_apply --domain a,b —— 于是去站点文件里找一个
            #   叫 203.0.113.9 的 server_name, 找不到, 报
            #   "找不到域名 203.0.113.9 的站点文件"。
            #   REALITY 下行是**直连**的, 本来就不该有站点。
            is_dl_tls = (dl_dom and d_ != dl_dom and dl.get("security") != "reality")
            # ★ 带上这个节点自己的 path。nginx 一个 server 只有一条
            #   location /, 所以同一个域名上跑两个分离节点 (不同端口) 时,
            #   第二个必须落在**各自的 path** 上, 否则两条 location / 打架,
            #   流量全被转到先插的那个端口 —— 而节点看起来都"生成成功"。
            #   nginx_apply 本来就按 `域名|/path` 打标记, 一节点一 path
            #   互不干扰, 删节点也只摘自己那一条。
            # 第六列: 回源是否 TLS —— 由**片段自己的** security 决定, 不再
            # 无条件开。tls 才是双层 TLS (xray 自带证书), none 必须明文回源。
            _otls = "1" if (ss.get("security") or "none") == "tls" else "0"
            rows.append((d_, port, tr, dl_dom if is_dl_tls else "", path, _otls))
print("\n".join("|".join(r) for r in rows))
PY
}

_cd_apply() {                     # <dom> <port> <tr> <cdn> <dl> <path> <origin_tls> [dry]
    local dom="$1" port="$2" tr="$3" cdn="$4" dl="$5" path="${6:-}" otls="${7:-}" dry="${8:-}"
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
    # 一节点一 path: nginx 里按 path 分段, 同域名多个节点互不覆盖。
    # 只在非根路径时才传 —— 传 --path / 和不传是同一件事, 但显式传能让
    # nginx_apply 打出 `域名|/` 这个标记, 删除时按同一套规则找得到。
    [[ -n "$path" ]] && a+=(--path "$path")
    [[ "$cdn" == "1" ]] && a+=(--cdn)
    # 回源 SNI 用**上行**那个域名 —— 下行域名是给客户端用的, 源站证书
    # 签的是上行域名, 用下行域名做 SNI 会证书不匹配。
    #
    # ★ --origin-tls 只在入站**自己**终结 TLS 时加 (来源: 片段的 security)。
    #   对明文入站加它是 https → 明文端口, 回源 502。
    if [[ "$otls" == "1" ]]; then
        a+=(--origin-tls --origin-sni "$dom")
    fi
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
            --domain) dom="$2"; export _CD_UL_DOMAINS="$2"; shift 2 ;;
            --downlink-domain) dl="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    # 配置这一趟跳过回环入站 (nginx 档节点由 deploy 自己配, 见上)
    local rows; rows=$(_CD_SKIP_LOOPBACK=1 _cd_scan "$@")
    [[ -z "$rows" ]] && return 0                       # 照抄 SB: 没 CDN 就安静

    local n=0 d0 port tr dl2 npath otls
    while IFS='|' read -r d0 port tr dl2 npath otls; do
        [[ -n "$d0" ]] && n=$((n+1))
    done <<< "$rows"
    [[ $n -eq 0 ]] && return 0

    printf '  自动配置 Nginx (CDN) —— %s 个站点\n' "$n" >&2

    # ★ 双域名会产出**两行**: 一行是上行 (第四列带下行域名), 一行是下行的
    #   单域名。照直跑两遍的话第二遍是重复劳动 —— nginx_apply 幂等, 所以
    #   结果不会错, 只是白跑一遍还多打一行"已存在"。
    #   所以先把"已经作为别人下行出现过"的域名收集起来, 跳过它们的独立行:
    #   双域名的活儿由上行那一行一次做完。
    # 双域名会产出两行 (上行那行带下行域名, 下行是独立一行)。第一行一次
    # 做完两个域名, 所以把"已经作为别人下行出现过"的域名跳过 —— 去重要
    # 连**端口与 path** 一起比, 只比域名会漏节点。
    local -a paired=()
    while IFS='|' read -r d0 port tr dl2 npath otls; do
        [[ -n "$dl2" ]] && paired+=("$dl2@$port@$npath")
    done <<< "$rows"

    local ok=0 bad=0
    while IFS='|' read -r d0 port tr dl2 npath otls; do
        [[ -z "$d0" ]] && continue
        if [[ -z "$dl2" ]]; then
            local skip=0 q
            for q in "${paired[@]:-}"; do [[ "$q" == "$d0@$port@$npath" ]] && skip=1; done
            [[ $skip -eq 1 ]] && continue
        fi
        # 行内第一列就是**这个域名**, 下行域名在第四列 —— 双域名时 nginx_apply
        # 会为两个域名各找站点文件各插一段 (它们的 server 块本来就分开)。
        if _cd_apply "$d0" "$port" "$tr" "1" "$dl2" "$npath" "$otls" "$dry"; then
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
    # ★ 存活清单要按**完整 tag** (`域名` 与 `域名|/path`) 给, 不能只给域名:
    #   prune 现在按 tag 精确比对, 只给域名的话带路径的段会被判成孤儿
    #   (反过来, 只按域名判又永远漏报同域名的孤儿 —— 两头都不对)。
    local live=""
    if [[ ${#frags[@]} -gt 0 ]]; then
        live=$(_cd_scan "${frags[@]}" | awk -F'|' '{print $1; if ($5 != "") print $1"|"$5}' \
               | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
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