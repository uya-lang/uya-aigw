#!/usr/bin/env bash
# D4 e2e：出站代理（CONNECT）——aigw serve --proxy → 本地 CONNECT 代理 → TLS mock 上游
#
# 断言：chat 走代理成功（200 + hello-from-mock），且代理确实收到 `CONNECT localhost:<port>`。
set -euo pipefail
cd "$(dirname "$0")/.."
# 环境里的 HTTPS_PROXY/NO_PROXY 会干扰断言：本脚本自己决定代理。
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

UYA=${UYA:-/home/winger/uya/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-/home/winger/uya/uya/lib}
TMP=$(mktemp -d)
SRV_PID=""
MOCK_PID=""
PROXY_PID=""

cleanup() {
  [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }
  [ -n "$MOCK_PID" ] && { kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true; }
  [ -n "$PROXY_PID" ] && { kill "$PROXY_PID" 2>/dev/null || true; wait "$PROXY_PID" 2>/dev/null || true; }
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "PROXY-FAIL $*" >&2; exit 1; }

# 1) 根 CA + leaf（SAN=localhost）
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/root.key" -out "$TMP/root.pem" \
  -days 2 -subj "/CN=Proxy E2E Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/leaf.key" -out "$TMP/leaf.csr" \
  -subj "/CN=localhost" 2>/dev/null
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nsubjectAltName=DNS:localhost\n" > "$TMP/leaf.ext"
openssl x509 -req -in "$TMP/leaf.csr" -CA "$TMP/root.pem" -CAkey "$TMP/root.key" \
  -CAcreateserial -out "$TMP/leaf.pem" -days 2 -extfile "$TMP/leaf.ext" 2>/dev/null

# 2) TLS mock 上游（多线程：连接池会长期占用 keep-alive 连接）
MPORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)
cat > "$TMP/mock.py" <<'PY'
import http.server, ssl, sys
port, cert, key, reqfile = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
BODY = (b'{"id":"chatcmpl-proxy","object":"chat.completion",'
        b'"choices":[{"message":{"role":"assistant","content":"hello-from-mock"}}],'
        b'"usage":{"prompt_tokens":10,"completion_tokens":5}}')
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        with open(reqfile, "wb") as f:
            f.write(self.rfile.read(n))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY); self.wfile.flush()
srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
srv.daemon_threads = True
sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
sctx.load_cert_chain(cert, key)
srv.socket = sctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
python3 "$TMP/mock.py" "$MPORT" "$TMP/leaf.pem" "$TMP/leaf.key" "$TMP/req.json" \
  >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!

# 3) CONNECT 代理（记录每条 CONNECT，之后双向转发）
cat > "$TMP/proxy.py" <<'PY'
import socket, sys, threading
portfile, logfile = sys.argv[1], sys.argv[2]
ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(("127.0.0.1", 0))
with open(portfile, "w") as f:
    f.write(str(ls.getsockname()[1]))
ls.listen(16)

def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except Exception:
        pass
    try:
        b.shutdown(socket.SHUT_WR)
    except Exception:
        pass

def handle(c):
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = c.recv(4096)
            if not d:
                return
            buf += d
        line = buf.split(b"\r\n")[0].decode(errors="replace")
        with open(logfile, "a") as f:
            f.write(line + "\n")
        parts = line.split()
        if len(parts) < 2 or parts[0] != "CONNECT":
            c.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        host, port = parts[1].rsplit(":", 1)
        up = socket.create_connection((host, int(port)), timeout=5)
        c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        t = threading.Thread(target=pipe, args=(up, c), daemon=True)
        t.start()
        pipe(c, up)
        t.join(timeout=5)
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass

while True:
    conn, _ = ls.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
python3 "$TMP/proxy.py" "$TMP/proxy.port" "$TMP/proxy.log" >"$TMP/proxy.err" 2>&1 &
PROXY_PID=$!
for _ in $(seq 1 100); do
  [ -s "$TMP/proxy.port" ] && break
  sleep 0.05
done
[ -s "$TMP/proxy.port" ] || { cat "$TMP/proxy.err" >&2; fail "proxy not ready"; }
PPORT=$(cat "$TMP/proxy.port")

# 4) 种子 + aigw
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
  --proxy "http://127.0.0.1:$PPORT" --no-proxy "" >"$TMP/serve.log" 2>&1 &
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

# 5) 登录拿 Key（走同一代理链路的是上游，不是这些本地接口）
OTPJSON=$(curl -s --max-time 5 -X POST --data '{"email":"proxy@example.com"}' "$BASE/v1/auth/otp")
CODE=$(echo "$OTPJSON" | sed -n 's/.*"code":"\([0-9]*\)".*/\1/p')
[ -n "$CODE" ] || { echo "$OTPJSON" >&2; fail "otp"; }
LOGIN=$(curl -s --max-time 5 -X POST --data "{\"email\":\"proxy@example.com\",\"code\":\"$CODE\"}" "$BASE/v1/auth/login")
SESSION=$(echo "$LOGIN" | sed -n 's/.*"session":"\([^"]*\)".*/\1/p')
[ -n "$SESSION" ] || { echo "$LOGIN" >&2; fail "login"; }
KEYS=$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $SESSION" --data '{"name":"proxy"}' "$BASE/v1/keys")
TOKEN=$(echo "$KEYS" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "$KEYS" >&2; fail "key"; }

# 6) chat → 必须经代理隧道到 TLS mock
CODE=$(curl -s --max-time 20 -o "$TMP/resp.json" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"mock-model","messages":[{"role":"user","content":"hi"}]}' \
  "$BASE/v1/chat/completions")
[ "$CODE" = "200" ] || { cat "$TMP/resp.json" >&2; cat "$TMP/serve.log" >&2; fail "chat status=$CODE"; }
grep -q 'hello-from-mock' "$TMP/resp.json" || { cat "$TMP/resp.json" >&2; fail "chat body"; }

[ -f "$TMP/proxy.log" ] || fail "proxy saw no CONNECT"
grep -q "CONNECT localhost:$MPORT" "$TMP/proxy.log" || { cat "$TMP/proxy.log" >&2; fail "CONNECT target"; }
grep -q '"upstream-model"' "$TMP/req.json" || fail "upstream did not receive rewritten body"

# 7) no_proxy 真的生效：带 --no-proxy localhost 的实例应直连（代理日志条数不变）
kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
SRV_PID=""
BEFORE=$(wc -l < "$TMP/proxy.log" | tr -d ' ')
./build/aigw serve --host 127.0.0.1 --port 0 --db "$SEED_DB" --data-dir "$TMP/data" \
  --ca "$TMP/root.pem" --dev-otp --admin-key test-admin \
  --proxy "http://127.0.0.1:$PPORT" --no-proxy "localhost" >"$TMP/serve2.log" 2>&1 &
SRV_PID=$!
PORT2=""
for _ in $(seq 1 200); do
  PORT2=$(sed -n 's/^listen port=\([0-9]\{1,\}\).*/\1/p' "$TMP/serve2.log" 2>/dev/null | head -1)
  [ -n "$PORT2" ] && break
  kill -0 "$SRV_PID" 2>/dev/null || { cat "$TMP/serve2.log" >&2; fail "server2 exited"; }
  sleep 0.05
done
[ -n "$PORT2" ] || fail "no port (2)"
CODE2=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"model":"mock-model","messages":[{"role":"user","content":"hi"}]}' \
  "http://127.0.0.1:$PORT2/v1/chat/completions")
[ "$CODE2" = "200" ] || { cat "$TMP/serve2.log" >&2; fail "no-proxy chat status=$CODE2"; }
AFTER=$(wc -l < "$TMP/proxy.log" | tr -d ' ')
[ "$BEFORE" = "$AFTER" ] || fail "no_proxy ignored: proxy lines $BEFORE -> $AFTER"

echo "PROXY-ALL-OK connects=$(wc -l < "$TMP/proxy.log")"
