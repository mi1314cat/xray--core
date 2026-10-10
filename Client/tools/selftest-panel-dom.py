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

setTimeout(async () => {
  const $ = s => d.querySelector(s);
  const $$ = s => [...d.querySelectorAll(s)];

  const rows = $$(ROWS);
  ck(rows.length >= 8, '节点行渲染出来了 (' + rows.length + ')');

  // ---- 应用外壳：文章式 → Dashboard 式 ----
  // 这一组是版式重构的验收点。最要紧的一条：**不再有窄居中容器** ——
  // 原来是 `.wrap{max-width:1100px;margin:0 auto}`，那是博客的版式。
  ck(!d.querySelector('.wrap'), '没有 .wrap 窄居中容器了');
  ck(!!$('.app') && !!$('.app > .side') && !!$('.app > .main'),
     '应用外壳 = 左侧导航 + 主工作区');
  const views = $$('.view');
  ck(views.length === 5, '5 个视图（节点/状态/分享/配置/内核）(' + views.length + ')');
  // ★ 视图必须在主工作区**里面**。这一条是事故后补的：多一个 </div> 会让浏览器
  //   提前闭合 <main>，配置页/内核页就跑到外壳外面去了 —— 症状是"点配置一片空白，
  //   内容在页面很下面"，而"有 4 个 .view"这种数量断言照样全绿。
  //   jsdom 用的是和浏览器同一套 HTML5 解析，所以这条能真的抓到。
  ck($$('.main > .view').length === 5,
     '5 个视图都在 .main 里 (' + $$('.main > .view').length + ')');
  const stray = views.filter(v => !v.closest('.main')).map(v => v.id);
  ck(stray.length === 0, '没有视图掉到应用外壳外面' +
     (stray.length ? ': ' + stray.join(',') : ''));
  ck(views.filter(v => v.classList.contains('on')).length === 1,
     '同一时刻只显示一个视图');
  const navBtns = $$('#nav button');
  ck(navBtns.length === 5, '侧栏 5 个导航项');
  ck(navBtns.filter(b => b.classList.contains('on')).length === 1,
     '侧栏只有一项处于选中态');
  ck(navBtns.filter(b => b.classList.contains('on'))[0]
     .getAttribute('data-view') === 'nodes', '默认停在节点视图');
  ck(!!$('#view-title') && $('#view-title').textContent === '节点',
     '顶栏标题跟着视图 (' + ($('#view-title') || {}).textContent + ')');

  // 切换视图：视图与导航必须同步（不同步就会出现"标题写着状态、内容是节点"）
  w.go('status');
  const onNow = $$('.view').filter(v => v.classList.contains('on'));
  ck(onNow.length === 1 && onNow[0].id === 'view-status', 'go(status) 切到状态视图');
  ck($('#view-title').textContent === '状态', '标题同步');
  ck(navBtns.filter(b => b.classList.contains('on'))[0]
     .getAttribute('data-view') === 'status', '导航高亮同步');
  w.go('nodes');
  ck($$('.view').filter(v => v.classList.contains('on'))[0].id === 'view-nodes',
     'go(nodes) 切回来');

  // 顶栏状态 chips + 侧栏计数
  const chips = $$('#top-chips .chip');
  ck(chips.length >= 2, '顶栏有状态 chips (' + chips.length + ')');
  ck(chips.some(c => c.textContent.includes('Xray')), 'chips 含 Xray 状态');
  ck(($('#nav-nodes') || {}).textContent === String(rows.length),
     '侧栏节点计数与列表一致 (' + ($('#nav-nodes') || {}).textContent + ')');

  // 节点区必须落在节点视图里（它是主角），且带「添加节点」入口
  ck(!!$('#view-nodes .nodes-card'), '节点区在节点视图内');
  ck(!!$('#view-nodes .nodes-card button[onclick*="openAdd"]'), '节点区有「添加节点」入口');
  ck(!d.querySelector('.wrap'), '（复查）仍无窄居中容器');

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
  // 可发现性：抓手必须真的渲染出来，而且三种密度都有（在下面的密度循环里再查一遍）。
  // 只断言 draggable="true" 会让"用户根本不知道能拖"这件事完全溜过去。
  const grips = $$('#node-list .grip');
  ck(grips.length === rows.length, '每个节点行都有拖拽抓手 (' + grips.length + ')');
  ck(grips.every(g => (g.getAttribute('title') || '').length > 0),
     '抓手带说明（不是只有一个看不懂的符号）');
  // 拖起来时所有分组行一起亮：这里验的是那个 class 真的被开关。
  try {
    // 这个 harness 跑在 Node 里（不是注入页面），页面里的 `let ST` 不挂在
    // window 上，取不到 —— 从行自己的 ondragstart 里把文件名抠出来，
    // 顺带也验证了"每行的拖拽确实绑定了它自己的文件"。
    const attr = rows[0].getAttribute('ondragstart') || '';
    const m2 = attr.match(/'([^']+)'/);
    if (!m2) throw new Error('第一行没有可解析的 ondragstart: ' + attr);
    const ev = new w.Event('dragstart');
    ev.dataTransfer = {setData(){}, effectAllowed: ''};
    w.nodeDragStart(ev, m2[1]);
    ck(d.body.classList.contains('dragging'),
       '开始拖拽后 body 进入 dragging 态（分组行全部高亮）');
    w.nodeDragEnd();
    ck(!d.body.classList.contains('dragging'), '拖拽结束退出 dragging 态');
    ck($$('.srow.dragover').length === 0, '拖拽结束后没有残留的高亮');
  } catch (e) {
    // 错误信息必须拼进断言名里 —— 这个 harness 的 ck 只吃 (条件, 名字)，
    // 写进第三个参数等于扔掉，排查时只能看到"失败了"三个字。
    ck(false, '拖拽状态开关: ' + String(e && e.message || e).slice(0, 100));
  }

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

  // ---- 「添加节点」的入口必须看得见 ----
  // 用户的反馈就是这一条："我怎么找不到原本添加节点的地方了" ——
  // 功能在弹窗里，但页面上看不出来，等于没有。所以两件事都要断言：
  //   ① 节点页上有常驻的快速导入行 ② 弹窗里有预设按钮
  w.go('nodes');
  const qa = $('.quickadd'), qi = $('#quick-in');
  ck(!!qa && !!qi, '节点页有常驻的「快速添加」输入框');
  ck(!!$('.quickadd button'), '快速添加有「导入」按钮');
  const addBtn = $$('button').find(x => /添加节点/.test(x.textContent));
  ck(!!addBtn, '「＋ 添加节点」按钮在页面上（不是只在弹窗里）');
  w.openAdd();
  const pchips = $$('#preset-list .preset');
  ck(pchips.length >= 6, '弹窗里有预设按钮 (' + pchips.length + ')');
  ck(pchips.every(c => c.querySelector('b') && c.querySelector('span')),
     '预设按钮有名字 + 说明');
  ck(pchips.every(c => (c.getAttribute('title') || '').length > 4),
     '预设按钮带提示（说明还要填什么）');
  // 点第一个预设：字段必须真的被填好 —— 只渲染按钮不接线是最容易漏的一步
  pchips[0].dispatchEvent(new w.MouseEvent('click', {bubbles: true}));
  ck(($('#f-proto').textContent || '').length > 0, '点预设后进入表单并显示协议');
  ck(($('#f-transport').value || '') !== '', '预设填好了传输 (' + $('#f-transport').value + ')');
  ck(!!$('#f-fingerprint') && !!$('#f-ech'),
     '表单有指纹与 ECH 字段（预设要用到的参数）');
  w.closeAdd();

  // ---- 局域网分享页 ----
  // 夹具里那条 share_status 会返回一条启用 + 一条停用的链接。
  // 断言的是"看得见、点得到、说清楚"：状态文字、地址、行数、按钮齐不齐。
  w.go('share');
  ck(!!$('#view-share.on'), '切到分享视图');
  await new Promise(r => setTimeout(r, 60));
  ck(($('#sh-addr').textContent || '').includes('18190'),
     '分享页显示服务地址 (' + $('#sh-addr').textContent + ')');
  ck(/运行中/.test($('#sh-state').textContent || ''),
     '分享页显示服务在运行 (' + $('#sh-state').textContent.trim() + ')');
  const srows2 = $$('#tb-share tr');
  ck(srows2.length === 2, '两条分享链接都列出来了 (' + srows2.length + ')');
  ck(srows2.some(r => /启用/.test(r.textContent)) && srows2.some(r => /已停用/.test(r.textContent)),
     '启用/停用两种状态都显示');
  ck($$('#tb-share button').length >= 6, '每条链接都有 复制/启用停用/删除 按钮');
  ck(($('#sh-proxy').textContent || '').includes('SOCKS5'),
     '分享页顺带给出局域网代理入口 (' + $('#sh-proxy').textContent + ')');
  // 覆盖：夹具里有一个节点生成不了链接 —— 面板必须**点名**，
  // 而不是让用户自己数"为什么手机里少一个"。
  ck(/7 \/ 8/.test($('#sh-cover').textContent || ''),
     '分享页显示节点覆盖 (7 / 8)');
  ck(/坏节点/.test($('#sh-note').textContent || ''),
     '没进分享的节点被点名（含原因）');
  w.go('nodes');

  // 三种密度都要能渲染（同一份标记在三个视图里都要成立）
  for (const dens of ['list', 'grid', 'table']) {
    try {
      w.setDensity(dens);
      const r2 = $$(ROWS);
      ck(r2.length === rows.length && r2.every(r => r.querySelector('.seg')),
         '切到「' + dens + '」视图后仍是每行都有分段控件 (' + r2.length + ')');
      // 抓手与拖拽属性必须三种密度都在：表格视图漏一个，那一屏的人就
      // 完全不知道能拖 —— 而这正是"一眼看得出"要求里最容易漏的一屏。
      ck(r2.every(r => r.querySelector('.grip') && r.getAttribute('draggable') === 'true'),
         '「' + dens + '」视图每行都有抓手且可拖');
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
        err = (r.stderr or "").strip()
        print("jsdom 夹具失败:", err[:400] + ("\n…\n" + err[-200:] if len(err) > 600 else ""))
        return 1
    for ln in open(opath, encoding="utf-8").read().strip().splitlines():
        ck(ln.startswith("OK "), ln[3:])
    shutil.rmtree(tmp, ignore_errors=True)

    print("\n结果：%d 通过 / %d 失败" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
