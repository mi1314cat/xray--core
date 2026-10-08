# xray-core 一键脚本

Xray 服务端节点管理面板。配置格式是 Xray 自己的 JSON。

```bash
bash <(curl -Ls https://github.com/mi1314cat/xray--core/raw/refs/heads/main/xray-panel.sh)
```

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
| 12 | 自检 |

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
