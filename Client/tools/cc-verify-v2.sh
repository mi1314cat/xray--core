#!/usr/bin/env bash
# ============================================================================
#  CC 实测台（v2 接入验收）—— 在 CC（192.168.1.178）上跑
#
#  做四件事，**全部只写 /tmp**：
#     1. 把发布包解到 /tmp/xbd-v2，用生产机上已装的节点/配置做只读副本，
#        跑 `xbd node list`、节点卡片、回滚开关、want-bd 一致性；
#     2. 面板（临时端口 + 令牌，只读 GET）；
#     3. 双跑对比（旧判定 vs compat vs 合并）；
#     4. 真实链路：reality / hysteria2 / xhttp 三种节点，以及
#        XHTTP × mux.cool 的**本机回环**（服务端也在 /tmp）。
#
#  纪律：不写 /opt/xray-browser-dialer 的任何文件，不启停任何生产服务。
#        需要的只有生产机上的 **xray 二进制**（软链过去只读使用）与节点文件副本。
#
#  用法:  scp Client/xbd-client.tar.gz 到 /tmp，然后
#         bash cc-verify-v2.sh             # 1~3
#         bash cc-verify-v2.sh --loop      # 追加第 4 项（会起临时内核进程）
#  收尾:  rm -rf /tmp/xbd-v2 /tmp/xbd-loop /tmp/xbd-logs /tmp/xbd-client.tar.gz
# ============================================================================
set -uo pipefail
T=/tmp/xbd-v2
PROD=/opt/xray-browser-dialer

rm -rf "$T"; mkdir -p "$T"
tar xzf /tmp/xbd-client.tar.gz -C "$T" || exit 1
mkdir -p "$T/xbd-dist"
cp -a "$T/lib" "$T/xbd-dist/lib"; cp -a "$T/bin" "$T/xbd-dist/bin"
cp -a "$T/tools" "$T/xbd-dist/tools"; cp -a "$T/VERSION" "$T/xbd-dist/VERSION"
mkdir -p "$T/bin"; [ -e "$T/bin/xray" ] || ln -s "$PROD/bin/xray" "$T/bin/xray"
cp -a "$PROD/nodes" "$T/nodes" 2>/dev/null
mkdir -p "$T/runtime"; cp -a "$PROD/runtime/xray-client.json" "$T/runtime/" 2>/dev/null
cp -a "$PROD/runtime/xray-gen.json" "$T/runtime/" 2>/dev/null
mkdir -p "$T/config"; cp -a "$PROD/config/." "$T/config/" 2>/dev/null
export XBD_PREFIX="$T"
XBD="$T/bin/xbd"


# ---------------------------------------------------------------------------
# ① 环境 / 列表 / 双跑 / 回滚 / want-bd / 卡片
# ---------------------------------------------------------------------------
echo "===== 0 · 环境 ====="
echo "prefix=$T  内核=$("$T/bin/xray" version 2>/dev/null | sed -n 1p)"
python3 "$T/lib/compat2.py" version
echo
echo "===== 1 · xbd node list（新判定） ====="
bash "$XBD" node list 2>&1
echo
echo "===== 2 · 每个真实节点：旧 vs 新 vs 合并 ====="
python3 "$T/tools/dualkernel-compare.py" "$T/tools/compat-corpus.json" "$T/nodes" 2>&1
echo
echo "===== 3 · 回滚开关（XBD_COMPAT_ENGINE=legacy）必须回到旧判定 ====="
XBD_COMPAT_ENGINE=legacy python3 "$T/lib/compat.py" json "$T/nodes/current" 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("engine=",(d.get("engine") or {}).get("kernel","(legacy)"),"xray=",d["xray"]["overall"],"dialer=",d["dialer"]["overall"])'
python3 "$T/lib/compat.py" json "$T/nodes/current" 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("engine=",(d.get("engine") or {}).get("kernel","(legacy)"),"xray=",d["xray"]["overall"],"dialer=",d["dialer"]["overall"],"verdict_source=",(d.get("engine") or {}).get("verdict_source"))'
echo
echo "===== 4 · want-bd（浏览器拨号的唯一入口）必须一致 ====="
for f in "$T"/nodes/node-*.json; do
  a=$(python3 "$T/lib/compat.py" want-bd "$f" 2>/dev/null)
  b=$(XBD_COMPAT_ENGINE=legacy python3 "$T/lib/compat.py" want-bd "$f" 2>/dev/null)
  printf '  %-46s v2=%-4s legacy=%-4s %s\n' "$(basename "$f")" "$a" "$b" \
    "$([ "$a" = "$b" ] && echo SAME || echo '*** DIFF ***')"
done
echo
echo "===== 5 · 节点卡片（xbd node check 的文案路径） ====="
python3 "$T/lib/compat.py" render "$T/nodes/current" 2>/dev/null > /tmp/xbd-render.txt; sed -n "1,30p" /tmp/xbd-render.txt
echo
echo "===== 7 · 真实链接（RN 产出的三条 + 生产 xhttp 形）过一遍 ====="
python3 - "$T" <<'PY'
import importlib.util, json, os, sys
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("c2", os.path.join(T, "lib", "compat2.py"))
c2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(c2)
spec = importlib.util.spec_from_file_location("nd", os.path.join(T, "lib", "node.py"))
nd = importlib.util.module_from_spec(spec); spec.loader.exec_module(nd)
URIS = [
 ("RN-batch-Reality(25000)", "vless://11111111-2222-3333-4444-555555555555@107.173.154.178:25000?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apps.apple.com&fp=chrome&pbk=uMcVRoEWeMAwPaj6e3jSVCZfbl-gj37MH9_XI9tL5wY&sid=58896ecc5f8bf710&type=tcp#RN-Reality"),
 ("RN-batch-Trojan+REALITY(25001)", "trojan://pw123456@107.173.154.178:25001?security=reality&sni=apps.apple.com&fp=chrome&pbk=uMcVRoEWeMAwPaj6e3jSVCZfbl-gj37MH9_XI9tL5wY&sid=58896ecc5f8bf710&type=tcp#RN-TrojanReality"),
 ("RN-batch-Hysteria2(25002/udp)", "hysteria2://pw123456@107.173.154.178:25002?sni=apps.apple.com&alpn=h3&insecure=0#RN-Hysteria2"),
 ("RN-生产-xhttp-04(pin)", "vless://u@cloudflare.com:22726?encryption=none&security=tls&sni=cloudflare.com&type=xhttp&path=/&ech=AGH+DQBdAAAgACCRE8kdV65r7OZoo9WgdkRM44Te7b/73CcbZQOJfFgq&pinSHA256=deadbeef#RN-xhttp04"),
 ("RN-真mKCP(已移除字段)", "vless://399ce595-894d-4d40-add1-7d87f1a3bd10@qv2ray.net:41971?type=kcp&headerType=wireguard&seed=69f04be3-d64e-45a3-8550-af3172c63055#RN-mKCP-seed"),
]
print(f"| 链接 | 旧判定 | compat | 合并 | 来源 | 原因码/损失 |")
print("|---|---|---|---|---|---|")
for name, u in URIS:
    try:
        n = nd.parse_node(u)
    except Exception as e:
        print(f"| {name} | (node.py 解析失败: {e}) | | | | |"); continue
    r = c2.compare(n)
    extra = ",".join(r["reason_codes"] or []) + (" 丢:" + ",".join(map(str, r["losses"])) if r["losses"] else "")
    print(f"| {name} | {r['legacy']} | {r['compat']} | {r['merged']} | {r['verdict_source']} | {extra or '-'} |")
    print(f"    raw_uri={'保留' if r['raw_uri'] else '（无，非 URI 来源）'}  extensions={r['extensions']}")
PY
echo
echo "===== 8 · 清理核对（/tmp 之外没有被动过） ====="
ls -la "$T" > /tmp/xbd-ls.txt; sed -n "1,5p" /tmp/xbd-ls.txt
echo "production mtime check:"
ls -la --time-style=+%F_%T "$PROD/nodes" > /tmp/xbd-ls2.txt; sed -n "1,3p" /tmp/xbd-ls2.txt

# ---------------------------------------------------------------------------
# ② 面板（带令牌）
# ---------------------------------------------------------------------------
T=/tmp/xbd-v2
PROD=/opt/xray-browser-dialer
export XBD_PREFIX="$T"
X="$T/bin/xray"
PORT=39971

echo "解包版本: $(cat "$T/VERSION")"

echo "===== 6b · 面板（带令牌，只读 GET） ====="
TOK=$(awk -F= '$1=="PANEL_TOKEN"{print $2}' "$T/config/panel.env" 2>/dev/null)
python3 "$T/lib/web/panel.py" --host 127.0.0.1 --port 18099 --token "$TOK" > /tmp/xbd-panel.log 2>&1 &
PP=$!
sleep 3
curl -s -m 10 -H "X-Panel-Token: $TOK" -o /tmp/xbd-panel.html \
     -w "GET / → http=%{http_code} bytes=%{size_download}\n" http://127.0.0.1:18099/
curl -s -m 20 -H "X-Panel-Token: $TOK" -o /tmp/xbd-state.json \
     -w "GET /api/state → http=%{http_code} bytes=%{size_download}\n" http://127.0.0.1:18099/api/state
python3 - <<'PY'
import json
try:
    d = json.load(open("/tmp/xbd-state.json"))
except Exception as e:
    print("  state 读不到:", e); raise SystemExit
st = d.get("state") or d
nodes = st.get("nodes") or []
print(f"  面板状态里的节点数: {len(nodes)}")
for n in nodes:
    c = n.get("compat") or {}
    k = c.get("kernel") or {}
    eng = c.get("engine") or {}
    print(f"    {str(n.get('name'))[:26]:<28} xray={(c.get('xray') or {}).get('overall','-'):<22}"
          f" kernel={str(k.get('status','-')):<22} src={str(eng.get('verdict_source','-'))[:30]:<32}"
          f" raw_uri={'有' if k.get('raw_uri') else '无'} ext={len(k.get('extensions') or [])}")
PY
sed -n "1,2p" /tmp/xbd-panel.log
kill $PP 2>/dev/null; sleep 1; kill -9 $PP 2>/dev/null

echo


# ---------------------------------------------------------------------------
# ③ 真实链路
# ---------------------------------------------------------------------------
T=/tmp/xbd-v2
PROD=/opt/xray-browser-dialer
export XBD_PREFIX="$T"
X="$T/bin/xray"
mkdir -p /tmp/xbd-logs

run_one() {  # run_one <名字> <节点文件> <端口> [genconfig 额外参数...]
  local name="$1" nf="$2" port="$3"; shift 3
  local out="/tmp/xbd-run-$name.json" log="/tmp/xbd-logs/$name.log"
  echo "--- $name  ($(basename "$nf"))  端口 $port"
  if ! python3 "$T/lib/genconfig.py" --node "$nf" --mode normal --output "$out" \
        --listen 127.0.0.1 --port-normal "$port" --logs /tmp/xbd-logs --loglevel warning "$@" \
        > /tmp/xbd-gen-$name.log 2>&1; then
    echo "    genconfig 失败: $(python3 -c "import sys;print(' '.join(open(sys.argv[1]).read().splitlines()[:2]))" /tmp/xbd-gen-$name.log)"; return
  fi
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1])); o=[x for x in d["outbounds"] if x.get("tag")=="proxy"][0]
ss=o.get("streamSettings",{})
print("    配置: network=%s method=%s security=%s mux=%s pin=%s ech=%s" % (
  ss.get("network"), ss.get("method"), ss.get("security"),
  json.dumps(o.get("mux")), bool((ss.get("tlsSettings") or {}).get("pinnedPeerCertSha256")),
  (ss.get("tlsSettings") or {}).get("echConfigList")))' "$out"
  "$X" run -config "$out" > "$log" 2>&1 &
  local pid=$!
  sleep 3
  if ! kill -0 $pid 2>/dev/null; then echo "    内核没起来:"; tail -3 "$log" | sed 's/^/      /'; return; fi
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 --socks5-hostname 127.0.0.1:$port \
         https://www.gstatic.com/generate_204 2>/dev/null)
  echo "    curl → http_code=${code:-000}"
  echo "    内核日志:"; tail -6 "$log" | sed 's/^/      /'
  kill $pid 2>/dev/null; sleep 1; kill -9 $pid 2>/dev/null; rm -f "$out"
}

echo "===== 11 · 真实链路（客户端 genconfig → 内核 → curl 204） ====="
run_one reality-nomux  "$T/nodes/node-001-ccsmreality-01.json"  39981 --no-mux
run_one reality-mux    "$T/nodes/node-001-ccsmreality-01.json"  39982
run_one xhttp-nomux    "$T/nodes/node-001-ccsxvless-xhttp-01.json" 39983 --no-mux
run_one xhttp-mux      "$T/nodes/node-001-ccsxvless-xhttp-01.json" 39984
run_one hysteria2      "$T/nodes/node-001-ccsmhysteria2-01.json" 39985
echo
echo "===== 12 · 生产实例现在跑的是哪个节点（只读） ====="
echo "current → $(readlink -f $PROD/nodes/current)"
python3 -c '
import json
d=json.load(open("/opt/xray-browser-dialer/runtime/xray-client.json"))
for o in d.get("outbounds",[])[:2]:
    print("  生产出站:", o.get("tag"), o.get("protocol"), "mux=", json.dumps(o.get("mux")))' 2>/dev/null

# ---------------------------------------------------------------------------
# ④ XHTTP × mux 回环
# ---------------------------------------------------------------------------
T=/tmp/xbd-v2
export XBD_PREFIX="$T"
X="$T/bin/xray"
W=/tmp/xbd-loop
rm -rf "$W"; mkdir -p "$W/logs"

echo "===== 13 · XHTTP 回环（服务端在 /tmp，客户端用 genconfig 生成） ====="
UUID="11111111-2222-3333-4444-555555555555"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/key.pem" -out "$W/cert.pem" \
    -days 2 -subj "/CN=loop.test" >/dev/null 2>&1 || { echo "证书生成失败"; exit 1; }
PINF=$(openssl x509 -in "$W/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')
echo "自签证书 sha256(pin): ${PINF:0:24}…"

cat > "$W/server.json" <<EOF
{"log":{"loglevel":"warning"},
 "inbounds":[{"tag":"in","listen":"127.0.0.1","port":39990,"protocol":"vless",
   "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
   "streamSettings":{"network":"xhttp","security":"tls",
     "xhttpSettings":{"path":"/x"},
     "tlsSettings":{"certificates":[{"certificateFile":"$W/cert.pem","keyFile":"$W/key.pem"}]}}}],
 "outbounds":[{"protocol":"freedom"}]}
EOF
"$X" run -config "$W/server.json" > "$W/logs/server.log" 2>&1 &
SPID=$!
sleep 2
kill -0 $SPID 2>/dev/null && echo "临时 XHTTP 服务端已起（127.0.0.1:39990）" || { echo "服务端没起来:"; tail -3 "$W/logs/server.log"; exit 1; }

cat > "$W/node.json" <<EOF
{"name":"loop-xhttp","protocol":"vless","address":"127.0.0.1","port":39990,
 "uuid":"$UUID","transport":"xhttp","transport_raw":"xhttp","security":"tls",
 "sni":"loop.test","host":"","path":"/x","mode":"auto","encryption":"none",
 "alpn":"","fingerprint":"","allow_insecure":false,"pinned_cert_sha256":"$PINF",
 "mux":false,"source":"local-proxy","raw_params":{}}
EOF

for variant in "nomux:关（--no-mux）" "mux:开（默认）"; do
  key="${variant%%:*}"; label="${variant#*:}"
  port=$([ "$key" = "mux" ] && echo 39993 || echo 39992)
  out="$W/client-$key.json"
  extra=""; [ "$key" = "nomux" ] && extra="--no-mux"
  python3 "$T/lib/genconfig.py" --node "$W/node.json" --mode normal --output "$out" \
      --listen 127.0.0.1 --port-normal "$port" --logs "$W/logs" --loglevel info $extra \
      > "$W/logs/gen-$key.log" 2>&1 || { echo "  [$label] genconfig 失败"; cat "$W/logs/gen-$key.log"; continue; }
  echo "--- mux $label"
  python3 -c '
import json,sys
o=[x for x in json.load(open(sys.argv[1]))["outbounds"] if x.get("tag")=="proxy"][0]
print("    mux 写进配置:", json.dumps(o.get("mux")), " network=", o["streamSettings"].get("network"))' "$out"
  "$X" run -config "$out" > "$W/logs/client-$key.log" 2>&1 &
  CPID=$!
  sleep 3
  if ! kill -0 $CPID 2>/dev/null; then echo "    客户端没起来"; tail -3 "$W/logs/client-$key.log" | sed 's/^/      /'; continue; fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --socks5-hostname 127.0.0.1:$port \
         https://www.gstatic.com/generate_204 2>/dev/null)
  echo "    curl 204 探测 → http_code=${code:-000}"
  echo "    客户端日志（含 mux 相关）:"
  grep -iE "mux|accepted|failed|error" "$W/logs/client-$key.log" | tail -6 | sed 's/^/      /'
  kill $CPID 2>/dev/null; sleep 1; kill -9 $CPID 2>/dev/null
done
echo "    服务端日志（末 5 行）:"; tail -5 "$W/logs/server.log" | sed 's/^/      /'
kill $SPID 2>/dev/null; sleep 1; kill -9 $SPID 2>/dev/null
echo "（临时目录 $W 由调用方清理）"

echo
echo "收尾：rm -rf /tmp/xbd-v2 /tmp/xbd-loop /tmp/xbd-logs /tmp/xbd-client.tar.gz"
