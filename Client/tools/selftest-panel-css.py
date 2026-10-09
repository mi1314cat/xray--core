#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""面板页面（PAGE）的结构自检。

这个文件存在的理由很具体：面板样式全靠手写 CSS 字符串，而字符串里的
结构性错误**不会报错** —— CSS 解析器遇到无法理解的东西会一路丢到下一个
`}`，页面照常渲染，只是悄悄少了一条规则。之前就真的发生过两次：

  1) 一次批量变量替换把 `--acc2:#5aa0ff` 改成了 `--acc2:var(--acc2)`，
     15 个变量变成自引用；浏览器不报错，界面直接失去配色。
  2) 一条规则的选择器整行丢失（引入它的提交里就已损坏），只剩孤立的
     `background:...}` 悬在样式表顶层，被解析器静默丢弃。

两种情况都能被下面的检查抓到，所以检查本身要跑在每次改动之后。
"""
import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PANEL = os.path.join(HERE, os.pardir, "lib", "web", "panel.py")

PASS = 0
FAIL = 0


def ck(cond, what, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ✅ %s" % what)
    else:
        FAIL += 1
        print("  ❌ %s%s" % (what, ("  ← " + detail) if detail else ""))


def load_page():
    """从 panel.py 里取出 PAGE 字面量。

    用 ast 而不是 import —— panel.py 导入时会做依赖探测，自检不该有副作用。
    """
    src = open(PANEL, encoding="utf-8").read()
    tree = ast.parse(src)
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "PAGE":
                    return node.value.value
    raise SystemExit("panel.py 里找不到 PAGE 赋值")


def style_and_script(page):
    m = re.search(r"<style>(.*?)</style>", page, re.S)
    css = m.group(1) if m else ""
    m2 = re.search(r"<script>(.*?)</script>", page, re.S)
    js = m2.group(1) if m2 else ""
    return css, js


def strip_comments(css):
    """去掉 /* ... */，但保留长度以便报行号。"""
    out = []
    i = 0
    while i < len(css):
        if css.startswith("/*", i):
            j = css.find("*/", i + 2)
            j = len(css) if j < 0 else j + 2
            out.append(" " * (j - i))
            i = j
        else:
            out.append(css[i])
            i += 1
    return "".join(out)


def walk_rules(css):
    """返回 (选择器, 声明体, 起始偏移) 与顶层残留片段。

    只做括号配对，不实现完整 CSS 语法 —— 够用了：能抓住"选择器丢了"和
    "括号不配对"这两类真实事故。
    """
    rules, strays = [], []
    i, n = 0, len(css)
    buf_start = None
    while i < n:
        c = css[i]
        if c == "{":
            sel = css[buf_start if buf_start is not None else 0:i].strip()
            depth, j = 1, i + 1
            while j < n and depth:
                if css[j] == "{":
                    depth += 1
                elif css[j] == "}":
                    depth -= 1
                j += 1
            rules.append((sel, css[i + 1:j - 1], i))
            i = j
            buf_start = i
        elif c == "}":
            tail = css[buf_start if buf_start is not None else 0:i].strip()
            if tail:
                strays.append(tail)
            i += 1
            buf_start = i
        else:
            i += 1
    tail = css[buf_start:].strip() if buf_start is not None else ""
    return rules, strays, tail


def main():
    page = load_page()
    css, js = style_and_script(page)
    print("面板页面自检  (panel.py, PAGE %d 字节)" % len(page))

    print("\n[1] 样式表结构")
    ck(css.count("{") == css.count("}"),
       "花括号配对", "%d 个 { vs %d 个 }" % (css.count("{"), css.count("}")))
    bare = strip_comments(css)
    rules, strays, tail = walk_rules(bare)
    ck(not strays, "没有顶层孤立声明（丢失选择器的残留）",
       " | ".join(s[:60] for s in strays[:3]))
    ck(not tail, "样式表结尾没有悬挂文本", tail[:60])
    ck(len(rules) > 60, "规则数量合理（%d 条）" % len(rules))

    print("\n[2] 变量定义完整且不自引用")
    root_defs = {}
    for sel, body, _ in rules:
        if ":root" in sel or sel.startswith("@media") or sel.startswith(":root["):
            for k, v in re.findall(r"(--[\w-]+)\s*:\s*([^;}]+)", body):
                root_defs.setdefault(k, []).append(v.strip())
    selfref = [(k, v) for k, vs in root_defs.items() for v in vs
               if v == "var(%s)" % k]
    ck(not selfref, "没有 var(--x) 自引用变量",
       ", ".join("%s:%s" % kv for kv in selfref[:5]))
    ck(len(root_defs) >= 30, "定义的变量数 >= 30（实际 %d）" % len(root_defs))

    # 用到的变量必须有定义，否则该属性会整条失效（静默）。
    used = set(re.findall(r"var\((--[\w-]+)\)", bare))
    undefined = sorted(used - set(root_defs))
    ck(not undefined, "所有 var() 都有定义", ", ".join(undefined[:8]))

    # 深色/浅色两套必须覆盖同一批变量，缺一个就会出现"浅色下某处仍是深色"。
    dark = set()
    for sel, body, _ in rules:
        if sel.strip() == ":root":
            dark |= set(re.findall(r"(--[\w-]+)\s*:", body))
    light = set()
    for sel, body, _ in rules:
        s = sel.strip()
        if s.startswith(':root[data-theme="light"]') or (
                s.startswith("@media") and "light" in s):
            light |= set(re.findall(r"(--[\w-]+)\s*:", body))
    missing = sorted(dark - light)
    ck(not missing, "浅色主题覆盖了深色主题的全部变量",
       "缺 " + ", ".join(missing[:8]))

    print("\n[3] 主题切换")
    ck("btn-theme" in page, "header 里有主题按钮")
    ck("themeCycle" in js, "定义了 themeCycle()")
    ck("xray-panel-theme" in js, "主题选择写入了 localStorage")
    # 三态循环：跟随系统 → 浅色 → 深色 → 跟随系统
    ck("'light'" in js and "'dark'" in js and "removeAttribute" in js,
       "三态循环（跟随系统/浅色/深色）")
    head_js = page.find("<script>")
    body = page.find("<body>")
    ck(0 <= head_js < body, "主题脚本在 <body> 之前执行（避免刷新闪白）")
    ck('document.addEventListener(\'DOMContentLoaded\'' in js,
       "DOM 就绪后重刷按钮图标")
    # 换肤瞬间必须关掉过渡：否则 color 与 background 同时渐变、在中点相交，
    # 文字和底色亮度相等，界面糊约 60ms（探针量到过 1.03:1）。
    # 选择器是一组（* / *::before / *::after），所以不写成"紧跟左花括号"的正则，
    # 而是确认同一条规则里既有 theme-switching 又有 transition:none!important。
    ts_rule = re.search(r"[^}]*theme-switching[^{]*\{([^}]*)\}", bare)
    ck(ts_rule is not None and "transition:none" in ts_rule.group(1).replace(" ", ""),
       "CSS 提供了 .theme-switching 关闭过渡")
    ck("classList.add('theme-switching')" in js and "offsetHeight" in js,
       "apply() 换肤时挂类 + 强制重排")

    print("\n[4] 打磨层")
    for what, pat in [("过渡", r"transition:background-color"),
                      ("卡片阴影", r"\.card\{box-shadow:var\(--shadow\)\}"),
                      ("表头吸顶", r"thead th\{position:sticky"),
                      ("键盘焦点环", r":focus-visible"),
                      ("滚动条跟随主题", r"::-webkit-scrollbar-thumb"),
                      ("尊重减少动态效果", r"prefers-reduced-motion")]:
        ck(re.search(pat, bare) is not None, what)

    print("\n[5] 面板接线：HTML 的 id 与 JS 引用对得上")
    # 这类错只会在浏览器里暴露成 "Cannot read properties of null"，
    # 而页面主体照常渲染 —— 静态检查能提前抓住。
    ids = set(re.findall(r'id="([\w-]+)"', page))
    used = set(re.findall(r"\$\('([\w-]+)'\)", page))
    missing = sorted(used - ids)
    ck(not missing, "JS 引用的 id 都在 HTML 里定义", ", ".join(missing[:6]))
    # onXXX 里调用的函数：普通函数 + 箭头函数两种写法都要认
    handlers = set(re.findall(r'on\w+="(\w+)\(', page))
    fns = (set(re.findall(r'function (\w+)', page))
           | set(re.findall(r'window\.(\w+)\s*=', page))
           | set(re.findall(r'const (\w+)\s*=', page)))
    undef = sorted(h for h in handlers if h not in fns)
    ck(not undef, "onXXX 调用的函数都有定义", ", ".join(undef[:6]))
    # 新增的地址族开关：面板与 core.sh 的白名单必须一致
    ck('id="family-mode"' in page and "setFamily" in page,
       "出站地址族下拉框已接线")
    ck("family_set" in page, "family_set 已进 DISPATCH")

    print("\n[6] 内联 JS 语法")
    # ★ 这一条是补一个真实盲区：页面的 JS 全拼在字符串里，此前**没有任何东西
    #   检查它的语法** —— CSS 有括号配对检查，JS 没有。一次重复的 const 声明
    #   就能让整个面板的脚本静默失效（页面照常渲染，只是所有按钮都没反应）。
    import shutil as _sh
    import subprocess as _sp
    import tempfile as _tf
    blocks = re.findall(r"<script>(.*?)</script>", page, re.S)
    if _sh.which("node"):
        with _tf.NamedTemporaryFile("w", suffix=".js", delete=False,
                                    encoding="utf-8") as fh:
            fh.write("\n;\n".join(blocks))
            jspath = fh.name
        r = _sp.run(["node", "--check", jspath], capture_output=True, text=True)
        os.unlink(jspath)
        ck(r.returncode == 0,
           "内联 JS 语法通过（%d 个 script 块）" % len(blocks),
           (r.stderr or "").strip().splitlines()[0] if r.returncode else "")
    else:
        print("  ⏭  没有 node，跳过 JS 语法检查")

    print("\n[7] 页面骨架")
    ck(page.lstrip().startswith("<!DOCTYPE html>"), "以 DOCTYPE 开头")
    ck(page.count("<style>") == 1 and page.count("</style>") == 1,
       "只有一段 <style>")
    for tag in ("html", "head", "body"):
        ck(page.count("<%s" % tag) >= 1 and ("</%s>" % tag) in page,
           "<%s> 开闭配对" % tag)
    ck('name="viewport"' in page, "声明了 viewport（手机可用）")
    ck("data-theme" in page and ":root[data-theme=\"light\"]" in page,
       "CSS 与 JS 用同一个 data-theme 约定")

    print("\n结果：%d 通过 / %d 失败" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
