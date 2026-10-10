#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 panel.py 的 PAGE 抽出来，用页面**自己的 JS** 渲染成真实 DOM 再截图。

为什么不用"看字符串"代替：样式问题的绝大多数（配色错乱、字出框、按钮换行、
浅色模式下某块还是深色）只在**排版之后**才存在。字符串检查能保证 CSS 语法对，
保证不了它长得对。

做法是 stub 掉 fetch，喂一份合成的 state。这样跑的是真实的 renderNodes /
renderSubs / paint 代码路径，而不是我另写一份假渲染 —— 后者验证不了任何东西。
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/xray-panel-render"
os.makedirs(OUT, exist_ok=True)


def page_html():
    src = open(os.path.join(REPO, "Client/lib/web/panel.py"), encoding="utf-8").read()
    import ast
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if getattr(t, "id", "") == "PAGE":
                    return node.value.value
    raise SystemExit("panel.py 里找不到 PAGE")


def mknode(i, name, addr, port, cur=False, tags=(), x="ok", d="ok"):
    return {
        "file": "node-%02d.json" % i, "name": name, "address": addr, "port": port,
        "current": cur,
        "compat": {"tags": list(tags),
                   "xray": {"overall": x, "reason": ""},
                   "dialer": {"overall": d, "reason": "", "notes": []},
                   "protocol_may_dialer": d != "bad" or "Browser Dialer" in tags},
        "probe_ok": (None if d == "warn" else True),
        "protocol": "vless", "transport": "xhttp",
        "proto": "vless", "security": "reality", "network": "xhttp",
    }


def state():
    n1 = mknode(1, "x-vless01-REALITY", "rn.example.net", 443, True,
                ["Xray", "Browser Dialer", "REALITY", "XHTTP"])
    n2 = mknode(2, "x-vless02-XHTTP-CDN", "cdn.example.net", 443,
                tags=["Xray", "XHTTP", "CDN"])
    n3 = mknode(3, "x-vmess03-TLS-WS-一条很长很长的节点名字用来验证截断", "us2.example.net", 8443,
                tags=["Xray", "Browser Dialer"])
    n4 = mknode(4, "x-trojan04-REALITY", "jp1.example.net", 443,
                tags=["Xray"], d="bad")
    n5 = mknode(5, "x-ss05-2022", "sg1.example.net", 8388, tags=["Xray"])
    n6 = mknode(6, "x-hysteria2-06", "hk1.example.net", 8443, tags=["Xray"], x="bad",
                d="bad")
    n7 = mknode(7, "x-vless07-gRPC-CDN", "cdn2.example.net", 443,
                tags=["Xray", "gRPC", "CDN"])
    n8 = mknode(8, "x-vless08-XHTTP-packet-up", "de1.example.net", 443,
                tags=["Xray", "Browser Dialer", "XHTTP"], d="warn")
    nodes = [n1, n2, n3, n4, n5, n6, n7, n8]
    return {
        "services": {"xray": {"state": "active", "active": True, "enabled": "enabled"},
                     "browser-dialer": {"state": "inactive", "active": False,
                                        "enabled": "disabled"}},
        "services_extra": {"panel": {"state": "active", "active": True, "enabled": "enabled"},
                           "timer": {"state": "active", "active": True, "enabled": "enabled"}},
        "nodes": nodes,
        "groups": [
            {"key": "sub:rn", "name": "RN 自建", "origin": "sub", "order": 0,
             "nodes": [n1, n2, n3]},
            {"key": "sub:airport", "name": "机场订阅 A", "origin": "sub", "order": 1,
             "nodes": [n4, n5, n6]},
            {"key": "other", "name": "手动添加", "origin": "other", "order": 2,
             "nodes": [n7, n8]},
        ],
        "ports_cfg": {"normal": "1080", "http": "10808", "lan_http": "10809",
                      "listen": "127.0.0.1", "channel": "18081", "api": "18085"},
        "multi_mode": "on", "multi_active": True,
        "dns_mode": "strict", "doh": "https://dns.alidns.com/dns-query",
        "takeover_local": False, "takeover_local_files": [], "takeover_local_owners": 0,
        "xray_ver": "25.8.3",
        "api": {"available": True,
                "balancer": {"tag": "auto", "selected": "node-01.json",
                             "overrides": {"node-02.json": "node-01.json"}},
                "traffic": {"node-01.json": {"uplink": 41_000_000, "downlink": 912_000_000},
                            "node-02.json": {"uplink": 1_200_000, "downlink": 8_400_000},
                            "node-05.json": {"uplink": 0, "downlink": 15_600}}},
        "error": "",
    }


# 用"行列表 + 换行拼接"而不是在字符串里写 \n：
# 这一段要经过 Python 字符串 → JS 字符串两层转义，手写 \n 很容易差一层，
# 结果是 JS 里出现真实换行、整个 <script> 报语法错误、夹具静默不生效。
NL = chr(10)
CONNINFO = {
    "yaml": NL.join([
        "mixed-port: 10808",
        "allow-lan: true",
        "proxies:",
        "  - name: x-vless01-REALITY",
        "    type: vless",
        "    server: rn.example.net",
        "    port: 443",
        "    uuid: 00000000-0000-0000-0000-000000000000",
        "    network: xhttp",
        "rules:",
        "  - MATCH,PROXY",
        "",
    ]),
    "env_example": NL.join([
        "export http_proxy=http://127.0.0.1:10808",
        "export https_proxy=http://127.0.0.1:10808",
        "export all_proxy=socks5://127.0.0.1:1080",
        "",
    ]),
    "local_note": "本机直接可用，无需额外配置。",
    "links": [{"label": "SOCKS5", "url": "socks5://127.0.0.1:1080"},
              {"label": "HTTP", "url": "http://127.0.0.1:10808"}],
}

# 局域网分享的夹具：一条启用（用过 3 次）、一条停用。
# 状态要能表达三件事：服务活没活、端口在不在听、有哪几条链接 ——
# 少任何一件，用户拿着链接都不知道能不能用。
SHARE = {
    "host": "192.168.1.178", "port": "18190",
    "unit": "xbd-share.service", "active": True, "listening": True, "enabled": True,
    "socks": "192.168.1.178:1080", "http": "192.168.1.178:10809", "clients": 2,
    "tokens": [
        {"token": "852933b3b1dd0dd04ac32f9f", "enabled": True, "used": 3, "max_uses": 0,
         "created_at": 1760000000,
         "url": "http://192.168.1.178:18190/share/852933b3b1dd0dd04ac32f9f"},
        {"token": "8d623760bd68595138ae875a", "enabled": False, "used": 0, "max_uses": 10,
         "created_at": 1759990000,
         "url": "http://192.168.1.178:18190/share/8d623760bd68595138ae875a"},
    ],
}

def add_meta():
    """预设与指纹白名单**从面板后端直接取**，不在这里抄一份。

    抄一份的后果很具体：预设改了、夹具没改，于是"预设按钮点下去填的字段"
    在自检里永远是对的，真机上却是错的 —— 夹具成了自我安慰。
    """
    here = os.path.dirname(os.path.abspath(__file__))
    lib = os.path.join(os.path.dirname(here), "lib")
    for path in (os.path.join(lib, "web"), lib):
        if path not in sys.path:
            sys.path.insert(0, path)
    import importlib
    pnl = importlib.import_module("panel")
    try:
        cmp_ = importlib.import_module("compat")
        fps, hint = sorted(cmp_.FP_VALUES), cmp_.FP_HINT
    except Exception:                                            # noqa: BLE001
        fps, hint = ["chrome", "firefox"], ""
    return {"presets": pnl.ADD_PRESETS, "fingerprints": fps,
            "fingerprint_hint": hint}


PREVIEW = {
    "url": "http://192.168.1.178:18190/share/852933b3b1dd0dd04ac32f9f",
    "bytes": 1180, "count": 8,
    "note": "8 个节点：x-vless01-REALITY、x-vless02-XHTTP-CDN、x-vmess03-TLS-WS…",
    "body": NL.join(["vless://00000000-0000-0000-0000-000000000000@rn.example.net:443"
                     "?type=xhttp&security=tls#x-vless01-REALITY",
                     "trojan://pw@jp1.example.net:443?security=reality#x-trojan04-REALITY",
                     ""]),
}

STUB = """
<script>
/* 渲染夹具：把 /api/state 与 /api/action 换成合成数据，其余一切照旧。 */
window.__FIXTURE__ = __FIXTURE_JSON__;
window.__CONNINFO__ = __CONNINFO_JSON__;
window.__SHARE__ = __SHARE_JSON__;
window.__PREVIEW__ = __PREVIEW_JSON__;
window.__ADDMETA__ = __ADDMETA_JSON__;
(function(){
  const real = window.fetch;
  const ok = obj => Promise.resolve({ok:true, status:200,
    json: () => Promise.resolve(obj)});
  window.fetch = function(url, opt){
    const u = String((url && url.url) || url);
    if (u.indexOf('/api/state') === 0)
      return ok(window.__FIXTURE__);
    if (u.indexOf('/api/action') === 0) {
      // ★ 按动作名分发。上一版所有动作都回同一份 conninfo 载荷 ——
      //   "分享"页拿到的是配置 JSON，于是那条路径在夹具里永远测不到
      //   （页面上不报错、只是空的），真机上才暴露。
      let act = '';
      try { act = JSON.parse((opt && opt.body) || '{}').action || ''; } catch(e){}
      if (act === 'share_status')
        return ok({ok:true, message: JSON.stringify(window.__SHARE__)});
      if (act === 'share_preview')
        return ok({ok:true, message: JSON.stringify(window.__PREVIEW__)});
      if (act === 'add_meta')
        return ok({ok:true, message: JSON.stringify(window.__ADDMETA__)});
      return ok({ok:true, message: JSON.stringify(window.__CONNINFO__)});
    }
    return real.apply(this, arguments);
  };
})();
</script>
"""

def js_json(obj):
    """序列化成可直接内嵌 <script> 的 JSON（顺手挡掉 </script> 截断）。"""
    return (json.dumps(obj, ensure_ascii=False)
            .replace("</", "<\/"))


# ------------------------------------------------------------------ 样式探针 ----
# 这个环境里的浏览器截图**看不了**（模型不支持图像输入）。所以"好不好看"
# 不能靠眼睛，改成把能客观度量的部分量出来：
#   · 配色是否真的换了一套（深/浅两套变量的解析值）
#   · 正文与背景的对比度够不够（WCAG AA 是 4.5:1，大字/次要文字 3:1）
#   · 有没有"文字颜色 == 背景色"这种等于隐形的元素
#   · 有没有横向溢出（历史上的"字出框"就是这一类）
# 报告写进 DOM，从无障碍快照里读回来。这比看图更可靠：看图只能看一张，
# 这个能同时覆盖两套主题和所有断点宽度。
PROBE = """
<script>
(function(){
  function parse(c){
    let m = /^#([0-9a-f]{6})$/i.exec(c.trim());
    if (m){ const v = parseInt(m[1], 16);
      return {r:(v>>16)&255, g:(v>>8)&255, b:v&255, a:1}; }
    m = /^#([0-9a-f]{3})$/i.exec(c.trim());
    if (m){ const v = parseInt(m[1], 16);
      return {r:((v>>8)&15)*17, g:((v>>4)&15)*17, b:(v&15)*17, a:1}; }
    m = /rgba?\\(([^)]+)\\)/.exec(c);
    if (m){ const p = m[1].split(',').map(Number);
      return {r:p[0], g:p[1], b:p[2], a:(p.length > 3 ? p[3] : 1)}; }
    return null;
  }
  // 把 fg 叠到 bg 上（fg 可半透明），得到实际看到的颜色。
  function over(fg, bg){
    const a = fg.a;
    return {r: fg.r*a + bg.r*(1-a), g: fg.g*a + bg.g*(1-a),
            b: fg.b*a + bg.b*(1-a), a: 1};
  }
  function lum(c){
    const f = v => { v /= 255; return v <= .03928 ? v/12.92 : Math.pow((v+.055)/1.055, 2.4); };
    return .2126*f(c.r) + .7152*f(c.g) + .0722*f(c.b);
  }
  function ratio(a, b){
    const la = lum(a), lb = lum(b);
    const hi = Math.max(la, lb), lo = Math.min(la, lb);
    return (hi + .05) / (lo + .05);
  }
  // 从 html 往下逐层合成，得到元素背后的**实际**底色。
  function backdrop(el){
    const chain = [];
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) chain.unshift(n);
    let bg = {r:255, g:255, b:255, a:1};
    chain.forEach(n => {
      const c = parse(getComputedStyle(n).backgroundColor);
      if (c && c.a > 0) bg = over(c, bg);
    });
    return bg;
  }
  function cr(el){
    if (!el) return null;
    const fg = parse(getComputedStyle(el).color) || {r:0,g:0,b:0,a:1};
    const bg = backdrop(el);
    return ratio(over(fg, bg), bg);
  }
  // 报出"量的是哪个元素"。
  // `q('.tag')` 这种选择器取的是 DOM 里**第一个**匹配 —— 版式一动，
  // 第一个可能是完全另一个元素，数字跟着变而没人知道量的是谁。
  // 上一版浅色下突然从 4.82 掉到 4.38，就是因为这个。
  function show(el){
    if (!el) return 'n/a';
    const r = cr(el);
    if (r === null) return 'n/a';
    const who = el.tagName.toLowerCase() + (el.className ? '.' + String(el.className).split(' ')[0] : '');
    return r.toFixed(2) + ':1' + (r < 4.5 ? '⚠' : '') + '(' + who + ')';
  }
  function vars(){
    const s = getComputedStyle(document.documentElement), out = {};
    ['--bg','--card','--line','--fg','--dim','--acc','--code-bg','--modal-bg',
     '--acc-tag-text','--acc-tag-bg'].forEach(k => {
      const v = s.getPropertyValue(k).trim();
      const c = parse(v);
      out[k] = c ? 'rgb(' + Math.round(c.r) + ',' + Math.round(c.g) + ','
                   + Math.round(c.b) + ')' : v;
    });
    return out;
  }
  // 横向溢出：历史上的"字出框"就是这一类，必须自动查。
  function overflow(){
    const bad = [];
    document.querySelectorAll('.wrap *').forEach(el => {
      const cs = getComputedStyle(el);
      if (cs.overflowX !== 'visible' || cs.position === 'fixed') return;
      if (el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0)
        bad.push((el.className || el.tagName) + ' ' + el.clientWidth + '<' + el.scrollWidth);
    });
    const de = document.documentElement;
    return {doc: de.scrollWidth + '/' + de.clientWidth, els: bad.slice(0, 6)};
  }
  // 隐形文字：合成后的前景与底色对比过低 —— 等于看不见。
  function invisible(){
    const bad = [];
    document.querySelectorAll('.wrap *').forEach(el => {
      if (el.children.length || !(el.textContent || '').trim()) return;
      if (el.id === 'style-report') return;
      const r = cr(el);
      if (r !== null && r < 3) bad.push((el.className || el.tagName) + ' ' + r.toFixed(2));
    });
    return bad.slice(0, 8);
  }
  function report(tag){
    const v = vars(), o = overflow(), inv = invisible();
    const q = s => document.querySelector(s);
    const rows = [
      '== ' + tag + ' ==',
      'data-theme=' + (document.documentElement.getAttribute('data-theme') || '(无)'),
      'bg=' + v['--bg'] + ' fg=' + v['--fg'] + ' card=' + v['--card'] + ' acc=' + v['--acc'],
      'code-bg=' + v['--code-bg'] + ' modal-bg=' + v['--modal-bg']
        + ' acc-tag=' + v['--acc-tag-text'] + '/' + v['--acc-tag-bg'],
      '正文=' + show(document.body) + '  卡片标题=' + show(q('.card h2'))
        + '  次要文字=' + show(q('.hint')) + '  小字=' + show(q('.sub')),
      '按钮=' + show(q('button')) + '  主按钮=' + show(q('button.pri'))
        + '  危险按钮=' + show(q('button.danger'))
        + '  输入框=' + show(q('input, select, textarea')),
      '表格头=' + show(q('thead th')) + '  单元格=' + show(q('td'))
        + '  代码块=' + show(q('pre')) + '  标签=' + show(q('.tag'))
        + '  分组行=' + show(q('.srow')),
      // `.tag` 有四种配色（底/ok/warn/bad/acc），`q('.tag')` 只量到**第一个**。
      // 只报一个数字时，读到 4.38 也说不清是谁不达标 —— 每个都列出来。
      '标签逐个=' + (function(){
        const seen = {}, out = [];
        document.querySelectorAll('.tag').forEach(function(el){
          const k = el.className;
          if (seen[k] || out.length >= 6) return;
          seen[k] = 1;
          out.push(k + '=' + show(el));
        });
        return out.length ? out.join('  ') : '无';
      })(),
      '页面宽度=' + o.doc + (o.doc.split('/')[0] === o.doc.split('/')[1]
        ? ' 无横向溢出' : ' ⚠ 有横向溢出'),
      '溢出元素=' + (o.els.length ? o.els.join(' | ') : '无'),
      '低对比(<3:1)=' + (inv.length ? inv.join(' | ') : '无'),
      '主题按钮=' + ((document.getElementById('btn-theme')||{}).textContent || '缺失'),
    ];
    // 累积而不是覆盖：三次报告（默认/浅色/深色）要能一次看全，
    // 否则只有最后一次留在 DOM 里，浅色那次的数字就丢了。
    let p = document.getElementById('style-report');
    if (!p){ p = document.createElement('pre'); p.id = 'style-report';
             p.style.cssText = 'position:fixed;left:0;top:0;z-index:9999;margin:0;'
               + 'padding:8px 10px;font:11px/1.4 monospace;white-space:pre-wrap;'
               + 'max-width:100vw;background:#000;color:#0f0;opacity:.93';
             document.body.appendChild(p); p.textContent = ''; }
    p.textContent += (p.textContent ? String.fromCharCode(10) : '')
                   + rows.join(String.fromCharCode(10));
    return p.textContent;
  }
  // ---- 界面重做的结构性检查 ----
  // 样式探针量的是"好不好看"（对比度/溢出），这一组量的是"改动的部件在不在、
  // 能不能用"：分段控件、分组行的圆点与计数、拖放属性、批量条的出现时机。
  // 顺带抓 JS 运行时错误 —— 面板的 JS 全拼在字符串里，出错只会静默失效。
  function uiChecks(){
    const rows = [];
    const q = s => document.querySelector(s);
    const segs = document.querySelectorAll('#node-list .seg');
    rows.push('分段控件数=' + segs.length +
              ' 首个含两侧=' + (segs[0]
                ? !!(segs[0].querySelector('[data-side="normal"]')
                     && segs[0].querySelector('[data-side="bd"]')) : false));
    const first = segs[0];
    rows.push('分段高亮侧=' + (first
      ? [...first.querySelectorAll('button')].map(b => (b.classList.contains('on') ? '●' : '○')).join('')
      : '-') + ' (●=当前走的那条路)');
    // 不能走浏览器的那一侧必须是 disabled 且有说明
    const na = document.querySelector('#node-list .seg.na');
    rows.push('不可用侧被禁用=' + (na
      ? na.querySelector('[data-side="bd"]').disabled : '(本次夹具无此类节点)'));

    const srows = document.querySelectorAll('.srow');
    rows.push('分组行=' + srows.length +
              ' 有圆点=' + [...srows].every(r => !!r.querySelector('.gd')) +
              ' 有计数=' + [...srows].every(r => !!r.querySelector('.sc')) +
              ' 有操作按钮=' + [...srows].slice(1).every(r => !!r.querySelector('.sa')));

    // 拖放属性：列表/卡片/表格三种视图各看一个
    const draggables = document.querySelectorAll(
      '#node-list [draggable="true"]');
    rows.push('可拖拽节点行=' + draggables.length +
              ' 带 ondragstart=' + (draggables[0]
                ? draggables[0].getAttribute('ondragstart').indexOf('nodeDragStart') >= 0
                : false));
    // 可发现性要读**计算样式**：JS 里有没有这个 class 是一回事，
    // 浏览器里到底看不得看得见（opacity / display / 宽度）是另一回事。
    const grips = document.querySelectorAll('#node-list .grip');
    const g0 = grips[0];
    rows.push('拖拽抓手=' + grips.length
      + ' 可见=' + (g0 ? (getComputedStyle(g0).display !== 'none'
                          && g0.getBoundingClientRect().width > 0) : false)
      + ' 光标=' + (g0 ? getComputedStyle(g0).cursor : '?')
      + ' 行光标=' + (draggables[0] ? getComputedStyle(draggables[0]).cursor : '?'));
    // 拖动中"所有分组行一起亮" —— 这条只有在真浏览器里加 class 再读
    // 计算样式才验得到（jsdom 不算样式，本地自检只能验 class 被开关）。
    const srow = q('.srow');
    if(srow){
      // 规则到底在不在样式表里 —— "没生效"可能是选择器写错，也可能是
      // 规则被前面的语法错误吞了。这两件事的修法完全不同，所以要分开报。
      let hasRule = false;
      try {
        hasRule = [...document.styleSheets].some(ss =>
          [...ss.cssRules].some(r => String(r.selectorText || '').indexOf('body.dragging') >= 0));
      } catch(e){}
      const b4 = getComputedStyle(srow).boxShadow + '|' + getComputedStyle(srow).backgroundColor;
      // ★ 必须先把过渡关掉再量。`.srow` 带着
      //   `transition: background-color .12s`，加完 class 立刻读计算样式，
      //   读到的是**过渡起点**（还是旧值）—— 于是"规则明明在样式表里、
      //   也匹配得上，量出来却说没变化"。这个坑和换肤闪烁是同一个。
      const de2 = document.documentElement;
      de2.classList.add('theme-switching');
      document.body.classList.add('dragging');
      void srow.offsetHeight;                       // 强制重排
      const on = getComputedStyle(srow).boxShadow + '|' + getComputedStyle(srow).backgroundColor;
      const cls = document.body.className;
      document.body.classList.remove('dragging');
      de2.classList.remove('theme-switching');
      rows.push('拖动中分组行高亮=' + (b4 !== on)
        + ' 样式表里有规则=' + hasRule + ' body 类=' + (cls || '(空)')
        + ' 前=' + b4.slice(0, 40) + ' 后=' + on.slice(0, 40));
    }

    // 批量条：没勾选时应隐藏，勾一个后应出现且选项里列出全部组
    const bar = q('#bulkbar');
    const before = bar ? bar.classList.contains('on') : null;
    const cb = q('#node-list .sel');
    if(cb){ cb.checked = true; cb.dispatchEvent(new Event('change')); }
    const after = bar ? bar.classList.contains('on') : null;
    const opts = q('#bulk-move') ? q('#bulk-move').options.length : 0;
    rows.push('批量条 勾选前/后=' + before + '/' + after + ' 可移动目标=' + opts);
    if(cb){ cb.checked = false; cb.dispatchEvent(new Event('change')); }

    // ★ 视图可见性必须读**计算样式**：class 对不代表真的只显示一个。
    //   无障碍快照会把隐藏子树也列出来（看起来像"两个视图同时显示"），
    //   拿它判断版式会得出完全相反的结论。
    const vis = [...document.querySelectorAll('.view')]
      .filter(v => getComputedStyle(v).display !== 'none')
      .map(v => v.id);
    rows.push('可见视图=' + (vis.join(',') || '无') + ' 数量=' + vis.length);
    const app = document.querySelector('.app');
    rows.push('外壳实际宽度=' + (app ? Math.round(app.getBoundingClientRect().width) : '?')
      + ' 视口=' + window.innerWidth);
    // ★ 视图必须在主工作区**里面**。多一个 </div> 就会让浏览器提前闭合
    //   <main>，两页界面掉到外壳外面 —— 症状是"点配置一片空白、东西在下面"。
    //   读几何位置最直接：掉出去的视图，顶端会在整个应用外壳之下。
    const inMain = document.querySelectorAll('.main > .view').length;
    const strayViews = [...document.querySelectorAll('.view')]
      .filter(v => !v.closest('.main')).map(v => v.id);
    const shellBottom = Math.round(
      (document.querySelector('.app') || {getBoundingClientRect: () => ({bottom: 0})})
        .getBoundingClientRect().bottom + window.scrollY);
    const activeTop = Math.round(
      (document.querySelector('.view.on') || {getBoundingClientRect: () => ({top: -1})})
        .getBoundingClientRect().top + window.scrollY);
    const allViews = document.querySelectorAll('.view').length;
    rows.push('视图在主区内=' + inMain + '/' + allViews
      + (strayViews.length ? ' ⚠ 掉出外壳: ' + strayViews.join(',') : '')
      + ' 当前视图顶端=' + activeTop + ' 外壳底=' + shellBottom);
    // 提示条：conninfo 之类的动作如果拿整份 JSON 当消息，这里会是几百字符，
    // 页面顶部就被一大段 JSON 顶下去。正常应当在打开时是空的。
    const mb = document.getElementById('msg');
    const mt = mb ? (mb.textContent || '') : '';
    rows.push('提示条 长度=' + mt.length + ' 可见=' + !!(mb && mb.classList.contains('on'))
      + (mt.length > 200 ? ' ⚠ 顶部被长文本顶下去了: ' + JSON.stringify(mt.slice(0, 60)) : ''));
    const main = document.querySelector('.main');
    rows.push('主区宽度=' + (main ? Math.round(main.getBoundingClientRect().width) : '?')
      + ' (占视口 ' + (main ? Math.round(main.getBoundingClientRect().width / window.innerWidth * 100) : '?') + '%)');
    // 侧栏与主区必须并排，不能各占一行（那说明 grid 没生效）
    const side = document.querySelector('.side');
    rows.push('侧栏/主区顶端对齐=' + (side && main
      ? Math.abs(side.getBoundingClientRect().top - main.getBoundingClientRect().top) < 2 : '?'));

    rows.push('分组菜单可弹出=' + (typeof groupMenu === 'function'));
    rows.push('JS 运行时错误=' + (window.__jserr || '无'));
    return rows;
  }

  window.__probe = report;
  // 抓运行时错误：面板的 JS 静态语法对了也可能在运行时抛（比如 CSS.escape
  // 不存在、某个 id 拼错）。不抓的话界面上只会"点了没反应"。
  window.__jserr = '';
  window.addEventListener('error', function(e){
    window.__jserr = (e.message || 'error') + ' @' + (e.lineno || '?');
  });

  window.addEventListener('load', function(){
    setTimeout(function(){
      // 先把上次运行遗留的选择清掉，否则"默认"那一次测的是上次的残留主题。
      try { localStorage.removeItem('xray-panel-theme'); } catch(e){}
      // 走页面自己的那套"关过渡→改属性→强制重排→开过渡"，
      // 直接 removeAttribute 会留下渐变的中间态，量出来是假的低对比。
      const de = document.documentElement;
      de.classList.add('theme-switching');
      de.removeAttribute('data-theme');
      void de.offsetHeight;
      de.classList.remove('theme-switching');
      // 表格视图默认不渲染，但吸顶表头/表格配色只有它才有，必须切出来量。
      try { setDensity('table'); } catch(e){}
      // 切密度会重建节点区，新节点的样式要等一次重排才算得准 ——
      // 立刻量过一次，量到的是重排前的旧值（.tag/.srow 报出 1.26:1 / 1.00:1
      // 这种不可能的数字）。先让出一帧。
      requestAnimationFrame(function(){ requestAnimationFrame(function(){
        report('默认（跟随系统）');
      try { report('界面结构检查'); document.getElementById('style-report')
              .textContent += String.fromCharCode(10)
              + uiChecks().join(String.fromCharCode(10)); }
      catch(e){ document.getElementById('style-report').textContent +=
                String.fromCharCode(10) + 'uiChecks 抛异常: ' + e; }
        const b = document.getElementById('btn-theme');
        if (!b) return;
        b.click();                                // '' → light
        setTimeout(function(){
          report('显式浅色（点一次）');
          b.click();                              // light → dark
          setTimeout(function(){
            report('显式深色（点两次）');
            // 三次报告都量完了，可以收摊：把应用整体隐藏，只留报告本身。
            // 远程无障碍快照是按整页生成的，应用树一大，报告就被挤到
            // "中间省略"里去 —— 探针跑完了却读不到数字，等于没跑。
            try {
              const app = document.querySelector('.app');
              if (app) app.style.display = 'none';
              document.querySelectorAll(
                '#add-modal,.toast,#msg').forEach(n => { n.style.display = 'none'; });
            } catch(e){}
          }, 150);
        }, 150);
      }); });
    }, 500);
  });
})();
</script>
"""

html = page_html()
stub = (STUB.replace("__FIXTURE_JSON__", js_json(state()))
            .replace("__CONNINFO_JSON__", js_json(CONNINFO))
            .replace("__SHARE_JSON__", js_json(SHARE))
            .replace("__PREVIEW_JSON__", js_json(PREVIEW))
            .replace("__ADDMETA_JSON__", js_json(add_meta())))
# 夹具在页面自己的脚本之前执行即可。锚点必须用**结束标签**：
# 页面里出现过字面量开始标签（注释里），按它替换会把脚本从中间劈开。
anchor = "<script>"
pos = html.rfind(anchor)
if pos < 0:
    raise SystemExit("注入失败：找不到主脚本")
# 探针则要排在主脚本**之后** —— 它依赖页面已经跑起来。
tail = "</body>"
html = html[:pos] + stub + html[pos:]
if html.count(tail) != 1:
    raise SystemExit("注入失败：</body> 不唯一")
html = html.replace(tail, PROBE + tail, 1)

dst = os.path.join(OUT, "panel.html")
open(dst, "w", encoding="utf-8").write(html)
print(dst)
