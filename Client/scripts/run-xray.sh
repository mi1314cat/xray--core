#!/usr/bin/env bash
# 由 xray-client.service 调用。唯一实例，同时提供两个 LAN 入站：
#   SOCKS :1080   +   HTTP :10809（+ loopback HTTP :10808）
#
# Browser Dialer 是"出站的一种拨号方式"，与入站无关。是否带 XRAY_BROWSER_DIALER
# **由当前节点的开关决定**，而不是无条件带上：
#
#   * 该节点要用浏览器（use_browser=on，或默认且协议支持）-> 带上，TLS 交给 Chromium；
#   * 该节点不用浏览器（use_browser=off）-> **不带**，Xray 自己完成 TLS。
#
# 为什么必须这样：只要进程带着这个环境变量，xhttp/websocket 出站就会被交给浏览器，
# 而 browser_dialer.dialTask() 是 `conn = <-conns` —— **没有超时**。Chromium 一停，
# 那些节点不会报错、不会回退，而是永久挂住。
# 所以"关掉浏览器"必须同时让进程不再声明这个能力，否则用户根本关不掉（实测踩过）。
#
# 其他节点（tcp / reality / hysteria2 …）本来就会忽略该变量，带不带都一样。
set -euo pipefail

PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
DIST="$PREFIX/xbd-dist"
XRAY="$PREFIX/bin/xray"

[ -x "$XRAY" ] || { echo "缺少 Xray 二进制: $XRAY" >&2; exit 1; }
NODE="$PREFIX/nodes/current"
[ -e "$NODE" ] || { echo "尚未选择节点：先用 xbd node add \"<uri>\"" >&2; exit 1; }

cfg() { awk -F= -v k="^$1=" '$0 ~ k {print $2; exit}' "$PREFIX/config/ports.env" 2>/dev/null || true; }
PORT_NORMAL=$(cfg PORT_NORMAL);     PORT_NORMAL=${PORT_NORMAL:-1080}
PORT_HTTP=$(cfg PORT_HTTP);         PORT_HTTP=${PORT_HTTP:-10808}
PORT_LAN_HTTP=$(cfg PORT_LAN_HTTP); PORT_LAN_HTTP=${PORT_LAN_HTTP:-10809}
LISTEN_ADDR=$(cfg LISTEN_ADDR);     LISTEN_ADDR=${LISTEN_ADDR:-127.0.0.1}
DIALER_ADDR=$(cfg DIALER_ADDR);     DIALER_ADDR=${DIALER_ADDR:-127.0.0.1:18081}
# DNS 模式存独立文件，面板上能改。读不到就当 off（=不接管，行为等同改造前），
# 不能默认给一个"更安全"的模式然后让用户以为自己已经防泄露了。
DNS_MODE=$(awk -F= '$1=="DNS_MODE" {print $2; exit}' "$PREFIX/config/dns.env" 2>/dev/null || true)
case "$DNS_MODE" in off|standard|strict) ;; *) DNS_MODE=off ;; esac

# 这个节点是否要用浏览器 —— 判定只有 compat.py 一个来源，三处（本脚本、
# health-check.sh、actions.sh）共用，避免各判各的导致"该不该跑 Chromium"打架。
WANT_BD=$(python3 "$DIST/lib/compat.py" want-bd "$NODE" 2>/dev/null || echo no)
[ "$WANT_BD" = "yes" ] || WANT_BD=no

mkdir -p "$PREFIX/runtime" "$PREFIX/logs"
OUT="$PREFIX/runtime/xray-client.json"

# 普通模式用多出站配置：所有节点常驻，切换只改 balancer 的选择，不重启。
# 浏览器拨号模式保持单节点 —— XRAY_BROWSER_DIALER 是进程级的，一个 env 会让
# 所有出站都去抢浏览器的连接额度，而观测器一探测就把额度耗光。
GEN_ARGS=(
  --output "$OUT" --mode normal
  --listen "$LISTEN_ADDR"
  --port-normal "$PORT_NORMAL"
  --http-port "$PORT_HTTP" --lan-http-port "$PORT_LAN_HTTP"
  --api-port "${XBD_API_PORT:-18085}"
  --logs "$PREFIX/logs" --loglevel "${XBD_LOGLEVEL:-warning}"
  --dns "$DNS_MODE"
  --validate-with "$XRAY"
)
# 多出站默认关闭。
#
# 开启后所有节点常驻一份配置，切换节点不用重启；代价是它们共享同一份配置 ——
# 任何一个节点构建失败，整份配置就通不过校验。多出站内部会剔除坏节点，
# 再加生成失败自动降级，起不来的情况堵住了，但故障域仍是"全体"而非"那一个"。
#
# 默认单节点：切换节点要重启一次（连接断 1-2 秒），换来坏的只是那一个节点。
# 节点少、切换不频繁时这个交换划算；节点多且经常切再开。
#
# 这里没有 source lib/core.sh（那份依赖交互式环境），所以直接读同一个文件。
# 路径必须和 core.sh 里的 XBD_MULTI_ENV 一致，判断逻辑也必须一致 ——
# 散在两处各判一次，迟早会出现"面板说是多出站、实际是单节点"。
MULTI=$(awk -F= '$1=="MULTI_OUTBOUND" {print $2; exit}' "$PREFIX/config/multi.env" 2>/dev/null || true)
case "$MULTI" in on|1|true) MULTI=on ;; *) MULTI=off ;; esac
# 实际跑的是哪种模式。多出站关着、或降级发生过, 都是 single。
ACTUAL_MODE="$([ "$MULTI" = "on" ] && echo multi || echo single)"
if [ "$WANT_BD" = "yes" ]; then
  GEN_ARGS+=(--node "$NODE")          # Browser Dialer 只能单节点
  [ "$MULTI" = "on" ] && echo "browser-dialer: 多出站已开启，本次仍走单节点（拨号必须单节点）" >&2
elif [ "$MULTI" = "on" ]; then
  GEN_ARGS+=(--all-nodes --nodes-dir "$PREFIX/nodes" --node "$NODE")
else
  GEN_ARGS+=(--node "$NODE")
fi

python3 "$DIST/lib/genconfig.py" "${GEN_ARGS[@]}" >/tmp/.xbd_gen.$$ 2>&1
GEN_RC=$?
if [ "$GEN_RC" -ne 0 ] && [ "$MULTI" = "on" ]; then
  # 多出站生成失败 → 降级成单节点再试一次。
  #
  # 这条路径由 systemd 拉起，是"重启后能不能起来"的最后一关。多出站把所有
  # 节点塞进同一份配置，一处不通整份就废；剔除坏节点只挡得住"节点写错"，
  # 挡不住内核升级、字段改名这类整体性问题。到这一步还没有可用配置的话，
  # 用户手里就只剩一个完全起不来的客户端了 —— 先让当前节点跑起来。
  echo "多出站配置生成失败，降级为单节点" >&2
  head -5 /tmp/.xbd_gen.$$ >&2
  GEN_ARGS=(--node "$NODE" --dns "$DNS_MODE")
  python3 "$DIST/lib/genconfig.py" "${GEN_ARGS[@]}" >/tmp/.xbd_gen.$$ 2>&1
  GEN_RC=$?
  # 用独立的标志表示"现在实际是单节点"。之前借用 WANT_BD 来表达这件事，
  # 而 WANT_BD 的语义是"这个节点要浏览器拨号" —— 降级之后拨号标志并不会变成
  # 是，借用它会让后面 export XRAY_BROWSER_DIALER 跟着一起错。
  ACTUAL_MODE=single
  if [ "$GEN_RC" -eq 0 ]; then
    echo "已降级为单节点：切换节点需重启" >&2
  fi
fi
if [ "$GEN_RC" -ne 0 ]; then
  echo "配置生成失败:" >&2; cat /tmp/.xbd_gen.$$ >&2; rm -f /tmp/.xbd_gen.$$; exit 1
fi
rm -f /tmp/.xbd_gen.$$

# 把"实际生效的是哪种模式"落成一个文件。
#
# 开关说开、运行配置里却没有 balancer（或者反过来）是会出现的不一致状态 ——
# 面板、菜单、xbd multi status 都要知道真实情况，而不是只看开关说什么。
# 只看开关的话，用户看到"已开启"却发现切换仍然要重启，只会以为面板坏了。
printf '%s\n' "$ACTUAL_MODE" > "$PREFIX/runtime/multi.actual" 2>/dev/null || true

# 校验失败绝不启动：宁可起不来，也不带着坏配置上线
"$XRAY" run -test -config "$OUT" >/dev/null 2>&1 \
  || { echo "生成的配置未通过校验: $OUT" >&2; exit 1; }

if [ "$WANT_BD" = "yes" ]; then
  export XRAY_BROWSER_DIALER="$DIALER_ADDR"
  echo "browser-dialer: 启用（该节点使用浏览器完成 TLS）" >&2
  exec "$XRAY" run -config "$OUT"
fi

echo "browser-dialer: 关闭（该节点由 Xray 自己完成 TLS）" >&2

# 多出站模式要在起来之后把 balancer 钉到用户选的那个节点。
# 观测器会按健康度自动选，而"用户明确选了哪个"必须优先于"哪个看起来更快"。
# 这里不能再 exec —— API 得先起来才能调，所以起后台、等 API、把选择钉上、再 wait。
# 信号转发不能省: systemd stop 发的是 SIGTERM 给本脚本, 不转发的话 Xray 会
# 变成孤儿进程, 端口一直被占住, 下次启动报 address already in use。
"$XRAY" run -config "$OUT" &
XPID=$!
trap 'kill -TERM "$XPID" 2>/dev/null' TERM INT
trap 'kill -KILL "$XPID" 2>/dev/null' EXIT

API="127.0.0.1:${XBD_API_PORT:-18085}"
for _ in $(seq 1 40); do          # 最多等 4 秒, 一步 100ms
  if "$XRAY" api lso --server="$API" >/dev/null 2>&1; then
    # 从生成结果里取 current_tag; 取不到就跳过 —— 此时行为退回"自动选",
    # 总比等不到 API 就不敢启动强。
    CTAG=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("current_tag") or "")' \
           "$PREFIX/runtime/xray-gen.json" 2>/dev/null)
    if [ -n "$CTAG" ]; then
      "$XRAY" api bo --server="$API" -b xbd-bal "$CTAG" >/dev/null 2>&1 \
        && echo "已选中节点: $CTAG" >&2
    fi
    break
  fi
  kill -0 "$XPID" 2>/dev/null || break
  sleep 0.1
done

wait "$XPID"
