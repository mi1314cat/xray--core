#!/usr/bin/env bash
# =============================================================
# xray--core 安装引导
#
#   bash <(curl -fsSL <仓库>/install.sh)              # 选择 服务端 / 客户端
#   bash <(curl -fsSL <仓库>/install.sh) server       # 直接进服务端面板
#   bash <(curl -fsSL <仓库>/install.sh) client       # 直接装/进客户端
#   bash <(curl -fsSL <仓库>/install.sh) uninstall    # 卸载(服务端 / 客户端 二选一)
#   bash <(curl -fsSL <仓库>/install.sh) --status     # 只报告状态
#   bash <(curl -fsSL <仓库>/install.sh) server update   # 强制取远端最新版再进
#
#   ---- 面板自身 (更新 / 回退) ----
#   bash <(curl -fsSL <仓库>/install.sh) update-panel     # 手动更新面板脚本
#   bash <(curl -fsSL <仓库>/install.sh) panel-rollback   # 回退到上一个版本
#   bash <(curl -fsSL <仓库>/install.sh) panel-status     # 看当前版本与备份
#
#   进服务端面板时会**自动**比对一次远端 (可用 XRAY_NO_UPDATE=1 跳过,
#   时限 XRAY_UPDATE_BUDGET 默认 20 秒; 连不上就用本机这份继续进)。
#   面板里也有同一组入口: 主菜单 12) 更新面板脚本。
#
# ★ 为什么要有这个入口 (借鉴 mihomo--core / sing-box-core):
#
#   X 原来有两个入口, 互不知道对方存在:
#       服务端   xray-panel.sh
#       客户端   Client/l.sh
#   用户拿到一个仓库地址, 得先知道"我要装哪个、该跑哪个脚本"。两个内核
#   都是**一个引导脚本 + 角色参数**, 这里对齐。
#
# =============================================================
# ★ 取文件的策略 —— 分两种, 别混:
#
#   A) 面板之外的脚本 (客户端 l.sh / 卸载脚本 ...): **本地优先, 远端兜底**。
#      原来的写法是"只走远端": 4 个镜像 × 每源重试 2 次 × 25 秒 = 最坏 **200 秒**
#      停在那儿不动, 失败就直接 die。用户的要求是:
#
#          「如果连接不上, GitHub 更新不了的时候, 它应该就用自己的,
#            不应该停在那边」
#
#      所以三条规矩:
#        1. 本机已经有能用的那份 → 直接用它, **一次网络都不发**。
#        2. 本地没有才去下载; 远端挂了且本地有 → 退回本地, 明确告诉用户
#           "这是本地那份, 更新没成功", 但**照常继续**。
#        3. 远端拿到的文件先验一下是不是真脚本 —— 404 的 HTML 页存成 .sh,
#           后面报的是语法错误, 跟网络八竿子打不着, 极难查。
#
#   B) **面板脚本本身 (xray-panel.sh): 先比对, 再决定用哪份**。
#      "本地优先"对它在**事实上是错的** —— 本机躺着的那份正是"上次装的那份",
#      用它等于永远不更新。2026-10-15 线上事故就是这么来的: 10-10 的旧面板
#      被优先采用, 旧面板里一个已修掉的缓存 bug 让整个子菜单点不动, 而
#      用户看到的现象是"GitHub 上是好的, 我这里坏"。
#      详见下面「面板自身」那一段。
# =============================================================

set -uo pipefail

# 颜色
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'
DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=""; GRN=""; YEL=""; CYN=""; DIM=""; RST=""; }

say()  { printf "  ${CYN}[--]${RST} %s\n" "$*"; }
tty_dim() { printf '%s' "$DIM"; }
tty_off() { printf '%s' "$RST"; }
ok()   { printf "  ${GRN}[OK]${RST} %s\n" "$*"; }
warn() { printf "  ${YEL}[!]${RST} %s\n" "$*"; }
err()  { printf "  ${RED}[X]${RST} %s\n" "$*"; }
die()  { err "$*"; exit 1; }

REPO_RAW_DEFAULT="${XRAY_RAW:-https://raw.githubusercontent.com/mi1314cat/xray--core/main}"
SRV_ROOT="${XRAY_BASE:-/root/catmi/xray}"
CLI_PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"

# 整条镜像链的总时限(秒)。到点就放弃去本地 —— "停在那边"比"慢一点"糟得多。
FETCH_BUDGET="${XRAY_FETCH_BUDGET:-75}"
FORCE_REMOTE=0

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 本地副本
# 从仓库检出跑 (bash install.sh) 时, 脚本旁边就是全套 —— 这种情况下根本
# 不该联网。生产上装好的那份在 /root/xray-panel.sh 与 $SRV_ROOT 下。
# 存成**变量**而不是函数 —— 函数名当变量引用, 在 set -u 下是 unbound variable。
# 从仓库检出跑时它就是仓库根, 于是 xray-panel.sh / conf/ 全都在本地。
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" \
    || _SELF_DIR="$(dirname "${BASH_SOURCE[0]:-$0}")"

# 本地副本在哪: 越靠前越权威。
# 生产上装好的面板落在 **/root/xray-panel.sh** —— 那是 SRV_ROOT (/root/catmi/xray)
# 的**祖父**目录, 只取一层 dirname 会落到 /root/catmi, 找不到它 (第一版就错在这)。
_local_roots() {
    local p1 p2 r seen=" "
    p1=$(dirname "$SRV_ROOT"); p2=$(dirname "$p1")
    for r in "$_SELF_DIR" "$SRV_ROOT" "$p1" "$p2" /root "$CLI_PREFIX"; do
        [[ -n "$r" && "$r" == "/" ]] && continue
        # 去重: 默认布局下这��目录会重合
        [[ "$seen" == *" $r "* ]] && continue
        seen="$seen$r "
        printf '%s\n' "$r"
    done
}

# <仓库相对路径> -> 打印本地绝对路径; 没有就返回 1
_local_find() {
    local rel="$1" r
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        [[ -s "$r/$rel" ]] && { printf '%s' "$r/$rel"; return 0; }
    done < <(_local_roots)
    return 1
}

# 下回来的东西是不是真脚本。GitHub 的 404 / 反代拦截页都是 HTML,
# 存成 .sh 之后报的是 "syntax error near unexpected token", 看着像代码坏了。
_looks_like_script() {
    local f="$1" h
    [[ -s "$f" ]] || return 1
    h=$(head -c 200 "$f" 2>/dev/null)
    # 网页 / 404 / 反代拦截页。
    # ★ GitHub 的 404 返回的是纯文本 "404: Not Found" **不是 HTML** (实测),
    #   只挡 HTML 挡不住它 —— 存下一个 11 字节的 .sh, 后面报语法错误,
    #   跟网络八竿子打不着, 极难查。
    printf '%s' "$h" | grep -qiE '^[[:space:]]*(<!doctype|<html)' && return 1
    printf '%s' "$h" | grep -qiE '^[[:space:]]*(404:|403:|502:|error:|proxy error)' && return 1
    # 整个文件没有换行 —— 正常脚本不可能
    [[ "$(wc -l < "$f" 2>/dev/null)" -eq 0 ]] && return 1
    return 0
}

# ---------------------------------------------------------------- 取文件
_fetch() { # <仓库相对路径> <本地路径> [总时限秒]
    local rel="$1" dest="$2" budget="${3:-$FETCH_BUDGET}" base i start now left
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    start=$(date +%s)
    for base in "$REPO_RAW_DEFAULT" \
                "https://ghproxy.net/$REPO_RAW_DEFAULT" \
                "https://gh-proxy.com/$REPO_RAW_DEFAULT" \
                "https://cdn.jsdelivr.net/gh/mi1314cat/xray--core@main" ; do
        # 整条链的总时限。到点立刻收手, 不再往下试。
        now=$(date +%s); left=$((budget - (now - start)))
        (( left <= 0 )) && break
        # 主站值得多试一次 (12 秒会把"首包慢但其实能通"的镜像误判成不通);
        # 镜像只试一次, 而且越靠后给的时间越短。
        local tries=1 to=12
        [[ "$base" == "$REPO_RAW_DEFAULT" ]] && tries=2
        (( $(echo "$base" | grep -c 'ghproxy\|gh-proxy\|jsdelivr') )) && to=8
        (( left < to )) && to=$left
        for (( i = 0; i < tries; i++ )); do
            if curl -fsSL --max-time "$to" "$base/$rel" -o "$dest.tmp" 2>/dev/null \
               && _looks_like_script "$dest.tmp"; then
                mv -f "$dest.tmp" "$dest"
                [[ "$base" == "$REPO_RAW_DEFAULT" ]] \
                    || say "主站不通, 用了镜像 $(printf '%s' "$base" | cut -d/ -f3)"
                return 0
            fi
        done
    done
    rm -f "$dest.tmp"
    return 1
}

# 取一份来用: 本地优先 → 远端 → 再退回本地。**任何情况下都不静默卡住。**
_get() { # <仓库相对路径> <目标路径>
    local rel="$1" dest="$2" src
    if [[ "$FORCE_REMOTE" == "0" ]] && src=$(_local_find "$rel"); then
        cp -f "$src" "$dest" 2>/dev/null && return 0
    fi
    if _fetch "$rel" "$dest"; then
        return 0
    fi
    # 远端没成 —— 回本地, 并明说这次没更新上
    if src=$(_local_find "$rel"); then
        cp -f "$src" "$dest" 2>/dev/null && {
            warn "远端取不到, 改用本机已有的那份: $src"
            return 0
        }
    fi
    return 1
}

# ---------------------------------------------------------------- 状态
srv_installed() { [[ -d "$SRV_ROOT" && -f "$SRV_ROOT/config.json" ]]; }
cli_installed() { [[ -d "$CLI_PREFIX" ]]; }
srv_service()   { systemctl is-active xrayls 2>/dev/null || echo "inactive"; }

# ★ 远端版本**只在用户显式要看时**去问。
#   原来它在主菜单每一轮重画都跑一遍 —— 那就是 4×2×25 秒的挂起,
#   用户表现为"菜单打出来就卡住, 什么都点不动"。菜单必须能离线用。
_remote_version() {
    local f; f=$(mktemp) || return 1
    _fetch "Client/VERSION" "$f" >/dev/null 2>&1 || { rm -f "$f"; return 1; }
    head -1 "$f" 2>/dev/null | tr -d '[:space:]'
    rm -f "$f"
}

check_update() {
    local rv
    printf '\n'
    if rv=$(_remote_version) && [[ -n "$rv" ]]; then
        ok "远端版本: $rv"
    else
        warn "查不到远端版本 (镜像链不通或超时) —— 本机已有的功能不受影响"
    fi
}

show_status() {
    printf '\n%s\n' "════ 当前状态 ════"
    if srv_installed; then
        ok "服务端已安装: $SRV_ROOT (xrayls: $(srv_service))"
    else
        say "服务端未安装"
    fi
    if cli_installed; then
        ok "客户端已安装: $CLI_PREFIX"
        [[ -x "$CLI_PREFIX/l.sh" ]] && say "  入口: $CLI_PREFIX/l.sh"
    else
        say "客户端未安装"
    fi
}

# =============================================================
# 面板自身: 进入前自动比对 + 备份 + 回退
#
# ★ 为什么必须有 (线上真实故障, 2026-10-15):
#
#   用户的机器上躺着一份 10-10 的 `/root/xray-panel.sh`, 而这次进来时面板
#   **没有自动更新** —— 因为原来 run_server 走的是 `_get`, 而 `_get` 的
#   第一条规矩是"本地优先": 它会先在 _local_roots (/root 就在里面) 里找到
#   那份旧面板, 复制过来就用, **一次网络都不发**。
#   于是:
#       · 面板永远是第一次装的那份, 后面推的功能一个都收不到;
#       · 旧面板里有个已经修掉的 bug (`f=$(xray_fetch ...)` 是子 shell,
#         `_XRAY_CACHE` 出了子 shell 就没了 → `$CACHE/lib/` 从来没铺过),
#         表现为一进子菜单就
#             [X] 取不到 /tmp/.xray-panel.XXXXXX/lib/print.sh —— 提示函数不可用
#         而用户看到的现象是"面板坏了, 但明明 GitHub 上是好的"。
#   更糟的是: 取下来的面板落在 `$TMP/xray-panel.sh`, 退出即删 ——
#   **什么都不会留下**, 所以下次进来还是那份旧的。手动 `server update`
#   只有那一次有效。
#
#   SB 在同一位置的做法是 auto_update: 进门先 fetch_soft → 有新版就换,
#   换之前 backup_scripts, 换完 scripts_sane 不过就 restore_scripts 回滚,
#   而且**任何一步失败都不许把人挡在面板外面**。这里照它的形状来, 只把
#   "git repo" 换成"托管副本 + 按内容比对"(X 不依赖 git)。
#
# ★ 与"本地优先"的关系:
#   本地优先的初衷是「GitHub 连不上时也能进面板」—— 那条继续成立, 只是
#   从"优先用本地"改成"先用本地兜底, 但照样花几秒问一次远端":
#       远端有新版 → 换新的 (备份旧的)
#       远端没响应 → 用本地这份, 明说"这次没更新上"
#   两边都不牺牲。
# =============================================================

PANEL_DIR="$SRV_ROOT/.panel"
PANEL_MANAGED="$PANEL_DIR/xray-panel.sh"
PANEL_PREV="$PANEL_DIR/prev"
# 进门那次检查的时限。**不能**用 FETCH_BUDGET (75 秒) —— 那是个安装预算,
# 而这里是"进面板前顺手看一眼", 让人对着黑屏等一分多钟是不能接受的。
PANEL_BUDGET="${XRAY_UPDATE_BUDGET:-20}"
PANEL_KEEP_PREV=5

panel_hash() { # 文件身份 (前 12 位)。比"版本号"可靠: 忘了改版本号也认得出来。
    local h
    h=$(md5sum "$1" 2>/dev/null | cut -d' ' -f1)
    [[ -n "$h" ]] || h=$(cksum "$1" 2>/dev/null | cut -d' ' -f1)
    printf '%s' "${h:0:12}"
}

panel_sane() { # 语法不过的面板会直接起不来 —— 而用户此刻正要进面板
    [[ -s "$1" ]] || return 1
    bash -n "$1" 2>/dev/null || return 1
    return 0
}

# 某个目录下的版本号 (取不到就打空 —— **不要**去别处兜底, 见 panel_label_of)
panel_ver_dir() {
    local f="$1/VERSION"
    [[ -s "$f" ]] || return 0
    head -1 "$f" 2>/dev/null | tr -d '[:space:]'
}

# ★ 这里以前会"到处找 VERSION": 先看托管目录, 再看脚本自己所在目录。
#   后果是**报出来的版本和实际跑的版本不是一回事** —— 实测: 从仓库检出跑
#   `install.sh panel-update`, 远端还是旧面板 (仓库刚加的 VERSION 还没推上去),
#   它却打了 "已更新面板脚本 → v3.0.0", 因为它在**本地仓库目录**里找到了
#   VERSION。给人看的版本号报错, 比不报更糟。
#   现在只有一个来源: **托管副本旁边那份 VERSION** (更新成功才会写)。
#   没有就报内容身份 (md5 前 12 位) —— 不好看, 但它一定是对的。
panel_ver() {
    local v; v=$(panel_ver_dir "$PANEL_DIR")
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    [[ -s "$PANEL_MANAGED" ]] && { printf '身份 %s' "$(panel_hash "$PANEL_MANAGED")"; return 0; }
    return 0
}

# 某一份面板文件"是什么版本" —— 只认它**自己旁边**的 VERSION, 不跨目录借
panel_label_of() {
    local v; v=$(panel_ver_dir "$(dirname "$1")")
    [[ -n "$v" ]] && { printf 'v%s' "$v"; return 0; }
    printf '身份 %s' "$(panel_hash "$1")"
}

# 备份当前托管副本, 供回退。打印备份路径; 建不出来就打印空。
panel_backup() {
    [[ -s "$PANEL_MANAGED" ]] || { printf ''; return 1; }
    mkdir -p "$PANEL_PREV" 2>/dev/null || { printf ''; return 1; }
    local b="$PANEL_PREV/xray-panel.sh.$(date +%Y%m%d-%H%M%S)"
    cp -f "$PANEL_MANAGED" "$b" 2>/dev/null || { printf ''; return 1; }
    # 只留最近 N 份 —— 面板自己才 30KB, 但没上限的目录终会变成垃圾场
    ls -1t "$PANEL_PREV"/xray-panel.sh.* 2>/dev/null \
        | tail -n +$((PANEL_KEEP_PREV + 1)) | while IFS= read -r old; do
            rm -f "$old" 2>/dev/null
        done
    printf '%s' "$b"
}

# 自动比对并更新。返回 0=已更新  10=已是最新  2=取不到(网络/仓库)  3=没通过检查
# ★ **任何情况下都不 die** —— 更新失败只是"这次没更新成", 用本地版本继续才对。
panel_autoupdate() {
    local tmp="$TMP/panel.new" msg
    _fetch "VERSION" "$TMP/VERSION" "$PANEL_BUDGET" >/dev/null 2>&1 || true
    if ! _fetch "xray-panel.sh" "$tmp" "$PANEL_BUDGET"; then
        return 2
    fi
    _looks_like_script "$tmp" || return 2
    if ! panel_sane "$tmp"; then
        warn "新版面板没通过语法检查 (bash -n) —— 保留本机这份, 没有覆盖"
        return 3
    fi
    if [[ -s "$PANEL_MANAGED" ]] && cmp -s "$PANEL_MANAGED" "$tmp"; then
        return 10
    fi

    local bak=""
    if [[ -s "$PANEL_MANAGED" ]]; then
        bak=$(panel_backup)
        [[ -n "$bak" ]] || warn "备份失败 —— 仍要更新 (出问题就没法自动回退了)"
    fi
    mkdir -p "$PANEL_DIR" 2>/dev/null
    if ! cp -f "$tmp" "$PANEL_MANAGED" 2>/dev/null; then
        warn "新版面板落地失败, 继续用本机这份"
        return 3
    fi
    chmod +x "$PANEL_MANAGED" 2>/dev/null
    # 版本号是给人看的, 落了才有得看; 取不到不影响更新本身。
    # ★ 取不到时必须**把旧的删掉** —— 否则下一次会拿上一版的版本号来报当前
    #   这一份, 屏幕上就成了"版本没变, 其实内容变了"。
    if [[ -s "$TMP/VERSION" ]]; then
        cp -f "$TMP/VERSION" "$PANEL_DIR/VERSION" 2>/dev/null
    else
        rm -f "$PANEL_DIR/VERSION" 2>/dev/null
    fi
    if ! panel_sane "$PANEL_MANAGED"; then
        warn "落地后的面板没通过语法检查, 已回滚"
        [[ -n "$bak" ]] && cp -f "$bak" "$PANEL_MANAGED" 2>/dev/null \
            && ok "已回滚到更新前的版本"
        return 3
    fi
    # ★ 顺手把 install.sh 也存一份到托管目录。
    #   面板里的「回退到上一版」走的就是 install.sh —— 如果每次都现从 GitHub
    #   取, 那么"新版面板有问题想退回去"的时刻恰好也常常是"网络/仓库不太顺"
    #   的时刻, 最需要回退的人反而用不了回退。存一份本地的最稳。
    #   取不到不算失败 (面板本身已经更新好了), 只是回退要多走一次网络。
    _fetch "install.sh" "$PANEL_DIR/install.sh.new" "$PANEL_BUDGET" >/dev/null 2>&1 \
      && bash -n "$PANEL_DIR/install.sh.new" 2>/dev/null \
      && mv -f "$PANEL_DIR/install.sh.new" "$PANEL_DIR/install.sh" 2>/dev/null
    rm -f "$PANEL_DIR/install.sh.new" 2>/dev/null

    msg="已更新面板脚本 → $(panel_label_of "$PANEL_MANAGED")"
    [[ -n "$bak" ]] && msg="$msg   ${DIM}(旧版备份: $bak)${RST}"
    ok "$msg"
    return 0
}

# 非托管的历史副本 —— 用户手工 curl 到 /root 的那种。
# ★ 它的危害不是"占地方", 是**会被 _local_find 找到并当成正式版本跑**。
#   一旦托管副本存在, 它就该退休了; 这里只提醒, 不擅自删用户的东西。
panel_warn_stray() {
    local r f
    [[ -s "$PANEL_MANAGED" ]] || return 0
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        f="$r/xray-panel.sh"
        [[ -s "$f" ]] || continue
        [[ "$f" == "$PANEL_MANAGED" ]] && continue
        # 从仓库检出跑的目录不算"历史副本" —— 那是你自己在跑的那份代码
        [[ "$(cd "$(dirname "$f")" 2>/dev/null && pwd)" == "$_SELF_DIR" ]] && continue
        # 与托管副本同内容的不算
        cmp -s "$f" "$PANEL_MANAGED" 2>/dev/null && continue
        warn "发现一份旧的手工副本: $f (不会再用它; 可自行删除)"
    done < <(_local_roots)
}

run_panel_update() {   # 手动: 强制取远端最新版
    local rc=0
    say "正在取远端最新版面板..."
    panel_autoupdate || rc=$?
    case $rc in
        0)  ;;
        10) ok "已是最新版本 ($(panel_ver))" ;;
        2)  warn "暂时连不上 GitHub —— 保留本机这份 (不影响使用)" ;;
        *)  warn "这次没更新成, 保留本机这份" ;;
    esac
    return 0
}

run_panel_rollback() {
    local list=() b
    while IFS= read -r b; do [[ -n "$b" ]] && list+=("$b"); done \
        < <(ls -1t "$PANEL_PREV"/xray-panel.sh.* 2>/dev/null)
    if (( ${#list[@]} == 0 )); then
        warn "没有可回退的备份 (还没更新过, 或备份被清理了)"
        say "备份目录: $PANEL_PREV"
        return 0
    fi
    printf '\n  可回退的版本 (新 → 旧):\n'
    local i
    for (( i = 0; i < ${#list[@]}; i++ )); do
        printf '    %d) %s  %s(%s 行 · %s)%s\n' \
            "$((i + 1))" "$(basename "${list[$i]}")" "$DIM" \
            "$(wc -l < "${list[$i]}" 2>/dev/null | tr -d ' ')" \
            "$(panel_hash "${list[$i]}")" "$RST"
    done
    printf '    0) 取消\n  选择: '
    local c; read -r c || return 0
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#list[@]} )) || { say "已取消"; return 0; }
    b="${list[$((c - 1))]}"
    panel_sane "$b" || { err "这份备份语法就不对, 不能回退到它"; return 1; }
    local cur=""
    [[ -s "$PANEL_MANAGED" ]] && cur=$(panel_backup)
    cp -f "$b" "$PANEL_MANAGED" 2>/dev/null || { err "回退写入失败"; return 1; }
    chmod +x "$PANEL_MANAGED" 2>/dev/null
    ok "已回退到 $(basename "$b")"
    [[ -n "$cur" ]] && say "回退前的版本也备份了: $cur"
    say "**重新进入面板后生效** (当前这份还在内存里跑)"
}

show_panel_status() {
    printf '\n%s\n' "════ 面板自身 ════"
    say "托管副本: ${PANEL_MANAGED:-未设置}"
    if [[ -s "$PANEL_MANAGED" ]]; then
        ok "当前版本: $(panel_ver)  ($(wc -l < "$PANEL_MANAGED" | tr -d ' ') 行 · $(panel_hash "$PANEL_MANAGED"))"
    else
        warn "本机还没有托管副本 (第一次进来会自动建)"
    fi
    local n; n=$(ls -1 "$PANEL_PREV"/xray-panel.sh.* 2>/dev/null | grep -c .)
    say "可回退备份: ${n:-0} 份  ($PANEL_PREV)"
    [[ -s "$PANEL_DIR/VERSION" ]] && say "版本文件: $(head -1 "$PANEL_DIR/VERSION")"
}

# ---------------------------------------------------------------- 服务端
run_server() {
    if srv_installed; then
        say "已安装: $SRV_ROOT (xrayls: $(srv_service))"
    else
        say "服务端未安装 —— 进入面板后选第 1 项「安装/更新 xray」"
    fi

    TMP="${TMP:-$(mktemp -d)}"
    local rc=0
    # ★ 进门先看一眼远端 —— 但**绝不为它停下**。
    # ★ 每次进门都查 —— **不要**加"是不是终端"这类条件。
    #   第一版加过, 结果是"交互式进来会更新、管道/脚本进来永远不更新",
    #   同一台机器两种行为。而进门检查的全部代价就是一个有时限的网络请求
    #   (PANEL_BUDGET, 默认 20 秒), 失败了也照常进面板。
    if [[ "${XRAY_NO_UPDATE:-0}" == "1" || "${XRAY_UPDATE_BUDGET:-20}" == "0" ]]; then
        say "已跳过更新检查 (XRAY_NO_UPDATE=1 / 时限为 0)"
    else
        printf '  %s[--]%s 检查面板更新...' "$CYN" "$RST"
        panel_autoupdate || rc=$?
        printf '\r                                          \r'
        case $rc in
            0)  ;;
            10) ok "面板已是最新 ($(panel_ver))" ;;
            2)  warn "连不上 GitHub —— 用本机这份继续 (没更新成, 不影响使用)" ;;
            *)  warn "更新检查没过, 用本机这份继续" ;;
        esac
    fi

    # 用**托管副本** —— 它是"最后一次成功取到的最新版", 而不是某个
    # 躺在 /root 下的历史遗留。托管副本没有才退回去找任意本地副本。
    local p=""
    if [[ -s "$PANEL_MANAGED" ]] && panel_sane "$PANEL_MANAGED"; then
        p="$PANEL_MANAGED"
    else
        if [[ -s "$PANEL_MANAGED" ]]; then
            warn "托管副本语法有问题, 不用它"
        fi
        p=$(_local_find "xray-panel.sh") || p=""
        [[ -n "$p" ]] && warn "改用找到的本地副本: $p (它可能不是最新版)"
    fi
    if [[ -z "$p" ]]; then
        p="$TMP/xray-panel.sh"
        _get "xray-panel.sh" "$p" \
            || die "本机没有面板、远端也取不到 (镜像链全不通?)。网络恢复后重跑, 或手动放置 xray-panel.sh"
    else
        panel_warn_stray
    fi
    exec bash "$p"
}

# ---------------------------------------------------------------- 客户端
#
# ★ 已经装过的机器上, `client` **直接进面板**, 不再重装。
#
#   原来的行为是"每次进来都跑一遍安装器": 用户想看一眼客户端, 却看到
#   "检测到已安装 → 将执行更新 → 下载发布包 → 校验 → 安装" 一整套 ——
#   既慢又吓人（看起来像要覆盖掉他的配置）。M / SB 那边进来就是面板,
#   这里对齐。
#
#   要更新得**明说**: `install.sh client update`（或 --update / -u）。
#   面板里也有「更新脚本」入口。
run_client() {
    local force=0 a
    for a in "$@"; do
        case "$a" in update|--update|-u|upgrade) force=1 ;; esac
    done
    [[ "$force" == "1" ]] && { FORCE_REMOTE=1; say "按要求取远端最新版（不进入面板）"; }

    if [[ "$force" == "0" ]] && cli_installed && [[ -x "$CLI_PREFIX/bin/xbd" ]]; then
        # 已经是客户端了 —— 直接进面板
        exec "$CLI_PREFIX/bin/xbd" menu
    fi
    if [[ "$force" == "0" ]] && cli_installed; then
        say "检测到客户端目录 $CLI_PREFIX, 但没有可用的 xbd —— 走安装器修复"
    fi
    # 面板不认 update 这个参数, 传下去会被 l.sh 当成未知参数
    local pass=()
    for a in "$@"; do
        case "$a" in update|--update|-u|upgrade) ;; *) pass+=("$a") ;; esac
    done
    TMP="${TMP:-$(mktemp -d)}"
    local l="$TMP/l.sh"
    _get "Client/l.sh" "$l" \
        || die "本机没有客户端安装器、远端也取不到 (镜像链全不通?)"
    exec bash "$l" ${pass[@]+"${pass[@]}"}
}

# ---------------------------------------------------------------- 更新
#
# 「更新」= 走安装器把脚本与内核同步到最新（等价于在客户端面板里选更新）。
# 单独拎出来是因为它和"进入面板"现在是两件事: 进面板不联网, 更新才下载。
run_update() {
    printf '\n  更新哪一个?\n'
    printf '    1) 服务端 (xray-panel.sh + conf/ + 内核不动)\n'
    printf '    2) 客户端 (xbd 全套 + 面板 + Web UI)\n'
    printf '    0) 返回\n'
    printf '  选择: '
    local c; read -r c || return 0
    case "$c" in
        1) FORCE_REMOTE=1; run_server ;;
        2) run_client update ;;
        0|"") return 0 ;;
        *) warn "无效选择" ;;
    esac
}

# ---------------------------------------------------------------- 卸载
run_uninstall() {
    printf '\n  卸载哪一个?\n'
    printf '    1) 服务端面板 (停 xrayls, 配置目录保留)\n'
    printf '    2) 客户端\n'
    printf '    0) 返回\n'
    printf '  选择: '
    local c; read -r c || return 0
    case "$c" in
        1)
            printf '  确认卸载服务端? 输入 yes: '
            local a; read -r a || true
            [[ "$a" == "yes" ]] || { say "已取消"; return 0; }
            TMP="${TMP:-$(mktemp -d)}"
            local u="$TMP/uninstall_xray.sh"
            _get "uninstall_xray.sh" "$u" \
                || die "本机没有卸载脚本、远端也取不到 (镜像链全不通?)"
            bash "$u"
            ;;
        2)
            if [[ -x "$CLI_PREFIX/uninstall-xray-client.sh" ]]; then
                bash "$CLI_PREFIX/uninstall-xray-client.sh"
            else
                TMP="${TMP:-$(mktemp -d)}"
                local u="$TMP/uninstall-client.sh"
                _get "Client/uninstall-xray-client.sh" "$u" \
                    || die "本机没有客户端卸载脚本、远端也取不到 (镜像链全不通?)"
                bash "$u"
            fi
            ;;
        0|"") return 0 ;;
        *) warn "无效选择" ;;
    esac
}

# ---------------------------------------------------------------- 菜单
banner() {
    cat <<'EOF'

                       |\__/,|   (\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.xray-core
       -----------------------------------------

EOF
}

main_menu() {
    while :; do
        banner
        show_status
        # 菜单本身先说清"进去是面板还是安装" —— 这一行差别就是用户
        # 上一次的困惑:"我明明装过了, 为什么又装一遍"。
        if srv_installed; then
            printf '\n  1) 服务端面板   %s(已安装 · 直接进入 · 不联网)%s\n' "$(tty_dim)" "$(tty_off)"
        else
            printf '\n  1) 服务端面板   %s(安装 + 进面板)%s\n' "$(tty_dim)" "$(tty_off)"
        fi
        if cli_installed; then
            printf '  2) 客户端面板   %s(已安装 · 直接进入)%s\n' "$(tty_dim)" "$(tty_off)"
        else
            printf '  2) 客户端       %s(装内核 + 面板 + Web UI)%s\n' "$(tty_dim)" "$(tty_off)"
        fi
        printf '  3) 更新到最新版本\n'
        printf '  4) 检查是否有新版本\n'
        printf '  5) 卸载\n'
        printf '  0) 退出\n'
        printf '  选择: '
        local c; read -r c || return 0
        case "$c" in
            1) run_server ;;
            2) run_client ;;
            3) run_update ;;
            4) check_update ;;
            5) run_uninstall ;;
            0|"") return 0 ;;
            *) warn "无效选择" ;;
        esac
        printf '\n  回车继续...'
        read -r _ || return 0
    done
}

# ---------------------------------------------------------------- 入口
case "${1:-}" in
    server)
        shift || true
        for a in "$@"; do
            case "$a" in update|--update|-u|upgrade) FORCE_REMOTE=1; XRAY_FORCE_UPDATE=1 ;; esac
        done
        run_server ;;
    update-panel|panel-update)
        # 面板里「更新面板脚本」也走这一条 —— 面板自己不能给自己做手术,
        # 落地/备份/语法检查/回滚只有一份实现, 就在这个脚本里。
        TMP="${TMP:-$(mktemp -d)}"
        run_panel_update ;;
    panel-rollback|rollback-panel)
        TMP="${TMP:-$(mktemp -d)}"
        run_panel_rollback ;;
    panel-status|--panel-status)
        show_panel_status ;;
    client)          shift; run_client "$@" ;;
    uninstall)       run_uninstall ;;
    --status|status) show_status; check_update ;;
    --check-update)  check_update ;;
    -h|--help)
        sed -n '2,21p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
        ;;
    "")              main_menu ;;
    *)               die "未知参数: $1 (可用: server | client | uninstall | update-panel | panel-rollback | panel-status | --status | --check-update)" ;;
esac