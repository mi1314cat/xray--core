# X 内核 · 全协议支持与推荐配置报表

> 生成日期：RN↔CC 真实连接验证之后。
> 数据来源：`conf/lib/preset.sh` 的 `X_PRESETS`（实跑 `x_preset_*` 导出）
> + `docs/e2e-rn.md` + 本轮 RN→CC 实测。
> 判据一律是**真连**，不是"配置能生成"。

---

## 一、总览

| 项 | 数量 |
|---|---|
| 支持的协议 | **7** 个 |
| 预置档位（协议 × 传输 × 加密） | **28** 档 |
| 推荐度分档 | 4 档（core / cdn / compat / special） |
| 全协议一键生成默认取哪几档 | `core` + `cdn`（共 15 档） |
| 本次新增 | VMess+HTTPUpgrade 预置、回落选配、Hysteria2 混淆 |

### 每个协议有多少种选择

| 协议 | 档数 | 推荐首档 | 传输选配 | 加密选配 |
|---|:--:|---|---|---|
| **VLESS** | **10** | ① REALITY + Vision + 后量子 | raw/tcp、xhttp、ws、grpc、httpupgrade | reality、tls、none |
| **Trojan** | **5** | ① REALITY | tcp、xhttp、ws、grpc | reality、tls |
| **VMess** | **5** | ① XHTTP + TLS | xhttp、ws、grpc、**httpupgrade**、tcp | tls |
| **Shadowsocks** | **3** | ① REALITY | tcp | reality、tls、none |
| **Hysteria2** | **1** | ① UDP + TLS | hysteria（UDP） | tls |
| **SOCKS5** | **2** | ① 无认证（仅内网） | tcp | none、tls |
| **HTTP** | **2** | ① 无认证（仅内网） | tcp | none、tls |
| | **28** | | | |

---

## 一之补：哪些档**不适合公网**（用户问的"有些可能是隧道之间用的"）

这一列比"推荐哪个"更重要 —— 有 6 档是**内网/隧道**用途，放到公网上等于开代理。

| 档 | 用途 | 放公网的后果 |
|---|---|---|
| socks ① 无认证 | 本机 / 可信内网 | **等于开放代理**，会被扫 |
| socks ② + TLS | 同上 | 同上（TLS 不解决无认证） |
| http ① 无认证 | 同上 | **等于开放代理** |
| http ② + TLS | 同上 | 同上 |
| shadowsocks ③ 裸 TCP 无加密 | 同一局域网 | 流量明文可识别 |
| vless ③ 后量子裸 TCP | 内网 / 隧道 | 无握手伪装，裸 TCP 特征明显 |
| vless ⑩ 裸 TCP + TLS | 确认不需要抗 DPI 时 | 最易被识别 |
| trojan ⑤ 裸 TCP + TLS | 同上 | 同上 |
| vmess ⑤ 裸 TCP + TLS | 同上 | 同上 |

**"全协议一键生成"默认不取这些** —— 它只取 `core` + `cdn` 两档（共 15 档）。
上表这些是 `special` / 部分 `compat`，必须手动点名才会生成。

另外两条**跨协议**的公网前提：

- **裸 TCP 类（tcp/raw）走不了 Cloudflare 橙云** —— CF 只代理 HTTP(S)。
  面板在建节点时就会拦：「CDN 档位下裸 TCP + 无加密不可用」。
- **自签证书走不了 CDN** —— Cloudflare 不接受自签源站证书，已在生成前拦。
  自签只适合直连档 + 客户端 pin。

---

## 二、推荐配置报表（28 档全表）

`★` = 推荐档；`[档位]` = 推荐度，决定它进不进"全协议一键生成"。
`ext` = Xray 特有的加密增强。

### VLESS（10 档）

| # | 传输 | 加密 | 档位 | ext | 一句话说明 |
|:--:|---|---|---|---|---|
| ① ★ | raw | reality | core | mlkem,mldsa65 | 裸 TCP + XTLS Vision + ML-KEM-768 会话加密 + ML-DSA-65 握手签名。**新装首选** |
| ② ★ | tcp | reality | core | none | 与 ① 等价，退掉后量子 |
| ③ | raw | none | special | mlkem | 最轻，延迟最低；没有握手伪装 |
| ④ ★ | xhttp | tls | cdn | none | **官方主推传输**，CDN 推荐档 |
| ⑤ ★ | xhttp | tls | cdn | mlkem | ④ + ECH + 后量子 |
| ⑥ ★ | xhttp | reality | core | none | **上下行分开**（mode=stream-up，同一目的地） |
| ⑦ | ws | tls | compat | — | 官方已弃用，仅兼容 |
| ⑧ | grpc | tls | compat | — | 官方已弃用 |
| ⑨ | httpupgrade | tls | compat | — | 官方已弃用 |
| ⑩ | tcp | tls | special | — | 最易被识别 |

### Trojan（5 档）

| # | 传输 | 加密 | 档位 | 说明 |
|:--:|---|---|---|---|
| ① ★ | tcp | reality | core | Trojan 侧最抗 DPI |
| ② ★ | xhttp | tls | cdn | 官方主推传输，可走橙云 |
| ③ | ws | tls | compat | 已弃用 |
| ④ | grpc | tls | compat | 已弃用 |
| ⑤ | tcp | tls | special | 最常见默认 |

### VMess（4 档）

| # | 传输 | 加密 | 档位 | 说明 |
|:--:|---|---|---|---|
| ① ★ | xhttp | tls | cdn | 官方主推 |
| ② | ws | tls | compat | 已弃用 |
| ③ | grpc | tls | compat | 已弃用 |
| ④ | httpupgrade | tls | compat | 本轮新增（比 WS 更轻的 HTTP 升级） |
| ⑤ | tcp | tls | special | 改连 TCP 伪装 |

### Shadowsocks（3 档）

| # | 传输 | 加密 | 档位 | 说明 |
|:--:|---|---|---|---|
| ① ★ | tcp | reality | core | 协议本身简单，靠 REALITY 补抗识别 |
| ② | tcp | tls | special | 标准用法 |
| ③ | tcp | none | special | **仅局域网** |

### Hysteria2 / SOCKS5 / HTTP（5 档）

| 协议 | # | 传输 | 加密 | 档位 | 说明 |
|---|---|------|---|---|---|
| hysteria2 | ① ★ | hysteria(UDP) | tls | core | 抗弱网靠协议本身 |
| socks | ① | tcp | none | special | 仅本机/内网 |
| socks | ② | tcp | tls | special | 同上 |
| http | ① | tcp | none | special | 仅本机/内网 |
| http | ② | tcp | tls | special | 同上 |

---

## 三、★ X 内核特殊能力（这是与 SB / M 最不同的地方）

### 3.1 XHTTP —— 本项目的重点

XHTTP 是 Xray 自己发明的传输（内核包名 `transport/internet/splithttp`），
SB **完全没有**，M 只能校验、不能生成。X 这边是全套。

#### mode 四个取值（**最容易误解的旋钮**）

| mode | 上行 | 下行 | 上下行是否分离 |
|---|---|---|---|
| `stream-one` | 一条常驻 POST（双向） | 同一条 | **否（合流）** |
| `stream-up` | 一条常驻 POST 流 | 独立 GET | **是** |
| `packet-up` | 每个包一个 POST（带 seq） | 独立 GET | **是** |
| `auto` | 由内核决定 | | 见下 |

**`auto` 的解析规则（`dialer.go:382-390`）**：

| 场景 | auto 解析成 |
|---|---|
| 非 REALITY | `packet-up`（分离） |
| REALITY | `stream-one`（**合流**） |
| REALITY + `downloadSettings` | `stream-up`（分离） |

> ⚠ 所以「我用了 XHTTP 所以上下行分开了」是错的。REALITY 档必须**显式**选
> `stream-up`。面板菜单 13 在 REALITY 下默认就是 `stream-up`，并把这句话打在屏幕上。

#### 上下行分离（`downloadSettings`）—— 真正的"两条腿"

`downloadSettings` 里的 `StreamConfig` **含 address 与 port**，客户端会用它
重建**另一个** client，连**另一个地址**。所以上下行可以走完全不同的网络路径。

**五条硬约束（全部在生成之前拦，`-test` 都查不到）**：

| 约束 | 依据 |
|---|---|
| 上下行**必须同一个 inbound / 同端口** | 会话表 `h.sessions` 是 per-inbound 的（`hub.go:39/464`） |
| 下行 path **必须等于**上行 path | 服务端只认顶层 `xhttpSettings.path`（`hub.go:461`） |
| `stream-one` **不能**配 `downloadSettings` | 内核 `transport_internet.go:440` |
| **绝不用 `extra` 字段** | 内核里 `extra` 非空会**整体替换**整个 xhttpSettings，且 `-test` 不报错 |
| `scMaxEachPostBytes` / `xPaddingBytes` 服务端必须 ≥ 客户端 | 否则 413 / 400 |

**四个组合与实测**（2026-10-17 复核，客户端 mihomo v1.19.32，RN↔CC 真连）：

| 组合 | 上行 | 下行 | 实测 |
|---|---|---|---|
| `cdn-cdn` | CDN(TLS) | CDN(TLS) | ✅ 200，3MB 下行 1.3MB/s |
| `reality-reality` | REALITY 直连 | REALITY 直连 | ✅ 200，3MB 下行 0.8MB/s |
| `cdn-reality` | CDN(TLS) | REALITY 直连 | ❌ 客户端 `REALITY authentication failed` |
| `reality-cdn` | REALITY 直连 | CDN(TLS) | ❌ nginx 明文转不进 REALITY 入站 |

**为什么只有两个能通**：xHTTP 的会话表 `h.sessions` 挂在**每个 inbound 自己**
的 `requestHandler` 上（`splithttp/hub.go:36-42`），下行的 GET 带 sessionId
必须落到**同一个 inbound** 才能拿到上行的 `uploadQueue`（`hub.go:380-390`）；
而一个 inbound 只有一个 `streamSettings.security`。于是：

* 上行经 CDN 时入站是**普通 TLS/明文**，REALITY 客户端握手必然失败
  （`REALITY authentication failed`）；换一个端口给下行，又会因为会话表
  per-inbound 而落进**空会话**（下行 000，连接空转）。
* 上行是 REALITY 时，下行若经 CDN 回源是**普通 HTTP/2**，nginx 转不进只认
  REALITY 握手的入站。

⇒ 上下行必须是**同一个安全层**。跨安全层的两个组合在生成阶段就被拒绝，
并把原因打印出来（`conf/lib/preset.sh` 的 `x_split_ok` / `x_split_why`），
而不是发一条连不上的死链。

**仍要保留的约束**：下行 `path` 必须与上行一致；`stream-one` 不能配
`downloadSettings`；REALITY 上行的 `dest` 必须是**真能握手的第三方站点**
（用节点自己的橙云域名会 `REALITY authentication failed`），`shortId`
非空且两端一致。

### 3.2 回落（fallback）—— 已做成**选配**

三件容易混的事，要分清：

| 机制 | 说明 | X 的支持 |
|---|---|---|
| **REALITY `target`** | 非 REALITY 握手流量转发到伪装站点 | ✅ 已有（内核 level） |
| **VLESS / Trojan `fallbacks`** | 非本协议流量落到真实网站 | ✅ **本轮新增，做成菜单选配** |
| DNS fallback | 解析失败时的兜底 | ✅ 有 |

**它解决什么**：入站是 VLESS/Trojan + TLS 时，内核先做 TLS 握手 —— 任何人都能连上 TLS 层。
接下来长得像本协议的走代理，**不像的（浏览器、扫描器）转去你的网站**。
所以探测者看到的是一张真证书 + 一个真网站，而不是一个连上就断的怪端口。

**实测（RN，v26.3.27）**：

```
普通 HTTPS 打 VLESS 端口  → 拿到回落目标的网页 "I-AM-THE-FALLBACK-SITE"  ✅
真 VLESS 客户端           → http=200                                   ✅
```

**菜单里的样子**（`1) 不回落` 是默认）：

```
  回落 (fallbacks) —— 不像本协议的流量转到哪?
    效果: 普通浏览器/扫描器打这个端口, 看到的是你的**真实网站**;
          只有真客户端才走代理。抗主动探测最有效的一招。
    前提: 那个网站必须真的在跑, 否则探测者会拿到 502 —— 比不开还显眼。
     1) 不回落 (默认, 最省事)
     2) 转到一个本机端口 (例如网站跑在 8080)
```

**约束**：只在 **TLS** 上有意义。REALITY 有自己的 `target`，两套混用会被拒
（生成之前就拦）。端口没人听时会二次确认。

### 3.2b Hysteria2 混淆 —— **能加**（走内核新的 finalmask 体系）

内核 26.3.27 把混淆搬进了 `finalmask`：

```jsonc
"streamSettings": {
  "finalmask": { "udp": [ { "type": "salamander", "settings": { "password": "…" } } ] }
}
```

| 项 | 结论 |
|---|---|
| 字段名 | **全小写 `finalmask`** —— 写 `finalMask` 内核**不报错也不生效**，静默失效 |
| 实测 | 无混淆 `200` / salamander 混淆 `200`（同一份配置只差这一个字段） |
| 两端 | 密码必须一致，且必须**一起开** —— 一端开一端不开，握手直接失败 |
| mihomo 侧 | `obfs: salamander` + `obfs-password`，**两者必须成对** —— 只写 `obfs` 会让 mihomo **整批**报 `missing obfs password` |
| 旧字段 | `congestion`/`up`/`down`/`udphop` 是旧的，内核会打告警后继续接受；新位置是 `finalmask.quicParams` |

### 3.3 其它 X 特有

| 能力 | 入口 | 状态 |
|---|---|---|
| **ML-KEM-768** 后量子会话加密 | `xray vlessenc` → `settings.decryption` | ✅ 预置 ①③⑤ |
| **ML-DSA-65** 后量子握手签名 | `xray mldsa65` → `realitySettings.mldsa65Seed/Verify` | ✅ 预置 ① |
| **TLS-ECH** | `xray tls ech` → 服务端 `echServerKeys` / 客户端 `echConfigList` | ✅ 预置 ⑤ |
| **XTLS Vision** | `flow: xtls-rprx-vision` | ✅ 只在裸 TCP（其它传输会挂） |
| **REALITY 传输白名单** | 内核原文 `REALITY only supports RAW, XHTTP and gRPC` | ✅ raw/tcp/xhttp/grpc |
| Browser Dialer | 客户端 Chromium | 客户端侧，本阶段未动 |

---

## 四、RN → CC 真实连接验证（本轮实测）

**拓扑**：服务端（公网 IPv4 + 公网 IPv6）与客户端（mihomo）两台独立机器。全部用 **X 自己的生成器**（`deploy.py` + `to_mihomo.py`）产出配置。

**结果：9/9 全部 200**

| 节点 | 协议 | 传输 | 加密 | HTTP |
|---|---|---|---|---|
| `vless+reality` | VLESS | raw | REALITY + Vision | ✅ 200 |
| `x-vless02-XHTTPTLS` | VLESS | xhttp | TLS（真证书） | ✅ 200 |
| `x-vless03-XHTTPREALITY` | VLESS | xhttp | REALITY（stream-up） | ✅ 200 |
| `x-vless04-SPLIT` | VLESS | xhttp | TLS + **上下行分离** | ✅ 200 |
| `x-vless05-WSTLS` | VLESS | ws | TLS | ✅ 200 |
| `x-vless06-GRPCTLS` | VLESS | grpc | TLS | ✅ 200 |
| `x-vmess01-WSTLS` | VMess | ws | TLS | ✅ 200 |
| `x-ss02-PLAIN` | SS2022 | tcp | none | ✅ 200 |
| `x-ss03-LEGACY` | SS(aes-256-gcm) | tcp | none | ✅ 200 |

**上下行分离的决定性证据**（Xray 客户端自己打印的两条腿）：

```
XHTTP is dialing to       tcp:<服务器 IPv4>:30004                 mode stream-up    ← 上行 IPv4
XHTTP is downloading from tcp:[<服务器 IPv6>]:30004               mode stream-down  ← 下行 IPv6
```

同一个 inbound、同一个端口，**两条完全独立的网络路径**，HTTP/2，`http=200`。
这是"分离真的在发生"的硬证据 —— 不是"配置里写了 downloadSettings"。

**客户端兼容性矩阵（实测）**：

| 节点形态 | mihomo 客户端 | Xray 客户端 |
|---|---|---|
| VLESS + xhttp（含分离） | ✅ | ✅（含 downloadSettings） |
| Trojan + xhttp | ❌ **mihomo 的 xhttp 仅 VLESS 支持**（官方文档） | ✅ |
| SS + TLS / REALITY | ❌ **mihomo 的 ss 没有 TLS/REALITY 层** | ✅ |
| 其它 | ✅ | ✅ |

> 两条 ❌ 现在都是**明确拒发并说明原因**，不再生成一条"看着正常、连不上"的条目。
> ⚠ `mihomo -t` 对 ss+tls 是**放行**的，只有真连才发现不通。

---

## 五、还不支持的（诚实清单）

| 项 | 状态 | 说明 |
|---|:--:|---|
| **VLESS / Trojan `fallbacks`（回落）** | ❌ | 内核支持，面板没写。**最大的功能缺口** |
| XHTTP 的 `reuse-settings`（XMUX） | ❌ | 用户已明确否掉 X 的 mux 维度 |
| `xPaddingBytes` / `noSSEHeader` | ❌ | 服务端参数，默认值可用，未暴露 |
| 过 CDN 的 grpc（nginx 侧 `grpc_pass`） | ❌ | X 的 nginx 渲染只有 `proxy_pass` |
| `reality-cdn` 分离组合 | ❌ | 设计冲突，已实测确认 |
| Hysteria2 / TUIC / AnyTLS / NaiveProxy 服务端 | ❌ | **Xray 内核本身不支持**（SB/M 支持），不是本项目的缺陷 |

---

## 六、一句话推荐

| 场景 | 选哪档 |
|---|---|
| 新装、不要域名、抗 DPI 最强 | VLESS **① REALITY + Vision + 后量子** |
| 要过 Cloudflare | VLESS **④ XHTTP + TLS**（想藏 SNI 用 ⑤ + ECH） |
| 上下行要分开走不同路径 | 菜单 5 → 15 **上下行分离**（不是预置 ⑥；⑥ 只是 mode=stream-up） |
| 兼容老客户端 | ⑦ WS + TLS |
| 就想要个简单代理 | SOCKS5 ①（**仅内网**） |
| 想让 443 看起来像个正常网站 | 建节点时选 **回落** → 指向你的网站端口 |
| 抗弱网 / UDP 场景 | Hysteria2 ①，可开 **salamander 混淆** |
