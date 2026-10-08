#!/usr/bin/env python3
"""部署规划 —— 一次生成节点所需的全部东西, 且保证彼此对得上。

## 为什么不是"生成节点"就够了

一个节点要能用, 需要三样东西同时存在且互相指向:

    片段      conf/<tag>.json, Xray 真正加载的
    分享元数据 对外地址/端口/公钥, 分享链接与订阅靠它
    nginx 站点 nginx 模式下的反代配置, 让 CDN 回源打到正确的端口

这���样东西如果分三次做, 就会出现"节点建好了但 nginx 没配"(用户手上链接
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
    if not domain:
        errors.append("缺少域名 (分享链接与 nginx 配置都要用)")

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

    # nginx 模式下 Xray 只听本机, 不需要自己终结 TLS
    if tier == ACCESS_NGINX:
        nopts["security"] = None if security == "none" else security

    fragment = node_build.build(protocol, transport, security, nopts)

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

    # ---- nginx ----
    nginx = None
    if tier == ACCESS_NGINX:
        nginx = {
            "domain": domain,
            "port": port,
            "public_port": public_port,
            "transport": transport,
            "cdn": False,          # nginx 模式已经是"经过 CDN 之后"的形态
        }

    return {"fragment": fragment, "meta": meta, "nginx": nginx, "errors": []}


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


def describe(protocol, transport, security, tier):
    t = {"cdn": "CDN 直连", "nginx": "Nginx 转发"}.get(tier, tier)
    return f"{node_build.describe(protocol, transport, security)} · {t}"


if __name__ == "__main__":
    # 规划预演: 不写盘, 只看方案是否可行
    import argparse
    import json

    ap = argparse.ArgumentParser(description="节点部署规划预演")
    ap.add_argument("--protocol", required=True)
    ap.add_argument("--transport", required=True)
    ap.add_argument("--security", required=True)
    ap.add_argument("--port", type=int, help="Xray 监听端口")
    ap.add_argument("--public-port", type=int, help="对外端口, nginx 档位默认 443")
    ap.add_argument("--domain")
    ap.add_argument("--tag")
    ap.add_argument("--tier", default=ACCESS_CDN, choices=[ACCESS_CDN, ACCESS_NGINX])
    ap.add_argument("--password")
    ap.add_argument("--uuid")
    ap.add_argument("--method")
    ap.add_argument("--path")
    ap.add_argument("--cert-file")
    ap.add_argument("--key-file")
    a = ap.parse_args()

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

    print(f"  {describe(a.protocol, a.transport, a.security, a.tier)}")
    print(f"  Xray 监听: {r['fragment']['inbounds'][0]['listen']}:{r['fragment']['inbounds'][0]['port']}")
    print(f"  对外地址: {r['meta']['host']}:{r['meta']['port']}")
    if r["nginx"]:
        print(f"  nginx: 站点 {r['nginx']['domain']} → 127.0.0.1:{r['nginx']['port']} ({r['nginx']['transport']})")
    else:
        print("  nginx: 不需要 (CDN 直接回源)")
    print("  片段:")
    print(json.dumps(r["fragment"], ensure_ascii=False, indent=4).replace("\n", "\n  "))
