#!/usr/bin/env python3
"""Xray 配置生成器。

线上的唯一实例一律用 `--mode normal`，**同时**提供 SOCKS 与 HTTP 两个入站，
进程始终带 XRAY_BROWSER_DIALER —— 于是"用不用浏览器"完全由节点决定，不需要第二个
实例、第二个端口。详见 scripts/run-xray.sh。

`--mode dialer` 只剩一个用途：`xbd ech` 的 ECH 诊断需要一份"TLS 由浏览器完成、只
监听回环临时端口"的探针配置。它做两件 normal 不会做的事：
    * 丢弃 flow（vision/xtls）：JS 网络栈不支持；
    * 把 websocket/xhttp 的自定义 Host 换回地址 —— 浏览器发出的 Host 必须等于 SNI，
      否则 TLS 对不上（见 transport/internet/websocket/dialer.go 的同域规则）。
请不要把这个模式接回线上服务。

不写入的东西（有意为之）：
    * allowInsecure：已由 pinnedPeerCertSha256 取代
    * echSettings：dialer 模式下 TLS 由 Chromium 完成，Xray 的 ECH 配置不生效
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
import sys

NORMAL, DIALER = "normal", "dialer"

# 出站地址族。auto 是**当前行为**（direct 走 IPv4、DNS 交给内核按连通性选），
# v4/v6 才强制。取名而不是用布尔，是因为以后要加 "prefer-v6" 这类档位时
# 不用改调用方。
FAMILIES = ("auto", "v4", "v6")


def _family_settings(family: str) -> tuple:
    """返回 (direct 出站的 domainStrategy, DNS 的 queryStrategy)。

    auto 保持现状：direct=UseIPv4（国内直连站点 v4 更稳），dns=UseIP
    （注释里写明了理由：交给上层按实际连通性选，兼容性最好）。
    """
    f = family if family in FAMILIES else "auto"
    if f == "v4":
        return "UseIPv4", "UseIPv4"
    if f == "v6":
        return "UseIPv6", "UseIPv6"
    return "UseIPv4", "UseIP"

# WebSocket early data 默认长度。官方 browser_dialer 文档推荐 ?ed=2048，
# 而且实测它是浏览器转发下 ws 能用的前提（缺了会让内嵌页面抛 TypeError）。
WS_ED_DEFAULT = 2048

# TLS 交给浏览器的模式只支持这些传输（浏览器只能发 HTTP(S)）
DIALER_TRANSPORTS = {"xhttp", "websocket"}

# 多出站模式下的命名约定。
# 观测器和 balancer 都用**前缀**匹配出站，所以 OUTBOUND_PREFIX 既是它们的选择器，
# 也是"哪些出站算节点"的唯一判据。新增节点出站必须沿用这个前缀，否则那个节点
# 既不会被观测、也进不了 balancer —— 而配置照样能起，只是那个节点永远选不上。
BALANCER = "xbd-bal"
OUTBOUND_PREFIX = "node-"

# ---------------------------------------------------------------------------
# mux.cool —— 什么情况下给出站写 mux
# ---------------------------------------------------------------------------
#
# 背景（改动前）：这里**无条件**写 `mux:{enabled:true,concurrency:8}`，
# 唯一的开关是 `--no-mux`（默认 False，即默认开）。后果有三层：
#
#   1. 节点 JSON 里的 `mux` 字段被完全忽略 —— 导入时明明记着"这个节点不要 mux"
#      （node.py 的 DEFAULT_NODE 就是 False），运行配置里照样给它开上。
#      用户的意图被吞掉, 而且没有任何提示。
#   2. XHTTP 节点被开上 mux.cool, 而官方文档**明确**写着"使用 XHTTP 时不要启用
#      mux.cool"：XHTTP 自带多路复用（`xhttpSettings.extra.xmux`），再叠一层
#      mux.cool 只会把所有并发压回一条连接。实测（CC 回环，同机同配置只差 mux）：
#          mux 关 -> 204，mux 开 -> 000（连不通）
#   3. 生产证据：RN 的 error.log 里能看到客户端经 mux.cool 建会话后立刻
#      `common/mux: unexpected EOF > failed to read metadata > timeout`。
#
# 现在的策略（三层，优先级从高到低）：
#
#   ① 命令行 `--mux` / `--no-mux`（显式，人说的一定算数）
#   ② 节点 JSON 的 `mux` 字段（来源的意图，现在真的生效了）
#   ③ 默认 **不开** —— mux.cool 是 2018 年前后为"浏览器同域并发只有 6 条"
#      设计的补丁；今天的瓶颈在服务端而不是连接数，而它对 UDP(xudp)、
#      与 XHTTP/QUIC 的组合都有副作用。想开就显式开。
#
# XHTTP / QUIC 例外是**硬**的：即使显式要求也不写，并在 stderr 说明原因 ——
# 这两条不是"风险偏好"问题，而是官方不建议 / 实测必坏。
MUX_FORBIDDEN_TRANSPORTS = {
    "xhttp": "官方文档明确「使用 XHTTP 时不要启用 mux.cool」—— XHTTP 自带多路复用"
             "（xhttpSettings.extra.xmux），叠加 mux.cool 会把并发压回单连接；"
             "实测 CC 回环: 同机同配置 mux 关 204 / mux 开 000",
    "quic": "QUIC 传输自带流级多路复用，mux.cool 叠上去没有收益；"
            "实测 RN 生产日志里 hysteria(QUIC) 上的 mux.cool 会话直接 "
            "「unexpected EOF > failed to read metadata > timeout」",
    "mkcp": "mKCP 本身就是为弱网重传设计的传输层，mux.cool 的会话超时"
            "（默认 30s 无流量即断）比它先到",
}
# 协议侧的判据：hysteria2 走 QUIC，transport 字段有时是空的（旧节点文件），
# 所以协议名也要判一次 —— 只看 transport 会漏掉这一批。
MUX_FORBIDDEN_PROTOCOLS = {"hysteria2": "hysteria2 走 QUIC，QUIC 自带流级多路复用"}


def mux_decision(node: dict, cli_mux=None) -> tuple:
    """决定这个出站要不要写 mux，返回 (enabled: bool, warn: str)。

    cli_mux: True=`--mux`（显式开），False=`--no-mux`（显式关），None=没给。
    warn 非空时调用方必须把它打到 stderr —— 被拒绝的请求必须说话,
    否则用户会以为"我明明开了"（这正是改动前 ech 那个 bool 的老毛病）。
    """
    n_mux = node.get("mux")
    if isinstance(n_mux, dict):                 # 内核配置里是对象, 宽容处理
        n_mux = n_mux.get("enabled")
    declared = bool(n_mux)

    if cli_mux is True:
        want, src = True, "--mux"
    elif cli_mux is False:
        want, src = False, "--no-mux"
    elif declared:
        want, src = True, "节点 JSON 的 mux 字段"
    else:
        want, src = False, ""

    if not want:
        return False, ""

    transport = (node.get("transport") or "").lower()
    proto = (node.get("protocol") or "").lower()
    why = MUX_FORBIDDEN_TRANSPORTS.get(transport) or MUX_FORBIDDEN_PROTOCOLS.get(proto)
    if why:
        return False, (f"节点要求开 mux（来自 {src}），但传输 {transport or proto} "
                       f"不能开 —— 已忽略：{why}")
    return True, (f"已按 {src} 启用 mux.cool（concurrency=8）。"
                  "注意：mux.cool 会降低 UDP(443) 与部分协议栈的兼容性，"
                  "且官方不建议在 XHTTP/QUIC 上使用；只在你确知需要时保留")



def fail(msg: str) -> None:
    print(f"genconfig: {msg}", file=sys.stderr)
    sys.exit(2)


def build_stream(node: dict, mode: str) -> dict:
    transport = (node.get("transport") or "tcp").lower()
    security = (node.get("security") or "none").lower()

    if mode == DIALER:
        if transport not in DIALER_TRANSPORTS:
            fail(f"Browser Dialer 模式不支持 transport={transport}（只支持 xhttp / websocket）")
        if security == "reality":
            fail("Browser Dialer 模式不支持 REALITY：splithttp/dialer.go 仅在 realityConfig == nil 时启用")

    # hysteria2 的传输在 Xray 里是 streamSettings.method="hysteria"，
    # 不是 network="quic" —— 官方文档明确列在 method 的取值里。
    if transport == "quic" or (node.get("protocol") or "").lower() == "hysteria2":
        # 字段名随版本不同（实测得出，不能照抄文档）：
        #   v26.3.27 及更早  -> streamSettings.network = "hysteria"
        #   main 分支/新版    -> streamSettings.method  = "hysteria"
        # 实测：正式版上用 method 会退回 TCP（dialing to tcp），
        #       用 network 才是正确的 QUIC（dialing to udp）。
        # 这里同时写两个字段：旧版认 network，新版认 method，互不冲突。
        stream: dict = {"network": "hysteria", "method": "hysteria"}
        hs: dict = {"version": 2}
        if node.get("password"):
            hs["auth"] = node["password"]
        stream["hysteriaSettings"] = hs
        if security in ("tls", "none"):
            # hysteria2 默认就是 TLS（QUIC 自带），按官方示例给 tlsSettings
            tls_h: dict = {"serverName": node.get("sni") or node.get("address", "")}
            if node.get("alpn"):
                tls_h["alpn"] = [a for a in str(node["alpn"]).split(",") if a]
            # hysteria2 的 TLS 配置走这个分支，pinning 也必须在这里加 ——
            # 之前只加在主 TLS 分支，hysteria2 节点永远读不到指纹。
            if node.get("pinned_cert_sha256"):
                tls_h["pinnedPeerCertSha256"] = node["pinned_cert_sha256"]
            stream["security"] = "tls" if security != "none" or node.get("sni") else "none"
            if stream["security"] == "tls":
                stream["tlsSettings"] = tls_h
        return stream

    # 传输字段名随版本变化，**必须两个都写**：
    #   v26.3.27 及更早 -> 只认 streamSettings.network（method 被整体静默丢弃）
    #   main / 26.9.9+  -> 认 method；官方 transport.md 里 network 已完全不出现
    #
    # 实测依据（26.3.27 逐变体对照）：
    #   network:"xhttp"        -> 正常出网，日志 XHTTP is dialing to tcp
    #   method:"xhttp" 单独写   -> 退回裸 TCP（与"两个都不写"逐字节相同）
    #   network + method 双写   -> 与只写 network 逐字节相同（无副作用）
    # 注意 26.3.27 会**静默丢弃未知 streamSettings 字段**（连杜撰字段名都 Configuration OK），
    # 所以"method 被接受"是假阳性，不能据此认为它生效。
    #
    # 为什么非 hysteria 分支也必须双写：它以前只写 network。一旦升级到 network
    # 被移除的版本，**所有非 hysteria 节点会静默退回 raw TCP** —— 不报错、起得来，
    # 只是连不上，属于最难排查的一类退化。
    stream: dict = {"network": transport, "method": transport}

    if security == "tls":
        tls: dict = {"serverName": node.get("sni") or node.get("address", "")}
        if node.get("alpn"):
            tls["alpn"] = [a for a in str(node["alpn"]).split(",") if a]
        if node.get("fingerprint") and mode == NORMAL:
            # dialer 模式下指纹无意义（Chromium 自带真实指纹）
            tls["fingerprint"] = node["fingerprint"]
        # ECH —— 官方 tlsSettings.echConfigList，**仅客户端参数**，
        # 不为空即代表客户端启用 Encrypted Client Hello。
        #
        # ★ 只在普通模式写。dialer 模式下 TLS 由 Chromium 完成，这条配置
        #   不会被读；那边的 ECH 是 Chromium 自己按 Secure DNS 里的
        #   HTTPS 记录做的（echcli.py 从 netlog 验过）。
        #
        # ★ 必须原样透传整个字符串，不能只记"有没有 ECH"：
        #   走 CDN 时它的形状是 "cloudflare-ech.com+https://dns.alidns.com/dns-query"
        #   —— 意思是"用 cloudflare-ech.com 的 DNS 记录里的 ECHConfig，
        #   并且指定从这个 DoH 查"。丢掉这个值 = 服务端配了 ECH 而客户端
        #   什么都没做，SNI 照样明文出去。
        #
        # ★ 只能写**非空字符串**。旧节点文件里 ech 可能是 bool：mihomo 的
        #   `ech-opts: {enable: true}`（没有静态 config，指望靠 DNS 取）在早期
        #   node.py 里落成了 `"ech": true`。把 true 写进 echConfigList 的后果不是
        #   "ECH 不生效"，而是**整份配置构建失败**（实测 26.3.27 原文：
        #   cannot unmarshal bool into Go struct field TLSConfig.outbounds.
        #   streamSettings.tlsSettings.echConfigList of type string），
        #   而单节点模式不跑 --validate-with → 写进去 → 内核起不来 → 客户端全挂。
        #   没有静态 config 的 ECH 本来就该由 pinnedPeerCertSha256 兜底（见下）。
        _ech = node.get("ech")
        if mode == NORMAL and isinstance(_ech, str) and _ech.strip():
            tls["echConfigList"] = _ech.strip()
        elif mode == NORMAL and _ech:
            print("genconfig: 节点声明的 ech 不是可用配置（需要 echConfigList 字符串，"
                  f"实际 {type(_ech).__name__}={_ech!r}）—— 已跳过 ECH，"
                  "证书校验请用 pinnedPeerCertSha256", file=sys.stderr)
        # 自签证书节点的正确解法：固定服务端证书哈希。
        # Xray 26.x 移除了 allowInsecure，官方替代就是 pinnedPeerCertSha256。
        if node.get("pinned_cert_sha256"):
            tls["pinnedPeerCertSha256"] = node["pinned_cert_sha256"]
        # 注意：Xray 26.x 已移除 allowInsecure（官方提示迁移到 pinnedPeerCertSha256），
        # 因此这里**不写**该字段 —— 写了会导致配置校验直接失败。
        # 若节点声明跳过证书校验，由 compat 检查提示"证书必须有效"。
        stream["security"] = "tls"
        stream["tlsSettings"] = tls
    elif security == "reality":
        reality = {
            "serverName": node.get("sni") or node.get("address", ""),
            "publicKey": node.get("reality_public_key", ""),
            "shortId": node.get("reality_short_id", ""),
            "fingerprint": node.get("fingerprint") or "chrome",
        }
        if node.get("reality_spider_x"):
            reality["spiderX"] = node["reality_spider_x"]
        stream["security"] = "reality"
        stream["realitySettings"] = reality
    else:
        stream["security"] = "none"

    if transport == "xhttp":
        xh: dict = {"path": node.get("path") or "/"}
        if node.get("host"):
            xh["host"] = node["host"]
        if node.get("mode"):
            xh["mode"] = node["mode"]
        if node.get("extra"):
            try:
                parsed = json.loads(node["extra"]) if isinstance(node["extra"], str) else node["extra"]
                if parsed:
                    xh["extra"] = parsed
            except (ValueError, TypeError):
                pass
        stream["xhttpSettings"] = xh
    elif transport == "websocket":
        ws: dict = {"path": node.get("path") or "/"}
        if node.get("host"):
            ws["host"] = node["host"]
        # early data（?ed=N）。官方 browser_dialer 文档推荐 2048，且这里是**必须**的：
        # 浏览器转发下若 ed 缺失，Xray 发给内嵌页面的 WS 任务里就没有 extra 字段，
        # 而页面要读 task.extra.protocol -> TypeError -> ws 节点在浏览器路径下必然失败。
        # 实测：同一个节点 path 不带 ed 必失败、带 ?ed=2048 立刻出网；原生路径两者都正常。
        # ed 只能通过 URL 查询串生效（实测：wsSettings.ed / earlyData / edMax 等字段全部无效），
        # 所以这里拼到 path 上。原生路径下也验证可用，不会造成回归。
        ed = node.get("ws_ed") or 0
        if ed <= 0:
            ed = WS_ED_DEFAULT
        if ed > 0 and "ed=" not in str(ws["path"]):
            sep = "&" if "?" in ws["path"] else "?"
            ws["path"] = f"{ws['path']}{sep}ed={int(ed)}"
        stream["wsSettings"] = ws
    elif transport == "grpc":
        stream["grpcSettings"] = {"serviceName": node.get("service_name") or ""}
    elif transport == "tcp" and node.get("header_type") == "http":
        stream["tcpSettings"] = {"header": {"type": "http"}}
    elif transport == "httpupgrade":
        stream["httpupgradeSettings"] = {"path": node.get("path") or "/"}
        if node.get("host"):
            stream["httpupgradeSettings"]["host"] = node["host"]

    return stream


def build_outbound(node: dict, mode: str, mux, tag: str = "proxy") -> dict:
    """mux: True/False/None —— None 表示调用方没表态，交给节点字段与默认策略。"""
    proto = (node.get("protocol") or "").lower()
    settings: dict

    if proto in ("vless", "vmess"):
        users = {"id": node.get("uuid", "")}
        if proto == "vless":
            users["encryption"] = node.get("encryption") or "none"
            # dialer 模式下 flow 必须丢弃：JS 网络栈不支持 xtls/vision
            if node.get("flow") and mode == NORMAL:
                users["flow"] = node["flow"]
        else:
            users["security"] = node.get("encryption") or "auto"
        settings = {"vnext": [{
            "address": node.get("address", ""),
            "port": int(node.get("port") or 443),
            "users": [users],
        }]}
    elif proto == "hysteria2":
        # 官方格式：protocol="hysteria" + settings.version=2 + address/port
        # 认证密码放在 streamSettings.hysteriaSettings.auth（见官方文档）
        settings = {
            "version": 2,
            "address": node.get("address", ""),
            "port": int(node.get("port") or 443),
        }
    elif proto == "trojan":
        settings = {"servers": [{
            "address": node.get("address", ""),
            "port": int(node.get("port") or 443),
            "password": node.get("password", ""),
        }]}
    elif proto == "shadowsocks":
        settings = {"servers": [{
            "address": node.get("address", ""),
            "port": int(node.get("port") or 8388),
            "method": node.get("method", ""),
            "password": node.get("password", ""),
        }]}
    elif proto in ("socks", "http"):
        # 简易出站：把本机或局域网里**别的内核**当上游用（socks5 / http 代理）。
        # 官方 Xray 的 socks/http 出站形状都是 servers 数组；认证是可选的，
        # 留空就完全不写 users 字段 —— 写了空 users 反而会被内核当成"要认证"。
        srv = {"address": node.get("address", ""),
               "port": int(node.get("port") or (1080 if proto == "socks" else 8080))}
        user = (node.get("username") or "").strip()
        if user:
            srv["users"] = [{"user": user, "pass": node.get("password") or ""}]
        settings = {"servers": [srv]}
    else:
        fail(f"不支持的协议: {proto}")

    # Xray 侧协议名是 hysteria（version 2 即 hysteria2）
    proto_out = "hysteria" if proto == "hysteria2" else proto
    ob: dict = {"tag": tag, "protocol": proto_out, "settings": settings}
    # socks / http 是**明文本地跳**，没有传输层可配。给它们塞一个
    # streamSettings 会被内核忽略，但会让人以为"这里能配 TLS" —— 不写。
    if proto not in ("socks", "http"):
        ob["streamSettings"] = build_stream(node, mode)
    if node.get("flow") and mode == NORMAL and proto == "vless":
        pass  # flow 已在 users 里
    # mux 的判据只有一处（mux_decision），单节点与多出站两条路径都走它 ——
    # 两边各判一次必然会漂移，而症状是"单节点没 mux、切到多出站又有了"。
    # socks / http 没有传输层，mux.cool 对它们无意义：不写。
    if proto not in ("socks", "http"):
        _mux_on, _mux_warn = mux_decision(node, mux)
        if _mux_warn:
            print(f"genconfig: {_mux_warn}", file=sys.stderr)
        if _mux_on:
            ob["mux"] = {"enabled": True, "concurrency": 8}
    return ob


def build(node: dict, args) -> dict:
    mode = args.mode
    port = args.port if args.port is not None else (args.port_dialer if mode == DIALER else args.port_normal)

    # 直连豁免：节点自身域名 + 私网必须走 freedom，避免将来启用 TUN/透明代理后形成环路。
    #
    # 必须区分域名 / IPv4 / IPv6 三种，不能只看"是不是全数字"：
    # IPv6 字面量（如 2001:470:c:c22::1）含冒号，去掉点后当然不是全数字，
    # 于是被当成域名拼成 `domain:2001:470:c:c22::1` —— 那是个永不匹配的垃圾规则，
    # 结果 IPv6 节点反而**没有**直连豁免，将来开了 TUN 就会形成环路。
    #
    # 另外 Xray 的 domain 字段不认 IP，IP 必须放进 ip 字段，所以两个列表要分开。
    direct_domains, direct_ips = [], []
    for key in ("address", "host", "sni"):
        v = (node.get(key) or "").strip()
        if not v:
            continue
        if ":" in v:                        # IPv6 字面量
            direct_ips.append(v)
        elif v.replace(".", "").isdigit():  # IPv4 字面量
            direct_ips.append(v)
        else:                               # 域名
            direct_domains.append(v)
    if direct_ips:
        direct_ips.append("geoip:private")  # 私网同样豁免

    inbounds = [{
        "tag": f"socks-{mode}",
        "listen": args.listen,
        "port": port,
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": bool(node.get("udp", True)),
                     "address": args.listen},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
    }]

    # 本机进程用的 HTTP 代理入口。
    # 为什么必须有：docker 的 HTTP_PROXY 只接受 http:// 与 https://，
    # 不认 socks5:// —— 只有 SOCKS 入口时 docker pull 依然不通。
    # 只监听回环：本机自用，不对外暴露。
    # 只给常驻实例：dialer 实例与常驻实例会同时运行，绑同一端口必然冲突。
    # 本机进程（docker 等）要的是普通模式出口，不需要走 Browser Dialer。
    if args.http_port and mode == NORMAL:
        inbounds.append({
            "tag": f"http-{mode}",
            "listen": "127.0.0.1",
            "port": args.http_port,
            "protocol": "http",
            "settings": {"auth": "noauth", "allowTransparent": False},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
        })

    # 局域网 HTTP 代理入口：给"WiFi 设置里填代理"这种用法。
    # 与回环那个分开，便于单独关闭；同样只出 SOCKS/HTTP 代理，不做流量劫持。
    if args.lan_http_port:
        inbounds.append({
            "tag": f"http-lan-{mode}",
            "listen": args.listen,
            "port": args.lan_http_port,
            "protocol": "http",
            "settings": {"auth": "noauth", "allowTransparent": False},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
        })

    inbounds.append({
        "tag": "api-in",
        "listen": "127.0.0.1",
        "port": args.api_port,
        "protocol": "dokodemo-door",
        "settings": {"address": "127.0.0.1"},
    })

    outbounds = [
        build_outbound(node, mode, args.mux),
        {"tag": "direct", "protocol": "freedom",
         "settings": {"domainStrategy": _family_settings(getattr(args, "family", "auto"))[0]}},
        {"tag": "block", "protocol": "blackhole"},
    ]

    routing_rules = [
        {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
        # 绝不代理自己：节点域名/自身 IP 与私网直连（环路防护）。
        # domain 与 ip 必须分成两条规则 —— Xray 的 domain 字段不认 IP 字面量。
        # 私网归在 ip 规则里；没有 IP 需要豁免时，单独出一条 geoip:private。
        *([{"type": "field", "outboundTag": "direct",
            "domain": sorted(set(direct_domains))}] if direct_domains else []),
        *([{"type": "field", "outboundTag": "direct",
            "ip": sorted(set(direct_ips))}] if direct_ips
          else [{"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]}]),
        {"type": "field", "outboundTag": "proxy", "network": "tcp,udp"},
    ]

    # metrics 端口: 显式给了就用, 否则自动挑一个**确认空闲**的。
    # 固定值在端口被占时会让内核启动失败, 代价远大于读不到 metrics。
    _metrics_port = args.metrics_port or pick_metrics_port()
    cfg = {
        "log": {
            "loglevel": args.loglevel,
            "access": f"{args.logs}/access-{mode}.log",
            "error": f"{args.logs}/error-{mode}.log",
        },
        "stats": {},
        "api": {"tag": "api", "services": ["StatsService", "HandlerService"]},
        # ★ 这里**故意不加 metrics**。
        #
        #   单节点配置就是 Browser Dialer 用的那份，而 BD 模式下**没有观测器**
        #   —— genconfig 里另一处的注释写明了原因: BD 的 env 是进程级的, 所有
        #   出站都会去抢浏览器的连接额度, 观测器一探测就把额度耗光。
        #   既然没有观测数据, 健康列在这一模式下本来就显示"未观测",
        #   在这里开一个监听端口只有"多一份流量统计"这点收益。
        #
        #   而代价是真实的: selftest-groups 有一条守卫断言"单节点配置与 HEAD
        #   逐字节一致（Browser Dialer 未受影响）"—— 那条守卫**真的拦住了**
        #   这次改动, 说明它守的是有价值的东西（BD 是最脆的一条路径）。
        #   不值得为了一点统计信息去动它。
        "policy": {
            "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
            "system": {"statsInboundUplink": True, "statsInboundDownlink": True,
                       "statsOutboundUplink": True, "statsOutboundDownlink": True},
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "routing": {"domainStrategy": "AsIs", "rules": routing_rules},
    }
    _apply_dns(cfg, args)
    return cfg


# DNS: 防泄漏靠的不是"用了加密 DNS"，而是"没有任何一条路径能落到明文"。
#
# 下面这套配置里，每一处选择都对应一个具体的泄漏路径：
#
#   1. 服务器地址写 IP 字面量（https://1.1.1.1/dns-query 而不是
#      https://one.one.one.one/dns-query）。域名形式的 DoH 需要先解析那个域名，
#      而解析它用的又是一次 DNS 查询 —— 这一次走的是系统默认解析器，
#      等于把最关键的一跳明文发了出去。已实测：Xray 接受 IP 字面量，且
#      `run -test` 直接输出 "created DOH client for https://1.1.1.1/dns-query"。
#
#   2. 顶层 disableFallback=True。这是防泄漏的核心开关。配了域名分流之后，
#      只要有一条规则没盖住的查询，Xray 就会回落到系统默认 DNS —— 那是明文
#      UDP 53，运营商一眼看得见。关掉它之后，漏网的查询会失败而不是泄漏。
#      宁可"某个域名解析不出来"，也不要"解析出去了"。
#
#   3. 末尾挂 localhost（本机 hosts / 系统缓存）。它只回答本机已知的东西，
#      不产生网络流量；放在最后是当兜底，防止前几条全挂时整个 DNS 瘫掉。
#
#   4. 不写任何 UDP 53 的明文服务器。这是最容易犯的错：为了"国内域名解析快"
#      加一条 {"address":"223.5.5.5"}，泄漏就从这里开始了。
DNS_MODES = ("off", "standard", "strict")


def build_dns(mode: str, family: str = "auto") -> dict:
    """生成 dns 段。off 返回空字典（表示不写这个 key）。"""
    if mode not in DNS_MODES:
        mode = "standard"
    if mode == "off":
        # 完全不接管 DNS。此时 Xray 走系统解析器，明文 UDP 53 是会出去的 ——
        # 所以 off 是明确的取舍，不是"更安全的默认"。
        return {}

    if mode == "strict":
        # 严格模式：境外和国内都只走加密 DNS，且全部经代理出口。
        # 牺牲是国内域名的解析速度，换的是"系统里不存在任何明文 DNS 出口"。
        servers = [
            {"address": "https://1.1.1.1/dns-query",
             "domains": ["geosite:geolocation-!cn"], "skipFallback": True},
            {"address": "https://8.8.8.8/dns-query",
             "domains": ["geosite:geolocation-!cn"], "skipFallback": True},
            {"address": "https://9.9.9.9/dns-query",
             "domains": ["geosite:geolocation-!cn"], "skipFallback": True},
        ]
    else:
        # 标准模式：境外走加密 DNS（可直连，也可经代理），国内走国内加密 DNS
        # 以免绕远路。两条都是加密的，明文一样不会出去。
        servers = [
            {"address": "https://1.1.1.1/dns-query",
             "domains": ["geosite:geolocation-!cn"], "skipFallback": True},
            {"address": "https://8.8.8.8/dns-query",
             "domains": ["geosite:geolocation-!cn"], "skipFallback": True},
            {"address": "https://223.5.5.5/dns-query",
             "domains": ["geosite:cn"], "expectIPs": ["geoip:cn"], "skipFallback": True},
        ]

    # 本机 hosts 兜底：不产生任何网络流量，放最后。
    servers.append({"address": "localhost", "skipFallback": True})

    return {
        "servers": servers,
        # auto: UseIP —— 交给上层按实际连通性选，兼容性最好（原行为）。
        # v4/v6: 强制只查 A / 只查 AAAA，配合 --family 一起用。
        "queryStrategy": _family_settings(family)[1],
        "tag": "dns-out",
        # 核心防泄漏开关，见文件头第 2 条。
        "disableFallback": True,
        # 缓存保留：既是性能也是隐私 —— 反复查同一个域名不发包，
        # 旁观者看到的信息量更少。
        "disableCache": False,
    }


def dns_routing_rules(mode: str, proxy_tag: str) -> list:
    """把 DNS 自身的流量也钉到代理上（仅严格模式）。

    Xray 里 DNS 模块发出的查询带一个虚拟入站标记，路由规则能匹配到它。
    不加这条，严格模式的"经代理"就只停留在配置意图上 —— 实际查询仍从本机
    直连出去，只是不再是明文。
    """
    if mode != "strict":
        return []
    return [{"type": "field", "inboundTag": ["dns-in"], "outboundTag": proxy_tag}]


def _apply_dns(cfg: dict, args) -> None:
    """按 --dns 模式补 dns 段和对应的路由规则。

    单节点和多出站都要调，所以抽出来 —— 两边各写一遍的话，早晚只改一处，
    然后用户在某一种模式下发现 DNS 又开始漏。
    """
    mode = getattr(args, "dns", "off")
    dns = build_dns(mode, getattr(args, "family", "auto"))
    if not dns:
        return
    cfg["dns"] = dns
    rules = dns_routing_rules(mode, BALANCER if cfg.get("balancers") else "proxy")
    if rules:
        # 插在最前面：DNS 的出口要压过后面所有规则，否则会被某条宽泛规则抢先。
        cfg["routing"].setdefault("rules", [])
        cfg["routing"]["rules"] = rules + cfg["routing"]["rules"]


def pick_metrics_port(preferred: int = 18086) -> int:
    """挑一个**确认空闲**的 metrics 端口。

    ★ 不能直接用固定值: 这个端点是要真去 bind 的, 端口被占时内核启动失败,
    而报错是内核级的 "listen tcp 127.0.0.1:18086: bind: address already in use"
    —— 与"metrics 读不到"相比, 这是一个**服务起不来**的故障, 代价大得多。
    复用 ports.py 的 pick_free (它用真 bind 判断, 比 grep ss 准)。
    """
    try:
        import ports as _P
        return int(_P.pick_free(preferred, "127.0.0.1"))
    except Exception:
        return int(preferred)


def tag_for(node: dict) -> str:
    """节点文件 → 多出站配置里的出站 tag。

    单独抽出来是因为面板和这里都要算同一个值。两边各算一次的话，
    迟早有一边算出 "node-node-001" 这种双前缀，而症状是"切换没反应"。
    """
    base = os.path.basename(node["__file"]).rsplit(".", 1)[0]
    if base.startswith(OUTBOUND_PREFIX):
        base = base[len(OUTBOUND_PREFIX):]
    return OUTBOUND_PREFIX + re.sub(r"[^A-Za-z0-9._-]", "_", base)


def _tag_of_bad_node(err: str):
    """从内核报错里认出是哪个出站坏了。

    内核的原话形如：
        failed to build outbound config with tag node-001-01 >
        infra/conf: Failed to build REALITY config.
    认得出 tag 才能只丢掉这一个 —— 直接放弃整份配置的话，订阅里一条
    写坏的节点就会让整个客户端起不来。
    """
    m = re.search(r"outbound config with tag ([A-Za-z0-9._-]+)", err or "")
    if m:
        return m.group(1)
    m = re.search(r"outbound \[([A-Za-z0-9._-]+)\]", err or "")
    return m.group(1) if m else None


def prune_unbuildable(nodes: list, cfg_fn, xray_bin: str, max_rounds: int = 12):
    """剔掉内核根本构建不出来的节点。

    为什么要做这件事：多出站把所有节点塞进同一份配置，任何一个节点写坏了
    （订阅里混进来的 REALITY 公钥少一位、uuid 少一横），整份配置就通不过校验，
    服务直接起不来。单节点模式下坏的只是那一个节点 —— 这是多出站换来的
    "切换不断线"所付的代价，必须在这里补回来。

    做法是让内核自己当裁判：校验失败 → 从报错里读出坏 tag → 剔掉 → 重生成。
    绝大多数情况一轮就干净；反复失败的次数封顶，避免内核一直报同一个错时
    变成死循环。
    """
    keep = list(nodes)
    dropped = []
    tmp = os.path.join(tempfile.gettempdir(), ".xbd-prune-%d.json" % os.getpid())
    try:
        for _ in range(max_rounds):
            cfg = cfg_fn(keep)
            # 必须落成文件再喂给内核：`xray run -test -c -` 不认 stdin，
            # 报的是 "Failed to get format of -"。已实测。
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(cfg, fh, ensure_ascii=False)
            p = subprocess.run([xray_bin, "run", "-test", "-c", tmp],
                               capture_output=True, text=True, timeout=60)
            if p.returncode == 0:
                return keep, dropped, None
            err = (p.stderr or "") + (p.stdout or "")
            tag = _tag_of_bad_node(err)
            if not tag:
                return keep, dropped, err.strip()[:400]
            idx = next((i for i, n in enumerate(keep)
                        if tag_for(n) == tag), None)
            if idx is None:
                return keep, dropped, err.strip()[:400]
            dropped.append({"file": os.path.basename(keep[idx]["__file"]),
                            "tag": tag})
            keep = keep[:idx] + keep[idx + 1:]
            if not keep:
                return keep, dropped, err.strip()[:400]
        return keep, dropped, "剔除次数用尽，仍未通过校验"
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass

def collect_direct_exemptions(nodes: list) -> tuple:
    """汇总所有节点的直连豁免项，返回 (域名列表, IP 列表)。

    环路防护必须覆盖**全部**节点，不只是当前那个。将来开了 TUN/透明代理，
    经由非当前节点连接的流量一样会回到本机；只豁免当前节点的域名，等于
    给其它节点留了环路。
    """
    domains, ips = set(), set()
    for node in nodes:
        for key in ("address", "host", "sni"):
            v = (node.get(key) or "").strip()
            if not v:
                continue
            if ":" in v or v.replace(".", "").isdigit():
                ips.add(v)
            else:
                domains.add(v)
    if ips:
        ips.add("geoip:private")
    return sorted(domains), sorted(ips)


def build_multi(nodes: list, current: dict, args) -> dict:
    """多出站配置：全部节点常驻，运行时用 API 切换。

    为什么值得这么做：
    每次换节点都要重新生成配置 + 重启进程，重启期间连接全断，而且节点多了
    之后"逐个试延迟"会变成 N 次重启。全部节点作为出站常驻、交给 balancer
    选，换节点就退化成一次 `xray api bo` —— 不重启、不掉连接。

    实测过的三个硬约束（缺一个就起不来）：
      · balancer 必须配 observatory，否则启动报 not all dependencies are resolved；
      · bo / bi 走 RoutingService，api.services 里少了它调用直接失败；
      · 简单 api 模式（只给 listen）不再需要 dokodemo 入站和那条 api 路由规则。

    Browser Dialer 不走这条路：那个 env 是整个进程级的，所有出站都会去抢浏览器
    的连接额度，而且观测器一探测就把额度耗光了。dialer 模式仍然是单节点配置，
    与改造前逐字节一致。
    """
    mode = args.mode
    port = args.port if args.port is not None else args.port_normal

    outbounds = []
    node_tag_by_id = {}
    for node in nodes:
        # tag 取文件名去扩展名：稳定、可读，且天然不撞。
        # 观测器和 balancer 用前缀匹配 selector=[OUTBOUND_PREFIX]，所以这里必须
        # 先把文件名自带的 node- 前缀剥掉再补一个 —— 节点文件本来就叫
        # node-001-a.json，不剥就会生成 node-node-001-a；而 node-a.json 和
        # a.json 这两个不同文件会撞成同一个 tag，后者静默顶掉前者。
        tag = tag_for(node)
        node_tag_by_id[node["__id"]] = tag
        outbounds.append(build_outbound(node, mode, args.mux, tag=tag))
    outbounds.append({"tag": "direct", "protocol": "freedom",
                      "settings": {"domainStrategy": _family_settings(
                          getattr(args, "family", "auto"))[0]}})
    outbounds.append({"tag": "block", "protocol": "blackhole"})

    direct_domains, direct_ips = collect_direct_exemptions(nodes)

    inbounds = [{
        "tag": f"socks-{mode}",
        "listen": args.listen,
        "port": port,
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": True, "address": args.listen},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
    }]
    if args.http_port:
        inbounds.append({
            "tag": f"http-{mode}", "listen": "127.0.0.1", "port": args.http_port,
            "protocol": "http", "settings": {"auth": "noauth", "allowTransparent": False},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
        })
    if args.lan_http_port:
        inbounds.append({
            "tag": f"http-lan-{mode}", "listen": args.listen, "port": args.lan_http_port,
            "protocol": "http", "settings": {"auth": "noauth", "allowTransparent": False},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False},
        })

    # metrics 端口: 显式给了就用, 否则自动挑一个**确认空闲**的。
    # 固定值在端口被占时会让内核启动失败, 代价远大于读不到 metrics。
    _metrics_port = args.metrics_port or pick_metrics_port()
    cfg = {
        "log": {
            "loglevel": args.loglevel,
            "access": f"{args.logs}/access-{mode}.log",
            "error": f"{args.logs}/error-{mode}.log",
        },
        "stats": {},
        # 简单 api 模式：只要给 listen 就行，不用再自己配 dokodemo 入站和路由规则。
        # 代价是 API 入站流量不计入统计 —— 对本项目无影响，那点流量没人看。
        "api": {
            "tag": "api",
            "listen": f"127.0.0.1:{args.api_port}",
            # ★ 这里**故意没有** ObservatoryService。
            #
            #   官方源码的判据: services 里写了 ObservatoryService 但配置里
            #   没有 observatory / burstObservatory 时, 内核**直接启动失败**:
            #       Failed to create server > core: not all dependencies are resolved.
            #   而单节点模式本来就没有观测器 —— 加进去就是把"打开配置"变成
            #   "服务起不来"。
            #
            #   读观测结果改走 metrics 的 /debug/vars (官方文档化的那条路),
            #   它没有启动期依赖, 两种模式都能用。这里保留 balancer 用的
            #   RoutingService。
            "services": ["StatsService", "HandlerService", "RoutingService"],
        },
        # 只读 HTTP 端点: 一次 GET 同时拿到流量聚合与观测结果。
        # 无鉴权, 所以只绑回环 —— 与 api 同一个原则。
        "metrics": {"listen": f"127.0.0.1:{_metrics_port}"},
        "policy": {
            "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
            "system": {"statsInboundUplink": True, "statsInboundDownlink": True,
                       "statsOutboundUplink": True, "statsOutboundDownlink": True},
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                *([{"type": "field", "outboundTag": "direct",
                    "domain": direct_domains}] if direct_domains else []),
                *([{"type": "field", "outboundTag": "direct",
                    "ip": direct_ips}] if direct_ips
                  else [{"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]}]),
                {"type": "field", "network": "tcp,udp", "balancerTag": BALANCER},
            ],
            "balancers": [{
                "tag": BALANCER,
                "selector": [OUTBOUND_PREFIX],
                "fallbackTag": "direct",
            }],
        },
        # 观测器不是可选项：balancer 没有它就选不出出站。
        # 用突发观测而非普通观测——探测时间点随机，更不容易形成固定特征。
        "burstObservatory": {
            "subjectSelector": [OUTBOUND_PREFIX],
            "pingConfig": {"interval": "1m", "sampling": 3, "timeout": "5s"},
        },
    }
    _apply_dns(cfg, args)
    return cfg, node_tag_by_id


def load_nodes(nodes_dir: str, current_file: str) -> tuple:
    """读节点目录，返回 (节点列表, 当前节点)。

    两个刻意的取舍：

    · `current` 软链不算节点。节点目录里那个软链指向当前节点，把它也当节点收进来
      就会生成一个和真节点配置完全一样的出站，于是列表里凭空多一个重复项。
    · 单个节点解析失败只跳过、不中止。一个订阅里混入一条格式不对的分享链接是
      常事，为此让整个配置生成失败、改不了任何节点，代价太大。跳过的会在
      stderr 上留一行。
    """
    nodes, current = [], None
    # current 是指向真实文件的软链，比对的是**解析后的**文件名。直接拿
    # basename 会拿到 "current"，跟任何真实节点都对不上，current_tag 恒为 null。
    cur_name = os.path.basename(os.path.realpath(current_file)) if current_file else ""
    try:
        names = sorted(os.listdir(nodes_dir))
    except OSError as e:
        fail(f"读不到节点目录 {nodes_dir}: {e}")
    for name in names:
        if not name.endswith(".json") or name == "current":
            continue
        path = os.path.join(nodes_dir, name)
        if os.path.islink(path):
            continue
        try:
            with open(path) as fh:
                node = json.load(fh)
        except (OSError, ValueError) as e:
            print(f"genconfig: 跳过 {name}: {e}", file=sys.stderr)
            continue
        if not all(node.get(k) for k in ("address", "port", "protocol")):
            continue
        node["__file"] = name
        node["__id"] = name
        nodes.append(node)
        if name == cur_name:
            current = node
    return nodes, current


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", help="统一模型的节点 JSON（单节点模式）")
    ap.add_argument("--all-nodes", action="store_true",
                    help="多出站模式：把 --nodes-dir 下所有节点写成常驻出站，运行时用 API 切换")
    ap.add_argument("--nodes-dir", default="", help="多出站模式的节点目录")
    ap.add_argument("--output", required=True)
    ap.add_argument("--mode", choices=[NORMAL, DIALER], required=True)
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=None, help="覆盖端口")
    ap.add_argument("--port-normal", type=int, default=1080)
    ap.add_argument("--port-dialer", type=int, default=1081)
    ap.add_argument("--validate-with", default="",
                    help="xray 二进制路径。给了就先用它剔掉构建不出来的节点 —— "
                         "多出站模式下订阅里一条坏节点会让整份配置起不来")
    ap.add_argument("--family", choices=list(FAMILIES), default="auto",
                    help="出站地址族。auto=直连走 IPv4、DNS 按连通性选（默认行为）；"
                         "v4/v6=强制只走该族（双栈机器上某一边不通时用）")
    ap.add_argument("--dns", choices=list(DNS_MODES), default="off",
                    help="off=不接管 DNS；standard=境外加密 DNS + 国内加密 DNS；"
                         "strict=全部加密 DNS 并强制经代理（防泄漏最严）")
    ap.add_argument("--api-port", type=int, default=18085)
    ap.add_argument("--metrics-port", type=int, default=0,
                    help="只读 metrics 端点 (GET /debug/vars); 0=自动挑一个空闲的")
    ap.add_argument("--http-port", type=int, default=0,
                    help="本机回环 HTTP 代理端口（0=不启用）。docker 等只认 HTTP 代理")
    ap.add_argument("--lan-http-port", type=int, default=0,
                    help="局域网 HTTP 代理端口（0=不启用）。设备在 WiFi 设置里填 IP+端口用")
    ap.add_argument("--logs", default="/opt/xray-browser-dialer/logs")
    ap.add_argument("--loglevel", default="warning")
    # mux: 三态。默认 None = 没表态 —— 由节点 JSON 的 mux 字段决定，都没有就不开。
    # ★ 以前是 `--no-mux` + default=True：默认给每个出站开 mux，节点里的
    #   `mux:false` 被吞掉，XHTTP 节点也被开上（官方明确不建议）。
    ap.add_argument("--mux", dest="mux", action="store_true", default=None,
                    help="显式开启 mux.cool（XHTTP/QUIC 传输下会被拒绝并说明原因）")
    ap.add_argument("--no-mux", dest="mux", action="store_false", default=None,
                    help="显式关闭 mux.cool（覆盖节点里的 mux:true）")
    args = ap.parse_args()

    if args.all_nodes:
        if args.mode != NORMAL:
            # 浏览器转发是进程级的：一个 env 让**所有**出站都去抢浏览器的连接额度，
            # 而观测器一开就会自动探测、瞬间把额度耗光。这里不静默降级成单节点，
            # 直接报错让调用方看清原因。
            fail("多出站模式不支持 dialer：Browser Dialer 必须单节点运行")
        nodes, cur = load_nodes(args.nodes_dir, args.node)
        if not nodes:
            fail(f"节点目录里没有可用节点: {args.nodes_dir}")
        xbin = getattr(args, "validate_with", "") or ""
        if xbin and os.access(xbin, os.X_OK):
            def _mk(ns):
                return build_multi(ns, cur, args)[0]
            nodes, dropped, perr = prune_unbuildable(nodes, _mk, xbin)
            if dropped:
                for d in dropped:
                    print(f"genconfig: 已剔除无法构建的节点 {d['file']} (tag {d['tag']})",
                          file=sys.stderr)
            if perr and not nodes:
                fail(f"所有节点都无法构建: {perr}")
        if not nodes:
            fail("剔除后没有可用节点")
        cfg, tags = build_multi(nodes, cur, args)
        cur_id = cur["__id"] if cur else None
    else:
        if not args.node:
            fail("必须给 --node，或给 --all-nodes --nodes-dir")
        node = json.load(open(args.node))
        for key in ("address", "port", "protocol"):
            if not node.get(key):
                fail(f"节点缺少字段 {key!r}")
        cfg = build(node, args)
        tags = {}
        cur_id = None
    # 输出目录自己建：这里是所有调用路径的公共落点（RUN.sh 建的布局、xbd apply、
    # 服务启动脚本 run-xray.sh），目录缺失时不能指望调用方自觉。
    # 实测踩过：全新安装漏建 runtime/ 时这里直接 FileNotFoundError，
    # 上层只看到「配置生成失败，这是致命的」—— 装完就用不了。
    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.output, "w") as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    out = {"ok": True, "mode": args.mode, "output": args.output,
           "port": cfg["inbounds"][0]["port"],
           "http_port": args.http_port,
           "lan_http_port": args.lan_http_port}
    if tags:
        # 把"节点 → 出站 tag"的映射交出去。切换节点靠的是这个 tag，调用方自己
        # 去猜文件名和 tag 的对应关系，早晚猜错一次。
        out["balancer"] = BALANCER
        out["tags"] = tags
        out["current_tag"] = tags.get(cur_id) if cur_id else None
    # 多出站模式额外落一份 sidecar。启动脚本要在 Xray 起来**之后**才把 balancer
    # 钉到用户选的那个节点，那时已经拿不到本函数的返回值了，只能读文件。
    # 只在多出站模式写: 单节点模式没有 balancer，钉了也没有意义。
    if tags:
        side = os.path.join(out_dir, "xray-gen.json")
        try:
            with open(side, "w") as fh:
                json.dump({k: out[k] for k in
                           ("balancer", "tags", "current_tag")}, fh, ensure_ascii=False)
        except OSError:
            # 落不了 sidecar 不影响启动: 退化成"观测器自动选"。
            # 但要说明白, 否则用户会以为是自己选的那个在跑。
            print(f"genconfig: 写不了 {side}，启动后无法自动选中当前节点",
                  file=sys.stderr)
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
