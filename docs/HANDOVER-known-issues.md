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

## 二、`reality-cdn` 上行 REALITY 握手不成立 (未结)

### 现象

上行 REALITY 握手**从不完成**。把网络全部排掉之后 (环回, 同一台机器, 同一对密钥,
两��都是 `Xray 26.3.27 d2758a0`) 仍然复现, 所以与 CDN、GFW、防火墙都无关。

最小复现: **裸 REALITY + 裸 tcp, 不带 xHTTP**, 连 xHTTP 都不涉及:

    服务端: REALITY: processed invalid connection from 127.0.0.1:42006:
            handshake did not complete successfully

换一个可达的 target (`www.cloudflare.com:443`, RN 到它 TLS1.3 正常) 后,
服务端的日志变了, 客户端给出了决定性的一句:

    [Error] transport/internet/reality: REALITY: received real certificate
            (potential MITM or redirection)

### 这句话说明什么

**服务端把这次连接当成了未授权的客户端, 直接转给了真实 target** ——
所以客户端拿到的是 cloudflare 真的那张证书, 而不是 REALITY 现算出来的那张。
客户端拿公钥去对, 对不上, 于是报 "potential MITM"。

即: **REALITY 的鉴权在服务端侧就没通过**, 与证书、CDN、路径都无关。

### 排除了什么

| 猜测 | 怎么排除的 |
|---|---|
| `flow: xtls-rprx-vision` 与 xHTTP 冲突 | 客户端报错原文就是这个, 但**去掉 flow 后依然失败**。而且 `node_build.build()` **本来就会拦**这个组合 (实测报错信息一模一样), 所以产品不会生成这种配置 —— 是我的夹具自己写了 flow |
| 字段名写错 (`dest` vs `target`) | 对照 `node_build` 第 197 行, 服务端确实用 `target`。我的夹具写的是 `dest`, 是错的; 但**改成 target 之后仍然失败** |
| 配置形状不对 | 用**产品自己的** `deploy.py --config-json` 生成一份, 产出的 `target / serverNames / privateKey / shortIds` 与手写夹具**逐字相同**, 一样失败 |
| 版本不一致 | 两端都是 `26.3.27 d2758a0` |
| target 不可达 | RN 到 microsoft / cloudflare / apple 的 TLS1.3 都正常 |

### 一个值得记的不对称

`cdn-reality` 的**下行**也是 REALITY, 而且它是**客户端**角色 (用 `password`),
那个**是通的** (环回全程跑通, 22 项验收里它过了)。

所以问题不在 REALITY 本身, 而在 **REALITY 的服务端侧**: 同一个内核版本,
当客户端能成, 当服务端就握不上。

### 下一步该查什么

- 让服务端 `show: true`, 看它到底为什么把这次连接判成未授权 —— 现在的
  `show: false` 会把失败完全吞掉, 只留一行 "invalid connection"。
- 重点查 **shortId 的取值/编码**: 两端都是 `0123abcd`, 但 REALITY 对短 ID 的
  长度与字符集有硬要求, 写对了不代表被接受。
- 也可以拿一份**已知能用的** REALITY 配置做对照 (别的面板产的), 逐字段比。

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