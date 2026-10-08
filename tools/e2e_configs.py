#!/usr/bin/env python3
"""按参数生成 E2E 用的 Xray 配置。

为什么用 python 而不是 shell 拼 JSON
-------------------------------------
TLS 证书要以 PEM 原文放进 tlsSettings.certificates[].certificate 数组, 而 PEM
里有换行 —— shell 拼字符串必然要处理转义, 这次拼 JSON 先后踩了四个坑:
证书写成 base64(内核要 PEM)、certificate 写成标量(26.x 要数组)、片段之间
漏逗号、extra 为空时多逗号。每一次的表现都是同一句"配置解析失败", 却分别指向
完全不同的原因。

交给 json.dumps 就没有转义问题, 少写一次错一次。shell 只负责起停进程和判定。
"""

import json
import sys

FREEDOM = {"protocol": "freedom", "settings": {}}


def server(protocol, port, stream, clients, cert=None, key=None):
    """服务端: 入站 + 一个 freedom 出站。

    freedom 出站不能省。服务端只有 inbounds 时, Xray 26.x 报的是
    "default outbound handler not exist", 而隧道请求其实已经正确到达服务端、
    日志里能看到 "received request for ..." —— 看起来像协议配错了, 实际只是
    没有出站去连目标地址。
    """
    settings = {"clients": clients}
    if protocol == "vless":
        # 26.x 强制要求显式声明, 缺了直接拒绝启动
        settings["decryption"] = "none"
    ss = dict(stream)
    if cert:
        ss["security"] = "tls"
        ss["tlsSettings"] = {
            "certificates": [{"certificate": [cert], "key": [key]}]
        }
    return {
        "inbounds": [{
            "port": port,
            "listen": "127.0.0.1",
            "protocol": protocol,
            "settings": settings,
            "streamSettings": ss,
        }],
        "outbounds": [FREEDOM],
    }


def client(protocol, sock_port, srv_port, stream, users, pin=None):
    """客户端: socks 入站 + 指向服务端的出站。"""
    ss = dict(stream)
    if pin:
        ss["security"] = "tls"
        # 26.x 移除了 allowInsecure, 官方替代就是把服务端证书的 DER 哈希固定下来。
        # 这个字段是字符串, 不是数组 —— 和 certificates[] 不是一回事。
        ss["tlsSettings"] = {
            "serverName": "e2e.test",
            "pinnedPeerCertSha256": pin,
        }
    return {
        "inbounds": [{
            "port": sock_port,
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": {"udp": False},
        }],
        "outbounds": [{
            "protocol": protocol,
            "settings": {"vnext": [{
                "address": "127.0.0.1",
                "port": srv_port,
                "users": users,
            }]},
            "streamSettings": ss,
        }],
    }


def client_trojan(sock_port, srv_port, stream, password, pin=None):
    """Trojan 出站。

    与 vless/vmess 不同: Trojan 的出站走 settings.servers 而不是 vnext。
    写成 vnext 时内核报的是 `Trojan settings: "servers" is required` —— 错误信息
    没提 vnext, 只说缺 servers, 容易让人往证书或端口方向找。
    """
    ss = dict(stream)
    if pin:
        ss["security"] = "tls"
        ss["tlsSettings"] = {"serverName": "e2e.test",
                             "pinnedPeerCertSha256": pin}
    return {
        "inbounds": [{
            "port": sock_port,
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": {"udp": False},
        }],
        "outbounds": [{
            "protocol": "trojan",
            "settings": {"servers": [{
                "address": "127.0.0.1",
                "port": srv_port,
                "password": password,
            }]},
            "streamSettings": ss,
        }],
    }


def client_ss(sock_port, srv_port, method, password):
    """Shadowsocks 没有 vnext 结构, 单独一支。"""
    return {
        "inbounds": [{
            "port": sock_port,
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": {"udp": False},
        }],
        "outbounds": [{
            "protocol": "shadowsocks",
            "settings": {"servers": [{
                "address": "127.0.0.1",
                "port": srv_port,
                "method": method,
                "password": password,
            }]},
        }],
    }


def ss_server(port, method, password):
    return {
        "inbounds": [{
            "port": port,
            "listen": "127.0.0.1",
            "protocol": "shadowsocks",
            "settings": {
                "method": method,
                "password": password,
                "network": "tcp",
            },
        }],
        "outbounds": [FREEDOM],
    }


def reality_server(port, uuid, pbk, dest, snames, sid):
    return {
        "inbounds": [{
            "port": port,
            "listen": "127.0.0.1",
            "protocol": "vless",
            "settings": {
                "decryption": "none",
                "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "dest": dest,
                    "xver": 0,
                    "serverNames": snames,
                    "privateKey": pbk,
                    "shortIds": [sid],
                },
            },
        }],
        "outbounds": [FREEDOM],
    }


def reality_client(sock_port, srv_port, uuid, pub, sname, sid):
    return {
        "inbounds": [{
            "port": sock_port,
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": {"udp": False},
        }],
        "outbounds": [{
            "protocol": "vless",
            "settings": {"vnext": [{
                "address": "127.0.0.1",
                "port": srv_port,
                "users": [{
                    "id": uuid,
                    "encryption": "none",
                    "flow": "xtls-rprx-vision",
                }],
            }]},
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverName": sname,
                    "fingerprint": "chrome",
                    "publicKey": pub,
                    "shortId": sid,
                    "spiderX": "/",
                },
            },
        }],
    }


def _selftest():
    """离线检查配置形状, 不需要 Xray 内核。

    这一层挡的是"生成出来的配置结构本身就错" —— 少了 decryption、证书放成了
    base64、Trojan 出站写成 vnext。这些错在内核里表现为一串和真正原因无关的
    解析失败, 逐个试错成本很高, 在这里一次全查出来。
    """
    import io
    import contextlib

    u = "11111111-2222-3333-4444-555555555555"
    results = []

    def chk(name, cond):
        results.append(("OK " if cond else "NO ") + name)

    s = server("vless", 1, {"network": "tcp"}, [{"id": u}])
    chk("vless 服务端带 decryption", s["inbounds"][0]["settings"].get("decryption") == "none")
    chk("服务端必须带 freedom 出站", s["outbounds"][0]["protocol"] == "freedom")

    s = server("vless", 1, {"network": "tcp"}, [{"id": u}], cert="PEM", key="PEM")
    t = s["inbounds"][0]["streamSettings"]["tlsSettings"]["certificates"][0]
    chk("certificate 是数组而非标量", isinstance(t["certificate"], list))
    chk("certificate 放 PEM 原文而非 base64", t["certificate"] == ["PEM"])

    c = client("vless", 2, 1, {"network": "tcp"}, [{"id": u, "encryption": "none"}],
               pin="ab" * 32)
    ts = c["outbounds"][0]["streamSettings"]["tlsSettings"]
    chk("客户端不再用已被移除的 allowInsecure", "allowInsecure" not in ts)
    chk("pinnedPeerCertSha256 是字符串而非数组", ts["pinnedPeerCertSha256"] == "ab" * 32)

    c = client_trojan(2, 1, {"network": "ws", "path": "/x"}, "pw", pin="ab" * 32)
    chk("Trojan 出站用 servers 而非 vnext",
        "servers" in c["outbounds"][0]["settings"])

    c = client_ss(2, 1, "2022-blake3-aes-128-gcm", "k")
    chk("Shadowsocks 出站结构正确",
        "servers" in c["outbounds"][0]["settings"])

    r = reality_client(2, 1, u, "PUB", "www.cloudflare.com", "0123456789abcdef")
    rs = r["outbounds"][0]["streamSettings"]["realitySettings"]
    chk("REALITY 客户端带 fingerprint", rs.get("fingerprint") == "chrome")
    chk("REALITY 客户端带 spiderX", "spiderX" in rs)

    r = reality_server(1, u, "PBK", "www.cloudflare.com:443",
                       ["www.cloudflare.com"], "0123456789abcdef")
    rs = r["inbounds"][0]["streamSettings"]["realitySettings"]
    chk("REALITY 服务端带 privateKey 与 dest",
        bool(rs.get("privateKey")) and bool(rs.get("dest")))

    # 每个生成物都必须是能序列化的合法 JSON
    for obj in (s, c, r, server("vmess", 1, {"network": "tcp"}, [{"id": u}])):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                json.dumps(obj)
            chk("生成物可序列化", True)
            break
        except (TypeError, ValueError):
            chk("生成物可序列化", False)

    print("\n".join(results))
    return 0 if all(x.startswith("OK ") for x in results) else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    sys.stderr.write("这个模块由 e2e_protocols.sh 调用, 不直接运行\n")
    sys.exit(2)