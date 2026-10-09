# sing-box-core（SB 内核）已知问题

> 记录日期：2026-10-09
> 环境：RN（服务端，Debian 13 / x86_64），sing-box 1.14.2
> 这些问题**在 X 内核里已经处理**，SB 侧尚未修（SB 是独立项目，不在本仓库改动范围）。

## 🔴 P0：SB 全部 TLS 节点依赖第三方脚本的证书目录

### 现象

RN 上 `sing-box` 的 **7 个配置文件全部**引用同一个证书路径：

```
/root/catmi/sing-box/config/anytls-01.json     → /home/web/certs/hxicc..._cert.pem
/root/catmi/sing-box/config/hysteria2-01.json  → 同上
/root/catmi/sing-box/config/naive-01.json      → 同上
/root/catmi/sing-box/config/trojan-01.json     → 同上
/root/catmi/sing-box/config/tuic-01.json       → 同上
/root/catmi/sing-box/config/vless-01.json      → 同上
/root/catmi/sing-box/config/vmess-01.json      → 同上
```

`/home/web/certs/` 由 **KPanel 的续签脚本**管理，不是 SB 自己的目录。

### 根因

KPanel 的 `/root/auto_cert_renewal.sh`（cron `0 0 * * *`，每天午夜）续签时的顺序是：

```bash
certbot delete --cert-name "$yuming"      # ① 先删 lineage
certbot certonly ... --force-renewal     # ② 再重新签发
cp .../fullchain.pem ..._cert.pem        # ③ 最后才复制回来
```

**先删后签**。三步里任何一步失败（网络、CA 限流、签发报错），磁盘上的
`*_cert.pem` 就永远不会回来。

2026-10-08 那次正是这样：`/home/web/certs` 里只剩 `*_key.pem`（私钥），
`*_cert.pem` 一个不剩。

### 为什么难以发现

**静默故障。** nginx 已经把证书加载进内存，网站照常能开，直到重启才暴露。
实测在线证书指纹与 `/etc/letsencrypt/live/` 里的完全一致 —— 证书一直好好地
在 letsencrypt 里，只是没被复制到 `/home/web/certs`。

### 影响范围（实测）

把 `/home/web/certs/*_cert.pem` 全部移走后逐个 check：

| 内核 | 依赖该路径 | 结果 |
|---|:--:|---|
| **sing-box** | ✓ 7 个配置 | **启动失败** |
| **Xray** | ✓ 5 个片段 | **启动失败** |
| mihomo | ✗ 自有 `conf/certs/` | 不受影响 |

即 **SB 整个服务对第三方脚本的单点故障是敞开的** —— 对方的续签脚本一旦
出问题，SB 直接起不来。

### 修复方向

照 mihomo 的做法（它是对的）：证书从 letsencrypt 复制一份到项目自己的目录，
配置只引用那里。

```bash
mkdir -p /root/catmi/certs
cp /etc/letsencrypt/live/<domain>/fullchain.pem /root/catmi/certs/<domain>_cert.pem
cp /etc/letsencrypt/live/<domain>/privkey.pem    /root/catmi/certs/<domain>_key.pem
sed -i 's#/home/web/certs/#/root/catmi/certs/#g' /root/catmi/sing-box/config/*.json
```

X 内核已在 RN 上完成这一步并验证（见 `docs/xray-unique-e2e.md` 与
`conf/lib/cert.sh` 的 `x_cert_sync`）。

## 🟡 P1：`cdn_check_node` 对 QUIC 类协议的 CDN 判定

mihomo 侧记录过：AnyTLS / Hysteria2 / TUIC 是原生 TCP/UDP 或专用协议，
Cloudflare 代理不了，走 CDN 会失败。SB 的 `cdn_node.sh` / `cdn_check_node`
需要确认是否有同样的判定，否则用户会配出"看着对、实际连不通"的节点。

**未验证** —— 待在 SB 仓库实测后补充。

## 🟡 P1：自签证书缺 SAN

SB 自签路径若用 `openssl req -subj "/CN=$dom"` 而不加
`-addext subjectAltName`，会产出只有 legacy CN 的证书，现代内核直接拒：

```
x509: certificate relies on legacy Common Name field
        use SANs instead
```

X 内核已修（`conf/vlessxhttpecn.sh` 的 `generate_cert`），SB 侧**待核实**。

## 🟡 P1：客户端不 pin 自签证书

自签证书的签发者不在任何信任链里，客户端必须 pin，否则报
`x509: certificate signed by unknown authority`。

Xray 26.x 有两个坑（实测踩出来）：

- `allowInsecure` **已移除**，内核原话：
  `The feature "allowInsecure" has been removed and migrated to "pinnedPeerCertSha256"`
- `pinnedPeerCertSha256` 收**十六进制字符串**，不是 base64 也不是数组
  - 给 base64 → `encoding/hex: invalid byte`
  - 给数组 → `cannot unmarshal array into Go struct field TLSConfig`

X 内核已在客户端配置生成时自动注入（`conf/vlessxhttpecn.sh`），
SB 侧**待核实**。

## 复核方式

```bash
# SB 引用了哪些证书
grep -rhoE 'certificate_path[^,}]*' /root/catmi/sing-box/config/*.json | sort -u

# 模拟证书丢失
mv /home/web/certs/hxicc.catmicos.dpdns.org_cert.pem /tmp/
/root/catmi/sing-box/sing-box check -C /root/catmi/sing-box/config   # 预期失败
mv /tmp/hxicc.catmicos.dpdns.org_cert.pem /home/web/certs/
```