"""订阅与分组。

节点一多，"一个扁平的列表"就不可用了：二十个节点往下拉要滚半天，而且看不出
哪个来自哪条订阅。SB 和 M 解决这件事的办法都是在导入时把归属记下来，再由
配置生成层把层级塞进内核。本模块只管数据，渲染和配置各归各家。

三个设计取舍，都是实测踩出来的：

**分组记在节点上，不靠名字前缀反推。**
SB 用 "节点名以 `<前缀>-` 开头" 来反推归属 (`client.sh:739`)。但名字是用户改
的，改完归属就悄悄丢了。所以节点 JSON 里直接写 `group`，前缀只用于显示和
排序。前缀树推导只在导入那一刻用一次，见 infer_groups()。

**订阅按前缀去重，不按 URL。**
同一个订阅换了个 token，URL 就变了，按 URL 去重会多出一个几乎一样的分组。
按前缀去重才对。

**注册表必须先写、再生成配置。**
SB 把这个顺序踩反过：新加的订阅节点跑进了"其它"组 (`client.sh:1234-1253`)。
本模块的 add_sub() 永远先落盘再返回，调用方拿到的就是已经可用的。
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.parse

SUBS_FILE = "subs.json"
SCHEMA = 1


def subs_path(prefix_dir: str) -> str:
    return os.path.join(prefix_dir, "runtime", SUBS_FILE)


def _now() -> int:
    return int(time.time())


def sub_id(url: str) -> str:
    """订阅 id。取 URL 的 md5 前 12 位，够短好认，碰撞概率在这个量级可忽略。"""
    return hashlib.md5(url.encode("utf-8")).hexdigest()[:12]


def load(prefix_dir: str) -> dict:
    """读注册表。文件缺失/损坏都退回空表 —— 注册表是派生数据，丢了要能重建，
    不能因为它坏了就让整个客户端打不开。"""
    path = subs_path(prefix_dir)
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        data = {"schema": SCHEMA, "subs": []}
    data.setdefault("subs", [])
    return data


def save(prefix_dir: str, data: dict) -> None:
    path = subs_path(prefix_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # 先写临时文件再改名：写到一半断电/被杀不会留下半个 JSON。
    # 直接覆盖的话，下一次读就是 ValueError，注册表内容全丢。
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def slugify(name: str, fallback: str = "sub") -> str:
    """把显示名变成能安全当句柄用的 ASCII 前缀。

    显示名原样保留（中文订阅名在列表里就该看得懂），前缀只做安全句柄，所以这里
    必须剥到纯 ASCII。注意 `str.isalnum()` 对中文是**返回 True** 的，所以不能
    用它来判"是不是 ASCII 字符" —— 直接用的话 `机场A` 会原样变成 `机场a`，
    而这个前缀要进文件路径，某些工具链上就是编码雷。

    剥完是空的（纯中文名）就退回 id，不让前缀变成空串 —— 空前缀会让所有节点
    都挤进"其它"组。
    """
    out = "".join(c if ("a" <= c <= "z" or "A" <= c <= "Z" or "0" <= c <= "9"
                        or c in "-_") else "-" for c in (name or ""))
    out = "-".join(p for p in out.split("-") if p).strip("-").lower()
    return out or fallback


def unique_prefix(data: dict, want: str) -> str:
    """给订阅分配不冲突的前缀。

    冲突时加数字后缀，但**不静默**加 —— 调用方要把新前缀报给用户，让他知道
    这条订阅在列表里长什么样。
    """
    taken = {(s.get("prefix") or "") for s in data["subs"]}
    if want not in taken:
        return want
    for i in range(2, 1000):
        cand = "%s-%d" % (want, i)
        if cand not in taken:
            return cand
    raise ValueError("前缀分配失败: 已有 998 条订阅同名前缀")


def add_sub(prefix_dir: str, url: str, name: str, kind: str = "external") -> dict:
    """登记一条订阅。同一 URL 重复登记返回原记录，不新建。"""
    data = load(prefix_dir)
    for s in data["subs"]:
        if s.get("url") == url:
            return s
    sid = sub_id(url)
    rec = {
        "id": sid,
        "name": name or sid,
        "prefix": unique_prefix(data, slugify(name, sid)),
        "url": url,
        "kind": kind,          # external=远程订阅 / local=本地文件 / server=Server Pull
        "nodes": [],
        "added_at": _now(),
        "last_ok": 0,
        "last_error": "",
    }
    data["subs"].append(rec)
    save(prefix_dir, data)     # 必须先落盘，调用方紧接着就要生成配置
    return rec


def set_nodes(prefix_dir: str, sub_id_: str, files: list) -> None:
    """更新这条订阅当前带来的节点文件列表。"""
    data = load(prefix_dir)
    for s in data["subs"]:
        if s.get("id") == sub_id_:
            s["nodes"] = sorted(files)
            s["last_ok"] = _now()
            s["last_error"] = ""
            break
    save(prefix_dir, data)


def mark_result(prefix_dir: str, sub_id_: str, ok: bool, error: str = "") -> None:
    data = load(prefix_dir)
    for s in data["subs"]:
        if s.get("id") == sub_id_:
            if ok:
                s["last_ok"] = _now()
                s["last_error"] = ""
            else:
                s["last_error"] = error
            break
    save(prefix_dir, data)


def _atomic_write(path: str, text: str) -> None:
    """先写临时文件再改名。

    节点文件被改到一半（比如进程被杀）就成了一段残缺 JSON，之后既读不出节点，
    也修不回来 —— 它本来是好的。半小时几百个节点的导入里，这种窗口是真实存在的。
    """
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def stamp_group(prefix_dir: str, gid: str, files: list) -> list:
    """把分组 id 写进每个节点文件。

    为什么要在**导入时**就把 group 落到文件里，而不是每次靠名字推断：
    名字推断是兜底，不是事实。机场改了节点命名（`01` → `美国 01`），推断出的组
    会整个变掉，用户昨天记住的分组今天对不上。写进文件的是当时的事实。

    写单个文件失败只跳过，不中断 —— 一批几十个节点里坏一个，不该让整次导入
    看起来失败。
    """
    ok = []
    for f in files:
        path = os.path.join(prefix_dir, "nodes", os.path.basename(f))
        try:
            with open(path, encoding="utf-8") as fh:
                node = json.load(fh)
        except (OSError, ValueError):
            continue
        if node.get("group") == gid:
            ok.append(f)
            continue
        node["group"] = gid
        try:
            _atomic_write(path, json.dumps(node, ensure_ascii=False, indent=2))
            ok.append(f)
        except OSError:
            continue
    return ok


def name_from_url(url: str) -> str:
    """用户没给订阅名时，从 URL 推一个能认出来的名字。

    取主机名去掉 www. 和常见的订阅后缀，而不是整条 URL —— 列表里显示
    `https://sub.example.com/link/abc123?token=xxx` 这种东西没法看。
    推不出来就交给调用方兜底。
    """
    try:
        host = urllib.parse.urlparse(url).netloc or ""
    except ValueError:
        return ""
    host = host.split("@")[-1].split(":")[0]
    if not host:
        return ""
    if host.startswith("www."):
        host = host[4:]
    return host


def drop_sub(prefix_dir: str, sub_id_: str, keep_nodes: bool = False) -> list:
    """删订阅记录。默认连节点文件一起删；keep_nodes=True 时只删记录。

    保留节点是给"这条是机场一次性链接"的场景：链接废了但节点还能用，删掉等于
    白丢。所以调用方要提供这个开关，而不只是"删/不删"两个按钮。
    """
    data = load(prefix_dir)
    gone = None
    for s in data["subs"]:
        if s.get("id") == sub_id_:
            gone = s
            break
    if gone is None:
        return []
    data["subs"] = [s for s in data["subs"] if s.get("id") != sub_id_]
    save(prefix_dir, data)
    return [] if keep_nodes else list(gone.get("nodes") or [])


def group_nodes(prefix_dir: str, nodes: list) -> list:
    """把节点列表组织成带分组的视图。

    nodes 每项需带 file 与 name。返回按分组聚合的结构：

        [{"key": 分组键, "name": 显示名, "order": 排序权重,
          "origin": registry|prefix|other, "nodes": [...]}]

    分组键的来源，按可信度从高到低：

    1. 节点自己带的 `group`（导入时由订阅登记写入）。这是唯一可靠来源 ——
       名字前缀只是导入那一瞬间的推断，用户改名之后就该失效。
    2. 注册表里这条订阅登记过的节点文件。用于老数据：这些节点没有 group 字段，
       但注册表记得它们属于谁。
    3. 都没命中就由名字推断（infer_groups）。
    4. 还是没有的落进「其它」。

    「其它」永远排最后且**不参与**"要不要分组"的判断。SB 当初想优化成"只有
    一个订阅时才分组"，结果整条需求等于消失，后来回退了 (`client.sh:760-768`)。
    有订阅就分组，与订阅数量无关。
    """
    by_file = {n["file"]: n for n in nodes}
    registry = load(prefix_dir)
    file_to_sub = {}
    for i, s in enumerate(registry["subs"]):
        for f in (s.get("nodes") or []):
            file_to_sub.setdefault(f, (i, s))

    # 前缀推断只在"有节点没归属"时才跑：全部都有 group 时它是白算的，
    # 而且会对没关系的节点编出些看起来像分组的假象。
    need_infer = [n for n in nodes
                  if not n.get("group") and n["file"] not in file_to_sub]
    inferred = infer_groups(need_infer) if need_infer else {}

    buckets: dict = {}
    for n in nodes:
        f = n["file"]
        if n.get("group") in by_group_ids(registry):
            key, name, order, origin = n["group"], group_name(registry, n["group"]), \
                group_order(registry, n["group"]), "registry"
        elif f in file_to_sub:
            i, s = file_to_sub[f]
            key, name, order, origin = s.get("id"), s.get("name") or s.get("prefix"), i, "registry"
        else:
            # 推断出来的组排在注册表组之后，按名字字母序互相排；「其它」垫底。
            name = inferred.get(f) or "其它"
            key = "pfx:" + name
            if name == "其它":
                order = 99999
            else:
                order = 9000 + sorted(set(inferred.values())).index(name)
            origin = "other" if name == "其它" else "prefix"
        b = buckets.setdefault(key, {"key": key, "name": name, "order": order,
                                    "origin": origin, "nodes": []})
        b["nodes"].append(n)
        # 一个节点的实际归属要写回去，前端才能按 group 做高亮/筛选
        n["group_key"] = key
        n["group_name"] = name
    # 空组也要列出来。用户新建一个组、往里放节点之前，它必须已经出现在列表里 ——
    # 否则"新建分组"这个动作看起来什么也没发生，用户会以为功能坏了。
    for i, sub in enumerate(registry["subs"]):
        sid = sub.get("id")
        if sid and sid not in buckets:
            buckets[sid] = {"key": sid, "name": sub.get("name") or sub.get("prefix"),
                            "order": i, "origin": "registry", "nodes": []}

    out = list(buckets.values())
    out.sort(key=lambda g: (g["order"], g["name"]))
    return out


def by_group_ids(registry: dict) -> set:
    return {s.get("id") for s in registry["subs"] if s.get("id")}


def group_name(registry: dict, gid: str) -> str:
    for s in registry["subs"]:
        if s.get("id") == gid:
            return s.get("name") or s.get("prefix") or gid
    return gid


def group_order(registry: dict, gid: str) -> int:
    for i, s in enumerate(registry["subs"]):
        if s.get("id") == gid:
            return i
    return 8000


def infer_groups(nodes: list) -> dict:
    """没有注册表时，从节点名反推分组。

    用**最长公共前缀树**，不能简单地砍掉最后一段。订阅节点常长这样：
    `srv1-vless01-TLS`、`srv1-vless02-TLS`、`srv1-trojan01-TLS`。砍一段全都对，
    但 `srv1-vless01-TLS-CDN` 砍一段会落到 `srv1-vless01`，把 CDN 节点单独
    分出去 —— 而它属于同一条订阅。逐层往下走，只有当这一层真的分叉了才停。

    nodes 每项需带 name 与 file。返回 {file: 分组显示名}。

    逐层下探时只要**所有**节点这一段的段头都相同就继续往深里走；一旦分叉，
    或有人先走完，就停在这里。

    分叉那一段本身是区分点，必须**包含**在分组名里。所以 depth=0（有分叉、没有
    公共段）时取 s[:1] 而不是 s[:0] —— 后者得到空串，几十个节点会一起掉进"其它"，
    正是这个函数要解决的问题。
    """
    segs = [[p for p in (n.get("name") or "").split("-") if p] for n in nodes]
    if not segs:
        return {}
    depth = 0
    while all(len(s) > depth for s in segs) and len({s[depth] for s in segs}) == 1:
        depth += 1
    take = depth if depth > 0 else 1
    # 别把名字吃光。只剩一个待推断节点时，"共享前缀"就是它整个名字，于是它自己
    # 变成一个以自己命名的组 —— 列表上多一行"手动-东京"，下面挂一个"手动-东京"。
    # 留不下余量就把 take 收一格，收成 0 则归入「其它」。
    # 只在 depth>0 时收缩：depth==0 的 take=1 是"按第一段区分"，本来就该原样用
    # —— 名字为空的节点在这里取到空串落进「其它」，那是对的。
    if depth > 0:
        shortest = min(len(s) for s in segs)
        while take > 0 and shortest - take <= 0:
            take -= 1
    out = {}
    for n in nodes:
        s = [p for p in (n.get("name") or "").split("-") if p]
        group = "-".join(s[:take]) if s else ""
        out[n["file"]] = group or "其它"
    return out

# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------
# 导入和删组都在 shell 侧发起，python 这边提供一个小入口。刻意做成"一次调用完成
# 一件事"：注册表写一半、节点还没盖上 group 的中间态，用户看到的是"组是空的"。
def _cli(argv):
    import sys
    if len(argv) < 3:
        print(__doc__ or "用法: subs.py <cmd> ...", file=sys.stderr)
        return 2
    cmd, prefix_dir = argv[1], argv[2]

    if cmd == "add":
        # add <prefix> <url> <name> [kind]
        name = argv[4] if len(argv) > 4 else ""
        kind = argv[5] if len(argv) > 5 else "external"
        url = argv[3]
        if not name:
            name = name_from_url(url) or "订阅"
        rec = add_sub(prefix_dir, url, name, kind)
        print(json.dumps({"id": rec["id"], "name": rec["name"],
                          "prefix": rec["prefix"]}, ensure_ascii=False))
        return 0

    if cmd == "bind":
        # bind <prefix> <gid> <file> [file ...]  —— 盖 group 字段
        files = argv[4:]
        done = stamp_group(prefix_dir, argv[3], files)
        set_nodes(prefix_dir, argv[3], done)
        print(json.dumps({"stamped": len(done), "asked": len(files)},
                         ensure_ascii=False))
        return 0

    if cmd == "bind-latest":
        # bind-latest <prefix> <gid> <before>  —— 把"导入开始前已有的文件"之外、
        # 新出现的节点文件全绑到这一组。shell 侧不方便收集文件名时用这个。
        gid, before = argv[3], set(argv[4:])
        nodes = os.path.join(prefix_dir, "nodes")
        new = [f for f in sorted(os.listdir(nodes))
               if f.endswith(".json") and not os.path.islink(os.path.join(nodes, f))
               and f not in before]
        done = stamp_group(prefix_dir, gid, new)
        set_nodes(prefix_dir, gid, done)
        print(json.dumps({"stamped": len(done), "files": done}, ensure_ascii=False))
        return 0

    if cmd == "drop":
        # drop <prefix> <gid> [--keep-nodes]
        keep = "--keep-nodes" in argv
        removed = drop_sub(prefix_dir, argv[3], keep_nodes=keep)
        if not keep:
            for f in removed:
                try:
                    os.remove(os.path.join(prefix_dir, "nodes", os.path.basename(f)))
                except OSError:
                    pass
        print(json.dumps({"removed": len(removed)}, ensure_ascii=False))
        return 0

    if cmd == "list":
        reg = load(prefix_dir)
        print(json.dumps(reg["subs"], ensure_ascii=False, indent=2))
        return 0

    print(f"未知子命令: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(_cli(sys.argv))
