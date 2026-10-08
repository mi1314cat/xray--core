#!/usr/bin/env python3
"""幽灵函数检测 —— 从用户入口出发的可达性分析。

## 为什么要有这个检查

mihomo 的 dl_route 模块踩过一个坑, 值得记下来: dl_curl 定义在, 但全项目
零调用 —— 菜单让你设下载通道, 没有任何代码会去用; dl_route_set_* 忽略传进来
的 scope 参数, "内核下载单独设置"会覆盖全局; dl_route_get 不接 scope, 分项值
根本读不回来。

净效果比"没有这个功能"更糟: 用户设了、以为生效了, 其实没有。

"某个函数定义了但文件内只出现一次"是粗筛, 但对库文件不成立 —— 库里的函数
互相调用是正常的 (x_cert_gc 就要调 x_cert_in_use)。所以真正要问的是:
**从任何用户入口出发, 能不能走到它。**

判据: 入口脚本 (面板菜单里 curl 出去的那些) → source 链 → 函数调用,
可达即非幽灵。

用法: python3 tools/check_wiring.py [--verbose]
退出码 0 = 无幽灵。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FUNC_RE = re.compile(r'^([a-z_][a-z_0-9]*)\(\)', re.M)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def collect_shells():
    out = []
    for d in ("", "conf", "conf/fd", "conf/lib", "tools"):
        p = os.path.join(ROOT, d)
        if not os.path.isdir(p):
            continue
        for n in sorted(os.listdir(p)):
            if n.endswith(".sh"):
                out.append(os.path.join(p, n))
    return out


def main():
    verbose = "--verbose" in sys.argv
    files = collect_shells()
    texts = {f: read(f) for f in files}
    libdir = os.path.join(ROOT, "conf/lib")
    libs = [f for f in files if os.path.dirname(f) == libdir]

    # 函数定义 -> 所在文件
    defs = {}
    for f, t in texts.items():
        for fn in FUNC_RE.findall(t):
            defs.setdefault(fn, f)

    # source 边: 文件 -> 它 source 的库文件
    def sources_of(text):
        deps = set()
        for m in re.finditer(r'lib/([a-z_0-9]+\.sh)', text):
            cand = os.path.join(libdir, m.group(1))
            if os.path.isfile(cand):
                deps.add(cand)
        return deps

    edges = {f: sources_of(t) for f, t in texts.items()}

    def mentions(fn, path):
        """在 path 里引用 fn, 且排除纯定义行。"""
        t = texts.get(path, "")
        if not t:
            return False
        pat = re.compile(r'(?<![\w-])' + re.escape(fn) + r'(?![\w-])')
        hits = pat.findall(t)
        if path == defs.get(fn):
            # 定义文件: 出现多次才算被用到 (定义行本身算一次)
            return len(hits) > 1
        return bool(hits)

    # 用户入口
    panel = texts.get(os.path.join(ROOT, "xray-panel.sh"), "")
    entries = set()
    for m in re.finditer(r'([A-Za-z0-9_/.-]+\.sh)', panel):
        cand = os.path.join(ROOT, m.group(1))
        if os.path.isfile(cand) and cand in texts:
            entries.add(cand)
    # 注意: 库文件**不能**无条件当入口 —— 那样每个库都是入口, 库里任何函数
    # 都"可达", 检查就永远返回 0, 等于没有检查。
    # 只有被 tools/check_libs.sh 直接 source 的库才算入口。
    check_libs = texts.get(os.path.join(ROOT, "tools/check_libs.sh"), "")
    for m in re.finditer(r'\$LIB/([a-z_0-9]+\.sh)', check_libs):
        cand = os.path.join(libdir, m.group(1))
        if os.path.isfile(cand):
            entries.add(cand)

    reach = set()

    def walk(path, seen):
        if path in seen:
            return
        seen.add(path)
        reach.update(FUNC_RE.findall(texts.get(path, "")))
        for dep in edges.get(path, ()):
            walk(dep, seen)

    for e in sorted(entries):
        walk(e, set())

    lib_funcs = [fn for fn, f in defs.items() if f in libs and not fn.startswith("_")]
    ghosts = sorted(fn for fn in lib_funcs if fn not in reach)

    print(f"库函数 {len(lib_funcs)} 个, 从用户入口可达 "
          f"{len(lib_funcs) - len(ghosts)} 个, 不可达 {len(ghosts)} 个")
    for g in ghosts:
        print(f"  幽灵: {g}  ({os.path.basename(defs[g])})")
    if verbose:
        print("\n可达的库函数:")
        for fn in sorted(f for f in lib_funcs if f in reach):
            print(f"  ✓ {fn}")
    if ghosts:
        print("\n这些函数从任何用户入口都走不到 —— 定义了但没人用。")
        print("要么接上入口, 要么删掉。留着会让读代码的人以为它在生效。")
    return 1 if ghosts else 0


if __name__ == "__main__":
    sys.exit(main())
