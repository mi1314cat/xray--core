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
import urllib.parse

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


def tls_domains(tls, declared=None):
    """TLS 节点上"该用哪个域名做 SNI"的候选, 按可靠程度排。

    1. 片段自带的 `_serverName` —— 生成它的脚本写在片段根上的"这个节点是
       为哪个域名建的"。conf/vlessxhttpecn.sh 的 rebuild_one() 就是**优先**
       用它 (`CERT_DOMAIN=$(extract_cert_domain ...)` 之后被 `_serverName`
       覆盖) —— 订阅载荷要与 per-node 产物同源, 这一条必须在候选里,
       否则"证书文件在别的机器上读不到"时载荷会没 sni 而产物有。
    2. tlsSettings.serverName —— 节点自己的显式声明
    3. 证书文件里的 SAN/CN  —— 客户端真的要校验的那个名字
    4. certificates[].domain —— 生成脚本写在证书项里的域名 (hy2 脚本会写)

    刻意**不**把"连接地址"算进来: 它就是 IP, 写进 sni 必然校验失败。
    """
    out = []
    if isinstance(declared, str) and declared.strip():
        out.append(declared.strip())
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


def extract(inbound, source_file, frag=None):
    """从单个 inbound 抽出统一节点视图。

    frag 是整个片段的顶层对象 —— `_serverName` / `_clientEncryption` 这类
    "给人看、内核不认"的字段写在根上 (Xray 配置是严格 schema, 塞进 inbound
    会让 `xray run -test` 失败), 所以抽取时要把根一起传进来。
    """
    if not isinstance(inbound, dict):
        return None
    frag = frag if isinstance(frag, dict) else {}
    ss = inbound.get("streamSettings") or {}
    tls = ss.get("tlsSettings") or {}
    reality = ss.get("realitySettings") or {}
    ws = ss.get("wsSettings") or {}
    xhttp = ss.get("xhttpSettings") or {}
    declared = frag.get("_serverName")
    declared = declared.strip() if isinstance(declared, str) and declared.strip() else None
    ech_keys = tls.get("echServerKeys")
    ech_keys = ech_keys.strip() if isinstance(ech_keys, str) and ech_keys.strip() else None

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
        # xhttp 的上下行模式。★ 必须在这里抽出来 —— build_share_link 早就有
        # `if n.get("mode")` 那一段 (注释还写着"以前链接里根本不带 mode"),
        # 但 extract() 从来没产出过这个键, 于是那个条件**恒假**, 条件本身
        # 成了摆设: 共享出去的 xhttp 节点一律退回 auto, 而 auto 在 REALITY 下
        # 解析成 stream-one (合流) —— 导入后"看着正常, 只是没在分离"。
        # (同类的还有 downloadSettings, 见 split_params 的兜底。)
        "mode": xhttp.get("mode") or "",
        "sni": None,        # TLS 节点的 SNI 候选 (片段 _serverName / serverName / 证书 SAN·CN /
        # 证书项 domain)。
        "tls_domains": tls_domains(tls, declared),
        # 片段自己的域名声明 —— 也是"这个节点支持 ECH"的来源标记
        # (只有 conf/vlessxhttpecn.sh 会写它, 而它的 ECH 形态只有 cdn/direct)。
        "declared_server_name": declared,
        # 直连 ECH 的服务端密钥 (有它 = 本节点自己终结 TLS 且开了 ECH)
        "ech_server_keys": ech_keys,
        "alpn": ",".join(tls.get("alpn") or []) or None,
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

    # ---- 上下行分离: 直接从片段里抽 ----
    #
    # ★ 片段是**服务端真相** (内核真正在跑的就是它), 元数据只是写的时候抄的
    #   一份副本 —— 所以这里填进 node 之后, build_share_link 的既有优先级
    #   (`n.get("dl_x") or meta.get("dl_x")`) 自然就是"片段优先, 元数据补位",
    #   两边都缺才落空。
    #
    #   这同时修掉了 split_params 里那段**永远不会执行**的兜底: 它去遍历
    #   `n["inbounds"]`, 而分享路径传进来的 n 是 extract() 出来的视图
    #   (根本没有 inbounds 键), 于是"老节点也能正确导出下行参数"这句注释
    #   一直没兑现 —— 元数据一旦缺失/写错目录, 所有 dl_* 静默消失,
    #   而链接看起来完全正常, 只是没在分离。
    dls = xhttp.get("downloadSettings") or {}
    if dls.get("address"):
        node["dl_address"] = dls.get("address") or ""
        node["dl_port"] = dls.get("port") or inbound.get("port")
        node["dl_security"] = dls.get("security") or node["security"] or "none"
        node["dl_sni"] = ((dls.get("realitySettings") or {}).get("serverName")
                          or (dls.get("tlsSettings") or {}).get("serverName")
                          or node["sni"])
        # ★ 下行 REALITY 在片段里存的是 `password` —— 因为那一侧服务端扮演的
        #   是**客户端**角色, 这个字段其实就是公钥 (见 node_build 的说明)。
        node["dl_public_key"] = (dls.get("realitySettings") or {}).get("password") or None
        node["dl_short_id"] = (dls.get("realitySettings") or {}).get("shortId") or None
        node["dl_mode"] = (dls.get("xhttpSettings") or {}).get("mode") or node["mode"]
        node["dl_path"] = (dls.get("xhttpSettings") or {}).get("path") or node["path"]
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
            # ★ REALITY 前置 (#4118) 不是节点: 它只做握手并把字节 fallback 进
            #   同一个 xhttp 入站。当成节点收进来会多出 xxx-front 条目, 而它
            #   没有公钥/路径, 分享时被拒发, 列表里还多两条"坏节点"。
            if str(ib.get("tag") or "").endswith("-front"):
                continue
            n = extract(ib, f, frag=d)
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

# hysteria2 链接的带宽/ALPN 默认值。
#
# ★ 口径只有一条, 与 conf/hysteria2.sh 的 hy2_bandwidth() 逐字对齐 ——
#   一个读文件一个写死, 等于"面板发出去的链接"和"脚本写出来的产物"描述的不是
#   同一件事, 而下一个建节点的人只会看脚本那半边:
#     显式设置 = ${XRAY_BASE}/.hy2-bandwidth, 两列空白分隔的 Mbps 文本
#                (与 mihomo 侧 src/lib/env.sh 的同名文件同一格式)
#     优先级   = .hy2-bandwidth → share_meta 的 upmbps/downmbps (逐节点记录;
#                生产上目前为空, 保留为兼容入口) → 默认
#     默认     = 上行 60 / 下行 200 (用户偏好: 上行 60, 下行 150~200 取 200)
#   逐字段校验: 两列里写坏一个, 另一个仍然生效。
#   旧的 `up=50&down=200` 两头都不对: 默认不是 60/200, 而且硬编码意味着
#   "用户显式设过"根本无处可设。
DEFAULT_HY2_UP = 60
DEFAULT_HY2_DOWN = 200
DEFAULT_HY2_ALPN = "h3"
HY2_BW_FILENAME = ".hy2-bandwidth"


def hy2_bw_path():
    """显式带宽设置文件 —— 与 conf/hysteria2.sh、mihomo 侧同一个路径口径。"""
    base = (os.environ.get("XRAY_BASE") or os.environ.get("XRAY_BASE_DIR")
            or "/root/catmi/xray")
    return os.path.join(base, HY2_BW_FILENAME)


def hy2_bandwidth():
    """读显式带宽 → (up|None, down|None)。文件不在/该字段不合法 → None。"""
    try:
        with open(hy2_bw_path(), encoding="utf-8") as fh:
            parts = fh.read().split()
    except OSError:
        return None, None
    up = int(parts[0]) if parts and parts[0].isdigit() else None
    down = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
    return up, down


def is_loopback_bound(n) -> bool:
    """节点是否**只**监听回环。

    listen 为空表示"没写这个字段" —— 内核默认监听 0.0.0.0, 也就是对外可达,
    所以空不算回环。只有明确写成回环地址才算。
    """
    listen = str(n.get("listen") or "").strip().lower()
    return listen in LOOPBACK_LISTEN


def client_security(n, meta=None):
    """客户端该用哪一层加密 —— **不是**片段里那个。

    ★ 两者在 nginx 档上恰好相反, 而这是一处会让"配置看着对、就是连不上"的分叉:

        片段里的 security   = xray **入站**用的  (nginx 档 = none, 因为
                              TLS 由 nginx 终结, nginx→xray 是明文)
        客户端要的 security = 客户端连出去的   (nginx 档 = tls, 因为
                              客户端连的是 nginx 的 443, 走 HTTPS)

      直接拿片段里那个当客户端配置, 客户端就会用**明文**去连一个 HTTPS 端口 ——
      实测: mihomo 先发明文 HTTP/2 前言, 再发 TLS, Cloudflare 直接关连接,
      客户端 000, 而服务端日志里一个字都没有 (请求根本没到)。
      本机访问看不到这个问题 (nginx 自己会 400), 所以很容易漏。

    cdn 档不一样: 客户端直连源站端口, 片段里写什么就是什么 (tls / reality / none)。
    """
    meta = meta or {}
    # ★ 上行 REALITY 前置 (#4118): 片段里的 security 是 xhttp 入站的 none,
    #   而客户端上行必须先和前置做 REALITY 握手。这里以前按 tier=nginx
    #   返回 tls —— 生成的链接是"明文 TLS 打 REALITY 端口", 客户端 000,
    #   服务端日志里什么都没有。判据在元数据里 (front_uplink), 不在片段里。
    if meta.get("front_uplink"):
        return "reality"
    sec = str(n.get("security") or "none").lower()
    tier = str(meta.get("tier") or "").strip().lower()
    if tier == "nginx" and sec == "none":
        return "tls"
    return sec


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

    # ★ 上行走 REALITY 前置 (#4118): 对外就是**前置**的地址与端口, 与 nginx
    #   无关。以前这里按 tier=nginx 走"前端端口 443", 于是 reality-cdn 被
    #   发布成 域名:443 —— 客户端拿它当 CDN 节点连, 连不上。
    if meta.get("front_uplink") and host and meta_port:
        return host, meta_port, None, None

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


# ================================================================ ECH
#
# 为什么分享层必须懂 ECH
# ----------------------
# per-node 产物 (conf/vlessxhttpecn.sh 的 render_client/rebuild_one) 写的链接里
# **带 `ech=`**, 而订阅载荷这条路径此前对它一无所知 —— 于是同一个节点:
#
#     out/vless-xhttp_share-08.txt  vless://…?…&ech=AGX%2BDQBhACA…
#     订阅载荷里的同一条            vless://…?…            ← ech 整段丢失
#
# 症状是静默的: 客户端照样导入、照样连, 只是 ECH 没开 —— 而 ECH 正是这个节点
# 存在的理由 (CDN-ECH 档 / 直连 ECH 档)。所以取值判据必须与脚本侧**同一套**。
ECH_CDN_DISCOVERY = "cloudflare-ech.com+https://dns.alidns.com/dns-query"
_ECH_KEYS_LEN_BYTES = 2


def ech_config_list(server_keys):
    """从 tlsSettings.echServerKeys 还原客户端可 pin 的 ECHConfigList。

    `xray tls ech` 生成的 server keys 是**两段拼起来的**:
        2 字节(大端)私钥长度 + 私钥 + ECHConfigList
    客户端要的是后半段, 这正是 `xray tls ech -i <keys>` 打印的
    "ECH config list:" 那一行。

    实测对齐 (RN 生产 vless-xhttp08.json): 这里算出来的字符串与
    `xrayls tls ech -i <keys>` 的输出**逐字节相同** —— 所以分享层不需要
    依赖 xray 二进制, 也能与脚本产物写出同一个值。
    """
    if not isinstance(server_keys, str) or not server_keys.strip():
        return ""
    try:
        raw = base64.b64decode(server_keys.strip(), validate=True)
    except Exception:                                        # noqa: BLE001
        return ""
    # 结构必须是 "2 字节密钥长度 + 密钥 + 至少 1 字节配置":
    # 长度不合法就返回空 —— 返回半截配置会让客户端拿一个解析不了的
    # ECHConfigList 去握手, 比"没有 ECH"更糟。
    if len(raw) <= _ECH_KEYS_LEN_BYTES:
        return ""
    klen = int.from_bytes(raw[:_ECH_KEYS_LEN_BYTES], "big")
    if klen <= 0 or _ECH_KEYS_LEN_BYTES + klen >= len(raw):
        return ""
    rest = raw[_ECH_KEYS_LEN_BYTES + klen:]
    return base64.b64encode(rest).decode()


def ech_discover(domain, timeout=3):
    """从域名的 HTTPS RR (type 65) 里取 ECHConfigList。取不到返回 ""。

    ★ 为什么必须有这一条 (2026-10-16 实测):
      CDN 前置的节点, ECH 是由 **CDN 边缘**终结的 —— 源站手里没有、
      也不该有那份私钥。客户端要用的 ECHConfigList 只存在于域名的
      HTTPS RR 里 (Cloudflare 自动发布, 值里 `cloudflare-ech.com` 就是
      它对外声称的 public name)。

      在那之前, 客户端产物只写了 mihomo 的 `ech-opts: {enable: true}`,
      以为"让客户端自己去 DNS 查"。**实测那个写法会让整条节点直接不可用**:
          dial ... error: resolve ECH config error: no ECH config found in DNS records
      连 curl 都拿不到任何响应 (HTTP=000) —— 不是"ECH 没生效", 是节点坏了。
      而同一台机器上 `dig TYPE65` 明明查得到。也就是说 **能不能查到取决于
      客户端自己的 DNS 实现, 不能赌**。

      拿到值直接写进配置 (`ech-opts.config`) 之后实测: SNI 明文变成
      cloudflare-ech.com, ClientHello 里出现扩展 65037, 隧道照常通。

    两条路都试: 先 dig (快, 且用的是本机 resolver 的策略), 再 DoH (dig 不在
    或本机 resolver 丢 type 65 时)。都不行就回空 —— 调用方必须把这件事
    **说出来**, 不能静默降级。
    """
    if not domain or is_ip_literal(domain):
        return ""
    import json as _json
    import re as _re
    import shutil
    import subprocess
    import urllib.request

    if os.environ.get("X_NO_ECH_DISCOVER") == "1":
        return ""

    def _from_rr(text):
        m = _re.search(r'ech=([A-Za-z0-9+/=]+)', text or "")
        return m.group(1) if m else ""

    dig = shutil.which("dig")
    if dig:
        try:
            out = subprocess.run([dig, "+short", "+time=2", "+tries=1",
                                  domain, "TYPE65"],
                                 capture_output=True, text=True,
                                 timeout=timeout).stdout
            v = _from_rr(out)
            if v:
                return v
        except Exception:                                   # noqa: BLE001
            pass

    for url in ("https://cloudflare-dns.com/dns-query?name=%s&type=HTTPS" % domain,
                "https://dns.google/resolve?name=%s&type=HTTPS" % domain):
        try:
            req = urllib.request.Request(url, headers={
                "accept": "application/dns-json",
                "user-agent": "xray-panel/ech-discover"})
            with urllib.request.urlopen(req, timeout=timeout) as fp:
                data = _json.load(fp)
            for ans in data.get("Answer", []):
                v = _from_rr(ans.get("data", ""))
                if v:
                    return v
        except Exception:                                   # noqa: BLE001
            continue
    return ""


def ech_param(n, host=None):
    """这个节点的分享链接该不该写 `ech=`, 写什么值。取不到返回 ""。

    **ECH 是端到端绑定的** —— 客户端发出去的 ECH 只有"它以为在连的那个
    服务端"能解开:
      · 片段里有 echServerKeys  → 本节点自己终结 TLS 且开了 ECH,
        值 = 由服务端密钥还原出的 ECHConfigList (与脚本产物同值);
      · 没有 echServerKeys, 但片段自带 _serverName (由
        conf/vlessxhttpecn.sh 生成 —— 它的 ECH 形态只有 cdn/direct 两种),
        **且这次发布连的就是 CDN 边缘**(host 是域名而不是 IP) → CDN-ECH,
        值 = 官方的 DNS 查询串 (Cloudflare 边缘处理 ECH);
      · 其余 → **不写**。直连源站而源站没开 ECH 时写 CDN 的配置,
        等于让客户端发一个源站解不开的 ClientHello —— 握手必失败。
    """
    cl = ech_config_list(n.get("ech_server_keys"))
    if cl:
        return cl
    if n.get("declared_server_name") and host and not is_ip_literal(host):
        return ECH_CDN_DISCOVERY
    return ""


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


def split_params(n, meta=None):
    """上下行分离在分享链接里的参数。

    用的都是**短参数名** (跟 sid/pbk/spx 一个风格), 因为分享链接的长度会
    直接影响很多客户端的剪贴板/二维码处理:

      dlad  下行地址 (域名或 IP)
      dlport 下行端口 —— 必须与上行同一个 (会话表 per-inbound, 见 node_build)
      dlsec 下行加密层: tls / reality / none
      dlsni 下行 SNI (TLS 与 REALITY 都要)
      dlpbk 下行 REALITY 公钥 (服务端写的 privateKey, 客户端要用 publicKey)
      dlsid 下行 shortId
      dlpath 下行 path (默认与上行相同)

    没有下行地址时返回空 dict —— 链接与原来**逐字节相同**, 不给存量链接添噪声。
    """
    # ★ 兜底: 直接从服务端的 downloadSettings 里读。
    #   元数据是**写**的时候带上的, 而历史节点是在加 dl_* 之前生成的 ——
    #   那些节点的元数据里根本没有这些字段, 于是链接发出来没有下行参数,
    #   而用户看不出任何区别 (导入正常、能连、只是没分离)。
    #   downloadSettings 一直都在片段里, 所以拿它兜底, 老节点也能正确导出。
    dls = {}
    try:
        for _in in (n.get("inbounds") or []):
            _ss = _in.get("streamSettings") or {}
            _xh = _ss.get("xhttpSettings") or {}
            if _xh.get("downloadSettings"):
                dls = _xh["downloadSettings"]
                nport = _in.get("port")
                break
    except Exception:
        dls = {}

    addr = (n.get("dl_address") or (meta or {}).get("dl_address")
            or dls.get("address") or "").strip()
    if not addr:
        return {}
    out = {"dlad": addr}
    port = n.get("dl_port") or (meta or {}).get("dl_port") or dls.get("port")
    if port:
        out["dlport"] = port
    sec = (n.get("dl_security") or (meta or {}).get("dl_security")
           or dls.get("security") or n.get("security") or "none")
    out["dlsec"] = sec
    # mode 必须发: 客户端侧 auto 在 REALITY 下会退化成合流, 就没分离了
    out["dlmode"] = ((n.get("dl_mode") or (meta or {}).get("dl_mode")
                      or (dls.get("xhttpSettings") or {}).get("mode") or "stream-up"))
    sni = (n.get("dl_sni") or (meta or {}).get("dl_sni")
           or (dls.get("realitySettings") or {}).get("serverName")
           or (dls.get("tlsSettings") or {}).get("serverName")
           or n.get("sni") or (meta or {}).get("sni"))
    if sni:
        out["dlsni"] = sni
    if sec == "reality":
        # ★ 字段名: 服务端 downloadSettings 里写的是 password (客户端角色),
        #   而**分享链接**这头要用 publicKey —— 客户端导入后自己填进它的
        #   客户端配置。取哪个都兜一遍, 免得只发一半。
        pbk = (n.get("dl_public_key") or (meta or {}).get("dl_public_key")
               or (dls.get("realitySettings") or {}).get("password")
               or (dls.get("realitySettings") or {}).get("publicKey")
               or (meta or {}).get("public_key"))
        sid = (n.get("dl_short_id") or (meta or {}).get("dl_short_id")
               or (dls.get("realitySettings") or {}).get("shortId")
               or (meta or {}).get("short_id"))
        if pbk:
            out["dlpbk"] = pbk
        if sid:
            out["dlsid"] = sid
    p = n.get("dl_path") or (meta or {}).get("dl_path")
    if p:
        out["dlpath"] = p
    return out


# Xray 官方文档 (XHTTP: Beyond REALITY) 给 XMUX 的默认值。
# 全为 0 (不写) 时内核取这三个 —— 也就是说客户端**本来**是这个行为;
# 而 mihomo 的 reuse-settings **没有默认值**, 不写就是"每个请求开一条新连接"。
_XMUX_DEFAULTS = {
    "maxConcurrency": "16-32",
    "hMaxRequestTimes": "600-900",
    "hMaxReusableSecs": "1800-3000",
}


def xhttp_extra(n, meta=None):
    """xhttp 的官方 `extra` (分享链接里那第四项)。没有内容时返回空 dict。

    ★ 为什么必须有: 官方文档写得很明确 ——
        「extra 是 host、path、mode 以外的所有参数的原始 JSON 分享方案，
          当 extra 存在时，只有该四项会生效。**且分享链接中只有这四项**」
      也就是说别人家的 GUI (v2rayN / v2rayNG / NekoBox ...) 认的是
        vless://...#...?...&mode=...&path=...&host=...&extra=<URL 编码的 JSON>
      而**不认识**我们自己那套 dlad/dlport/dlsec/... —— 那些参数在别人的客户端里
      会被直接忽略, 于是"分享出去的链接在别人那里变成合流"甚至少半段配置,
      而两边看着都正常。

      我们自己那套 dl* 继续保留: 本项目客户端读的是它 (见 Client/lib/node.py),
      忽略 extra。两套并存, 谁都不断。
    """
    meta = meta or {}
    extra = {}
    if n.get("network") == "xhttp":
        extra["xmux"] = dict(_XMUX_DEFAULTS)
    # ---- 上下行分离: 官方 shape 是"一套完整的 streamSettings + address/port" ----
    dl_addr = (n.get("dl_address") or meta.get("dl_address") or "").strip()
    if n.get("network") == "xhttp" and dl_addr:
        dsec = (n.get("dl_security") or meta.get("dl_security") or "tls").lower()
        dl = {
            "address": dl_addr,
            "port": int(n.get("dl_port") or meta.get("dl_port") or 443),
            "network": "xhttp",
            "security": dsec,
        }
        sni = (n.get("dl_sni") or meta.get("dl_sni")
               or n.get("sni") or meta.get("host") or "")
        if dsec == "reality":
            # ★ 公钥要写**两遍**:
            #     password  = Xray 官方 schema 的字段名 (realitySettings 在
            #                 客户端角色下, password 就是公钥)
            #     publicKey = mihomo 认的字段名
            #   实测 (mihomo v1.19.32 导入订阅):
            #     只有 password → 整份 provider 解析失败, 0 个节点, 报
            #        "'xhttp-opts.download-settings.reality-opts' has unset
            #         fields: public-key"
            #     两个都给    → 正常解析
            #   Xray 用标准 json.Unmarshal, 会忽略它不认识的字段, 所以多出来的
            #   publicKey 对 Xray 客户端无害。
            _pbk = n.get("dl_public_key") or meta.get("dl_public_key") or ""
            dl["realitySettings"] = {
                "serverName": sni,
                "fingerprint": meta.get("fingerprint") or "chrome",
                "password": _pbk,
                "publicKey": _pbk,
                "shortId": n.get("dl_short_id") or meta.get("dl_short_id") or "",
                "spiderX": meta.get("spx") or "/",
            }
        else:
            dl["tlsSettings"] = {"serverName": sni}
        dl["xhttpSettings"] = {
            # 服务端片段按官方口径不再写 mode (同时接受三种), 所以下行模式
            # 只在元数据里 —— 不取 meta 就会退回 "auto", 而 auto 在 REALITY
            # 下是 stream-one (合流), 分享出去就"看起来分离、实际没分离"。
            "path": n.get("dl_path") or meta.get("dl_path")
                    or n.get("path") or "/",
            "mode": n.get("dl_mode") or meta.get("dl_mode")
                    or n.get("mode") or "auto",
        }
        extra["downloadSettings"] = dl
    return extra


def build_share_link(n, meta=None, notes=None):
    """从节点视图生成 Xray 分享链接。

    meta 是 conf/lib/share_meta.py 的记录, 提供片段里没有的字段
    (REALITY 公钥、VLESS encryption、对外地址、显示名)。
    notes 非空时, 把"元数据陈旧"这类提示 append 进去 —— 生成链接的路径有好几条
    (创建 / 刷新 / 面板), 提示必须跟着返回值走, 否则总有一条路径不吭声。
    """
    meta = meta or {}
    # 上行 REALITY 前置 (#4118): 客户端上行是 xhttp 套在 REALITY 里
    if meta.get("uplink_network") or meta.get("uplink_path"):
        n = dict(n)
        if meta.get("uplink_network"):
            n["network"] = meta["uplink_network"]
        if meta.get("uplink_path"):
            n["path"] = meta["uplink_path"]
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
        if client_security(n, meta) == "reality" and not meta.get("public_key"):
            if notes is not None:
                notes.append(f"{n.get('tag') or '?'}: 未发布 —— REALITY 缺公钥(pbk), "
                             "客户端会静默丢弃这条链接")
            return None
        _sec = client_security(n, meta)
        q = {
            "encryption": meta.get("encryption", "none"),
            "security": _sec,
            "type": n.get("network") or "tcp",
        }
        if n.get("flow"):
            q["flow"] = n["flow"]
        if _sec == "reality":
            # REALITY 的 SNI 仍然只来自 serverNames (握手伪装的目标站点) ——
            # 这一条不动。只拦"serverNames 里被填成 IP"这种病态配置:
            # 那不是域名, 客户端拿它做 SNI 必然对不上。
            # ★ 前置节点的片段 (xhttp, security=none) 里没有 serverNames,
            #   真正的 serverName 在前置入站里, 由元数据带过来 (sni)。
            sni = reality_sni(n) or str(meta.get("sni") or "").strip()
            if sni:
                q["sni"] = sni
            q["fp"] = meta.get("fingerprint", "chrome")
            if meta.get("short_id"):
                q["sid"] = meta["short_id"]
            if meta.get("public_key"):
                q["pbk"] = meta["public_key"]
            q["spx"] = meta.get("spx", "")
        elif _sec == "tls":
            # ★ 这里以前是 `if n.get("sni")`, 而 n["sni"] 只从 REALITY 的
            #   serverNames 取 —— 于是 TLS 节点的链接**永远没有 sni=**。
            sni = link_sni(n, meta)
            if sni:
                q["sni"] = sni
            # ★ ech 与 sni 同源同命: 脚本产物里有、这里整段丢, 客户端就
            #   静默退化成"没开 ECH"。判据与值都在 ech_param() 一处实现。
            ech = ech_param(n, host)
            if ech:
                q["ech"] = ech
            if n.get("network") == "ws":
                q["host"] = meta.get("host_header", "")
        # ★ path 原来**只写在 tls 分支里** —— 于是 REALITY + ws/xhttp/grpc/
        #   httpupgrade 这四种组合的分享链接**不带 path**。客户端导入后按
        #   "/x" 去连, 服务端却是 "/real" 之类的路径, 直接 404, 而且**没有任何
        #   报错**: 节点显示正常, 只是永远连不上。
        #   这四条路径型传输与 security 无关, 所以必须挪到分支外面。
        if n.get("path"):
            q["path"] = n["path"]
        # ---- xhttp 的 mode ----
        # ★ 以前链接里根本不带 mode, 客户端一律退回 auto。而 auto 在 REALITY 下
        #   解析成 stream-one (上下行**合流**) —— 分享出去再导入, 节点看起来
        #   一切正常, 只是没在分离。显式写了才不丢。
        # ★ mode 现在存在**元数据**里 (服务端片段按官方口径不再写它),
        #   所以两级取: 片段 (老节点) → 元数据 (新节点)。
        _mode = (n.get("mode") or (meta or {}).get("mode") or "").strip()
        if n.get("network") == "xhttp" and _mode:
            q["mode"] = _mode
        # ---- 官方 extra: 把 dl* 那套同时按官方形状发一份 ----
        #   (文档: 分享链接里只有 host/path/mode/extra 四项是通用的)
        if n.get("network") == "xhttp":
            import json as _json
            _ex = xhttp_extra(n, meta)
            if _ex:
                q["extra"] = _json.dumps(_ex, ensure_ascii=False,
                                         separators=(",", ":"))
        # ---- 上下行分离 ----
        # 分享链接是节点搬家的唯一途径, 下行那一套目的地不带过去,
        # 换台设备导入就退化成合流, 而且**看不出**。
        # ★ 放在 tls/reality 分支**外面** —— 放里面就只有 TLS 节点带得上,
        #   而上下行分离最常见的用法恰恰是 REALITY (见 node_build 的说明)。
        q.update(split_params(n, meta))
        qs = "&".join(f"{k}={_qval(v)}" for k, v in q.items() if v not in (None, ""))
        return f"vless://{n.get('id') or ''}@{_q(host)}:{port}?{qs}#{_q(name)}"

    if proto == "trojan":
        if n.get("security") == "reality" and not meta.get("public_key"):
            if notes is not None:
                notes.append(f"{n.get('tag') or '?'}: 未发布 —— REALITY 缺公钥(pbk)")
            return None
        _sec = client_security(n, meta)
        q = {"security": _sec, "type": n.get("network") or "tcp"}
        if _sec == "reality":
            sni = reality_sni(n)
            if sni:
                q["sni"] = sni
            q["fp"] = meta.get("fingerprint", "chrome")
            if meta.get("short_id"):
                q["sid"] = meta["short_id"]
            if meta.get("public_key"):
                q["pbk"] = meta["public_key"]
        elif _sec == "tls":
            sni = link_sni(n, meta)
            if sni:
                q["sni"] = sni
            ech = ech_param(n, host)
            if ech:
                q["ech"] = ech
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
        # ★ 参数名以**两家内核的解析器**为准 (实测 mihomo v1.19.32
        #   common/convert/converter.go:72-116 与 sing-box 面板
        #   src/conf/outbound_uri.py:441-509), 名字写错就是**静默忽略**:
        #     alpn      —— 两家都认 (mihomo 逗号切分)
        #     up/down   —— mihomo 认 (裸数字 = Mbps); sing-box 面板不认
        #     upmbps/downmbps —— sing-box 面板与本项目 conf/hysteria2.sh 认;
        #                        mihomo 只对已废弃的 hysteria v1 认这两个名字
        #   所以两个写法都写: 各自的解析器取自己认识的那个, 不认识的是普通
        #   未知参数 (mihomo 只看它认识的键, sing-box 面板同理, 都不会报错)。
        #   只写一种是实测过的坑: 旧链接里 upmbps=50 被 mihomo 整条丢掉,
        #   带宽提示等于没写。
        #
        #   sni 同理: 以前取的是 meta["host"], 生产上那是**连接地址** ——
        #   实测生成过 `sni=107.173.154.178`, 客户端拿 IP 校验证书必然失败。
        #   现在取证书/节点声明的域名, 拿不到就整个参数不写。
        q = {}
        sni = link_sni(n, meta)
        if sni:
            q["sni"] = sni
        q["insecure"] = "0"
        # hy2 走 QUIC, ALPN 必须是 h3 (节点自己的 tlsSettings.alpn 就是 h3);
        # 不写的话客户端可能一个 ALPN 都不带, 服务端直接不应答。
        q["alpn"] = n.get("alpn") or meta.get("alpn") or DEFAULT_HY2_ALPN
        # 显式设置 (.hy2-bandwidth) 优先; 没有才看逐节点记录, 最后才是默认
        bw_up, bw_down = hy2_bandwidth()
        up = (bw_up if bw_up is not None
              else (meta.get("upmbps") or meta.get("up") or DEFAULT_HY2_UP))
        down = (bw_down if bw_down is not None
                else (meta.get("downmbps") or meta.get("down") or DEFAULT_HY2_DOWN))
        q["up"] = up
        q["down"] = down
        q["upmbps"] = up
        q["downmbps"] = down
        if meta.get("mport"):
            q["mport"] = meta["mport"]
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
            "ech": "" if n.get("security") == "reality" else ech_param(n, host),
        }
        b = base64.b64encode(json.dumps(obj, ensure_ascii=False).encode()).decode()
        return f"vmess://{b}"

    return None


# =============================================== 载荷 ↔ per-node 产物 一致性
#
# 为什么必须有这道闸门
# --------------------
# 同一个节点有**两条**生成链接的路径, 它们各写各的:
#
#   A. per-node 产物  out/<proto>_share-<NN>.txt
#      —— 由各协议脚本 (conf/vlessxhttpecn.sh / conf/hysteria2.sh /
#      conf/Trojan.sh …) 在创建节点时写, 字段来自脚本自己的变量。
#   B. 订阅载荷       conf/lib/share_payload.py → build_share_link()
#      —— 只读 conf/*.json 片段 + out/share/<tag>.json 元数据**重建**。
#
# 实测事故 (RN 生产, 2026-10-10): 同一个 vless-xhttp08 节点,
#   A: vless://…&sni=moontv.6896698.xyz&…&ech=AGX%2BDQBhACA…
#   B: vless://…(没有 sni)(没有 ech)          ← 客户端静默退化成用 IP 当 SNI
# 而 hy2 的 B 把 sni 写成了节点 IP —— 三家客户端同时报
#   x509: cannot validate certificate for 107.173.154.178 … no IP SANs
#
# 所以: 载荷里每一条链接, 都必须与它**同名节点的 per-node 产物**在关键字段上
# 一致; 不一致就**拒发这一条并说明差在哪**, 而不是把两条互相矛盾的链接
# 分别交给不同的人。
#
# 只比对"两边都该有确定值"的字段, 不比对显示名 (载荷带旗帜+服务器前缀,
# 产物不带 —— 那是有意的, 见 build_share_link 里的 naming 说明)。
# 产物命名在四个协议脚本里**不统一**: hy2_share-04.txt / vless-xhttp_share-07.txt
# 用下划线, ss2022-share-02.txt / trojan-share-03.txt / reality-share-01.txt 用连字符。
# 只写 `*_share-*.txt` 会漏掉后一半 (实测: SS2022-02 / TROJAN-03 被判"无产物可比对")。
PRODUCT_GLOB = "*share-*.txt"

# 双方**任一**声明了就必须相等的字段。
#   缺失也是不一致: "产物有 sni、载荷没有"正是上面那个事故的形态。
CRITICAL_FIELDS = ("security", "type", "sni", "ech", "alpn", "path",
                   "pbk", "sid", "fp")
# 只在两边都声明时比对 (值本身是提示性的, 缺一个不算故障)。
SOFT_FIELDS = ("spx", "host", "insecure", "mport", "flow", "encryption")
# 带宽在两家内核里是两个名字 (up/upmbps), 同一件事。
ALIASES = {"up": ("up", "upmbps"), "down": ("down", "downmbps")}

_URI_RX = re.compile(
    r"^(?P<scheme>[a-zA-Z0-9]+)://(?P<userinfo>[^@]*)@"
    r"(?P<host>\[[^\]]*\]|[^:/?#]+):(?P<port>\d+)(?P<rest>[^#]*)(?:#(?P<frag>.*))?$")


def _split_uri(link):
    """把分享链接拆成 (scheme, credential, host, port, query, fragment)。

    vmess:// 是 base64 的 JSON, 不是 URI 形态 → 返回 None, 调用方跳过比对
    (它没有"host:port?query"可拆, 硬拆会得到假的差异)。
    """
    m = _URI_RX.match((link or "").strip())
    if not m:
        return None
    q = {}
    rest = m.group("rest") or ""
    if rest.startswith("?"):
        for kv in rest[1:].split("&"):
            if not kv:
                continue
            k, _, v = kv.partition("=")
            q[urllib.parse.unquote(k)] = urllib.parse.unquote(v)
    return {
        "scheme": m.group("scheme").lower(),
        "credential": urllib.parse.unquote(m.group("userinfo")),
        "host": m.group("host"),
        "port": m.group("port"),
        "query": q,
        "fragment": urllib.parse.unquote(m.group("frag") or ""),
    }


def node_credential(n):
    """节点在链接 userinfo 里的凭据 —— 用它把 tag 与 per-node 产物对上。

    产物文件名 (<proto>_share-<NN>.txt) 与 tag 之间**没有**可靠的机械映射
    (hy2 ↔ hysteria-04, SS2022-02 ↔ ss2022-share-02.txt, vless-xhttp07 ↔
    vless-xhttp_share-07.txt), 按文件名猜迟早会配错。凭据是唯一的:
    vless/vmess 是 uuid, trojan/hy2 是密码, ss 是 base64(method:password)。
    """
    if n.get("protocol") == "shadowsocks":
        raw = f"{n.get('method') or ''}:{n.get('password') or ''}".encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")
    return str(n.get("id") or n.get("password") or "")


def product_links(out_dir):
    """扫描 per-node 产物目录, 返回 ({凭据: (文件名, 链接)}, 坏行列表)。"""
    index, bad = {}, []
    if not out_dir or not os.path.isdir(out_dir):
        return index, bad
    for f in sorted(glob.glob(os.path.join(out_dir, PRODUCT_GLOB))):
        try:
            with open(f, encoding="utf-8") as fh:
                line = next((x.strip() for x in fh if x.strip()), "")
        except OSError as e:
            bad.append((os.path.basename(f), str(e)[:80]))
            continue
        u = _split_uri(line)
        if not u:
            continue                    # vmess / 非 URI 形态: 不参与比对
        index.setdefault(u["credential"], (os.path.basename(f), line, u))
    return index, bad


def _field(u, key):
    """取一个字段的值, 带宽类走别名。返回 "" 表示这一侧没有声明。"""
    q = u["query"]
    for name in ALIASES.get(key, (key,)):
        v = q.get(name)
        if v not in (None, ""):
            return str(v)
    return ""


def compare_payload_link(link, product):
    """载荷链接 vs per-node 产物链接 —— 返回 (verdict, [原因…])。

    verdict:
      · "ok"                    关键字段全一致
      · "endpoint-cdn-vs-origin" 端点不同, 但正是"CDN 边缘 ↔ 直连源站"这一对
                                (产物写域名:443, 载荷写源站 IP:端口)。这一对
                                是**允许**的, 但每次都要说出来, 不能沉默;
                                此时 ech 随端点绑定 —— 连源站时 CDN 的 ECH
                                配置必须不写。
      · "mismatch"              有实质冲突 → 调用方必须拒发这一条
    """
    pu = _split_uri(link)
    if pu is None or product is None:
        return "ok", []                 # 无法比对 (vmess) → 不假装比过, 由调用方记数
    pr = product[2] if isinstance(product, tuple) and len(product) > 2 else product
    notes, bad = [], []

    same_endpoint = (pu["host"] == pr["host"] and pu["port"] == pr["port"])
    cdn_pair = False
    if not same_endpoint:
        # 产物是域名 + 载荷是 IP ⇒ CDN 回源 vs 直连源站
        cdn_pair = (not is_ip_literal(pr["host"])) and is_ip_literal(pu["host"])
        msg = (f"端点不同: 产物 {pr['host']}:{pr['port']} / 载荷 "
               f"{pu['host']}:{pu['port']}")
        if cdn_pair:
            notes.append(msg + " —— 按既有规则允许 (CDN 边缘 ↔ 直连源站), "
                               "但两者可达性不同, 这里必须留痕")
        else:
            bad.append(msg)

    for key in CRITICAL_FIELDS:
        a, b = _field(pu, key), _field(pr, key)
        if key == "ech" and cdn_pair:
            # ECH 与端点绑定: 连源站时不该带 CDN 的 ECH 配置。
            if a:
                bad.append(f"ech: 载荷连的是源站却给 CDN 的 ECH 配置 ({a[:24]}…)")
            else:
                notes.append(f"ech: 产物为 CDN 形态 ({b[:24]}…), 载荷连源站故不写 —— "
                             "符合规则")
            continue
        if a == b:
            continue
        if a and b:
            bad.append(f"{key}: 载荷={a} 产物={b}")
        else:
            bad.append(f"{key}: 载荷={'有' if a else '缺'} 产物={'有' if b else '缺'}"
                       f" ({a or b})")
    for key in SOFT_FIELDS:
        a, b = _field(pu, key), _field(pr, key)
        if a != b:
            notes.append(f"{key}: 载荷={a or '(无)'} 产物={b or '(无)'}")
    if not bad:
        return ("endpoint-cdn-vs-origin" if cdn_pair else "ok"), notes
    return "mismatch", bad + notes


def verify_against_products(items, out_dir, notes=None):
    """把载荷链接逐条与 per-node 产物核对。

    items: [(tag, link)] —— 拒发的链接返回在 refused 里, 并给出**差在哪**。
    返回 (kept_items, refused, checked, unchecked) —— unchecked 是"没有产物
    可比对"的 tag 列表: 不比对上就少一条防线, 必须报出来而不是静默通过。
    """
    index, bad_files = product_links(out_dir)
    if notes is not None:
        for f, e in bad_files:
            notes.append(f"{f}: per-node 产物读不出来 ({e}) —— 未参与一致性校验")
    kept, refused, checked, unchecked = [], [], [], []
    for tag, link in items:
        cred = ""
        # 凭据从链接本身取, 不要求调用方再传节点视图 (少一处可能漂移的输入)
        u = _split_uri(link)
        if u:
            cred = u["credential"]
        product = index.get(cred)
        if not u or product is None:
            # ★ 没有产物可比对 ≠ 不一致: 保持发布 (否则"没有 per-node 产物的
            #   部署"会一条都发不出去), 但**记进 unchecked 报出来** ——
            #   少一条防线这件事不能被静默吞掉。
            unchecked.append(tag)
            kept.append((tag, link))
            continue
        checked.append(tag)
        verdict, why = compare_payload_link(link, product)
        if verdict == "mismatch":
            refused.append((tag, f"与 per-node 产物 {product[0]} 不一致 —— "
                                 + "; ".join(why)))
            if notes is not None:
                notes.append(f"{tag}: 拒发 —— 载荷与 {product[0]} 不一致: "
                             + "; ".join(why))
            continue
        if notes is not None and why:
            notes.append(f"{tag}: 与 {product[0]} 核对通过 ({verdict}); "
                         + "; ".join(why))
        kept.append((tag, link))
    return kept, refused, checked, unchecked
