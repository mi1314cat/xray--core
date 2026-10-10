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
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys

# 显示名（旗帜 + 服务器前缀）实现在 naming.py —— 只有一份，
# bash 侧 conf/lib/naming.sh 也调它。两边各写一套必然漂移。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import naming  # noqa: E402
except Exception:                                                # noqa: BLE001
    naming = None


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


def _strip_port(host):
    """去掉 host:port 里的端口。IPv6 必须带方括号才算有端口, 否则冒号是地址的一部分。"""
    h = str(host or "").strip()
    if h.startswith("["):
        return h[1:h.index("]")] if "]" in h else h
    if h.count(":") == 1 and h.rsplit(":", 1)[1].isdigit():
        return h.rsplit(":", 1)[0]
    return h


def is_ip_literal(host) -> bool:
    """这个值是不是 IP 字面量。

    ★ 为什么分享层必须能判这个: SNI 是**域名**。写成 IP 时客户端拿 IP 去
      校验证书, 而证书的 SAN 里不会有这个 IP (自签证书即使补了 IP SAN, 也只
      补 127.0.0.1/0.0.0.0 这类本机地址) —— 实测报错就是
          x509: cannot validate certificate for 107.173.154.178
              because it doesn't contain any IP SANs
      即"链接生成成功, 客户端导入成功, 就是连不上"。宁可省略 sni 让客户端
      按默认行为走, 也不要写一个必然校验失败的 IP。
    """
    h = _strip_port(host)
    if not h:
        return False
    if h.endswith("."):            # FQDN 写法的尾巴, 1.2.3.4. 也是 IPv4
        h = h[:-1]
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        return False


# 同一个证书文件在一次进程生命周期里只读一次 (key 里带 mtime, 换证书会失效)。
# collect() 每次列表/分享都要遍历全部片段, 不加缓存就是每个 TLS 节点两次
# openssl 子进程 —— 面板每刷一次都付这个代价。
_CERT_DOMAIN_CACHE = {}


def cert_domain(cert_file):
    """从证书文件读它签给谁: SAN 里第一个 DNS: → CN。读不到返回 None。

    这是**客户端实际会看到的那张证书**上的名字, 比任何元数据都可靠 ——
    分享元数据里的 host 是"连到哪"(可以是 IP), 证书里的是"该用哪个 SNI"。
    与 sing-box / mihomo 面板侧的做法一致 (extract_cert_domain / cert_is_trusted):
    先 SAN 再 CN, 拿不到就返回空, 不猜文件名当域名用。
    """
    if not cert_file:
        return None
    try:
        key = (cert_file, os.path.getmtime(cert_file))
    except OSError:
        return None                      # 证书不在本机 (别的机器上生成的片段)
    if key in _CERT_DOMAIN_CACHE:
        return _CERT_DOMAIN_CACHE[key]
    dom = None
    if shutil.which("openssl"):
        for args, rx in ((["-ext", "subjectAltName"], r"DNS:([^,\s]+)"),
                         (["-subject"], r"CN\s*=\s*([^,\n]+)")):
            try:
                r = subprocess.run(
                    ["openssl", "x509", "-in", cert_file, "-noout"] + args,
                    capture_output=True, text=True, timeout=10)
            except Exception:            # noqa: BLE001 — openssl 缺失/超时都不该炸分享
                break
            m = re.search(rx, r.stdout or "") if r.returncode == 0 else None
            if m:
                dom = m.group(1).strip().strip('"').lower()
                break
    _CERT_DOMAIN_CACHE[key] = dom
    return dom


def tls_domains(tls):
    """TLS 节点上"该用哪个域名做 SNI"的候选, 按可靠程度排。

    1. tlsSettings.serverName —— 节点自己的显式声明, 最直接
    2. 证书文件里的 SAN/CN  —— 客户端真的要校验的那个名字
    3. certificates[].domain —— 生成脚本写在证书项里的域名 (hy2 脚本会写)

    刻意**不**把"连接地址"算进来: 它就是 IP, 写进 sni 必然校验失败。
    """
    out = []
    sn = tls.get("serverName")
    if isinstance(sn, str) and sn.strip():
        out.append(sn.strip())
    for c in (tls.get("certificates") or []):
        if not isinstance(c, dict):
            continue
        d = cert_domain(c.get("certificateFile"))
        if d:
            out.append(d)
        if isinstance(c.get("domain"), str) and c["domain"].strip():
            out.append(c["domain"].strip())
    return out


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
        # TLS 节点的 SNI 候选 (serverName / 证书 SAN·CN / 证书项 domain)。
        # 旧版本只从 realitySettings.serverNames 取 sni, 于是**所有 tls 节点
        # 的分享链接都没有 sni=** —— 实测 (RN 真实节点 vless-xhttp07/08):
        # 链接里 security=tls 却没有 sni, 客户端拿连接地址(公网 IP)当 SNI,
        # 报 "cannot validate certificate for <IP> ... no IP SANs", 经分享
        # 链接根本连不上, 而服务端一切正常。
        "tls_domains": tls_domains(tls),
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


# ================================================================ 对外目标
#
# 分享链接里的 host:port 是"客户端去哪里连", 与"内核听在哪里"是**两件事**。
# 生产上出过一次典型事故 (vless-xhttp-01/02/03): 三个入站只绑 127.0.0.1,
# 分享链接却写 107.173.154.178:25333 —— 那个地址端口外部根本没人听,
# 三条链接必然是死链。根因就是这里**从来没看过 listen**。
LOOPBACK_LISTEN = {"127.0.0.1", "::1", "localhost", "[::1]", "127.0.0.2"}
DEFAULT_FRONT_PORT = 443        # nginx 前端默认端口 (与 deploy.py 的 public_port 同义)


def is_loopback_bound(n) -> bool:
    """节点是否**只**监听回环。

    listen 为空表示"没写这个字段" —— 内核默认监听 0.0.0.0, 也就是对外可达,
    所以空不算回环。只有明确写成回环地址才算。
    """
    listen = str(n.get("listen") or "").strip().lower()
    return listen in LOOPBACK_LISTEN


def share_target(n, meta=None):
    """决定分享链接里的 host:port, 返回 (host, port, note, refuse)。

    refuse 非空 = **不该发布**: 调用方必须把原因报出来, 而不是静默少一个节点。

    规则:
      · 只绑回环 + tier=nginx  → 用域名 + nginx 前端端口 (默认 443), 正确形态
      · 只绑回环 + 没有 nginx  → 拒绝发布 (外部访问不到; 要么去配 nginx, 要么改绑定)
      · 绑公网                 → 用分享元数据里的 host:port
    另外报 two 类"元数据陈旧"的疑点 (note), 它们不会让链接必然失效, 但值得说:
      · tier=nginx 却把节点自己的回环端口当对外端口 (生产 VLESS-WS_01 就是这种)
      · 元数据端口与片段端口不一致 (换了端口没重建分享元数据)
    """
    meta = meta or {}
    host = str(meta.get("host") or n.get("sni") or "").strip()
    tier = str(meta.get("tier") or "").strip().lower()
    node_port = n.get("port")
    meta_port = meta.get("port")

    if not is_loopback_bound(n):
        if not host or not (meta_port or node_port):
            return "", 0, None, "缺对外地址/端口"
        if tier == "nginx" and str(meta_port) == str(node_port):
            # 绑了公网却说自己走 nginx —— 端口语义有歧义, 按元数据发布但要说出来
            return host, meta_port, ("tier=nginx 但元数据端口与片段端口相同 "
                                     f"({meta_port}); 若确实经 nginx 转发, 对外端口应是前端端口",
                                     ), None
        if meta_port and node_port and str(meta_port) != str(node_port):
            return host, meta_port, (f"元数据端口 {meta_port} 与片段端口 {node_port} 不一致 —— "
                                     "多半是换了端口没重建分享元数据 (客户端按元数据连)", ), None
        return host, meta_port or node_port, None, None

    # ---- 只绑回环 ----
    if tier != "nginx":
        return "", 0, None, (
            f"节点只监听 {n.get('listen')}, 外部访问不到, 分享元数据里也没有 "
            "tier=nginx · 先给它配 nginx 反代 (conf/lib/nginx_apply.py) 或改绑 0.0.0.0")
    if not host:
        return "", 0, None, "nginx 档但分享元数据没有域名(host), 生成不出可连的链接"
    front = meta.get("public_port") or DEFAULT_FRONT_PORT
    note = None
    if str(meta_port) == str(node_port) or meta_port in (None, ""):
        note = (f"元数据里的端口 {meta_port or '(缺)'} 是节点自己的回环端口, 不是对外端口 —— "
                f"已按 nginx 前端的 {front} 发布")
    elif str(front) != str(meta_port):
        note = f"按 nginx 前端端口 {front} 发布 (元数据记的是 {meta_port})"
    return host, front, note, None


def reality_sni(n):
    """REALITY 节点的 SNI —— 仍然只来自 serverNames (握手伪装的目标站点),
    取法一字未改; 只拦"serverNames 被填成 IP"这种病态配置。"""
    sni = (n.get("server_names") or [""])[0]
    return sni if sni and not is_ip_literal(sni) else ""


def link_sni(n, meta=None):
    """TLS 类节点该写进分享链接的 sni。取不到返回 "" (整个参数不写)。

    **绝不返回 IP 字面量** —— 见 is_ip_literal 的说明, 那是"链接看起来正常
    但客户端必然握手失败"。宁可省略: 省略时各家客户端的行为是"用连接地址
    作 SNI", 至少不会比我们写死一个错的更差, 而且不会让订阅解析器当成
    "节点自己声明了 SNI=<IP>"。

    优先级 (与 SB/M 面板侧一致: 证书/节点声明优先, 元数据只是兜底):
      1. 节点自身的 serverName / 证书 SAN·CN / 证书项 domain
      2. 分享元数据里的域名 (CDN 节点就是这种: 元数据 host 是域名)
    """
    for cand in (n.get("tls_domains") or []):
        if cand and not is_ip_literal(cand):
            return str(cand)
    host = str((meta or {}).get("host") or "").strip()
    if host and not is_ip_literal(host):
        return host
    return ""


def build_share_link(n, meta=None, notes=None):
    """从节点视图生成 Xray 分享链接。

    meta 是 conf/lib/share_meta.py 的记录, 提供片段里没有的字段
    (REALITY 公钥、VLESS encryption、对外地址、显示名)。
    notes 非空时, 把"元数据陈旧"这类提示 append 进去 —— 生成链接的路径有好几条
    (创建 / 刷新 / 面板), 提示必须跟着返回值走, 否则总有一条路径不吭声。
    """
    meta = meta or {}
    proto = n.get("protocol")
    host, port, note, refuse = share_target(n, meta)
    if notes is not None and note:
        notes.append(f"{n.get('tag') or '?'}: {note}")
    if refuse:
        if notes is not None:
            notes.append(f"{n.get('tag') or '?'}: 未发布 —— {refuse}")
        return None
    name = meta.get("name") or n.get("tag") or ""

    # 显示名不能为空。Client 的解析器是 `name = fragment or hostname`
    # (Client/lib/node.py:121) —— 没有 fragment 就退化成域名, 于是同一域名
    # 下的所有节点在列表里名字完全一样, 用户分不清谁是谁。
    # 兜底到端口, 保证任何情况下 fragment 都非空。
    if not name:
        name = f"{proto or 'node'}-{port or 'x'}"

    # ★ 旗帜 + 服务器前缀。对照 sing-box-core 的做法 (sb_server_name):
    #   tag 是内部标识 (稳定 ASCII), 给人看的名字要有"哪台机器"这一层 ——
    #   否则两台服务器各跑一份全协议时, 客户端里两组节点名字一模一样,
    #   导入第二条直接覆盖第一条 (Client 的节点文件名带名字), 静默少节点。
    #
    # 在这里做而不是在 share_payload 里: 面板创建时与节点变动后刷新时
    # 都必须带上, 而两处都走这个函数。
    if naming is not None:
        name = naming.display_name(name)

    if not host or not port:
        # 兜底: share_target 已经保证到这里 host/port 都非空, 这一条是防止
        # 以后有人改 share_target 时把它破坏掉 (宁可少一条链接, 不要发一条
        # host="" 的链接 —— 客户端会把它当成地址解析失败)。
        return None

    if proto == "vless":
        # REALITY 缺公钥的链接是残缺的。Client 的能力检查会判
        # "security=reality 但缺少 pbk" 而静默丢弃该节点 (compat.py),
        # 表现是"分享了 4 个节点客户端只收到 3 个"且没有任何报错。
        # 生成一条连不上的链接比不生成更糟 —— 用户会以为已经分享成功了。
        if n.get("security") == "reality" and not meta.get("public_key"):
            if notes is not None:
                notes.append(f"{n.get('tag') or '?'}: 未发布 —— REALITY 缺公钥(pbk), "
                             "客户端会静默丢弃这条链接")
            return None
        q = {
            "encryption": meta.get("encryption", "none"),
            "security": n.get("security") or "none",
            "type": n.get("network") or "tcp",
        }
        if n.get("flow"):
            q["flow"] = n["flow"]
        if n.get("security") == "reality":
            # REALITY 的 SNI 仍然只来自 serverNames (握手伪装的目标站点) ——
            # 这一条不动。只拦"serverNames 里被填成 IP"这种病态配置:
            # 那不是域名, 客户端拿它做 SNI 必然对不上。
            sni = reality_sni(n)
            if sni:
                q["sni"] = sni
            q["fp"] = meta.get("fingerprint", "chrome")
            if meta.get("short_id"):
                q["sid"] = meta["short_id"]
            if meta.get("public_key"):
                q["pbk"] = meta["public_key"]
            q["spx"] = meta.get("spx", "")
        elif n.get("security") == "tls":
            # ★ 这里以前是 `if n.get("sni")`, 而 n["sni"] 只从 REALITY 的
            #   serverNames 取 —— 于是 TLS 节点的链接**永远没有 sni=**。
            sni = link_sni(n, meta)
            if sni:
                q["sni"] = sni
            if n.get("path"):
                q["path"] = n["path"]
            if n.get("network") == "ws":
                q["host"] = meta.get("host_header", "")
        qs = "&".join(f"{k}={_qval(v)}" for k, v in q.items() if v not in (None, ""))
        return f"vless://{n.get('id') or ''}@{_q(host)}:{port}?{qs}#{_q(name)}"

    if proto == "trojan":
        if n.get("security") == "reality" and not meta.get("public_key"):
            if notes is not None:
                notes.append(f"{n.get('tag') or '?'}: 未发布 —— REALITY 缺公钥(pbk)")
            return None
        q = {"security": n.get("security") or "none", "type": n.get("network") or "tcp"}
        if n.get("security") == "reality":
            sni = reality_sni(n)
            if sni:
                q["sni"] = sni
            q["fp"] = meta.get("fingerprint", "chrome")
            if meta.get("short_id"):
                q["sid"] = meta["short_id"]
            if meta.get("public_key"):
                q["pbk"] = meta["public_key"]
        elif n.get("security") == "tls":
            sni = link_sni(n, meta)
            if sni:
                q["sni"] = sni
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
        #
        # ★ sni 以前取的是 meta["host"], 生产上那是**连接地址** —— 实测生成过
        #   `sni=107.173.154.178`, 客户端拿 IP 校验证书必然失败。现在取证书/
        #   节点声明的域名, 拿不到就整个参数不写。
        q = {}
        sni = link_sni(n, meta)
        if sni:
            q["sni"] = sni
        q["insecure"] = "0"
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
            "sni": reality_sni(n) if n.get("security") == "reality"
            else link_sni(n, meta),
        }
        b = base64.b64encode(json.dumps(obj, ensure_ascii=False).encode()).decode()
        return f"vmess://{b}"

    return None
