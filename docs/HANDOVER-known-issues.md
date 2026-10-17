# 交接文档 · 已知问题与实测结论

> 这份文档记的是**跑出来的结论**, 不是设想。每条都能复现。
> 最后更新: 分离节点三组合验收之后。

---

## 一、上下行分离三组合 · 实测状态

> **2026-10-17 复核结论：跨安全层的两个组合不成立，已从生成列表移除。**

| 组合 | 生成 | 真实连通性 | 备注 |
|---|---|---|---|
| `cdn-cdn` | ✅ | ✅ **200** | RN↔CC 真连, 3MB 下行 1.3MB/s, 订阅导入后同样可用 |
| `reality-reality` | ✅ | ✅ **200** | 上下行都 REALITY 直连; 3MB 下行 0.8MB/s |
| `cdn-reality` | ❌ 已拒绝 | ❌ **REALITY authentication failed** | 上行入站是普通 TLS, REALITY 客户端握不上 |
| `reality-cdn` | ❌ 已拒绝 | ❌ 不通 | 见第二节 |

判据是**内核结构**，不是配置调优：xHTTP 的会话表 `h.sessions` 是
per-inbound 的（`splithttp/hub.go:36-42`），下行 GET 必须落到同一个 inbound
才拿得到上行的 `uploadQueue`（`hub.go:380-390`）；而一个 inbound 只有一个
`security`。所以上下行必须同一安全层。

`cdn-reality` 曾经在文档里标 ✅ —— 那是在"下行给个独立入站"的设想下测的，
而独立入站会因会话表 per-inbound 拿到**空会话**（下行 000）；同一端口又只能
有一个安全层。两条路都实测过了，现在生成阶段直接拒绝并打印原因。

验收脚本: `tools/e2e_journey.sh`。订阅导入 (mihomo proxy-provider) 另外单独
验过：6 个节点全部解析，两个分离节点都能真连。

---

## 二、`reality-cdn` 下行走不通 —— 是**设计冲突**, 不是配置错

### 结论

`reality-cdn` (上行 REALITY 直连 + 下行走 CDN) **通不了**, 原因是这两个要求
互相冲突:

* 上下行必须落在**同一个 inbound、同一个端口**上 —— xHTTP 的会话表
  `h.sessions` 是 per-inbound 的 (内核 `hub.go:39/464`), 换端口就找不到会话,
  连接直接断。
* `reality-cdn` 的下行要经 Cloudflare/nginx, 也就是**普通 TLS**。

而 `reality-cdn` 的那个 inbound 是 **REALITY** 的, 只认 REALITY 握手。
**nginx 用普通 HTTPS 代理过去, 对不上。** 于是:

    nginx access log: "GET /rc5/... HTTP/2.0" 404
    xray 服务端:      启动之后一行 inbound 都没有

### 怎么验出来的 (一步一��排除)

| 组合 | 结果 |
|---|---|
| 裸 REALITY + 裸 tcp, 环回 | ✅ **200** |
| REALITY + xhttp, 环回, **上下行都 REALITY 直连同端口** | ✅ **200** |
| REALITY 上行 + TLS 下行走 CDN | ❌ 服务端收不到 |
| REALITY 上行 + TLS 下行, RN → RN 公网 IP | ❌ 同样 |

第三、四行与第二行的唯一差别就是**下行那一段**: 直连 REALITY 通, 走 CDN 的
普通 TLS 就不通。网络本身没问题 —— 从 CC 用 `openssl s_client` 打 RN 那个
REALITY 端口, `CONNECTED` 且握手完成 (返回的是真实证书, 因为未授权客户端会被
转给 target)。

所以**上行 REALITY 是好的, CDN 下行才是断的那一段**。

### 两处我上轮判断错了, 一起记下来

1. 说"上行 REALITY 握手需要真实 dest, 环回验不了" —— **错**。环回完全正常。
   我当时被残留进程误导了 (同一类错误这轮之前犯过一次)。
2. 说"REALITY 鉴权在服务端侧没通过" —— 也**不成立**。裸 REALITY 在环回上是
   通的。真正的原因就是上面那条设计冲突。

另外顺手确认: 服务端字段是 **`target`** 而不是 `dest` (对照
`conf/lib/node_build.py:197`)。写错了也不该指望它工作 —— 但它不是这次的主因,
改成 `target` 之后问题依旧。

### 该怎么改 (还没动手)

两条路, 都需要先验:

1. **把 `reality-cdn` 的下行也定成 REALITY** —— 也就是"上下行都直连"。
   那样它就和 `cdn-reality` 对称了, 而且环回已经证明这条路能通。
   代价: `reality-cdn` 就失去了"下行借 CDN 加速"的意义, 名不副实。
2. **给下行单开一个 TLS inbound** —— 但这违反"同端口同 inbound"的硬约束,
   除非内核允许按会话路由。这条我没验。

**这个已经做了**: 菜单里选到 `reality-cdn` 会先把原因和替代组合摆出来再问要不要
继续; 同时新增了实测可用的 `reality-reality` 作为替代。

### 还有一个副产品发现

REALITY 的伪装站点 (`target`) **不能随便选**。同一份配置:

* `target: www.cloudflare.com:443` → 环回 200, RN↔CC 200
* `target: www.microsoft.com:443`  → 握手不完成 (`rc=56` 连接重置)

两者从 RN 都能正常握 TLS1.3, 但只有前者能让 REALITY 借到证书。所以
`tools/e2e_journey.sh` 里的伪装站点已从 microsoft 换成 cloudflare。

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
6. **scp 到仓库根目录时要写全子目录**。
   `scp tools/a.sh rn:/repo/` 会把文件落在 `/repo/a.sh` 而不是 `/repo/tools/a.sh`,
   而套件的 lint 会遍历整个仓库扫 `.sh` —— 于是凭空冒出两条失败, 看着像产品
   有问题, 其实是我自己的散落文件。用 `2>/dev/null` 还会把这件事一起吞掉,
   连报错都看不见。**同步完顺手 `ls *.sh` 对一下上游**。
7. **Python 侧改文件时, 切片前先断言非空**。
   `s[a:b]` 若 `a >= b` 得到的是**空串**, 而 `str.replace('', new)` 会把 new
   插到**文件开头** —— 我就这么把一段注释塞到了 shebang 前面。是 `head -1` 和
   `wc -l` 对不上才发现的。改完顺手核对首行和行数。
8. **对照实验前先清干净残留进程**。我有过一次"RN 经 Cloudflare 是好的"是被上一轮
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