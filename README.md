# X-Panel — Xray 服务端 / 客户端面板

个人 Xray 核心管理面板：**服务端节点管理 + 客户端配置生成 + 分享**。
两端内核都用 [XTLS/Xray-core](https://github.com/XTLS/Xray-core)，服务端配置格式是 Xray 自己的 JSON。

## 一键安装

```bash
bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/install.sh)
```

跑起来先选角色：**1) 服务端**（节点 / 分享 / 证书 / Nginx / 诊断）、
**2) 客户端**（装内核 + 面板 + Web UI）、3) 卸载。也可以直接带参数：

```bash
bash <(curl -Ls .../install.sh) server        # 直接进服务端面板
bash <(curl -Ls .../install.sh) client        # 直接装 / 进客户端
bash <(curl -Ls .../install.sh) uninstall     # 卸载（服务端 / 客户端 二选一）
bash <(curl -Ls .../install.sh) --status      # 只报告状态，什么都不改
```

> 与 `mihomo--core` / `sing-box-core` 一致：**一个引导脚本 + 角色参数**。
> `install.sh` 只是把两个入口接在一起，两个入口本身仍可单独跑：
> 服务端 `xray-panel.sh`、客户端 `Client/l.sh`（见 [Client/README.md](Client/README.md)）。

## 面板

| 序号 | 功能 |
|---|---|
| 1 | 安装 / 更新 xray（自动检测版本：旧版升级、最新则跳过） |
| 2 | 卸载 xray |
| 3 | 查看客户端配置 |
| 4 | 查询服务状态 |
| 5 | 添加节点 |
| 6 | 校验配置 / 重启服务 |
| 7 | 出站管理 |
| 8 | 分流规则管理 |
| 9 | 反向代理管理 |
| 10 | 分享管理 |
| 11 | 节点管理 |
| 12 | 自检 (252 项; 有内核时另跑 12 种协议链路 + 从零安装验证) |
| 13 | DNS 解析配置 |
| 14 | 日志查看 |
| 15 | 预置建节点 |
| 16 | 预置批量生成 |
| 17 | 证书管理 |
| 18 | Nginx 站点管理 |
| 19 | 分享服务 |

## 反向代理的 nginx 联动

反向代理隧道要能被外面访问，得有一条 nginx location 指向它。手工写的
location 没有标记，于是改端口时旧的那条留着、删隧道时 location 不跟着消失
（变成 502）、重复添加会插出多条让 nginx 起不来。

新建隧道时给了对外路径和服务端域名，脚本会自动走 Nginx 站点管理
（菜单 18）同一套逻辑插入 location：带标记、幂等、插入前 `nginx -t`、
失败自动回滚。插入前先打印预演结果，确认才写。

删除隧道时，对应的 location 一起摘除。nginx 跑在容器里时，查找与写入都
落在容器内部，不是宿主机那份同名文件。

## 分享

分享链接的形如 `http://<地址>:9443/sub/<token>`，客户端拉到的内容是标准
base64 订阅（一行一条 `vless://` / `trojan://` / `ss://` / `hysteria2://`）。

面板 10 提供：生成、列表、启停、改次数上限、改有效期、分享服务管理。

令牌有三个独立开关，各自返回不同的 HTTP 状态：

| 状态 | 码 | 含义 |
|---|---|---|
| 有效 | 200 | 正常下发 |
| 不存在 | 404 | token 不存在或形状非法 |
| 已停用 | 410 | 手动停用或节点被删后自动吊销 |
| 已过期 | 410 | 超过有效期 |
| 次数用尽 | 410 | 达到 max_uses |
| 无可分发内容 | 503 | 片段缺失或服务未运行 |

三条约定：

- **拿到 200 必然拿到完整 body。** 扣次数在载荷构造成功之后；构造期间令牌
  若被别人用掉，则放弃下发而不是照发。
- **健康检查和 HEAD 预检不消耗额度。** 客户端拿它探活，每次探活扣一次的话，
  一次加 20 个订阅就把额度耗光了。
- **需要定时刷新的令牌请设 `max_uses=0`。** 限次令牌被自动重拉一次就废。

缺节点 / 缺对外地址 / 片段解析失败这三类问题走 `X-Xray-*` 响应头上报，
body 保持纯 base64 —— 订阅解析器按整段解码，body 里多一行注释就整个解析
失败，诊断信息不能反过来把订阅弄坏。

## 节点管理

面板 11：列出、查看详情、改名、删除。

改名会同步四处：片段内的 `tag`、片段文件名、分享元数据 sidecar、令牌里的
tag 引用。漏掉任何一处，表现都是"改名后分享链接指向一个不存在的节点"，
而令牌本身不报错。

删除的顺序是固定的：

```
删片段 → 校验并重载 → 重载成功后才吊销关联分享 → 失败则回滚且不动令牌
```

反过来做（先吊销再校验）会出现：校验失败回滚，节点其实还在跑，但令牌已
全被吊销，用户手上的链接无声失效 —— 回滚只恢复配置，不恢复令牌。

## 预置建节点

面板 15。先挑一个推荐组合，再问最少的问题。

现有 7 个协议脚本各自问一堆参数、默认"最高配置"。但"最高配置"不一定对当前
场景——要走 Cloudflare 就得用 WS，局域网内用 SS+无加密就够了，为此去读某个
脚本的源码找参数名不现实。这里反过来：先选组合，每个组合附一句"为什么选它"。

预置表在 `conf/lib/preset.sh`，21 条覆盖 vless / trojan / vmess / shadowsocks
/ hysteria2 / socks / http。REALITY 组合在选完当场校验——表是手维护的，加错
一行不该等到生成配置时才炸，更不该等到用户连不上。

## 预置批量生成

菜单 16。一次生成多种协议 × 预置的节点。

```bash
# 全部走 CDN 直连
bash <(curl -Ls .../tools/preset_batch.sh) vless:2 trojan:3

# 逐节点指定档位（CDN / nginx）
bash <(curl -Ls .../tools/preset_batch.sh) vless:2 trojan:2:nginx

# 看可用组合
bash <(curl -Ls .../tools/preset_batch.sh) --list
```

与菜单 7（批量生成）的区别：那条路径逐个调用各协议脚本的交互式流程、各自走
"最高配置"，且不区分接入场景；这里走统一预置，可按节点指定档位。两条路径
并存。

TLS 节点要域名，两种给法：

```bash
X_BATCH_DOMAIN=b.example.com       # 全部 TLS 节点共用一个 SNI
X_BATCH_DOMAIN_BASE=b.example.com  # 每个节点一个 b.example.com-1、-2
```

都不给会明确报错并跳过该节点——不会静默跳过，否则用户以为建好了而实际一个
都没生成。

## 协议与接入

`conf/lib/node_build.py` 把 inbound 拆成协议 / 传输 / 加密三段组合，加新
组合是加一行规格而不是加一个脚本。

**接入档位**（`conf/lib/deploy.py`）：

| 档位 | Xray 监听 | 对外 | 需要 nginx |
|---|---|---|---|
| CDN 直连 | `0.0.0.0:<端口>` | 同左 | 否 |
| Nginx 转发 | `127.0.0.1:<端口>` | 域名 443 | 是 |

CDN 档位下 Xray 必须绑 `0.0.0.0`，只绑 `127.0.0.1` 的话 Cloudflare 回源
直接被拒，而面板显示一切正常。

一次规划同时产出三样，端口与域名只在一处出现：Xray 片段、分享元数据、
nginx 站点配置。nginx 配置失败会回滚前两步 —— 否则会留下"节点存在但没人
转发流量"的半应用状态，用户拿到一个连不上的分享链接而面板显示正常。

**REALITY 只能跑裸 TCP。** 握手伪装要求客户端直连目标站点，WS / gRPC /
XHTTP 的封装层会破坏握手。这类组合在生成阶段就被拒绝，而不是生成一条能
通过配置校验但永远连不上的节点。

**CDN 档位下裸 TCP + 无加密不可用。** Cloudflare 橙云只代理 HTTP(S)，裸 TCP
会被直接拒绝。这是"配置全对但连不上"最常见的一种。

## nginx

`conf/lib/nginx_apply.py` 对站点文件做**带标记的幂等插入 / 移除**。

nginx 站点文件是手写的。直接追加一段 location，第二次执行就追加第二份，
配置不报错（同 server_name 下后者覆盖前者），但用户已经无从判断当前生效
的是哪一段。所以插入内容一律加标记，动手前先摘掉上一轮插入的整段再插新的。

location 级与 server 级用两种标记，避免两种插入互相摘错：

```nginx
# >>> xray-core BEGIN example.com >>>
location / { ... }
# <<< xray-core END example.com <<<

# === xray-core BEGIN example.com (server 指令) ===
upstream xray_example { ... }
# === xray-core END example.com ===
```

跨行匹配时如果遇到第二个 BEGIN，说明两份交错了 —— 那已经是被改坏的状态。
取到第一个 END 就停，不把别人的段一起吞掉。

写入路径：

```
备份 → 原子替换 → nginx -t → 不通过立刻回滚
```

缩进跟随文件实际风格，而不是写死 —— 写死会让 diff 全是空白变化，掩盖真正
的改动。nginx 跑在 Docker 里时自动改用 `docker exec` 校验。

## DNS

面板 13。服务端此前没有 dns 段，内核只能用内置默认解析：明文、无 fallback。
服务端解析被劫持会污染分流判断 —— 配分流前先确认这一段。

支持：查看、增删 DNS 服务器、设 queryStrategy、静态解析、禁用 fallback、
清空整段。

Xray 的 dns 段是严格 schema，手改 `config.json` 改错了要等到下次重启才发现
内核拒。这里每次写入前做 schema 校验，写入后立刻 `xray run -test`，不通过
就回滚 —— 报错时机从"下次重启"提前到"执行命令的瞬间"。

只碰 dns 键，其余键原样保留，也不重排文件格式 —— 重排会让每次编辑都产生
整篇 diff，真正改动的那一行反而淹没在格式变化里。

## 日志

面板 14。查看日志、看报错解释、跟随输出、服务状态与端口占用。

"报错解释"把内核日志翻成人话。用户打开的是 `unknown field: sockopt`，
实际要改的是某个已废弃的字段；看到的是 `bind: address already in use`，
实际要换的是端口而不是重启。映射覆盖端口占用、权限不足、证书不成对、
引用文件不存在、配置字段不被版本接受、配置构建失败、内核崩溃。

正常启动的日志行会被压掉，不刷屏。

## 容器共处

Docker 在本项目里的含义不是"把 Xray 部署进容器"，而是与容器共存：配套服务
（nginx）跑在容器里时，命令必须打向容器而不是宿主。

- **nginx** —— 自动探测容器化 nginx，校验与 reload 走 `docker exec`。
  否则 `nginx -t` 验的是宿主那份，可能根本没挂进容器，验过了也不代表真正
  生效的配置没问题。
- **证书** —— 容器常把证书挂进容器而宿主对应目录是空的。只扫宿主目录的结果
  是"一张证书都找不到"，而证书明明就在 nginx 正在用的地方 —— 续期脚本会
  报告"没有可续期的证书"，实际是扫描路径错了。这里从挂载关系反推宿主路径
  并加入扫描，同时列出容器内 nginx 正在引用的证书。

私有钥一律排除。nginx 证书链常见 `xxx.crt` + `xxx.crt.key` 两件套，只挡
`*_key.pem` / `*key*.pem` 会漏掉 `.key` 后缀，于是私钥被当成"待续期证书"
列给用户，续期脚本对着一把私钥申请续期。

所有 docker 调用带超时 —— 没有守护进程时它是瞬时返回的，但辅助查询不该
有能力挂住整个面板。

## 证书

`conf/lib/cert.sh` 提供有效性校验、域名提取、在用检测与 GC。

删证书前会扫三处引用：Xray 片段与主配置、nginx 站点、分享元数据。有引用就
跳过并列出具体位置，不静默删 —— 用户以为自己清理干净了，第二天节点全挂，
而证书已经在垃圾桶里。

## 自检

```bash
bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/tools/check_libs.sh)
```

76 项断言，覆盖全部通用模块与 Client 兼容性。也可以从面板菜单 12 运行。

## 客户端

`Client/` 是独立的 Xray 客户端，**不依赖本仓库**，可单独分发安装。

从本服务端拉取节点：

```bash
xbd node sub "http://<地址>:9443/sub/<token>"     # 首次导入
xbd node sub-refresh "http://<地址>:9443/sub/<token>"   # 刷新（自动去重）
```

客户端已支持把订阅 URL 直接粘进面板输入框。刷新会自动去重，失败时保留
现有节点。

## 安装升级 Xray-core

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

## 相关

- [One-click-script](https://github.com/mi1314cat/One-click-script) —— 公共
  共享函数库，本项目远程引用其中的 `load_env` / `update_env` / `random_website`。
- [sing-box-core](https://github.com/mi1314cat/sing-box-core) —— 同系列，
  通用产品能力对等，内核与配置格式不同。
- [mihomo--core](https://github.com/mi1314cat/mihomo--core) —— 同上。
