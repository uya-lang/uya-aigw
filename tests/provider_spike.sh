#!/usr/bin/env bash
# TLS-09 端到端：本机 Python TLS 上游 + Uya 供应商调用（CL / chunked / SSE）
set -euo pipefail
cd "$(dirname "$0")/.."

UYA=${UYA:-/home/winger/uya/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-/home/winger/uya/uya/lib}
TMP=$(mktemp -d)
SRV_PID=""

cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# 三级链：root -> inter -> leaf(SAN=localhost)
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/root.key" -out "$TMP/root.pem" \
  -days 2 -subj "/CN=Prov Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/inter.key" -out "$TMP/inter.csr" \
  -subj "/CN=Prov Intermediate CA" 2>/dev/null
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n" > "$TMP/inter.ext"
openssl x509 -req -in "$TMP/inter.csr" -CA "$TMP/root.pem" -CAkey "$TMP/root.key" \
  -CAcreateserial -out "$TMP/inter.pem" -days 2 -extfile "$TMP/inter.ext" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/leaf.key" -out "$TMP/leaf.csr" \
  -subj "/CN=localhost" 2>/dev/null
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nsubjectAltName=DNS:localhost\n" > "$TMP/leaf.ext"
openssl x509 -req -in "$TMP/leaf.csr" -CA "$TMP/inter.pem" -CAkey "$TMP/inter.key" \
  -CAcreateserial -out "$TMP/leaf.pem" -days 2 -extfile "$TMP/leaf.ext" 2>/dev/null

PORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)

cat > "$TMP/srv.py" <<'PY'
import http.server, ssl, sys, time
port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        body = b'{"data":[{"id":"m1"}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(n)
        stall = self.path == "/v1/stall"
        if self.headers.get("Accept") == "text/event-stream" and stall:
            # TLS-09E：发一条事件后就**不再发**（模拟上游半开），客户端必须靠空闲超时收尾
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            payload = b"data: {\"i\":0}\n\n"
            self.wfile.write(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")
            self.wfile.flush()
            time.sleep(30)
            return
        if self.headers.get("Accept") == "text/event-stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(3):
                payload = ("data: {\"i\":%d}\n\n" % i).encode()
                self.wfile.write(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")
                self.wfile.flush()
            payload = b"data: [DONE]\n\n"
            self.wfile.write(("%x\r\n" % len(payload)).encode() + payload + b"\r\n0\r\n\r\n")
            self.wfile.flush()
        else:
            body = b'{"ok":true,"n":3}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(("%x\r\n" % len(body)).encode() + body + b"\r\n0\r\n\r\n")
            self.wfile.flush()

srv = http.server.HTTPServer(("127.0.0.1", port), H)
sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
sctx.load_cert_chain(cert, key)
srv.socket = sctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY

cat "$TMP/leaf.pem" "$TMP/inter.pem" > "$TMP/fullchain.pem"
python3 "$TMP/srv.py" "$PORT" "$TMP/fullchain.pem" "$TMP/leaf.key" >"$TMP/srv.log" 2>&1 &
SRV_PID=$!

READY=0
for _ in $(seq 1 80); do
  if ss -ltn "sport = :$PORT" 2>/dev/null | grep -q LISTEN; then READY=1; break; fi
  sleep 0.1
done
if [ "$READY" != "1" ]; then
  echo "上游未就绪" >&2; cat "$TMP/srv.log" >&2 || true; exit 10
fi

mkdir -p build
UYA_ROOT="$UYA_ROOT" "$UYA" build \
  src/foundation/buf.uya src/net/rsav.uya src/net/x509min.uya src/net/chainx.uya \
  src/net/urlx.uya src/net/dnsx.uya src/net/tcpx.uya src/net/tlsx.uya \
  src/net/tlsx_conn.uya src/net/httpc.uya src/net/ssex.uya src/net/httpc_pool.uya \
  src/net/proxyx.uya src/providers/http.uya src/providers/httpcall.uya \
  tests/provider_spike_main.uya -o build/provider_spike

set +e
AIGW_TLS_PORT="$PORT" AIGW_TLS_ROOT="$TMP/root.pem" timeout 40 ./build/provider_spike
RC=$?
set -e
if [ "$RC" != "0" ]; then echo "--- server log ---"; cat "$TMP/srv.log"; fi
exit "$RC"
