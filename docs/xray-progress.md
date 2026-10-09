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
| 证书管理 | 🟢 已解耦第三方依赖 + 本轮修掉 3 处 | `docs/sb-known-issues.md` |
| 分享 | 🟢 **已改走公共基础服务** (2026-10-09) | 见 §二之三 |
| 通用库自检 | 🟡 `check_libs.sh` 253/254 | 唯一失败是**既有的**幽灵函数门禁, 见 §七 |

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

### 二之三、分享已改走公共基础服务（2026-10-09）

**改动**：`conf/lib/share_server.py` + `xray-share.service` 已删除，
分享的存储与生命周期归 **proxy-share-service**（M / SB / X 共用），
provider 固定 `xray`。

- `conf/share_client.py` —— 适配器（从 SB 那份参考实现复制，provider 改 xray）
- `conf/lib/share_payload.py` —— 载荷构建（从 share_server.py 原样抽出，
  创建与刷新共用**同一份**实现）
- `conf/share.sh` —— 面板 6 项菜单与文案不变；菜单 6 改成管公共服务
- `conf/share_service.sh` —— 菜单 19 改成管公共服务；**故意没有"停止/卸载"**
  （公共服务的生命周期不属于任何单个内核，从 X 的面板停掉会连带打断 M/SB）
- 收口点：`share_refresh_hook` 挂在面板层（协议脚本各写各的收尾，没有统一点；
  而面板是唯一入口）

**载荷格式一字未改**：base64 的订阅行。但**路径变了** —— 本地服务端发
`/sub/<token>`，公共服务发 `/share/<token>`（与 M/SB 统一）。老链接失效。

**实测（RN 真机）**：

```
载荷  纯 base64，解码后是 vless:// 订阅行
计次  拉取一次 used 0→1；HEAD 不消耗
保鲜  改节点元数据后 refresh，已发链接内容跟着变（token/URL 不变）
隔离  mihomo=1 / sing-box=1 / xray=2；X 拿 M 的 token 读 → 404
```

**实测中修掉的三个问题**（都是"看起来正常、实际不通"那一类）：

1. 链接主机名取的是 `api.ipify.org` 的答案 —— 那是**出站出口**。RN 上 WARP
   开着，生成出来是 `104.28.201.80`，而入站是 `107.173.154.178`，客户端
   照着连必然不通。改成取自节点自己的 `share_meta.host`。
2. `share_list` 用了两条 stdin 重定向（heredoc + 进程替换），后者覆盖前者，
   python 把 JSON 当脚本执行 → `name 'true' is not defined`。
3. 适配器的 `update` 漏了 `--max-uses` / `--expires-at`（服务端 PUT 本来
   就支持），于是"改次数上限 / 改有效期"**静默无效** —— argparse 报错退出，
   调用方把 stderr 丢掉当成功了。

**迁移**：`bash conf/share.sh migrate` —— 本地 token 搬进公共服务；
**已过期/已用尽的直接删掉不搬**（搬过去也只是占地方，清理器下一轮会删）。
RN 上没有历史分享，这条路径是干净的。

---

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

### 与分享迁移的关系：**零耦合**（2026-10-09 核实）

担心的是"改服务端分享会不会把自研 Web UI 弄坏"。核实结论：**不会**。

- `panel.py` 是**薄 HTTP 壳** —— 动作都走 `sh(args)` 出去调客户端 CLI，
  没有自己一套实现（所以服务端怎么改都碰不到它）
- 它唯一与分享沾边的地方是 **Server Pull**：把「地址 + 路径」拼成一个 URL
  丢给 `import`，**与 URL 形状无关**。而且它的占位符写的就是 `/share/xxx`
  —— 迁移后反而**对上了**（旧的服务端路径是 `/sub/<token>`）
- 它**不碰** `conf/lib/share_server.py`（那是服务端的分享服务，已删），
  也不碰 `Client/lib/share_server.py`（那是**客户端自己**的内容分发，
  发 `/share/<token>`，一行未动）

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

---

## 七、既有的门禁问题（本轮发现，未修）

### `check_libs.sh` 唯一失败项：幽灵函数门禁有假阳性

```
库函数 49 个, 从用户入口可达 43 个, 不可达 6 个
  幽灵: random_pass / random_path / random_token / random_user  (random.sh)
  幽灵: xr_choice / xr_read                                       (read.sh)
```

**这 6 个在改动前就存在**（用 `git worktree add` 在干净 HEAD 上复跑确认过，
两边都是 6 个），而且**至少 3 个是假阳性**：

- `random_user` / `random_pass` 被 `conf/http.sh:198-199`、`conf/sock5.sh:198-199`
  **实际调用**，而这两个脚本就挂在面板第 5 项的子菜单里（`xray-panel.sh:239/249`）
- `xr_read` 被 `safe_read` 调用，而 `safe_read`/`clean_input` 全项目有 **264 处**引用

根因在 `tools/check_wiring.py:97`：*"只有被 tools/check_libs.sh 直接 source
的库才算入口"* —— 而这两个脚本是通过 `source "$_x_lib_dir/lib/random.sh"`
（**变量路径**）加载的，检测器的 source 边解析不了这种形式，于是把整条链
当成不可达。

**影响**：门禁长期红着，人就学会忽略它 —— 真出现幽灵函数时没人看。
**建议**：让 `sources_of()` 支持 `$VAR/lib/xxx.sh` 与 `source <(curl …)`
两种形式；或至少在报告里区分"确认不可达"与"路径解析不了，无法判定"。
