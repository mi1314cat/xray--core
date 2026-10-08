# AUDIT-03 · Share/Pull 缺口与 Client 能力

> 审计日期：2026-10-08
> 核心结论：**Xray 的 Share 停在「单机单节点文本文件」，Pull 停在「一次性 curl 导入」。**
> Xray Client 与服务端**零代码耦合**，唯一通路是人工复制粘贴。

---

## 1. Share 现状

### 1.1 有：单节点分享链接（18 处生成点）

每个协议脚本各自生成本地文本文件，**逐协议确认过全部 15 个 `conf/*.sh`**：

| 脚本:行 | 协议 | 产物 |
|---|---|---|
| `conf/Reality.sh:407` | `vless://` Reality | `out/Reality-share-NN.txt` |
| `conf/Trojan.sh:386` | `trojan://` | `out/trojan-share-NN.txt` |
| `conf/Shadowsocks.sh:428` | `ss://` SIP002 | `out/ss2022-share-NN.txt` |
| `conf/hysteria2.sh:693,793` | `hysteria2://` | `out/hy2_share-NN.txt` |
| `conf/vlessxhttpecn.sh:1159` | `vless://` xhttp/ws + `ech=` | `out/${PROTO}_share-NN.txt` |
| `conf/vlessecn.sh:357` | `vless://` tcp | append `out/${PROTO}.txt` |
| `conf/vlesswsecn.sh:318` | `vless://` ws | append `out/${PROTO}.txt` |
| `conf/vlessxhttp_tls.sh:506` | `vless://` xhttp | append `out/${PROTO}.txt` |
| `conf/GDargo.sh:111` / `lsargo.sh:119` | `vless://` Argo | `out/GDargo.txt` / `lsargo.txt` |
| `conf/cconf.sh:194` / `nconf.sh:208` | `vless://`×N + `vmess://` | `out/Cv2ray.txt` / `Nv2ray.txt` |
| `reality_xray.sh:466` / `reality_xray_ip.sh:336` | `vless://` | 变量 `LINK` |
| `VEVLRE6.sh:592` | `vless://`×3 + `vmess://` | `v2ray.txt` |

**已确认不生成分享链接**：`vmessws.sh` `tunnel.sh` `sock5.sh` `http.sh`
`split.sh` `verify.sh` `XRevise.sh` `fd/xray*.sh`

### 1.2 无：全量订阅产物

- 唯一的聚合文件是 `out/hysteria.txt`（`hysteria2.sh:789-792` 去重 append），
  **只含 hysteria2**，纯文本 URI，非标准订阅格式
- `batch.sh:242-249` 只是把各协议的 share 文件 `sed` 到 stderr **打印**，不落聚合文件
- `xray-panel.sh` 菜单 3「查看客户端配置」= `cat out/*.txt`，**不是导出、不是订阅**

### 1.3 无：限次 / 过期 / 分享管理

全项目 grep `expires_at` / `max_uses` / `used_count` / 订阅 token：**零命中**。

### 1.4 QR 码：1 处且残缺

- `reality_xray.sh:111` 装了 `qrencode`，`:476` 输出到终端，
  但**存 PNG 的 `:477-478` 被注释掉了**
- `reality_xray_ip.sh:107` 装了 `qrencode` 但**无任何调用点**（dead code）

### 1.5 配置导出：只有单节点，无全量

- Xray JSON：各协议脚本的 `$PROTO-NN.json`
- mihomo/Clash YAML：各协议脚本手写 heredoc

**全部是「单节点一个文件」，无全量合并、无 proxy-groups、无 rules。**
且各协议手写的 YAML 片段 **schema 不统一**（这正是做聚合的最大障碍）。

---

## 2. Pull 现状

### 2.1 服务端没有 HTTP 分享服务

| 检查项 | 结果 |
|---|---|
| `nginx.sh:211-262` | server 块只有 `location /`（伪装站）+ WS/xhttp 反代，**无 root、无 autoindex** |
| `caddy.sh:210` | `root * /var/www/html` —— **不是产物目录**，拉不到任何东西 |
| `share_server.py` | 不存在 |
| `python3 -m http.server` | 不存在 |
| 分享服务 systemd unit | 不存在 |

对比：M 有 `share/share.sh:553` + `share_server.py`；SB 有 `conf/share_server.py`。

### 2.2 客户端拉取：只有一次性导入

`Client/lib/actions.sh:492-517` `cmd_node_subscription()`：
```
curl -sL --max-time 60 "$url" → node.py subscription → 逐个导入
```

限制：
- URL **用完即弃**（不落盘）
- 无订阅名、无 prefix 分组
- `while read` 里失败只 `>/dev/null` **吞掉错误**（`:513`）
- 不区分 HTTP 状态码（404/410/000 全部表现为"没有解析出节点"）

### 2.3 无订阅注册表

无 `subscriptions.json` 之类。节点直接落 `node-NNN-slug.json`，
**来源 URL 不保留** → 所以"更新某条订阅"根本无法实现。

### 2.4 无订阅更新、无自动更新

`cmd_node()` 的 11 项子命令（`actions.sh:278-292`）里**没有 `update`**。
无 `.timer` / 无 crontab 订阅任务。

---

## 3. Xray Client Web UI 能力

### 3.1 最重要的发现：**Client 与服务端零耦合**

- 全 `Client/` 目录 grep `xary|catmi|xrayls`，命中项**全部**指向
  GitHub raw 下载地址和"节点对端的服务端"（证书指纹探测）
- **没有任何一处是 xary-core 服务端 API**
- `xray-panel.sh:78` 的「客户端管理（xrayclient-reverse）」容易误判——
  那是 FRP 式反向隧道脚本，**不与 Client/ 面板交互、不下发节点**

**唯一实际通路是人工**：
```
服务端 reality_xray.sh:466 打印 vless:// 链接
      ↓ 用户手动复制
Client Web UI 导入框粘贴
```

### 3.2 Client 实际具备的能力

| 类别 | 能力 | 实现 |
|---|---|---|
| 节点 | 添加/删除/列表/选择/测速/探测 | `actions.sh` `node.py` |
| 节点 | 订阅导入、单文件导入 | `:492` |
| 节点 | 证书指纹自动固定 | `actions.sh:1871-1938` |
| 节点 | 协议能力判定 | `compat.py` |
| 节点 | Browser Dialer 实测探测 | `tools/browserprobe.py` |
| 端口 | 冲突自动重分配 | `lib/ports.py` |
| 服务 | 启停/重启/状态 | `:420-432` |
| 内核 | 管理/更新 | `lib/xrayup.py` |
| 出口 | `cmd_proxy` | |
| 证书 | `cmd_cert` | |
| ECH | `cmd_ech` | |
| 导出 | `act_conninfo` → mihomo.yaml | `panel.py:469-518` |
| Web UI | 1361 行 | `lib/web/panel.py` |

### 3.3 Client 的五项真实缺口

| # | 缺口 | 证据 |
|---|---|---|
| 1 | **订阅无管理/更新** | 11 项子命令无 `update`；URL 拉完即焚 |
| 2 | **不能对外提供配置** | `act_conninfo` 只导静态 YAML，**不含节点**，别人拿到也无法用 |
| 3 | **DNS/分流不可配** | `XBD_DOH` 安装时写死 `actions.sh:187`；`panel.py:116` 只读入 state，**PAGE 从未渲染**（全文件 grep `doh` 仅 1 处）。路由规则 `genconfig.py:304-332` 硬编码 |
| 4 | **Web UI 运维弱** | `act_service` 无 enable/disable，无开机自启；面板令牌无法更换；"改绑定地址"改的是代理入站不是面板 |
| 5 | **已实现但未暴露** | `diagnose` / `ech` / `config_update` / `node_use` 四个动作后端齐全、DISPATCH 已注册，**页面零按钮调用** |

> **第 5 项是最便宜的补齐项** —— 后端已经写好了，只差按钮。

### 3.4 一个方法论提醒

`DISPATCH` 有 4 个动作是死代码：**后端实现完整、注册完整、页面无入口**。
如果只读文档、或只列后端函数，会把这 4 项误报成"已有能力"。

这属于 M 项目里那个教训的同一类：**"看起来有"不等于"用户能用"**。

### 3.5 客观评价

Xray Client 在**单节点维度做深了**——协议能力判定、证书指纹自动固定、
Browser Dialer 实测、端口冲突自动重分配，这些 M/SB 无对等物。

但在**多节点、多端、长期运维中枢**维度上，还是单页小工具阶段。

---

## 4. 能力对比总表

| # | 能力 | Xray | M | SB | 缺口 |
|---|---|:---:|:---:|:---:|---|
| 1 | 单节点分享链接 | ✅ 18 处 | ✅ | ✅ | — |
| 2 | **全量订阅链接** | ❌ | ✅ | ✅ | **缺** |
| 3 | **一次性/限次分享** | ❌ | ✅ | ✅ | **缺** |
| 4 | **定时过期分享** | ❌ | ✅ | ✅ | **缺** |
| 5 | QR 码 | ⚠️ 1 处残缺 | ❌ | ❌ | 可选 |
| 6 | **全量配置导出** | ❌ 单节点片段 | ✅ | ✅ | **缺** |
| 7 | **服务端 HTTP 分享服务** | ❌ | ✅ | ✅ | **缺** |
| 8 | 客户端订阅添加 | ⚠️ 一次性 | ✅ | ✅ | 部分 |
| 9 | **客户端订阅更新** | ❌ | ✅ | ✅ | **缺** |
| 10 | **订阅自动更新开关** | ❌ | ✅ | ❌ | **缺** |
| 11 | **订阅自定义命名** | ❌ | ✅ | ✅ | **缺** |
| 12 | **拉取失败降级** | ❌ 静默吞错 | ✅ | ✅ | **缺** |
| 13 | **Client 对接服务端** | ❌ 人工复制 | ✅ | ✅ | **缺（最大）** |
| 14 | **Client DNS 可配** | ❌ 写死 | ✅ | ✅ | **缺** |
| 15 | Client 节点管理 | ✅ | ✅ | ✅ | — |
| 16 | Client 节点测速 | ✅ | ✅ | ✅ | — |
| 17 | Client 服务控制 | ✅ | ✅ | ✅ | — |

**M 和 SB 都没有的能力**：Xray 的证书指纹自动固定、Browser Dialer 实测探测。
这部分不要在补 Share/Pull 的过程中改坏。

---

## 5. 缺口实现建议

| 缺什么 | M 的参考实现 | 工作量 |
|---|---|---|
| **HTTP 分享服务** | `share/share_server.py:164-300`；**SB 版更精简** `conf/share_server.py:76-105` | 中等，建议抄 SB 版 |
| token 元数据与生命周期 | `share.sh:236-244` | 简单（纯 JSON + flock） |
| 限次/过期菜单 | `share.sh:192-213` | 中等 |
| 分享管理面板 | `share.sh:319,352,476,501` | 中等 |
| **客户端订阅注册表** | `client.sh:47,177-297` `subs_*` 全套 | 简单（一个 JSON + 4 函数） |
| **订阅更新 + 失败降级** | `client.sh:1072-1118` | 中等 |
| 订阅命名 + 来源前缀 | `client.sh:886-917` `node_prefix_names` | 中等 |
| **全量聚合订阅产物** | `build_sub.py` | **复杂**——各协议 YAML schema 不统一，需先统一 |
| Client DNS 可配 | `lib/dns.sh` | 中等 |
| Web UI 四个死代码按钮 | — | **很低**，后端已就绪 |
| CDN 档位 | `conf/all.sh` CDN 组 | 中等 |

### 建议顺序

```
share_server.py（抄 SB 版）
  → token 生命周期
  → 分享管理菜单
  → 客户端订阅注册表
  → 订阅更新 + 降级
  → 全量聚合产物（最重，先统一 YAML schema）
```

⚠ **不要**走 nginx/caddy 静态目录暴露 `out/` 那条捷径——
那会绕过 token 和限次机制，等于把订阅变成公开目录。

---

## 6. 一条来自 M 项目的教训

M 项目在 ECH 上栽过：客户端 DNS 的 `fallback-filter` 让全部 CDN 节点连不上，
而 mihomo **静默丢弃** DNS 查询，日志里没有任何一条指向 DNS。

同一类风险在这里也存在：`actions.sh:513` 用 `>/dev/null` 吞掉订阅拉取的错误，
**会导致"更新失败"表现为"订阅里没有解析出节点"**，用户完全看不出原因。

补 Share/Pull 时，所有拉取路径都要**区分 HTTP 状态码并显式报错**，
不要静默失败。这是这套项目里最高频的 bug 类型。