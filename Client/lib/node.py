#!/usr/bin/env python3
"""统一节点模型与多协议解析器（仅标准库）。

设计原则（对应需求第十二条）：
    解析阶段**尽可能完整保留**所有参数，即使 Browser Dialer 用不到。
    "能不能用"是后续能力的判断，不在解析阶段丢信息。

统一模型字段命名尽量贴近 Xray 的 streamSettings，便于直接生成配置。

支持输入：
    vless://  vmess://  trojan://  ss://  hysteria2://  hy2://
    Xray JSON 配置          Mihomo YAML 节点
    订阅 URL（多个节点换行分隔，或 base64 编码的列表）
"""
from __future__ import annotations

import base64
import binascii
import os
import json
import re
import sys
import urllib.parse

# ---------------------------------------------------------------------------
# 内部模型
# ---------------------------------------------------------------------------
DEFAULT_NODE = {
    "name": "",
    "protocol": "",            # vless / vmess / trojan / shadowsocks / hysteria2
    "address": "",
    "port": 0,
    "uuid": "",
    "password": "",
    "method": "",              # shadowsocks 加密方式
    "encryption": "none",      # vless 的 encryption
    "flow": "",
    "transport": "",           # xhttp / websocket / tcp / grpc / h2 / httpupgrade
    "transport_raw": "",
    "security": "none",        # tls / reality / none
    "sni": "",
    "alpn": "",
    "fingerprint": "",
    "allow_insecure": False,
    "path": "",
    "host": "",
    "mode": "",                # xhttp mode
    # WebSocket early data 长度。0 = 不启用。
    # 官方 browser_dialer 文档推荐 ?ed=2048；实测定量结论：
    #   浏览器路径下若没有 ed，内嵌页面会读 task.extra.protocol 抛 TypeError（extra 是空的），
    #   于是 ws 节点在浏览器路径下**必然失败**；加上 ed 后立刻可用。
    #   原生路径下有没有 ed 都能用，所以加上不会造成回归。
    "ws_ed": 0,
    "extra": "",               # xhttp extra
    "service_name": "",        # grpc
    "header_type": "",         # tcp 伪装
    "reality_public_key": "",
    "reality_short_id": "",
    "reality_spider_x": "",
    # ECHConfigList 原文（不是布尔）。官方 tlsSettings.echConfigList 支持两种格式：
    #   固定值 "AF7+DQBaAAAg…" / DNS 查询式 "example.com+https://1.1.1.1/dns-query"
    # 走 CDN 时是后者 —— 必须原样下发，只记"有没有"等于没配。
    "ech": "",
    "ech_declared": False,     # 来源声明了 ECH 但没给出可用配置（只有 mihomo 的 enable 会这样）
    "pinned_cert_sha256": "",  # 自签证书节点的证书哈希（Xray 26.x 的 allowInsecure 替代）
    # mux：**只表示 Xray 自己的 mux.cool**。见 parse_mihomo_yaml 里对 smux 的说明 ——
    # 那是 sing-box/mihomo 的另一套多路复用协议，不能混为一谈。
    "mux": False,
    "smux": False,             # mihomo/sing-box 的 SMUX（来源原生意图，不冒充 mux.cool）
    "udp": True,
    "source": "",              # 来源格式，便于排查
    "raw_params": {},          # 原始 query，一个都不丢
    "raw": "",                 # 原始字符串/片段
    # 这个节点是否用浏览器完成 TLS。这是**每个节点各自的属性**，不是全局模式：
    #     None  = 默认（协议支持就用浏览器，不支持就用 Xray 自带 TLS）
    #     True  = 强制用浏览器
    #     False = 强制不用（即使协议支持）
    # 为什么不做成全局开关：全局关掉会让**所有**依赖浏览器的节点一起失效（实测踩过）。
    "use_browser": None,
}

_TRANSPORT_ALIASES = {
    "xhttp": "xhttp", "splithttp": "xhttp",
    "ws": "websocket", "websocket": "websocket",
    "tcp": "tcp", "raw": "tcp",
    "grpc": "grpc", "gun": "grpc",
    "h2": "h2", "http": "h2",
    "httpupgrade": "httpupgrade",
    "mkcp": "mkcp", "kcp": "mkcp",
    "quic": "quic",
}


def new_node() -> dict:
    return dict(DEFAULT_NODE)


def _b64decode(s: str) -> str:
    """宽松的 base64 解码：兼容 urlsafe、缺失 padding、换行。"""
    s = s.strip().replace("\n", "").replace("\r", "")
    s = s.replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    try:
        return base64.b64decode(s).decode("utf-8", "replace")
    except (binascii.Error, ValueError):
        return ""


def _norm_transport(raw: str) -> str:
    return _TRANSPORT_ALIASES.get((raw or "").lower(), (raw or "").lower())


def _flag(v) -> bool:
    """把各种"开关"写法归一成 bool。

    ★ 字典必须读 `enabled` 而不是直接 bool()：`{"enabled": false}` 是个**非空
    字典**，`bool()` 恒为真 —— 明确关掉的开关会被读成"要开"。
    """
    if isinstance(v, dict):
        return bool(v.get("enabled", False))
    if isinstance(v, str):
        return v.strip().lower() not in ("", "0", "false", "no", "off")
    return bool(v)


def _q(params: dict) -> dict:
    """把 parse_qs 的 {k: [v]} 压平为 {k: v}。"""
    return {k: (v[0] if isinstance(v, list) and v else "") for k, v in (params or {}).items()}


# ---------------------------------------------------------------------------
# 各协议解析
# ---------------------------------------------------------------------------
def parse_vless(uri: str) -> dict:
    u = urllib.parse.urlparse(uri)
    if not u.hostname:
        raise ValueError("VLESS 链接缺少地址")
    q = _q(urllib.parse.parse_qs(u.query, keep_blank_values=True))
    n = new_node()
    n.update({
        "name": urllib.parse.unquote(u.fragment) or u.hostname,
        "protocol": "vless",
        "uuid": urllib.parse.unquote(u.username or ""),
        "address": u.hostname,
        "port": u.port or 443,
        "encryption": q.get("encryption", "none"),
        "security": (q.get("security") or "none").lower(),
        "sni": q.get("sni") or q.get("serverName") or "",
        "host": q.get("host") or "",
        "path": q.get("path") or "",
        "mode": q.get("mode") or "",
        "extra": q.get("extra") or "",
        "flow": q.get("flow") or "",
        "fingerprint": q.get("fp") or "",
        "alpn": q.get("alpn") or "",
        "service_name": q.get("serviceName") or "",
        "header_type": q.get("headerType") or "",
        "reality_public_key": q.get("pbk") or "",
        "reality_short_id": q.get("sid") or "",
        "reality_spider_x": q.get("spx") or "",
        "allow_insecure": str(q.get("allowInsecure", "")).lower() in ("1", "true"),
        "ech": (q.get("ech") or "").strip(),
        "ech_declared": bool(q.get("ech")),
        "source": "vless-uri",
        "raw_params": q,
        "raw": uri,
    })
    n["transport_raw"] = (q.get("type") or "tcp").lower()
    n["transport"] = _norm_transport(n["transport_raw"])
    return n


def parse_vmess(uri: str) -> dict:
    """vmess://<base64 json>"""
    body = uri.split("://", 1)[1]
    txt = _b64decode(body)
    if not txt.strip().startswith("{"):
        raise ValueError("vmess 链接不是有效的 base64 JSON")
    d = json.loads(txt)
    n = new_node()
    n.update({
        "name": d.get("ps") or d.get("add", "vmess"),
        "protocol": "vmess",
        "uuid": d.get("id", ""),
        "address": d.get("add", ""),
        "port": int(d.get("port") or 443),
        "encryption": d.get("scy") or "auto",
        "security": "tls" if str(d.get("tls", "")).lower() in ("tls", "true", "1") else "none",
        "sni": d.get("sni") or d.get("host") or "",
        "host": d.get("host") or "",
        "path": d.get("path") or "",
        "service_name": d.get("path") or "",
        "fingerprint": d.get("fp") or "",
        "alpn": d.get("alpn") or "",
        "header_type": d.get("type") or "",
        "source": "vmess-uri",
        "raw_params": d,
        "raw": uri,
    })
    n["transport_raw"] = (d.get("net") or "tcp").lower()
    n["transport"] = _norm_transport(n["transport_raw"])
    return n


def parse_trojan(uri: str) -> dict:
    u = urllib.parse.urlparse(uri)
    if not u.hostname:
        raise ValueError("Trojan 链接缺少地址")
    q = _q(urllib.parse.parse_qs(u.query, keep_blank_values=True))
    n = new_node()
    n.update({
        "name": urllib.parse.unquote(u.fragment) or u.hostname,
        "protocol": "trojan",
        "password": urllib.parse.unquote(u.username or ""),
        "address": u.hostname,
        "port": u.port or 443,
        # Trojan 默认就是 TLS
        "security": (q.get("security") or "tls").lower(),
        "sni": q.get("sni") or q.get("peer") or "",
        "host": q.get("host") or "",
        "path": q.get("path") or "",
        "service_name": q.get("serviceName") or "",
        "fingerprint": q.get("fp") or "",
        "alpn": q.get("alpn") or "",
        "allow_insecure": str(q.get("allowInsecure", "")).lower() in ("1", "true"),
        "source": "trojan-uri",
        "raw_params": q,
        "raw": uri,
    })
    n["transport_raw"] = (q.get("type") or "tcp").lower()
    n["transport"] = _norm_transport(n["transport_raw"])
    return n


def parse_shadowsocks(uri: str) -> dict:
    """支持 SIP002 (ss://base64(method:pass)@host:port) 与旧式 ss://base64(全部)。"""
    body = uri.split("://", 1)[1]
    q, _, frag = body.partition("#")
    name = urllib.parse.unquote(frag)
    q, _, query = q.partition("?")
    params = _q(urllib.parse.parse_qs(query, keep_blank_values=True))

    if "@" in q:
        userinfo, hostpart = q.rsplit("@", 1)
        cred = _b64decode(userinfo) if ":" not in userinfo else urllib.parse.unquote(userinfo)
    else:
        decoded = _b64decode(q)
        if "@" not in decoded:
            raise ValueError("ss 链接格式无法识别")
        cred, hostpart = decoded.rsplit("@", 1)

    method, _, password = cred.partition(":")
    hostpart = hostpart.split("/")[0]
    if hostpart.startswith("["):          # IPv6
        host, _, port = hostpart.rpartition("]:")
        host = host.lstrip("[")
    else:
        host, _, port = hostpart.rpartition(":")

    n = new_node()
    n.update({
        "name": name or host,
        "protocol": "shadowsocks",
        "method": method,
        "password": password,
        "address": host,
        "port": int(port or 8388),
        "security": "none",
        "source": "ss-uri",
        "raw_params": params,
        "raw": uri,
    })
    n["transport_raw"] = "tcp"
    n["transport"] = "tcp"
    return n


def parse_hysteria2(uri: str) -> dict:
    u = urllib.parse.urlparse(uri)
    if not u.hostname:
        raise ValueError("Hysteria2 链接缺少地址")
    q = _q(urllib.parse.parse_qs(u.query, keep_blank_values=True))
    n = new_node()
    n.update({
        "name": urllib.parse.unquote(u.fragment) or u.hostname,
        "protocol": "hysteria2",
        "password": urllib.parse.unquote(u.username or "") or q.get("password", ""),
        "address": u.hostname,
        "port": u.port or 443,
        "security": "tls",
        "sni": q.get("sni") or q.get("peer") or "",
        "alpn": q.get("alpn") or "",
        "allow_insecure": str(q.get("insecure", "")).lower() in ("1", "true"),
        "source": "hysteria2-uri",
        "raw_params": q,
        "raw": uri,
    })
    n["transport_raw"] = "quic"
    n["transport"] = "quic"
    return n


# ---------------------------------------------------------------------------
# 配置文件解析
# ---------------------------------------------------------------------------
def parse_xray_json(text: str) -> dict:
    cfg = json.loads(text)
    outbounds = cfg.get("outbounds") or []
    ob = None
    for cand in outbounds:
        if cand.get("protocol") in ("vless", "vmess", "trojan", "shadowsocks", "hysteria2"):
            ob = cand
            break
    if ob is None:
        raise ValueError("Xray 配置里没有可识别的出站")

    proto = ob["protocol"]
    ss = ob.get("streamSettings") or {}
    settings = ob.get("settings") or {}
    n = new_node()
    n["protocol"] = proto
    n["name"] = ob.get("tag") or proto
    n["source"] = "xray-json"
    n["raw"] = text[:4000]
    n["transport_raw"] = (ss.get("network") or "tcp").lower()
    n["transport"] = _norm_transport(n["transport_raw"])
    n["security"] = (ss.get("security") or "none").lower()

    if proto in ("vless", "vmess"):
        vnext = (settings.get("vnext") or [{}])[0]
        users = (vnext.get("users") or [{}])[0]
        n["address"] = vnext.get("address", "")
        n["port"] = int(vnext.get("port") or 443)
        n["uuid"] = users.get("id", "")
        n["flow"] = users.get("flow") or ""
        n["encryption"] = users.get("encryption") or ("auto" if proto == "vmess" else "none")
    else:
        servers = (settings.get("servers") or [{}])[0]
        n["address"] = servers.get("address", "")
        n["port"] = int(servers.get("port") or 443)
        n["password"] = servers.get("password", "")
        n["method"] = servers.get("method", "")

    tls = ss.get("tlsSettings") or {}
    reality = ss.get("realitySettings") or {}
    ws = ss.get("wsSettings") or {}
    xh = ss.get("xhttpSettings") or ss.get("splithttpSettings") or {}
    grpc = ss.get("grpcSettings") or {}

    n["sni"] = tls.get("serverName") or reality.get("serverName") or ""
    n["alpn"] = ",".join(tls.get("alpn") or [])
    n["fingerprint"] = tls.get("fingerprint") or reality.get("fingerprint") or ""
    n["allow_insecure"] = bool(tls.get("allowInsecure"))
    n["host"] = ws.get("host") or xh.get("host") or ""
    n["path"] = ws.get("path") or xh.get("path") or ""
    n["mode"] = xh.get("mode") or ""
    n["extra"] = json.dumps(xh.get("extra") or {})
    n["service_name"] = grpc.get("serviceName") or ""
    n["reality_public_key"] = reality.get("publicKey") or ""
    n["reality_short_id"] = reality.get("shortId") or ""
    # Xray JSON 里的 `mux:{enabled:…}` 就是 mux.cool 本身 —— 这里读它是**对的**，
    # 与 mihomo 的 smux 不是一回事。字典要读 enabled（见 _flag）。
    n["mux"] = _flag(ob.get("mux")) if ob.get("mux") is not None else False
    # 官方字段名：客户端是 echConfigList，服务端是 echServerKeys。
    # 原来读的 "echSettings" 在官方文档里不存在 —— 所以从 Xray JSON 导入的
    # ECH 节点，配置一直是空的。
    n["ech"] = str(tls.get("echConfigList") or "").strip()
    n["ech_declared"] = bool(n["ech"] or tls.get("echServerKeys") or tls.get("echSettings"))
    return n


_MIHOMO_KEYS = {
    "servername": "sni", "sni": "sni", "flow": "flow", "uuid": "uuid",
    "password": "password", "cipher": "method", "alterId": "alter_id",
    "client-fingerprint": "fingerprint", "skip-cert-verify": "allow_insecure",
}


def parse_mihomo_yaml(text: str) -> dict:
    """mihomo 节点解析。优先用 PyYAML，缺失时退化为键值扫描。"""
    entry = None
    try:
        import yaml
        data = yaml.safe_load(text) or {}
        candidates = (data.get("proxies") or []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
        for p in candidates:
            if isinstance(p, dict) and str(p.get("type", "")).lower() in (
                    "vless", "vmess", "trojan", "ss", "shadowsocks", "hysteria2"):
                entry = p
                break
    except ImportError:
        entry = None
    except Exception as exc:
        raise ValueError(f"mihomo YAML 解析失败: {exc}") from exc

    if entry is None:
        # 退化路径：至少能读出 server/port/type
        if not re.search(r"^\s*(server|type)\s*:", text, re.M):
            raise ValueError("mihomo 配置里没有可识别的节点")
        entry = {}
        for k in ("name", "type", "server", "port", "uuid", "password", "cipher",
                  "network", "tls", "servername", "sni", "path", "host"):
            m = re.search(rf"^\s*{k}\s*:\s*(.+?)\s*$", text, re.M)
            if m:
                entry[k] = m.group(1).strip().strip('"\'')
        if "path" not in entry:
            m = re.search(r"^\s*path\s*:\s*(.+?)\s*$", text, re.M)
            if m:
                entry["path"] = m.group(1).strip().strip('"\'')

    return _yaml_entry_to_node(entry)


def _split_ws_path(path: str):
    """把 '/path?ed=2048' 拆成 ('/path', 2048)。

    为什么必须拆开：Xray 的浏览器转发会把整串当 URL 路径用，带着 ?ed= 会让
    服务端路径匹配失败（实测：path 含 ?ed=2048 时连接建立不起来）。
    early data 应该单独表达，而不是塞进路径。
    """
    p = str(path or "")
    if "?" not in p:
        return p, 0
    base, _, q = p.partition("?")
    ed = 0
    for kv in q.split("&"):
        k, _, v = kv.partition("=")
        if k.strip().lower() == "ed":
            try:
                ed = int(v.strip() or 0)
            except ValueError:
                ed = 0
    return (base or "/"), ed


def _extract_ws_ed(ws: dict, path: str) -> int:
    """early data 长度：优先显式字段，其次 path 里的 ?ed=。"""
    for k in ("ed", "earlyData", "early_data", "edMax"):
        v = ws.get(k)
        if v in (None, "", 0, "0"):
            continue
        try:
            n = int(v)
        except (TypeError, ValueError):
            continue
        if n > 0:
            return n
    return _split_ws_path(path)[1]


def _yaml_entry_to_node(entry: dict) -> dict:
    t = str(entry.get("type", "")).lower()
    proto = {"ss": "shadowsocks"}.get(t, t)
    n = new_node()
    n["protocol"] = proto
    n["name"] = entry.get("name") or entry.get("server", "node")
    n["address"] = str(entry.get("server", ""))
    n["port"] = int(entry.get("port") or 443)
    n["uuid"] = str(entry.get("uuid", ""))
    n["password"] = str(entry.get("password", ""))
    n["method"] = str(entry.get("cipher", ""))
    # vless 的 encryption 必须原样保留！
    # Xray 25.x 起 vless 支持后量子加密（mlkem768x25519plus.*），服务端开了之后
    # 客户端写 "none" 会直接连不上。曾经这里漏读该字段，于是所有 mlkem 节点
    # 都被静默降级成 none —— 表现为"原生 TLS 连不上"，被误判成服务端问题。
    if "encryption" in entry and entry.get("encryption") not in (None, ""):
        n["encryption"] = str(entry["encryption"])
    n["sni"] = str(entry.get("servername") or entry.get("sni") or "")
    n["flow"] = str(entry.get("flow", ""))
    n["fingerprint"] = str(entry.get("client-fingerprint", ""))
    n["allow_insecure"] = bool(entry.get("skip-cert-verify"))
    # ---- mux 与 smux 必须分开 ----
    #
    # mihomo 的 `smux:{enabled,protocol,max-connections,…}` 是 sing-box/mihomo 的
    # SMUX 协议，**不是** Xray 的 mux.cool（后者的握手是固定域名
    # v1.mux.cool:9527，只在 Xray 语境里有意义）。原来这里写的是
    #     n["mux"] = bool(entry.get("smux") or entry.get("mux"))
    # 两个毛病：
    #   ① 字典恒为真 —— `smux:{enabled:false}`（明确关掉）也被读成"要开"；
    #   ② 把另一个协议的字段当成 mux.cool 的意图，于是**导入 mihomo 订阅就等于
    #      给节点贴上 mux**。同一份订阅里的 XHTTP 节点一旦被开上 mux.cool 就必坏
    #      （官方明确不建议，实测 mux 开 000 / 关 204）。
    # 现在：老实读 `enabled`，存进 smux 字段备查；mux（mux.cool）只认同名键。
    smux = entry.get("smux")
    n["smux"] = _flag(smux) if smux is not None else False
    n["mux"] = _flag(entry.get("mux")) if "mux" in entry else False
    n["udp"] = bool(entry.get("udp", True))
    n["source"] = "mihomo-yaml"
    # 原始片段：单条解析时能拿到全文，从列表抽取时只能拿到该条目
    n["raw"] = json.dumps(entry, ensure_ascii=False)[:4000]

    if entry.get("reality-opts"):
        n["security"] = "reality"
        ro = entry["reality-opts"] if isinstance(entry["reality-opts"], dict) else {}
        n["reality_public_key"] = str(ro.get("public-key", ""))
        n["reality_short_id"] = str(ro.get("short-id", ""))
    elif str(entry.get("tls", "")).lower() in ("true", "1"):
        n["security"] = "tls"
    else:
        n["security"] = "none"

    # hysteria2 走 QUIC，配置里通常不写 network —— 不能默认成 tcp
    default_net = "quic" if proto == "hysteria2" else "tcp"
    net = str(entry.get("network") or default_net).lower()
    n["transport_raw"] = net
    n["transport"] = _norm_transport(net)

    ws = entry.get("ws-opts") if isinstance(entry.get("ws-opts"), dict) else {}
    xh = entry.get("xhttp-opts") or entry.get("splithttp-opts")
    xh = xh if isinstance(xh, dict) else {}
    if ws:
        n["path"] = str(ws.get("path") or "")
        headers = ws.get("headers") or {}
        n["host"] = str(headers.get("Host") or headers.get("host") or "")
        # early data：只记录，**不把 ?ed= 从 path 里拆掉**。
        # 实测（26.3.27）：ed 只能通过 URL 查询串生效，写 wsSettings.ed 等字段一律无效；
        # 而浏览器转发要靠它才会在任务里带上 extra.protocol，缺了页面就抛 TypeError。
        # 拆出去看着更"干净"，实际上会让 ws 节点在浏览器路径下必然失败。
        n["ws_ed"] = _extract_ws_ed(ws, n["path"])
    if xh:
        n["path"] = str(xh.get("path") or n["path"])
        n["mode"] = str(xh.get("mode") or "")
        headers = xh.get("headers") or {}
        n["host"] = str(headers.get("Host") or headers.get("host") or n["host"])
    if entry.get("ech-opts"):
        # mihomo 的形状是 {enable: bool, config: "<ECHConfigList>"}。
        # config 才是能下发的值；只有 enable: true 时**拿不到配置**，不能瞎猜 ——
        # 记成 declared，由 compat 如实说明"声明了但没有配置"。
        _eo = entry["ech-opts"] if isinstance(entry["ech-opts"], dict) else {}
        n["ech"] = str(_eo.get("config") or "").strip()
        n["ech_declared"] = bool(n["ech"] or _eo.get("enable"))
    if "alpn" in entry:
        alpn = entry["alpn"]
        n["alpn"] = ",".join(alpn) if isinstance(alpn, list) else str(alpn)
    return n


# ---------------------------------------------------------------------------
# 格式识别与统一入口
# ---------------------------------------------------------------------------
_URI_SCHEMES = {
    "vless": parse_vless, "vmess": parse_vmess, "trojan": parse_trojan,
    "ss": parse_shadowsocks, "shadowsocks": parse_shadowsocks,
    "hysteria2": parse_hysteria2, "hy2": parse_hysteria2,
}


def is_uri(text: str) -> bool:
    return bool(re.match(r"^[a-z0-9]+://", text.strip(), re.I))


def detect_format(text: str) -> str:
    t = text.lstrip()
    if is_uri(t):
        scheme = t.split("://", 1)[0].lower()
        if scheme in _URI_SCHEMES:
            return f"uri:{scheme}"
        if scheme in ("http", "https"):
            return "subscription"
    if t.startswith("{"):
        try:
            d = json.loads(t)
        except ValueError:
            return "unknown"
        if isinstance(d, dict):
            if "outbounds" in d:
                return "xray-json"
            if "source" in d and "address" in d:
                return "node-record"
            if "transport" in d and ("address" in d or "server" in d):
                return "node-record"
            if "address" in d or "server" in d:
                return "node-record"
        return "unknown"
    if "proxies:" in t or t.startswith("- ") or re.search(r"^\s*type\s*:", t, re.M):
        return "mihomo-yaml"
    return "unknown"


def _apply_query_flags(n: dict) -> dict:
    """把 URI 查询串里的开关兑现成节点字段。

    mux 不在 #716 官方分享规范里（属客户端私有扩展），但 v2rayN 一类客户端会写
    `mux=1`（少数写 `mux-enabled`）。raw_params 一直是一个都不丢地留着，可**留着
    不等于生效** —— 来源明确要开 mux，节点字段却还是 False，等于意图被吞掉。
    这里只认 mux.cool 的同义键；`smux=` 是另一套协议，记进 smux 字段备查。
    """
    q = {str(k).lower(): v for k, v in (n.get("raw_params") or {}).items()}
    for key in ("mux", "mux-enabled", "mux_enabled"):
        if key in q:
            n["mux"] = _flag(q[key])
            break
    if "smux" in q:
        n["smux"] = _flag(q["smux"])
    return n


def parse_node(text: str) -> dict:
    """把任意支持的输入解析成统一模型。"""
    fmt = detect_format(text)
    if fmt.startswith("uri:"):
        scheme = fmt.split(":", 1)[1]
        return _apply_query_flags(_URI_SCHEMES[scheme](text.strip()))
    if fmt == "xray-json":
        return parse_xray_json(text)
    if fmt == "node-record":
        d = json.loads(text)
        if not isinstance(d, dict) or "address" not in d:
            raise ValueError("不是节点记录")
        merged = new_node()
        merged.update({k: v for k, v in d.items() if v not in (None, "")})
        merged.setdefault("transport_raw", merged.get("transport", ""))
        return merged
    if fmt == "mihomo-yaml":
        return parse_mihomo_yaml(text)
    raise ValueError("无法识别的输入格式（支持 vless/vmess/trojan/ss/hysteria2 链接、"
                     "Xray JSON、Mihomo YAML）")


def parse_many(text: str) -> list[dict]:
    """解析可能包含多个节点的输入。

    支持三种形态：
      1) 一段 mihomo YAML（含多个 - name: 条目）—— 必须整段解析，
         按行拆开会把多行结构拆散（这是之前的 bug）
      2) 多行 URI（每行一个 vless:// 等）
      3) 订阅内容（可能 base64 编码）
    """
    body = text.strip()
    if not body:
        return []

    # 形态 1：YAML 文档 / 列表
    looks_yaml = (
        body.startswith("- ") or body.startswith("proxies:")
        or ("\n" in body and re.search(r"^\s*-\s*name\s*:", body, re.M))
        or re.search(r"^\s*type\s*:\s*(vless|vmess|trojan|ss|shadowsocks|hysteria2)\s*$",
                     body, re.M)
    )
    if looks_yaml and not is_uri(body):
        return _parse_yaml_all(body)

    # 形态 2/3：多行 URI（含 base64 订阅）
    decoded = _b64decode(body) if ("\n" not in body and not is_uri(body)) else ""
    if decoded and is_uri(decoded):
        body = decoded

    nodes = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            nodes.append(parse_node(line))
        except Exception:
            continue
    return nodes


def _parse_yaml_all(text: str) -> list[dict]:
    """从 mihomo YAML 里取出全部节点。"""
    entries = None
    try:
        import yaml
        data = yaml.safe_load(text) or {}
        if isinstance(data, dict):
            entries = data.get("proxies") or []
        elif isinstance(data, list):
            entries = data
    except Exception:
        entries = None

    if entries:
        out = []
        for e in entries:
            if not isinstance(e, dict):
                continue
            try:
                out.append(_yaml_entry_to_node(e))
            except Exception:
                continue
        if out:
            return out

    # 退化路径：PyYAML 不可用或结构异常时，按 "  - name:" 切块后逐块解析
    import yaml as _y  # noqa: F401  (仅确认可用性)
    blocks = re.split(r"^\s*-\s*(?=name\s*:)", text, flags=re.M)
    out = []
    for blk in blocks:
        blk = blk.strip()
        if not blk:
            continue
        candidate = "- " + blk if not blk.startswith("- ") else blk
        try:
            out.append(parse_mihomo_yaml(candidate))
            continue
        except Exception:
            pass
        # v2.1: 粘贴常带多余前导缩进（首行 "- name:" 顶格、其余字段多 2 格以上），
        # PyYAML 报 "mapping values are not allowed here"。
        # 方法：首行作为键行，后续行按 (自身缩进 - 第二字段行缩进 + 2) 左移，
        # 重建为合法列表项后再解析一次。
        lines = [l.rstrip() for l in blk.splitlines() if l.strip()]
        if len(lines) >= 2:
            first_c = len(lines[0]) - len(lines[0].lstrip())   # "name:" 行的当前缩进
            shift = len(lines[1]) - len(lines[1].lstrip()) - 2  # 第二字段行相对键位的多余空格
            if shift > 0:
                fixed_lines = ["- " + lines[0].lstrip()]
                for l in lines[1:]:
                    c = len(l) - len(l.lstrip())
                    fixed_lines.append(" " * max(0, c - shift - first_c) + l.lstrip())
                try:
                    out.append(parse_mihomo_yaml("\n".join(fixed_lines)))
                    continue
                except Exception:
                    pass
        continue
    return out


def parse_subscription(text: str) -> list[dict]:
    """订阅内容 → 节点列表。自动识别 base64 编码与多行文本。"""
    body = text.strip()
    decoded = _b64decode(body) if not is_uri(body) and "\n" not in body else ""
    if decoded and is_uri(decoded):
        body = decoded
    nodes = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            nodes.append(parse_node(line))
        except Exception:
            continue
    return nodes


def dump(node: dict) -> str:
    return json.dumps(node, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def selftest() -> int:
    """多协议解析自检：每种协议至少一条真实形态的输入。"""
    failed = 0
    cases = [
        ("vless://u@a.example:443?encryption=none&security=tls&type=xhttp&path=%2Fx&sni=a.example&mode=auto",
         "vless", "xhttp", "tls"),
        ("vless://u@b.example:443?encryption=none&security=reality&type=ws&path=%2Fw&sni=b.example&pbk=k&sid=01&fp=chrome",
         "vless", "websocket", "reality"),
        ("vmess://" + base64.b64encode(json.dumps({
            "v":"2","ps":"vm","add":"c.example","port":"443","id":"11111111-2222-3333-4444-555555555555",
            "net":"ws","tls":"tls","host":"c.example","path":"/ws","scy":"auto"}).encode()).decode(),
         "vmess", "websocket", "tls"),
        ("trojan://pw@d.example:443?sni=d.example&type=tcp#trojan-node",
         "trojan", "tcp", "tls"),
        ("ss://" + base64.b64encode(b"aes-256-gcm:pass123").decode() + "@e.example:8388#ss-node",
         "shadowsocks", "tcp", "none"),
        ("hysteria2://pw@f.example:443?sni=f.example#hy2-node",
         "hysteria2", "quic", "tls"),
    ]
    print("=== 节点解析自检 ===")
    for raw, proto, transport, security in cases:
        try:
            n = parse_node(raw)
            good = (n["protocol"] == proto and n["transport"] == transport
                    and n["security"] == security and n["address"] and n["port"])
            detail = f'{n["protocol"]:<12} {n["transport"]:<10} {n["security"]:<8} {n["address"]}:{n["port"]}'
        except Exception as exc:
            good, detail = False, f"异常: {exc}"
        failed += 0 if good else 1
        print(f"  [{'PASS' if good else 'FAIL'}] {detail}")

    # 统一模型的完整性：解析阶段不许丢字段
    n = parse_node(cases[1][0])
    keep = ["reality_public_key", "reality_short_id", "fingerprint", "path", "sni"]
    missing = [k for k in keep if not n.get(k)]
    good = not missing
    failed += 0 if good else 1
    print(f"  [{'PASS' if good else 'FAIL'}] 字段完整性（缺失: {missing or '无'}）")

    # 生成 → 解析 的往返：解析器认识的字段，生成时必须原样写回去。
    # 这一条是补的：fp / encryption / ech / alpn / mode 以前只解析不生成，
    # 表单里填了、拼链接时被悄悄丢掉，导入回来少一半参数而界面毫无提示。
    rt = {"name": "rt", "protocol": "vless", "address": "rt.example", "port": 443,
          "uuid": "11111111-2222-3333-4444-555555555555", "transport": "tcp",
          "security": "reality", "flow": "xtls-rprx-vision", "fingerprint": "chrome",
          "encryption": "mlkem768x25519plus.native.0rtt.KEY",
          "ech": "https://ech.example/config", "sni": "rt.example", "alpn": "h2",
          "reality_public_key": "PBK", "reality_short_id": "0a",
          "reality_spider_x": "/"}
    try:
        back = parse_node(build_link(rt))
        lost = [k for k in ("fingerprint", "encryption", "ech", "flow", "alpn",
                            "reality_public_key", "reality_short_id",
                            "reality_spider_x", "sni")
                if back.get(k) != rt[k]]
        good = not lost
    except Exception as exc:
        good, lost = False, [f"异常: {exc}"]
    failed += 0 if good else 1
    print(f"  [{'PASS' if good else 'FAIL'}] 生成→解析往返不丢字段（丢: {lost or '无'}）")

    # 自动命名（手动添加留空时用）：不能空、不能与已有重名、规则与服务端一致
    try:
        n1 = auto_name("vless", "tls")
        n2 = auto_name("vless", "tls", ["x-vless01-TLS"])
        n3 = auto_name("shadowsocks", "none", ["x-ss01-none", "x-ss02-none"])
        good = (n1 == "x-vless01-TLS" and n2 == "x-vless02-TLS" and n3 == "x-ss03-none")
        detail = f"{n1} / {n2} / {n3}"
    except Exception as exc:
        good, detail = False, f"异常: {exc}"
    failed += 0 if good else 1
    print(f"  [{'PASS' if good else 'FAIL'}] 自动命名（{detail}）")

    # 订阅解析
    sub = "\n".join([c[0] for c in cases[:3]])
    nodes = parse_subscription(sub)
    good = len(nodes) == 3
    failed += 0 if good else 1
    print(f"  [{'PASS' if good else 'FAIL'}] 订阅解析（{len(nodes)}/3 个节点）")

    # base64 订阅
    b64sub = base64.b64encode(sub.encode()).decode()
    nodes = parse_subscription(b64sub)
    good = len(nodes) == 3
    failed += 0 if good else 1
    print(f"  [{'PASS' if good else 'FAIL'}] base64 订阅（{len(nodes)}/3）")

    print(f"\n自检: {'PASS' if failed == 0 else str(failed) + ' 项失败'}")
    return 1 if failed else 0


# 内部规范名 → 分享链接里通用的短名。
# 规范名 websocket/mkcp 是给内部用的，v2rayN、Shadowrocket、Clash 收链接时
# 认的是 ws/kcp。发错名的后果很隐蔽：链接能存进订阅，但实际连不上。
_LINK_TRANSPORT = {"websocket": "ws", "mkcp": "kcp", "http": "h2", "h2": "h2",
                   "gun": "grpc", "raw": "tcp"}


# 协议 / 安全层在名字里的写法 —— 与**服务端** conf/lib/naming.sh 的
# x_proto_slug / x_sec_slug 保持一致。两边不一致的话，同一台服务器推来的
# 节点和手动加的节点在列表里长得不一样，用户会以为不是一套东西。
_NAME_PROTO = {"shadowsocks": "ss", "ss2022": "ss2022", "shadowsocks2022": "ss2022",
               "hy2": "hysteria2", "hysteria": "hysteria2"}


def _name_proto(proto: str) -> str:
    p = re.sub(r"[^a-z0-9]", "", (proto or "node").lower())
    return _NAME_PROTO.get(p, p) or "node"


def _name_sec(sec: str) -> str:
    s = (sec or "none").lower()
    return {"tls": "TLS", "reality": "REALITY", "none": "none", "": "none"}.get(s, s.upper())


def auto_name(proto: str, security: str = "", existing=(), transport: str = "") -> str:
    """留空时自动生成的名字：`x-<协议><两位编号>-<安全>`。

    ★ 为什么非要有：手动添加表单写的是"留空自动生成"，但以前**真的留空** ——
      fragment 是空的，而解析器是 `name = fragment or hostname`，于是同一个
      域名下的节点在列表里全叫一个名字，用户分不清谁是谁（服务端那边
      同样的问题在 x_default_name 的注释里记过）。

    编号取已有的同名最大值 +1，所以连加几个不会撞名。
    """
    p = _name_proto(proto)
    sec = _name_sec(security)
    pat = re.compile(r"^x-" + re.escape(p) + r"(\d+)-", re.I)

    def idx_of(name: str) -> int:
        m = pat.match((name or "").strip())
        return int(m.group(1)) if m else 0

    n = max([idx_of(x) for x in existing] + [0]) + 1
    tag = "x-%s%02d-%s" % (p, n, sec)
    if transport and transport.lower() == "xhttp" and "cdn" in "".join(existing).lower():
        pass                       # 位置留给将来；CDN 后缀由调用方决定
    return tag


# ---------------------------------------------------------------- 简易出站
#
# 把本机 / 局域网里别的内核当上游：socks5 或 http 代理。
# 与订阅导入的节点**同构**（同一份状态模型），所以配置生成、能力检查、
# 面板列表全都不需要为新类型写分支。
SIMPLE_PROTOCOLS = {"socks": "SOCKS5", "http": "HTTP"}


def simple_node(proto: str, host: str, port: int, username: str = "",
                password: str = "", name: str = "") -> dict:
    """构造一个简易出站节点。

    默认名对齐另外两个内核：`SOCKS5-127.0.0.1-1080` / `HTTP-127.0.0.1-7890`
    —— 名字里带类型和地址端口，列表里一眼知道它指向哪。
    """
    p = (proto or "").strip().lower()
    p = {"socks5": "socks", "socks5h": "socks", "https": "http"}.get(p, p)
    if p not in SIMPLE_PROTOCOLS:
        raise ValueError("类型只能是 socks 或 http（得到 %r）" % proto)
    host = (host or "").strip()
    if not host:
        raise ValueError("目标地址不能为空")
    if host in ("0.0.0.0", "::"):
        # 监听地址不是连接目标；这里挡住，别让它变成"连不上又看不出原因"
        raise ValueError("%s 是监听地址，不能当连接目标（本机请填 127.0.0.1）" % host)
    try:
        port = int(port)
    except (TypeError, ValueError):
        raise ValueError("端口必须是数字")
    if not (1 <= port <= 65535):
        raise ValueError("端口必须在 1-65535")

    n = new_node()
    n.update({
        "name": (name or "").strip() or "%s-%s-%d" % (SIMPLE_PROTOCOLS[p], host, port),
        "protocol": p,
        "address": host,
        "port": port,
        "username": (username or "").strip(),
        "password": (password or "").strip() if (username or "").strip() else "",
        # 简易出站没有传输层与安全层（明文本地跳），显式写死，免得后面
        # 被 build_stream 当成普通节点去拼 streamSettings。
        "transport": "tcp",
        "transport_raw": "tcp",
        "security": "none",
        "source": "local-proxy",
    })
    return n


def build_link(node: dict) -> str:
    """把统一模型节点拼成分享链接。

    为什么是"拼链接"而不是"直接写节点 JSON"：导入只有一套解析器
    （parse_node），拼链接再喂给它，校验、归一化、能力检查全都复用。
    再写一套结构化导入，就等于多一个解析器，将来字段行为不一致时，
    用户看到的是"手动建的能用、粘贴的不能用"这种最难查的问题。

    参数按各协议的实际写法给，不是想当然：
      · flow 只在 vless+tcp+reality 组合下有意义
      · 浏览器拨号要求 SNI == host == address，这里如实填，容错交给导入端
    """
    proto = (node.get("protocol") or "").lower()
    addr = node.get("address") or ""
    port = int(node.get("port") or 443)
    name = node.get("name") or ""
    transport = _LINK_TRANSPORT.get(_norm_transport(node.get("transport") or "tcp"),
                                   _norm_transport(node.get("transport") or "tcp"))
    security = (node.get("security") or "none").lower()
    sni = node.get("sni") or ""
    host = node.get("host") or ""
    path = node.get("path") or ""
    frag = "#" + urllib.parse.quote(name, safe="")

    if proto == "vmess":
        payload = {
            "v": "2", "ps": name, "add": addr, "port": str(port), "id": node.get("uuid") or "",
            "aid": "0", "scy": "auto", "net": transport, "type": "none", "host": host,
            "path": path, "tls": "tls" if security in ("tls", "reality") else "",
            "sni": sni,
        }
        return "vmess://" + base64.b64encode(
            json.dumps(payload, ensure_ascii=False).encode("utf-8")).decode("ascii")

    q = []
    if transport and transport != "tcp":
        q.append(("type", transport))
    if security in ("tls", "reality"):
        q.append(("security", security))
    if sni:
        q.append(("sni", sni))
    if host:
        q.append(("host", host))
    if path:
        q.append(("path", path))
    if transport in ("grpc", "xhttp") and node.get("service_name"):
        q.append(("serviceName", node["service_name"]))
    # ★ 下面这几个以前**只解析不生成** —— 表单里填了、拼链接时被悄悄丢掉，
    #   导入回来一看少一半参数，而界面上什么错都不报。解析器认识哪些键，
    #   生成就得写哪些键，否则"手动建的"和"粘贴的"行为不一致。
    if node.get("fingerprint"):
        q.append(("fp", node["fingerprint"]))
    if node.get("alpn"):
        q.append(("alpn", node["alpn"]))
    if node.get("mode") and transport == "xhttp":
        # xhttp 的 mode（auto / packet-up / stream-up）走 mode= 参数
        q.append(("mode", node["mode"]))
    if node.get("header_type") and transport == "tcp":
        q.append(("headerType", node["header_type"]))
    if node.get("ech"):
        q.append(("ech", node["ech"]))
    if proto == "vless":
        if node.get("encryption"):
            q.append(("encryption", node["encryption"]))
        if node.get("flow"):
            q.append(("flow", node["flow"]))
        if node.get("reality_public_key"):
            q.append(("pbk", node["reality_public_key"]))
        if node.get("reality_short_id"):
            q.append(("sid", node["reality_short_id"]))
        if node.get("reality_spider_x"):
            q.append(("spx", node["reality_spider_x"]))
    qs = urllib.parse.urlencode(q)
    tail = ("?" + qs) if qs else ""

    if proto == "vless":
        user = node.get("uuid") or ""
    elif proto == "trojan":
        user = urllib.parse.quote(node.get("password") or "", safe="")
    elif proto == "shadowsocks":
        method, pw = node.get("method") or "", node.get("password") or ""
        if pw.endswith("=") or pw.endswith("=="):
            user = urllib.parse.quote(pw, safe="")
        else:
            user = urllib.parse.quote(
                base64.b64encode(("%s:%s" % (method, pw)).encode()).decode(), safe="")
    elif proto == "hysteria2":
        user = urllib.parse.quote(node.get("password") or "", safe="")
    else:
        raise ValueError(f"不支持生成链接的协议: {proto}")

    return f"{proto}://{user}@{addr}:{port}{tail}{frag}"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]

    if cmd == "selftest":
        return selftest()

    raw = sys.stdin.read() if (len(argv) > 2 and argv[2] == "-") else ""
    if not raw and len(argv) > 2:
        arg = argv[2]
        if os.path.isfile(arg):      # v2 fix: 支持 node.py multi <file> 直接读文件
            raw = open(arg, encoding="utf-8", errors="replace").read()
        else:
            raw = arg
    if not raw:
        print("缺少输入", file=sys.stderr)
        return 2

    try:
        if cmd == "parse":
            print(dump(parse_node(raw)))
        elif cmd == "multi":
            print(json.dumps(parse_many(raw), ensure_ascii=False))
        elif cmd == "subscription":
            nodes = parse_subscription(raw)
            print(json.dumps(nodes, ensure_ascii=False, indent=2))
        elif cmd == "field":
            node = parse_node(raw)
            print(node.get(argv[3], "") if len(argv) > 3 else "")
        elif cmd == "detect":
            print(detect_format(raw))
        elif cmd == "build":
            # 输入是统一模型的 JSON，输出是分享链接。面板的手动添加表单走这里，
            # 再把链接喂给 parse —— 导入只有一套解析器。
            print(build_link(json.loads(raw)))
        else:
            print(f"未知子命令: {cmd}", file=sys.stderr)
            return 2
    except Exception as exc:
        print(f"解析失败: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv))
