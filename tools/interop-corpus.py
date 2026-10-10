#!/usr/bin/env python3
"""三家互通 · 测试语料生成器 —— 造一组"覆盖各协议×传输×加密"的 Xray 片段。

用法:
    python3 tools/interop-corpus.py <目标目录> [--host 127.0.0.1]

产出 <目标目录>/conf/*.json 与 <目标目录>/out/share/*.json（分享元数据），
供 tools/interop-e2e.sh 端到端使用。**只在临时目录里用**, 不要指向生产路径。

语料刻意包含四类边界（每类都对应一个"看起来正常其实错了"的失效）:
  · 只绑回环又没 nginx  → 两条产品都必须**不发**（URI 路径是发布闸门）
  · socks               → 可发布但没有原生表达 → 必须报出来, 不许静默少一个
  · ECH / xhttp mode / grpc serviceName / 证书 pin → URI 装不下, 原生必须带上
  · ss + reality        → ss:// 物理上装不下 reality（uri-representation.md §2）
                          → 原生必须比普通话**多**（这正是原生路径的意义）
"""

import argparse
import json
import os

# 真值对（RN 生产 vless-xhttp08, 184 字符）: 用 `xray tls ech -i <keys>` 现验过 ——
# 本文件里的 echServerKeys 与 client 端的 echConfigList 必须成对出现, 不能只留一半。
ECH_KEYS = ("ACAeHgJriV0xujYELoel7l+Avsa2y7yjytil2vOQSlCdLgBl/g0AYQAAIAAgP6zoBwcqbFn"
            "Pyw2P1mY5ivBpuY6XvO+omOwChaYR3QIAJAABAAEAAQACAAEAAwACAAEAAgACAAIAAwAD"
            "AAEAAwACAAMAAwASbW9vbnR2LjY4OTY2OTgueHl6AAA=")
ECH_WANT = ("AGX+DQBhAAAgACA/rOgHBypsWc/LDY/WZjmK8Gm5jpe876iY7AKFphHdAgAkAAEAAQABAAIA"
            "AQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADABJtb29udHYuNjg5NjY5OC54eXoAAA==")
PBK = "GiR4k0uVRhKEWlfD9oRjjv-C0STrp5M0uP3kRIT2pgU"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    d, HOST = a.dir, a.host
    CONF, SHARE = os.path.join(d, "conf"), os.path.join(d, "out", "share")
    os.makedirs(CONF, exist_ok=True)
    os.makedirs(SHARE, exist_ok=True)

    def write(tag, inbound, declared=None, meta=None):
        frag = {"inbounds": [inbound]}
        if declared:
            frag["_serverName"] = declared
        json.dump(frag, open(os.path.join(CONF, tag + ".json"), "w",
                             encoding="utf-8"), ensure_ascii=False, indent=2)
        if meta is not None:
            meta = dict(meta)
            meta.setdefault("schema", 1)
            meta.setdefault("tag", tag)
            meta.setdefault("created_at", 1)
            meta.setdefault("updated_at", 1)
            json.dump(meta, open(os.path.join(SHARE, tag + ".json"), "w",
                                 encoding="utf-8"), ensure_ascii=False, indent=2)

    def vless(tag, port, net, security, extra=None, tls=None, listen="0.0.0.0",
              flow=None, reality=None):
        ss = {"network": net, "security": security}
        if tls is not None:
            ss["tlsSettings"] = tls
        if reality is not None:
            ss["realitySettings"] = reality
        key = {"ws": "wsSettings", "xhttp": "xhttpSettings",
               "grpc": "grpcSettings"}.get(net)
        if key and extra:
            ss[key] = extra
        u = {"id": "11111111-2222-3333-4444-555555555555"}
        if flow:
            u["flow"] = flow
        return {"tag": tag, "listen": listen, "port": port, "protocol": "vless",
                "settings": {"clients": [u], "decryption": "none"}, "streamSettings": ss}

    # 1 · vless + xhttp + tls + ECH(服务端密钥) + xhttp mode
    write("v-xhttp-tls", vless("v-xhttp-tls", 29601, "xhttp", "tls",
                               extra={"path": "/xh", "mode": "auto"},
                               tls={"serverName": None, "alpn": ["h2"]}),
          declared="cdn.example",
          meta={"host": HOST, "port": 29601, "name": "v-xhttp-tls"})
    f = json.load(open(os.path.join(CONF, "v-xhttp-tls.json"), encoding="utf-8"))
    f["inbounds"][0]["streamSettings"]["tlsSettings"]["echServerKeys"] = ECH_KEYS
    json.dump(f, open(os.path.join(CONF, "v-xhttp-tls.json"), "w",
                      encoding="utf-8"), ensure_ascii=False, indent=2)

    # 2 · vless + ws + tls（host 头）
    write("v-ws-tls", vless("v-ws-tls", 29602, "ws", "tls",
                            extra={"path": "/ws", "host": "ws.example"},
                            tls={"serverName": "ws.example", "alpn": ["http/1.1"]}),
          meta={"host": HOST, "port": 29602, "name": "v-ws-tls",
                "host_header": "ws.example"})

    # 3 · vless + tcp + reality（vision）+ spx
    write("v-tcp-reality", vless("v-tcp-reality", 29603, "tcp", "reality",
                                 flow="xtls-rprx-vision",
                                 reality={"serverNames": ["www.example.com"],
                                          "privateKey": "x"}),
          meta={"host": HOST, "port": 29603, "name": "v-tcp-reality",
                "public_key": PBK, "short_id": "b860a9f0", "spx": "/",
                "fingerprint": "chrome"})

    # 4 · vless + grpc + tls（serviceName —— URI 装不下）
    write("v-grpc-tls", vless("v-grpc-tls", 29604, "grpc", "tls",
                              extra={"serviceName": "grpcsvc"},
                              tls={"serverName": "grpc.example"}),
          meta={"host": HOST, "port": 29604, "name": "v-grpc-tls"})

    # 5 · trojan + tcp + reality
    write("t-tcp-reality", {"tag": "t-tcp-reality", "listen": "0.0.0.0", "port": 29605,
                            "protocol": "trojan",
                            "settings": {"clients": [{"password": "tpass"}]},
                            "streamSettings": {"network": "tcp", "security": "reality",
                                               "realitySettings": {
                                                   "serverNames": ["www.example.com"],
                                                   "privateKey": "x"}}},
          meta={"host": HOST, "port": 29605, "name": "t-tcp-reality",
                "public_key": PBK, "short_id": "b860a9f0", "fingerprint": "chrome"})

    # 6 · shadowsocks 明文
    write("s-plain", {"tag": "s-plain", "listen": "0.0.0.0", "port": 29606,
                      "protocol": "shadowsocks",
                      "settings": {"method": "2022-blake3-aes-128-gcm",
                                   "password": "cGFzc3dvcmQ="}},
          meta={"host": HOST, "port": 29606, "name": "s-plain"})

    # 7 · shadowsocks + reality（ss:// 装不下 —— 原生这条路的意义）
    write("s-reality", {"tag": "s-reality", "listen": "0.0.0.0", "port": 29607,
                        "protocol": "shadowsocks",
                        "settings": {"method": "2022-blake3-aes-128-gcm",
                                     "password": "cGFzc3dvcmQ="},
                        "streamSettings": {"network": "tcp", "security": "reality",
                                           "realitySettings": {
                                               "serverNames": ["www.example.com"],
                                               "privateKey": "x"}}},
          meta={"host": HOST, "port": 29607, "name": "s-reality",
                "public_key": PBK, "short_id": "b860a9f0", "fingerprint": "chrome"})

    # 8 · vmess + ws + tls
    write("m-ws-tls", {"tag": "m-ws-tls", "listen": "0.0.0.0", "port": 29608,
                       "protocol": "vmess",
                       "settings": {"clients": [
                           {"id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                            "alterId": 0}]},
                       "streamSettings": {"network": "ws", "security": "tls",
                                          "wsSettings": {"path": "/vm"},
                                          "tlsSettings": {"serverName": "vm.example"}}},
          meta={"host": HOST, "port": 29608, "name": "m-ws-tls"})

    # 9 · hysteria2 + tls（带宽 / 端口跳跃 / 证书 pin）
    write("h-tls", {"tag": "h-tls", "listen": "0.0.0.0", "port": 29609,
                    "protocol": "hysteria",
                    "settings": {"version": 2, "clients": [{"password": "hpass"}]},
                    "streamSettings": {"network": "hysteria", "security": "tls",
                                       "tlsSettings": {"serverName": "hy.example",
                                                       "alpn": ["h3"]}}},
          meta={"host": HOST, "port": 29609, "name": "h-tls",
                "upmbps": 100, "downmbps": 500, "mport": "20000-30000",
                "pinned_cert_sha256": "ab" * 32})

    # 10 · socks（可发布, 但原生没有表达）
    write("k-socks", {"tag": "k-socks", "listen": "0.0.0.0", "port": 29610,
                      "protocol": "socks", "settings": {"auth": "noauth"}},
          meta={"host": HOST, "port": 29610, "name": "k-socks"})

    # 11 · 只绑回环、没有 nginx → 两条产品都必须不发
    write("v-loopback", vless("v-loopback", 29611, "xhttp", "tls",
                              extra={"path": "/lb"},
                              tls={"serverName": "lb.example"}, listen="127.0.0.1"),
          meta={"host": HOST, "port": 29611, "name": "v-loopback"})

    # 12 · CDN-ECH（有 _serverName、无服务端密钥、host 是域名 → CDN 形式 ECH）
    write("v-cdn-ech", vless("v-cdn-ech", 29612, "ws", "tls",
                             extra={"path": "/ce"},
                             tls={"serverName": "cdn.example"}),
          declared="cdn.example",
          meta={"host": "cdn.example", "port": 443, "name": "v-cdn-ech",
                "tier": "nginx", "public_port": 443})

    print("语料已写入 %s（conf/ + out/share/）" % d)
    print("ECH_WANT=%s" % ECH_WANT)


if __name__ == "__main__":
    main()
