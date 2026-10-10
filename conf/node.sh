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

py() { python3 "$@"; }

# ---------------------------------------------------------------- 辅助
py_lib() { # 把 lib 目录作为参数传给内嵌脚本, 避免 heredoc 猜 sys.path
    py -c "import sys; sys.path.insert(0, '$LIB_DIR'); exec(sys.stdin.read())"
}

node_list() { py "$LIB_DIR/nodes.py" "$CONF_DIR"; }

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
    [[ "$tier" == "nginx" ]] || return 0

    domain=$(SHARE_DIR="$SHARE_DIR" TAG="$tag" LIB="$LIB_DIR" py -c "
import os, sys
sys.path.insert(0, os.environ['LIB'])
import share_meta
m = share_meta.load(os.environ['SHARE_DIR'], os.environ['TAG']) or {}
print(m.get('host', ''))
" 2>/dev/null)
    [[ -n "$domain" ]] || { warn "该节点是 nginx 档但没记域名, 无法自动摘除 nginx 片段"; return 0; }

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
    #   2. `grep -r` 会把 *.xray-core-bak / *.yaml 这些 nginx **根本不加载**的
    #      文件也算进来 (备份里留着标记) —— 于是报出一堆不存在的孤儿, 白折腾。
    #   nginx_apply.site_files() 只列 nginx 真会读的 *.conf, 且容器/宿主自适应,
    #   与"插入/摘除"用的是同一个口径 (改哪儿就在哪儿查)。
    local marked
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
    # tag 可能是 `域名` 或 `域名|/路径` —— 存活判断按**域名**做, 所以这里
    # 只取竖线前面那半截。取整段的话带路径的片段会被永远当成孤儿。
    for m in re.finditer(r'>>>\s*xray-core\s+BEGIN\s+(\S+)', raw):
        print(N.tag_domain(m.group(1)))
" 2>/dev/null | sort -u)
    if [[ -z "$marked" ]]; then
        ok "没有发现 xray-core 插入的 nginx 片段"
        return 0
    fi

    # 当前还活着的节点域名 (tier=nginx 的那些)
    local live
    live=$(SHARE_DIR="$SHARE_DIR" LIB="$LIB_DIR" py -c "
import glob, json, os, sys
sys.path.insert(0, os.environ['LIB'])
import share_meta
d = os.environ['SHARE_DIR']
for f in glob.glob(os.path.join(d, '*.json')):
    try: m = json.load(open(f, encoding='utf-8'))
    except Exception: continue
    if m.get('tier') == 'nginx' and m.get('host'):
        print(m['host'])
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
    printf "  确认删除? 输入节点名确认: " >&2
    read -r conf || true
    [[ "$conf" == "$tag" ]] || { info "已取消"; return 1; }

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
    ok "节点已删除: $tag"
    return 0
}

validate_and_reload() {
    local xb; xb=$(command -v xray || echo /usr/local/bin/xray)
    if [[ -x "$xb" ]]; then
        if ! "$xb" run -test -c "$MAIN_CONFIG" >/tmp/xray-validate.log 2>&1; then
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

# ---------------------------------------------------------------- 菜单
node_menu() {
    while :; do
        printf '\n' >&2
        ui_title "节点管理"
        node_list >&2
        ui_menu 1 "查看节点详情"
        ui_menu 2 "改名           片段 / 文件名 / 分享元数据 / 令牌引用四处同步"
        ui_menu 3 "删除           先校验再吊销分享，失败则回滚"
        ui_menu 4 "检查 nginx 孤儿片段（已删节点残留的 location）"
        ui_menu 0 "返回"
        printf '\n  请选择: ' >&2
        read -r c || return 0
        case "$c" in
            1)
                printf "  节点名: " >&2; read -r t || true
                [[ -n "$t" ]] && node_show "$t"
                ;;
            2)
                printf "  节点名: " >&2; read -r t || true
                printf "  新名字: " >&2; read -r nn || true
                [[ -n "$t" && -n "$nn" ]] && node_rename "$t" "$nn"
                ;;
            3)
                printf "  节点名: " >&2; read -r t || true
                [[ -n "$t" ]] && node_delete "$t"
                ;;
            4) check_orphan_nginx ;;
            0|"") return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-menu}" in
        list)   node_list ;;
        show)   node_show "${2:?用法: node.sh show <tag>}" ;;
        rename) node_rename "${2:?}" "${3:?}" ;;
        delete) node_delete "${2:?}" ;;
        orphans) check_orphan_nginx ;;
        menu)   node_menu ;;
        *) echo "用法: node.sh [menu|list|show <tag>|rename <tag> <新名>|delete <tag>|orphans]" >&2; exit 1 ;;
    esac
fi