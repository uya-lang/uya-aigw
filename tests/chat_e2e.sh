#!/usr/bin/env bash
# A4 e2e：种子 Key/供应商/价目 → aigw serve → TLS mock 上游 → chat → usage 落账
set -euo pipefail
cd "$(dirname "$0")/.."

UYA=${UYA:-/home/winger/uya/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-/home/winger/uya/uya/lib}
TMP=$(mktemp -d)
SRV_PID=""
MOCK_PID=""

cleanup() {
  [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }
  [ -n "$MOCK_PID" ] && { kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true; }
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
BODY = (b'{"id":"chatcmpl-e2e","object":"chat.completion","usage":{'
        b'"prompt_tokens":100000,"completion_tokens":50000,'
        b'"prompt_tokens_details":{"cached_tokens":10000}}}')
USAGE = (b'{"usage":{"prompt_tokens":100000,"completion_tokens":50000,'
         b'"prompt_tokens_details":{"cached_tokens":10000}}}')
SSE = (b'data: {"i":0}\n\n'
       b'data: {"i":1}\n\n'
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
  src/core/money.uya src/core/reqlog.uya src/core/dbx.uya src/net/rsav.uya \
  src/core/schema.uya src/core/store.uya src/core/backup.uya src/core/journal.uya \
  src/core/runtime.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/rollup.uya \
  src/core/billing.uya src/core/chat.uya src/providers/upstream.uya \
  src/providers/upstream_cfg.uya \
  src/net/x509min.uya src/net/chainx.uya src/net/urlx.uya src/net/dnsx.uya \
  src/net/tlsx.uya src/net/tlsx_conn.uya src/net/httpc.uya src/net/ssex.uya \
  src/net/httpc_pool.uya src/net/proxyx.uya src/providers/http.uya \
  src/providers/httpcall.uya src/cli/tls_cmd.uya src/app.uya \
  -o build/aigw >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log" >&2; fail "aigw build"; }

./build/aigw serve --host 127.0.0.1 --port 0 --db "$SEED_DB" --data-dir "$TMP/data" \
  --ca "$TMP/root.pem" --dev-otp >"$TMP/serve.log" 2>&1 &
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
grep -q 'data: {"i":0}' "$TMP/stream.txt" || fail "stream event missing"
grep -q 'data: \[DONE\]' "$TMP/stream.txt" || fail "stream DONE missing"

# 4b2) models：公开列表来自 provider_models
MJSON=$(curl -s --max-time 10 "http://127.0.0.1:$PORT/v1/models")
echo "$MJSON" | grep -q '"id":"mock-model"' || { echo "$MJSON" >&2; fail "models list"; }

# 4c) 用量汇总（A6：billing 实时 upsert usage_daily）
UJSON=$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/v1/usage?from_day=0&to_day=999999")
echo "$UJSON" | grep -q '"mock-model"' || { echo "$UJSON" >&2; fail "usage model missing"; }
echo "$UJSON" | grep -q '"requests":2' || { echo "$UJSON" >&2; fail "usage totals"; }
echo "$UJSON" | grep -q '"profit_nano":264' || { echo "$UJSON" >&2; fail "usage profit"; }

# 5) 停机后查账本
kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
SRV_PID=""
COUNT=$(AIGW_MODE=count AIGW_DB="$SEED_DB" ./build/seed | sed -n 's/^COUNT=//p')
[ "$COUNT" = "2" ] || fail "usage_ledger count=$COUNT"
echo "CHAT-ALL-OK status=$CODE count=$COUNT"
