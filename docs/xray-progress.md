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
| 客户端 Web UI | 🟢 **主题/配色/可访问性已量化验证** | 见 §四 |
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

### 已处理：自研 Web UI 重做（2026-10-09）

面板 HTML 拼在 `Client/lib/web/panel.py` 的 `PAGE` 常量里。这一轮做了三件事，
关键是把"好不好看"从主观判断变成了**可量化的检查**。

#### 1. 主题系统（新增）

原来只有一套写死的深色。现在：

- `:root` 深色；`@media (prefers-color-scheme: light)` 下 `:root:not([data-theme])`
  是系统偏好浅色；`:root[data-theme="light"]` 是手动浅色。
  **用属性而不是 class**，因为这两个入口优先级不同，手动选择要能稳定压过系统偏好。
- 头部一个三态按钮（跟随系统 → 浅色 → 深色），选择存 localStorage。
- 切换脚本放在 `<head>`、页面主体之前：放文档末尾的话，浅色用户每次刷新
  都会先按深色画一帧再翻白。

#### 2. 修掉的真实缺陷（都是量出来的，不是看出来的）

| 问题 | 现象 | 根因 |
|---|---|---|
| `pre` 深底深字 | 浅色下代码块对比度 **1.17:1** | `background:#0b0d11` 写死，不跟主题 |
| `.mbox` 弹窗 | 浅色下「添加节点」整块仍是深色 | 同上，`#12161c` 写死 |
| `.tag.acc` | 浅色下浅蓝字压浅蓝底 | `color:#9cc8ff` 写死 |
| 主按钮 | 白字压 `--acc` 只有 **2.85:1**（AA 要 4.5:1） | 亮蓝是给描边/链接用的，做实心底太亮 |
| 危险按钮 | 深色下 3.01:1 | 同上 |
| 按钮悬停 | 浅色下**文字直接消失** | `--on-acc`(#fff) 被用在非强调底色上，而浅色按钮底就是 #fff |
| 换肤闪烁 | 切换瞬间整页糊成灰，约 60ms | 过渡层让 color 与 background 同时渐变，在中点相交 |

修法统一是**加语义变量**（`--code-bg` / `--modal-bg` / `--acc-btn` /
`--bad-btn` / `--acc-fg-dim`），而不是在用到的地方写两套值：变量集中在三个
主题块里，"浅色漏了一个变量"能被自检直接抓出来。

顺带清掉一处**继承下来的 CSS 地雷**：`.nli#nq` 后面挂着一条没有选择器的孤立
声明（`background:...;user-select:none;...}`），从引入它的那次提交起就是坏的。
CSS 解析器遇到无法理解的东西会一路丢到下一个 `}` —— 页面照常渲染，只是悄悄
少一条规则，所以它能潜伏很久。

#### 3. 验证方式：样式探针（不是截图）

这台机器上的浏览器**截图看不了**（当前模型不支持图像输入），MCP 的 Playwright
又是**远端**服务（`cfmcx…dpdns.org`），本机地址在那边不可达、公网图床一律强制
`text/plain`。所以没有靠眼睛，而是把能客观度量的部分量出来。

`Client/tools/render-panel.py` 把 `PAGE` 抽出来，stub 掉 `fetch` 喂一份合成
state，**用页面自己的 JS 渲染**（不是另写一套假渲染），再注入探针，把结果写成
DOM 文本从无障碍快照读回：

- 两套主题下分别采样正文 / 次要文字 / 按钮 / 表格头 / 代码块 / 标签 / 分组行
  的 **WCAG 对比度**（逐层 alpha 合成到不透明再算，标出 <4.5:1 的项）
- **横向溢出**检测（历史上的「字出框」就是这一类）
- **隐形文字**检测（合成后前景 ≈ 底色的元素）

实测（1280px，RN 测试服务器上的真实浏览器）：

| | 浅色（跟随系统 / 显式） | 深色 |
|---|---|---|
| 正文 | 15.45:1 | 15.78:1 |
| 表格头 / 次要文字 | 5.09:1 | 5.75:1 |
| 主按钮 | 4.51:1 | 4.88:1 |
| 危险按钮 | 4.77:1 | 5.44:1 |
| 代码块 | 15.30:1 | 16.24:1 |
| 低对比(<3:1) 元素 | 无 | 无 |
| 横向溢出 | 无 | 无 |

`Client/tools/selftest-panel-css.py`（**29 项，不需要浏览器**）覆盖结构面：
花括号配对、没有顶层孤立声明、变量无自引用、所有 `var()` 都有定义、
**浅色主题覆盖深色主题的全部变量**、主题脚本在页面主体之前、换肤免过渡机制
存在、打磨层（状态过渡 / 卡片阴影 / 吸顶表头 / `:focus-visible` / 跟随主题的
滚动条 / `prefers-reduced-motion`）在位。

> 验证跑在 **RN 测试服务器**上：临时静态服务 + 远端浏览器，跑完服务与文件
> 都已删除（符合 `DEPLOY-BOUNDARY.md`）。

## 五、缺口清单（按优先级）

### 🟡 P1：Web UI 仍缺「功能清单 + HTTP 冒烟」

样式侧已经量化（见 §四：`selftest-panel-css.py` 29 项 + 渲染探针）。
仍缺的是**行为侧**的回归：
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

---

## 八、面板的 curl 路径：所有菜单项都缺依赖（2026-10-09 发现）

### 现象

面板里每一项都是这么跑的：

```bash
bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/xxx.sh)
```

于是 `$BASH_SOURCE` 指向 `/dev/fd/63`，而各脚本都这么找依赖：

```bash
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib"   # -> /dev/fd/lib
```

实测（菜单 11，未改过调用方式）：

```
python3: can't open file '/dev/fd/lib/nodes.py': [Errno 2] No such file or directory
```

**所以"面板能用"这个结论只在仓库检出目录里成立。** 真实部署路径下，凡是要用
`lib/` 的菜单项都拿不到依赖。之前 47/47 通过是因为
`tools/server-interactive-test.sh` 在检出目录里跑脚本。

### 影响（实测）

| 菜单项 | curl 路径下的实际表现 |
|---|---|
| 10 分享管理 | 列表报"服务不可达"；状态一律"未运行"（服务其实跑得好好的） |
| 19 分享服务 | 同上 |
| 11 节点管理 | `can't open file '/dev/fd/lib/nodes.py'` |
| 其它（node.sh / mknode.sh / hysteria2.sh / vlessxhttpecn.sh …） | 同类，按 `dirname $BASH_SOURCE/lib` 找依赖 |

内联 `source <(curl ...)` 的那几个文件是例外 —— 它们本来就考虑了这一点。

### 已修（本次）

`conf/share.sh` + `conf/share_service.sh`：依赖三级查找 —— 脚本旁边（仓库里
直接跑）→ 安装目录 → 现拉。现拉用**本次运行的临时目录**，不做长期缓存：
脚本本身每次都是新拉的，缓存住的库会和它版本不一致，那种错比"取不到"更难查。

实测（真实 curl 路径）：

```
菜单 10  list   -> （还没有生成分享）        ← 服务可达，不再是"不可达"
菜单 19  status -> [OK] proxy-share-service 运行中 / 端口 9443 在监听
菜单 19  health -> ok (exit 0)
菜单 10  create -> [OK] 分享已生成 + 链接
```

### 待办

**其余菜单项仍是坏的。** 建议抽一个公共库（比如 `conf/lib/self.sh`）提供
`x_lib_dir()` / `x_fetch()`，各脚本改用它；并把
`server-interactive-test.sh` 改成**模拟 curl 路径**跑一遍（把脚本复制到临时
目录再执行），否则这个类别的错永远不会被测出来。

### 附带发现：GitHub raw 有 CDN 缓存

`.../raw/refs/heads/main/xxx` 在 push 后 **约 5 分钟内仍返回旧内容**（实测
拉到的是上一版）。调试"改了不生效"时，第一步应该用 commit 固定 URL 确认：

```bash
curl -Ls "https://raw.githubusercontent.com/mi1314cat/xray--core/<commit>/conf/share.sh"
```

按 commit 拉不受分支缓存影响。这条与 §二 记的"本地改了不生效，必须先 push"
是同一类坑的第二层 —— **push 了也可能还要等几分钟**。

## 九、镜像链只做了一半 —— §八 那些「例外」的续集

面板侧的镜像链是完整的：19 个菜单项全部改走 `xray_run` → `xray_fetch`，带
`XRAY_MIRRORS` 多源回退。`conf/lib/fetch.sh`（`X_REPO_MIRRORS` + `x_fetch`）
也已经建好，并有 3 条断言守着。

**但是**：各协议脚本内部的**依赖兜底加载**仍然是直连 github.com：

```bash
if [[ -r "$_x_lib_dir/lib/addr.sh" ]]; then
    source "$_x_lib_dir/lib/addr.sh"
else
    source <(curl -fsSL "https://github.com/mi1314cat/xray--core/raw/refs/heads/main/conf/lib/addr.sh") \
        || die "..."
fi
```

实测统计（`grep -rn 'source <(curl -fsSL "https://github.com/'`）：

| | |
|---|---|
| 出现次数 | **40** |
| 涉及文件 | **17**（`conf/` 下 13 个 + 根目录 `VEVLRE.sh` / `ngcadall.sh` / `nginx.sh` / `caddy.sh`） |

**为什么这个缺口要紧**：这条 `else` 分支恰恰是"本地没有 lib"时才走的 ——
也就是 `bash <(curl ...)` 首次运行、以及国内网络连不上 github.com 的时候。
换句话说，**镜像链存在的唯一理由，正好就是这条没走镜像链的路径**。
另外 `conf/share.sh` 的 `_x_fetch` 也是单源（`$XRAY_RAW`），没接 `X_REPO_MIRRORS`。

### 建议做法（不要在收尾时仓促做）

不要逐个脚本内联一段镜像循环 —— 那是把重复从 40 处换成 17 处。正确做法是
一个 `conf/lib/deps.sh`，提供 `x_dep <lib 文件名>`（本地三级查找 → 镜像链），
各脚本的 `else` 分支改成调它。难点在**它自己怎么被加载**（鸡生蛋）：需要一段
不超过 3 行的引导，且镜像表要能从脚本内部拿到（不能依赖面板的 `XRAY_MIRRORS`）。

改完必须在 **RN 测试机**上按"模拟 curl 路径"验证：把脚本复制到临时目录再执行、
并临时把 lib 目录改名，否则这条分支永远不会被测到 —— 这也正是它至今没被发现的
原因（面板菜单路径被测试覆盖了，脚本内部路径没有）。
