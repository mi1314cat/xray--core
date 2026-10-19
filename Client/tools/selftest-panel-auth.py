#!/usr/bin/env python3
"""面板登录/会话/API 鉴权的无浏览器自检。

启动一个临时 panel.py（独立端口 + 临时 prefix），用真实 HTTP 请求验证：
    * 直接访问 / 是登录页，不再要求 ?token=
    * 错误密码 401，正确密码 303 + HttpOnly 会话 Cookie
    * 带 Cookie 能进主页；无 Cookie 的 API 返回 401 JSON
    * /logout 清会话
不依赖 systemd、不碰生产面板。
"""
from __future__ import annotations

import http.client
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main() -> int:
    tmp = tempfile.mkdtemp(prefix="xbd-auth-test-")
    prefix = os.path.join(tmp, "prefix")
    os.makedirs(os.path.join(prefix, "xbd-dist"), exist_ok=True)
    os.makedirs(os.path.join(prefix, "config"), exist_ok=True)
    os.makedirs(os.path.join(prefix, "nodes"), exist_ok=True)
    os.symlink(os.path.join(ROOT, "lib"), os.path.join(prefix, "lib"))
    os.symlink("../lib", os.path.join(prefix, "xbd-dist", "lib"))
    port = free_port()
    env = dict(os.environ, XBD_PREFIX=prefix)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "lib", "web", "panel.py"),
         "--host", "127.0.0.1", "--port", str(port),
         "--user", "admin", "--password", "test-pass-123"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    passed = failed = 0

    def check(name, cond, detail=""):
        nonlocal passed, failed
        if cond:
            print(f"  \033[32m✓\033[0m {name}")
            passed += 1
        else:
            print(f"  \033[31m✗\033[0m {name} {detail}")
            failed += 1

    try:
        for _ in range(40):
            try:
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                c.request("GET", "/")
                r = c.getresponse()
                home = r.read().decode("utf-8", "replace")
                c.close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            print("  ✗ 面板未启动")
            return 1
        check("直接访问 / 返回登录页", r.status == 200 and "用户名" in home and "密码" in home)
        check("登录页不再要求 token 路径", "需要令牌" not in home and "?token=" not in home)

        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        body = urllib.parse.urlencode({"username": "admin", "password": "wrong"})
        c.request("POST", "/login", body, {"Content-Type": "application/x-www-form-urlencoded"})
        r = c.getresponse(); bad = r.read().decode("utf-8", "replace"); c.close()
        check("错误密码被拒绝", r.status == 401 and "不正确" in bad)

        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        body = urllib.parse.urlencode({"username": "admin", "password": "test-pass-123"})
        c.request("POST", "/login", body, {"Content-Type": "application/x-www-form-urlencoded"})
        r = c.getresponse(); r.read(); c.close()
        cookie = r.getheader("Set-Cookie") or ""
        check("正确密码 303", r.status == 303 and r.getheader("Location") == "/")
        check("会话 Cookie 是 HttpOnly", "xbd_session=" in cookie and "HttpOnly" in cookie)

        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        c.request("GET", "/", headers={"Cookie": cookie.split(";", 1)[0]})
        r = c.getresponse(); page = r.read().decode("utf-8", "replace"); c.close()
        check("带会话能进主页", r.status == 200 and "Xray Client Manager" in page)

        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        c.request("GET", "/api/state")
        r = c.getresponse(); api = r.read().decode("utf-8", "replace"); c.close()
        check("无会话 API 返回 401 JSON", r.status == 401 and '"ok": false' in api)

        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        c.request("GET", "/logout", headers={"Cookie": cookie.split(";", 1)[0]})
        r = c.getresponse(); r.read(); c.close()
        check("退出登录 303", r.status == 303 and r.getheader("Location") == "/login")

        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        c.request("GET", "/api/state", headers={"Cookie": cookie.split(";", 1)[0]})
        r = c.getresponse(); r.read(); c.close()
        check("退出后会话失效", r.status == 401)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"面板登录自检: {'PASS' if failed == 0 else 'FAIL'}（{passed} 项）")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
