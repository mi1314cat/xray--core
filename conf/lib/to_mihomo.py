"""把面板的节点视图翻译成 **mihomo** 的 YAML 节点。

为什么需要它
------------
X 面板的节点数据只有一份 (`conf/lib/node_build.py` 生成), 但客户端产物有两种:
Xray 用 JSON, mihomo 用 YAML。两边的字段名、嵌套层级、**能力边界都不一样**,
所以必须各写各的 —— 不能"生成 JSON 再想办法转 YAML":

  传输层    Xray `streamSettings.xhttpSettings`  vs  mihomo `xhttp-opts`
  ECH       Xray `echConfigList` (字符串)        vs  mihomo `ech-opts{enable,config}`
  证书校验  Xray 26.x 只有 `pinnedPeerCertSha256` vs  mihomo `skip-cert-verify`
  上下行    Xray `downloadSettings`             vs  mihomo
            `xhttp-opts.download-settings` ← 官方文档确认支持, 且分成
            **xhttp 部分**与 **proxy 部分**两段

★ 关于 mihomo 的上下行分离
-------------------------
曾经记过一条"mihomo 的 xhttp-opts 表达不了 downloadSettings"——**那是错的**。
错因是拿我们自己的读取端 (`Client/lib/node.py` 的 mihomo 解析器) 当成了
整个生态的能力上限。官方文档里写得很清楚:

    xhttp-opts:
      download-settings:
        ## xhttp part
        path / host / reuse-settings
        ## proxy part
        server / port / tls / alpn / ech-opts / reality-opts /
        skip-cert-verify / fingerprint / servername / client-fingerprint

而且是**逐项覆盖**语义: "每一项如果不填写则会沿用上行参数"。
所以这里只写**真正要覆盖**的项, 其余交给 mihomo 自己继承 ——
既少写一大半, 也不会因为写全了反而和上游默认值打架。
"""
import ipaddress
import sys

# mihomo 侧 xhttp 的 mode 取值比 Xray 少一个: Xray 有 auto, mihomo 文档
# 写的是 "auto, stream-one, stream-up or packet-up" —— 一致, 所以原样透传。
_MIHOMO_XHTTP_MODES = ("auto", "stream-one", "stream-up", "packet-up")


def _is_ip(v):
    try:
        ipaddress.ip_address(str(v))
        return True
    except ValueError:
        return False


def _server(value, default=""):
    """mihomo 的 server 字段: IP 原样, 域名原样, 空值不写。"""
    s = str(value or "").strip()
    return s or default


# ================================================================ 片段 → 节点视图
#
# ★ 为什么需要这一层 (原来没有, 所以本文件一直没有生产调用方)
#
#   proxy() 要的是**客户端视角**的字段; 而服务端手上只有另外两个视角:
#
#     inbound 片段     listen / privateKey / xhttpSettings.mode   (服务端视角)
#     分享元数据 sidecar 对外 host / public_key / fingerprint      (发布视角)
#
#   缺了这一层, 谁也没法把片段喂给 proxy() —— 片段里根本没有 `address`,
#   REALITY 只有 `privateKey` (客户端要的是 publicKey), `mode` 藏在
#   `xhttpSettings` 里而不是顶层。以前各处只能自己手写 YAML heredoc,
#   于是 5 个协议脚本各写一份, 而带上下行分离的那一份谁都没写。
#
#   nodes.extract() 不能干这个活: 它产出的是**分享链接**要的字段, 没有
#   address / reality_public_key / fingerprint / mode / pinned_cert_sha256。

def node_from_fragment(frag, meta=None, name=None):
    """inbound 片段 (+ 分享元数据) → proxy() 认得的节点视图。

    frag 可以是整份 {"inbounds": [...]}, 也可以是单个 inbound。
    meta 是 share_meta 的内容 (host / port / public_key / short_id / fingerprint)。
    拼不出来的字段留空 —— proxy() 会对缺关键字段的情况返回 None, 由调用方报出来。
    """
    meta = meta or {}
    meta = dict(meta)
    ibs = frag.get("inbounds") if isinstance(frag, dict) else None
    ib = (ibs[0] if ibs else frag) or {}
    ss = ib.get("streamSettings") or {}
    settings = ib.get("settings") or {}
    net = ss.get("network") or "tcp"
    sec = ss.get("security") or "none"
    # ★ nginx 档: 片段里是 security:none (TLS 由 nginx 终结, nginx→xray 明文),
    #   而客户端连的是 nginx 的 443 —— 必须走 TLS。
    #   照搬片段里那个的话, 生成的 YAML 会写 `tls: false`, 客户端就用明文
    #   去连 HTTPS 端口: 实测 mihomo 先发明文 HTTP/2 前言再发 TLS,
    #   Cloudflare 直接关连接, 客户端 000 而服务端日志一片空白。
    #   本机自测看不出来 (nginx 自己会 400), 所以这个分叉特别隐蔽。
    if str(meta.get("tier") or "").strip().lower() == "nginx" and sec == "none":
        sec = "tls"

    def _norm_path(p):
        p = str(p or "").strip()
        return p or ""

    node = {
        "tag": ib.get("tag") or "",
        "name": name or meta.get("name") or ib.get("tag") or "",
        "protocol": ib.get("protocol") or "",
        "network": net,
        "security": sec,
        # 对外地址走元数据 —— 片段里的 listen 是 0.0.0.0 / 127.0.0.1, 不是客户端该连的
        "address": meta.get("host") or "",
        "port": meta.get("port") or ib.get("port"),
        "path": _norm_path((ss.get("xhttpSettings") or {}).get("path")
                           or (ss.get("wsSettings") or {}).get("path")
                           or (ss.get("httpupgradeSettings") or {}).get("path")
                           or ""),
    }

    # ---- 凭据 ----
    node["id"] = meta.get("uuid") or ""
    clients = settings.get("clients") or []
    if ib.get("protocol") == "vless":
        node["id"] = (clients[0].get("id") if clients else "") or ""
        # ★ 客户端那一半**只能**来自元数据 (它由 xray vlessenc 与本节点的服务端
        #   密钥**成对**生成, 客户端和服务端各拿一半, 不能互推)。
        #
        #   这里以前有个"取不到就用服务端 decryption 顶上"的兜底 —— 那是错的,
        #   而且错得很隐蔽: 服务端片段完全正确, 面板一路绿灯, 客户端产物看起来
        #   也像那么回事, 只有真连的时候炸。实测两种客户端的表现:
        #       mihomo → proxy 0: invaild vless encryption value: …600s.…
        #       Xray   → 握手失败
        #   所以取不到就如实留空, 由 enc_unsupported 拒绝出产物并把原因讲清楚。
        node["encryption"] = (meta.get("encryption") or "").strip() or "none"
        # 服务端那一半带着走: 判断"这个节点到底要不要会话加密"要用它 ——
        # 服务端要、客户端没有, 等于这条节点怎么配都连不上。
        node["vless_srv_decryption"] = str(settings.get("decryption") or "")
        # flow 只在裸 TCP 上成立 (内核: XTLS only supports TLS and REALITY
        # directly) —— 这里如实带出去, 拦不拦由生成期的护栏决定。
        node["flow"] = (clients[0].get("flow") if clients else "") or ""
    elif ib.get("protocol") == "vmess":
        node["id"] = (clients[0].get("id") if clients else "") or ""
        node["alter_id"] = (clients[0].get("alterId") if clients else 0) or 0
    elif ib.get("protocol") == "trojan":
        node["password"] = (clients[0].get("password") if clients else "") or ""
    elif ib.get("protocol") in ("hysteria", "hysteria2"):
        node["password"] = (clients[0].get("auth") if clients else "") or ""
    elif ib.get("protocol") == "shadowsocks":
        node["method"] = settings.get("method") or ""
        node["password"] = settings.get("password") or ""
    if meta.get("encryption"):
        node["encryption"] = meta["encryption"]

    # ---- 传输细节 ----
    xh = ss.get("xhttpSettings") or {}
    node["mode"] = xh.get("mode") or ""
    node["host"] = xh.get("host") or (ss.get("wsSettings") or {}).get(
        "headers", {}).get("Host") or ""
    node["grpc_service"] = (ss.get("grpcSettings") or {}).get("serviceName") or ""
    # grpc 的 serviceName 不是 URI 路径, 别让它落进 path —— 那会让
    # ws/httpupgrade 的分支误以为有 path, 也会让 grpc 的取值来源变模糊。
    if net == "grpc" and node["grpc_service"]:
        node["path"] = ""
    node["alpn"] = (ss.get("tlsSettings") or {}).get("alpn") or []
    # Hysteria2 的 salamander 混淆在 streamSettings.finalmask.udp 里 (全小写)。
    _fm = ss.get("finalmask") or {}
    for _m in (_fm.get("udp") or []):
        if str(_m.get("type") or "").lower() == "salamander":
            node["hy2_obfs_password"] = (_m.get("settings") or {}).get("password") or ""
            break

    # ---- TLS / REALITY ----
    ts = ss.get("tlsSettings") or {}
    rs = ss.get("realitySettings") or {}
    if sec == "reality":
        names = rs.get("serverNames") or []
        node["sni"] = meta.get("sni") or (names[0] if names else "")
        # ★ 片段里是 privateKey (服务端), 客户端要的是 publicKey —— 只能从元数据来。
        #   缺了就是连不上的节点, proxy() 会返回 None, 不会生成一条假链接。
        node["reality_public_key"] = meta.get("public_key") or ""
        node["reality_short_id"] = meta.get("short_id") or ""
        node["fingerprint"] = meta.get("fingerprint") or "chrome"
    elif sec == "tls":
        node["sni"] = (meta.get("sni") or ts.get("serverName")
                       or (meta.get("host") if str(meta.get("tier") or "").lower() == "nginx" else "")
                       or "")
        node["pinned_cert_sha256"] = (meta.get("pinned_cert_sha256")
                                      or ts.get("pinnedPeerCertSha256") or "")
        # 服务端字段是 echServerKeys, 客户端才是 echConfigList —— 库里不能互相顶替。
        # 元数据里的 `ech` 如果是 True (只声明"开了") 而不是一串配置, 就不能当
        # config 用: 喂给 mihomo 会得到 config: "True"。
        node["ech"] = meta.get("ech_config") or ""
        node["ech_enable"] = bool(meta.get("ech"))

    # ---- 上下行分离 ----
    dl = xh.get("downloadSettings") or {}
    if dl.get("address"):
        node["dl_address"] = dl.get("address") or ""
        node["dl_port"] = dl.get("port") or ib.get("port")
        node["dl_security"] = dl.get("security") or sec
        dlts = dl.get("tlsSettings") or {}
        dlrs = dl.get("realitySettings") or {}
        dlxh = dl.get("xhttpSettings") or {}
        node["dl_sni"] = (dlrs.get("serverName") or dlts.get("serverName")
                          or node["sni"] or "")
        # ★ 用 .get() 兜底, 不能直接下标。
        #   上行是 **TLS** 而下行是 REALITY 时 (就是 cdn-reality 那个组合),
        #   reality_public_key / reality_short_id 这两个键**根本没被设置** ——
        #   它们在 `sec == "reality"` 分支里才写。直接下标会 KeyError,
        #   而报错发生在生成客户端产物的半路, 用户看到的是一串 python 回溯。
        #   (实测: RN 上拿真实的 cdn-reality 节点喂 node_from_fragment 当场炸。)
        node["dl_public_key"] = dlrs.get("password") or node.get("reality_public_key") or ""
        node["dl_short_id"] = dlrs.get("shortId") or node.get("reality_short_id") or ""
        node["dl_mode"] = dlxh.get("mode") or node["mode"]
        node["dl_path"] = dlxh.get("path") or node["path"]
        node["dl_ech"] = meta.get("dl_ech_config") or ""
        node["dl_ech_enable"] = bool(meta.get("dl_ech"))

    return node


def xhttp_download_settings(node):
    """上下行分离在 mihomo 侧的形状; 没配下行就返回 None。

    官方示例是**两段**: xhttp 部分 (path/host/reuse-settings) 与
    proxy 部分 (server/port/tls/reality-opts/ech-opts/servername...)。我们
    两段都写 —— 因为「换目的地」正是上下行分离的目的, 只写一半等于没分离。
    """
    addr = str(node.get("dl_address") or "").strip()
    if not addr:
        return None

    dl = {"server": _server(addr)}

    port = node.get("dl_port")
    if port:
        try:
            dl["port"] = int(port)
        except (TypeError, ValueError):
            pass

    # ---- proxy 部分: 下行那一侧自己的 TLS 层 ----
    sec = (node.get("dl_security") or node.get("security") or "none").lower()
    sni = (node.get("dl_sni") or node.get("sni") or "").strip()
    if sec == "reality":
        # 下行公钥缺省沿用上行 —— 这不是"忘了检查", 是有意的:
        # 上下行分离最常见的形态是**同一台服务器的两个域名**(双域名)或
        # 上下行打到同一端口, 那里 REALITY 密钥本来就是同一个。node_build
        # 的 _xhttp_download_settings 用的是同一条规则, 两边必须一致。
        # 真正要跨机器时由调用方显式给 dl_public_key 覆盖。
        pbk = (node.get("dl_public_key") or node.get("reality_public_key") or "").strip()
        if not pbk:
            # 两边都没有公钥 = 这条下行连不上 (内核会报 invalid password)。
            # 与其生成一条看着完整的节点让用户排查到怀疑人生, 不如不生成。
            return None
        ropts = {"public-key": pbk}
        sid = (node.get("dl_short_id") or node.get("reality_short_id") or "").strip()
        if sid:
            ropts["short-id"] = sid
        dl["reality-opts"] = ropts
        dl["tls"] = True
        if sni:
            dl["servername"] = sni
        fp = node.get("fingerprint") or node.get("client_fingerprint")
        if fp:
            dl["client-fingerprint"] = fp
    elif sec == "tls":
        dl["tls"] = True
        if sni:
            dl["servername"] = sni
        if node.get("dl_pinned_cert_sha256"):
            # Xray 那边只能钉 pin; mihomo 这边可以用 skip-cert-verify,
            # 但钉证书更安全, 所以优先用 pin。
            dl["certificate"] = node["dl_pinned_cert_sha256"]
    else:
        dl["tls"] = False

    # ECH: 下行也要开时, 一并带过去 (CDN 档最常见的形态)
    ech = str(node.get("dl_ech") or "").strip()
    if ech:
        dl["ech-opts"] = {"enable": True, "config": ech}
    # ★ 同上: 没有配置串就不写 `enable: true` —— 那会让 mihomo 自己去查 DNS,
    #   查不到就把整条下行打成连不上。

    # ---- xhttp 部分 ----
    xh = {}
    path = str(node.get("dl_path") or node.get("path") or "").strip()
    if path:
        xh["path"] = path
    host = str(node.get("dl_host") or node.get("host") or "").strip()
    if host:
        xh["host"] = host
    mode = (node.get("dl_mode") or node.get("mode") or "").strip()
    if mode:
        if mode not in _MIHOMO_XHTTP_MODES:
            # 不认识的 mode 原样透传会让 mihomo 启动失败, 这里挡在生成阶段。
            return None
        xh["mode"] = mode
    if xh:
        dl.update(xh)
    return dl


def xhttp_opts(node):
    """mihomo 的 xhttp-opts; 带上下行时含 download-settings。"""
    opts = {}
    path = str(node.get("path") or "").strip()
    if path:
        opts["path"] = path
    host = str(node.get("host") or "").strip()
    if host:
        opts["host"] = host
    mode = (node.get("mode") or "").strip()
    if mode:
        if mode not in _MIHOMO_XHTTP_MODES:
            return None
        opts["mode"] = mode
    if (node.get("sc_max_each_post_bytes") or "").strip():
        # 服务端会拒绝超过上限的 POST, 所以这项必须两端一致。
        v = node["sc_max_each_post_bytes"]
        opts["sc-max-each-post-bytes"] = int(v) if str(v).isdigit() else v
    if (node.get("sc_min_posts_interval_ms") or "").strip():
        v = node["sc_min_posts_interval_ms"]
        opts["sc-min-posts-interval-ms"] = int(v) if str(v).isdigit() else v

    dl = xhttp_download_settings(node)
    if dl:
        opts["download-settings"] = dl
    return opts


def proxy(node):
    """一个节点 → mihomo proxies 条目 (dict)。不支持的组合返回 None。"""
    proto = str(node.get("protocol") or "").lower()
    net0 = str(node.get("network") or node.get("transport") or "tcp").lower()

    # mihomo 的 xhttp **仅 VLESS 支持** —— 官方文档原文:
    #   "仅 VLESS 支持 xhttp 传输层, 请勿在其他协议上使用"
    #   (https://wiki.metacubex.one/config/proxies/transport/#xhttp-opts)
    # 别的协议即便 X 内核接受, mihomo 侧也起不来 —— 生成出来只会让人以为能用。
    if net0 == "xhttp" and proto != "vless":
        return None

    # VLESS 会话加密 (Xray 独有): mihomo 拿到就直接拒绝加载**整份配置** ——
    # 不是"这个节点不可用", 是**所有节点一起起不来**。实测见 enc_unsupported。
    if enc_unsupported(node):
        return None

    if proto == "vmess":
        uid = (node.get("id") or node.get("uuid") or "").strip()
        if not uid:
            return None
        out = {
            "name": str(node.get("name") or node.get("tag") or "x"),
            "type": "vmess",
            "server": _server(node.get("address")),
            "port": int(node.get("port") or 443),
            "uuid": uid,
            "alterId": int(node.get("alter_id") or 0),
            "cipher": str(node.get("cipher") or "auto"),
            "udp": True,
        }
    elif proto == "trojan":
        pw = (node.get("password") or "").strip()
        if not pw:
            return None
        out = {
            "name": str(node.get("name") or node.get("tag") or "x"),
            "type": "trojan",
            "server": _server(node.get("address")),
            "port": int(node.get("port") or 443),
            "password": pw,
            "udp": True,
        }
    elif proto == "shadowsocks":
        method = (node.get("method") or "").strip()
        pw = (node.get("password") or "").strip()
        if not method or not pw:
            return None
        out = {
            "name": str(node.get("name") or node.get("tag") or "x"),
            "type": "ss",
            "server": _server(node.get("address")),
            "port": int(node.get("port") or 443),
            "cipher": method,
            "password": pw,
            "udp": True,
        }
        # ★ mihomo 的 ss 出站既没有 REALITY 层, 也没有 TLS 层 —— 这两个都是
        #   Xray 对 shadowsocks 的扩展, mihomo 侧没有等价物。
        #   实测 (CC→RN): 带 tls 的 ss 节点 curl 得 000, 而同机其它协议全 200。
        #   与其生成一条"看着正常、连不上"的条目, 不如明确拒发让调用方说出原因。
        #   (别被 mihomo -t 骗了: 它对 ss+tls 是**放行**的, 只有真连才发现不通。)
        if str(node.get("security") or "none").lower() in ("reality", "tls"):
            return None
    elif proto in ("hysteria", "hysteria2"):
        pw = (node.get("password") or "").strip()
        if not pw:
            return None
        out = {
            "name": str(node.get("name") or node.get("tag") or "x"),
            "type": "hysteria2",
            "server": _server(node.get("address")),
            "port": int(node.get("port") or 443),
            "password": pw,
        }
        # Hysteria2 混淆 (salamander)。★ 两个字段**必须成对出现** ——
        # 项目自己在这一条上踩过: 一条 `hysteria2://…&obfs=none` 让 mihomo 报
        #   initial proxy provider error: proxy 0 error: missing obfs password
        # 而且是**整批**归零, 不是只丢那一条。所以只在一起写。
        obfs = str(node.get("hy2_obfs_password") or "").strip()
        if obfs:
            out["obfs"] = "salamander"
            out["obfs-password"] = obfs
    elif proto == "socks":
        out = {
            "name": str(node.get("name") or node.get("tag") or "x"),
            "type": "socks5",
            "server": _server(node.get("address")),
            "port": int(node.get("port") or 1080),
        }
    elif proto == "http":
        out = {
            "name": str(node.get("name") or node.get("tag") or "x"),
            "type": "http",
            "server": _server(node.get("address")),
            "port": int(node.get("port") or 8080),
        }
    elif proto == "vless":
        uid = (node.get("id") or node.get("uuid") or "").strip()
        if not uid:
            return None
        out = {
            "name": str(node.get("name") or node.get("tag") or "x"),
            "type": "vless",
            "server": _server(node.get("address")),
            "port": int(node.get("port") or 443),
            "uuid": uid,
            "udp": True,
            "encryption": str(node.get("encryption") or "none"),
        }
    else:
        return None
    if not out["server"]:
        return None

    net = str(node.get("network") or node.get("transport") or "tcp").lower()
    sec = str(node.get("security") or "none").lower()
    sni = (node.get("sni") or "").strip()

    if net == "xhttp":
        xh = xhttp_opts(node)
        if xh is None:
            return None
        out["network"] = "xhttp"
        # mihomo 默认只支持 h2; 别的要靠 alpn 显式声明。
        alpn = node.get("alpn")
        if alpn:
            out["alpn"] = alpn if isinstance(alpn, list) else str(alpn).split(",")
        else:
            out["alpn"] = ["h2"]
        if xh:
            out["xhttp-opts"] = xh
    elif net in ("ws", "websocket"):
        out["network"] = "ws"
        ws = {"path": str(node.get("path") or "/")}
        host = (node.get("host") or "").strip()
        if host:
            ws["headers"] = {"Host": host}
        out["ws-opts"] = ws
    elif net in ("grpc",):
        out["network"] = "grpc"
        # ★ 服务名从哪儿来: 适配层 (node_from_fragment) 把它放在 `grpc_service`,
        #   而这里原来只读 path / service_name —— 于是生成出
        #   `grpc-service-name: ''`, 与服务端的 `grpcSettings.serviceName` 对不上,
        #   连接**必定失败**且没有任何报错。
        #   实测 (CC→RN): grpc 节点 curl 得 000, 而同机其它协议全 200。
        out["grpc-opts"] = {
            "grpc-service-name": str(node.get("grpc_service")
                                     or node.get("service_name")
                                     or node.get("path") or "")}
    elif net in ("hysteria", "hysteria2"):
        # ★ Hysteria2 走的是 QUIC/UDP, mihomo 的 hysteria2 出站**不写 network**
        #   (类型本身就说明了一切)。这里原来没有这一支, 于是 net="hysteria"
        #   落到下面的 else —— 而 else 只认 tcp/raw/空, 直接 return None:
        #   **hysteria2 节点永远生成不出 mihomo YAML**。
        #   (以前没暴露, 是因为 to_mihomo.py 根本没有生产调用方。)
        pass
    else:
        out["network"] = "tcp"
        if net not in ("tcp", "raw", ""):
            return None

    if sec == "reality":
        pbk = (node.get("reality_public_key") or "").strip()
        if not pbk:
            return None
        ropts = {"public-key": pbk}
        sid = (node.get("reality_short_id") or "").strip()
        if sid:
            ropts["short-id"] = sid
        out["reality-opts"] = ropts
        out["client-fingerprint"] = str(node.get("fingerprint") or "chrome")
        if sni:
            out["servername"] = sni
        out["tls"] = True
    elif sec == "tls":
        out["tls"] = True
        if sni:
            out["servername"] = sni
        if node.get("pinned_cert_sha256"):
            out["certificate"] = node["pinned_cert_sha256"]
        elif node.get("allow_insecure"):
            # 只在没有 pin 可用时才退到跳过校验, 并且必须如实记下来。
            out["skip-cert-verify"] = True
    else:
        out["tls"] = False

    ech = str(node.get("ech") or "").strip()
    if ech:
        out["ech-opts"] = {"enable": True, "config": ech}
    # ★ 这里**故意**没有"没有配置串也写个 enable: true"的分支。
    #   实测那样做会把整条节点打成不可用: mihomo 会去自己查 DNS, 查不到就
    #       resolve ECH config error: no ECH config found in DNS records
    #   直接连不上 (HTTP=000) —— 比不开 ECH 糟得多, 而用户看到的是"节点坏了"。
    #   取不到配置串时宁可不写这一项: 节点至少是通的, 而"为什么没有 ECH"
    #   由生成节点那一刻的警告说清楚 (见 deploy.plan)。

    if (node.get("flow") or "").strip():
        out["flow"] = str(node["flow"]).strip()

    return out


def build(nodes, name="xray-panel"):
    """一组节点 → mihomo 代理组配置 (dict)。"""
    proxies = [p for p in (proxy(n) for n in nodes) if p]
    return {"proxies": proxies}


def _cli(argv):
    import argparse
    import json

    ap = argparse.ArgumentParser(description="节点 → mihomo YAML")
    ap.add_argument("--node", help="单个节点 JSON 文件")
    ap.add_argument("--nodes", help="节点列表 JSON 文件")
    ap.add_argument("--output", help="输出 YAML 路径 (默认 stdout)")
    ap.add_argument("--group", default="🚀 节点选择")
    a = ap.parse_args(argv[1:])

    if a.node:
        with open(a.node, encoding="utf-8") as fh:
            nodes = [json.load(fh)]
    elif a.nodes:
        with open(a.nodes, encoding="utf-8") as fh:
            nodes = json.load(fh)
    else:
        ap.error("需要 --node 或 --nodes")

    cfg = build(nodes)
    doc = {"proxies": cfg["proxies"]}
    if cfg["proxies"]:
        doc["proxy-groups"] = [{"name": a.group, "type": "select",
                                "proxies": [p["name"] for p in cfg["proxies"]]}]

    text = _dump(doc)
    if a.output:
        with open(a.output, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(a.output, file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def _dump(doc):
    try:
        import yaml
        return yaml.safe_dump(doc, allow_unicode=True, sort_keys=False,
                              default_flow_style=False)
    except ImportError:
        # 没有 PyYAML 时给一份够用的最小 YAML —— mihomo 配置结构简单,
        # 但**不能**退化成 JSON: mihomo 的 YAML 解析器认 JSON, 而用户
        # 打开 .yaml 想看的是 YAML。
        import json
        return json.dumps(doc, ensure_ascii=False, indent=2)


# ================================================================ 产物落盘
#
# ★ 为什么产物必须由**建节点的那一步**生成, 而不是"以后想看再转"
#
#   1. 建完节点不产出 YAML, 用户就只能"按文档自己拼" —— 而 xhttp 的
#      download-settings 是两段式、逐项覆盖语义, 手拼必错;
#   2. 上下行分离**只存在于服务端配置里**, 时间一长没人记得这个节点是分离的;
#   3. 定式: SB 在 lib.sh 里记过教训 —— 手写 YAML 漂移过 (trojan 漏指纹、
#      vless 漏 pin), 所以它有 gen_mihomo_yaml 这一个唯一转换器。
#      X 这边 5 个协议脚本各写一份 heredoc, 正是那个教训的重演。

def write_products(frag, meta, out_dir, name=None, tag=None):
    """片段 + 元数据 → out/<tag>.yaml。返回 (路径, 原因)。

    路径为 None 时 `原因` 说明**为什么没生成** —— 不生成必须看得见,
    静默少一个文件正是这个项目既往缺陷的共同形态。

    只写 mihomo YAML: Xray 客户端的出站 JSON 由各协议脚本自己写 (见
    conf/vlessxhttpecn.sh 等), 服务端这条路径还没有等价生成器 —— 那是
    另一件事, 不在这里顺手造一个半成品。
    """
    import os
    node = node_from_fragment(frag, meta, name=name)
    if tag:
        node["tag"] = tag
    if not node.get("tag"):
        return None, "片段里没有 tag"
    p = proxy(node)
    if not p:
        why = _why_unsupported(node)
        return None, why
    os.makedirs(out_dir, exist_ok=True)
    dest = os.path.join(out_dir, f"{node['tag']}.yaml")
    doc = {"proxies": [p]}
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(_dump(doc))
    return dest, ""


# mihomo 认的 VLESS encryption 取值。
#
# ★ 这条是实测出来的 (mihomo v1.19.32): Xray 的 VLESS Encryption 串
#   `mlkem768x25519plus.native.600s.<密钥>` 交给 mihomo, 它**整个配置都不加载**:
#       level=error msg="proxy 0: invaild vless encryption value: mlkem768x25519plus..."
#       configuration file ... test failed
#   也就是说产出一份 mihomo YAML 等于产出一份"客户端起不来"的配置 ——
#   而屏幕上只写着"已写入客户端产物"。宁可不出这份文件, 把原因讲清楚。
#
#   注意 mihomo 里确实有 mlkem (它的 ECH/TLS 栈用它), 但那不是同一个东西:
#   那是 TLS 层, 这是 VLESS 应用层的会话加密。名字像, 不能互推。
_MIHOMO_VLESS_ENC_OK = ("", "none")


def enc_unsupported(node):
    """这个节点的 VLESS encryption mihomo 吃不吃得下。吃得下返回 ""。

    ★ 结论来自实测 (mihomo v1.19.32), 不是猜的:
        mlkem768x25519plus.native.0rtt.<客户端公钥>   → 接受
        mlkem768x25519plus.native.600s.<服务端私钥>   → 拒绝
            proxy 0: invaild vless encryption value: …
      也就是说 mihomo **是支持**后量子 VLESS 会话加密的, 它只认客户端那一种形态。
      所以这里不能一刀切成"不支持" —— 那种判据会把本来能用的节点拒之门外,
      真正要挡的是"把服务端那一半写进客户端"。
    """
    proto = str(node.get("protocol") or "").lower()
    if proto != "vless":
        return ""
    enc = str(node.get("encryption") or "").strip()
    srv = str(node.get("vless_srv_decryption") or "").strip()
    if enc.lower() in _MIHOMO_VLESS_ENC_OK:
        # 客户端没写, 但**服务端要求**会话加密 —— 那不是"这个节点没加密",
        # 是"这条节点怎么配都连不上"。必须挡下来, 否则用户拿到一份
        # 看起来正常、导入也不报错的配置, 然后永远连不上。
        if srv and srv.lower() != "none" and srv.startswith("mlkem"):
            return ("服务端要求 VLESS 会话加密, 但这个节点的客户端那一半密钥取不到 "
                    "(它由 xray vlessenc 与服务端密钥成对生成, 推不出来)。"
                    "用菜单 13 重建这条节点 —— 重建时会同时取到两半")
        return ""
    if enc.startswith("mlkem768x25519plus.native.0rtt."):
        return ""
    if enc.startswith("mlkem768x25519plus.native.600s."):
        return ("客户端加密串写成了服务端的 decryption (600s)。"
                "客户端要用 0rtt 那一半 —— 两个串由 xray vlessenc 成对生成, 不能混用。"
                "用菜单 13 重建这条节点即可")
    return (f"VLESS 会话加密 {enc.split('.')[0]} 的形态 mihomo 不认 "
            f"(实测它只认 mlkem768x25519plus.native.0rtt.<客户端公钥>)")


def _why_unsupported(node):
    """proxy() 返回 None 时, 说清是**哪一条**不满足。

    不这么做的后果是屏幕上只有一句"没生成 YAML", 而用户手上那份服务端配置
    看起来完全正常 —— 排查会从"是不是文件权限"开始, 浪费很久。
    """
    proto = str(node.get("protocol") or "").lower()
    net = str(node.get("network") or "tcp").lower()
    sec = str(node.get("security") or "none").lower()
    if net == "xhttp" and proto != "vless":
        return f"mihomo 的 xhttp 仅 VLESS 支持, 本节点是 {proto} (官方文档 xhttp-opts 节)"
    if not node.get("address"):
        return "节点没有对外地址 (分享元数据里缺 host)"
    if proto == "shadowsocks" and sec in ("reality", "tls"):
        return (f"mihomo 的 ss 出站没有 {sec.upper()} 层 "
                f"(那是 Xray 对 shadowsocks 的扩展, mihomo 无等价物)")
    if sec == "reality" and not node.get("reality_public_key"):
        return "REALITY 缺公钥 (pbk) —— 分享元数据里没有 public_key"
    if not (node.get("id") or node.get("password")):
        return "缺凭据 (uuid / password)"
    _enc_bad = enc_unsupported(node)
    if _enc_bad:
        return _enc_bad
    if net not in ("xhttp", "ws", "websocket", "grpc", "tcp", "raw", ""):
        return f"mihomo 不支持 {net} 传输"
    return f"不支持的组合: {proto} + {net} + {sec}"


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv))