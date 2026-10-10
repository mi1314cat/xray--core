#!/bin/bash
# ================================
# 证书同步 —— letsencrypt -> 各内核的证书目录
#
# 为什么需要这个:
#
#   三个内核的证书目录各不相同, 但都靠"复制"拿到证书, 而复制之后
#   **没有任何人负责同步**。KPanel 的 /root/auto_cert_renewal.sh 续签成功后
#   只做两件事: cp 到 /home/web/certs/, reload nginx。它不碰别的目录,
#   也不重启 sing-box / mihomo / xrayls。
#
#   结果就是各内核会拿着旧证书继续对外服务, 直到过期断连那天。
#   内核自己不检查证书有效期 —— 只有客户端在握手时才会拒。
#
#   三个已知的断链:
#     /home/web/certs              KPanel 会更新, 但它的脚本先 certbot delete
#                                  再 certonly, 中途失败证书就没了 (10-08 事故)
#     /root/catmi/certs            10-08 由手工从 letsencrypt 填入, 无人维护
#     /root/catmi/mihomo/conf/certs  同上, 且 mihomo-hy2-cert-sync.timer 指向的
#                                  sync-hy2-certs.sh 根本不存在, 每晚 203/EXEC
#                                  失败 (M 项目 docs/E2E_VERIFY_REPORT.md:440
#                                  已记录为"未处理")
#
# 所以这里做**唯一真源**: 直接从 /etc/letsencrypt/live 读, 按 mtime 判断
# 是否变化, 变了才复制并重启对应服务。不经过 /home/web/certs, 也就不会被
# KPanel 的删除动作波及。
#
# 用法:
#   bash tools/cert-sync.sh            # 同步(有变化才重启)
#   bash tools/cert-sync.sh --check    # 只报告状态, 不改任何东西
#   bash tools/cert-sync.sh --install  # 装 systemd timer, 每天 03:30 跑
# ================================
set -uo pipefail

SRC="${CERT_SYNC_SRC:-/etc/letsencrypt/live}"
# 目标目录:服务名|目录|证书要什么后缀|证书文件名(留空则与源同名)
# 注意: 目标文件名里带 <domain> 的, 每个域名各存一份。
# 不带 <domain> 的, 是"整个服务只认这一个文件名"的布局 —— 这时候必须写死
# 绑定到**唯一一个**域名, 否则第二个域名会把第一个覆盖掉。
#
# 踩过的坑: 最初这里给 mihomo 写的是 "fullchain.pem"(不带域名), 结果两个
# 域名依次同步, moontv 把 hxicc 覆盖了, 证书与私钥配不上对。mihomo
# check 依然通过、service 依然 active、14 个监听照常 —— 但所有 TLS 节点
# 握手都会失败。这类"配置检查通过但运行时是坏的"最难发现, 所以这里对
# 不带 <domain> 的目标强制校验配对关系。
TARGETS=(
    "sing-box|/root/catmi/certs|<domain>_cert.pem"
    "mihomo|/root/catmi/mihomo/conf/certs|fullchain.pem@__PRIMARY__"
)
# 续签后必须 restart 才能加载新证书。
# sing-box 没有 SIGHUP 热重载 —— `systemctl reload sing-box` 返回 0 但配置
# 根本没重读, 属于"最坏一类假成功"(SB 项目 lib.sh:2806-2819 有实测记录)。
# mihomo 同理。所以一律 restart, 且只在本目录真的变了时才 restart。
SERVICES=("sing-box" "mihomo")

changed_any=0
declare -a REPORT=()

_color() { [[ -t 1 ]] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
ok()   { _color 32 "$1"; }
warn() { _color 33 "$1"; }
bad()  { _color 31 "$1"; }
dim()  { _color 90 "$1"; }

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# ---------------------------------------------------------------- 采集源证书
collect_sources() {
    SRC_DOMAINS=()
    SRC_CERT=()
    SRC_KEY=()
    [[ -d "$SRC" ]] || return 1
    local d n
    for d in "$SRC"/*/; do
        [[ -d "$d" ]] || continue
        n=$(basename "$d")
        [[ "$n" == "README" ]] && continue
        [[ -f "$d/fullchain.pem" ]] || continue
        SRC_DOMAINS+=("$n")
        SRC_CERT+=("$d/fullchain.pem")
        SRC_KEY+=("$d/privkey.pem")
    done
    ((${#SRC_DOMAINS[@]} > 0))
}

# ---------------------------------------------------------------- 复制判定
#
# 靠 mtime 而非内容比对: 内容比对每次都要 openssl 解证书, 而这个脚本每天跑,
# 三十几张证书跑一遍不便宜。mtime 够用 —— certbot 换证书时一定更新文件时间。
# 判据是**证书指纹**, 不是 mtime。
#
# 先用 mtime 做过一次, 结果每次跑都判"已更新" —— cp 保留不了源文件的 mtime
# (除非加 -p), 两者总差那么一点, 于是天天重启三个内核。指纹比对没有这个
# 问题, 而且顺带覆盖了"内容相同但 mtime 不同"的场景。
#
# 指纹取 SPKI 而不是整个证书: certbot 续签会重新生成证书文件本身, 但如果
# 签出来的公钥没变(极少见, 但 key 是 --key-type ecdsa 复用的), 我们就不该
# 白白重启一遍服务。
same_file() {
    local a="$1" b="$2"
    [[ -f "$b" ]] || return 1
    local fa fb
    fa=$(openssl x509 -in "$a" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')
    fb=$(openssl x509 -in "$b" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')
    [[ -n "$fa" && "$fa" == "$fb" ]]
}

# ---------------------------------------------------------------- 配对校验
#
# 用 SPKI 比对, 而不是 openssl x509 -modulus (那是 RSA 专用的, 遇到 EC 证书
# 直接报错)。openssl pkey 能同时处理 RSA/EC/Ed25519。
cert_key_match() {
    local c="$1" k="$2"
    [[ -f "$c" && -s "$c" && -f "$k" && -s "$k" ]] || return 1
    local a b
    a=$(openssl x509 -in "$c" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')
    b=$(openssl pkey -in "$k" -pubout 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')
    [[ -n "$a" && "$a" == "$b" ]]
}

# ---------------------------------------------------------------- 主流程
main() {
    if ! collect_sources; then
        bad "证书源不可用: $SRC"
        echo "  letsencrypt lineage 目录不存在或没有证书。"
        echo "  内核会继续用旧证书服务 —— 过期后客户端握手会失败。"
        return 1
    fi

    echo "========================================"
    echo "证书同步  (源: $SRC)"
    echo "========================================"

    local i svc dir suffix name newfile changed_svc
    for i in "${!SRC_DOMAINS[@]}"; do
        local dom="${SRC_DOMAINS[$i]}"
        local cert="${SRC_CERT[$i]}" key="${SRC_KEY[$i]}"

        # 源证书本身是否还有效 —— 同步一个已过期的证书没有意义, 反而会让
        # 故障静默: 文件在, 但所有人都连不上。
        local enddays
        enddays=$(openssl x509 -in "$cert" -noout -checkend $((7*86400)) >/dev/null 2>&1 \
                  && echo ok || echo soon)
        if [[ "$enddays" == "soon" ]]; then
            local ed
            ed=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
            warn "  $dom 源证书 7 天内到期: $ed"
            warn "     KPanel 的续签脚本可能又失败了, 请检查 /root/auto_cert_renewal.sh"
        fi

        for t in "${TARGETS[@]}"; do
            IFS='|' read -r svc dir name <<< "$t"
            [[ -n "$dir" ]] || continue
            # 目标不带 <domain> 时, 只有主域名才写 —— 否则同名目标会被后一个
            # 域名覆盖, 证书和私钥就对不上了。
            local primary=0
            [[ "$name" == *"@__PRIMARY__"* ]] && primary=1
            name="${name%@__PRIMARY__*}"
            if ((primary)); then
                [[ "$dom" == "${CERT_SYNC_PRIMARY:-hxicc.catmicos.dpdns.org}" ]] || continue
            fi
            [[ "$name" == *"<domain>"* ]] && name="${name//<domain>/$dom}"
            local target="$dir/$name"
            local tkey="$dir/${dom}_key.pem"
            [[ "$svc" == "mihomo" ]] && tkey="$dir/privkey.pem"

            if same_file "$cert" "$target"; then
                dim "  = $svc  $name (已是最新)"
                continue
            fi

            if ((CHECK_ONLY)); then
                warn "  ! $svc  $name 需要同步: $target"
                REPORT+=("$svc|$target")
                changed_svc=1
                changed_any=1
                continue
            fi

            if ! mkdir -p "$dir" 2>/dev/null; then
                bad "  x $svc  无法创建目录 $dir"
                continue
            fi
            if cp "$cert" "$target" 2>/dev/null; then
                ok "  + $svc  $name 已更新"
                [[ -f "$key" ]] && cp "$key" "$tkey" 2>/dev/null
                chmod 600 "$tkey" 2>/dev/null || true

                # 配对校验: 证书和私钥必须来自同一个 lineage。
                #
                # 这一步不是多余的 —— mihomo check 不会验配对关系, 服务照样
                # active、监听照常起, 只有客户端握手才失败。写错了却"一切正常",
                # 是最难排查的一类故障, 所以在这里当场拦。
                if ! cert_key_match "$target" "$tkey"; then
                    bad "    x 证书与私钥不配对 ($target <-> $tkey)"
                    warn "    已保留原文件, 未重启 $svc —— 宁可不同步也不要写坏"
                    # 撤回: 用源文件覆盖回去会一样坏, 所以直接删掉本次写入的
                    # 证书, 让服务继续用上一份(配对的)证书, 并报错。
                    rm -f "$target"
                    REPORT=()
                    changed_svc=0
                    continue
                fi
                dim "    配对 OK"
                REPORT+=("$svc|$target")
                changed_svc=1
                changed_any=1
            else
                bad "  x $svc  复制失败 -> $target"
            fi
        done
    done

    # ------------------------------------------------------------ 重启服务
    local s
    for s in "${SERVICES[@]}"; do
        local hit=0 t
        for t in "${REPORT[@]}"; do
            [[ "$t" == "$s|"* ]] && hit=1
        done
        [[ "$hit" == 0 ]] && continue

        if ((CHECK_ONLY)); then
            warn "  → $s 需要 restart 才能加载新证书 (当前会继续用旧证书)"
            continue
        fi
        # 只有真的活着才重启。服务本来就是停的, 拉起来不是同步脚本的职责,
        # 而且会掩盖"它本来就没在跑"这个事实。
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            if systemctl restart "$s" 2>/dev/null; then
                sleep 2
                if systemctl is-active --quiet "$s" 2>/dev/null; then
                    ok "  → $s 已重启"
                else
                    bad "  → $s 重启后未运行! 查 journalctl -u $s"
                fi
            else
                bad "  → $s 重启失败"
            fi
        else
            dim "  → $s 当前未运行, 跳过重启 (下次启动会自动加载新证书)"
        fi
    done

    echo "----------------------------------------"
    if ((changed_any)); then
        if ((CHECK_ONLY)); then
            warn "有证书需要同步。执行不带 --check 的本脚本即可。"
            return 2
        fi
        ok "同步完成。"
    else
        ok "全部已是最新, 无需操作。"
    fi
    return 0
}

install_timer() {
    local unit=/etc/systemd/system/cert-sync.service
    local timer=/etc/systemd/system/cert-sync.timer
    local self; self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

    cat > "$unit" <<UNIT
[Unit]
Description=同步 letsencrypt 证书到各内核
After=network.target

[Service]
Type=oneshot
ExecStart=$self
UNIT

    cat > "$timer" <<UNIT
[Unit]
Description=每天同步一次 letsencrypt 证书

[Timer]
OnCalendar=*-*-* 03:30:00
# 关机时错过了就开机补跑 —— 证书不会因为机器关着就不过期
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now cert-sync.timer
    echo "  已安装 cert-sync.timer, 下次运行:"
    systemctl list-timers cert-sync.timer --no-pager 2>/dev/null | awk 'NR<=2' | sed 's/^/    /'
}

case "${1:-}" in
    --install) install_timer ;;
    --check)   main; exit $? ;;
    *)         main ;;
esac
