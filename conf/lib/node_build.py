#!/usr/bin/env python3
"""通用节点生成 —— 声明式描述 → Xray inbound JSON。

## 为什么要有这层

现有 9 个协议脚本各自用一段 bash heredoc 拼 inbound JSON, 每加一个
"协议 × 传输 × 加密"的组合就要复制一份。缺口就是这么攒起来的:

    Trojan+WS        缺
    gRPC+REALITY     缺
    Trojan/SS 的 CDN 档位  缺

与其再写三个一次性脚本, 这里把 inbound 的组成拆成"协议 / 传输 / 加密"
三段, 组合出来。加新组合是加一行规格, 不是加一个脚本。

## 不改现有脚本

现有 9 个协议脚本是能用的, 本层不替换它们 —— 那属于"为了统一代码而重写
能跑的东西"。本层只负责新组合, 并且输出的片段格式与现有脚本完全一致,
所以下游 (节点注册表 / 分享 / nginx / Client) 一个都不用改。
"""

import json
import os
import tempfile
import uuid as _uuid

# 传输方式 → streamSettings 片段
TRANSPORTS = {
    "tcp": {},                       # Xray 里 network:"tcp" 本身就是裸 TCP
    "raw": {},
    "ws": {"network": "ws"},
    "xhttp": {"network": "xhttp"},
    "grpc": {"network": "grpc"},
    "httpupgrade": {"network": "httpupgrade"},
}

# 加密方式 → 可用传输。
#
# REALITY 只能跑在裸 TCP 上 —— 它的握手伪装依赖客户端直连目标站点,
# 中间任何一层协议封装 (WS/gRPC/XHTTP) 都会破坏握手。写成数据而不是注释,
# 这样拼错组合时会被拒绝, 而不是生成一条连不上的配置。
SECURITY_TRANSPORTS = {
    "none":   None,                  # 不限制
    "tls":    None,
    "reality": {"tcp", "raw"},
}


class NodeError(ValueError):
    """规格不合法。消息直接面向用户, 不需要再包装。"""


def _check_combo(protocol, transport, security):
    allowed = SECURITY_TRANSPORTS.get(security)
    if allowed is not None and transport not in allowed:
        raise NodeError(
            f"{security} 不能与 {transport} 组合 "
            f"(只支持 {'/'.join(sorted(allowed))})。\n"
            f"  原因: REALITY 的握手伪装要求客户端直连目标站点, "
            f"WS/gRPC/XHTTP 的封装层会破坏握手。"
        )


def _stream_settings(transport, security, opts):
    ss = dict(TRANSPORTS.get(transport, {}))
    if not ss:
        ss["network"] = transport if transport in ("tcp", "raw") else transport

    if security == "tls":
        tls = {"serverName": opts.get("sni") or opts.get("domain", "")}
        if opts.get("cert_file"):
            tls["certificates"] = [{
                "certificateFile": opts["cert_file"],
                "keyFile": opts["key_file"],
            }]
        if opts.get("alpn"):
            tls["alpn"] = opts["alpn"]
        # hysteria2 走 QUIC, ALPN 必须是 h3。不设的话内核不报配置错,
        # 但握手一定失败 —— 客户端 TCP 连上了却等不到 QUIC 回应。这种
        # "配置全对但连不上"最难查, 所以直接补上。
        elif transport == "hysteria":
            tls["alpn"] = ["h3"]
        if opts.get("allow_insecure"):
            tls["allowInsecure"] = True
        ss["security"] = "tls"
        ss["tlsSettings"] = tls

    elif security == "reality":
        rs = {
            "target": opts.get("dest") or f"{opts.get('sni','')}:443",
            "serverNames": [opts.get("sni") or opts.get("domain", "")],
            "privateKey": opts["private_key"],
            "shortIds": [opts.get("short_id", "")],
        }
        if opts.get("spider_x"):
            rs["spiderX"] = opts["spider_x"]
        ss["security"] = "reality"
        ss["realitySettings"] = rs

    else:
        ss["security"] = "none"

    # 传输细节
    if transport == "ws":
        ws = {}
        if opts.get("path"):
            ws["path"] = opts["path"]
        if opts.get("host"):
            ws["headers"] = {"Host": opts["host"]}
        if opts.get("early_data"):
            ws["maxEarlyData"] = int(opts["early_data"])
        if ws:
            ss["wsSettings"] = ws

    elif transport == "xhttp":
        xh = {"mode": opts.get("xhttp_mode", "auto")}
        if opts.get("path"):
            xh["path"] = opts["path"]
        if opts.get("host"):
            xh["host"] = opts["host"]
        ss["xhttpSettings"] = xh

    elif transport == "grpc":
        gs = {"serviceName": opts.get("grpc_service", "GunService")}
        if opts.get("multi_mode"):
            gs["multiMode"] = True
        ss["grpcSettings"] = gs

    elif transport == "httpupgrade":
        hu = {}
        if opts.get("path"):
            hu["path"] = opts["path"]
        if opts.get("host"):
            hu["host"] = opts["host"]
        if hu:
            ss["httpupgradeSettings"] = hu

    return ss


# 协议必填项 → (选项名, 界面文案)
REQUIRED = {
    "vless":       [],
    "vmess":       [],
    "trojan":      [("password", "密码")],
    "shadowsocks": [("method", "加密方式"), ("password", "密码")],
    "hysteria2":   [("password", "密码")],
    "socks":       [],
    "http":        [],
}


# Shadowsocks 2022 的密码必须是精确长度的 base64。生成时随手截断出来的长度
# 几乎一定不合法, 而内核要等到 run -test 才报错 —— 那时候用户已经填完一堆
# 参数、部署完 nginx 了。这里提前拦。
#   16 字节 → base64 24 字符 (aes-128-gcm)
#   32 字节 → base64 44 字符 (aes-256-gcm / chacha20-poly1305)
SS2022_LENGTH = {
    "2022-blake3-aes-128-gcm": 24,
    "2022-blake3-aes-256-gcm": 44,
    "2022-blake3-chacha20-poly1305": 44,
}
# 非 2022 的传统加密对密码长度没有硬性要求 (任意长度经 KDF 派生), 但要拦
# 未知的 method —— 写错了内核会当成不支持的协议, 报错难懂。
SS_LEGACY_METHODS = ("aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
                     "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
                     "chacha20-ietf", "xchacha20-ietf-poly1305",
                     "none", "plain")


def _check_ss(method, password):
    """校验 Shadowsocks 的 method 与密码是否匹配。"""
    import base64 as _b64
    if method in SS2022_LENGTH:
        need = SS2022_LENGTH[method]
        got = len(password or "")
        if got != need:
            raise NodeError(
                f"Shadowsocks 2022 的 {method} 要求 {need} 个字符的 base64 密码"
                f" (原文 16/32 字节经 base64), 当前 {got} 个。"
            )
        try:
            _b64.b64decode(password, validate=True)
        except Exception:
            raise NodeError(
                "Shadowsocks 2022 的密码必须是合法 base64 (A-Za-z0-9+/=), "
                "当前含非法字符。"
            )
    elif method not in SS_LEGACY_METHODS:
        raise NodeError(
            f"未知的 Shadowsocks 加密方式: {method}。常用: "
            f"{', '.join(list(SS2022_LENGTH)[:2])} 或 aes-256-gcm"
        )


def _check_reality(opts):
    """REALITY 密钥必须是 x25519 生成的 base64url。

    只检查"有没有"不够: 非交互场景下 read 可能把脚本自己的输入读成密钥
    (实测拿到过 `echo "  ═══ 校验 ═══"` 这种内容), 原样写进配置后内核才报
    invalid privateKey —— 而配置里躺着的是一句 shell 片段, 排查时很难看出
    根因。按形状提前拦。
    """
    import re as _re
    pat = _re.compile(r"^[A-Za-z0-9_-]{43,44}$")
    pk = opts.get("private_key") or ""
    pb = opts.get("public_key") or ""
    if not pk:
        raise NodeError("REALITY 需要私钥 (opts['private_key'])。生成: xray x25519")
    if not pat.match(pk):
        raise NodeError(
            f"REALITY 私钥格式不对: {pk[:40]!r}。x25519 私钥是 43-44 个字符的 "
            f"base64url (A-Za-z0-9_-)。生成: xray x25519"
        )
    if not pb:
        raise NodeError("REALITY 需要公钥 (opts['public_key'])。分享链接要用 —— "
                        "缺了客户端会静默丢弃这个节点, 零报错。")
    if not pat.match(pb):
        raise NodeError(f"REALITY 公钥格式不对: {pb[:40]!r}。与私钥同格式。")


def _settings(protocol, opts):
    """协议级 settings。"""
    if protocol == "vless":
        client = {"id": opts.get("uuid") or str(_uuid.uuid4())}
        if opts.get("flow"):
            client["flow"] = opts["flow"]
        if opts.get("encryption"):
            return {"clients": [client], "decryption": opts["encryption"]}
        return {"clients": [client], "decryption": "none"}

    if protocol == "vmess":
        return {"clients": [{"id": opts.get("uuid") or str(_uuid.uuid4()),
                             "alterId": 0}]}

    if protocol == "trojan":
        return {"clients": [{"password": opts["password"]}]}

    if protocol == "shadowsocks":
        return {"method": opts["method"], "password": opts["password"]}

    if protocol == "hysteria2":
        # Xray 的 hysteria2 inbound 用的是 protocol="hysteria" + version=2,
        # 不是 protocol="hysteria2"。写成 "hysteria2" 内核报
        # unknown config id: hysteria2 —— 它根本不认识这个名字。
        # 凭据字段也�� clients[].auth, 不是 clients[].password。
        return {"version": 2, "clients": [{"auth": opts["password"]}]}

    if protocol in ("socks", "http"):
        return {"auth": opts.get("auth", "noauth")}

    raise NodeError(f"未知协议: {protocol}")


def build(protocol, transport, security, opts=None):
    """按规格生成 inbound dict。

    返回 {"inbounds": [ ... ]}, 可直接写成片段文件。
    """
    opts = dict(opts or {})
    # listen 与 tag 可以有默认值, port 不行 —— 默认 443 会让"忘了填端口"
    # 悄悄绑到 443, 而 443 通常已经被 nginx 或别的节点占着, 于是报出的
    # 错误是"端口被占用", 与真正的原因无关。
    opts.setdefault("listen", "0.0.0.0")
    opts.setdefault("tag", f"{protocol}-{transport}-{security}")

    _check_combo(protocol, transport, security)

    # 必填校验放在生成之前。直接让 _settings 取 opts["password"] 的话, 缺参数
    # 抛的是 KeyError: 'password' —— 用户看到的是 Python 内部错误, 不知道
    # 该去补什么。
    if not opts.get("port"):
        raise NodeError("缺少端口")
    if protocol not in REQUIRED:
        raise NodeError(f"未知协议: {protocol}")
    for key, label in REQUIRED[protocol]:
        if not opts.get(key):
            raise NodeError(f"{protocol} 需要{label} (opts['{key}'])")
    if security == "reality":
        _check_reality(opts)
    if protocol == "shadowsocks":
        _check_ss(opts.get("method"), opts.get("password"))

    inbound = {
        "listen": opts["listen"],
        "port": int(opts["port"]),
        # hysteria2 是协议族名, 内核侧的 inbound id 是 "hysteria" + version=2
        "protocol": ("hysteria" if protocol == "hysteria2" else protocol),
        "settings": _settings(protocol, opts),
        "streamSettings": _stream_settings(transport, security, opts),
    }
    if opts.get("tag"):
        inbound["tag"] = opts["tag"]
    return {"inbounds": [inbound]}


def write(path, spec, indent=2):
    """生成并原子写入片段文件。

    原子写的原因: 片段文件正被 xray 加载着, 写到一半中断会留下半个 JSON,
    之后每次读都失败 —— 表现是"所有节点管理功能全挂了"。

    临时文件名用 mkstemp 而不是拼 "{path}.tmp.{pid}": 拼的名字在同一进程的
    多线程里会撞 —— 两个线程算出同一个临时名, 互相 os.replace 对方的文件,
    后一个拿到 FileNotFoundError。mkstemp 保证唯一, 且落在同目录 (跨目录
    rename 不保证原子)。
    """
    data = json.dumps(spec, ensure_ascii=False, indent=indent)
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".frag-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return data
def describe(protocol, transport, security):
    """一行说明, 给菜单和日志用。"""
    sec = {"none": "无", "tls": "TLS", "reality": "REALITY"}.get(security, security)
    tr = {"tcp": "TCP", "raw": "TCP", "ws": "WebSocket", "xhttp": "XHTTP",
          "grpc": "gRPC", "httpupgrade": "HTTPUpgrade"}.get(transport, transport)
    return f"{protocol.upper()} + {tr} + {sec}"
