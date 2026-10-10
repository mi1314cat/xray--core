#!/usr/bin/env python3
"""Xray **原生产品** —— 同内核同发行版的客户端拉这一份, 不走 URI。

    · 普通话产品 = base64 的 URI 列表 (conf/lib/share_payload.py, 一字未改)
    · 原生产品   = Xray 客户端出站 JSON 文档 (本文件)

两者的关系（设计: proxy-node-compat/docs/three-way-interop.md §5）:

    节点集合必须**完全一致**  —— 以 URI 路径为发布闸门: build_share_link() 判
        "不该发布"的节点 (只绑回环又没 nginx / REALITY 缺公钥 …), 原生文档里也
        不许有。两条产品给不同的人, 发布的节点却不一样, 是最难查的一类错。
    字段只许多不许少        —— 原生能表达 URI 表达不了的 (ech / xhttp mode /
        grpc serviceName / 证书 pin), 这正是"零损失路径"的意义; 反过来,
        URI 有的字段原生必须有 (门禁按客户端解析结果逐字段断言)。

为什么是 Xray JSON 而不是别的:
  · 客户端 `Client/lib/node.py:parse_xray_json()` 本来就吃这个形状 (粘贴导入
    支持 Xray JSON), 所以"零损失"不是新造一条读取路径;
  · Xray 的配置词汇表就是这套字段名, 不存在"我们自己发明的中间格式"。

**不做**的事:
  · 不在这里决定客户端最终配置怎么写 (ws 的 ?ed=、hysteria 的 network/method
    双写、mux 开关 —— 那些是 conf/lib/../Client/lib/genconfig.py 的职责,
    是"客户端自己的事实", 不是"节点是什么")。本文件只如实描述节点。
  · 不猜字段: 片段里没写的 (xhttp mode / grpc serviceName 之类) 要么按片段里
    声明的原值写, 要么不写。
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nodes as N                    # noqa: E402  同一份节点视图 + 同一份发布闸门
import share_meta                    # noqa: E402

CONF_DIR = os.environ.get("XRAY_CONF_DIR", "/root/catmi/xray/conf")
SHARE_DIR = os.environ.get("XRAY_SHARE_DIR", "/root/catmi/xray/out/share")

PRODUCT_SOURCE = "xray--core"

# ---- 客户端 ECH 配置的载体（官方字段名）----
# 服务端片段里是 tlsSettings.echServerKeys, 客户端配置里是 tlsSettings.echConfigList。
# 官方约定: server keys = 2 字节(大端)私钥长度 + 私钥 + ECHConfigList, 客户端要的是
# 后半段。真值对照 (RN 生产 vless-xhttp08): 用本函数算出来的字符串与
# `xray tls ech -i <keys>` 打印的 "ECH config list:" **逐字节相同**（门禁用这条向量钉住）。
_ECH_KEYS_LEN_BYTES = 2
ECH_CDN_DISCOVERY = "cloudflare-ech.com+https://dns.alidns.com/dns-query"


def ech_config_list(server_keys) -> str:
    """服务端 echServerKeys → 客户端可 pin 的 ECHConfigList (base64)。取不到返回 ""。

    真值对照（RN 生产 vless-xhttp08, 184 字符的服务端密钥）:
        xray tls ech -i <keys> → "ECH config list:
            AGX+DQBhAAAgACA/rOgHBypsWc/LDY/WZjmK8Gm5jpe876iY7AKFphHdAgAkAAEAAQABAAIA
            AQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADABJtb29udHYuNjg5NjY5OC54eXoAAA=="
        本函数算出来**逐字节相同**（门禁用这条向量钉住）。

    长度不是 4 的倍数时按 base64 规则补 padding —— 这是机械修复, 不是猜:
    padding 由长度唯一确定。真值本来就不会缺, 但缺了不该整段丢掉 (丢 = 客户端
    静默不开 ECH, 而那正是这个节点存在的理由)。
    """
    s = str(server_keys or "").strip()
    if not s:
        return ""
    try:
        raw = base64.b64decode(s + "=" * (-len(s) % 4), validate=True)
    except Exception:                                            # noqa: BLE001
        return ""
    if len(raw) <= _ECH_KEYS_LEN_BYTES:
        return ""
    klen = int.from_bytes(raw[:_ECH_KEYS_LEN_BYTES], "big")
    rest = raw[_ECH_KEYS_LEN_BYTES + klen:]
    if not rest:
        return ""
    return base64.b64encode(rest).decode()


def _link_name(link) -> str:
    """从 build_share_link() 生成的链接里读回**显示名**。

    为什么不在这里自己拼名字: 显示名带旗帜+服务器前缀 (conf/lib/naming.py),
    只有 build_share_link 一处实现 —— 本文件再拼一遍必然漂移, 而两条产品
    名字不一致的后果是客户端把**同一个节点落成两份**(或互相覆盖)。
    vmess 的链接是 base64 JSON, 名字在 `ps` 字段里, 没有 fragment。
    """
    if not link:
        return ""
    if link.startswith("vmess://"):
        body = link[len("vmess://"):]
        try:
            d = json.loads(base64.b64decode(body + "=" * (-len(body) % 4)).decode())
            return str(d.get("ps") or "")
        except Exception:                                        # noqa: BLE001
            return ""
    frag = urllib.parse.urlsplit(link).fragment
    return urllib.parse.unquote(frag) if frag else ""


def _fragment_extra(n, conf_dir):
    """片段里**已经被声明**、但节点视图与 URI 都装不下的字段。取不到返回 {}。

    为什么直接读片段而不是先扩节点视图: 节点视图 (nodes.extract) 的所有者是另一条
    线的工作, 而这里只要三样 —— ECH(EchServerKeys/_serverName)、xhttp 的 mode、
    grpc 的 serviceName。为它们去改 extract 会把两条不相干线的改动缠在同一个函数
    里; 而"多一个抽取器"的风险在这里是**有界**的: 本函数只挑 URI 表达不了、
    因此不可能与 URI 路径冲突的字段, 任何异常都退化成"没有"（少几个字段,
    不会让整个文档生成失败）。
    """
    out = {}
    try:
        src = n.get("source") or ""
        path = os.path.join(conf_dir, src)
        if not src or not os.path.isfile(path):
            return out
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        declared = d.get("_serverName")
        if isinstance(declared, str) and declared.strip():
            out["declared_server_name"] = declared.strip()
        for ib in d.get("inbounds") or []:
            if not isinstance(ib, dict) or ib.get("tag") != n.get("tag"):
                continue
            ss = ib.get("streamSettings") or {}
            tls = ss.get("tlsSettings") or {}
            keys = tls.get("echServerKeys")
            if isinstance(keys, str) and keys.strip():
                out["ech_server_keys"] = keys.strip()
            xh = ss.get("xhttpSettings") or {}
            if xh.get("mode"):
                out["xhttp_mode"] = str(xh["mode"])
            gr = ss.get("grpcSettings") or {}
            if gr.get("serviceName"):
                out["grpc_service_name"] = str(gr["serviceName"])
            if tls.get("fingerprint"):
                out["tls_fingerprint"] = str(tls["fingerprint"])
            if ss.get("network") == "ws":
                ws = ss.get("wsSettings") or {}
                if ws.get("host"):
                    out["ws_host"] = str(ws["host"])
            break
    except Exception:                                            # noqa: BLE001
        return out
    return out


def _ech_value(n, meta, extra, host):
    """这个节点该不该带 echConfigList、带什么值。取不到返回 ""。

    ECH 与**端点**绑定（这条是既有结论, 见 conf/lib/nodes.py 同族说明）:
      · 片段里有 echServerKeys → 本节点自己终结 TLS 且开了 ECH, 值 = 还原出来的
        ECHConfigList（客户端按它发 ClientHello）;
      · 没有服务端密钥, 但有 `_serverName`（由 conf/vlessxhttpecn.sh 生成,
        它的 ECH 形态只有 cdn/direct）且这次发布连的是 CDN 边缘（host 是域名）
        → CDN-ECH, 值 = 官方 DNS 查询串;
      · 其余 → **不写**（直连源站而源站没开 ECH 时写 CDN 的配置, 握手必失败）。
    """
    for key in ("ech", "ech_config_list"):
        v = n.get(key) if isinstance(n.get(key), str) else meta.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    keys = n.get("ech_server_keys") or extra.get("ech_server_keys") \
        or meta.get("ech_server_keys")
    if isinstance(keys, str) and keys.strip():
        fn = getattr(N, "ech_config_list", None)     # 节点视图将来暴露了就用它（同一份实现）
        val = fn(keys) if callable(fn) else ech_config_list(keys)
        if val:
            return val
    if extra.get("declared_server_name") and host and not N.is_ip_literal(host):
        return ECH_CDN_DISCOVERY
    return ""


# ------------------------------------------------------------------ 带宽
_BW_RE = re.compile(r"^([0-9]+(?:\.[0-9]+)?)\s*([kmgt]?)(?:b|bps|bit|bits)?$", re.I)


def _bandwidth(v) -> str:
    """链接侧的带宽写法 → Xray `Bandwidth` 语法 ("50 mbps" / "1.5 gbps")。

    ★ 两边的约定**相反**, 不能互相照抄（Client/lib/node.py:bandwidth_hint 与
      bandwidth_xray 的注释里有实测依据）:
        链接侧   "50" → 50 Mbps（mihomo 的 up/down、sing-box 的 upmbps）
        Xray     "50" → 50 bit/s（缺数量级 = bit/s）, 而 brutalUp 有 65536 B/s 下限,
                 写小了内核会**拒收整份配置**。
      所以这里必须把链接侧的裸数字补成 "mbps"。认不出返回 ""（宁可不写）。
    """
    if v is None or isinstance(v, bool):
        return ""
    s = f"{v:g}" if isinstance(v, (int, float)) else str(v).strip()
    m = _BW_RE.match(s)
    if not m:
        return ""
    try:
        num = float(m.group(1))
    except ValueError:
        return ""
    if not num > 0:
        return ""
    mag = m.group(2).lower()
    if not mag:
        # 没写数量级 → 按**链接侧**约定当 Mbps 补上（"50" 在链接里就是 50 Mbps）。
        # 不补的话, 内核按 bit/s 读, 50 bit/s 连 brutalUp 的 65536 B/s 下限都不到,
        # 结果是**整份配置被拒收**。
        mag = "m"
    return f"{num:g} {mag}bps"


# ------------------------------------------------------------------ 渲染
def build_outbound(n, meta=None, conf_dir=None, notes=None):
    """一个节点 → Xray 客户端出站对象。不可发布/表达不了返回 None。

    `n` / `meta` 与 build_share_link() 完全同一份输入 —— 端点、SNI、REALITY 参数、
    带宽默认值都从**同一些函数与同一些常量**取, 不另写一套取值逻辑。
    """
    meta = meta or {}
    conf_dir = conf_dir or CONF_DIR
    # ★ 发布闸门: URI 路径说"不发"的, 原生路径也必须不发。
    link = N.build_share_link(n, meta, notes=notes)
    if not link:
        return None
    host, port, _note, _refuse = N.share_target(n, meta)
    if not host or not port:
        return None
    # 显示名与 URI 路径**逐字相同** —— 客户端按名字落盘, 两条路径名字不一致会
    # 让同一个节点在列表里出现两次(或者互相覆盖)。名字只有一处实现: 从链接里读回来。
    name = _link_name(link) or n.get("tag")
    extra = _fragment_extra(n, conf_dir)

    proto = n.get("protocol")
    network = (n.get("network") or "tcp")
    security = (n.get("security") or "none")
    ob = {"tag": name, "protocol": proto}

    if proto in ("vless", "vmess"):
        u = {"id": n.get("id") or ""}
        if proto == "vless":
            u["encryption"] = meta.get("encryption") or "none"
            if n.get("flow"):
                u["flow"] = n["flow"]
        else:
            u["alterId"] = 0
            u["security"] = "auto"
        ob["settings"] = {"vnext": [{"address": host, "port": int(port), "users": [u]}]}
    elif proto == "trojan":
        ob["settings"] = {"servers": [{"address": host, "port": int(port),
                                       "password": n.get("password") or ""}]}
    elif proto == "shadowsocks":
        ob["settings"] = {"servers": [{"address": host, "port": int(port),
                                       "password": n.get("password") or "",
                                       "method": n.get("method") or ""}]}
    elif proto in ("hysteria", "hysteria2", "hy2"):
        # 官方出站的 settings 是**扁平**的, 不是 servers[]/vnext[]。
        ob["protocol"] = "hysteria"
        ob["settings"] = {"version": 2, "address": host, "port": int(port)}
    else:
        # socks / http 之类: URI 侧也只发一条裸链接, 没有可靠的原生表达 → 不发原生。
        # 调用方（share.sh）会把这几个 tag 报成"原生未覆盖", 不是静默少一个。
        return None

    stream = {"network": network, "method": network}
    if proto in ("hysteria", "hysteria2", "hy2"):
        # hysteria2 的传输在 Xray 里是 QUIC: 26.3.27 及更早认 network="hysteria",
        # 新版认 method。两个都写（互不冲突, 与 genconfig 同一口径）。
        stream = {"network": "hysteria", "method": "hysteria"}
        hs = {"version": 2}
        if n.get("password"):
            hs["auth"] = n["password"]
        stream["hysteriaSettings"] = hs
        qp = {}
        up = _bandwidth(meta.get("upmbps") or meta.get("up") or N.DEFAULT_HY2_UP)
        down = _bandwidth(meta.get("downmbps") or meta.get("down") or N.DEFAULT_HY2_DOWN)
        if up:
            qp["brutalUp"] = up
        if down:
            qp["brutalDown"] = down
        hop = str(meta.get("mport") or "").strip()
        if hop:
            qp["udpHop"] = {"ports": hop}
        if qp:
            stream["finalmask"] = {"quicParams": qp}
        # hy2 的 TLS 由 QUIC 自带; sni / alpn 取法与 URI 路径同一处
        sni = N.link_sni(n, meta)
        alpn = n.get("alpn") or meta.get("alpn") or N.DEFAULT_HY2_ALPN
        tls_h = {}
        if sni:
            tls_h["serverName"] = sni
        if alpn:
            tls_h["alpn"] = [x for x in str(alpn).split(",") if x]
        pin = str(meta.get("pinned_cert_sha256") or meta.get("pin") or "").strip().lower()
        if pin:
            tls_h["pinnedPeerCertSha256"] = pin
        ech = _ech_value(n, meta, extra, host)
        if ech:
            tls_h["echConfigList"] = ech
        stream["security"] = "tls" if (security in ("tls", "none") and (sni or alpn)) else security
        if stream["security"] == "tls" and tls_h:
            stream["tlsSettings"] = tls_h
    elif security == "tls":
        tls = {}
        sni = N.link_sni(n, meta)
        if sni:
            tls["serverName"] = sni
        if n.get("alpn"):
            tls["alpn"] = [x for x in str(n["alpn"]).split(",") if x]
        fp = meta.get("fingerprint") or extra.get("tls_fingerprint")
        if fp:
            tls["fingerprint"] = str(fp)
        pin = str(meta.get("pinned_cert_sha256") or meta.get("pin") or "").strip().lower()
        if pin:
            tls["pinnedPeerCertSha256"] = pin
        ech = _ech_value(n, meta, extra, host)
        if ech:
            tls["echConfigList"] = ech
        stream["security"] = "tls"
        if tls:
            stream["tlsSettings"] = tls
    elif security == "reality":
        sni = N.reality_sni(n)
        reality = {"fingerprint": meta.get("fingerprint") or "chrome"}
        if sni:
            reality["serverName"] = sni
        if meta.get("public_key"):
            reality["publicKey"] = meta["public_key"]
        if meta.get("short_id"):
            reality["shortId"] = meta["short_id"]
        if meta.get("spx"):
            reality["spiderX"] = meta["spx"]
        stream["security"] = "reality"
        stream["realitySettings"] = reality
    else:
        stream["security"] = "none"

    if proto not in ("hysteria", "hysteria2", "hy2"):
        if network == "xhttp":
            xh = {"path": n.get("path") or "/"}
            hm = meta.get("host_header")
            if hm:
                xh["host"] = str(hm)
            if extra.get("xhttp_mode"):
                xh["mode"] = extra["xhttp_mode"]
            stream["xhttpSettings"] = xh
        elif network == "ws":
            ws = {"path": n.get("path") or "/"}
            hm = meta.get("host_header") or extra.get("ws_host")
            if hm:
                ws["host"] = str(hm)
            stream["wsSettings"] = ws
        elif network == "grpc":
            stream["grpcSettings"] = {"serviceName": extra.get("grpc_service_name") or ""}
        elif network == "httpupgrade":
            hu = {"path": n.get("path") or "/"}
            hm = meta.get("host_header")
            if hm:
                hu["host"] = str(hm)
            stream["httpupgradeSettings"] = hu
    ob["streamSettings"] = stream
    return ob


def build_document(tags, conf_dir=None, share_dir=None, facts=None, notes=None):
    """一组 tag → 原生产品文档。

    返回 (doc|None, missing, nometa, refused, unsupported, notes):
      · doc          {"interop":1,"kernel":…,"distribution":…,"version":…,"source":…,
                      "outbounds":[…]}; 一条都发不出时是 None
      · missing      片段里没有这个 tag
      · nometa       节点在、分享元数据不在
      · refused      [(tag, 原因)] —— 与 URI 路径同一条判据（build_share_link）
      · unsupported  [(tag, 原因)] —— 节点可发布, 但这个协议还没有原生表达
                      （例如 socks/http）: 必须报出来, 不许静默少一个
    """
    conf_dir = conf_dir or CONF_DIR
    share_dir = share_dir or SHARE_DIR
    node_list, bad = N.collect(conf_dir)
    by_tag = {x["tag"]: x for x in node_list}
    if facts is None:
        import interop                                          # noqa: E402
        facts = interop.self_facts()

    outbounds, missing, nometa, refused, unsupported = [], [], [], [], []
    for t in tags:
        n = by_tag.get(t)
        if not n:
            missing.append(t)
            continue
        meta = share_meta.load(share_dir, t) or {}
        before = len(notes) if notes is not None else 0
        ob = build_outbound(n, meta, conf_dir=conf_dir, notes=notes)
        if ob is None:
            why = None
            if notes is not None:
                why = next((x for x in reversed(notes[before:]) if "未发布" in x), None)
            if why:
                refused.append((t, why.split("未发布 —— ", 1)[-1]))
            elif n.get("protocol") not in ("vless", "vmess", "trojan",
                                           "shadowsocks", "hysteria",
                                           "hysteria2", "hy2"):
                unsupported.append((t, "协议 %s 还没有原生表达" % n.get("protocol")))
            else:
                nometa.append(t)
            continue
        outbounds.append(ob)
    if notes is not None and bad:
        notes.append("片段解析失败 %d 个: %s" % (
            len(bad), ",".join(b for b, _ in bad)))
    if not outbounds:
        return None, missing, nometa, refused, unsupported, (notes or [])
    doc = {
        "interop": 1,
        "kernel": facts.get("kernel", "xray"),
        "distribution": facts.get("distribution", ""),
        "version": facts.get("version", ""),
        "source": PRODUCT_SOURCE,
        "outbounds": outbounds,
    }
    return doc, missing, nometa, refused, unsupported, (notes or [])


def document_text(doc) -> str:
    """产品正文。**不**做 base64: content_type 是 application/json,
    客户端按"原生 JSON 文档"识别（Client/lib/node.py:detect_format）。"""
    return json.dumps(doc, ensure_ascii=False, indent=2) + "\n"


def main(argv):
    conf_dir = argv[1] if len(argv) > 1 else CONF_DIR
    share_dir = argv[2] if len(argv) > 2 else SHARE_DIR
    tags = argv[3:]
    notes = []
    doc, missing, nometa, refused, unsupported, _ = build_document(
        tags, conf_dir, share_dir, notes=notes)
    for t, why in refused:
        print("不该对外发布: %s —— %s" % (t, why), file=sys.stderr)
    for t, why in unsupported:
        print("原生未覆盖: %s —— %s" % (t, why), file=sys.stderr)
    if missing:
        print("节点已删: %s" % ",".join(missing), file=sys.stderr)
    if nometa:
        print("缺分享元数据: %s" % ",".join(nometa), file=sys.stderr)
    for x in notes:
        print("提示: %s" % x, file=sys.stderr)
    if doc is None:
        print("没有可发布的原生内容", file=sys.stderr)
        return 1
    sys.stdout.write(document_text(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
