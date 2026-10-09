#!/usr/bin/env python3
"""节点延时测试。

为什么不是简单的 TCP ping：
    节点能不能用，取决于整条链路（TCP + TLS + 传输协议 + 服务端）。
    只测 TCP 握手会给出误导性的好结果 —— 例如节点端口开着但凭据过期。
    这里临时起一个 Xray 实例，真实发一次 HTTPS 请求，测完整往返时间。

测量口径：
    latency_ms = 一次 https 请求的 total_time（含建连、TLS、请求、响应）
失败分类：
    timeout / refused / tls / handshake / no_response —— 便于判断问题在哪一层
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
DIST = os.environ.get("XBD_DIST", os.path.join(PREFIX, "xbd-dist"))
XRAY = os.path.join(PREFIX, "bin", "xray")

TEST_URL = "https://www.cloudflare.com/cdn-cgi/trace"
TEST_URL_FALLBACK = "https://api.ipify.org"


# ---------------------------------------------------------------------------
# Browser Dialer 相关
#
# 判定"这个节点要不要浏览器完成 TLS"只有一个来源: compat.py 的 want_bd。
# 这里不自己写一套 —— 三处各判一次迟早走偏, 而走偏的后果是"测速说节点坏了"
# 这种会让人删掉好节点的误报。
# ---------------------------------------------------------------------------
def _load_compat():
    for base in (os.path.dirname(os.path.abspath(__file__)), DIST):
        p = os.path.join(base, "lib", "compat.py")
        if os.path.isfile(p):
            import importlib.util
            spec = importlib.util.spec_from_file_location("_xbd_compat", p)
            mod = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(mod)
                return mod
            except Exception:
                return None
    return None


def want_browser_dialer(node: dict) -> bool:
    mod = _load_compat()
    if not mod:
        # 判定不了就不要求浏览器 —— 保持旧行为, 宁可少报也不误报。
        return False
    try:
        return bool(mod.want_browser_dialer(node))
    except Exception:
        return False




def sh(args, timeout=60):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_port(port, seconds=15):
    end = time.time() + seconds
    while time.time() < end:
        with socket.socket() as s:
            s.settimeout(0.4)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.25)
    return False


# curl 退出码 -> 失败阶段。比匹配文本可靠得多。
CURL_EXIT = {
    5: "proxy_error",     # 无法解析代理
    6: "dns",             # 无法解析主机
    7: "unreachable",     # 连接失败
    28: "timeout",
    35: "tls",            # SSL 握手失败
    51: "tls",            # 证书校验失败
    52: "no_response",    # 服务端无响应
    56: "no_response",    # 接收数据失败
    97: "proxy_error",
}


def classify(err: str, code: int | None = None) -> str:
    if code is not None and code in CURL_EXIT:
        return CURL_EXIT[code]
    e = (err or "").lower()
    if "timed out" in e or "timeout" in e:
        return "timeout"
    if "connection refused" in e:
        return "refused"
    if "ssl" in e or "tls" in e or "certificate" in e:
        return "tls"
    if "empty reply" in e or "reset" in e:
        return "no_response"
    if "could not resolve" in e or "name or service" in e or "dns" in e:
        return "dns"
    if "couldn't connect" in e or "failed to connect" in e:
        return "unreachable"
    if "proxy" in e:
        return "proxy_error"
    return "error"


def measure(node_path: str, url: str, timeout: int, tls_mismatch_ok: bool = True) -> dict:
    """返回 {ok, latency_ms, error, exit_ip}"""
    work = tempfile.mkdtemp(prefix="xbd-lat-")
    port = free_port()
    cfg = os.path.join(work, "xray.json")

    try:
        rc, out, err = sh([
            "python3", os.path.join(DIST, "lib", "genconfig.py"),
            "--node", node_path, "--output", cfg, "--mode", "normal",
            "--listen", "127.0.0.1", "--port", str(port),
            "--api-port", str(free_port()), "--no-mux",
            "--logs", work,
        ], timeout=30)
        if rc != 0:
            return {"ok": False, "latency_ms": None, "error": "config_failed",
                    "detail": (out or err)[:200]}

        # Browser Dialer 是**进程级**能力: 只有带着 XRAY_BROWSER_DIALER 启动的
        # Xray 才会让 Chromium 完成 TLS。上面这个探测进程原本不带, 于是走
        # Xray 自带 TLS —— 对"只认浏览器指纹"的服务端必然失败。
        #
        # 症状是: xbd node latency 对所有 xhttp 节点报「失败 tls」, 但切过去
        # 实际能用 (CC 上 node-001-ccsmvless-01 延时测速报 tls 失败, 常驻
        # 服务下 HTTP 204 / 出口正确)。用户看到"测速失败"会以为节点坏了,
        # 可能直接删掉好节点 —— 误报比不可用更糟。
        #
        # 所以这里两件事: 能带就带上, 带不上就明说原因。
        node = json.loads(open(node_path).read())
        needs_bd = want_browser_dialer(node)
        env = None
        if needs_bd:
            # 这里故意**不**给探测进程挂 XRAY_BROWSER_DIALER。
            #
            # 试过带上, 错误确实从 tls 变成 timeout, 说明变量传到了 —— 但仍不通。
            # 根因是 Browser Dialer 的额度只有一份: browser_dialer.dialTask()
            # 是 `conn = <-conns`, 没有超时。常驻 Xray 已经在用它, 探测进程再去
            # 抢同一个 Chromium 就永久挂住, 表现为 timeout。
            #
            # 要真测这种节点得给它单独的 Chromium 实例, 代价是几百 MB 内存和
            # 十几秒启动时间 —— 对"测一下快慢"这个动作太重。所以这里不测,
            # 直接说清楚原因, 让用户以实际使用为准。
            #
            # 关键是**别报"失败"**: 那个节点可能完全正常, 用户看到"失败"
            # 会以为节点坏了, 可能直接删掉 (CC 上 node-001-ccsmvless-01 就是
            # 常驻下 HTTP 204、被测速说 tls 失败)。
            return {"ok": False, "latency_ms": None,
                    "error": "need_browser",
                    "detail": ("该节点由浏览器完成 TLS，测速不适用。"
                               "切到它实际能用与否，以使用为准。")}

        proc = subprocess.Popen([XRAY, "run", "-config", cfg], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            if not wait_port(port):
                return {"ok": False, "latency_ms": None, "error": "xray_not_up"}

            # 预热一次，避免把 DNS/建连开销算进"延时"
            sh(["curl", "-s", "-o", "/dev/null", "--max-time", "20",
                "--socks5-hostname", f"127.0.0.1:{port}", url], timeout=30)

            best, detail, fail_code = None, "", None
            for _ in range(3):
                rc, out, err = sh([
                    "curl", "-s", "-o", "/dev/null", "--max-time", str(timeout),
                    "--socks5-hostname", f"127.0.0.1:{port}",
                    "-w", "%{time_total}", url,
                ], timeout=timeout + 10)

                # -w 总是会打印时间；但只有 rc==0 才代表这次请求真的成功。
                # rc!=0 时输出的是"失败前耗时"，不能当作延时。
                try:
                    t = float(out.strip().splitlines()[-1])
                except (ValueError, IndexError):
                    t = None

                if rc == 0 and t is not None and t > 0:
                    best = t if best is None else min(best, t)
                    break
                if fail_code is None and rc != 0:
                    fail_code, detail = rc, (err or "")

            if best is None:
                return {"ok": False, "latency_ms": None,
                        "error": classify(detail, fail_code),
                        "detail": (detail or "")[:160] or "请求失败"}

            # 顺便取出口 IP，便于确认真的走了节点
            rc, ip, _ = sh(["curl", "-s", "--max-time", "15",
                            "--socks5-hostname", f"127.0.0.1:{port}",
                            "https://api.ipify.org"], timeout=25)
            return {"ok": True, "latency_ms": round(best * 1000),
                    "exit_ip": ip if rc == 0 else ""}
        finally:
            proc.terminate()
            time.sleep(0.5)
            try:
                proc.kill()
            except Exception:
                pass
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("nodes", nargs="+", help="节点文件路径")
    ap.add_argument("--url", default=TEST_URL)
    ap.add_argument("--timeout", type=int, default=15)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    results = {}
    for path in args.nodes:
        name = os.path.basename(path)
        if not os.path.exists(path):
            results[name] = {"ok": False, "latency_ms": None, "error": "not_found"}
            continue
        r = measure(path, args.url, args.timeout)
        results[name] = r
        if not args.json:
            if r["ok"]:
                print(f"  {name:<44} {r['latency_ms']:>5} ms   {r.get('exit_ip','')}")
            elif r.get("error") == "need_browser":
                # 不能写成"失败"。这个节点很可能完全正常, 只是这次测不了 ——
                # 报"失败"会让人以为节点坏了, 直接删掉。
                print(f"  {name:<44}  需浏览器  {r.get('detail','')}")
            else:
                print(f"  {name:<44}  失败   {r['error']}")
        sys.stdout.flush()

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    # need_browser 不是失败 —— 节点没被证明不可用, 只是这次没测成。
    # 算进失败会让整条命令 exit 1, 调用方据此报"有节点坏了", 同样是误导。
    return 0 if any(v.get("ok") or v.get("error") == "need_browser"
                    for v in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
