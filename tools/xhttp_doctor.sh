#!/usr/bin/env bash
# xhttp_doctor.sh — 上下行分离节点连不上时, 先分清是"哪一段"断的
#
# 为什么需要这个:
#
# 上下行分离节点连不上时, 面板上一切正常 (配置校验过、内核接受、nginx 也配了),
# 源站 access log 里 POST 和 GET **都是 200** —— 唯一留下的线索是 xray 侧一行:
#
#     connection ends > http: invalid Read on closed Body
#
# 而这一行**不区分**是谁的问题。我实测过四种组合, 结果是:
#
#     直连 xray 端口 (不过 nginx / 不过 Cloudflare)   → 200
#     经 Cloudflare → nginx → xray                    → invalid Read on closed Body
#
# 所以第一件事是分清: 是**服务器配置**坏了, 还是**中间那一段** (CDN) 坏了。
# 这两者的修法完全相反, 靠猜会白折腾很久。
#
# 已知的一处根因 (用户可自行在 Cloudflare 控制台改, 不在本仓库):
#   SSL/TLS → Origin Server → Origin HTTP Protocol 选成了 **HTTP/2**。
#   Cloudflare 用 HTTP/2 回源时, nginx 把它降级成 HTTP/1.1 再转给 xray,
#   而 xray (Go 的 HTTP 服务) 在 xHTTP 上行那种"请求体边发边等下行"的
#   读法上会撞上 `invalid Read on closed Body`。
#   改成 **HTTP/1.1** 即可。
set -u

_g() { printf '\e[32m[OK]\e[0m %s\n' "$*" >&2; }
_w() { printf '\e[33m[Warn]\e[0m %s\n' "$*" >&2; }
_e() { printf '\e[31m[Error]\e[0m %s\n' "$*" >&2; }
_i() { printf '\e[36m[Info]\e[0m %s\n' "$*" >&2; }

XRAY_LOG="${1:-}"
case "${1:-}" in
    --help|-h|"")
        echo >&2
        _i "用法: $0 [xray日志路径]"
        _i "  没有日志路径就只查服务器侧的配置是否自洽"
        _i "  例: $0 /root/catmi/xray/log/access.log"
        exit 0 ;;
esac

echo >&2
echo "════ xHTTP 上下行分离 自检 ════" >&2

# ---- 1) 片段本身对不对 ----
CONF_DIR="${XRAY_BASE:-/root/catmi/xray}/conf"
N_SPLIT=0; N_BAD=0
for f in "$CONF_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for ib in d.get('inbounds') or []:
    xh=(ib.get('streamSettings') or {}).get('xhttpSettings') or {}
    if xh.get('downloadSettings'): raise SystemExit(0)
raise SystemExit(1)
" "$f" 2>/dev/null; then
        N_SPLIT=$((N_SPLIT + 1))
        # 下载设置里的三个必填项, 少一个内核就会那一句 invalid Read
        python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for ib in d.get('inbounds') or []:
    xh=(ib.get('streamSettings') or {}).get('xhttpSettings') or {}
    ds=xh.get('downloadSettings')
    if not ds: continue
    need=[]
    if not ds.get('address'): need.append('address')
    if not ds.get('port'):    need.append('port')
    sec=ds.get('security')
    if sec=='reality':
        rs=ds.get('realitySettings') or {}
        if not (rs.get('password') or rs.get('publicKey')): need.append('password/publicKey')
        if not rs.get('serverName'): need.append('serverName')
    if need: sys.exit(1)
" "$f" 2>/dev/null || N_BAD=$((N_BAD + 1))
    fi
done

if [[ "$N_SPLIT" -eq 0 ]]; then
    _i "conf/ 里没有上下行分离节点 (这一项只在你建过分离节点时有意义)"
else
    _g "$N_SPLIT 个分离节点"
    if [[ "$N_BAD" -gt 0 ]]; then
        _e "$N_BAD 个节点的 downloadSettings 缺必填字段 —— 这会直接连不上"
        _e "  内核会报: Failed to build REALITY config / empty \"password\""
        _e "  重新建一遍这个节点 (菜单 15), 别手工改片段"
    fi
fi

# ---- 2) 内核能不能起得来 ----
if command -v xray >/dev/null 2>&1; then
    BADF=""
    for f in "$CONF_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        xray run -test -config "$f" >/dev/null 2>&1 || BADF="$BADF $f"
    done
    if [[ -n "$BADF" ]]; then
        _e "这些片段内核不接受:$BADF"
    else
        _g "全部片段通过内核校验"
    fi
fi

# ---- 3) nginx 那段 ----
N_DIR="${X_NGINX_CONF_DIR:-/home/web/conf.d}"
if [[ -d "$N_DIR" ]]; then
    BLOCKS=$(grep -rl 'xray-core BEGIN' "$N_DIR"/*.conf 2>/dev/null | wc -l)
    if [[ "$BLOCKS" -gt 0 ]]; then
        _g "$BLOCKS 个站点插了面板的段"
        # xHTTP 必须两个方向都关缓冲
        BADBUF=0
        for b in $(grep -rl 'xray-core BEGIN' "$N_DIR"/*.conf 2>/dev/null); do
            seg=$(sed -n '/xray-core BEGIN/,/xray-core END/p' "$b")
            grep -q 'location .*xhttp\|/cdn-\|/reality-\|/split-' <<<"$seg" && {
                grep -qF 'proxy_buffering off' <<<"$seg" || BADBUF=$((BADBUF + 1))
                grep -qF 'proxy_request_buffering off' <<<"$seg" || BADBUF=$((BADBUF + 1))
            }
        done
        [[ "$BADBUF" -eq 0 ]] && _g "xHTTP 的缓冲两个方向都关了" \
            || _e "有 xHTTP 的段没关缓冲 —— 重建这些节点即可"
    else
        _w "没找到面板插的 nginx 段"
    fi
fi

# ---- 3b) nginx access log: CF 回源用了 HTTP/2 吗 ----
#
# ★ 这一条是**实测补上的**: 上面那句 `invalid Read on closed Body` 是最常见的
#   形态, 但还有一种更安静的 —— **请求根本没到 xray**, 客户端直接 000,
#   而 xray 日志里一个字都没有。这时只看 xray 日志会得出"服务器没问题"的
#   错觉 (因为确实没记录), 用户会去反复重建节点。
#
#   判据在 nginx 的 access log 里: 面板插的那条 xhttp location 上,
#   如果 CF 回源的请求是 `HTTP/2.0`, 就是同一条根因 (Origin HTTP Protocol
#   选成了 HTTP/2)。对照: 同一路径用 HTTP/1.1 的请求能到 xray。
_NGLOG=""
for _c in /home/web/log/nginx/access.log /var/log/nginx/access.log \
          /root/catmi/xray/log/access.log; do
    [[ -r "$_c" ]] && { _NGLOG="$_c"; break; }
done
if [[ -n "$_NGLOG" ]]; then
    # 面板插的 location 有哪些 —— 从**站点文件里读**, 不猜路径。
    # 与第 3) 条同一个 N_DIR / 同一套 BEGIN-END 标记。
    _ng_paths=""
    if [[ -n "${N_DIR:-}" && -d "$N_DIR" ]]; then
        _ng_paths=$(sed -n '/xray-core BEGIN/,/xray-core END/p' "$N_DIR"/*.conf 2>/dev/null \
                    | grep -oE 'location[[:space:]]+/[^ {]*' | awk '{print $2}' | sort -u | head -10)
    fi
    if [[ -n "$_ng_paths" ]]; then
        _h2=0
        while read -r _p; do
            [[ -n "$_p" ]] || continue
            _c2=$(grep -c "\"GET ${_p}.*HTTP/2.0" "$_NGLOG" 2>/dev/null) || _c2=0
            (( _c2 > 0 )) && _h2=$((_h2 + _c2))
        done <<< "$_ng_paths"
        if (( _h2 > 0 )); then
            echo >&2
            _w "nginx 日志里有 $_h2 次 **HTTP/2.0** 回源到面板插的 xhttp 路径"
            _i "  这和下面第 4 条是同一个根因的另一种表现: Cloudflare 的源站协议是 HTTP/2"
            _i "  区别只是这次请求**根本没到 xray** —— xray 日志里不会有一行, 别被它误导"
            _i "  控制台: SSL/TLS → Origin Server → Origin HTTP Protocol → 改成 **HTTP/1.1**"
        fi
    fi
fi

# ---- 4) 日志里那句话 ----
if [[ -n "$XRAY_LOG" && -r "$XRAY_LOG" ]]; then
    # ★ 不能写 `$(grep -c … || echo 0)`: grep -c 在**没命中时也会打印 0**
    #   并返回非 0, 于是 `|| echo 0` 又补一个 —— 变量成了 "0\n0",
    #   下一行 [[ … -gt 0 ]] 直接报
    #       [[: 0\n0: syntax error in expression (error token is "0")
    #   而这句话出现在**自检工具自己的输出里** —— 用户会以为自检坏了。
    #   正确写法: 拿 grep 的输出, 只用退出码决定要不要覆盖。
    N_BADLOG=$(grep -c 'invalid Read on closed Body' "$XRAY_LOG" 2>/dev/null) || N_BADLOG=0
    if [[ "${N_BADLOG:-0}" -gt 0 ]]; then
        echo >&2
        _e "日志里有 $N_BADLOG 次 invalid Read on closed Body"
        _i "这句话本身不说是谁的问题。分清的办法:"
        echo >&2
        _i "  1) 客户端改成**直连** xray 那个端口 (不过 CDN、不过 nginx)"
        _i "     直连能通 → 服务器配置没问题, 断在 CDN 那一段"
        _i "     直连也不通 → 是节点配置本身的问题, 看上面第 1/2 条"
        echo >&2
        _i "  2) 已知根因: Cloudflare 的 Origin HTTP Protocol 选成了 HTTP/2"
        _i "     控制台: SSL/TLS → Origin Server → Origin HTTP Protocol → 改成 **HTTP/1.1**"
        _i "     改完不用等, 生效很快。这不是本仓库能改的, 只能你去面板上点。"
    else
        _g "日志里没有 invalid Read on closed Body"
    fi
fi

echo >&2
_i "结论怎么读:"
_i "  直连通 + 经 CDN 不通  → 改 Cloudflare 的 Origin HTTP Protocol 为 HTTP/1.1"
_i "  两种都不通              → 重建节点 (菜单 15), 片段本身有问题"
echo >&2