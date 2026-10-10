#!/usr/bin/env bash
# ================================================================
# 交互验证台 —— 把菜单真正点一遍，而不是只检查文件在不在
#
# 为什么非要用交互式:
#   菜单脚本的大部分代码只有"被人按键"时才会执行，而且问题几乎全出在
#   交互路径上 —— 取消没处理、回车跳过了该问的问题、非法输入没兜住、
#   管道被 head 掐断、read 拿到空值就往下走。这些静态检查一个都发现不了。
#
#   做法是把按键喂给 stdin（模拟真人），捕获 stdout，逐项断言。
#
# 用法: bash interactive-test.sh <client|server>
# ================================================================
set -uo pipefail

ROLE="${1:-client}"
PASS=0; FAIL=0
FAILED_NAMES=()

PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"

# 只读模式。生产机上跑验证台时必须开:
#   --read-only   不做任何会改配置/重启服务的动作
#
# 默认是全量的, 因为在测试机上要把"能不能真的切过去"也验掉。
# 但生产机上跑全量 = 可能把用户正在用的代理切掉, 所以要能只验不碰。
READ_ONLY=0
for a in "$@"; do
  case "$a" in
    --read-only) READ_ONLY=1 ;;
    client|server) ROLE="$a" ;;
  esac
done
[ "${READ_ONLY}" -eq 1 ] && printf '  \033[33m[只读模式]\033[0m 会改配置/重启的项已跳过\n\n'
# HERE = Client/, 不是 tools/。写错的话各项路径断言会一起挂。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPO="$(mktemp -t xbd-iv-out.XXXXXX)"
TMPB="$(mktemp -t xbd-iv-blk.XXXXXX)"
trap 'rm -f "$TMPO" "$TMPB"' EXIT

# 捕获一段命令的输出到 $TMPO。不用 $(...): 命令替换会丢 NUL 字节, 而且
# 60KB+ 的页面在 $( ) 里会被截断 —— 症状是"断言全挂", 但功能其实是好的。
# 之前面板那一组就是这么误判的。
cap() { "$@" >"$TMPO" 2>&1; CAP_RC=$?; return 0; }
capstr() { grep -a . "$TMPO" 2>/dev/null | head -c 2000; }

ok()   { PASS=$((PASS+1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"
         [ $# -gt 1 ] && printf '        %s\n' "$2"; }

# 基于文件的断言。三参数：名字 / 正则 / 可选的附加说明。
# 一律用 grep -a：页面里混进控制字符时，没有 -a 的 grep 会判定为 binary
# 直接不输出 —— 所有断言一起挂掉，而且看不出原因。
hasf() {
  if grep -qaE -- "$2" "$TMPO"; then ok "$1"
  else bad "$1" "${3:-找不到「$2」} 内容开头: $(head -c 160 "$TMPO" | tr '\n' ' ')"; fi
}
hasntf() {
  if grep -qaE -- "$2" "$TMPO"; then
    bad "$1" "${3:-不该出现「$2」} 实际: $(head -c 160 "$TMPO" | tr '\n' ' ')"
  else ok "$1"; fi
}

# 从菜单文本里现查某一项的编号, 别在测试里硬编码数字。
#
# 这不是洁癖: 节点子菜单按用途重排过一次, 原来的 8) 浏览器拨号 变成 9),
# 而 8) 的位置换成了「删除节点」—— 测试里的 '1\n8\n0\n0' 于是从"看一眼
# 拨号菜单"变成了"对着删除菜单敲回车"。断言失败是看得见的, 全量跑时
# 真的删掉一个节点是看不见的。
#
# 用法: IDX=$(menu_idx "$TMPO" 浏览器拨号)
#
# 用 awk 而不是 sed: 选项名里有 `/`（安装 / 更新内核）, 拿 / 当分隔符
# 会把表达式拆坏 —— 抓不到编号却不报错, 于是脚本退回硬编码的旧数字。
menu_idx() {  # menu_idx <含菜单的文本文件> <关键字>
  awk -v pat="$2" '
    { line = $0; gsub(/\033\[[0-9;]*m/, "", line) }
    line ~ /^[[:space:]]*[0-9]+[).][[:space:]]/ {
      if (index(line, pat) > 0) {
        sub(/^[[:space:]]*/, "", line); sub(/[).].*$/, "", line); print line; exit
      }
    }' "$1"
}

# 只截出某个子菜单盒子里的行。
#
# 必须做这层: 主菜单上也有「浏览器拨号」和「分组管理」两个顶层快捷项,
# 直接对整个输出查标签会命中主菜单那一行 —— 拿到的 3 是主菜单的编号,
# 敲进节点子菜单就是「测速」。子菜单标题只出现在子菜单盒子里, 且以
# 「0) 返回」收尾, 用这两头夹出来才是稳的。
menu_block() {  # menu_block <含菜单的文本文件> <子菜单标题>
  awk -v title="$2" '
    { line = $0; gsub(/\033\[[0-9;]*m/, "", line) }
    seen && line ~ /^[[:space:]]*0\)[[:space:]]*(返回|退出)/ { print buf; exit }
    seen { buf = buf line "\n"; next }
    line ~ ("^[[:space:]]*" title "[[:space:]]*$") { seen = 1 }
  ' "$1"
}

# ============================================================ 客户端
test_client() {
  XBD="$PREFIX/bin/xbd"
  [ -x "$XBD" ] || { printf '  找不到 %s\n' "$XBD"; return 1; }

  # ---------------------------------------------------------- 入口
  #
  # 这里只验 xbd 自己的入口, 不验 RUN.sh。
  #
  # RUN.sh 是**客户端分发包**的安装脚本, 跑在还没装好的机器上;
  # 它的菜单里有"1. 服务端"是给"手上捏着整个仓库、在服务端机上也能拉起
  # xrayls 面板"用的。客户端机上装完之后, 服务端脚本根本不在旁边 ——
  # `RUN.sh server` 会找不到面板直接报错, 那是正确行为, 不是缺陷。
  #
  # 服务端那条路径由 tools/server-interactive-test.sh 在服务端机上验。
  printf '\n  \033[36m入口\033[0m\n'
  timeout 25 "$XBD" help >"$TMPO" 2>&1
  hasf "xbd help 列出全部子命令" "menu|node|multi" ""
  hasf "xbd help 提到 share" "share" ""

  # 直接进菜单
  printf '0\n' | timeout 40 "$XBD" menu >"$TMPO" 2>&1
  hasf "xbd menu 能进能退" "请输入选项|状态" ""

  # ---------------------------------------------------------- 主菜单
  printf '\n  \033[36m主菜单\033[0m\n'
  printf '0\n' | timeout 25 "$XBD" menu >"$TMPO" 2>&1
  for item in 节点管理 服务控制 端口设置 配置分发 "Web 面板" 诊断 多出站; do
    hasf "主菜单含「$item」" "$item" ""
  done
  # 顶部状态块：标签在 2.6.2 改成了与网页面板一致的中文（原来叫"状态:"），
  # 断言跟着改 —— 同一条信息两个名字正是最容易让人怀疑"这是两个东西"的地方。
  hasf "主菜单顶部显示服务状态" "服务状态" ""
  hasf "主菜单顶部显示节点数量" "节点数量" ""
  hasf "主菜单顶部显示内核版本" "内核版本" ""
  hasf "主菜单顶部显示网页面板地址" "网页面板" ""
  hasf "主菜单有分组说明（不是一行光秃秃的命令）" "添加 / 切换 / 测速" ""

  printf 'zz\n0\n' | timeout 25 "$XBD" menu >"$TMPO" 2>&1
  hasf "主菜单非法输入被兜住（回显敲的内容）" "无效选项: zz" ""

  # 每个子菜单进去再立刻退出来 —— 验证能进能退、不卡死
  printf '\n  \033[36m子菜单进出\033[0m\n'
  for k in 1 2 3 4 5 7; do
    printf '%s\n0\n0\n' "$k" | timeout 30 "$XBD" menu >"$TMPO" 2>&1
    rc=$?
    if [ $rc -eq 124 ]; then bad "子菜单 $k 能在超时内退出" "超时卡死"
    else ok "子菜单 $k 能进能退"; fi
  done

  # ---------------------------------------------------------- 节点
  printf '\n  \033[36m节点\033[0m\n'
  timeout 40 "$XBD" node list >"$TMPO" 2>&1
  hasf "node list 有输出" "节点" ""

  # xbd node 不带参数默认等价于 list（不是打印用法）—— 这是刻意的:
  # 用户敲 xbd node 最可能就是想看有哪些节点。
  timeout 40 "$XBD" node >"$TMPO" 2>&1 </dev/null
  hasf "node 不带参数时列出节点" "当前节点|节点" ""

  timeout 40 "$XBD" node use >"$TMPO" 2>&1 </dev/null
  hasf "node use 不带参数时给用法" "用法" ""

  timeout 40 "$XBD" node use 999999 >"$TMPO" 2>&1
  hasf "切到不存在的节点会明确报错" "没有编号|找不到|✗" ""

  if [ "$READ_ONLY" -eq 0 ]; then
    # 切节点会重写配置并重启 —— 生产机上不做, 除非显式要求
    first=$(ls "$PREFIX"/nodes/node-*.json 2>/dev/null | head -1 | xargs -r basename)
    [ -n "$first" ] && timeout 90 "$XBD" node use "${first%.json}" >"$TMPO" 2>&1
    hasf "切节点能成功" "当前|✓" ""
  else
    printf '    \033[90m(skipped) node use —— 会重写配置并重启\033[0m\n'
  fi

  # ---------------------------------------------------------- 多出站
  printf '\n  \033[36m多出站开关\033[0m\n'
  timeout 30 "$XBD" multi status >"$TMPO" 2>&1
  hasf "multi status 有输出" "单节点模式|多出站已开启" ""
  timeout 30 "$XBD" multi >"$TMPO" 2>&1
  hasf "multi 不带参数 = status" "单节点模式|多出站已开启" ""
  timeout 30 "$XBD" multi zz >"$TMPO" 2>&1
  hasf "multi 非法取值被兜住" "未知操作" ""
  hasf "multi 非法取值给出正确提示" "xbd multi status" ""

  if [ "$READ_ONLY" -eq 0 ]; then
    # 切多出站会重启 xray 并改配置 —— 生产机上默认不碰
    before=$(awk -F= '$1=="MULTI_OUTBOUND"{print $2}' "$PREFIX/config/multi.env" 2>/dev/null | head -1)
    timeout 180 "$XBD" multi on >"$TMPO" 2>&1
    hasf "multi on 能开启" "多出站|✓|已" ""
    timeout 60 "$XBD" multi status >"$TMPO" 2>&1
    hasf "multi on 后状态是开" "多出站已开启" ""
    timeout 180 "$XBD" multi off >"$TMPO" 2>&1
    timeout 60 "$XBD" multi status >"$TMPO" 2>&1
    hasf "multi off 能关回去" "单节点模式" ""
    # 恢复原状
    [ "$before" = "on" ] && timeout 180 "$XBD" multi on >/dev/null 2>&1
  else
    printf '    \033[90m(skipped) multi on/off —— 会重启并改配置\033[0m\n'
  fi

  # ---------------------------------------------------------- Browser Dialer
  printf '\n  \033[36m浏览器拨号\033[0m\n'
  # 菜单入口: 之前 node browser 只能敲命令行, 菜单里没有
  # 先只进节点子菜单, 读出「浏览器拨号」这一项的真实编号再往下走。
  printf '1\n0\n0\n' | timeout 90 "$XBD" menu >"$TMPO" 2>&1
  menu_block "$TMPO" "节点管理" >"$TMPB"
  DIALER_IDX=$(menu_idx "$TMPB" "浏览器拨号")
  if [ -n "$DIALER_IDX" ]; then
    ok "节点菜单含「浏览器拨号」(第 ${DIALER_IDX} 项)"
    # 顺带把"别把删除当拨号"钉死: 这两项挨着, 混了代价最大
    DEL_IDX=$(menu_idx "$TMPB" "删除节点")
    if [ "$DIALER_IDX" = "$DEL_IDX" ]; then
      bad "「浏览器拨号」和「删除节点」不是同一项" "编号都是 $DIALER_IDX"
    else ok "「浏览器拨号」和「删除节点」是两项（$DIALER_IDX / $DEL_IDX）"; fi
  else
    bad "节点菜单含「浏览器拨号」" "节点子菜单里找不到该项: $(head -20 "$TMPB" | tr '\n' ' ')"
    DIALER_IDX=9
  fi
  printf "1\n%s\n0\n0\n" "$DIALER_IDX" | timeout 90 "$XBD" menu >"$TMPO" 2>&1
  hasf "浏览器拨号菜单列出每个节点" "可浏览器" ""
  # 不支持的节点也要列出来 —— 用户要能看出"为什么这个没开关"
  hasf "浏览器拨号菜单说明能力边界" "xhttp/websocket" ""
  hasf "浏览器拨号菜单有批量开关" "最省内存" ""

  # 关浏览器必须先警告: 有服务端只认浏览器 TLS 指纹, 关掉就断
  # (CC 上 node-001-ccsmvless-01 实测: 开 204 / 关 000)
  # readlink -f 给的是全路径带 .json, 而 node browser 要的是节点名(不带后缀)
  cur_node=$(readlink -f "$PREFIX/nodes/current" 2>/dev/null || true)
  cur_name=$(basename "${cur_node:-}" .json)
  cur_json="$cur_node"
  if [ -n "$cur_node" ] && [ -e "$cur_node" ]; then
    can=$(python3 "$PREFIX/lib/compat.py" json "$cur_json" 2>/dev/null \
          | python3 -c 'import sys,json
try: print("yes" if json.load(sys.stdin).get("can_use_dialer") else "no")
except Exception: print("no")' 2>/dev/null)
    if [ "$can" = "yes" ]; then
      printf 'n\n' | timeout 60 "$XBD" node browser "$cur_name" off >"$TMPO" 2>&1
      hasf "关浏览器前会警告后果" "只认浏览器的 TLS 指纹" ""
      hasf "关浏览器前要用户确认" "要继续关闭吗" ""
      # 输入 n 之后不能真改掉
      still=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("use_browser"))' "$cur_json" 2>/dev/null)
      if [ "$still" != "False" ]; then ok "回答 n 时不改动设置"
      else bad "回答 n 时不改动设置" "use_browser 变成了 False"; fi
    else
      printf '    \033[90m(skipped) 关闭确认 —— 当前节点不支持浏览器\033[0m\n'
    fi
  fi

  # ---------------------------------------------------------- 配置分发
  printf '\n  \033[36m配置分发\033[0m\n'
  timeout 30 "$XBD" share list >"$TMPO" 2>&1
  if [ -s "$TMPO" ]; then ok "share list 有输出"; else bad "share list 有输出" "空"; fi
  timeout 30 "$XBD" share zz >"$TMPO" 2>&1
  hasf "share 非法操作被兜住" "未知操作" ""
  hasf "share 非法操作给出用法" "xbd share help" ""
  timeout 30 "$XBD" share off >"$TMPO" 2>&1
  hasf "share off 不带 token 会给用法" "用法|缺少" ""

  if [ "$READ_ONLY" -eq 0 ]; then
    poke_share=$(timeout 60 "$XBD" share new >"$TMPO" 2>&1; echo $?)
    hasf "share new 能开" "http|令牌|token|分享" ""
    timeout 60 "$XBD" share off >"$TMPO" 2>&1
    hasf "share off 能关" "已关闭|✓" ""
  else
    printf '    \033[90m(skipped) share new/off —— 会起服务并改配置\033[0m\n'
  fi

  # ---------------------------------------------------------- 只读命令
  printf '\n  \033[36m只读命令（不能有副作用）\033[0m\n'
  for c in status ports diagnose help; do
    cap timeout 45 "$XBD" $c
    rc=$CAP_RC
    if [ $rc -le 1 ] && [ -s "$TMPO" ]; then ok "xbd $c 可用 (rc=$rc)"
    else bad "xbd $c 可用" "rc=$rc $(head -c 120 "$TMPO" | tr '\n' ' ')"; fi
  done

  # ---------------------------------------------------------- Web 面板
  printf '\n  \033[36mWeb 面板\033[0m\n'
  PANEL_ENV="$PREFIX/config/panel.env"
  if [ -f "$PANEL_ENV" ]; then
    PT=$(awk -F= '$1=="PANEL_TOKEN"{print $2}' "$PANEL_ENV" | head -1)
    PH=$(awk -F= '$1=="PANEL_HOST"{print $2}' "$PANEL_ENV" | head -1)
    url="http://$PH:18090"          # BIND_PORT 在 panel.py 里是 18090
    curl -s -m 20 "$url/?token=$PT" -o "$TMPO" 2>/dev/null
    if [ -s "$TMPO" ]; then
      hasf "面板首页可访问" "<!DOCTYPE html>|<html" ""
      # 这些标记都在页面后半段, 必须整页判断
      for f in subs-rail nodes-body multi-mode dns-mode setMulti setDns; do
        hasf "面板含 $f" "$f" ""
      done
    else
      bad "面板首页可访问" "curl 没拿到内容"
    fi
    curl -s -m 20 "$url/api/state?token=$PT" -o "$TMPO" 2>/dev/null
    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "nodes" in d' "$TMPO" 2>/dev/null; then
      ok "面板 /api/state 返回合法 JSON 且含 nodes"
    else bad "面板 /api/state 返回合法 JSON 且含 nodes" "$(head -c 120 "$TMPO")"; fi
    curl -s -m 20 "$url/?token=wrongtoken" -o "$TMPO" 2>/dev/null
    hasntf "错误令牌被拒绝" "subs-rail"
    # 关键: 开关值和实际状态必须一致
    curl -s -m 20 "$url/api/state?token=$PT" -o "$TMPO" 2>/dev/null
    python3 - "$TMPO" <<'PY' || bad "面板 multi_mode 与 multi_active 自洽"
import json,sys
d=json.load(open(sys.argv[1]))
m,a = d.get("multi_mode"), d.get("multi_active")
# off+True 或 on+False 都说明"开关说的"和"跑着的"不一致
assert not (m=="off" and a) and not (m=="on" and not a), f"{m}/{a}"
PY
    ok "面板 multi_mode 与 multi_active 自洽"
  else
    printf '    (没有 panel.env，跳过)\n'
  fi

  # ---------------------------------------------------------- 代理
  printf '\n  \033[36m代理可用性\033[0m\n'
  PORT=$(awk -F= '$1=="PORT_NORMAL"{print $2}' "$PREFIX/config/ports.env" 2>/dev/null | head -1)
  PORT="${PORT:-1080}"

  # 监听地址必须从实际生成的配置里读, 不能假设 127.0.0.1。
  #
  # LAN 模式下 socks 入站绑的是本机 LAN IP（LAN 共享是这版客户端的核心功能,
  # 手机/其他设备要能连), 不是 localhost。
  # 早先这里硬写 127.0.0.1, 在 LAN 模式下必然连不上 —— 测出来是
  # "经 SOCKS 出网正常" 失败, 而服务其实好着。CC 上就踩了这个:
  # 实际监听 192.168.1.178:1080, 出口 104.28.195.192, 完全正常。
  BIND=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for i in d.get("inbounds",[]):
    if i.get("protocol")=="socks" and i.get("port")==int(sys.argv[2]):
        print(i.get("listen") or "0.0.0.0"); break
' "$PREFIX/runtime/xray-client.json" "$PORT" 2>/dev/null)
  case "$BIND" in ""|0.0.0.0|::) ADDR="127.0.0.1" ;; *) ADDR="$BIND" ;; esac
  printf '    (SOCKS: %s —— 生成配置绑定 %s)\n' "$ADDR:$PORT" "${BIND:-未找到}"

  if command -v ss >/dev/null && ss -tln 2>/dev/null | grep -q ":$PORT "; then
    ok "SOCKS $PORT 在监听"
  else bad "SOCKS $PORT 在监听" "没监听"; fi

  r=$(timeout 25 curl -s -o /dev/null -w '%{http_code}' --socks5-hostname "$ADDR:$PORT" https://www.gstatic.com/generate_204 2>/dev/null)
  case "$r" in
    204|200) ok "经 SOCKS 出网正常 (HTTP $r)" ;;
    000) bad "经 SOCKS 出网正常" "连不上 $ADDR:$PORT" ;;
    *) bad "经 SOCKS 出网正常" "HTTP $r" ;;
  esac
}

# ============================================================ 服务端
test_server() {
  REPO="$(cd "$HERE/.." && pwd)"
  PANEL="$REPO/xray-panel.sh"
  printf '\n  \033[36m服务端面板\033[0m\n'
  if [ ! -f "$PANEL" ]; then bad "xray-panel.sh 存在" "$PANEL"; return 1; fi
  ok "xray-panel.sh 存在"

  # 语法先过一遍，否则后面全是噪音
  for f in xray-panel.sh xargo.sh VEVLRE.sh VEVLRE6.sh caddy.sh nginx.sh; do
    [ -f "$REPO/$f" ] || continue
    if bash -n "$REPO/$f" 2>/dev/null; then ok "$f 语法通过"
    else bad "$f 语法通过" "$(bash -n "$REPO/$f" 2>&1 | head -2 | tr '\n' ' ')"; fi
  done

  # 主菜单：用 0 退出，不能卡死
  printf '0\n' | timeout 30 bash "$REPO/xray-panel.sh" >"$TMPO" 2>&1
  hasf "服务端主菜单能显示" "xrayls 管理脚本" ""
  for it in "安装/更新" "查看客户端配置" "添加节点" "分流规则" "反向代理" "证书" "分享"; do
    hasf "服务端菜单含「$it」" "$it" ""
  done
  hasntf "主菜单不残留 shell 错误" "command not found"

  printf '99\n0\n' | timeout 30 bash "$REPO/xray-panel.sh" >"$TMPO" 2>&1
  hasf "服务端非法选项被兜住" "无效的选项" "非法输入 99 之后没有任何提示"

  # 只读项：3 查看客户端配置、4 查询服务状态 —— 这两项不该改系统
  printf '4\n\n0\n' | timeout 40 bash "$REPO/xray-panel.sh" >"$TMPO" 2>&1
  if [ -s "$TMPO" ]; then ok "服务端「查询服务状态」能跑出内容"
  else bad "服务端「查询服务状态」能跑出内容" "空"; fi

  printf '3\n\n0\n' | timeout 40 bash "$REPO/xray-panel.sh" >"$TMPO" 2>&1
  if [ -s "$TMPO" ]; then ok "服务端「查看客户端配置」能跑出内容"
  else bad "服务端「查看客户端配置」能跑出内容" "空"; fi
}


case "$ROLE" in
  client) test_client ;;
  server) test_server ;;
  *) printf '用法: bash interactive-test.sh <client|server>\n'; exit 2 ;;
esac

printf '\n  %s\n' "────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[32m全部通过: %d 项\033[0m\n\n' "$PASS"
  exit 0
else
  printf '  \033[32m通过 %d\033[0m, \033[31m失败 %d\033[0m\n' "$PASS" "$FAIL"
  printf '  失败项:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  printf '\n'
  exit 1
fi
