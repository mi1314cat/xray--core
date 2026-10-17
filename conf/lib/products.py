#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""客户端产物重建 —— 片段 + 分享元数据 → 每节点 YAML + 整份可运行 mihomo 配置。

★ 为什么要单独有这个脚本 (而不是各调用点各自拼一遍):
  指纹 / 连接地址是**分享元数据**里的字段, 而客户端产物 (out/*.yaml) 是
  创建节点那一刻生成的快照。换完指纹或地址族之后, 链接/订阅已经变了, 产物
  却还是旧的 —— 用户看到的文件与实际连接参数不一致, 而面板一切正常。
  实测 (2026-10-17): 换指纹后 out/<tag>.yaml 里的 client-fingerprint 还是
  旧值; 换地址族后 server 还是旧 IP。SB 侧同类功能是"改 JSON 再重新生成
  YAML", 这里照它的做法, 以**元数据为唯一真相**重建产物。

★ 地址: `server` 取的是 share_meta.host —— 域名节点的 host 是 CDN 域名,
  重建**永远不会**把它换成 IP。SB 当年那个 bug (换 IP 时把 CDN 域名换成
  IP, 客户端全部失效) 在这里结构上不可能发生: 本脚本只读 host, 不推导地址。

用法:
    python3 products.py --conf-dir <conf> --share-dir <out/share> \
                        --out-dir <out> [--full-name mihomo-full.yaml]
输出 JSON: {"nodes":N,"proxies":M,"full":路径或"","skipped":[{tag,why}]}
"""
import argparse
import json
import os
import sys


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf-dir", required=True)
    ap.add_argument("--share-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--full-name", default="mihomo-full.yaml")
    ap.add_argument("--mixed-port", type=int, default=7890)
    ap.add_argument("--group", default="🚀 节点选择")
    a = ap.parse_args(argv[1:])

    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    import share_meta
    import to_mihomo

    os.makedirs(a.out_dir, exist_ok=True)
    frags = sorted(f for f in os.listdir(a.conf_dir) if f.endswith(".json"))
    proxies, skipped, n_written = [], [], 0
    for fn in frags:
        path = os.path.join(a.conf_dir, fn)
        try:
            frag = json.load(open(path, encoding="utf-8"))
        except Exception as e:                                   # noqa: BLE001
            skipped.append({"tag": fn[:-5], "why": "片段读不了: %s" % e})
            continue
        ibs = frag.get("inbounds") or []
        if not ibs:
            continue                       # 00-base 这类基底不是节点
        # ★ tag 以**片段文件名**为准: 有 REALITY 前置的片段, inbounds[0]
        #   是前置 (tag 带 -front), 而分享元数据是按主节点的 tag 存的。
        tag = fn[:-5]
        meta = share_meta.load(a.share_dir, tag) or {}
        if not meta:
            # 协议脚本建的片段可能文件名与 tag 不一致, 再按入站 tag 试一次
            for ib in ibs:
                t = ib.get("tag") or ""
                if t and not t.endswith("-front"):
                    meta = share_meta.load(a.share_dir, t) or {}
                    if meta:
                        tag = t
                        break
        if not meta:
            skipped.append({"tag": tag, "why": "没有分享元数据 (没对外地址)"})
            continue
        try:
            p, why = to_mihomo.write_products(frag, meta, a.out_dir,
                                              name=meta.get("name"), tag=tag)
        except Exception as e:                                   # noqa: BLE001
            skipped.append({"tag": tag, "why": "生成失败: %s" % e})
            continue
        if not p:
            skipped.append({"tag": tag, "why": why or "生成不出来"})
            continue
        n_written += 1
        node = to_mihomo.node_from_fragment(frag, meta, name=meta.get("name"))
        pr = to_mihomo.proxy(node)
        if pr:
            proxies.append(pr)
        else:
            skipped.append({"tag": tag, "why": "YAML 有, 但整份配置里拼不出这条"})

    full = ""
    # 整份可运行配置: 客户端拿到直接 `mihomo -f` 就能跑, 不是一份片段。
    # 片段问题是"还要自己补 mixed-port / 组 / 规则", 而这三样最容易写错。
    if proxies:
        doc = {
            "mixed-port": int(a.mixed_port),
            "allow-lan": False,
            "mode": "rule",
            "log-level": "info",
            "proxies": proxies,
            "proxy-groups": [{"name": a.group, "type": "select",
                              "proxies": [p["name"] for p in proxies]}],
            "rules": ["MATCH,%s" % a.group],
        }
        full = os.path.join(a.out_dir, a.full_name)
        tmp = full + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(to_mihomo._dump(doc))
        os.replace(tmp, full)

    print(json.dumps({"nodes": n_written, "proxies": len(proxies),
                      "full": full, "skipped": skipped}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
