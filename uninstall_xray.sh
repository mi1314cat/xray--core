#!/bin/bash
# =============================================================
# 卸载 xrayls (Xray 服务端面板 + 内核 + 节点配置)
#
#   bash uninstall_xray.sh                 交互: 先说清删什么, 输 yes 才动手
#   bash uninstall_xray.sh --dry-run       只看它打算删什么 (不动任何文件)
#   bash uninstall_xray.sh --yes           非交互 (脚本化)
#   bash uninstall_xray.sh --keep-data     只卸程序与内核, 节点配置和产物留着
#   bash uninstall_xray.sh --purge-backups 连本脚本产生的备份一起删
#
# ★ 这个脚本重写过一次。第一版只有五行:
#
#       systemctl stop xrayls.service
#       systemctl disable xrayls.service
#       rm -rf /etc/xrayls
#       rm -rf /usr/local/bin/xrayls
#       rm -rf /root/catmi/xray
#
#   实测 (用诱饵目录跑的, 没碰真数据) 的结论:
#     · 它**只删这几条固定路径**, 邻居 (证书 / 别的内核 / nginx 站点) 一个没动
#       —— 这方面是干净的;
#     · 但 `rm -rf` 前面**没有任何确认、没有任何备份**: 39M、56 个节点片段、
#       252 份客户端产物, 一条命令就没了;
#     · 前两条 `rm` 打的是**面板根本不装在那里**的路径 (内核在
#       $SRV_ROOT/xrayls, 不在 /usr/local/bin) —— 无害的空操作, 但会让人
#       以为装过那两个地方;
#     · **systemd 单元文件没删**: 卸完 `systemctl status xrayls` 还认得它,
#       只是启动会失败 (找不到二进制);
#     · **nginx 里我们插进去的 location 不摘**: 那些 location 继续指向一个
#       已经没人监听的端口, 访问对应路径得到 502 —— 用户以为卸干净了,
#       其实站点上留着一堆指向空气的入口。
#
#   现在: 先列清单 → 要确认 → 先备份 → 摘 nginx → 停服务 → 删单元 → 删目录。
#   任何一步失败都停在那儿并说清楚, 不半途而废。
# =============================================================

set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=""; GRN=""; YEL=""; CYN=""; RST=""; }
say()  { printf "  ${CYN}[--]${RST} %s\n" "$*"; }
ok()   { printf "  ${GRN}[OK]${RST} %s\n" "$*"; }
warn() { printf "  ${YEL}[!]${RST} %s\n" "$*"; }
err()  { printf "  ${RED}[X]${RST} %s\n" "$*"; }

SRV_ROOT="${XRAY_BASE:-/root/catmi/xray}"
SERVICE="${XRAY_SERVICE:-xrayls}"
UNIT="/etc/systemd/system/${SERVICE}.service"
LEGACY_DIRS=(/etc/xrayls /usr/local/bin/xrayls)

YES=0; DRY=0; KEEP_DATA=0; PURGE_BACKUPS=0
for a in "$@"; do
    case "$a" in
        --yes|-y)        YES=1 ;;
        --dry-run|-n)    DRY=1 ;;
        --keep-data)     KEEP_DATA=1 ;;
        --purge-backups) PURGE_BACKUPS=1 ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) err "未知参数: $a (可用: --yes | --dry-run | --keep-data | --purge-backups)"; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- 这是我们的吗
# ★ "不能删错" 的核心只有这一条: **在动手之前先证明这个目录是我们的**。
#   判据用"安装器一定会留下的东西", 而不是"路径长得像" —— 路径是可以被
#   任何人占用的, 而且 $SRV_ROOT 能用 XRAY_BASE 指到别处。
dir_is_ours() {
    [[ -d "$1" ]] || return 1
    [[ -x "$1/xrayls" || -d "$1/conf" || -f "$1/config.json" || -d "$1/.panel" ]]
}

if [[ -L "$SRV_ROOT" ]]; then
    err "$SRV_ROOT 是一个符号链接 (指向 $(readlink "$SRV_ROOT"))。"
    err "卸载脚本不跟随符号链接 —— 万一它指到别处, 删的就不是你以为的那个目录。"
    exit 3
fi

echo
printf '%s\n' "════════ 卸载 xrayls ════════"
say "安装目录: $SRV_ROOT"
say "服务单元: $UNIT"

if [[ -e "$SRV_ROOT" ]]; then
    if ! dir_is_ours "$SRV_ROOT"; then
        err "$SRV_ROOT 存在, 但**看不出是 xrayls 的安装目录**"
        err "(里面没有 xrayls / conf / config.json / .panel 任何一样)"
        err "已中止, 一个文件都没有动。如果你确实要删它, 请手动处理。"
        exit 3
    fi
    _marks=""
    [[ -x "$SRV_ROOT/xrayls" ]] && _marks="内核 "
    [[ -d "$SRV_ROOT/conf" ]] && _marks="${_marks}conf/ "
    [[ -d "$SRV_ROOT/.panel" ]] && _marks="${_marks}.panel/ "
    ok "确认是我们的安装目录 (含 ${_marks})"
else
    warn "$SRV_ROOT 不存在 —— 目录部分跳过, 只清理服务与 nginx"
fi

# ---------------------------------------------------------------- 清单
NODES=0; PRODUCTS=0; HEADSIZE="?"
[[ -d "$SRV_ROOT/conf" ]] && NODES=$(ls -1 "$SRV_ROOT/conf"/*.json 2>/dev/null | wc -l | tr -d ' ')
[[ -d "$SRV_ROOT/out" ]] && PRODUCTS=$(ls -1 "$SRV_ROOT/out"/* 2>/dev/null | wc -l | tr -d ' ')
[[ -d "$SRV_ROOT" ]] && HEADSIZE=$(du -sh "$SRV_ROOT" 2>/dev/null | cut -f1)

echo
say "将要删除:"
printf "    %-46s %s\n" "$SRV_ROOT" "整个安装目录 ($HEADSIZE)"
[[ "$KEEP_DATA" == "1" ]] && printf "    %-46s %s\n" "  └ --keep-data" "只删内核与面板, 保留 conf/ out/"
printf "    %-46s %s\n" "$UNIT" "systemd 单元文件"
for d in "${LEGACY_DIRS[@]}"; do
    [[ -e "$d" ]] && printf "    %-46s %s\n" "$d" "存在, 一并删"
done
printf "    %-46s %s\n" "nginx 里我们插入的 location" "按标记摘除 (段外一个字符都不动)"
echo
say "其中包含: ${NODES} 个节点片段 / ${PRODUCTS} 份客户端产物与元数据"
[[ "$KEEP_DATA" == "0" ]] && warn "节点配置会一起没有 —— 但**会先打包备份**"
echo
say "不会被碰的:"
printf "    %-46s\n" "证书目录 (通常在 $(dirname "$SRV_ROOT")/certs)"
printf "    %-46s\n" "nginx 站点文件本身 (只摘我们标记的那几段)"
printf "    %-46s\n" "同目录下的其它东西 (别的内核 / 备份 / 你自己的文件)"
printf "    %-46s\n" "分享服务里的记录 (那是独立服务)"

if [[ "$DRY" == "1" ]]; then
    echo; ok "预演结束 —— 一个文件都没有动 (去掉 --dry-run 才会真删)"
    exit 0
fi

# ---------------------------------------------------------------- 确认
if [[ "$YES" != "1" ]]; then
    echo
    printf '  %s真要卸载吗? 它会停掉服务并删除上面的目录。%s\n' "$YEL" "$RST"
    printf '  确认请输入 yes (其它任何输入都取消): '
    _a=""
    read -r _a || _a=""
    if [[ "$_a" != "yes" ]]; then
        say "已取消, 一个文件都没有动"
        exit 0
    fi
fi

# ---------------------------------------------------------------- 备份
BACKUP=""
UNIT_BAK="$(dirname "$SRV_ROOT")/${SERVICE}.service.uninstall-bak"
if [[ -d "$SRV_ROOT" && "$KEEP_DATA" == "0" ]]; then
    BACKUP="$(dirname "$SRV_ROOT")/xray-uninstall-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    say "先备份…"
    # ★ 只打包"用户会心疼的": conf / out / 元数据 / 托管面板 / 安装信息。
    #   35M 的内核二进制不进来 —— 它是可下载的, 打进去只会让备份大十倍。
    #   备份**放在被删目录的外面**, 否则会跟着一起没。
    _items=()
    for d in conf out share share-state .panel; do
        [[ -d "$SRV_ROOT/$d" ]] && _items+=("$d")
    done
    for f in install_info.env config.json; do
        [[ -f "$SRV_ROOT/$f" ]] && _items+=("$f")
    done
    if (( ${#_items[@]} > 0 )) && tar czf "$BACKUP" -C "$SRV_ROOT" "${_items[@]}" 2>/dev/null; then
        ok "已备份: $BACKUP ($(du -h "$BACKUP" 2>/dev/null | cut -f1))"
        say "    恢复: tar xzf $BACKUP -C $SRV_ROOT"
    else
        warn "备份失败 (${BACKUP:-没有可备份的内容})"
        printf '  仍要继续删除? 输入 yes: '
        _b=""; read -r _b || _b=""
        [[ "$_b" == "yes" ]] || { say "已取消"; exit 0; }
        BACKUP=""
    fi
fi
if [[ -f "$UNIT" ]]; then
    cp -f "$UNIT" "$UNIT_BAK" 2>/dev/null && say "单元文件也留了一份: $UNIT_BAK"
fi

# ---------------------------------------------------------------- 摘 nginx
# ★ 必须在删目录之前做 —— 相关逻辑就在被删的那个目录里。
#   这里**内联实现**而不是调用 conf/lib/nginx_apply.py: 卸载常常发生在
#   "目录已经半坏"的时候, 那时候再去依赖目录里的文件是本末倒置。
#   判据与 nginx_apply 一致: 只认我们自己写的 BEGIN/END 标记配对, 段外不动。
# 站点目录自己找, 不指望调用方传 —— 用户是直接 `bash uninstall_xray.sh` 跑的。
# 顺序: 显式变量 → **跑着 nginx 的容器挂载点** (容器装法下宿主机路径不是
# /etc/nginx/conf.d, 只在宿主机上找会一个站点都找不到) → 常见默认位置。
_ngx_roots() {
    if [[ -n "${NGINX_CONF_ROOTS:-}" ]]; then printf '%s' "$NGINX_CONF_ROOTS"; return 0; fi
    local roots="" dc src dst
    # 不用管道取第一行 —— 管道里的 head 会让产出方吃 SIGPIPE (pipefail 下随机猝死)
    dc=$(docker ps -qf name=nginx 2>/dev/null || true)
    dc=${dc%%$'\n'*}
    if [[ -n "$dc" ]]; then
        while IFS='|' read -r src dst; do
            [[ -n "$src" && -n "$dst" && "$dst" == *nginx* ]] || continue
            [[ -d "$src" ]] || continue
            roots="${roots:+$roots:}$src"
        done < <(docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$dc" 2>/dev/null)
    fi
    for d in /home/web/conf.d /etc/nginx/conf.d /etc/nginx/sites-enabled \
             /usr/local/nginx/conf /usr/local/openresty/nginx/conf /etc/nginx; do
        [[ -d "$d" ]] || continue
        case ":$roots:" in *":$d:"*) continue ;; esac
        roots="${roots:+$roots:}$d"
    done
    printf '%s' "$roots"
}

NGINX_CONF_ROOTS="$(_ngx_roots)"
if [[ -n "$NGINX_CONF_ROOTS" ]]; then
    say "摘除 nginx 里我们插入的 location…"
    say "    站点目录: $NGINX_CONF_ROOTS"
    _ngx_out=$(NGX_ROOTS="$NGINX_CONF_ROOTS" python3 - <<'PYEOF' 2>&1
import os, re
roots = [r for r in os.environ.get("NGX_ROOTS", "").split(":") if r]
files = []
for r in roots:
    for dirpath, _dirs, names in os.walk(r):
        for n in names:
            if n.endswith(".conf") and not re.search(r"\.(bak|save|orig|old|disabled)$", n):
                files.append(os.path.join(dirpath, n))
BEGIN = re.compile(r"^[ \t]*# >>> xray-core BEGIN .*?>>>[ \t]*$")
END = re.compile(r"^[ \t]*# <<< xray-core END .*?<<<[ \t]*$")
tf = tb = 0
for path in files:
    try:
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
            lines = f.read().splitlines(keepends=True)
    except OSError:
        continue
    out, i, n, removed = [], 0, len(lines), 0
    while i < n:
        if BEGIN.match(lines[i].rstrip("\r\n")):
            j = i + 1
            while j < n and not END.match(lines[j].rstrip("\r\n")):
                j += 1
            if j < n:
                k = j + 1
                if k < n and lines[k].strip() == "":
                    k += 1
                removed += 1
                i = k
                continue
        out.append(lines[i]); i += 1
    if removed:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.writelines(out)
        print("  removed %d block(s) from %s" % (removed, path))
        tf += 1; tb += removed
print("RESULT %d %d" % (tf, tb))
PYEOF
)
    _ngx_files=$(printf '%s' "$_ngx_out" | sed -n 's/^RESULT \([0-9]*\) .*/\1/p')
    _ngx_blocks=$(printf '%s' "$_ngx_out" | sed -n 's/^RESULT [0-9]* \([0-9]*\)/\1/p')
    printf '%s' "$_ngx_out" | grep '^  removed' | sed 's/^/  /'
    if [[ "${_ngx_blocks:-0}" -gt 0 ]]; then
        ok "摘了 ${_ngx_blocks} 段 (涉及 ${_ngx_files} 个站点文件)"
        # 容器里的 nginx 与宿主机是两套路径, 用 docker exec 才对得上
        _dc=$(docker ps -qf name=nginx 2>/dev/null || true)
        _dc=${_dc%%$'\n'*}
        if [[ -n "$_dc" ]]; then
            if docker exec "$_dc" nginx -t >/dev/null 2>&1 && docker exec "$_dc" nginx -s reload >/dev/null 2>&1; then
                ok "nginx 校验通过并已 reload"
            else
                warn "nginx 校验/reload 没过 —— 请看 docker logs $_dc"
            fi
        elif command -v nginx >/dev/null 2>&1; then
            if nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1; then
                ok "nginx 校验通过并已 reload"
            else
                warn "nginx 校验/reload 没过"
            fi
        else
            warn "没找到 nginx, 摘除后请自行校验"
        fi
    else
        say "nginx 里没有我们插入的片段, 无需处理"
    fi
else
    warn "一个站点目录都没找到 —— nginx 部分跳过"
    say "    如果 nginx 装在别处: NGINX_CONF_ROOTS=/你的/conf.d bash uninstall_xray.sh"
fi

# ---------------------------------------------------------------- 服务与单元
say "停止服务…"
if systemctl stop "$SERVICE" 2>/dev/null; then ok "已停止 $SERVICE"; else say "$SERVICE 本来就没在跑"; fi
systemctl disable "$SERVICE" >/dev/null 2>&1 && ok "已禁用开机自启"
# ★ 单元文件必须删掉。第一版只 stop+disable, 于是卸完
#   `systemctl status xrayls` 还认得这个服务 —— 用户会以为没卸干净,
#   而且它会以 failed 状态一直挂在那儿。
if [[ -f "$UNIT" ]]; then
    if rm -f "$UNIT"; then ok "已删除单元文件 $UNIT"; else warn "删不掉单元文件 $UNIT"; fi
    systemctl daemon-reload 2>/dev/null || true
fi
systemctl reset-failed "$SERVICE" 2>/dev/null || true

# ---------------------------------------------------------------- 删目录
if [[ -d "$SRV_ROOT" ]]; then
    if [[ "$KEEP_DATA" == "1" ]]; then
        say "--keep-data: 只删内核与面板, 保留 conf/ out/"
        [[ -f "$SRV_ROOT/xrayls" ]] && rm -f "$SRV_ROOT/xrayls" && ok "已删内核 $SRV_ROOT/xrayls"
        [[ -d "$SRV_ROOT/.panel" ]] && rm -rf "$SRV_ROOT/.panel" && ok "已删托管面板 $SRV_ROOT/.panel"
        rm -f "$SRV_ROOT/config.json" 2>/dev/null || true
    else
        if rm -rf "$SRV_ROOT"; then ok "已删除 $SRV_ROOT"; else err "删不掉 $SRV_ROOT"; exit 4; fi
    fi
fi
for d in "${LEGACY_DIRS[@]}"; do
    [[ -e "$d" ]] && rm -rf "$d" && ok "已删除 $d"
done

# ---------------------------------------------------------------- 收尾
if [[ "$PURGE_BACKUPS" == "1" && -n "${BACKUP:-}" && -f "${BACKUP:-}" ]]; then
    rm -f "$BACKUP" && say "已按 --purge-backups 删除备份"
fi

echo
printf '%s\n' "════════ 卸载完成 ════════"
[[ -n "${BACKUP:-}" && -f "${BACKUP:-}" ]] && ok "备份还在: $BACKUP"
[[ "$KEEP_DATA" == "1" ]] && ok "节点配置与产物保留在 $SRV_ROOT"
say "没有动过: 证书、nginx 站点文件、同目录下的其它项目"
say "重新安装: bash <(curl -fsSL <仓库>/install.sh) server"
