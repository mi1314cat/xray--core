# 实机 E2E 记录 (RN)

运行环境：`racknerd-75e0e8`，Xray 26.3.27 (d2758a0, go1.26.1 linux/amd64)。
代码从本仓库 `conf/` 与 `tools/` 直接部署，用独立目录 `/tmp/e2e` 与高位端口，
不碰生产那 16 个 inbound。

## 1. 预置矩阵

21 个预置全部生成，`xray run -test` **18/18 通过**（另 3 个是 CDN 档对裸 TCP
的预期拒绝，不是缺陷）。

18 个覆盖：vless(tcp/ws/xhttp/grpc/httpupgrade)×reality、trojan(ws/grpc/tcp)
×tls、vmess(ws/grpc/tcp)×tls、shadowsocks(tcp)×tls、hysteria2、socks、http。

## 2. 分享链接

`nodes.build_share_link` 对全部 18 个节点都生成了链接。

## 3. 真实握手

客户端与服务端是同一台机器上的两个独立进程，客户端走本地 SOCKS 入口，按
`routing` 分流到不同 outbound。

**已验证跑通**：trojan + WebSocket + TLS

```
客户端: [socks-trojan -> out-trojan]  proxy/socks: TCP Connect request
        transport/internet/websocket: creating connection to tcp:127.0.0.1:41001
        proxy/trojan: tunneling request to tcp:127.0.0.1:42000 via 127.0.0.1:41001
服务端: proxy/trojan: firstLen = 147
        proxy/trojan: received request for tcp:127.0.0.1:42000
        app/dispatcher: default route for tcp:127.0.0.1:42000
数据面: 响应体 HANDSHAKE-OK
```

**未能在这台机上验证**：VLESS + REALITY

原因有二，都不是本项目代码的问题：

1. REALITY 要求客户端**直连**握手目标站点来伪装（steal-oneself）。目标填
   `127.0.0.1` 时伪装不成立，必须换成真实站点。
2. 换成真实站点后，这台机的出网本身受限（`api.ipify.org` 也返回空），无法
   完成到第三方站点的 REALITY 握手。

内核侧已验证到位：`xray run -test` 通过、REALITY 私钥/公钥格式正确、分享
链接带正确的 `pbk`。要完整验证 REALITY 握手，需要一台出网正常且客户端直连的
机器。

## 4. 过程中内核报出来的三个错误

都是"配置看着对、但内核不认"，值得记下来：

```
unknown config id: hysteria2
  → 内核的 inbound id 是 protocol=hysteria + settings.version=2,
    凭据字段叫 auth 不是 password, tlsSettings 要带 alpn:["h3"]

decode psk: illegal base64 data at input byte 5
  → SS2022 密码要精确长度: aes-128 是 24 字符, aes-256/chacha 是 44 字符

The feature "allowInsecure" has been removed and migrated to
"pinnedPeerCertSha256"
  → 内核 26.x 移除了 allowInsecure, 客户端配置要用 pinnedPeerCertSha256,
    且它是单个字符串而不是数组
```

## 5. 一个反直觉的失败

服务端配置只有 `inbounds` 没有 `outbounds` 时：

```
proxy/trojan: received request for tcp:127.0.0.1:42000   ← 握手成功
app/dispatcher: default route for tcp:127.0.0.1:42000
app/dispatcher: default outbound handler not exist      ← 这里才失败
```

协议层看起来一切正常——认证通过、请求解析正确——只是没地方转发。日志停在
"received request" 会让人以为协议配错了。

## 复现

```bash
# 部署
tar czf dep.tgz conf tools && scp dep.tgz rn:/tmp/dep.tgz

# 跑全套预置 + 内核校验
export XRAY_CONF_DIR=/tmp/e2e/run/conf XRAY_SHARE_DIR=/tmp/e2e/run/share
bash tools/preset_batch.sh vless:1 vless:2 trojan:1 trojan:2 ...
for f in $XRAY_CONF_DIR/*.json; do xray run -test -c "$f"; done
```

验证套件 `tools/check_libs.sh`（176 项）不需要真机，本地容器即可跑完；上面
这些是套件覆盖不到、必须真内核才能发现的部分。
