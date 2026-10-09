#!/usr/bin/env bash
# =============================================================
# 取仓库文件 —— 镜像链 + 重试 + 代理回退
#
# ★ 为什么需要它:
#
#   面板 19/20 项都是 `bash <(curl -Ls https://github.com/…/raw/refs/heads/main/…)`
#   跑的。国内机器连 github.com 经常是**连接超时**而不是拒绝, 单个源不通就
#   整个菜单项卡死。而且实测: push 之后约 5 分钟内 raw 仍返回**旧内容**
#   (GitHub CDN 缓存), 于是"改了不生效"又添一层。
#
# ★ 镜像顺序的讲究 (照抄 M 的实战结论, 见 mihomo--core/install.sh):
#
#   · ghproxy / gh-proxy 是**实时回源**的, 能立刻拿到刚推上去的版本 → 排前
#   · jsdelivr 是 CDN **带缓存**的 —— 实测推完 commit 后它仍返回旧文件,
#     加时间戳也绕不过去 → 只能放最后兜底
#   · cfgithub 在部分机器上直接超时 → 排中间
#
# ★ 探测参数也是踩出来的: **25 秒且试两次**。
#   原注释: "12 秒的探测窗口会把本来能用的镜像也判成'不通', 结果整条链全废、
#   安装直接卡死。而 cdn.jsdelivr.net / ghproxy.net 实际都能通, 只是首包慢。"
#
# 用法:
#   source conf/lib/fetch.sh
#   x_fetch conf/share.sh /tmp/share.sh        # 取单个文件
#   x_pick_source                              # 只探测可用源 (结果在 X_SRC)
# =============================================================

X_REPO_RAW="${X_REPO_RAW:-https://raw.githubusercontent.com/mi1314cat/xray--core/main}"
X_REPO_MIRRORS=(
    "https://ghproxy.net/https://raw.githubusercontent.com/mi1314cat/xray--core/main"
    "https://gh-proxy.com/https://raw.githubusercontent.com/mi1314cat/xray--core/main"
    "${X_REPO_PROXY:-https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/xray--core/raw/refs/heads/main}"
    "https://cdn.jsdelivr.net/gh/mi1314cat/xray--core@main"
    "https://fastly.jsdelivr.net/gh/mi1314cat/xray--core@main"
)

# 探测用的文件: 稳定、一定存在 (与 M 一致用 README.md)。
# ⚠ 别拿一个看起来该有的路径当探测目标 —— 首次写的是 src/VERSION,
#   而 X 仓库里**没有这个文件**, 于是每个源都探不通, 整条链直接全废。
#   探测目标必须是**确认存在**的文件。
X_PROBE_FILE="${X_PROBE_FILE:-README.md}"

_X_SRC=""
_X_PROXY=""

# 本机可用代理 —— 第二轮才用。找得到就用, 找不到就直连。
_x_find_proxy() {
    local p
    if [[ -n "${https_proxy:-}${http_proxy:-}" ]]; then
        _X_PROXY="${https_proxy:-$http_proxy}"; return 0
    fi
    for p in 7890 7891 10808 10809 2080 20171; do
        if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" 2>/dev/null; then
            _X_PROXY="http://127.0.0.1:$p"; return 0
        fi
    done
    return 1
}

_x_cargs() { [[ -n "$_X_PROXY" ]] && printf '%s' "--proxy $_X_PROXY"; }

# 选一个可用源, 结果放进 X_SRC。找不到返回 1。
x_pick_source() {
    local base i
    [[ -n "$_X_SRC" ]] && { printf '%s' "$_X_SRC"; return 0; }

    for base in "$X_REPO_RAW" "${X_REPO_MIRRORS[@]}"; do
        for i in 1 2; do
            # 25 秒不是随手写的: 12 秒会把"首包慢但其实能通"的镜像判死
            if curl -fsSL --max-time 25 $(_x_cargs) "$base/$X_PROBE_FILE" -o /dev/null 2>/dev/null; then
                _X_SRC="$base"; printf '%s' "$_X_SRC"; return 0
            fi
        done
    done

    # 第二轮: 带本机代理把整条链再走一遍
    if _x_find_proxy; then
        for base in "$X_REPO_RAW" "${X_REPO_MIRRORS[@]}"; do
            if curl -fsSL --max-time 25 $(_x_cargs) "$base/$X_PROBE_FILE" -o /dev/null 2>/dev/null; then
                _X_SRC="$base"; printf '%s' "$_X_SRC"; return 0
            fi
        done
    fi
    return 1
}

# x_fetch <仓库相对路径> <本地路径>
# 成功 0; 失败 1 (调用方自己决定是报错还是降级)。
x_fetch() {
    local rel="$1" dest="$2" base
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    base=$(x_pick_source) || return 1
    if curl -fsSL --max-time 30 $(_x_cargs) "$base/$rel" -o "$dest.tmp" 2>/dev/null; then
        mv -f "$dest.tmp" "$dest"; return 0
    fi
    rm -f "$dest.tmp"
    # 选中的源这次抽风 —— 换一个再试一次, 别让整条链白探
    local alt
    for alt in "$X_REPO_RAW" "${X_REPO_MIRRORS[@]}"; do
        [[ "$alt" == "$base" ]] && continue
        if curl -fsSL --max-time 30 $(_x_cargs) "$alt/$rel" -o "$dest.tmp" 2>/dev/null; then
            mv -f "$dest.tmp" "$dest"; _X_SRC="$alt"; return 0
        fi
        rm -f "$dest.tmp"
    done
    return 1
}

# 把一组文件拉到同一个目录下 (保持相对结构)。
#   x_fetch_into <目标目录> <相对路径>...
x_fetch_into() {
    local dest="$1"; shift
    local rel ok=0
    for rel in "$@"; do
        if x_fetch "$rel" "$dest/${rel##*/}"; then ok=$((ok+1)); else
            printf '  [!] 取不到 %s\n' "$rel" >&2
        fi
    done
    (( ok > 0 ))
}

# 源的名字 (给提示用)。**必须传参** —— 不能读全局 $_X_SRC:
# `s=$(x_pick_source)` 是命令替换, 探测跑在子 shell 里, 全局赋值传不回父 shell
# (这个坑在本项目其它地方也踩过两次)。要名字就把 URL 一起带出来。
x_source_name() {
    local s="${1:-}"
    [[ -n "$s" ]] || { printf '未探测'; return; }
    [[ "$s" == "$X_REPO_RAW" ]] && { printf '主站'; return; }
    printf '%s' "$s" | cut -d/ -f3
}

# ---------------------------------------------------------------- 直跑
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-pick}" in
        pick)   s=$(x_pick_source) && echo "可用源: $(x_source_name "$s")
  $s" || { echo "整条链都不通 (含代理回退)"; exit 1; } ;;
        get)    [[ -n "${2:-}" && -n "${3:-}" ]] || { echo "用法: fetch.sh get <相对路径> <本地路径>" >&2; exit 1; }
                x_fetch "$2" "$3" && echo "已取: $3 ($(wc -c < "$3") 字节)" ;;
        list)   printf '  %s\n' "$X_REPO_RAW" "${X_REPO_MIRRORS[@]}" ;;
        *) echo "用法: fetch.sh [pick|get <相对> <本地>|list]" >&2; exit 1 ;;
    esac
fi
