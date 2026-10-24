#!/usr/bin/env bash
# TLS-05 spike：本机 openssl s_server + Uya 异步 TLS 客户端
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

# 1) 三级链：root -> inter -> leaf（SAN=localhost）
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/root.key" -out "$TMP/root.pem" \
  -days 2 -subj "/CN=Spike Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/inter.key" -out "$TMP/inter.csr" \
  -subj "/CN=Spike Intermediate CA" 2>/dev/null
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n" > "$TMP/inter.ext"
openssl x509 -req -in "$TMP/inter.csr" -CA "$TMP/root.pem" -CAkey "$TMP/root.key" \
  -CAcreateserial -out "$TMP/inter.pem" -days 2 -extfile "$TMP/inter.ext" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/leaf.key" -out "$TMP/leaf.csr" \
  -subj "/CN=localhost" 2>/dev/null
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nsubjectAltName=DNS:localhost\n" > "$TMP/leaf.ext"
openssl x509 -req -in "$TMP/leaf.csr" -CA "$TMP/inter.pem" -CAkey "$TMP/inter.key" \
  -CAcreateserial -out "$TMP/leaf.pem" -days 2 -extfile "$TMP/leaf.ext" 2>/dev/null

# 2) 找一个空闲端口
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)

# 3) TLS 服务端（强制 TLS1.2，与 stdlib 客户端一致）
openssl s_server -tls1_2 -accept "127.0.0.1:$PORT" \
  -cert "$TMP/leaf.pem" -key "$TMP/leaf.key" -cert_chain "$TMP/inter.pem" \
  -www -quiet >"$TMP/srv.log" 2>&1 &
SRV_PID=$!

# 4) 等监听（不要用 TCP 探测：s_server 单连接处理，探测会占住唯一的连接）
READY=0
for _ in $(seq 1 50); do
  if ss -ltn "sport = :$PORT" 2>/dev/null | grep -q LISTEN; then
    READY=1
    break
  fi
  sleep 0.1
done
if [ "$READY" != "1" ]; then
  echo "s_server 未就绪" >&2
  cat "$TMP/srv.log" >&2 || true
  exit 10
fi

# 5) 编译 + 运行
mkdir -p build
UYA_ROOT="$UYA_ROOT" "$UYA" build \
  src/foundation/buf.uya src/net/rsav.uya src/net/x509min.uya src/net/chainx.uya \
  src/net/urlx.uya src/net/dnsx.uya src/net/tcpx.uya src/net/tlsx.uya \
  src/net/tlsx_conn.uya tests/tls_spike_main.uya \
  -o build/tls_spike

# TLS-05A 之前预期失败（握手不可恢复），用 timeout 防止挂死
AIGW_TLS_PORT="$PORT" AIGW_TLS_ROOT="$TMP/root.pem" timeout 20 ./build/tls_spike
