"""Xray API 封装。

优先用 API 做运行时操作，而不是改 config.json 再重启。理由很实际：重启会断掉
所有连接，而切节点、读延迟、查流量这些操作本来都不需要重启。

只依赖 `xray api` 这个命令行，不引入 gRPC 客户端。理由：内核自带这个子命令，
没有额外的二进制、没有版本耦合、没有依赖要跟着内核走。

三个硬约束（都是实测踩出来的，不是文档写的）：

  · `bo` / `bi` 走 **RoutingService**。api.services 里少了它，调用直接失败：
    "unknown service xray.app.router.command.RoutingService"。
  · 全局 flag 放在**子命令后面**：`xray api bo --server=... -b bal node`。
    放前面会被当成未知命令。
  · balancer 没有 observatory 就选不出出站（配置层就起不来，见 genconfig）。

所有函数在 API 不可用时都要返回"不可用"而不是抛异常 —— Browser Dialer 模式是
单节点单进程，本来就没有 balancer；老内核也没有 RoutingService。UI 必须能在这
两种情况下照常工作，只是退回"重启切换"的路子。
"""

from __future__ import annotations

import json
import os
import subprocess

DEFAULT_TIMEOUT = 8


class ApiUnavailable(Exception):
    """API 不可达或内核不支持所需服务。调用方据此退回重启路径。"""


def _xray_bin() -> str:
    for c in (os.environ.get("XBD_XRAY"),
              "/opt/xray-browser-dialer/bin/xray",
              "/root/catmi/xray/xrayls"):
        if c and os.path.exists(c):
            return c
    return "xray"


def _run(server: str, args: list, timeout: int = DEFAULT_TIMEOUT) -> str:
    # --server 必须紧跟在子命令后面，不能拼到最后。
    # 实测: `xray api bo -b bal node --server=X` 会**静默**去连默认的 127.0.0.1:8080
    # 然后报 "failed to dial 127.0.0.1:8080" —— 报错说的是默认端口，看不出是参数
    # 位置错了，很容易误判成"API 没开"。放在子命令后面才生效。
    cmd = [_xray_bin(), "api", args[0], "--server=" + server] + list(args[1:])
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as e:
        raise ApiUnavailable(f"找不到 xray 可执行文件: {e}") from e
    except subprocess.TimeoutExpired as e:
        raise ApiUnavailable("API 调用超时") from e
    if p.returncode != 0:
        raise ApiUnavailable((p.stderr or p.stdout or "").strip().splitlines()[:1][0]
                             if (p.stderr or p.stdout) else f"退出码 {p.returncode}")
    return p.stdout


def _json(server: str, args: list, timeout: int = DEFAULT_TIMEOUT):
    out = _run(server, args, timeout)
    try:
        return json.loads(out)
    except ValueError as e:
        raise ApiUnavailable("API 返回的不是 JSON") from e


def available(server: str) -> bool:
    try:
        _run(server, ["lso"])
        return True
    except ApiUnavailable:
        return False


def switch_node(server: str, balancer: str, tag: str) -> None:
    """把 balancer 的选择钉到指定出站。进程不重启，连接不断。"""
    _run(server, ["bo", "-b", balancer, tag])


def clear_override(server: str, balancer: str) -> None:
    """撤掉人工指定，交回观测器自动选（"自动选最快"）。"""
    _run(server, ["bo", "-b", balancer, "-r"])


def balancer_info(server: str, balancer: str) -> dict:
    """当前选中了谁、候选有哪些。

    Xray 这里返回的是文本而不是 JSON（`- Selecting Override:` / `- Selects:`），
    所以只能按行解析。已验证的格式就这两种，认不出来就返回空 dict 而不是猜。
    """
    try:
        out = _run(server, ["bi", balancer])
    except ApiUnavailable:
        return {}
    override, selects, mode = "", [], ""
    for line in out.splitlines():
        t = line.strip()
        if t.startswith("- Selecting Override:"):
            mode = "override"
            continue
        if t.startswith("- Selects:"):
            mode = "selects"
            continue
        # 条目形如 `1   node-002-x`，序号后是 tag；正文没有别的行是这个形状。
        # 只有序号没有 tag 的行必须跳过 —— 未设置覆盖时这一节会渲染成一个光秃秃
        # 的 `1`，按 split()[-1] 取会把序号当成节点名，于是"未指定"变成"当前是
        # 名为 1 的节点"。
        if mode and t and t[0].isdigit():
            parts = t.split()
            if len(parts) < 2:
                continue
            tag = parts[-1]
            if mode == "override":
                override = tag
            else:
                selects.append(tag)
    return {"override": override, "selects": selects}


def node_stats(server: str) -> dict:
    """每个出站的上下行字节数。

    内核对计到 0 的项不返回 `value` 字段，所以取值要容错 —— 直接 stat['value']
    会在"某节点一次都没通过"时抛 KeyError。
    """
    data = _json(server, ["statsquery", "-pattern", "outbound"])
    out = {}
    for s in data.get("stat") or []:
        name = s.get("name") or ""
        if not name.startswith("outbound>>>"):
            continue
        parts = name.split(">>>")
        if len(parts) < 4:
            continue
        tag, direction = parts[1], parts[3]
        rec = out.setdefault(tag, {"uplink": 0, "downlink": 0})
        rec[direction] = int(s.get("value") or 0)
    return out


# 观测结果的读法 —— 走 metrics 的只读 HTTP 端点, 不走 gRPC。
#
# 为什么不走 gRPC 的 ObservatoryService: 官方源码里那个服务**有启动期依赖** ——
# services 写了它但配置里没有 observatory/burstObservatory 时, 内核直接
#     Failed to create server > core: not all dependencies are resolved.
# 而单节点模式本来就没有观测器。metrics 没这个问题, 而且官方文档化了
# (metrics.html 明确写: `observatory` 包含观测结果)。
#
# 死节点的判据有**三个坑**, 都来自官方源码与实测:
#   1. delay 的哨兵值是 **99999999**, 而且 alive 字段**直接缺失** ——
#      只看 delay 是个数字就当成"在线且很快"会得到完全相反的结论。
#   2. burstObservatory 的 health_ping.average 是**纳秒** (Go time.Duration
#      原值), 而 delay 是毫秒。混用会渲染出"延迟 589528066 毫秒"。
#   3. 没被 subjectSelector 覆盖的出站**根本不在结果里** —— 那是"未观测",
#      不是"离线"。所以缺的 tag 不返回条目, 由调用方显示"未观测"。
OBS_SENTINEL = 99999999


def observatory_status(port: int, timeout: int = 5) -> dict:
    """{tag: {"alive": bool|None, "delay_ms": int|None, "last_error": str}}

    读不到就返回 {} —— 调用方据此显示"未知", 而不是把所有节点标成离线。
    """
    import urllib.request

    url = f"http://127.0.0.1:{int(port)}/debug/vars"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
    except Exception:
        return {}
    obs = data.get("observatory") or {}
    if not isinstance(obs, dict):
        return {}

    out = {}
    for tag, v in obs.items():
        if not isinstance(v, dict):
            continue
        alive = v.get("alive")
        delay_ms = None

        raw = v.get("delay")
        if isinstance(raw, (int, float)):
            if int(raw) >= OBS_SENTINEL:
                alive = False            # 哨兵值 = 探测超时/失败
            else:
                delay_ms = int(raw)

        # burst 的 health_ping 是纳秒；只有拿不到 delay 时才退到它
        if delay_ms is None:
            avg = (v.get("health_ping") or {}).get("average")
            if isinstance(avg, (int, float)) and 0 < avg < OBS_SENTINEL * 1_000_000:
                delay_ms = int(avg / 1_000_000)

        # 有可用延迟但没显式 alive -> 视为在线 (官方只在失败时才写 alive=false)
        if alive is None and delay_ms is not None:
            alive = True

        out[tag] = {
            "alive": alive,
            "delay_ms": delay_ms,
            "last_error": str(v.get("last_error_reason") or ""),
            "last_seen": str(v.get("last_seen_time") or ""),
        }
    return out


def outbounds(server: str) -> list:
    data = _json(server, ["lso"])
    return [o.get("tag") for o in (data.get("outbounds") or []) if o.get("tag")]


def logger_restart(server: str) -> None:
    """配合 logrotate：转储完日志让内核重开文件。"""
    _run(server, ["restartlogger"])