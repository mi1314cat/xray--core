#!/usr/bin/env python3
"""Xray 内核版本检查与更新。

为什么单独一个模块：
    * 之前 `xbd update` 只同步项目文件，从不更新 Xray 二进制；
    * 下载要校验 SHA256（对官方 .dgst），不能只信"下载完成"；
    * 家宽常被限速/阻断 GitHub Release，需要连通性预探测与代理回退。

只操作本项目自己的 $PREFIX/bin/xray，绝不碰 /usr/local/bin/xray。
"""
from __future__ import annotations

import argparse
import base64
import gzip
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

PREFIX = os.environ.get("XBD_PREFIX", "/opt/xray-browser-dialer")
XRAY = os.path.join(PREFIX, "bin", "xray")
BACKUP = os.path.join(PREFIX, "backup")
REPO = "XTLS/Xray-core"
HTTP_PROXY_PORTS = (10808, 7890, 10809, 1080, 1088, 20171, 8080)
KERNEL_DIR = os.environ.get("XBD_KERNEL_DIR", os.path.join(PREFIX, "kernels"))
KERNEL_EXTRA_DIRS = ("/root/xray-kernels", "/root/catmi/xray-kernels")


def sh(args, timeout=60):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 124, "", str(exc)


def installed_version() -> str:
    if not os.path.exists(XRAY):
        return ""
    rc, out, _ = sh([XRAY, "version"])
    if rc != 0:
        return ""
    parts = out.split()
    return parts[1] if len(parts) > 1 else ""


def reachable(host: str, port: int = 443, seconds: int = 6) -> bool:
    try:
        with socket.create_connection((host, port), timeout=seconds):
            return True
    except OSError:
        return False


def _proxy_works(url: str) -> bool:
    if not url:
        return False
    rc, _, _ = sh(["curl", "-fsS", "--max-time", "8", "-x", url,
                   "-o", "/dev/null", "https://www.gstatic.com/generate_204"], timeout=12)
    return rc == 0


def pick_proxy() -> str:
    """返回可用的本机代理 URL；都没有则返回空串（直连）。

    顺序：显式环境变量 XBD_DL_PROXY → 常见端口扫描并**实际验证**
    （只测端口通不够：1080 可能是别的服务，curl 走它会报错）。
    """
    env = (os.environ.get("XBD_DL_PROXY") or os.environ.get("https_proxy")
           or os.environ.get("http_proxy") or "").strip()
    if env:
        if _proxy_works(env):
            return env
        print(f"  ! 指定的代理不可用: {env}", file=sys.stderr)
    for port in HTTP_PROXY_PORTS:
        u = f"http://127.0.0.1:{port}"
        if _proxy_works(u):
            return u
    return ""


def fetch(url: str, proxy: str = "", timeout: int = 120) -> bytes:
    # --connect-timeout / --speed-time：GitHub 有时 TCP 能连上但完全不发数据，
    # 只给 --max-time 会让安装卡满 5 分钟。连接 10s、30s 内低于 1KB/s 就放弃，
    # 交给下一个候选（尤其是镜像/代理）。
    args = ["curl", "-fsSL", "--connect-timeout", "10",
            "--speed-limit", "1024", "--speed-time", "30",
            "--max-time", str(timeout)]
    if proxy:
        args += ["-x", proxy]
    args.append(url)
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout + 20)
        return p.stdout if p.returncode == 0 else b""
    except subprocess.TimeoutExpired:
        return b""


def download_first(cands, tmp: str, timeout: int = 180):
    """并行下载多个候选，谁先完整下完用谁。

    为什么不是串行：实测同一台机器上
        GitHub 官方（经本机代理） 415 KB/s
        gh-proxy.com（直连）      119 KB/s
        ghproxy.net（直连）         9 KB/s
    串行会先在最慢的镜像上耗满 max-time；并行则是"能下的那条先到"。
    返回 (bytes, url, proxy)，全失败返回 (b"", "", "")。
    """
    procs = []
    for i, (url, px) in enumerate(cands):
        out = os.path.join(tmp, f"dl-{i}")
        args = ["curl", "-fsSL", "--connect-timeout", "10",
                "--speed-limit", "1024", "--speed-time", "30",
                "--max-time", str(timeout), "-o", out]
        if px:
            args += ["-x", px]
        args.append(url)
        try:
            p = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        except OSError:
            continue
        procs.append((p, out, url, px))
        print(f"  尝试: {url.split('/')[2]}{'（代理）' if px else ''}", file=sys.stderr)

    deadline = time.time() + timeout
    win = None
    while time.time() < deadline:
        for p, out, url, px in procs:
            if p.poll() is not None:
                try:
                    size = os.path.getsize(out)
                except OSError:
                    size = 0
                if p.returncode == 0 and size > 1000:
                    win = (out, url, px)
                    break
        if win:
            break
        if all(p.poll() is not None for p, _, _, _ in procs):
            break
        time.sleep(0.3)

    for p, _out, _url, _px in procs:
        if p.poll() is None:
            p.kill()
    for p, _out, _url, _px in procs:
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

    if not win:
        return b"", "", ""
    out, url, px = win
    try:
        with open(out, "rb") as f:
            return f.read(), url, px
    except OSError:
        return b"", "", ""


def latest_version(proxy: str = "") -> str:
    """取最新版本号。

    先走 API（有 tag_name 最准）；API 被限流/墙掉时改看
    /releases/latest 的 302 终点（.../releases/tag/vX），这条路不需要 API
    配额 —— 共享出口 IP 上 api.github.com 很容易 403 rate limit，实测踩过。
    """
    raw = fetch(f"https://api.github.com/repos/{REPO}/releases/latest", proxy, 25)
    try:
        return json.loads(raw.decode())["tag_name"]
    except (ValueError, KeyError, UnicodeDecodeError):
        pass

    args = ["curl", "-fsSL", "--max-time", "25", "-o", "/dev/null",
            "-w", "%{url_effective}"]
    if proxy:
        args += ["-x", proxy]
    args.append(f"https://github.com/{REPO}/releases/latest")
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=40)
    except subprocess.TimeoutExpired:
        return ""
    if p.returncode != 0:
        return ""
    tail = p.stdout.strip().rstrip("/").rsplit("/tag/", 1)
    return tail[1] if len(tail) == 2 and tail[1] else ""


def arch_asset() -> str:
    m = os.uname().machine
    return {"aarch64": "arm64-v8a", "arm64": "arm64-v8a",
            "x86_64": "64", "amd64": "64",
            "armv7l": "arm32-v7a", "armv7": "arm32-v7a"}.get(m, "")


def _elf_arch(path: str) -> str:
    try:
        with open(path, "rb") as f:
            head = f.read(20)
        if len(head) < 20 or head[:4] != b"\x7fELF":
            return ""
        e_machine = struct.unpack("<H", head[18:20])[0]
        return {0x3E: "amd64", 0xB7: "arm64"}.get(e_machine, "")
    except OSError:
        return ""


def _want_arch() -> str:
    m = os.uname().machine
    return "amd64" if m in ("x86_64", "amd64") else "arm64"


def _extract_kernel(src: str, work: str) -> str:
    """把 zip / gz / 裸二进制解成可执行文件，返回路径（失败空串）。"""
    low = src.lower()
    out = os.path.join(work, "xray")
    try:
        if low.endswith(".zip"):
            rc, _, _ = sh(["unzip", "-oq", src, "-d", os.path.join(work, "x")], timeout=60)
            if rc != 0:
                return ""
            for root, _dirs, files in os.walk(os.path.join(work, "x")):
                if "xray" in files:
                    return os.path.join(root, "xray")
            return ""
        # 先判 .tar.gz/.tar.xz：否则 .tar.gz 会被下面的 .gz 当裸 gzip 解，
        # 解出来的是 tar 而不是 ELF，探测必然失败。
        if low.endswith(".tar.xz") or low.endswith(".tar.gz"):
            d = os.path.join(work, "t")
            os.makedirs(d, exist_ok=True)
            rc, _, _ = sh(["tar", "-xf", src, "-C", d], timeout=60)
            if rc != 0:
                return ""
            for root, _dirs, files in os.walk(d):
                if "xray" in files:
                    return os.path.join(root, "xray")
            return ""
        if low.endswith(".gz"):
            with gzip.open(src, "rb") as f, open(out, "wb") as o:
                shutil.copyfileobj(f, o)
            return out
        # 裸二进制
        shutil.copy2(src, out)
        return out
    except OSError:
        return ""


def _probe_kernel(path: str) -> str:
    """架构匹配 + 真跑 version，返回版本号；不可用返回空串。"""
    if not os.path.isfile(path):
        return ""
    arch = _elf_arch(path)
    if arch and arch != _want_arch():
        return ""
    os.chmod(path, 0o755)
    rc, out, _ = sh([path, "version"], timeout=10)
    if rc != 0:
        return ""
    parts = out.split()
    return parts[1] if len(parts) > 1 else out.splitlines()[0][:40]


def _local_candidates():
    files = []
    envf = os.environ.get("XBD_KERNEL_FILE", "").strip()
    if envf:
        files.append(envf)
    for d in (KERNEL_DIR,) + KERNEL_EXTRA_DIRS:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".part"):
                continue
            p = os.path.join(d, name)
            if os.path.isfile(p):
                files.append(p)
    return files


def install_local(as_json=False, force=False) -> int:
    """安装用户上传到 kernels/ 的内核（zip/gz/裸二进制）。"""
    cur = installed_version()
    if cur and not force:
        print(json.dumps({"ok": True, "updated": False, "version": cur},
                         ensure_ascii=False) if as_json else f"  ✓ 已是最新版本 {cur}")
        return 0
    cands = _local_candidates()
    if not cands:
        msg = (f"上传目录为空: {KERNEL_DIR}\n"
               f"  把 Xray-linux-*.zip / .gz / 裸二进制放进去后重试\n"
               f"  下载页: https://github.com/XTLS/Xray-core/releases")
        print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
        return 1
    tmp = tempfile.mkdtemp(prefix="xbd-local-")
    try:
        for f in cands:
            base = os.path.basename(f)
            k = _extract_kernel(f, tmp)
            ver = _probe_kernel(k) if k else ""
            if not ver:
                print(f"  ✗ {base}: 不是可用的 Xray 内核（架构/解压/执行失败）", file=sys.stderr)
                continue
            os.makedirs(BACKUP, exist_ok=True)
            if os.path.exists(XRAY):
                shutil.copy2(XRAY, os.path.join(BACKUP, f"xray.{cur or 'unknown'}.bak"))
            os.makedirs(os.path.dirname(XRAY), exist_ok=True)
            shutil.copy2(k, XRAY)
            os.chmod(XRAY, 0o755)
            # 官方 zip 里还带 geoip.dat / geosite.dat，本地安装也要一起复制，
            # 否则分流规则会缺数据（联网路径一直有这一步，别只修一半）。
            for geo in ("geoip.dat", "geosite.dat"):
                gsrc = os.path.join(os.path.dirname(k), geo)
                if os.path.exists(gsrc):
                    shutil.copy2(gsrc, os.path.join(os.path.dirname(XRAY), geo))
            newver = installed_version()
            out = {"ok": True, "updated": True, "from": cur, "to": newver, "source": base}
            print(json.dumps(out, ensure_ascii=False) if as_json else
                  f"  ✓ 已用上传的内核安装: {cur or '无'} → {newver}（{base}）")
            return 0
        msg = f"上传目录里没有可用的内核: {KERNEL_DIR}"
        print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
        return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def cmd_check(as_json=False) -> int:
    cur = installed_version()
    proxy = pick_proxy()
    direct = reachable("api.github.com", 443, 5)
    if not direct and not proxy:
        out = {"installed": cur, "latest": "", "error": "无法访问 GitHub 且本机没有可用代理",
               "updatable": False}
        print(json.dumps(out, ensure_ascii=False) if as_json else
              f"  已安装: {cur or '无'}\n  ! 无法访问 GitHub，也没有可用代理")
        return 1

    latest = latest_version(proxy if not direct else "")
    if as_json:
        print(json.dumps({"installed": cur, "latest": latest,
                          "updatable": bool(latest and latest.lstrip("v") != cur),
                          "proxy": proxy, "direct": direct}, ensure_ascii=False))
        return 0
    print(f"  已安装: {cur or '无'}")
    print(f"  最新版: {latest or '获取失败'}")
    if latest and latest.lstrip("v") != cur:
        print(f"  可更新: {cur or '无'} → {latest.lstrip('v')}")
    elif latest:
        print("  已是最新版本")
    return 0


def cmd_update(as_json=False, force=False) -> int:
    cur = installed_version()
    proxy = pick_proxy()

    # 没有内核时，优先用用户上传到 kernels/ 的包（完全离线）。
    # 只在目录里真有候选文件时才试 —— 否则全新安装会先打一行
    # “上传目录为空”的报错，用户会以为安装失败了。
    if not cur and _local_candidates():
        rc = install_local(as_json, force=True)
        if rc == 0:
            return 0

    # 直连优先；不通再用本机代理（本项目 HTTP 代理优先，其次 mihomo）
    direct = reachable("api.github.com", 443, 5)
    if not direct and not proxy:
        print(json.dumps({"ok": False, "error": "无法访问 GitHub 且无本机代理"},
                         ensure_ascii=False) if as_json else
              "  ✗ 无法访问 GitHub，且本机没有可用代理（先 xbd proxy on）")
        return 1
    if not direct and proxy:
        print(f"  直连不通，改用代理 {proxy}" if not as_json else "", end="" if not as_json else "\n")

    latest = latest_version(proxy if not direct else "")
    if not latest:
        # GitHub API 不通不代表 release 文件不可达：用 /releases/latest/download/
        # 直链 + 镜像继续试，版本号装完由 xray version 读出来。
        print("  ! 取不到最新版本号（GitHub API 不通），改用 latest 直链下载",
              file=sys.stderr)

    target = latest.lstrip("v")
    # latest 拿不到时 target 是空串，不能拿它和 cur 比 —— 空==空 会误判
    # “已是最新版本”，然后一次都不下载（实测踩过）。
    if target and cur == target and not force:
        msg = f"已是最新版本 {cur}"
        print(json.dumps({"ok": True, "updated": False, "version": cur},
                         ensure_ascii=False) if as_json else f"  ✓ {msg}")
        return 0

    asset = arch_asset()
    if not asset:
        msg = f"不支持的架构: {os.uname().machine}"
        print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
        return 1

    if latest:
        pathpart = f"releases/download/{latest}/Xray-linux-{asset}.zip"
    else:
        pathpart = f"releases/latest/download/Xray-linux-{asset}.zip"

    # 并行候选：官方 + 两个镜像的直连，以及（有代理时）官方走代理。
    # 直连不通时把镜像排前面；直连可用时官方排前面，但代理也一起跑，
    # 谁快谁赢（实测同一台机器代理 415KB/s、镜像 9KB/s）。
    github = f"https://github.com/{REPO}/{pathpart}"
    ghproxy = f"https://ghproxy.net/https://github.com/{REPO}/{pathpart}"
    ghprox2 = f"https://gh-proxy.com/https://github.com/{REPO}/{pathpart}"
    base_order = [github, ghprox2, ghproxy] if direct else [ghprox2, ghproxy, github]
    cands = [(u, "") for u in base_order]
    if proxy:
        cands.insert(0, (github, proxy))
    # 去重并限制并发数：4 条已经够覆盖直连/镜像/代理，别把本机带宽打满
    seen = set()
    uniq = []
    for u, px in cands:
        k = (u, px)
        if k in seen:
            continue
        seen.add(k)
        uniq.append((u, px))
    cands = uniq[:4]
    tmp = tempfile.mkdtemp(prefix="xbd-upd-")
    try:
        blob, base, used_proxy = download_first(cands, tmp, 180)
        if not blob:
            msg = "下载失败（直连与镜像都不通）"
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
            return 1

        # 校验：官方 .dgst 里的 SHA2-256（取不到就记未验证）
        # .dgst 跟随**实际成功的通道**，不要无条件绕代理；直连镜像下的
        # .dgst 通常也直连最快，失败再退回代理。
        if base:
            print(f"  下载源: {base.split('/')[2]}{'（代理）' if used_proxy else '（直连）'}",
                  file=sys.stderr)
        dgst_raw = fetch(base + ".dgst", used_proxy, 60)
        if not dgst_raw and proxy and used_proxy != proxy:
            dgst_raw = fetch(base + ".dgst", proxy, 60)
        if not dgst_raw and used_proxy:
            dgst_raw = fetch(base + ".dgst", "", 60)
        dgst = dgst_raw.decode("utf-8", "replace")
        want = ""
        for line in dgst.splitlines():
            if "SHA2-256" in line:
                want = line.split("=", 1)[1].strip()
                break

        zip_path = os.path.join(tmp, "xray.zip")
        open(zip_path, "wb").write(blob)

        got = ""
        rc, out, _ = sh(["sha256sum", zip_path])
        if rc == 0:
            got = out.split()[0]

        if want:
            if want != got:
                msg = f"SHA256 不匹配（期望 {want[:16]}… 实际 {got[:16]}…）"
                print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
                return 1
            verified = True
        else:
            verified = False

        rc, out, err = sh(["unzip", "-oq", zip_path, "-d", os.path.join(tmp, "x")])
        if rc != 0:
            msg = f"解压失败: {err[:120]}"
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
            return 1

        newbin = os.path.join(tmp, "x", "xray")
        if not os.path.exists(newbin):
            msg = "压缩包里没有 xray"
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False) if as_json else f"  ✗ {msg}")
            return 1

        os.makedirs(BACKUP, exist_ok=True)
        if os.path.exists(XRAY):
            shutil.copy2(XRAY, os.path.join(BACKUP, f"xray.{cur or 'unknown'}.bak"))

        os.makedirs(os.path.dirname(XRAY), exist_ok=True)
        shutil.copy2(newbin, XRAY)
        os.chmod(XRAY, 0o755)
        for geo in ("geoip.dat", "geosite.dat"):
            src = os.path.join(tmp, "x", geo)
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(os.path.dirname(XRAY), geo))

        newver = installed_version()
        out = {"ok": True, "updated": True, "from": cur, "to": newver,
               "sha256_verified": verified}
        if as_json:
            print(json.dumps(out, ensure_ascii=False))
        else:
            print(f"  ✓ 已更新: {cur or '无'} → {newver}"
                  + ("" if verified else "（未取得官方 .dgst，仅记录本地校验值）"))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "update", "version", "install-local"])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    if a.cmd == "version":
        print(installed_version())
        return 0
    if a.cmd == "check":
        return cmd_check(a.json)
    if a.cmd == "install-local":
        return install_local(a.json, a.force)
    return cmd_update(a.json, a.force)


if __name__ == "__main__":
    sys.exit(main())
