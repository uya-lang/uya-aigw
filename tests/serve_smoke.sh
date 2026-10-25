#!/usr/bin/env bash
# A1 冒烟：`aigw serve` 起监听 → /healthz 200 → 未知路径 404 → keep-alive 复用
# → 大包体（64 KiB，超过读缓冲）排空后同连接仍可用。
#
# 端口用 `--port 0` 由内核分配，从服务端 stdout 的 `listen port=N` 读回真实端口，
# 避免脚本选端口与服务端绑定时序不一致。
set -uo pipefail
cd "$(dirname "$0")/.."

UYA=${UYA:-/home/winger/uya/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-/home/winger/uya/uya/lib}
TMP=$(mktemp -d)
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null
    for _ in $(seq 1 40); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.05
    done
    kill -9 "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fail() {
  echo "SERVE-FAIL $*" >&2
  echo "--- server log ---" >&2
  cat "$TMP/serve.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p build
rm -f build/aigw
# 构建失败不能静默复用旧二进制（曾经因此把「旧行为」当成新代码来诊断）。
build_aigw() {
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
    -o build/aigw
}
if ! build_aigw >"$TMP/build.log" 2>&1; then
  # Uya 0.11 的 .uyacache 按 `uya_cimport_N.o` 位置命名：新增 @c_import 后
  # 旧对象可能错配（make 按 mtime 认为不用重编）。清一次缓存重试。
  rm -rf .uyacache
  if ! build_aigw >"$TMP/build.log" 2>&1; then
    cat "$TMP/build.log" >&2
    fail "build"
  fi
fi
[ -x build/aigw ] || fail "build produced no binary"

./build/aigw serve --host 127.0.0.1 --port 0 \
  --db "$TMP/data/aigw.db" --data-dir "$TMP/data" >"$TMP/serve.log" 2>&1 &
PID=$!

# 等服务端打印真实端口（最多 10 s）
PORT=""
for _ in $(seq 1 200); do
  PORT=$(sed -n 's/^listen port=\([0-9]\{1,\}\).*/\1/p' "$TMP/serve.log" 2>/dev/null | head -1)
  [ -n "$PORT" ] && break
  kill -0 "$PID" 2>/dev/null || fail "server exited before listening"
  sleep 0.05
done
[ -n "$PORT" ] || fail "no listen port reported"
[ "$PORT" != "0" ] || fail "port 0 not resolved"
# A2 接线：启动流程必须真的打开/迁移了数据库
[ -f "$TMP/data/aigw.db" ] || fail "database not created by serve startup"

BASE="http://127.0.0.1:$PORT"

# 1) /healthz
BODY=$(curl -s --max-time 5 "$BASE/healthz")
[ "$BODY" = '{"ok":true}' ] || fail "healthz body=[$BODY]"

# 2) /v1/models 占位
MODELS=$(curl -s --max-time 5 "$BASE/v1/models")
case "$MODELS" in
  '{"object":"list","data":[]}') ;;
  *) fail "models body=[$MODELS]" ;;
esac

# 3) chat 路由：body 采集 + Bearer 鉴权（假 Key → 401）
CODE=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
  -H 'Authorization: Bearer sk-test' --data '{"model":"gpt-4o","stream":true}' \
  "$BASE/v1/chat/completions")
[ "$CODE" = "401" ] || fail "chat route expected 401, got $CODE"
CODE=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
  --data '{"model":"gpt-4o"}' "$BASE/v1/chat/completions")
[ "$CODE" = "401" ] || fail "chat route without auth expected 401, got $CODE"

# 4) 未知路径 404
CODE=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/nope")
[ "$CODE" = "404" ] || fail "404 expected, got $CODE"

# 4) keep-alive：三条请求复用同一条 TCP 连接
#    `num_connects` 在复用连接时为 0 —— 这是「真的 keep-alive」而不是三条新连接。
SEQ=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}:%{num_connects},' "$BASE/healthz" \
      --next -s --max-time 5 -o /dev/null -w '%{http_code}:%{num_connects},' "$BASE/healthz" \
      --next -s --max-time 5 -o /dev/null -w '%{http_code}:%{num_connects},' "$BASE/nope")
[ "$SEQ" = "200:1,200:0,404:0," ] || fail "keep-alive seq=$SEQ"

# 5) 64 MiB 包体（远大于 16 KiB 读缓冲）→ 排空后再发一条必须仍然正确
head -c 67108864 /dev/zero | tr '\0' 'a' >"$TMP/big.txt"
BIG=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' --data-binary @"$TMP/big.txt" "$BASE/nope")
[ "$BIG" = "404" ] || fail "big body status=$BIG"
AFTER=$(curl -s --max-time 5 "$BASE/healthz")
[ "$AFTER" = '{"ok":true}' ] || fail "after big body=[$AFTER]"

kill -0 "$PID" 2>/dev/null || fail "server died"

# 6) 线程数恒 1：并发全部走 epoll，进程内没有第二个线程
THREADS=$(awk '/^Threads:/ {print $2}' "/proc/$PID/status" 2>/dev/null)
[ "$THREADS" = "1" ] || fail "threads=$THREADS (expect 1)"

# 7) 512 并发 SSE：每条连接 20 个事件，全部并行推完
ulimit -n 4096 2>/dev/null || true
SSE_OUT=$(python3 tests/serve_sse_load.py "$PORT" 512 20 2>&1) || fail "sse load: $SSE_OUT"
case "$SSE_OUT" in
  SSE-OK*) ;;
  *) fail "sse load: $SSE_OUT" ;;
esac

# 8) 并发压完以后服务仍然正常（槽位已回收）
AFTER2=$(curl -s --max-time 5 "$BASE/healthz")
[ "$AFTER2" = '{"ok":true}' ] || fail "after sse body=[$AFTER2]"

# 9) 优雅停机：SIGTERM → 3 s 内以 0 退出（不是被信号打死）
kill -TERM "$PID"
WAITED=0
while kill -0 "$PID" 2>/dev/null; do
  WAITED=$((WAITED + 1))
  [ "$WAITED" -gt 60 ] && fail "server did not exit within 3s after SIGTERM"
  sleep 0.05
done
wait "$PID"
RC=$?
PID=""
[ "$RC" = "0" ] || fail "graceful exit code=$RC (expect 0)"

echo "SERVE-ALL-OK port=$PORT $SSE_OUT threads=$THREADS"
