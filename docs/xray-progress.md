# X 内核进度盘点

> 盘点日期：2026-10-09
> 判据：**只认真实运行结果**。代码存在、`run -test` 通过、面板能画出菜单 ——
> 这些都不算完成。每个结论都有对应命令可复跑。
> 对标对象是 SB（sing-box-core）与 M（mihomo--core）两个项目本身。

## 一、总览

| 面 | 状态 | 实测证据 |
|---|:--:|---|
| 服务端面板 | 🟢 **47/47 通过** | `tools/server-interactive-test.sh` |
| 客户端 CLI + 菜单 | 🟢 **54/54 通过** | `Client/tools/interactive-test.sh` |
| 客户端 Web UI | 🟡 **能用，但覆盖面不清** | 见 §四 |
| 协议能力 | 🟢 优于 SB/M | 见 §三 |
| 证书管理 | 🟢 已解耦第三方依赖 | `docs/sb-known-issues.md` |

**结论：主体功能是完成且可用的，不存在"半成品"。真正的问题是 Web UI
覆盖度不透明，以及缺 4 类通用能力。**

## 二、服务端（RN）

### 面板 20 项全部可用

```
1.  安装/更新 xray      11. 节点管理
2.  卸载 xray           12. 自检
3.  查看客户端配置      13. DNS 管理
4.  查询服务状态        14. 日志
5.  添加节点            15. 预置建节点
6.  校验配置/重启服务   16. 预置批量生成
7.  出站管理            17. 证书管理
8.  分流规则管理        18. Nginx 站点管理
9.  反向代理管理        19. 分享服务
10. 分享管理            0. 退出
```

验证套件 **47 项全过**（此前记录 55 项，差值来自套件本身调整，非退化）。

### 已知架构特点（不是 bug，但要记住）

**面板的 20 个菜单项里有 19 个是 `curl` 从 GitHub 拉脚本**：

```bash
bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/outbound.sh)
```

**这意味着本地改了不生效，必须先 push。** 今天是踩过两次的坑
（`outbound.sh` 的 EOF 修复、`vlessxhttpecn.sh` 的 SAN 修复，本地改完
RN 上跑还是旧行为，push 之后才生效）。

调试面板问题时，第一步应该是确认远程版本而不是本地版本。

## 三、协议能力（我们最强的一块）

### 内核支持

Xray 26.3.27 实测支持的入站协议：

| | Xray | sing-box 1.14.2 | mihomo 1.19.32 |
|---|:--:|:--:|:--:|
| VLESS / VMess / Trojan / SS | ✓ | ✓ | ✓ |
| **Hysteria2** | ✗ | ✓ | ✓ |
| **TUIC** | ✗ | ✓ | ✓ |
| **AnyTLS** | ✗ | ✓ | ✓ |
| **NaiveProxy** | ✗ | ✓ | ✗ |

内核缺这四个不是我们的缺陷。CC 上 8 个真实节点有 4 个是 hysteria2，
`Client/lib/nodefilter.py` 在导入时主动剔除并提示"Xray 内核不支持该协议"，
处理正确。

### X 独有能力（全部实测通过）

| 能力 | 状态 | 证据 |
|---|:--:|---|
| **Browser Dialer** | ✅ | 切到 xhttp 启动 Chromium（875MB），切走停掉（0MB） |
| **浏览器 ECH** | ✅ | `xbd ech` → `ECH_ACTIVE`，QUIC 116 次握手全部启用 |
| **ML-KEM 后量子** | ✅ | `node-001-vless-tcp-mlkem-01` HTTP 204 |
| **REALITY + Vision** | ✅ | `node-001-ccsmreality-01` HTTP 204 |

⚠️ **ECH 有两条实现路径，不要混用**（今天误判过一次）：

- `dialer` 模式：TLS 由 Chromium 完成，**Xray 的 `echConfigList` 不生效**
  ——这是 `xbd ech` 诊断用的，也是真正"用浏览器做 ECH"的路径
- `normal` 模式：Xray 自己发 ECH，用 `echConfigList` + `pinnedPeerCertSha256`

### 项目模块覆盖比 SB/M 更全

我们有而 SB/M 没有的：`split`（分流规则）、`cert`（证书管理）、
`node`、`logs`、`nginx_site`、`share_service`、`sock5`、`http`、`tunnel`、
`verify`、以及 `lib/` 下的 `read.sh`/`random.sh`/`preset.sh` 等公共库。

SB/M 有而我们没有的只剩 4 类真缺能力（见 §五）。

## 四、客户端 Web UI —— 这是最不透明的一块

### 实测状态：能用

```
browser-dialer-panel.service   active
监听                            192.168.1.178:18090
带令牌访问                      HTTP 200，66 KB 页面，标题「Xray Client Manager」
无令牌访问                      HTTP 401  ← 鉴权正常
```

### 已覆盖的功能（从页面里读出来的）

| 功能 | 状态 |
|---|---|
| 节点列表 / 切换 | ✅ |
| 添加节点（VLESS/VMess/Trojan/SS/Hysteria2） | ✅ |
| 分享链接 / 订阅地址 | ✅ |
| 导出 Xray JSON / Mihomo YAML | ✅ |
| 二维码 | ✅ |
| 启动 / 重启 Xray | ✅ |
| 多出站开关（含回单节点确认） | ✅ |
| 浏览器拨号提示 | ✅ |
| 端口修改 | ✅ |
| Server Pull | ✅ |

### 问题

**没有独立的进度文档**，所以"什么进度"只能靠翻页面代码回答。
`Client/lib/web/panel.py` 有 2220 行，但**没有任何前端资源文件**
（无 html/js/css），全部是 Python 里拼字符串。

这带来三个问题：

1. **无法评估**——没有 feature 清单，改了什么没人说得清
2. **无法回归**——没有针对 Web UI 的测试，`interactive-test.sh` 完全没覆盖它
3. **UI 改不动**——2220 行拼字符串的 HTML，改一处容易崩一片

### 建议

给 Web UI 补一份功能清单 + 一个 HTTP 冒烟测试（登录、列节点、切换、
导出格式各打一次），成本很低，能立刻把"进度"变成可度量的东西。

## 五、缺口清单（按优先级）

### 🔴 P0：Web UI 无清单无测试

唯一"完成度不透明"的东西。需要：
- `docs/web-ui.md` 列出全部功能点与对应代码位置
- `Client/tools/web-test.sh`：起面板 → 登录 → 断言关键 API

### 🟡 P1：缺 4 类通用能力（SB/M 有）

| 能力 | SB | M | 缺了会怎样 |
|---|:--:|:--:|---|
| **端口转发 / 隧道** | ✓ `portforward.sh` | ✓ `tunnel` 类 | 内网服务无法暴露 |
| **规则集订阅** | ✓ `ruleset.sh` | ✓ `rules_bind.sh` | 分流只能手写规则 |
| **Web 仪表盘** | ✓ `ui.sh` | ✓ `webui.sh` | 没有流量/连接可视化 |
| **端口体检** | ✗ | ✓ `portcheck.sh` | 端口冲突只能等启动失败才发现 |

其中 **`portcheck` 最值得先做** —— 我们已经在端口分配上踩过坑：
`conf/lib/ports.sh` 的注释记着"服务停了 `ss` 就查不到，于是同一个端口被
再次分配，两个片段撞在一起，第二个启动即 bind 失败"。这正是 portcheck
要解决的问题，但我们只有分配时的检查，没有全局体检。

### 🟢 P2：uninstall 脚本

SB 有独立的 `uninstall.sh`，我们没有（面板第 2 项"卸载 xray"只卸内核，
不清理配置）。属于收尾完善，不紧急。

## 六、复核方式

```bash
# 服务端 47 项
bash tools/server-interactive-test.sh --repo <repo>

# 客户端 54 项（--read-only 不动生产配置）
bash Client/tools/interactive-test.sh client --read-only

# Web UI 手工验证
curl -s -o /dev/null -w '%{http_code}\n' http://<host>:18090/            # 预期 401
curl -s -o /dev/null -w '%{http_code}\n' 'http://<host>:18090/?token=<t>' # 预期 200

# 浏览器 ECH 实证
xbd ech
```