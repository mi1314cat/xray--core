#!/usr/bin/env python3
"""Xray DNS 段编辑 —— 结构化读写 config.json 的 dns 字段。

## 为什么单独做一层

Xray 的 dns 段是严格的 typed schema: servers 里换一种形态、queryStrategy
写错一个字母, `xray run -test` 就拒。整个 config.json 因此不能手改 —— 但
手改又恰恰是很多人改 DNS 的方式, 改完要等到下次重启才发现配置根本不合法。

这里把 dns 段变成可增删改的结构化对象: 每次写入前做 schema 级校验,
写入后立即 `xray run -test`, 不通过就回滚。

## 与 mihomo 版的差异

mihomo 的 dns 在 config.yaml 里, 走 YAML 解析; Xray 在 config.json 里,
走 JSON 解析。能力对等 —— 读、整体替换、按单条增删 —— 但字段名和校验
规则各自按自己的内核来, 不共用一套。

## 只碰 dns 键

config.json 里其余键 (inbounds/outbounds/routing/log) 原样保留。这里只
对 dns 这一棵子树做操作, 不做全文件的重排 —— 重排会让每次编辑都产生整篇
diff, 真正改动的那一行反而淹没在格式变化里。
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

# Xray 支持的 queryStrategy。写错时 xray -test 才会报, 这里提前拦住 ——
# 报错时机从"下次重启"提前到"执行命令的瞬间"。
QUERY_STRATEGIES = ("UseIP", "UseIPv4", "UseIPv6")

# 允许出现的顶层键。出现别的键说明理解错了 schema, 直接拒绝而不是原样
# 写进去等内核报错。
ALLOWED_TOP = {"servers", "hosts", "clientIp", "queryStrategy", "disableCache",
               "disableFallback", "disableFallbackIfMatch", "tag",
               "queryTimeout", "expectedIPs", "expectedIPsMatching"}


class DnsError(ValueError):
    """DNS 配置不合法。消息直接面向用户。"""


def _validate(obj):
    """schema 级校验。不通过抛 DnsError, 消息说明怎么改。"""
    if not isinstance(obj, dict):
        raise DnsError(f"dns 必须是一个对象, 实际是 {type(obj).__name__}")

    unknown = set(obj) - ALLOWED_TOP
    if unknown:
        raise DnsError(
            f"dns 里有 Xray 不认识的字段: {', '.join(sorted(unknown))}\n"
            f"  可用字段: {', '.join(sorted(ALLOWED_TOP))}"
        )

    qs = obj.get("queryStrategy")
    if qs is not None and qs not in QUERY_STRATEGIES:
        raise DnsError(
            f"queryStrategy 只接受 {', '.join(QUERY_STRATEGIES)}, 收到 '{qs}'"
        )

    servers = obj.get("servers")
    if servers is not None:
        if not isinstance(servers, list):
            raise DnsError(f"servers 必须是数组, 实际是 {type(servers).__name__}")
        for i, s in enumerate(servers):
            _validate_server(s, i)

    for k in ("hosts", "expectedIPs", "expectedIPsMatching"):
        v = obj.get(k)
        if v is not None and not isinstance(v, dict):
            raise DnsError(f"{k} 必须是对象, 实际是 {type(v).__name__}")

    for k in ("disableCache", "disableFallback", "disableFallbackIfMatch"):
        v = obj.get(k)
        if v is not None and not isinstance(v, bool):
            raise DnsError(f"{k} 必须是 true 或 false, 收到 '{v}'")

    qt = obj.get("queryTimeout")
    if qt is not None and not isinstance(qt, str):
        raise DnsError(f"queryTimeout 必须是字符串如 '10s', 收到 '{qt}'")

    return obj


def _validate_server(s, i):
    where = f"servers[{i}]"
    if not isinstance(s, dict):
        raise DnsError(f"{where} 必须是对象")
    if "address" not in s:
        raise DnsError(f"{where} 缺少 address (DNS 服务器地址)")
    allowed = {"address", "port", "domains", "expectIPs", "skipFallback",
               "clientIp", "tag", "timeoutMs", "queryStrategy",
               "disableCache", "finalQuery", "unexpectedIPs"}
    unknown = set(s) - allowed
    if unknown:
        raise DnsError(
            f"{where} 有不认识的字段: {', '.join(sorted(unknown))}\n"
            f"  可用字段: {', '.join(sorted(allowed))}"
        )
    for k in ("domains", "expectIPs", "unexpectedIPs", "finalQuery"):
        v = s.get(k)
        if v is not None and not isinstance(v, list):
            raise DnsError(f"{where}.{k} 必须是数组, 实际是 {type(v).__name__}")
    p = s.get("port")
    if p is not None and not isinstance(p, int):
        raise DnsError(f"{where}.port 必须是数字, 收到 '{p}'")


def load(path):
    """读出整个 config.json; 不存在时返回空骨架。"""
    if not os.path.isfile(path):
        return {"log": {"loglevel": "warning"}, "inbounds": [], "outbounds": []}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def get_dns(path):
    cfg = load(path)
    return cfg.get("dns") or {}


def write_atomic(path, cfg):
    """原子写。同目录 mkstemp + fsync + replace。

    config.json 正被 xray 加载着, 写到一半中断会留下半个 JSON, 之后每次
    启动都失败 —— 表现是"DNS 改完之后服务彻底起不来了"。
    """
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".dns-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def save(path, dns, test_cmd=None, reload_cmd=None):
    """写入 dns 段并可选校验 + 重载。

    校验不通过会恢复原文件 —— 留下一个改坏的配置比不改更糟。
    """
    _validate(dns)
    cfg = load(path)
    had_dns = "dns" in cfg
    prev = cfg.get("dns")

    if dns:
        cfg["dns"] = dns
    else:
        cfg.pop("dns", None)

    bak = None
    if os.path.isfile(path):
        bak = path + ".dns-bak"
        shutil.copy2(path, bak)
    try:
        write_atomic(path, cfg)
    except (OSError, TypeError) as e:
        if bak:
            try:
                shutil.copy2(bak, path)
                os.unlink(bak)
            except OSError:
                pass
        raise DnsError(f"写入失败: {e}")

    if test_cmd:
        r = subprocess.run(test_cmd, shell=isinstance(test_cmd, str),
                           capture_output=True, text=True)
        if r.returncode != 0:
            if bak:
                shutil.copy2(bak, path)
                print("[信息] 配置校验未通过, 已恢复原文件", file=sys.stderr)
            else:
                if had_dns:
                    cfg["dns"] = prev
                else:
                    cfg.pop("dns", None)
                write_atomic(path, cfg)
            # 备份只在"恢复成功"之后才有意义。留着会让下次执行把上一轮的
            # 备份当成本轮的基准 —— 恢复回去的是更早的状态, 一次失败就
            # 悄悄回退了用户不止一次改动。
            if bak:
                try:
                    os.unlink(bak)
                except OSError:
                    pass
            err = (r.stderr or r.stdout or "").strip().splitlines()
            for line in err[-6:]:
                print("  " + line, file=sys.stderr)
            return False

    if bak:
        os.unlink(bak)

    if reload_cmd:
        subprocess.run(reload_cmd, shell=isinstance(reload_cmd, str),
                       capture_output=True, text=True)
    return True


def main():
    ap = argparse.ArgumentParser(description="Xray DNS 段编辑")
    ap.add_argument("--config", required=True, help="config.json 路径")
    ap.add_argument("--get", action="store_true", help="读取当前 dns 段")
    ap.add_argument("--set-json", help="整体替换 (JSON 字符串或 @file 路径)")
    # 开关而不是带值参数: 具体地址由 --server-address 给。写成带值参数会
    # 让 "--add-server" 单独使用时报 "expected one argument", 而那本来
    # 是最自然的用法 (取 --server-address 的默认值)。
    ap.add_argument("--add-server", action="store_true", help="追加/更新一条 DNS 服务器")
    ap.add_argument("--server-address", default="1.1.1.1")
    ap.add_argument("--server-port", type=int)
    ap.add_argument("--server-domains", help="指定域名的解析入口, 逗号分隔")
    ap.add_argument("--del-server", help="按 address 删除一条 DNS 服务器")
    ap.add_argument("--query-strategy", choices=QUERY_STRATEGIES)
    ap.add_argument("--no-fallback", action="store_true",
                    help="禁用 fallback —— 所有服务器都失败时不再用默认值兜底")
    ap.add_argument("--host", action="append", default=[],
                    metavar="DOMAIN=IP", help="静态解析 (可重复)")
    ap.add_argument("--test", action="store_true", help="写入后跑 xray run -test")
    ap.add_argument("--no-reload", action="store_true")
    a = ap.parse_args()

    if a.get:
        d = get_dns(a.config)
        if not d:
            print("（当前没有 dns 段，内核用内置默认解析）")
        else:
            json.dump(d, sys.stdout, ensure_ascii=False, indent=2)
            sys.stdout.write("\n")
        return 0

    # 整体替换优先; 其余是增量修改
    if a.set_json:
        raw = a.set_json
        if raw.startswith("@"):
            with open(raw[1:], encoding="utf-8") as f:
                raw = f.read()
        dns = json.loads(raw)
    else:
        dns = get_dns(a.config)

    changed = False

    if a.add_server:
        s = {"address": a.server_address}
        if a.server_port:
            s["port"] = a.server_port
        if a.server_domains:
            s["domains"] = [d.strip() for d in a.server_domains.split(",") if d.strip()]
        servers = list(dns.get("servers") or [])
        dup = next((x for x in servers if x.get("address") == s["address"]), None)
        if dup:
            dup.update(s)
        else:
            servers.append(s)
        dns["servers"] = servers
        changed = True

    if a.del_server:
        servers = [x for x in (dns.get("servers") or [])
                   if x.get("address") != a.del_server]
        if len(servers) == len(dns.get("servers") or []):
            print(f"没有找到 address={a.del_server} 的 DNS 服务器", file=sys.stderr)
            return 1
        if servers:
            dns["servers"] = servers
        else:
            dns.pop("servers", None)
        changed = True

    if a.query_strategy:
        dns["queryStrategy"] = a.query_strategy
        changed = True

    if a.no_fallback:
        dns["disableFallback"] = True
        changed = True

    if a.host:
        hosts = dict(dns.get("hosts") or {})
        for h in a.host:
            if "=" not in h:
                print(f"--host 格式应为 DOMAIN=IP, 收到 '{h}'", file=sys.stderr)
                return 1
            dom, ip = h.split("=", 1)
            hosts[dom.strip()] = ip.strip()
        dns["hosts"] = hosts
        changed = True

    if not changed and not a.set_json:
        print("没有指定任何修改操作。加 --get 查看当前配置。", file=sys.stderr)
        return 1

    test_cmd = ["xray", "run", "-test", "-c", a.config] if a.test else None
    reload_cmd = None
    if not a.no_reload:
        reload_cmd = ["systemctl", "restart", os.environ.get("XRAY_SERVICE", "xrayls")]

    if not save(a.config, dns, test_cmd, reload_cmd):
        return 1
    print(f"已更新 {a.config} 的 dns 段")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DnsError as e:
        print(f"[错误] {e}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"[错误] JSON 格式错误: {e}", file=sys.stderr)
        sys.exit(1)