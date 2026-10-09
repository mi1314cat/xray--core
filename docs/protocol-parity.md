# 三项目协议能力对比

> 生成日期：2026-10-09
> 判据：内核版本在测试机上**实测**得出，不抄文档。对比对象是三个项目本身
> （`xray--core` / `sing-box-core` / `mihomo--core`），不是内核官方文档。
> 实测环境：RN = 服务端（Debian 13 / x86_64），CC = 客户端（aarch64）。

## 内核版本

| 项目 | 内核 | 版本 | 部署位置 |
|---|---|---|---|
| xray--core | Xray | 26.3.27 | RN 服务端 + CC 客户端 |
| sing-box-core | sing-box | 1.14.2 | RN 服务端 + CC 客户端 |
| mihomo--core | Mihomo Meta | 1.19.32 | RN 服务端 + CC 客户端 |

## 一、内核本身支持什么（实测）

在 RN 上用 `xray run -test` 逐协议验证服务端入站。**注意**：VLESS 必须带
`"decryption":"none"`，否则报 `VLESS settings: please add/set "decryption"`
—— 探测时会误判成"不支持"。

| 协议 | Xray 26.3.27 | sing-box 1.14.2 | mihomo 1.19.32 |
|---|:--:|:--:|:--:|
| VLESS | ✓ | ✓ | ✓ |
| VMess | ✓ | ✓ | ✓ |
| Trojan | ✓ | ✓ | ✓ |
| Shadowsocks | ✓ | ✓ | ✓ |
| Hysteria2 | ✗ **（内核不支持）** | ✓ | ✓ |
| Hysteria v1 | ✓ | ✓ | ✗ |
| TUIC | ✗ **（内核不支持）** | ✓ | ✓ |
| AnyTLS | ✗ **（内核不支持）** | ✓ | ✓ |
| NaiveProxy | ✗ **（内核不支持）** | ✓ | ✗ |
| Snell | ✗ **（内核不支持）** | ✗ | ✓ |
| WireGuard | ✗ **（内核不支持）** | ✓ | 仅出站组 |

**这是最重要的一条结论**：Xray 内核缺 Hysteria2 / TUIC / AnyTLS / NaiveProxy
四个协议。而 `mihomo--core` 和 `sing-box-core` 都支持其中大部分。

我们项目对此的处理是正确的 —— `Client/lib/nodefilter.py` 在导入订阅时主动
剔除内核不支持的协议，提示用户"Xray 内核不支持该协议"。这不是缺陷。

## 二、项目层面对比

### 2.1 服务端协议模块

| | xray--core | sing-box-core | mihomo--core |
|---|---|---|---|
| 协议模块数 | 11（`conf/*.sh`） | 10 | 7 |
| 预置组合 | 见 `conf/batch.sh` | 35 | 19（全部双端实测） |
| 完成度文档 | `docs/parity.md`（通用能力） | README 矩阵 | `PROJECT_STATUS.md` ✅DONE/🟡/🔴 三态标注 |

sing-box 与 mihomo 都有**明确的预置方案计数 + 双端实测标注**。我们没有
这一层 —— `docs/parity.md` 只核对了通用产品能力（令牌/证书/DNS/报错解释），
**没有协议矩阵**。这是文档缺口。

### 2.2 mihomo--core 的实测完成表（值得抄的格式）

它用 `✅ DONE / 🟡 PARTIAL / 🔴 TODO / ⚠️ BLOCKED` 四态标注，每个组合都写
清"服务端生成 / 服务端监听 / 客户端拉取 / 客户端延迟 / 最终判定"，并把
**内核限制**和**本项目未做**分开列 —— 这个区分很重要，能避免后人把
"内核做不到"记成"我们没做"。

结论：**19 个组合全部双端实测通过，部分完成 0，未完成 0。**

## 三、Xray 独有能力（我们的差异化）

用户判断"我们跟别人不同的就是客户端这边多了一些 X 类和特殊的应用"。核对
结果：**这些确实存在，而且大部分已经做了。**

| 能力 | 只有 Xray 内核有 | 我们实现状态 | 代码位置 |
|---|:--:|---|---|
| **Browser Dialer** | ✓ | ✅ **完整** | `run-chromium.sh` + `run-xray.sh` + `compat.py` + 菜单 + 面板 |
| **ECH（内核原生）** | ✓ | ✅ **完整** | `Client/lib/echcli.py`（58 文件引用） |
| **ML-KEM 后量子** | ✓ | ✅ **完整** | `compat.py` 加密方案判定 + `genconfig.py` |
| REALITY | ✓ | ✅ 完整 | `conf/Reality.sh` + `GDargo.sh` |
| XHTTP 传输 | ✓ | ✅ 完整 | `conf/vlessxhttpecn.sh` |
| Vision 流控 | ✓ | ✅ 完整 | 13 文件引用 |
| **多出站 + balancer** | ✓ | ✅ 完整（默认关） | `genconfig.py` + `runtime/multi.actual` |

### 3.1 sing-box 那张表的 Xray 列是 ✗，但要读懂它

`sing-box-core/README.md` 的「客户端产物支持矩阵」里，Xray 一列大量是 ✗
（AnyTLS ✗、Hysteria2 ✗、TUIC ✗、内核 ECH ✗、CDN+ECH ✗）。

**但那是"从 sing-box 配置导出 Xray 产物"的跨内核转换能力**，不是说 Xray
客户端缺功能。区别在于：

- 那张表测的是：`to_mihomo.py` 这类**跨内核配置转换器**能不能把 A 内核的
  节点导出成 B 内核能吃的格式。
- 我们的 `Client` 是**直接用 Xray 内核跑**，不需要经过转换。Xray 支持的
  组合它直接就支持。

所以正确读法是：**✗ 的那几格，是"转换器覆盖不到"，不是"能力没有"。**
拿那张表对比"我们的客户端有没有 X 独有能力"是比错了对象。

### 3.2 真正属于"内核缺口"的部分

即便如此，Xray 内核确实缺四个协议（Hysteria2 / TUIC / AnyTLS / NaiveProxy）。
CC 上那 8 个真实节点里有 **4 个是 hysteria2**，也就是说：

> **我们客户端有一半的常用节点用不上浏览器拨号** —— 不是 bug，是内核限制。

hysteria2 是 QUIC/UDP，Browser Dialer 只对 xhttp/websocket + TLS 有意义。
这一条 `compat.py` 已经正确判定并显示"可浏览器 = 否"。

## 四、我们比 SB/M 做得好的地方

| 能力 | xray--core | sing-box-core | mihomo--core | 说明 |
|---|:--:|:--:|:--:|---|
| Browser Dialer（浏览器 TLS 指纹） | ✅ | ✗ | ✗ | X 独有，27 文件 |
| 内核 ECH | ✅ | 部分（仅 hy2/tuic） | ✗ | X 独有 |
| 错误解释（把内核报错翻成人话） | ✅ | ✗ | ✗ | 见 `parity.md` |
| 证书在用检测 / GC | ✅ | ✗ | ✅ | 本项目补齐 |
| DNS 段可视化编辑 | ✅ | ✗ | ✅ | 本项目补齐 |
| 端口归属诊断 | ✅ | ✅ | ✅ | 本项目更稳 |

## 五、缺口清单

### 🔴 真缺口

1. **协议矩阵文档** —— SB/M 都有"预置组合数 + 双端实测标注"，我们没有。
   后人无法知道 xray--core 到底支持哪些组合、哪些验证过、哪些内核做不到。
   这是**当前最该补的一项**，且成本低（照 mihomo 的 `PROJECT_STATUS.md`
   格式写即可）。

2. **客户端实测记录** —— CC 上的 8 个节点是真实节点，但"哪些组合在 CC 上
   实测通过"没有落到文档。`docs/e2e-rn.md` 只覆盖服务端。

### 🟡 需要决策

3. **Hysteria2 用户的出路** —— Xray 内核不支持，而 CC 上半数节点是 hy2。
   可选：
   - 明确文档化"hy2 节点只能走 Xray 自带 TLS，浏览器拨号不适用"
     （`compat.py` 已经这么判了，缺的是文档）
   - 或在客户端里给出提示，引导用户去 sing-box/mihomo 客户端

### ⚪ 不在范围

- TUIC / AnyTLS / NaiveProxy / Snell —— 内核不支持，不是项目能补的。
- `docs/parity.md` 里已核对过的通用能力（令牌/证书/DNS/端口诊断），不重复。

## 六、复核方式

```bash
# Xray 支持哪些服务端协议（RN 上实跑）
X=/root/catmi/xray/xrayls
cat > /tmp/t.json <<'EOF'
{"inbounds":[{"listen":"127.0.0.1","port":23456,"protocol":"vless",
  "settings":{"decryption":"none","clients":[{"id":"00000000-0000-0000-0000-000000000000"}]}}]}
EOF
$X run -test -c /tmp/t.json && echo 支持
```

改 `protocol` 逐个试即可。**记住 VLESS 必须带 `decryption: "none"`。**
