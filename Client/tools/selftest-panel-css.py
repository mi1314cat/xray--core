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

    print("\n[6] 节点区重做：分段控件 / 分组行 / 拖放 / 批量条")
    # 连接方式是节点的属性，用分段控件表达；三内核里只有 X 有浏览器拨号，
    # 它值得一个专门的控件而不是混在一排按钮里。
    # 注意别先把空格去掉再找带空格的串 —— 上一版就是这么把自己绊倒的。
    ck(re.search(r"\.seg\s*\{", bare) is not None
       and re.search(r"\.seg\s+button\.on\s*\{", bare) is not None,
       "分段控件有样式（含选中态）")
    ck("data-side=\"normal\"" in page and "data-side=\"bd\"" in page,
       "分段控件两侧齐全（原生 / 浏览器）")
    ck("class=\"seg${canBD ? '' : ' na'}\"" in page or "seg${canBD" in page,
       "不可用的一侧会置灰（不是直接消失 —— 用户要看到能力边界）")
    # 延迟 pill：色点 + 三档类名
    ck(all(x in bare.replace(" ", "") for x in [".lat.ok{", ".lat.warn{", ".lat.bad{"]),
       "延迟 pill 三档配色齐全（沿用 300/800 阈值）")
    # 分组行：圆点 / 计数 / 操作按钮 / 拖放目标
    ck(".srow .gd{" in bare.replace(" ", "") or ".srow .gd{" in bare,
       "分组行有来源圆点")
    ck(".srow.dragover{" in bare.replace(" ", ""), "分组行有拖放高亮")
    ck("ondragover=\"groupDragOver" in page and "ondrop=\"groupDrop" in page,
       "分组行是拖放目标")
    ck('draggable="true"' in page and "nodeDragStart" in page, "节点行可拖拽")
    # ⋯ 菜单取代原来的裸 ✕（删除不可撤销，不该只有一个难发现的图标）
    ck("groupMenu(" in page and 'class="sa"' in page, "分组操作收进 ⋯ 菜单")
    ck("renameGroup(" in page and "group_rename" in page, "分组可重命名")
    ck("reorderGroup(" in page and "group_reorder" in page, "分组可排序")
    ck('id="bulkbar"' in page and "renderBulkbar" in page and "pickMoveTarget" in page,
       "批量条含「移动到分组」")
    ck("node_group_set" in page, "移动分组已进 DISPATCH")

    print("\n[7] 纯函数的产出标记（Node 实跑）")
    import shutil as _sh2
    import subprocess as _sp2
    if not _sh2.which("node"):
        print("  ⏭  没有 node，跳过")
    else:
        js_all = "\n".join(re.findall(r"<script>(.*?)</script>", page, re.S))
        harness = r"""
const js = require('fs').readFileSync(process.argv[2], 'utf8');
const grab = (n) => {
  let i = js.indexOf('const ' + n + ' = ');
  if (i >= 0) return js.slice(i, js.indexOf('\n', i));
  i = js.indexOf('function ' + n + '(');
  if (i < 0) return '';
  let d = 0, j = js.indexOf('{', i);
  for (let k = j; k < js.length; k++) {
    if (js[k] === '{') d++;
    else if (js[k] === '}') { d--; if (!d) return js.slice(i, k + 1); }
  }
  return '';
};
const src = ['ESC','escAttr','tagHtml','latText','useButtons'].map(grab).filter(Boolean).join('\n');
const fn = new Function('LAT','VIEW', src + '\nreturn {latText, useButtons};');
const out = [];
const ck = (c, m) => out.push((c ? 'OK ' : 'NO ') + m);
const base = (o) => Object.assign({file:'n.json', name:'n', compat:{protocol_may_dialer:true}, probe_ok:true}, o);

// 延迟 pill 五档
for (const [lat, want, why] of [
    [{}, 'class="lat"', '未测'],
    [{a:{loading:true}}, 'lat busy', '测试中'],
    [{a:{ok:true,ms:120}}, 'lat ok', '120ms 绿'],
    [{a:{ok:true,ms:500}}, 'lat warn', '500ms 黄'],
    [{a:{ok:true,ms:1200}}, 'lat bad', '1200ms 红'],
    [{a:{ok:false,msg:'超时'}}, 'lat bad', '失败 红']]) {
  const f = fn(lat, {sel:new Set(), density:'list'});
  ck(f.latText('a').includes(want), '延迟 ' + why);
}

// 分段控件：四种状态各高亮/禁用哪一侧
let f = fn({}, {sel:new Set(), density:'list'});
let h = f.useButtons(base({current:true, use_browser:false}));
ck(/data-side="normal" class="on"/.test(h), '当前+显式原生 → 原生侧高亮');
h = f.useButtons(base({current:true, use_browser:true}));
ck(/data-side="bd" class="on"/.test(h), '当前+显式浏览器 → 浏览器侧高亮');
h = f.useButtons(base({current:true}));
ck(/data-side="bd" class="on"/.test(h),
   '当前+未设(=auto)+协议支持 → 浏览器侧高亮（auto 的语义就是"支持就用"）');
h = f.useButtons(base({current:false}));
ck(!/class="on"/.test(h), '非当前 → 两侧都不高亮（点了才切过去）');
h = f.useButtons(base({compat:{protocol_may_dialer:false, dialer:{notes:['只有 vless 的 ws/xhttp 能走']}}}));
ck(h.includes('seg na') && /data-side="bd"[^>]*disabled/.test(h) && h.includes('只有 vless'),
   '协议不支持 → 浏览器侧禁用且带原因');
ck(!h.includes('>重测<'), '协议不支持时不给「重测」');
h = f.useButtons(base({probe_ok:false}));
ck(/data-side="bd"[^>]*disabled/.test(h) && h.includes('重测'),
   '实测失败 → 浏览器侧禁用 + 给「重测」');
ck(!f.useButtons(base({file:'a"b.json'})).includes('"a"b.json"'),
   '文件名里的引号被转义（否则 onclick 会被截断）');

require('fs').writeFileSync(process.argv[3], out.join('\n'));
"""
        import tempfile as _tf2
        # 后缀必须是 .cjs：夹具用的是 require，而 .mjs 是 ES 模块作用域，
        # require 在里面根本不存在（第一版就栽在这儿）。
        with _tf2.NamedTemporaryFile("w", suffix=".cjs", delete=False, encoding="utf-8") as fh:
            fh.write(harness)
            hpath = fh.name
        with _tf2.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as fh:
            fh.write(js_all)
            jpath = fh.name
        opath = hpath + ".out"
        r = _sp2.run(["node", hpath, jpath, opath], capture_output=True, text=True)
        if r.returncode != 0:
            ck(False, "Node 夹具能跑通", (r.stderr or "").strip().splitlines()[-1:] and
               (r.stderr or "").strip().splitlines()[-1] or "")
        else:
            lines = open(opath, encoding="utf-8").read().strip().splitlines()
            for ln in lines:
                ck(ln.startswith("OK "), "分段/延迟：" + ln[3:])
        for p_ in (hpath, jpath, opath):
            try:
                os.unlink(p_)
            except OSError:
                pass

    print("\n[8] 节点区新样式的对比度（本地计算，不依赖浏览器）")
    # 远端浏览器只看得到"页面跑起来了"，看不到"这两块颜色放一起能不能读"。
    # 新样式全部复用已验证的变量对，但**复用不等于没问题** —— 底色一变
    # （比如 --ov3 换 --ov2）对比度就跟着变。这里逐对算一遍。
    def _theme(block):
        return dict(re.findall(r"(--[\w-]+)\s*:\s*([^;}]+)", block))

    _d = re.search(r"^:root\{(.*?)\n\}", bare, re.S | re.M)
    _l = re.search(r':root\[data-theme="light"\]\{(.*?)\n\}', bare, re.S)
    if _d and _l:
        TD, TL = _theme(_d.group(1)), _theme(_l.group(1))

        def _parse(c):
            c = (c or "").strip()
            m = re.match(r"^#([0-9a-f]{6})$", c, re.I)
            if m:
                v = int(m.group(1), 16)
                return ((v >> 16) & 255, (v >> 8) & 255, v & 255, 1.0)
            # ★ 三位写法（#fff）必须认 —— 第一版漏了它，于是"当前节点高亮"
            #   那一对直接被判成解析失败。
            m = re.match(r"^#([0-9a-f]{3})$", c, re.I)
            if m:
                h = m.group(1)
                return (int(h[0] * 2, 16), int(h[1] * 2, 16), int(h[2] * 2, 16), 1.0)
            m = re.match(r"rgba?\(([^)]+)\)", c)
            if m:
                p = [float(x) for x in m.group(1).split(",")]
                return (p[0], p[1], p[2], p[3] if len(p) > 3 else 1.0)
            return None

        def _over(f, b):
            a = f[3]
            return (f[0] * a + b[0] * (1 - a), f[1] * a + b[1] * (1 - a),
                    f[2] * a + b[2] * (1 - a), 1.0)

        def _lum(c):
            g = lambda v: (v / 255) / 12.92 if (v / 255) <= .03928 else (((v / 255) + .055) / 1.055) ** 2.4
            return .2126 * g(c[0]) + .7152 * g(c[1]) + .0722 * g(c[2])

        def _cr(a, b):
            la, lb = _lum(a), _lum(b)
            hi, lo = max(la, lb), min(la, lb)
            return (hi + .05) / (lo + .05)

        PAIRS = [("分段控件·选中", "--on-acc", "--acc-btn", "--acc-btn"),
                 ("分段控件·未选中", "--dim", "--ov0", "--card"),
                 ("延迟 pill·快", "--ok-text", "--ok-bg", "--card"),
                 ("延迟 pill·中", "--warn-text", "--warn-bg", "--card"),
                 ("延迟 pill·慢", "--bad-text", "--bad-bg", "--card"),
                 ("分组计数徽标", "--dim", "--ov2", "--card"),
                 ("分组行·选中名", "--fg", "--acc-bg2", "--card"),
                 ("批量条文字", "--fg", "--acc-bg", "--card"),
                 ("分组菜单·危险", "--bad-text", "--modal-bg", "--modal-bg"),
                 # 应用外壳（版式重构新增）
                 ("顶栏 chip 文字", "--dim", "--ov0", "--bg"),
                 # 侧栏底 = --ov0 叠在页面 --bg 上。上一版把 base 也写成
                 # --ov0，等于叠了两层，合成出一个浅底 —— 于是"选中态"算出
                 # 1.04:1 这种不可能的数字。基准链错一层，结论就完全反了。
                 ("侧栏导航·未选中", "--dim", "--ov0", "--bg"),
                 ("侧栏导航·选中", "--fg", "--acc-bg2", "--bg"),
                 ("品牌方块文字", "--on-acc", "--acc-btn", "--acc-btn")]
        bad_pairs = []
        for label, fgv, bgv, basev in PAIRS:
            for tname, T in (("深色", TD), ("浅色", TL)):
                fg, bg, base = (_parse(T.get(fgv)), _parse(T.get(bgv)),
                                _parse(T.get(basev)))
                if not (fg and bg and base):
                    bad_pairs.append("%s/%s 解析失败" % (tname, label))
                    continue
                b = _over(bg, base)
                r = _cr(_over(fg, b), b)
                if r < 4.5:
                    bad_pairs.append("%s/%s=%.2f:1" % (tname, label, r))
        ck(not bad_pairs, "节点区新样式的配色对全部 ≥4.5:1（两套主题）",
           "; ".join(bad_pairs[:4]))
    else:
        ck(False, "能取出两套主题变量")

    print("\n[9] 版式：应用式而不是文章式")
    # 这一组是版式重构的**硬约束**。用户的原话是"不要设置一个很小的 max-width
    # 把整个应用限制成文章宽度" —— 所以这里直接断言"不存在居中的窄容器"，
    # 而不是靠人记得别加回去。
    ck(re.search(r"\.app\s*\{[^}]*display:\s*grid", bare) is not None,
       "应用外壳用 grid 布局")
    ck(re.search(r"\.app\s*\{[^}]*grid-template-columns:\s*212px", bare) is not None,
       "左栏固定宽度 + 主区自适应")
    ck(".wrap" not in re.sub(r"/\*.*?\*/", "", bare, flags=re.S).split("@media")[0]
       or re.search(r"\.wrap\s*\{[^}]*max-width", bare) is None,
       "没有 .wrap 居中窄容器")
    # 主区不得再设 max-width（只允许 pre/hint 这类文字块限宽）
    m = re.search(r"\.main\s*\{([^}]*)\}", bare)
    ck(m is not None and "max-width" not in m.group(1),
       "主工作区不设宽度上限（桌面端吃满屏宽）")
    ck(re.search(r"\.card pre[^{]*\{[^}]*max-width", bare) is not None,
       "改由文字块自己限宽（可读性不靠缩小整个应用）")
    ck(re.search(r"\.view\s*\{[^}]*display:\s*none", bare) is not None
       and re.search(r"\.view\.on\s*\{[^}]*display:\s*block", bare) is not None,
       "视图切换：同一时刻只显示一个")
    ck(re.search(r"\.nav button\.on\s*\{", bare) is not None,
       "侧栏导航有选中态")
    ck(re.search(r"\.chip\s*\{", bare) is not None, "顶栏状态 chip 有样式")
    ck('id="view-nodes"' in page and 'id="view-status"' in page
       and 'id="view-config"' in page and 'id="view-core"' in page,
       "四个视图都在")
    ck('class="app"' in page and 'class="side"' in page and 'class="main"' in page,
       "应用外壳三件套齐（app / side / main）")
    # 桌面优先：窄屏才塌成顶部导航
    ck(re.search(r"@media\(max-width:900px\)\{[^}]*\.app\s*\{[^}]*grid-template-columns:1fr",
                 bare, re.S) is not None,
       "窄屏（≤900px）才把侧栏收成顶部条")

    print("\n[10] 内联 JS 语法")
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

    print("\n[11] 页面骨架")
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
