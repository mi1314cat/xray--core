#!/usr/bin/env python3
"""Xray 分享**载荷构建** —— 从 conf/ 片段重建订阅内容。

从 share_server.py 抽出来的。理由: 分享的存储与生命周期已归**公共基础服务**
(proxy-share-service), 本机不再需要那个 HTTP 服务端; 但"内容怎么生成"是
Xray 自己的知识, 必须留着 —— 而且两边 (面板创建时 / 节点变动后刷新时)
要用**同一份**实现, 抄一遍必然漂移。

★ 载荷格式一字未改: base64 的订阅行。已发出去的链接、已经导入过的客户端
  都按这个格式解析, 改格式等于把所有人踢下线。
"""

import base64
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import share_meta  # noqa: E402

CONF_DIR = os.environ.get("XRAY_CONF_DIR", "/root/catmi/xray/conf")
SHARE_DIR = os.environ.get("XRAY_SHARE_DIR", "/root/catmi/xray/out/share")
# per-node 产物目录 (out/<proto>_share-<NN>.txt) —— 一致性校验的参照物。
# 默认取 SHARE_DIR 的上一级: 生产是 out/share → out。
OUT_DIR = (os.environ.get("XRAY_OUT_DIR")
           or os.path.dirname(os.path.abspath(SHARE_DIR.rstrip("/"))))

# ★ 载荷生成逻辑的版本号。任何会改变**已发出载荷内容**的改动都要 +1:
#   它被写进分享记录的 meta, 于是 "服务端修好了但用户手里还是旧订阅"
#   这件事从"没人会发现"变成"refresh 时会自动重建 / list 时会明确报陈旧"。
#   1 → 2: 分享层补 ECH + 与 per-node 产物做一致性校验 (2026-10-10)
PAYLOAD_SCHEMA = 2


def build_links(tags, full=False):
    """按 tag 从 conf/ 片段重建分享链接。

    返回 (lines, missing, nometa, bad) —— 这是**沿用**的老四元组接口;
    full=True 时返回七元组, 多出 `refused` / `notes` / `inconsistent`:
    节点在、元数据也在, 但**按它的监听地址不该对外发布**(例如只绑回环
    又没有 nginx 反代)。生产上 vless-xhttp-01/02/03 就是这种:
    链接发出去写的是 `107.173.154.178:25333`, 而那个端口只绑在 127.0.0.1。

    `inconsistent` 是**新的一类** (与 refused 分开): 节点本身没问题, 但
    这次重建出来的链接与它自己的 per-node 产物 (out/<proto>_share-*.txt)
    在关键字段上对不上 —— 两条路径的取值逻辑又漂移了。这一条**必须拒发**:
    实测事故就是"产物有 sni/ech、载荷没有", 三家客户端同时连不上, 而
    面板上一切正常。

    这些都不是致命错误: 其余节点的订阅仍然有用, 全都丢掉反而更糟。
    但必须分开报出来 —— "分享了 4 个节点客户端只收到 1 个" 如果只给一个
    总数, 是节点被删了、没配地址、还是绑了回环发不出去, 完全查不出来。
    """
    import nodes as nodereg

    node_list, bad = nodereg.collect(CONF_DIR)
    by_tag = {n["tag"]: n for n in node_list}

    lines, missing, nometa, refused, notes = [], [], [], [], []
    for t in tags:
        n = by_tag.get(t)
        if not n:
            missing.append(t)
            continue
        meta = share_meta.load(SHARE_DIR, t) or {}
        # 先把"这个 tag 为什么没进订阅"记下来: build_share_link 返回 None 时
        # 从它 append 的提示里取最后一条, 这样原因只有一处实现。
        before = len(notes)
        link = nodereg.build_share_link(n, meta, notes=notes)
        if link:
            lines.append((t, link))
            continue
        why = next((x for x in reversed(notes[before:]) if "未发布" in x), None)
        if why:
            refused.append((t, why.split("未发布 —— ", 1)[-1]))
        else:
            nometa.append(t)

    # 一致性校验 —— 载荷里每一条都与同名节点的 per-node 产物对关键字段。
    kept, inconsistent, checked, unchecked = nodereg.verify_against_products(
        lines, OUT_DIR, notes=notes)
    if unchecked:
        notes.append("没有 per-node 产物可比对 (未校验): " + ",".join(unchecked))
    if checked:
        notes.append(f"与 per-node 产物一致性校验: {len(checked)} 条通过, "
                     f"{len(inconsistent)} 条被拒发")
    lines = [link for _, link in kept]

    if full:
        return lines, missing, nometa, bad, refused, notes, inconsistent
    # 老接口: 拒发并入 nometa(调用方看不出细分)，要看细分请用 full=True
    return (lines, missing,
            nometa + [t for t, _ in refused] + [t for t, _ in inconsistent], bad)


def build_payload(tags, full=False):
    """标准订阅格式: base64 的一行。

    绝大多数客户端 (含本项目自己的 Client) 都按 base64 订阅解析, 明文多行
    只是兼容项。
    """
    if full:
        links, missing, nometa, bad, refused, notes, inconsistent = \
            build_links(tags, full=True)
        if not links:
            return None, missing, nometa, bad, refused, notes, inconsistent
        text = "\n".join(links)
        return (base64.b64encode(text.encode()).decode(), missing, nometa, bad,
                refused, notes, inconsistent)
    links, missing, nometa, bad = build_links(tags)
    if not links:
        return None, missing, nometa, bad
    text = "\n".join(links)
    return base64.b64encode(text.encode()).decode(), missing, nometa, bad
