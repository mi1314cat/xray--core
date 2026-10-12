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
    elif node.get("dl_ech_enable"):
        dl["ech-opts"] = {"enable": True}

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
    if proto != "vless":
        # mihomo 的 xhttp **仅 VLESS 支持** (官方文档明写), 其他协议
        # 即便 X 内核接受, mihomo 侧也起不来。
        if str(node.get("network") or node.get("transport") or "").lower() == "xhttp":
            return None
        return None

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
        out["grpc-opts"] = {
            "grpc-service-name": str(node.get("path") or node.get("service_name") or "")}
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
    elif node.get("ech_declared") or node.get("ech_enable"):
        out["ech-opts"] = {"enable": True}

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


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv))