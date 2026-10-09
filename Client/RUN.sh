#!/usr/bin/env bash
# ============================================================================
#  Xray Client —— 一键安装（在解压后的目录里运行这一个脚本就够了）
# ============================================================================
#      tar xzf xbd-client.tar.gz
#      cd xbd-client
#      sudo bash RUN.sh
#
#  就这么简单。RUN.sh 会自己检查环境、装依赖、装 Xray、分配端口、
#  建 systemd 服务、启动、然后问你要节点链接。
#
#  可选参数（一般不需要）：
#      --vless "<链接>"   直接带上节点，不问
#      --yes              全自动，不交互
#      --no-start         只安装不启动
#      --prefix <目录>    自定义安装目录（默认 /opt/xray-browser-dialer）
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"

if [ -t 1 ]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; O=$'\033[0m'
else R=""; G=""; Y=""; B=""; D=""; O=""; fi
dim()  { printf '%s%s%s\n' "${D:-}" "$*" "$O"; }
ok()   { printf '%s✓%s %s\n' "$G" "$O" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$O" "$*"; }
bad()  { printf '%s✗%s %s\n' "$R" "$O" "$*"; }
die()  { bad "$*"; exit 1; }

echo
printf '%s==========================================%s\n' "$B" "$O"
printf ' Xray Client 安装\n'
printf '%s==========================================%s\n' "$B" "$O"
echo

[ "$(id -u)" -eq 0 ] || die "需要 root 权限：请用 sudo bash RUN.sh"
command -v python3 >/dev/null 2>&1 || die "缺少 python3（apt install python3 / dnf install python3）"
[ -f "$HERE/bin/xbd" ] || die "文件不完整：找不到 bin/xbd（请重新解压）"

# 安装到固定目录，之后统一用 xbd 命令管理
mkdir -p "$PREFIX"
if [ "$HERE" != "$PREFIX" ]; then
  for d in bin lib service scripts docs tools; do
    [ -d "$HERE/$d" ] && mkdir -p "$PREFIX/$d" && cp -a "$HERE/$d/." "$PREFIX/$d/" 2>/dev/null || true
  done
  [ -f "$HERE/VERSION" ] && cp "$HERE/VERSION" "$PREFIX/VERSION"
  ok "文件已复制到 $PREFIX"
fi

# 运行时状态目录：**包里刻意不带**（它们不是发布内容），但必须在这里建出来。
# 漏建的后果实测过：runtime/ 缺失 → 生成配置时 FileNotFoundError →
# `xbd start` 直接报「配置生成失败，这是致命的」，即"装完用不了"。
#   runtime/   生成的 xray 配置（genconfig 的落点）
#   logs/      Xray 的 access/error 日志目录
#   generated/ xbd export 的导出目录
#   config/ nodes/ backup/  端口、面板令牌、节点、备份
mkdir -p "$PREFIX"/{config,logs,nodes,generated,runtime,backup}

# 权限必须显式设定（umask 会让 systemd 报 203/EXEC）
chmod 0755 "$PREFIX/bin/xbd" 2>/dev/null || true
chmod 0755 "$PREFIX"/scripts/*.sh "$PREFIX"/lib/*.sh 2>/dev/null || true
find "$PREFIX/lib" -name '*.py' -exec chmod 0755 {} + 2>/dev/null || true
find "$PREFIX/tools" -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true

# xbd 需要从 xbd-dist 找到 lib（与自解压版目录约定一致）
mkdir -p "$PREFIX/xbd-dist"
cp -a "$PREFIX/lib/." "$PREFIX/xbd-dist/lib/" 2>/dev/null || true
cp -a "$PREFIX/bin/." "$PREFIX/xbd-dist/bin/" 2>/dev/null || true
cp -a "$PREFIX/tools/." "$PREFIX/xbd-dist/tools/" 2>/dev/null || true
[ -f "$PREFIX/VERSION" ] && cp "$PREFIX/VERSION" "$PREFIX/xbd-dist/VERSION"
find "$PREFIX/xbd-dist" -name '*.py' -exec chmod 0755 {} + 2>/dev/null || true

# 让 xbd 在任意位置可用。只在默认前缀时创建：
# 自定义 prefix（测试或多实例）不应覆盖全局命令。
if [ "$PREFIX" = "/opt/xray-browser-dialer" ]; then
  cat > /usr/local/bin/xbd <<EOF
#!/usr/bin/env bash
exec $PREFIX/bin/xbd "\$@"
EOF
  chmod 0755 /usr/local/bin/xbd
  ok "已安装命令 xbd"
else
  dim "  自定义前缀，跳过全局 xbd 命令（直接用 $PREFIX/bin/xbd）"
fi

# xbd install 只认 --no-start / --vless；过滤掉其余部署层参数
INSTALL_ARGS=()
for a in "$@"; do
  case "$a" in
    --no-start|--vless) INSTALL_ARGS+=("$a") ;;
    --yes|-y|--prefix) : ;;
    *) [ "${a#--}" = "$a" ] && INSTALL_ARGS+=("$a") || : ;;
  esac
done
# --vless 的值要跟着保留
FINAL_ARGS=()
i=0
while [ $i -lt $# ]; do
  eval "cur=\${$((i+1))}"
  if [ "$cur" = "--vless" ]; then
    eval "val=\${$((i+2))}"
    FINAL_ARGS+=(--vless "$val"); i=$((i+2)); continue
  fi
  if [ "$cur" = "--no-start" ]; then FINAL_ARGS+=(--no-start); fi
  i=$((i+1))
done

echo
"$PREFIX/bin/xbd" install ${FINAL_ARGS[@]+"${FINAL_ARGS[@]}"}
rc=$?
[ "$rc" -ne 0 ] && exit "$rc"


# ================================================================
# 入口分发 —— 与 sing-box-core / mihomo 的 install.sh 保持同一种交互
#
# 进去先选角色，而不是让人自己在这个脚本里猜现在是干什么的。同时支持命令行
# 直传（bash RUN.sh client），免交互 —— 自动化和双端验证都靠它。
# ================================================================
do_client() {
  case "${1:-}" in
    menu) exec "$PREFIX/bin/xbd" menu ;;
    "")   # 装完直接进菜单面板
           printf '\n'
           exec "$PREFIX/bin/xbd" menu ;;
    *)    exec "$PREFIX/bin/xbd" "${@}" ;;
  esac
}

do_server() {
  # Xray 客户端这一侧暂时没有服务端。留这个分支是为了跟 SB/M 的结构对齐，
  # 将来加服务端时不用再改入口。真要用却不存在，要说清楚而不是静默退出。
  if [ -x "$PREFIX/bin/xbd-server" ]; then
    exec "$PREFIX/bin/xbd-server" "${@}"
  fi
  printf '\n'
  printf '  \033[33mXray 客户端这一版还没有服务端功能。\033[0m\n\n'
  printf '  客户端功能（含 Web 面板、节点管理、配置分发）都在客户端这一侧。\n'
  printf '  想管理服务端，请用 sing-box-core 或 mihomo 那边。\n\n'
  exit 1
}

MODE="${1:-}"
if [ -z "$MODE" ]; then
  clear 2>/dev/null || true
  printf '\033[32mXray Client 一键管理\033[0m\n'
  printf -- '----------------------\n'
  printf '\033[32m1.\033[0m 服务端 (暂未提供)\n'
  printf '\033[32m2.\033[0m 客户端 (LAN SOCKS/HTTP + Web 面板 + 配置分发)\n'
  printf '\033[32m0.\033[0m 退出\n'
  printf -- '----------------------\n'
  read -r -p '请输入选项 [0-2]: ' MODE || exit 0
fi
case "$MODE" in
  1|server) shift; do_server "${@:-}" ;;
  2|client) shift; do_client "${@:-}" ;;
  0)        exit 0 ;;
  *)        printf '无效选项 %s\n' "$MODE"; exit 1 ;;
esac

