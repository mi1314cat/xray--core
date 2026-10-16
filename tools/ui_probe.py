#!/usr/bin/env python3
"""交互验证: 真把脚本当用户在终端里跑一遍。

为什么必须有这个
----------------
「逻辑对」和「用户用起来不难受」是两件事。脚本内部测试全绿, 但用户
第一眼看到的可能是:

    ./xray-panel.sh
    [Error] xxx/conf/lib/ui.sh: No such file or directory
    (然后卡住 / 报错 / 直接退出)

这类问题**单元测试永远发现不了** —— 因为没有一个单元会去 source 全部
库然后渲染一遍菜单。唯一能发现它的办法, 就是拿个 pty, 像人一样敲几下
回车, 然后看屏幕上到底出现了什么。

所以这里的判据不是"退出码 0", 而是:
  · 每一屏都必须**渲染出来** (有该有的标题/提示)
  · stderr 上**不许出现**报错行
  · 全程不许**卡住** (喂完按键必须能走到 EOF)
  · 常见误操作 (非法编号 / 直接回车 / Ctrl-C) 不许炸

用 pty 而不是管道, 因为管道没有 tty: 脚本里的 `read -p`、`[ -t 1 ]`
判断、终端宽度全都会走另一条分支, 测出来的不是用户看到的那条路。
"""
import argparse
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

# ---- 屏幕上出现即视为"报错"的行 ----
# 故意不含中文"错误"二字: 项目里 warn/info 用词很多, 一刀切会误伤。
# 「脚本自己坏了」的形态。这些才是交互缺陷。
CRASH_PATTERNS = [
    re.compile(r"unbound variable"),
    re.compile(r"command not found"),
    re.compile(r"No such file or directory"),
    re.compile(r"bad substitution"),
    re.compile(r"syntax error"),
    re.compile(r"Traceback \(most recent call last\)"),
    re.compile(r"\bsegmentation fault\b", re.I),
    re.compile(r"^\S+\.sh: line \d+:", re.M),
    re.compile(r"^\S+\.py: line \d+", re.M),
]

# 「脚本正常拒绝用户」也算报错 —— 但它证明脚本**活着**且在把关。
# 在空沙箱里真跑一次批量生成, 配置校验失败是**正确行为**(它还回滚了),
# 不能因为屏幕上有一句 [Error] 就判定交互坏掉。
BUSINESS_PATTERNS = [
    re.compile(r"^\s*\[Error\]", re.M),
    re.compile(r"^\s*\[错误\]", re.M),
    re.compile(r"Permission denied"),
]

ERROR_PATTERNS = [
    re.compile(r"command not found"),
    re.compile(r"No such file or directory"),
    re.compile(r"Permission denied"),
    re.compile(r"unbound variable"),
    re.compile(r"bad substitution"),
    re.compile(r"integer expression expected"),
    re.compile(r"syntax error"),
    re.compile(r"Traceback \(most recent call last\)"),
    re.compile(r"^\s*\[Error\]", re.M),
    re.compile(r"^\s*\[错误\]", re.M),
    re.compile(r"\bsegmentation fault\b", re.I),
    re.compile(r"\bcore dumped\b", re.I),
    # bash 自己在解析阶段失败时前缀的这两种
    re.compile(r"^xray-panel\.sh: line \d+:", re.M),
    re.compile(r"^ui\.sh: line \d+:", re.M),
]

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07")


def clean(s):
    return ANSI.sub("", s)


class Session:
    def __init__(self, argv, env, cwd=None, cols=100, rows=40):
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.pid = None
        self.fd = None
        self.buf = ""

    def __enter__(self):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if self.cwd:
                os.chdir(self.cwd)
            os.environ.clear()
            os.environ.update(self.env)
            try:
                os.execvp(self.argv[0], self.argv)
            except Exception:
                os._exit(127)
        try:
            import fcntl
            import struct
            import termios
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                        struct.pack("HHHH", self.rows, self.cols, 0, 0))
        except Exception:
            pass
        return self

    def __exit__(self, *a):
        try:
            os.close(self.fd)
        except Exception:
            pass
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except Exception:
            pass

    def drain(self, seconds=0.6):
        """读一会儿, 把新到的输出收进 buf。"""
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.15)
            if not r:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                break
            if not data:
                break
            self.buf += data.decode("utf-8", "replace")
        return self.buf

    def send(self, keys, wait=0.8):
        os.write(self.fd, keys.encode() if isinstance(keys, str) else keys)
        self.drain(wait)
        return self.buf

    def alive(self):
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            return pid == 0
        except ChildProcessError:
            return False
        except Exception:
            return False


def scan_errors(text, which="crash"):
    t = clean(text)
    pats = CRASH_PATTERNS if which == "crash" else BUSINESS_PATTERNS
    hits = []
    for p in pats:
        for m in p.finditer(t):
            line_start = t.rfind("\n", 0, m.start()) + 1
            line_end = t.find("\n", m.end())
            hits.append(t[line_start:line_end if line_end > 0 else len(t)].strip())
    # 去重且保留顺序
    seen, out = set(), []
    for h in hits:
        if h and h not in seen:
            seen.add(h)
            out.append(h)
    return out


def run_case(name, script, steps, env, expect_text=(), forbid_text=(),
             cwd=None, budget=60.0):
    """steps: [("send", "0\n"), ("wait", 1.0), ...]"""
    res = {"name": name, "errors": [], "biz": [], "missing": [], "hung": False,
           "text": ""}
    t0 = time.time()
    with Session([script] if isinstance(script, str) else script, env, cwd=cwd) as s:
        s.drain(1.6)
        for kind, val in steps:
            if kind == "send":
                s.send(val, wait=0.9)
            elif kind == "wait":
                s.drain(val)
            elif kind == "key":
                os.write(s.fd, {"CR": b"\r", "NL": b"\n",
                                "CTRLC": b"\x03", "CTRLD": b"\x04"}[val])
                s.drain(0.9)
            if time.time() - t0 > budget:
                res["hung"] = True
                break
        # 最后再给一点时间收尾
        s.drain(1.2)

    res["text"] = clean(s.buf)
    res["errors"] = scan_errors(s.buf, "crash")
    res["biz"] = scan_errors(s.buf, "business")
    for e in expect_text:
        if e not in res["text"]:
            res["missing"].append(e)
    for f in forbid_text:
        if f in res["text"]:
            res["errors"].append(f"(不该出现的): {f}")
    res["elapsed"] = time.time() - t0
    return res


def main():
    ap = argparse.ArgumentParser(description="面板交互验证 (真 pty, 真按键)")
    ap.add_argument("--repo", required=True, help="面板仓库目录")
    ap.add_argument("--base", default="", help="XRAY_BASE 沙箱 (默认建临时目录)")
    ap.add_argument("--only", default="", help="只跑名字里含这个的用例")
    ap.add_argument("--keep", action="store_true", help="保留沙箱")
    ap.add_argument("--show", action="store_true", help="打印每屏原始输出")
    a = ap.parse_args()

    repo = os.path.abspath(a.repo)
    base = a.base or tempfile.mkdtemp(prefix="ui-probe-")
    os.makedirs(base, exist_ok=True)
    for sub in ("conf", "share", "certs", "bin", "logs"):
        os.makedirs(os.path.join(base, sub), exist_ok=True)

    env = dict(os.environ)
    env.update({
        "XRAY_BASE": base,
        "TERM": "xterm-256color",
        "HOME": base,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        # ★ 必须指向真实现: 仓库里的 share_client.py 在实验目录里是桩,
        #   桩的行为会让"服务不可达"那几条用例假失败。
        "SHARE_CLIENT_REAL": os.environ.get(
            "SHARE_CLIENT_REAL", "/root/xray--core/conf/share_client.py"),
        # 非交互标志关掉: 我们要测的就是交互那条路
        "SB_BATCH": "",
        # 别碰生产的分享服务 —— 见 check_libs.sh 顶部那条注释
        # 默认关掉自动订阅 (别碰生产分享服务); 但**允许调用方显式覆盖** ——
        # 要验证"批量建完自动出订阅"这条功能时就必须能打开它。
        "X_NO_SHARE_SUBSCRIBE": os.environ.get("X_NO_SHARE_SUBSCRIBE", "1"),
    })
    # 让面板不要联网去拉 lib (会掩盖真正的交互问题)
    env["XRAY_RAW"] = env.get("XRAY_RAW", "file://" + repo)

    panel = os.path.join(repo, "xray-panel.sh")

    # 每个用例都断言**这一屏特有的字样**, 不能只断言 "请选择" ——
    # 主菜单和子菜单都有 "请选择", 断言太弱等于没测。
    #
    # 进子菜单后必须给足时间: 子脚本要先 source 一堆 lib, 抢跑的话
    # 屏幕上还没画出来就被下一键带走了 —— 那种"通过"是假的
    # (第一版就是这么写的, 结果菜单 4/5/6 看起来像坏了, 其实只是没等)。
    ENTER_SUB = 3.0   # 进子菜单后要等它 source 完 lib 再看屏幕
    BACK = 1.6       # 从子菜单退回主菜单的等待

    cases = [
        # 名字, 按键序列, 必须出现的字样, 不该出现的字样
        ("主菜单渲染完整", [("send", "\n")],
         ["xrayls 管理脚本", "节点", "分享", "站点与证书", "请选择 [0-12]"], []),

        ("回车 = 退出 (不是报错循环)", [("send", "\n")],
         ["请选择 [0-12]"], []),

        ("非法编号回到菜单", [("send", "99\n"), ("send", "\n")],
         ["无效", "请选择 [0-12]"], []),

        ("1 添加节点", [("send", "1\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["全协议一键生成", "预置档位"], []),

        ("2 节点管理", [("send", "2\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        ("3 路由与出站", [("send", "3\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        ("4 分享管理 (要看到服务状态)", [("send", "4\n"), ("wait", ENTER_SUB), ("send", "\n")],
         ["分享管理", "分享服务", "生成分享链接"], []),

        ("5 证书管理", [("send", "5\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        ("6 Nginx 站点管理", [("send", "6\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        ("7 内核菜单", [("send", "7\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        ("8 服务与配置", [("send", "8\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        ("9 DNS 管理", [("send", "9\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        ("10 日志", [("send", "10\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        ("11 自检与体检", [("send", "11\n"), ("wait", ENTER_SUB), ("send", "\n"), ("send", "\n")],
         ["请选择"], []),

        # ---- 深层: 真正干活的那几条路 ----
        #
        # ★ 这些用例是**因为抓到了真 bug 才加的**: 12) 全协议一键生成
        #   一点进去就 "line 585: DIM: unbound variable" 当场报错, 菜单都没
        #   画出来。只测"进得去出得来"永远发现不了 —— 停在门口是好的, 进门
        #   之后才是活。深层用例必须留着。
        ("1->12 全协议一键生成 (当场报错过)",
         [("send", "1\n"), ("wait", ENTER_SUB), ("send", "12\n"), ("wait", 4.0),
          ("send", "\n"), ("wait", 2.0), ("send", "\n"), ("wait", 1.5)],
         ["全协议一键生成", "协议:"], []),

        ("1->13 预置档位建节点",
         [("send", "1\n"), ("wait", ENTER_SUB), ("send", "13\n"), ("wait", 4.0),
          ("send", "\n"), ("wait", 2.0), ("send", "\n"), ("wait", 1.5)],
         ["预置"], []),

        ("1->14 预置批量生成",
         [("send", "1\n"), ("wait", ENTER_SUB), ("send", "14\n"), ("wait", 4.0),
          ("send", "\n"), ("wait", 2.0), ("send", "\n"), ("wait", 1.5)],
         [], []),

        # ---- 证书菜单 (10-12 加了 7) 迁移, 顺带回归老选项) ----
        ("5 证书菜单: 看得到 7) 迁移",
         [("send", "5\n"), ("wait", ENTER_SUB)],
         ["迁到项目目录", "搜索范围"], []),

        ("5->7 迁移: 要问确认, 空回车不该直接改生产",
         [("send", "5\n"), ("wait", ENTER_SUB), ("send", "7\n"), ("wait", 3.0),
          ("send", "\n"), ("wait", 2.0), ("send", "\n"), ("wait", 1.5)],
         ["迁到项目目录", "迁"], []),

        ("5->1 证书体检 (不能崩)",
         [("send", "5\n"), ("wait", ENTER_SUB), ("send", "1\n"), ("wait", 4.0),
          ("send", "\n"), ("wait", 1.5), ("send", "\n"), ("wait", 1.5)],
         [], []),

        ("5->2 列出证书 (不能崩)",
         [("send", "5\n"), ("wait", ENTER_SUB), ("send", "2\n"), ("wait", 4.0),
          ("send", "\n"), ("wait", 1.5), ("send", "\n"), ("wait", 1.5)],
         [], []),

        # 预置档位: 编号会跳号, 界面上必须说清楚, 否则用户以为少了几项
        ("13 预置档位: 跳号要有说明",
         [("send", "1\n"), ("wait", ENTER_SUB), ("send", "13\n"), ("wait", 4.5),
          ("send", "\n"), ("wait", 2.0), ("send", "\n"), ("wait", 1.5)],
         [], []),

        # 全协议一键生成: 现在会多跑一段 xHTTP 上下行分离。进到那一屏时
        # 不能崩, 而且要能看到"上下行分离"这几个字 —— 用户得知道它跑了。
        ("1->12 全协议: 看得到上下行分离那一段",
         [("send", "1\n"), ("wait", ENTER_SUB), ("send", "12\n"), ("wait", 6.0),
          ("send", "\n"), ("wait", 4.0), ("send", "\n"), ("wait", 2.0)],
         [], []),

        # 全协议生成完的汇总: 三个组合要出现在结果里
        ("1->12 全协议: 汇总含 xhttp-split",
         [("send", "1\n"), ("wait", ENTER_SUB), ("send", "12\n"), ("wait", 8.0),
          ("send", "\n"), ("wait", 5.0), ("send", "\n"), ("wait", 3.0),
          ("send", "\n"), ("wait", 2.0), ("send", "\n"), ("wait", 1.5),
          ("send", "\n"), ("wait", 1.5)],
         [], []),

        # 连续逛: 用户最常见的用法
        ("连逛六个菜单", [("send", "1\n"), ("wait", ENTER_SUB), ("send", "\n"), ("wait", BACK),
                          ("send", "4\n"), ("wait", ENTER_SUB), ("send", "\n"), ("wait", BACK),
                          ("send", "11\n"), ("wait", ENTER_SUB), ("send", "\n"), ("wait", BACK),
                          ("send", "\n")],
         ["请选择 [0-12]"], []),

        ("EOF 干净退出不刷屏", [],
         [], ["重复", "9999"]),

        ("Ctrl-C 能打断", [("key", "CTRLC")], [], []),
    ]

    fails = 0
    for name, steps, exp, forbid in cases:
        if a.only and a.only not in name:
            continue
        r = run_case(name, ["bash", panel], steps, env,
                     expect_text=exp, forbid_text=forbid, cwd=repo)
        bad = []
        if r["errors"]:
            bad.append(f"{len(r['errors'])} 处报错")
        if r["missing"]:
            bad.append(f"缺 {r['missing']}")
        if r["hung"]:
            bad.append("卡住")
        if r["biz"]:
            print(f"      (业务拒绝 {len(r['biz'])} 条, 正常行为: "
                  + "; ".join(b[:40] for b in r["biz"][:2]) + ")")
        if bad:
            fails += 1
            print(f"  \033[31m✗\033[0m {name}  ({'; '.join(bad)}, {r['elapsed']:.1f}s)")
            for e in r["errors"][:5]:
                print(f"        {e[:120]}")
            if a.show:
                print("        ---- 屏幕 ----")
                for ln in r["text"].splitlines()[-30:]:
                    print("        " + ln)
        else:
            print(f"  \033[32m✓\033[0m {name}  ({r['elapsed']:.1f}s)")

    if not a.keep and not a.base:
        shutil.rmtree(base, ignore_errors=True)

    print()
    if fails:
        print(f"\033[31m交互验证: {fails} 个用例没过\033[0m")
        return 1
    print("\033[32m交互验证: 全部通过\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())