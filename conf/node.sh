#!/usr/bin/env bash
# 节点管理 —— 列出 / 查看 / 改名 / 删除
#
# 删除的顺序是这个脚本存在的理由:
#
#     1. 删掉 conf/ 片段
#     2. 校验整份配置, 重载 xray
#     3. 重载成功后, 才吊销关联的分享令牌
#     4. 重载失败 → 回滚片段, 分享令牌原样不动
#
# 反过来做 (先吊销再校验) 是 SB/M 都踩过的坑: 配置校验失败会回滚, 节点其实
# 还在跑, 但分享令牌已经全被吊销, 用户手上的链接无声失效。回滚只恢复
# 配置, 不恢复令牌 —— 因为没有记录谁被吊销过。

set -uo pipefail

XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}"
CONF_DIR="${XRAY_CONF_DIR:-$XRAY_BASE/conf}"
SHARE_DIR="${XRAY_SHARE_DIR:-$XRAY_BASE/out/share}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib"
XRAY_SERVICE="${XRAY_SERVICE:-xrayls}"
MAIN_CONFIG="${XRAY_MAIN_CONFIG:-$XRAY_BASE/config.json}"

# 提示函数（ok/info/warn/err/die）—— 与 share.sh / share_service.sh 共用一份。
# 这里的 LIB_DIR 就是脚本旁边的 lib/；只要 node.sh 找得到 nodes.py，它就成立。
if [[ -r "$LIB_DIR/print.sh" ]]; then
    source "$LIB_DIR/print.sh"
else
    printf '  [X] 取不到 %s/print.sh —— 提示函数不可用\n' "$LIB_DIR" >&2
    exit 1
fi

# 统一交互层 (编号选择 / 确认 / 提问 / 方框排版)。
# 拿不到就退化成只有 ui_* 排版的老样子 —— 交互退化不能让菜单点不动。
if [[ -r "$LIB_DIR/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/ui.sh"
else
    ui_box() { ui_title "$@"; }
    UI_PICK_KEY=""
    ui_pick() {   # 无库时的兜底: 仍然编号化, 只是没有方框
        local title="$1" empty="$2" verb="$3" -a keys=() labels=()
        local k v i idx
        while IFS=$'\t' read -r k v; do
            [[ -n "$k" ]] || continue; keys+=("$k"); labels+=("$v")
        done <<< "${UI_PICK_ROWS:-}"
        if (( ${#keys[@]} == 0 )); then warn "$empty"; return 2; fi
        while :; do
            ui_title "$title"
            for (( i = 0; i < ${#keys[@]}; i++ )); do
                printf '   %2d) %s\n' "$((i+1))" "${labels[$i]}" >&2
            done
            printf '    0) 返回\n\n' >&2
            read -r -p "  $verb [1-${#keys[@]}, 0=取消]: " idx || return 1
            [[ -z "$idx" || "$idx" == "0" ]] && return 1
            [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#keys[@]} )) || { ui_invalid "$idx"; continue; }
            UI_PICK_KEY="${keys[$((idx-1))]}"; return 0
        done
    }
    ui_ask_num() { local p="$1" lo="$2" hi="$3" a
        while :; do read -r -p "  $p [$lo-$hi, 0=取消]: " a || return 1
            [[ -z "$a" || "$a" == 0 ]] && return 1
            [[ "$a" =~ ^[0-9]+$ ]] && (( a >= lo && a <= hi )) && { printf '%s' "$a"; return 0; }
            ui_invalid "$a"; done; }
    ui_confirm() { local q="$1" a
        read -r -p "  $q 输入 yes 确认: " a || return 1
        [[ "$a" == "yes" || "$a" == "y" || "$a" == "Y" ]]; }
    ui_note() { printf '  %s\n' "$1" >&2; }
    # node_print_table 还要用这两个 —— 漏了会让"库缺失"从交互退化变成菜单直接崩
    ui_rule2() { printf '  %s\n' "------------------------------------------------" >&2; }
    ui_pad_w() { printf '%s' "$1"; }
fi

py() { python3 "$@"; }

# ---------------------------------------------------------------- 辅助
py_lib() { # 把 lib 目录作为参数传给内嵌脚本, 避免 heredoc 猜 sys.path
    py -c "import sys; sys.path.insert(0, '$LIB_DIR'); exec(sys.stdin.read())"
}

# CLI 的 `node.sh list` 保持原样 (裸表, 给脚本/管道用) —— 菜单走
# node_print_table, 两者分工不同, 不要混。
node_list() { py "$LIB_DIR/nodes.py" "$CONF_DIR"; }

# ---------------------------------------------------------------- 节点表
# 一次解析, 供「画表」与「按编号取节点」共用。
#
# ★ 必须**一次** python 扫全部片段 (nodes.py 本来就是这个形状, 保持住):
#   Mihomo 的首屏 node_count() 给每个节点文件各起一个 python 进程,
#   单是 import yaml 就要 60ms, 20 个文件 = 1.3 秒 —— 那正是用户说的"卡"。
#   这里只花一次进程, 之后每层菜单都复用这一份结果。
_NODE_TAGS=(); _NODE_FIELDS=()
_node_cache=""; _node_loaded=0

_node_load() {
    _node_loaded=1
    _NODE_TAGS=(); _NODE_FIELDS=()
    [[ -n "$_node_cache" ]] || _node_cache=$(py "$LIB_DIR/nodes.py" "$CONF_DIR" json 2>/dev/null)
    [[ -n "$_node_cache" ]] || return 0
    local t rest
    while IFS=$'\t' read -r t rest; do
        [[ -n "$t" ]] || continue
        _NODE_TAGS+=("$t"); _NODE_FIELDS+=("$rest")
    done < <(printf '%s' "$_node_cache" | py -c "
import json, sys
try: d = json.load(sys.stdin)
except Exception: d = {}
rows = [(n.get('tag') or '', [n.get('protocol') or '-', n.get('port') or '-',
         n.get('network') or '-', n.get('security') or '-'])
        for n in (d.get('nodes') or []) if n.get('tag')]
rows.sort(key=lambda r: r[0].lower())
for tag, f in rows: print(tag + '\t' + '\t'.join(str(x) for x in f))
" 2>/dev/null)
}

# 节点表失效 (增/删/改名之后) —— 下一次重画时重新解析
node_cache_drop() { _node_cache=""; _node_loaded=0; _node_load; }

node_count() { _node_load; printf '%s' "${#_NODE_TAGS[@]}"; }

# 画编号节点表 —— 走 ui.sh 的统一渲染器。
#
# ★ 列是按"用户要拿它做什么选"选的, 不是把 nodes.py 的字段一股脑倒出来:
#   **凭据那列删掉了** —— 截断的 UUID 对选节点毫无帮助, 却占了最宽的一列,
#   顺带把整张表撑到要换行。凭据属于「查看节点详情」。
node_print_table() {
    _node_load
    if (( ${#_NODE_TAGS[@]} == 0 )); then
        printf '  %s还没有任何节点 —— 先用「添加节点」建一个%s\n' "$_DIM" "$_RST" >&2
        return 1
    fi
    UI_PICK_COLS=(节点名 类型 端口 传输 安全)
    UI_PICK_ROWS=""
    local i
    for (( i = 0; i < ${#_NODE_TAGS[@]}; i++ )); do
        # 行格式 key<TAB>显示列… —— 节点名就是 tag 本身, 所以第一列重复一遍。
        # (证书/站点那些表 key 是完整路径而显示列是 basename, 不重复。)
        UI_PICK_ROWS+="${_NODE_TAGS[$i]}"$'\t'"${_NODE_TAGS[$i]}"$'\t'"${_NODE_FIELDS[$i]}"$'\n'
    done
    ui_table_print "共 ${#_NODE_TAGS[@]} 个节点"
}

# 按编号取节点。编号与上面那张表**是同一套**, 所以不再重画一遍 ——
# 用户看到的编号和输入的编号来自同一次解析, 不可能对不上。
node_pick() { # <动作名>
    _node_load
    local n=${#_NODE_TAGS[@]}
    if (( n == 0 )); then
        warn "还没有任何节点, 先用「添加节点」建一个"
        ui_pause; return 2
    fi
    ui_pick_from_shown "要$1的" "$n" || { UI_PICK_KEY=""; return 1; }
    UI_PICK_KEY="${_NODE_TAGS[$((UI_PICK_IDX-1))]}"
    return 0
}

node_exists() {
    [[ -n "$1" ]] || return 1
    py "$LIB_DIR/nodes.py" "$CONF_DIR" json 2>/dev/null \
        | py -c "import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if any(n.get('tag')==sys.argv[1] for n in d['nodes']) else 1)" "$1"
}

node_file() { # tag → 片段完整路径
    # nodes.py 的 source 字段只存文件名 (用于展示), 这里要拼回完整路径 ——
    # 直接拿 source 当路径用, 相对路径会被当前工作目录解析, 结果是
    # "找不到片段文件", 而文件明明在那儿。
    local src
    src=$(py -c "
import json,sys
d=json.load(sys.stdin)
for n in d['nodes']:
    if n.get('tag')==sys.argv[1]:
        print(n.get('source','')); break
" "$1" < <(py "$LIB_DIR/nodes.py" "$CONF_DIR" json 2>/dev/null))
    [[ -n "$src" ]] || return 1
    printf '%s' "$CONF_DIR/$src"
}

# ---------------------------------------------------------------- 查看
node_show() {
    local tag="$1"
    node_exists "$tag" || { err "没有这个节点: $tag"; return 1; }
    py "$LIB_DIR/nodes.py" "$CONF_DIR" json 2>/dev/null | TAG="$tag" py -c "
import json, os, sys
sys.path.insert(0, os.environ['LIB'] if 'LIB' in os.environ else '.')
d = json.load(sys.stdin)
tag = os.environ['TAG']
n = next(x for x in d['nodes'] if x.get('tag') == tag)
for k in ('tag','protocol','network','security','port','listen','flow','id','password',
          'method','decryption','sni','path','source'):
    v = n.get(k)
    if v not in (None, '', [], {}):
        print(f'  {k:<12} {v}')
if d.get('unreadable'):
    print(f'  ${_YEL}另有 {len(d[\"unreadable\"])} 个片段解析不了${_RST}')
"
}

# ---------------------------------------------------------------- 改名
# 改 tag 要同时动三处: 片段里的 tag、分享元数据的文件名、令牌里的引用。
# 漏掉任何一处, 表现都是"改名后分享链接指向一个不存在的节点"。
node_rename() {
    local tag="$1" new="$2"
    node_exists "$tag" || { err "没有这个节点: $tag"; return 1; }
    [[ -n "$new" ]] || die "新名字不能为空"
    # tag 会变成 sidecar 文件名和 URL 片段, 限制字符集
    [[ "$new" =~ ^[A-Za-z0-9._-]+$ ]] || die "新名字只能用字母数字 . _ -"
    node_exists "$new" && die "已经有一个叫 $new 的节点"

    local f; f=$(node_file "$tag")
    [[ -f "$f" ]] || die "找不到片段文件: $f"

    local bak="${f}.rename-bak"
    cp -p "$f" "$bak" || die "无法备份 $f"

    # jq 精确改 tag, 不用正则 —— 正则会连同 password 里的同名子串一起改
    if ! jq --arg o "$tag" --arg n "$new" '
        (.inbounds[]? | select(.tag == $o) | .tag) = $n
    ' "$f" > "${f}.new" 2>/dev/null; then
        err "jq 处理失败, 已放弃改名"
        rm -f "${f}.new"; return 1
    fi
    [[ -s "${f}.new" ]] || { err "改写结果为空, 已放弃"; rm -f "${f}.new"; return 1; }

    # 文件名也要改。节点注册表用 "tag -> 文件名" 建立索引, 文件名没跟着改的
    # 话, 列表里显示新名字而磁盘上还是老名字, 后续任何按文件名的操作
    # (删节点、导入、清理) 都会指向一个不存在的文件。
    local nf="$CONF_DIR/$new.json"
    if [[ -e "$nf" ]]; then
        err "已存在同名片段: $nf"
        rm -f "${f}.new"; return 1
    fi
    mv -f "${f}.new" "$nf" || { err "无法重命名片段"; rm -f "${f}.new"; return 1; }
    # 新片段已就位, 原文件这时才可以删。顺序反过来会出现"两个片段都在"
    # 的窗口 —— 注册表会把两个都收进去, 同一个节点在列表里出现两次。
    rm -f "$f" || { err "新片段已写入但旧文件删除失败: $f"; warn "请手动删除, 否则该节点会重复出现"; }
    rm -f "$bak"

    # 分享侧跟着改, 两处:
    #   1) 节点元数据 sidecar (仍在本地 —— 它记的是"这个节点的对外地址",
    #      是生成分享链接的输入, 属于内核自己的知识)
    #   2) 分享记录里的 tag 引用 (在**公共基础服务**里)
    #
    # ★ 第 2 处改漏了的后果是**静默少一个节点**: 令牌本身没报错, 客户端
    #   拉到的订阅里就是少了一个, 而面板显示一切正常。
    SHARE_DIR="$SHARE_DIR" TAG="$tag" NEW="$new" LIB="$LIB_DIR" py -c "
import os, sys
sys.path.insert(0, os.environ['LIB'])
import share_meta
d, tag, new = os.environ['SHARE_DIR'], os.environ['TAG'], os.environ['NEW']
src = share_meta.meta_path(d, tag)
if os.path.exists(src):
    m = share_meta.load(d, tag) or {}
    m['tag'] = new
    m['name'] = m.get('name') or new
    share_meta.save(d, new, m)
    os.unlink(src)
"
    local _sh="$LIB_DIR/../share.sh"
    if [[ -f "$_sh" ]]; then
        bash "$_sh" retag "$tag" "$new" 2>&1 | sed 's/^/  /' >&2 || true
    else
        warn "找不到 share.sh —— 分享里的节点引用未联动, 请到菜单 10 检查"
    fi
    ok "已改名: $tag → $new"
    info "别忘了重启服务让配置生效"
}

# ---------------------------------------------------------------- nginx 站点清理
# 拿 nginx_apply.py (本地优先, 否则取仓库那份)。
_ng_apply_py() {
    local f="$LIB_DIR/nginx_apply.py"
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    local t; t=$(mktemp -t nginx_apply.XXXXXX.py) || return 1
    curl -fsSL --max-time 20 \
        "${XRAY_RAW:-https://github.com/mi1314cat/xray--core/raw/refs/heads/main}/conf/lib/nginx_apply.py" \
        -o "$t" 2>/dev/null || { rm -f "$t"; return 1; }
    printf '%s' "$t"
}

# 删节点时，把当初为它插入的 nginx 片段一并摘掉。
#
# ★ 不做这件事的后果是**延迟暴露、且看起来像别的问题**：
#   站点配置里留着一条指向已删端口的 location，回源时 nginx 连不上后端 ——
#   表现是 Cloudflare 502，而且要等到**真的有人访问那条路径**才暴露。
#   更麻烦的是现场没有任何线索指向"这个节点已经删了"。
#   (sing-box-core 那边踩过同一个坑，它的 sb_cdn_cleanup_stale 就是为此而写。)
#
# 只在 tier == nginx 时做 —— CDN 直连档没有插入过 nginx，摘了反而误伤。
cleanup_nginx_for() { # <tag>
    local tag="$1"
    local tier domain port transport path
    tier=$(SHARE_DIR="$SHARE_DIR" TAG="$tag" LIB="$LIB_DIR" py -c "
import os, sys
sys.path.insert(0, os.environ['LIB'])
import share_meta
m = share_meta.load(os.environ['SHARE_DIR'], os.environ['TAG']) or {}
print(m.get('tier', ''))
" 2>/dev/null)
    # ★ CDN 档节点也**会**有 nginx 片段: cdn_auto.sh 建完 CDN 节点会自动往
    #   站点里插一段 (回源到该端口)。原来这里只认 nginx 档, 于是删 CDN 档
    #   节点后那段 location 留在站点里 —— 指向一个已经不存在的端口, 访问
    #   那条路径就是回源 502, 而节点列表里已经看不到它了。
    #   现在两档都尝试摘除: nginx_apply.py --remove 找不到标记段时会明确
    #   回"没有找到", 对没有片段的节点 (如直连 REALITY) 是无害的。
    case "$tier" in nginx|cdn) ;; *) return 0 ;; esac

    domain=$(SHARE_DIR="$SHARE_DIR" TAG="$tag" LIB="$LIB_DIR" py -c "
import os, sys
sys.path.insert(0, os.environ['LIB'])
import share_meta
m = share_meta.load(os.environ['SHARE_DIR'], os.environ['TAG']) or {}
print(m.get('host', ''))
" 2>/dev/null)
    [[ -n "$domain" ]] || { warn "该节点是 nginx 档但没记域名, 无法自动摘除 nginx 片段"; return 0; }

    # ---- 双域名 (上下行分离的"两个域名"形态) ----
    #
    # 上行域名与下行域名各自都要有一段 nginx location, **两段都 proxy_pass 到
    # 同一个 xray 端口** (xHTTP 会话表是 per-inbound 的, 跨端口下行必断)。
    # 删节点时必须**两段都摘** —— 只摘一段的话, 站点里会留下一个指向
    # 已删节点的 location: 它不报任何错, 但那个域名还会把流量转过来,
    # 用户以为删干净了, 其实还留着一个入口。
    local dl_domain=""
    dl_domain=$(SHARE_DIR="$SHARE_DIR" TAG="$tag" LIB="$LIB_DIR" py -c "
import os, sys
sys.path.insert(0, os.environ['LIB'])
import share_meta
m = share_meta.load(os.environ['SHARE_DIR'], os.environ['TAG']) or {}
print(m.get('dl_domain', '') or m.get('dl_host', '') or '')
" 2>/dev/null)
    if [[ -n "$dl_domain" && "$dl_domain" != "$domain" ]]; then
        domain="$domain,$dl_domain"
        info "双域名节点: 两段都要摘 ($domain)"
    fi

    # 端口与传输从片段里取 (删除前调用)
    local f; f=$(node_file "$tag")
    port=$(py -c 'import json,sys
try:
    j=json.load(open(sys.argv[1]))
    ss=j["inbounds"][0].get("streamSettings") or {}
    print(j["inbounds"][0].get("port",""))
except Exception: print("")' "$f" 2>/dev/null)
    transport=$(py -c 'import json,sys
try:
    j=json.load(open(sys.argv[1]))
    ss=j["inbounds"][0].get("streamSettings") or {}
    n=ss.get("network") or "tcp"
    print({"ws":"ws","grpc":"grpc","h2":"h2","httpupgrade":"httpupgrade","xhttp":"xhttp"}.get(n,"tcp"))
except Exception: print("tcp")' "$f" 2>/dev/null)
    [[ -n "$port" ]] || { warn "读不到节点端口, 跳过 nginx 清理"; return 0; }

    # location 路径: 与 deploy.py 插入时用的是同一个值 (ws/httpupgrade/xhttp/h2
    # 才当路径用), 其余传输退回 "/" —— 插入与摘除必须同一个标识, 否则摘不到。
    local npath
    npath=$(py -c 'import json,sys
try:
    j=json.load(open(sys.argv[1]))
    ss=j["inbounds"][0].get("streamSettings") or {}
    net=ss.get("network") or "tcp"
    p=""
    if net=="ws": p=(ss.get("wsSettings") or {}).get("path","")
    elif net=="httpupgrade": p=(ss.get("httpupgradeSettings") or {}).get("path","")
    elif net=="xhttp": p=(ss.get("xhttpSettings") or {}).get("path","")
    elif net=="h2": p=(ss.get("h2Settings") or {}).get("path","")
    if p and not p.startswith("/"): p="/"+p
    print(p if p else "/")
except Exception: print("/")' "$f" 2>/dev/null)

    local pyf; pyf=$(_ng_apply_py) || { warn "拿不到 nginx_apply.py, 请手工摘除 $domain 的片段"; return 0; }
    info "摘除 nginx 片段: $domain (port=$port transport=$transport path=$npath)"
    # ★ 精确到 path: 删一个节点不该把同一个域名下别的隧道/节点一起带走。
    #   老版本按 `location /` 插进去 (标记里只有域名), 所以带 path 找不到时
    #   再按 "/" 试一次 —— 两种形态都是"我们自己插的那一段", 都是精确删除;
    #   两次都找不到才说明确实没有可摘的, 这时不动站点 (也不会误删别人)。
    local out rc=0
    out=$(py "$pyf" --domain "$domain" --path "$npath" --remove 2>&1) || rc=$?
    if (( rc == 0 )) && grep -q '没有找到' <<< "$out" && [[ "$npath" != "/" ]]; then
        info "没有 $npath 的片段 (可能是旧版本按 / 插入的), 按 / 再试一次"
        out=$(py "$pyf" --domain "$domain" --path / --remove 2>&1) || rc=$?
    fi
    if (( rc == 0 )); then
        printf '%s\n' "$out" | sed 's/^/  /' >&2
        ok "nginx 片段已摘除 (不再有指向已删端口的 location)"
    else
        printf '%s\n' "$out" | sed 's/^/  /' >&2
        warn "nginx 片段摘除失败 —— 站点里可能残留指向 $port 的 location (会表现为 CDN 回源 502)"
    fi
}

# ---------------------------------------------------------------- nginx 孤儿检查
# 站点里还留着 xray-core 标记、但对应节点已经不在了 —— 那就是孤儿。
#
# 为什么需要它: cleanup_nginx_for 是**这次才加上的**, 在此之前所有删掉的
# nginx 档节点都留下了残留 location。症状是 Cloudflare 回源 502, 而且要等到
# 真有人访问那条路径才暴露, 现场也没有任何线索指向"某次删节点"。
#
# 只报告不自动删: 站点文件是用户自己的东西, 自动改动的风险大于收益。
# 报告里直接给出可复制的摘除命令。
check_orphan_nginx() {
    # 站点里被 xray-core 标记过的域名。
    #
    # ★ 这里必须走 nginx_apply.py 的同一套探测, 不能自己 grep 宿主目录:
    #   1. nginx 跑在容器里时 (生产就是这样) 真正生效的站点在容器的挂载目录
    #      (如 /home/web/conf.d), 宿主 /etc/nginx/conf.d 是空的 —— 自己扫宿主
    #      目录会得出"没有发现片段"的**假结论**, 而站点里其实一堆孤儿;
    #   2. grep -r 会把 *.xray-core-bak / *.yaml 这些 nginx **根本不加载**的
    #      文件也算进来 (备份里留着标记) —— 于是报出一堆不存在的孤儿, 白折腾。
    #   nginx_apply.site_files() 只列 nginx 真会读的 *.conf, 且容器/宿主自适应,
    #   与"插入/摘除"用的是同一个口径 (改哪儿就在哪儿查)。
    local marked
    # ★ 下面这段 python 是用 py -c 配**双引号**裹进来的。bash 在双引号里照样会做
    #   反引号命令替换, 连以 # 开头的行也不例外 —— 所以这一整块里(包括上面的注释)
    #   **不能出现反引号, 也不能出现双引号**。两边都会把字符串提前闭合或跑命令:
    #   反引号 → "域名: command not found"; 双引号 → 后半段被当 shell 解析,
    #   python 直接收不到完整代码, 结果是 marked 恒空, 明明有孤儿也报"没有发现"。
    #   要引东西一律用「」。
    marked=$(LIB="$LIB_DIR" py -c "
import os, re, sys
sys.path.insert(0, os.environ['LIB'])
import nginx_apply as N
dk = N.probe_docker()
for f in N.site_files(dk):
    try:
        raw = N.c_read(f, dk).decode('utf-8', 'replace')
    except Exception:
        continue
    # ★ 这里取**完整 tag** (域名 或 域名|/路径)。
    #   以前只取域名, 于是同一个域名下只要还有一个节点活着, 所有同域名的
    #   孤儿段都被算成"还活着" —— 一节点一 path 是本项目的常规用法, 这种
    #   漏报等于孤儿检查形同虚设 (实测 2026-10-17 删节点后仍报"没有孤儿")。
    for m in re.finditer(r'>>>\s*xray-core\s+BEGIN\s+(\S+)', raw):
        print(m.group(1))
" 2>/dev/null | sort -u)
    if [[ -z "$marked" ]]; then
        ok "没有发现 xray-core 插入的 nginx 片段"
        return 0
    fi

    # 当前还活着的**标记** (`域名` 与 `域名|/path`)。
    #   ★ 不能只看 tier=nginx: CDN 档节点同样被 cdn_auto 插过段;
    #     也不能只看域名 (见上)。所以从**片段**里取路径、从元数据里取域名。
    local live
    live=$(CONF_DIR="$CONF_DIR" SHARE_DIR="$SHARE_DIR" LIB="$LIB_DIR" py -c "
import glob, json, os, sys
sys.path.insert(0, os.environ['LIB'])
import share_meta
cd, sd = os.environ['CONF_DIR'], os.environ['SHARE_DIR']
tags = set()
for f in glob.glob(os.path.join(cd, '*.json')):
    try:
        j = json.load(open(f, encoding='utf-8'))
    except Exception:
        continue
    ib = (j.get('inbounds') or [{}])[0]
    tag = ib.get('tag') or os.path.basename(f)[:-5]
    m = share_meta.load(sd, tag) or {}
    host = (m.get('host') or '').strip()
    if not host:
        continue
    tags.add(host)
    ss = ib.get('streamSettings') or {}
    net = ss.get('network') or 'tcp'
    p = ''
    if net == 'ws': p = (ss.get('wsSettings') or {}).get('path', '')
    elif net == 'httpupgrade': p = (ss.get('httpupgradeSettings') or {}).get('path', '')
    elif net == 'xhttp': p = (ss.get('xhttpSettings') or {}).get('path', '')
    elif net == 'h2': p = (ss.get('h2Settings') or {}).get('path', '')
    if p:
        p = p if p.startswith('/') else '/' + p
        tags.add(host + '|' + p)
for t in sorted(tags):
    print(t)
" 2>/dev/null | sort -u)

    local orphan=0 dom
    while IFS= read -r dom; do
        [[ -n "$dom" ]] || continue
        if ! grep -qxF "$dom" <<< "$live"; then
            orphan=$((orphan + 1))
            [[ $orphan -eq 1 ]] && warn "以下站点的片段已无对应节点 (CDN 回源会 502):"
            printf '    %s\n' "$dom" >&2
            printf '      摘除: 菜单 18) Nginx 站点管理 -> 移除, 或手工删掉标记段\n' >&2
        fi
    done <<< "$marked"

    if (( orphan == 0 )); then
        ok "nginx 片段与节点一一对应, 没有孤儿"
    else
        warn "共 $orphan 个孤儿片段 (只报告, 未自动改动 — 站点文件是你自己的)"
        # 给一条**可以照抄**的清理命令。清理走 nginx_apply 的 --prune-orphans:
        # 它只认本工具的 BEGIN/END 标记段, 用户自己写的 location 一个都不碰
        # (sing-box 的 cdn_prune 是按"顶层 location + proxy_pass 127.0.0.1:死端口"
        #  的形状认领的 —— 那个形状正是用户手写反代的样子, 会误删)。
        local live_csv
        live_csv=$(printf '%s\n' "$live" | tr '\n' ',' | sed 's/,$//')
        info "安全清理 (只删标记段, 不动你手写的 location):"
        if [[ -n "$live_csv" ]]; then
            printf '      python3 %s --prune-orphans %s\n' "$LIB_DIR/nginx_apply.py" "$live_csv" >&2
        else
            # 一个存活的 nginx 档节点都没有 -> 报告里列出的每一条都是孤儿。
            # 这时**不**自动给命令: "把站点里所有标记段都删掉"是个大动作,
            # 得让用户看着上面那份清单自己决定。
            printf '      (当前没有存活的 nginx 档节点, 上面列出的都是孤儿)\n' >&2
            printf '      确认后: python3 %s --prune-orphans "" --dry-run\n' "$LIB_DIR/nginx_apply.py" >&2
        fi
        printf '      先加 --dry-run 看它会删什么\n' >&2
    fi
    return 0
}

# ---------------------------------------------------------------- 删除
# 返回 0 = 节点已删除且服务已重载; 1 = 用户取消; 2 = 失败已回滚
node_delete() {
    local tag="$1"
    node_exists "$tag" || { err "没有这个节点: $tag"; return 1; }

    local f; f=$(node_file "$tag")
    [[ -f "$f" ]] || { err "找不到片段文件: $f"; return 1; }

    printf "\n  ${_YEL}将删除节点: %s${_RST}\n" "$tag" >&2
    printf "  片段文件: %s\n" "$f" >&2

    # 提前告知会影响哪些分享 —— 事后才知道链接失效就晚了
    local _sh="$LIB_DIR/../share.sh"
    [[ -f "$_sh" ]] && bash "$_sh" affected "$tag" 2>&1 | sed 's/^/  /' >&2 || true
    # 确认词用 yes, **不再重打节点名**。
    #
    # ★ 旧交互要求再输一遍节点名, 理由是"防手滑"。但节点名刚才是**编号选**
    #   出来的 —— 让用户为了一次编号选择再去手打一遍同样的字符串, 防的是
    #   手滑, 罚的是记忆。SB / M 两边都用 yes, 行为一致。
    if ! ui_confirm "删除节点 $tag ?"; then
        info "已取消"
        return 1
    fi

    # --- 第 0 步: 摘除为它插入的 nginx 片段 ---
    # 必须放在移走片段**之前**: 端口与传输是从片段里读出来的, 片段没了就读不到。
    # 失败不阻断删除 (节点本身还是要删掉), 但会明确告警。
    cleanup_nginx_for "$tag" || true

    # --- 第 1 步: 移走片段 (留备份以便回滚) ---
    local bak="${f}.del-bak"
    mv "$f" "$bak" || { err "无法移动片段文件"; return 2; }

    # --- 第 2 步: 校验 + 重载 ---
    # 节点没了, 其它分享的内容也变了 —— 刷新一次。
    # 放在 reload 之前: reload 失败也要刷新, 否则"配置没生效"和
    # "分享内容陈旧"两件事会一起留下来。
    declare -F share_refresh_all >/dev/null 2>&1 || {
        local _sh="$LIB_DIR/../share.sh"
        [[ -f "$_sh" ]] && bash "$_sh" refresh >/dev/null 2>&1 || true
    }
    if ! validate_and_reload; then
        err "配置校验或重载失败, 已回滚节点"
        mv -f "$bak" "$f"
        info "分享令牌未做任何改动"
        return 2
    fi
    rm -f "$bak"

    # --- 第 3 步: 重载成功后才吊销分享 ---
    revoke_shares_for "$tag"
    # 客户端产物 (out/<tag>.yaml) 跟着删 —— 不留孤儿文件。
    # 不删的话用户下次在产物目录里还能看到这个节点, 以为它还在。
    local _od="${XRAY_OUT_DIR:-$XRAY_BASE/out}"
    if [[ -f "$_od/$tag.yaml" ]]; then
        rm -f "$_od/$tag.yaml" && info "已删除客户端产物: $_od/$tag.yaml"
    fi
    ok "节点已删除: $tag"
    return 0
}

validate_and_reload() {
    local xb; xb=$(command -v xray || echo /usr/local/bin/xray)
    if [[ -x "$xb" ]]; then
        # ★ 校验口径必须与服务**实际启动方式**一致。
        #   本项目的 systemd 单元是 `xrayls -confdir $CONF_DIR`, 没有
        #   $XRAY_BASE/config.json 这个文件。这里原来固定 `-c $MAIN_CONFIG`,
        #   于是删除/改名**永远**走到这个分支:
        #       failed to read config: open .../config.json: no such file
        #   然后回滚, 界面上只写"配置校验或重载失败" —— 看不出是路径问题,
        #   用户会觉得"节点删不掉"。实测 (2026-10-17) 删除 100% 失败。
        #
        #   先试 -confdir (与单元一致), 没有 conf/ 时才退回老的单文件口径。
        local -a _vargs=()
        if [[ -d "$CONF_DIR" ]] && [[ -n "$(ls -A "$CONF_DIR" 2>/dev/null)" ]]; then
            _vargs=(-confdir "$CONF_DIR")
        elif [[ -f "$MAIN_CONFIG" ]]; then
            _vargs=(-c "$MAIN_CONFIG")
        fi
        if [[ ${#_vargs[@]} -eq 0 ]]; then
            warn "找不到可校验的配置 (conf/ 与 config.json 都不在), 跳过配置校验"
        elif ! "$xb" run -test "${_vargs[@]}" >/tmp/xray-validate.log 2>&1; then
            err "xray 配置校验不通过:"
            tail -5 /tmp/xray-validate.log | sed 's/^/    /' >&2
            return 1
        fi
    else
        warn "找不到 xray 二进制, 跳过配置校验"
    fi
    if ! systemctl restart "$XRAY_SERVICE" 2>/dev/null; then
        err "$XRAY_SERVICE 重启失败"
        return 1
    fi
    return 0
}

# 只停用不删记录 —— 删了就看不出"这个节点分享过又被撤了", 也没法恢复。
#
# ★ 存储已经搬到**公共基础服务** (与 M/SB 共用), 所以这里不再改本地
#   token 文件, 而是让公共服务把对应记录停用。
#   判据仍然是"这条分享的 tags 里含这个节点" —— 与旧实现一致。
#
# ★ 找不到适配器时**只告警不报错**: 删节点是主流程, 不能因为分享服务
#   那边的问题而失败。但要**说出来** —— 静默跳过的话, 用户以为分享已撤,
#   其实那条链接还活着, 而节点已经没了 (客户端拉到的是连不上的订阅)。
revoke_shares_for() {
    local tag="$1" client="$LIB_DIR/../share_client.py"
    if [[ ! -f "$client" ]]; then
        warn "找不到 share_client.py —— 分享未自动吊销, 请到菜单 10 手动检查"
        share_meta_purge "$tag"
        return 0
    fi
    local js; js=$(SHARE_PROVIDER=xray python3 "$client" list 2>/dev/null)
    if [[ -z "$js" || "$js" == "[]" ]]; then
        share_meta_purge "$tag"
        return 0
    fi
    local toks
    toks=$(printf '%s' "$js" | python3 -c '
import sys, json
tag = sys.argv[1]
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    m = r.get("meta") or {}
    tags = m.get("tags") or []
    if isinstance(tags, str): tags = [tags]
    if tag in tags and r.get("enabled", True):
        print(r["token"])
' "$tag" 2>/dev/null)
    if [[ -z "$toks" ]]; then
        share_meta_purge "$tag"
        return 0
    fi
    local n=0 t
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        SHARE_PROVIDER=xray python3 "$client" update --token "$t" --enabled false \
            >/dev/null 2>&1 && n=$((n + 1))
    done <<< "$toks"
    ok "已吊销 $n 条分享 (链接仍在, 但拉取会返回已失效)"
    share_meta_purge "$tag"
}

# 节点没了, 它的"对外地址/端口"元数据也要清掉 —— 否则下次同名节点复用时
# 会带着上一次的地址, 生成的分享链接指向一个已经不存在的地方。
share_meta_purge() {
    local tag="$1"
    SHARE_DIR="$SHARE_DIR" TAG="$tag" LIB="$LIB_DIR" py -c "
import os, sys
sys.path.insert(0, os.environ['LIB'])
import share_meta
share_meta.purge(os.environ['SHARE_DIR'], os.environ['TAG'])
" 2>/dev/null || true
}

# ---------------------------------------------------------------- 全部删除
# 一次清空全部节点 —— 旧交互只能一个个删, 节点多了就是十几轮交互。
# Sing-box 的客户端面板有独立的一项「全部删除节点」, 这里对齐。
#
# ★ 为什么整批做反而比逐个删**更安全**:
#   逐个删中途失败, 会留下"删了一半"的配置 —— 剩下的节点在、已删的没了,
#   而用户以为自己还在一个完整的状态里。整批是"要么全成, 要么全还原"。
node_delete_all() {
    _node_load
    local -a tags=("${_NODE_TAGS[@]}")

    if (( ${#tags[@]} == 0 )); then
        warn "还没有任何节点, 没什么可删"
        ui_pause; return 0
    fi

    ui_box "全部删除节点"
    printf '  %s将删除全部 %s 个节点:%s\n' "$_YEL" "${#tags[@]}" "$_RST" >&2
    local i
    for (( i = 0; i < ${#tags[@]}; i++ )); do
        printf '    %s%2d%s) %s\n' "$_CYN" "$((i+1))" "$_RST" "${tags[$i]}" >&2
    done
    printf '\n' >&2
    ui_note "这一步不可撤销 (节点只能重新添加)"
    printf '\n' >&2

    if ! ui_confirm "确认删除全部 ${#tags[@]} 个节点?"; then
        info "已取消"
        ui_pause; return 0
    fi

    # --- 第 0 步: 摘除为它们插入的 nginx 片段 (必须在片段移走之前) ---
    for t in "${tags[@]}"; do cleanup_nginx_for "$t" || true; done

    # --- 第 1 步: 整目录移走, 留一份完整备份以便回滚 ---
    local bak; bak=$(mktemp -d "${TMPDIR:-/tmp}/xray-delall.XXXXXX") \
        || { err "建不了临时目录, 已放弃"; return 2; }
    local moved=0 f
    for t in "${tags[@]}"; do
        f="$CONF_DIR/$t.json"
        [[ -f "$f" ]] || { f=$(node_file "$t" 2>/dev/null) || f=""; }
        [[ -n "$f" && -f "$f" ]] || continue
        mv "$f" "$bak/" 2>/dev/null && moved=$((moved + 1))
    done
    if (( moved == 0 )); then
        rmdir "$bak" 2>/dev/null
        err "一个片段都没移走, 已放弃 (磁盘可能只读)"
        return 2
    fi

    # --- 第 2 步: 校验 + 重载 (只做一次) ---
    local _sh="$LIB_DIR/../share.sh"
    [[ -f "$_sh" ]] && bash "$_sh" refresh >/dev/null 2>&1 || true
    if ! validate_and_reload; then
        err "配置校验或重载失败, 已还原全部节点"
        for f in "$bak"/*.json; do
            [[ -f "$f" ]] || continue
            mv -f "$f" "$CONF_DIR/$(basename "$f")" 2>/dev/null
        done
        rmdir "$bak" 2>/dev/null
        info "分享令牌未做任何改动"
        return 2
    fi

    # --- 第 3 步: 重载成功后才吊销分享 (与 node_delete 同一顺序) ---
    for t in "${tags[@]}"; do revoke_shares_for "$t"; done
    rm -rf "$bak"
    node_cache_drop
    ok "已删除全部节点 (共 $moved 个)"
    ui_pause
    return 0
}

# ---------------------------------------------------------------- 服务器标识
# 节点在客户端里显示成 "<旗帜> <前缀>-<节点名>", 这个前缀就是服务器标识。
#
# ★ 为什么不放在"进节点管理就问"的位置:
#   conf/lib/naming.sh 的 x_ask_server_name 注释写着"只在真的建节点时问" ——
#   但 xray-panel.sh 把它挂在了**主菜单的 case 分支**上 (1) 添加节点
#   (2) 节点管理), 于是进「节点管理」也要答一遍。而查看/改名/删除这三个
#   动作**一个都不会用到它**: 它只影响分享链接里给人看的名字, tag 一个字不动。
#   提示里明明写着"当前: 🇺🇸 1"(值早就落盘了)却还要再问一次 —— 所以它看起来
#   就是纯粹的多余步骤。
#
#   Sing-box 把这个 hook 挂进**每个协议的建节点流程** (sb_ask_server_name_hook),
#   Mihomo 则做成独立菜单项「给已有节点名补地区旗帜」, 两边都不在节点管理
#   里拦人。这里对齐后者: 想改随时来改, 平时一个字都不多问。
_naming_py() {
    local d
    for d in "$LIB_DIR" "${XRAY_CONF_DIR:-${CONF_DIR:-/root/catmi/xray/conf}}/lib" \
             /root/catmi/xray/conf/lib; do
        [[ -f "$d/naming.py" ]] && { printf '%s' "$d/naming.py"; return 0; }
    done
    printf '%s' "$LIB_DIR/naming.py"
}
_naming() { local p; p=$(_naming_py); [[ -f "$p" ]] || return 1
            XRAY_BASE="${XRAY_BASE:-/root/catmi/xray}" python3 "$p" "$@" 2>/dev/null; }

node_naming_menu() {
    ui_box "服务器标识 (节点名前缀)"
    local cur; cur=$(_naming server)
    ui_kv "当前标识" "${cur:-🇺🇸 X}"
    printf '\n' >&2
    ui_note "它只决定节点在客户端里显示成什么, 例如:"
    printf '    %s%s-vless01-TLS%s\n' "$_DIM" "${cur:-🇺🇸 X}" "$_RST" >&2
    ui_note "内部 tag (配置 / 文件名 / 链接) 一个字都不改 —— 改它不会让节点失效。"
    ui_note "平时不需要动。什么时候值得改: 同一台机器跑多个面板, 或想让它"
    ui_note "在客户端里一眼看出是哪台服务器。"
    printf '\n' >&2

    local a
    printf '  %s要改吗?%s %s[y=改 / 回车=返回]%s: ' \
        "$_CYN" "$_RST" "$_DIM" "$_RST" >&2
    IFS= read -r a || return 0
    [[ "$a" == "y" || "$a" == "Y" ]] || { info "已取消"; return 0; }

    local v
    v=$(ui_ask "新的服务器标识 (会带上归属地旗帜)" "${cur:-X}")
    [[ -n "$v" ]] || { info "已取消"; return 0; }

    local saved; saved=$(_naming set "$v")
    if [[ -z "$saved" ]]; then
        err "保存失败 —— 标识未改动"
        return 1
    fi
    ok "服务器标识已改为: $saved"

    # 已发出去的链接里还是旧名字, 问要不要顺手刷新 —— 不自动做, 因为
    # refresh 会重写所有分享的载荷, 是个有后果的动作。
    printf '\n' >&2
    if ui_confirm "立刻刷新全部分享链接里的节点名?"; then
        local _sh="$LIB_DIR/../share.sh"
        if [[ -f "$_sh" ]]; then
            bash "$_sh" refresh 2>&1 | sed 's/^/  /' >&2
            ok "分享链接里的节点名已刷新"
        else
            warn "找不到 share.sh —— 请到「分享管理」手动刷新一次"
        fi
    else
        info "分享链接里还是旧名字, 客户端下次拉取才生效 —— 想现在刷: 菜单 4) 分享管理"
    fi
    return 0
}

# ---------------------------------------------------------------- 菜单
node_menu() {
    local c
    while :; do
        printf '\n' >&2
        ui_title "节点管理"
        node_print_table
        echo >&2
        ui_menu 1 "查看节点详情    编号选择"
        ui_menu 2 "改名            片段 / 文件名 / 分享元数据 / 令牌引用四处同步"
        ui_menu 3 "删除节点        先校验再吊销分享, 失败则回滚"
        ui_menu 4 "全部删除节点    清空全部节点 (需输入 yes 确认)"
        ui_menu 5 "检查 nginx 孤儿片段 (已删节点残留的 location)"
        ui_menu 6 "服务器标识      改节点在客户端里显示的前缀（平时不用动）"
        ui_menu 0 "返回"
        printf '\n  %s请选择%s: ' "${_CYN:-}" "${_RST:-}" >&2
        read -r c || return 0
        case "$c" in
            1) node_pick "查看" && { node_show "$UI_PICK_KEY"; ui_pause; } ;;
            2)
                if node_pick "改名"; then
                    node_rename "$UI_PICK_KEY" "$(ui_ask "新名字 (字母数字 . _ -)" "$UI_PICK_KEY")"
                    node_cache_drop
                    ui_pause
                fi
                ;;
            3)
                if node_pick "删除"; then
                    node_delete "$UI_PICK_KEY"
                    node_cache_drop
                    ui_pause
                fi
                ;;
            4) node_delete_all ;;
            5) check_orphan_nginx; ui_pause ;;
            6) node_naming_menu; ui_pause ;;
            0|"") return 0 ;;
            *) warn "无效选择"; ui_pause ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-menu}" in
        list)   node_list ;;
        show)   node_show "${2:?用法: node.sh show <tag>}" ;;
        rename) node_rename "${2:?}" "${3:?}" ;;
        delete) node_delete "${2:?}" ;;
        delete-all) node_delete_all ;;
        orphans) check_orphan_nginx ;;
        menu)   node_menu ;;
        *) echo "用法: node.sh [menu|list|show <tag>|rename <tag> <新名>|delete <tag>|delete-all|orphans]" >&2; exit 1 ;;
    esac
fi