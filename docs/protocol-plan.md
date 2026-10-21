# 协议规划 —— 对标 SB 的「每个协议都有推荐搭配 + 自己逐项配」

> 写于接手第二轮。判据是**跑出来的结果**，不是设想。
> 当前数据：`X_PRESETS` 30 档 / 7 协议 / 4 个推荐档位。

---

## 一、SB 那边到底是什么结构（要学的是这个）

| 层 | SB 的做法 | 出处 |
|---|---|---|
| 协议入口 | 主菜单**一个协议一项**（Reality / VLESS / VMess / AnyTLS…） | `sing-box.sh:261-304` |
| 推荐搭配 | `SB_PRESETS` 表格，字段 `协议\|id\|显示名\|传输\|mux档\|flow\|证书\|说明\|标签\|额外` | `lib.sh:1561-1617` |
| 显示 | 编号 + 中文卖点 + 一句话说明，**每行还有实测依据** | `lib.sh:1550-1555` |
| 手工路径 | 预置菜单最后一项：`不用预设, 我自己逐项配 (回答每一个问题)` | `lib.sh:1672` |
| 预置语义 | **预置只预填答案**，后续每一步仍可改（"下面仍会逐项确认, 想改直接选别的即可"） | `lib.sh:1726` |
| 防呆 | 16 条冲突检查，**在建配置之前**拦（不是校验时报错） | 见 §三 |

一句话概括 SB 的设计哲学：

> **推荐搭配是"默认值"，不是"快捷键"。** 用户永远能走到底，也永远能改。

---

## 二、X 现在有什么、缺什么

### 已经有（质量不差，不要重做）

- `X_PRESETS` 30 档，覆盖 vless(12) / trojan(5) / vmess(4) / shadowsocks(3) / hysteria2(1) / socks(2) / http(2)
- **4 档推荐度**：`core` / `cdn` / `compat` / `special`，全协议一键生成只取 core+cdn
- 每档带 `[档位] 一句话说明`，推荐档打 `★`
- 护栏（**比 SB 更贴内核**，全部有源码/实测依据）：
  REALITY 传输白名单、flow 只裸 TCP、xhttp mode 四值、
  `stream-one`×`downloadSettings` 互斥、下行端口/路径必须与上行一致、
  绝不用 `extra`、kcp 已移除、TLS 无证书拒绝建

### 缺（这就是要做的规划）

| # | 缺口 | 影响 |
|---|---|---|
| G1 | **没有「不用预设，我自己逐项配」** | `x_preset_ask` 里 `0`/空 = 取消；用户想要一个表里没有的组合时，无路可走 |
| G2 | **预置不是"预填默认值"** | 选了 ④ 就直接按 ④ 的参数生成，中间没有"想改就改"的机会（SB 每步都能改） |
| G3 | **护栏只作用于静态表** | 表外的手工组合没有护栏可拦 —— G1 一旦打开，护栏必须同时覆盖手工路径，否则是"开了门没装锁" |
| G4 | 预置档的**推荐依据没有进 UI** | SB 把实测依据（`裸TCP ✓3/3  WebSocket ✗0/3`）写进表里；X 的实测结论在 docs 里，用户看不到 |
| G5 | `reality-reality` 这档**菜单里没有** | 实测可用的第四种分离组合，只能手敲命令 |

---

## 三、规划（分三步，每步都要 pty 验证）

### 第 1 步：打开手工路径 + 把护栏做成"唯一判据"（G1 + G3）

**做法**（照 SB 的形状，但不抄代码）：

```
选择协议 → 预置档位列表
   1) ★① 隐匿优先 · REALITY + Vision + 后量子   [core] …
   …
  10)  ⑩ 裸 TCP + TLS                          [special] …
  11)  不用预设, 我自己逐项配 (回答每一个问题)      ← 新增
   0) 返回
```

选 11 之后逐项问：**传输 → 加密层 → 端口 → 接入档 → 凭据 →（xhttp）mode**，
**每一步都先过 `_preset_security_allows`**，非法组合当场拒绝并说明为什么
（复用现有白名单，**不新写第二份判据** —— 两份判据必然漂移）。

关键设计：**手工路径与预置路径走同一个生成器**（`node_build._check_combo`），
护栏只有一份。手工路径不是"绕过护栏的旁路"。

### 第 2 步：预置改成"预填默认值"（G2）

SB 的语义：选了 ④ 之后，后续每一步的默认值变成 ④ 的取值，但用户能改。
X 现在的做法是"选了就用"，中间没有确认与修改点。

改法：`x_preset_ask` 返回的 `tr/sec/enh` 不直接进生成，而是作为**默认值**
传给后续的 `safe_read` / `ui_ask_num`；用户回车即采纳，输入即覆盖。

这一步**必须小心**：它会改变现有交互（多几次回车）。所以先做第 1 步，
把手工路径跑通，再看用户对预置路径的反馈决定是否改。

### 第 3 步：把实测结论搬进 UI（G4 + G5）

- 每个预置档后面跟一行**实测状态**（✓ 已实测 / ⚠ 未实测 / ✗ 已知不通），
  数据来自 `docs/e2e-rn.md` + `docs/HANDOVER-known-issues.md`，不新造
- `reality-reality` 补进菜单 15 与 `batch.sh`（现在是 3/4，缺一个）

---

## 四、每个协议的推荐档矩阵（现状 + 规划）

标注：✓ 已实测连通 / ⚠ 未实测 / ✗ 已知不通

### VLESS（最强的一块）

| 档 | 传输 | 加密 | 推荐度 | 实测 | 定位 |
|---|---|---|---|---|---|
| ① | raw | reality | core ★ | ✓ | Vision + ML-KEM-768 + ML-DSA-65，全套后量子 |
| ② | tcp | reality | core ★ | ✓ | Vision（与 ① 等价，退掉后量子） |
| ③ | raw | none | special | ✓ | 后量子裸 TCP，延迟最低 |
| ④ | xhttp | tls | cdn ★ | ✓ | **官方主推**，CDN 首选 |
| ⑤ | xhttp | tls | cdn ★ | ⚠ | ④ + ECH + 后量子 |
| ⑥ | xhttp | reality | core ★ | ✓ | 上下行分开（mode=stream-up，**同一目的地**） |
| ⑦ | ws | tls | compat | ✓ | 官方已弃用，仅兼容 |
| ⑧ | grpc | tls | compat | ✓ | 官方已弃用 |
| ⑨ | httpupgrade | tls | compat | ⚠ | 官方已弃用 |
| ⑩ | tcp | tls | special | ✓ | 最易被识别 |

### Trojan / VMess / Shadowsocks / Hysteria2 / SOCKS / HTTP

| 协议 | 档数 | 推荐首档 | 备注 |
|---|---|---|---|
| trojan | 5 | `tcp + reality` (core) | 与 VLESS 口径一致 |
| vmess | 4 | `xhttp + tls` (cdn) | ⚠ **mihomo 的 xhttp 仅 VLESS 支持** → 这一档的 mihomo 产物生成不出来（已如实报因，不静默） |
| shadowsocks | 3 | `tcp + reality` (core) | SS2022 密码长度按算法校验 |
| hysteria2 | 1 | UDP + TLS | Xray 内核用 `protocol: hysteria` + `version: 2` |
| socks / http | 各 2 | special | 仅内网，不进默认全协议 |

### 上下行分离（菜单 15，用户点名要的三组）

| 组合 | 上行 | 下行 | 实测 |
|---|---|---|---|
| `cdn-cdn` | CDN(TLS) | CDN(TLS) | ✓ |
| `cdn-reality` | CDN(TLS) | REALITY 直连 | ✓ |
| `reality-reality` | REALITY 直连 | REALITY 直连 | ✓（**菜单里还没有 → G5**） |
| `reality-cdn` | REALITY 直连 | CDN(TLS) | ✗ **设计冲突**（同 inbound 硬约束），菜单已如实提示并给替代 |

---

## 五、明确**不做**的事

- **不重写**现有 30 档预置表（它是对的，只是缺入口）
- **不引入 SB 的 mux 档位**（用户已明确否掉 X 的 mux 维度）
- **不把 YAML/JSON 配置逻辑从 SB/M 抄过来**（学交互，不抄配置）
- **不为手工路径新写一套护栏** —— 复用 `_preset_security_allows` + `node_build._check_combo`

---

## 六、验收方式（这一条是硬要求）

每一步都用 `tools/pty_journey.py` **真按键走一遍**，而不是静态检查：

```bash
python3 tools/pty_journey.py --repo . --keys "1 13 1 11 2 3 ..." --screen 40
```

判据（顺序即优先级）：

1. 走完之后**产物真的在磁盘上**（片段 + 分享元数据 + mihomo YAML）
2. 片段过 `xray run -test` **且** mihomo YAML 过 `mihomo -t`
3. 屏幕上**没有**提示与行为相反的文案
4. 非法组合**在生成之前**被拒，且说清为什么
5. 全程没有 `command not found` / `unbound variable` / 卡住

> 第 1 条是这轮加上的，因为菜单 13 曾经"屏幕上有完整 JSON、有完成提示、
> 退出码 0，磁盘上一个文件都没有"—— 静态检查和单元测试都发现不了。
