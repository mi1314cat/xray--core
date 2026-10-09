#!/usr/bin/env python3
"""Xray Client Web Manager — 面板后端。

设计要点：
    * **唯一一个 Xray 实例**，同时提供 SOCKS 与 HTTP 两个 LAN 入站，并始终带
      XRAY_BROWSER_DIALER —— 所以不存在"普通模式 / Browser Dialer 模式"的切换，
      也没有第二条 SOCKS 端口。节点是共享资产，换节点不改任何服务。
    * Browser Dialer 是**节点的属性**：当前节点是 xhttp/websocket 且非 REALITY 时
      Xray 把 TLS 交给 Chromium，否则自己完成 TLS。状态栏如实显示"这个节点走哪条路"。
    * Chromium 是 Browser Dialer 的运行时依赖，面板只控制它开/关：
      它是唯一实例的常驻依赖，停掉后依赖浏览器拨号的节点会失败，其余节点不受影响。

安全：只监听配置里的地址；可选访问令牌；动作走白名单，参数以 argv 传递。
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
DIST = os.path.join(PREFIX, "xbd-dist")
NODES = os.path.join(PREFIX, "nodes")
CONF = os.path.join(PREFIX, "config")
RUNTIME = os.path.join(PREFIX, "runtime")

U_XRAY = "xray-client.service"
U_CHROMIUM = "chromium-browser-dialer.service"
U_PANEL = "browser-dialer-panel.service"
U_TIMER = "browser-dialer-health.timer"

STATE_PY = os.path.join(DIST, "lib", "state.py")
COMPAT_PY = os.path.join(DIST, "lib", "compat.py")
NODE_PY = os.path.join(DIST, "lib", "node.py")
GENCONFIG_PY = os.path.join(DIST, "lib", "genconfig.py")

sys.path.insert(0, os.path.join(DIST, "lib"))
import subs as _subs          # noqa: E402
import xrayapi                 # noqa: E402

# 多出站模式下 balancer 的名字。与 genconfig.py 的 BALANCER 必须一致。
BALANCER = "xbd-bal"

BIND_HOST = "127.0.0.1"
BIND_PORT = 18090


# --------------------------------------------------------------------- 工具 ----
def sh(args, timeout=60, stdin=None):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, input=stdin)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def sh_bg(args):
    """后台执行，用于会重启自身所在单元的动作（否则会把自己的响应掐掉）。"""
    try:
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
        return True
    except OSError:
        return False


def cfg_get(path, key, default=""):
    try:
        for line in open(path):
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return default


def cfg_set(path, key, value):
    lines, found = [], False
    try:
        lines = open(path).read().splitlines()
    except OSError:
        pass
    out = []
    for line in lines:
        if line.startswith(key + "="):
            out.append(f"{key}={value}")
            found = True
        else:
            out.append(line)
    if not found:
        out.append(f"{key}={value}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")


def unit_state(unit):
    rc, out, _ = sh(["systemctl", "is-active", unit], timeout=10)
    rc2, en, _ = sh(["systemctl", "is-enabled", unit], timeout=10)
    return {"state": out or "unknown", "active": out == "active", "enabled": en == "enabled"}


# ---------------------------------------------------------------------- 状态 ----
def build_state():
    rc, out, err = sh(["python3", STATE_PY, "--json"], timeout=60)
    if rc != 0 or not out:
        return {"error": err or "state.py 执行失败", "services": {}, "nodes": []}
    try:
        state = json.loads(out)
    except ValueError:
        return {"error": "状态解析失败", "services": {}, "nodes": []}

    state["services_extra"] = {"panel": unit_state(U_PANEL), "timer": unit_state(U_TIMER)}
    state["doh"] = cfg_get(os.path.join(CONF, "chromium.env"), "XBD_DOH", "")
    _dm = cfg_get(os.path.join(CONF, "dns.env"), "DNS_MODE", "off")
    state["dns_mode"] = _dm if _dm in ("off", "standard", "strict") else "off"
    # 多出站状态要一起给出。开关和运行配置可能不一致（改了没 apply），
    # 所以两个都报，面板上才看得出"我开了但没生效"这种状态。
    state["multi_mode"] = multi_mode()
    # 实际生效的模式由 run-xray.sh 落盘。以它为准，而不是靠开关推断 ——
    # 开关和运行状态不一致是会出现的情况（改了没重启、降级过）。
    try:
        with open(os.path.join(RUNTIME, "multi.actual"), encoding="utf-8") as fh:
            state["multi_active"] = (fh.read().strip() == "multi")
    except OSError:
        # 落盘文件还没有（老版本升级上来的），退回看配置里有没有 balancer
        try:
            with open(os.path.join(RUNTIME, "xray-client.json"), encoding="utf-8") as fh:
                state["multi_active"] = ("\"balancerTag\"" in fh.read())
        except OSError:
            state["multi_active"] = state["multi_mode"] == "on"

    ports = os.path.join(CONF, "ports.env")
    state["ports_cfg"] = {
        "normal": cfg_get(ports, "PORT_NORMAL", "1080"),
        "http": cfg_get(ports, "PORT_HTTP", "10808"),
        "lan_http": cfg_get(ports, "PORT_LAN_HTTP", "10809"),
        "listen": cfg_get(ports, "LISTEN_ADDR", "127.0.0.1"),
        "channel": (cfg_get(ports, "DIALER_ADDR", "127.0.0.1:18081").rpartition(":")[2]),
        "api": cfg_get(os.path.join(CONF, "api.env"), "API_PORT", "18085"),
    }

    # 本机接管：不能只看 proxy.sh —— 接管点可能落在**别人**原有的配置里
    # （xbd proxy on 是"改配置而非新增"）。真相只有一个来源：xbd proxy json。
    rc, out, _ = sh([os.path.join(PREFIX, "bin", "xbd"), "proxy", "json"], timeout=30)
    try:
        local = json.loads((out or "").strip().splitlines()[-1])
    except (ValueError, IndexError):
        local = {}
    state["takeover_local"] = bool(local.get("enabled"))
    state["takeover_local_files"] = [f for f in (local.get("shell"), local.get("docker"),
                                                 local.get("environment")) if f]
    state["takeover_local_owners"] = int(local.get("owners") or 0)
    state["xray_ver"] = ""
    rc, out, _ = sh([os.path.join(PREFIX, "bin", "xray"), "version"], timeout=15)
    if rc == 0 and len(out.split()) > 1:
        state["xray_ver"] = out.split()[1]

    # 分组：订阅注册表 + 名字前缀推断。见 subs.group_nodes 的说明。
    # 节点上顺带带回 group_key / group_name，前端按它做折叠、筛选和高亮。
    try:
        state["groups"] = _subs.group_nodes(PREFIX, state.get("nodes") or [])
    except Exception as e:                      # noqa: BLE001
        # 分组只是展示层的便利。出问题时退回扁平列表，不能因此让面板打不开。
        state["groups"] = []
        state["group_error"] = str(e)

    # 运行时状态：balancer 选了谁 + 每节点流量。API 不可用时置 unavailable，
    # 前端据此隐藏"自动选"和流量列，而不是显示一堆 0。
    api = {"available": False}
    srv = api_server()
    try:
        if xrayapi.available(srv):
            api = {"available": True, "balancer": xrayapi.balancer_info(srv, BALANCER),
                   "traffic": xrayapi.node_stats(srv)}
    except xrayapi.ApiUnavailable as e:
        api = {"available": False, "error": str(e)}
    state["api"] = api
    return state


def node_path(ident):
    """把编号或文件名解析成绝对路径，并确保它落在 nodes/ 内。"""
    ident = str(ident)
    if ident.isdigit():
        import glob
        files = sorted(glob.glob(os.path.join(NODES, "node-*.json")))
        idx = int(ident) - 1
        if 0 <= idx < len(files):
            return files[idx]
        return None
    if "/" in ident or not ident.startswith("node-"):
        return None
    p = os.path.join(NODES, ident)
    return p if os.path.exists(p) else None


def compat_of(path):
    rc, out, _ = sh(["python3", COMPAT_PY, "json", path], timeout=30)
    if rc in (0, 1) and out:
        try:
            return json.loads(out)
        except ValueError:
            pass
    return {}


# ------------------------------------------------------------------- 动作 ----
def act_build_link(p):
    """手动添加表单 → 分享链接。

    只做拼装，不落盘：拼出来的链接立刻交给既有的 import 路径，走同一套解析与
    能力检查。这里一旦自己写节点，等于多出一条导入通道，两边字段行为不一致时
    排查成本极高。

    返回 (True, 链接)。走 DISPATCH 的两元组约定 —— 那套约定没法带第三个字段，
    硬塞 dict 会让调用处解包失败。链接当"消息"返回，前端从 message 取。
    """
    payload = {k: v for k, v in (p or {}).items() if k != "action"}
    missing = {"protocol", "address"} - {
        k for k, v in payload.items() if str(v or "").strip()}
    if missing:
        return False, "缺少字段: " + ", ".join(sorted(missing))
    try:
        payload["port"] = int(payload.get("port") or 443)
    except (TypeError, ValueError):
        return False, "端口不是数字"
    rc, out, err = sh([sys.executable, NODE_PY, "build", "-"], timeout=20,
                      stdin=json.dumps(payload))
    if rc != 0:
        return False, (err or out or "生成分享链接失败").strip()
    return True, out.strip()


def act_group_create(name):
    """新建一个自定义分组。

    用途是把手动加的节点归到一起，而不是每个手动节点自己一组 —— 后者会把
    组列表淹成几十行单节点条目（metacubexd 和 zashboard 都为此改过版式）。
    """
    if not name:
        return False, "分组名不能为空"
    if len(name) > 40:
        return False, "分组名太长（最多 40 字）"
    sys.path.insert(0, os.path.join(DIST, "lib"))
    import subs as _subs
    try:
        rec = _subs.add_sub(PREFIX, "local:" + str(time.time()), name, kind="local")
    except Exception as e:                       # noqa: BLE001
        return False, f"创建分组失败: {e}"
    return True, rec["id"]


def act_group_delete(key):
    """删除一个分组。

    不可撤销，所以前端已经把"连带删掉 N 个节点"写进确认框了。这里不再问一遍。
    删的是节点文件本体，不是只删分组记录 —— 只删记录的话，那些节点会变成
    无归属状态，下次分组靠名字猜到「其它」里去，用户以为删掉了其实还在。
    """
    if not key or key == "__all__":
        return False, "「全部」不是分组，不能删除"
    nodes_dir = os.path.join(PREFIX, "nodes")
    cur = os.path.realpath(os.path.join(nodes_dir, "current"))
    doomed, keep = [], []
    for f in sorted(os.listdir(nodes_dir)):
        if not f.endswith(".json"):
            continue
        p = os.path.join(nodes_dir, f)
        if os.path.islink(p):
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                nd = json.load(fh)
        except (OSError, ValueError):
            keep.append(f)
            continue
        (doomed if nd.get("group") == key else keep).append(f)

    # 当前节点正要被删掉：先把 current 挪走，免得留下一个指向不存在文件的
    # 符号链接 —— 那样 xbd 之后的每一次读取都会失败，且报的是"找不到节点"。
    cur_link = os.path.join(nodes_dir, "current")
    if any(os.path.realpath(os.path.join(nodes_dir, f)) == cur for f in doomed) and keep:
        tmp = cur_link + ".new"
        os.symlink(keep[0], tmp)
        os.replace(tmp, cur_link)      # 换符号链接必须走 replace, unlink+symlink
                                          # 中间有个"链接不存在"的瞬间

    for f in doomed:
        try:
            os.remove(os.path.join(nodes_dir, f))
        except OSError:
            pass
    sys.path.insert(0, os.path.join(DIST, "lib"))
    import subs as _subs
    _subs.drop_sub(PREFIX, key, keep_nodes=False)
    return True, f"已删除分组及其 {len(doomed)} 个节点"


DNS_LABELS = {"off": "不接管（使用系统 DNS）",
              "standard": "标准（境外加密 DNS + 国内加密 DNS）",
              "strict": "严格防泄漏（全部加密 DNS 且强制经代理）"}


def act_dns_set(mode):
    """切换 DNS 模式。

    切换会改运行配置，所以要重启 Xray 才生效 —— 这一点必须说清楚。
    面板上改完看着像生效了、实际没生效，是这类开关最容易出的问题。
    """
    if mode not in DNS_LABELS:
        return False, f"未知 DNS 模式: {mode}"
    os.makedirs(CONF, exist_ok=True)
    cfg_set(os.path.join(CONF, "dns.env"), "DNS_MODE", mode)
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "restart"], timeout=120)
    if rc != 0:
        # 配置已经写下去了，重启失败时要说清楚，否则用户改了却看不到变化，
        # 会以为按钮坏了。
        return False, (err or out or "重启失败").strip() + "（设置已保存，下次重启生效）"
    return True, f"DNS 已切换为「{DNS_LABELS[mode]}」并重启"


def multi_mode():
    """读多出站开关。缺文件 = 关（与 run-xray.sh 的默认一致）。"""
    f = os.path.join(CONF, "multi.env")
    v = cfg_get(f, "MULTI_OUTBOUND", "off")
    return "on" if str(v).strip().lower() in ("on", "1", "true") else "off"


def act_multi_set(mode):
    """切换多出站。

    和 DNS 开关一样：改完必须重启才生效，所以这里直接重启而不是让用户自己记。
    多出站开启后重启更久（要校验所有节点），超时给足。
    """
    if mode not in ("on", "off"):
        return False, f"未知取值: {mode}"
    os.makedirs(CONF, exist_ok=True)
    cfg_set(os.path.join(CONF, "multi.env"), "MULTI_OUTBOUND", mode)
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "restart"], timeout=180)
    if rc != 0:
        return False, (err or out or "重启失败").strip() + f"（设置已保存，{'已开启' if mode=='on' else '已关闭'}）"
    if mode == "on":
        return True, "多出站已开启 · 切换节点不再需要重启"
    return True, "已回到单节点 · 切换节点会重启（连接断 1-2 秒）"


def act_import(uri, sub_name=""):
    # 超时给 300 秒：导入自签证书节点时会顺手编译证书探针（go build quic-go），
    # 冷构建实测 114 秒 —— 原来卡在 120 秒，首次导入经常被杀在半路。
    args = [os.path.join(PREFIX, "bin", "xbd"), "node", "add"]
    # 只在确实是订阅地址时才传组名。分享链接也传的话会被当成一条名为空的
    # 订阅登记，生成一个永远只有一个节点的组。
    if sub_name and uri.startswith(("http://", "https://")):
        args += [uri, sub_name]
    else:
        args += [uri]
    rc, out, err = sh(args, timeout=300)
    return rc == 0, (out or err)


def api_server():
    """Xray API 地址。端口以 config/api.env 为准 —— 面板上能改端口，改完必须
    真的生效，所以这里每次现读，不能用启动时的默认值。"""
    return "127.0.0.1:" + cfg_get(os.path.join(CONF, "api.env"), "API_PORT", "18085")


def multi_node_outbound(tag):
    """把节点文件名换算成多出站配置里的出站 tag。

    规则必须和 genconfig.py 里完全一致（剥掉文件名自带的 node- 前缀再补一个）。
    两边一旦不一致，切换就会报"balancer 里没有这个 tag"，而症状是"点了没反应"。
    """
    import re as _re
    base = os.path.basename(tag)
    if base.endswith(".json"):
        base = base[:-5]
    if base.startswith("node-"):
        base = base[len("node-"):]
    return "node-" + _re.sub(r"[^A-Za-z0-9._-]", "_", base)


def act_node_use(ident):
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    # 先看能不能用普通模式；不能用就没必要切
    caps = compat_of(path)
    if not caps.get("can_use_xray"):
        return False, "该节点连普通 Xray 模式都不支持，拒绝切换"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "use", os.path.basename(path)], timeout=60)
    if rc != 0:
        return False, out or err

    # 快路径：常驻实例已经是多出站配置时，换节点就是改 balancer 的选择，
    # 不必重启 —— 重启会断掉所有正在跑的连接。
    # 浏览器拨号的节点不能走这条路：那个 env 是进程级的，要换进程才行。
    node = {}
    try:
        with open(path) as fh:
            node = json.load(fh)
    except (OSError, ValueError):
        pass
    if not node.get("use_browser"):
        srv = api_server()
        try:
            if xrayapi.available(srv):
                tag = multi_node_outbound(path)
                live = set(xrayapi.outbounds(srv))
                if tag in live:
                    xrayapi.switch_node(srv, BALANCER, tag)
                    return True, f"已切换到 {node.get('name') or tag}（未重启，连接不断）"
        except xrayapi.ApiUnavailable as e:
            # 走不通不是致命错误，退回重启那条路，但要让用户知道为什么慢了
            return _restart_to_node(path, caps, f"API 切换未生效（{e}），已改为重启")

    return _restart_to_node(path, caps)


def _restart_to_node(path, caps, prefix_note=""):
    sh_bg(["bash", "-c", "sleep 1; systemctl restart " + U_XRAY])
    time.sleep(4)
    msg = "已切换节点，Xray 正在重启"
    if prefix_note:
        msg = prefix_note + "。" + msg
    if caps.get("can_use_dialer") and not unit_state(U_CHROMIUM)["active"]:
        started, note = ensure_chromium()
        msg += f"；{note}" if started else f"；⚠ {note}（该节点需要浏览器拨号，请手动执行 xbd dialer on）"
    return True, msg


def act_node_browser(ident, value):
    """单个节点的"是否用浏览器完成 TLS"开关。

    协议不支持时后端会拒绝打开；**支持的节点后端会拒绝关闭** ——
    因为 xhttp/websocket 出站只要浏览器在线就被无条件接管（见 Xray 源码
    splithttp/dialer.go:50、websocket/dialer.go:114），关掉只会让该节点不可用。
    """
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "browser",
                       os.path.basename(path), str(value)], timeout=300)
    return rc == 0, ((out or err or "").strip() or "已保存")


def act_node_use_as(ident, mode):
    """切到某个节点，并明确指定用普通连接还是 BD 连接。

    这是把"用哪个节点"和"用哪种 TLS"合成一个动作 —— 用户点「BD 连接」时，
    期望的是"切过去并且用浏览器"，而不是切过去之后还得再找开关。
    """
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    caps = compat_of(path) or {}
    if mode == "bd" and not caps.get("protocol_may_dialer"):
        return False, "该节点不走浏览器转发（只对 vless 的 ws/xhttp 生效）"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "use-as",
                       os.path.basename(path), mode], timeout=300)
    if rc != 0:
        return False, (out or err or "切换失败")
    # 节点切换与 TLS 方式变化都会让旧进程的环境变量失效，统一重启一次
    sh(["systemctl", "restart", U_XRAY], timeout=90)
    time.sleep(5)
    if not unit_state(U_XRAY)["active"]:
        return False, "Xray 重启失败，请查看 xbd status"
    # 用浏览器时确保 Chromium 在线；不用时确保停掉（省内存）
    if mode == "bd":
        okc, notec = ensure_chromium()
        if not okc:
            return True, "已切到 %s，但 %s" % (os.path.basename(path), notec)
        return True, "已切到 BD 连接（浏览器 TLS），%s" % notec
    if unit_state(U_CHROMIUM)["active"]:
        sh([os.path.join(PREFIX, "bin", "xbd"), "dialer", "off"], timeout=180)
    return True, "已切到普通连接（Xray 自带 TLS），Chromium 已关闭以释放内存"


def act_node_probe(ident):
    """真实探测一个节点的浏览器路径（临时起 Xray + Chromium，不动生产服务）。"""
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, err = sh(["python3", os.path.join(PREFIX, "tools", "browserprobe.py"),
                       path, "--save", "--json"], timeout=180)
    try:
        d = json.loads(out or "{}")
    except ValueError:
        d = {}
    if d.get("not_applicable"):
        return True, "该节点不走浏览器转发：" + str(d.get("reason", ""))
    if d.get("ok"):
        return True, "实测可用（出口 %s）" % (d.get("exit_ip") or "已通")
    return True, "实测不可用：" + str(d.get("reason") or err or "未知原因")


def ensure_chromium():
    """确保 Browser Dialer 的运行时在线。节点依赖它却没跑时，代理会静默失败。"""
    if unit_state(U_CHROMIUM)["active"]:
        return True, "Chromium 已在线"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "dialer", "on"], timeout=300)
    return rc == 0, ("已自动启动 Chromium" if rc == 0 else (out or err or "Chromium 启动失败"))


def act_node_remove(ident):
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "node", "remove", os.path.basename(path)], timeout=60)
    return rc == 0, (out or err)


def act_node_latency(ident):
    """真实请求测延时。走临时 Xray 实例，不占用常驻服务。"""
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "latency.py"),
                       path, "--json", "--timeout", "12"], timeout=120)
    if rc != 0 and not out:
        return False, f"测速失败: {err or '未知错误'}"
    try:
        data = json.loads(out)
    except ValueError:
        return False, "测速结果解析失败"
    res = next(iter(data.values()), {})
    if res.get("ok"):
        return True, f"延时 {res['latency_ms']} ms（出口 {res.get('exit_ip') or '未知'}）"
    labels = {"timeout": "超时", "tls": "TLS 握手失败", "dns": "域名解析失败",
              "refused": "连接被拒绝", "unreachable": "无法连接", "no_response": "服务端无响应",
              "proxy_error": "代理错误", "config_failed": "配置生成失败", "xray_not_up": "临时实例未启动"}
    return False, f"测速失败：{labels.get(res.get('error'), res.get('error') or '未知')}"


def act_xray_version():
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "xrayup.py"), "check", "--json"], timeout=60)
    try:
        d = json.loads(out)
    except ValueError:
        return False, f"版本检查失败: {err or out}"
    if d.get("error"):
        return False, f'{d["error"]}（已安装 {d.get("installed") or "无"}）'
    cur, latest = d.get("installed") or "无", (d.get("latest") or "").lstrip("v")
    if d.get("updatable"):
        return True, f"已安装 {cur}，可更新到 {latest}。点「更新内核」开始。"
    return True, f"已是最新版本 {cur}"


def act_xray_upgrade():
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "xrayup.py"), "update", "--json"], timeout=600)
    try:
        d = json.loads(out)
    except ValueError:
        return False, f"更新失败: {err or out}"
    if not d.get("ok"):
        return False, f'更新失败: {d.get("error", "未知错误")}'
    if not d.get("updated"):
        return True, f'已是最新版本 {d.get("version")}'
    note = "（SHA256 已校验）" if d.get("sha256_verified") else "（未取得官方 .dgst）"
    # 换二进制后必须重启，否则还在跑旧内核
    sh(["systemctl", "restart", U_XRAY], timeout=60)
    if unit_state(U_CHROMIUM)["active"]:
        sh(["systemctl", "restart", U_CHROMIUM], timeout=60)
    return True, f'内核已更新 {d.get("from") or "无"} → {d.get("to")} {note}，服务已重启'


def _px_note(out):
    """把 xbd proxy on 的关键决策行带回界面：改了谁家的配置，或新建了什么。"""
    keep = [l.strip() for l in (out or "").splitlines()
            if ("接管" in l or "已写" in l or "已移除" in l or l.lstrip().startswith("["))
            and "本机没有别的" not in l]
    return ("\n" + "\n".join(keep)) if keep else ""


def act_takeover(mode):
    """接管已下线，这里只保留"清理旧配置"这一个动作。

    原来有「不接管 / 接管本机」两种模式，另有已移除的「接管局域网」。
    接管会往 /etc/profile.d、docker.service.d 写系统级代理配置，理由有两个：

    一是风险：改一次影响全机，出问题极难定位。
    二是耦合：为了写 docker 的代理，systemd 单元的 ReadWritePaths 里就得开
    /etc/systemd/system/docker.service.d —— 而没装 Docker 的机器上该目录不存在，
    systemd 会放弃整个单元，面板根本起不来（226/NAMESPACE）。为了一个可选
    功能把主功能绑架了。

    端口本身不动（PORT_HTTP / PORT_LAN_HTTP 仍是正常入口），只是不再自动往
    系统里写。需要的人自己指定，或在客户端里填。
    """
    xbd = os.path.join(PREFIX, "bin", "xbd")
    if mode == "none":
        return (True, "本客户端不再修改系统代理配置。代理入口照常提供："
                "SOCKS5 / HTTP 按需在客户端或 shell 里指定即可。")
    if mode == "clean":
        rc, out, err = sh([xbd, "proxy", "clean"], timeout=180)
        return rc == 0, (out or err or "").strip() or "已清理"
    return False, "未知模式"


def act_node_check(ident):
    path = node_path(ident)
    if not path:
        return False, "找不到该节点"
    rc, out, _ = sh(["python3", COMPAT_PY, "json", path], timeout=30)
    try:
        caps = json.loads(out)
    except ValueError:
        return False, "能力检查失败"
    lines = []
    x = caps.get("xray", {}).get("overall", "?")
    b = caps.get("dialer", {}).get("overall", "?")
    labels = {"SUPPORTED": "✓ 支持", "SUPPORTED_WITH_WARNING": "⚠ 支持（有注意项）",
              "NOT_SUPPORTED": "✗ 不支持", "UNKNOWN": "? 未知"}
    lines.append(f"Xray：{labels.get(x, x)}")
    lines.append(f"Browser Dialer：{labels.get(b, b)}")
    if caps.get("tags"):
        lines.append("能力标签：" + "  ".join(f"[{t}]" for t in caps["tags"]))
    for note in (caps.get("dialer", {}).get("notes") or [])[:4]:
        lines.append(f"  · {note}")
    return True, "\n".join(lines)


def act_mode(mode):
    """Browser Dialer 运行时的开关。

    注意：这里**没有**"切换到普通模式"这回事 —— 唯一 Xray 实例始终同时服务
    SOCKS 与 HTTP，并始终带 XRAY_BROWSER_DIALER。停掉 Chromium 不会中断任何
    不需要浏览器拨号的节点，只是让依赖它的那些节点暂时不可用。
    """
    xbd = os.path.join(PREFIX, "bin", "xbd")
    if mode in ("browser_dialer", "on"):
        rc, out, err = sh([xbd, "dialer", "on"], timeout=300)
        if rc != 0:
            return False, (out or err or "启动失败")
        # 只回报结果，不回放整段脚本输出（页面上那样很难读）
        ws = (build_state() or {}).get("ws_connections", 0)
        return True, (f"Chromium 已启动，浏览器已接上（{ws} 条 WS）" if ws
                      else "Chromium 已启动，浏览器还在连接（health timer 会在 30 秒内自愈）")
    if mode in ("normal", "off"):
        rc, out, err = sh([xbd, "dialer", "off"], timeout=180)
        if rc != 0:
            return False, (out or err or "关闭失败")
        needs = False
        try:
            rc2, o2, _ = sh(["python3", COMPAT_PY, "json",
                             os.path.realpath(os.path.join(NODES, "current"))], timeout=30)
            needs = rc2 == 0 and json.loads(o2 or "{}").get("can_use_dialer") is True
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        warn = "⚠ 当前节点依赖浏览器拨号，它现在会拨号失败" if needs else "当前节点不需要浏览器拨号，不受影响"
        return True, f"Chromium 已停止，Xray 继续运行；{warn}"
    return False, "未知操作"


def act_service(op):
    xbd = os.path.join(PREFIX, "bin", "xbd")
    if op == "start":
        # 面板会重启到自己所在的单元，放到后台执行，避免响应被掐断
        sh_bg([xbd, "start"])
        return True, "正在启动常驻 Xray…"
    if op in ("stop", "restart", "stop-all"):
        if op == "stop-all":
            sh_bg([xbd, "stop", "--all"])
            return True, "正在全部停止…"
        sh_bg([xbd, op])
        return True, f"正在{ {'stop': '停止', 'restart': '重启'}[op] }常驻 Xray…"
    return False, "未知操作"


def _validate_port(v):
    v = str(v).strip()
    if not re.fullmatch(r"\d{1,5}", v) or not (1 <= int(v) <= 65535):
        return None
    return v


def act_port_set(kind, value):
    """统一端口修改。kind: normal/dialer/http/lan-http/channel/panel/api"""
    value = _validate_port(value)
    if value is None:
        return False, "端口必须是 1-65535 的数字"
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "port", kind, value], timeout=120)
    if rc != 0:
        return False, out or err or "修改失败"
    # 面板端口改的是自己，响应可能被掐断，所以后台重启
    if kind in ("panel",):
        return True, out or f"面板端口已改为 {value}，请用新地址访问"
    # 其余端口需要重新生成配置并重启对应服务
    rc2, o2, e2 = sh([xbd, "apply"], timeout=120)
    if rc2 != 0:
        return False, f"端口已改，但配置生成失败: {o2 or e2}"
    if kind == "channel":
        # 内部通道两端都要重启，否则 Chromium 还在连旧端口
        sh(["systemctl", "restart", U_XRAY, U_CHROMIUM], timeout=120)
        if unit_state(U_CHROMIUM)["active"]:
            return True, f"内部通道已改为 {value}，Xray 与 Chromium 已重启"
        return True, f"内部通道已改为 {value}（Chromium 未运行，下次启动时生效）"
    sh_bg(["bash", "-c", "sleep 1; systemctl restart " + U_XRAY])
    time.sleep(3)
    return True, f"{kind} 端口已改为 {value}"


def act_conninfo():
    """生成可直接复制的连接配置。

    为什么要后端生成：端口随时会改，前端拼字符串一定会和真实配置脱节。
    """
    ports = os.path.join(CONF, "ports.env")
    listen = cfg_get(ports, "LISTEN_ADDR", "127.0.0.1")
    p_socks = cfg_get(ports, "PORT_NORMAL", "1080")
    p_lan_http = cfg_get(ports, "PORT_LAN_HTTP", "10809")
    p_http = cfg_get(ports, "PORT_HTTP", "10808")

    node_name = "LAN"
    node_path = os.path.join(NODES, "current")
    try:
        node_name = json.load(open(os.path.realpath(node_path))).get("name") or "LAN"
    except (OSError, ValueError):
        pass

    safe = "".join(ch for ch in node_name if ch.isalnum() or ch in "-_") or "LAN"

    yaml_text = f"""# 由 Xray Client Manager 生成 —— 复制到需要代理的机器上使用
# 本机地址: {listen}
# 两个入口都由同一个 Xray 实例服务，所有节点通用；节点是否需要浏览器拨号由服务器决定。
proxies:
  - name: "{safe}-SOCKS5"
    type: socks5
    server: {listen}
    port: {p_socks}
    udp: true
  - name: "{safe}-HTTP"
    type: http
    server: {listen}
    port: {p_lan_http}
"""

    links = [
        {"label": "SOCKS5（推荐，支持 UDP）", "env": "socks5", "url": f"socks5://{listen}:{p_socks}"},
        {"label": "HTTP 代理", "env": "http", "url": f"http://{listen}:{p_lan_http}"},
    ]

    return True, json.dumps({
        "listen": listen,
        "yaml": yaml_text,
        "links": links,
        "env_example": (f'export http_proxy="http://{listen}:{p_lan_http}"\n'
                        f'export https_proxy="http://{listen}:{p_lan_http}"\n'
                        f'export all_proxy="socks5://{listen}:{p_socks}"'),
        "local_note": (f'本机进程（docker/apt/curl）请用 127.0.0.1:{p_http}，'
                       f'它只监听回环，不对外暴露。'),
    }, ensure_ascii=False)


def act_ports_check():
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "ports.py"), "check"], timeout=120)
    return rc == 0, (out or err)


def act_ports_fix():
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "ports", "fix"], timeout=300)
    return rc == 0, (out or err)


def act_port(kind, value):
    value = _validate_port(value)
    if value is None:
        return False, "端口必须是 1-65535 的数字"
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "port", kind, value], timeout=60)
    if rc != 0:
        return False, out or err
    rc2, out2, err2 = sh([xbd, "apply"], timeout=120)
    if rc2 != 0:
        return False, f"端口已改但配置生成失败: {out2 or err2}"
    if kind == "channel":
        sh(["systemctl", "restart", U_XRAY, U_CHROMIUM], timeout=120)
        return True, f"内部通道已改为 {value}，两端已重启"
    sh_bg(["bash", "-c", "sleep 1; systemctl restart " + U_XRAY])
    time.sleep(4)
    return True, f"端口已改为 {value}，Xray 已重启"


def act_config_update():
    xbd = os.path.join(PREFIX, "bin", "xbd")
    rc, out, err = sh([xbd, "apply"], timeout=120)
    return rc == 0, (out or err)


def act_diagnose():
    rc, out, err = sh([os.path.join(PREFIX, "bin", "xbd"), "diagnose"], timeout=240)
    return rc == 0, (out or err)


def act_ech():
    rc, out, err = sh(["python3", os.path.join(DIST, "lib", "echcli.py"), "--quick"], timeout=120)
    return rc == 0, (out or err)


DISPATCH = {
        "import": lambda p: act_import(str(p.get("uri", "")).strip(),
                                        str(p.get("sub_name", "")).strip()),
    "build_link": lambda p: act_build_link(p),
    "group_create": lambda p: act_group_create(str(p.get("name", "")).strip()),
    "group_delete": lambda p: act_group_delete(str(p.get("key", "")).strip()),
    "dns_set": lambda p: act_dns_set(str(p.get("mode", "")).strip()),
    "multi_set": lambda p: act_multi_set(str(p.get("mode", "")).strip()),
    "node_use": lambda p: act_node_use(p.get("ident", "")),
    "node_browser": lambda p: act_node_browser(p.get("ident", ""), p.get("value", "auto")),
    "node_probe": lambda p: act_node_probe(p.get("ident", "")),
    "node_use_as": lambda p: act_node_use_as(p.get("ident", ""), p.get("mode", "normal")),
    "node_remove": lambda p: act_node_remove(p.get("ident", "")),
    "node_check": lambda p: act_node_check(p.get("ident", "")),
    "node_latency": lambda p: act_node_latency(p.get("ident", "")),
    "xray_version": lambda p: act_xray_version(),
    "xray_upgrade": lambda p: act_xray_upgrade(),
    "takeover": lambda p: act_takeover(str(p.get("mode", ""))),
    "mode": lambda p: act_mode(str(p.get("mode", ""))),
    "service": lambda p: act_service(str(p.get("op", ""))),
    "port": lambda p: act_port(str(p.get("kind", "normal")), p.get("value", "")),
    "port_set": lambda p: act_port_set(str(p.get("kind", "")), p.get("value", "")),
    "conninfo": lambda p: act_conninfo(),
    "ports_check": lambda p: act_ports_check(),
    "ports_fix": lambda p: act_ports_fix(),
    "config_update": lambda p: act_config_update(),
    "diagnose": lambda p: act_diagnose(),
    "ech": lambda p: act_ech(),
}


# ---------------------------------------------------------------------- 页面 ----
PAGE = r"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Xray Client Manager</title>
<style>
:root{--bg:#0f1115;--card:#171a21;--line:#252a34;--fg:#e7ebf0;--dim:#8b95a5;
--ok:#3ddc84;--warn:#ffb44d;--bad:#ff5c5c;--acc:#4c9aff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.55 -apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:22px 18px 60px}
header{display:flex;align-items:baseline;gap:12px;margin-bottom:18px;flex-wrap:wrap}
h1{font-size:19px;margin:0;font-weight:600}
.sub{color:var(--dim);font-size:12px}
.grid{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(260px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px}
.card h2{margin:0 0 12px;font-size:12px;color:var(--dim);font-weight:600;
text-transform:uppercase;letter-spacing:.05em}
.row{display:flex;justify-content:space-between;align-items:center;padding:5px 0;
border-bottom:1px solid rgba(255,255,255,.04);gap:10px}
.row:last-child{border:0}
.k{color:var(--dim);white-space:nowrap}
.v{font-variant-numeric:tabular-nums;text-align:right}
/* 圆点：背景色只加在 .dot 上。
   之前 .ok/.bad 是独立类且带实心背景，凡是同时写 class="tag ok"
   的元素都会被涂成绿底绿字 —— 文字完全看不见。 */
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:7px;vertical-align:middle;background:#4a5262}
.dot.ok{background:var(--ok);box-shadow:0 0 8px rgba(61,220,132,.5)}
.dot.bad{background:var(--bad);box-shadow:0 0 8px rgba(255,92,92,.5)}
.dot.warn{background:var(--warn)}
.dim2{background:#4a5262}
button{background:#222834;color:var(--fg);border:1px solid var(--line);
border-radius:7px;padding:7px 13px;cursor:pointer;font-size:13px;transition:.12s}
button:hover:not(:disabled){border-color:var(--acc);color:#fff}
button.pri{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
button.danger{background:var(--bad);border-color:var(--bad);color:#fff;font-weight:600}
button.sm{padding:5px 10px;font-size:12px}
button:disabled{opacity:.4;cursor:not-allowed}
input,select{background:#11141a;color:var(--fg);border:1px solid var(--line);
border-radius:7px;padding:7px 10px;font-size:13px;width:100%}
input:focus,select:focus{outline:none;border-color:var(--acc)}
.bar{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap;align-items:center}
.bar>*{flex:0 0 auto}.bar input{flex:1 1 200px;min-width:120px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;color:var(--dim);font-weight:600;padding:7px 8px;
border-bottom:1px solid var(--line);font-size:11px;text-transform:uppercase}
td{padding:9px 8px;border-bottom:1px solid rgba(255,255,255,.04);vertical-align:middle}
tr.cur{background:rgba(76,154,255,.10)}
tr.cur td:first-child{box-shadow:inset 3px 0 0 var(--acc)}
.tag{display:inline-block;padding:2px 7px;border-radius:5px;font-size:11px;
border:1px solid var(--line);color:var(--dim);background:rgba(255,255,255,.03);
margin:1px 3px 1px 0;white-space:nowrap}
.tag.ok{color:#8ff0b8;border-color:rgba(61,220,132,.55);background:rgba(61,220,132,.13)}
.tag.warn{color:#ffd08a;border-color:rgba(255,180,77,.55);background:rgba(255,180,77,.13)}
.tag.bad{color:#ff9b9b;border-color:rgba(255,92,92,.55);background:rgba(255,92,92,.13)}

/* ---- 节点列表：分组 / 密度 ----
   密度不是"把字调小"，而是每屏能塞下多少个**节点**。三十个节点时，
   表格一行要一行、卡片一行两行，紧凑列表能一行三个 —— 一屏能对比的节点
   数量差三倍，这才是真正决定"节点多了好不好用"的东西。 */
.nlt{display:flex;gap:6px;flex-wrap:wrap;margin:10px 0 12px;align-items:center}
.nli{background:rgba(255,255,255,.05);border:1px solid var(--line);color:var(--fg);
 border-radius:7px;padding:6px 9px;font-size:12px;font-family:inherit}
.nli#nq{flex:1 1 220px;min-width:160px}
 background:rgba(255,255,255,.045);user-select:none;border-bottom:1px solid transparent}
.nm{display:flex;align-items:center;gap:7px;flex-wrap:wrap}
.nm .sel{width:13px;height:13px;accent-color:var(--acc)}
.nm .cur-dot{width:7px;height:7px;border-radius:50%;background:var(--acc);flex:0 0 auto}
.tr{color:var(--dim);font-size:11px;white-space:nowrap}
/* 卡片视图：一行两个，信息密度靠并排而不是靠缩小字号 */
.view-grid .gridwrap{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:8px}
.ncard{border:1px solid var(--line);border-radius:9px;padding:10px;background:rgba(255,255,255,.03)}
.ncard.cur{border-color:var(--acc);background:rgba(76,154,255,.10)}
/* 紧凑列表：一行一个，只留"名字 + 状态 + 操作"，延迟和流量合并成一行小字 */
.view-list .grp-body{padding:0}
.view-list .listwrap{display:flex;flex-direction:column}
.view-list .nrow{display:flex;align-items:center;gap:8px;padding:6px 9px;
 border-bottom:1px solid rgba(255,255,255,.04);flex-wrap:wrap}
.view-list .nrow:hover{background:rgba(255,255,255,.04)}
.view-list .nrow.cur{background:rgba(76,154,255,.10)}
.view-list .nrow .grow{flex:1 1 auto;min-width:140px}
.empty{color:var(--dim);font-size:12px;padding:14px 6px}
/* ---- 节点区: 左订阅栏 + 右节点表 ----
   两栏而不是一棵可嵌套的树。调研下来 (metacubexd / zashboard / v2rayN) 分组
   关系都很浅, 嵌套一深就没人用。zashboard 在组数 > 20 时才退化成左树, 说明
   右边的"选中一个组、看它的节点"更好用, 只是需要给组留个固定的位置。
   固定在左边的好处: 组永远看得见, 不会因为展开/折叠而从视野里消失。 */
.nodes-card{padding:0}
.nodes-head{display:flex;align-items:center;gap:10px;padding:11px 13px;
 border-bottom:1px solid var(--line);flex-wrap:wrap}
.nh-l{display:flex;align-items:center;gap:8px}
.badge{background:rgba(255,255,255,.08);border-radius:20px;padding:1px 8px;
 font-size:11px;color:var(--dim)}
.chipbar{display:flex;gap:8px;margin-left:4px}
.chk{display:flex;align-items:center;gap:4px;font-size:11px;color:var(--dim);cursor:pointer}
.nodes-body{display:flex;align-items:stretch;min-height:220px}
.subs-rail{width:212px;flex:0 0 212px;border-right:1px solid var(--line);
 padding:10px;display:flex;flex-direction:column;gap:7px;background:rgba(255,255,255,.015)}
.subs-rail .wide{width:100%}
#subs-list{flex:1 1 auto;overflow:auto;max-height:420px}
.srow{display:flex;align-items:center;gap:6px;padding:6px 7px;border-radius:7px;
 cursor:pointer;font-size:12px;line-height:1.3}
.srow:hover{background:rgba(255,255,255,.055)}
.srow.on{background:rgba(90,160,255,.16);box-shadow:inset 2px 0 0 #5aa0ff}
.srow .sn{flex:1 1 auto;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.srow .sc{color:var(--dim);font-size:10px;flex:0 0 auto}
.srow .sd{opacity:0;flex:0 0 auto;font-size:11px;padding:0 3px;border-radius:4px}
.srow:hover .sd{opacity:.75}
.srow .sd:hover{opacity:1;background:rgba(255,90,90,.25)}
.sempty{color:var(--dim);font-size:11px;padding:10px 6px;text-align:center}
.nodes-main{flex:1 1 auto;min-width:0;padding:11px 13px}

/* ---- 添加节点 ---- */
.modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.62);z-index:50;
 align-items:flex-start;justify-content:center;padding:40px 12px;overflow:auto}
.modal.show{display:flex}
.mbox{background:#12161c;border:1px solid var(--line);border-radius:13px;max-width:640px;
 width:100%;box-shadow:0 18px 60px rgba(0,0,0,.55)}
.mhead{display:flex;align-items:center;padding:13px 16px;border-bottom:1px solid var(--line);
 font-weight:600;font-size:14px}
.mhead button{margin-left:auto}
.mbody{padding:16px}
.mgroup{color:var(--dim);font-size:11px;text-transform:uppercase;margin:14px 0 7px}
.mgroup:first-child{margin-top:0}
.mitem{display:block;width:100%;text-align:left;margin:0 0 5px;padding:9px 12px}
.mrow{display:flex;align-items:center;gap:10px;margin-bottom:9px}
.mrow label{width:72px;flex:0 0 auto;color:var(--dim);font-size:12px}
.mrow input,.mrow select{flex:1 1 auto;background:rgba(255,255,255,.05);border:1px solid var(--line);
 color:var(--fg);border-radius:7px;padding:7px 9px;font-size:12px;font-family:inherit}
.mfoot{display:flex;gap:8px;justify-content:flex-end;margin-top:16px;
 padding-top:13px;border-top:1px solid var(--line)}
.tag.acc{color:#9cc8ff;border-color:rgba(76,154,255,.55);background:rgba(76,154,255,.13)}
pre{background:#0b0d11;border:1px solid var(--line);border-radius:8px;padding:12px;
overflow:auto;max-height:380px;font-size:12px;margin:0;white-space:pre-wrap}
#msg{margin:12px 0;padding:10px 13px;border-radius:8px;border:1px solid var(--line);
display:none;font-size:13px;white-space:pre-wrap}
#msg.on{display:block}
#msg.good{border-color:rgba(61,220,132,.5)}
#msg.err{border-color:rgba(255,92,92,.5)}
.hint{color:var(--dim);font-size:12px;margin-top:8px;line-height:1.5}
.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
.mode-pick{display:flex;gap:8px;margin-top:6px}
.mode-pick button{flex:1}
.mode-pick button.sel{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
.stopped{color:var(--dim)}
.modes{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}
.modes button{display:flex;flex-direction:column;align-items:flex-start;gap:4px;
  text-align:left;padding:11px 12px;line-height:1.35}
.modes button b{font-size:13px}
.modes button span{font-size:11px;color:var(--dim);font-weight:400}
.modes button.sel{background:var(--acc);border-color:var(--acc)}
.modes button.sel span{color:rgba(255,255,255,.85)}
@media(max-width:620px){.modes{grid-template-columns:1fr}}
</style></head><body><div class="wrap">

<header>
  <h1>Xray Client</h1>
  <span class="sub" id="stamp">加载中…</span>
  <span style="flex:1"></span>
  <button onclick="load()">刷新</button>
</header>

<div id="msg"></div>

  <div class="card"><h2>运行状态</h2>
    <div class="row"><span class="k">Xray（常驻）</span><span class="v" id="s-xray">—</span></div>
    <div class="row"><span class="k">连接模式</span><span class="v" id="s-mode">—</span></div>
    <div class="row"><span class="k">当前节点</span><span class="v" id="s-node">—</span></div>
    <div class="row"><span class="k">出口 IP</span><span class="v mono" id="s-ip">—</span></div>
    <div class="bar">
      <button class="pri" id="btn-toggle" onclick="toggleMain()">启动</button>
      <button onclick="svc('restart')">重启 Xray</button>
    </div>
    <div class="hint" id="hint-main">Xray 常驻运行；Browser Dialer 按需启用，两者互不影响。</div>
  </div>

<div class="card"><h2>添加节点</h2>
  <div class="bar">
    <textarea id="in-node" rows="6" style="width:100%;font-family:monospace" placeholder="粘贴节点（可多个）：vless:// vmess:// trojan:// ss:// hysteria2:// / Xray JSON / Mihomo YAML（支持整段多行粘贴）/ 订阅URL"></textarea>
    <button class="pri" onclick="openAdd()">添加节点</button>
  </div>
  <div class="hint">导入后自动做能力检查：Xray 普通模式与 Browser Dialer 分别判定。也支持 Xray JSON 与 Mihomo YAML。</div>

<div id="add-modal" class="modal">
 <div class="mbox">
  <div class="mhead">添加节点<button class="sm" onclick="closeAdd()">关闭</button></div>
  <div class="mbody">
   <div id="add-menu">
     <div class="mgroup">手动添加</div>
     <button class="mitem" onclick="pickProto('vless')">VLESS</button>
     <button class="mitem" onclick="pickProto('vmess')">VMess</button>
     <button class="mitem" onclick="pickProto('trojan')">Trojan</button>
     <button class="mitem" onclick="pickProto('shadowsocks')">Shadowsocks</button>
     <button class="mitem" onclick="pickProto('hysteria2')">Hysteria2</button>
     <div class="mgroup">直接粘贴</div>
     <button class="mitem" onclick="pickPaste()">分享链接</button>
     <button class="mitem" onclick="pickPaste()">订阅地址</button>
     <button class="mitem" onclick="pickPaste()">Xray JSON / Mihomo YAML</button>
     <div class="mgroup">其它</div>
     <button class="mitem" onclick="pickQR()">扫码（二维码）</button>
     <button class="mitem" onclick="pickPull()">Server Pull</button>
   </div>
   <div id="add-form" style="display:none">
     <div class="mrow"><label>协议</label><span id="f-proto" class="mono"></span></div>
     <div class="mrow"><label>名称</label><input id="f-name" placeholder="留空自动生成"></div>
     <div class="mrow"><label>地址</label><input id="f-address" placeholder="域名或 IP（浏览器拨号要求域名）"></div>
     <div class="mrow"><label>端口</label><input id="f-port" value="443" inputmode="numeric"></div>
     <div id="f-cred"></div>
     <div class="mrow"><label>传输</label><select id="f-transport" onchange="onTransport()"></select></div>
     <div id="f-transport-fields"></div>
     <div class="mrow"><label>安全</label><select id="f-security" onchange="renderFields()">
        <option value="none">无</option><option value="tls">TLS</option><option value="reality">REALITY</option>
     </select></div>
     <div id="f-security-fields"></div>
     <div class="mrow"><label>流控</label><select id="f-flow">
        <option value="">无</option><option value="xtls-rprx-vision">xtls-rprx-vision</option>
     </select></div>
     <div class="mfoot"><button class="sm" onclick="openAdd()">返回</button>
       <button class="pri" onclick="submitNode()">生成并导入</button></div>
   </div>
   <div id="add-paste" style="display:none">
     <div class="mgroup">把链接、订阅地址、Xray JSON 或 Mihomo YAML 整段贴进来</div>
     <textarea id="add-text" rows="7" style="width:100%;background:rgba(255,255,255,.05);
       border:1px solid var(--line);border-radius:8px;color:var(--fg);padding:9px;font-family:inherit"></textarea>
     <div class="hint" id="add-sub-name-row" style="display:none">
       订阅地址请填名称，导入后它就是一个分组，可以整组管理：<br>
       <input id="add-sub-name" placeholder="例如：我的机场 / 公司专线" style="width:260px;margin-top:5px">
     </div>
     <div class="mfoot"><button class="sm" onclick="openAdd()">返回</button>
       <button class="pri" onclick="submitPaste()">导入</button></div>
   </div>
   <div id="add-qr" style="display:none">
     <div class="mgroup">从图片里识别分享链接</div>
     <input type="file" id="add-qr-file" accept="image/*">
     <div class="hint">需要系统里有 zbarimg 或 python3 的二维码库；都没有会明确告诉你，不会静默失败。</div>
     <div class="mfoot"><button class="sm" onclick="openAdd()">返回</button></div>
   </div>
   <div id="add-pull" style="display:none">
     <div class="mgroup">从 Server 拉取分享链接</div>
     <div class="mrow"><label>地址</label><input id="pull-addr" placeholder="https://…"></div>
     <div class="mrow"><label>路径</label><input id="pull-path" placeholder="/share/xxx"></div>
     <div class="mfoot"><button class="sm" onclick="openAdd()">返回</button>
       <button class="pri" onclick="submitPull()">拉取并导入</button></div>
   </div>
  </div>
 </div>
</div>

<div class="card nodes-card">
  <div class="nodes-head">
    <div class="nh-l">
      <b>节点</b><span class="badge" id="side-count">0</span>
      <span class="chipbar">
        <label class="chk"><input type="checkbox" id="onlyavail" onchange="renderNodes()">仅可用</label>
      </span>
    </div>
    <div class="nlt">
      <input id="nq" class="nli wide" placeholder="搜索名称 / 地址 / 协议…" oninput="renderNodes()">
      <select id="ns" class="nli" onchange="renderNodes()">
        <option value="default">默认排序</option>
        <option value="name">按名称</option><option value="lat">按延迟</option>
        <option value="traffic">按流量</option><option value="proto">按协议</option>
      </select>
      <select id="nd" class="nli" onchange="setDensity(this.value)">
        <option value="table">表格</option><option value="grid">卡片</option>
        <option value="list">紧凑</option>
      </select>
      <button class="sm" onclick="batchAll(this)">全选</button>
      <button class="sm" onclick="batchTest()">测速</button>
      <button class="sm" onclick="batchDelete()">删除</button>
    </div>
  </div>
  <div class="nodes-body">
    <aside class="subs-rail">
      <input id="gq" class="nli" placeholder="筛选分组…" oninput="renderSubs()">
      <div id="subs-list"></div>
      <button class="sm wide" onclick="newGroup()">＋ 新建分组</button>
    </aside>
    <div class="nodes-main">
      <div id="node-list"></div>
      <div class="hint" id="node-count"></div>
    </div>
  </div>
  <div class="hint">「普通连接」与「Browser Dialer」只是同一节点的两种用法，切换不会修改节点本身。</div>
</div>

  <div class="card"><h2>Browser Dialer（按节点自动生效）</h2>
    <div class="row"><span class="k">当前节点走哪条路</span><span class="v" id="s-dialer">—</span></div>
    <div class="row"><span class="k">Chromium 运行时</span><span class="v" id="s-chromium">—</span></div>
    <div class="row"><span class="k">浏览器连接数</span><span class="v" id="s-ws">—</span></div>
    <div class="row"><span class="k">Chromium 进程</span><span class="v" id="s-chromium-procs">—</span></div>
    <div class="mode-pick">
      <button id="m-dialer" onclick="setMode('browser_dialer')">启动 Chromium</button>
      <button id="m-normal" onclick="setMode('normal')"
              title="会把当前节点切到普通连接（Xray 自带 TLS）并停掉 Chromium，释放约 890MB">停掉 Chromium</button>
    </div>
    <div class="hint" id="hint-dialer"></div>
  </div>

  <div class="card"><h2>运行概况</h2>
    <div class="row"><span class="k">SOCKS5 入口</span><span class="v mono" id="s-nport">—</span></div>
    <div class="row"><span class="k">HTTP 入口</span><span class="v mono" id="s-hport">—</span></div>
    <div class="row"><span class="k">代理连通</span><span class="v" id="s-proxy">—</span></div>
    <div class="row"><span class="k">DNS</span><span class="v">
        <select id="dns-mode" onchange="setDns(this.value)" style="background:rgba(255,255,255,.05);
          border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 8px;font-size:12px">
          <option value="off">不接管（系统 DNS）</option>
          <option value="standard">标准：加密 DNS</option>
          <option value="strict">严格防泄漏</option>
        </select></span></div>
    <div class="row"><span class="k">多出站</span><span class="v">
        <select id="multi-mode" onchange="setMulti(this.value)" style="background:rgba(255,
          border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 8p
          <option value="off">关：单节点（切换需重启）</option>
          <option value="on">开：全部常驻（切换不断线）</option>
        </select></span></div>
    <div class="row"><span class="k">出口 IP</span><span class="v mono" id="s-ip2">—</span></div>
    <div class="hint" id="hint-multi"></div>
    <div class="hint">端口统一在下面的「端口设置」里改，这里只做显示 ——
      之前两处都能改，容易改重。</div>
  </div>
</div>

<div class="card" style="margin-top:14px"><h2>代理入口</h2>
  <div class="hint" style="margin:0 0 10px">本客户端<strong>不修改系统代理配置</strong>。
    下面这些入口照常提供，需要时在客户端或 shell 里指定即可。</div>
  <div class="row"><span class="k">代理入口</span>
    <span class="v mono" id="entries">—</span></div>
  <div class="hint" id="hint-takeover"></div>
  <div class="row" style="margin-top:6px"><span class="k">旧版接管残留</span>
    <span class="v"><button id="tk-clean" onclick="cleanTakeover()">清理系统代理配置</button>
    <span class="hint" id="clean-note"></span></span></div>
</div>

<div class="card" style="margin-top:14px"><h2>连接配置（可直接复制）</h2>
  <div class="hint" style="margin:0 0 10px">在需要代理的设备上使用。所有内容按当前端口实时生成，改端口后点「刷新配置」即可。</div>
  <div class="bar">
    <button onclick="loadConn(this)">刷新配置</button>
    <button onclick="copyText(document.getElementById('conn-yaml').textContent, this)">复制 YAML</button>
    <button onclick="copyText(document.getElementById('conn-env').textContent, this)">复制环境变量</button>
  </div>

  <div style="margin-top:12px"><div class="k" style="margin-bottom:5px">Mihomo / Clash 配置</div>
    <pre id="conn-yaml">点「刷新配置」生成…</pre></div>

  <div style="margin-top:12px"><div class="k" style="margin-bottom:5px">代理链接（点右侧按钮复制）</div>
    <table><tbody id="tb-links"></tbody></table></div>

  <div style="margin-top:12px"><div class="k" style="margin-bottom:5px">环境变量（Linux / macOS）</div>
    <pre id="conn-env">—</pre></div>

  <div class="hint" id="conn-note"></div>
</div>

<div class="card" style="margin-top:14px"><h2>端口设置</h2>
  <div class="hint" style="margin:0 0 10px">所有端口都可以改。改完会自动重新生成配置并重启对应服务。
    第一次安装时会自动挑没被占用的端口。</div>
  <table><tbody id="tb-ports"></tbody></table>
  <div class="bar" style="margin-top:10px">
    <input id="in-addr" placeholder="绑定地址（当前值见下表）" style="flex:1 1 160px">
    <button onclick="setAddr(this)">改绑定地址</button>
  </div>
  <div class="bar">
    <button onclick="portsCheck(this)">检查冲突</button>
    <button class="pri" onclick="portsFix(this)">自动重新分配</button>
  </div>
  <div class="hint">「自动重新分配」只改被别的服务占用的那些端口，不会动正常的。</div>
</div>

<div class="card" style="margin-top:14px"><h2>Xray 内核</h2>
  <div class="row"><span class="k">已安装版本</span><span class="v mono" id="xver">—</span></div>
  <div class="bar">
    <button onclick="xrayCheck(this)">检查更新</button>
    <button class="pri" onclick="xrayUpgrade(this)">更新内核</button>
  </div>
  <div class="hint">只更新本项目自己的副本（$PREFIX/bin/xray），不碰系统 Xray。下载后会校验官方 SHA256。</div>
</div>


</div>


</div>

<div class="card" id="out-card" style="margin-top:14px;display:none"><h2>输出</h2><pre id="out">—</pre></div>



<script>
const $ = id => document.getElementById(id);

// 复制到剪贴板。面板走的是 http（非安全上下文），
// navigator.clipboard 会被浏览器禁用，所以必须回退到 execCommand。
async function copyText(text, btn){
  if (!text || text.startsWith('点「刷新')) return say('还没有内容可复制', 'err');
  let ok = false;
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      ok = true;
    }
  } catch (e) { /* 继续走回退 */ }
  if (!ok) {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.left = '-9999px';
      ta.setAttribute('readonly', '');
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, ta.value.length);
      ok = document.execCommand('copy');
      document.body.removeChild(ta);
    } catch (e) { ok = false; }
  }
  if (ok) {
    const old = btn ? btn.textContent : '';
    if (btn) { btn.textContent = '已复制 ✓'; setTimeout(() => btn.textContent = old, 1400); }
    say('已复制到剪贴板');
  } else {
    say('自动复制被浏览器拦了，请手动选中下面的内容复制', 'err');
  }
}
const ESC = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
// 属性值里的引号必须转义, 否则组名里一个 " 就能把 onclick 整段打断 ——
// 后果是页面还能开, 但点哪个组都不对。
const escAttr = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let ST = {};
// 延时结果缓存在前端：测速较慢，不放进 5 秒轮询里
const LAT = {};
function latText(file){
  const v = LAT[file];
  if (!v) return '<span class="hint">未测</span>';
  if (v.loading) return '<span class="hint">测试中…</span>';
  if (!v.ok) return `<span class="tag bad">${ESC(v.msg||'失败')}</span>`;
  const ms = v.ms;
  const cls = ms < 300 ? 'ok' : ms < 800 ? 'warn' : 'bad';
  return `<span class="tag ${cls}">${ms} ms</span>`;
}

function dot(on, text){ return `<span class="dot ${on?'ok':'bad'}"></span>${ESC(text)}`; }
const CN = {active:'正在运行',inactive:'已停止',failed:'启动失败',activating:'正在启动',deactivating:'正在停止',unknown:'未知'};
const cn = s => CN[s] || s;
function vtag(v, kind){
  const m = {SUPPORTED:'ok',SUPPORTED_WITH_WARNING:'warn',NOT_SUPPORTED:'bad'};
  const label = kind === 'dialer'
    ? {SUPPORTED:'✓ 支持',SUPPORTED_WITH_WARNING:'⚠ 支持',NOT_SUPPORTED:'✗ 不支持'}[v]
    : {SUPPORTED:'✓ 支持',SUPPORTED_WITH_WARNING:'⚠ 支持',NOT_SUPPORTED:'✗ 不支持'}[v];
  return `<span class="tag ${m[v]||''}">${ESC(label||v||'?')}</span>`;
}
// 每节点的"浏览器"开关。
//   协议不支持 -> 置灰不可点（它本来就走 Xray 自带 TLS，开了也没用）
//   协议支持   -> 显示为"始终使用"并锁住：xhttp/websocket 出站只要浏览器在线就被
//                Xray 无条件接管，关掉不是退回 Xray TLS，而是让该节点直接不可用。
// 每节点的"浏览器"开关。
//   协议不支持（非 vless 的 ws/xhttp、或 REALITY）-> 置灰，写了也没用
//   协议支持 -> 可切换：默认（用浏览器）/ 强制用 / 强制不用（走 Xray 自带 TLS）
// 切换会重启 Xray：是否带 XRAY_BROWSER_DIALER 是进程启动时决定的，不重启不生效。
function browserToggle(n){
  const c = n.compat || {};
  const dialer = c.dialer || {};
  const overall = dialer.overall || '';
  const can = overall === 'SUPPORTED' || overall === 'SUPPORTED_WITH_WARNING';
  const mayProto = !!c.protocol_may_dialer;      // 协议层面是否可能走浏览器
  const probe = n.probe_ok;                       // true / false / undefined

  // 协议层面就不可能 -> 真置灰。写了也没用：hysteria2 会走它自己的原生 QUIC，
  // 浏览器根本不在路径上（实测过：代理能通，但那是原生 QUIC 通的）。
  if (!mayProto) {
    const why = (dialer.notes||[])[0] || '该协议不走浏览器转发（只对 vless 的 ws/xhttp 生效，且不支持 REALITY）';
    return `<span class="tag" title="${ESC(why)}">— 不需要</span>`;
  }

  // 协议可能但实测失败 -> 给个可点的「重测」。
  // 不能做成死灰：服务器那边的配置问题修好之后，用户得有办法恢复。
  if (probe === false) {
    const why = (dialer.notes||[]).join(' ') || '实测未通过';
    return `<span class="tag warn" style="cursor:pointer" title="${ESC('实测未通过：' + why + ' — 点此重新探测（服务器修好后可恢复）')}"`
         + ` onclick="reprobe('${ESC(n.file)}', this)">重测</span>`;
  }
  // 协议可能、还没测过
  if ((probe === undefined || probe === null) && !can) {
    const why = (dialer.notes||[]).join(' ') || '判定未通过';
    return `<span class="tag warn" style="cursor:pointer" title="${ESC(why + ' — 点此实测一次')}"`
         + ` onclick="reprobe('${ESC(n.file)}', this)">未实测</span>`;
  }

  // 可用：在 默认 / 浏览器 / 原生 之间切换
  const ub = n.use_browser;
  let label, cls, title;
  if (ub === false)     { label = '原生 TLS';     cls = '';    title = '已强制不用浏览器，Xray 自己完成 TLS（点一下改为默认）'; }
  else if (ub === true) { label = '浏览器';       cls = 'acc'; title = '已强制使用浏览器（点一下改为原生）'; }
  else                  { label = '浏览器(默认)'; cls = 'acc'; title = '默认：协议支持就用浏览器（点一下改为原生 TLS）'; }
  return `<span class="tag ${cls}" style="cursor:pointer" title="${ESC(title)}"`
       + ` onclick="toggleBrowser('${ESC(n.file)}', this)">${ESC(label)}</span>`;
}
// 「普通连接」与「BD 连接」两个独立按钮 —— 这是同一个节点的两种用法：
//   普通连接 = 用 Xray 自带 TLS（同时会把浏览器关掉，省下 Chromium 的显存/内存）
//   BD 连接  = 用浏览器完成 TLS（真实浏览器指纹）
// 当前节点上也各留一个**可点**的按钮，用来在两种用法之间切换 ——
// 以前当前节点什么都不显示，用户就没有入口去切换，看起来像"关不掉"。
function useButtons(n){
  const c = n.compat || {};
  const mayProto = !!c.protocol_may_dialer;      // 协议层面能否走浏览器
  const probe = n.probe_ok;                       // true / false / undefined
  const canBD = mayProto && probe !== false;      // 能用浏览器的前提：协议可能 + 实测没失败
  const ub = n.use_browser;
  const bdOn = canBD && ub !== false;             // 当前是否在用浏览器
  const cur = !!n.current;

  // 「普通连接」**永远**要有 —— 任何节点都能用 Xray 自带 TLS。
  // 之前只在"能用浏览器"的分支里给这个按钮，导致不支持 BD 的节点完全没有入口切过去
  // （用户反馈：其他节点连"普通连接"按钮都没有）。这是个实打实的疏漏。
  let h = `<button class="sm ${(!bdOn && cur) ? 'pri' : ''}" `
        + `onclick="useNodeAs('${ESC(n.file)}','normal', this)" `
        + `title="用 Xray 自带 TLS（会关闭浏览器，释放内存）">普通连接</button>`;

  if (!mayProto) {
    // 协议层面就不可能走浏览器：标明原因即可，不再给 BD 按钮
    const why = ((c.dialer||{}).notes||[])[0] || '该协议不走浏览器转发（只对 vless 的 ws/xhttp 生效）';
    h += `<span class="tag" title="${ESC(why)}">仅原生</span>`;
  } else if (probe === false) {
    // 协议可能、实测失败：给「重测」，服务器修好后能恢复
    h += `<span class="tag warn" style="cursor:pointer" `
       + `title="${ESC('实测未通过，点此重新探测（服务器修好后可恢复）')}" `
       + `onclick="reprobe('${ESC(n.file)}', this)">重测</span>`;
  } else {
    h += `<button class="sm ${(bdOn && cur) ? 'pri' : ''}" `
       + `onclick="useNodeAs('${ESC(n.file)}','bd', this)" `
       + `title="用浏览器完成 TLS（真实浏览器指纹）">BD 连接</button>`;
  }
  return h;
}
async function useNodeAs(file, mode, btn){
  const label = (mode === 'bd')
    ? '正在切到 BD 连接（启用浏览器）…'
    : '正在切到普通连接（关闭浏览器）…';
  await post('node_use_as', {ident:file, mode:mode}, label, btn);
}
async function reprobe(file, btn){
  await post('node_probe', {ident:file}, '正在实测浏览器路径（约 30-60 秒）…', btn);
}
async function toggleBrowser(file, btn){
  // 在 默认 -> 原生 -> 浏览器 -> 默认 之间循环
  const row = (ST.nodes||[]).find(x => x.file === file) || {};
  const cur = row.use_browser;
  const next = (cur === null || cur === undefined) ? 'off' : (cur === false ? 'on' : 'auto');
  const label = {off:'正在改为原生 TLS（重启 Xray）…', on:'正在改为浏览器 TLS（重启 Xray）…',
                 auto:'正在改为默认…'}[next];
  await post('node_browser', {ident:file, value:next}, label, btn);
}
function say(t, cls){ const m=$('msg'); m.textContent=t; m.className='on '+(cls||''); }
function clearMsg(){ $('msg').className=''; }
function out(t){ $('out-card').style.display='block'; $('out').textContent=t; }

async function load(){
  try{
    const ctl=new AbortController(); const tm=setTimeout(()=>ctl.abort(),20000);
    ST = await (await fetch('/api/state',{signal:ctl.signal})).json();
    clearTimeout(tm);
  }catch(e){ say('无法连接面板后端：'+e, 'err'); return; }
  if (ST.error){ say('状态异常：'+ST.error,'err'); return; }

  $('stamp').textContent = '更新于 ' + ST.time;

  const svc = ST.services||{}, ports = ST.ports||{}, extra = ST.services_extra||{};
  const xrayOn = svc.xray && svc.xray.active;
  const chromOn = svc.chromium && svc.chromium.active;
  const canBD = !!ST.can_use_dialer;

  $('s-xray').innerHTML = dot(xrayOn, cn(svc.xray ? svc.xray.state : 'unknown'));
  // 状态栏要说清"这个节点实际走哪条路"，而不是笼统的 Running
  // 连接模式也要说"当前实际走哪条路"。以前只看 can_use_dialer（协议能力），
  // 于是用户主动选了「普通连接」之后，界面还在报红"需要浏览器 TLS，但 Chromium 已停" ——
  // 明明能正常用，纯属误报，看着让人以为坏了。
  // 现在优先用后端给的 mode_detail（把"在跑什么"和"走哪条路"合成一句话），
  // 拿不到时退回本地判断。
  const bdInUse = canBD && ST.use_browser !== false;
  const detail = ST.mode_detail || '';
  $('s-mode').innerHTML = !xrayOn
    ? '<span class="tag">已停止</span>'
    : (bdInUse && !chromOn
        ? '<span class="tag bad">需要浏览器 TLS，但 Chromium 已停</span>'
        : `<span class="tag ${bdInUse ? 'acc' : 'ok'}">${ESC(detail || (bdInUse ? '浏览器 TLS' : 'Xray 自带 TLS'))}</span>`);
  $('s-node').textContent = ST.node ? ST.node.name : '（未选择）';
  $('s-ip').textContent = ST.exit_ip || '—';
  if ($('s-ip2')) $('s-ip2').textContent = ST.exit_ip || '—';
  $('s-proxy').innerHTML = ST.proxy_ok ? dot(true,'正常') : dot(false,'未连通');

  const nodePath = !ST.node ? '（未选择节点）'
    : (canBD ? (chromOn ? '经浏览器（Chromium 完成 TLS）' : '需要浏览器，但 Chromium 未运行')
             : '经 Xray（自带 TLS，不需要浏览器）');
  $('s-dialer').innerHTML = !ST.node ? ESC(nodePath)
    : (canBD ? `<span class="tag ${chromOn?'acc':'bad'}">${ESC(nodePath)}</span>`
             : `<span class="tag ok">${ESC(nodePath)}</span>`);
  $('s-chromium').innerHTML = dot(chromOn, chromOn ? `正在运行 (${ST.chromium_procs||0} 进程)` : '已停止');
  $('s-ws').textContent = ST.ws_connections ?? 0;
  $('s-nport').innerHTML = `${ESC((ports.listen||'')+':'+(ports.normal||''))} ${ports.normal_up?'<span class="tag ok">监听中</span>':'<span class="tag bad">未监听</span>'}`;
  if ($('s-hport')) $('s-hport').innerHTML = `${ESC((ports.listen||'')+':'+(ports.lan_http||''))} ${ports.lan_http_up?'<span class="tag ok">监听中</span>':'<span class="tag bad">未监听</span>'}`;

  // 主按钮：跟着 Xray 状态切换
  const bt = $('btn-toggle');
  bt.textContent = xrayOn ? '停止 Xray' : '启动 Xray';
  bt.className = xrayOn ? 'danger' : 'pri';
  bt.disabled = false;

  // 运行时按钮：控制 Chromium 在不在线。
  //
  // 这里刻意**不**用"节点是否支持 BD"来禁用「停掉 Chromium」——
  // 以前那样写，当前节点一旦支持 BD 这个按钮就永远点不动，用户以为坏了（实测反馈）。
  // 现在的语义是：
  //   启动 Chromium  -> 当前节点走浏览器（等价于点「BD 连接」）
  //   停掉 Chromium  -> 先把当前节点切到普通连接（Xray 自带 TLS），再停浏览器
  // 也就是说这两个按钮和操作列的两个按钮是**同一套动作**，不会再互相矛盾。
  const nodeUsesBrowser = !!ST.can_use_dialer && ST.use_browser !== false;
  $('m-normal').className = chromOn ? '' : 'sel';
  $('m-dialer').className = chromOn ? 'sel' : '';
  $('m-dialer').disabled = !xrayOn || chromOn;
  $('m-normal').disabled = !xrayOn || !chromOn;
  if ($('s-chromium-procs')) {
    $('s-chromium-procs').textContent = chromOn
      ? `${ST.chromium_procs || 0} 个进程（约 890MB）` : '未运行';
  }
  $('hint-dialer').textContent = !ST.node
    ? '还没有节点。'
    : (nodeUsesBrowser
        ? (chromOn
            ? '当前节点由 Chromium 完成 TLS。点「停掉 Chromium」会先把它切到普通连接（Xray 自带 TLS）再关闭浏览器 —— 节点不会断，只是不再走浏览器。'
            : '⚠ 当前节点设置为走浏览器，但 Chromium 没在运行 —— 点「启动 Chromium」恢复。')
        : '当前节点走 Xray 自带 TLS，Chromium 关着即可（省约 890MB）。想改用浏览器指纹：在下面节点表点「BD 连接」。');
    // 代理入口照常展示（本客户端不再自动改系统配置）
    const pc = ST.ports_cfg || {};
    const L = pc.listen || '';
    $('entries').innerHTML =
      `本机 <span class="mono">127.0.0.1:${pc.http}</span><br>` +
      `LAN HTTP <span class="mono">${L}:${pc.lan_http}</span><br>` +
      `LAN SOCKS <span class="mono">${L}:${pc.normal}</span><br>` +
      `<span class="hint">三个入口都是全部节点通用，服务器按节点自动决定走哪条。</span>`;
    $('hint-takeover').textContent = ST.takeover_local
      ? '⚠ 检测到本机还有旧版「接管本机」留下的配置（'+ (ST.takeover_local_files||[]).join('、')
        + '）。不影响代理本身，但新开的 shell 会带着这些变量 —— 需要的话点右边清理。'
      : '本机没有旧版接管残留，系统环境干净。';

  $('xver').textContent = ST.xray_ver || '未知';

  // 端口设置表
  const PORT_ROWS = [
    ['normal',  'LAN SOCKS5（全部节点）',   pc.normal],
    ['http',    '本机 HTTP 代理（docker 等）', pc.http],
    ['lan-http','局域网 HTTP 代理（WiFi）',  pc.lan_http],
    ['channel', 'Xray↔Chromium 内部通道',   pc.channel],
    ['panel',   '面板',                     ST.panel_port || pc.panel],
    ['api',     'Xray 统计 API',            pc.api],
  ];
  // 绑定地址单独一行（只读展示 + 单独按钮改）
  if ($('in-addr')) $('in-addr').placeholder = '绑定地址（当前 ' + (pc.listen || '') + '）';
  $('tb-ports').innerHTML = PORT_ROWS.map(([k, label, val]) =>
    `<tr><td style="white-space:nowrap">${ESC(label)}</td>
      <td class="mono" style="width:90px">${ESC(val || '—')}</td>
      <td style="width:1%"><input id="pk-${k}" placeholder="新端口" inputmode="numeric" style="width:90px"></td>
      <td style="width:1%"><button class="sm" onclick="setPortOne('${k}', this)">改</button></td>
    </tr>`).join('');


  const dm = $('dns-mode');
  if (dm && ST.dns_mode) dm.value = ST.dns_mode;
  renderSubs();
  renderNodes();
}

async function setMulti(v){
  if(!confirm(v==='on'
     ? '开启多出站？所有节点会常驻一份配置，切换节点不再需要重启。\n\n代价：所有节点共享一份配置，任何一个节点构建失败，整份配置都通不过校验。'
     : '关闭多出站？回到单节点模式，切换节点需要重启 Xray（连接断 1-2 秒）。\n\n好处是出问题只有那一个节点，不影响其余。')) return;
  act('multi_set', {mode:v}, ()=>{
    toast(v==='on' ? '已开启多出站，正在重启…' : '已回到单节点，正在重启…');
    poll();
  });
}

function setDns(mode){
  // 切换 DNS 要重启 Xray 才生效 —— 这一点要说在前面, 否则用户改完看着没反应。
  if(!confirm('切换 DNS 模式会重启 Xray（约 3 秒），期间连接会断一次。继续？')){
    $('dns-mode').value = (ST.dns_mode || 'off');
    if ($('multi-mode')) {
      $('multi-mode').value = (ST.multi_mode || 'off');
      // 开关和运行配置可能不一致：面板上开着、运行配置里却没有 balancer。
      // 这种情况必须说出来，否则用户会以为"开关坏了"。
      const off = ST.multi_mode === 'on' && !ST.multi_active;
      $('hint-multi').innerHTML = off
        ? '<b style="color:var(--warn)">开关已打开但还没生效</b>，需要重启一次服务。'
        : (ST.multi_mode === 'on'
            ? '所有节点常驻一份配置，切换不需要重启。代价：所有节点共享一份配置，一个节点构建失败整份都过不了校验。'
            : '只有当前节点进配置。切换节点需要重启（连接断 1-2 秒），但出问题的只有那一个节点。');
    }
    return;
  }
  post('dns_set', {mode:mode}, '正在切换 DNS 并重启…');
}

/* ============================ 节点列表：分组 / 搜索 / 筛选 / 排序 ============================
   以前这里是一个扁平表格：所有节点平铺，行数等于节点数。三十个节点就要滚半天，
   而且看不出哪个来自哪条订阅。现在按订阅/分组折叠，密度可切，搜索/筛选/排序在前端
   做 —— 不重新请求，输一个字就出结果。

   状态存在 VIEW 里而不是散在 DOM 上：轮询会整块重画节点区，靠 DOM 属性保存
   勾选/展开状态每次都会被冲掉。 */
const VIEW = { density: 'table', open: {}, sel: new Set() };

function nodeGroups(){
  // 后端已经算好分组；拿不到时退回"全部塞进一个组"，保证列表还能显示
  if (ST.groups && ST.groups.length) return ST.groups;
  return [{key:'__all__', name:'全部节点', origin:'other', order:0, nodes: ST.nodes||[]}];
}

function trafficOf(f){
  const t = (ST.api && ST.api.traffic) || {};
  return t[f] || null;
}
function trafficText(f){
  const t = trafficOf(f); if (!t) return '—';
  const sum = (t.uplink||0) + (t.downlink||0);
  return fmtBytes(sum);
}
function fmtBytes(n){
  if (!n) return '0 B';
  const u = ['B','KB','MB','GB','TB'];
  let i = 0; while (n >= 1024 && i < u.length-1){ n /= 1024; i++; }
  return (i ? n.toFixed(1) : n) + ' ' + u[i];
}

function passFilter(n, q, f){
  const c = n.compat || {};
  if (q){
    const hay = [n.name, n.address, n.protocol, n.transport, n.file,
                 (c.tags||[]).join(' ')].join(' ').toLowerCase();
    if (!hay.includes(q)) return false;
  }
  // 左栏选中的组。放在这里而不是 renderNodes 里单独过滤, 是为了让"计数"和
  // "实际渲染出来的行数"永远一致 —— 两处各算一次, 迟早对不上, 而对不上时
  // 用户看到的是"写着 20 个, 列了 3 行"。
  if (f && f !== '__all__' && n.group_key !== f) return false;
  if (f === '__dialer__' && !c.can_use_dialer) return false;
  if (f === '__unsup__' && c.can_use_xray) return false;
  if (f === '__noprobe__' && n.probe_ok !== null && n.probe_ok !== undefined) return false;
  if ($('onlyavail') && $('onlyavail').checked && !(c.can_use_xray || c.can_use_dialer)) return false;
  return true;
}

function sortNodes(a, b, key){
  const la = LAT[a.file], lb = LAT[b.file];
  const va = (la && typeof la.ms === 'number') ? la.ms : null;
  const vb = (lb && typeof lb.ms === 'number') ? lb.ms : null;
  const ta = trafficOf(a.file), tb = trafficOf(b.file);
  const sa = ta ? ta.uplink+ta.downlink : -1, sb = tb ? tb.uplink+tb.downlink : -1;
  switch(key){
    case 'name':    return String(a.name).localeCompare(String(b.name), 'zh');
    // 延迟升序。没测过的排最后 —— 按 0 排会让"没测"看起来像"最快"。
    case 'lat':     return (va===null)-(vb===null) || ((va??1e9)-(vb??1e9));
    case 'traffic': return sb-sa;
    case 'proto':   return String(a.protocol).localeCompare(String(b.protocol)) ||
                           String(a.name).localeCompare(String(b.name), 'zh');
    default:        return 0;   // 默认保持后端顺序：当前节点排最前，其余按文件名
  }
}

/* 右边只渲染**当前选中组**的节点，不再是可折叠的树。

这是这次布局简化的核心：分组关系很浅（一层），套一层折叠树只增加两级点击
和一层状态要维护，没换来任何东西。组固定在左边，选中即看，折叠与否都不存在
"我刚才展开的那个组"这种要记住的状态。 */
function renderNodes(){
  const box = $('node-list'); if(!box) return;
  const q  = ($('nq').value || '').trim().toLowerCase();
  const sk = $('ns').value;
  const gk = SUBUI.group || '__all__';
  const all = ST.nodes || [];

  let ns = all.filter(n => passFilter(n, q, gk));
  ns = ns.slice().sort((a,b) => sk==='default' ? 0 : sortNodes(a,b,sk));

  box.className = 'view-' + VIEW.density;
  box.innerHTML = ns.length ? renderBody(ns, sk)
    : '<div class="empty">这个分组里没有匹配的节点。<br>换个关键字，或把分组切回「全部」。</div>';

  const g = groupNodesNow().find(x => x.key === gk);
  const gname = (gk === '__all__') ? '全部' : (g ? g.name : '');
  $('node-count').textContent = `${gname} · 显示 ${ns.length} / ${all.length} 个节点`
    + (VIEW.sel.size ? ` · 已选 ${VIEW.sel.size}` : '')
    + ((ST.api && ST.api.available) ? ' · API 在线（切换不重启）'
                                    : ' · API 不可用（切换会重启 Xray）');

  // 轮询重画后把已测延迟补回去，否则测速结果每次刷新都被冲掉。
  Object.keys(LAT).forEach(f => {
    const c = document.getElementById('lat-'+f);
    if (c) c.innerHTML = latText(f);
  });
}

function renderBody(ns, sk){
  const sel = n => `<input type="checkbox" class="sel" ${VIEW.sel.has(n.file)?'checked':''}
      onchange="toggleSel('${ESC(n.file)}', this)">`;
  if (VIEW.density === 'grid'){
    return `<div class="gridwrap">` + ns.map(n => {
      const c = n.compat || {};
      return `<div class="ncard ${n.current?'cur':''}">
        <div class="nm">${sel(n)}${n.current?'<span class="cur-dot" title="当前节点"></span>':''}
          <span>${ESC(n.name)}</span></div>
        <div class="hint mono">${ESC(n.address)}:${ESC(n.port)}</div>
        <div style="margin:6px 0">${(c.tags||[]).map(tagHtml).join('')}</div>
        <div class="tr">延迟 <span id="lat-${ESC(n.file)}">${latText(n.file)}</span> · 流量 ${trafficText(n.file)}</div>
        <div style="margin-top:7px;display:flex;gap:5px;flex-wrap:wrap">
          ${useButtons(n)}
          <button class="sm" onclick="testLatency('${ESC(n.file)}', this)">测速</button>
          <button class="sm" onclick="checkNode('${ESC(n.file)}', this)">检查</button>
          ${n.current?'':`<button class="sm" onclick="rmNode('${ESC(n.file)}')">删除</button>`}
        </div></div>`;
    }).join('') + `</div>`;
  }
  if (VIEW.density === 'list'){
    return `<div class="listwrap">` + ns.map(n => {
      const c = n.compat || {};
      const ok = c.can_use_xray, dl = c.can_use_dialer;
      return `<div class="nrow ${n.current?'cur':''}">
        ${sel(n)}
        <span class="grow">${n.current?'<span class="tag ok">当前</span> ':''}${ESC(n.name)}</span>
        <span class="tag ${ok?'':'bad'}">${ok?'Xray':'不可用'}</span>
        ${dl?'<span class="tag acc">Dialer</span>':''}
        <span class="tr mono" id="lat-${ESC(n.file)}">${latText(n.file)}</span>
        <span class="tr">${trafficText(n.file)}</span>
        <span>${useButtons(n)}
          <button class="sm" onclick="testLatency('${ESC(n.file)}', this)">测速</button>
          ${n.current?'':`<button class="sm" onclick="rmNode('${ESC(n.file)}')">删除</button>`}</span>
      </div>`;
    }).join('') + `</div>`;
  }
  return `<table><thead><tr>
      <th class="rowsel"></th><th>节点</th><th>能力标签</th><th>Xray</th>
      <th>Browser Dialer</th><th>延时</th><th>流量</th><th style="text-align:right">操作</th>
    </tr></thead><tbody>` + ns.map(n => {
    const c = n.compat || {};
    return `<tr class="${n.current?'cur':''}">
      <td class="rowsel">${sel(n)}</td>
      <td>${n.current?'<span class="tag ok">当前</span> ':''}${ESC(n.name)}
        <div class="hint mono">${ESC(n.address)}:${ESC(n.port)}</div></td>
      <td>${(c.tags||[]).map(tagHtml).join('')}</td>
      <td>${vtag((c.xray||{}).overall,'xray')}</td>
      <td>${vtag((c.dialer||{}).overall,'dialer')}</td>
      <td class="mono" id="lat-${ESC(n.file)}" style="white-space:nowrap">${latText(n.file)}</td>
      <td class="mono tr">${trafficText(n.file)}</td>
      <td style="text-align:right;white-space:nowrap">
        ${useButtons(n)}
        <button class="sm" onclick="testLatency('${ESC(n.file)}', this)">测速</button>
        <button class="sm" onclick="checkNode('${ESC(n.file)}', this)">检查</button>
        ${n.current?'':`<button class="sm" onclick="rmNode('${ESC(n.file)}')">删除</button>`}
      </td></tr>`;
  }).join('') + `</tbody></table>`;
}

function tagHtml(t){
  const cls = t.includes('不可用') ? 'bad' : (t==='Browser Dialer'||t==='Xray' ? 'acc' : '');
  return `<span class="tag ${cls}">${ESC(t)}</span>`;
}

function setDensity(d){ VIEW.density = d; renderNodes(); }
function toggleSel(file, el){ el.checked ? VIEW.sel.add(file) : VIEW.sel.delete(file); renderNodes(); }

function batchAll(btn){
  const vis = visibleFiles();
  const all = vis.every(f => VIEW.sel.has(f));
  vis.forEach(f => all ? VIEW.sel.delete(f) : VIEW.sel.add(f));
  renderNodes();
}
function visibleFiles(){
  const out = [];
  document.querySelectorAll('#node-list .sel').forEach(c => {
    const m = /toggleSel\('([^']+)'/.exec(c.getAttribute('onchange')||'');
    if (m) out.push(m[1]);
  });
  return out;
}
async function batchTest(){
  const files = selectedOrVisible();
  if (!files.length) return say('先用勾选挑节点，或先点「全选」');
  say(`正在测速 ${files.length} 个节点…`);
  let ok = 0;
  // 批量里必须用不刷新状态的那条路: post() 每次都 load() 整个面板,
  // 三十个节点就是三十次全量重拉, 比测速本身还慢。
  for (const f of files){
    if (await postQuiet('node_latency', {ident:f})) ok++;
  }
  renderNodes();
  say(`测速完成：${ok}/${files.length}`);
}
async function batchDelete(){
  const files = selectedOrVisible();
  if (!files.length) return say('先用勾选挑节点，或先点「全选」');
  if (!confirm(`确定删除选中的 ${files.length} 个节点？\n当前节点不会被删除。`)) return;
  let ok = 0, bad = [];
  for (const f of files){
    const cur = (ST.nodes||[]).find(n => n.file === f);
    if (cur && cur.current) continue;      // 当前节点不删, 删了代理就没出口了
    if (await postQuiet('node_remove', {ident:f})) ok++; else bad.push(f);
  }
  VIEW.sel.clear();
  await load();
  say(bad.length ? `已删除 ${ok} 个，${bad.length} 个失败` : `已删除 ${ok} 个节点`,
      bad.length ? 'err' : 'good');
}
function selectedOrVisible(){
  return VIEW.sel.size ? [...VIEW.sel] : visibleFiles();
}

// 只禁用"被点的那个按钮"并显示进度 —— 以前是全局禁用所有按钮，
// 一旦异常或状态残留，整个面板就再也点不动了（看起来像黑掉）。
async function post(action, payload, label, btn){
  if (label) say(label);
  let oldText = '';
  if (btn) { oldText = btn.textContent; btn.disabled = true; btn.dataset.busy = '1'; }
  try{
    const r = await fetch('/api/action', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify(Object.assign({action}, payload||{}))});
    const j = await r.json();
    say((j.ok?'✓ ':'✗ ') + (j.message||''), j.ok?'good':'err');
    return j;
  }catch(e){ say('请求失败：'+e,'err'); return {ok:false}; }
  finally{
    if (btn) { btn.disabled = false; btn.dataset.busy = ''; btn.textContent = oldText; }
    try { await load(); } catch(e) { /* 刷新失败不影响按钮恢复 */ }
  }
}

// 批量操作专用：不刷新面板状态，只回报成败。
// post() 每次调用都会 load() 整个状态，批量三十个节点就是三十次全量重拉。
async function postQuiet(action, payload){
  try{
    const r = await fetch('/api/action', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify(Object.assign({action}, payload||{}))});
    const j = await r.json();
    if (!j.ok) say(j.message || '操作失败', 'err');
    return !!j.ok;
  }catch(e){ say('请求失败：'+e, 'err'); return false; }
}
async function toggleMain(){
  const on = ST.services && ST.services.xray && ST.services.xray.active;
  await post('service', {op: on?'stop':'start'}, on?'正在停止 Xray…':'正在启动 Xray…');
}
const svc = op => post('service', {op}, '正在执行…');
async function setMode(m){
  // 「停掉 Chromium」不能只是停进程：若当前节点设置为走浏览器，停掉会让它永久挂住
  // （dialTask 没有超时）。所以先把当前节点切成普通连接，再停浏览器 —— 一步到位。
  if (m === 'normal' && ST.node) {
    return post('node_use_as', {ident: ST.node.file, mode: 'normal'},
                '正在切到普通连接并关闭浏览器…');
  }
  if (m === 'browser_dialer' && ST.node && ST.can_use_dialer) {
    return post('node_use_as', {ident: ST.node.file, mode: 'bd'},
                '正在切到 BD 连接并启动浏览器…');
  }
  return post('mode', {mode:m},
    m==='browser_dialer' ? '正在启动 Chromium（约需 15 秒）…' : '正在停掉 Chromium…');
}
const useNode = (f, btn) => post('node_use', {ident:f}, '正在切换节点…', btn);
const rmNode = f => { if(confirm('确认删除该节点？')) post('node_remove', {ident:f}); };
async function cleanTakeover(){
  if(!confirm('清理旧版「接管本机」写进系统的代理配置？\n'
         + '会处理 /etc/profile.d/proxy.sh、docker 的代理覆盖、/etc/environment。\n'
         + '不属于本客户端写的会跳过。\n\n继续？')) return;
  const el = document.getElementById('tk-clean');
  await post('takeover', {mode:'clean'}, '正在清理旧配置…', el);
}

async function xrayCheck(btn){ await post('xray_version', {}, '正在检查版本…', btn); }

async function xrayUpgrade(btn){
  if (!confirm('确认更新 Xray 内核？更新后本项目服务会重启（局域网代理会短暂中断几秒）。')) return;
  await post('xray_upgrade', {}, '正在下载并更新内核，可能需要 1-2 分钟…', btn);
}

async function setPortOne(kind, btn){
  const el = document.getElementById('pk-'+kind);
  const v = (el && el.value || '').trim();
  if (!v) return say('请先在「'+kind+'」这一行填入新端口', 'err');
  const warn = {channel:'内部通道改动会重启 Xray 与 Chromium', panel:'面板端口改动后需用新地址访问'}[kind];
  if (warn && !confirm(warn + '，确认继续？')) return;
  const j = await post('port_set', {kind, value:v}, `正在修改 ${kind} 端口…`, btn);
  if (j.ok && el) el.value = '';
}

async function loadConn(btn){
  const j = await post('conninfo', {}, '正在生成连接配置…', btn);
  if (!j.ok) return;
  let d;
  try { d = JSON.parse(j.message); } catch (e) { return say('配置生成失败', 'err'); }
  $('conn-yaml').textContent = d.yaml;
  $('conn-env').textContent = d.env_example;
  $('conn-note').textContent = d.local_note || '';
  $('tb-links').innerHTML = (d.links || []).map(l =>
    `<tr><td style="white-space:nowrap">${ESC(l.label)}</td>
      <td class="mono">${ESC(l.url)}</td>
      <td style="width:1%"><button class="sm" onclick="copyText('${ESC(l.url)}', this)">复制</button></td>
    </tr>`).join('');
}

async function setAddr(btn){
  const el = $('in-addr');
  const v = (el && el.value || '').trim();
  if (!v) return say('请输入绑定地址（如 127.0.0.1 或 192.168.1.178）', 'err');
  if (v === '0.0.0.0') {
    if (!confirm('0.0.0.0 会让代理对你的整个网络（含公网，若端口转发）开放。确认？')) return;
  }
  const j = await post('port_set', {kind:'addr', value:v}, '正在修改绑定地址…', btn);
  if (j.ok && el) el.value = '';
}

async function portsCheck(btn){ await post('ports_check', {}, '正在检查端口冲突…', btn); }
async function portsFix(btn){
  if (!confirm('自动重新分配被占用的端口？只改冲突的那些，正常的端口不动。')) return;
  await post('ports_fix', {}, '正在重新分配…', btn);
}

/* ============================ 添加节点 ============================
   以前只有一个粘贴框，把链接/订阅/JSON/YAML 混在一起。现在按来源分开，
   手动添加则先选协议 —— 只有选了协议才知道该问哪些字段。

   表单最后拼成分享链接交给既有解析器导入（node.py build → parse）。
   不另外写一套结构化导入：那样就多一个解析器，字段行为一旦不一致，
   用户看到的是"手动建的能用、粘贴的不能用"，那是最难查的一类问题。 */
/* ===================== 订阅栏（左） =====================
   组固定在左边，不做可嵌套的树。理由见 CSS 注释。
   手动节点进常驻的「手动」组 —— 而不是每个手动节点自己生成一组：
   那样组列表会被单节点淹没，正是 zashboard/metacubexd 都踩过的坑。 */
const SUBUI = {group:'__all__'};

function groupNodesNow(){
  return (ST.groups && ST.groups.length) ? ST.groups
       : [{key:'__all__', name:'全部', origin:'fallback', order:0, nodes:(ST.nodes||[])}];
}

function renderSubs(){
  const box = $('subs-list'); if(!box) return;
  const q = ($('gq').value||'').trim().toLowerCase();
  const gs = groupNodesNow().filter(g => !q || g.name.toLowerCase().includes(q));
  const total = (ST.nodes||[]).length;

  // 「全部」永远第一行：用户最常用的动作是"我想看所有节点"。
  let h = `<div class="srow${SUBUI.group==='__all__'?' on':''}" onclick="pickGroup('__all__')">
      <span class="sn">全部</span><span class="sc">${total}</span></div>`;
  h += gs.map(g=>{
    const n = (g.nodes||[]).length;
    return `<div class="srow${SUBUI.group===g.key?' on':''}" onclick="pickGroup('${escAttr(g.key)}')"
        title="${escAttr(g.name)}">
      <span class="sn">${ESC(g.name)}</span><span class="sc">${n}</span>
      <button class="sd" title="删除这个组" onclick="event.stopPropagation();delGroup('${escAttr(g.key)}','${escAttr(g.name)}',${n})">✕</button>
    </div>`;
  }).join('');
  if(!gs.length) h += '<div class="sempty">没有匹配的分组</div>';
  box.innerHTML = h;
  const sc = $('side-count'); if(sc) sc.textContent = total;
}

function pickGroup(k){ SUBUI.group = k; renderSubs(); renderNodes(); }

// 删组是不可撤销的，所以确认框必须写清"连带删掉 N 个节点"。
// 只问一句"确定吗"的话，用户根本不知道这一下会带走多少东西。
function delGroup(key, name, n){
  if(key === '__all__') return say('「全部」不是分组，不能删除','err');
  const extra = (ST.nodes||[]).length - n;
  const tail = extra > 0 ? `，该组以外的 ${extra} 个节点会保留` : '';
  if(!confirm(`删除分组「${name}」？\n\n会同时移除它的 ${n} 个节点，此操作不可撤销。${tail}\n\n节点本身删除后无法从面板恢复。`)) return;
  post('group_delete', {key:key}, `正在删除分组「${name}」…`);
}

async function newGroup(){
  const name = (prompt('新分组名称：','')||'').trim();
  if(!name) return;
  const r = await post('group_create', {name:name}, '正在创建分组…');
  if(r.ok) { SUBUI.group = r.message || SUBUI.group; load(); }
}

const ADD = {proto:''};

function openAdd(){
  $('add-modal').classList.add('show');
  ['add-menu','add-form','add-paste','add-qr','add-pull'].forEach(i=>$(i).style.display = (i==='add-menu')?'':'none');
}
function closeAdd(){ $('add-modal').classList.remove('show'); }

// 各协议支持哪些传输。hysteria2 是 QUIC 内建的, Xray 里没有 streamSettings,
// 所以不给传输选项 —— 让用户在传输下拉里选 tcp+quic 只会配出一个连不上的节点。
const TRANS = {
  vless:        [['tcp','TCP'],['ws','WebSocket'],['grpc','gRPC'],['xhttp','XHTTP'],['httpupgrade','HTTPUpgrade'],['kcp','mKCP']],
  vmess:        [['tcp','TCP'],['ws','WebSocket'],['grpc','gRPC'],['httpupgrade','HTTPUpgrade'],['kcp','mKCP']],
  trojan:       [['tcp','TCP'],['ws','WebSocket'],['grpc','gRPC'],['xhttp','XHTTP'],['httpupgrade','HTTPUpgrade']],
  shadowsocks:  [['tcp','TCP']],
  hysteria2:    [],
};
const NSEC = {shadowsocks:['none'], hysteria2:['none'], vless:['none','tls','reality'],
              vmess:['none','tls'], trojan:['none','tls','reality']};

function pickProto(p){
  ADD.proto = p;
  ['add-menu','add-form','add-paste','add-qr','add-pull'].forEach(i=>$(i).style.display = (i==='add-form')?'':'none');
  $('f-proto').textContent = p;
  $('f-cred').innerHTML = (p==='vless'||p==='vmess')
    ? row('UUID', `<input id="f-uuid" placeholder="${p==='vmess'?'VMess UUID':'VLESS UUID'}">`)
    : (p==='shadowsocks'
        ? row('加密', `<select id="f-method"><option>aes-128-gcm</option><option>aes-256-gcm</option>
             <option>chacha20-ietf-poly1305</option><option>2022-blake3-aes-128-gcm</option>
             <option>2022-blake3-aes-256-gcm</option><option>2022-blake3-chacha20-poly1305</option></select>`)
             + row('密码', '<input id="f-password">')
        : row('密码', '<input id="f-password">'));
  const tr=$('f-transport');
  tr.innerHTML = (TRANS[p]||[]).map(([v,t])=>`<option value="${v}">${t}</option>`).join('');
  tr.disabled = !(TRANS[p]||[]).length;
  const se=$('f-security');
  se.innerHTML = (NSEC[p]||['none']).map(v=>`<option value="${v}">${v.toUpperCase()}</option>`).join('');
  // flow 只在 vless + tcp + reality 下有意义, 其余时候置灰并说明为什么
  const fl=$('f-flow'); fl.value=''; fl.disabled = true;
  onTransport();
}
const row = (label, inner) => `<div class="mrow"><label>${label}</label>${inner}</div>`;

function onTransport(){
  const t = $('f-transport').value, sec = $('f-security').value;
  const fl = $('f-flow');
  const needFlow = ADD.proto==='vless' && (t==='tcp') && sec==='reality';
  fl.disabled = !needFlow;
  fl.title = needFlow ? '' : 'xtls-rprx-vision 仅适用于 VLESS + TCP + REALITY';
  if (!needFlow) fl.value='';
  renderFields();
}

function renderFields(){
  const t = $('f-transport').value, sec = $('f-security').value;
  let h = '';
  const hostPath = ['ws','xhttp','httpupgrade'].includes(t);
  if (hostPath) h += row('路径', `<input id="f-path" placeholder="/">`);
  if (['ws','xhttp','httpupgrade','grpc'].includes(t)) h += row('Host', '<input id="f-host">');
  if (t==='grpc') h += row('服务名', '<input id="f-service_name" placeholder="GunService">');
  if (sec==='tls'||sec==='reality'){
    h += row('SNI', '<input id="f-sni" placeholder="留空则与地址相同">');
  }
  if (sec==='reality'){
    h += row('公钥', '<input id="f-reality_public_key" placeholder="REALITY public key">');
    h += row('ShortID', '<input id="f-reality_short_id" placeholder="十六进制, 可留空">');
    h += row('爬虫', '<input id="f-reality_spider_x" placeholder="spiderX, 可留空">');
  }
  $('f-transport-fields').innerHTML = h;
  $('f-security-fields').innerHTML = '';
}

function pickPaste(){ show1('add-paste'); $('add-sub-name-row').style.display=''; }
function pickQR(){ show1('add-qr'); }
function pickPull(){ show1('add-pull'); }
function show1(id){ ['add-menu','add-form','add-paste','add-qr','add-pull'].forEach(i=>$(i).style.display = (i===id)?'':'none'); }

function collect(){
  const v = id => { const e=$(id); return e ? e.value.trim() : ''; };
  const n = {
    name: v('f-name'), protocol: ADD.proto, address: v('f-address'),
    port: parseInt(v('f-port')||'443',10),
    transport: v('f-transport') || 'tcp',
    security: v('f-security') || 'none',
  };
  if (v('f-uuid'))    n.uuid = v('f-uuid');
  if (v('f-password')) n.password = v('f-password');
  if (v('f-method'))   n.method = v('f-method');
  for (const k of ['sni','host','path','service_name','flow',
                   'reality_public_key','reality_short_id','reality_spider_x']){
    if (v('f-'+k)) n[k] = v('f-'+k);
  }
  // Browser Dialer 官方说明：SNI == host == address，自定义项会被忽略。
  // 这里如实告诉用户，免得填完 sni 却发现"浏览器拨号连不上"。
  if (n.transport==='ws'||n.transport==='xhttp'){
    n.sni = n.sni || n.address;
    n.host = n.host || n.address;
  }
  return n;
}

async function submitNode(){
  const n = collect();
  if(!n.address) return say('请填地址','err');
  if((n.protocol==='vless'||n.protocol==='vmess') && !n.uuid)
    return say('请填 UUID','err');
  if(!['vless','vmess','trojan','shadowsocks','hysteria2'].includes(n.protocol))
    return say('该协议不支持，请换一个','err');
  const r = await fetch('/api/action', {method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify(Object.assign({action:'build_link'}, n))});
  const j = await r.json();
  if(!j.ok) return say(j.message||'生成分享链接失败','err');
  closeAdd();
  // 链接由后端当"消息"返回（DISPATCH 是两元组约定，带不了第三个字段）
  post('import', {uri: j.message}, '正在导入并做能力检查…');
}

async function submitPaste(){
  const v = $('add-text').value.trim();
  if(!v) return say('请先粘贴内容','err');
  const name = $('add-sub-name').value.trim();
  closeAdd();
  post('import', {uri:v, sub_name:name}, name ? '正在导入并归入分组…' : '正在导入并做能力检查…');
}

function submitPull(){
  const addr = $('pull-addr').value.trim(), p = $('pull-path').value.trim();
  if(!addr) return say('请填 Server 地址','err');
  closeAdd();
  post('import', {uri: (addr.replace(/\/+$/,'') + '/' + p.replace(/^\/+/,''))},
       '正在从 Server 拉取…');
}

const addNode = () => {
  const v = $('in-node').value.trim();
  if(!v) return say('请粘贴节点链接、Xray JSON 或 Mihomo YAML','err');
  post('import', {uri:v}, '正在导入并做能力检查…');
};
async function testLatency(file, btn){
  LAT[file] = {loading:true};
  const paint = () => {
    const c = document.getElementById('lat-'+file);
    if (c) c.innerHTML = latText(file);
  };
  paint();
  // 关键：把结果写回该行的延时单元格。
  // 以前 load() 会重建表格把结果冲掉，且 post() 的全局禁用在异常时永不恢复。
  const j = await post('node_latency', {ident:file}, '正在测速（真实请求，约 3-10 秒）…', btn);
  if (j.ok) {
    const m = /(\d+)\s*ms/.exec(j.message||'');
    LAT[file] = {ok:true, ms: m ? parseInt(m[1],10) : 0, echo:(j.message||'').trim()};
  } else {
    LAT[file] = {ok:false, msg:(j.message||'').replace(/^✗\s*/,'')};
  }
  paint();
}

async function checkNode(f, btn){
  const j = await post('node_check', {ident:f}, '正在检查能力…', btn);
  if (j.ok) out(j.message);
  else say((j.message||'检查失败'), 'err');
}

load();
loadConn();
setInterval(load, 5000);
</script></div></body></html>
"""


# ---------------------------------------------------------------------- HTTP ----
class Handler(BaseHTTPRequestHandler):
    server_version = "XBD-Panel"
    token = ""
    cookie_name = "xbd_token"

    def log_message(self, *a):
        pass

    def handle_one_request(self):
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        except Exception:
            import traceback
            traceback.print_exc()

    def _authed(self):
        if not self.token:
            return True
        if self.headers.get("X-Panel-Token") == self.token:
            return True
        raw = self.headers.get("Cookie", "")
        if raw:
            try:
                jar = SimpleCookie()
                jar.load(raw)
                if jar.get(self.cookie_name) and jar[self.cookie_name].value == self.token:
                    return True
            except Exception:
                pass
        given = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("token", [""])[0]
        if given == self.token:
            self._set_cookie = True
            return True
        return False

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if getattr(self, "_set_cookie", False):
            self.send_header("Set-Cookie", f"{self.cookie_name}={self.token}; Path=/; SameSite=Strict")
            self._set_cookie = False
        self.end_headers()
        self.wfile.write(data)

    def _deny(self):
        body = ("<!DOCTYPE html><meta charset=utf-8><title>需要令牌</title>"
                '<body style="font:15px -apple-system,Segoe UI,Roboto,sans-serif;'
                'background:#0f1115;color:#e7ebf0;padding:40px">'
                "<h2>需要访问令牌</h2>"
                "<p>请在地址后加上 <code>?token=你的令牌</code></p>"
                '<p style="color:#8b95a5">令牌保存在服务器的 '
                "<code>/opt/xray-browser-dialer/config/panel.env</code></p></body>")
        self._send(401, body, "text/html")

    def do_GET(self):
        if not self._authed():
            return self._deny()
        path = urllib.parse.urlparse(self.path).path or "/"
        if path in ("/", "/index.html"):
            return self._send(200, PAGE, "text/html")
        if path == "/api/state":
            state = build_state()
            state["panel_host"] = cfg_get(os.path.join(CONF, "panel.env"), "PANEL_HOST", "")
            state["panel_port"] = cfg_get(os.path.join(CONF, "panel.env"), "PANEL_PORT", "")
            return self._send(200, json.dumps(state, ensure_ascii=False))
        return self._send(404, "<!DOCTYPE html><meta charset=utf-8><h3>404</h3>", "text/html")

    def do_POST(self):
        if not self._authed():
            return self._deny()
        if urllib.parse.urlparse(self.path).path != "/api/action":
            return self._send(404, json.dumps({"ok": False, "message": "not found"}))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, TypeError):
            return self._send(400, json.dumps({"ok": False, "message": "bad request"}))
        action = str(payload.get("action", ""))
        fn = DISPATCH.get(action)
        if not fn:
            return self._send(200, json.dumps({"ok": False, "message": f"未知操作: {action}"}, ensure_ascii=False))
        try:
            ok, message = fn(payload)
        except Exception as exc:
            ok, message = False, f"执行异常: {exc}"
        return self._send(200, json.dumps({"ok": bool(ok), "message": message}, ensure_ascii=False))


def load_panel_env():
    env = os.path.join(CONF, "panel.env")
    return (cfg_get(env, "PANEL_HOST", BIND_HOST),
            int(cfg_get(env, "PANEL_PORT", str(BIND_PORT)) or BIND_PORT),
            cfg_get(env, "PANEL_TOKEN", ""))


def main():
    host, port, token = load_panel_env()
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--host" and i + 1 < len(args):
            host = args[i + 1]; i += 2; continue
        if a == "--port" and i + 1 < len(args):
            port = int(args[i + 1]); i += 2; continue
        if a == "--token" and i + 1 < len(args):
            token = args[i + 1]; i += 2; continue
        i += 1
    Handler.token = token
    srv = ThreadingHTTPServer((host, port), Handler)
    scope = "仅本机" if host in ("127.0.0.1", "localhost") else f"局域网可达 {host}"
    print(f"面板 http://{host}:{port} ({scope})" + ("，需要令牌" if token else ""), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
