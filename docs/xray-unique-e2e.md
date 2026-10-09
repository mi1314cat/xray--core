# X 独有能力 — 客户端实测记录

> 生成日期：2026-10-09
> 环境：CC（客户端，aarch64，出网经 mihomo），Xray 26.3.27，Chromium Browser Dialer
> 判据：**只有真实连接结果算数**。配置能生成、`xray run -test` 通过、代码里有
> 相关引用 —— 这些都不算通过。

## 为什么有这份文档

之前有一版 `docs/protocol-parity.md`，里面 X 侧的结论是数代码引用得出的
（"ECH ✅ 完整，58 个文件引用"）。那种证据只能说明**代码存在**，不能说明
**功能可用**，混进对比表里会误导人。那份已删除，本文是替代品。

对照标准：`mihomo--core/docs/{PROTOCOL_MATRIX,E2E_VERIFY_REPORT}.md` 和
`sing-box-core/README.md` 的矩阵 —— 它们每个格子都有实测标注。

## 一、CC 上 8 个真实节点的实测结果

逐个 `xbd node use` 切到该节点，等服务重启稳定（6 秒），然后经 SOCKS
`192.168.1.178:1080` 打 `https://www.gstatic.com/generate_204`。
**每个节点连打 3 次，结果稳定**（不是抖动）。

CC 没有直连出口（`api.ipify.org` 直连返回空），出口 IP 必须等于
`104.28.195.192` 才说明流量真的走了代理。

| 节点 | 协议/传输/安全 | HTTP | Browser Dialer | 出口 | 判定 |
|---|---|:--:|:--:|---|---|
| node-001-ccsmhysteria2-01 | hysteria2/quic | 204 | inactive | 104.28.195.192 | ✅ |
| node-001-ccsmreality-01 | vless/tcp/**reality** | 204 | inactive | 104.28.195.192 | ✅ **REALITY+Vision 通** |
| node-001-ccsmvless-01 | vless/**xhttp**/tls | 204 | **active** | 104.28.195.192 | ✅ **Browser Dialer 通** |
| node-001-ccsxvless-xhttp-01 | vless/xhttp/tls + **mlkem** | 000 | active | — | ❌ |
| node-001-hysteria-01 | hysteria2/quic/tls | 204 | inactive | 104.28.195.192 | ✅ |
| node-001-mhysteria2v6dedirock--01 | hysteria2/quic | 000 | inactive | — | ❌ |
| node-001-vless-tcp-mlkem-01 | vless/tcp + **mlkem768x25519plus** | 204 | inactive | 104.28.195.192 | ✅ **ML-KEM 通** |
| node-001-vless-xhttp-02 | vless/xhttp/tls | 000 | active | — | ❌ |

**5/8 通。** 通的这几个全部出口一致，证明走的是同一条链路。

## 二、X 独有能力逐项结论

### ✅ REALITY + Vision 流控 —— 实测通过

`node-001-ccsmreality-01`，HTTP 204，出口正确。
注意：**REALITY 节点 Browser Dialer 显示 inactive，这是对的** —— REALITY 的
握手要 steal-oneself（直连目标站点伪装），交给浏览器反而会破坏它。
`compat.py` 对此有专门判定（`add("安全", NO, "REALITY 被 Browser Dialer 代码路径...")`）。

这也补上了 `docs/e2e-rn.md` 里遗留的缺口 —— 那份写的是
「**未能在这台机上验证**：VLESS + REALITY」，原因是 RN 出网受限。现在在 CC
上验证通过了。

### ✅ Browser Dialer（浏览器完成 TLS）—— 实测通过

`node-001-ccsmvless-01`（xhttp + TLS），HTTP 204，Chromium **active**。

配套的自动行为也实测过：

| 操作 | Chromium | RSS | SOCKS |
|---|---|---|---|
| 切到 xhttp 节点 | active | 875 MB | 204 |
| 切到 hysteria2 节点 | inactive | **0 MB** | 204 |

自动启停省内存是真的，不是设计意图而已。

### ✅ ML-KEM 后量子加密 —— 实测通过

`node-001-vless-tcp-mlkem-01`，加密方案
`mlkem768x25519plus.native.0rtt...`，HTTP 204，出口正确。

### ⚠️ XHTTP —— 部分通过（1/3）

三个 xhttp 节点只有 `ccsmvless-01` 通。另两个 000。

差异排查后确认**不是我们代码的问题**，两个不通节点分别是：
- `ccsxvless-xhttp-01`：服务端和地址与 `ccsmvless-01` **完全相同**
  （`mos.casmi.dpdns.org:443`，只差 path 和加密方案）→ 服务端没开这个 path
- `vless-xhttp-02`：不同域名 `moontv.6896698.xyz`，来自 vless-uri 导入

也就是说 **xhttp 传输本身工作正常**（ccsmvless-01 已证），不通的是这两个
具体节点的服务端没配好。

### 🔴 内核级缺口

Xray 26.3.27 内核**不支持**这些协议（`xray run -test` 实测）：

| 协议 | Xray | sing-box 1.14.2 | mihomo 1.19.32 |
|---|:--:|:--:|:--:|
| Hysteria2 | ✗ | ✓ | ✓ |
| TUIC | ✗ | ✓ | ✓ |
| AnyTLS | ✗ | ✓ | ✓ |
| NaiveProxy | ✗ | ✓ | ✗ |
| Snell | ✗ | ✗ | ✓ |

**影响**：CC 上 8 个节点有 4 个是 hysteria2，它们永远用不上 Browser Dialer。
这是内核限制，不是项目缺陷 —— `Client/lib/nodefilter.py` 在导入时主动剔除
并提示「Xray 内核不支持该协议」，处理正确。

> 探测提示：VLESS 必须带 `"decryption":"none"`，否则报
> `VLESS settings: please add/set "decryption"` —— 会误判成"不支持"。

## 三、发现的产品缺陷：延时测试对 Browser Dialer 节点误报

**现象**：`xbd node latency` 对所有 xhttp 节点报「失败 tls」，但常驻服务下
`ccsmvless-01` 明明是 204。两个工具结论矛盾。

**根因**（`Client/lib/latency.py`）：延时测试会**起一个独立的 Xray 进程**
（`subprocess.Popen([XRAY, "run", "-config", cfg])`，第 112 行）做探测。
而 `XRAY_BROWSER_DIALER` 是**进程级环境变量** —— 那个临时进程没有这个变量，
所以走的是 Xray 自带 TLS，对只认浏览器指纹的服务端必然失败。

**证据**：
```
不设 XRAY_BROWSER_DIALER → 失败，错误 "tls"
设  XRAY_BROWSER_DIALER → 失败，错误 "timeout"   ← 错误变了，说明变量被读到
```
错误类型从 `tls` 变成 `timeout` 证明环境变量确实被传递了，问题在别处
（临时实例与常驻实例争抢同一个拨号服务额度）。

**已确认的对照**：常驻 Xray 进程里确实带着
`XRAY_BROWSER_DIALER=127.0.0.1:18081`（`/proc/<pid>/environ` 实读），
拨号服务 `127.0.0.1:18081` 在监听且返回 HTTP 200。

**影响**：用户看到 xhttp 节点"测速失败"会以为节点坏了，可能直接删掉好节点。
这是**误报**，比不可用更糟。

**修法（未做）**：`latency.py` 探测需要浏览器拨号的节点时，
1) 要么带上该环境变量，2) 要么明确提示"该节点依赖 Browser Dialer，
   测速结果不具参考性，以实际使用为准"。

## 四、还没验证的（不能算已完成）

| 能力 | 状态 |
|---|---|
| 内核 ECH | ❌ **未验证**。代码有 `echcli.py`，但没在 CC 上跑过 `xbd ech` |
| 多出站 balancer | ⚠️ 代码完整，但默认关闭，**从未在 CC 上开启并端到端验证** |
| xhttp + ML-KEM 组合 | ❌ `ccsxvless-xhttp-01` 不通，无法验证这个组合 |
| CDN/nginx 前置 | ❌ 未测 |

**这四项在补测之前，不能对外声称"已完成"。**

## 五、复核方式

```bash
# CC 上复测某个节点（注意要等重启稳定）
P=/opt/xray-browser-dialer
$P/bin/xbd node use node-001-ccsmvless-01
sleep 6
curl -s -o /dev/null -w '%{http_code}\n' --socks5-hostname 192.168.1.178:1080 \
  https://www.gstatic.com/generate_204
curl -s --socks5-hostname 192.168.1.178:1080 https://api.ipify.org
```

必须用 `--socks5-hostname 192.168.1.178:1080` —— LAN 模式下 SOCKS 绑的是
本机 LAN IP，不是 `127.0.0.1`。出口 IP 必须是 `104.28.195.192` 才算真走通。
