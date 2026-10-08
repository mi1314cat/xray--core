#!/usr/bin/env python3
"""Xray 节点注册表 —— 从 conf/ 片段抽取统一节点视图。

为什么需要
----------
各协议脚本各自往 conf/ 写一个 JSON 片段, 字段差异很大:

    VLESS       settings.clients[0].id
    Trojan      settings.clients[0].password
    Shadowsocks settings.password          (单用户, 没有 clients 数组)
    hysteria2   settings.clients[0].password

分享、分发、列表、删除联动都要"这个节点是什么", 所以这里把差异收敛到一处。
以后加协议只需要在这里加一个抽取器, 不用改分享、UI、删除联动。

刻意不做的事
------------
不解析 streamSettings 里的细节来"猜"节点身份 —— 那些字段每个协议含义不同,
猜出来的结果不可信。这里只读有确定语义的部分。
"""

import base64
import glob
import json
import os
import sys


def _client_field(inbound, field):
    """从 inbound 里取客户端凭据, 兼容有 clients 数组和单用户两种写法。"""
    settings = inbound.get("settings") or {}
    clients = settings.get("clients")
    if isinstance(clients, list) and clients:
        c = clients[0]
        if isinstance(c, dict):
            # hysteria2 的 inbound 是 protocol=hysteria + version=2, 凭据字段
            # 叫 auth 而不是 password —— 不带这一条的话 hysteria2 节点的
            # 凭据全是 None, 分享链接生成不出来。
            return (c.get(field) or c.get("password") or c.get("auth")
                    or c.get("id"))
    # Shadowsocks / Socks / HTTP 是单用户形态
    return settings.get("password") or settings.get("auth")


def extract(inbound, source_file):
    """从单个 inbound 抽出统一节点视图。"""
    if not isinstance(inbound, dict):
        return None
    ss = inbound.get("streamSettings") or {}
    tls = ss.get("tlsSettings") or {}
    reality = ss.get("realitySettings") or {}
    ws = ss.get("wsSettings") or {}
    xhttp = ss.get("xhttpSettings") or {}

    proto = inbound.get("protocol")
    node = {
        # ---- 身份 ----
        "tag": inbound.get("tag") or os.path.basename(source_file).rsplit(".", 1)[0],
        "source": os.path.basename(source_file),
        # ---- 协议/传输/加密 ----
        "protocol": proto,
        "network": ss.get("network"),
        "security": ss.get("security"),
        "flow": ((inbound.get("settings") or {}).get("clients") or [{}])[0].get("flow")
        if isinstance((inbound.get("settings") or {}).get("clients"), list)
        and (inbound.get("settings") or {}).get("clients") else None,
        # ---- 监听 ----
        "listen": inbound.get("listen"),
        "port": inbound.get("port"),
        # ---- 凭据 (按协议取) ----
        "id": _client_field(inbound, "id"),
        "password": _client_field(inbound, "password"),
        "method": (inbound.get("settings") or {}).get("method"),
        "decryption": (inbound.get("settings") or {}).get("decryption"),
        # ---- 服务名 (分享/分发时客户端要显示) ----
        "server_names": reality.get("serverNames") or [],
        "path": ws.get("path") or xhttp.get("path") or "",
        "sni": None,
        # ---- 证书 ----
        "cert_files": [
            c.get("certificateFile")
            for c in (tls.get("certificates") or [])
            if isinstance(c, dict) and c.get("certificateFile")
        ],
    }

    sni = node["server_names"]
    if sni:
        node["sni"] = sni[0]
    return node


def collect(conf_dir):
    """遍历 conf/ 下所有片段, 返回节点列表。

    坏文件跳过而不是整体失败 —— 一个写坏的文件不该让分享/列表全线失效,
    更不该把已经能用的节点一起藏起来。
    """
    nodes, bad = [], []
    for f in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception as e:  # noqa: BLE001 — 片段是用户可写的, 什么错都可能
            bad.append((os.path.basename(f), str(e)[:120]))
            continue
        if not isinstance(d, dict):
            bad.append((os.path.basename(f), "顶层不是对象"))
            continue
        for ib in d.get("inbounds") or []:
            n = extract(ib, f)
            if n:
                nodes.append(n)
    return nodes, bad


def main():
    conf_dir = sys.argv[1] if len(sys.argv) > 1 else "/root/catmi/xray/conf"
    fmt = sys.argv[2] if len(sys.argv) > 2 else "table"
    nodes, bad = collect(conf_dir)

    if fmt == "json":
        print(json.dumps({"nodes": nodes, "unreadable": bad}, ensure_ascii=False, indent=2))
        return 0

    if not nodes:
        print(f"没有节点 (扫描了 {conf_dir})", file=sys.stderr)
    else:
        w = max(len(n["tag"] or "") for n in nodes)
        print(f"{'TAG'.ljust(w)}  {'协议':<12} {'端口':<7} {'传输':<8} {'加密':<10} 凭据")
        for n in nodes:
            cred = n["id"] or n["password"] or n["method"] or "-"
            cred = cred[:24]
            print(
                f"{(n['tag'] or '').ljust(w)}  {str(n['protocol']):<12} "
                f"{str(n['port'] or '-'):<7} {str(n['network'] or '-'):<8} "
                f"{str(n['security'] or '-'):<10} {cred}"
            )
    for f, e in bad:
        print(f"[跳过] {f}: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

# ================================================================ 分享链接
def _q(v):
    """URL 查询串里的值转义。分享链接里最容易出错的就是这个。

    路径里的 base64 / ML-KEM 字符串含 '+' '/' '=' , 不转义会被解析器当成
    别的含义 —— 症状是"链接生成对了但客户端连不上"。
    """
    if v is None:
        return ""
    out = []
    safe = set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~"
    )
    for b in str(v).encode():
        c = chr(b)
        out.append(c if c in safe else f"%{b:02X}")
    return "".join(out)


def _qval(v):
    """值里的空格和 + 需要显式处理成 %20 / %2B, _q 已经覆盖了。"""
    return _q(v)


def build_share_link(n, meta=None):
    """从节点视图生成 Xray 分享链接。

    meta 是 conf/lib/share_meta.py 的记录, 提供片段里没有的字段
    (REALITY 公钥、VLESS encryption、对外地址、显示名)。
    """
    meta = meta or {}
    proto = n.get("protocol")
    host = meta.get("host") or n.get("sni") or ""
    port = meta.get("port") or n.get("port")
    name = meta.get("name") or n.get("tag") or ""

    # 显示名不能为空。Client 的解析器是 `name = fragment or hostname`
    # (Client/lib/node.py:121) —— 没有 fragment 就退化成域名, 于是同一域名
    # 下的所有节点在列表里名字完全一样, 用户分不清谁是谁。
    # 兜底到端口, 保证任何情况下 fragment 都非空。
    if not name:
        name = f"{proto or 'node'}-{port or 'x'}"

    if not host or not port:
        # 没有对外地址就没法生成分享链接 —— 但不静默返回 None 让上层
        # 以为"节点不存在", 这里显式区分。
        return None

    if proto == "vless":
        # REALITY 缺公钥的链接是残缺的。Client 的能力检查会判
        # "security=reality 但缺少 pbk" 而静默丢弃该节点 (compat.py),
        # 表现是"分享了 4 个节点客户端只收到 3 个"且没有任何报错。
        # 生成一条连不上的链接比不生成更糟 —— 用户会以为已经分享成功了。
        if n.get("security") == "reality" and not meta.get("public_key"):
            return None
        q = {
            "encryption": meta.get("encryption", "none"),
            "security": n.get("security") or "none",
            "type": n.get("network") or "tcp",
        }
        if n.get("flow"):
            q["flow"] = n["flow"]
        if n.get("security") == "reality":
            if n.get("server_names"):
                q["sni"] = n["server_names"][0]
            q["fp"] = meta.get("fingerprint", "chrome")
            if meta.get("short_id"):
                q["sid"] = meta["short_id"]
            if meta.get("public_key"):
                q["pbk"] = meta["public_key"]
            q["spx"] = meta.get("spx", "")
        elif n.get("security") == "tls":
            if n.get("sni"):
                q["sni"] = n["sni"]
            if n.get("path"):
                q["path"] = n["path"]
            if n.get("network") == "ws":
                q["host"] = meta.get("host_header", "")
        qs = "&".join(f"{k}={_qval(v)}" for k, v in q.items() if v not in (None, ""))
        return f"vless://{n.get('id') or ''}@{_q(host)}:{port}?{qs}#{_q(name)}"

    if proto == "trojan":
        if n.get("security") == "reality" and not meta.get("public_key"):
            return None
        q = {"security": n.get("security") or "none", "type": n.get("network") or "tcp"}
        if n.get("security") == "reality":
            if n.get("server_names"):
                q["sni"] = n["server_names"][0]
            q["fp"] = meta.get("fingerprint", "chrome")
            if meta.get("short_id"):
                q["sid"] = meta["short_id"]
            if meta.get("public_key"):
                q["pbk"] = meta["public_key"]
        elif n.get("security") == "tls":
            if n.get("sni"):
                q["sni"] = n["sni"]
            if n.get("network") == "ws" and n.get("path"):
                # 原样放进 q, 转义交给下面的 _qval 统一做 ——
                # 这里再 _q 一次会变成 %252F, 路径里出现字面量 "%252F"。
                q["path"] = n["path"]
        qs = "&".join(f"{k}={_qval(v)}" for k, v in q.items() if v not in (None, ""))
        return f"trojan://{_q(n.get('password') or '')}@{_q(host)}:{port}?{qs}#{_q(name)}"

    if proto == "shadowsocks":
        # SIP002: ss://<base64(method:password)>@host:port#name
        userinfo = base64.urlsafe_b64encode(
            f"{n.get('method') or ''}:{n.get('password') or ''}".encode()
        ).decode().rstrip("=")
        return f"ss://{userinfo}@{_q(host)}:{port}#{_q(name)}"

    if proto in ("hysteria2", "hy2", "hysteria"):
        # 内核侧的 inbound protocol 是 "hysteria" (配 settings.version=2),
        # 而分享链接的 scheme 必须写 hysteria2://。所以匹配时要把
        # "hysteria" 也算进来 —— 漏了它, 内核实机跑出来的 hysteria2 节点
        # 一个都生成分享链接。
        q = {"sni": meta.get("host") or "", "insecure": "0"}
        if meta.get("alpn"):
            q["alpn"] = meta["alpn"]
        qs = "&".join(f"{k}={_qval(v)}" for k, v in q.items() if v)
        return f"hysteria2://{_q(n.get('password') or n.get('id') or '')}@{_q(host)}:{port}?{qs}#{_q(name)}"

    if proto in ("socks", "http"):
        # socks5:// 与 http:// 是标准 URI 形态。Client 的 scheme 白名单里
        # 没有这两个 (它只认 vless/vmess/trojan/ss/hysteria2), 所以生成了
        # 对方也不收 —— 但它们仍可能有别的客户端用, 不该在这里直接吞掉。
        scheme = "socks5" if proto == "socks" else "http"
        # settings.auth 是 "noauth"/"password" 这种模式名, 不是用户名。
        # 当成用户名会生成 socks5://noauth@host:443 —— 客户端会拿 "noauth"
        # 去当密码, 认证必然失败。真正的用户名在 settings.accounts[0].user,
        # 由 _client_field 取不到, 所以这里只在有真实账号时才写 userinfo。
        accounts = (n.get("_accounts") or [])
        user = accounts[0] if accounts and accounts[0] not in ("noauth", "") else ""
        auth = f"{_q(user)}@" if user else ""
        return f"{scheme}://{auth}{_q(host)}:{port}#{_q(name)}"

    if proto in ("vmess",):
        # vmess:// 是 base64 的 JSON, 不是标准 URI
        obj = {
            "v": "2", "ps": name, "add": host, "port": str(port),
            "id": n.get("id") or "", "aid": "0",
            "net": n.get("network") or "tcp",
            "type": "none", "host": "", "path": n.get("path") or "",
            "tls": "tls" if n.get("security") in ("tls", "reality") else "",
            "sni": n.get("sni") or "",
        }
        b = base64.b64encode(json.dumps(obj, ensure_ascii=False).encode()).decode()
        return f"vmess://{b}"

    return None
