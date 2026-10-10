#!/usr/bin/env python3
"""节点能力检查：一个节点，两种使用方式。

对应需求第二/三条。核心观点：
    不要把节点分成"Browser Dialer 节点"和"普通节点"，
    而是同一个节点分别判断两种用法能不能用。

    Xray 普通模式   —— 几乎都支持（除本版本不认的协议）
    Browser Dialer  —— 只有 xhttp/websocket + TLS + 域名 才支持

判定规则来源（Xray-core 当前源码，不是教程）：
    transport/internet/splithttp/dialer.go:50   只有 realityConfig == nil 才启用 browser dialer
    transport/internet/websocket/dialer.go:114  同样的 host 规则
    docs/config/features/browser_dialer.md      只支持 XHTTP/WebSocket；不能自定义 SNI/Host

────────────────────────────────────────────────────────────────────────────
接入 proxy-node-compat 之后本文件的分工
────────────────────────────────────────────────────────────────────────────
* **内核能力维度**（协议/传输/安全/组合/版本）→ 交给 `compat2.py`
  → `proxy_node_compat`（判定只在那里发生一次）。入口 `check_all()` 默认走它。
* **Browser Dialer 维度** → 仍然只在本文件判定。它是**客户端自己的功能路径**
  （浏览器拨号的实测探测、SNI==host==address、xhttp mode、Chromium 无跳过证书校验），
  不是内核能力，proxy-node-compat 里没有也不该有对应规则 —— 所以它保留在这里，
  且**只有一个实现**，compat2 只转发不重写。
* **旧判定基线** → 全部原逻辑原样保留在 `check_all_legacy()` / `check_xray()` 里，
  用途有二：(1) compat 因为"没有规则"而 UNKNOWN 时回退；(2) `tools/dualkernel-compare.py`
  的双跑对比基准。
* 回滚开关：`XBD_COMPAT_ENGINE=legacy` 一键退回旧判定（不改代码）。
"""
from __future__ import annotations

import json
import os
import re
import sys

OK = "SUPPORTED"
WARN = "SUPPORTED_WITH_WARNING"
NO = "NOT_SUPPORTED"
UNKNOWN = "UNKNOWN"

# ---------------------------------------------------------------------------
# 官方能力清单（来自 Xray 源码与官方文档，不是推测）
# ---------------------------------------------------------------------------
# 出站协议：源码 proxy/ 目录下注册的协议
#   vless vmess trojan shadowsocks shadowsocks_2022 hysteria wireguard
#   http socks freedom dns blackhole loopback
#   （dokodemo-door / tun 是入站专用，不能做出站）
# 我们这里只关心"能当节点用的代理协议"，所以只列代理类。
XRAY_PROTOCOLS = {"vless", "vmess", "trojan", "shadowsocks", "hysteria2",
                  # 简易出站：把本机/局域网里别的内核当上游（见 xbd node simple）
                  "socks", "http"}

# 传输方式：官方 transport.md 的 method 取值 —— raw|xhttp|mkcp|grpc|websocket|httpupgrade|hysteria
# 实测（v26.3.27）method 还接受这些别名与遗留值：
#   tcp=raw  splithttp=xhttp  ws=websocket  kcp=mkcp  http=h2
# 见 TRANSPORT_ALIASES，统一归一化后再判定。
# 只列官方 transport.md 支持、且本机 26.3.27 实测 ACCEPT 的值。
# h2 / h3 / http / quic 在 26.x 已被移除（实测报错：
#   "The feature HTTP transport ... has been removed and migrated to XHTTP stream-one H2 & H3"
#   "The feature QUIC transport ... has been removed and migrated to XHTTP stream-one H3"），
# 如果把它们算作"支持"，genconfig 会写出 network=h2，而 run-xray.sh 的 `xray run -test`
# 会直接 exit 1 —— 后果不是单节点失败，而是**整个 Xray 实例起不来**。
XRAY_TRANSPORTS = {"raw", "xhttp", "mkcp", "grpc", "websocket", "httpupgrade", "hysteria"}

# 传输方式别名 -> 规范名。判定前一律先归一化，避免同一个传输被写成不同样子而漏判。
TRANSPORT_ALIASES = {
    "tcp": "raw", "raw": "raw",
    "xhttp": "xhttp", "splithttp": "xhttp",
    "ws": "websocket", "websocket": "websocket",
    "kcp": "mkcp", "mkcp": "mkcp",
    "grpc": "grpc",
    "httpupgrade": "httpupgrade",
    "hysteria": "hysteria",
}
# 刻意**不**收录 gun / http / h2 / h3 / quic：
# 它们在 26.x 全部被拒（实测 network=gun/http/h2/quic 均 REJECT）。
# 把非法值"洗"成合法值会让界面把一个必然起不来的节点显示成"支持"。

# 传输安全：官方 transport.md 的 security 取值
XRAY_SECURITIES = {"none", "tls", "reality"}

# REALITY 能配的传输（实测内核报错：REALITY only supports RAW, XHTTP and gRPC for now.）
REALITY_TRANSPORTS = {"raw", "xhttp", "grpc"}


_XRAY_VERSION_CACHE: list = []


def xray_version() -> tuple:
    """本机 Xray 的版本号，例如 (26, 3, 27)。取不到就返回 ()（此时不做版本判定）。"""
    if _XRAY_VERSION_CACHE:
        return _XRAY_VERSION_CACHE[0]
    ver: tuple = ()
    try:
        import subprocess
        xray = os.path.join(os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer"), "bin", "xray")
        if not os.path.exists(xray):
            xray = "xray"
        out = subprocess.run([xray, "version"], capture_output=True, text=True, timeout=10).stdout
        ver = parse_version(out)
    except Exception:
        ver = ()
    _XRAY_VERSION_CACHE.append(ver)
    return ver


def canon_transport(name: str) -> str:
    """传输名归一化。判定与生成都用它，避免 'ws' / 'websocket' 被判成两种东西。"""
    return TRANSPORT_ALIASES.get((name or "").strip().lower(), (name or "").strip().lower())

# Browser Dialer 只实现了这两种
DIALER_TRANSPORTS = {"xhttp", "websocket"}

# XHTTP 下 Browser Dialer **只实现了 packet-up**。
#
# ★ 这一条官方文档完全没写, 是从源码挖出来的:
#     splithttp/browser_client.go:24-27 —— 非 nil body 直接返回
#     "bidirectional streaming for browser dialer not implemented yet";
#     而 stream-up (dialer.go:442-446) 与 stream-one (:423-428) 都传非 nil reader。
#
#   packet-up 与 auto 可以用:
#     · packet-up 本来就是它
#     · auto 在 TLS 下已于 commit 0995fa41 (→v1.250516.0) 改为 packet-up,
#       所以 "auto + BD" 开箱可用
#   显式写 stream-up / stream-one 的节点走 BD 会**失败**。
BD_XHTTP_BAD_MODES = {"stream-up", "stream-one", "streamup", "streamone"}


def bd_xhttp_mode_ok(node: dict) -> bool:
    """XHTTP 节点的 mode 是否与 Browser Dialer 兼容（非 xhttp 一律 True）。"""
    if canon_transport(node.get("transport") or "") != "xhttp":
        return True
    mode = (node.get("mode") or "").strip().lower().replace("_", "-")
    return mode not in BD_XHTTP_BAD_MODES

# 这些 vless 加密方案不影响浏览器拨号：浏览器只负责 TLS/HTTP 传输，
# 加密协商仍然在 Xray 内完成。比较时只看算法名（点号前一段），且忽略大小写 ——
# key 部分大小写敏感不能动，算法名不敏感。
DIALER_OK_ENCRYPTION = {"none", "auto", "mlkem768x25519plus", "mlkem768", "x25519"}

# 官方版本门槛（见 browser_dialer.md 的两个 Badge）：
#   WebSocket 浏览器转发  -> v1.4.1+
#   XHTTP 浏览器转发      -> v1.8.19+
# 低于该版本的 Xray 即使带 XRAY_BROWSER_DIALER，对应传输也不会走浏览器。
DIALER_MIN_VERSION = {"websocket": (1, 4, 1), "xhttp": (1, 8, 19)}


# 内核认得的指纹取值 —— 取自官方源码 transport/internet/tls/tls.go 的三张表
# （PresetFingerprints / ModernFingerprints / OtherFingerprints）。
#
# ★ 为什么要在脚本里拦：未知值**不是静默降级，是整份配置构建失败**
#   （infra/conf: unknown "fingerprint": xxx）。多出站把所有节点放进一份配置，
#   所以一个节点写错 fp 就能让整个客户端起不来。
#   实测：fp=not-a-real-fingerprint → run -test 退出码 23、Failed to start。
#
# 大小写不敏感（实测 fp=Chrome / CHROME 均通过），比较时统一转小写。
FP_VALUES = {
    # 面板/客户端推荐的短名
    "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq",
    "random", "randomized", "randomizednoalpn", "unsafe",
    # 具体版本（会被 random 抽中的一组）
    "hellofirefox_120", "hellofirefox_148", "hellochrome_120", "hellochrome_131",
    "hellochrome_133", "helloios_13", "helloios_14", "helloedge_106",
    "hellosafari_26_3", "hello360_11_0", "helloqq_11_1",
    # 其余（含过老版本），内核也认
    "hellogolang", "hellorandomized", "hellorandomizedalpn",
    "hellorandomizednoalpn", "hellofirefox_auto", "hellofirefox_55",
    "hellofirefox_56", "hellofirefox_63", "hellofirefox_65", "hellofirefox_99",
    "hellofirefox_102", "hellofirefox_105", "hellochrome_auto",
    "hellochrome_58", "hellochrome_62", "hellochrome_70", "hellochrome_72",
    "hellochrome_83", "hellochrome_87", "hellochrome_96", "hellochrome_100",
    "hellochrome_102", "hellochrome_106_shuffle", "helloios_auto",
    "helloios_11_1", "helloios_12_1", "helloandroid_11_okhttp",
    "helloedge_85", "helloedge_auto", "hellosafari_16_0", "hellosafari_auto",
    "hello360_auto", "hello360_7_5", "helloqq_auto", "hellochrome_100_psk",
    "hellochrome_112_psk_shuf", "hellochrome_114_padding_psk_shuf",
    "hellochrome_115_pq", "hellochrome_115_pq_psk", "hellochrome_120_pq",
}

# 给用户看的一小段（不要把 40 多个都糊上去）
FP_HINT = "chrome firefox safari edge ios android 360 qq random randomized"


def parse_version(text: str) -> tuple:
    """从 'Xray 26.3.27 (Xray, Penetrates Everything.) ...' 里取出 (26,3,27)。"""
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(x) for x in m.groups()) if m else ()

VERDICT_RANK = {OK: 3, WARN: 2, UNKNOWN: 1, NO: 0}


def _is_ip(host: str) -> bool:
    if not host:
        return False
    if host.startswith("[") or ":" in host:
        return True
    parts = host.split(".")
    if len(parts) != 4:
        return False
    return all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)


# ---------------------------------------------------------------------------
# Xray 普通模式
# ---------------------------------------------------------------------------
def check_xray(node: dict) -> dict:
    checks, notes = [], []

    def add(item, verdict, detail):
        checks.append({"item": item, "verdict": verdict, "detail": detail})

    proto = (node.get("protocol") or "").lower()
    if not proto:
        add("协议", NO, "缺失")
        return _pack(checks, notes)

    if proto in XRAY_PROTOCOLS:
        label = {"shadowsocks": "Shadowsocks", "hysteria2": "Hysteria2",
                 "socks": "SOCKS5（简易出站）", "http": "HTTP（简易出站）"}.get(proto, proto.upper())
        add("协议", OK, label)
    else:
        add("协议", NO, f"{proto} 不在本 Xray 版本的出站协议里")
        notes.append("Browser Dialer 不能替代协议支持：它只是把 TLS/HTTP 交给浏览器，"
                     "协议本身仍由 Xray 处理。")
        return _pack(checks, notes)

    if not node.get("address"):
        add("地址", NO, "缺失")
    else:
        add("地址", OK, f'{node["address"]}:{node.get("port")}')
    # 指纹：内核未知值会**整份配置构建失败**，必须在导入时就拦住。
    # 放在这里而不是渲染阶段 —— 那时配置已经生成完了，用户看到的是
    # "某个节点莫名其妙不见了"，而不是"这个 fp 不支持"。
    _fp = (node.get("fingerprint") or "").strip()
    if _fp:
        if _fp.lower() in FP_VALUES:
            add("指纹", OK, _fp)
        else:
            add("指纹", NO, f"{_fp} 内核不认")
            notes.append(f'内核遇到未知 fingerprint 会直接构建失败'
                         f'（unknown "fingerprint": {_fp}），'
                         f'多出站时一个节点就能让整份配置起不来。'
                         f'可用：{FP_HINT}')

    if proto in ("socks", "http"):
        # 上游代理可以不开认证。写了用户名就必须有密码（反之亦然）——
        # 只填一个的话内核会拿空密码去认证，报错还很难懂。
        _u = (node.get("username") or "").strip()
        _p = (node.get("password") or "").strip()
        if _u and not _p:
            add("凭据", WARN, "填了用户名但没填密码")
            notes.append("很多本地代理是「用户名+密码」一起校验；只填一个通常会认证失败。")
        elif _u:
            add("凭据", OK, f"用户名 {_u}")
        else:
            add("凭据", OK, "无需认证")
    elif proto in ("vless", "vmess") and not node.get("uuid"):
        add("凭据", NO, "缺少 UUID")
    elif proto in ("trojan", "hysteria2") and not node.get("password"):
        add("凭据", NO, "缺少密码")
    elif proto == "shadowsocks" and not (node.get("method") and node.get("password")):
        add("凭据", NO, "缺少 method/password")
    else:
        add("凭据", OK, "完整")

    # 必须归一化再用：node.py 把 raw 统一存成 "tcp"，而 XRAY_TRANSPORTS 里是 "raw"。
    # 不归一化的话**每个普通 TCP 节点**都会被误报"未在本版本确认"（实测过），
    # 而且同一个节点在 check_xray 与 check_dialer 里会得到互相矛盾的结论。
    transport = canon_transport(node.get("transport") or "")
    if proto in ("socks", "http"):
        # 简易出站没有传输层（不支持 TLS/WS/XHTTP —— 上游是什么就是什么）。
        # 按传输白名单去判它会得到"传输不支持"这种莫名其妙的结论。
        add("传输", OK, "无（本地代理跳，传输由上游决定）")
    elif proto == "hysteria2":
        add("传输", OK, "hysteria（原生 QUIC 传输）")
    elif transport in XRAY_TRANSPORTS:
        add("传输", OK, transport)
    else:
        add("传输", NO, f"{transport or '未知'} 不在本 Xray 版本支持的传输里")
        notes.append("本版本支持的传输：raw / xhttp / mkcp / grpc / websocket / httpupgrade / hysteria。"
                     "h2、h3、http、quic、gun 等已被 26.x 移除，写了会让整个实例起不来。")
        return _pack(checks, notes)

    if proto in ("socks", "http"):
        add("安全", OK, "无（明文本地跳；要加密请在上游那端开）")
        if node.get("flow"):
            add("flow", WARN, "简易出站没有 flow")
        return _pack(checks, notes)

    security = (node.get("security") or "none").lower()
    # security 只认这三个；xtls 已被移除（实测报错 "The feature Legacy XTLS has been removed"）。
    # 之前给了 WARN，而 WARN 仍算"可用"，会让一个必然起不来的节点显示成能用。
    if security not in XRAY_SECURITIES:
        add("安全", NO, f"{security} 不是本版本支持的传输安全（可选 none/tls/reality）")
        notes.append("Legacy XTLS 已移除；官方建议改用 xtls-rprx-vision + tls/reality。")
        return _pack(checks, notes)
    add("安全", OK, security)

    # REALITY 只支持 RAW / XHTTP / gRPC —— 实测报错原文：
    #   "REALITY only supports RAW, XHTTP and gRPC for now."
    # 之前这里只分别检查 transport 和 security，从不校验**组合**，
    # 于是 ws+reality 这类必然起不来的组合被判"支持" → 选中它 → 整个实例起不来。
    if security == "reality" and transport not in REALITY_TRANSPORTS:
        add("REALITY × 传输", NO, f"REALITY 不支持 {transport}")
        notes.append("REALITY 只能与 RAW / XHTTP / gRPC 组合（实测内核报错："
                     "REALITY only supports RAW, XHTTP and gRPC for now.）。")
        return _pack(checks, notes)

    if security == "reality" and not node.get("reality_public_key"):
        add("Reality 公钥", NO, "security=reality 但缺少 pbk")
    if proto == "hysteria2":
        notes.append("Hysteria2 在 Xray 里的协议名是 hysteria（version 2）；"
                     "传输字段名随版本不同：v26.3.27 及更早用 streamSettings.network，"
                     "main 分支/新版用 method。本项目生成配置时会两个都写以兼容。")
        if node.get("allow_insecure") and not node.get("pinned_cert_sha256"):
            notes.append("该节点声明了 skip-cert-verify / allowInsecure，"
                         "但 Xray 26.x 已移除 allowInsecure —— 会报"
                         "「certificate relies on legacy Common Name field」而连不上。"
                         "解决：执行 xbd cert <编号> 取服务端证书指纹并固定"
                         "（pinnedPeerCertSha256 是官方替代方案）。")
    if node.get("allow_insecure"):
        add("证书校验", WARN, "节点声明跳过证书校验")
        notes.append("Xray 26.x 已移除 allowInsecure（迁移到 pinnedPeerCertSha256）；"
                     "本次生成的配置不会写入该项，因此证书必须有效。")
    if node.get("flow") and proto != "vless":
        add("flow", WARN, f"flow 仅对 VLESS 有意义（当前协议 {proto}）")

    return _pack(checks, notes)


# ---------------------------------------------------------------------------
# Browser Dialer 模式
# ---------------------------------------------------------------------------
def check_dialer(node: dict) -> dict:
    checks, notes = [], []

    def add(item, verdict, detail):
        checks.append({"item": item, "verdict": verdict, "detail": detail})

    proto = (node.get("protocol") or "").lower()
    transport = canon_transport(node.get("transport") or "")
    security = (node.get("security") or "none").lower()
    addr = (node.get("address") or "").strip()
    sni = (node.get("sni") or "").strip()
    host = (node.get("host") or "").strip()

    if proto in ("socks", "http"):
        # 简易出站没有传输层，浏览器拨号对它**不适用**（也不需要）——
        # 不能沿用"要求传输是 ws/xhttp"那句通用原因，那会让人以为配错了。
        add("类型", OK, "本地代理跳（socks/http 出站）")
        add("浏览器拨号", WARN, "不适用：它没有传输层，本来就是直连上游口")
        notes.append("浏览器拨号是给「代理协议 + ws/xhttp 传输」用的；"
                     "简易出站走的是本机/局域网的代理口，用不用它都一样。"
                     "该节点仍可正常使用。")
        return _pack(checks, notes)

    # 实测优先：配置层面"合法"不等于"能通"。实测过两种判定覆盖不到的情况：
    #   * 同一套 ws 配置，8nm3ai 这台服务器浏览器路径可用、cswdcsdcw 不行 —— 配置一模一样；
    #   * WebSocket 缺 early data 时，内嵌页面会因为 task.extra 为空直接抛 TypeError。
    # 所以只要 tools/browserprobe.py 跑过并留下结果，就**以实测为准**，不再靠推断。
    probe = node.get("browser_probe") or {}
    if probe.get("ok") is False:
        add("实测", NO, f"浏览器路径实测不可用：{probe.get('reason') or '未知原因'}")
        notes.append(f"这是真实请求的探测结果（{probe.get('at', '')}），"
                     "不是配置推断。该节点请使用原生 TLS：同一个入口，无需任何设置。")
        return _pack(checks, notes)
    if probe.get("ok") is True:
        add("实测", OK, f"浏览器路径实测可用（出口 {probe.get('exit_ip') or '已通'}）")

    add("协议", OK if proto == "vless" else NO,
        "VLESS" if proto == "vless" else f"{proto} 不满足浏览器转发条件（需要传输为 WebSocket/XHTTP）")
    if proto != "vless":
        notes.append("Browser Dialer 是 Xray 的传输层能力，与代理协议无关（vmess/trojan 同样可用），"
                     "但它要求传输是 WebSocket 或 XHTTP。该节点仍可用普通 Xray 模式。")
        return _pack(checks, notes)

    # vless 的 encryption 可能是后量子方案：mlkem768x25519plus.native.0rtt.<key>。
    # 它不是"服务端应用层加密"，浏览器拨号照常可用 —— 之前这里只认 "none"，
    # 于是所有 mlkem 节点被误判成"Browser Dialer 不支持"。
    enc = (node.get("encryption") or "none").strip()
    enc_scheme = enc.lower().split(".")[0] if enc else "none"
    add("encryption", OK if enc_scheme in DIALER_OK_ENCRYPTION else NO, enc or "none")

    if transport in DIALER_TRANSPORTS:
        add("传输", OK, transport)
    else:
        add("传输", NO, f"{transport or '未知'}：浏览器只能发 HTTP(S)，只实现了 XHTTP 与 WebSocket")
        notes.append(f"该节点仍可用普通 Xray 模式（transport={transport}）。")
        return _pack(checks, notes)

    # 官方版本门槛：低于门槛的 Xray 即使带 XRAY_BROWSER_DIALER，该传输也不会走浏览器
    need = DIALER_MIN_VERSION.get(transport)
    if need:
        have = xray_version()
        if have and have < need:
            ver = ".".join(str(x) for x in have)
            low = ".".join(str(x) for x in need)
            add("Xray 版本", NO, f"当前 {ver}，{transport} 的浏览器转发需要 >= {low}")
            notes.append(f"官方文档：{transport} 的浏览器转发需要 Xray >= {low}。"
                         f"请先 xbd xray update。")
            return _pack(checks, notes)
        if have:
            add("Xray 版本", OK, ".".join(str(x) for x in have))

    if security == "reality":
        add("安全", NO, "REALITY 被 Browser Dialer 代码路径排除")
        notes.append("splithttp/dialer.go:50 只在 realityConfig == nil 时启用 browser dialer；"
                     "浏览器 JS 无法完成 REALITY 握手。该节点可用普通 Xray 模式。")
        return _pack(checks, notes)

    # XHTTP 的 mode 限制 —— 官方文档没写, 依据在 bd_xhttp_mode_ok 的注释里
    if transport == "xhttp" and not bd_xhttp_mode_ok(node):
        add("XHTTP mode", NO, node.get("mode") or "")
        notes.append("Browser Dialer 的 XHTTP 只实现了 packet-up："
                     "stream-up / stream-one 会返回 "
                     "\"bidirectional streaming for browser dialer not implemented yet\"。"
                     "该节点仍可用普通 Xray 模式；要用浏览器请把 mode 改成 packet-up 或 auto。")
        return _pack(checks, notes)
    elif transport == "xhttp":
        add("XHTTP mode", OK, (node.get("mode") or "auto") + "（回落到 packet-up）")

    if security == "tls":
        port = int(node.get("port") or 0)
        add("TLS", OK if port == 443 else WARN, f"TLS :{port}")
        if port != 443:
            notes.append(f"非 443 端口会生成 https://<host>:{port}，服务端需接受该 authority。")
    else:
        add("安全", WARN, f"security={security}（明文 HTTP/WS）")
        notes.append("无 TLS 时浏览器走 ws:// 或 http://，可用但无保护。")

    if not addr:
        add("地址", NO, "缺失")
        return _pack(checks, notes)

    if _is_ip(addr):
        add("地址", NO, f"{addr} 是 IP 字面量")
        notes.append("浏览器直接拨 URL host，IP 会让 SNI 变成 IP，证书需含 IP SAN；"
                     "官方要求用域名（需要指 IP 就配 DNS 或 hosts）。")
    else:
        add("地址", OK, addr)

    # 官方硬要求：SNI == host == address，且自定义 HTTP 头与其它 tlsSettings 项都会被忽略。
    # 三者不一致时浏览器仍会尝试，但用的是它自己拼出来的 URL，极易握手失败 —— 判 NOT_SUPPORTED。
    effective = host or sni or addr
    if host and sni and host != sni:
        add("SNI == Host == Address", NO, f"host={host} sni={sni} address={addr}")
        notes.append("官方要求 SNI == host == address：Browser Dialer 忽略自定义 Host 与其它 "
                     "tlsSettings 项，浏览器只按 SNI 拼 URL，不一致会导致握手失败。")
        return _pack(checks, notes)
    if (host and host != addr) or (sni and sni != addr):
        add("SNI == Host == Address", NO,
            f"host={host or '（未写）'} sni={sni or '（未写）'} address={addr}")
        notes.append("官方要求 SNI == host == address。请把地址写成域名（需要指 IP 就配 DNS 或 hosts），"
                     "并让 sni/host 与 address 完全一致。")
        return _pack(checks, notes)
    add("SNI == Host == Address", OK, effective)
    if not probe:
        notes.append("尚未实测：配置层面合法，但实际能否连通取决于服务端。"
                     "跑 xbd node probe <编号> 做一次真实探测。")

    # 官方注意事项，属于"节点级环境要求"，判定为警告而非不支持
    notes.append("浏览器必须能直连该节点域名（用 tun 时注意环路），且节点域名不能依赖代理才能解析 —— "
                 "浏览器开了 Secure DNS 时尤其容易出现这种死锁。")

    # 这条必须判 NOT_SUPPORTED，不能只给个 WARN 提示 —— 实测就是**必然失败**：
    # Browser Dialer 下 TLS 完全由 Chromium 完成，而 Chromium 没有任何"跳过证书校验"
    # 的开关（--ignore-certificate-errors 在 headless 下也不生效）。
    # 节点声明 skip-cert-verify 说明服务端证书不被系统信任，浏览器路径就走不通。
    # 注意：这里不能直接判 NOT_SUPPORTED。skip-cert-verify 只是个客户端开关，
    # 不代表服务端证书一定不被信任 —— 实测同一个 xhttp 节点声明了它，
    # 浏览器路径照样能用（因为证书本来就有效）。所以只给警告，让实验结果说话。
    if node.get("allow_insecure"):
        add("证书校验", WARN, "节点声明 skip-cert-verify；浏览器会照常校验证书")
        notes.append("浏览器无法跳过证书校验。若该节点证书实际不被系统信任，"
                     "浏览器路径会失败，请改用原生 TLS。")
    else:
        add("证书校验", OK, "由浏览器正常校验")

    if node.get("fingerprint"):
        notes.append(f"fingerprint={node['fingerprint']} 无意义：Chromium 自带真实指纹。")
    if node.get("flow"):
        add("flow", WARN, f"flow={node['flow']} 会被丢弃")
        notes.append("flow（vision/xtls）无法用于 JS 网络栈，生成配置时不写入。")

    if transport == "xhttp":
        add("XHTTP mode", OK if node.get("mode") else WARN, node.get("mode") or "未指定（用服务端默认）")
        notes.append("Xray issue #5739：Browser Dialer 忽略 xhttp sessionId/seqStr，服务端需接受。")
        notes.append("XHTTP 响应需带 CORS 头；第三方 CDN 可能剥掉。")
    if transport == "websocket":
        path = node.get("path") or ""
        add("WS path", OK if (not path or path.startswith("/")) else WARN, path or "(默认)")
        notes.append("early data 走 Sec-WebSocket-Protocol，服务端需 Xray >= 1.4.1。")

    notes.append("建议开 Mux.Cool：浏览器对同域并发有上限。")
    return _pack(checks, notes)


def _pack(checks, notes) -> dict:
    verdicts = [c["verdict"] for c in checks]
    if NO in verdicts:
        overall = NO
    elif UNKNOWN in verdicts:
        overall = UNKNOWN
    elif WARN in verdicts:
        overall = WARN
    else:
        overall = OK
    return {"overall": overall, "checks": checks, "notes": notes}


# ---------------------------------------------------------------------------
# 能力标签（需求第十三条）
# ---------------------------------------------------------------------------
def capability_tags(node: dict, xray: dict, dialer: dict) -> list[str]:
    tags = []
    if node.get("protocol"):
        tags.append(node["protocol"].upper() if node["protocol"] != "shadowsocks" else "Shadowsocks")
    if node.get("transport"):
        tags.append(node["transport"].upper() if node["transport"] != "websocket" else "WS")
    if (node.get("security") or "none") != "none":
        tags.append(node["security"].upper())
    if node.get("ech"):
        tags.append("ECH")
    if node.get("reality_public_key"):
        tags.append("Reality")
    if node.get("flow"):
        tags.append(node["flow"])
    if xray["overall"] in (OK, WARN):
        tags.append("Xray")
    else:
        tags.append("Xray 不可用")
    tags.append("Browser Dialer" if dialer["overall"] in (OK, WARN) else "Browser Dialer 不可用")
    return tags


def blocking_reason(node: dict, result: dict = None) -> str:
    """这个节点**为什么**用不了 Xray 内核 —— 一句话, 且必须是真实原因。

    为什么单独有这个函数
    --------------------
    `nodefilter.py` 原来把任何 `can_use_xray=False` 都写成
        Xray 内核不支持该协议（trojan）
    实测 (E2E: 分享订阅 5 个节点只导入 4 个) 那句话是**错的**: trojan 是内核
    原生支持的协议, 该节点被丢掉的真实原因是"链接里的 pbk 没被解析出来 →
    security=reality 却缺 REALITY 公钥"。用户照那句提示去查"内核为什么不支持
    trojan", 方向完全错了 —— 而且换个内核也解决不了。

    所以判据是: **协议这一项是否本身不可用**。
      · 协议就不支持            -> 说"内核不支持该协议"
      · 协议支持、某项参数缺失  -> 逐条点名缺的是什么 (可执行的修复方向)
    """
    result = result if result is not None else check_all(node)
    xray = (result or {}).get("xray") or {}
    checks = xray.get("checks") or []
    # "内核兼容性 SUPPORTED / compat" 是适配层加进来的**汇总行**, 不是一条具体
    # 判据 —— 把它当原因念出来只会让人更糊涂 (实测原文:
    # "…：内核兼容性 —— SUPPORTED / compat; Reality 公钥 —— security=reality 但缺少 pbk")。
    bad = [c for c in checks
           if c.get("verdict") == NO and c.get("item") != "内核兼容性"]
    if not bad:
        return ""
    proto = node.get("protocol") or "?"
    proto_bad = [c for c in bad if c.get("item") == "协议"]
    if proto_bad:
        return f"Xray 内核不支持该协议（{proto}）：{proto_bad[0].get('detail') or ''}".rstrip("：")
    detail = "; ".join(f"{c.get('item')} —— {c.get('detail')}" for c in bad)
    return (f"节点参数不完整，不是内核不支持 {proto}（{proto} 是内核原生支持的协议）：{detail}")


def want_browser_dialer(node: dict) -> bool:
    """这个节点要不要用浏览器完成 TLS —— **唯一**判定入口。

    为什么必须只有一个入口：run-xray.sh（决定带不带 XRAY_BROWSER_DIALER）、
    health-check.sh（决定要不要拉起 Chromium）、actions.sh（换节点时决定启停）
    三处若各判各的，就会出现"一个说要、一个说不要"的打架状态 ——
    而这类不一致的后果不是标签错，是节点**永久挂住**（dialTask 没有超时）。

    判定顺序：
      1. 协议层面必须可能（vless + ws/xhttp + 非 reality）
      2. 实测结论：tools/browserprobe.py 判过"浏览器路径不可用"的，一律不用。
         这一条是**必需**的，不是保守：进程只要带着 XRAY_BROWSER_DIALER，
         xhttp/websocket 出站就全部交给浏览器，而 dialTask() 阻塞在 <-conns 上
         **没有超时** —— 实测不通的节点会永久挂住（curl 一直等到超时）。
         面板 UI 早就是这条规则（mayProto && probe !== false，实测失败只给「普通连接」），
         这里必须一致，否则就是"界面显示仅原生、进程却在走浏览器"。
      3. 节点自己的 use_browser：None=默认用，True=用，False=不用
    """
    proto = (node.get("protocol") or "").lower()
    transport = canon_transport(node.get("transport") or "")
    security = (node.get("security") or "none").lower()
    if proto != "vless" or transport not in DIALER_TRANSPORTS or security == "reality":
        return False
    # XHTTP 只支持 packet-up (见 bd_xhttp_mode_ok 的源码依据)。
    # ★ 必须与 check_dialer 判得一模一样 —— 这两处不一致的后果不是标签错,
    #   是节点**永久挂住**: 进程带着 XRAY_BROWSER_DIALER, xhttp 出站就交给
    #   浏览器, 而 dialTask() 阻塞在 <-conns 上没有超时。
    if not bd_xhttp_mode_ok(node):
        return False
    probe = node.get("browser_probe") or {}
    if probe.get("ok") is False:
        return False      # 实测不可用 → 只能原生，否则节点永久挂住
    return node.get("use_browser", None) is not False


def check_all_legacy(node: dict) -> dict:
    """旧判定（v1）—— **原逻辑原样保留**，不再作为默认入口。

    保留原因：
      1. compat 的注册表没有覆盖某个组合时会返回 UNKNOWN_CAPABILITY，
         那表示"我们没有数据"，不是"节点不行" —— 此时回退到这里（见 compat2.merge）；
      2. tools/dualkernel-compare.py 用它做双跑对比的基准。
    """
    xray = check_xray(node)
    dialer = check_dialer(node)

    # protocol_may_dialer：**不考虑实测结论**，只看协议/传输层面"是否可能走浏览器转发"。
    # 为什么要单独有这个字段：can_use_dialer 在"实测失败"时也是 false，
    # 但那种节点并不能因此停掉 Chromium —— 进程带着 XRAY_BROWSER_DIALER 时
    # xhttp/websocket 出站仍会被交给浏览器，而 dialTask() 没有超时，会**永久挂住**。
    # 所以"能不能停浏览器"必须看这个字段，而不是 can_use_dialer。
    proto = (node.get("protocol") or "").lower()
    transport = canon_transport(node.get("transport") or "")
    security = (node.get("security") or "none").lower()
    may = (proto == "vless" and transport in DIALER_TRANSPORTS and security != "reality")
    # 把实测结论也带出来，面板/CLI 可以显示"实测可用/失败"而不是只凭推断
    dialer["probe_ok"] = (node.get("browser_probe") or {}).get("ok")
    return {
        "node": node,
        "xray": xray,
        "dialer": dialer,
        "tags": capability_tags(node, xray, dialer),
        # 两种用法互相独立：这里给 UI 直接用
        "can_use_xray": xray["overall"] in (OK, WARN),
        "can_use_dialer": dialer["overall"] in (OK, WARN),
        "protocol_may_dialer": may,
    }


_COMPAT2_CACHE: list = []


def _compat2():
    """惰性载入 compat2（内核维度判定）。取不到就返回 None → 用旧判定。

    默认走 v2；`XBD_COMPAT_ENGINE=legacy` 一键回滚（不改代码）。
    **必须缓存**：节点列表会对每个节点调一次 check_all，不缓存就是每个节点
    重新 exec 一遍适配层（还要重载一次注册表），节点一多就明显卡。
    """
    import importlib.util
    if os.environ.get("XBD_COMPAT_ENGINE", "v2").strip().lower() in (
            "legacy", "v1", "off", "0", "no"):
        return None
    if _COMPAT2_CACHE:
        return _COMPAT2_CACHE[0]
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "compat2.py")
    if not os.path.exists(path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("_xbd_compat2", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _COMPAT2_CACHE.append(mod)
        return mod
    except Exception:
        return None          # 适配层坏了也绝不让节点列表崩掉 —— 退回旧判定


def check_all(node: dict) -> dict:
    """**唯一对外入口**。默认 = compat2（内核维度交给 proxy_node_compat）。

    compat2 只做映射与合并，判定本身发生在 proxy_node_compat 里；
    Browser Dialer 维度仍由本文件的 check_dialer 判定（同一个实现，不重写）。
    """
    v2 = _compat2()
    if v2 is not None:
        try:
            return v2.check_all(node)
        except Exception:
            pass
    return check_all_legacy(node)


def render(result: dict) -> str:
    n = result["node"]
    L = []
    L.append(f"节点名称：{n.get('name') or n.get('address')}")
    L.append("")
    L.append(f"Xray：")
    mark = {"SUPPORTED": "✓ 支持", "SUPPORTED_WITH_WARNING": "✓ 支持（有注意项）",
            "NOT_SUPPORTED": "✗ 不支持", "UNKNOWN": "? 未知"}[result["xray"]["overall"]]
    L.append(f"  {mark}")
    L.append("")
    L.append(f"Browser Dialer：")
    mark = {"SUPPORTED": "✓ 支持", "SUPPORTED_WITH_WARNING": "⚠ 支持（有注意项）",
            "NOT_SUPPORTED": "✗ 不支持", "UNKNOWN": "? 未知"}[result["dialer"]["overall"]]
    L.append(f"  {mark}")
    notes = (result["xray"].get("notes") or []) + (result["dialer"].get("notes") or [])
    if notes:
        L.append("")
        L.append("原因 / 说明：")
        for x in notes:
            L.append(f"  - {x}")
    L.append("")
    L.append("能力标签：" + "  ".join(f"[{t}]" for t in result["tags"]))
    return "\n".join(L)


# ---------------------------------------------------------------------------
SELFTEST_CASES = [
    # (节点, (Xray 普通模式可用, Browser Dialer 可用))
    ({"protocol": "vless", "transport": "xhttp", "security": "tls", "address": "a.example",
      "port": 443, "sni": "a.example", "uuid": "u", "mode": "auto", "encryption": "none"}, (True, True)),
    ({"protocol": "vless", "transport": "tcp", "security": "tls", "address": "b.example",
      "port": 443, "sni": "b.example", "uuid": "u", "encryption": "none"}, (True, False)),
    ({"protocol": "vless", "transport": "xhttp", "security": "reality", "address": "c.example",
      "port": 443, "sni": "c.example", "uuid": "u", "encryption": "none",
      "reality_public_key": "k"}, (True, False)),
    ({"protocol": "trojan", "transport": "tcp", "security": "tls", "address": "d.example",
      "port": 443, "password": "p"}, (True, False)),
    ({"protocol": "shadowsocks", "transport": "tcp", "security": "none", "address": "e.example",
      "port": 8388, "method": "aes-256-gcm", "password": "p"}, (True, False)),
    # hysteria2：Xray 支持（协议名 hysteria / version 2），Browser Dialer 不支持
    ({"protocol": "hysteria2", "transport": "quic", "security": "tls", "address": "f.example",
      "port": 443, "password": "p"}, (True, False)),
    ({"protocol": "vless", "transport": "websocket", "security": "tls", "address": "g.example",
      "port": 443, "sni": "g.example", "path": "/ws", "uuid": "u", "encryption": "none"}, (True, True)),
    # 后量子加密（mlkem768x25519plus）仍可用浏览器拨号，不该被判成不支持
    ({"protocol": "vless", "transport": "websocket", "security": "tls", "address": "pq.example",
      "port": 443, "sni": "pq.example", "path": "/ws", "uuid": "u",
      "encryption": "mlkem768x25519plus.native.0rtt.4CITIGkd1KI2w7oXdwkEzgY64MLHHfuS0CV"}, (True, True)),
    ({"protocol": "vless", "transport": "xhttp", "security": "tls", "address": "1.2.3.4",
      "port": 443, "sni": "h.example", "uuid": "u", "encryption": "none"}, (True, False)),
    ({"protocol": "vless", "transport": "grpc", "security": "tls", "address": "i.example",
      "port": 443, "sni": "i.example", "uuid": "u", "encryption": "none"}, (True, False)),
]


def selftest() -> int:
    print("=== 能力检查自检 ===")
    failed = 0
    for node, (exp_xray, exp_dialer) in SELFTEST_CASES:
        r = check_all(node)
        good = (r["can_use_xray"] == exp_xray) and (r["can_use_dialer"] == exp_dialer)
        failed += 0 if good else 1
        print(f"  [{'PASS' if good else 'FAIL'}] {node['protocol']:<11} {node['transport']:<10} "
              f"{node['security']:<8} {node['address']:<12} "
              f"Xray={r['xray']['overall']:<22} BD={r['dialer']['overall']}")
    print(f"\n自检: {'PASS' if failed == 0 else str(failed) + ' 项失败'}")
    return 1 if failed else 0


def main(argv) -> int:
    if len(argv) > 1 and argv[1] == "selftest":
        return selftest()
    if len(argv) < 3:
        print("用法: compat.py <check|json|render|want-bd> <节点JSON文件|->  [--json]", file=sys.stderr)
        return 2
    cmd = argv[1]
    src = argv[2]
    text = sys.stdin.read() if src == "-" else open(src).read()
    if cmd == "want-bd":
        print("yes" if want_browser_dialer(json.loads(text)) else "no")
        return 0
    if cmd in ("check", "render", "json"):
        node = json.loads(text)
        result = check_all(node)
        if cmd == "render":
            print(render(result))
            return 0 if result["can_use_dialer"] else 1
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if (result["can_use_xray"] or result["can_use_dialer"]) else 1
    print(f"未知命令: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
