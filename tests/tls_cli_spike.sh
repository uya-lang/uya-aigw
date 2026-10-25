#!/usr/bin/env bash
# TLS-11：`aigw tls probe/pin` 端到端
set -euo pipefail
cd "$(dirname "$0")/.."
UYA=${UYA:-/home/winger/uya/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-/home/winger/uya/uya/lib}
TMP=$(mktemp -d); SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }; rm -rf "$TMP"; }
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/root.key" -out "$TMP/root.pem" -days 2 \
  -subj "/CN=Cli Root CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/inter.key" -out "$TMP/inter.csr" -subj "/CN=Cli Intermediate" 2>/dev/null
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n" > "$TMP/inter.ext"
openssl x509 -req -in "$TMP/inter.csr" -CA "$TMP/root.pem" -CAkey "$TMP/root.key" -CAcreateserial \
  -out "$TMP/inter.pem" -days 2 -extfile "$TMP/inter.ext" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/leaf.key" -out "$TMP/leaf.csr" -subj "/CN=localhost" 2>/dev/null
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nsubjectAltName=DNS:localhost\n" > "$TMP/leaf.ext"
openssl x509 -req -in "$TMP/leaf.csr" -CA "$TMP/inter.pem" -CAkey "$TMP/inter.key" -CAcreateserial \
  -out "$TMP/leaf.pem" -days 2 -extfile "$TMP/leaf.ext" 2>/dev/null
cat "$TMP/leaf.pem" "$TMP/inter.pem" > "$TMP/fullchain.pem"

PORT=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
cat > "$TMP/srv.py" <<'PY'
import http.server, ssl, sys
port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*a): pass
    def do_GET(self):
        b=b'{}'; self.send_response(200); self.send_header("Content-Length","2"); self.end_headers(); self.wfile.write(b)
srv=http.server.HTTPServer(("127.0.0.1",port),H)
c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain(cert,key)
srv.socket=c.wrap_socket(srv.socket,server_side=True); srv.serve_forever()
PY
python3 "$TMP/srv.py" "$PORT" "$TMP/fullchain.pem" "$TMP/leaf.key" >"$TMP/srv.log" 2>&1 & SRV_PID=$!
for _ in $(seq 1 80); do ss -ltn "sport = :$PORT" 2>/dev/null | grep -q LISTEN && break; sleep 0.1; done

mkdir -p build
UYA_ROOT="$UYA_ROOT" "$UYA" build \
  src/foundation/buf.uya src/net/rsav.uya src/net/x509min.uya src/net/chainx.uya \
  src/net/urlx.uya src/net/dnsx.uya src/net/tcpx.uya src/net/tlsx.uya src/net/tlsx_conn.uya \
  src/net/httpc.uya src/net/ssex.uya src/net/httpc_pool.uya src/net/proxyx.uya \
  src/providers/http.uya src/providers/httpcall.uya src/cli/tls_cmd.uya \
  src/core/money.uya src/core/reqlog.uya src/core/dbx.uya \
  src/core/schema.uya src/core/store.uya src/core/backup.uya src/core/journal.uya \
  src/core/runtime.uya src/core/schedule.uya src/core/price.uya src/core/json.uya \
  src/core/billing.uya src/core/chat.uya src/providers/upstream.uya \
  src/providers/upstream_cfg.uya \
  src/net/httpsrv.uya src/net/serve.uya src/app.uya \
  -o build/aigw

OUT=$(./build/aigw tls probe localhost --port "$PORT" --ca "$TMP/root.pem")
echo "$OUT"
echo "$OUT" | grep -q "status=ok verified=1" || { echo "probe 未通过" >&2; exit 1; }
echo "$OUT" | grep -q "^chain=ok$" || { echo "链校验未通过" >&2; exit 2; }
FP=$(echo "$OUT" | sed -n 's/^fingerprint=sha256:\(.*\)$/\1/p')
[ ${#FP} -eq 64 ] || { echo "指纹长度不对: ${#FP}" >&2; exit 3; }

./build/aigw tls pin localhost "$FP" --file "$TMP/pins.tsv" | tee "$TMP/pin.out"
grep -q "pinned=localhost" "$TMP/pin.out" || exit 4
grep -q "$FP" "$TMP/pins.tsv" || { echo "pin 未落盘" >&2; exit 5; }
echo "CLI-ALL-OK"
