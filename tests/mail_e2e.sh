#!/usr/bin/env bash
# D7 邮件投递 e2e：/v1/auth/otp → mailer（fork `aigw smtp-relay`）→ SMTP 服务器。
#
# 覆盖四条：
#   1) 正常投递：OTP 返回 200，mock SMTP 真收到一封信（头/正文/认证都对）；
#   2) 非法收件人：地址里带 CRLF → 不投递（不能拿头注入当玩具）；
#   3) **慢 SMTP 不阻塞事件循环**：mock 每条连接先睡 3 s，此时并发打 /healthz
#      必须仍然毫秒级；4 个在途作业最终都送到（子进程各跑各的）；
#   4) SMTP 不可达：OTP 依然 200（异步），失败只记日志，/healthz 不受影响。
set -uo pipefail
cd "$(dirname "$0")/.."
# 出站代理会把 127.0.0.1 也劫持掉，e2e 要确定行为。
unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy

UYA=${UYA:-/home/winger/uya/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-/home/winger/uya/uya/lib}
TMP=$(mktemp -d)
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null
  done
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    for _ in $(seq 1 40); do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.05
    done
    kill -9 "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fail() {
  echo "MAIL-FAIL $*" >&2
  for f in "$TMP"/*.log; do
    [ -f "$f" ] || continue
    echo "--- $f ---" >&2
    tail -40 "$f" >&2
  done
  exit 1
}

mkdir -p build
rm -f build/aigw
build_aigw() {
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
    src/providers/httpcall.uya src/plugins/pool.uya src/providers/plug.uya src/cli/tls_cmd.uya \
    src/net/smtp_msg.uya src/net/smtp.uya src/core/mailer.uya src/app.uya \
    -o build/aigw
}
if ! build_aigw >"$TMP/build.log" 2>&1; then
  rm -rf .uyacache
  if ! build_aigw >"$TMP/build.log" 2>&1; then
    cat "$TMP/build.log" >&2
    fail "build"
  fi
fi
[ -x build/aigw ] || fail "build produced no binary"

# 起一个 mock SMTP：$1=名字 $2=额外参数
start_mock() {
  local name=$1
  shift
  python3 tests/mock_smtp.py --port-file "$TMP/$name.port" --out-dir "$TMP/$name" "$@" \
    >"$TMP/$name.log" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  local port=""
  for _ in $(seq 1 200); do
    port=$(sed -n '1p' "$TMP/$name.port" 2>/dev/null)
    [ -n "$port" ] && break
    kill -0 "$pid" 2>/dev/null || fail "mock $name exited"
    sleep 0.05
  done
  [ -n "$port" ] || fail "mock $name gave no port"
  MOCK_PID=$pid
  MOCK_PORT=$port
}

MOCK_PID=""
MOCK_PORT=""

# 起一个网关：$1=名字，其余透传给 serve
GWPID=""
GWPORT=""
start_gateway() {
  local name=$1
  shift
  ./build/aigw serve --host 127.0.0.1 --port 0 --db "$TMP/$name/aigw.db" \
    --data-dir "$TMP/$name" "$@" >"$TMP/$name.log" 2>&1 &
  GWPID=$!
  PIDS+=("$GWPID")
  local port=""
  for _ in $(seq 1 200); do
    port=$(sed -n 's/^listen port=\([0-9]\{1,\}\).*/\1/p' "$TMP/$name.log" 2>/dev/null | head -1)
    [ -n "$port" ] && break
    kill -0 "$GWPID" 2>/dev/null || fail "gateway $name exited"
    sleep 0.05
  done
  [ -n "$port" ] || fail "gateway $name gave no port"
  GWPORT=$port
}

stop_gateway() {
  [ -n "$GWPID" ] || return 0
  kill -TERM "$GWPID" 2>/dev/null
  local waited=0
  while [ "$waited" -lt 200 ]; do
    kill -0 "$GWPID" 2>/dev/null || return 0
    sleep 0.05
    waited=$((waited + 1))
  done
  fail "gateway did not stop on SIGTERM"
}

otp_post() { # $1=email → 打印 HTTP 状态码
  curl -s --max-time 10 -o "$TMP/otp.json" -w '%{http_code}' -X POST \
    --data "{\"email\":\"$1\"}" "http://127.0.0.1:$GWPORT/v1/auth/otp"
}

wait_msgs() { # $1=目录 $2=期望封数 $3=超时秒数
  local dir=$1 want=$2 timeout=${3:-15}
  local n=0 i=0
  while [ "$i" -lt $((timeout * 20)) ]; do
    n=$(ls "$dir"/msg-*.eml 2>/dev/null | wc -l)
    [ "$n" -ge "$want" ] && { echo "$n"; return 0; }
    i=$((i + 1))
    sleep 0.05
  done
  echo "$n"
  return 1
}

# ---------------------------------------------------------------- 1) 正常投递
start_mock mail_fast
start_gateway gw1 --dev-otp \
  --smtp "127.0.0.1:$MOCK_PORT" --smtp-user bot --smtp-pass 's3cr3t!' \
  --mail-from 'ops@example.com' --mail-hostname aigw-e2e

grep -q '^\[mail\] enabled' "$TMP/gw1.log" || fail "mailer not enabled (log: $(head -5 "$TMP/gw1.log"))"

CODE=$(otp_post 'alice@example.com')
[ "$CODE" = "200" ] || fail "otp status=$CODE body=$(cat "$TMP/otp.json")"
grep -q '"ok":true' "$TMP/otp.json" || fail "otp body=$(cat "$TMP/otp.json")"

COUNT=$(wait_msgs "$TMP/mail_fast" 1 15) || fail "no mail delivered (got $COUNT)"
MSG="$TMP/mail_fast/msg-001.eml"
grep -q '^To: alice@example.com' "$MSG" || fail "To header: $(head -8 "$MSG")"
grep -q '^From: ops@example.com' "$MSG" || fail "From header: $(head -8 "$MSG")"
grep -q '^Subject: ' "$MSG" || fail "no Subject: $(head -8 "$MSG")"
grep -q '^Content-Transfer-Encoding: base64' "$MSG" || fail "no base64 CTE"
grep -q '^Message-ID: <' "$MSG" || fail "no Message-ID"
# 认证真的发生了，且用的是 --smtp-user
grep -qx 'bot' "$TMP/mail_fast/auth.log" || fail "auth user: $(cat "$TMP/mail_fast/auth.log" 2>/dev/null)"
# 正文是 base64：解出来必须是「aigw login code: NNNNNN」（code 只在信里，库里只有 hash）
python3 - "$MSG" >"$TMP/body.txt" <<'PY' || fail "decode body"
import base64, sys
raw = open(sys.argv[1], 'rb').read()
head, _, body = raw.partition(b'\r\n\r\n')
txt = base64.b64decode(body.replace(b'\r\n', b'')).decode('utf-8')
sys.stdout.write(txt)
PY
grep -Eq 'aigw login code: [0-9]{6}' "$TMP/body.txt" || fail "body=$(cat "$TMP/body.txt")"
grep -q 'Valid for' "$TMP/body.txt" || fail "body has no ttl: $(cat "$TMP/body.txt")"
# 子进程日志经父进程转发出来了（父进程最多 200ms 才收尸一次，等一下）
FOUND=0
for _ in $(seq 1 100); do
  if grep -q 'smtp-relay: sent to=alice@example.com' "$TMP/gw1.log" 2>/dev/null; then
    FOUND=1
    break
  fi
  sleep 0.05
done
[ "$FOUND" = "1" ] || fail "relay log missing: $(tail -5 "$TMP/gw1.log")"

# ---------------------------------------------------------------- 2) 非法收件人
BEFORE=$(ls "$TMP/mail_fast"/msg-*.eml 2>/dev/null | wc -l)
CODE=$(otp_post 'evil@example.com')
[ "$CODE" = "200" ] || fail "baseline otp status=$CODE"
wait_msgs "$TMP/mail_fast" $((BEFORE + 1)) 15 >/dev/null || fail "baseline mail missing"
# 地址里塞 CRLF 的注入尝试：要么接口直接拒，要么 mailer 拒收（都不能落一封信）
CODE=$(curl -s --max-time 10 -o "$TMP/inj.json" -w '%{http_code}' -X POST \
  --data '{"email":"a\r\nBcc: evil@example.com"}' "http://127.0.0.1:$GWPORT/v1/auth/otp")
AFTER=$(ls "$TMP/mail_fast"/msg-*.eml 2>/dev/null | wc -l)
[ "$CODE" != "200" ] || fail "CRLF address accepted (status=$CODE)"
[ "$AFTER" = "$((BEFORE + 1))" ] || fail "CRLF address delivered mail ($BEFORE -> $AFTER)"
stop_gateway
GWPID=""

# ---------------------------------------------------------------- 3) 慢 SMTP
start_mock mail_slow --delay-ms 3000
start_gateway gw2 --smtp "127.0.0.1:$MOCK_PORT" --smtp-user bot --smtp-pass pw \
  --mail-from 'ops@example.com'
grep -q '^\[mail\] enabled' "$TMP/gw2.log" || fail "slow: mailer not enabled"

# 4 个并发 OTP：每个都只是「塞进子进程」，HTTP 立刻回 200
CURL_PIDS=()
for i in 1 2 3 4; do
  otp_post "slow$i@example.com" >"$TMP/slow$i.code" &
  CURL_PIDS+=($!)
done
sleep 0.3
# 投递在飞的时候打 /healthz：每条都必须快（事件循环没被 SMTP 拖住）
SLOWEST=0
S=0
while [ "$S" -lt 20 ]; do
  T=$(curl -s -o /dev/null -w '%{http_code}:%{time_total}' --max-time 5 \
      "http://127.0.0.1:$GWPORT/healthz")
  case "$T" in
    200:*) ;;
    *) fail "healthz under slow smtp: $T" ;;
  esac
  MS=$(echo "${T#*:}" | awk '{printf "%d", $1 * 1000}')
  [ "$MS" -gt "$SLOWEST" ] && SLOWEST=$MS
  S=$((S + 1))
done
[ "$SLOWEST" -lt 200 ] || fail "healthz blocked by slow smtp: ${SLOWEST}ms"
# 只等这四条 curl（不能裸 `wait`：mock 与网关还在跑，会一直挂住）
wait "${CURL_PIDS[@]}"
for i in 1 2 3 4; do
  CODE=$(cat "$TMP/slow$i.code")
  [ "$CODE" = "200" ] || fail "slow otp$i status=$CODE"
done
COUNT=$(wait_msgs "$TMP/mail_slow" 4 25) || fail "slow smtp delivered $COUNT/4"
stop_gateway
GWPID=""

# ---------------------------------------------------------------- 4) SMTP 不可达
start_gateway gw3 --smtp '127.0.0.1:1' --mail-from 'ops@example.com'
grep -q '^\[mail\] enabled' "$TMP/gw3.log" || fail "unreachable: mailer not enabled"
CODE=$(otp_post 'nobody@example.com')
[ "$CODE" = "200" ] || fail "unreachable otp status=$CODE (投递是异步的，不该阻塞请求)"
FOUND=0
for _ in $(seq 1 200); do
  if grep -q 'smtp-relay: send failed' "$TMP/gw3.log" 2>/dev/null; then
    FOUND=1
    break
  fi
  sleep 0.05
done
[ "$FOUND" = "1" ] || fail "send failure not logged: $(tail -5 "$TMP/gw3.log")"
grep -q '\[mail\] relay failed' "$TMP/gw3.log" || fail "parent did not account the failure"
BODY=$(curl -s --max-time 5 "http://127.0.0.1:$GWPORT/healthz")
[ "$BODY" = '{"ok":true}' ] || fail "healthz after failure=[$BODY]"
stop_gateway
GWPID=""

echo "MAIL-OK 投递/头注入/慢 SMTP 不阻塞/不可达降级 全通过（slowest /healthz ${SLOWEST}ms）"
