# 遗留脚本

本目录的脚本**保留原位**, 不删、不移、不改。原因写在最后, 先说分类。

## 分类

| 脚本 | 分类 | 现状 | 与谁重叠 |
|---|---|---|---|
| `nginx.sh` | legacy | 面板不可达, 被下述遗留链引用 | `conf/lib/nginx_apply.py` |
| `caddy.sh` | legacy | 面板不可达, 被下述遗留链引用 | 无对等模块 (Caddy 目前不作为主路径) |
| `Conversion.sh` | legacy | 面板不可达, 零外部引用 | `conf/vlessxhttpecn.sh` + `node_build.py` |
| `VEVLRE.sh` | legacy | 面板不可达, 零外部引用 | 同上 |
| `VEVLRE6.sh` | legacy | 面板不可达, 零外部引用 | 同上 |
| `ngcadall.sh` | legacy | 面板不可达, 零外部引用 | 同上 |

## 这条链的结构

    Conversion.sh ─┐
    VEVLRE.sh     ─┼─→ caddy.sh, nginx.sh
    VEVLRE6.sh    ─┤
    ngcadall.sh   ─┘

链内互有引用, 链外**零引用** —— 面板的 22 个入口里没有任何一个调它们。

## 为什么判定为 legacy 而非直接删除

三个理由, 三个都要成立才删得掉:

1. **它们与现行脚本是同一功能的两代实现。** 都在做"生成 VLESS 节点 +
   配置 nginx/caddy + 申请证书", 只是写法不同。能力上已被
   `conf/vlessxhttpecn.sh`、`conf/lib/node_build.py`、`conf/lib/nginx_apply.py`
   覆盖, 所以"留着以防万一"没有价值。

2. **但无法确认没有人在直接用。** 面板不可达不等于没人用 —— 这类脚本历来是
   通过 `bash <(curl -Ls .../VEVLRE.sh)` 直接执行的, 老书签、老教程、
   别人转发的链接都还指向它们。删掉之后那些链接会 404, 而失败发生在别人
   的机器上, 排查不到。

3. **caddy 不是纯冗余。** nginx 路径已被 `nginx_apply.py` 覆盖, Caddy 目前
   仍然只在 `caddy.sh` 里。要删就得连 Caddy 这条路一起放弃, 那是产品决定,
   不是清理动作能顺手做的。

因此保留, 但标记清楚。满足以下全部条件后可删:

- 确认无人再直接 curl 执行这四个脚本 (或接受破坏性变更)
- Caddy 路径的去留已定
- 删前确认 `conf/` 下没有脚本会调它们 (改代码时随手加回去的引用很难发现)

## 与 `conf/fd/legacy/` 的区别

`conf/fd/legacy/` 装的是**反向代理**的两代实现, 判定依据是"新的一代尚未
在生产验证过", 所以不能删。

本目录装的是**节点生成 + nginx/caddy** 的两代实现, 判定依据是"能力已被
覆盖但可能仍有外部使用者", 同样不能删。

两组都不能删, 但原因不同 —— 混淆这两者会导致该保留的被删, 或该删的
被永久留下。

## 另两个易被误判的脚本

**`xargo.sh`** —— 零引用, 但**不是死代码**。它管 cloudflared 隧道的生命周期
(建/删/状态/重启/健康定时器), 而 `conf/GDargo.sh` 和 `conf/lsargo.sh` 只是
生成器, 负责写出 `conf/argo.json` 与 `argo_state.env`。两者互补, 由 argo
域名串联。删掉 `xargo.sh` 不会让面板少一个入口, 但会让已建的 argo 隧道失去
管理与自愈。

**`bin/xray_install.sh`** —— 曾位于 `unused/` 目录, 名字让人以为是死码,
实际是面板菜单 1 (安装/更新 xray) 的唯一实现。目录名是历史遗留, 已迁到
`bin/`。这是"目录名会骗人"的典型。
