# AUDIT-02 · conf/fd 审计与废弃候选

> 审计日期：2026-10-08
> 原则：**禁止仅凭"看起来没有调用"就删除。** 以下每条结论都有 git / grep 证据。

---

## 1. conf/fd 四脚本完整审计

### 1.1 审计总表

| 脚本 | 首次提交 | 最后提交 | 行数 | 面板可达 | 外部引用 | 结论 |
|---|---|---|---|---|---|---|
| `xrayserver-reverse.sh` | 2026-09-02 | 2026-09-02 | 385 | ✅ 菜单9→1 | 仅 panel | **保留** |
| `xrayclient-reverse.sh` | 2026-09-02 | 2026-09-02 | 372 | ✅ 菜单9→2 | 仅 panel | **保留** |
| `server-reverse.sh` | 2026-05-20 | 2026-05-21 | 503 | ❌ | **无** | **实验性保留** |
| `client-reverse.sh` | 2026-05-20 | 2026-05-20 | 432 | ❌ | **无** | **实验性保留** |

用户的情报完全属实：**两个是 5 个月前（2026-05-20），一对是 1-2 个月前（2026-09-02）。**

---

### 1.2 逐脚本 12 项审计

#### ① `xrayserver-reverse.sh` —— 新一代服务端

| 审计项 | 结果 |
|---|---|
| 1. Git 历史 | `28d8160` 2026-09-02，`Add files via upload`（一次性提交） |
| 2. 最后修改 | 2026-09-02，1 个月前 |
| 3. 谁调用 | `xray-panel.sh:83` 菜单 9→1 |
| 4. 谁引用它 | `xrayclient-reverse.sh:287` 仅在提示文案里提 |
| 5. README 提及 | ❌ 未提 |
| 6. 环境变量依赖 | `REV_BASE_DIR` `REV_SERVER_ADDR`（都有默认值，可独立跑） |
| 7. service 依赖 | **`xrayls.service`** —— 无独立进程，片段并入主服务 |
| 8. 其他目录调用 | ❌ 无 |
| 9. 实机使用痕迹 | ⚠️ 用户自述"没有做过真实长期实机验证" |
| 10. 可独立运行 | ✅ `bash -n` 通过；支持 `REV_BASE_DIR=/tmp/xrev bash x` 测试 |
| 11. 当前 Xray 是否支持 | ✅ 用 `protocol: tunnel` 入站 + VLESS `reverse` tag，是 Xray 反代的标准做法 |
| 12. 实际价值 | 高——Xray 独有的能力，M/SB 都没有 |

**关键特性**：
```json
{ "protocol": "tunnel", "tag": "..." }      ← 回流入口
{ "protocol": "vless", "settings": {"clients":[{"reverse":{"tag":"..."}}]} }
```

---

#### ② `xrayclient-reverse.sh` —— 新一代客户端

| 审计项 | 结果 |
|---|---|
| 3. 谁调用 | `xray-panel.sh:84` 菜单 9→2 |
| 5. README 提及 | ❌ 未提 |
| 6. 环境变量 | `REV_BASE_DIR` `PUSH_SERVER_PORT` |
| 7. service 依赖 | `xrayls.service` |
| 9. 实机痕迹 | ⚠️ 同上 |
| 10. 可独立运行 | ✅ |
| 11. Xray 支持 | ✅ `protocol: freedom` 出站 + VLESS `reverse` |
| 12. 价值 | 高 |

**设计意图**（脚本头注释）：
```
xrayclient-reverse.sh — 反向代理【客户端】(主动回连侧)
  运行在 RN/有服务的机器上，主动回连服务端(家)，把本机某个服务端口通过反向隧道暴露给服务端入口
xrayserver-reverse.sh — 反向代理【服务端】(公网入口侧)
  运行在"家/公网入口"机器，接收 RN(客户端) 回连
```

> 注：注释里写的"对应 gostc.sh / gosts.sh"在本仓库中**不存在**，
> 说明这两个脚本是从 gost 版本的思路移植过来的。

---

#### ③ `server-reverse.sh` —— 第一代服务端

| 审计项 | 结果 |
|---|---|
| 1. Git 历史 | `e440f0d` 2026-05-20 创建，此后 5 次更新，最后 `90d174c` 2026-05-21 |
| 3. 谁调用 | **无**。grep 全项目（含 README / docs / 子目录）无任何引用 |
| 5. README | ❌ 未提 |
| 6. 环境变量 | **无**（无任何 `${VAR:-}` 形式的依赖） |
| 7. service | **无**（不依赖 `xrayls.service`，自己起进程） |
| 10. 可独立运行 | ✅ 语法通过 |
| 12. 价值 | **不确定**——功能已被新一代覆盖，但实现方式不同 |

**它和新一代的差异（关键）**：

```jsonc
// 第一代：portal 用 socks 入站
{ "protocol": "socks", "tag": "$portal", "settings": {"auth":"noauth"} }

// 新一代：portal 用 tunnel 入站
{ "protocol": "tunnel", "tag": "..." }
```

第一代是**完整实现**（有 `menu()` `add_config()` `list_configs()` `delete_config()`
`generate_mlkem()` `show_vless_links()`），不是残稿。

---

#### ④ `client-reverse.sh` —— 第一代客户端

同上，与 ③ 配对。`add_config()` `list_configs()` `delete_config()` 齐全，
`delete_config` 会清理 `conf` 片段并重启。

---

### 1.3 为什么不能直接删掉第一代

第一代**不是残稿**，它是完整可运行的实现。判定为"实验性保留"而非"明确废弃"，
理由：

1. ❌ 不满足"确认存在明确替代且新版已被实际使用"——
   新一代虽然接进了面板，但**你自己说没做过真实长期实机验证**。
   在没有替代品实测证据之前，删掉第一代等于毁掉唯一的备份。
2. ❌ 不满足"确认删除不会破坏现有功能"——
   万一有用户按 README 之外的方式直接 curl 了老脚本（老脚本在仓库里躺了 5 个月），
   删掉就是静默断链。
3. ✅ 满足"无任何调用"——但这一条**单独不足以判定废弃**。

**结论**：`server-reverse.sh` / `client-reverse.sh` → **实验性保留**。
移入 `conf/fd/legacy/`，README 注明"已被 tunnel 版取代，待实机验证新版后再议"。
不删。

---

## 2. Xray 反向代理：是否值得作为独立功能保留

### 2.1 它解决什么问题

让**没有公网 IP 的内网机器**（如家里的设备、RN）主动回连有公网入口的机器，
把内网的某个服务端口通过隧道暴露出去。反向隧道，避免内网穿透。

### 2.2 官方支持状态

✅ **Xray 官方仍然支持**。用到的是 Xray 的 `reverse` 特性：
- 服务端：VLESS 入站，clients 里带 `reverse: {tag}`，配一个 `tunnel` 入站
- 客户端：VLESS 出站带 `reverse.tag`，配一个 `freedom` 出站

这是 Xray 内核的原生功能，不是脚本自己造的东西。

### 2.3 与 Nginx 的冲突

⚠️ 需要验证但本次未验：服务端脚本依赖 `nginx`（`grep` 显示调用 nginx）。
`xrayserver-reverse.sh` 同时操作 `xrayls.service` 和 nginx 配置，
**如果它改的是同一个站点配置、而你的站点里还有 SB-Panel 的 CDN 段落
（生产机 nginx 上确实有），存在互相覆盖的风险。**

> 这是第二阶段必须实机验证的第一项。

### 2.4 结论

**作为 `experimental / advanced` 功能保留**，理由：
- 能力真实且 Xray 独有
- 但未实机验证
- 建议接入面板时**标注 experimental**，并在 README 写清用途和限制

---

## 3. 全项目废弃脚本候选

> 判定"明确废弃"必须同时满足 6 条（见审计要求）。以下为候选，**未删除任何文件**。

### 3.1 明确候选

| 脚本 | 最后提交 | 引用情况 | 替代方案 | 判定 |
|---|---|---|---|---|
| `conf/vlesswsecn.sh` | 2026-05-07 | **无任何引用** | `vlessxhttpecn.sh`（1332 行，已含 WS 分支） | 明确废弃候选 |
| `conf/vlessxhttp_tls.sh` | 2026-05-07 | **无任何引用** | `vlessxhttpecn.sh` | 明确废弃候选 |
| `conf/vmessws.sh` | 2026-05-06 | **无任何引用** | 无（M 已砍 VMess） | 明确废弃候选 |
| `conf/fd/server-reverse.sh` | 2026-05-21 | **无任何引用** | `xrayserver-reverse.sh`（未实测） | 实验性保留 |
| `conf/fd/client-reverse.sh` | 2026-05-20 | **无任何引用** | `xrayclient-reverse.sh`（未实测） | 实验性保留 |

**前三个的性质已查清**：
- `vlesswsecn.sh` (VLESS-WS-MLKEM, 427 行) 与 `vlessxhttp_tls.sh`
  (VLESS-xHTTP-MLKEM, 615 行) 被合并进了 `vlessxhttpecn.sh`（1332 行，同时支持
  ws 和 xhttp 两种 `$xray_linktype`）。合并后这两个就成了孤儿。
- `vmessws.sh` 是 VMess+WS。M 内核已实测砍掉 VMess（特征明显、性能不如 VLESS、
  两个 VMess-CDN 节点实测不通），X 侧同批砍掉是一致的。

### 3.2 成对脚本关系（尚未判定）

| 一对 | 关系 | 需要确认 |
|---|---|---|
| `nginx.sh` (316) / `nginx6.sh` (306) | 大概率 IPv4/IPv6 双版本 | 有无自动选择逻辑？ |
| `VEVLRE.sh` (230) / `VEVLRE6.sh` (614) | 同上？ | 6 版行数翻倍，是否含更多功能 |
| `reality_xray.sh` (818) / `reality_xray_ip.sh` (465) | 单 IP / 多 IP | 是否都还需要 |

**这三对本次未下结论**，需要逐对比对后再判。第二阶段处理。

### 3.3 疑似重复

| 文件 | 说明 |
|---|---|
| `vlessxhttpecn.sh`(根, 1164 行) vs `conf/vlessxhttpecn.sh`(1332 行) | **同名不同路径，行数不同** —— 疑似分叉，需要比对 diff |

---

## 4. 本节结论

1. **conf/fd 四个脚本一个都不删。** 新一代保留并接入，第一代移入 `legacy/` 标注。
2. 明确废弃候选 3 个（`vlesswsecn.sh` `vlessxhttp_tls.sh` `vmessws.sh`），
   但**第二阶段删除前要再做一次确认**：确认 `vlessxhttpecn.sh` 真的覆盖了
   WS 和 xhttp 两种传输，且能生成可用的分享链接。
3. 反向代理作为 **experimental** 功能保留，第二阶段实机验证 nginx 冲突。