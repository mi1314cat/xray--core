#!/usr/bin/env python3
"""compat2 —— `proxy-node-compat` 适配层（**只映射，不判定**）。

设计纪律（与 proxy-node-compat 的 docs/00-design-principles.md 对齐）
------------------------------------------------------------------
1. **判定只发生一次**：内核能力/版本/组合的唯一判定者是 `proxy_node_compat`。
   本文件不写任何"某传输/某协议支不支持"的规则 —— 它只做三件事：
       (a) 把 X 客户端的节点 JSON 映射成 Node Profile（字段 → feature）；
       (b) 把 `check_node()` 的结果翻译成现有 UI 需要的形状；
       (c) 与旧判定（compat.py）做**机械合并**，保证不倒退。
2. **不静默丢字段**：`raw_uri` / `extensions` / `diagnostics` 原样随结果返回；
   节点 JSON 里没有落到任何 feature 的键，一律进 `extensions`。
3. **不猜**：内核版本真探测（`xray version`）；探测不到就把 version 留空，
   让 compat 返回 UNKNOWN —— 不写死版本号。
4. **浏览器拨号（Browser Dialer）不是内核能力**：它由 X 客户端自己的
   `compat.py` 判定（实测探测结果、SNI==host==address、xhttp mode…），
   本层**原样转发**，不改写。

与旧判定的关系
--------------
    merged_xray = 更差者( compat 的内核判定 , 旧 check_xray 的判定 )

    * compat 只能**收紧**，不能放宽 —— "旧说不支持、新说支持"这件事在合并层
      被机械挡住（并把该差异记进 `downgrades`，不是静默处理）。
    * compat 因**没有规则**而 UNKNOWN（reason_codes 含 UNKNOWN_CAPABILITY）时，
      退回旧判定（`fallback=legacy`）—— 那是"我们没数据"，不是"节点不行"，
      不能因此把一个一直能用的节点显示成不可用。
    * 每一次回退/收紧都带 `reason` 与 `rules_applied`，可审计。

用法：
    python3 compat2.py json   <节点JSON文件|->      # 与 compat.py json 同形状 + kernel 段
    python3 compat2.py render <节点JSON文件|->
    python3 compat2.py want-bd <节点JSON文件|->     # 与 compat.py 完全一致（同一个实现）
    python3 compat2.py compare <节点JSON文件|->     # 双跑：旧 vs 新 vs 合并
"""
from __future__ import annotations

import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# 载入同目录的 compat.py（旧判定：Browser Dialer 维度 + 回退基线）与 vendored compat 库
# ---------------------------------------------------------------------------
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import importlib.util  # noqa: E402


def _load_compat_legacy():
    """旧 compat.py —— 只做两件事：Browser Dialer 判定 + 基线判定。不复制它的规则。"""
    path = os.path.join(_HERE, "compat.py")
    spec = importlib.util.spec_from_file_location("_xbd_compat_legacy", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


LEGACY = _load_compat_legacy()

# ★ 必须拿 `check_all_legacy`，**不能**拿 `check_all` —— 后者是分派入口，
#   调它就会再载入一次本模块，形成无限递归（每个节点都重新 exec 一遍适配层）。
_LEGACY_CHECK_ALL = getattr(LEGACY, "check_all_legacy", None)
if _LEGACY_CHECK_ALL is None:                     # pragma: no cover
    raise RuntimeError("compat.py 缺少 check_all_legacy：compat.py 与 compat2.py 版本不匹配")

# 复用旧判定的常量（不重新定义一套状态名）
OK = LEGACY.OK
WARN = LEGACY.WARN
NO = LEGACY.NO
UNKNOWN = LEGACY.UNKNOWN
RANK = LEGACY.VERDICT_RANK          # {OK:3, WARN:2, UNKNOWN:1, NO:0}

STATUS_TO_LEGACY = {
    "SUPPORTED": OK,
    "SUPPORTED_WITH_WARNING": WARN,
    "SUPPORTED_WITH_LOSS": WARN,     # UI 只有四态；有损失属于"支持（有注意项）"
    "UNSUPPORTED": NO,
    "UNKNOWN": UNKNOWN,
}
LABEL = {"SUPPORTED": "✓ 支持", "SUPPORTED_WITH_WARNING": "⚠ 支持（有注意项）",
         "SUPPORTED_WITH_LOSS": "⚠ 支持（会丢能力）", "UNSUPPORTED": "✗ 不支持",
         "UNKNOWN": "? 未知"}

_VENDORED = os.path.join(_HERE, "proxy_node_compat")
_VENDORED_ERROR = None
try:
    from proxy_node_compat import (Target, check_node, parse_uri, Registry,  # noqa: E402
                                   default_registry_path)
    from proxy_node_compat.model import (Field, Feature, NodeProfile, Presence,  # noqa: E402
                                         Provenance)
    from proxy_node_compat.uri import TRANSPORT_MAP, SCHEMES  # noqa: E402
except Exception as exc:                                  # pragma: no cover
    _VENDORED_ERROR = f"{type(exc).__name__}: {exc}"

_VER_CACHE: list = []
_REG_CACHE: list = []


def _registry():
    """注册表只加载一次（61KB JSON，节点列表会逐个节点调用）。"""
    if not _REG_CACHE:
        _REG_CACHE.append(Registry.load(default_registry_path()))
    return _REG_CACHE[0]

# ---------------------------------------------------------------------------
# 1 · 目标（内核 + **真探测**的版本）
# ---------------------------------------------------------------------------
def xray_version_text() -> tuple[str, str]:
    """跑 `xray version`，返回 (版本号, 发行版名)。探测不到返回 ("", "")。

    真探测，不写死。XBD_XRAY_VERSION 只为测试/离线场景预留（默认不生效）。
    """
    forced = os.environ.get("XBD_XRAY_VERSION", "").strip()
    if forced:
        return forced, "xray"
    prefix = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
    bins = [os.path.join(prefix, "bin", "xray"), "xray", "/usr/local/bin/xray"]
    text = ""
    for b in bins:
        if os.path.sep in b and not os.path.exists(b):
            continue
        try:
            import subprocess
            p = subprocess.run([b, "version"], capture_output=True, text=True, timeout=10)
            text = ((p.stdout or "") + (p.stderr or "")).strip()
        except Exception:
            text = ""
        if text:
            break
    if not text:
        return "", ""
    first = text.splitlines()[0]
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", first)
    name = (first.split(" ", 1)[0] or "").strip().lower()
    return (m.group(0) if m else ""), name


def xray_target() -> "Target":
    """声明本客户端的内核事实。版本真探测；探测不到就留空 → compat 判 UNKNOWN（不猜）。"""
    if _VER_CACHE:
        return _VER_CACHE[0]
    ver, name = xray_version_text()
    # 发行版：官方二进制首词是 Xray；别的名字（fork）不继承上游，交给 compat 判 UNKNOWN。
    dist = None if (not name or name == "xray") else name
    t = Target(
        kernel="xray",
        distribution=dist,
        version=ver or None,
        build_tags=None,        # 未探测（None = 未知，不是"空"）→ 相关规则判 UNKNOWN
        platform=None,
        runtime_options=runtime_options(),
    )
    _VER_CACHE.append(t)
    return t


def runtime_options() -> dict:
    """本客户端**运行期会做什么**的事实（不是能力判断，是"我们会怎么写配置"）。

    `mux_cool`：`lib/genconfig.py` 现在**默认不开** mux.cool，判据是
    `mux_decision()` 三层：① 命令行 `--mux/--no-mux` ② 节点 JSON 的 `mux` 字段
    ③ 默认关。XHTTP/QUIC 传输下即使显式要求也会被拒（官方明确不建议）。
    这里只能给出"全局默认值"这一个事实；**单个节点**的实际形态由
    `_augment()` 按 `mux_decision` 的同一套判据算（`effective_mux`）。
    `XBD_GEN_MUX=1` 留给"这次全都要开"的场景，语义与 `--mux` 一致。
    """
    mux = os.environ.get("XBD_GEN_MUX")
    if mux is None:
        mux = "0"                       # genconfig.py: 不给 --mux 时默认不开
    return {"mux_cool": mux.strip() not in ("", "0", "false", "no")}


# 与 lib/genconfig.py 的 MUX_FORBIDDEN_* 同一套判据。
#
# ★ 为什么这里要抄一份：compat2 是要能独立跑的适配层（面板、CC 上的
#   `compat2.py json <节点>` 都不带 genconfig 的依赖），import genconfig 会把
#   ports/addr 那一串也拖进来。抄一份就必须**锁死**：check_libs.sh 里有一条
#   门禁逐项比对这两处的键集合，漂移了会红 —— 不然"判据漂移"正是最难查的 bug。
_MUX_FORBIDDEN_TRANSPORTS = ("xhttp", "quic", "mkcp")
_MUX_FORBIDDEN_PROTOCOLS = ("hysteria2",)


def effective_mux(node: dict, cli_mux=None) -> tuple:
    """客户端**实际**会不会给这个节点开 mux.cool，返回 (enabled, 原因)。

    与 genconfig.mux_decision 同判据：显式关闭 > 显式开启 > 节点 mux 字段 > 默认关；
    XHTTP/QUIC 一律拒绝。
    命令行那层的"显式"在适配层里对应环境变量 `XBD_GEN_MUX`（与 runtime_options 同一个）。
    """
    if cli_mux is None:
        env = os.environ.get("XBD_GEN_MUX")
        if env is not None:
            cli_mux = env.strip() not in ("", "0", "false", "no")
    n_mux = node.get("mux")
    if isinstance(n_mux, dict):
        n_mux = n_mux.get("enabled")
    declared = bool(n_mux)
    if cli_mux is False:
        return False, "--no-mux（或 XBD_GEN_MUX=0）显式关闭"
    if cli_mux is True:
        want, src = True, "--mux（或 XBD_GEN_MUX=1）"
    elif declared:
        want, src = True, "节点 mux 字段"
    else:
        return False, "默认不开（没有 --mux，节点也没声明）"
    transport = str(node.get("transport") or "").lower()
    proto = str(node.get("protocol") or "").lower()
    if transport in _MUX_FORBIDDEN_TRANSPORTS or proto in _MUX_FORBIDDEN_PROTOCOLS:
        return False, f"{transport or proto} 传输下被拒绝（官方不建议 mux.cool 与 XHTTP/QUIC 同开）"
    return True, f"按 {src} 开启"


# ---------------------------------------------------------------------------
# 2 · 节点 JSON → Node Profile（字段 → feature 映射）
# ---------------------------------------------------------------------------
_PROTO_ID = {
    "vless": "standard:vless", "vmess": "standard:vmess", "trojan": "standard:trojan",
    "shadowsocks": "standard:shadowsocks", "ss": "standard:shadowsocks",
    "hysteria2": "standard:hysteria2", "hy2": "standard:hysteria2",
    "tuic": "standard:tuic", "anytls": "standard:anytls",
    "socks": "standard:socks", "socks5": "standard:socks", "http": "standard:http",
    "https": "standard:http",
}
# 这些协议自带 TLS（QUIC/TLS 是协议的一部分），即使 security 空 —— 与 uri.py 一致
_TLS_IMPLICIT = {"standard:trojan", "standard:hysteria2", "standard:tuic", "standard:anytls"}
_SECURITY_FEATURE = {"tls": "standard:tls", "reality": "standard:reality"}
_SECURITY_KNOWN = ("", "none", "tls", "reality")

# 已经映射过的节点键（其余键一律进 extensions，禁止静默丢）
_MAPPED_KEYS = {
    "name", "protocol", "transport", "transport_raw", "security", "address", "port",
    "uuid", "password", "method", "username", "encryption", "flow", "sni", "alpn",
    "fingerprint", "allow_insecure", "path", "host", "mode", "extra", "service_name",
    "header_type", "reality_public_key", "reality_short_id", "reality_spider_x",
    "ech", "pinned_cert_sha256", "mux",
}
_PRESENCE_FLATTENED = ("source", "raw", "raw_params", "browser_probe",
                       "group", "use_browser", "ws_ed", "udp")


def _prov(node: dict) -> "Provenance":
    src = (node.get("source") or "").lower()
    if src.endswith("-uri"):
        return Provenance.URI
    if "mihomo" in src or "yaml" in src or "clash" in src:
        return Provenance.MIHOMO_YAML
    if "xray" in src or "json" in src:
        return Provenance.XRAY_JSON
    return Provenance.USER_DEFINED


def _is_uri_source(node: dict) -> bool:
    raw = (node.get("raw") or "").strip()
    return ((node.get("source") or "").endswith("-uri")
            and bool(raw) and "://" in raw.split("\n")[0])


def _fmt(node: dict) -> str:
    """source_format 字符串（NodeProfile.source_format 用；URI 之外的按来源如实标注）。"""
    return {"URI": "URI", "MIHOMO_YAML": "MIHOMO_YAML", "XRAY_JSON": "XRAY_JSON",
            "USER_DEFINED": "MANUAL", "SUBSCRIPTION": "SUBSCRIPTION",
            "EXTENSION": "MANUAL"}.get(_prov(node).value, "MANUAL")


def _str(node: dict, key: str) -> str:
    v = node.get(key)
    return "" if v is None else str(v).strip()


def profile_of(node: dict) -> "NodeProfile":
    """节点 JSON → Node Profile。URI 来源走 parse_uri（保真最高）；其余走字段映射。"""
    if _VENDORED_ERROR:
        raise RuntimeError(f"vendored proxy_node_compat 不可用: {_VENDORED_ERROR}")
    if _is_uri_source(node):
        raw = (node.get("raw") or "").strip()
        prof = parse_uri(raw)
        # 客户端自己的收尾（自动 pin 指纹等）产生的字段补进 profile，
        # 但不覆盖链接里已经写明的值（provenance 优先 URI）。
        _augment(prof, node, override=False)
        return prof
    prof = _profile_from_dict(node)
    _augment(prof, node, override=True)
    return prof


def _profile_from_dict(node: dict) -> "NodeProfile":
    prov = _prov(node)
    proto = _str(node, "protocol").lower()
    prof = NodeProfile(source_format=_fmt(node))
    prof.raw_fields = dict(node)        # I1：原文（归一化后的节点 JSON）逐键保留

    pid = _PROTO_ID.get(proto)
    if pid is None:
        pid = f"unknown:{proto or 'noproto'}"
        prof.diagnostics.append({"code": "UNKNOWN_PROTOCOL",
                                 "detail": f"未收录的协议: {proto!r}"})
    prof.protocol = Feature(id=pid, presence=Presence.EXPLICIT, provenance=prov)

    addr = _str(node, "address")
    if addr:
        prof.endpoint["host"] = Field.explicit(addr, prov, "address")
    if node.get("port"):
        prof.endpoint["port"] = Field.explicit(node["port"], prov, "port")

    # --- 传输（hysteria2 的传输是协议自带的，与 uri.py 的 hysteria2 scheme 保持一致不建 feature）
    tname = LEGACY.canon_transport(_str(node, "transport") or _str(node, "transport_raw"))
    transport_feat = None
    if tname and pid != "standard:hysteria2":
        tid = TRANSPORT_MAP.get(tname)
        if tid is None:
            prof.add_feature(Feature(id=f"unknown:transport.{tname}",
                                     presence=Presence.EXPLICIT, provenance=prov,
                                     note=f"未收录的传输方式 transport={tname}"))
            prof.add_extension("transport", node.get("transport"), _fmt(node),
                               "未知传输方式，原样保留")
        else:
            transport_feat = Feature(id=tid, presence=Presence.EXPLICIT, provenance=prov)
            prof.add_feature(transport_feat)
    elif tname:
        prof.add_extension("transport", node.get("transport"), _fmt(node),
                           "hysteria2 的传输由协议自带（QUIC），不单独建 feature")

    # --- 安全层
    sec = _str(node, "security").lower()
    if sec in _SECURITY_FEATURE:
        prof.add_feature(Feature(id=_SECURITY_FEATURE[sec], presence=Presence.EXPLICIT,
                                 provenance=prov))
    elif sec in ("", "none"):
        if pid in _TLS_IMPLICIT:
            prof.add_feature(Feature(id="standard:tls", presence=Presence.DEFAULTED,
                                     provenance=Provenance.INFERRED,
                                     note=f"{pid} 默认走 TLS（与 uri.py 的解析保持一致）"))
    else:
        # 未收录的 security 取值（例如已被 26.x 移除的 xtls）：
        # 不能静默吃掉 —— 登记成 unknown: feature，交由 compat 判 UNKNOWN，
        # 而不是让节点看起来"支持"。
        prof.add_feature(Feature(id=f"unknown:security.{sec}", presence=Presence.EXPLICIT,
                                 provenance=prov,
                                 note=f"未收录的传输安全取值 security={sec}"))
        prof.add_extension("security", node.get("security"), _fmt(node),
                           "未收录的 security 取值，原样保留")

    if node.get("allow_insecure"):
        prof.add_feature(Feature(id="standard:tls.allow_insecure", presence=Presence.EXPLICIT,
                                 provenance=prov))
    if node.get("ech"):
        prof.add_feature(Feature(id="standard:ech", presence=Presence.EXPLICIT,
                                 provenance=prov))
    flow = _str(node, "flow")
    if flow:
        prof.add_feature(Feature(id="standard:flow", presence=Presence.EXPLICIT,
                                 provenance=prov))
    enc = _str(node, "encryption")
    if pid == "standard:vless" and enc and enc.lower() != "none":
        prof.add_feature(Feature(id="standard:vless.encryption", presence=Presence.EXPLICIT,
                                 provenance=prov,
                                 params={"encryption": Field.explicit(enc, prov, "encryption")},
                                 note="VLESS encryption（含 mlkem768x25519plus 后量子方案）；值原样保存"))
    elif enc and enc.lower() != "none":
        prof.add_extension("encryption", node.get("encryption"), _fmt(node),
                           "非 vless 协议的 encryption 字段，原样保留")

    # --- REALITY / TLS 参数
    reality = prof.get_feature("standard:reality")
    pbk = _str(node, "reality_public_key")
    if pbk and reality is None:
        reality = Feature(id="standard:reality", presence=Presence.INFERRED, provenance=prov,
                          note="由 reality_public_key 反推（与 uri.py 的 pbk 归属一致）")
        prof.add_feature(reality)
    if reality is not None:
        for key, pk in (("reality_public_key", "pbk"), ("reality_short_id", "sid"),
                        ("reality_spider_x", "spx")):
            v = _str(node, key)
            if v:
                reality.params[pk] = Field.explicit(v, prov, key)
    # sni/fp 在 reality 节点上属于 REALITY 的握手身份（uri.py 的 _REALITY_IDENTITY 同规则）
    identity_owner = reality if (sec == "reality" or prof.get_feature("standard:tls") is None) \
        else prof.get_feature("standard:tls")
    for key, pk in (("sni", "server_name"), ("alpn", "alpn"), ("fingerprint", "fingerprint"),
                    ("pinned_cert_sha256", "pinned_peer_cert_sha256")):
        v = _str(node, key)
        if not v:
            continue
        owner = identity_owner
        if key in ("alpn", "pinned_cert_sha256") and prof.get_feature("standard:tls") is not None:
            owner = prof.get_feature("standard:tls")
        if owner is None:
            prof.add_extension(key, node.get(key), _fmt(node), "无对应 feature，原样保留")
        else:
            owner.params[pk] = Field.explicit(v, prov, key)

    # --- 传输专属参数挂到传输 feature 上
    if transport_feat is not None:
        for key, pk in (("path", "path"), ("host", "host"), ("mode", "mode"),
                        ("extra", "extra"), ("service_name", "service_name"),
                        ("header_type", "headerType")):
            v = _str(node, key)
            if v:
                transport_feat.params[pk] = Field.explicit(v, prov, key)

    # --- 认证
    for key, ak in (("uuid", "uuid"), ("password", "password"), ("method", "method"),
                    ("username", "username")):
        v = _str(node, key)
        if v:
            prof.auth[ak] = Field.explicit(v, prov, key)
    return prof


def _augment(prof: "NodeProfile", node: dict, override: bool) -> None:
    """把节点 JSON 里 compat 解析不到、但会影响"实际怎么跑"的事实补进 profile。

    三条，都是**客户端事实**，不是能力判断：
      · mux.cool —— 现在只有"节点声明了 + 传输允许"才会真的写进配置；
        声明了但传输不允许（XHTTP/QUIC）时 genconfig 会**拒绝**并在 stderr 说明，
        这时 compat 必须报告"实际形态里没有 mux"，否则它对 XHTTP 节点给出的
        运行期结论（`xray.combo.xhttp_muxcool` 判 runtime_fail）比现实更悲观。
      · 未收录的 security 取值（parse_uri 会把 security 当已消费键、静默不建模）。
    """
    # (a) mux
    on, why = effective_mux(node)
    if on:
        if prof.get_feature("standard:mux") is None:
            prof.add_feature(Feature(
                id="standard:mux",
                presence=Presence.EXPLICIT if node.get("mux") else Presence.INFERRED,
                provenance=_prov(node) if node.get("mux") else Provenance.INFERRED,
                note=f"客户端会开 mux.cool（{why}）"))
        if not node.get("mux"):
            prof.diagnostics.append({
                "code": "RUNTIME_IMPLIED_MUX",
                "detail": f"节点自己没写 mux，但客户端运行期会开（{why}）—— "
                          "它来自客户端，不是链接"})
    elif node.get("mux"):
        # 节点要求了、客户端拒绝 —— 必须说话。改动前这里的形态是"节点写了也照开"
        # （XHTTP 上必坏），改后是"拒绝"，两个结论差别就在运行期成不成。
        prof.diagnostics.append({
            "code": "MUX_REQUEST_DECLINED",
            "detail": f"节点声明了 mux，但客户端不会写进配置：{why}"})
    # (b) 未收录的 security 取值
    sec = _str(node, "security").lower()
    if sec not in _SECURITY_KNOWN and prof.get_feature(f"unknown:security.{sec}") is None:
        prof.add_feature(Feature(id=f"unknown:security.{sec}", presence=Presence.EXPLICIT,
                                 provenance=_prov(node),
                                 note=f"未收录的传输安全取值 security={sec}"))
    # (c) 其余没落到任何 feature 的节点键 → extensions（禁止静默丢字段）
    in_features = {f.id for f in prof.features} | ({prof.protocol.id} if prof.protocol else set())
    for key, val in node.items():
        if key in _MAPPED_KEYS or key in _PRESENCE_FLATTENED:
            continue
        if val in (None, "", [], {}, 0, False):
            continue
        prof.add_extension(key, val, _fmt(node), "未被 compat 模型覆盖的节点字段")
    prof.diagnostics.append({
        "code": "CLIENT_RUNTIME_FACTS",
        "detail": f"runtime_options={runtime_options()} features={sorted(in_features)}"})


# ---------------------------------------------------------------------------
# 3 · 判定（唯一判定点：proxy_node_compat）
# ---------------------------------------------------------------------------
def check_kernel(node: dict, target=None) -> dict:
    """节点 JSON → compat 的内核判定（结构化，含 raw_uri / extensions）。"""
    if _VENDORED_ERROR:
        return {"ok": False, "error": _VENDORED_ERROR, "status": "UNKNOWN",
                "legacy": UNKNOWN, "raw_uri": None, "extensions": []}
    tgt = target or xray_target()
    try:
        prof = profile_of(node)
        res = check_node(prof, tgt, _registry())
    except Exception as exc:                     # 适配层绝不把 UI 弄崩
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}", "status": "UNKNOWN",
                "legacy": UNKNOWN, "raw_uri": None, "extensions": []}
    d = res.to_dict()
    d["ok"] = True
    d["legacy"] = STATUS_TO_LEGACY.get(res.status, UNKNOWN)
    d["target"] = tgt.to_dict()
    d["raw_uri"] = res.raw_uri                  # 原样保留
    d["extensions"] = list(prof.extensions)     # 原样保留
    d["diagnostics"] = list(prof.diagnostics)
    d["detected_features"] = d.get("detected_features") or []
    d["source_format"] = prof.source_format
    return d


# ---------------------------------------------------------------------------
# 4 · 机械合并（新 vs 旧）
# ---------------------------------------------------------------------------
# compat 的"层级 X 没有任何证据覆盖"是**注册表覆盖度**的元信息，不是这个节点的
# 结论；面板/卡片上列出来只会淹掉真正有用的那几句。原始数据仍在 kernel.unknowns 里。
_META_UNKNOWN_PREFIX = ("层级 ",)


def _notes_from_kernel(k: dict) -> list[str]:
    out = []
    diags = {d.get("code") for d in (k.get("diagnostics") or [])}
    if "RUNTIME_IMPLIED_MUX" in diags and any(
            "mux" in str(ls.get("feature", "")) for ls in (k.get("losses") or [])):
        out.append("⚠ 关于 mux：这个节点的 mux.cool 不是链接里写的 —— "
                   "是客户端按 `--mux`（或 XBD_GEN_MUX=1）显式开出来的。"
                   "下面 compat 对 mux 的结论针对的就是这个运行期行为。")
    if "MUX_REQUEST_DECLINED" in diags:
        out.append("ℹ 关于 mux：链接/节点里声明了 mux.cool，但客户端**不会**写进配置 —— "
                   "XHTTP/QUIC 传输下官方不建议与 mux.cool 同开（实测开了必连不上），"
                   "所以按传输类型拒了。"
                   "下面 compat 判的是「链接声明了什么」，不是你实际跑成什么样。")
    for ls in k.get("losses") or []:
        out.append(f"🟠 会丢能力：{ls.get('feature')} —— {ls.get('what')}"
                   f"（规则 {ls.get('rule')}）")
    for wn in k.get("warnings") or []:
        out.append(f"🟡 {wn.get('code')}：{wn.get('detail')}")
    for un in k.get("unknowns") or []:
        if str(un.get("what", "")).startswith(_META_UNKNOWN_PREFIX):
            continue                       # 元信息噪音，不进 UI
        out.append(f"❓ 未知：{un.get('what')} —— {un.get('why')}")
    if k.get("failure_mode"):
        out.append(f"内核失败模式：{k['failure_mode']}"
                   + (f"（{'/'.join(k.get('reason_codes') or [])}）"
                      if k.get("reason_codes") else ""))
    for ev in (k.get("evidence") or [])[:2]:
        out.append(f"证据：[{ev.get('type')}/{ev.get('confidence')}] {ev.get('claim')}"
                   f" ↳ {ev.get('where')}")
    seen, uniq = set(), []
    for x in out:                      # 同一条损失会被多条规则重复报，去重后再给 UI
        if x not in seen:
            seen.add(x)
            uniq.append(x)
    return uniq


def _definite_status(kernel: dict):
    """compat 总状态是 UNKNOWN 时，它是否仍给出了**确定**的结论？

    只读 compat 自己的输出字段，不引入任何能力知识：
      · 某一层被判 UNSUPPORTED            → 确定"不支持"
      · losses 非空                        → 确定"会丢能力"（compat 对 SUPPORTED_WITH_LOSS 的定义）
      · failure_mode=hard_error            → 确定"配置期就起不来"
    没有确定结论就返回 None → 交给旧判定。
    """
    lv = kernel.get("levels") or {}
    if any(v == "UNSUPPORTED" for v in lv.values()):
        return NO
    if kernel.get("losses"):
        return WARN
    if kernel.get("failure_mode") == "hard_error":
        return NO
    return None


def merge(node: dict, legacy: dict, kernel: dict) -> dict:
    """把 compat 的内核判定与旧判定合并成现有 UI 的形状。

    合并规则（是**策略**，不是能力判断）：
      1. compat 判 UNKNOWN 且**没有任何确定结论** → 退回旧判定。
         UNKNOWN 的含义是"我们没依据"，不是"不能用" —— 拿它去推翻客户端手里
         已有的依据（源码级读出来的那些）会让 XHTTP+ECH 这类节点凭空变成
         "未知→不可用"，那是退步。
      2. compat 判 UNKNOWN 但**有确定结论**（某层 UNSUPPORTED / 有 losses /
         hard_error）→ 用那个确定结论（例如 XHTTP+mux.cool 的运行期失败）。
      3. 其余情况取两者中更差的一个 —— compat 只能收紧，不能放宽。
    """
    lx = legacy.get("xray") or {}
    lo = lx.get("overall", UNKNOWN)
    reasons = list(kernel.get("reason_codes") or [])
    fallback = None

    if not kernel.get("ok"):
        ko, verdict_src = UNKNOWN, "compat 不可用"
    elif kernel.get("status") == "UNKNOWN":
        definite = _definite_status(kernel)
        if definite is None:
            ko, verdict_src = STATUS_TO_LEGACY[UNKNOWN], "legacy（compat 判 UNKNOWN）"
            fallback = "legacy:compat-unknown"
        else:
            ko = definite
            verdict_src = "compat（总状态 UNKNOWN，但该结论是确定的）"
    else:
        ko = STATUS_TO_LEGACY.get(kernel.get("status"), UNKNOWN)
        verdict_src = "compat"

    if fallback:
        merged_overall = lo
    else:
        merged_overall = ko if RANK[ko] <= RANK[lo] else lo
    downgrades = []
    if RANK[ko] < RANK[lo] and not fallback:
        downgrades.append({"from": lo, "to": ko,
                           "why": "compat 比旧判定更严（收紧，不是放宽）",
                           "reason_codes": reasons, "rules": kernel.get("rules_applied")})
    # 融合说明：旧判定的原因文案 + compat 的损失/警告/未知（回退时也照样带上，
    # 回退不等于把 compat 看到的东西丢掉）
    notes = _notes_from_kernel(kernel) + list(lx.get("notes") or [])
    if fallback:
        notes.insert(0, "内核判定沿用旧判定：compat 判 UNKNOWN"
                        f"（{','.join(reasons) or '无原因码'}）—— 那是「我们没有依据」，"
                        "不是「节点不行」。compat 看到的东西在下面照常列出。")
    if kernel.get("ok") and not kernel.get("rules_applied"):
        notes.append("compat 未匹配到任何规则（rules_applied 为空）。")
    checks = [{"item": "内核兼容性", "verdict": merged_overall,
               "detail": f"{kernel.get('status', '?')} / {verdict_src}"
                         + (f" / {','.join(reasons)}" if reasons else "")}]
    checks.extend(c for c in (lx.get("checks") or []) if c.get("item") != "内核兼容性")
    xray = {"overall": merged_overall, "checks": checks, "notes": notes}

    out = dict(legacy)
    out["node"] = node
    out["xray"] = xray
    out["dialer"] = legacy.get("dialer") or {}       # 浏览器拨号：旧判定，原样
    out["kernel"] = kernel                            # compat 全量结果（含 raw_uri/extensions）
    out["engine"] = {"kernel": "proxy-node-compat", "dialer": "compat.py",
                     "engine_version": _vendor_version(),
                     "verdict_source": verdict_src, "fallback": fallback}
    out["downgrades"] = downgrades
    out["can_use_xray"] = merged_overall in (OK, WARN)
    out["can_use_dialer"] = legacy.get("can_use_dialer", False)
    out["protocol_may_dialer"] = legacy.get("protocol_may_dialer", False)
    out["tags"] = LEGACY.capability_tags(node, xray, out["dialer"])
    return out


def _vendor_version() -> str:
    try:
        import proxy_node_compat as p
        return getattr(p, "__version__", "?")
    except Exception:
        return "?"


# ---------------------------------------------------------------------------
# 5 · 对外入口（与 compat.py 同形状）
# ---------------------------------------------------------------------------
def check_all(node: dict) -> dict:
    legacy = _LEGACY_CHECK_ALL(node)         # 旧判定：Dialer 维度 + 回退基线（原样复用）
    kernel = check_kernel(node)
    try:
        return merge(node, legacy, kernel)
    except Exception:                        # 合并出问题也绝不让 UI 崩
        legacy["engine"] = {"kernel": "compat.py (merge failed)", "dialer": "compat.py"}
        return legacy


def kernel_report(node: dict) -> str:
    k = check_kernel(node)
    if not k.get("ok"):
        return f"compat 不可用: {k.get('error')}"
    L = [f"{LABEL.get(k['status'], k['status'])}  [{node.get('name') or '?'}]",
         f"  目标: {k['target'].get('kernel')} {k['target'].get('version') or '(版本未探测到)'}",
         "  分层: " + "  ".join(f"{lv}={k['levels'][lv]}"
                               for lv in ("parse", "config", "uri", "runtime", "semantic")),
         "  规则: " + (", ".join(k.get("rules_applied") or []) or "（无）")]
    if k.get("raw_uri"):
        L.append(f"  原始链接: {k['raw_uri']}")
    if k.get("extensions"):
        L.append(f"  未建模字段(extensions): {len(k['extensions'])} 项 —— "
                 + ", ".join(str(e.get("key")) for e in k["extensions"][:8]))
    L.extend("  " + n for n in _notes_from_kernel(k))
    return "\n".join(L)


def render(result: dict) -> str:
    n = result["node"]
    L = [f"节点名称：{n.get('name') or n.get('address')}", ""]
    L.append("Xray：")
    L.append(f"  {LABEL.get(result['xray']['overall'], result['xray']['overall'])}")
    L.append(f"  （判定来源：{(result.get('engine') or {}).get('verdict_source', '?')}"
             f"；内核 compat={(result.get('kernel') or {}).get('status', '?')}）")
    L.append("")
    L.append("Browser Dialer：")
    mark = {OK: "✓ 支持", WARN: "⚠ 支持（有注意项）", NO: "✗ 不支持", UNKNOWN: "? 未知"}
    L.append(f"  {mark.get(result['dialer'].get('overall'), '?')}")
    notes = (result["xray"].get("notes") or []) + (result["dialer"].get("notes") or [])
    if notes:
        L.append("")
        L.append("原因 / 说明：")
        L.extend(f"  - {x}" for x in notes)
    L.append("")
    L.append("能力标签：" + "  ".join(f"[{t}]" for t in result["tags"]))
    return "\n".join(L)


def compare(node: dict, target=None) -> dict:
    """双跑：旧判定 / 新判定 / 合并结果。差异全部显式列出。"""
    legacy = _LEGACY_CHECK_ALL(node)
    kernel = check_kernel(node, target)
    merged = merge(node, legacy, kernel)
    lo = (legacy.get("xray") or {}).get("overall", UNKNOWN)
    ko = kernel.get("legacy", UNKNOWN)
    return {
        "name": node.get("name"), "protocol": node.get("protocol"),
        "transport": node.get("transport"), "security": node.get("security"),
        "legacy": lo, "compat": kernel.get("status"), "compat_legacy": ko,
        "merged": merged["xray"]["overall"], "verdict_source": merged["engine"]["verdict_source"],
        "fallback": merged["engine"]["fallback"],
        "reason_codes": kernel.get("reason_codes") or [],
        "rules_applied": kernel.get("rules_applied") or [],
        "losses": [ls.get("feature") for ls in (kernel.get("losses") or [])],
        "dialer_legacy": (legacy.get("dialer") or {}).get("overall"),
        "dialer_merged": merged["dialer"].get("overall"),
        "can_use_xray_legacy": legacy.get("can_use_xray"),
        "can_use_xray": merged["can_use_xray"],
        "raw_uri": kernel.get("raw_uri"),
        "extensions": [e.get("key") for e in (kernel.get("extensions") or [])],
    }


def main(argv) -> int:
    src = None
    if len(argv) > 2:
        src = argv[2]
    text = ""
    if src == "-":
        text = sys.stdin.read()
    elif src:
        text = open(src, encoding="utf-8").read()

    if len(argv) > 1 and argv[1] == "selftest":
        return selftest()
    if len(argv) > 1 and argv[1] == "version":
        print(json.dumps({"target": xray_target().to_dict(),
                          "vendored": _vendor_version(), "error": _VENDORED_ERROR},
                         ensure_ascii=False))
        return 0
    if len(argv) < 3:
        print("用法: compat2.py <check|json|render|want-bd|compare|version|selftest> "
              "<节点JSON文件|->", file=sys.stderr)
        return 2
    node = json.loads(text)
    cmd = argv[1]
    if cmd == "want-bd":
        # 与 compat.py 是同一个实现，不做二次判断
        print("yes" if LEGACY.want_browser_dialer(node) else "no")
        return 0
    if cmd == "compare":
        print(json.dumps(compare(node), ensure_ascii=False))
        return 0
    result = check_all(node)
    if cmd == "render":
        print(render(result))
        return 0 if result["can_use_dialer"] else 1
    if cmd == "kernel":
        print(kernel_report(node))
        return 0 if result["can_use_xray"] else 1
    if cmd in ("check", "json"):
        if cmd == "check":
            print(render(result))
        else:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if (result["can_use_xray"] or result["can_use_dialer"]) else 1
    print(f"未知命令: {cmd}", file=sys.stderr)
    return 2


# ---------------------------------------------------------------------------
def selftest() -> int:
    """适配层自检：只验"映射与合并"，不重新判定能力（能力判定由 compat 单测覆盖）。"""
    print("=== compat2 适配层自检 ===")
    bad = 0

    def ck(label, got, want):
        nonlocal bad
        okk = got == want
        bad += 0 if okk else 1
        print(f"  [{'PASS' if okk else 'FAIL'}] {label}" + ("" if okk else f"  期望 {want!r} 实际 {got!r}"))

    ck("内核版本真探测到", bool(xray_version_text()[0]) or os.environ.get("XBD_XRAY_VERSION") is not None, True)
    t = xray_target()
    ck("Target.kernel=xray", t.kernel, "xray")

    # 旧判定里"不支持"的，合并后绝不允许变成支持（单调保险丝）
    cases = [
        ({"protocol": "vless", "transport": "magic", "security": "tls", "address": "a.example",
          "port": 443, "uuid": "u"}, False),
        ({"protocol": "vless", "transport": "tcp", "security": "xtls", "address": "a.example",
          "port": 443, "uuid": "u"}, False),
        ({"protocol": "vless", "transport": "tcp", "security": "tls", "address": "a.example",
          "port": 443, "uuid": "u", "fingerprint": "not-a-real-fp"}, False),
        ({"protocol": "vless", "transport": "tcp", "security": "tls", "address": "a.example",
          "port": 443}, False),
        ({"protocol": "socks", "transport": "", "security": "none", "address": "127.0.0.1",
          "port": 1080}, True),
        ({"protocol": "hysteria2", "transport": "quic", "security": "none",
          "address": "h.example", "port": 443, "password": "p"}, True),
    ]
    for n, want in cases:
        n.setdefault("name", "t")
        r = check_all(n)
        ck(f"can_use_xray({n['protocol']}/{n['transport'] or '-'}/{n['security']})",
           bool(r["can_use_xray"]), want)

    # 不静默丢字段：extensions / raw_uri 必须随结果返回
    n = {"name": "ext", "protocol": "vless", "transport": "tcp", "security": "tls",
         "address": "a.example", "port": 443, "uuid": "u", "evilField": "1", "mux": False}
    r = check_all(n)
    ck("extensions 随结果返回", "evilField" in [e.get("key") for e in r["kernel"]["extensions"]], True)
    ck("raw_uri 键存在", "raw_uri" in r["kernel"], True)

    # parse_uri 路径：原始链接必须原样带出
    uri = "vless://u@a.example:443?type=tcp&security=tls#n1"
    r2 = check_all({"name": "u", "source": "vless-uri", "raw": uri, "protocol": "vless",
                    "transport": "tcp", "security": "tls", "address": "a.example", "port": 443})
    ck("URI 来源保留原始链接", r2["kernel"]["raw_uri"], uri)
    print(f"\n自检: {'PASS' if bad == 0 else str(bad) + ' 项失败'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
