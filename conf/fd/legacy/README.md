# conf/fd/legacy

第一代 Xray 反向代理实现，**保留备查，不要使用**。

| 脚本 | 首次提交 | 状态 |
|---|---|---|
| `server-reverse.sh` | 2026-05-20 | 已被 `../xrayserver-reverse.sh` 取代 |
| `client-reverse.sh` | 2026-05-20 | 已被 `../xrayclient-reverse.sh` 取代 |

## 为什么不删

两代机制不同，但都能跑：

```jsonc
// 第一代: portal 用 socks 入站
{ "protocol": "socks", "tag": "$portal", "settings": {"auth":"noauth"} }

// 当前: portal 用 tunnel 入站 (Xray 反代的标准做法)
{ "protocol": "tunnel", "tag": "..." }
```

新一代虽然接进了面板菜单 9，但**尚未经过真实长期实机验证**。
在替代品有实测证据之前删掉这一代，等于毁掉唯一的备份。

## 什么时候可以删

新一代完成实机验证（建连成功 + 与 nginx 无冲突）之后。
