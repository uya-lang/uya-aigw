#!/usr/bin/env bash
# A4 e2e：种子 Key/供应商/价目 → aigw serve → TLS mock 上游 → chat → usage 落账
set -euo pipefail
cd "$(dirname "$0")/.."

UYA=${UYA:-/home/winger/uya/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-/home/winger/uya/uya/lib}
TMP=$(mktemp -d)
SRV_PID=""
MOCK_PID=""
NB_PID=""

cleanup() {
  [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }
  [ -n "$MOCK_PID" ] && { kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true; }
  [ -n "$NB_PID" ] && { kill "$NB_PID" 2>/dev/null || true; wait "$NB_PID" 2>/dev/null || true; }
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "CHAT-FAIL $*" >&2; exit 1; }

# 1) 根 CA + leaf（SAN=localhost）
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/root.key" -out "$TMP/root.pem" \
  -days 2 -subj "/CN=E2E Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/leaf.key" -out "$TMP/leaf.csr" \
  -subj "/CN=localhost" 2>/dev/null
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nsubjectAltName=DNS:localhost\n" > "$TMP/leaf.ext"
openssl x509 -req -in "$TMP/leaf.csr" -CA "$TMP/root.pem" -CAkey "$TMP/root.key" \
  -CAcreateserial -out "$TMP/leaf.pem" -days 2 -extfile "$TMP/leaf.ext" 2>/dev/null

# 2) TLS mock 上游：POST /v1/chat/completions 回 usage JSON，并保存收到的请求体
MPORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)
cat > "$TMP/mock.py" <<'PY'
import http.server, ssl, sys
port, cert, key, reqfile = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
BODY = (b'{"id":"chatcmpl-e2e","object":"chat.completion",'
        b'"choices":[{"message":{"role":"assistant","content":"hello-from-mock"}}],'
        b'"usage":{"prompt_tokens":100000,"completion_tokens":50000,'
        b'"prompt_tokens_details":{"cached_tokens":10000}}}')
USAGE = (b'{"usage":{"prompt_tokens":100000,"completion_tokens":50000,'
         b'"prompt_tokens_details":{"cached_tokens":10000}}}')
SSE = (b'data: {"choices":[{"delta":{"content":"hello-from-mock"}}]}\n\n'
       b'data: ' + USAGE + b'\n\n'
       b'data: [DONE]\n\n')
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(n)
        with open(reqfile, "wb") as f:
            f.write(data)
        if "text/event-stream" in (self.headers.get("Accept") or ""):
            data = SSE
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data); self.wfile.flush()
        else:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(BODY)))
            self.end_headers()
            self.wfile.write(BODY); self.wfile.flush()
srv = http.server.HTTPServer(("127.0.0.1", port), H)
sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
sctx.load_cert_chain(cert, key)
srv.socket = sctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
python3 "$TMP/mock.py" "$MPORT" "$TMP/leaf.pem" "$TMP/leaf.key" "$TMP/req.json" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!
sleep 0.3

# 3) 种子夹具 + aigw
mkdir -p build
UYA_ROOT="$UYA_ROOT" "$UYA" build \
  src/core/dbx.uya src/core/schema.uya src/core/store.uya src/core/money.uya \
  src/core/schedule.uya src/core/price.uya tests/seed_main.uya -o build/seed >"$TMP/seedbuild.log" 2>&1 \
  || { cat "$TMP/seedbuild.log" >&2; fail "seed build"; }

SEED_DB="$TMP/data/aigw.db"
mkdir -p "$TMP/data"
AIGW_MODE=seed AIGW_DB="$SEED_DB" AIGW_UPSTREAM_PORT="$MPORT" ./build/seed >/dev/null

UYA_ROOT="$UYA_ROOT" "$UYA" build \
  src/foundation/buf.uya src/net/httpsrv.uya src/net/tcpx.uya src/net/serve.uya \
  src/core/money.uya src/core/reqlog.uya src/core/dbx.uya src/cluster/meta.uya src/cluster/elect.uya src/cluster/uplink.uya src/cluster/ingest.uya src/net/ui.uya src/net/rsav.uya \
  src/core/schema.uya src/core/store.uya src/core/backup.uya src/core/journal.uya \
  src/core/runtime.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/rollup.uya \
  src/core/billing.uya src/core/lb.uya src/core/responses.uya src/core/chat.uya src/providers/upstream.uya \
  src/providers/upstream_cfg.uya \
  src/net/x509min.uya src/net/chainx.uya src/net/urlx.uya src/net/dnsx.uya \
  src/net/tlsx.uya src/net/tlsx_conn.uya src/net/httpc.uya src/net/ssex.uya \
  src/net/httpc_pool.uya src/net/proxyx.uya src/providers/http.uya \
  src/providers/httpcall.uya src/cli/tls_cmd.uya src/app.uya \
  -o build/aigw >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log" >&2; fail "aigw build"; }

./build/aigw serve --host 127.0.0.1 --port 0 --db "$SEED_DB" --data-dir "$TMP/data" \
  --ca "$TMP/root.pem" --dev-otp --admin-key test-admin \
  --meta "$TMP/data/meta.db" --node-id node-a >"$TMP/serve.log" 2>&1 &
SRV_PID=$!
PORT=""
for _ in $(seq 1 200); do
  PORT=$(sed -n 's/^listen port=\([0-9]\{1,\}\).*/\1/p' "$TMP/serve.log" 2>/dev/null | head -1)
  [ -n "$PORT" ] && break
  kill -0 "$SRV_PID" 2>/dev/null || { cat "$TMP/serve.log" >&2; fail "server exited"; }
  sleep 0.05
done
[ -n "$PORT" ] || { cat "$TMP/serve.log" >&2; fail "no port"; }

BASE="http://127.0.0.1:$PORT"
# 3b) A2 HTTP 认证：OTP → 登录 → 建 Key → /v1/me
OTPJSON=$(curl -s --max-time 5 -X POST --data '{"email":"http@example.com"}' "$BASE/v1/auth/otp")
CODE=$(echo "$OTPJSON" | sed -n 's/.*"code":"\([0-9]*\)".*/\1/p')
[ -n "$CODE" ] || { echo "$OTPJSON" >&2; fail "otp code"; }
LOGIN=$(curl -s --max-time 5 -X POST --data "{\"email\":\"http@example.com\",\"code\":\"$CODE\"}" "$BASE/v1/auth/login")
SESSION=$(echo "$LOGIN" | sed -n 's/.*"session":"\([^"]*\)".*/\1/p')
[ -n "$SESSION" ] || { echo "$LOGIN" >&2; fail "login session"; }
KEYS=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $SESSION" --data '{"name":"e2e"}' "$BASE/v1/keys")
TOKEN=$(echo "$KEYS" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "$KEYS" >&2; fail "key create"; }
ME=$(curl -s --max-time 5 -H "Authorization: Bearer $SESSION" "$BASE/v1/me")
echo "$ME" | grep -q '"user_id":' || { echo "$ME" >&2; fail "me"; }

# 4) chat 调用
CODE=$(curl -s --max-time 15 -o "$TMP/resp.json" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"model":"mock-model","messages":[{"role":"user","content":"hi"}]}' \
  "http://127.0.0.1:$PORT/v1/chat/completions")
[ "$CODE" = "200" ] || { cat "$TMP/resp.json" >&2; cat "$TMP/serve.log" >&2; fail "chat status=$CODE"; }
grep -q '"usage"' "$TMP/resp.json" || fail "no usage in response"
grep -q '"upstream-model"' "$TMP/req.json" || fail "model not rewritten upstream"
grep -q '"messages"' "$TMP/req.json" || fail "messages lost"

# 4b) 流式：SSE 逐事件透传 + [DONE]
SCODE=$(curl -s -N --max-time 15 -o "$TMP/stream.txt" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Accept: text/event-stream' \
  --data '{"model":"mock-model","stream":true,"messages":[{"role":"user","content":"hi"}]}' \
  "http://127.0.0.1:$PORT/v1/chat/completions")
[ "$SCODE" = "200" ] || { cat "$TMP/stream.txt" >&2; fail "stream status=$SCODE"; }
grep -q 'hello-from-mock' "$TMP/stream.txt" || { cat "$TMP/stream.txt" >&2; fail "stream event missing"; }
grep -q 'data: \[DONE\]' "$TMP/stream.txt" || fail "stream DONE missing"

# 4b1) A5 responses：首轮 + previous_response_id 续轮
R1=$(curl -s --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"model":"mock-model","input":"hello"}' "$BASE/v1/responses")
echo "$R1" | grep -q '"output_text"' || { echo "$R1" >&2; fail "responses output"; }
echo "$R1" | grep -q 'hello-from-mock' || { echo "$R1" >&2; fail "responses text"; }
RID=$(echo "$R1" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
[ -n "$RID" ] || { echo "$R1" >&2; fail "responses id"; }
R2=$(curl -s --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" \
  --data "{\"model\":\"mock-model\",\"input\":\"next\",\"previous_response_id\":\"$RID\"}" "$BASE/v1/responses")
echo "$R2" | grep -q '"output_text"' || { echo "$R2" >&2; fail "responses continue"; }

# 4b1b) responses 流式事件序列
RS=$(curl -s -N --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: text/event-stream' \
  --data '{"model":"mock-model","stream":true,"input":"hello"}' "$BASE/v1/responses")
echo "$RS" | grep -q 'response.created' || { echo "$RS" >&2; fail "responses created"; }
echo "$RS" | grep -q 'response.output_text.delta' || { echo "$RS" >&2; fail "responses delta"; }
echo "$RS" | grep -q 'hello-from-mock' || { echo "$RS" >&2; fail "responses delta text"; }
echo "$RS" | grep -q 'response.completed' || { echo "$RS" >&2; fail "responses completed"; }

# 4b2) models：公开列表来自 provider_models
MJSON=$(curl -s --max-time 10 "http://127.0.0.1:$PORT/v1/models")
echo "$MJSON" | grep -q '"id":"mock-model"' || { echo "$MJSON" >&2; fail "models list"; }

# 4c) 用量汇总（A6：billing 实时 upsert usage_daily）
UJSON=$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/v1/usage?from_day=0&to_day=999999")
echo "$UJSON" | grep -q '"mock-model"' || { echo "$UJSON" >&2; fail "usage model missing"; }
echo "$UJSON" | grep -q '"requests":5' || { echo "$UJSON" >&2; fail "usage totals"; }
echo "$UJSON" | grep -q '"profit_nano":660' || { echo "$UJSON" >&2; fail "usage profit"; }

# 4d) A7 管理 REST（--admin-key）
AH=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/health")
echo "$AH" | grep -q '"ok":true' || { echo "$AH" >&2; fail "admin health"; }
AB=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/billing?user_id=0&from_day=0&to_day=999999")
echo "$AB" | grep -q '"mock-model"' || { echo "$AB" >&2; fail "admin billing"; }
AP=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/pricing?model=mock-model&provider=mock&ts=1700000000")
echo "$AP" | grep -q '"input_nano_per_mtok":1000' || { echo "$AP" >&2; fail "admin pricing sell"; }
echo "$AP" | grep -q '"input_nano_per_mtok":600' || { echo "$AP" >&2; fail "admin pricing cost"; }
AK=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/backup")
echo "$AK" | grep -q '"ok":true' || { echo "$AK" >&2; fail "admin backup"; }
AN=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/admin/health")
[ "$AN" = "401" ] || fail "admin without key expected 401, got $AN"

# 4e) A7 MCP：initialize / tools/list / tools/call
M0=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize"}' "$BASE/mcp")
echo "$M0" | grep -q '"protocolVersion"' || { echo "$M0" >&2; fail "mcp initialize"; }
MT=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "$BASE/mcp")
echo "$MT" | grep -q '"pricing_get"' || { echo "$MT" >&2; fail "mcp tools/list"; }
MC=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"backup_status","arguments":{}}}' "$BASE/mcp")
echo "$MC" | grep -q 'last_backup_day' || { echo "$MC" >&2; fail "mcp tools/call"; }

# 4f) B1 controller：注册/心跳/配置/状态
CR=$(curl -s --max-time 5 -X POST --data '{"id":"node-b","role":"edge","addr":"127.0.0.1:1"}' "$BASE/controller/register")
echo "$CR" | grep -q '"ok":true' || { echo "$CR" >&2; fail "controller register"; }
CH=$(curl -s --max-time 5 -X POST --data '{"id":"node-b","journal_day":19700,"entries":7}' "$BASE/controller/heartbeat")
echo "$CH" | grep -q '"ok":true' || { echo "$CH" >&2; fail "controller heartbeat"; }
CFG0=$(curl -s --max-time 5 "$BASE/controller/config")
echo "$CFG0" | grep -q '"version":0' || { echo "$CFG0" >&2; fail "controller config0"; }
CFGSET=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"payload":"{\"x\":1}"}' "$BASE/controller/config")
echo "$CFGSET" | grep -q '"version":1' || { echo "$CFGSET" >&2; fail "controller configset"; }
CFG1=$(curl -s --max-time 5 "$BASE/controller/config")
echo "$CFG1" | grep -q '"version":1' || { echo "$CFG1" >&2; fail "controller config1"; }
CST=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/controller/status")
echo "$CST" | grep -q '"node-a"' || { echo "$CST" >&2; fail "controller status a"; }
echo "$CST" | grep -q '"node-b"' || { echo "$CST" >&2; fail "controller status b"; }
echo "$CST" | grep -q '"leader":"node-a"' || { echo "$CST" >&2; fail "controller leader"; }

# B3：epoch / 归属 fencing（stale → 421）/ drain
CE=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' --data '{"id":"node-b"}' "$BASE/controller/epoch")
echo "$CE" | grep -q '"epoch":1' || { echo "$CE" >&2; fail "epoch bump"; }
CA1=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"slug":"s1","node_id":"node-b","epoch":1}' "$BASE/controller/assign")
echo "$CA1" | grep -q '"ok":true' || { echo "$CA1" >&2; fail "assign ok"; }
CE2=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' --data '{"id":"node-b"}' "$BASE/controller/epoch")
echo "$CE2" | grep -q '"epoch":2' || { echo "$CE2" >&2; fail "epoch bump2"; }
CA2=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"slug":"s1","node_id":"node-b","epoch":1}' "$BASE/controller/assign")
[ "$CA2" = "421" ] || fail "stale epoch expected 421, got $CA2"
CA3=$(curl -s --max-time 5 "$BASE/controller/assign?slug=s1")
echo "$CA3" | grep -q '"node_id":"node-b"' || { echo "$CA3" >&2; fail "assign get"; }
echo "$CA3" | grep -q '"epoch":1' || { echo "$CA3" >&2; fail "assign epoch"; }
CD=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' --data '{"id":"node-b"}' "$BASE/controller/drain")
echo "$CD" | grep -q '"ok":true' || { echo "$CD" >&2; fail "drain"; }
CST3=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/controller/status")
echo "$CST3" | grep -q '"status":"draining"' || { echo "$CST3" >&2; fail "drain status"; }

# 4g) B2：node-b 通过 uplink 注册到 controller
mkdir -p "$TMP/nodeb"
./build/aigw serve --host 127.0.0.1 --port 0 --db "$TMP/nodeb/aigw.db" \
  --data-dir "$TMP/nodeb" --uplink "127.0.0.1:$PORT" --node-id node-b \
  >"$TMP/nodeb.log" 2>&1 &
NB_PID=$!
CST2=""
for _ in $(seq 1 50); do
  CST2=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/controller/status")
  echo "$CST2" | grep -q '"node-b"' && break
  sleep 0.1
done
echo "$CST2" | grep -q '"node-b"' || { cat "$TMP/nodeb.log" >&2; echo "$CST2" >&2; fail "uplink register"; }
kill "$NB_PID" 2>/dev/null || true
wait "$NB_PID" 2>/dev/null || true
NB_PID=""

# 4j) C2：用量 CSV 导出
CSVH=$(curl -s --max-time 5 -D - -o /dev/null -H "Authorization: Bearer $TOKEN" "$BASE/v1/usage.csv")
echo "$CSVH" | grep -qi 'content-type: text/csv' || { echo "$CSVH" >&2; fail "csv ctype"; }
CSV=$(curl -s --max-time 5 -H "Authorization: Bearer $TOKEN" "$BASE/v1/usage.csv")
echo "$CSV" | head -1 | grep -q 'day,model,provider,period,requests' || { echo "$CSV" >&2; fail "csv header"; }
echo "$CSV" | grep -q 'mock-model' || { echo "$CSV" >&2; fail "csv row"; }

# 4i) C1：静态壳与前端脚本
UI=$(curl -s --max-time 5 "$BASE/")
echo "$UI" | grep -q 'id="login"' || { echo "$UI" >&2; fail "ui index"; }
echo "$UI" | grep -q '/ui/app.js' || { echo "$UI" >&2; fail "ui script tag"; }
UIJS=$(curl -s --max-time 5 "$BASE/ui/app.js")
echo "$UIJS" | grep -q '/v1/keys/revoke' || { echo "$UIJS" >&2; fail "ui js"; }
echo "$UI" | grep -q 'id="overview"' || { echo "$UI" >&2; fail "ui overview"; }
echo "$UIJS" | grep -q '/v1/usage' || { echo "$UIJS" >&2; fail "ui usage"; }
echo "$UIJS" | grep -q 'usage-table' || { echo "$UIJS" >&2; fail "ui usage table"; }
CT=$(curl -s --max-time 5 -o /dev/null -w '%{content_type}' "$BASE/")
case "$CT" in text/html*) ;; *) fail "ui content-type=$CT";; esac

# 4h) B5：controller 幂等 ingest（重复批 duplicate=2）
ING='{"rows":[{"request_id":"ing1","user_id":1,"ts":1700000000,"model":"mock-model","provider":"mock","input_tokens":10,"output_tokens":5,"cache_read_tokens":0,"cost_nano":2,"price_nano":3,"period":"","rate_version":1},{"request_id":"ing2","user_id":1,"ts":1700000060,"model":"mock-model","provider":"mock","input_tokens":20,"output_tokens":10,"cache_read_tokens":0,"cost_nano":4,"price_nano":6,"period":"","rate_version":1}]}'
I1=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' --data "$ING" "$BASE/controller/ingest")
echo "$I1" | grep -q '"applied":2' || { echo "$I1" >&2; fail "ingest applied"; }
I2=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' --data "$ING" "$BASE/controller/ingest")
echo "$I2" | grep -q '"duplicate":2' || { echo "$I2" >&2; fail "ingest duplicate"; }

# 5) 停机后查账本
kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
SRV_PID=""
COUNT=$(AIGW_MODE=count AIGW_DB="$SEED_DB" ./build/seed | sed -n 's/^COUNT=//p')
[ "$COUNT" = "7" ] || fail "usage_ledger count=$COUNT"
echo "CHAT-ALL-OK status=$CODE count=$COUNT"
