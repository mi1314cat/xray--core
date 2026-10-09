#!/usr/bin/env python3
"""节点列表渲染：显示两种使用方式的能力，而不是只给一个模糊状态。"""
from __future__ import annotations

import json
import os
import sys

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")

LABEL = {
    "SUPPORTED": "支持",
    "SUPPORTED_WITH_WARNING": "支持!",
    "NOT_SUPPORTED": "不支持",
    "UNKNOWN": "未知",
}


def load_compat_module():
    path = os.path.join(PREFIX, "xbd-dist", "lib", "compat.py")
    import importlib.util
    spec = importlib.util.spec_from_file_location("_xbd_compat", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def observatory_health(nodes: list) -> dict:
    """{节点文件名: {"alive":..., "delay_ms":...}} —— 读不到就返回 {}。

    数据来自 metrics 的 GET /debug/vars（官方文档化的那条路）。

    ★ 三点必须说清楚, 否则 UI 会骗人:
      · 只有**多出站模式**才有观测器。单节点模式读不到数据 —— 那是"没有观测",
        不是"全部离线", 所以返回空 dict 让调用方显示"未观测"。
      · 观测是按**出站 tag** 给的, 而 tag 由文件名派生(tag_for)。这里用
        genconfig 落盘的 tags 映射回文件名, 而不是自己猜命名规则 ——
        猜错会把 A 的延迟显示在 B 那一行。
      · 没被 subjectSelector 覆盖的出站**不在结果里**, 同样显示"未观测"。
    """
    import importlib.util

    # 端口以**生成的配置**为准 (genconfig 会挑一个确认空闲的, 不是固定值)
    cfg_path = os.path.join(PREFIX, "runtime", "xray-client.json")
    port = None
    try:
        cfg = json.load(open(cfg_path, encoding="utf-8"))
        listen = ((cfg.get("metrics") or {}).get("listen") or "")
        if ":" in listen:
            port = int(listen.rsplit(":", 1)[1])
    except Exception:
        return {}
    if not port:
        return {}

    spec = importlib.util.spec_from_file_location(
        "_xbd_api", os.path.join(PREFIX, "xbd-dist", "lib", "xrayapi.py"))
    if spec is None:
        return {}
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception:
        return {}
    obs = mod.observatory_status(port)
    if not obs:
        return {}

    # tag -> 文件名：读 genconfig 落盘的 sidecar，**不自己猜命名规则**。
    # 猜错会把 A 的延迟显示在 B 那一行，而且看不出来。
    # sidecar 只在多出站模式写 —— 恰好也是唯一有观测器的模式。
    tag2file = {}
    try:
        gen = json.load(open(os.path.join(PREFIX, "runtime", "xray-gen.json"),
                             encoding="utf-8"))
        for fname, tag in (gen.get("tags") or {}).items():
            tag2file[tag] = fname
    except Exception:
        return {}

    out = {}
    for tag, v in obs.items():
        f = tag2file.get(tag)
        if f:
            out[f] = v
    return out


def main() -> int:
    state_py = os.path.join(PREFIX, "xbd-dist", "lib", "state.py")
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("_xbd_state", state_py)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        nodes = mod.nodes_dir()[0]
    except Exception as exc:
        print(f"  读取节点失败: {exc}", file=sys.stderr)
        return 1

    if not nodes:
        print('  还没有节点。用: xbd node add "<uri>"')
        return 1

    # 判定一律**实时计算**，不用文件里可能过期的 _compat 缓存。
    # 为什么：缓存是导入那一刻写下的，之后 Xray 升级或判定逻辑改了它不会更新 ——
    # 于是两个内容完全相同的节点会一个显示"支持"、一个显示"不支持"（实测踩过），
    # 而被信以为真的恰恰是那个错的旧值。
    compat_mod = None
    for n in nodes:
        try:
            if compat_mod is None:
                compat_mod = load_compat_module()
            path = os.path.join(PREFIX, "nodes", n["file"])
            n["compat"] = compat_mod.check_all(json.load(open(path)))
        except Exception:
            n["compat"] = {}

    health = observatory_health(nodes)
    head = (f'{"#":<4}{"":<3}{"名称":<30}{"协议":<13}{"传输":<11}'
            f'{"健康":<12}{"Xray":<11}Browser Dialer')
    print("  " + head)
    print("  " + "-" * (len(head) - 6))
    for i, n in enumerate(nodes, 1):
        caps = n.get("compat") or {}
        x = (caps.get("xray") or {}).get("overall", "UNKNOWN")
        b = (caps.get("dialer") or {}).get("overall", "UNKNOWN")
        mark = "*" if n.get("current") else " "
        name = (n.get("name") or "?")[:28]
        h = health.get(n.get("file") or "")
        if not health:
            ht = "未观测"          # 单节点模式 / 读不到 metrics：不是"离线"
        elif h is None:
            ht = "未观测"          # 没被观测器覆盖
        elif h.get("alive") is False:
            ht = "离线"
        elif h.get("delay_ms") is not None:
            ht = f'{h["delay_ms"]} ms'
        else:
            ht = "在线"
        print(f'  {i:<4}{mark:<3}{name:<30}{n.get("protocol",""):<13}'
              f'{n.get("transport",""):<11}{ht:<12}{LABEL.get(x,x):<11}{LABEL.get(b,b)}')
    print("  (* = 当前节点)")
    if not health:
        print("  （健康列需要多出站模式：单节点模式没有观测器）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
