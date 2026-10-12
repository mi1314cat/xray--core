#!/usr/bin/env python3
"""部署规划 —— 一次生成节点所需的全部东西, 且保证彼此对得上。

## 为什么不是"生成节点"就够了

一个节点要能用, 需要三样东西同时存在且互相指向:

    片段      conf/<tag>.json, Xray 真正加载的
    分享元数据 对外地址/端口/公钥, 分享链接与订阅靠它
    nginx 站点 nginx 模式下的反代配置, 让 CDN 回源打到正确的端口

这样的东西如果分三次做, 就会出现"节点建好了但 nginx 没配"(用户手上链接
连不上)、"nginx 配好了但端口是别的节点的"(流量打到错的入站)、"改了端口
忘了改 nginx"(最常见)。

所以这里把它们绑成一次规划: 输入一份规格, 输出三样, 端口与域名只在一处
出现, 不可能对不上。

## 接入档位

    cdn     监听 0.0.0.0, Cloudflare 直接回源到端口, 不需要 nginx
    nginx   监听 127.0.0.1, 由 nginx 统一入口转发

CDN 档位下 Xray 绑定 0.0.0.0 是必须的 —— 只绑 127.0.0.1 的话 Cloudflare
回源直接被拒, 而面板显示一切正常。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import node_build  # noqa: E402

ACCESS_CDN = "cdn"
ACCESS_NGINX = "nginx"

# 各档位下 Xray 的监听地址
LISTEN_FOR = {ACCESS_CDN: "0.0.0.0", ACCESS_NGINX: "127.0.0.1"}

# 分享链接里对外暴露的地址。nginx 模式下用户连的是域名, 不是 127.0.0.1。
PUBLIC_HOST_SOURCE = {ACCESS_CDN: "domain", ACCESS_NGINX: "domain"}


def plan(protocol, transport, security, opts=None, tier=ACCESS_CDN):
    """生成完整部署方案。

    返回 dict:
        fragment   写进 conf/<tag>.json 的内容
        meta       写进 SHARE_DIR/<tag>.json 的内容
        nginx      nginx 模式下的站点配置参数; cdn 模式为 None
        errors     规划阶段发现的问题 (空列表表示可行)
    """
    opts = dict(opts or {})
    errors = []

    if tier not in LISTEN_FOR:
        errors.append(f"未知接入档位: {tier} (可选 {ACCESS_CDN} / {ACCESS_NGINX})")
        tier = ACCESS_CDN

    port = opts.get("port")
    domain = opts.get("domain") or opts.get("sni")
    tag = opts.get("tag") or f"{protocol}-{transport}-{security}"

    # ---- 校验: 在生成之前把话说清楚 ----
    if not port:
        errors.append("缺少端口")
    # 域名只在两处真正需要: TLS 要证书 (nginx 档则是 nginx 要), nginx 档要
    # 挂站点。security=none 时两处都不需要 —— 无证书、无反代, 对外地址就是
    # 公网 IP。之前无条件要求域名, 于是 "shadowsocks + 裸 TCP + 无加密"
    # 这个完全合法的组合永远建不出来, 而且报错说的是"缺少域名", 与用户
    # 实际遇到的问题 (他压根不知道要域名) 无关。
    if not domain and (security == "tls" or tier == ACCESS_NGINX):
        errors.append("缺少域名 (TLS 要证书, nginx 档要挂站点)")

    # CDN 档位要求传输层能被 CDN 代理。
    # 裸 TCP / REALITY 走 CDN 是可行的 (Cloudflare 支持 Spectrum, 但那是
    # 付费档), 而默认的免费橙云只代理 HTTP(S) —— WS/gRPC/XHTTP 可以,
    # 裸 TCP 会被 Cloudflare 直接拒掉。这是最常见的"配置全对但连不上"。
    if tier == ACCESS_CDN and transport in ("tcp", "raw") and security == "none":
        errors.append(
            "CDN 档位下裸 TCP + 无加密不可用: Cloudflare 橙云只代理 HTTP(S), "
            "裸 TCP 会被直接拒绝。改用 WS/gRPC/XHTTP, 或切到 nginx 档位。"
        )

    # nginx 档位下, Xray 不直接对外, 所以它自己不需要证书 ——
    # 证书由 nginx 终结。给 Xray 配证书只是多一处要维护的东西。
    if tier == ACCESS_NGINX and opts.get("cert_file"):
        opts["cert_file"] = None
        opts["key_file"] = None

    if errors:
        return {"fragment": None, "meta": None, "nginx": None, "errors": errors}

    listen = LISTEN_FOR[tier]
    nopts = dict(opts)
    nopts["listen"] = listen
    nopts["tag"] = tag

    # nginx 模式下 Xray 只听本机, 不需要自己终结 TLS —— 证书在 nginx 手里。
    #
    # ★ 这里以前写的是 `None if security == "none" else security`, 也就是
    #   security 本来就是 none 时才置空, 而 tls 档位原样保留。配上上面刚被清掉的
    #   cert_file/key_file, 就得到一个**有 TLS 但没有证书**的入站:
    #       http: TLS handshake error: tls: no certificates configured
    #   片段还过得了 `xray -test` (它不校验证书在不在), 面板也一切正常, 只有真连
    #   的时候才炸 —— 而 nginx 档位是所有 WS 类节点的默认档位, 等于菜单 13/14
    #   建出来的 nginx 节点一个都连不上。
    #   现在按注释里原本的意图执行: 证书谁终结, 谁用 security。
    #   只动 tls: REALITY 的握手是 xray 自己做的, 不在这个结论覆盖范围内, 不动它。
    eff_security = "none" if (tier == ACCESS_NGINX and security == "tls") else security

    # ★ 必须把解析后的 security **按位置**传进去。
    #   build() 的第三个参数才是它真正用的加密层, opts 里的 "security" 它不看 ——
    #   所以以前那句 `nopts["security"] = ...` 从来没起过任何作用, 等于没写。
    #   配合上面被清掉的证书, 产出就是一个"要 TLS 却没证书"的入站。
    fragment = node_build.build(protocol, transport, eff_security, nopts)

    # ---- 分享元数据 ----
    #
    # 对外端口不是 Xray 的端口。nginx 档位下 Xray 端口只绑在 127.0.0.1,
    # 客户端连的是 nginx 的 443 —— 把 Xray 端口写进分享链接, 用户连的是
    # 一个外部访问不到的端口, 表现是"链接导入正常但永远连不上"。
    public_port = opts.get("public_port") or (443 if tier == ACCESS_NGINX else port)

    meta = {
        "host": domain,
        "port": public_port,
        "name": opts.get("name") or tag,
        "tier": tier,
    }
    if security == "reality":
        meta["public_key"] = opts.get("public_key")
        meta["short_id"] = opts.get("short_id", "")
        meta["fingerprint"] = opts.get("fingerprint", "chrome")
    if opts.get("encryption"):
        meta["encryption"] = opts["encryption"]
    if opts.get("alpn"):
        meta["alpn"] = opts["alpn"]
    if opts.get("path"):
        meta["host_header"] = opts.get("host") or domain

    # ---- 上下行分离 ----
    #
    # ★ 这里原来**完全没写** dl_* —— 于是 share_meta 里查无此项, 分享链接
    #   也就发不出下行参数。客户端导入后拿到的是一个"看着普通"的节点:
    #   连得上、能跑, 只是**没有下行分离**, 而这正是这个节点存在的理由。
    #   症状是完全静默的 —— 用户不会收到任何报错, 只是下行没走预期那条路。
    #
    #   写全: 地址/加密层/模式/path 一律要。下行 REALITY 还要它自己的
    #   serverName 与公钥短 id (上下行是两套凭据, 不能默认复用上行那套 ——
    #   上行可能是 TLS, 压根没有 REALITY 参数可复用)。
    dl_addr = (opts.get("dl_address") or "").strip()
    if dl_addr:
        meta["dl_address"] = dl_addr
        meta["dl_port"] = int(opts.get("dl_port") or port)   # 会话表 per-inbound, 必须同端口
        meta["dl_security"] = opts.get("dl_security") or security
        meta["dl_mode"] = opts.get("dl_mode") or "stream-up"
        meta["dl_path"] = opts.get("path") or "/"
        # 回源 SNI 用下行自己的; 没有就沿用上行 (共用域名是正常用法)
        meta["dl_sni"] = (opts.get("dl_sni") or opts.get("sni") or domain)
        if meta["dl_security"] == "reality":
            meta["dl_public_key"] = opts.get("dl_public_key") or ""
            meta["dl_short_id"] = opts.get("dl_short_id") or ""
        # 客户端拿哪个地址连下行: 域名走 CDN, IP/其他是直连
        meta["dl_domain"] = opts.get("dl_domain") or dl_addr
    if opts.get("dl_ech"):
        meta["dl_ech"] = True

    # ---- nginx ----
    #
    # ★ location 用**节点自己的 path**, 不再一律写 `location /`:
    #   1. 站点里几乎一定有 `location /` (首页/伪静态/acme), 再插一个同名
    #      location 会让 nginx 直接 `duplicate location "/"` —— 旧的写法在
    #      这类站点上**永远配不进去**, 而且报的是一句看不懂的回滚;
    #   2. `location /` 会把整个站点的流量吸到这个节点上, 用户在同域名下的
    #      网站就没了;
    #   3. 精确到 path 之后, 同一个域名下的多个节点可以各占一条, 删一个也
    #      不会把另一个带走 —— mihomo 的 CDN 集成就是按节点 path 渲染 location。
    #   只对"path 真的是 URI 路径"的传输这么做: ws / httpupgrade / xhttp / h2。
    #   grpc 的 serviceName 不是路径 (且 gRPC 过 nginx 需要 grpc_pass, 是另一
    #   件事), tcp/raw 根本没有 path —— 这两种仍用 `/`, 由 nginx_apply 的
    #   同名检查兜底报错。
    nginx_path = "/"
    if transport in ("ws", "httpupgrade", "xhttp", "h2") and opts.get("path"):
        nginx_path = opts["path"] if str(opts["path"]).startswith("/") else "/" + str(opts["path"])

    nginx = None
    if tier == ACCESS_NGINX:
        nginx = {
            "domain": domain,
            "port": port,
            "public_port": public_port,
            "transport": transport,
            "path": nginx_path,
            "cdn": False,          # nginx 模式已经是"经过 CDN 之后"的形态
        }

    return {"fragment": fragment, "meta": meta, "nginx": nginx, "errors": []}


def adopt(frag_path, domain=None, tier=None, path=None, conf_dir=None):
    """给一个**已经写好的**片段补上分享元数据 (以及可选的 nginx 段)。

    为什么要有这条:
    `vlessecn.sh` / `vlessxhttpecn.sh` / `Reality.sh` 这三个老脚本是**自己拿
    heredoc 拼 JSON** 的, 绕过了 plan()/apply_plan()。它们建出来的节点:

      * 没有分享元数据 → **没有分享链接、不进订阅**
      * 没有校验       → 配错了面板也不知道
      * 没有 nginx 段  → CDN 档位下回源直接 502

    第三条最容易漏: 用户从菜单 5/6/7 建完节点, 面板上一片正常, 但客户端
    连不上 —— 因为没人给这个节点挂 nginx location。

    这里不去改那三个脚本怎么**建**节点 (那是它们自己的交互流程, 重写风险大),
    只在它们写完之后调用一次本函数, 把"发布"这一步补齐。
    于是新老两条入口建出来的节点**待遇一致**: 都有链接、都进订阅、都配 nginx。

    片段是**唯一真相**: 协议/传输/加密层/端口/UUID 全部从里面读回来, 不要求
    调用方再报一遍 —— 报两遍就一定会有一遍对不上。
    """
    import json

    try:
        with open(frag_path, "r", encoding="utf-8") as f:
            frag = json.load(f)
    except Exception as e:
        return {"ok": False, "errors": [f"读不了片段 {frag_path}: {e}"]}

    inbounds = frag.get("inbounds") or []
    if not inbounds:
        return {"ok": False, "errors": ["片段里没有 inbound"]}
    ib = inbounds[0]

    protocol = ib.get("protocol")
    ss = ib.get("streamSettings") or {}
    transport = ss.get("network") or "tcp"
    security = ss.get("security") or "none"
    port = ib.get("port")
    tag = ib.get("tag") or os.path.basename(frag_path)[:-5]

    xh = ss.get("xhttpSettings") or {}
    xpath = xh.get("path")
    if xpath and not xpath.endswith("/"):
        xpath += "/"

    settings = ib.get("settings") or {}
    clients = settings.get("clients") or []
    uuid = clients[0].get("id") if clients else None

    errors = []
    if not protocol:
        errors.append("片段里没有 protocol")
    if not port:
        errors.append("片段里没有监听端口")

    # 域名: 调用方给的优先, 否则从 serverName / host 兜底
    dom = domain or ss.get("serverName") or (ss.get("tlsSettings") or {}).get("serverName")

    # 档位: 调用方给的优先, 否则从 listen 推断
    t = tier
    if not t:
        listen = ib.get("listen")
        t = ACCESS_NGINX if listen in ("127.0.0.1", "::1") else ACCESS_CDN

    # 分享链接里要对外暴露的端口: nginx 档位下是 443, 不是 Xray 的端口
    public_port = 443 if t == ACCESS_NGINX else port

    meta = {
        "host": dom or "127.0.0.1",
        "port": public_port,
        "name": tag,
        "tier": t,
        "tag": tag,
        "schema": 1,
    }
    if path or xpath:
        meta["host_header"] = dom or meta["host"]
    if security == "reality":
        rs = ss.get("realitySettings") or {}
        meta["public_key"] = rs.get("publicKey") or rs.get("password") or ""
        meta["short_id"] = rs.get("shortId") or ""
        meta["fingerprint"] = rs.get("fingerprint") or "chrome"
    if clients and clients[0].get("encryption") and clients[0]["encryption"] != "none":
        meta["encryption"] = clients[0]["encryption"]
    alpn = (ss.get("tlsSettings") or {}).get("alpn")
    if alpn:
        meta["alpn"] = alpn
    ech = (ss.get("tlsSettings") or {}).get("echServerKeys")
    if ech:
        meta["ech"] = True

    if errors:
        return {"ok": False, "errors": errors}

    cdir = conf_dir or os.path.dirname(frag_path)
    sdir = os.path.join(os.path.dirname(cdir.rstrip("/")), "share", "tokens")
    import share_meta
    share_meta.save(sdir, tag, meta)

    # 上下行分离的老节点: 把 downloadSettings 一并带进元数据, 否则发出去的
    # 链接里没有下行参数, 客户端导入后就是个"看着正常但没分离"的节点。
    dl = xh.get("downloadSettings")
    if dl and dl.get("address"):
        import nodes as _nodes
        _ = _nodes.split_params(frag, meta)   # 兜底路径: 走 fragments 也能导出

    return {"ok": True, "tag": tag, "meta_path": share_meta.meta_path(sdir, tag),
            "errors": [], "tier": t, "domain": dom}


def apply_plan(result, conf_dir, share_dir, nginx_apply=None, nginx_bin="-t"):
    """把方案落到磁盘。

    nginx 配置放最后, 但它失败时**回滚前两步**。只做"前面失败不动后面"是不够
    的 —— 反过来的半应用状态更糟: 片段在、分享元数据在、nginx 没配, 于是节点
    存在但没人转发流量, 用户拿到一个连不上的分享链接, 而面板显示一切正常。
    """
    if result["errors"]:
        return False

    tag = result["fragment"]["inbounds"][0]["tag"]
    frag_path = os.path.join(conf_dir, f"{tag}.json")
    import share_meta
    meta_existed = os.path.exists(share_meta.meta_path(share_dir, tag))
    meta_before = share_meta.load(share_dir, tag) if meta_existed else None

    node_build.write(frag_path, result["fragment"])
    share_meta.save(share_dir, tag, result["meta"])

    if not (result["nginx"] and nginx_apply):
        return True

    import subprocess
    n = result["nginx"]
    argv = [sys.executable, nginx_apply,
            "--domain", n["domain"],
            "--port", str(n["port"]),
            "--transport", n["transport"],
            "--nginx", nginx_bin]
    # 插入与摘除必须用**同一个 path**, 否则摘的时候按 `域名|/prefix` 找不到
    # 当初按 `域名` 插进去的那段 —— 删除要精确, 前提就是标识一致。
    if n.get("path") and n["path"] != "/":
        argv += ["--path", n["path"]]
    r = subprocess.run(argv, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, file=sys.stderr)
        print(r.stderr, file=sys.stderr)

        # 回滚前两步, 不留半应用状态
        try:
            os.unlink(frag_path)
            if meta_existed:
                if meta_before is not None:
                    share_meta.save(share_dir, tag, meta_before)
            else:
                share_meta.purge(share_dir, tag)
        except OSError as e:
            print(f"回滚失败, 请手工清理: {e}", file=sys.stderr)
        print("[信息] nginx 配置未生效, 已回滚节点与分享元数据", file=sys.stderr)
        print("      常见原因: 该域名还没有 nginx 站点文件。"
              "先建站点并配好证书, 再执行本步骤。", file=sys.stderr)
        return False
    return True


def _print_plan(r, protocol, transport, security, tier):
    """打印预演结果。两条入口共用, 免得预演和实际落盘的呈现不一致 ——
    用户在预演里看到的和最后落盘的不是一回事, 那预演就没有意义。"""
    print(f"  {describe(protocol, transport, security, tier)}")
    ib = r["fragment"]["inbounds"][0]
    print(f"  Xray 监听: {ib['listen']}:{ib['port']}")
    print(f"  对外地址: {r['meta']['host']}:{r['meta']['port']}")
    if r["nginx"]:
        print(f"  nginx: 站点 {r['nginx']['domain']} → 127.0.0.1:{r['nginx']['port']}"
              f" ({r['nginx']['transport']})")
    else:
        print("  nginx: 不需要 (CDN 直接回源)")
    print("  片段:")
    print(json.dumps(r["fragment"], ensure_ascii=False, indent=4).replace("\n", "\n  "))


def describe(protocol, transport, security, tier):
    t = {"cdn": "CDN 直连", "nginx": "Nginx 转发"}.get(tier, tier)
    return f"{node_build.describe(protocol, transport, security)} · {t}"


def _write_plan(r, conf_dir, share_dir):
    """把 plan() 的结果落盘。config_json 路径和 CLI 参数路径共用这一份。

    单独抽出来是因为以前只有 config_json 那条路会落盘 —— CLI 参数那条路带着
    --apply 也只做预演。见调用处的注释。
    """
    import share_meta
    conf_dir = conf_dir or os.environ.get("XRAY_CONF_DIR", "/root/catmi/xray/configs")
    share_dir = share_dir or os.environ.get("XRAY_SHARE_DIR", "/root/catmi/xray/share/tokens")
    os.makedirs(conf_dir, exist_ok=True)
    os.makedirs(os.path.dirname(share_dir) or share_dir, exist_ok=True)
    tag = r["fragment"]["inbounds"][0]["tag"]
    node_build.write(os.path.join(conf_dir, f"{tag}.json"), r["fragment"])
    share_meta.save(share_dir, tag, r["meta"])
    ib = r["fragment"]["inbounds"][0]
    print(f"已写入片段: {conf_dir}/{tag}.json", file=sys.stderr)
    print(f"已写入分享元数据: {share_dir}/{tag}.json", file=sys.stderr)
    print(f"监听: {ib['listen']}:{ib['port']}", file=sys.stderr)
    print(f"对外: {r['meta']['host']}:{r['meta']['port']}  ({r['meta']['tier']})", file=sys.stderr)
    if r["nginx"]:
        print(f"提示: nginx 档位还需配置反代 "
              f"{r['nginx']['domain']} → 127.0.0.1:{r['nginx']['port']}", file=sys.stderr)


if __name__ == "__main__":
    # 规划预演: 不写盘, 只看方案是否可行
    import argparse
    import json

    ap = argparse.ArgumentParser(description="节点部署规划预演")
    ap.add_argument("--adopt", metavar="片段路径",
                    help="给一个已经写好的片段补分享元数据 (老脚本用)")
    ap.add_argument("--protocol")
    ap.add_argument("--transport")
    ap.add_argument("--security")
    ap.add_argument("--port", type=int, help="Xray 监听端口")
    ap.add_argument("--public-port", type=int, help="对外端口, nginx 档位默认 443")
    ap.add_argument("--domain")
    ap.add_argument("--tag")
    ap.add_argument("--tier", default=ACCESS_CDN, choices=[ACCESS_CDN, ACCESS_NGINX])
    ap.add_argument("--password")
    ap.add_argument("--uuid")
    ap.add_argument("--method")
    ap.add_argument("--path")
    ap.add_argument("--config-json", help="整份 opts 以 JSON 传入 (给 conf/mknode.sh 用, "
                                          "避免在 bash 里拼 JSON —— 引号地狱)")
    ap.add_argument("--conf-dir", help="片段输出目录 (默认 /root/catmi/xray/configs)")
    ap.add_argument("--share-dir", help="分享元数据目录 (默认 .../share/tokens)")
    ap.add_argument("--apply", action="store_true", help="直接落盘而不只是预演")
    ap.add_argument("--cert-file")
    ap.add_argument("--key-file")
    a = ap.parse_args()

    # ---- --adopt: 补发布 ----
    if a.adopt:
        r = adopt(a.adopt, domain=a.domain, tier=a.tier, path=a.path)
        if r["ok"]:
            print(f"[OK] 已补分享元数据: {r['meta_path']}", file=sys.stderr)
            print(f"[信息] tag={r['tag']} 档位={r['tier']}", file=sys.stderr)
        else:
            for e in r["errors"]:
                print(f"[错误] {e}", file=sys.stderr)
        raise SystemExit(0 if r["ok"] else 1)


    # 整份 JSON 优先: 字段比一长串命令行参数更不容易出错
    if a.config_json:
        raw = a.config_json
        if raw.startswith("@"):
            with open(raw[1:], encoding="utf-8") as f:
                raw = f.read()
        spec = json.loads(raw)
        protocol = spec.pop("protocol")
        transport = spec.pop("transport")
        security = spec.pop("security")
        tier = spec.pop("tier", a.tier)
        opts = {k: v for k, v in spec.items() if v is not None}
        r = plan(protocol, transport, security, opts, tier)
        if r["errors"]:
            print("不可行:", file=sys.stderr)
            for e in r["errors"]:
                print("  - " + e, file=sys.stderr)
            sys.exit(1)
        if a.apply:
            _write_plan(r, a.conf_dir, a.share_dir)
            sys.exit(0)
        _print_plan(r, protocol, transport, security, tier)
        sys.exit(0)

    # 走命令行参数时三者仍必填 (argparse 的 required 已放开, 因为 JSON
    # 路径不需要它们)
    missing = [n for n, v in (("--protocol", a.protocol),
                              ("--transport", a.transport),
                              ("--security", a.security)) if not v]
    if missing:
        ap.error(f"缺少必填参数: {', '.join(missing)} (或用 --config-json 整份传入)")

    opts = {k: v for k, v in {
        "port": a.port, "public_port": a.public_port, "domain": a.domain, "tag": a.tag, "password": a.password,
        "uuid": a.uuid, "method": a.method, "path": a.path,
        "sni": a.domain, "cert_file": a.cert_file, "key_file": a.key_file,
    }.items() if v is not None}

    r = plan(a.protocol, a.transport, a.security, opts, a.tier)
    if r["errors"]:
        print("不可行:", file=sys.stderr)
        for e in r["errors"]:
            print("  - " + e, file=sys.stderr)
        sys.exit(1)
    # ★ 这条路以前**忽略** --apply, 直接掉进预演: 传了 --apply 却什么都不写,
    #   而且一句错都不报。调用方 (包括我自己写的验收测试) 于是以为建好了,
    #   下一句去读文件才发现根本没有 —— 错位很远, 极难往回想。
    #   成因是 --apply 那段被写在了 `if a.config_json:` 里面, 只有 JSON 路径够得着。
    if a.apply:
        _write_plan(r, a.conf_dir, a.share_dir)
        sys.exit(0)
    _print_plan(r, a.protocol, a.transport, a.security, a.tier)
