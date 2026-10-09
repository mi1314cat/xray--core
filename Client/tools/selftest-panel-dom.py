#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""面板的 DOM 级自检 —— 用 jsdom 真跑一遍页面的 JS。

和 selftest-panel-css.py 的分工：

  · selftest-panel-css.py  验**字符串**（样式/标记在不在、JS 语法对不对）
  · 本文件                 验**行为**：把页面放进真实 DOM 跑一遍，然后断言
                           分段控件高亮哪一侧、拖放属性有没有、批量条出现时机、
                           分组菜单能不能弹出、有没有运行时错误

为什么必须有一层 DOM 级：字符串检查全部通过、JS 语法也通过，仍然可能出现
"点了没反应" —— 比如某个 id 拼错、某个函数在 DOM 上取到 null。这类问题
静态检查一个都抓不到。

依赖 jsdom（可选）。没装就跳过，不阻塞其他人：

    npm install jsdom            # 在仓库根或任一上级目录
    XBD_JSDOM=/path/to/node_modules python3 selftest-panel-dom.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

PASS = 0
FAIL = 0
SKIP = 0


def ck(cond, what, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ✅ %s" % what)
    else:
        FAIL += 1
        print("  ❌ %s%s" % (what, ("  ← " + detail) if detail else ""))


def find_jsdom():
    """找 jsdom 的 node_modules。允许用环境变量指定。"""
    cands = [os.environ.get("XBD_JSDOM", "")]
    cands += [
        os.path.join(REPO, "node_modules"),
        "/tmp/node_modules",          # npm 在 /tmp 下装的时候会落在这儿
        "/tmp/domtest/node_modules",
        "/usr/lib/node_modules",
    ]
    # 从仓库往上找几层
    d = REPO
    for _ in range(4):
        cands.append(os.path.join(d, "node_modules"))
        d = os.path.dirname(d)
    for c in cands:
        if c and os.path.isdir(os.path.join(c, "jsdom")):
            return c
    return None


HARNESS = r"""
const fs = require('fs'), path = require('path');
const { JSDOM } = require(path.join(process.argv[3], 'jsdom'));

const html = fs.readFileSync(process.argv[2], 'utf8');
const out = [];
const ck = (c, m) => out.push((c ? 'OK ' : 'NO ') + m);

const dom = new JSDOM(html, {runScripts: 'dangerously', pretendToBeVisual: true,
                             url: 'http://localhost/'});
const w = dom.window, d = w.document;
const errs = [];
w.addEventListener('error', e => errs.push(e.message));

// 视图选择器：三种密度各有各的行元素，表头 <TR> 不是节点行 ——
// 第一版把 `#node-list tr` 也算进去，于是"9 行里 8 行有分段控件"，
// 白白报了一个不存在的 bug。表头在 thead 里，用 tbody 限定。
const ROWS = '#node-list .nrow, #node-list .ncard, #node-list tbody tr';

setTimeout(() => {
  const $ = s => d.querySelector(s);
  const $$ = s => [...d.querySelectorAll(s)];

  const rows = $$(ROWS);
  ck(rows.length >= 8, '节点行渲染出来了 (' + rows.length + ')');

  // 分段控件：每个节点行一个，两侧齐全，当前节点有一侧高亮
  const segs = $$('#node-list .seg');
  ck(segs.length === rows.length,
     '每个节点行都有分段控件 (' + segs.length + '/' + rows.length + ')');
  ck(segs.every(s => s.querySelector('[data-side="normal"]')
                  && s.querySelector('[data-side="bd"]')), '分段控件两侧齐全');
  ck($$('.seg button.on').length >= 1, '当前节点有一侧高亮');
  // 不可用的那一侧必须**保留但禁用**，而不是消失 —— 用户要看到能力边界
  const na = $$('.seg.na');
  ck(na.length >= 1, '有节点标出"不能走浏览器" (' + na.length + ')');
  ck(na.every(s => s.querySelector('[data-side="bd"]').disabled),
     '不可用侧的按钮确实被禁用（且仍在，不消失）');

  // 分组行：圆点 / 计数 / ⋯ 菜单 / 拖放目标
  const srows = $$('.srow');
  ck(srows.length >= 4, '分组行 ' + srows.length + ' 条（全部 + 各分组）');
  ck(srows.every(r => r.querySelector('.gd')), '每条分组行都有来源圆点');
  ck(srows.every(r => r.querySelector('.sc')), '每条分组行都有计数');
  ck(srows.slice(1).every(r => r.querySelector('.sa')), '各分组都有 ⋯ 操作按钮');
  ck(srows.every(r => r.getAttribute('ondrop')), '分组行都是拖放目标');

  // 拖拽
  ck($$('#node-list [draggable="true"]').length === rows.length,
     '所有节点行可拖拽');

  // 延迟 pill
  ck($$('#node-list .lat').length === rows.length, '每行都有延迟 pill');

  // 批量条：勾选前后
  const bar = $('#bulkbar');
  ck(bar && !bar.classList.contains('on'), '未勾选时批量条隐藏');
  const cb = $('#node-list .sel');
  cb.checked = true;
  cb.dispatchEvent(new w.Event('change'));
  ck(bar.classList.contains('on'), '勾选后批量条出现');
  ck($('#bulk-n').textContent === '1', '批量条计数正确');
  const mv = $('#bulk-move');
  ck(mv.options.length >= 4, '「移动到分组」列出了各分组 (' + mv.options.length + ')');
  ck($$('#bulk-move option').slice(1).every(o => o.value),
     '每个可移动目标都有真实的组 key');
  // 收尾：取消勾选，避免影响后面的断言
  cb.checked = false;
  cb.dispatchEvent(new w.Event('change'));
  ck(!bar.classList.contains('on'), '取消勾选后批量条收起');

  // 分组菜单
  srows[1].querySelector('.sa').dispatchEvent(new w.MouseEvent('click', {bubbles: true}));
  const pop = $('#gpop');
  ck(!!pop, '点 ⋯ 弹出分组菜单');
  if (pop) {
    const t = pop.textContent;
    ck(['重命名', '上移', '下移', '删除'].every(x => t.includes(x)),
       '菜单含重命名/上移/下移/删除');
    w.closeGroupMenu();
    ck(!$('#gpop'), '菜单可关闭');
  }

  // 就地重命名
  w.renameGroup(srows[1].getAttribute('data-key'), '组A');
  ck(!!$('.srow.renaming input.grename'), '重命名进入就地编辑态');

  // 三种密度都要能渲染（同一份标记在三个视图里都要成立）
  for (const dens of ['list', 'grid', 'table']) {
    try {
      w.setDensity(dens);
      const r2 = $$(ROWS);
      ck(r2.length === rows.length && r2.every(r => r.querySelector('.seg')),
         '切到「' + dens + '」视图后仍是每行都有分段控件 (' + r2.length + ')');
    } catch (e) {
      ck(false, '切到「' + dens + '」视图', String(e).slice(0, 60));
    }
  }

  ck(errs.length === 0, '页面无 JS 运行时错误' +
     (errs.length ? ': ' + errs.join(' | ') : ''));

  fs.writeFileSync(process.argv[4], out.join('\n'));
  // ★ 必须显式退出：面板里有 setInterval(load, 5000) 做轮询，jsdom 的
  //   事件循环会一直活着，node 永不返回 —— 第一版就是这么超时 180 秒的。
  process.exit(0);
}, 1000);
"""


def main():
    global SKIP
    if not shutil.which("node"):
        print("没有 node，跳过 DOM 自检"); return 0
    jsdom = find_jsdom()
    if not jsdom:
        print("没有 jsdom，跳过 DOM 自检")
        print("  装法: npm install jsdom   （或用 XBD_JSDOM 指向 node_modules）")
        return 0

    # 复用渲染夹具：它会把 fetch 换成合成数据，并注入样式探针
    tmp = tempfile.mkdtemp(prefix="xbd-dom-")
    r = subprocess.run([sys.executable, os.path.join(HERE, "render-panel.py"), tmp],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("生成夹具失败:", (r.stderr or r.stdout).strip()[-300:]); return 1
    fixture = os.path.join(tmp, "panel.html")

    hpath = os.path.join(tmp, "h.cjs")
    opath = os.path.join(tmp, "out.txt")
    open(hpath, "w", encoding="utf-8").write(HARNESS)
    print("面板 DOM 自检  (jsdom: %s)" % jsdom)
    r = subprocess.run(["node", hpath, fixture, jsdom, opath],
                       capture_output=True, text=True, timeout=180)
    if r.returncode != 0 and not os.path.exists(opath):
        print("jsdom 夹具失败:", (r.stderr or "").strip()[-500:]); return 1
    for ln in open(opath, encoding="utf-8").read().strip().splitlines():
        ck(ln.startswith("OK "), ln[3:])
    shutil.rmtree(tmp, ignore_errors=True)

    print("\n结果：%d 通过 / %d 失败" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
