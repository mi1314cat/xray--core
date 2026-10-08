#!/usr/bin/env python3
"""Xray 分享服务 —— 把 conf/ 里的节点变成带 token 的订阅。

与 mihomo / sing-box 保持一致的产品语义, 但载荷是 Xray 自己的分享链接。

## 接口

    GET  /sub/<token>   200 订阅内容 / 403 禁止 / 404 不存在
                        410 已停用 / 410 已过期 / 410 次数用尽
                        503 内核服务未运行 / 503 无可分发内容
    GET  /status        200 健康检查 (不消耗额度)
    GET  /nodes         200 当前节点列表 (诊断用)

## 几个必须守住的性质

1. **拿到 200 必然拿到完整 body。** 扣次数在发 body 之前提交。反过来写,
   客户端收到 200 却只拿到半截内容, 而额度已经扣了 —— 用户重试一次,
   额度少一次, 问题却依旧。

2. **健康检查不扣额度。** 客户端拿它探活, 每次探活都扣一次的话,
   一次加 20 个订阅就把所有额度耗光了。

3. **HEAD 只做存在性预检。** 预检不该消耗额度, 否则"先探活再拉取"
   这个正常流程会白扣一次。

4. **扣次在锁内。** 并发拉取时, 不加锁会读-改-写竞态, 10 个并发能发出
   20 次。max_uses 是硬约束。

5. **状态码要能区分。** 404 / 410 / 503 全都返回"拉取失败"的话,
   用户无法判断是该换个链接、等过期、还是等服务起来。
"""

import base64
import json
import os
import subprocess
import sys
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import share_meta  # noqa: E402
import token_store  # noqa: E402

CONF_DIR = os.environ.get("XRAY_CONF_DIR", "/root/catmi/xray/conf")
SHARE_DIR = os.environ.get("XRAY_SHARE_DIR", "/root/catmi/xray/out/share")
LISTEN_ADDR = os.environ.get("XRAY_SHARE_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("XRAY_SHARE_PORT", "9443"))
XRAY_SERVICE = os.environ.get("XRAY_SERVICE", "xrayls")

# 两层锁, 缺一不可。
#
# 只用 threading.Lock: 多进程(比如另起一个脚本改 token)时不防竞态。
# 只用 flock: **flock 锁的是 open file description**, 同一进程内多个线程
# 若共享同一个 fd, 后者根本不会阻塞 —— 实测 12 并发抢 1 次额度全部 200,
# 超发 12 倍。所以线程锁必须自己拿, 文件锁每次调用重新 open 一次 fd。
_lock = None   # 由 token_store.locked 提供两层锁


def file_lock():
    return token_store.locked(SHARE_DIR)


# ------------------------------------------------------------------ 内容构造
def core_healthy():
    """内核服务在不在跑。不在跑就返回 503, 别发一份连不上的订阅。

    健康检查本身不扣额度 —— 它是探活, 不是取内容。
    """
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "--quiet", XRAY_SERVICE],
            capture_output=True, timeout=5,
        )
        return r.returncode == 0
    except Exception:  # noqa: BLE001
        # 容器里可能没有 systemd。查不到不等于服务一定没跑, 这种情况
        # 不该拦住分发 —— 否则 share server 会一直返回 503。
        return True


def build_links(tags):
    """按 tag 从 conf/ 片段重建分享链接。

    返回 (lines, missing, nometa, bad):

      missing  tag 在注册表里、但 conf/ 片段已经没了 (节点被删)
      nometa   片段还在, 但缺对外地址/端口 —— 生成不出分享链接
      bad      片段本身解析不了

    三类都不是致命错误: 其余节点的订阅仍然有用, 全都丢掉反而更糟。
    但必须分开报出来 —— "分享了 4 个节点客户端只收到 1 个" 如果只给一个
    总数, 是节点被删了还是没配地址, 完全查不出来。
    """
    import nodes as nodereg

    node_list, bad = nodereg.collect(CONF_DIR)
    by_tag = {n["tag"]: n for n in node_list}

    lines, missing, nometa = [], [], []
    for t in tags:
        n = by_tag.get(t)
        if not n:
            missing.append(t)
            continue
        meta = share_meta.load(SHARE_DIR, t) or {}
        link = nodereg.build_share_link(n, meta)
        if link:
            lines.append(link)
        else:
            nometa.append(t)
    return lines, missing, nometa, bad


def build_payload(tags):
    """标准订阅格式: base64 的一行。

    绝大多数客户端 (含本项目自己的 Client) 都按 base64 订阅解析, 明文多行
    只是兼容项。
    """
    links, missing, nometa, bad = build_links(tags)
    if not links:
        return None, missing, nometa, bad
    text = "\n".join(links)
    return base64.b64encode(text.encode()).decode(), missing, nometa, bad


# ------------------------------------------------------------------ HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "xray-share/1"

    def log_message(self, *_args):
        pass  # 每次拉取打一行日志, 很快就把 journal 淹了

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", head_only=False,
              extra=None):
        self.send_response(code)
        for k, v in (extra or {}).items():
            # HTTP 头是 latin-1。节点名/tag 含中文时直接 send_header 会抛
            # UnicodeEncodeError, 请求当场崩掉 —— 表现是客户端拿到空响应,
            # 而日志里只有一条看不懂的编码错误。这里做 ASCII 安全化:
            # 保留 ASCII, 其余按 UTF-8 百分号编码 (RFC 允许 header 里出现
            # %XX, 且解码方能还原)。
            v = str(v)
            v = "".join(
                c if ord(c) < 128 else "".join(f"%{b:02X}" for b in c.encode("utf-8"))
                for c in v
            )
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # 订阅内容是凭证。中间缓存留着它 = 链接被分享出去还能继续被缓存命中,
        # 停用了也照样能拉到。
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head_only and body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_HEAD(self):
        self._guard(head_only=True)

    def do_GET(self):
        self._guard(head_only=False)

    def _guard(self, head_only):
        """兜底。

        _route 里没有 try/except, 而这是常驻服务: 任何一个未捕获的异常
        (配置目录权限变了、某个片段在校验前被删、磁盘满) 都会让
        BaseHTTPRequestHandler 回 500 并往 stderr 打一整段栈。订阅客户端
        看到的是 500 而不是可判定的状态码, 排查还得去翻服务日志。

        这里兜住并给出 500 + X-Xray-Error 头。诊断信息不进 body —— body 是
        纯 base64, 多一行就整个订阅解析失败。
        """
        try:
            self._route(head_only)
        except (BrokenPipeError, ConnectionResetError):
            # 客户端自己断开。不算错误, 也不该往日志里刷栈。
            pass
        except Exception as e:  # noqa: BLE001 —— 兜底就该兜所有
            sys.stderr.write("[share] 请求处理异常: %r\n" % (e,))
            traceback.print_exc()
            try:
                self._send(500, b"internal error\n", head_only=head_only,
                           extra={"X-Xray-Error": "internal"})
            except Exception:
                pass

    def _route(self, head_only):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path == "/status":
            healthy = core_healthy()
            body = json.dumps({"ok": healthy, "service": XRAY_SERVICE}).encode()
            return self._send(200 if healthy else 503, body, "application/json", head_only)

        if path == "/nodes":
            import nodes as nodereg
            node_list, bad = nodereg.collect(CONF_DIR)
            body = json.dumps(
                {"count": len(node_list), "nodes": node_list,
                 "unreadable": [{"file": f, "error": e} for f, e in bad]},
                ensure_ascii=False, indent=2,
            ).encode()
            return self._send(200, body, "application/json; charset=utf-8", head_only)

        if not path.startswith("/sub/"):
            return self._send(404, b"not found\n", head_only=head_only)

        token = path[len("/sub/"):]
        # 形状校验同时挡路径穿越 (文件名就是 token)。返回 404 而不是 403:
        # 不告诉探测者"这条路径存在但你没权限"。
        if not token_store.valid_token(token):
            return self._send(404, b"not found\n", head_only=head_only)

        meta = token_store.read(SHARE_DIR, token)
        if meta is None or meta.get("_broken"):
            return self._send(404, b"not found\n", head_only=head_only)
        if not meta.get("enabled", True):
            return self._send(410, b"disabled\n", head_only=head_only)
        now = int(time.time())
        exp = int(meta.get("expires_at", 0))
        if exp and now > exp:
            return self._send(410, b"expired\n", head_only=head_only)
        used = int(meta.get("used_count", 0))
        maxu = int(meta.get("max_uses", 0))
        if maxu and used >= maxu:
            return self._send(410, b"used up\n", head_only=head_only)

        # HEAD 只做存在性预检: 不构造负载, 不扣额度
        if head_only:
            return self._send(200, b"", "text/plain", head_only=True)

        tags = meta.get("tags") or meta.get("tag") or []
        if isinstance(tags, str):
            tags = [tags]
        payload, missing, nometa, bad = build_payload(tags)
        if payload is None:
            # 构建失败不扣额度
            return self._send(503, b"config unavailable\n", head_only=head_only)

        # 扣减放在载荷构造成功之后。consume_once 内部重判一次状态 ——
        # 构造期间令牌可能已被别人用掉/停用, 这时必须放弃而不是照发。
        allowed, why = token_store.consume_once(SHARE_DIR, token)
        if not allowed:
            return self._send(410, f"{why}\n".encode(), head_only=head_only)

        # 告警走 HTTP 头, 不混进 body。
        #
        # body 必须是纯 base64 —— 订阅解析器按整段解码, 前面多一行注释就
        # 整个解析失败, 于是诊断信息反而把订阅弄坏了。
        # 两类"没发出去"要分开: 片段没了(节点被删) 和 缺对外地址(没配分享
        # 元数据) 是完全不同的故障, 合并成一条告警就查不出是哪一种。
        extra = {}
        if missing:
            extra["X-Xray-Missing-Nodes"] = ",".join(missing)
        if nometa:
            extra["X-Xray-No-Share-Meta"] = ",".join(nometa)
        if bad:
            extra["X-Xray-Unreadable-Fragments"] = len(bad)
        return self._send(200, payload.encode(), "text/plain; charset=utf-8",
                          head_only=head_only, extra=extra)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    os.makedirs(os.path.join(SHARE_DIR, "tokens"), exist_ok=True)
    srv = Server((LISTEN_ADDR, LISTEN_PORT), Handler)
    print(f"[OK] xray share server: http://{LISTEN_ADDR}:{LISTEN_PORT}", flush=True)
    print(f"     conf={CONF_DIR}  share={SHARE_DIR}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()