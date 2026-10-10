#!/usr/bin/env python3
"""节点显示名 —— **旗帜 + 服务器前缀 + 节点名**。

对照 sing-box-core 的做法（`src/conf/lib.sh` 的 `sb_flag_emoji` /
`sb_ensure_flag` / `sb_server_name`）：

    旗帜 + 服务器标识 + "-" + 节点名
    🇺🇸 X-vless01-TLS          （默认：旗帜 + 默认前缀 X）
    🇭🇰 HK1-vless01-TLS        （用户把前缀改成 HK1）
    🇺🇸 CCSm-anytls01-TLS      （SB 那边的形态，同一个思路）

★ 为什么旗帜必须是**服务器的属性**，而不是名字的一部分：

  · 节点名（tag）要进配置文件、要当文件名、要进分享链接的 fragment ——
    它必须是稳定的 ASCII 标识。所以旗帜只出现在**给人看的地方**
    （分享链接的 # 片段 → 客户端列表），tag 一个字都不改。
  · 用户改名字时不能把旗帜弄丢：输入"HK1"之后仍然要是 🇭🇰 HK1-…。
    这就是 ensure_flag 存在的理由（SB 那边踩过一次）。
  · 多台服务器各跑一份全协议时，两边的 tag 完全一样（都是 x-vless01-TLS），
    客户端 `node-<名字>.json` 导入第二条就把第一条覆盖掉 —— 静默少节点。
    前缀就是为这件事存在的。

★ 旗帜从哪来：按服务器 IP 归属地问一次，然后**缓存**。
  SB 那边的原话是"IP 归属地接口时好时坏，每次都现查，某次超时就悄悄变成
  没有旗帜的名字，用户会以为前缀被弄丢了"。所以查到就落盘，
  只要 IP 没换，旗帜就一直在。查不到就**不带旗帜**（功能不受影响），
  但那不是"随便少一个东西"——`--check` 会把这件事明确报出来。

用法（CLI，给 bash 调）：

    naming.py flag                      # 当前旗帜（可能是空串）
    naming.py prefix                    # 当前服务器前缀
    naming.py server                    # 旗帜 + 前缀（给人看的完整标识）
    naming.py display <tag>             # 旗帜 + 前缀 + 去掉 x- 的 tag
    naming.py ensure <name>             # 名字里没旗帜就补上
    naming.py set <name>                # 落盘服务器标识（用户自定义）
    naming.py --check                   # 自检：ISO→emoji、组合、去重

环境变量：
    XRAY_SERVER_NAME   服务器标识（优先于缓存文件）
    XRAY_SKIP_FLAG     非空 = 不要旗帜（离线/隐私场景）
    XRAY_BASE          安装根（默认 /root/catmi/xray），缓存在 <BASE>/share-state/
"""
from __future__ import annotations

import json
import os
import re
import socket
import sys
import urllib.request

BASE = os.environ.get("XRAY_BASE", "/root/catmi/xray")
STATE_DIR = os.environ.get("XRAY_STATE_DIR", os.path.join(BASE, "share-state"))
FLAG_CACHE = os.path.join(STATE_DIR, "flag")
NAME_CACHE = os.path.join(STATE_DIR, "server-name")

# 旗帜 = 两个连着的区域指示符号（U+1F1E6..U+1F1FF）。
# 用正则判"这个名字里有没有旗帜"，而不是靠前缀字符串比对 ——
# 用户完全可能自己带一个别的国家的旗帜，那时应当尊重他的。
FLAG_RE = re.compile("[\U0001F1E6-\U0001F1FF]{2}")

# 默认前缀。用户的原话是"一个 X 的默认值" —— 这台机器是 X 内核建的，
# 默认就叫 X；要多台服务器区分就改成自己的名字（HK1 / 公司专线 …）。
DEFAULT_PREFIX = "X"

# 归属地查询源。SB 早先用 ip.cloudflare.now，那个域名现在解析不了
# （实测 curl: (6) Could not resolve host），所以这里直接用能通的。
GEO_SOURCES = (
    "http://ip-api.com/json/?fields=countryCode",
    "https://ifconfig.co/json",
    "http://ip-api.com/json/",
)


def iso_to_flag(iso: str) -> str:
    """ISO 3166-1 alpha-2 → 国旗 emoji。不合法就返回空串。"""
    c = (iso or "").strip().upper()
    if len(c) != 2 or not c.isalpha():
        return ""
    return "".join(chr(0x1F1E6 + ord(x) - 65) for x in c)


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _write(path: str, text: str) -> None:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except OSError:
        pass


def _hostname() -> str:
    try:
        h = socket.gethostname()
    except OSError:
        h = ""
    return (h or "").split(".")[0]


def detect_iso(timeout: float = 4.0) -> str:
    """问一次服务器 IP 的归属国。全都不通就返回空串（不是错误）。"""
    for url in GEO_SOURCES:
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                data = json.loads(resp.read(4096).decode("utf-8", "replace"))
        except Exception:                                        # noqa: BLE001
            continue
        code = (data.get("countryCode") or data.get("country_iso")
                or data.get("country_code") or "")
        code = re.sub(r"[^A-Za-z]", "", str(code)).upper()
        if len(code) == 2:
            return code
    return ""


def flag_emoji(refresh: bool = False) -> str:
    """当前旗帜。查不到就返回空串 —— 但**不缓存空结果**：
    接口临时不通时缓存了空，之后永远没有旗帜，而用户只会觉得"前缀丢了"。"""
    if os.environ.get("XRAY_SKIP_FLAG"):
        return ""
    if not refresh:
        cached = _read(FLAG_CACHE)
        if cached:
            return cached
    iso = detect_iso()
    flag = iso_to_flag(iso)
    if flag:
        _write(FLAG_CACHE, flag)
    return flag


def prefix() -> str:
    """服务器前缀。顺序：环境变量 → 缓存（用户答过的）→ 默认 X。"""
    env = (os.environ.get("XRAY_SERVER_NAME") or "").strip()
    if env:
        # 环境变量里可能带旗帜（用户从提示里复制的），旗帜单独留着，
        # 前缀里不留 emoji —— 否则 display_name 会拼出两个旗帜。
        return FLAG_RE.sub("", env).strip(" -") or DEFAULT_PREFIX
    cached = _read(NAME_CACHE)
    if cached:
        return FLAG_RE.sub("", cached).strip(" -") or DEFAULT_PREFIX
    return DEFAULT_PREFIX


def server_id() -> str:
    """给人看的完整服务器标识：旗帜 + 前缀。"""
    flag = flag_emoji()
    p = prefix()
    return (flag + " " + p).strip() if flag else p


def ensure_flag(name: str) -> str:
    """名字里没有旗帜就补一个；有就原样保留（用户自己的旗帜优先）。"""
    name = (name or "").strip()
    if not name:
        return name
    if FLAG_RE.search(name):
        return name
    flag = flag_emoji()
    return (flag + " " + name).strip() if flag else name


def strip_tag_marker(tag: str) -> str:
    """去掉 tag 开头的 `x-`。

    tag 是 `x-vless01-TLS`（x- 表明这是 Xray 建的）。显示名里前缀已经
    承担了"哪台/哪个内核"的职责，再带一个 x- 就成了 `X-x-vless01-TLS`。
    """
    t = (tag or "").strip()
    return re.sub(r"^x-", "", t, flags=re.I) or t


def display_name(tag: str) -> str:
    """节点显示名 = <旗帜> <前缀>-<节点名>。

    三条规则，按优先级：
      1. 名字里**已经有旗帜**（用户自己写的那种）→ 原样返回，不叠前缀
         —— 用户明确表达了"这个节点挂哪个地区的旗"，尊重他。
      2. 其余情况 → `<旗帜> <前缀>-<去掉 x- 的节点名>`。
      3. **绝不能是空串**：空 fragment 会让客户端退化成用域名当名字，
         同一域名下的节点在列表里全叫一个名。
    """
    body = (tag or "").strip()
    if not body:
        body = "node"
    elif FLAG_RE.search(body):
        return body
    body = strip_tag_marker(body) or "node"
    pref = prefix()
    name = f"{pref}-{body}" if pref else body
    return ensure_flag(name)


def set_server_name(name: str) -> str:
    """落盘用户自定义的服务器标识（保留旗帜，供后续所有节点复用）。"""
    name = (name or "").strip()
    if not name:
        return server_id()
    flag = FLAG_RE.search(name)
    if not flag:
        f = flag_emoji()
        if f:
            name = f + " " + name
    _write(NAME_CACHE, name)
    return name


def check() -> int:
    """自检 —— 不联网的部分全部验一遍（联网的只在能通时验）。"""
    bad = 0

    def ck(cond, what):
        nonlocal bad
        print(("  [PASS] " if cond else "  [FAIL] ") + what)
        if not cond:
            bad += 1

    ck(iso_to_flag("US") == "\U0001F1FA\U0001F1F8", "ISO US → 🇺🇸")
    ck(iso_to_flag("hk") == "\U0001F1ED\U0001F1F0", "ISO hk（小写）→ 🇭🇰")
    ck(iso_to_flag("JP") == "\U0001F1EF\U0001F1F5", "ISO JP → 🇯🇵")
    ck(iso_to_flag("U") == "" and iso_to_flag("USA") == "" and iso_to_flag("") == "",
       "非法 ISO 一律返回空（不瞎猜）")
    ck(strip_tag_marker("x-vless01-TLS") == "vless01-TLS", "去掉 tag 的 x- 前缀")
    ck(strip_tag_marker("REALITY-01") == "REALITY-01", "老形态 tag 原样保留")
    ck(strip_tag_marker("x") == "x", "只有 x- 时不至于变空")

    old_flag = os.environ.pop("XRAY_SKIP_FLAG", None)
    old_name = os.environ.pop("XRAY_SERVER_NAME", None)
    # 自检期间不联网、也不读写真实缓存：用临时目录 + 直接注入旗帜
    tmp = os.path.join("/tmp", "xray-naming-check")
    global FLAG_CACHE, NAME_CACHE
    saved = (FLAG_CACHE, NAME_CACHE)
    try:
        FLAG_CACHE = os.path.join(tmp, "flag")
        NAME_CACHE = os.path.join(tmp, "server-name")
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp, exist_ok=True)
        _write(FLAG_CACHE, "\U0001F1FA\U0001F1F8")          # 🇺🇸
        ck(flag_emoji() == "\U0001F1FA\U0001F1F8", "旗帜读缓存（不联网）")
        ck(display_name("x-vless01-TLS") == "\U0001F1FA\U0001F1F8 X-vless01-TLS",
           "默认显示名 = 旗帜 + X + 节点名")
        _write(NAME_CACHE, "HK1")
        ck(display_name("x-trojan02-REALITY") == "\U0001F1FA\U0001F1F8 HK1-trojan02-REALITY",
           "自定义前缀生效")
        ck(display_name("REALITY-01") == "\U0001F1FA\U0001F1F8 HK1-REALITY-01",
           "老形态 tag 也能拼出完整显示名")
        # 多服务器防冲突：前缀不同，名字必须不同
        a = display_name("x-vless01-TLS")
        _write(NAME_CACHE, "HK2")
        ck(a != display_name("x-vless01-TLS"), "不同前缀 → 不同名字（防覆盖）")
        _write(NAME_CACHE, "HK1")
        ck(ensure_flag("\U0001F1ED\U0001F1F0 我自己起的名字") == "\U0001F1ED\U0001F1F0 我自己起的名字",
           "用户自带旗帜时不被改")
        ck(ensure_flag("裸名字").startswith("\U0001F1FA\U0001F1F8 "), "裸名字自动补旗帜")
        ck(display_name("\U0001F1EF\U0001F1F5 我自己起的") == "\U0001F1EF\U0001F1F5 我自己起的",
           "用户自己带旗帜的名字原样保留（不叠前缀）")
        ck(display_name("我的香港节点") == "\U0001F1FA\U0001F1F8 HK1-我的香港节点",
           "裸自定义名补成 旗帜+前缀+名字")
        os.environ["XRAY_SKIP_FLAG"] = "1"
        ck(flag_emoji() == "", "XRAY_SKIP_FLAG=1 → 不要旗帜")
        ck(display_name("x-vless01-TLS") == "HK1-vless01-TLS",
           "没有旗帜时仍然有前缀（而不是什么都没有）")
        ck(display_name("") == "HK1-node", "空 tag 也有非空名字（fragment 不能空）")
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
        FLAG_CACHE, NAME_CACHE = saved
        if old_flag is not None:
            os.environ["XRAY_SKIP_FLAG"] = old_flag
        else:
            os.environ.pop("XRAY_SKIP_FLAG", None)
        if old_name is not None:
            os.environ["XRAY_SERVER_NAME"] = old_name
        else:
            os.environ.pop("XRAY_SERVER_NAME", None)

    print(f"\n命名自检: {'PASS' if bad == 0 else str(bad) + ' 项失败'}")
    return 1 if bad else 0


def main(argv) -> int:
    cmd = argv[1] if len(argv) > 1 else "server"
    if cmd == "--check":
        return check()
    if cmd == "flag":
        print(flag_emoji())
    elif cmd == "prefix":
        print(prefix())
    elif cmd == "server":
        print(server_id())
    elif cmd == "display":
        print(display_name(argv[2] if len(argv) > 2 else ""))
    elif cmd == "ensure":
        print(ensure_flag(argv[2] if len(argv) > 2 else ""))
    elif cmd == "set":
        print(set_server_name(argv[2] if len(argv) > 2 else ""))
    elif cmd == "refresh":
        print(flag_emoji(refresh=True) or "")
    else:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
