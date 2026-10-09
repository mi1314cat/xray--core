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
# HERE = Client/, 不是 tools/。RUN.sh 在 Client/ 下, 弄错的话入口那一组
# 会一直去执行一个不存在的文件, 表现是"入口全部失败"而其他项全过。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPO="$(mktemp -t xbd-iv-out.XXXXXX)"
trap 'rm -f "$TMPO"' EXIT

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

# ============================================================ 客户端
test_client() {
  XBD="$PREFIX/bin/xbd"
  [ -x "$XBD" ] || { printf '  找不到 %s\n' "$XBD"; return 1; }

  # ---------------------------------------------------------- 入口
  printf '\n  \033[36m入口与角色分发\033[0m\n'
  printf '0\n' | timeout 25 bash "$HERE/RUN.sh" >"$TMPO" 2>&1
  hasf "入口列出服务端选项" "1\." "xrayls"
  hasf "入口列出客户端选项" "2\." "客户端"
  hasf "入口列出退出选项" "0\." "退出"
  hasntf "入口不再说'暂未提供'" "暂未提供"
  hasntf "入口不再说'还没有服务端功能'" "还没有服务端功能"

  timeout 25 bash "$HERE/RUN.sh" client multi status >"$TMPO" 2>&1
  hasf "命令行直传 client 生效（不重装、直接执行）" "单节点模式|多出站已开启" ""

  # 服务端分支：必须真的进 xrayls 面板，而不是又跑一遍安装
  printf '0\n0\n' | timeout 25 bash "$HERE/RUN.sh" server >"$TMPO" 2>&1
  if grep -qaE 'xrayls 管理脚本|找不到服务端面板' "$TMPO"; then
    ok "服务端分支进到了 xrayls 面板"
  else
    bad "服务端分支进到了 xrayls 面板" "$(head -c 200 "$TMPO" | tr '\n' ' ')"
  fi
  hasntf "服务端分支不会先跑客户端安装" "Xray Client 安装"

  printf '\n' | timeout 25 bash "$HERE/RUN.sh" >"$TMPO" 2>&1
  hasf "空回车不退出（重画菜单）" "请输入选项" ""

  printf 'zz\n0\n' | timeout 25 bash "$HERE/RUN.sh" >"$TMPO" 2>&1
  hasf "入口非法选项被兜住" "无效选项 zz" ""

  # ---------------------------------------------------------- 主菜单
  printf '\n  \033[36m主菜单\033[0m\n'
  printf '0\n' | timeout 25 "$XBD" menu >"$TMPO" 2>&1
  for item in 节点管理 服务控制 端口设置 配置分发 "Web 面板" 诊断 多出站; do
    hasf "主菜单含「$item」" "$item" ""
  done
  hasf "主菜单顶部显示状态" "状态:" ""
  hasf "主菜单顶部显示节点数" "节点:" ""

  printf 'zz\n0\n' | timeout 25 "$XBD" menu >"$TMPO" 2>&1
  hasf "主菜单非法输入被兜住" "无效选项 zz" ""

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

  # ---------------------------------------------------------- 多出站
  printf '\n  \033[36m多出站开关\033[0m\n'
  timeout 30 "$XBD" multi status >"$TMPO" 2>&1
  hasf "multi status 有输出" "单节点模式|多出站已开启" ""
  timeout 30 "$XBD" multi >"$TMPO" 2>&1
  hasf "multi 不带参数 = status" "单节点模式|多出站已开启" ""
  timeout 30 "$XBD" multi zz >"$TMPO" 2>&1
  hasf "multi 非法取值被兜住" "未知操作" ""
  hasf "multi 非法取值给出正确提示" "xbd multi status" ""

  # ---------------------------------------------------------- 配置分发
  printf '\n  \033[36m配置分发\033[0m\n'
  timeout 30 "$XBD" share list >"$TMPO" 2>&1
  if [ -s "$TMPO" ]; then ok "share list 有输出"; else bad "share list 有输出" "空"; fi
  timeout 30 "$XBD" share zz >"$TMPO" 2>&1
  hasf "share 非法操作被兜住" "未知操作" ""
  hasf "share 非法操作给出用法" "xbd share help" ""
  timeout 30 "$XBD" share off >"$TMPO" 2>&1
  hasf "share off 不带 token 会给用法" "用法|缺少" ""

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
  printf '    (SOCKS 端口: %s)\n' "$PORT"
  if command -v ss >/dev/null && ss -tln 2>/dev/null | grep -q ":$PORT "; then
    ok "SOCKS $PORT 在监听"
  else bad "SOCKS $PORT 在监听" "没监听"; fi
  r=$(timeout 25 curl -s -o /dev/null -w '%{http_code}' --socks5-hostname "127.0.0.1:$PORT" https://www.gstatic.com/generate_204 2>/dev/null)
  case "$r" in
    204|200) ok "经 SOCKS 出网正常 (HTTP $r)" ;;
    000) bad "经 SOCKS 出网正常" "连不上" ;;
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
