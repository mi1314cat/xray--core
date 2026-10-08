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

## 全协议链路验证

`xray run -test` 只能证明内核接受了配置, 证明不了流量真能通。`tools/e2e_protocols.sh`
对每种协议/传输搭一条完整链路:

```
源站 (本地 HTTP)  <-  Xray 客户端 (socks5 入口)  <-  Xray 服务端 (测试入站)
```

两端必须起在**两个进程**里。同一个进程同时装入站和出站时, 两端会直接握手,
配置写错也可能通 —— 那样测的就不是链路而是进程内的捷径。

curl 通过 socks 访问源站, 拿到源站预先放好的 token 才算过。

### 实机结果 (Xray 26.3.27, d2758a0)

| 组合 | 结果 |
|---|---|
| vless + tcp | 通过 |
| vmess + tcp | 通过 |
| shadowsocks2022 + aes-128-gcm | 通过 |
| vless + tcp + tls (xtls-rprx-vision) | 通过 |
| vless + ws + tls | 通过 |
| vless + grpc + tls | 通过 |
| vless + xhttp + tls | 通过 |
| trojan + tcp + tls | 通过 |
| trojan + ws + tls | 通过 |
| trojan + grpc + tls | 通过 |
| vmess + ws + tls | 通过 |
| vless + tcp + reality | 通过 |

12 种全部打通。此前记为"REALITY 握手受阻"的那一项, 在本机自环 + 直连出网
的条件下可以通过 —— 之前的失败是链路条件不具备, 不是 REALITY 本身不通。

### 搭这条链路时踩到的内核行为

这些都是"配置看起来对、内核却不接受"或"接受了却不通"的一类, 值得单独记:

- **服务端只写 inbounds 不写出站**, 隧道请求其实已经正确到达 (日志里有
  `received request for ...`), 但没有出站去连目标地址, 内核报的是
  `default outbound handler not exist`。看起来像协议配错, 实际是少了 freedom。
- **VLESS 入站必须显式 `"decryption": "none"`**, 26.x 缺了直接拒绝启动。
- **`tlsSettings.certificates[].certificate` 与 `.key` 是数组**, 且放 PEM
  原文而非 base64。写成标量会报 `cannot unmarshal string into []string`,
  写成 base64 会报 `failed to find any PEM data`。
- **`pinnedPeerCertSha256` 是字符串**, 与上面的 `certificate` 不是一个形状。
  `allowInsecure` 已在 26.x 移除, 内核直接拒绝这种配置。
- **Trojan 出站用 `settings.servers`, 不是 `vnext`**。写成 vnext 时内核报的是
  `Trojan settings: "servers" is required`, 错误信息不提 vnext, 容易让人往
  证书或端口方向找。
- **`xray x25519` 把公钥那行标成 `Password (PublicKey)`**。只匹配
  `^PublicKey:` 取不到值, 于是密钥对判空、REALITY 用例被静默跳过。
- **SS2022 密钥长度必须精确对应算法** (aes-128 要 16 字节)。长度不对时报
  `decode psk: illegal base64 data`, 长度"碰巧合法"时更糟 —— 不报错, 静默不通。

配置由 `tools/e2e_configs.py` 生成而不是 shell 拼字符串: TLS 证书要塞含换行的
PEM, 拼字符串必然要在转义上翻车。这次拼 JSON 先后踩了四个坑 (证书形式、数组
形状、片段间逗号、空片段多逗号), 每次的表现都是同一句"配置解析失败", 指向的
却是完全不同的原因。`e2e_configs.py --selftest` 把这些形状检查固化成离线断言。

### 自检在实机上的行为

菜单 12 (自检) 在实机上跑时, 曾把测试配置写进容器里 nginx 的**真实站点** ——
因为测试用 `NGINX_CONF_ROOTS` 指定夹具目录, 而代码里的容器探测会盖掉这个指定。
现在调用方显式指定了配置根或文件路径时不再探容器, 实机跑完站点校验和不变。

## 从零安装

菜单 1 (安装/更新) 此前只在已经装好的机器上跑过, 真正的从零路径没验证过 ——
新机器上没有内核、没有 `conf/`、没有 systemd 条目, 全靠 `bin/xray_install.sh`
建起来。

用 `XRAY_INSTALL_DIR` 指到临时目录, 不碰真实安装, 脚本也会自己识别成测试模式
并跳过 systemd 安装:

```
XRAY_INSTALL_DIR=/tmp/isotest bash bin/xray_install.sh
```

实机结果:

| 检查项 | 结果 |
|---|---|
| GitHub API 403 (限流) 后回退直连 release 下载 | 通过 |
| 生成 `00-base.json`, 零节点即可运行 | 通过 |
| `xray run -test -confdir` 基础配置 | 通过 |
| 内核进程能起来并保持运行 | 通过 |
| 重复安装跳过下载 | 通过 |
| 重复安装不删除 `conf/` 里已有的节点文件 | 通过 |

自检里对应的一组断言会先把内核放好让脚本跳过下载 —— 每次联网拉一遍内核既慢,
又会在 GitHub API 限流时变成随机失败, 那种失败复现不了, 也没法当作回归信号。
