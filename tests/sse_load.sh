#!/usr/bin/env bash
# B4/A4：网关侧 SSE 并发（1000 条连接）与尾延迟基线。
set -u
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; [ -n "$PID" ] && wait "$PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "LOAD-FAIL $*" >&2; exit 1; }

CONNS="${1:-1000}"
EVENTS="${2:-20}"

./build/aigw serve --host 127.0.0.1 --port 0 --db "$TMP/a.db" --data-dir "$TMP" >"$TMP/serve.log" 2>&1 &
PID=$!
sleep 0.6
PORT=$(sed -n 's/^listen port=\([0-9]*\).*/\1/p' "$TMP/serve.log" | head -1)
[ -n "$PORT" ] || { cat "$TMP/serve.log" >&2; fail "serve port"; }

T0=$(date +%s%N)
python3 tests/serve_sse_load.py "$PORT" "$CONNS" "$EVENTS" || fail "sse load $CONNS conns"
T1=$(date +%s%N)
MS=$(( (T1 - T0) / 1000000 ))
echo "LOAD-OK conns=$CONNS events=$EVENTS elapsed_ms=$MS"
