#!/usr/bin/env bash
# Xray 项目证书校验公共库
#
# 只管"能不能用"这件事: 路径存不存在、文件是不是有效证书、证书有没有过期、
# key 和 crt 配不配对。
#
# 为什么单独做: 证书问题在现场的表现是"节点配好了但连不上", 而配置校验
# (xray run -test) 对一个不存在的证书文件并不总是报错 —— 校验通过、启动
# 失败, 或者更糟, 启动成功但握手永远失败。必须在生成阶段就拦住。

# x_cert_check <crt> <key> [期望域名]
#
# 返回 0 可用; 非 0 时错误信息已打到 stderr。
x_cert_check() {
    local crt="$1" key="$2" want="${3:-}"
    local err=""
    if [[ -z "$crt" || -z "$key" ]]; then
        printf '证书路径为空 (crt=%s key=%s)\n' "$crt" "$key" >&2
        return 1
    fi
    [[ -f "$crt" ]] || { printf '证书不存在: %s\n' "$crt" >&2; return 1; }
    [[ -f "$key" ]] || { printf '私钥不存在: %s\n' "$key" >&2; return 1; }
    [[ -r "$crt" ]] || { printf '证书不可读: %s\n' "$crt" >&2; return 1; }
    [[ -r "$key" ]] || { printf '私钥不可读: %s\n' "$key" >&2; return 1; }

    command -v openssl >/dev/null 2>&1 || {
        printf '缺 openssl, 无法校验证书\n' >&2
        return 1
    }

    # 是不是真的 PEM 证书 (而不是空文件 / HTML 错误页 / 别的文本)
    if ! openssl x509 -in "$crt" -noout >/dev/null 2>&1; then
        err=$(head -c 60 "$crt" | tr -d '\0' | tr '\n' ' ')
        printf '证书无法解析 (可能下载到了错误页): %s\n' "${err:0:60}" >&2
        return 1
    fi
    # 私钥是不是真的私钥
    if ! openssl pkey -in "$key" -noout >/dev/null 2>&1; then
        err=$(head -c 60 "$key" | tr -d '\0' | tr '\n' ' ')
        printf '私钥无法解析: %s\n' "${err:0:60}" >&2
        return 1
    fi

    # 过期检查。只看 notAfter —— notBefore 过期的情况罕见但存在。
    # -checkend 0 的语义是"再过 0 秒是否还有效", 即已过期则非 0。
    if ! openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then
        printf '证书已过期: %s (到期 %s)\n' \
            "$crt" "$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)" >&2
        return 1
    fi
    # 30 天内到期要提醒 —— 过期当天才发现, 通常已经忘了节点在哪台机器上。
    # -checkend N 返回 0 的意思是"再过 N 秒仍然有效"。所以返回**非 0**
    # 才是临期。写反了会对每一张正常证书都报临期, 报多了就等于没报。
    if ! openssl x509 -in "$crt" -noout -checkend $((30*86400)) >/dev/null 2>&1; then
        printf '证书将在 30 天内过期: %s (到期 %s)\n' \
            "$crt" "$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)" >&2
    fi

    # crt 和 key 是不是一对
    local a b
    a=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
    b=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null)
    if [[ -n "$a" && -n "$b" && "$a" != "$b" ]]; then
        printf '证书与私钥不配对 (crt=%s key=%s)\n' "$crt" "$key" >&2
        return 1
    fi

    # 期望域名对不上是最难查的一类: 配置全对、服务在跑、客户端就是握手失败
    if [[ -n "$want" ]]; then
        local got san
        got=$(x_cert_domain "$crt")
        san=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null)
        if [[ -n "$got" && "$got" != "$want" ]]; then
            if grep -qE "DNS:${want}\b" <<< "$san" || grep -qE "DNS:\*\." <<< "$san"; then
                :   # 通配符或 SAN 里确实有期望域名, 以 openssl 判定为准
            else
                printf '证书域名与使用域名不一致: 证书=%s 使用=%s\n' "$got" "$want" >&2
                printf '  证书 SAN: %s\n' "$(grep -oE 'DNS:[^,]+' <<< "$san" | tr '\n' ' ' | sed 's/^/DNS:/' | cut -c1-120)" >&2
                return 1
            fi
        fi
    fi
    return 0
}

# x_cert_domain <crt> —— 从证书取真实域名
#
# 优先 SAN (现代签发方都在 SAN 里), 回退 CN。取不到再用文件名猜 —— 文件名
# 猜出来的域名是**猜测**, 调用方若要拿它去核对, 必须知道这一点。
x_cert_domain() {
    local crt="$1" dom=""
    if command -v openssl >/dev/null 2>&1 && [[ -f "$crt" ]]; then
        dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null |
            grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
        [[ -z "$dom" ]] && dom=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null |
            grep -oE "CN *= *[^,]+" | head -1 | sed 's/.*CN *= *//' | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi
    if [[ -z "$dom" && -n "$crt" ]]; then
        # 拿不到就按文件名猜, 并在 stderr 说明这是猜的
        dom=$(basename "$crt" | sed -E 's/\.(crt|pem|cer)$//; s/_cert$//; s/^cert-//')
        printf '证书里读不到域名, 按文件名猜: %s\n' "$dom" >&2
    fi
    printf '%s' "$dom"
}