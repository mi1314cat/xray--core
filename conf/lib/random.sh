#!/usr/bin/env bash
# ================================================================
# 随机值生成 —— 端口/路径/密码/用户名共用的随机源
#
# 为什么单独抽出来:
#   这些函数原先散在各处, 而且**有一半根本没定义**。现场抓到的:
#
#     random_path   只定义在 conf/fd/legacy/server-reverse.sh,
#                   conf/vlessxhttpecn.sh 却在调它 —— 于是那条命令返回空,
#                   XHTTP 路径退化成 "/"。路径是 nginx 按路径转发的匹配依据,
#                   退化后所有 xhttp 节点挤在同一个路径上。
#
#     random_pass   **零处定义**, 被 Trojan.sh / http.sh / sock5.sh 调
#     random_user   **零处定义**, 被 http.sh / sock5.sh 调
#
#   random_pass 这两个更严重: 调用方拿到的默认值是空字符串, 而脚本用
#   `$(random_pass)` 的结果当"回车即用的默认值"。用户不回车就拿到空密码 ——
#   节点能建起来、能跑、看起来一切正常, 但任何人都能用空密码连上。
#   这属于"配置生成成功但安全失效", 比直接报错难发现得多。
#
#   之所以一直没暴露: 交互式运行时用户总会自己敲一个值, 默认值空着看不出来;
#   而 `$(未定义命令)` 的退出码没人检查, stderr 被 `2>&1` 混进了彩笔输出里。
#
# 统一放一处, 顺带把 legacy 那份实现收编, 不再各写各的。
#
# 输出一律带换行: 直接 `tr ... | head -c N` 不带换行, 捕获到变量里没问题,
# 但输出到文件或和下一段拼接时会和后一行黏在一起(random_path 一直有
# echo 所以没事, 这三个照抄时漏了)。
# ================================================================

# random_path —— URL 路径, 8 位字母数字, 带首斜杠
#
# 长度选 8: nginx location 是精确匹配, 路径要够长才不会被猜到; 再长对
# 排障不友好(要手敲)。legacy 那份就是这个长度, 保持一致, 免得同一批
# 节点的路径形态前后不一样。
random_path() {
    echo "/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)"
}

# random_pass —— 20 位密码
#
# 字母数字混排, 不用符号: 密码要出现在分享链接和 YAML 里, 带符号会被
# URL 编码搞出 %XX, 客户端解析时多一层出错的地方。
random_pass() {
    echo "$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)"
}

# random_user —— 16 位用户名
#
# 比密码短: 用户名在 HTTP Basic 认证里要跟着每次请求走, 而它对强度的贡献
# 远小于密码。
random_user() {
    echo "$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"
}

# random_token —— 32 位, 给订阅令牌一类需要更长随机量的场合
random_token() {
    echo "$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"
}

# gen_psk —— Shadowsocks-2022 的 PSK (SIP022: 密码学安全随机 base64)
#
# ★ 这个函数被删过一次, 代价是"一键全协议"永远生成不出 SS2022:
#   1ef13f2 把端口分配收敛到 lib/ports.sh 时连同本函数一起删了 —— 它当时长在
#   Shadowsocks.sh 的"随机生成函数"块里, 与端口无关, 属于误删。调用点留着:
#   `PSK=$(gen_psk "$method")` → bash 报 `gen_psk: command not found`, 变量为空,
#   紧接着的长度校验报 "PSK 长度错误：2022-blake3-aes-256-gcm 需要 32 字节
#   (获得 0 字节)" —— 而 batch 汇总时又以退出码 0 收尾, 失败被完全掩盖。
#
#   放这里而不是各协议脚本里: 它是"随机值生成"这一类, 与 random_pass 同级;
#   当年散在各脚本里正是这次误删的成因。
#
# 长度由**算法**决定, 不能一律 32 字节:
#   2022-blake3-aes-128-gcm -> 16 字节原文 (base64 24 字符)
#   2022-blake3-aes-256-gcm / 2022-blake3-chacha20-poly1305 -> 32 字节 (44 字符)
# openssl rand -base64 的输出**带 '=' 填充**, 不能为了"干净"去掉:
# 去掉后 base64 解码不再对齐, 内核报 illegal base64 或长度不符。
gen_psk() {
    local method="${1:-}" bytes=32
    case "$method" in
        2022-blake3-aes-128-gcm) bytes=16 ;;
        *) bytes=32 ;;   # aes-256-gcm / chacha20-poly1305 / 未给方法
    esac
    openssl rand -base64 "$bytes" | tr -d '\n'
}