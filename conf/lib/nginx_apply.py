#!/usr/bin/env python3
"""nginx 站点配置管理 —— 带标记的幂等插入 / 移除 / 回滚。

与 mihomo 的 nginx_apply.py 同一套应用逻辑, 只是插入的内容换成 Xray 的
upstream / location 参数。

## 为什么必须是"带标记的幂等"

nginx 的站点文件是手写的、有注释、有各种排版习惯。直接往里追加一段
location, 第二次执行就会追加第二份 —— 配置不报错(两个 server 名字相同
时后者覆盖前者), 但用户已经无从判断当前生效的是哪一段。

所以插入的内容一律加 BEGIN/END 标记, 每次动手之前先摘掉上一轮插入的
整段, 再插新的。同一个域名反复配置 N 次, 结果和配置 1 次完全一样。

## 写入路径

    备份 → 原子替换 → nginx -t → 不通过立刻回滚

nginx -t 是唯一的权威检查。写入成功但语法错了, 站点直接起不来, 所以
校验必须在提交后立刻做, 而且失败要能恢复原文件。
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

MARK = "xray-core"

RE_BEGIN = re.compile(r"#\s*===\s*" + re.escape(MARK) + r"\s+(BEGIN|END)\s+(\S+?)"
                      r"\s*(?:\(server 指令\))?\s*===\s*$")
RE_LOC = re.compile(r"#\s*(>>>|<<<)\s+" + re.escape(MARK) + r"\s+(BEGIN|END)\s+(\S+?)\s*(?:>>>|<<<)\s*$")


# ---------------------------------------------------------------- 基础探测
def probe_docker():
    """nginx 跑在容器里吗。

    mihomo 的生产环境就是这样。直接在宿主机上跑 nginx -t 会报找不到
    配置, 而配置其实好好地在那儿 —— 于是"校验失败"触发回滚, 改动丢失,
    而真正的原因只是命令敲错了地方。
    """
    if not shutil.which("docker"):
        return None
    try:
        r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                           capture_output=True, timeout=8, text=True)
        if r.returncode != 0:
            return None
        for name in r.stdout.split():
            if name in ("nginx", "nginx-proxy"):
                return name
    except Exception:  # noqa: BLE001
        return None
    return None


def nginx_cmd(docker=None):
    """返回能真正执行 nginx 命令的 argv 前缀。"""
    if docker:
        return ["docker", "exec", docker, "nginx"]
    return ["nginx"]


def config_roots(docker=None):
    """可能存在站点配置的目录。

    NGINX_CONF_ROOTS 可以覆盖 (冒号分隔), 用途有两个: 测试时指向临时目录,
    以及非标准安装路径 —— openresty 装在 /usr/local/openresty/nginx 时那几
    个默认值一个都不存在, 站点文件自然一张都找不到。
    """
    env = os.environ.get("NGINX_CONF_ROOTS")
    if env:
        cands = [d for d in env.split(":") if d]
    else:
        cands = ["/etc/nginx/conf.d", "/etc/nginx/sites-enabled",
                 "/usr/local/nginx/conf", "/usr/local/openresty/nginx/conf",
                 "/etc/nginx"]
    return [c for c in cands if os.path.isdir(c)]


# ---------------------------------------------------------------- 容器内的文件
#
# 为什么需要这一层
# ----------------
# nginx 跑在容器里时, 宿主机的 /etc/nginx/conf.d 和容器里的 /etc/nginx/conf.d
# 是两个互不相干的目录。之前 config_roots(docker) 收了 docker 参数却从没用过,
# 于是所有查找与写入都落在宿主机上 —— 而容器里的 nginx 从不读那些文件。
#
# 后果不是报错, 是"成功"地改了一个 nginx 永远不会加载的文件: 用户插入完看到
# "已写入", reload 也成功, 但站点毫无变化, 排查起来毫无线索。
#
# 所以读写都要落到真正跑 nginx 的那一侧。

_CONF_DIRS_CONTAINER = ["/etc/nginx/conf.d", "/etc/nginx/sites-enabled",
                        "/usr/local/nginx/conf", "/usr/local/openresty/nginx/conf"]


def _dexec(docker, argv, stdin=None):
    """在容器里跑一条命令, 返回 (rc, stdout_bytes)。"""
    cmd = ["docker", "exec"]
    if stdin is not None:
        cmd.append("-i")
    cmd += [docker] + argv
    r = subprocess.run(cmd, input=stdin, capture_output=True)
    return r.returncode, r.stdout


def c_file_exists(path, docker=None):
    if not docker:
        return os.path.exists(path)
    rc, _ = _dexec(docker, ["sh", "-c", 'test -f "$1"', "sh", path])
    return rc == 0


def c_read(path, docker=None):
    """读一个文件的内容 (bytes)。"""
    if not docker:
        with open(path, "rb") as f:
            return f.read()
    rc, out = _dexec(docker, ["cat", path])
    if rc != 0:
        raise OSError(f"读取容器内 {path} 失败 (rc={rc})")
    return out


def c_write(path, data, docker=None):
    """原子地写一个文件。容器里没有 bind 挂载时走 stdin 管道。"""
    if not docker:
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        return
    # 容器侧没有宿主的原子 replace 可用, 退化成先写临时文件再 mv。mv 在容器
    # 同一文件系统内是原子的, 所以中途断电不会留下半个配置文件。
    rc, _ = _dexec(docker, ["sh", "-c", 'cat > "$1.tmp" && mv "$1.tmp" "$1"',
                            "sh", path], stdin=data)
    if rc != 0:
        raise OSError(f"写入容器内 {path} 失败 (rc={rc})")


def c_copy(src, dst, docker=None):
    if not docker:
        shutil.copy2(src, dst)
        return
    rc, _ = _dexec(docker, ["cp", src, dst])
    if rc != 0:
        raise OSError(f"容器内备份失败: {src} -> {dst} (rc={rc})")


def container_site_files(docker):
    """容器里实际存在的站点配置文件。"""
    seen = {}
    roots = []
    # 末尾显式 exit 0: for 循环最后一次 [ -d ] 对不存在的目录返回 1, 整条命令
    # 的退出码就会是 1 —— 输出明明是对的, 却因为退出码被当成失败。这里判的是
    # 输出, 不是退出码。
    rc, out = _dexec(docker, ["sh", "-c",
                              'for d in %s; do [ -d "$d" ] && echo "$d"; done; exit 0'
                              % " ".join(_CONF_DIRS_CONTAINER)])
    if rc == 0:
        roots = [d for d in out.decode().split() if d]
    if not roots:
        return []
    pat = " ".join(f'"{d}"' for d in roots)
    # find 在部分路径不存在时返回非 0 但仍会输出已找到的部分, 所以同样只看输出。
    rc, out = _dexec(docker, ["sh", "-c",
                              f'find {pat} -name "*.conf" -type f 2>/dev/null; exit 0'])
    for line in out.decode(errors="replace").split("\n"):
        line = line.strip()
        if line:
            seen.setdefault(line, line)
    return sorted(seen.values())


def site_files(docker=None):
    """站点配置文件, 去重且跟随符号链接。

    必须去重的两个原因:

    1. config_roots 里既有 /etc/nginx/sites-enabled 也有 /etc/nginx, 而
       os.walk 是递归的 —— /etc/nginx 那一遍会把 conf.d、sites-available、
       sites-enabled 整个再走一遍, 同一个站点文件被列出两三次。实测过
       torrent-tool.conf 在列出的站点里出现两次。

    2. sites-enabled 里的文件通常是指向 sites-available 的符号链接, 按路径
       去重不够, 要按 realpath 去重。

    不去重的后果不只是难看: find_site 按顺序取第一个命中, 用户看到的站点
    列表和实际改的文件对不上, 而"我明明有 5 个站点"会数出 8 个。
    """
    if docker:
        return container_site_files(docker)
    seen = {}
    for root in config_roots(docker):
        for dirpath, _dirs, files in os.walk(root):
            for f in files:
                if not f.endswith(".conf"):
                    continue
                p = os.path.join(dirpath, f)
                try:
                    key = os.path.realpath(p)
                except OSError:
                    key = p
                # 保留首次出现的路径 (通常来自更具体的根, 而不是 /etc/nginx)
                seen.setdefault(key, p)
    return sorted(seen.values())


def server_name_of(path, docker=None):
    try:
        raw = c_read(path, docker).decode("utf-8", errors="replace")
    except OSError:
        return None
    m = re.search(r"^\s*server_name\s+([^;]+);", raw, re.M)
    return m.group(1).strip() if m else None


def list_sites(docker=None):
    out = []
    for f in site_files(docker):
        sn = server_name_of(f, docker)
        if sn:
            out.append((f, sn))
    return out


def find_site(domain, docker=None):
    for path, sn in list_sites(docker):
        names = sn.split()
        if domain in names or "*" in names:
            return path
    return None


def find_server_block(lines):
    """返回 server{} 块的 (起, 止) 行号, 含花括号本身。

    只认顶层 server 块 —— 缩进只是给人看的, 真正的判据是花括号深度。

    起始行自身的花括号必须计入初始深度: 漏掉的话, 循环进入后的第一行
    就因为 depth 仍为 0 而被判定成块的结束, 于是"块"只剩 server{ 这一行,
    插入点落在 listen/server_name 之前 —— 语法上仍然合法, 但生成结果
    一眼就能看出不对。
    """
    start = None
    depth = 0
    for i, ln in enumerate(lines):
        if start is None:
            if re.match(r"^\s*server\s*\{", ln):
                start = i
                depth = ln.count("{") - ln.count("}")
            continue
        depth += ln.count("{") - ln.count("}")
        if depth <= 0:
            return start, i
    return None


# ---------------------------------------------------------------- 文本工具
def newline_style(raw):
    return "\r\n" if b"\r\n" in raw[:4000] else "\n"


def strip_comment(lines):
    return [ln for ln in lines if not ln.strip().startswith("#")]


def find_marked_span(lines, domain):
    """找 location 级标记段的 (起, 止)。

    跨行匹配: BEGIN 在上一行、END 在若干行之后, 中间不能出现第二个
    BEGIN —— 出现说明是两份交错了, 那已经是被改坏的状态, 取到第一个
    END 就停, 别把别人的段一起吞掉。
    """
    start = None
    for i, ln in enumerate(lines):
        m = RE_LOC.search(ln)
        if not m:
            continue
        kind, tag = m.group(2), m.group(3)
        if tag != domain:
            continue
        if kind == "BEGIN":
            start = i
        elif kind == "END" and start is not None:
            return start, i
    return None


def find_marked_dirs(lines, domain):
    """找 server 级指令标记段。"""
    start = None
    for i, ln in enumerate(lines):
        m = RE_BEGIN.search(ln)
        if not m:
            continue
        kind, tag = m.group(1), m.group(2)
        if tag != domain:
            continue
        if kind == "BEGIN":
            start = i
        elif kind == "END" and start is not None:
            return start, i
    return None


def _trim_blanks(lines, idx):
    while idx < len(lines) and not lines[idx].strip():
        del lines[idx]
    return lines


# ---------------------------------------------------------------- 生成片段
def render_block(domain, port, block, cdn, transport, ind="    ", inner=None):
    """生成 location 级片段 (带缩进和标记)。

    CDN 和传输方式决定要哪些 location —— 没有 CDN 就不写 resolve,
    非 WS 传输就不写 Upgrade/Connection 头。
    """
    inner = inner or (ind + "    ")
    L = [f"{ind}# >>> {MARK} BEGIN {domain} >>>"]

    if cdn:
        L.append(f"{ind}# CDN 接入: 回源到本机, 边缘负责 TLS 与就近接入")
        L.append(f"{ind}location / {{")
        L.append(f"{inner}proxy_pass http://127.0.0.1:{port};")
        L.append(f"{inner}proxy_http_version 1.1;")
        L.append(f"{inner}proxy_set_header Host $host;")
        L.append(f"{inner}proxy_set_header X-Real-IP $remote_addr;")
        L.append(f"{inner}proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;")
        L.append(f"{inner}proxy_set_header X-Forwarded-Proto $scheme;")
        L.append(f"{ind}}}")
    else:
        L.append(f"{ind}location / {{")
        L.append(f"{inner}proxy_pass http://127.0.0.1:{port};")
        L.append(f"{inner}proxy_http_version 1.1;")
        L.append(f"{inner}proxy_set_header Host $host;")
        L.append(f"{inner}proxy_set_header Upgrade $http_upgrade;")
        L.append(f"{inner}proxy_set_header Connection $connection_upgrade;")
        L.append(f"{inner}proxy_set_header X-Real-IP $remote_addr;")
        L.append(f"{inner}proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;")
        L.append(f"{inner}proxy_read_timeout 300s;")
        L.append(f"{inner}proxy_buffering off;")
        if transport == "grpc":
            L.append(f"{inner}proxy_pass http://127.0.0.1:{port};")
        L.append(f"{ind}}}")

    L.append(f"{ind}# <<< {MARK} END {domain} <<<")
    return L


def render_upstream(name, port):
    """upstream 段。放在 http 级而不是 server 级。"""
    return [
        f"# >>> {MARK} BEGIN {name} >>>",
        f"upstream {name} {{",
        f"    server 127.0.0.1:{port};",
        f"    keepalive 32;",
        "}",
        f"# <<< {MARK} END {name} <<<",
    ]


def detect_indent(lines, server_end):
    """从 server 块内部已有内容推断缩进单位。

    nginx 站点文件是手写的, 有 2 空格也有 4 空格也有 tab。固定写死一种
    只会让 diff 全是空白变化, 掩盖真正的改动。
    """
    for ln in lines[:server_end]:
        if not ln.strip() or ln.strip().startswith("#"):
            continue
        if ln.startswith(" "):
            n = len(ln) - len(ln.lstrip(" "))
            if n > 0:
                return " " * n
        if ln.startswith("\t"):
            return "\t"
    return "    "


# ---------------------------------------------------------------- 提交
def commit(path, lines, nl, had_bom, dry_run, nginx, docker, remove_only):
    payload = nl.join(lines) + nl
    data = payload.encode("utf-8")
    if had_bom:
        data = b"\xef\xbb\xbf" + data

    if dry_run:
        print("---- 预演, 未写入 ----")
        sys.stdout.write(payload[:4000])
        print("\n----------------")
        return 0

    bak = f"{path}.{MARK}-bak"
    try:
        c_copy(path, bak, docker)
        if docker:
            # 容器里走 stdin 管道 + 容器内 mv。权限随原文件, mv 在同一文件系统
            # 内是原子的, 断电不会留下半个配置文件。
            rc, _ = _dexec(docker, ["sh", "-c",
                                    'cat > "$1.tmp" && chmod --reference="$1" "$1.tmp" '
                                    '2>/dev/null; mv "$1.tmp" "$1"',
                                    "sh", path], stdin=data)
            if rc != 0:
                print(f"[错误] 写入容器内文件失败 (rc={rc}): {path}", file=sys.stderr)
                return 2
        else:
            tmp = None
            try:
                fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                                           prefix=f".{MARK}.")
                os.close(fd)
                with open(tmp, "wb") as f:
                    f.write(data)
                shutil.copymode(path, tmp)     # 权限必须跟上, 否则 nginx 读不到
                os.replace(tmp, path)
                tmp = None
            except OSError as e:
                print(f"[错误] 写入失败: {e}", file=sys.stderr)
                if tmp and os.path.exists(tmp):
                    os.unlink(tmp)
                return 2
    except OSError as e:
        print(f"[错误] 备份失败: {e}", file=sys.stderr)
        return 2

    if remove_only:
        print(f"[信息] 已移除, 备份: {bak}")
        return reload(nginx, docker, bak, path)

    return reload(nginx, docker, bak, path)


def reload(nginx, docker, bak, path):
    """校验 + 重载。失败立刻回滚 —— 写入成功但语法错的站点会直接起不来。"""
    if nginx == "none" or not nginx:
        print("[信息] 已写入 (跳过 nginx -t, 需要时请手动 reload)")
        return 0

    argv = nginx_cmd(docker) + [nginx]
    t = subprocess.run(argv, capture_output=True, text=True)
    if t.returncode != 0:
        print("[错误] nginx 配置校验不通过, 已回滚:", file=sys.stderr)
        for ln in (t.stderr or "").strip().splitlines()[:8]:
            print("    " + ln, file=sys.stderr)
        if bak and (c_file_exists(bak, docker) if docker else os.path.exists(bak)):
            c_copy(bak, path, docker)
            print(f"[信息] 已恢复到 {path}", file=sys.stderr)
        return 1

    r = subprocess.run(nginx_cmd(docker) + ["-s", "reload"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("[错误] reload 失败, 已回滚:", file=sys.stderr)
        if bak and (c_file_exists(bak, docker) if docker else os.path.exists(bak)):
            c_copy(bak, path, docker)
        return 1

    print("[OK] 已写入并 reload 成功")
    return 0


# ---------------------------------------------------------------- 主流程
def apply(args):
    path = args.file
    # 容器部署时 path 指的是容器内的路径, 用宿主机的 os.path.isfile 判断必然
    # 报"文件不存在" —— 所以存在性检查也要落到容器那一侧。
    if not c_file_exists(path, args.docker):
        print(f"[错误] 站点文件不存在: {path}", file=sys.stderr)
        return 2

    raw = c_read(path, args.docker)
    nl = newline_style(raw)
    had_bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig" if had_bom else "utf-8", errors="replace")
    lines = text.splitlines()

    domain = args.domain

    # --- 0) 先摘掉上一轮插入的内容, 这是幂等的基础 ---
    span = find_marked_span(lines, domain)
    if span:
        del lines[span[0]:span[1] + 1]
        _trim_blanks(lines, span[0])
        print(f"[信息] 已移除上次插入的 {domain} 片段 ({span[1]-span[0]+1} 行)")

    dspan = find_marked_dirs(lines, domain)
    if dspan:
        del lines[dspan[0]:dspan[1] + 1]
        _trim_blanks(lines, dspan[0])
        print(f"[信息] 已移除上次自动补入的 server 级指令 ({dspan[1]-dspan[0]+1} 行)")

    # --- 1) --remove 到此为止 ---
    if args.remove:
        return commit(path, lines, nl, had_bom, args.dry_run,
                      args.nginx, args.docker, True)

    if args.upstream_port:
        block = render_upstream(domain, args.upstream_port)
    else:
        if not args.port:
            print("[错误] 需要 --port, 或用 --upstream-port, 或用 --remove",
                  file=sys.stderr)
            return 2
        block = render_block(domain, args.port, args.block,
                             args.cdn, args.transport,
                             ind=" " * (args.indent or 4))

    # --- 2) 插进 server 块 ---
    sb = find_server_block(lines)
    if sb is None:
        print(f"[错误] {path} 里找不到 server 块", file=sys.stderr)
        return 2
    s, e = sb

    # upstream 属于 http 级, 插在 server 块外面 (前面)
    if args.upstream_port:
        ins = s
    else:
        ins = e

    if args.indent == 0 and not args.upstream_port:
        block = render_block(domain, args.port, args.block, args.cdn,
                             args.transport, ind=detect_indent(lines, e))

    lines[ins:ins] = block
    print(f"[信息] 已插入 {len(block)} 行 (位置 {ins+1})")

    return commit(path, lines, nl, had_bom, args.dry_run,
                  args.nginx, args.docker, False)


def main():
    p = argparse.ArgumentParser(description="nginx 站点配置幂等管理")
    p.add_argument("--file", help="站点配置文件")
    p.add_argument("--domain", required=True, help="域名 (标记用)")
    p.add_argument("--port", type=int, help="回源端口")
    p.add_argument("--upstream-port", type=int, help="改为插入 upstream 段")
    p.add_argument("--transport", default="ws",
                   choices=["ws", "grpc", "h2", "httpupgrade", "tcp", "xhttp"])
    p.add_argument("--cdn", action="store_true", help="CDN 接入模式")
    p.add_argument("--remove", action="store_true", help="移除本工具插入的内容")
    p.add_argument("--block", help="片段文件")
    p.add_argument("--nginx", default="-t", help="校验命令, none=跳过")
    p.add_argument("--indent", type=int, default=0,
                   help="插入内容的缩进空格数, 0=自动跟随文件风格")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--docker", help="nginx 所在容器名")
    args = p.parse_args()

    if not args.docker:
        args.docker = probe_docker()

    if not args.file:
        found = find_site(args.domain, args.docker)
        if not found:
            print(f"[错误] 找不到域名 {args.domain} 的站点文件", file=sys.stderr)
            for f, sn in list_sites(args.docker):
                print(f"    {f}  server_name {sn}", file=sys.stderr)
            return 2
        args.file = found
        print(f"[信息] 站点文件: {found}")

    if args.block and not os.path.isfile(args.block):
        print(f"[错误] 片段文件不存在: {args.block}", file=sys.stderr)
        return 2

    return apply(args)


if __name__ == "__main__":
    sys.exit(main())
