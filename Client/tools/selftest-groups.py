#!/usr/bin/env python3
"""分组 / 多出站 / Browser Dialer 不回归 的自检。

三组断言：

1. 前缀树推导的边界情况（分叉、深浅混合、空名）。
2. 订阅注册表的增删改查，以及损坏后能不能自愈。
3. **单节点配置逐字节不变**。这条最要紧 —— Browser Dialer 走的就是单节点路径，
   多出站改造动的是同一个文件。这里每跑一次就把"改造前的输出"重新算一遍再比对，
   将来谁改了单节点路径都会在这里炸掉，而不是等到用户开浏览器才发现。

第 3 组拿 git 里的旧版本当基准。拿不到旧版本（比如源码包分发、.git 不在）时
跳过并说明，不静默通过。

用法： python3 selftest-groups.py [--lib DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

PASS = 0
FAIL = 0


def ok(cond, msg):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ✓ {msg}")
    else:
        FAIL += 1
        print(f"  ✗ {msg}")


def eq(got, want, msg):
    ok(got == want, f"{msg}（得到 {got!r}，期望 {want!r}）")


# --------------------------------------------------------------- 前缀树推导 ----
def test_infer(subs):
    print("分组推导")
    def g(names):
        return subs.infer_groups([{"name": n, "file": n + ".json"} for n in names])

    eq(sorted(set(g(["a-vless01-TLS", "a-vless02-TLS", "a-trojan01-TLS"]).values())),
       ["a"], "一条订阅合成一组")
    eq(sorted(set(g(["a-v1", "a-v2", "b-v1", "b-t2"]).values())), ["a", "b"],
       "两条订阅分开")
    eq(sorted(set(g(["a-v1-TLS", "a-v2-TLS", "a-v1-TLS-CDN", "b-x"]).values())),
       ["a", "b"], "CDN 节点不被拆出去")
    eq(sorted(set(g(["Tokyo-01", "HK-02", "US-03"]).values())), ["HK", "Tokyo", "US"],
       "第一段就分叉时按第一段分")
    eq(sorted(set(g(["", "abc"]).values())), ["abc", "其它"], "空名落进其它且不炸")


# ------------------------------------------------------------------ 注册表 ----
def test_registry(subs, tmp):
    print("订阅注册表")
    d = os.path.join(tmp, "reg")
    os.makedirs(d, exist_ok=True)
    eq(subs.load(d)["subs"], [], "空目录返回空表")

    a = subs.add_sub(d, "https://x/a", "机场 A")
    ok(a["id"] and a["prefix"], f"登记成功 id={a['id']} prefix={a['prefix']}")
    b = subs.add_sub(d, "https://x/b", "机场 A")
    ok(b["prefix"] != a["prefix"], f"同名订阅拿到不同前缀（{a['prefix']} / {b['prefix']}）")
    eq(subs.add_sub(d, "https://x/a", "x")["id"], a["id"], "同 URL 重复登记不新建")
    ok(all(ord(ch) < 128 for ch in a["prefix"]),
       f"前缀是纯 ASCII（{a['prefix']!r}）—— 中文名不能进文件路径")

    subs.set_nodes(d, a["id"], ["n1.json", "n2.json"])
    eq(len(subs.load(d)["subs"][0]["nodes"]), 2, "set_nodes 记录节点")
    subs.mark_result(d, b["id"], False, "HTTP 403")
    ok(any(s["last_error"] == "HTTP 403" for s in subs.load(d)["subs"]),
       "失败原因被记住")
    eq(subs.drop_sub(d, b["id"], keep_nodes=True), [], "保留节点模式返回空删除列表")
    eq(len(subs.drop_sub(d, a["id"])), 2, "普通删除返回要删的节点列表")

    with open(subs.subs_path(d), "w") as fh:
        fh.write("{坏掉的")
    eq(subs.load(d)["subs"], [], "注册表损坏时退回空表而不是崩")


def test_group_nodes(subs, tmp):
    print("分组视图")
    d = os.path.join(tmp, "grp")
    os.makedirs(d, exist_ok=True)
    s1 = subs.add_sub(d, "https://a/s", "A")
    s2 = subs.add_sub(d, "https://b/s", "B")
    nodes = [
        {"file": "n1.json", "name": "a-1", "group": s1["id"]},
        {"file": "n2.json", "name": "a-2", "group": s1["id"]},
        {"file": "n3.json", "name": "b-1", "group": s2["id"]},
        {"file": "n4.json", "name": "手动-东京"},
    ]
    gs = subs.group_nodes(d, nodes)
    eq([g["name"] for g in gs], ["A", "B", "其它"], "分组顺序 = 注册顺序, 无归属的在最后")
    eq(sum(len(g["nodes"]) for g in gs), 4, "没有节点在分组过程中丢失")
    ok(nodes[0]["group_key"] == s1["id"], "节点上带回 group_key")
    ok(gs[-1]["name"] == "其它" and gs[-1]["origin"] == "other",
       "无归属节点统一进「其它」, 不再一节点一组")


# ------------------------------------------------------------- 配置生成 ----
SAMPLE = {
    "name": "t", "protocol": "vless", "address": "example.com", "port": 443,
    "uuid": "11111111-1111-1111-1111-111111111111", "encryption": "none",
    "flow": "xtls-rprx-vision", "transport": "ws", "security": "tls",
    "sni": "example.com", "path": "/ws", "host": "example.com",
    "service_name": "example.com",
}


def _run_genconfig(lib, workdir, args):
    out = os.path.join(workdir, "cfg.json")
    p = subprocess.run(
        [sys.executable, os.path.join(lib, "genconfig.py")] + args + ["--output", out],
        capture_output=True, text=True, cwd=workdir)
    return p, out


def test_single_node_unchanged(lib, tmp):
    """单节点路径必须逐字节不变 —— Browser Dialer 走这条路。"""
    print("单节点路径不回归（Browser Dialer）")
    src = os.path.join(lib, "genconfig.py")
    repo_src = None
    for up in (lib, os.path.dirname(lib), os.path.dirname(os.path.dirname(lib))):
        cand = os.path.join(up, "Client", "lib", "genconfig.py")
        if os.path.isdir(os.path.join(up, ".git")) and os.path.exists(cand):
            repo_src = cand
            break
    if repo_src is None:
        head = subprocess.run(["git", "-C", os.path.dirname(lib), "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True)
        if head.returncode == 0:
            cand = os.path.join(head.stdout.strip(), "Client", "lib", "genconfig.py")
            if os.path.exists(cand):
                repo_src = cand
    if repo_src is None:
        print("  - 找不到 git 里的旧版本，跳过逐字节比对（源码包分发场景）")
        return

    old = subprocess.run(["git", "-C", os.path.dirname(os.path.dirname(repo_src)),
                          "show", "HEAD:Client/lib/genconfig.py"],
                         capture_output=True, text=True)
    if old.returncode != 0:
        print("  - 取不到 HEAD 版本，跳过逐字节比对")
        return
    oldlib = os.path.join(tmp, "oldlib")
    os.makedirs(oldlib, exist_ok=True)
    with open(os.path.join(oldlib, "genconfig.py"), "w") as fh:
        fh.write(old.stdout)

    d1, d2 = os.path.join(tmp, "n1"), os.path.join(tmp, "n2")
    for d in (d1, d2):
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "n.json"), "w") as fh:
            json.dump(SAMPLE, fh)
    common = ["--node", "n.json", "--mode", "normal", "--port-normal", "1080"]
    p1, o1 = _run_genconfig(oldlib, d1, common)
    p2, o2 = _run_genconfig(lib, d2, common)
    if p1.returncode != 0 or p2.returncode != 0:
        ok(False, f"单节点生成失败 old={p1.returncode} new={p2.returncode} {p2.stderr[:120]}")
        return
    ok(open(o1).read() == open(o2).read(),
       "单节点配置与 HEAD 版本逐字节一致（Browser Dialer 未受影响）")


def test_multi(lib, tmp):
    print("多出站配置")
    d = os.path.join(tmp, "multi")
    nd = os.path.join(d, "nodes")
    os.makedirs(nd, exist_ok=True)
    for i in range(1, 4):
        with open(os.path.join(nd, "node-%03d-x.json" % i), "w") as fh:
            json.dump(dict(SAMPLE, name="n%d" % i,
                           address="10.0.0.%d" % i), fh)
    os.symlink("node-001-x.json", os.path.join(nd, "current"))
    p, out = _run_genconfig(lib, d, [
        "--all-nodes", "--nodes-dir", "nodes", "--node", os.path.join("nodes", "current"),
        "--mode", "normal", "--port-normal", "1080"])
    if p.returncode != 0:
        ok(False, f"多出站生成失败: {p.stderr[:200]}")
        return
    cfg = json.load(open(out))
    ok(True, "多出站配置生成成功")

    tags = [o["tag"] for o in cfg["outbounds"]]
    ok(tags[:3] == ["node-001-x", "node-002-x", "node-003-x"],
       f"出站 tag 不重复也不加双前缀（{tags[:3]}）")
    ok("direct" in tags and "block" in tags, "direct/block 出站仍在")

    bal = cfg["routing"]["balancers"][0]
    ok(bal["selector"] == ["node-"], "balancer 用前缀选中所有节点出站")
    ok(cfg["routing"]["rules"][-1].get("balancerTag") == bal["tag"],
       "末条路由指向 balancer 而不是写死某个出站")
    ok(cfg.get("burstObservatory", {}).get("subjectSelector") == ["node-"],
       "配了观测器 —— 缺了它 balancer 起不来")
    ok("RoutingService" in cfg["api"]["services"],
       "api.services 含 RoutingService —— 缺了 bo/bi 直接失败")
    ok("listen" in cfg["api"], "用简单 api 模式（给 listen 即可）")

    # 直连豁免要覆盖全部节点，不只是当前那个
    doms = set()
    for r in cfg["routing"]["rules"]:
        doms.update(r.get("domain") or [])
    ok({"example.com"} <= doms, "直连豁免覆盖全部节点")

    meta = json.loads(p.stdout.strip().splitlines()[-1])
    ok(meta.get("current_tag") == "node-001-x",
       f"回传 current_tag（{meta.get('current_tag')}）")

    # dialer 必须显式拒绝，不能静默降级
    pd, _ = _run_genconfig(lib, d, [
        "--all-nodes", "--nodes-dir", "nodes", "--node", os.path.join("nodes", "current"),
        "--mode", "dialer"])
    ok(pd.returncode != 0 and "dialer" in pd.stderr,
       "多出站模式在 dialer 下被显式拒绝")


def test_build_roundtrip(lib):
    """build → parse 往返。

    手动添加表单拼出分享链接后交给既有解析器导入。往返断了就意味着"手动建的
    节点和粘贴进来的行为不一致" —— 那是最难查的一类问题，所以在这里钉死。
    """
    print("分享链接生成往返")
    sys.path.insert(0, lib)
    import node as nodemod
    cases = [
        {"name": "东京01", "protocol": "vless", "address": "a.example.com", "port": 443,
         "uuid": "11111111-1111-1111-1111-111111111111", "transport": "tcp",
         "security": "reality", "sni": "a.example.com", "flow": "xtls-rprx-vision",
         "reality_public_key": "PK123", "reality_short_id": "abcd"},
        {"name": "WS", "protocol": "vless", "address": "b.example.com", "port": 8443,
         "uuid": "22222222-2222-2222-2222-222222222222", "transport": "ws",
         "security": "tls", "sni": "b.example.com", "host": "b.example.com", "path": "/ray"},
        {"name": "gRPC", "protocol": "vless", "address": "c.example.com", "port": 443,
         "uuid": "33333333-3333-3333-3333-333333333333", "transport": "grpc",
         "security": "tls", "service_name": "GunService", "sni": "c.example.com"},
        {"name": "XHTTP", "protocol": "vless", "address": "h.example.com", "port": 443,
         "uuid": "55555555-5555-5555-5555-555555555555", "transport": "xhttp",
         "security": "tls", "path": "/x", "host": "h.example.com", "sni": "h.example.com"},
        {"name": "Trojan", "protocol": "trojan", "address": "d.example.com", "port": 443,
         "password": "pw#123", "transport": "tcp", "security": "tls", "sni": "d.example.com"},
        {"name": "SS", "protocol": "shadowsocks", "address": "e.example.com", "port": 8388,
         "method": "aes-128-gcm", "password": "secret", "transport": "tcp", "security": "none"},
        {"name": "VMess", "protocol": "vmess", "address": "f.example.com", "port": 443,
         "uuid": "44444444-4444-4444-4444-444444444444", "transport": "ws",
         "security": "tls", "path": "/v", "host": "f.example.com", "sni": "f.example.com"},
        {"name": "HY2", "protocol": "hysteria2", "address": "g.example.com", "port": 443,
         "password": "pw", "transport": "tcp", "security": "none"},
    ]

    def canon(c):
        o = dict(c)
        # 传输名有别名表（ws → websocket）；hysteria2 在 Xray 里天生就是 quic+tls，
        # parse_hysteria2 会显式覆盖这两个字段，比对时按规范形式比
        if o["protocol"] != "hysteria2":
            o["transport"] = nodemod._norm_transport(o.get("transport") or "tcp")
        else:
            o["transport"], o["security"] = "quic", "tls"
        return o

    keys = ("protocol", "address", "port", "uuid", "password", "method", "transport",
            "security", "sni", "host", "path", "service_name", "flow",
            "reality_public_key", "reality_short_id")
    for c in cases:
        want = canon(c)
        try:
            back = nodemod.parse_node(nodemod.build_link(c))
        except Exception as e:                              # noqa: BLE001
            ok(False, f"{c['protocol']} 往返异常: {e}")
            continue
        bad = [f"{k}: {want[k]!r}->{back.get(k)!r}" for k in keys
               if want.get(k) not in (None, "") and
               str(want[k]) != str(back.get(k) if back.get(k) not in (None, "") else "")]
        if back.get("name") != c["name"]:
            bad.append(f"name->{back.get('name')!r}")
        ok(not bad, f"{c['protocol']}/{c.get('transport')} 往返一致" + ("; " + "; ".join(bad) if bad else ""))


def test_state_carries_group(lib, tmp):
    """state.py 必须把 group 带出来。

    这里踩过一次坑: 导入时明明把分组 id 盖进了节点文件, 面板里却仍然显示成
    按名字推断出来的组。原因是 state.py 逐个重建节点字典, 只挑了自己认识的
    字段, group 不在其中 —— 它是节点信息唯一的出口, 少一个字段下游就只能猜。
    """
    print("state.py 带出分组")
    d = os.path.join(tmp, "stg")
    os.makedirs(os.path.join(d, "nodes"), exist_ok=True)
    sys.path.insert(0, lib)
    import subs as S
    sub = S.add_sub(d, "http://x/a", "我的机场")
    with open(os.path.join(d, "nodes", "node-001-a.json"), "w") as fh:
        json.dump({"name": "A-01", "protocol": "vless", "address": "1.2.3.4",
                   "port": 443, "uuid": "11111111-1111-1111-1111-111111111111",
                   "transport": "tcp", "security": "none", "group": sub["id"]}, fh)
    env = dict(os.environ, XBD_PREFIX=d)
    p = subprocess.run([sys.executable, os.path.join(lib, "state.py"), "--json"],
                       capture_output=True, text=True, env=env, timeout=60)
    if p.returncode != 0:
        ok(False, f"state.py 执行失败: {p.stderr[:120]}")
        return
    data = json.loads(p.stdout)
    ns = data.get("nodes") or []
    ok(bool(ns), f"state.py 列出节点（{len(ns)} 个）")
    if ns:
        ok(ns[0].get("group") == sub["id"],
           f"节点带出 group（{ns[0].get('group')!r} == {sub['id']!r}）")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default=None, help="Client/lib 目录")
    a = ap.parse_args()
    # 必须转绝对路径：下面起子进程时把 cwd 设成了临时目录，相对路径会指向那里。
    lib = os.path.abspath(a.lib or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
    sys.path.insert(0, lib)
    import subs  # noqa: E402

    tmp = tempfile.mkdtemp(prefix="xbd-selftest-")
    try:
        test_infer(subs)
        test_registry(subs, tmp)
        test_group_nodes(subs, tmp)
        test_single_node_unchanged(lib, tmp)
        test_multi(lib, tmp)
        test_build_roundtrip(lib)
        test_state_carries_group(lib, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n  {'═══'} 结果: {PASS} 通过, {FAIL} 失败 {'═══'}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())