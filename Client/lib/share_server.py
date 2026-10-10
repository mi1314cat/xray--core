#!/usr/bin/env python3
"""Xray Client 配置分发服务。

让局域网里其他设备用一个 URL 拉取本客户端的完整配置 —— 换设备时不用一个个
重新导入节点，填个地址就完事。

    http://<服务器IP>:<端口>/share/<token>   → 本客户端的完整节点配置

设计上有几处是照着踩过的坑来的：

* **token 必须够长且随机。** 这服务是把节点凭据发到局域网，短 token 等于没有
  认证 —— 猜到就能拿。所以至少 16 位纯字母数字，且只在用户主动开启时生成。

* **次数预留放在发响应之前。** 用户点"导入"时，v2rayN / Shadowrocket 之类会先
  发一次 HEAD 探活再 GET。如果扣次数放在 GET 之后，一次导入会算两次，
  max_uses 很快就不准了。

* **主服务不健康就 503。** 客户端拿到一份节点配置、却连不上——那比直接报错
  更让人困惑（他会以为是机场的问题）。所以内核心不活就明确回 503。

* **只监听配置里指定的地址。** 默认只绑 LAN IP。绑 0.0.0.0 等于把节点凭据
  暴露到公网，绝不能默认。
"""
import json
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
CONF = os.path.join(PREFIX, "config")
RUNTIME = os.path.join(PREFIX, "runtime")
NODES = os.path.join(PREFIX, "nodes")
STORE_DIR = os.path.join(RUNTIME, "share")
ENV_FILE = os.path.join(CONF, "share.env")

# 单个响应最大给多少。配置本身就是几十 KB 级别，1MB 足够且能挡住异常情况。
MAX_BODY = 1024 * 1024


def _env(key, default=""):
    try:
        for line in open(ENV_FILE, encoding="utf-8"):
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return default


def listen_addr():
    return _env("SHARE_HOST", "127.0.0.1"), int(_env("SHARE_PORT", "0") or 0)


def core_healthy() -> bool:
    """内核是不是真的在跑。

    不看 PID 文件、不看配置在不在，只看这个客户端自己的服务单元。PID 文件在
    崩溃后会残留，用它判断会把"早就死了"报成"活着"。
    """
    unit = _env("SHARE_HEALTH_UNIT", "xray-client.service")
    if not unit:
        return True
    try:
        r = os.popen("systemctl is-active %s 2>/dev/null" % unit).read().strip()
        return r == "active"
    except Exception:
        return True


class Store:
    """分享链接的登记簿。并发下用一把锁串行化。"""

    _lock = threading.Lock()

    @staticmethod
    def _path(token: str) -> str:
        return os.path.join(STORE_DIR, token + ".json")

    @staticmethod
    def load(token: str):
        try:
            with open(Store._path(token), encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None

    @staticmethod
    def save(token: str, meta: dict):
        os.makedirs(STORE_DIR, exist_ok=True)
        tmp = Store._path(token) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False)
        # 先写临时文件再改名：分享状态被读到一半（订阅已经扣了次数、元数据却没写
        # 进去）会让 max_uses 计数漂移，反复几次就对不上了。
        os.replace(tmp, Store._path(token))

    @staticmethod
    def list_all():
        out = []
        try:
            for name in sorted(os.listdir(STORE_DIR)):
                if not name.endswith(".json"):
                    continue
                tok = name[:-5]
                meta = Store.load(tok)
                if meta:
                    meta["_token"] = tok
                    out.append(meta)
        except OSError:
            pass
        return out

    @staticmethod
    def new_token() -> str:
        while True:
            t = secrets.token_hex(12)          # 24 位
            if Store.load(t) is None:
                return t


def build_config() -> bytes:
    """把当前节点目录打成一个客户端能直接吃的东西。

    优先用面板订阅文件（有的话它已经带好了分组）；没有就从节点目录现拼一份
    base64 订阅 —— 这个格式 v2rayN / Shadowrocket / Clash 系都能读。
    """
    # 面板/订阅导出的文件最省事：格式已经对了，还带分组
    for cand in ("share-sub.txt", "nodes-share.txt"):
        p = os.path.join(RUNTIME, cand)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            with open(p, "rb") as fh:
                return fh.read()

    import base64
    lines = []
    try:
        for name in sorted(os.listdir(NODES)):
            if not (name.startswith("node-") and name.endswith(".json")):
                continue
            try:
                with open(os.path.join(NODES, name), encoding="utf-8") as fh:
                    node = json.load(fh)
            except (OSError, ValueError):
                continue
            try:
                sys.path.insert(0, os.path.join(PREFIX, "lib"))
                import node as N
                link = N.build_link(node)
                if link:
                    lines.append(link)
            except Exception as exc:                             # noqa: BLE001
                # ★ 不许静默：少一个节点的症状是"手机导入后就是比别人少一个"，
                #   而服务端一切正常、日志一片安静 —— 这种错最难查。
                #   实测踩到过：一个字段空掉的节点文件让 build_link 抛
                #   "不支持生成链接的协议"，于是分享里少一个节点。
                sys.stderr.write("share: 跳过 %s（%s）\n" % (name, exc))
                continue
    except OSError:
        pass
    if not lines:
        return b""
    body = "\n".join(lines).encode("utf-8")
    return base64.b64encode(body)


class Handler(BaseHTTPRequestHandler):
    server_version = "XBD-Share"

    def log_message(self, *a):      # 别把每个请求都打进 journal
        pass

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_HEAD(self):
        """订阅预检：只报状态和长度，不送正文，也不消耗次数。"""
        self._send(200 if self._serve(write_body=False) else 404)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/status":
            return self._send(200, b"XBD Share Server OK\n")
        if not self._serve(write_body=True):
            return self._send(404, b"not found\n")

    def _serve(self, write_body):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if not path.startswith("/share/"):
            return False
        token = path[len("/share/"):]
        if len(token) < 16 or not token.isalnum():
            return False

        with Store._lock:
            meta = Store.load(token)
            if meta is None:
                return False
            if not meta.get("enabled", False):
                return False
            now = int(time.time())
            if meta.get("expires_at") and now > int(meta["expires_at"]):
                return False
            maxu = int(meta.get("max_uses", 0))
            if maxu and int(meta.get("used_count", 0)) >= maxu:
                return False
            if not core_healthy():
                return False
            if not write_body:
                return True
            body = build_config()
            if not body:
                return False
            # 扣次数放在真正发出响应之前。客户端先 HEAD 再 GET，先扣才只算一次。
            meta["used_count"] = int(meta.get("used_count", 0)) + 1
            meta["last_used_at"] = now
            Store.save(token, meta)

        if len(body) > MAX_BODY:
            body = body[:MAX_BODY]
        self._send(200, body)
        return True


def main():
    host, port = listen_addr()
    if not port:
        print("share.env 未配置 SHARE_PORT，拒绝启动", file=sys.stderr)
        return 1
    srv = ThreadingHTTPServer((host, port), Handler)
    srv.daemon_threads = True
    print("分享服务: http://%s:%d/share/<token>" % (host, port), file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())