#!/usr/bin/env python3
"""运行状态收集：把"到底在用什么模式、哪些在跑"讲清楚。

架构：**唯一一个 Xray 实例**，同时提供 SOCKS 与 HTTP 两个 LAN 入站，并始终带
XRAY_BROWSER_DIALER —— 因此 "Browser Dialer" 不是模式，而是节点的一个属性：
当前节点是 xhttp/websocket 且非 REALITY 时，Xray 把 TLS 交给 Chromium，否则自己完成。

所以这里判定的是"这个实例健不健康"：
    1. Xray 在跑 + Chromium 在跑 -> mode = ready（两个端口全部可用，含 BD 节点）
    2. Xray 在跑 + Chromium 停了 -> mode = degraded（BD 节点会拨号失败，其他节点照常）
    3. Xray 没跑                 -> mode = stopped
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")

U_XRAY = "xray-client.service"
U_CHROMIUM = "chromium-browser-dialer.service"
U_PANEL = "browser-dialer-panel.service"
U_TIMER = "browser-dialer-health.timer"

MODE_READY = "ready"
MODE_DEGRADED = "degraded"
MODE_STOPPED = "stopped"

MODE_LABEL = {
    MODE_READY: "就绪",
    MODE_DEGRADED: "降级（Chromium 未运行，而当前节点需要它）",
    MODE_STOPPED: "已停止",
}


def sh(args, timeout=20):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def cfg_get(path, key, default=""):
    try:
        for line in open(path):
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return default


def unit_info(unit):
    rc, out, _ = sh(["systemctl", "is-active", unit])
    active = out == "active"
    rc2, enabled, _ = sh(["systemctl", "is-enabled", unit])
    rc3, since, _ = sh(["systemctl", "show", unit, "-p", "ActiveEnterTimestamp", "--value"])
    return {"unit": unit, "active": active, "state": out or "unknown",
            "enabled": enabled == "enabled", "since": since}


def port_listening(port):
    rc, out, _ = sh(["ss", "-H", "-tln"])
    if rc != 0:
        return False
    return any(line.split()[3].endswith(f":{port}") for line in out.splitlines() if len(line.split()) >= 4)


def ws_count(addr):
    rc, out, _ = sh(["ss", "-H", "-tn"])
    if rc != 0:
        return 0
    return sum(1 for line in out.splitlines() if addr in line)


def count_procs(name, exact=False):
    """pgrep -c 在部分实现下会输出多行，只取第一行。"""
    args = ["pgrep", "-c"] + (["-x"] if exact else []) + [name]
    rc, out, _ = sh(args)
    # pgrep -c 输出的是**计数本身**（单个整数），取第一行即正确。
    # 不要改成"数行数"：那会得到 1（实测验证过）。
    # 真正的坑在别处：不带 -x 时 pgrep 会把调用者自己也算进去。
    first = (out or "").strip().splitlines()
    try:
        return int(first[0]) if first else 0
    except (ValueError, IndexError):
        return 0


def chromium_procs():
    # exact=True 是必须的：不加 -x 时 pgrep 会连调用者所在的命令行一起匹配。
    return count_procs("chromium", exact=True)


def xray_procs():
    # 精确匹配：否则会匹配到 xbd 脚本自身的命令行（里面含 xray 字样）
    return count_procs("xray", exact=True)


def load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def nodes_dir():
    """节点列表。判定一律实时算，不读文件里的 _compat 缓存 ——
    缓存写于导入那一刻，Xray 升级或判定逻辑改动后它不会更新，于是两个内容完全
    相同的节点会一个显示"支持"一个显示"不支持"（实测踩过），而错的那个反而被当真。"""
    d = os.path.join(PREFIX, "nodes")
    files = []
    if not os.path.isdir(d):
        return files, ""
    compat_mod = None
    compat_py = os.path.join(PREFIX, "xbd-dist", "lib", "compat.py")
    if not os.path.exists(compat_py):
        compat_py = os.path.join(PREFIX, "lib", "compat.py")
    if os.path.exists(compat_py):
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location("_xbd_compat_list", compat_py)
            compat_mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(compat_mod)
        except Exception:
            compat_mod = None
    current = ""
    link = os.path.join(d, "current")
    if os.path.islink(link):
        current = os.path.basename(os.path.realpath(link))
    for name in sorted(os.listdir(d)):
        if name.startswith("node-") and name.endswith(".json"):
            data = load_json(os.path.join(d, name)) or {}
            caps = {}
            if compat_mod is not None:
                try:
                    caps = compat_mod.check_all(data)
                except Exception:
                    caps = {}
            files.append({
                "file": name,
                "name": data.get("name") or data.get("address") or name,
                # 所属分组（订阅 id）。必须带出去: 这里是节点信息的唯一出口,
                # 少带一个字段, 下游的分组就只能退回按名字猜 —— 机场改了节点
                # 命名, 用户昨天记住的分组今天就对不上。
                "group": data.get("group", ""),
                "protocol": data.get("protocol", ""),
                "transport": data.get("transport", ""),
                "security": data.get("security", "none"),
                "address": data.get("address", ""),
                "port": data.get("port", 0),
                "ech": bool(data.get("ech")),
                "current": name == current,
                "compat": caps,
                # 这个节点是否用浏览器完成 TLS（None=默认，True/False=用户显式选择）
                "use_browser": data.get("use_browser", None),
                # 实测结果（tools/browserprobe.py 写的）。面板用它显示"实测可用/失败"，
                # 而不是只凭配置推断 —— 配置合法不等于能通（实测过同一套配置不同服务器结果相反）。
                "probe_ok": (data.get("browser_probe") or {}).get("ok"),
            })
    return files, current


def build_state(deep: bool = True) -> dict:
    ports = os.path.join(PREFIX, "config", "ports.env")
    p_normal = int(cfg_get(ports, "PORT_NORMAL", "1080"))
    p_http = int(cfg_get(ports, "PORT_HTTP", "10808"))
    p_lan_http = int(cfg_get(ports, "PORT_LAN_HTTP", "10809"))
    listen = cfg_get(ports, "LISTEN_ADDR", "127.0.0.1")
    dialer_addr = cfg_get(ports, "DIALER_ADDR", "127.0.0.1:18081")
    panel_env = os.path.join(PREFIX, "config", "panel.env")
    panel_host = cfg_get(panel_env, "PANEL_HOST", "127.0.0.1")
    panel_port = cfg_get(panel_env, "PANEL_PORT", "18090")

    # 内核版本：面板里有这一行, 命令行也得有 —— 用户排查时最常问的就是
    # "我这是哪个版本"。本地二进制, 调用开销可忽略（已实测 <20ms）。
    xray_ver = ""
    # 浏览器运行时：Browser Dialer 的依赖。装没装、哪个版本 —— 面板要显示。
    browser_path, browser_ver = "", ""
    try:
        rc, out, _ = sh([os.path.join(PREFIX, "bin", "xray"), "version"], timeout=10)
        if rc == 0 and len(out.split()) > 1:
            xray_ver = out.split()[1]
    except Exception:                                            # noqa: BLE001
        pass

    try:
        import shutil as _sh
        for _c in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable"):
            _p = _sh.which(_c)
            if _p:
                browser_path = _p
                break
        if browser_path:
            _rc, _out, _ = sh([browser_path, "--version"], timeout=10)
            browser_ver = (_out or "").strip().splitlines()[0] if _rc == 0 else ""
    except Exception:                                            # noqa: BLE001
        pass

    ux = unit_info(U_XRAY)
    uc = unit_info(U_CHROMIUM)
    up = unit_info(U_PANEL)
    ut = unit_info(U_TIMER)

    # Chromium 没跑**不等于**降级 —— 要看当前节点是否真的需要它。
    # 曾经只要 Chromium 不在跑就报 degraded，于是用户主动把节点设成原生 TLS 后，
    # 界面一直显示"降级（Browser Dialer 节点不可用）"，而他其实一切正常。
    # 判据与 run-xray.sh / health-check.sh 共用同一套语义。
    _need = False
    try:
        _curn = load_json(os.path.join(PREFIX, "nodes", current)) or {}
        _proto = (_curn.get("protocol") or "").lower()
        _tr = (_curn.get("transport") or "").lower()
        _tr = {"ws": "websocket", "splithttp": "xhttp"}.get(_tr, _tr)
        _sec = (_curn.get("security") or "none").lower()
        _may = _proto == "vless" and _tr in ("websocket", "xhttp") and _sec != "reality"
        _need = _may and _curn.get("use_browser", None) is not False
    except Exception:
        _need = False

    if not ux["active"]:
        mode = MODE_STOPPED
    elif not uc["active"] and _need:
        mode = MODE_DEGRADED          # 真需要浏览器却没跑，才叫降级
    else:
        mode = MODE_READY

    nodes, current = nodes_dir()
    cur_node = next((n for n in nodes if n["current"]), None)

    ws = ws_count(dialer_addr)

    result = {
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "xray_ver": xray_ver,
        "browser_path": browser_path,
        "browser_ver": browser_ver,
        "mode": mode,
        "mode_label": MODE_LABEL[mode],
        # 一句话说清当前到底在跑什么、当前节点走哪条路 —— 不写死"Xray + Chromium"，
        # 那会在 Chromium 本来就不需要跑（节点走原生 TLS）时误导。
        "mode_detail": (
            "Xray 未运行" if mode == MODE_STOPPED
            else ("Xray 在跑；当前节点需要浏览器，但 Chromium 未运行" if mode == MODE_DEGRADED
                  else ("Xray + Chromium 都在跑（当前节点走浏览器 TLS）" if uc["active"]
                        else "Xray 在跑；当前节点走 Xray 自带 TLS，Chromium 无需运行"))
        ),
        "services": {"xray": ux, "chromium": uc, "panel": up, "health_timer": ut},
        "ports": {
            "normal": p_normal, "http": p_http, "lan_http": p_lan_http, "listen": listen,
            "dialer_addr": dialer_addr,
            "normal_up": port_listening(p_normal),
            "http_up": port_listening(p_http),
            "lan_http_up": port_listening(p_lan_http),
        },
        "chromium_procs": chromium_procs(),
        "xray_procs": xray_procs(),
        "ws_connections": ws,
        "node": cur_node,
        "nodes": nodes,
        "project_installed": os.path.exists(os.path.join(PREFIX, "bin", "xray")),
    }

    # Browser Dialer 可用性：当前节点能不能用浏览器拨号
    if cur_node and deep:
        node_path = os.path.join(PREFIX, "nodes", cur_node["file"])
        node = load_json(node_path)
        if node:
            # 直接 import compat，省掉一次子进程与临时文件
            compat_py = os.path.join(PREFIX, "xbd-dist", "lib", "compat.py")
            if os.path.exists(compat_py):
                try:
                    import importlib.util
                    spec = importlib.util.spec_from_file_location("_xbd_compat", compat_py)
                    mod = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(mod)
                    result["compat"] = mod.check_all(node)
                except Exception:
                    pass

    # 当前节点的浏览器开关提到顶层 —— 面板的按钮要用它判断"当前该不该走浏览器"。
    # 只从列表里取会漏掉"节点文件有、但面板读的是旧缓存"这类情况，所以明确提上来。
    if cur_node:
        try:
            _cur = load_json(os.path.join(PREFIX, "nodes", cur_node["file"])) or {}
            result["use_browser"] = _cur.get("use_browser", None)
            result["probe_ok"] = (_cur.get("browser_probe") or {}).get("ok")
        except Exception:
            result["use_browser"] = None
            result["probe_ok"] = None

    can_dialer = bool(result.get("compat", {}).get("can_use_dialer"))
    result["can_use_dialer"] = can_dialer
    result["dialer_reason"] = ""
    if cur_node and not can_dialer:
        notes = result.get("compat", {}).get("dialer", {}).get("notes") or []
        result["dialer_reason"] = notes[0] if notes else "该节点不满足 Browser Dialer 条件"

    # 出口 IP 只在需要时探测，避免每次轮询都走一遍网络。
    # 只探测 SOCKS：HTTP 入站由同一个实例服务，出口必然一致。
    if deep and result["ports"]["normal_up"]:
        rc, out, _ = sh(["curl", "-s", "--max-time", "15", "--socks5-hostname",
                         f"{listen}:{p_normal}", "https://api.ipify.org"], timeout=25)
        result["exit_ip"] = out if rc == 0 else ""
        result["proxy_ok"] = rc == 0 and bool(out)
    else:
        result["exit_ip"] = ""
        result["proxy_ok"] = False

    return result


def _disp_w(t: str) -> int:
    """显示宽度：中文/全角算两列。

    printf 与 python 的 %-Ns 都按**字节或字符数**补齐，中文标签会参差不齐 ——
    竖着看对不齐的键值块，比不带冒号还难读。
    """
    import unicodedata
    w = 0
    for ch in t:
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def _is_tty() -> bool:
    import os as _os
    if _os.environ.get("XBD_PLAIN"):
        return False
    try:
        return sys.stdout.isatty()
    except Exception:                                            # noqa: BLE001
        return False


# ANSI 只在终端里给。管道/日志里带转义序列 = 一片乱码（实测过）。
_C = {"g": "\033[32m", "y": "\033[33m", "r": "\033[31m", "b": "\033[36m",
      "d": "\033[2m", "0": "\033[0m"}


def _c(key: str, text: str) -> str:
    if not _is_tty():
        return text
    return f"{_C[key]}{text}{_C['0']}"


def cmd_status_text(state: dict) -> str:
    """给人看的状态块。

    与网页面板同一套信息、同一套中文标签 —— 命令行和面板各叫一个名字
    （"Connection Mode" / "连接模式"）是最容易让人怀疑"这俩是不是两个东西"
    的地方。
    """
    svc = state["services"]

    def dot(on):
        return _c("g", "●") if on else _c("y", "○")

    def state_cn(on, yes="运行中", no="未运行"):
        return _c("g", yes) if on else _c("y", no)

    rows = []
    x = svc["xray"]
    rows.append(("服务状态", f'{dot(x["active"])} '
                 + (state_cn(True) if x["active"] else state_cn(False, no=x["state"]))))

    mode = state["mode_label"] + (" —— " + state["mode_detail"] if state.get("mode_detail") else "")
    rows.append(("连接方式", mode))

    node = state.get("node")
    rows.append(("当前节点", (node["name"] if node else _c("d", "（未选择）"))))
    if state.get("xray_ver"):
        rows.append(("内核版本", f'Xray {state["xray_ver"]}'))

    ports = state["ports"]

    def ep(label, host, port, up):
        return f'{label} {host}:{port} ' + (_c("g", "✓") if up else _c("y", "（未监听）"))

    rows.append(("代理入口", ep("SOCKS5", ports["listen"], ports["normal"], ports["normal_up"])))
    rows.append(("", ep("HTTP  ", ports["listen"], ports["lan_http"], ports["lan_http_up"])))
    rows.append(("", ep("本机  ", "127.0.0.1", ports["http"], ports["http_up"])))

    ch = svc["chromium"]
    ch_txt = state_cn(True) if ch["active"] else state_cn(False, no="未运行")
    if ch["active"] and state.get("chromium_procs"):
        ch_txt += f'（{state["chromium_procs"]} 进程）'
    if node and not state.get("can_use_dialer"):
        # 明确说清"不需要它"而不是让人以为坏了 —— 这是最容易误解的一行
        ch_txt += _c("d", "（当前节点不需要：走 Xray 自带 TLS）")
    rows.append(("浏览器拨号", ch_txt))

    if state.get("browser_path"):
        rows.append(("浏览器", f'{state["browser_path"]}'
                     + (f'  {state["browser_ver"]}' if state.get("browser_ver") else '')))
    else:
        rows.append(("浏览器", _c("y", "未安装 —— 依赖浏览器拨号的节点会不可用")
                     + _c("d", "（xbd browser install）")))
    rows.append(("出口 IP", state["exit_ip"] or _c("d", "（未探测）")))
    panel_host = cfg_get(os.path.join(PREFIX, "config", "panel.env"), "PANEL_HOST", "127.0.0.1")
    panel_port = cfg_get(os.path.join(PREFIX, "config", "panel.env"), "PANEL_PORT", "18090")
    rows.append(("网页面板", f'{dot(svc["panel"]["active"])} http://{panel_host}:{panel_port}/'))

    width = 44
    out = [_c("b", "─" * width)]
    for k, v in rows:
        # 冒号必须落在同一列: 1(前导空格) + 键宽 + 补白 = 12
        out.append(f' {k}{" " * max(1, 12 - _disp_w(k))}: {v}' if k
                   else f' {" " * 11}: {v}')
    out.append(_c("b", "─" * width))
    if node and state.get("dialer_reason") and not state.get("can_use_dialer"):
        out.append(_c("d", " 说明: " + str(state["dialer_reason"])[:160]))
    out.append(_c("d", " 详情: xbd diagnose ｜ 网页面板里能点着改"))
    return "\n".join(out)


def main(argv) -> int:
    as_json = "--json" in argv
    quick = "--quick" in argv
    state = build_state(deep=not quick)
    if as_json:
        print(json.dumps(state, ensure_ascii=False, indent=2))
    else:
        print(cmd_status_text(state))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
