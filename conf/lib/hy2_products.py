#!/usr/bin/env python3
"""hysteria2 per-node 产物 (out/hy2_share-<NN>.txt) 的**只重建**路径。

为什么要这个文件
================
`hy2_share-*.txt` 唯一的写入方是 `conf/hysteria2.sh` 的 `add_config`（新增节点）。
于是节点建好之后：

  · 改了带宽/字段口径（本轮：默认 50 → 60，且用户可显式设置）—— 已发出的产物永远是旧的；
  · 生成逻辑本身修了（本轮：去掉会让整条订阅打挂的 `obfs=none`）—— 同上；
  · 环境变了（本轮实测：证书文件被续期流程删掉 → 载荷侧推导不出 sni）——
    产物与载荷从此不一致。

前两种没有任何路径能修回来；第三种是本文件最需要小心的一种。实测 RN：
`hy2_share-02/03/04` 还是旧字节（`obfs=none&up=50`），而订阅载荷走的是新的
`nodes.build_share_link()`，两条路不一致 —— 发布闸门拒发是对的（拒发比发出去
连不上强），但**没有任何面板路径能把产物重建回来**，用户只能手改产物
（那是明令不许的）。

设计
====
★ 链接**只从 `nodes.build_share_link()` 一处取** —— 与订阅载荷同一份实现。
  本模块再拼一遍链接必然漂移，而"两条路漂移"正是它要消灭的问题。
★ **无损重建**：现有产物里有、而新链接里没有的**安全相关**参数
  （`sni` / `pin` / `insecure`；`obfs` 只在非 none 时算）一律**拒绝写**并报出原因。
  这不是洁癖：实测 RN 上 hysteria-04 的证书文件被删掉后，新推导拿不到 sni；
  把"没有 sni"的产物写下去会得到一份**两边一致地错**的产物 ——
  闸门放行、面板全绿，而客户端拿 IP 当 SNI 校验证书必然失败：

      CC 实测（同一个节点、同一时刻）:
        sni=moontv.6896698.xyz → HTTP 204 + 出口 104.28.195.192
        sni 为空                → HTTP 000

  宁可留着"产物与载荷不一致"让人看见，也不写一份会把手链接搞坏的产物。
★ 带宽类参数（`up/down/upmbps/downmbps/mport`）是**口径对齐**，不算丢失：
  新旧值都会逐项打出来（`changed=`），报告里能看到改了哪几个。

用法（非交互；不新建节点、不重启任何服务、不碰内核）
====================================================
    python3 conf/lib/hy2_products.py --conf-dir DIR --out-dir DIR \
            [--share-dir DIR] [--apply]

不带 `--apply` 只报告，不写盘（默认是 dry-run —— 这个脚本会被人在生产上手跑）。

输出（稳定可 grep，门禁按这些行断言）:
    NODE <tag> verdict=<ok|refused|unchanged|no-product|missing> lost=<k,k> \
         changed=<k:old->new,...> written=<0|1>
    SUMMARY total=N rebuilt=M refused=K unchanged=J
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nodes as N            # noqa: E402  同一份节点视图 + 同一份发布闸门 + 同一份链接实现
import share_meta            # noqa: E402

# 安全相关参数: 旧产物里有、新链接里没有 → 拒绝重建（见模块 docstring 的实测）
GUARD_KEYS = ("sni", "pin", "insecure", "alpn", "obfs")
# 口径对齐类: 值变化照写，逐项报告
SOFT_KEYS = ("up", "down", "upmbps", "downmbps", "mport")
PRODUCT_RE = re.compile(r"^hy2_share-(\d+)\.txt$")


def _query(link):
    """链接的查询串 → dict（同名取第一个；片段/大小写归一）。"""
    if not link:
        return {}
    q = urllib.parse.urlsplit(link).query
    out = {}
    for k, v in urllib.parse.parse_qsl(q, keep_blank_values=True):
        out.setdefault(k.strip().lower(), v)
    return out


def _diff(old, new):
    """→ (lost, changed)。lost 非空 = 必须拒绝写。"""
    oq, nq = _query(old), _query(new)
    lost, changed = [], []
    for k in GUARD_KEYS:
        ov = str(oq.get(k, "") or "").strip()
        nv = str(nq.get(k, "") or "").strip()
        if not ov:
            continue
        if k == "obfs" and ov.lower() == "none":
            continue            # obfs=none 是旧代码的错值, 不算"丢失"(本轮要消灭它)
        if not nv:
            lost.append(k)
        elif ov != nv:
            changed.append("%s:%s->%s" % (k, ov, nv))
    for k in SOFT_KEYS:
        ov = str(oq.get(k, "") or "").strip()
        nv = str(nq.get(k, "") or "").strip()
        if ov != nv:
            changed.append("%s:%s->%s" % (k, ov or "-", nv or "-"))
    return lost, changed


def _first_line(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return next((x.strip() for x in fh if x.strip()), "")
    except OSError:
        return ""


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="重建 hysteria2 per-node 产物（非交互，不碰内核）")
    ap.add_argument("--conf-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--share-dir", default="")
    ap.add_argument("--apply", action="store_true",
                    help="真的写盘；不给就是 dry-run")
    a = ap.parse_args(argv)
    share_dir = a.share_dir or os.path.join(a.out_dir, "share")

    node_list, _bad = N.collect(a.conf_dir)
    by_tag = {x["tag"]: x for x in node_list}

    products = {}
    try:
        for f in sorted(os.listdir(a.out_dir)):
            m = PRODUCT_RE.match(f)
            if m:
                products[m.group(1)] = os.path.join(a.out_dir, f)
    except OSError as e:
        print("无法扫描产物目录 %s: %s" % (a.out_dir, e), file=sys.stderr)
        return 2

    total = rebuilt = refused = unchanged = 0
    for idx in sorted(products):
        total += 1
        path = products[idx]
        tag = "hysteria-%s" % idx            # add_config 写的 inbound tag 就是 $PROTO-$index
        n = by_tag.get(tag)
        old = _first_line(path)
        if n is None:
            print("NODE %s verdict=missing changed= written=0" % tag)
            unchanged += 1
            continue
        meta = share_meta.load(share_dir, tag) or {}
        new = N.build_share_link(n, meta)
        if not new:
            print("NODE %s verdict=refused lost=<链接构不出来> changed= written=0" % tag)
            refused += 1
            continue
        lost, changed = _diff(old, new)
        if lost:
            print("NODE %s verdict=refused lost=%s changed=%s written=0"
                  % (tag, ",".join(lost), ",".join(changed)))
            refused += 1
            continue
        if old == new:
            print("NODE %s verdict=unchanged changed= written=0" % tag)
            unchanged += 1
            continue
        written = 0
        if a.apply:
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(new + "\n")
            os.replace(tmp, path)
            written = 1
        print("NODE %s verdict=ok changed=%s written=%d"
              % (tag, ",".join(changed) or "-", written))
        rebuilt += 1

    print("SUMMARY total=%d rebuilt=%d refused=%d unchanged=%d"
          % (total, rebuilt, refused, unchanged))
    return 0


if __name__ == "__main__":
    sys.exit(main())
