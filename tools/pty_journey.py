#!/usr/bin/env python3
"""pty_journey.py —— 像用户一样把面板**走完**，并把整屏记录交出来。

为什么不是 ui_probe.py
----------------------
ui_probe.py 是**断言式**的: 每个用例只走到"这一屏画出来了、没崩", 然后
断言几个字样。它擅长抓"一进去就报错", 但抓不到:

    · 一个向导要问 9 个问题, 第 7 个问题的默认值其实是错的
    · 菜单说"回车=默认", 但回车之后走的是另一个分支
    · 跳号 / 提示与实际写入不一致
    · 一屏里出现两遍同样的提示 (双重提问)

这些都是**读屏**才能发现的问题, 不是断言能写的 —— 因为写断言的人得先
知道正确长什么样。所以这个工具不做判断, 只负责**忠实回放**:
把每一次按键之后的整屏原样 dump 出来, 让人(或 AI)以用户的视角读一遍。

设计要点
--------
· 用 pty 而不是管道 —— 管道没有 tty, `read -p` / `[ -t 1 ]` / 终端宽度
  全走另一条分支, 测出来的不是用户看到的那条路。
· 按键之间按**输出静止**判时机 (而不是固定 sleep): 真人就是等屏幕不动了
  才敲下一个键; 固定 sleep 要么抢跑(把还没画出来的屏带走), 要么白等。
· 每个按键单独切一屏, 并在屏首标注 `[按键 N: 'x']`, 读的时候能对上。

用法
----
    python3 tools/pty_journey.py --repo <仓库> --keys "1 13 1" [--base <沙箱>]
    python3 tools/pty_journey.py --repo . --keys "5" --screen 30

按键写法
--------
  "1"        普通按键 (自动补回车)
  "\\n"       只敲回车 (空输入)
  ":raw:y"   只发字符, 不补回车 (给 y/N 这类单字符确认用)
  ":wait:5"  不给按键, 只等 5 秒 (看长任务的进度输出)
"""
import argparse
import os
import pty
import re
import select
import signal
import struct
import fcntl
import sys
import termios
import time

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][AB0]")


def clean(s):
    return ANSI.sub("", s)


class Term:
    def __init__(self, argv, env, cwd, cols=110, rows=44):
        self.argv, self.env, self.cwd = argv, env, cwd
        self.cols, self.rows = cols, rows
        self.buf = ""

    def __enter__(self):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(self.cwd)
                os.environ.clear()
                os.environ.update(self.env)
                os.execvp(self.argv[0], self.argv)
            except Exception:
                os._exit(127)
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                        struct.pack("HHHH", self.rows, self.cols, 0, 0))
        except Exception:
            pass
        return self

    def __exit__(self, *a):
        for fn in (lambda: os.close(self.fd),
                   lambda: os.kill(self.pid, signal.SIGKILL),
                   lambda: os.waitpid(self.pid, 0)):
            try:
                fn()
            except Exception:
                pass

    def drain(self, quiet=1.0, hard=25.0):
        """读到**输出静止** quiet 秒为止; hard 秒是上限, 防止真卡住时不返回。"""
        last = time.time()
        start = last
        while True:
            r, _, _ = select.select([self.fd], [], [], 0.15)
            if r:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                self.buf += data.decode("utf-8", "replace")
                last = time.time()
            elif time.time() - last >= quiet:
                break
            if time.time() - start > hard:
                break

    def send(self, text):
        os.write(self.fd, text.encode())


def split_keys(keys):
    """把 "1 13 :raw:y :wait:5" 拆成 [(kind, val), ...]"""
    out = []
    for tok in keys.split():
        if tok.startswith(":wait:"):
            out.append(("wait", float(tok[6:])))
        elif tok.startswith(":raw:"):
            out.append(("raw", tok[5:]))
        elif tok == "\\n" or tok == "ENTER":
            out.append(("nl", "\n"))
        else:
            out.append(("line", tok + "\n"))
    return out


def main():
    ap = argparse.ArgumentParser(description="把面板当用户走一遍, 回放整屏")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--base", default="", help="XRAY_BASE 沙箱 (默认临时目录)")
    ap.add_argument("--keys", required=True, help='如 "1 13 1 2 1"')
    ap.add_argument("--quiet", type=float, default=1.0, help="输出静止多少秒算一屏结束")
    ap.add_argument("--screen", type=int, default=0, help="每屏只显示最后 N 行 (0=全部)")
    ap.add_argument("--budget", type=float, default=180.0, help="整场总时长上限")
    ap.add_argument("--script", default="xray-panel.sh", help="入口脚本 (相对仓库)")
    # 有的入口脚本靠**参数**决定走哪条路 (install.sh server / client / ...),
    # 不支持参数就只能测到主菜单那条路, 而用户日常敲的恰恰是带参数那条。
    ap.add_argument("--args", default="", help='传给入口脚本的参数, 如 "server"')
    ap.add_argument("--keep", action="store_true", help="保留沙箱")
    a = ap.parse_args()

    repo = os.path.abspath(a.repo)
    base = a.base or os.path.join("/tmp", "journey-%d" % int(time.time()))
    for sub in ("conf", "out", "out/share", "certs", "log", "share-state"):
        os.makedirs(os.path.join(base, sub), exist_ok=True)

    env = dict(os.environ)
    env.update({
        "XRAY_BASE": base,
        "XRAY_CONF_DIR": os.path.join(base, "conf"),
        "XRAY_SHARE_DIR": os.path.join(base, "out", "share"),
        "OUT_DIR": os.path.join(base, "out"),
        "TERM": "xterm-256color",
        "HOME": base,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        # 别联网拉 lib: 那会把真正的交互问题掩掉, 而且慢
        "XRAY_RAW": env.get("XRAY_RAW", "file://" + repo),
        # 别碰生产的分享服务 —— 见 check_libs.sh 顶部那条注释
        # 默认关掉自动订阅 (别碰生产分享服务); 但**允许调用方显式覆盖** ——
        # 要验证"批量建完自动出订阅"这条功能时就必须能打开它。
        "X_NO_SHARE_SUBSCRIBE": os.environ.get("X_NO_SHARE_SUBSCRIBE", "1"),
    })

    argv = ["bash", os.path.join(repo, a.script)]
    if a.args:
        argv += a.args.split()
    keys = split_keys(a.keys)
    steps = [("wait", 2.5)] + keys

    t0 = time.time()
    with Term(argv, env, repo) as t:
        prev = 0
        n = 0
        for kind, val in steps:
            if time.time() - t0 > a.budget:
                print("!! 超出总时长上限, 提前结束", file=sys.stderr)
                break
            if kind == "wait":
                t.drain(quiet=a.quiet, hard=val + 2)
            else:
                t.send(val)
                t.drain(quiet=a.quiet)
            n += 1
            chunk = clean(t.buf[prev:])
            prev = len(t.buf)
            if kind == "wait":
                label = "[等待 %.0fs]" % val
            elif kind == "nl":
                label = "[按键 %d: 回车]" % n
            elif kind == "raw":
                label = "[按键 %d: 裸字符 %r]" % (n, val)
            else:
                label = "[按键 %d: %r]" % (n, val.strip())
            print("\n" + "=" * 78)
            print("=== %s" % label)
            print("=" * 78)
            body = chunk.rstrip("\n")
            if a.screen and body.count("\n") > a.screen:
                lines = body.splitlines()
                print("  …(前 %d 行省略)…" % (len(lines) - a.screen))
                body = "\n".join(lines[-a.screen:])
            print(body if body.strip() else "  (无输出)")
        # 收尾
        try:
            t.send("\n")
            t.drain(quiet=a.quiet, hard=3)
        except Exception:
            pass

    print("\n" + "-" * 78)
    print("沙箱: %s" % base)
    tree = []
    for root, _dirs, files in os.walk(base):
        for f in files:
            p = os.path.join(root, f)
            tree.append(os.path.relpath(p, base))
    print("沙箱产物 (%d 个):" % len(tree))
    for x in sorted(tree)[:40]:
        print("  " + x)
    return 0


if __name__ == "__main__":
    sys.exit(main())
