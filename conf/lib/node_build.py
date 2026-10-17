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
# ★ REALITY 的传输白名单照**内核源码**, 不照直觉 (2026-10-12 实测校正):
#
#   这里原来写的是 {"tcp","raw"}, 注释还写着"REALITY 只能跑在裸 TCP 上,
#   任何一层封装 (WS/gRPC/XHTTP) 都会破坏握手"。那是错的, 而且错的方向是
#   "挡掉合法组合":
#
#     内核 infra/conf/transport_internet.go 的报错原文:
#       "REALITY only supports RAW, XHTTP and gRPC for now."
#     并实测 `reality + xhttp` 的配置 xray run -test 通过。
#
#   官方恰恰主推 REALITY + XHTTP (最强安全层 + 官方主推传输), 把它挡掉等于
#   挡掉用户最想要的组合。conf/lib/preset.sh 的白名单也是这四个, 两边必须一致
#   (tools/check_libs.sh 有一条门禁专门盯这个漂移)。
#
#   真正非法的是 ws / httpupgrade —— 那两个不在内核白名单里, 建出来必然握手失败。
#
#   注: Vision flow 另有限制, 只在裸 TCP 上给 (见 mknode.sh)。
SECURITY_TRANSPORTS = {
    "none":   None,                  # 不限制
    "tls":    None,
    "reality": {"raw", "tcp", "xhttp", "grpc"},
}


class NodeError(ValueError):
    """规格不合法。消息直接面向用户, 不需要再包装。"""


# flow=xtls-rprx-vision (XTLS) 只在**裸 TCP 直接承载**时成立。
#
# ★ 这条不是推测, 是实测出来的 —— 而且是最阴的那一类:
#
#   `xray run -test` **放行** `reality + xhttp + flow=xtls-rprx-vision`
#   (它只校验 flow 这个名字合不合法), 但真跑起来立刻挂, 客户端日志:
#
#       proxy/vless/outbound: XTLS only supports TLS and REALITY directly for now.
#
#   端到端实测 (真内核 + 真 REALITY + 公网伪装目标):
#       REALITY + 裸TCP  + Vision   → 下载 http=200  ✓
#       REALITY + xHTTP  无 flow     → 下载 http=200  ✓
#       REALITY + xHTTP  + Vision   → 下载 http=000  ✗
#
#   不在这里拦住, 用户拿到的就是一个"配好了、校验通过、就是连不上"的节点。
#   内核自己也知道这条规矩, 报错原文就是 "directly" —— 中间隔了一层 HTTP
#   传输就不是"直接"了。
_XTLS_TRANSPORTS = ("raw", "tcp")


# xhttpSettings.mode 的合法值 (内核只认这四个, 别的直接拒)
#   照内核 infra/conf/xhttp 的解析逻辑, 见 _check_combo 里的说明。
_XHTTP_MODES = ("auto", "stream-up", "packet-up", "stream-one")


def _check_combo(protocol, transport, security, opts=None):
    opts = opts or {}
    allowed = SECURITY_TRANSPORTS.get(security)
    if allowed is not None and transport not in allowed:
        raise NodeError(
            f"{security} 不能与 {transport} 组合 "
            f"(只支持 {'/'.join(sorted(allowed))})。\n"
            f"  REALITY 的传输白名单照内核源码: "
            f"\"REALITY only supports RAW, XHTTP and gRPC for now.\""
        )

    # ---- flow(XTLS) 只能在裸 TCP 上 ----
    # 见 _XTLS_TRANSPORTS 处的实测记录: xray run -test 放行、真连失败,
    # 是最阴的一类"看着配好了其实连不上"。必须在生成前拦。
    flow = opts.get("flow") or ""
    if flow and flow != "none" and transport not in _XTLS_TRANSPORTS:
        raise NodeError(
            f"flow={flow} (XTLS) 只能在裸 TCP 上用, 不能配 {transport} 传输。\n"
            f"  内核原文: \"XTLS only supports TLS and REALITY directly for now.\"\n"
            f"  ⚠ xray run -test **不会**拦这个组合 —— 配置能校验通过, 真连起来立刻失败。\n"
            f"  要么去掉 flow (推荐), 要么换成 tcp/raw 传输。"
        )

    # ---- xhttp 的 mode ----
    # 内核对非法值是硬报错, 但那要等到 xray run -test 才看得到;
    # 这里提前拦, 报的是"你填错了什么"。
    mode = opts.get("xhttp_mode")
    if mode and mode not in _XHTTP_MODES:
        raise NodeError(
            f"xhttp 模式 {mode!r} 不合法, 只能是: "
            f"{' / '.join(_XHTTP_MODES)}。\n"
            f"  提醒: auto 在 **REALITY 下会退化成 stream-one (上下行合流)** —— "
            f"要上下行分离得显式选 stream-up。"
        )

    # ---- 上下行分离 (downloadSettings) ----
    if (opts.get("dl_address") or "").strip():
        # ① 内核明确禁止, 但**只在运行期**才报 —— `-test` 根本不执行这段检查
        #    (`infra/conf/transport_internet.go:439-441`), 实测 6 种组合全部
        #    "Configuration OK"。不拦就是"看着配好了、连上就断"。
        if (mode or "auto") == "stream-one":
            raise NodeError(
                "stream-one 是上下行**合流**模式, 不能配 downloadSettings。\n"
                f"  内核原文: Can not use \"downloadSettings\" in \"stream-one\" mode.\n"
                f"  ⚠ 这条检查在 xray run -test 阶段不会执行, 配置能校验通过、"
                f"真连起来立刻失败。要分离请选 stream-up 或 packet-up。"
            )
        # ② **直连**下行时端口必须与本 inbound 相同 (会话表 per-inbound)。
        #    ★ 经 CDN 的下行例外: 客户端连的是**边缘** (443), 源站仍然是
        #      同一个 inbound —— 端口不同是正常的。以前这里一刀切, 于是
        #      cdn-cdn 这种"两段都走 CDN"的组合直接建不出来。
        dport = opts.get("dl_port")
        # ★ front_reality: 下行连的是 REALITY 前置端口 (另一个监听), 它 fallback
        #   进同一个 xhttp 入站 —— 会话表仍是一份, 端口不同是正确形态。
        if dport and not opts.get("dl_cdn") and not opts.get("front_reality") \
                and int(dport) != int(opts.get("port") or 0):
            raise NodeError(
                f"下行端口 {dport} 与本节点端口 {opts.get('port')} 不一致 —— 连不上。\n"
                f"  原因: xHTTP 的会话表挂在**每个 inbound 自己**上 (hub.go:39/464), "
                f"上行 POST 建好的会话, 下行 GET 到另一个端口就找不到, 连接直接断。\n"
                f"  实测: 同一 inbound 同端口下行 http=200; 两个 inbound 下行 http=000。\n"
                f"  CDN 与直连的差别只能体现在**网络路径**上 —— 两段 nginx "
                f"都要 proxy_pass 到同一个 xray 端口。"
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
        # ★ 这里原来有一句 `if opts.get("allow_insecure"): tls["allowInsecure"] = True`。
        #
        #   现在没有任何调用方传 allow_insecure, 所以它一直是死代码 —— 但它是
        #   一颗**哑雷**: 谁哪天给向导加个"跳过证书校验"选项接上来, 生成的配置
        #   就会**直接启动失败**, 而且报错是内核级的:
        #       The feature "allowInsecure" has been removed and migrated to
        #       "pinnedPeerCertSha256".
        #
        #   官方替代方案是证书钉扎。自签证书要连通, 唯一正确的做法是钉扎,
        #   不是跳过校验 —— 跳过校验等于把中间人攻击的门打开。
        if opts.get("pinned_cert_sha256"):
            tls["pinnedPeerCertSha256"] = opts["pinned_cert_sha256"]
        # ★ ECH 服务端公钥 (X 特有)。
        #   字段名服务端是 echServerKeys, 客户端才是 echConfigList —— 用错内核
        #   直接拒收整份配置。值由 `xray tls ech` 生成, **成对**: 一次输出的
        #   ECH config list 给客户端、ECH server keys 留服务端。
        #   注意内核**不在加载期校验这个值** (实测塞垃圾串也能过 -test), 所以
        #   面板必须自己保证它来自 xray tls ech, 不能让用户手打。
        if opts.get("ech_server_keys"):
            tls["echServerKeys"] = opts["ech_server_keys"]
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
        # ★ ML-DSA-65 后量子签名 (X 特有, sing-box 没有)。
        #   `xray mldsa65` 输出 Seed / Verify 两个值, 对应下面这两个字段
        #   (从内核二进制 JSON tag 提取并实测 -test 通过)。
        #   注意它与 VLESS 的 ML-KEM-768 encryption 是**两个独立机制**:
        #     · mldsa65*  = REALITY 握手签名的抗量子
        #     · mlkem*    = VLESS 会话密钥交换的抗量子
        #   两者可以同时上。
        if opts.get("mldsa65_seed"):
            rs["mldsa65Seed"] = opts["mldsa65_seed"]
        if opts.get("mldsa65_verify"):
            rs["mldsa65Verify"] = opts["mldsa65_verify"]
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
        # ★ 服务端**不写 mode**。
        #
        #   官方文档 (XHTTP: Beyond REALITY, 快速上手 + STREAM-UP/ONE 两节) 原文:
        #     「服务端：默认同时接受三种模式，若设为具体的模式就是仅接受它」
        #   也就是说 mode 是**客户端**的选择; 服务端一写就把自己限死了。
        #   以前这里默认写 "auto"、nginx 档还会被改成 "packet-up", 于是:
        #     · 服务端只认那一种;
        #     · 客户端用别的模式 (比如浏览器拨号, 它的 HTTP 版本与 mode 由浏览器
        #       决定) 一律连不上, 而服务端日志里什么都看不出来。
        #   实测 (RN+CC 三模式矩阵):
        #     服务端不写 mode + nginx 用 grpc_pass → packet-up/stream-up/stream-one 全部 204
        #     服务端写 packet-up  + nginx 用 grpc_pass → 只有 packet-up 204, 另两个 000
        #   想**故意**只接受某一种时, 显式传 xhttp_server_mode。
        xh = {}
        if opts.get("xhttp_server_mode"):
            xh["mode"] = opts["xhttp_server_mode"]
        if opts.get("path"):
            xh["path"] = opts["path"]
        if opts.get("host"):
            xh["host"] = opts["host"]
        dl = _xhttp_download_settings(transport, security, opts)
        if dl:
            # ★ downloadSettings 是 **client only** (官方文档在 extra 的示例里
            #   明确标注为 client only)。这里仍然写进片段, 但要说清楚这是**本
            #   项目的内部载体**, 不是服务端配置的一部分:
            #     · 内核侧: 入站不读它 (只有客户端的 xhttpSettings 用它);
            #     · 本项目: conf/<tag>.json 是"这个节点是什么"的唯一真相,
            #       分享元数据、客户端产物、面板展示都从它extract 出来
            #       (nodes.py 的 dl_* 优先读片段, 元数据兜底);
            #     · 它**不会**把 mode 之类带进服务端 —— 服务端的 mode 由上面
            #       那句单独控制, 两者互不影响。
            #   想彻底不要它, 传 strip_download_settings=True。
            if not opts.get("strip_download_settings"):
                xh["downloadSettings"] = dl
        ss["xhttpSettings"] = xh

    elif transport == "grpc":
        gs = {"serviceName": opts.get("grpc_service", "GunService")}
        if opts.get("multi_mode"):
            gs["multiMode"] = True
        ss["grpcSettings"] = gs

    # ---- Hysteria2 混淆 (salamander) ----
    #
    # ★ 内核 26.3.27 把混淆搬进了新的 **finalmask** 体系:
    #     streamSettings.finalmask.udp = [{type:"salamander", settings:{password:"…"}}]
    #   注意字段名是**全小写** `finalmask` (不是 finalMask) —— 大小写写错
    #   内核不报错、也不生效, 直接静默失效。
    #
    #   HysteriaConfig 里那些 congestion/up/down/udphop 是**旧字段**,
    #   内核会打一行 "move to finalmask/quicParams" 的告警后继续接受,
    #   真正的新位置是这里。
    #
    #   实测 (RN, 同一份配置只差这一个字段):
    #     无混淆                  -> http=200
    #     finalmask.salamander    -> http=200
    #   两端密码必须一致, 且**必须**一起开 —— 一端开一端不开, 握手直接失败。
    if transport == "hysteria" and opts.get("hy2_obfs_password"):
        ss.setdefault("finalmask", {})["udp"] = [{
            "type": "salamander",
            "settings": {"password": opts["hy2_obfs_password"]},
        }]

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


def _xhttp_download_settings(transport, security, opts):
    """上下行分离 —— 下行那一套独立的目的地与 TLS/REALITY。

    内核对上/下行是分开建连接的 (`dialer.go:403-440`): 只要 `downloadSettings`
    非空, 就用**另一套** StreamConfig 重建一个 client, 连**另一个地址**。
    所以下行可以换 IP / 端口 / 证书 / REALITY 密钥 / SNI / path。

    ★ 端口必须与本 inbound 相同 —— 这不是风格问题, 是硬约束:
      会话表 `h.sessions` 是挂在**每个 inbound 自己**的 requestHandler 上的
      (`hub.go:39` / `hub.go:464`)。上行 POST 在 A 端口建会话, 下行 GET 到
      B 端口就查不到, 连接直接断。

      实测 (同一台机、同一套证书, 只改上下行是否同端口):
        同一 inbound 同端口        -> 下行 http=200  ✓
        同一 inbound 下行指死端口   -> 下行 http=000  (证明 downloadSettings 真在用)
        两个 inbound (TLS上/REALITY下) -> 下行 http=000  ✗ 会话不共享
        两个 inbound (TLS上/TLS下)     -> 下行 http=000  ✗

      所以 CDN 与直连的差别只能体现在**网络路径**上, 不能体现在端口上:
      两段 nginx 都要 proxy_pass 到**同一个** xray 端口。
    """
    addr = (opts.get("dl_address") or "").strip()
    if not addr:
        return None

    # 端口默认跟本 inbound 一样; 用户显式给了不同的, 在 _check_combo 里报。
    port = int(opts.get("dl_port") or opts.get("port") or 0)

    dl = {"address": addr, "port": port, "network": transport}

    # 下行的加密层: 默认与上行一致, 可以单独换 (最常见的用法是上行走 CDN 的
    # TLS、下行走直连的 REALITY, 或者反过来)。
    dsec = opts.get("dl_security") or security
    if dsec == "none":
        dl["security"] = "none"
    elif dsec == "reality":
        # ★ 下行 REALITY 是**服务端扮演客户端**去连出去, 所以这是一份**客户端**
        #   配置, 字段名与服务端入站那边不同: 内核要的是 `password`。
        #   原来这里写的是 `publicKey`, 于是 -test 直接:
        #       Failed to build REALITY config. > empty "password"
        #   —— 报错里只提 password, 一个字没提 publicKey, 照着报错查会绕远路。
        _rpw = (opts.get("dl_public_key") or opts.get("public_key") or "").strip()
        _rsni = (opts.get("dl_sni") or opts.get("sni") or "").strip()
        _rsid = (opts.get("dl_short_id") or opts.get("short_id") or "").strip()
        # ★ 缺凭据要**当场说清楚缺哪个**, 而不是让内核报 empty "password"。
        #   上下行分离 + 下行 REALITY 意味着要额外给一组 REALITY 参数,
        #   而这三个字段一个都不能空 (serverName 也不例外, 空的话 REALITY
        #   握手拿不到有效的 SNI)。
        _miss = [n for n, v in (("serverName", _rsni), ("password", _rpw),
                                ("shortId", _rsid)) if not v]
        if _miss:
            raise ValueError(
                "下行 REALITY 缺少参数: " + ", ".join(_miss) + "\n"
                "  原因: 下行 REALITY 是服务端扮演客户端连出去, 字段名是 "
                "password (不是 publicKey), 且三者都不能空。\n"
                "  给法 (conf/vlessxhttpecn.sh 或 preset_batch.sh):\n"
                "    dl_sni         = 伪装用的域名 (SNI, 不必解析到本机)\n"
                "    dl_public_key  = REALITY 公钥 (xray x25519 输出的 Password)\n"
                "    dl_short_id    = 短 ID (十六进制, 长度 <= 16, 偶数位)")
        dl["security"] = "reality"
        dl["realitySettings"] = {
            "serverName": _rsni,
            "fingerprint": opts.get("dl_fingerprint") or opts.get("fingerprint") or "chrome",
            "password": _rpw,
            "shortId": _rsid,
            "spiderX": opts.get("spider_x") or "/",
        }
    else:
        dl["security"] = "tls"
        dl["tlsSettings"] = {"serverName": opts.get("dl_sni") or opts.get("sni") or ""}

    # ★ 下行 path 必须与上行**完全相同**, 不是"可以不同"。
    #   实测 (RN, 真连): 把下行 path 设成另一个值, 服务端直接拒:
    #       [Info] transport/internet/splithttp: failed to validate path,
    #              request:/downlink-path-3k2/<sessionId>, config:/uplink-path-7x9/
    #   原因在源码 hub.go:461 —— 入站的请求处理器只认**顶层**
    #   xhttpSettings.path (l.config.GetNormalizedPath()), 入站那份
    #   downloadSettings 只用来建第二个 dialer, **不参与 path 校验**。
    #   所以下行请求带的路径必须与上行 path 一致, 服务端才认。
    #   于是: 服务端这里不该下发 dl_path (它会被忽略), 客户端也必须与上行一致。
    if (opts.get("dl_path") or "").strip() and \
            (opts["dl_path"].strip() != (opts.get("path") or "/").strip()):
        raise ValueError(
            "下行 path 与上行不一致 —— 这是连不上的, 内核不接受。\n"
            "  实测: 服务端只用顶层 xhttpSettings.path 校验下行请求\n"
            "        (hub.go:461), 入站的 downloadSettings.path 根本不参与。\n"
            f"  下行 {opts['dl_path']} vs 上行 {opts.get('path') or '/'}\n"
            "  上下行共用同一个 path 才对 —— 差异要体现在域名/CDN 那一侧。")
    xh = {"path": opts.get("path") or "/",
          "mode": opts.get("dl_mode") or opts.get("xhttp_mode") or "auto"}
    # ★ 绝不用 `extra`: 内核里 `extra` 非空会**整体替换**整个 xhttpSettings
    #   (`infra/conf/transport_internet.go:269-278`), 只保留 host/path/mode,
    #   其余字段静默回默认值 —— 而且 `-test` 不会报任何错。
    dl["xhttpSettings"] = xh
    return dl


# ================================================================ 回落 (fallbacks)
#
# 「不是本协议的流量转到哪」。
#
#   入站是 VLESS/Trojan + TLS 时, 内核先做 TLS 握手 —— 握手成功的**任何人都
#   连得上 TLS 层**。接下来:
#     · 报文长得像 VLESS/Trojan  → 走代理
#     · 不像 (普通浏览器、扫描器) → 转到 fallbacks.dest
#
#   所以它解决的是"**这个端口看起来必须像个真网站**"这件事: 主动探测的人
#   拿到的是一张真证书 + 一个真网站, 而不是一个连上就断的怪端口。
#
# 内核实测 (RN, v26.3.27):
#   普通 HTTPS 打 VLESS 端口  -> 拿到回落目标的网页 ("I-AM-THE-REAL-WEBSITE")
#   真 VLESS 客户端           -> http=200 (回落没影响真客户端)
#
# ★ 只在 **TLS** 上有意义:
#   · REALITY 有自己的回落 (realitySettings.target), 两套不要混;
#   · 无加密的入站连"是不是本协议"都判不了, 没有回落可言。
#
# ★ dest 收**端口数字**或 "host:port" 字符串。写数字 = 127.0.0.1:<端口>,
#   这是最常见的用法 (网站就跑在同一台机器上)。
#   xver 是 PROXY protocol 版本: 0 = 不发 (普通网站要这个),
#   1/2 = 发 v1/v2 (目标站要能解析 PROXY protocol 才行, 否则会把
#   PROXY 头当成 HTTP 请求 → 400)。
def _fallbacks(opts, security, protocol):
    port = str(opts.get("fallback_port") or "").strip()
    if not port:
        return None
    if security != "tls":
        raise ValueError(
            "回落 (fallbacks) 只在 TLS 入站上有意义。\n"
            "  · REALITY 有自己的回落机制 (realitySettings.target), 不要两套混用;\n"
            "  · 无加密入站连'是不是本协议'都判不了。"
        )
    if protocol not in ("vless", "trojan"):
        raise ValueError(f"{protocol} 不支持 fallbacks (内核只对 VLESS/Trojan 实现了它)")
    if not port.isdigit():
        # 允许 "host:port", 但必须是合法形态
        if ":" not in port:
            raise ValueError(f"回落目标 {port!r} 既不是端口也不是 host:port")
    try:
        xver = int(opts.get("fallback_xver") or 0)
    except (TypeError, ValueError):
        xver = 0
    if xver not in (0, 1, 2):
        raise ValueError(f"fallback xver 只能是 0/1/2, 得到 {xver}")
    return [{"dest": int(port) if port.isdigit() else port, "xver": xver}]


def _settings(protocol, opts):
    """协议级 settings。

    ★ flow 与传输的相容性在 build() 里查 (那里才知道 transport) ——
      原来误放在这里, 于是引用了一个本函数没有的名字, 直接 NameError。
    """
    if protocol == "vless":
        client = {"id": opts.get("uuid") or str(_uuid.uuid4())}
        if opts.get("flow"):
            client["flow"] = opts["flow"]
        if opts.get("encryption"):
            out = {"clients": [client], "decryption": opts["encryption"]}
        else:
            out = {"clients": [client], "decryption": "none"}
        fb = _fallbacks(opts, opts.get("_security") or "none", "vless")
        if fb:
            out["fallbacks"] = fb
        return out

    if protocol == "vmess":
        return {"clients": [{"id": opts.get("uuid") or str(_uuid.uuid4()),
                             "alterId": 0}]}

    if protocol == "trojan":
        out = {"clients": [{"password": opts["password"]}]}
        fb = _fallbacks(opts, opts.get("_security") or "none", "trojan")
        if fb:
            out["fallbacks"] = fb
        return out

    if protocol == "shadowsocks":
        return {"method": opts["method"], "password": opts["password"]}

    if protocol == "hysteria2":
        # Xray 的 hysteria2 inbound 用的是 protocol="hysteria" + version=2,
        # 不是 protocol="hysteria2"。写成 "hysteria2" 内核报
        # unknown config id: hysteria2 —— 它根本不认识这个名字。
        # 凭据字段也是 clients[].auth, 不是 clients[].password。
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

    _check_combo(protocol, transport, security, opts)

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

    # settings 里要判"回落能不能用" (只 TLS 上有意义), 所以把 security 也带进去
    _opts = dict(opts)
    _opts["_security"] = security
    inbound = {
        "listen": opts["listen"],
        "port": int(opts["port"]),
        # hysteria2 是协议族名, 内核侧的 inbound id 是 "hysteria" + version=2
        "protocol": ("hysteria" if protocol == "hysteria2" else protocol),
        "settings": _settings(protocol, _opts),
        "streamSettings": _stream_settings(transport, security, opts),
    }
    if opts.get("tag"):
        inbound["tag"] = opts["tag"]
    spec = {"inbounds": [inbound]}

    # ---- REALITY 前置 (#4118) ----
    #  0.0.0.0:<front>  vless+reality  --fallbacks--> 127.0.0.1:<xhttp>
    #  nginx:443        grpc_pass      -------------> 127.0.0.1:<xhttp>
    # 两条来路落到同一个 xhttp 入站, 会话表只有一份; 前置只做握手。
    if opts.get("front_reality"):
        fp = opts.get("front_port")
        if not fp:
            raise NodeError("需要 REALITY 前置, 但没给 front_port")
        fo = dict(opts)
        fo["listen"] = "0.0.0.0"
        fo["port"] = int(fp)
        fo["tag"] = (opts.get("tag") or "") + "-front"
        fo["sni"] = opts.get("front_sni") or opts.get("sni") or opts.get("domain") or ""
        fo["private_key"] = opts.get("front_private_key") or opts.get("private_key") or ""
        fo["short_id"] = opts.get("front_short_id") or opts.get("short_id") or ""
        fo["dest"] = opts.get("front_dest") or ((fo["sni"] + ":443") if fo["sni"] else "")
        if not fo["private_key"]:
            raise NodeError("REALITY 前置缺私钥 (front_private_key)")
        front = {
            "listen": fo["listen"],
            "port": fo["port"],
            "protocol": "vless",
            "settings": {
                "clients": [{"id": opts.get("front_uuid") or opts.get("uuid") or ""}],
                "decryption": "none",
                "fallbacks": [{"dest": "127.0.0.1:%d" % int(opts["port"]), "xver": 0}],
            },
            "streamSettings": _stream_settings("raw", "reality", fo),
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"],
                         "routeOnly": True},
            "tag": fo["tag"],
        }
        # reality-cdn 的上行就是前置 → 放第一个 (分享链接/产物按 inbounds[0] 取)
        if opts.get("front_first"):
            spec["inbounds"].insert(0, front)
        else:
            spec["inbounds"].append(front)
    return spec


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
