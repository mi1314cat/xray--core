# AUDIT-06 · Phase 0 接手审计（只读）

- 仓库：`mi1314cat/xray--core`，审计时 HEAD `7e7356e`（1198 commits）
- 审计日期：接手第一轮
- 方法：通读入口链路 + 逐文件引用扫描 + **在沙箱里真跑生成链路复现** + 真机 `check_libs.sh`
- 真机环境：Xray 26.3.27，Xray 26.3.27 (`d2758a0`, go1.26.1)
- **本轮未改任何生产代码，未 push**

---

## 一、当前真正使用的入口

```
install.sh                 ← 一键引导（只做分发，不是主体）
  └─ run_server()                     install.sh:209-220
       └─ exec bash xray-panel.sh     install.sh:219
            └─ xray-panel.sh          ← **真正的主体入口**（主循环 :794-796）
                 ├─ 菜单 1  → bin/xray_install.sh        ← 内核安装/systemd
                 └─ 菜单 5  → add_node_menu()  :684-791  ← 建节点的唯一入口
```

| 层 | 落点 | 说明 |
|---|---|---|
| 引导 | `install.sh` | 分发到 server / client 两条安装线，本阶段只关心 server |
| 面板 | `xray-panel.sh` | 强依赖 `conf/lib/*`；启动时按需**取到 / 缓存 / curl** |
| 内核安装 | `bin/xray_install.sh` | 建 `00-base.json`、写 `xrayls.service`（`ExecStart=<BIN> -confdir <CONF_DIR>`，:409） |
| 服务 | `xrayls.service` | **不是** `xray.service`（后者是无关的旧单元） |
| 配置 | `<CONF_DIR>/config.json` + `00-base.json` + 每节点一个片段 | `config.json` 用 `include` 通配加载片段 |

### ★ 一个必须记住的行为：面板是「远端优先」的脚本运行器

`xray_run()`（`xray-panel.sh:203-220`）→ `xray_fetch()`（:113-131）按三级取脚本：

1. **仓库检出目录**（`$self/$rel` 存在就用它）← 开发时走这条
2. 本次会话缓存 `$_XRAY_CACHE`
3. GitHub 镜像链

所以：

- **从仓库检出跑** → 本地改动立即生效
- **用户的一键安装**（面板在 `/root/xray-panel.sh`，没有 `conf/` 树）→ **每个菜单项都从 GitHub 现拉，本地改了不生效，必须先 push**

这解释了过去「本地改了 RN 上跑还是旧行为」的现象。**判断"当前跑的是哪一份"是排查任何面板问题的第一步。**

---

## 二、当前服务端架构

```
/root/catmi/xray/                     XRAY_BASE
├── xrayls                            内核二进制
├── config.json                       主配置（只有一个 include）
├── conf/                             ← 内核 -confdir 读的就是这里
│   ├── 00-base.json                  log / dns / outbounds / routing 骨架
│   └── <tag>.json                    每个节点一个 inbound 片段
├── log/                              access.log / error.log
└── out/                              客户端产物
    ├── <proto>_client-NN.yaml        mihomo 客户端
    ├── <proto>_client-NN.json        Xray 客户端出站
    ├── <proto>_share-NN.txt          分享链接
    └── <proto>_nginx-NN.conf         nginx 站点片段
```

- **分享**已外包给公共基础服务 `proxy-share-service`（M / SB / X 共用，provider=`xray`）；
  适配器 `conf/share_client.py`，载荷构建 `conf/lib/share_payload.py`；
  订阅内容是 **base64 的单行链接列表**，路径 `/share/<token>`。
- **分享元数据**（sidecar）`share_meta.py`：存 `host / port / public_key / fingerprint / short_id / tier / dl_*`。
  它**不在** Xray 片段里 —— 因为内核 schema 严格，未知字段会让 `run -test` 直接失败。

---

## 三、当前节点生成流程：**两条互不相干的路径**

这是理解整个项目最关键的一件事。

### 路径 A —— 逐协议脚本（第一代，仍在生产用）

```
菜单 5 → 1..9
  conf/tunnel.sh      conf/hysteria2.sh   conf/sock5.sh
  conf/http.sh        conf/vlessecn.sh    conf/vlessxhttpecn.sh
  conf/Reality.sh     conf/Shadowsocks.sh conf/Trojan.sh
菜单 5 → 12  conf/batch.sh   （编排上面 4 个老脚本：Reality/Trojan/SS/hysteria2）
```

每个脚本**自己**完成：交互 → 拼 inbound JSON → 写 mihomo YAML（heredoc）→ 写 share txt → 重启服务。

### 路径 B —— 声明式预置（第二代，能力更强）

```
菜单 13  conf/mknode.sh            预置档位建节点
菜单 14  tools/preset_batch.sh     预置批量生成
菜单 15  tools/split_menu.sh       xHTTP 上下行分离  ← 走 preset_batch
菜单 16  tools/xhttp_doctor.sh     分离节点自检
              ↓
        conf/lib/node_build.py     声明式规格 → inbound JSON（含 downloadSettings）
              ↓
        conf/lib/deploy.py         落盘：片段 + 分享元数据（+ nginx 预演）
```

**路径 B 是 XHTTP 上下行分离唯一的实现路径**，也是唯一有统一冲突护栏的一条。

---

## 四、当前 XHTTP 实现

### 4.1 服务端写入（`node_build.py`）

`_stream_settings()` → `transport == "xhttp"` 分支（:233-242）写：

```jsonc
"xhttpSettings": {
  "mode": "auto",                 // opts["xhttp_mode"]，缺省 auto
  "path": "/...",
  "host": "...",
  "downloadSettings": {           // 有 dl_address 才写（_xhttp_download_settings :343-437）
    "address": "...", "port": <与 inbound 同端口>, "network": "xhttp",
    "security": "tls|reality|none",
    "tlsSettings":     {"serverName": ...},
    "realitySettings": {"serverName","fingerprint","password","shortId","spiderX"},
    "xhttpSettings":   {"path": <与上行相同>, "mode": "..."}
  }
}
```

### 4.2 已有的护栏（这部分做得很好，是项目最扎实的一块）

| 护栏 | 依据 | 位置 |
|---|---|---|
| REALITY 传输白名单 `raw/tcp/xhttp/grpc` | 内核原文 `REALITY only supports RAW, XHTTP and gRPC for now.` | `node_build.py:62-66`、`preset.sh:64-81` |
| `flow` 只能在裸 TCP | 实测：`-test` 放行、真连必挂 | `node_build.py:85,108-114` |
| xhttp mode 四值白名单 | 内核硬报错 | `node_build.py:90,119-126` |
| `stream-one` × `downloadSettings` 互斥 | 内核 `transport_internet.go:440`，**`-test` 不执行这段检查** | `node_build.py:133-139` |
| 下行端口必须等于上行端口 | 会话表 per-inbound（`hub.go:39/464`） | `node_build.py:141-150` |
| 下行 path 必须等于上行 path | `hub.go:461` 只认顶层 path，实测反证 | `node_build.py:423-430` |
| **绝不使用 `extra`** | 内核里 `extra` 非空会**整体替换** xhttpSettings，`-test` 不报错 | `node_build.py:433` |
| kcp 从传输白名单移除 | 26.3.27 报 `mkcp header & seed has been removed` | `preset.sh:56-63` |

### 4.3 四个分离组合（`preset.sh:170-228`）

| 模式 | 上行 | 下行 | 下行经 nginx | 监听档 | 实测 |
|---|---|---|---|---|---|
| `cdn-cdn` | tls | tls | 是 | nginx (`127.0.0.1`) | ✅ 200 |
| `cdn-reality` | tls | reality | 否 | cdn (`0.0.0.0`) | ✅ 200 |
| `reality-reality` | reality | reality | 否 | cdn | ✅ 200 |
| `reality-cdn` | reality | tls | 是 | cdn | ❌ **设计冲突，不通**（已如实记录） |

### 4.4 mihomo 侧映射：**已实现，但没有接线**

`conf/lib/to_mihomo.py` 的 `xhttp_download_settings()`（:56-136）已经正确实现
`xhttp-opts.download-settings` 的**两段式**（xhttp 部分 + proxy 部分），
但全仓**零生产调用方** —— 唯一引用是 `tools/check_libs.sh:3810,3857`（测试）。

实际产出 mihomo YAML 的是 5 个协议脚本各自手写的 heredoc
（`Reality.sh:326` / `Trojan.sh:392,411` / `Shadowsocks.sh:434,453` /
`hysteria2.sh:869,887` / `vlessxhttpecn.sh:1024`），**都不带 `download-settings`**。

RN 生产实测（`out/vless-xhttp_client-01.yaml`）：

```yaml
network: xhttp
xhttp-opts:
  mode: auto
  path: /HaaDoJ29/
ech-opts: {enable: true, config: ...}
```

→ **上下行分离信息在 mihomo 产物里完全不存在。**

### 4.5 客户端侧（本阶段冻结，仅记录）

- 项目自带 `Client/` 是独立的「客户端网关」产品（Xray 常驻 + Browser Dialer），**不是 mihomo 客户端**。
- `Client/lib/genconfig.py:502,1116-1154` 已支持 `downloadSettings`（客户端侧用 `publicKey`）。
- 但 `Client/lib/node.py:326-336` 的解析器**丢掉了 `dlmode`**，于是下行退回 `auto`。

---

## 五、当前已经完成的协议（有实测证据）

`docs/e2e-rn.md` 记录：**12 种组合真实链路打通**（源站 ← 客户端进程 ← 服务端进程）。

```
vless+tcp   vmess+tcp   ss2022+aes-128-gcm
vless+tcp+tls(vision)   vless+ws+tls   vless+grpc+tls   vless+xhttp+tls
trojan+tcp+tls   trojan+ws+tls   trojan+grpc+tls   vmess+ws+tls
vless+tcp+reality
```

预置矩阵：21 个预置全部生成，`xray run -test` **18/18 通过**（另 3 个是 CDN 档对裸 TCP 的预期拒绝）。

分离组合：`cdn-cdn` / `cdn-reality` / `reality-reality` RN↔CC 实测 200；`reality-cdn` 不通。

自检套件（本轮真机复跑，RN 有真内核）：

```
bash tools/check_libs.sh  →  939 通过, 0 失败
```

> 本机（无 xray 二进制）跑同一套是 931/2 —— 两条红灯**都是环境**：
> ① `share_client.py health` 无输出（本机没有分享服务）
> ② downloadSettings 用例要 `/usr/local/bin/xray run -test`
> 在真机上都是绿的。**不要把本机结果当代码问题。**

---

## 六、当前明显存在的问题

标注 🔴 = 已复现，🟡 = 静态可证未复现，⚪ = 待确认。

### ✅ P0-1 【已修 · d16b8fb】`conf/mknode.sh` 曾把节点写到内核**不读**的目录

| | 值 |
|---|---|
| `conf/mknode.sh:105` | `CONF_DIR="${CONF_DIR:-$XRAY_BASE/configs}"` → `/root/catmi/xray/configs` |
| 内核实际读 | `bin/xray_install.sh:35,409` → `$INSTALL_DIR/conf` + `ExecStart=... -confdir <CONF_DIR>` |
| 其他所有脚本 | `xray-panel.sh:302,419` 都用 `${CONF_DIR:-/root/catmi/xray/conf}` |

**面板从不 `export CONF_DIR`**（全文件只有 `XRAY_SERVER_NAME` 一个 export，:289），
所以菜单 13 建出来的节点落在 `configs/`，**内核永远看不到，节点静默无效**。
RN 上 `/root/catmi/xray/configs` 至今不存在 —— 说明这条路要么没被用过，要么用了以后没人发现节点不生效。

沙箱实测（照 `mknode.sh:105` + `:420` 的取值，面板环境）：

```
mknode writes fragments to : /tmp/p1/base/configs      ← mknode.sh:105
kernel loads               : /tmp/p1/base/conf         ← ExecStart -confdir
已写入分享元数据: /tmp/p1/base/share/tokens/vless-xhttp-cdn.json
内核 -confdir 读的目录: ls: cannot access '/tmp/p1/base/conf': No such file or directory
节点实际落在: /tmp/p1/base/configs/vless-xhttp-cdn.json
```

（顺带确认真实护栏是活的：伪造的 REALITY 私钥被 `node_build._check_reality` 当场拒绝，
`mknode.sh:402` 也确实会注入 `public_key` —— 这两条不是缺口。）

### ✅ P0-2 【已修 · d16b8fb】分享元数据曾「双目录」

| 写入方 | 目录 |
|---|---|
| `conf/mknode.sh:106`、`tools/preset_batch.sh:61`、`conf/lib/deploy.py:396` | `$XRAY_BASE/share/tokens` |
| `conf/share.sh:30`、`conf/node.sh:19`、`conf/lib/share_payload.py:21`、`conf/lib/cert.sh:17`、`conf/share_service.sh:25` | `$XRAY_BASE/out/share` |

**已在沙箱里复现**：走 `mknode`/`preset_batch` 的路径建出的节点，
`share_payload.build_links()` 返回 `nometa`（节点在、元数据找不到）→ **没有分享链接**；
即使强行找到，`dl_*` 参数也来自元数据，于是**上下行分离信息一并丢失**。

套件发现不了它：`tools/check_libs.sh:138` 自己把 `XRAY_SHARE_DIR` 指成同一个目录。

### ✅ P0-3 【已修 · 6f78bac】预置路径曾**一份客户端产物都不产出**

沙箱实测（`vless:4:split:cdn-reality` 的完整 spec 喂给 `deploy.py --apply`）：

```
产出文件：
  conf/vless-xhttp-tls-01.json          ← 服务端片段（downloadSettings 正确）
  share/tokens/vless-xhttp-tls-01.json  ← 元数据（写错目录，见 P0-2）
  （没有 out/ 目录，没有 YAML，没有 Xray JSON，没有 share txt）
```

`deploy.py:328-329` 只写这两样。**菜单 15（上下行分离）就是这条路径。**

### ✅ P0-4 【已修 · 6f78bac】`to_mihomo.py` 曾是死代码 → 分离信息进不了 mihomo 产物

见 §4.4。用户当前最想要的东西（"生成客户端的时候也要生成 YAML 文件"）断在这里。

### ✅ P0-5 【已修 · d16b8fb】菜单 15 曾在一键安装上**根本跑不起来**

`tools/split_menu.sh:24-33` 按 `dirname $0/..` 找 `conf/lib/preset.sh`。
而 `xray_run` 会把脚本**扁平化**到 `$_XRAY_CACHE/tools_split_menu.sh`
（`xray-panel.sh:127`，`tr '/' '_'`），`xray_ensure_lib` 只铺 `$CACHE/lib/`。

沙箱复现（完全照 `xray_run` 的做法）：

```
$ bash /tmp/.xray-panel.XXXX/tools_split_menu.sh
[Error] 找不到 conf/lib/preset.sh (/tmp/conf/lib/preset.sh)
```

→ **除 git 检出以外的一切安装方式，菜单 15 都是死的。**

### 🟡 P1-1 【本项经复核**不成立**，已作废】

初稿写的是「预置 ⑥ 的宣传与实际相反」。复核后**推翻**：

`mknode.sh:255-282` **确实会问 xhttp mode**，且 REALITY 下默认值就是
`stream-up`，选出来的值会经 `MK_XHTTP_MODE` 进 `xhttpSettings.mode`。
所以预置 ⑥ 的说明（"内核里 mode=stream-up … 下行走独立 GET、上行走独立 POST"）
**是兑现了的**。

真正存在的只是**能力边界**，不是缺陷：

| | 预置 ⑥（菜单 13） | 分离组合（菜单 15） |
|---|---|---|
| `mode=stream-up` | ✅ 有 | ✅ 有 |
| 上下行是两条独立 HTTP 请求 | ✅ 有 | ✅ 有 |
| `downloadSettings`（去**不同目的地**） | ❌ 没有 | ✅ 有 |

菜单 13 不产出 `downloadSettings` 是合理的 —— 它问不到下行域名/地址；
要"上行 CDN + 下行 Reality"这种**目的地分离**，入口就是菜单 15。

> 教训记在这里：初稿这条来自子代理的静态结论，未经复核就写进了报告。
> **"预置说明"与"配置里有没有 dl_\*"是两件事**，前者说的是 mode 语义。
> 接手审计里凡是要动用户可见文案的结论，都必须先读生成路径的每一条赋值。

### ✅ P1-2 【已修 · a68ccee】分享链接里的 `mode` 参数曾是死代码

`nodes.py:679` 读 `n.get("mode")`，但 `extract()`（:183-221）**从来不产出 `mode` 这个键**
→ 条件恒假，链路上永远不带 `mode`，客户端一律退回 `auto`。
（:676-678 的注释声称已修好，实际没有。）

### ✅ P1-3 【已修 · a68ccee】`split_params` 的片段兜底在分享路径上永远不触发

`nodes.py:530-540` 想从 `n["inbounds"]` 里读 `downloadSettings` 兜底，
但 `build_share_link` 传进去的是 `extract()` 出来的**视图**（没有 `inbounds`）
→ 元数据一旦缺失，**所有 `dl_*` 静默消失**（正是它想防的那件事）。

### 🟡 P1-4 TLS 下行的 `serverName` 写成空串

`node_build.py:412` 对 `dl_security == "tls"` 写 `{"serverName": opts.get("dl_sni") or opts.get("sni") or ""}`，
而元数据那边记的是域名（`deploy.py:160`）→ 两边口径不一致（影响 `cdn-cdn` / `reality-cdn`）。

### 🟡 P1-5 `dl_ech` 无人消费

`preset_batch.sh:348` 会写 `o["dl_ech"]`，但 `node_build.py` 从不读它；
`to_mihomo.py:113` 期望的是字符串，直接喂布尔会变成 `"True"`。

### ✅ P1-6 【已修 · a68ccee】「客户端产物」菜单的三个口径问题

- `xray-panel.sh:657` 硬编码 `/root/catmi/xray/out`，而同文件 `_client_status`（:620）用 `${OUT_DIR:-...}`
- **没有 json 分支** → `vless-xhttp_client-NN.json`、`hy2_client-NN.xray.json` 看不到
- `_client_status` 的文件计数（:623）也只数 txt/yaml/yml

### 🟡 P1-7 缺「不用预置，我自己逐项配」这条路

SB（`lib.sh:1672`）与 M（`preset.sh:219`）都有；X 的 `x_preset_ask` 里 `0`/空 = 取消（`preset.sh:432-436`），
`mknode.sh` 也从不问 transport / security。**用户明确要的「一个协议一个选择 + 自己逐项配 + 防呆」缺后半截。**

### 🟡 P1-8 菜单覆盖不全

- `reality-reality` 在 `split_menu.sh:57-63` 与 `batch.sh:367` 里**都没有**，只能靠命令hand
- 菜单 14 实际是 `tools/preset_batch.sh --help`（`xray-panel.sh:782`）—— 不是可用入口

### ⚪ P2（记录，暂不动）

- 客户端解析器丢 `dlmode`（`Client/lib/node.py:326-336`）—— 客户端阶段的事
- 全仓**没有任何 `mihomo -t` 级别的产物校验**
- 产物命名不统一（`_share-` vs `-share-`），项目自己已记录
- 预置路径的 TLS 节点可能没有 `certificates`（`deploy.py` 不设 `cert_file/key_file`）—— 待实测
- Cloudflare 橙云未实测；`reality-cdn` 若要做，唯一未验的路是「同端口按会话路由」，需先做内核级验证

---

## 七、ACTIVE / LEGACY / UNUSED / UNKNOWN 分类

### ACTIVE（现行生产路径，不要动）

| 组 | 文件 |
|---|---|
| 入口 | `install.sh`、`xray-panel.sh`、`bin/xray_install.sh`、`uninstall_xray.sh` |
| 单协议 | `conf/{tunnel,hysteria2,sock5,http,vlessecn,vlessxhttpecn,Reality,Shadowsocks,Trojan}.sh` |
| 编排 | `conf/batch.sh`、`conf/mknode.sh`、`tools/preset_batch.sh`、`tools/split_menu.sh`、`tools/xhttp_doctor.sh` |
| 管理 | `conf/{node,share,share_service,cert,nginx_site,dns,logs,split,outbound,verify}.sh` |
| 公共库 | `conf/lib/*`（`node_build.py`/`deploy.py`/`nodes.py`/`preset.sh`/`to_mihomo.py`/…；`to_mihomo.py` 是「已登记未接线」，属 ACTIVE 待接线） |
| 生成器 | `conf/XRevise.sh`（被 Reality/SS/Trojan 调用，**不是**死码） |
| 工具 | `tools/{check_libs,check_wiring,e2e_*,cdn_auto,port-check,prepush_check,preset_batch,cert_guard,cert-sync}.sh` |
| 反向代理 | `conf/fd/xrayserver-reverse.sh`、`conf/fd/xrayclient-reverse.sh` |
| 客户端 | `Client/**`（独立产品线，本轮冻结） |

### LEGACY（保留备查，**先不要删**）

| 文件 | 为什么不删 |
|---|---|
| `conf/fd/legacy/{client,server}-reverse.sh` | 第一代反代实现；下一代**尚未长期实机验证**，删了等于毁掉唯一备份（见该目录 README） |

### UNUSED

| 位置 | 状态 |
|---|---|
| `unused/` | 只剩 `.gitkeep`。早期「v2ray 独立套件」（`VEVLRE*.sh`/`Conversion.sh`/`ngcadall.sh`/`nginx.sh`/`caddy.sh`/`conf/{c,n}conf.sh`）已于 2026-10-10 整体删除，`docs/legacy/README.md` 有完整判定过程与取回方式 |

### UNKNOWN（零引用但**不是**死码，需保留）

| 文件 | 判断 |
|---|---|
| `xargo.sh` | 零引用，但管 cloudflared 隧道的全生命周期；`conf/GDargo.sh`/`conf/lsargo.sh` 只是生成器。删了会让已建隧道失去自愈 |
| `conf/GDargo.sh` / `conf/lsargo.sh` | 菜单 10/11 在用，但依赖外部仓库脚本，零错误处理 —— 属**质量**问题不是**死码**问题 |

> 结论：**这个项目没有需要清理的大块死代码** —— 与 AUDIT-05 时代（那时有 20+ 个孤儿）相比，
> 清理工作基本已经做完。本阶段**不建议做任何删除**。

---

## 八、最应该修复的 3~5 个问题（按性价比排序）

| # | 问题 | 为什么排这个位置 | 规模 |
|---|---|---|---|
| **1** | **P0-1 + P0-2 目录口径统一** | 两条都是「一行改对、整条路径活过来」。修完菜单 13 才真的能建节点、预置节点才有分享链接 | 极小 |
| **2** | **P0-3 + P0-4 产出客户端产物** | 用户当前的头号诉求（"生成客户端时也要生成 YAML"）。把已实现的 `to_mihomo.py` 接进 `deploy.py`，分离信息立刻进 mihomo YAML | 小 |
| **3** | **P0-5 修 `split_menu.sh` 的库定位** | 不修的话 XHTTP 分离在一键安装上**完全不可达**；修完才能谈真实验证 | 极小 |
| **4** | **P1-1/2/3 分离元数据正确性** | 预置 ⑥ 的说明与实际相反、链接丢 `mode`、兜底路径失效 —— 都是「看着配好了其实没分离」那一类 | 小 |
| **5** | **P1-7 手选路径 + 防呆** | 用户明确的要求；SB/M 都有，X 是唯一缺口 | 中 |

修完 1~4 才具备「RN 部署 → CC 真实连接 → 日志验证」的闭环条件；
第 5 项是产品形态，可与验证并行。

---

## 九、本轮验证做到哪一步（诚实记录）

| 项 | 做了 | 结果 |
|---|---|---|
| 仓库结构 / 入口链路 | ✅ | §一 |
| 全文件引用扫描（死码分类） | ✅ | §七 |
| `tools/check_wiring.py` | ✅ | 库函数 119/119 可达，0 不可达 |
| `bash -n` 全量语法 | ✅ | 干净 |
| `tools/check_libs.sh`（本机） | ✅ | 931/2 —— **两条均为环境** |
| `tools/check_libs.sh`（RN 真内核） | ✅ | **939/0** |
| 沙箱复现 P0-2 / P0-3 | ✅ | 真跑了 `deploy.py --apply` |
| 沙箱复现 P0-5 | ✅ | 真跑了扁平化缓存调用 |
| 内核语义核对 | ✅ | 对 RN 上 `d2758a0` 源码（`hub.go`/`dialer.go`/`transport_internet.go`） |
| RN 生产只读盘点 | ✅ | 服务 active、无 `configs/`、8 组 vless-xhttp 产物无对应片段（孤儿） |
| **CC 真实连接验证** | ❌ | 本轮**未做** —— 属 Phase 2/3 |
| **XHTTP 分离端到端（RN→CC）** | ❌ | 本轮**未做** |

**下一步（Phase 1）**：先修 §八 的 1~3 项，然后在 RN 上用**独立目录 + 高位端口**（不碰生产 16 个 inbound）
跑通一次完整生命周期，再进 Phase 2 的普通协议 RN→CC 真实连接。
