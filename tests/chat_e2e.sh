#!/usr/bin/env bash
# A4 e2e：种子 Key/供应商/价目 → aigw serve → TLS mock 上游 → chat → usage 落账
set -euo pipefail
cd "$(dirname "$0")/.."
# D4：环境里的 HTTPS_PROXY/NO_PROXY 会让出站走代理，e2e 需要确定行为。
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy

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
port, cert, key, reqfile, connfile, reretryfile = (int(sys.argv[1]), sys.argv[2],
                                                  sys.argv[3], sys.argv[4],
                                                  sys.argv[5], sys.argv[6])
BODY = (b'{"id":"chatcmpl-e2e","object":"chat.completion",'
        b'"choices":[{"message":{"role":"assistant","content":"hello-from-mock"}}],'
        b'"usage":{"prompt_tokens":100000,"completion_tokens":50000,'
        b'"prompt_tokens_details":{"cached_tokens":10000}}}')
USAGE = (b'{"usage":{"prompt_tokens":100000,"completion_tokens":50000,'
         b'"prompt_tokens_details":{"cached_tokens":10000}}}')
SSE = (b'data: {"choices":[{"delta":{"content":"hello-from-mock"}}]}\n\n'
       b'data: ' + USAGE + b'\n\n'
       b'data: [DONE]\n\n')
# A5：流式工具调用（arguments 分片），用于断言 output_item.added/done
SSE_TOOL = (b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}\n\n'
            b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"city\\":"}}]}}]}\n\n'
            b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"SF\\"}"}}]}}]}\n\n'
            b'data: ' + USAGE + b'\n\n'
            b'data: [DONE]\n\n')
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def setup(self):
        super().setup()
        # D2：每次 TCP accept 记一行，用于断言连接池复用（请求数 >> 连接数）
        with open(connfile, "a") as f:
            f.write("c\n")
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(n)
        with open(reqfile, "wb") as f:
            f.write(data)
        # D3：retry-upstream 前两次回 503，用于验证网关按退避重试同一家
        if b'"retry-upstream"' in data:
            cnt = 0
            try:
                with open(reretryfile) as f:
                    cnt = int((f.read().strip() or "0"))
            except Exception:
                cnt = 0
            cnt += 1
            with open(reretryfile, "w") as f:
                f.write(str(cnt))
            if cnt <= 2:
                eb = b'{"error":"rate limited"}'
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(eb)))
                self.end_headers()
                self.wfile.write(eb); self.wfile.flush()
                return
        if "text/event-stream" in (self.headers.get("Accept") or ""):
            data = SSE_TOOL if b'"tools"' in data else SSE
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data); self.wfile.flush()
            return
        if b'"tools"' in data:
            tb = (b'{"id":"chatcmpl-tool","object":"chat.completion",'
                  b'"choices":[{"message":{"role":"assistant","content":null,'
                  b'"tool_calls":[{"id":"call_1","type":"function",'
                  b'"function":{"name":"get_weather","arguments":"{\\"city\\":\\"SF\\"}"}}]}}],'
                  b'"usage":{"prompt_tokens":10,"completion_tokens":5}}')
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(tb)))
            self.end_headers()
            self.wfile.write(tb); self.wfile.flush()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY); self.wfile.flush()
# D2：连接池会长期占用 keep-alive 连接，单线程 HTTPServer 会让后续新连接饿死，
# 因此 mock 用「每连接一线程」。
srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
srv.daemon_threads = True
sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
sctx.load_cert_chain(cert, key)
srv.socket = sctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
python3 "$TMP/mock.py" "$MPORT" "$TMP/leaf.pem" "$TMP/leaf.key" "$TMP/req.json" "$TMP/conns.txt" "$TMP/retry.txt" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!
sleep 0.3

# 3) 种子夹具 + aigw
mkdir -p build
UYA_ROOT="$UYA_ROOT" "$UYA" build \
  src/core/dbx.uya src/core/schema.uya src/core/store.uya src/core/budget.uya src/core/money.uya \
  src/core/schedule.uya src/core/price.uya tests/seed_main.uya -o build/seed >"$TMP/seedbuild.log" 2>&1 \
  || { cat "$TMP/seedbuild.log" >&2; fail "seed build"; }

SEED_DB="$TMP/data/aigw.db"
mkdir -p "$TMP/data"
AIGW_MODE=seed AIGW_DB="$SEED_DB" AIGW_UPSTREAM_PORT="$MPORT" ./build/seed >/dev/null

UYA_ROOT="$UYA_ROOT" "$UYA" build \
  src/foundation/buf.uya src/net/httpsrv.uya src/net/tcpx.uya src/net/serve.uya \
  src/core/money.uya src/core/reqlog.uya src/core/dbx.uya src/cluster/meta.uya src/cluster/elect.uya src/cluster/uplink.uya src/cluster/edge.uya src/cluster/spool.uya src/cluster/ingest.uya src/cluster/shard.uya src/net/ui.uya src/net/rsav.uya \
  src/core/schema.uya src/core/store.uya src/core/budget.uya src/core/backup.uya src/core/journal.uya \
  src/core/runtime.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/rollup.uya \
  src/core/billing.uya src/core/batch.uya src/core/notify.uya src/core/upwait.uya src/core/lb.uya src/core/responses.uya src/core/chat.uya src/providers/upstream.uya \
  src/providers/upstream_cfg.uya \
  src/net/x509min.uya src/net/chainx.uya src/net/urlx.uya src/net/dnsx.uya \
  src/net/tlsx.uya src/net/tlsx_conn.uya src/net/httpc.uya src/net/ssex.uya \
  src/net/httpc_pool.uya src/net/proxyx.uya src/providers/http.uya \
  src/providers/httpcall.uya src/plugins/pool.uya src/providers/plug.uya src/cli/tls_cmd.uya src/net/smtp_msg.uya src/net/smtp.uya src/core/mailer.uya src/app.uya \
  -o build/aigw >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log" >&2; fail "aigw build"; }

./build/aigw serve --host 127.0.0.1 --port 0 --db "$SEED_DB" --data-dir "$TMP/data" \
  --ca "$TMP/root.pem" --dev-otp --admin-key test-admin \
  --meta "$TMP/data/meta.db" --node-id node-a \
  --plugin-cmd "python3 $PWD/tests/plugin_chat.py $TMP/plug.pids" >"$TMP/serve.log" 2>&1 &
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

# 4b1c) A5 responses 流式工具事件：added → arguments.delta → done
RST=$(curl -s -N --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: text/event-stream' \
  --data '{"model":"mock-model","stream":true,"input":"weather?","tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object"}}}]}' \
  "$BASE/v1/responses")
echo "$RST" | grep -q 'response.output_item.added' || { echo "$RST" >&2; fail "tool item added"; }
echo "$RST" | grep -q '"type":"function_call"' || { echo "$RST" >&2; fail "tool item type"; }
echo "$RST" | grep -q '"name":"get_weather"' || { echo "$RST" >&2; fail "tool item name"; }
echo "$RST" | grep -q 'response.function_call_arguments.delta' || { echo "$RST" >&2; fail "tool args delta"; }
echo "$RST" | grep -q 'response.output_item.done' || { echo "$RST" >&2; fail "tool item done"; }
echo "$RST" | grep -q '"arguments":"{\\"city\\":\\"SF\\"}"' || { echo "$RST" >&2; fail "tool args accumulated"; }
echo "$RST" | grep -q '"output":\[{"type":"function_call"' || { echo "$RST" >&2; fail "tool output array"; }
echo "$RST" | grep -q 'response.completed' || { echo "$RST" >&2; fail "tool completed"; }

# 4b2) models：列表来自 provider_models，且必须带有效 Key
MCODE=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models")
[ "$MCODE" = "401" ] || fail "models without key status=$MCODE"
MCODE=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}x" \
  "http://127.0.0.1:$PORT/v1/models")
[ "$MCODE" = "401" ] || fail "models with key+suffix status=$MCODE"
MJSON=$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/models")
echo "$MJSON" | grep -q '"id":"mock-model"' || { echo "$MJSON" >&2; fail "models list"; }

# 4c) 用量汇总（A6：billing 实时 upsert usage_daily）
UJSON=$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/v1/usage?from_day=0&to_day=999999")
echo "$UJSON" | grep -q '"mock-model"' || { echo "$UJSON" >&2; fail "usage model missing"; }
echo "$UJSON" | grep -q '"requests":6' || { echo "$UJSON" >&2; fail "usage totals"; }
echo "$UJSON" | grep -q '"profit_nano":792' || { echo "$UJSON" >&2; fail "usage profit"; }

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

# 4e) A7 MCP：initialize / tools/list / tools/call + A7b 角色隔离
M0=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize"}' "$BASE/mcp")
echo "$M0" | grep -q '"protocolVersion"' || { echo "$M0" >&2; fail "mcp initialize"; }
MT=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "$BASE/mcp")
echo "$MT" | grep -q '"pricing_get"' || { echo "$MT" >&2; fail "mcp tools/list"; }
echo "$MT" | grep -q '"admin_health"' || { echo "$MT" >&2; fail "mcp admin tools/list"; }
MC=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"backup_status","arguments":{}}}' "$BASE/mcp")
echo "$MC" | grep -q 'last_backup_day' || { echo "$MC" >&2; fail "mcp tools/call"; }
MAH=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"admin_health","arguments":{}}}' "$BASE/mcp")
echo "$MAH" | grep -q 'schema' || { echo "$MAH" >&2; fail "mcp admin_health"; }
MAP=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"pricing_get","arguments":{"model":"mock-model","provider":"mock","ts":1700000000}}}' "$BASE/mcp")
echo "$MAP" | grep -q '\\"sell\\"' || { echo "$MAP" >&2; fail "mcp admin pricing sell"; }
echo "$MAP" | grep -q '\\"cost\\"' || { echo "$MAP" >&2; fail "mcp admin pricing cost"; }
MAB=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"billing_query","arguments":{"user_id":0,"from_day":0,"to_day":999999}}}' "$BASE/mcp")
MABJ=$(printf '%s' "$MAB" | sed 's/\\"/"/g')
echo "$MABJ" | grep -q '"model":"mock-model"' || { echo "$MAB" >&2; fail "mcp admin billing"; }

# 普通 API Key：tools/list 不含 admin_*，只能操作自己账号
MUT=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"jsonrpc":"2.0","id":10,"method":"tools/list"}' "$BASE/mcp")
echo "$MUT" | grep -q '"keys_list"' || { echo "$MUT" >&2; fail "mcp user tools/list"; }
if echo "$MUT" | grep -q '"admin_'; then echo "$MUT" >&2; fail "mcp user tools/list leaked admin"; fi
MUM=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"me","arguments":{}}}' "$BASE/mcp")
echo "$MUM" | grep -q 'user_id' || { echo "$MUM" >&2; fail "mcp user me"; }
MUD=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"admin_health","arguments":{}}}' "$BASE/mcp")
echo "$MUD" | grep -q 'permission denied' || { echo "$MUD" >&2; fail "mcp user admin denied"; }
echo "$MUD" | grep -q -- '-32001' || { echo "$MUD" >&2; fail "mcp user admin deny code"; }
MUP=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"pricing_get","arguments":{"model":"mock-model"}}}' "$BASE/mcp")
MUPJ=$(printf '%s' "$MUP" | sed 's/\\"/"/g')
echo "$MUPJ" | grep -q '"sell"' || { echo "$MUP" >&2; fail "mcp user pricing sell"; }
if echo "$MUPJ" | grep -q '"cost"'; then echo "$MUP" >&2; fail "mcp user pricing leaked cost"; fi
# user_id 参数必须被忽略：传别人的 id 仍只返回自己的用量
MUB=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"billing_query","arguments":{"user_id":999,"from_day":0,"to_day":999999}}}' "$BASE/mcp")
MUBJ=$(printf '%s' "$MUB" | sed 's/\\"/"/g')
echo "$MUBJ" | grep -q '"model":"mock-model"' || { echo "$MUB" >&2; fail "mcp user billing self scope"; }
echo "$MUBJ" | grep -q '"requests":6' || { echo "$MUB" >&2; fail "mcp user billing own rows"; }
MUU=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"usage_get","arguments":{}}}' "$BASE/mcp")
MUUJ=$(printf '%s' "$MUU" | sed 's/\\"/"/g')
echo "$MUUJ" | grep -q '"requests":6' || { echo "$MUU" >&2; fail "mcp user usage"; }
MNA=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
  --data '{"jsonrpc":"2.0","id":16,"method":"initialize"}' "$BASE/mcp")
[ "$MNA" = "401" ] || fail "mcp without auth expected 401, got $MNA"

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

# 4g) B2：node-uplink 通过 uplink 注册到 controller（独立 id，避免与上面的 curl 注册混淆）
mkdir -p "$TMP/nodeb"
./build/aigw serve --host 127.0.0.1 --port 0 --db "$TMP/nodeb/aigw.db" \
  --data-dir "$TMP/nodeb" --uplink "127.0.0.1:$PORT" --node-id node-uplink \
  >"$TMP/nodeb.log" 2>&1 &
NB_PID=$!
CST2=""
for _ in $(seq 1 50); do
  CST2=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/controller/status")
  echo "$CST2" | grep -q '"node-uplink"' && break
  sleep 0.1
done
echo "$CST2" | grep -q '"node-uplink"' || { cat "$TMP/nodeb.log" >&2; echo "$CST2" >&2; fail "uplink register"; }
kill "$NB_PID" 2>/dev/null || true
wait "$NB_PID" 2>/dev/null || true
NB_PID=""

# 4q) A8：失败转移（dead provider 优先 → 熔断后重试落到 live provider）
FO=$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"failover-model","messages":[{"role":"user","content":"hi"}]}' "$BASE/v1/chat/completions")
echo "$FO" | grep -q 'hello-from-mock' || { echo "$FO" >&2; fail "failover"; }
# 只有 dead 一家（且已被熔断）→ 明确报错，不静默成功
FD=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"fail-model","messages":[{"role":"user","content":"hi"}]}' "$BASE/v1/chat/completions")
[ "$FD" = "400" ] || [ "$FD" = "502" ] || [ "$FD" = "503" ] || fail "all-dead unexpected $FD"
# 4q2) D3：HTTP 级重试——mock 先回 503 两次，网关按退避重试同一家后成功
RT0=$(date +%s%N)
RT=$(curl -s --max-time 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"retry-model","messages":[{"role":"user","content":"hi"}]}' \
  "$BASE/v1/chat/completions")
RT1=$(date +%s%N)
echo "$RT" | grep -q 'hello-from-mock' || { echo "$RT" >&2; fail "retry-model"; }
RETRIES=$(cat "$TMP/retry.txt" 2>/dev/null || echo 0)
[ "$RETRIES" = "3" ] || fail "expected 3 upstream attempts, got $RETRIES"
ELAPSED_MS=$(( (RT1 - RT0) / 1000000 ))
[ "$ELAPSED_MS" -ge 200 ] || fail "backoff too fast: ${ELAPSED_MS}ms"
echo "CHAT-RETRY attempts=$RETRIES elapsed=${ELAPSED_MS}ms"
# 4q3) D5：stdio 插件供应商（kind=stdio）——进程复用、响应与用量都落账
PLUG1=$(curl -s --max-time 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"plug-model","messages":[{"role":"user","content":"hi"}]}' \
  "$BASE/v1/chat/completions")
echo "$PLUG1" | grep -q 'hello-from-plugin' || { echo "$PLUG1" >&2; fail "plug-model"; }
PLUG2=$(curl -s --max-time 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"plug-model","messages":[{"role":"user","content":"again"}]}' \
  "$BASE/v1/chat/completions")
echo "$PLUG2" | grep -q 'hello-from-plugin' || { echo "$PLUG2" >&2; fail "plug-model 2"; }
# 插件路径不支持流式：带 stream=true 也要拿到完整 JSON（回落为非流式）
PLUGS=$(curl -s --max-time 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"plug-model","stream":true,"messages":[{"role":"user","content":"s"}]}' \
  "$BASE/v1/chat/completions")
echo "$PLUGS" | grep -q 'hello-from-plugin' || { echo "$PLUGS" >&2; fail "plug-model stream fallback"; }
echo "$PLUGS" | grep -q '^data:' && fail "plug-model returned SSE"
PLUGPROCS=$(wc -l < "$TMP/plug.pids" 2>/dev/null | tr -d ' ')
[ "$PLUGPROCS" = "1" ] || fail "plugin not reused: $PLUGPROCS processes"
echo "CHAT-PLUG procs=$PLUGPROCS"
# 熔断不影响其他模型
MC=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"mock-model","messages":[{"role":"user","content":"hi"}]}' "$BASE/v1/chat/completions")
[ "$MC" = "200" ] || fail "mock-model after failover expected 200 got $MC"

# 4p) A5：responses 透传 tools/reasoning + tool_calls → function_call
TOOLS='{"model":"mock-model","input":"weather?","reasoning":{"effort":"high"},"tools":[{"type":"function","function":{"name":"get_weather","description":"d","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}],"tool_choice":"auto"}'
TR=$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$TOOLS" "$BASE/v1/responses")
echo "$TR" | grep -q '"type":"function_call"' || { echo "$TR" >&2; fail "responses function_call"; }
echo "$TR" | grep -q '"name":"get_weather"' || { echo "$TR" >&2; fail "responses tool name"; }
echo "$TR" | grep -q '"call_id":"call_1"' || { echo "$TR" >&2; fail "responses call_id"; }
echo "$TR" | grep -q '"status":"completed"' || { echo "$TR" >&2; fail "responses status"; }
# 上游确实收到了 tools/tool_choice/reasoning（mock 落了最后一次请求体）
grep -q '"tools"' "$TMP/req.json" || { cat "$TMP/req.json" >&2; fail "tools forwarded"; }
grep -q '"get_weather"' "$TMP/req.json" || { cat "$TMP/req.json" >&2; fail "tool name forwarded"; }
grep -q '"tool_choice":"auto"' "$TMP/req.json" || { cat "$TMP/req.json" >&2; fail "tool_choice forwarded"; }
grep -q '"effort":"high"' "$TMP/req.json" || { cat "$TMP/req.json" >&2; fail "reasoning forwarded"; }
# chat 路径原样透传 tools
CTOOLS='{"model":"mock-model","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"chat_tool","parameters":{"type":"object"}}}]}'
curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$CTOOLS" "$BASE/v1/chat/completions" >/dev/null
grep -q '"chat_tool"' "$TMP/req.json" || { cat "$TMP/req.json" >&2; fail "chat tools forwarded"; }

# 4o) C3：模型绑定 + 价目条目编辑
AB=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' -H 'Content-Type: application/json' \
  --data '{"provider":"mock","model":"price-model","upstream_model":"mock-1"}' "$BASE/admin/bind")
echo "$AB" | grep -q '"ok":true' || { echo "$AB" >&2; fail "admin bind"; }
AM=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/models")
echo "$AM" | grep -q '"upstream_model":"mock-1"' || { echo "$AM" >&2; fail "admin models"; }
AP2=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' -H 'Content-Type: application/json' \
  --data '{"model":"price-model","input":1000000,"output":2000000,"cache_read":0}' "$BASE/admin/price-entries")
echo "$AP2" | grep -q '"ok":true' || { echo "$AP2" >&2; fail "price entry put"; }
APL=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/price-entries")
echo "$APL" | grep -q '"model":"price-model"' || { echo "$APL" >&2; fail "price entry list"; }
echo "$APL" | grep -q '"input":1000000' || { echo "$APL" >&2; fail "price entry rate"; }
# C3：分时价编辑（schedule 入库 + 列表回显 + 非法规则拒绝）
APS=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"model":"sched-model","provider":"","input":100,"output":200,"cache_read":0,"schedule":"workday 09:00-18:00 120%"}' "$BASE/admin/price-entries")
echo "$APS" | grep -q '"ok":true' || { echo "$APS" >&2; fail "schedule price put"; }
APL2=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/price-entries")
echo "$APL2" | grep -q '"schedule":"workday 09:00-18:00 120%"' || { echo "$APL2" >&2; fail "schedule echoed"; }
APBAD=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer test-admin' \
  --data '{"model":"sched-model","schedule":"bogus"}' "$BASE/admin/price-entries")
[ "$APBAD" = "400" ] || fail "bad schedule expected 400, got $APBAD"
AP401=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/admin/price-entries")
[ "$AP401" = "401" ] || fail "price entries expected 401, got $AP401"
# C5：审计日志记录改价与绑定
AA=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/audit")
echo "$AA" | grep -q '"action":"price.put"' || { echo "$AA" >&2; fail "audit price.put"; }
echo "$AA" | grep -q '"action":"bind"' || { echo "$AA" >&2; fail "audit bind"; }
echo "$AA" | grep -q '"target":"price-model"' || { echo "$AA" >&2; fail "audit target"; }
AA401=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/admin/audit")
[ "$AA401" = "401" ] || fail "audit expected 401, got $AA401"
# C5：更多审计动作（key.create / key.revoke / schedule.put，actor=user）
NK=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $SESSION" --data '{"name":"audit-key"}' "$BASE/v1/keys")
echo "$NK" | grep -q '"key":"aigw_sk_' || { echo "$NK" >&2; fail "audit key create"; }
NKEYS=$(curl -s --max-time 5 -H "Authorization: Bearer $SESSION" "$BASE/v1/keys")
NKID=$(echo "$NKEYS" | tr '}' '\n' | grep '"name":"audit-key"' | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
[ -n "$NKID" ] || { echo "$NKEYS" >&2; fail "audit key id"; }
NRV=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $SESSION" --data "{\"key_id\":$NKID}" "$BASE/v1/keys/revoke")
echo "$NRV" | grep -q '"ok":true' || { echo "$NRV" >&2; fail "audit key revoke"; }
AA2=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/audit")
echo "$AA2" | grep -q '"action":"key.create"' || { echo "$AA2" >&2; fail "audit key.create"; }
echo "$AA2" | grep -q '"action":"key.revoke"' || { echo "$AA2" >&2; fail "audit key.revoke"; }
echo "$AA2" | grep -q '"action":"schedule.put"' || { echo "$AA2" >&2; fail "audit schedule.put"; }
echo "$AA2" | grep -q '"actor":"user"' || { echo "$AA2" >&2; fail "audit actor"; }

# 4n) C2：请求列表 / 详情（分页）
RL=$(curl -s --max-time 5 -H "Authorization: Bearer $TOKEN" "$BASE/v1/requests?limit=5&offset=0")
echo "$RL" | grep -q '"request_id"' || { echo "$RL" >&2; fail "requests list"; }
echo "$RL" | grep -q '"limit":5' || { echo "$RL" >&2; fail "requests limit"; }
RID=$(echo "$RL" | grep -o '"request_id":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')
[ -n "$RID" ] || { echo "$RL" >&2; fail "requests id"; }
RD=$(curl -s --max-time 5 -H "Authorization: Bearer $TOKEN" "$BASE/v1/requests?id=$RID")
echo "$RD" | grep -q "\"request_id\":\"$RID\"" || { echo "$RD" >&2; fail "request detail"; }
echo "$RD" | grep -q '"cost_nano"' || { echo "$RD" >&2; fail "request cost"; }
R401=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/v1/requests")
[ "$R401" = "401" ] || fail "requests unauthorized expected 401 got $R401"
R404=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/v1/requests?id=nope")
[ "$R404" = "404" ] || fail "requests unknown id expected 404 got $R404"

# 4m) C5：管理后台（用户/供应商/节点/定价/备份 + 页面）
AU=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/users")
echo "$AU" | grep -q 'e2e@example.com' || { echo "$AU" >&2; fail "admin users"; }
AP=$(curl -s --max-time 5 -H 'Authorization: Bearer test-admin' "$BASE/admin/providers")
echo "$AP" | grep -q '"name":"mock"' || { echo "$AP" >&2; fail "admin providers"; }
AU401=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/admin/users")
[ "$AU401" = "401" ] || fail "admin users expected 401, got $AU401"
ADM=$(curl -s --max-time 5 "$BASE/admin")
echo "$ADM" | grep -q 'id="admin-audit"' || { echo "$ADM" >&2; fail "admin audit section"; }
echo "$ADM" | grep -q 'id="admin-users"' || { echo "$ADM" >&2; fail "admin page"; }
echo "$ADM" | grep -q 'id="pe-schedule"' || { echo "$ADM" >&2; fail "admin schedule input"; }
echo "$ADM" | grep -q '价目表' || { echo "$ADM" >&2; fail "admin price table"; }
ADMJ=$(curl -s --max-time 5 "$BASE/ui/admin.js")
echo "$ADMJ" | grep -q '/admin/price-entries' || { echo "$ADMJ" >&2; fail "admin js pricing"; }
echo "$ADMJ" | grep -q '/admin/bind' || { echo "$ADMJ" >&2; fail "admin js bind"; }
echo "$ADMJ" | grep -q '/admin/providers' || { echo "$ADMJ" >&2; fail "admin js"; }
echo "$ADMJ" | grep -q 'pe-schedule' || { echo "$ADMJ" >&2; fail "admin js schedule"; }

# 4l) C4：预算设置与告警（当月已用来自 usage_daily）
BG=$(curl -s --max-time 5 -H "Authorization: Bearer $TOKEN" "$BASE/v1/budget")
echo "$BG" | grep -q '"monthly_nano":0' || { echo "$BG" >&2; fail "budget get"; }
BS=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" --data '{"monthly_nano":1}' "$BASE/v1/budget")
echo "$BS" | grep -q '"over_budget":true' || { echo "$BS" >&2; fail "budget over"; }
BS2=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" --data '{"monthly_nano":100000000}' "$BASE/v1/budget")
echo "$BS2" | grep -q '"over_budget":false' || { echo "$BS2" >&2; fail "budget under"; }
# C4：站内通知（预算超额写一条，同月不重复；无 token 401）
NT=$(curl -s --max-time 5 -H "Authorization: Bearer $TOKEN" "$BASE/v1/notifications")
echo "$NT" | grep -q '"kind":"budget.over"' || { echo "$NT" >&2; fail "notify budget"; }
echo "$NT" | grep -q '"limit_nano":1' || { echo "$NT" >&2; fail "notify limit"; }
NTN=$(echo "$NT" | grep -c '"kind":"budget.over"')
[ "$NTN" = "1" ] || fail "notify dedup count=$NTN"
NT401=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/v1/notifications")
[ "$NT401" = "401" ] || fail "notify expected 401, got $NT401"

# 4k) C3：费用估算（价格来自 seed 的 sell 价目）
EST=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"model":"mock-model","provider":"mock","prompt_tokens":1000,"completion_tokens":500}' "$BASE/v1/estimate")
echo "$EST" | grep -q '"price_nano"' || { echo "$EST" >&2; fail "estimate"; }
EST2=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $TOKEN" \
  --data '{"model":"nope-model","provider":"mock","prompt_tokens":1,"completion_tokens":1}' "$BASE/v1/estimate")
echo "$EST2" | grep -q '"error"' || { echo "$EST2" >&2; fail "estimate 404"; }

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
echo "$UI" | grep -q 'id="estimate"' || { echo "$UI" >&2; fail "ui estimate"; }
echo "$UI" | grep -q 'id="playground"' || { echo "$UI" >&2; fail "ui playground"; }
echo "$UI" | grep -q 'id="req-table"' || { echo "$UI" >&2; fail "ui requests"; }
echo "$UI" | grep -q 'id="billing"' || { echo "$UI" >&2; fail "ui billing"; }
echo "$UIJS" | grep -q '/v1/budget' || { echo "$UIJS" >&2; fail "ui budget js"; }
echo "$UI" | grep -q 'id="notifications"' || { echo "$UI" >&2; fail "ui notifications"; }
echo "$UIJS" | grep -q '/v1/notifications' || { echo "$UIJS" >&2; fail "ui notifications js"; }
echo "$UIJS" | grep -q '/v1/chat/completions' || { echo "$UIJS" >&2; fail "ui playground js"; }
echo "$UIJS" | grep -q '/v1/estimate' || { echo "$UIJS" >&2; fail "ui estimate js"; }
HDR=$(curl -s --max-time 5 -D - -o /dev/null "$BASE/")
echo "$HDR" | grep -qi "content-security-policy: default-src 'self'" || { echo "$HDR" >&2; fail "csp"; }
echo "$HDR" | grep -qi 'x-content-type-options: nosniff' || { echo "$HDR" >&2; fail "nosniff"; }
echo "$HDR" | grep -qi 'x-frame-options: DENY' || { echo "$HDR" >&2; fail "xfo"; }
echo "$HDR" | grep -qi 'referrer-policy: no-referrer' || { echo "$HDR" >&2; fail "referrer"; }
# XSS：前端只用 textContent 写用户数据（无 innerHTML 注入）
echo "$UIJS" | grep -q 'textContent' || { echo "$UIJS" >&2; fail "xss textContent"; }
if echo "$UIJS" | grep -q 'innerHTML='; then
  if echo "$UIJS" | grep -v "innerHTML=''" | grep -q 'innerHTML='; then fail "xss innerHTML"; fi
fi
# 越权：撤别人的 Key / 无 admin key 访问管理接口都被拒
RC=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" --data '{"key_id":99999}' "$BASE/v1/keys/revoke")
[ "$RC" = "404" ] || fail "cross-user revoke expected 404 got $RC"
RC=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/admin/users")
[ "$RC" = "401" ] || fail "admin no-auth expected 401 got $RC"
CT=$(curl -s --max-time 5 -o /dev/null -w '%{content_type}' "$BASE/")
case "$CT" in text/html*) ;; *) fail "ui content-type=$CT";; esac

# 4h) B5：controller 幂等 ingest（重复批 duplicate=2）
ING='{"rows":[{"request_id":"ing1","user_id":1,"ts":1700000000,"model":"mock-model","provider":"mock","input_tokens":10,"output_tokens":5,"cache_read_tokens":0,"cost_nano":2,"price_nano":3,"period":"","rate_version":1},{"request_id":"ing2","user_id":1,"ts":1700000060,"model":"mock-model","provider":"mock","input_tokens":20,"output_tokens":10,"cache_read_tokens":0,"cost_nano":4,"price_nano":6,"period":"","rate_version":1}]}'
I1=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' --data "$ING" "$BASE/controller/ingest")
echo "$I1" | grep -q '"applied":2' || { echo "$I1" >&2; fail "ingest applied"; }
I2=$(curl -s --max-time 5 -X POST -H 'Authorization: Bearer test-admin' --data "$ING" "$BASE/controller/ingest")
echo "$I2" | grep -q '"duplicate":2' || { echo "$I2" >&2; fail "ingest duplicate"; }

# 4y) A4：上游事件驱动等待下的 p99（20 次顺序 chat；上游是本地 TLS mock）
LAT="$TMP/lat.txt"
: > "$LAT"
# D2：连接池复用——这 20 次顺序请求不应各建一条 TCP/TLS 连接
CONN0=$(wc -l < "$TMP/conns.txt" 2>/dev/null | tr -d ' ' || echo 0)
[ -n "$CONN0" ] || CONN0=0
for i in $(seq 1 20); do
  curl -s --max-time 10 -o /dev/null -w '%{time_total}\n' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data '{"model":"mock-model","messages":[{"role":"user","content":"ping"}]}' \
    "$BASE/v1/chat/completions" >> "$LAT"
done
CONN1=$(wc -l < "$TMP/conns.txt" 2>/dev/null | tr -d ' ' || echo 0)
[ -n "$CONN1" ] || CONN1=0
CONND=$((CONN1 - CONN0))
[ "$CONND" -le 2 ] || fail "pool not reusing: 20 chats opened $CONND conns"
echo "CHAT-POOL reused conns_delta=$CONND"
P99=$(sort -n "$LAT" | awk '{a[NR]=$1} END{print a[int(NR*0.99)]}')
AVG=$(awk '{s+=$1} END{printf "%.4f", s/NR}' "$LAT")
awk -v p="$P99" 'BEGIN{exit !(p>0 && p<1.0)}' || fail "chat p99=$P99"
echo "CHAT-LAT n=20 avg=${AVG}s p99=${P99}s"

# 4z) 大请求体：>32 KiB 不再 413（默认上限 8 MiB），上游收到完整 body
python3 - "$TMP/big.json" <<'PY'
import sys
blob = (b'{"model":"mock-model","messages":[{"role":"user","content":"'
        + b'a' * 300000 + b'"}]}')
with open(sys.argv[1], 'wb') as f:
    f.write(blob)
PY
BIGSZ=$(wc -c < "$TMP/big.json" | tr -d ' ')
BCODE=$(curl -s --max-time 30 -o "$TMP/big_resp.json" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary "@$TMP/big.json" "$BASE/v1/chat/completions")
[ "$BCODE" = "200" ] || { cat "$TMP/big_resp.json" >&2; fail "big body status=$BCODE size=$BIGSZ"; }
grep -q '"usage"' "$TMP/big_resp.json" || { cat "$TMP/big_resp.json" >&2; fail "big body usage"; }
REQSZ=$(wc -c < "$TMP/req.json" | tr -d ' ')
[ "$REQSZ" -ge "$BIGSZ" ] || fail "big body truncated upstream: $REQSZ < $BIGSZ"
grep -q '"upstream-model"' "$TMP/req.json" || fail "big body model not rewritten"
grep -q '"content":"aaa' "$TMP/req.json" || fail "big body content lost"
echo "CHAT-BIG size=$BIGSZ upstream=$REQSZ"

# 4z2) 超过 --max-body（默认 8 MiB）→ 413，且服务不受影响
python3 - "$TMP/huge.json" <<'PY'
import sys
chunk = b'a' * 65536
with open(sys.argv[1], 'wb') as f:
    f.write(b'{"model":"mock-model","messages":[{"role":"user","content":"')
    left = 9 * 1024 * 1024
    while left > 0:
        w = chunk[:min(left, len(chunk))]
        f.write(w)
        left -= len(w)
    f.write(b'"}]}')
PY
HCODE=$(curl -s --max-time 60 -o "$TMP/huge_resp.json" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary "@$TMP/huge.json" "$BASE/v1/chat/completions")
[ "$HCODE" = "413" ] || { head -c 200 "$TMP/huge_resp.json" >&2; fail "oversize expected 413 got $HCODE"; }
grep -q 'payload too large' "$TMP/huge_resp.json" || { cat "$TMP/huge_resp.json" >&2; fail "413 body"; }
AFTER=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"mock-model","messages":[{"role":"user","content":"after"}]}' \
  "$BASE/v1/chat/completions")
[ "$AFTER" = "200" ] || fail "after oversize status=$AFTER"
echo "CHAT-413 oversize=$HCODE after=$AFTER"

# 5) 停机后查账本
kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
SRV_PID=""
# A4：逐请求日志（reqlog 行追加到 <data_dir>/requests.log）
REQLOG="$TMP/data/requests.log"
[ -f "$REQLOG" ] || fail "reqlog missing"
grep -q 'endpoint=/v1/chat/completions' "$REQLOG" || { head -3 "$REQLOG" >&2; fail "reqlog endpoint"; }
grep -q 'endpoint=/v1/responses' "$REQLOG" || fail "reqlog responses endpoint"
grep -q 'model=mock-model' "$REQLOG" || fail "reqlog model"
grep -q 'provider=mock' "$REQLOG" || fail "reqlog provider"
grep -q 'status=200' "$REQLOG" || fail "reqlog status"
grep -q 'email=http@example.com' "$REQLOG" || fail "reqlog email"
grep -q 'stream=1' "$REQLOG" || fail "reqlog stream"
grep -q 'ua=curl' "$REQLOG" || fail "reqlog ua"
grep -q 'toks_x100=' "$REQLOG" || fail "reqlog toks"
echo "CHAT-REQLOG lines=$(wc -l < "$REQLOG")"
# B5：controller 分片后账本在 usage-<k>.db；逐库求和（不含则不重复计）。
COUNT=0
for db in "$SEED_DB" "$TMP/data"/usage-*.db; do
  [ -f "$db" ] || continue
  C=$(AIGW_MODE=count AIGW_DB="$db" ./build/seed | sed -n 's/^COUNT=//p')
  [ -n "$C" ] || fail "count db=$db"
  COUNT=$((COUNT + C))
done
# D3 的 retry-model 请求也会落一条（32 + 1）
# D5 的两次 plug-model 调用也落账（33 + 2）
# 4z 的大包请求与超限后的恢复请求各落一条（36 + 2）
[ "$COUNT" = "38" ] || fail "usage_ledger count=$COUNT"
echo "CHAT-ALL-OK status=$CODE count=$COUNT"
