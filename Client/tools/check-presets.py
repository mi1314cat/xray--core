#!/usr/bin/env python3
"""预设合法性检查：面板「添加节点」里的每个预设，都拿 compat.check_xray 验一遍。

为什么值得单独一个脚本：预设是"服务端实际会生成的那几种形状"的抄本，
写错一个组合（比如 reality + ws）的后果不是"这个预设不好用"，而是**选中它
之后整份配置构建失败** —— 而面板上看起来完全正常。

和导入一条真实节点走的是同一套判定函数，所以这里绿了，等于"预设至少不会
生成一个内核拒绝的节点"。
"""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "Client", "lib"))
sys.path.insert(0, os.path.join(ROOT, "Client", "lib", "web"))


def load_panel():
    spec = importlib.util.spec_from_file_location(
        "panel_under_test", os.path.join(ROOT, "Client", "lib", "web", "panel.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    import compat
    panel = load_panel()
    bad = []
    for p in panel.ADD_PRESETS:
        node = {"protocol": p["proto"], "address": "x.example", "port": 443,
                "transport": p.get("transport", "tcp"),
                "security": p.get("security", "none"),
                "uuid": "u" * 8, "password": "pw", "method": p.get("method", ""),
                "flow": p.get("flow", ""), "fingerprint": p.get("fingerprint", ""),
                "reality_public_key": "PBK" if p.get("security") == "reality" else ""}
        # ★ 判定值必须用 compat 自己的常量比较（"NOT_SUPPORTED"），
        #   第一版这里写的是字面量 "NO" —— 永远不匹配，于是**每个预设都通过**，
        #   连故意写的 reality+ws 非法组合也照样绿。静默失效的守卫比没有更糟。
        no = [c["item"] for c in compat.check_xray(node)["checks"]
              if c["verdict"] == compat.NO]
        if no:
            bad.append("%s(%s/%s/%s): %s" % (
                p["id"], p["proto"], p.get("transport", "tcp"),
                p.get("security", "none"), ",".join(no)))
    if bad:
        print("BAD " + "; ".join(bad))
        return 1
    print("OK")


if __name__ == "__main__":
    sys.exit(main())
