#!/usr/bin/env python3
"""观测结果解析的落地检查（纯本地断言，不发网络请求、不碰服务）。

为什么需要它：`xrayapi.observatory_status()` 把内核的 `/debug/vars` 变成
节点列表里的"健康"列。判错的表现**不是报错，是显示一个看起来合理的错值** ——
用户照着它选节点，然后连不上。

三个坑都来自官方源码与实测，全部在这里钉死：
  1. 死节点的 delay 是**哨兵值 99999999**，而且 `alive` 字段直接缺失 ——
     只看"delay 是个数字"会得出完全相反的结论（把离线节点显示成"很快"）。
  2. burstObservatory 的 `health_ping.average` 是**纳秒**（Go time.Duration
     原值），而 `delay` 是毫秒。混用会渲染出"延迟 589528066 毫秒"。
  3. 没被 subjectSelector 覆盖的出站**根本不在结果里** —— 那是"未观测"，
     不是"离线"。所以缺失的 tag 不返回条目。

用法: python3 tools/selftest-observatory.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import urllib.request

for cand in (os.path.join(os.path.dirname(__file__), "..", "lib"),
             "/opt/xray-browser-dialer/xbd-dist/lib",
             "/opt/xray-browser-dialer/lib"):
    cand = os.path.abspath(cand)
    if os.path.exists(os.path.join(cand, "xrayapi.py")):
        LIB = cand
        break
else:
    print("找不到 xrayapi.py", file=sys.stderr)
    sys.exit(2)

spec = importlib.util.spec_from_file_location("_xa", os.path.join(LIB, "xrayapi.py"))
xa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xa)

passed = failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        print(f"  \033[32m✓\033[0m {label}")
        passed += 1
    else:
        print(f"  \033[31m✗\033[0m {label} (得到 {got!r}, 期望 {want!r})")
        failed += 1


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def with_vars(payload, fn):
    """把 /debug/vars 的响应替换成 payload，跑完还原。"""
    orig = urllib.request.urlopen
    urllib.request.urlopen = lambda *a, **k: _Resp(json.dumps(payload).encode())
    try:
        return fn()
    finally:
        urllib.request.urlopen = orig


print("=== 观测结果解析检查 ===")

# --- 1. 哨兵值 ---------------------------------------------------------------
print("\n[1] 死节点的哨兵值 99999999")
r = with_vars({"observatory": {
    "dead": {"delay": 99999999, "last_error_reason": "timeout"},
}}, lambda: xa.observatory_status(1))
check("哨兵 delay -> alive=False", r["dead"]["alive"], False)
check("哨兵 delay -> 不产出延迟数字（否则显示成'很快'）", r["dead"]["delay_ms"], None)
check("错误原因带出来（UI 能说明为什么）", r["dead"]["last_error"], "timeout")

# --- 2. burst 的纳秒 ---------------------------------------------------------
print("\n[2] burstObservatory 的 health_ping 是纳秒")
r = with_vars({"observatory": {
    "burst": {"health_ping": {"average": 589528066}},
}}, lambda: xa.observatory_status(1))
check("纳秒 -> 毫秒（/1e6）", r["burst"]["delay_ms"], 589)
check("有可用延迟即视为在线", r["burst"]["alive"], True)
r = with_vars({"observatory": {
    "normal": {"alive": True, "delay": 706},
}}, lambda: xa.observatory_status(1))
check("普通观测的 delay 本来就是毫秒（不除）", r["normal"]["delay_ms"], 706)

# --- 3. 未观测 != 离线 --------------------------------------------------------
print("\n[3] 未观测不等于离线")
r = with_vars({"observatory": {"seen": {"alive": True, "delay": 10}}},
              lambda: xa.observatory_status(1))
check("没被覆盖的 tag 不返回条目（UI 显示'未观测'）", "unseen" in r, False)
check("被覆盖的照常返回", r["seen"]["delay_ms"], 10)

# --- 4. 读不到就是空，不是"全离线" --------------------------------------------
print("\n[4] 读不到时的行为")
check("没有 observatory 键 -> {}", with_vars({"stats": {}},
      lambda: xa.observatory_status(1)), {})
check("observatory 不是 dict -> {}", with_vars({"observatory": []},
      lambda: xa.observatory_status(1)), {})
_orig = urllib.request.urlopen


def _boom(*a, **k):
    raise OSError("connection refused")


urllib.request.urlopen = _boom
try:
    check("连不上 -> {}（而不是把所有节点标成离线）", xa.observatory_status(1), {})
finally:
    urllib.request.urlopen = _orig

# --- 5. 生成配置里必须有 metrics（否则整条链没有数据源） ----------------------
print("\n[5] 配置侧：metrics 端点")
GEN = os.path.join(LIB, "genconfig.py")
src = open(GEN, encoding="utf-8").read()
check("genconfig 写了 metrics 段", '"metrics"' in src, True)
check("metrics 只绑回环（无鉴权，不能对外）", '"listen": f"127.0.0.1:{_metrics_port}"' in src, True)
check("metrics 端口经过 pick_free（固定值被占会让内核起不来）",
      "def pick_metrics_port" in src, True)
# ★ ObservatoryService 有启动期依赖：services 里写了它、而配置里没有
#   observatory / burstObservatory 时，内核**直接启动失败**：
#       Failed to create server > core: not all dependencies are resolved.
#   单节点模式本来就没有观测器 —— 加进去等于把"打开配置"变成"服务起不来"。
#   所以只看真正的 services 行，不猜。
# ★ 单节点配置（= Browser Dialer 用的那份）**不该**有 metrics。
#   BD 模式下没有观测器（探测会抢浏览器额度），健康列本来就只有"未观测"，
#   在那里开监听端口收益极低；而 selftest-groups 有一条守卫断言
#   "单节点配置与 HEAD 逐字节一致"—— 那条守卫真的拦住过这次改动。
#   这里把"不给 BD 配置加东西"也钉住，免得下次又被顺手加上。
_single = src.split('"stats": {}')[1].split("def ")[0] if '"stats": {}' in src else ""
check("单节点/BD 配置里没有 metrics（那条逐字节守卫守的就是它）",
      '"metrics"' in _single, False)

svc_lines = [ln.strip() for ln in src.splitlines() if '"services"' in ln]
check("找到 services 行", len(svc_lines) >= 2, True)
check("任何一处 services 都不含 ObservatoryService",
      any("ObservatoryService" in ln for ln in svc_lines), False)
check("多出站那份 services 含 RoutingService（bi/bo 要用）",
      any("RoutingService" in ln for ln in svc_lines), True)

print("\n" + "=" * 44)
if failed:
    print(f"观测结果解析检查: FAIL（{passed} 通过 / {failed} 失败）")
    sys.exit(1)
print(f"观测结果解析检查: PASS（{passed} 项）")
