# AUDIT-01 · 项目结构与功能矩阵

> 审计日期：2026-10-08
> 审计对象：`mi1314cat/xary-core`（1017 次提交）
> 方法：只读审计，全部结论基于实际 grep / git / 代码阅读

---

## 1. 项目结构图

```
xary-core/
├── xray-panel.sh              主面板 (243 行) —— 9 项菜单
│
├── 协议脚本 conf/              每个协议一个脚本，独立可跑
│   ├── Reality.sh      514    VLESS+REALITY+Vision+ML-DSA
│   ├── Trojan.sh       532    Trojan+REALITY
│   ├── Shadowsocks.sh  579    SS-2022
│   ├── hysteria2.sh    923    Hysteria2
│   ├── vlessecn.sh     466    VLESS+TCP+ML-KEM        (菜单4)
│   ├── vlessxhttpecn.sh 1332   VLESS+xHTTP/WS+ML-KEM   (菜单6)
│   ├── vlesswsecn.sh   427    VLESS+WS+ML-KEM        ★ 孤儿
│   ├── vlessxhttp_tls.sh 615   VLESS+xHTTP+ML-KEM     ★ 孤儿
│   ├── vmessws.sh      268    VMess+WS               ★ 孤儿
│   ├── sock5.sh        303    SOCKS5（无加密）         (菜单3)
│   ├── http.sh         301    HTTP（无加密）          (菜单5)
│   ├── tunnel.sh       301    Tunnel                 (菜单1)
│   ├── GDargo.sh       132    固定 Argo              (菜单10)
│   ├── lsargo.sh       127    临时 Argo              (菜单11)
│   ├── batch.sh        290    全协议一键生成          (菜单12)
│   │
│   ├── verify.sh       157    配置校验               (菜单6)
│   ├── outbound.sh    2099    出站管理               (菜单7) ← 最成熟
│   ├── split.sh        419    分流规则               (菜单8)
│   ├── cconf.sh        421    C 端配置
│   ├── nconf.sh        358    N 端配置
│   └── XRevise.sh      241    密钥/UUID/shortid 生成（被外部脚本依赖）
│
├── 反向代理 conf/fd/           Xray 特有的 tunnel 反代
│   ├── xrayserver-reverse.sh  385   (菜单9→1) ★ 新一代
│   ├── xrayclient-reverse.sh  372   (菜单9→2) ★ 新一代
│   ├── server-reverse.sh      503   ★ 无引用
│   └── client-reverse.sh      432   ★ 无引用
│
├── 基础设施（根目录，未全部接进面板）
│   ├── reality_xray.sh    818    独立 REALITY 安装器 + QR
│   ├── reality_xray_ip.sh  465    多 IP 版
│   ├── nginx.sh / nginx6.sh 316/306   反代配置
│   ├── caddy.sh           249
│   ├── xargo.sh           298    Argo 隧道
│   ├── Conversion.sh      242    配置格式转换
│   ├── VEVLRE.sh / VEVLRE6.sh 230/614  v2ray 早期脚本
│   ├── ngcadall.sh        125    nginx+caddy 一键
│   ├── vlessxhttpecn.sh  1164    ★ 根目录与 conf/ 同名，重复？
│   ├── uninstall_xray.sh    5
│   └── upxray.sh            5
│
└── Client/                     独立维护的 Xray 客户端（已有成熟 Web UI）
    ├── RUN.sh / l.sh
    ├── lib/node.py     783   节点解析（订阅/URI）
    ├── lib/actions.sh 2119   全部命令实现
    ├── lib/state.py    332
    ├── lib/ports.py    283
    ├── lib/xrayup.py   240   内核管理
    ├── lib/web/panel.py 1361  Web UI
    └── service/ scripts/ bin/
```

**规模对比**：本项目约 16000 行 shell，`outbound.sh` 单文件 2099 行已超过 M 内核
`lib/env.sh` 的 1654 行——**Xray 的 Outbound 是全项目最成熟的模块，不要动。**

---

## 2. Server 功能矩阵

| 面板项 | 功能 | 对应脚本 | 成熟度 |
|---|---|---|---|
| 1 | 安装/更新 xray（自动检测版本） | 内联于 panel | ✅ |
| 2 | 卸载 xray | `uninstall_xray.sh` | ✅ |
| 3 | 查看客户端配置 | `show_xray_configs()` | 🟡 仅 `cat` 到屏幕，不是导出 |
| 4 | 查询服务状态 | `systemctl status xrayls` | ✅ |
| 5 | 添加节点（12 项） | `conf/*.sh` | ✅ |
| 6 | 校验配置/重启服务 | `conf/verify.sh` | ✅ |
| 7 | 出站管理 | `conf/outbound.sh` | ✅ **最成熟，不要重构** |
| 8 | 分流规则管理 | `conf/split.sh` | ✅ |
| 9 | 反向代理管理 | `conf/fd/` | 🟠 未实机验证（见 AUDIT-02） |

### 有实现但没接进面板

| 能力 | 位置 | 说明 |
|---|---|---|
| 证书签发/续期 | `nginx.sh` `caddy.sh` | 绑在反代脚本里，没有独立入口 |
| 端口批量分配 | 各协议脚本各自 `shuf` 随机 | **一个节点跑一次**，无区间管理 |
| 绑定核对 | **无** | 生成后不检查端口是否真绑上 |
| 分享管理 | **无** | 见 AUDIT-03 |
| DNS 配置 | `cconf.sh` `nconf.sh` 片段 | 无独立菜单 |

---

## 3. Client 功能矩阵

| 能力 | 命令 | 实现 |
|---|---|---|
| 安装 | `cmd_install` | `Client/lib/actions.sh` |
| 节点管理 | `cmd_node_add/remove/list/use` | 同上 |
| **订阅导入** | `cmd_node_subscription` | `actions.sh:492` |
| 导入文件 | `cmd_node_import_file` | 同上 |
| 导入单个 | `cmd_node_import_one` | 同上 |
| 节点测速 | `cmd_node_latency` | 同上 |
| 节点探测 | `cmd_node_probe` / `cmd_node_check` | 同上 |
| 节点选择 | `cmd_node_use` | 同上 |
| 浏览器拨测 | `cmd_node_browser` | 独立 timer |
| 出口管理 | `cmd_proxy` | 同上 |
| 端口管理 | `cmd_port` / `cmd_ports` | 同上 |
| 证书 | `cmd_cert` | 同上 |
| ECH | `cmd_ech` | 同上 |
| **导出** | `cmd_export` | `actions.sh:1804`，导出 mihomo.yaml |
| 服务控制 | `cmd_start/stop/restart/status` | 同上 |
| 内核管理 | `cmd_xray` / `cmd_update` | `lib/xrayup.py` |
| 诊断 | `cmd_diagnose` / `cmd_selftest` | 同上 |
| Web UI | `cmd_panel` | `lib/web/panel.py`（1361 行） |

**Client 侧的成熟度明显高于 Server 侧的 Share/Pull。**

---

## 4. 协议/传输矩阵

### 4.1 实际使用到的 Xray 特性

| 特性 | 取值 | 出现处 |
|---|---|---|
| `streamSettings.network` | tcp / ws / xhttp / raw | 全部协议脚本 |
| `security` | tls(14) / reality(11) / none(3) | 全部 |
| `flow` | `xtls-rprx-vision` / `none` | Reality |
| VLESS `encryption` | `mlkem768x25519plus.native.*` / `none` | ENC 系列 |

**未使用**：gRPC / kcp / mkcp / h2 / quic / httpupgrade
（gRPC 仅在 `outbound.sh` 里出现，不在入站）

### 4.2 三内核协议覆盖对照

| 协议/传输 | Xray | M(mihomo) | SB | 说明 |
|---|:---:|:---:|:---:|---|
| VLESS REALITY tcp | ✅ | ✅ | ✅ | X 带 Vision + ML-DSA |
| VLESS REALITY gRPC | ✗ | ✅ | ✅ | **X 缺** |
| VLESS REALITY xHTTP | ✗ | ✅ | ✅ | **X 缺** |
| VLESS TLS WS | ✗ | ✅ | ✅ | **X 缺**（脚本存在但没接菜单） |
| VLESS TLS xHTTP | ✅ | ✅ | ✅ | |
| VLESS TLS gRPC | ✗ | ✅ | ✅ | **X 缺** |
| Trojan REALITY | ✅ | ✅ | ✅ | |
| Trojan TLS/WS | ✗ | ✅ | ✅ | **X 缺** |
| Hysteria2 | ✅ | ✅ | ✅ | |
| TUIC v5 | ✗ | ✅ | ✅ | **X 缺**（Xray 内核无原生 TUIC） |
| AnyTLS | ✗ | ✅ | ✅ | **X 缺**（Xray 内核无原生 AnyTLS） |
| Shadowsocks 2022 | ✅ | — | ✅ | |
| VMess | 🟠 脚本在、没接菜单 | 已砍 | ✗ | 建议一并明确废弃 |
| **CDN 档位** | ✗ | ✅ (5个) | ✅ | **X 全缺，最大缺口** |

### 4.3 Xray 独有能力（护城河，不要动）

| 能力 | 实现 | M/SB |
|---|---|---|
| **VLESS Encryption（ML-KEM-768）** | `vlessecn.sh` `vlesswsecn.sh` `vlessxhttpecn.sh` | ❌ 都没有 |
| **REALITY ML-DSA-65 密钥** | `Reality.sh:278` 默认 `mldsa` | ❌ 都没有 |
| **Xray tunnel 反向代理** | `conf/fd/xray*.sh` | ❌ 都没有 |
| Cloudflare Argo | `GDargo.sh` `lsargo.sh` | ❌ 都没有 |
| XTLS Vision | ✅ | ✅ |

> ⚠ **兼容性约束**：`Reality.sh:388` 自己写了
> "M 内核需为支持 VLESS Encryption 的新版本；旧版 M 内核请选纯 X25519 模式"。
> 所以**默认档位不能带 ENC/ML-DSA**，否则同一个订阅喂给 M 客户端会连不上。
> ENC 必须是可选项。

---

## 5. 协议缺口结论

**缺的不是深度，是面。**

Xray 已有 M/SB 都没有的后量子能力，但缺少：

1. **CDN 档位全缺** —— M 有 5 个（xHTTP-CDN / VLESS-CDN-WS / Trojan-CDN-WS 等），
   X 一个都没有。这是缺口最大、最明显的一项。
2. **VLESS + WS + TLS** —— 脚本 `vlesswsecn.sh` 已存在，只是没接进菜单
3. **VLESS + gRPC + REALITY** —— 兼容性最好的传输之一
4. **Trojan + WS** —— Trojan REALITY 已在，WS 是回退

**不需要补的**：TUIC / AnyTLS（Xray 内核没有原生支持，补了也是死的）、
VMess（M 项目已实测砍掉，性能不如 VLESS 且特征明显）。