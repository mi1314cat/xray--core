#!/usr/bin/env python3
"""nginx 站点配置管理 —— 带标记的幂等插入 / 移除 / 回收 / 回滚。

与 mihomo 的 nginx_apply.py 同一套应用逻辑, 只是插入的内容换成 Xray 的
upstream / location 参数。

## 为什么必须是"带标记的幂等"

nginx 的站点文件是手写的、有注释、有各种排版习惯。直接往里追加一段
location, 第二次执行就会追加第二份 —— 配置不报错(两个 server 名字相同
时后者覆盖前者), 但用户已经无从判断当前生效的是哪一段。

所以插入的内容一律加 BEGIN/END 标记, 每次动手之前先摘掉上一轮插入的
整段, 再插新的。同一个域名反复配置 N 次, 结果和配置 1 次完全一样。

## 标记的粒度: 域名 + 路径

标记里的 tag 是 `<域名>` 或 `<域名>|<location 路径>` (路径为 / 时省略)。
为什么要带路径: 反向代理那条链会给**同一个域名**上的多条隧道各开一个
`location /前缀`, 只按域名做标记的话, 第二条隧道会把第一条替换掉, 删一条
也会把另一条一起删掉 —— 那是"连坐", 与"绝不误删"直接冲突。
(mihomo 用一张 tag→域名 的绑定表解决同一件事, 这里把标识放进标记本身,
少一个需要维护、可能失配的文件。)

三种删除粒度, 对应三种插入:

    --remove --domain D            删 `D` 与所有 `D|*`  (整域名收工)
    --remove --domain D --path /   只删 `D`            (默认插入的形态)
    --remove --domain D --path /p  只删 `D|/p`         (只删这一条隧道)

默认(不给 `--path`)是"把这个域名的反代摘干净" —— 只摘一条、把别的悄悄
留着, 用户会以为删完了, 而站点里还留着指向已删端口的 location。
给节点做**自动**清理时相反: 调用方知道自己是哪一条 (deploy 建的节点就是
`--path /` 那一段), 于是带上 `--path /`, 删节点不会把同域名下的隧道带走。

## 生命周期

    插入/更新   摘掉同 tag 的旧段 → 插入 → 提交
    删除        同上, 摘完就提交 (没有可摘的内容时**一个字节都不写**)
    禁用/启用   用 `--remove` / 重新插入 (nginx 没有"禁用"语义; 本工具
                不发明不可回滚的第三态: 注释掉的配置既不会被 -t 校验,
                也没人知道该由谁来恢复)
    备份回收    `--prune-backups`: 只回收**本工具命名**的历史备份, 保留
                最近 N 份, 站点文件已消失的备份一律不碰 (可能是唯一副本)

## 写入路径

    前置 nginx -t → 备份 → 原子替换 → nginx -t → 不通过立刻回滚

nginx -t 是唯一的权威检查。写入成功但语法错了, 站点直接起不来, 所以
校验必须在提交后立刻做, 而且失败要能恢复原文件。前置那一关同样重要:
站点**本来就是坏的**时候, 后置校验会把"配置坏了"记到这次操作头上。
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

MARK = "xray-core"

RE_BEGIN = re.compile(r"#\s*===\s*" + re.escape(MARK) + r"\s+(BEGIN|END)\s+(\S+?)"
                      r"\s*(?:\(server 指令\))?\s*===\s*$")
RE_LOC = re.compile(r"#\s*(>>>|<<<)\s+" + re.escape(MARK) + r"\s+(BEGIN|END)\s+(\S+?)\s*(?:>>>|<<<)\s*$")

# tag 里区分域名与路径的分隔符。域名里不可能出现 `|` (DNS 字符集),
# 路径里也不会 —— 所以它既能当分隔符, 也能被 `(\S+)` 一次性捕获。
TAG_SEP = "|"


def tag_for(domain, path=None):
    """标记用的 tag: 路径是 / 时就是域名 (与旧版本写下的标记兼容)。"""
    p = (path or "/").strip() or "/"
    if not p.startswith("/"):
        p = "/" + p
    return domain if p == "/" else f"{domain}{TAG_SEP}{p}"


def tag_domain(tag):
    return tag.split(TAG_SEP, 1)[0]


def tag_path(tag):
    parts = tag.split(TAG_SEP, 1)
    return parts[1] if len(parts) > 1 else "/"


def norm_path(path):
    p = (path or "/").strip() or "/"
    return p if p.startswith("/") else "/" + p


# ---------------------------------------------------------------- 基础探测
def probe_docker():
    """nginx 跑在容器里吗。

    mihomo 的生产环境就是这样。直接在宿主机上跑 nginx -t 会报找不到
    配置, 而配置其实好好地在那儿 —— 于是"校验失败"触发回滚, 改动丢失,
    而真正的原因只是命令敲错了地方。

    ★ 判据不能只精确匹配容器名。生产上那个容器恰好叫 nginx, 但用户把容器
      命名成 web / proxy ("web" + 镜像 nginx:alpine 是很常见的组合) 时,
      只认 {"nginx", "nginx-proxy"} 就找不到 —— 于是又回到"改了一个 nginx
      永远不会加载的文件"那个坑: 提示写入成功, reload 也成功, 站点毫无变化。
      现在与 SB 的 cdn_probe_nginx 同一口径: **容器名或镜像名里带 nginx** 就算,
      名字正好是 nginx / nginx-proxy 的优先 (保持原有选择不变)。
    """
    if not shutil.which("docker"):
        return None
    try:
        r = subprocess.run(["docker", "ps", "--format", "{{.Names}}\t{{.Image}}"],
                           capture_output=True, timeout=8, text=True)
        if r.returncode != 0:
            return None
        cands = []
        for line in r.stdout.splitlines():
            parts = line.split("\t")
            name = parts[0].strip() if parts else ""
            image = parts[1].strip() if len(parts) > 1 else ""
            if not name:
                continue
            if "nginx" not in f"{name} {image}".lower():
                continue
            cands.append((0 if name in ("nginx", "nginx-proxy") else 1, name))
        if not cands:
            return None
        cands.sort()
        return cands[0][1]
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
    """取出文件里第一个 server_name 的值。

    必须避开 `proxy_ssl_server_name on;` 这类指令 (它们的后半截长得一模一样),
    但又不能只认行首 —— 站点写成一行的 (`server { listen 443 ssl; server_name
    a.com; }`) 同样常见。用"前一个字符不是标识符字符"当判据, 两种都能认。
    """
    try:
        raw = c_read(path, docker).decode("utf-8", errors="replace")
    except OSError:
        return None
    m = re.search(r"(?<![A-Za-z0-9_-])server_name[ \t]+([^;]+);", raw)
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


def strip_comment(line):
    """去掉行尾注释 —— 只做粗略处理, 目的是不把注释里的 { } 当结构。

    ★ 为什么必须去: 花括号配对数错一次, "server 块的结束位置"就整段偏掉。
      用户站点里 `# 下面是 location { ... }` 这种注释很常见, 一行注释里的
      `{` 会让块永远合不上 (找不到插入点), 一行 `}` 会让块提前结束
      (片段插到 server 块外面 —— nginx -t 立刻报 directive is not allowed
      here)。mihomo 的实现里就有这一步, 我们此前是直接对原行数括号。
    """
    out, quote = [], None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out)


def iter_server_blocks(lines):
    """枚举顶层 server{} 块, 返回 [(起, 止, server_name 原文), ...]。

    只认顶层 server 块 —— 缩进只是给人看的, 真正的判据是花括号深度, 而深度
    只在**去掉注释与引号内容**之后才数得准 (见 strip_comment)。

    起始行自身的花括号必须计入初始深度: 漏掉的话, 循环进入后的第一行
    就因为 depth 仍为 0 而被判定成块的结束, 于是"块"只剩 server{ 这一行,
    插入点落在 listen/server_name 之前 —— 语法上仍然合法, 但生成结果
    一眼就能看出不对。
    """
    out = []
    i = 0
    n = len(lines)
    while i < n:
        code = strip_comment(lines[i])
        if not re.match(r"^\s*server\s*\{", code):
            i += 1
            continue
        start = i
        depth = code.count("{") - code.count("}")
        j = i + 1
        while j < n and depth > 0:
            depth += strip_comment(lines[j]).count("{") - strip_comment(lines[j]).count("}")
            j += 1
        end = j - 1 if depth <= 0 else n - 1
        body = "\n".join(strip_comment(l) for l in lines[start:end + 1])
        m = re.search(r"(?<![A-Za-z0-9_-])server_name[ \t]+([^;]+);", body)
        out.append((start, end, m.group(1).strip() if m else ""))
        i = end + 1
    return out


def _names_match(names, domain):
    """server_name 是否覆盖这个域名。返回 'exact' / 'loose' / None。"""
    hit = None
    for tok in names.split():
        if tok == domain:
            return "exact"
        if tok in ("_", "*"):
            hit = hit or "loose"
        elif tok.startswith("*.") and (domain == tok[2:] or domain.endswith(tok[1:])):
            hit = hit or "loose"
        elif tok.startswith(".") and domain.endswith(tok):
            hit = hit or "loose"
        elif tok.startswith("~"):
            hit = hit or "loose"
    return hit


def _block_is_tls(lines, start, end):
    """这个 server 块是不是 TLS 回源入口。

    CDN/nginx 回源打的是 443 那个 server 块, 而站点文件里通常还有一个
    `listen 80; return 301` 的重定向块 —— 两者的 server_name 一模一样。
    挑错了不会报错, 只会让节点**静默不通**。
    """
    body = "\n".join(strip_comment(l) for l in lines[start:end + 1])
    if re.search(r"(?<![A-Za-z0-9_-])listen[ \t][^;]*\b(443|ssl)\b", body):
        return True
    if re.search(r"(?<![A-Za-z0-9_-])ssl_certificate[ \t]", body):
        return True
    if re.search(r"(?<![A-Za-z0-9_-])http2[ \t]+on[ \t]*;", body):
        return True
    return False


def find_server_block(lines, domain):
    """返回**该域名**的 server{} 块的 (起, 止) 行号, 含花括号本身。

    ★ 为什么必须按 server_name 挑, 而不是"第一个 server 块":
      站点文件里通常有多个 server 块 —— 80 端口的 301 重定向块、443 的
      真站点、以及**别的域名**的站点。取第一个的后果实测过两种, 都不报错:
        · 片段插进了 80 重定向块 -> `return 301` 先命中, location 永远到
          不了, 回源 (走 443) 上根本没有这段配置;
        · 片段插进了 other.example.com 的块 -> 给别人的站点开了一条指向
          我们节点的反代 (既是"配好了但用不了", 也是误伤)。
      nginx -t 对这两种都是绿的, 所以只能靠选块这一步选对。
      (mihomo 与 sing-box 的实现都按 server_name 选块, 这里是向它们对齐。)

    多个块都匹配时优先**TLS 回源入口** (listen 443 / ssl / http2 on)。
    一个都不匹配时: 文件里只有一个 server 块就直接用它并告警; 有多个就
    拒绝 (返回 None) —— 让调用方报错, 绝不猜。
    """
    blocks = iter_server_blocks(lines)
    if not blocks:
        return None
    exact, loose = [], []
    for (s, e, names) in blocks:
        m = _names_match(names, domain) if names else None
        if m == "exact":
            exact.append((s, e))
        elif m == "loose":
            loose.append((s, e))
    cands = exact or loose
    if not cands:
        if len(blocks) == 1:
            single = blocks[0]
            print(f"[提示] 文件里只有一个 server 块, 且它的 server_name 不是 "
                  f"{domain} (实际: {single[2] or '无'}) —— 按位置沿用, 请核对。",
                  file=sys.stderr)
            return single[0], single[1]
        return None
    if len(cands) > 1:
        tls = [c for c in cands if _block_is_tls(lines, c[0], c[1])]
        if tls:
            return tls[0]
    return cands[0]


def describe_blocks(lines):
    """给报错用的站点块清单: [(行号, server_name, 是否 TLS), ...]。"""
    return [(s + 1, names or "(无 server_name)", _block_is_tls(lines, s, e))
            for (s, e, names) in iter_server_blocks(lines)]


# ---------------------------------------------------------------- 文本工具
def newline_style(raw):
    return "\r\n" if b"\r\n" in raw[:4000] else "\n"


def find_marked_span(lines, tag):
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
        kind, got = m.group(2), m.group(3)
        if got != tag:
            continue
        if kind == "BEGIN":
            start = i
        elif kind == "END" and start is not None:
            return start, i
    return None


def find_all_marked_spans(lines, domain):
    """找该域名下**所有** location 级标记段 (含带路径的)。

    返回 [(start, end, tag), ...], 按出现顺序。删除多个段时必须从后往前删,
    否则前面的下标会失效 —— 这是这类"先收集再删除"的经典坑。
    """
    out = []
    i = 0
    n = len(lines)
    while i < n:
        m = RE_LOC.search(lines[i])
        if not m:
            i += 1
            continue
        kind, got = m.group(2), m.group(3)
        if kind != "BEGIN" or tag_domain(got) != domain:
            i += 1
            continue
        end = None
        for j in range(i + 1, n):
            m2 = RE_LOC.search(lines[j])
            if m2 and m2.group(2) == "END" and m2.group(3) == got:
                end = j
                break
        if end is None:
            # 只有 BEGIN 没有 END: 已经被改坏, 不碰它 —— 猜区间就会吞掉
            # 后面用户自己写的东西 (宁可留着让人看见, 也不误删)
            i += 1
            continue
        out.append((i, end, got))
        i = end + 1
    return out


def span_declares_location(lines, span, path):
    """这段标记块里有没有 `location <path> {`。

    用途是**旧标记的升级路径**: 老版本写下的标记只有域名 (没有路径),
    现在要精确删/换某一条路径时, 得先确认这段讲的正是那条路径, 才敢动它。
    """
    want = norm_path(path)
    for ln in lines[span[0]:span[1] + 1]:
        m = re.match(r"^\s*location\s+(\S+?)\s*\{", strip_comment(ln))
        if m and m.group(1) == want:
            return True
    return False


def find_marked_dirs(lines, tag):
    """找 server 级指令标记段 (upstream 也是这一套)。"""
    start = None
    for i, ln in enumerate(lines):
        m = RE_BEGIN.search(ln)
        if not m:
            continue
        kind, got = m.group(1), m.group(2)
        if got != tag:
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
def render_block(domain, port, block, cdn, transport, ind="    ", inner=None,
                 path="/"):
    """生成 location 级片段 (带缩进和标记)。

    CDN 和传输方式决定要哪些 location —— 没有 CDN 就不写 resolve,
    非 WS 传输就不写 Upgrade/Connection 头。

    path 是 location 的匹配路径。默认 "/" 覆盖整个站点; 反向代理那种"给一条
    隧道单开一个前缀"的场景要传具体路径 (如 /HCaVHO3U), 否则插进去的
    location / 会抢占整个站点, 把原有流量全吸走 —— 语法没错, 但线上立刻挂。

    ★ path 同时决定标记的 tag (`域名` 或 `域名|路径`, 见 tag_for)。同域名下
      多条隧道因此各有各的段: 重建其中一条不会把另一条替换掉, 删其中一条
      也不会连坐 —— 只按域名做标记时, 这两件事都会发生。

    block 是自定义片段文件的内容。给了就用它, 不再自动生成 —— 此前这个参数
    一路传进来却从没被用过, --block 写了等于没写。
    """
    inner = inner or (ind + "    ")
    path = norm_path(path)
    tag = tag_for(domain, path)
    L = [f"{ind}# >>> {MARK} BEGIN {tag} >>>"]

    if block:
        # 自定义片段: 仍然由本函数加标记, 保证摘除时找得到边界。
        #
        # 必须保留片段内部的相对缩进。直接 ind + ln.strip() 会把嵌套层级抹平,
        # 于是 location 里的 proxy_pass 和 location 变成同级 —— nginx -t 会
        # 报 unexpected "}"。正确做法是取非空行的最小缩进当基准, 整段左移后
        # 再统一加 ind: 片段自身怎么写都不管, 落进 server 块后都是对的层级。
        raw = block.rstrip("\n").split("\n")
        widths = [len(l) - len(l.lstrip()) for l in raw if l.strip()]
        base = min(widths) if widths else 0
        for ln in raw:
            L.append(ind + ln[base:].rstrip() if ln.strip() else "")
        L.append(f"{ind}# <<< {MARK} END {tag} <<<")
        return L

    if cdn:
        L.append(f"{ind}# CDN 接入: 回源到本机, 边缘负责 TLS 与就近接入")
        L.append(f"{ind}location {path} {{")
        L.append(f"{inner}proxy_pass http://127.0.0.1:{port};")
        L.append(f"{inner}proxy_http_version 1.1;")
        L.append(f"{inner}proxy_set_header Host $host;")
        L.append(f"{inner}proxy_set_header X-Real-IP $remote_addr;")
        L.append(f"{inner}proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;")
        L.append(f"{inner}proxy_set_header X-Forwarded-Proto $scheme;")
        L.append(f"{ind}}}")
    else:
        L.append(f"{ind}location {path} {{")
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

    L.append(f"{ind}# <<< {MARK} END {tag} <<<")
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


RE_LOCATION = re.compile(r"^\s*location\s+(?:([=^~]+|~\*?)\s+)?(\S+?)\s*\{")


def location_paths(lines):
    """列出这些行里出现的 location 匹配路径 (含 = / ^~ / ~ 修饰符后的那个)。"""
    out = []
    for ln in lines:
        m = RE_LOCATION.match(strip_comment(ln))
        if m:
            out.append(m.group(2))
    return out


def find_location_conflicts(lines, block_start, block_end, block):
    """要插的 location 与目标 server 块里**用户自己写的** location 是否重名。

    ★ 为什么必须提前拦:
      站点里已经有 `location /` 时, 再插一个 `location /` 会让 nginx 直接
      emerg (`duplicate location "/"`)。靠"写完再 nginx -t + 回滚"当然也能
      兜住, 但那把一次本可以讲清楚的拒绝变成了一条看不懂的回滚日志, 而
      用户真正需要知道的是"换个前缀"或者"用 --path"。

    判据是**路径字符串相等** —— nginx 的 location 冲突就是按 (修饰符, 路径)
    判的, 这里保守一点只看路径; 我们自己的标记段此时已经摘掉, 不会自己撞自己。
    """
    want = location_paths(block)
    if not want:
        return []
    # 只看目标 server 块内部 (别的 server 块里的同名 location 是合法的)
    have = set(location_paths(lines[block_start:block_end + 1]))
    return [p for p in want if p in have]


# ---------------------------------------------------------------- 提交
BAK_SUFFIX = f".{MARK}-bak"
# 历史备份的命名: <站点文件>.xray-core-bak.<YYYYmmdd-HHMMSS>
RE_BAK_HIST = re.compile(re.escape(BAK_SUFFIX) + r"\.(\d{8}-\d{6})$")
BAK_KEEP_DEFAULT = 3


def _list_dir(dirpath, docker=None):
    """列目录里的文件名 (不含路径)。容器里没有 os.listdir, 走 ls -1。"""
    if docker:
        rc, out = _dexec(docker, ["sh", "-c", 'ls -1 "$1" 2>/dev/null; exit 0',
                                  "sh", dirpath])
        return [x for x in out.decode(errors="replace").split("\n") if x]
    try:
        return os.listdir(dirpath)
    except OSError:
        return []


def c_remove(path, docker=None):
    if not docker:
        os.unlink(path)
        return
    _dexec(docker, ["rm", "-f", path])


def backup_paths(path, docker=None):
    """本工具在这份站点旁边留下的所有备份: (最新一份, 历史列表)。

    只认**本工具自己的命名**: `<文件>.xray-core-bak` 与
    `<文件>.xray-core-bak.<时间戳>`。
    别人的备份 (`*.bak` / `.sbpanel-bak` / `.mihomo-core-cdn-bak` /
    手工的 `.bak-vless` ...) 一律不在回收范围内 —— "回收"能碰的前提是
    "这确实是我自己产生的、且我知道怎么重建它"。
    """
    d = os.path.dirname(path) or "."
    base = os.path.basename(path)
    cur = f"{path}{BAK_SUFFIX}"
    hist = []
    for name in _list_dir(d, docker):
        if not name.startswith(base):
            continue
        rest = name[len(base):]
        m = RE_BAK_HIST.match(rest)
        if m:
            hist.append((m.group(1), f"{d}/{name}"))
    hist.sort(key=lambda x: x[0], reverse=True)      # 时间戳大的在前 = 新的在前
    cur_exists = c_file_exists(cur, docker)
    return (cur if cur_exists else None), hist


def _bak_dir_ok(path, docker=None):
    """站点文件还在吗。不在就不回收 —— 那可能是唯一副本。"""
    return c_file_exists(path, docker)


def prune_backups(path, docker=None, keep=BAK_KEEP_DEFAULT, force=False, quiet=False):
    """回收本工具留下的历史备份, 只保留最新 keep 份。

    ★ 判据 (三条, 缺一不可, 宁可少删):
      1. 名字必须是 `<站点文件>.xray-core-bak.<时间戳>` —— 本工具自己写的;
         别的工具的备份、用户手抄的 `x.conf.bak`, 一个都不碰。
      2. **站点文件必须还在**。站点已经不在了的备份不回收: 它可能是这份配置
         的最后一份副本 (现场就看到过 9 个这样的残留, 其中还留着标记),
         删掉就真没了。
      3. 最新的一份永远保留 (keep 至少 1) —— 它是回滚的依据。
    `force` 只影响"站点文件不在"这一条之外的行为? 不: force 也不删 (见 2),
    它只是允许在 keep=0 时至少保 1。回收的边界写死在这里, 不给绕过。
    """
    keep = max(1, int(keep))
    cur, hist = backup_paths(path, docker)
    if not hist:
        if not quiet:
            print(f"[信息] 没有可回收的历史备份 ({os.path.basename(path)})")
        return []
    if not _bak_dir_ok(path, docker):
        if not quiet:
            print(f"[信息] 站点文件已不在 ({path}), 保留全部 {len(hist)} 份备份 "
                  f"(可能是唯一副本)。确认不再需要后手工删除。")
        return []
    removed = []
    for _ts, p in hist[keep:]:
        try:
            c_remove(p, docker)
            removed.append(p)
        except OSError as e:
            if not quiet:
                print(f"[提示] 回收失败 (跳过): {p} ({e})", file=sys.stderr)
    if not quiet:
        if removed:
            print(f"[信息] 已回收 {len(removed)} 份历史备份, 保留最新 {min(keep, len(hist))} 份:")
            for p in removed:
                print(f"    - {p}")
        else:
            print(f"[信息] 历史备份已有 {len(hist)} 份, 未超过保留数 {keep}, 无需回收")
    return removed


def rotate_backup(path, docker=None):
    """把**上一轮的**规范备份挪进历史, 再留出新的一份位置。

    规范备份 `<file>.xray-core-bak` 只有一份 (回滚用), 每次写入都会覆盖它。
    不转存的话, "插入前"的原件会被下一次操作抹掉 —— 而那正是用户最想要的
    那个版本 (一份没有被本工具改过的站点)。转存后: 规范备份 = 上一次改动前,
    历史备份 = 更早的若干份, 且份数有上限 (可回收)。
    """
    cur = f"{path}{BAK_SUFFIX}"
    if not c_file_exists(cur, docker):
        return
    d = os.path.dirname(path) or "."
    # 时间戳用**备份自己的 mtime**: 它代表那份内容产生的时刻, 而不是
    # "我们什么时候想起来转存"。同名已存在就顺延一秒, 不覆盖已有历史。
    try:
        if docker:
            rc, out = _dexec(docker, ["sh", "-c", 'date -u -r "$1" +%Y%m%d-%H%M%S',
                                      "sh", cur])
            ts = out.decode().strip() if rc == 0 else ""
        else:
            ts = time.strftime("%Y%m%d-%H%M%S", time.gmtime(os.path.getmtime(cur)))
    except OSError:
        ts = ""
    if not ts:
        ts = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    cand = f"{cur}.{ts}"
    n = 0
    while c_file_exists(cand, docker) and n < 120:
        n += 1
        t = time.strptime(ts, "%Y%m%d-%H%M%S")
        cand = f"{cur}.{time.strftime('%Y%m%d-%H%M%S', time.gmtime(time.mktime(t) + n))}"
    try:
        c_copy(cur, cand, docker)
    except OSError as e:
        print(f"[提示] 历史备份转存失败 (不影响本次写入): {e}", file=sys.stderr)


def nginx_precheck(nginx, docker, required=False):
    """动手之前先验证**当前**这份配置是好的。

    ★ 为什么要前置 (与写入后的校验是两件事):
      后面的路径是"写入 -> nginx -t -> 失败回滚"。如果站点**本来就是坏的**
      (用户手改坏了 / 别的工具写坏了), 那条路径会把我们的改动回滚, 同时把
      "配置坏了"这件事归到这次操作头上 —— 用户看到"插入失败", 真正的原因
      (本来就坏) 完全被掩盖; 更糟的是我们还在一个坏文件上动了手。
      前置校验失败就一个字都不改, 直接告诉用户"先修好它"。

    返回 (ok, 说明)。检测不到 nginx (没装 / PATH 里没有) 时视为 ok ——
    与写入后的处理口径一致: 没得校验就跳过, 不能因为校验不可用而拦住操作。
    `required=True` (--require-check) 时反过来: 校验不了就**拒绝写入** ——
    "坏配置一个字都不落盘"只有在能校验的前提下才成立, 校验不了还照写,
    剩下的就全靠运气了。
    """
    if nginx == "none" or not nginx:
        if required:
            return False, ("    指定了 --require-check 但校验被显式关掉 (--nginx none): "
                           "无法保证配置可用, 拒绝写入")
        return True, ""
    argv = nginx_cmd(docker) + [nginx]
    try:
        t = subprocess.run(argv, capture_output=True, text=True)
    except OSError as e:
        if required:
            return False, f"    无法执行 {' '.join(argv)} ({e}); --require-check 要求先能校验"
        return True, f"无法执行 {' '.join(argv)} ({e}); 跳过前置校验"
    if t.returncode != 0:
        msg = (t.stderr or t.stdout or "").strip()
        return False, "\n".join("    " + ln for ln in msg.splitlines()[:6])
    return True, ""


def commit(path, lines, nl, had_bom, dry_run, nginx, docker, remove_only,
           keep=BAK_KEEP_DEFAULT, same_as_before=None):
    payload = nl.join(lines) + nl
    data = payload.encode("utf-8")
    if had_bom:
        data = b"\xef\xbb\xbf" + data

    if dry_run:
        print("---- 预演, 未写入 ----")
        sys.stdout.write(payload[:4000])
        print("\n----------------")
        return 0

    # ★ 内容没变就**什么都不做**。
    #   以前 --remove 一个没插过的域名也会走完整套: 覆盖一次备份、重写一次
    #   文件、reload 一次 nginx。最要命的是那个备份 —— 规范备份槽只有一份,
    #   这一覆盖就把"插入前的原件"抹掉了, 用户再也回不到干净版本。
    #   幂等的完整含义是"结果一致", 不只是"文件内容一致": 副作用也要一致 ——
    #   第二次执行不该比第一次多留下任何痕迹。
    if same_as_before is not None and data == same_as_before:
        print("[信息] 没有需要改动的内容 (幂等: 未写盘、未动备份、未 reload)")
        return 0

    bak = f"{path}{BAK_SUFFIX}"
    try:
        rotate_backup(path, docker)        # 上一轮的备份转成历史, 再让出槽位
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

    rc = reload(nginx, docker, bak, path)
    if rc == 0:
        # 回收放在**写成功之后**: 写失败/回滚时那份备份正是要用的东西,
        # 不能在此之前动它。份数上限只是"别只增不减", 不是"立刻清空"。
        prune_backups(path, docker, keep=keep, quiet=False)
    return rc


def reload(nginx, docker, bak, path):
    """校验 + 重载。失败立刻回滚 —— 写入成功但语法错的站点会直接起不来。"""
    if nginx == "none" or not nginx:
        print("[信息] 已写入 (跳过 nginx -t, 需要时请手动 reload)")
        return 0

    argv = nginx_cmd(docker) + [nginx]
    try:
        t = subprocess.run(argv, capture_output=True, text=True)
    except OSError as e:
        # 没装 nginx / PATH 里找不到: 直接抛会打一整屏 traceback, 而这里要做
        # 的只是"跳过校验并说明原因"。文件已经写入了, 不回滚 —— 回滚会让用户
        # 以为什么都没发生, 实际上配置已经生效只是没被校验。
        print(f"[信息] 已写入, 但无法执行 {' '.join(argv)} ({e}); "
              f"请手工 nginx -t 确认后再 reload", file=sys.stderr)
        return 0
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

    # --- 前置校验: 现有配置就已经不通过 nginx -t 时, 什么都不动 ---
    #     (--skip-precheck 是给"就是来修这份坏配置"的场景留的出口)
    if not args.dry_run and not args.skip_precheck:
        pre_ok, pre_why = nginx_precheck(args.nginx, args.docker,
                                         required=args.require_check)
        if not pre_ok:
            print("[错误] 站点现有配置就没通过 nginx -t, 未做任何改动。"
                  "先修好它再来 (或加 --skip-precheck 强行操作):", file=sys.stderr)
            print(pre_why, file=sys.stderr)
            return 3
        if pre_why:
            print(f"[信息] {pre_why}", file=sys.stderr)

    domain = args.domain
    if not domain or TAG_SEP in domain or any(c.isspace() for c in domain):
        print(f"[错误] 域名不合法 (不能含空白或 '{TAG_SEP}'): {domain!r}", file=sys.stderr)
        return 2
    path_wanted = norm_path(args.path) if args.path else None

    # --- 0) 先摘掉上一轮插入的内容, 这是幂等的基础 ---
    #
    # 摘哪些段取决于这次要干什么:
    #   插入 --path /p        -> 只摘 `域名|/p` (同域名别的路径不碰)
    #   删除 (默认)           -> 只摘 `域名`   (正是默认插入写下的那个 tag)
    #   删除 --path /p        -> 只摘 `域名|/p`
    #   删除 --all            -> 摘 `域名` 与 `域名|*` (整域名收工)
    #
    # 旧版本只按域名做标记, 所以这里还要认"老标记": 只有当它的正文里确实
    # 写着我们要动的那条 location 时才摘 —— 认的是内容, 不是猜。
    targets = set()
    if args.remove:
        if path_wanted is not None:
            # 显式给了 --path (含 "/"): 只动这一条 —— 删一条隧道不该把
            # 同域名下别的隧道带走
            targets.add(tag_for(domain, path_wanted))
        else:
            # 没给 --path: 整域名收工 (所有路径)。这是"把一个域名的反代摘掉"
            # 的自然含义 —— 默认只删其中一条、把别的留着, 用户会以为摘干净了,
            # 而站点里还留着指向已删端口的 location (回源 502), 正是本工具
            # 最该消灭的那种幽灵配置。
            targets.add(tag_for(domain, "/"))
            for (_s, _e, tag) in find_all_marked_spans(lines, domain):
                targets.add(tag)
    else:
        targets.add(tag_for(domain, path_wanted or "/"))

    removed_tags = []
    spans = [(s, e, t) for (s, e, t) in find_all_marked_spans(lines, domain)
             if t in targets]
    # 旧标记 (tag == 域名) 的升级路径: 请求动的是带路径的 tag 时, 若有一段
    # 只有域名、正文里正好是那条 location, 一并摘掉再插新的 —— 否则同一条
    # location 会同时存在于新旧两段里, nginx -t 直接报 duplicate location。
    if path_wanted and path_wanted != "/":
        for (s, e, t) in find_all_marked_spans(lines, domain):
            if t == domain and (s, e, t) not in spans \
                    and span_declares_location(lines, (s, e), path_wanted):
                spans.append((s, e, t))
    spans.sort(key=lambda x: x[0], reverse=True)     # 从后往前删, 下标不失效
    for (s, e, t) in spans:
        del lines[s:e + 1]
        _trim_blanks(lines, s)
        removed_tags.append(t)
        print(f"[信息] 已移除标记段 {t} ({e - s + 1} 行)")
    if removed_tags:
        print(f"[信息] 本次摘除: {', '.join(removed_tags)}")

    # server 级指令段 (`===` 标记) 是整域名一份的, 只按路径删某一条时不能动它,
    # 否则同域名别的路径还在用这段里的 upstream。
    dirs_removed = False
    dspan = find_marked_dirs(lines, domain)
    if dspan and not (args.remove and path_wanted and path_wanted != "/"):
        del lines[dspan[0]:dspan[1] + 1]
        _trim_blanks(lines, dspan[0])
        dirs_removed = True
        print(f"[信息] 已移除上次自动补入的 server 级指令 ({dspan[1]-dspan[0]+1} 行)")

    # --- 1) --remove 到此为止 ---
    if args.remove:
        if not removed_tags and not dirs_removed:
            # 没有可摘的内容 -> 一个字节都不写。
            # (以前这里照样走 commit: 覆盖备份 + 重写文件 + reload nginx,
            #  把"插入前的原件"备份也抹掉了 —— 副作用一点也不幂等)
            print(f"[信息] 没有找到 {domain} 的标记段, 无需改动 (未写盘、未 reload)")
            return 0
        return commit(path, lines, nl, had_bom, args.dry_run,
                      args.nginx, args.docker, True, keep=args.keep,
                      same_as_before=raw)

    if args.upstream_port:
        block = render_upstream(domain, args.upstream_port)
    else:
        # 自定义片段自带 proxy_pass, 再要求 --port 只会让调用方为了过校验而
        # 填一个根本没被使用的数字。
        if not args.port and not args.block:
            print("[错误] 需要 --port, 或用 --upstream-port, 或用 --block 片段文件, 或用 --remove",
                  file=sys.stderr)
            return 2
        block = render_block(domain, args.port, args.block,
                             args.cdn, args.transport,
                             ind=" " * (args.indent or 4),
                             path=path_wanted or "/")

    # --- 2) 插进 server 块 ---
    sb = find_server_block(lines, domain)
    if sb is None:
        print(f"[错误] {path} 里找不到 server_name 覆盖 {domain} 的 server 块 —— 拒绝写入。",
              file=sys.stderr)
        print("       本工具只往已存在的 server{} 内插 location, 不会新建 server 块"
              "(同名 server 会让 nginx 起不来)。", file=sys.stderr)
        print(f"       {path} 里现有的 server 块:", file=sys.stderr)
        for (ln, names, tls) in describe_blocks(lines):
            print(f"         第 {ln} 行  server_name {names}{'  (TLS)' if tls else ''}",
                  file=sys.stderr)
        print("       请确认域名拼写, 或把片段手工贴进对应的 server{} 内。", file=sys.stderr)
        return 3
    s, e = sb

    if args.indent == 0 and not args.upstream_port:
        block = render_block(domain, args.port, args.block, args.cdn,
                             args.transport, ind=detect_indent(lines, e),
                             path=path_wanted or "/")

    # 回源打的是 443 (或 CDN 回源端口)。选到了非 TLS 块也不拒绝 —— 用户可能
    # 就是想在 80 上做反代 —— 但必须说出来, 因为绝大多数情况下那是选错了块,
    # 而 nginx -t 对此完全无感。
    if not args.upstream_port and not _block_is_tls(lines, s, e):
        print(f"[提示] 选中的 server 块 (第 {s+1} 行) 看不到 listen 443 / ssl —— "
              f"如果这是 80 端口的跳转块, CDN 回源不会走到这段配置, 请核对。",
              file=sys.stderr)

    # 同名 location 冲突: 提前拒绝, 并把出路写清楚 (写完再回滚也能兜住,
    # 但那对用户来说只是一条看不懂的报错)
    if not args.upstream_port:
        dup = find_location_conflicts(lines, s, e, block)
        if dup and args.dry_run:
            print(f"[提示] 预演: 该 server 块里已经有同名的 location "
                  f"({', '.join(dup)}) —— 真写入会被拒绝 (nginx 报 "
                  f"duplicate location)。给节点单开一个前缀: --path /你的前缀。",
                  file=sys.stderr)
        elif dup:
            print(f"[错误] 该 server 块里已经有同名的 location: {', '.join(dup)} —— "
                  f"再插一个会让 nginx 直接 emerg (duplicate location), "
                  f"已拒绝, 未做任何改动。", file=sys.stderr)
            print("       办法一 (推荐): 给这个节点单开一个前缀 —— 把节点配置里的 "
                  "path 传给 --path, 如 --path /HaaDoJ29/。", file=sys.stderr)
            print("       办法二: 如果这条就是要抢占站点首页, 先把你原来的 "
                  "location 改个路径或删掉。", file=sys.stderr)
            if args.transport in ("tcp", "raw"):
                print("       办法三 (裸 TCP): 裸 TCP 不能靠 location 反代 "
                      "(需要在 nginx 的 stream{} 里 forward), 建议改用 "
                      "ws/httpupgrade/xhttp。", file=sys.stderr)
            return 4

    # upstream 属于 http 级, 插在 server 块外面 (前面)
    ins = s if args.upstream_port else e
    lines[ins:ins] = block
    print(f"[信息] 已插入 {len(block)} 行 (位置 {ins+1}, tag {tag_for(domain, path_wanted or '/')})")

    return commit(path, lines, nl, had_bom, args.dry_run,
                  args.nginx, args.docker, False, keep=args.keep,
                  same_as_before=raw)


def prune_orphans(live_domains, args):
    """按标记清掉"已无对应节点"的片段 —— 只删**本工具自己标记的段**。

    ★ 与 sing-box 的 cdn_prune.py 的关键区别 (那是"不要学"的部分):
      它按**形状**认领: 顶层 `location` + `proxy_pass http://127.0.0.1:<端口>`
      + 端口不在存活列表里 -> 删。于是用户自己手写的
      `location /myapp { proxy_pass http://127.0.0.1:8080; }` 只要那个端口
      当时没在听, 就会被当成孤儿删掉 —— 判据是猜的, 删的是别人的东西。
      这里只认 `# >>> xray-core BEGIN <tag> >>>` / `END` 配对的段: 认领范围
      是确定的, 段外一个字符都不动。标记之外的配置**永远**不在回收范围里。
    """
    live = {d for d in live_domains if d}
    files = [args.file] if args.file else site_files(args.docker)
    total = 0
    for path in files:
        if not c_file_exists(path, args.docker):
            continue
        raw = c_read(path, args.docker)
        nl = newline_style(raw)
        had_bom = raw.startswith(b"\xef\xbb\xbf")
        lines = raw.decode("utf-8-sig" if had_bom else "utf-8",
                           errors="replace").splitlines()
        spans = [(s, e, t) for (s, e, t) in find_all_marked_spans_all(lines)
                 if tag_domain(t) not in live]
        dspan = None
        for (s, e, t) in find_all_marked_spans_all(lines, dirs=True):
            if tag_domain(t) not in live:
                dspan = dspan or (s, e, t)
        if not spans and not dspan:
            continue
        print(f"[信息] {path}: 发现 {len(spans)} 个孤儿片段 "
              f"({', '.join(sorted({t for _s, _e, t in spans}))})")
        if args.dry_run:
            continue
        for (s, e, t) in sorted(spans, key=lambda x: x[0], reverse=True):
            del lines[s:e + 1]
            _trim_blanks(lines, s)
            total += 1
        if dspan:
            del lines[dspan[0]:dspan[1] + 1]
            _trim_blanks(lines, dspan[0])
        rc = commit(path, lines, nl, had_bom, False, args.nginx, args.docker,
                    True, keep=args.keep, same_as_before=raw)
        if rc != 0:
            print(f"[错误] {path} 的孤儿片段清理失败 (已回滚), 未继续", file=sys.stderr)
            return rc
    if args.dry_run:
        print("[信息] 预演结束, 未写入")
    elif total:
        print(f"[OK] 已清理 {total} 个孤儿片段")
    else:
        print("[信息] 没有发现孤儿片段")
    return 0


def find_all_marked_spans_all(lines, dirs=False):
    """列出文件里**所有**标记段的 (起, 止, tag), 不限定域名。

    用在孤儿清理上 —— 那里要先知道"这个文件里有哪些 tag", 再判断哪些是孤儿。
    只认标记, 不认形状: 用户自己写的东西不会被卷进来。

    ★ 两套标记的正则分组位置不同: FILE 级 `===` 的 (1,2) 是 (BEGIN|END)、tag,
      location 级 `>>>` 的 (1,2) 是箭头、真正的是 (2,3)。按同一套下标取,
      kind 会永远是 ">>>" 而不是 "BEGIN", 于是**一个段都找不到**、还报
      "没有孤儿" —— 假绿灯。所以这里按用哪套正则分别取。
    """
    rx = RE_BEGIN if dirs else RE_LOC

    def kind_tag(m):
        return (m.group(1), m.group(2)) if dirs else (m.group(2), m.group(3))

    out = []
    i, n = 0, len(lines)
    while i < n:
        m = rx.search(lines[i])
        if not m:
            i += 1
            continue
        kind, tag = kind_tag(m)
        if kind != "BEGIN":
            i += 1
            continue
        end = None
        for j in range(i + 1, n):
            m2 = rx.search(lines[j])
            if not m2:
                continue
            k2, t2 = kind_tag(m2)
            if k2 == "END" and t2 == tag:
                end = j
                break
        if end is None:
            i += 1
            continue
        out.append((i, end, tag))
        i = end + 1
    return out


def main():
    p = argparse.ArgumentParser(description="nginx 站点配置幂等管理")
    p.add_argument("--file", help="站点配置文件")
    p.add_argument("--domain", help="域名 (标记用)")
    p.add_argument("--port", type=int, help="回源端口")
    p.add_argument("--upstream-port", type=int, help="改为插入 upstream 段")
    p.add_argument("--transport", default="ws",
                   choices=["ws", "grpc", "h2", "httpupgrade", "tcp", "xhttp"])
    p.add_argument("--cdn", action="store_true", help="CDN 接入模式")
    p.add_argument("--remove", action="store_true", help="移除本工具插入的内容")
    p.add_argument("--all", dest="remove_all", action="store_true",
                   help="配合 --remove: 明确表示「该域名下所有路径都摘掉」"
                        " (不带 --path 时的默认行为)")
    p.add_argument("--block", help="片段文件 (自定义内容, 给了就不自动生成)")
    p.add_argument("--path", default=None,
                   help="location 匹配路径, 默认 /。反向代理单开前缀时用, "
                        "如 --path /HCaVHO3U —— 写成 / 会抢占整个站点。"
                        "它同时是标记的一部分, 所以同域名不同路径互不干扰")
    p.add_argument("--nginx", default="-t", help="校验命令, none=跳过")
    p.add_argument("--indent", type=int, default=0,
                   help="插入内容的缩进空格数, 0=自动跟随文件风格")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--skip-precheck", action="store_true",
                   help="跳过【写入前 nginx -t】这道前置校验 (默认不跳; "
                        "站点本来就是坏的、而你就是来修它的时候用)")
    p.add_argument("--require-check", action="store_true",
                   help="校验不可用 (没装 nginx / --nginx none) 时拒绝写入; "
                        "默认是「没得校验就跳过并告警」")
    p.add_argument("--docker", help="nginx 所在容器名")
    p.add_argument("--keep", type=int, default=BAK_KEEP_DEFAULT,
                   help=f"历史备份保留份数 (默认 {BAK_KEEP_DEFAULT}; 最新一份永远保留)")
    p.add_argument("--prune-backups", action="store_true",
                   help="只回收本工具的历史备份 (不动站点配置)")
    p.add_argument("--prune-orphans", metavar="LIVE_DOMAINS",
                   help="清掉已无对应节点的标记段; 参数是存活域名 (逗号分隔)。"
                        "只认本工具的标记, 段外一个字符都不动")
    p.add_argument("--list-backups", action="store_true",
                   help="列出本工具在这份站点旁留下的备份")
    args = p.parse_args()

    # 容器自动探测只在"需要自己去找站点文件"时才做。
    #
    # 显式给了 --file 的路径是调用方手上的路径, 默认按宿主机路径处理。曾经这里
    # 无条件探测, 于是 nginx 跑在容器里时, --file /etc/nginx/conf.d/x.conf 会
    # 被拿到容器里去找 —— 宿主机上明明有这个文件, 却报"站点文件不存在"。
    # 连带的是 --block / --path 这些新参数在容器机器上一个都用不了, 因为卡在
    # 这道存在性检查上。
    #
    # NGINX_CONF_ROOTS 同理: 调用方已经明确指定了在哪找配置, 就不要再自作主张
    # 去容器里找。自检脚本就是靠它把测试钉在夹具目录上, 而在这之前探测会覆盖它
    # —— 于是在 nginx 跑在容器里的机器上, 自检改的是真实站点配置。
    explicit_roots = bool(os.environ.get("NGINX_CONF_ROOTS"))
    if not args.docker and not args.file and not explicit_roots:
        args.docker = probe_docker()
    if args.file and not args.docker:
        args.docker = None

    # ---- 回收 / 巡检这两个模式不需要 --domain, 先分流 ----
    if args.prune_orphans is not None:
        return prune_orphans([d.strip() for d in args.prune_orphans.split(",")],
                             args)
    if args.prune_backups or args.list_backups:
        targets = [args.file] if args.file else [f for f, _sn in list_sites(args.docker)]
        if not targets:
            print("[信息] 没有找到站点文件")
            return 0
        for path in targets:
            cur, hist = backup_paths(path, args.docker)
            if args.list_backups:
                print(f"{path}")
                print(f"    最新备份: {cur or '(无)'}")
                for ts, p2 in hist:
                    print(f"    历史备份: {p2}  ({ts})")
                if not cur and not hist:
                    print("    (本工具没有留下备份)")
                continue
            prune_backups(path, args.docker, keep=args.keep)
        return 0

    if not args.domain:
        print("[错误] 需要 --domain (或用 --prune-backups / --list-backups / "
              "--prune-orphans)", file=sys.stderr)
        return 2

    if not args.file:
        found = find_site(args.domain, args.docker)
        if not found:
            print(f"[错误] 找不到域名 {args.domain} 的站点文件", file=sys.stderr)
            for f, sn in list_sites(args.docker):
                print(f"    {f}  server_name {sn}", file=sys.stderr)
            return 2
        args.file = found
        print(f"[信息] 站点文件: {found}")

    if args.block:
        if not os.path.isfile(args.block):
            print(f"[错误] 片段文件不存在: {args.block}", file=sys.stderr)
            return 2
        # 读成内容再传下去。render_block 拿到的是片段文本, 而 --block 给的是
        # 路径 —— 之前直接把路径传进去了, 于是每次都被当成"没有自定义片段"
        # 走自动生成, --block 静默失效, 用的人以为已经换掉了 location。
        try:
            args.block = open(args.block, encoding="utf-8",
                              errors="replace").read()
        except OSError as e:
            print(f"[错误] 读取片段文件失败: {e}", file=sys.stderr)
            return 2

    return apply(args)


if __name__ == "__main__":
    sys.exit(main())
