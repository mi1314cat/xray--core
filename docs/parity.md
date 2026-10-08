# 三项目能力交叉核对

方向是单向的：**SB/M → Xray**。sing-box-core 是功能规格参考，mihomo--core
已归档，都不修改。

判据只有一条：**M 或 SB 有、且属于通用产品能力的，Xray 应当有**。

## 结果

| 能力 | SB | M | Xray | 判定 |
|---|---|---|---|---|
| 令牌消费 / TTL / 订阅服务 | ✓ | ✓ | ✓ | 已覆盖 |
| 分享链接生成 | ✓ | ✓ | ✓ | 已覆盖 |
| 订阅去重 | ✓ | ✓ | ✓ | 已覆盖 |
| nginx 幂等 / 回滚 | ✓ | ✓ | ✓ | 已覆盖 |
| 证书在用检测 / GC | ✗ | ✓ | ✓ | 本项目补齐 |
| 容器感知 | ✓ | ✓ | ✓ | 已覆盖 |
| DNS 段编辑 | ✓ | ✓ | ✓ | 本项目补齐 |
| 报错解释 | ✗ | ✗ | ✓ | 本项目独有 |
| 端口归属 / 替代建议 | ✓ | ✓ | ✓ | 本项目补齐（且比 M 更稳） |
| 协议推荐预置 | ✓ | ✓ | ✓ | 本项目补齐 |
| 服务名单一真源 | ✗ | ✓ | ✓ | 本项目补齐 |
| 验证套件 | ✓ | ✓ | ✓ | 三方都有，Xray 132 项 |
| 幽灵函数检测 | ✓ | ✓ | ✓ | 抄自 M 的 dl_route 教训 |

## 三个"看起来缺、其实不缺"

核对时容易误判的三个，逐个查证过：

**rules_bind（域名分流）** — M 有 `src/lib/rules_bind.sh`，Xray grep 不到同名
文件。但 Xray 的 `conf/split.sh` 就是分流规则管理（面板菜单 8），只是命名
不同。**假缺口。**

**dl_route（下载通道）** — 设定"拉订阅/下内核/开 UI 走不走代理"。不落在
17 项目标能力的任何一项上，是 M 针对自己客户端场景的补充。**不在范围。**

**webui（仪表盘）** — 给 `external-controller` 配可视化前端。清单里的 "UI"
指面板与 Client 的交互层，不是仪表盘；且 §7 要求不重建 Client UI。
**不在范围。**

## 真正的缺口（已补）

**cert_in_use / cert_gc** — M 有，SB 没有，Xray 原先也没有。证书被
片段 / nginx / 分享元数据任一处引用就删不得。已补，含子串误匹配的修复
（`nginxused.crt` 原本会命中 `used.crt`，导致 GC 一个也删不掉）。

**dns_edit** — M 有 `dns.sh` + `dns_edit.py`，SB 没有，Xray 原先没有。
Xray 的 dns 段是严格 schema，手改 config.json 改错了要等下次重启才发现。

**preset** — SB 12 处引用、M 15 处，Xray 零处。"该用哪种传输 + 加密"是产品
知识，VLESS 用户把 REALITY 配成 WS 的表现是"配置校验通过但永远连不上"。

**port_holder / port_suggest** — M 有，Xray 的 `x_port_in_use` 只回答是/否。
用户看到 "address already in use" 时真正要问的是"那是谁"。

**服务名单一真源** — M 有，Xray 原先在 `outbound.sh` 和 `split.sh` 各写一份
if/elif。

## 本项目比 M/SB 做得更宽的两处

**x_port_holder 的四级回退。** M 的 `port_holder` 只用 `ss -tlnp`。实测
`ss` 在无 netlink 的容器/精简环境里不可用（`Cannot open netlink socket`），
所以 Xray 加了 lsof / fuser / /proc 三级回退，拿不到就明确说"未知"而不是
编一个。

**报错解释的可用性。** `x_svc_explain_errors` 把内核报错翻成人话。这项 SB
和 M 都没有。

## 检测工具

```bash
python3 tools/check_wiring.py        # 幽灵函数: 从用户入口出发的可达性
bash tools/check_libs.sh             # 全部通用模块, 132 项
```

幽灵检测的来源是 M 的 dl_route 教训：菜单让你设、但没有任何代码会去用，
净效果比"没有这个功能"更糟。粗筛（"函数在文件里只出现一次"）对库不成立，
因为库里的函数互相调用是正常的；真正要问的是从任何用户入口能不能走到它。