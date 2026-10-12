#!/usr/bin/env bash
# cert_guard.sh — 证书自愈: nginx 引用的证书缺了, 就把它补回去
#
# 为什么需要这个:
#
# 这台机器上有三套东西在动 /home/web/certs/:
#   ~/auto_cert_renewal.sh   宝塔的每日续签, 会 `certbot delete` 整个 lineage
#   mihomo 的 cert_sync.sh   把 letsencrypt 的证书复制进来
#   以及**别的脚本/面板**, 具体是谁删的至今没抓到现行 —— 只观测到现象:
#   私钥 `*_key.pem` 一直在, 而证书 `*_cert.pem` / `*.crt` 会**突然全没了**。
#
# 后果不是"某个节点连不上", 是**整个 nginx 起不来**:
#   nginx 启动时只要有一个 ssl_certificate 读不到就直接 [emerg] 退出,
#   容器进重启循环 → Cloudflare 回源 521 → 所有走 CDN 的节点**一起挂**。
#
# 所以这里做的是**兜底**, 不是根治: 缺了就补, 补完 reload,
# 让 nginx 重新能起来, 再让续签脚本去管到期。
set -u

CERTS_DIR="${X_CERT_DIR:-/home/web/certs}"
CONF_DIR="${X_NGINX_CONF_DIR:-/home/web/conf.d}"
LE_DIR="${X_LE_DIR:-/etc/letsencrypt/live}"
NGINX_CTR="${X_NGINX_CTR:-nginx}"

_g() { printf '\e[32m[OK]\e[0m %s\n' "$*" >&2; }
_w() { printf '\e[33m[Warn]\e[0m %s\n' "$*" >&2; }
_e() { printf '\e[31m[Error]\e[0m %s\n' "$*" >&2; }
_i() { printf '\e[36m[Info]\e[0m %s\n' "$*" >&2; }

# 站点文件里引用了哪些证书 —— 以 nginx 真正读到的为准, 不是猜
wanted_certs() {
    [[ -d "$CONF_DIR" ]] || return 0
    grep -hoE 'ssl_certificate(_key)?[[:space:]]+[^;]+;' "$CONF_DIR"/*.conf 2>/dev/null \
    | sed -E 's/.*[[:space:]]+([^;]+);.*/\1/' \
    | sed 's#^/etc/nginx/certs/#'"$CERTS_DIR"'/#' \
    | sort -u
}

# 一个域名的证书能不能从 letsencrypt 补回来
restore_from_le() {
    local base="$1" src
    for src in "$LE_DIR/$base/fullchain.pem" "$LE_DIR/$base/cert.pem"; do
        [[ -f "$src" ]] || continue
        cp -f "$src" "$CERTS_DIR/${base}_cert.pem" 2>/dev/null || return 1
        _g "$base 的证书已从 letsencrypt 补回"
        return 0
    done
    return 1
}

# 兜底站点的证书 (server_name _): 从来没有签发记录, 只能自签。
#
# ★ 必须**拿现成的私钥去签**, 不能顺手生成一对新的:
#   站点里 ssl_certificate_key 指向的往往是一把早就存在的私钥。证书没了、
#   私钥还在时, 正确做法是拿这把私钥补一张自签的 —— 换了私钥等于动了用户的
#   东西, 而这里只是想"别让 nginx 起不来"。
#   (第一版我写了 `[[ -f "$base_key.pem" ]] || return 1`, 于是这张卡直接放弃,
#    nginx 继续重启循环 —— 兜底代码自己成了故障的一部分。)
self_sign() {
    local cert_path="$1" key_path="$2" tmpc
    tmpc="$(mktemp "${TMPDIR:-/tmp}/cguard.XXXXXX")" || return 1
    if [[ -f "$key_path" ]]; then
        openssl req -x509 -key "$key_path" -days 3650 -out "$tmpc" \
            -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
    else
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "${key_path}.tmp" -out "$tmpc" \
            -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 || {
                rm -f "$tmpc"; return 1; }
        mv -f "${key_path}.tmp" "$key_path" && chmod 600 "$key_path" 2>/dev/null
    fi
    if [[ -s "$tmpc" ]]; then
        mv -f "$tmpc" "$cert_path" || { rm -f "$tmpc"; return 1; }
        _g "$(basename "$cert_path") 已用现有私钥自签补上"
        return 0
    fi
    rm -f "$tmpc"; return 1
}

# 站点里给这个证书配套的私钥在哪 (同目录、同前缀)
key_for() {
    local cert_path="$1" dir base k
    dir="$(dirname "$cert_path")"
    base="$(basename "$cert_path")"
    base="${base%.crt}"; base="${base%.pem}"
    for k in "${base}.key" "${base}_key.pem" "${base}.pem"; do
        if [[ -f "$dir/$k" ]]; then echo "$dir/$k"; return 0; fi
    done
    echo "$dir/${base}.key"
}

main() {
    local dry=0 f base fixed=0 want
    [[ "${1:-}" == "--dry-run" ]] && dry=1

    _i "检查 nginx 引用的证书 (源: $CONF_DIR)"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        base=$(basename "$f")
        [[ -f "$f" ]] && continue
        want="${base%_key.pem}"; want="${want%_cert.pem}"; want="${want%.crt}"; want="${want%.pem}"
        _w "缺证书: $base"
        if [[ "$dry" == 1 ]]; then
            if [[ -d "$LE_DIR/$want" ]]; then
                _i "  → 会从 $LE_DIR/$want 补回"
            else
                _i "  → 没有签发记录, 会自签"
            fi
            continue
        fi
        if restore_from_le "$want" || self_sign "$f" "$(key_for "$f")"; then
            fixed=$((fixed + 1))
        else
            _e "  ✗ $base 补不回来 —— nginx 会一直起不来, 需要手工处理"
        fi
    done < <(wanted_certs)

    if [[ "$dry" == 1 ]]; then
        return 0
    fi
    if [[ "$fixed" -eq 0 ]]; then
        _i "证书齐全, 不用动"
        return 0
    fi

    _i "补了 $fixed 个, 让 nginx 重新读一次"

    # ★ 容器正在重启循环里的时候, `docker exec nginx -t` 直接报
    #   "Container ... is restarting, wait until it is running" 而**退出非零**。
    #   第一版把这个非零当成"配置有问题", 于是又去 restart —— 而容器此刻
    #   根本没在跑, 补好的证书也就没被读进去, 看起来像自愈没生效。
    #   所以先等它真能 exec, 再判配置。
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        docker exec "$NGINX_CTR" true >/dev/null 2>&1 && break
        sleep 2
    done
    if docker exec "$NGINX_CTR" nginx -t >/dev/null 2>&1; then
        docker exec "$NGINX_CTR" nginx -s reload >/dev/null 2>&1 \
            && _g "nginx 已 reload" || _w "reload 失败, 但配置本身是好的"
        return 0
    fi
    docker restart "$NGINX_CTR" >/dev/null 2>&1
    sleep 4
    for i in 1 2 3 4 5 6 7 8 9 10; do
        docker exec "$NGINX_CTR" true >/dev/null 2>&1 && break
        sleep 2
    done
    if docker exec "$NGINX_CTR" nginx -t >/dev/null 2>&1; then
        _g "nginx 已重启并通过配置校验"
        return 0
    fi
    _e "nginx 还是起不来 —— 站点里还有别的缺证书/语法问题"
    docker exec "$NGINX_CTR" nginx -t 2>&1 | tail -3 >&2
    return 1
}

main "$@"