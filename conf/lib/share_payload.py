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


def build_links(tags):
    """按 tag 从 conf/ 片段重建分享链接。

    返回 (lines, missing, nometa, bad):

      missing  tag 在注册表里、但 conf/ 片段已经没了 (节点被删)
      nometa   片段还在, 但缺对外地址/端口 —— 生成不出分享链接
      bad      片段本身解析不了

    三类都不是致命错误: 其余节点的订阅仍然有用, 全都丢掉反而更糟。
    但必须分开报出来 —— "分享了 4 个节点客户端只收到 1 个" 如果只给一个
    总数, 是节点被删了还是没配地址, 完全查不出来。
    """
    import nodes as nodereg

    node_list, bad = nodereg.collect(CONF_DIR)
    by_tag = {n["tag"]: n for n in node_list}

    lines, missing, nometa = [], [], []
    for t in tags:
        n = by_tag.get(t)
        if not n:
            missing.append(t)
            continue
        meta = share_meta.load(SHARE_DIR, t) or {}
        link = nodereg.build_share_link(n, meta)
        if link:
            lines.append(link)
        else:
            nometa.append(t)
    return lines, missing, nometa, bad


def build_payload(tags):
    """标准订阅格式: base64 的一行。

    绝大多数客户端 (含本项目自己的 Client) 都按 base64 订阅解析, 明文多行
    只是兼容项。
    """
    links, missing, nometa, bad = build_links(tags)
    if not links:
        return None, missing, nometa, bad
    text = "\n".join(links)
    return base64.b64encode(text.encode()).decode(), missing, nometa, bad
