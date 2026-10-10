#!/usr/bin/env bash
# ================================================================
# 服务端交互验证 —— 把 xrayls 面板真正点一遍
#
# 背景: 客户端 (Client/) 一直有人验, 服务端 (xray-panel.sh + 那些 .sh)
# 一直没有。面板里二十项菜单, 大部分是 curl 远端拉脚本再跑, 直接点会改
# 生产配置 —— 所以这里的策略是:
#
#   · 纯展示类菜单: 真正点进去, 断言有内容且不卡死
#   · 会改配置的菜单: 只验证"能加载、能看到选项、取消是安全的", 不提交
#   · 任何一步都用超时兜着, 面板卡住不算验证通过
#
# 用法: bash server-interactive-test.sh [--repo <仓库根目录>]
# ================================================================
set -uo pipefail

REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$REPO" ] || REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

PASS=0; FAIL=0; FAILED_NAMES=()
TMPO="$(mktemp -t xbd-srv-XXXXXX)"
# 主菜单文本单独存一份: poke 会反复覆盖 TMPO, 而编号查询要一直能对着
# 主菜单原文查（下面好几处 loop 都要）。
MENU_TXT="$(mktemp -t xbd-srv-menu-XXXXXX)"
# 子菜单文本又是另一份: 查主菜单编号时不能被它覆盖掉（下面"危险项"那组
# 还要回头对主菜单查 7 个选项名）。
SUB_TXT="$(mktemp -t xbd-srv-sub-XXXXXX)"
# 子菜单盒子截出来的那一段（查子菜单内部编号时对着它查）。
BLK_TXT="$(mktemp -t xbd-srv-blk-XXXXXX)"
trap 'rm -f "$TMPO" "$MENU_TXT" "$SUB_TXT" "$BLK_TXT"' EXIT

ok()  { PASS=$((PASS+1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"
        [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
hasf() {
  if grep -qaE -- "$2" "$TMPO"; then ok "$1"
  else bad "$1" "${3:-找不到「$2」} 开头: $(head -c 150 "$TMPO" | tr '\n' ' ')"; fi
}
hasntf() {
  if grep -qaE -- "$2" "$TMPO"; then
    bad "$1" "${3:-不该出现「$2」} 实际: $(head -c 150 "$TMPO" | tr '\n' ' ')"
  else ok "$1"; fi
}
# 点一次菜单: feed 是喂给 read 的按键
poke() { # poke <说明> <超时秒> <按键...>
  local name="$1" tmo="$2"; shift 2
  printf '%b' "$*" | timeout "$tmo" bash "$REPO/xray-panel.sh" >"$TMPO" 2>&1
  local rc=$?
  if [ $rc -eq 124 ]; then bad "$name（不卡死）" "超时 ${tmo}s 没退出"
  else ok "$name（能退出, rc=$rc）"; fi
}

# 从菜单文本里现查某一项的编号, 别硬编码。
#
# 主菜单刚按用途重排过一次; 客户端那边的同类硬编码就出过事 ——
# 节点子菜单重排后测试里的 8) 从「浏览器拨号」变成了「删除节点」。
# 服务端这边 8) 是「安装 / 更新内核」, 点错虽然不删东西, 但断言会全部
# 悄悄变成"验的是另一个菜单", 比红更糟。
#
# 用 awk 而不是 sed: 选项名里有 `/`（安装 / 更新内核）, 拿 / 当分隔符
# 会把表达式拆坏, 结果抓不到编号却不报错。
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
# 必须做这层: 主菜单那一行 `9) 服务与配置  查询状态 / 校验并重载 / 查看客户端配置`
# 把子菜单三项的名字当**说明文字**写进去了 —— 直接对整个输出查
# 「查看客户端配置」会命中主菜单的 9, 敲进去还是在主菜单里打转。
# 子菜单标题只出现在子菜单盒子里, 且以「0) 返回」收尾, 两头夹出来才稳。
menu_block() {  # menu_block <含菜单的文本文件> <子菜单标题>
  awk -v title="$2" '
    { line = $0; gsub(/\033\[[0-9;]*m/, "", line) }
    seen && line ~ /^[[:space:]]*0\)[[:space:]]*(返回|退出)/ { print buf; exit }
    seen { buf = buf line "\n"; next }
    line ~ ("^[[:space:]]*" title "[[:space:]]*$") { seen = 1 }
  ' "$1"
}

printf '  仓库: %s\n' "$REPO"
printf '  时间: %s\n\n' "$(date '+%F %T')"

# ---------------------------------------------------------- 静态检查
printf '  \033[36m脚本静态检查\033[0m\n'
n=0
for f in xray-panel.sh xargo.sh VEVLRE.sh VEVLRE6.sh caddy.sh nginx.sh \
         ngcadall.sh Conversion.sh; do
  [ -f "$f" ] || { printf '    (缺少 %s)\n' "$f"; continue; }
  n=$((n+1))
  if bash -n "$f" 2>/dev/null; then ok "$f 语法通过"
  else bad "$f 语法通过" "$(bash -n "$f" 2>&1 | awk 'NR<=2' | tr '\n' ' ')"; fi
done
[ "$n" -gt 0 ] || bad "至少找到一个服务端脚本" "$REPO 下没有 .sh"

# 所有面板脚本都该有可执行位, 否则用户 ./xray-panel.sh 会 Permission denied
for f in xray-panel.sh xargo.sh; do
  [ -f "$f" ] && { [ -x "$f" ] && ok "$f 有可执行位" || bad "$f 有可执行位" "需要 chmod +x"; }
done

# ---------------------------------------------------------- 主菜单
printf '\n  \033[36m主菜单\033[0m\n'
poke "主菜单（按 0 退出）" 30 '0\n'
hasf "主菜单标题" "xrayls 管理脚本" ""
hasf "主菜单显示服务状态" "服务状态" ""
hasf "主菜单显示内核版本" "内核版本" ""
hasf "主菜单显示节点数量" "节点数量" ""

# 主菜单已按用途分组（原来是 21 项平铺一列）。这里断言的是**主菜单**上
# 应该看得见的东西；子菜单里的内容在下面分别点进去验。
for it in "节点" "分享" "站点与证书" "内核与服务" "维护" \
          "添加节点" "节点管理" "路由与出站" "分享管理" "分享服务" \
          "证书管理" "Nginx 站点管理" "安装 / 更新内核" "服务与配置" \
          "DNS 管理" "日志" "自检与体检"; do
  hasf "主菜单含「$it」" "$it" ""
done

# 子菜单内容: 分组之后这些能力挪进了子菜单，必须点进去还在
# 编号一律从主菜单文本里现查 —— 见 menu_idx 上面的说明。
# 注意「内核与服务」「维护」是**分组标题**, 不带编号; 要抓的是组里那一项
# （安装 / 更新内核 = 8, 自检与体检 = 12）。抓标题会得到空串。
printf '0\n' | timeout 30 bash "$REPO/xray-panel.sh" >"$MENU_TXT" 2>&1
M_ROUTE=$(menu_idx "$MENU_TXT" "路由与出站")
M_KERNEL=$(menu_idx "$MENU_TXT" "安装 / 更新内核")
M_SVC=$(menu_idx "$MENU_TXT" "服务与配置")
M_MAINT=$(menu_idx "$MENU_TXT" "自检与体检")
M_MISSING=""
for pair in "路由与出站:$M_ROUTE" "安装 / 更新内核:$M_KERNEL" \
            "服务与配置:$M_SVC" "自检与体检:$M_MAINT"; do
  [ -n "${pair#*:}" ] || M_MISSING="$M_MISSING ${pair%%:*}"
done
if [ -n "$M_MISSING" ]; then
  bad "主菜单编号能从选项名查到" "查不到:$M_MISSING —— 下面的子菜单断言会验错菜单"
else ok "主菜单编号从选项名查到（路由 $M_ROUTE / 内核 $M_KERNEL / 服务 $M_SVC / 维护 $M_MAINT）"; fi

poke "路由与出站子菜单" 30 "$M_ROUTE\n0\n0\n"
for it in "出站管理" "分流规则" "反向代理"; do
  hasf "路由与出站含「$it」" "$it" ""
done
poke "内核子菜单" 30 "$M_KERNEL\n0\n0\n"
for it in "安装 / 更新" "回退内核" "卸载内核"; do
  hasf "内核子菜单含「$it」" "$it" ""
done
poke "服务与配置子菜单" 30 "$M_SVC\n0\n0\n"
for it in "查询服务状态" "校验配置并重载" "查看客户端配置"; do
  hasf "服务与配置含「$it」" "$it" ""
done
poke "维护子菜单" 30 "$M_MAINT\n0\n0\n"
for it in "能力自检" "端口体检" "片段体检"; do
  hasf "维护含「$it」" "$it" ""
done

# 分发完整性: 菜单上有的选项, case 里必须都有对应分支
# 少了分支的话, 用户点了会静默什么都不发生。
missing=""
# ★ 菜单改用 ui_menu 之后, 原来按 ${GREEN}N.${PLAIN} 抓编号的写法会**一个都抓不到**,
#   于是这条检查永远是绿的 —— 空检查比没有检查更糟。这里改成抓 ui_menu 的编号。
grep -oE '^\s*ui_menu [0-9]+' xray-panel.sh 2>/dev/null | grep -oE '[0-9]+$' | sort -un | while read -r n; do
  grep -qE "^\s+${n}\)" xray-panel.sh || missing="$missing $n"
done
if [ -z "$missing" ]; then ok "菜单里每个编号都有 case 分支"
else bad "菜单里每个编号都有 case 分支" "缺:$missing"; fi

# ---------------------------------------------------------- 交互健壮性
printf '\n  \033[36m交互健壮性\033[0m\n'
poke "非法选项" 30 '99\n0\n'
hasf "非法选项有提示" "无效的选项" ""
hasntf "非法选项不会继续往下执行菜单项" "命令未找到"

# 空回车: 2.8 起主菜单把空回车当成"退出"（菜单提示里就这么写的：
# "回车 = 退出"）。所以这里验的是**干净退出**，不是提示无效选项 ——
# 要防的始终是"按空回车被踢出一堆报错"或"刷屏到超时"。
poke "空回车" 30 '\n'
hasntf "空回车干净退出（不刷报错）" "line [0-9]+: " 2>/dev/null || true
hasntf "空回车不刷屏" "请输入选项" 2>/dev/null || true

poke "EOF (直接关掉 stdin)" 30 ''
hasntf "stdin 关闭时干净退出（不刷错）" "line [0-9]+: read:" 2>/dev/null || true

# ---------------------------------------------------------- 只读菜单项
printf '\n  \033[36m只读菜单项（真正点进去）\033[0m\n'
# 「服务与配置」里的三项: 编号也从子菜单文本现查, 别记 1/2/3 ——
# 子菜单内部重排过一次, 记数字就等于把断言绑在排版上。
printf '%s\n0\n0\n' "$M_SVC" | timeout 45 bash "$REPO/xray-panel.sh" >"$SUB_TXT" 2>&1
menu_block "$SUB_TXT" "服务与配置" >"$BLK_TXT"
SVC_STATUS=$(menu_idx "$BLK_TXT" "查询服务状态")
SVC_RELOAD=$(menu_idx "$BLK_TXT" "校验配置并重载")
SVC_CLIENT=$(menu_idx "$BLK_TXT" "查看客户端配置")
for pair in "查询服务状态:$SVC_STATUS" "校验配置并重载:$SVC_RELOAD" "查看客户端配置:$SVC_CLIENT"; do
  [ -n "${pair#*:}" ] || bad "服务与配置里能找到「${pair%%:*}」" "抓不到编号, 下面点的会是别的项"
done

poke "服务与配置 → 查询服务状态 ($M_SVC,$SVC_STATUS)" 45 "$M_SVC\n$SVC_STATUS\n\n0\n"
if [ -s "$TMPO" ]; then ok "「查询服务状态」有内容"; else bad "「查询服务状态」有内容" "空"; fi

poke "服务与配置 → 查看客户端配置 ($M_SVC,$SVC_CLIENT)" 45 "$M_SVC\n$SVC_CLIENT\n\n0\n"
if [ -s "$TMPO" ]; then ok "「查看客户端配置」有内容"; else bad "「查看客户端配置」有内容" "空"; fi

# 「校验配置」只做校验不重启, 是安全可点的
poke "服务与配置 → 校验并重载 ($M_SVC,$SVC_RELOAD)" 90 "$M_SVC\n$SVC_RELOAD\n\n0\n"
if [ -s "$TMPO" ]; then ok "「校验配置」有内容"; else bad "「校验配置」有内容" "空"; fi

# 分组子菜单本身要能进能出
for pair in "$M_ROUTE:路由与出站" "$M_KERNEL:安装 / 更新内核" \
            "$M_MAINT:自检与体检"; do
  n="${pair%%:*}"; label="${pair#*:}"
  [ -n "$n" ] || continue
  poke "$label ($n) 能进能出" 30 "$n\n0\n0\n"
  if [ -s "$TMPO" ]; then ok "「$label」有内容"; else bad "「$label」有内容" "空"; fi
done

# ---------------------------------------------------------- 危险项：只验证能取消
printf '\n  \033[36m会改配置的菜单项（只验证能加载与安全取消）\033[0m\n'
# 这些项会 curl 远端脚本或写配置。我们只喂取消/空回车, 确认不会在无确认下执行。
# 注意: 这几项走 `bash <(curl ...conf/xxx.sh)`, 拿的是 GitHub 上的版本。
# 本地改完没推送之前, 这里会超时 —— 那是预期结果, 不是回归。推完再跑一次就绿了。
for label in "添加节点" "节点管理" "分享管理" "分享服务" "证书管理" \
             "Nginx 站点管理" "DNS 管理"; do
  n=$(menu_idx "$MENU_TXT" "$label")
  if [ -z "$n" ]; then
    bad "主菜单里能找到「$label」" "抓不到编号, 该项这轮没验到"
    continue
  fi
  poke "$label ($n) 能加载并安全取消" 45 "$n\n\n\n\n0\n"
done

# ---------------------------------------------------------- 服务端运行状态
printf '\n  \033[36m服务端运行状态\033[0m\n'
if systemctl is-active --quiet xrayls.service 2>/dev/null; then ok "xrayls.service 运行中"
else bad "xrayls.service 运行中" "$(systemctl is-active xrayls.service 2>&1)"; fi

conf_dir=$(systemctl cat xrayls.service 2>/dev/null | grep -oE '\-confdir +[^ ]+' | awk '{print $2}')
if [ -n "$conf_dir" ] && [ -d "$conf_dir" ]; then
  ok "xrayls 配置目录存在: $conf_dir"
  cnt=$(ls "$conf_dir"/*.json 2>/dev/null | wc -l)
  [ "$cnt" -gt 0 ] && ok "配置片段 $cnt 个" || bad "配置片段" "目录里没有 .json"
  # 每个片段都该是合法 JSON —— 坏一个 xrayls 就起不来
  badj=0
  for f in "$conf_dir"/*.json; do
    [ -f "$f" ] || continue
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null || {
      printf '        %s 不是合法 JSON\n' "$(basename "$f")"; badj=$((badj+1)); }
  done
  [ "$badj" -eq 0 ] && ok "全部配置片段是合法 JSON" || bad "全部配置片段是合法 JSON" "$badj 个坏了"
else
  printf '    (xrayls 未配置 confdir, 跳过)\n'
fi

# ---------------------------------------------------------- 汇总
printf '\n  %s\n' "────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[32m服务端全部通过: %d 项\033[0m\n\n' "$PASS"; exit 0
fi
printf '  \033[32m通过 %d\033[0m, \033[31m失败 %d\033[0m\n' "$PASS" "$FAIL"
printf '  失败项:\n'
for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
printf '\n'
exit 1
