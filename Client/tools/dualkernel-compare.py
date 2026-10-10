#!/usr/bin/env python3
"""双跑对比台：旧判定（compat.py） vs 新判定（compat2 → proxy-node-compat） vs 合并结果。

用途（顺序就是用法）：
    1. 先把差异**列出来**，不是先切换；
    2. 差异分四类，只有第一类允许存在：
         relaxed   旧"不支持" → 新"支持"     ❌ 绝不允许（单调保险丝，出现即 exit 1）
         tightened 旧"支持"   → 新"不支持"   ✅ 允许，但必须逐条给出 reason_code 与规则
         fallback  compat 无规则 → 沿用旧判定 ✅ 允许（"我们没数据"≠"节点不行"）
         same      一致
       `dialer` 维度必须**完全一致**（它本来就是同一个实现，改了就是 bug）。
    3. 输出一张 markdown 表，可直接贴进报告。

用法:
    python3 tools/dualkernel-compare.py                     # 内置语料
    python3 tools/dualkernel-compare.py <语料.json> [节点.json|节点目录 ...]
    XBD_XRAY_VERSION=26.3.27 python3 tools/dualkernel-compare.py   # 无内核二进制时
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.abspath(os.path.join(HERE, "..", "lib"))
CORPUS = os.path.join(HERE, "compat-corpus.json")

spec = importlib.util.spec_from_file_location("_c2", os.path.join(LIB, "compat2.py"))
c2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c2)
spec = importlib.util.spec_from_file_location("_c1", os.path.join(LIB, "compat.py"))
c1 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c1)


def _node_mod():
    spec = importlib.util.spec_from_file_location("_nd", os.path.join(LIB, "node.py"))
    nd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nd)
    return nd


SKIPPED: list = []


def node_from_uri(uri: str):
    """URI → 节点 JSON。**走 node.py 自己的解析器**（不另写一套）。

    解析不了就返回 None —— 那说明"客户端根本导不进这个链接"，属于另一类结论
    （不是判定差异），单独列出来，不混进对照表。
    """
    nd = _node_mod()
    try:
        n = nd.parse_node(uri)
        if isinstance(n, dict) and n.get("protocol"):
            return n
    except Exception:
        pass
    scheme = uri.split("://", 1)[0].lower()
    if scheme in ("socks", "socks5", "http", "https"):
        try:      # 简易出站走的是另一条构造路径
            from urllib.parse import urlsplit
            u = urlsplit(uri)
            proto = "http" if scheme in ("http", "https") else "socks"
            return nd.simple_node(proto, u.hostname or "127.0.0.1", u.port or 0,
                                  username=u.username or "", password=u.password or "",
                                  name=(u.fragment or f"{proto}-simple"))
        except Exception:
            pass
    SKIPPED.append((uri, "客户端不支持导入该 scheme"))
    return None


def load_corpus(path: str) -> list[dict]:
    data = json.load(open(path, encoding="utf-8"))
    out = [n for n in (node_from_uri(u) for u in data.get("uris") or []) if n]
    out += list(data.get("nodes") or [])
    return out


def collect(extra: list[str]) -> list[dict]:
    nodes, seen = [], set()

    def add(n):
        k = json.dumps(n, sort_keys=True, ensure_ascii=False)
        if k not in seen:
            seen.add(k)
            nodes.append(n)

    for p in extra:
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if f.startswith("node-") and f.endswith(".json"):
                    add(json.load(open(os.path.join(p, f), encoding="utf-8")))
        elif os.path.exists(p):
            raw = open(p, encoding="utf-8").read()
            try:
                d = json.loads(raw)
                for x in (d if isinstance(d, list) else [d]):
                    add(x)
            except ValueError:
                add(node_from_uri(raw.strip()))
        else:
            sys.stderr.write(f"跳过不存在的路径: {p}\n")
    return nodes


def main(argv) -> int:
    args = argv[1:]
    if args and args[0].endswith(".json") and os.path.exists(args[0]):
        corpus, args = args[0], args[1:]
    else:
        corpus = CORPUS
    nodes = load_corpus(corpus) + collect(args)
    tgt = c2.xray_target()
    print(f"# 双跑对比 —— 语料 {len(nodes)} 条；目标 kernel={tgt.kernel} "
          f"version={tgt.version or '(未探测到)'} distribution={tgt.distribution or 'upstream'}")
    print(f"# runtime_options={tgt.runtime_options}")
    print()
    print("| 节点 | 协议/传输/安全 | 旧判定 | compat | 合并 | 来源 | reason_codes | 多判出的 |")
    print("|---|---|---|---|---|---|---|---|")
    cats = {"same": [], "tightened": [], "relaxed": [], "fallback": [], "dialer_bug": []}
    for n in nodes:
        r = c2.compare(n)
        lo, ko, me = r["legacy"], r["compat_legacy"], r["merged"]
        if r["fallback"]:
            cat = "fallback"
        elif c1.VERDICT_RANK[me] > c1.VERDICT_RANK[lo]:
            cat = "relaxed"
        elif c1.VERDICT_RANK[me] < c1.VERDICT_RANK[lo]:
            cat = "tightened"
        else:
            cat = "same"
        if r["dialer_legacy"] != r["dialer_merged"]:
            cats["dialer_bug"].append(r)
        extra = []
        if r["losses"]:
            extra.append("丢:" + ",".join(str(x) for x in r["losses"]))
        if r["reason_codes"]:
            extra.append("码:" + ",".join(r["reason_codes"]))
        if r["extensions"]:
            extra.append("ext:" + ",".join(str(x) for x in r["extensions"][:4]))
        print(f"| {r['name']} | {r['protocol']}/{r['transport'] or '-'}/{r['security']} | {lo} | "
              f"{(r['compat'] or '-')} | {me} | {r['verdict_source']} | "
              f"{','.join(r['reason_codes']) or '-'} | {'; '.join(extra) or '-'} |")
        cats[cat].append(r)

    if SKIPPED:
        print()
        print(f"## 客户端不支持导入（不是判定差异）: {len(SKIPPED)} 条")
        for u, why in SKIPPED:
            print(f"    - {why}: {u[:80]}")
    print()
    print("## 分类")
    for k in ("same", "tightened", "fallback", "relaxed", "dialer_bug"):
        print(f"- **{k}**: {len(cats[k])}")
        for r in cats[k]:
            if k == "same":
                continue
            print(f"    - {r['name']} [{r['protocol']}/{r['transport'] or '-'}/{r['security']}] "
                  f"{r['legacy']} → {r['merged']}"
                  + (f"  规则={r['rules_applied']}" if r["rules_applied"] else "")
                  + (f"  原因码={r['reason_codes']}" if r["reason_codes"] else ""))
    bad = len(cats["relaxed"]) + len(cats["dialer_bug"])
    print()
    print(f"结论: {'✗ 存在放宽/退步' if bad else '✓ 无放宽（新判定只收紧或一致）'}"
          f"；收紧 {len(cats['tightened'])} 条；回退旧判定 {len(cats['fallback'])} 条")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
