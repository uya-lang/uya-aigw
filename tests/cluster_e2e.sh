#!/usr/bin/env bash
# B6：集群端到端 —— controller + uplink 注册 + epoch/assign + edge 路由 + drain 重分配 + ingest 幂等
set -u
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  for p in "${PIDS[@]:-}"; do wait "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "CLUSTER-FAIL $*" >&2; exit 1; }
ok() { echo "CLUSTER-OK $*"; }

mkdir -p "$TMP/c" "$TMP/n"

# 1) 编译
UYA_ROOT=/home/winger/uya/uya/lib /home/winger/uya/uya/bin/uya build \
  src/foundation/buf.uya src/net/httpsrv.uya src/net/tcpx.uya src/net/serve.uya \
  src/core/money.uya src/core/reqlog.uya src/core/dbx.uya src/cluster/meta.uya src/cluster/elect.uya \
  src/cluster/uplink.uya src/cluster/ingest.uya src/cluster/edge.uya src/net/ui.uya src/net/rsav.uya \
  src/core/schema.uya src/core/store.uya src/core/budget.uya src/core/backup.uya src/core/journal.uya \
  src/core/runtime.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/rollup.uya \
  src/core/billing.uya src/core/lb.uya src/core/responses.uya src/core/chat.uya src/providers/upstream.uya \
  src/providers/upstream_cfg.uya \
  src/net/x509min.uya src/net/chainx.uya src/net/urlx.uya src/net/dnsx.uya \
  src/net/tlsx.uya src/net/tlsx_conn.uya src/net/httpc.uya src/net/ssex.uya \
  src/net/httpc_pool.uya src/net/proxyx.uya src/providers/http.uya \
  src/providers/httpcall.uya src/cli/tls_cmd.uya src/app.uya \
  -o build/aigw >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log" >&2; fail "aigw build"; }

# 2) controller
./build/aigw serve --host 127.0.0.1 --port 0 --db "$TMP/c/a.db" --data-dir "$TMP/c" \
  --admin-key ck --meta "$TMP/c/meta.db" --node-id node-a >"$TMP/c.log" 2>&1 &
PIDS+=($!)
sleep 0.6
PORT=$(sed -n 's/^listen port=\([0-9]*\).*/\1/p' "$TMP/c.log" | head -1)
[ -n "$PORT" ] || { cat "$TMP/c.log" >&2; fail "controller port"; }
BASE="http://127.0.0.1:$PORT"

# 3) edge 节点通过 uplink 注册（真 uplink，不是 curl 伪造）
./build/aigw serve --host 127.0.0.1 --port 0 --db "$TMP/n/a.db" --data-dir "$TMP/n" \
  --uplink "127.0.0.1:$PORT" --node-id node-b >"$TMP/n.log" 2>&1 &
PIDS+=($!)
ST=""
i=0
while [ $i -lt 60 ]; do
  ST=$(curl -s --max-time 5 -H 'Authorization: Bearer ck' "$BASE/controller/status")
  echo "$ST" | grep -q '"node-b"' && break
  i=$((i + 1)); sleep 0.1
done
echo "$ST" | grep -q '"node-b"' || { cat "$TMP/n.log" >&2; echo "$ST" >&2; fail "uplink register"; }

# 再起两台 node，验证多节点注册（1 controller + 3 node）
for nid in node-c node-d; do
  mkdir -p "$TMP/$nid"
  ./build/aigw serve --host 127.0.0.1 --port 0 --db "$TMP/$nid/a.db" --data-dir "$TMP/$nid" \
    --uplink "127.0.0.1:$PORT" --node-id "$nid" >"$TMP/$nid.log" 2>&1 &
  PIDS+=($!)
done
i=0
while [ $i -lt 60 ]; do
  ST=$(curl -s --max-time 5 -H 'Authorization: Bearer ck' "$BASE/controller/status")
  echo "$ST" | grep -q '"node-c"' && echo "$ST" | grep -q '"node-d"' && break
  i=$((i + 1)); sleep 0.1
done
echo "$ST" | grep -q '"node-c"' || { cat "$TMP/node-c.log" >&2; echo "$ST" >&2; fail "node-c register"; }
echo "$ST" | grep -q '"node-d"' || { cat "$TMP/node-d.log" >&2; echo "$ST" >&2; fail "node-d register"; }
for nid in node-b node-c node-d; do
  echo "$ST" | grep -q "\"id\":\"$nid\"" || { echo "$ST" >&2; fail "missing $nid"; }
done
ok uplink-nodes=3

# 4) epoch + 归属
CE=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer ck' --data '{"id":"node-b"}' "$BASE/controller/epoch")
echo "$CE" | grep -q '"epoch":1' || { echo "$CE" >&2; fail "epoch"; }
CA=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer ck' --data '{"slug":"s1","node_id":"node-b","epoch":1}' "$BASE/controller/assign")
echo "$CA" | grep -q '"ok":true' || { echo "$CA" >&2; fail "assign"; }
# 同一 epoch 再抢写必须被 fencing 拒绝（epoch 必须严格递增）
CS=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer ck' --data '{"slug":"s1","node_id":"node-a","epoch":1}' "$BASE/controller/assign")
echo "$CS" | grep -qi 'stale' || { echo "$CS" >&2; fail "fencing"; }
ok epoch

# 4b) B2：node 拉 config 快照（版本/epoch/归属），并暴露 /node/status
CFG=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer ck' --data '{"payload":"{}"}' "$BASE/controller/config")
echo "$CFG" | grep -q '"ok":true' || { echo "$CFG" >&2; fail "config put"; }
NPORT=$(sed -n 's/^listen port=\([0-9]*\).*/\1/p' "$TMP/n.log" | head -1)
[ -n "$NPORT" ] || { cat "$TMP/n.log" >&2; fail "node port"; }
NS=""
i=0
while [ $i -lt 80 ]; do
  NS=$(curl -s --max-time 5 "http://127.0.0.1:$NPORT/node/status")
  echo "$NS" | grep -q '"config_version":1' && break
  i=$((i + 1)); sleep 0.1
done
echo "$NS" | grep -q '"config_version":1' || { cat "$TMP/n.log" >&2; echo "$NS" >&2; fail "config snapshot"; }
echo "$NS" | grep -q '"assignments":1' || { echo "$NS" >&2; fail "snapshot assignments"; }
echo "$NS" | grep -q '"uplink":true' || { echo "$NS" >&2; fail "node uplink flag"; }
# 边缘节点用本地快照就能解析归属（没有 meta.db）
NR=$(curl -s --max-time 5 "http://127.0.0.1:$NPORT/edge/route?slug=s1")
echo "$NR" | grep -q '"node":"node-b"' || { echo "$NR" >&2; fail "snapshot route"; }
ok config-snapshot

# 5) edge 路由 + session 亲和
R1=$(curl -s --max-time 5 "$BASE/edge/route?slug=s1&session=sess-1")
echo "$R1" | grep -q '"node":"node-b"' || { echo "$R1" >&2; fail "edge route"; }
R2=$(curl -s --max-time 5 "$BASE/edge/route?slug=s1&session=sess-1")
echo "$R2" | grep -q '"node":"node-b"' || { echo "$R2" >&2; fail "affinity"; }
RF=$(curl -s --max-time 5 "$BASE/edge/fail?session=sess-1")
echo "$RF" | grep -q '"ok":true' || { echo "$RF" >&2; fail "edge fail"; }
# 归属校验：node-b 认为 s1 是自己的，node-c 认为不是
MINE=$(curl -s --max-time 5 "http://127.0.0.1:$NPORT/edge/route?slug=s1&self=node-b")
echo "$MINE" | grep -q '"mine":true' || { echo "$MINE" >&2; fail "ownership mine"; }
CPORT=$(sed -n 's/^listen port=\([0-9]*\).*/\1/p' "$TMP/node-c.log" | head -1)
NOTMINE=$(curl -s --max-time 5 "http://127.0.0.1:$CPORT/edge/route?slug=s1&self=node-c")
echo "$NOTMINE" | grep -q '"mine":false' || { echo "$NOTMINE" >&2; fail "ownership not mine"; }
R404=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/edge/route?slug=none")
[ "$R404" = "404" ] || fail "edge unknown slug expected 404 got $R404"
ok edge

# 6) drain node-b → 归属迁到 node-a，会话亲和失效后重新解析
DR=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer ck' --data '{"id":"node-b"}' "$BASE/controller/drain")
echo "$DR" | grep -q '"ok":true' || { echo "$DR" >&2; fail "drain"; }
R3=$(curl -s --max-time 5 "$BASE/edge/route?slug=s1&session=sess-2")
echo "$R3" | grep -q '"node":"node-a"' || { echo "$R3" >&2; fail "drain reassign"; }
ok drain

# 7) ingest 幂等（同 request_id 两次只记一次）
IB='{"day":20300,"rows":[{"request_id":"r1","user_id":1,"key_id":1,"provider":"mock","model":"m","prompt_tokens":10,"completion_tokens":5,"cost_nano":1000}]}'
I1=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer ck' --data "$IB" "$BASE/controller/ingest")
echo "$I1" | grep -q '"applied":1' || { echo "$I1" >&2; fail "ingest 1"; }
I2=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer ck' --data "$IB" "$BASE/controller/ingest")
echo "$I2" | grep -q '"duplicate":1' || { echo "$I2" >&2; fail "ingest dup"; }
ok ingest

echo "CLUSTER-ALL-OK"
