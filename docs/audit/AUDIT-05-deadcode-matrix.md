# xary-core 审计报告：Server 功能矩阵 + 废弃脚本候选

- 仓库：`/root/deepseek/repos/xary-core`（HEAD `153556c`，共 1017 次提交）
- 审计日期：2026-10-08　　**只读审计，未删除任何文件**
- 方法：`git log`/`--follow`/`--diff-filter=A` 逐文件追溯 + 全项目 `grep -rIn` 引用扫描（含 README/docs/子目录）

---

## 第一部分：Server 功能矩阵

### A. 主菜单（`xray-panel.sh:36-65`）

| # | 面板菜单项 | 功能 | 对应脚本 / 行号 | 成熟度 | 备注 |
|---|---|---|---|---|---|
| 1 | 安装/更新 xray | 幂等升级 + 重建基础配置 | `unused/xray_install.sh`（`xray-panel.sh:111,113-118`） | ✅ | 375 行，`trap` + 18 处错误处理；**目录名叫 unused 但是活跃依赖**，建议移出 |
| 2 | 卸载 xray | 停止/禁用服务 + 删目录 | `uninstall_xray.sh`（`:55`） | 🟡 | 仅 5 行、无 shebang、无确认、`rm -rf /root/catmi/xray` 无条件执行 |
| 3 | 查看客户端配置 | 打印 `/root/catmi/xray/out/` 下 txt/yaml | 内联 `show_xray_configs()`（`:119-140`） | ✅ | 路径与 `conf/*.sh` 的 `BASE_DIR=/root/catmi/xray` 体系一致 |
| 4 | 查询服务状态 | `systemctl status xrayls` | 内联（`:57`） | ✅ | 顶部状态栏读 `xrayls.service`（`:13`），命名不统一但无功能影响 |
| 5 | 添加节点 | 二级菜单，见下表 B | `add_node_menu()`（`:142-238`） | ✅ | 12 项，全部经 curl 拉取远端最新 |
| 6 | 校验配置 / 重启服务 | check + reload | `conf/verify.sh`（`:59`） | ✅ | 文件头 `verify.sh:5` 明写"设计给 xray-panel.sh 面板复用" |
| 7 | 出站管理 | 出站规则增删改 | `conf/outbound.sh`（`:60`） | ✅ | 2099 行、56 处错误处理，项目内最成熟的脚本 |
| 8 | 分流规则管理 | 分流规则增删改 | `conf/split.sh`（`:61`） | ✅ | 419 行；`conf/verify.sh`、`conf/outbound.sh` 互引同目录公共函数 |
| 9 | 反向代理管理 | 二级菜单，见下表 C | `reverse_menu()`（`:71-90`） | ✅ | 服务端/客户端分家 |
| 0 | 退出 | — | 内联 | — | — |

### B. 添加节点子菜单（`xray-panel.sh:147-162`）

| # | 功能 | 对应脚本 / 行号 | 成熟度 | 备注 |
|---|---|---|---|---|
| 1 | Tunnel 节点 | `conf/tunnel.sh`（`:173`） | 🟡 | 301 行但仅 6 处错误处理，无自校验 |
| 2 | Hysteria2 | `conf/hysteria2.sh`（`:178`） | ✅ | 923 行，含 IPv4/IPv6/双栈自动探测（`:154-162`） |
| 3 | SOCKS5（无加密） | `conf/sock5.sh`（`:183`） | 🟡 | 301 行 / 6 处错误处理 |
| 4 | VLESS-ECN（tcp） | `conf/vlessecn.sh`（`:188`） | ✅ | 466 行 / 18 处错误处理 |
| 5 | HTTP（无加密） | `conf/http.sh`（`:193`） | 🟡 | 301 行；含 IPv4/IPv6 自动探测（`:100-111`）但无自校验 |
| 6 | VLESS-xHTTP TLS | `conf/vlessxhttpecn.sh`（`:198`） | ✅ | 1332 行，含 ECH + ML-KEM + Nginx 转发 |
| 7 | Reality（vision + ML-KEM-768） | `conf/Reality.sh`（`:203`） | ✅ | 514 行；内部调用 `conf/XRevise.sh`（`:218`）生成密钥 |
| 8 | Shadowsocks-2022 | `conf/Shadowsocks.sh`（`:208`） | ✅ | 579 行；同样复用 `conf/XRevise.sh`（`:319`） |
| 9 | Trojan | `conf/Trojan.sh`（`:213`） | ✅ | 532 行；复用 `conf/XRevise.sh`（`:275`） |
| 10 | **固定** Argo | `conf/GDargo.sh`（`:218`） | 🟠 | 132 行、**零错误处理**（grep `print_error` = 0）；依赖外部仓库 `One-click-script/argo/url_argo.sh`（`:103`），外部挂了无提示 |
| 11 | **临时** Argo | `conf/lsargo.sh`（`:223`） | 🟠 | 127 行、**零错误处理**；仅 source 外部 `update_env.sh`/`load_env.sh`（`:110-111`） |
| 12 | 全协议一键生成 | `conf/batch.sh`（`:229`） | ✅ | 290 行，15 处校验；编排 Reality/Trojan/Shadowsocks/hysteria2（`:38`），批内自动端口 + 幂等 + 失败隔离 + 统一 reload |

### C. 反向代理子菜单（`xray-panel.sh:75-79`）

| # | 功能 | 对应脚本 / 行号 | 成熟度 | 备注 |
|---|---|---|---|---|
| 1 | 服务端（公网入口侧） | `conf/fd/xrayserver-reverse.sh`（`:83`） | ✅ | 385 行，`set -e`；文件头 `:8` 留有测试钩子 `REV_BASE_DIR=/tmp/xrev` |
| 2 | 客户端（RN 回连侧） | `conf/fd/xrayclient-reverse.sh`（`:84`） | ✅ | 372 行，`set -e`；同样有 `REV_BASE_DIR` 测试钩子 |

### D. 面板**没有**但脚本库里**存在**的能力

| 能力 | 脚本 | 最后提交 | 规模 | 判定 |
|---|---|---|---|---|
| VMess-WS+ECH 节点生成 | `conf/vmessws.sh` | 2026-05-06 (`778c037`) | 18 个函数 | 🟠 实现完整但零引用、未接菜单 |
| VLESS-WS+ECH 节点生成 | `conf/vlesswsecn.sh` | 2026-05-07 (`2ed2315`) | 19 个函数 | 🟠 同上 |
| VLESS-xHTTP（TLS，非 ECN） | `conf/vlessxhttp_tls.sh` | 2026-05-07 (`c89435d`) | 23 个函数 | 🟠 同上；与菜单 6 的 `conf/vlessxhttpecn.sh` 高度重叠 |
| Reality 密钥/UUID/short-id/ML-KEM 生成器 | `conf/XRevise.sh` | 2026-04-28 (`e4e7340`) | — | ✅ **隐式接入**：被 Reality/Shadowsocks/Trojan 以 curl 子进程调用 |
| 客户端面板（Browser Dialer） | `Client/l.sh` + `Client/RUN.sh` + `bin/xbd` | 2026-09-15 | 独立 Python 体系 | ✅ 独立分发链路（`Client/README.md:119`、`tools/make-release.sh:48`），不走面板 |
| 云端临时隧道运维（7 项菜单） | `xargo.sh` | 2025-04-27 (`3cd0df5`) | 298 行 | 🟡 独立可用，与菜单 11「临时 Argo」职能部分重叠 |

---

## 第二部分：废弃脚本候选

### 2.1 结论汇总

| 脚本 | 最后提交 | 被谁引用 | 是否有替代方案 | 结论 |
|---|---|---|---|---|
| `nginx6.sh` | 2026-04-20 `b4f45ea` | **无**（孤儿链只引 `nginx.sh`） | `nginx.sh`（同日新建，`d46a1c3`） | **明确废弃** |
| `upxray.sh` | 2025-03-23 `56d6a12` | **无** | `unused/xray_install.sh`（面板菜单 1 在用） | **明确废弃** |
| `vlessxhttpecn.sh`（根） | 2026-09-04 `747de7f` | **无** | `conf/vlessxhttpecn.sh`（面板菜单 6 在用，严格超集） | **明确废弃** |
| `reality_xray_ip.sh` | 2024-10-27 `1b0514b` | **无** | `conf/Reality.sh`（面板菜单 7 在用） | **明确废弃** |
| `reality_xray.sh` | 2024-12-02 `d89d8b1` | 仅注释提及（`Client/tools/push-client.sh:6`） | 同上 | **明确废弃** |
| `conf/fd/client-reverse.sh` | 2026-05-20 `b6e6694` | 仅 `conf/fd/xray*-reverse.sh` 头部注释 | `conf/fd/xrayclient-reverse.sh`（面板菜单 9.2） | **明确废弃** |
| `conf/fd/server-reverse.sh` | 2026-05-21 `90d174c` | 同上 + `xrayserver-reverse.sh:287` 提示语 | `conf/fd/xrayserver-reverse.sh`（面板菜单 9.1） | **明确废弃** |
| `unused/acme.sh` | 2026-04-20 `d2cf51d` | **无真引用**（`caddy.sh:44` 等命中的是 get.acme.sh，非本文件） | 无等价物，但无人使用 | **明确废弃** |
| `unused/svless.sh` | 2026-04-20 `494bc4b` | **无** | — | **明确废弃** |
| `unused/test.sh` | 2026-04-20 `86d036e` | **无** | — | **明确废弃** |
| `unused/ultiport-sock5.sh` | 2026-04-20 `7f29e71` | **无** | `conf/sock5.sh`（部分） | **明确废弃** |
| `unused/vless.sh` | 2026-04-20 `b137942` | **无** | `conf/vlessecn.sh`（部分） | **明确废弃** |
| `unused/xrayL.sh` | 2026-04-20 `67ed9a3` | **无** | — | **明确废弃** |
| `unused/xrayM-sock5.sh` | 2026-04-20 `9a7f9d8` | **无** | `conf/sock5.sh` | **明确废弃** |
| `unused/xrayS.sh` | 2026-04-20 `ced5236` | **无** | — | **明确废弃** |
| `unused/xrayw-vmess.sh` | 2026-04-20 `9c93730` | **无** | — | **明确废弃** |
| `VEVLRE6.sh` | 2026-04-20 `fb4431e` | **无** | `VEVLRE.sh`（2026-04-28） | **合并**（与 VEVLRE.sh 二选一） |
| `VEVLRE.sh` | 2026-04-28 `7f91a8f` | **无** | 面板 + `conf/*` 体系 | **合并**（保留其一） |
| `Conversion.sh` | 2026-04-21 `9f23386` | **无**（但它自己调 `xray-panel.sh:241`） | `xray-panel.sh` | **实验性保留** |
| `nginx.sh` | 2026-04-22 `6328da5` | `Conversion.sh`、`ngcadall.sh`、`VEVLRE.sh`、`VEVLRE6.sh`（**四者全部零外部引用**） | 新版 CDN 前置方案未接入 | **实验性保留** |
| `caddy.sh` | 2026-04-23 `6da7bd3` | `Conversion.sh`、`ngcadall.sh`、`VEVLRE.sh`（同上） | 无 | **实验性保留** |
| `ngcadall.sh` | 2026-04-23 `a6a22bf` | **无** | 无 | **实验性保留** |
| `xargo.sh` | 2025-04-27 `3cd0df5` | **无** | `conf/lsargo.sh`（职能部分重叠） | **实验性保留** |
| `conf/vmessws.sh` | 2026-05-06 `778c037` | **无** | 未接菜单的新能力 | **实验性保留** |
| `conf/vlesswsecn.sh` | 2026-05-07 `2ed2315` | **无** | 未接菜单的新能力 | **实验性保留** |
| `conf/vlessxhttp_tls.sh` | 2026-05-07 `c89435d` | **无** | 与 `conf/vlessxhttpecn.sh` 重叠 | **实验性保留** |
| `conf/cconf.sh` | 2026-04-28 `794defd` | `Conversion.sh:218`、`ngcadall.sh:78`、`VEVLRE.sh:118`（孤儿链） | `conf/nconf.sh` 成对 | **合并**（CDN 配置对，孤儿链处置后需复评） |
| `conf/nconf.sh` | 2026-09-02 `0eb96d4` | `Conversion.sh:196`、`ngcadall.sh:65`、`VEVLRE.sh:106`（孤儿链） | 同上 | **合并** |
| `unused/xray_install.sh` | 2026-09-20 `98d305c` | `xray-panel.sh:111`、`VEVLRE.sh:79` | — | **保留** ⚠️ 目录名误导，建议移至 `bin/` 或根目录 |
| `conf/XRevise.sh` | 2026-04-28 `e4e7340` | `Reality.sh:218`、`Shadowsocks.sh:319`、`Trojan.sh:275`、`ngcadall.sh:45`、`VEVLRE.sh:79` | — | **保留** |
| `uninstall_xray.sh` | 2026-04-20 `2e2ba65` | `xray-panel.sh:55` | — | **保留**（建议加确认与备份） |
| `conf/verify.sh` `outbound.sh` `split.sh` `batch.sh` `tunnel.sh` `hysteria2.sh` `sock5.sh` `vlessecn.sh` `http.sh` `vlessxhttpecn.sh` `Reality.sh` `Shadowsocks.sh` `Trojan.sh` `GDargo.sh` `lsargo.sh` | 2026-04~2026-09 | `xray-panel.sh` | — | **保留** |
| `Client/**`（15 个 .sh） | 2026-09-14~15 | `Client/README.md`、`RUN.md`、`service/*.service`、`tools/make-release.sh:18,48` | — | **保留**（独立客户端产品线，含 systemd unit 实引用） |

> `Client/tools/push-client.sh`、`push-delete.sh`、`selftest-proxy.sh` 无被引用记录，但它们是**手工运维/自检入口**（`selftest-proxy.sh:1-12` 有完整设计说明），属正常零引用，不列候选。

---

## 2.2 重复 / 分叉实现关系（重点结论）

**三对「成对脚本」都不是 IPv4/IPv6 双版本，而是新旧两代。** 全项目 grep `IP_CHOICE` 的 24 处命中全部在 `nginx.sh`/`nginx6.sh`/`unused/*` 内，运行时按 `IP_CHOICE=1/2` 选 `0.0.0.0` 还是 `[::]`（`nginx.sh:27-29`、`nginx6.sh:13-15`），**没有任何按系统栈自动分派的逻辑**，因此不需要也不存在「6 = IPv6」的命名含义。

| 对 | 关系 | 判定依据 |
|---|---|---|
| `nginx.sh` ↔ `nginx6.sh` | **新旧两代**。`b4f45ea`（2026-04-20）把旧 `nginx.sh` **重命名**为 `nginx6.sh`，同一天 `d46a1c3` 重新 `Create nginx.sh`。旧版从 `/root/catmi/install_info.txt` 用 `grep|sed` 解析 IP_CHOICE（`nginx6.sh:4`），新版走 `load_env` + catmi.env（`nginx.sh:16-29`）。`nginx6.sh` 此后再无一次提交。 | **明确废弃** `nginx6.sh` |
| `VEVLRE.sh` ↔ `VEVLRE6.sh` | **新旧两代**。`VEVLRE6.sh`（建 2025-01-07，止 2026-04-20）内联 IPv4/IPv6 选择（`:201-233`）；`VEVLRE.sh`（止 2026-04-28，更晚）删掉了这段，改为把密钥/IP 生成下沉到 `conf/XRevise.sh`（`XRevise.sh:114-136` 才有 IP_CHOICE）。diff 共 694 行，是真正的重构而非双版本。 | **合并**，建议留 `VEVLRE.sh` |
| `reality_xray.sh` ↔ `reality_xray_ip.sh` | **旧代码快照对**。两者都装**官方 Xray**（`XTLS/Xray-install`，`reality_xray.sh:164`、`reality_xray_ip.sh:165`），服务名 `xray`（`:20` `SERVICE_FILE=.../${NAME}.service`），**完全不属 catmi 的 `xrayls` 体系**（grep `catmi|xrayls` 仅命中 banner 字符串）。`_ip` 版是 2024-10 的更早快照，`reality_xray.sh` 2024-12 才最后更新，两者已停更 **22 个月**。 | **明确废弃**（两者） |
| `conf/fd/{client,server}-reverse.sh` ↔ `conf/fd/xray{client,server}-reverse.sh` | **新旧两代**，命名带 `xray` 前缀的是新体系（`BASE_DIR=${REV_BASE_DIR:-/root/catmi/xray}`，`:30`），旧版 diff 达 751/830 行。新版已接面板菜单 9。 | **明确废弃**（无前缀的两个） |
| 根 `vlessxhttpecn.sh` ↔ `conf/vlessxhttpecn.sh` | **同名分叉**。同一份脚本被复制到两处（头部注释完全一致）。`conf/` 版多一个 `extract_cert_domain()` 函数、更新晚 11 天、已被面板菜单 6 使用。 | **明确废弃**（根目录版） |

---

## 2.3 `unused/` 目录说明

- **来源**：作者在 2026-04-20 一天内把 9 个脚本 `git mv` 进此目录，commit message 形如 `Rename xrayM-sock5.sh to unused/xrayM-sock5.sh`（`9a7f9d8`/`b137942`/`ced5236`/`494bc4b`/`7f29e71`/`9c93730`/`67ed9a3`/`d2cf51d`/`86d036e`），并加 `.gitkeep`（`ce5d93a`）。**这 9 个是作者亲手标记的废弃集**，commit message 满足判定条件 ⑥。
- **例外**：`unused/xray_install.sh` 于 2026-04-22 `bd3688a` 后单独新建（`git log --diff-filter=A` 显示其 Add 记录晚于目录建立），至今仍在 2026-09 被维护，并被**面板菜单 1 直接调用**（`xray-panel.sh:111`）。它只是"被放在 unused/ 里"的历史误会，**不是废弃脚本**。
- 建议：把 `xray_install.sh` 移出 `unused/`，其余 9 个连目录一并删除。

---

## 2.4 「明确废弃」的 6 条判定核对（抽样：nginx6.sh / upxray.sh）

| 条件 | nginx6.sh | upxray.sh |
|---|---|---|
| ① 全项目 grep（含 README/docs/子目录） | ✅ 仅自身 | ✅ 仅自身 |
| ② 无任何脚本/菜单/文档引用 | ✅ `xray-panel.sh`、`README.md` 均无 | ✅ 同 |
| ③ 最后改动距今已久 | ✅ 2026-04-20（约 5.5 月） | ✅ 2025-03-23（约 6.5 月） |
| ④ 有明确新版替代且已被实际使用 | ✅ `nginx.sh` 同日新建；虽未接面板但被 4 个脚本当 Web 前置调用 | ✅ `unused/xray_install.sh` **已在面板菜单 1 上线** |
| ⑤ 删除不破坏现有功能 | ✅ 无入边 | ✅ 无入边 |
| ⑥ commit message 查过是否已提及废弃 | ✅ `b4f45ea` "Rename nginx.sh to nginx6.sh"（保留旧名即事实归档） | ✅ 查过，无提及（**本条为"已查证结果为否"**） |

> ⚠️ **判据 ⑥ 的口径需人工确认**：仓库 1017 条 commit 中，仅 `3ff4597`/`16aa5b6`/`27c36c0` 三条提到「删除废弃文件」，且都针对 Client。若「⑥」要求的是**必须存在明确的废弃声明**，则除 `unused/` 的 9 个（作者已用 rename 声明）和 `nginx6.sh`/`conf/fd` 旧版（分叉证据充分）外，其余应降级为「实验性保留」。上表中 `upxray.sh`、`reality_xray*.sh`、根 `vlessxhttpecn.sh` 属于此边界情形，建议人工拍板后再删。

---

## 2.5 建议的处置顺序（供人工确认，本次未执行）

1. **零风险**：删除 `unused/` 下 9 个作者已归档的脚本 + `unused/.gitkeep`；删除 `nginx6.sh`、`conf/fd/client-reverse.sh`、`conf/fd/server-reverse.sh`、`upxray.sh`。
2. **先改名再评估**：把 `unused/xray_install.sh` 迁至 `bin/xray_install.sh`，同步改 `xray-panel.sh:111`、`VEVLRE.sh:79`。
3. **孤儿链整体决策**：`Conversion.sh` → `{caddy.sh, nginx.sh, conf/cconf.sh, conf/nconf.sh, xray-panel.sh}`、`VEVLRE.sh` → `{caddy.sh, nginx.sh, conf/cconf.sh, conf/nconf.sh, conf/XRevise.sh, unused/xray_install.sh}`、`ngcadall.sh` 同上。这 3 个入口脚本无任何外部引用，可整体保留为「独立部署套件」或整体删除——**必须作为一个决策单元处理**，不要只删叶子。
4. **补菜单**：`conf/vmessws.sh`、`conf/vlesswsecn.sh`、`conf/vlessxhttp_tls.sh` 是三个已完工但未接线的节点生成器，建议接入 `add_node_menu`（菜单 12 后追加 13/14/15）而非删除。
5. **补健壮性**：`conf/GDargo.sh`、`conf/lsargo.sh` 零错误处理却对外 `curl` 外部仓库（`One-click-script`），建议加 `|| { print_error; return 1; }`；`uninstall_xray.sh` 建议加确认与备份。