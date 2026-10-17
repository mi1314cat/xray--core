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

# ---------------------------------------------------------------- 路径口径
#
# ★ 这两个默认值必须与**全项目其余部分**逐字一致, 否则症状是"节点建好了、
#   面板显示正常、就是没有分享链接 / 就是不生效" —— 最难查的一类。
#
#   实测事故 (接手审计, 沙箱复现): 本文件与 conf/mknode.sh、tools/preset_batch.sh
#   曾经默认成
#       conf  → $XRAY_BASE/configs          (内核 -confdir 读的是 $XRAY_BASE/conf)
#       元数据 → $XRAY_BASE/share/tokens     (读的是 $XRAY_BASE/out/share)
#   后果分两半, 且都不报错:
#     ① 菜单 13 建的节点落在 configs/, 内核**从来不加载**它;
#     ② 走预置路径的节点, 分享载荷构建器在 out/share 里找不到元数据 →
#        链接直接不发 (REALITY 节点尤其: 缺 pbk 就判"未发布"),
#        上下行分离的 dl_* 参数也一并消失。
#
#   为什么是 out/share 而不是 share/tokens: 读的一方有 5 处
#   (conf/share.sh / conf/node.sh / conf/share_service.sh / conf/lib/cert.sh /
#    conf/lib/share_payload.py) 早就统一在 out/share, 写的一方只有预置路径
#   这一处跑偏。改一处对齐五处, 不是反过来。
#
#   注意 share_meta 的文件是**直接**放在这个目录下的 (<tag>.json),
#   没有 tokens 子目录 —— out/share/tokens/ 是另一码事 (旧版订阅令牌存储,
#   见 conf/share.sh 的 share_migrate)。
def default_conf_dir():
    return os.environ.get("XRAY_CONF_DIR") or os.path.join(
        os.environ.get("XRAY_BASE", "/root/catmi/xray"), "conf")


def default_share_dir():
    return os.environ.get("XRAY_SHARE_DIR") or os.path.join(
        os.environ.get("XRAY_BASE", "/root/catmi/xray"), "out", "share")


# 各档位下 Xray 的监听地址
LISTEN_FOR = {ACCESS_CDN: "0.0.0.0", ACCESS_NGINX: "127.0.0.1"}

# 分享链接里对外暴露的地址。nginx 模式下用户连的是域名, 不是 127.0.0.1。
PUBLIC_HOST_SOURCE = {ACCESS_CDN: "domain", ACCESS_NGINX: "domain"}


def plan(protocol, transport, security, opts=None, tier=None):
    if not tier:
        tier = ACCESS_CDN
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

    # ---- xhttp 的 mode: 服务端**不设**, 由客户端选 ----
    #
    # ★ 这里以前会"自动纠正"成 packet-up (理由是实测 stream-up 过不了 nginx)。
    #   那个实测没错, 但**结论下错了**: 真正过不去的原因是 nginx 用了
    #   proxy_pass, 而官方文档的快速上手第 5 条写得很清楚 ——
    #     「无法穿透 Nginx 的话, 把 Nginx 的 proxy_pass 改为 grpc_pass」
    #   改成 grpc_pass 之后三种模式**全部**能过 (实测矩阵见 node_build.py 注释)。
    #   而把服务端的 mode 钉死成 packet-up, 反而把 stream-up / stream-one
    #   一起废掉了 —— 包括浏览器拨号那条路 (它的 HTTP 版本与 mode 由浏览器决定)。
    #
    #   所以现在: 服务端不写 mode (接受三种), nginx 用 grpc_pass,
    #   客户端产物里写 mode (那才是它该出现的地方)。
    #   想故意只接受某一种, 用 XHTTP_SERVER_MODE / opts["xhttp_server_mode"]。
    if tier == ACCESS_NGINX and transport == "xhttp":
        _sm = (opts.get("xhttp_server_mode") or "").strip()
        if _sm:
            nopts["xhttp_server_mode"] = _sm

    # ---- nginx 档位的 path: **不能**默认落在 "/" ----
    #
    # ★ 这一条是"按用户的方式走一遍"才暴露的 —— 而且是端到端死活不通的根因。
    #
    #   现状: 菜单 13/14/15 建 nginx 档节点时**没人问过 path**, 于是 nginx_apply
    #   拿到的是默认值 "/", 往站点里插 `location /`。而任何一个真在跑的站点
    #   都已经有 `location /` 了 (那是它的首页), nginx_apply 正确地拒绝了
    #   (插进去就是 duplicate location, nginx 直接 emerg)。
    #
    #   后果链条, 每一环单独看都"正常":
    #       节点片段写好了 → 面板显示"已写入" → 分享元数据也写了
    #       → 但没有人转发 → nginx 里没有这个 location
    #       → 客户端连 域名:443 打到的是**网站首页**
    #   (实测: 全套按用户的操作路径走下来, 屏幕上只多了一行被截断的警告,
    #    而这个节点永远不通。)
    #
    #   修法: nginx 档位下, 用户没给 path 就**自己分配一个唯一前缀**。
    #   路径本来就该是唯一的 (同一台机器上多个 xhttp 节点共用 443,
    #   靠 path 区分), 而且不可猜 —— 固定的 "/" 等于把入口写在脸上。
    #   CDN 档位不动: 那边 Cloudflare 直接回源到 xray 端口, 不经过 nginx,
    #   "/" 不冲突; 而且改它会让已经发出去的订阅链接失效。
    #
    #   显式传了 path (哪怕就是 "/") 一律尊重 —— 用户说了算。
    if (tier == ACCESS_NGINX and transport in ("ws", "httpupgrade", "xhttp", "h2")
            and not opts.get("path")):
        import secrets
        nopts["path"] = "/" + secrets.token_hex(6)
        print(f"[提示] 这条节点过 nginx, 已自动分配路径 {nopts['path']}。\n"
              f"       原因: 不分配的话路径默认是 \"/\", 往站点里插 `location /` 会和"
              f"网站首页冲突, nginx 会拒绝\n"
              f"       (duplicate location), 于是**没有人转发这个节点** —— "
              f"客户端连过去看到的是网站首页。\n"
              f"       路径同时是这条节点的入口口令, 客户端产物/订阅里已经带上它,"
              f"不用你手抄。",
              file=sys.stderr)

    # ★ 必须把解析后的 security **按位置**传进去。
    #   build() 的第三个参数才是它真正用的加密层, opts 里的 "security" 它不看 ——
    #   所以以前那句 `nopts["security"] = ...` 从来没起过任何作用, 等于没写。
    #   配合上面被清掉的证书, 产出就是一个"要 TLS 却没证书"的入站。
    fragment = node_build.build(protocol, transport, eff_security, nopts)
    # ★ 片段里可能有多个入站 (REALITY 前置 + xhttp)。前置的 tag 带 -front,
    #   而文件/分享元数据必须按**主节点**的 tag 落盘 —— 用 inbounds[0] 的 tag
    #   会让节点名字变成 xxx-front, 删节点/发链接全都对不上。
    r_tag = tag

    # ---- 分享元数据 ----
    #
    # 对外端口不是 Xray 的端口。nginx 档位下 Xray 端口只绑在 127.0.0.1,
    # 客户端连的是 nginx 的 443 —— 把 Xray 端口写进分享链接, 用户连的是
    # 一个外部访问不到的端口, 表现是"链接导入正常但永远连不上"。
    public_port = opts.get("public_port") or (443 if tier == ACCESS_NGINX else port)

    # ★ 对外地址不一定是域名。
    #   经 CDN 的节点, 客户端连的是边缘: 域名:443。
    #   直连的节点 (REALITY 上行) 客户端必须连**服务器**: IP:端口 —— 域名
    #   若在橙云后面, 它解析到 CF 的边缘, 裸 REALITY 握手在那里必失败。
    #   以前这里一律写 domain, 于是 reality-reality 的链接指向橙云域名,
    #   导入正常、一连就断, 而服务端一切正常。
    public_host = (opts.get("public_host") or "").strip() or domain

    meta = {
        "host": public_host,
        "port": public_port,
        "name": opts.get("name") or tag,
        "tier": tier,
    }
    if opts.get("split_mode") or opts.get("split"):
        meta["split"] = True
    if security == "reality":
        meta["public_key"] = opts.get("public_key")
        meta["short_id"] = opts.get("short_id", "")
        meta["fingerprint"] = opts.get("fingerprint", "chrome")
    # ★ 只要有一段是 REALITY 就要给 client-fingerprint —— 包括**只有下行**
    #   是 REALITY 的组合 (上行 TLS 经 CDN)。mihomo 见到 reality-opts
    #   (哪怕在 download-settings 里) 就要求它:
    #       REALITY is based on uTLS, please set a client-fingerprint
    #   缺了就是客户端直接连不上, 而产物看起来只差一个字段。
    elif opts.get("front_first") or (opts.get("uplink_security") or "").lower() == "reality":
        # 上行 REALITY 前置 (#4118): 片段第一个入站是 RELAITY 前置, 位置参数
        # security 是 none (xhttp 入站), 但客户端那一段要按 REALITY 生成 ——
        # 公钥/短 ID/serverName 全从 opts 带进元数据。
        if opts.get("public_key"):
            meta["public_key"] = opts["public_key"]
            meta["short_id"] = opts.get("short_id", "")
            meta["fingerprint"] = opts.get("fingerprint", "chrome")
            meta["sni"] = opts.get("sni") or domain
            # ★ 前置是 raw/reality, 而客户端**上行**是 xhttp 套在 REALITY 里。
            #   节点视图按 inbounds[0] 会得出 network=tcp 的假结论 —— 这里把
            #   真正的上行传输写进元数据, 链接与产物都以它为准。
            meta["uplink_network"] = transport
            meta["uplink_path"] = nopts.get("path") or ""
    elif (opts.get("dl_security") or "").strip().lower() == "reality":
        meta["fingerprint"] = opts.get("fingerprint", "chrome")
    # ★ 客户端产物里这一项必须是**客户端**的 encryption, 不是服务端的 decryption。
    #
    #   实测 (2026-10-16): 这两个串长得像、作用相反 ——
    #       decryption: mlkem768x25519plus.native.600s.<服务端私钥>
    #       encryption: mlkem768x25519plus.native.0rtt.<客户端公钥>
    #   以前这里写的是 opts["encryption"], 而那个值是**服务端的 decryption**
    #   (mknode 只取了那一行)。于是客户端拿着服务端私钥去握手:
    #       mihomo → proxy 0: invaild vless encryption value: …600s.…
    #       Xray   → 握手失败
    #   服务端片段完全正确, 面板上一切正常, 只有真连的时候炸。
    # ★ 服务端片段不再写 xhttp 的 mode (官方口径: 服务端同时接受三种), 所以
    #   用户在面板上选的那一项必须**落在元数据里** —— 否则它会凭空消失:
    #   分享链接又变回 auto, 分离节点的下行模式也跟着丢, 而"我明明选了 X"
    #   这件事在产物里再也看不到。客户端产物与链接都从这里取。
    if transport == "xhttp":
        _m = (opts.get("xhttp_mode") or "").strip()
        if _m:
            meta["mode"] = _m
        _dm = (opts.get("dl_mode") or "").strip()
        if _dm:
            meta["dl_mode"] = _dm
    _cli_enc = (opts.get("client_encryption") or "").strip()
    if _cli_enc:
        meta["encryption"] = _cli_enc
    elif opts.get("encryption"):
        # 只有服务端那半 (老片段 / adopt 这类拿不到客户端密钥的路径) ——
        # **宁可不写**, 也不能把服务端私钥当客户端公钥发出去。
        print("[警告] 这个节点用了 VLESS 会话加密, 但只有服务端密钥、取不到客户端那一半 ——"
              "\n"
              "       客户端产物里**不会**写 encryption。写服务端的 decryption 出去,"
              "客户端会拿着\n"
              "       服务端私钥去握手, 表现是「配置全对、就是连不上」。\n"
              "       补救: 用 菜单 13 重建这条节点 (它会在生成时同时取到两半),"
              "或手工填客户端密钥。",
              file=sys.stderr)

    # ---- ECH: 客户端产物必须拿到 ECHConfigList ----
    #
    # ★ 以前 plan() 这条路上**完全没有 ECH**: 预置⑤「CDN + ECH + 后量子」
    #   建出来的节点, 服务端片段和客户端产物里都没有任何 ECH 信息 ——
    #   说明里写着 ECH, 产物里没有, 而屏幕上看不出来。
    #
    #   更糟的是"只写 enable 不写配置"这种半吊子做法 (见 to_mihomo 的旧分支):
    #   mihomo 拿到 `ech-opts: {enable: true}` 会去自己查 DNS, 查不到就
    #   **整个节点连不上** (实测: resolve ECH config error: no ECH config
    #   found in DNS records, curl HTTP=000)。所以要么给配置, 要么说清楚。
    #
    #   取值: 本节点自己终结 TLS 且有 echServerKeys → 由服务端密钥还原;
    #         否则 (CDN 橙云终结 ECH) → 从域名的 HTTPS RR 查。
    # 片段是唯一真相: 服务端密钥从落盘的片段里读回来, 不要求调用方再报一遍
    # (报两遍就一定有一遍对不上 —— adopt() 里那条注释同理)。
    ech_keys = None
    try:
        _ibs = (fragment or {}).get("inbounds") or []
        ech_keys = (((_ibs[0].get("streamSettings") or {}).get("tlsSettings") or {})
                    .get("echServerKeys"))
    except Exception:                                       # noqa: BLE001
        ech_keys = None

    if (bool(opts.get("ech")) or bool(ech_keys)) and security == "tls":
        meta["ech"] = True
        _cl = ""
        _src = ""
        try:
            import nodes as _nodes
            _cl = _nodes.ech_config_list(ech_keys) or ""
            if _cl:
                _src = "服务端密钥"
            else:
                _cl = _nodes.ech_discover(domain or "")
                if _cl:
                    _src = "域名 HTTPS RR (CDN 边缘终结 ECH)"
        except Exception as _e:                             # noqa: BLE001
            print(f"[警告] ECH 配置取值失败: {_e}", file=sys.stderr)
        if _cl:
            meta["ech_config"] = _cl
            print(f"[信息] ECH 已启用, 配置串已写进客户端产物 ({len(_cl)} 字符, 来源: {_src})",
                  file=sys.stderr)
        else:
            print("[警告] 这个节点要开 ECH, 但取不到 ECH 配置 —— 客户端产物里"
                  "**不会**写 ECH。\n"
                  "       不写不是漏了: 实测'只写启用、不给配置'会让 mihomo 自己去查 DNS,"
                  "查不到就整条连不上\n"
                  "       (resolve ECH config error / HTTP 000) —— 比不开 ECH 糟得多。"
                  "所以这里选择让节点先能用。\n"
                  "       常见原因: 域名没有 HTTPS RR (type 65), 或本机查不了这个记录类型。\n"
                  "       补救: 在能解析该域名的机器上执行  dig +short <域名> TYPE65\n"
                  "             取出 ech= 后面那串, 手工填进客户端配置的 ech-opts.config。",
                  file=sys.stderr)
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
    if opts.get("dl_cdn"):
        # 下行也走 CDN: 产物里要能看出"这一段的地址是边缘, 不是源站"
        meta["dl_cdn"] = True
    if opts.get("dl_ech"):
        meta["dl_ech"] = True
    # ---- 自签证书的 pin ----
    # ★ 必须进 meta: 自签节点的客户端配置要靠它才能连 (Xray 26.x 已移除
    #   allowInsecure, 只剩 pinnedPeerCertSha256)。meta 是分享链接与 mihomo
    #   YAML 的共同输入 —— 不写在这里, 链接和产物都拿不到 pin, 用户拿到的
    #   是一个"证书不匹配"的节点。
    if opts.get("cert_pin"):
        meta["pinned_cert_sha256"] = opts["cert_pin"]
    if opts.get("self_signed"):
        meta["self_signed"] = True
    if opts.get("cert_file"):
        meta["cert_file"] = opts["cert_file"]

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
    if transport in ("ws", "httpupgrade", "xhttp", "h2") and nopts.get("path"):
        nginx_path = (nopts["path"] if str(nopts["path"]).startswith("/")
                      else "/" + str(nopts["path"]))

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

    return {"fragment": fragment, "meta": meta, "nginx": nginx, "errors": [],
            "tag": r_tag}


def _reality_pubkey_from_private(private_key):
    """由 REALITY 私钥推出公钥 (`xray x25519 -i <私钥>`)。推不出来返回 ""。

    服务端片段只存私钥; 而分享链接里必须有公钥 (pbk), 否则客户端连不上、
    链接也建不出来。内核本来就有这个子命令, 现推一次比要求调用方再传一遍可靠
    (传两遍就一定有一遍会漏)。
    """
    pk = (private_key or "").strip()
    if not pk:
        return ""
    import os as _os
    import re
    import shutil
    import subprocess
    for cand in (_os.path.join(_os.environ.get("XRAY_BASE", "/root/catmi/xray"), "xrayls"),
                 "xray"):
        exe = cand if _os.path.isabs(cand) else shutil.which(cand)
        if not exe or not _os.path.isfile(exe):
            continue
        try:
            out = subprocess.run([exe, "x25519", "-i", pk], capture_output=True,
                                 text=True, timeout=10).stdout
        except Exception:                                   # noqa: BLE001
            continue
        m = re.search(r'^\s*(?:Password \(PublicKey\)|Password|Public key)\s*:\s*(\S+)',
                       out, re.M)
        if m:
            return m.group(1)
    return ""


def adopt(frag_path, domain=None, tier=None, path=None, conf_dir=None,
          client_encryption=None):
    """给一个**已经写好的**片段补上分享元数据 (以及可选的 nginx 段)。

    为什么要有这条:
    `vlessecn.sh` / `vlessxhttpecn.sh` / `Reality.sh` 这三个老脚本是**自己拿
    heredoc 拼 JSON** 的, 绕过了 plan()/_write_plan()。它们建出来的节点:

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
        # ★ 服务端片段里**没有**公钥 —— 只有 privateKey 与 shortIds(列表)。
        #   公钥要用 `xray x25519 -i <privateKey>` 现推 (实测推出来的值与
        #   协议脚本自己写进分享链接的 pbk 逐字节相同)。
        #   以前这里读的是 publicKey/password —— 服务端片段里都不存在, 于是
        #   补出来的 public_key 是**空串**; 而 REAILTY 的分享链接必须有 pbk,
        #   建不出来 → 节点进不了订阅。实测: 全协议 10 个节点里, 两个
        #   REALITY 系的 (Reality / Trojan) 就是这个原因漏掉的, 而屏幕上
        #   一切正常 (协议脚本自己写的那份链接是对的, 与订阅无关)。
        _pub = rs.get("publicKey") or rs.get("password") or ""
        if not _pub:
            _pub = _reality_pubkey_from_private(rs.get("privateKey"))
        meta["public_key"] = _pub
        # shortId: 服务端存的是**列表** shortIds, 不是单个 shortId。
        # ★ 顺序很要紧: 下面那句 `meta["short_id"] = rs.get("shortId") or ""`
        #   在服务端片段上**永远是空串**, 写在后面就会把上面刚取到的值覆盖掉。
        #   (实测就是这样: public_key 补上了, short_id 仍是空 —— 而 REALITY
        #    的分享链接 sid 为空时, 客户端要么连不上要么被静默丢弃。)
        _sids = rs.get("shortIds")
        if not rs.get("shortId") and isinstance(_sids, list) and _sids:
            meta["short_id"] = _sids[0]
        else:
            meta["short_id"] = rs.get("shortId") or ""
        meta["fingerprint"] = rs.get("fingerprint") or "chrome"
    # ★ 客户端那一半的 VLESS 会话加密**推不出来** (它由 xray vlessenc 与服务端
    #   密钥成对生成), 只能由调用方给。协议脚本手里有它 (Reality.sh 的
    #   CLIENT_ENC), 以前没往这里传 —— 于是订阅里这条链接写的是
    #   `encryption=none`, 而服务端要求 ML-KEM: 客户端连上去必然失败
    #   (实测: REALITY 节点"延时测试失败 tls", 而协议脚本自己写的那份链接
    #    带着正确的 encryption, 是好的 —— 两条生成链接的路径又漂了)。
    if client_encryption:
        meta["encryption"] = client_encryption
    elif clients and clients[0].get("encryption") and clients[0]["encryption"] != "none":
        meta["encryption"] = clients[0]["encryption"]
    alpn = (ss.get("tlsSettings") or {}).get("alpn")
    if alpn:
        meta["alpn"] = alpn
    # ---- ECH: 服务端两种形态, 客户端产物都要拿到 ECHConfigList ----
    #
    # ★ 以前这里只写了一个 `meta["ech"] = True`, 而**没人消费**它能不能用。
    #   真正的后果是 mihomo 那头直接连不上 (实测见 nodes.ech_discover 的说明):
    #       ech-opts: {enable: true}  →  resolve ECH config error:
    #                                      no ECH config found in DNS records
    #   于是"开了 ECH 的节点"变成一个比不开还糟的东西 —— 用户看到的是
    #   节点坏了, 而不是"ECH 没生效"。
    #
    #   两种形态取值来源不同:
    #     · 本节点自己终结 TLS 且开了 ECH (echServerKeys) → 由服务端密钥还原;
    #     · CDN 前置 (橙云) → CDN 边缘终结, 值只能来自域名的 HTTPS RR。
    #   取不到就**明说**, 不静默降级: 静默降级正是这条链路上最难查的形态。
    ech = (ss.get("tlsSettings") or {}).get("echServerKeys")
    _want_ech = bool(ech)
    if _want_ech:
        meta["ech"] = True
        try:
            import nodes as _nodes
            _cl = _nodes.ech_config_list(ech) or ""
            if not _cl:
                _cl = _nodes.ech_discover(meta.get("host") or domain or "")
        except Exception as _e:                             # noqa: BLE001
            _cl = ""
            print(f"[警告] ECH 配置取值失败: {_e}", file=sys.stderr)
        if _cl:
            meta["ech_config"] = _cl
        else:
            print("[警告] 这个节点开了 ECH, 但取不到 ECH 配置 —— 客户端产物里只写了"
                  "「启用 ECH」而没有配置串。\n"
                  "       实测那样客户端会直接连不上 (它自己去 DNS 查不一定查得到),"
                  "比不开 ECH 更糟。\n"
                  "       取不到的原因通常是: 域名没有 HTTPS RR (type 65),"
                  "或本机查不了这个记录类型。\n"
                  "       补救: 在能解析该域名的机器上执行"
                  "  dig +short <域名> TYPE65  取 ech= 后面那串, 填进客户端配置。",
                  file=sys.stderr)
        if opts.get("dl_ech"):
            meta["dl_ech"] = True
            _dlhost = opts.get("dl_address") or ""
            try:
                import nodes as _nodes2
                _dlcl = _nodes2.ech_config_list(opts.get("dl_ech_server_keys")) or \
                        _nodes2.ech_discover(_dlhost)
            except Exception:                               # noqa: BLE001
                _dlcl = ""
            if _dlcl:
                meta["dl_ech_config"] = _dlcl
    # 老脚本建的自签节点: 从片段的 certificates 里反算 pin (adopt 没有 opts,
    # 拿不到 cert_pin, 只能从证书文件本身算)。
    _certs = (ss.get("tlsSettings") or {}).get("certificates") or []
    _cf = (_certs[0] or {}).get("certificateFile") if _certs else None
    if _cf and os.path.isfile(_cf):
        import subprocess
        try:
            _der = subprocess.run(["openssl", "x509", "-in", _cf, "-outform", "DER"],
                                  capture_output=True, timeout=15).stdout
            _pin = subprocess.run(["openssl", "dgst", "-sha256", "-hex"],
                                  input=_der, capture_output=True, timeout=15) \
                .stdout.decode().strip().split()[-1]
            # 自签才需要 pin —— 真证书客户端本来就信, 塞 pin 反而多一层耦合。
            _subj = subprocess.run(["openssl", "x509", "-in", _cf, "-noout", "-subject"],
                                   capture_output=True, text=True, timeout=15).stdout
            _iss = subprocess.run(["openssl", "x509", "-in", _cf, "-noout", "-issuer"],
                                  capture_output=True, text=True, timeout=15).stdout
            if _pin and _subj.strip() and _subj == _iss:
                meta["pinned_cert_sha256"] = _pin
                meta["self_signed"] = True
                meta["cert_file"] = _cf
        except Exception:
            pass          # 算不出来就不写, 不影响补发布本身

    if errors:
        return {"ok": False, "errors": errors}

    cdir = conf_dir or os.path.dirname(frag_path)
    # 从片段目录反推节点根目录: <root>/conf → <root>/out/share
    # (原来写的是 <root>/share/tokens, 与全项目的读取方对不上, 见文件头的路径口径)
    _root = os.path.dirname(os.path.abspath(cdir.rstrip("/")))
    sdir = os.environ.get("XRAY_SHARE_DIR") or os.path.join(_root, "out", "share")
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


def _nginx_apply_path():
    """conf/lib/nginx_apply.py 的路径; 找不到返回 None。"""
    cand = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nginx_apply.py")
    return cand if os.path.isfile(cand) else None


def _configure_nginx(r):
    """nginx 档位: 顺手把反代配好。

    ★ 为什么不是"只写片段 + 打印一行提示":
      菜单 13/15 建出来的 nginx 档节点监听在 127.0.0.1, 如果没人给它配反代,
      客户端连 域名:443 打不到任何东西 —— 而面板显示节点已建好。
      sing-box-core 在同一位置是**建完就自动配** (vless.sh:278 / vmess.sh:337)。

    ★ 为什么失败**不回滚节点** (与"一次事务、失败全回滚"的取舍不同):
      事务式落盘 (一次写片段+元数据+nginx, 失败全回滚) 的顾虑是"节点在、没人转发"的半应用状态。但 X 的发布侧
      已经有更准的一道闸 —— nodes.share_target() 对
      「只绑回环 + 没有 nginx」的节点**拒绝发布**并把原因报出来。
      所以节点留着是安全的: 它不会被发出去, 用户还能去 菜单 8→6 补站点。
      反过来回滚的代价是"nginx 没配好就完全建不出节点", 那更难用 ——
      SB 在这一步也是"留着 + 把片段打出来让人手工粘"。

    返回 (ok, 原因)。
    """
    n = r.get("nginx")
    if not n:
        return True, ""
    apy = _nginx_apply_path()
    if not apy:
        return False, "找不到 conf/lib/nginx_apply.py"
    import subprocess
    argv = [sys.executable, apy,
            "--domain", n["domain"],
            "--port", str(n["port"]),
            "--transport", n["transport"]]
    # ★ 不传 --nginx。它的默认值就是 "-t" (校验命令), 而写成
    #   ["--nginx", "-t"] 会被 argparse 当成另一个选项, 报
    #       error: argument --nginx: expected one argument
    #   —— nginx_apply.py:1359-1363 记过这个坑 (双域名那条路踩的),
    #   这段代码一直没被调用过, 于是同一个坑又埋了一遍。少传一个参数最稳。
    #
    # ★ 也**不传** --origin-tls: nginx 档位下 xray 的入站是 security:none
    #   (TLS 由 nginx 终结, 见 plan() 的 eff_security), 所以回源是**明文**。
    #   传了 --origin-tls 就是对一个明文端口说 TLS —— 502。
    #   (CDN 档位相反: 那边 xray 自己终结 TLS, cdn_auto.sh 才传 --origin-tls。
    #    同一个 flag 在两个档位含义相反, 不能照抄。)
    if n.get("path") and n["path"] != "/":
        argv += ["--path", n["path"]]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    except Exception as e:                                  # noqa: BLE001
        return False, f"调用 nginx_apply.py 失败: {e}"
    if p.returncode == 0:
        return True, ""
    detail = [ln for ln in (p.stderr or p.stdout or "").splitlines() if ln.strip()]
    if not detail:
        return False, f"退出码 {p.returncode}"
    # ★ 必须把**整段**理由带回去。
    #   原来写的是 `detail[-1]` —— 只取最后一行。而 nginx_apply.py 的拒绝
    #   理由是多行的:
    #       [错误] 该 server 块里已经有同名的 location: / —— 再插一个会让
    #              nginx 直接 emerg (duplicate location), 已拒绝, 未做任何改动。
    #              办法一 (推荐): 给这个节点单开一个前缀 ...
    #              办法二: ...
    #   取最后一行, 用户看到的就是:  "nginx 反代没配上 (       办法二: 如果...)"
    #   —— 一个左括号配不上一句话, 前后都不知所云, 而真正的原因 (同名冲突)
    #   和首选出路 (办法一) 全被丢掉了。实测时屏幕上就是这个样子。
    return False, "\n".join(detail)


def _write_plan(r, conf_dir, share_dir):
    """把 plan() 的结果落盘。config_json 路径和 CLI 参数路径共用这一份。

    单独抽出来是因为以前只有 config_json 那条路会落盘 —— CLI 参数那条路带着
    --apply 也只做预演。见调用处的注释。
    """
    import share_meta
    conf_dir = conf_dir or default_conf_dir()
    share_dir = share_dir or default_share_dir()
    os.makedirs(conf_dir, exist_ok=True)
    os.makedirs(share_dir, exist_ok=True)
    tag = r.get("tag") or r["fragment"]["inbounds"][0]["tag"]
    node_build.write(os.path.join(conf_dir, f"{tag}.json"), r["fragment"])
    share_meta.save(share_dir, tag, r["meta"])
    ib = r["fragment"]["inbounds"][0]
    print(f"已写入片段: {conf_dir}/{tag}.json", file=sys.stderr)
    print(f"已写入分享元数据: {share_dir}/{tag}.json", file=sys.stderr)
    print(f"监听: {ib['listen']}:{ib['port']}", file=sys.stderr)
    print(f"对外: {r['meta']['host']}:{r['meta']['port']}  ({r['meta']['tier']})", file=sys.stderr)
    _emit_products(r, conf_dir, share_dir, tag)

    if r.get("nginx"):
        ok, why = _configure_nginx(r)
        n = r["nginx"]
        if ok:
            print(f"已配置 nginx 反代: {n['domain']}{'' if n.get('path') in (None, '/') else n['path']}"
                  f" → 127.0.0.1:{n['port']}", file=sys.stderr)
        else:
            # 节点**保留** —— 见 _configure_nginx 的说明。
            #
            # ★ why 可能是多行 (nginx_apply.py 的拒绝理由本来就是一段话)。
            #   不能塞进括号里 —— 换行会把括号撑成"左括号 + 半句话"。
            #   第一行当标题, 其余原样缩进贴出来。
            import textwrap
            _first, _, _rest = why.partition("\n")
            print("", file=sys.stderr)
            print(f"[警告] nginx 反代没配上: {_first}", file=sys.stderr)
            if _rest.strip():
                print(textwrap.indent(_rest.strip(), "       "), file=sys.stderr)
            print(f"        这个节点监听 127.0.0.1:{n['port']}, 现在**外部访问不到**。", file=sys.stderr)
            print(f"        去 菜单 8) 服务与配置 → 6) Nginx 站点管理 给它补一个站点,", file=sys.stderr)
            print(f"        或先建好 {n['domain']} 的站点与证书再重建本节点。", file=sys.stderr)
            print("        在配上之前, 它不会被发到订阅里 (发布侧会拒发并说明原因)。", file=sys.stderr)
    return True


def _emit_products(r, conf_dir, share_dir, tag):
    """客户端产物 + nginx 档位的补齐提示。两条落盘路径共用。"""
    import os
    # ---- 客户端产物 ----
    # ★ 建节点就必须产出 mihomo YAML, 不是"以后想看再转"。
    #   预置路径 (菜单 13/14/15) 原来一份 out/ 产物都没有 —— 用户建完节点
    #   手上只有服务端片段, 客户端那份得自己按文档拼, 而 xhttp 的
    #   download-settings 是两段式、逐项覆盖语义, 手拼必错。
    #   上下行分离尤其: 它**只存在于服务端配置里**, 不落成产物就没人记得
    #   这个节点是分离的。
    #
    #   生成不出来时**必须说出来** —— 静默少一个文件正是本项目既往缺陷的
    #   共同形态 (见 conf/lib/to_mihomo.py 的 _why_unsupported)。
    out_dir = os.environ.get("XRAY_OUT_DIR") or os.path.join(
        os.path.dirname(os.path.abspath(conf_dir.rstrip("/"))), "out")
    try:
        import to_mihomo
        p, why = to_mihomo.write_products(
            r["fragment"], r["meta"], out_dir, name=r["meta"].get("name"), tag=tag)
        if p:
            print(f"已写入客户端产物: {p}", file=sys.stderr)
        else:
            print(f"[信息] 没生成 mihomo YAML —— {why}", file=sys.stderr)
    except Exception as e:                                  # noqa: BLE001
        # 产物生成失败**不能**让节点创建失败: 服务端片段已经落盘了, 报错退出
        # 会让用户以为节点没建成, 于是重建一次 —— 结果多出一个节点。
        print(f"[警告] 生成 mihomo YAML 时出错 (节点本身已建好): {e}", file=sys.stderr)


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
    # ★ 默认必须是 None, 不能是 ACCESS_CDN。
    #   --adopt 要按片段自己判断档位 (监听 127.0.0.1 就是 nginx 档), 而
    #   argparse 的 default 会**悄悄覆盖**那个判断: 于是 nginx 档节点被补成
    #   tier=cdn, 发布侧按"绑回环又没 nginx"拒发 —— 节点在, 却永远进不了订阅。
    #   plan() 那边收到 None 时自己兜成 cdn, 行为不变。
    ap.add_argument("--tier", default=None, choices=[ACCESS_CDN, ACCESS_NGINX])
    ap.add_argument("--password")
    ap.add_argument("--uuid")
    ap.add_argument("--method")
    ap.add_argument("--path")
    ap.add_argument("--config-json", help="整份 opts 以 JSON 传入 (给 conf/mknode.sh 用, "
                                          "避免在 bash 里拼 JSON —— 引号地狱)")
    ap.add_argument("--conf-dir", help="片段输出目录 (默认 $XRAY_CONF_DIR 或 $XRAY_BASE/conf)")
    ap.add_argument("--share-dir", help="分享元数据目录 (默认 $XRAY_SHARE_DIR 或 $XRAY_BASE/out/share)")
    ap.add_argument("--apply", action="store_true", help="直接落盘而不只是预演")
    ap.add_argument("--client-encryption",
                    help="客户端那一半的 VLESS 会话加密串 (协议脚本手里有, 推不出来)")
    ap.add_argument("--cert-file")
    ap.add_argument("--key-file")
    a = ap.parse_args()

    # ---- --adopt: 补发布 ----
    if a.adopt:
        r = adopt(a.adopt, domain=a.domain, tier=a.tier, path=a.path,
                  client_encryption=a.client_encryption)
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
