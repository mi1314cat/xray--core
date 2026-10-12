# 交接文档 · 已知问题与实测结论

> 这份文档记的是**跑出来的结论**, 不是设想。每条都能复现。
> 最后更新: 分离节点三组合验收之后。

---

## 一、上下行分离三组合 · 实测状态

| 组合 | 片段/元数据/投影 | 真实连通性 | 备注 |
|---|---|---|---|
| `cdn-cdn` | ✅ | ✅ **200** | RN↔CC 双端实测 |
| `cdn-reality` | ✅ | ✅ **200** | 环回全程跑通 |
| `reality-cdn` | ✅ | ❌ **未通** | 见下 |

验收脚本: `tools/e2e_journey.sh` (22 通过 / 0 失败 / 2 跳过)。

---

## 二、`reality-cdn` 下行不通 (未结)

### 现象

上行 REALITY 握手**是成功的** —— 客户端日志:

    proxy/vless/outbound: tunneling request to tcp:www.baidu.com:443 via 107.173.154.178:24301

但下行取不到数据, 紧接着 `failed to process outbound traffic`。

服务端日志在 `Xray started` 之后**一行 inbound 都没有**。

### 试过两条路, 都一样

1. **下行走 CDN** (产品生成的那种): nginx 收到了请求, 但 **404**。
   nginx access log:

       "GET /rc-cdn/29df6158-... HTTP/2.0" 404 9

2. **下行直连同一个端口** (绕过 CDN): 服务端**仍然一行日志都没有**。

所以**不是 CDN 那一跳的问题** —— 绕开它也一样不通。

### 为什么 404 那条值得单独看

nginx 的段是对的 (`proxy_pass https://127.0.0.1:24301` + `proxy_ssl_name`),
而 24301 上那个 inbound 是 **REALITY** 的, nginx 用普通 HTTPS 代理过去, 对不上。
按本仓库自己的硬约束:

> xHTTP 的会话表挂在**每个 inbound 自己**上, 上行 POST 建好的会话, 下行 GET 到另一个
> 端口就找不到, 连接直接断。CDN 与直连的差别只能体现在**网络路径**上 —— 两段 nginx
> 都要 proxy_pass 到同一个 xray 端口。

也就是说 `reality-cdn` 的上行与下行必须落在**同一个 REALITY inbound** 上,
而"下行经 CDN"要求那一端能被 nginx 以普通 TLS 代理 —— 这两条要求互相冲突。

### 下一步该查什么

还没定位到根因, 但线索是明确的:

- 服务端完全收不到下行请求 → 要看 xHTTP 服务端对 **REALITY 入站的 GET 请求**
  是怎么路由的, 是不是只在 POST 建好会话后才认。
- 建议先在**环回**上把 uplink+downlink 都设成 REALITY 直连同一端口, 看最小复现
  能不能成 —— 排掉 CDN 和网络因素。

---

## 三、Cloudflare 会打断 xHTTP 的上下行分离

实测四组对照 (服务器侧已经排除):

| 路径 | 结果 |
|---|---|
| RN → xray 公网端口 (不过 nginx/不过 CF) | ✅ 200, 1.47s |
| CC → xray 公网端口 (不过 nginx/不过 CF) | ✅ 200, 2.67s |
| RN → Cloudflare → nginx → xray | ❌ `invalid Read on closed Body` |
| CC → Cloudflare → nginx → xray | ❌ `invalid Read on closed Body` |

**节点本身是好的, 断的是 Cloudflare 那一段**, 而且与是否在境内无关 ——
RN 在境外一样断。

已知根因 (不在本仓库, 要去控制台点):

    Cloudflare → SSL/TLS → Origin Server → Origin HTTP Protocol
    改成 **HTTP/1.1**

旁证: nginx access log 里 CF 回源的请求确实带 `HTTP/2.0`。

用户自查入口: 菜单 **16) 分离节点自检** (`tools/xhttp_doctor.sh`),
它会读日志认出那半行, 并直接给出上面这条路径。

---

## 四、别再犯的几个坑 (都踩过)

1. **`grep -q` 在管道里会提前关管道**, 上游吃 SIGPIPE, `pipefail` 把"找到了"变成
   "命令失败"。用 `grep -qF <<<"$VAR"`。
2. **节点脚本只从菜单进时看不出问题**。`Reality.sh` 的 `safe_read` 带 batch 守卫而
   另外两个不带 —— 哪天给它们加条非交互调用路径, 就会永远卡在 `read` 上。
   现在三个共用 `conf/lib/proto_ui.sh`, 守卫只有一份。
3. **`x_cert_gc` 会把 nginx 正在用的证书当垃圾删掉** —— 这就是"证书莫名丢失"的
   真凶。现在删之前先扫一遍 nginx 配置; 配了 `tools/cert_guard.sh` 自愈。
4. **`allowInsecure` 自 xray 26.3.27 起已被移除**, 带这个字段的客户端配置根本起不来。
   自签证书要钉 `pinnedPeerCertSha256`。
5. **`pinnedPeerCertSha256` 是字符串**, 不是数组。
6. **对照实验前先清干净残留进程**。我有过一次"RN 经 Cloudflare 是好的"是被上一轮
   直连用的客户端占着同一端口造成的, 差点把结论写反。

---

## 五、复现用的命令

```bash
# 全套自测 (920+ 项)
cd /root/xray-ux-lab/repo
SHARE_CLIENT_REAL=/root/xray--core/conf/share_client.py bash tools/check_libs.sh

# 用户那条路的验收 (含分离三组合)
JOURNEY_PUBKEY=<x25519 公钥> \
JOURNEY_PRIVKEY=<x25519 私钥> \
JOURNEY_SHORTID=0123abcd \
bash tools/e2e_journey.sh

# 交互验证 (真 pty)
python3 tools/ui_probe.py --repo /root/xray-ux-lab/repo

# 分离节点自检
bash tools/xhttp_doctor.sh /root/catmi/xray/log/access.log
```