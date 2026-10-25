#!/usr/bin/env bash
# 全量验收：当前已完成的 TLS 栈单测 + 本机 TLS 端到端 spike
set -euo pipefail
cd "$(dirname "$0")/.."

UYA=${UYA:-/home/winger/uya/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-/home/winger/uya/uya/lib}

run() {
  echo "== $*"
  UYA_ROOT="$UYA_ROOT" "$UYA" test "$@"
}

run src/net/urlx.uya tests/test_urlx.uya
run src/net/dnsx.uya tests/test_dnsx.uya
run src/net/tcpx.uya tests/test_tcpx.uya
run src/net/tlsx.uya tests/test_tlsx.uya
run src/foundation/buf.uya src/net/rsav.uya src/net/x509min.uya src/net/chainx.uya tests/test_chainx.uya
run src/foundation/buf.uya src/net/rsav.uya src/net/x509min.uya src/net/chainx.uya src/net/urlx.uya src/net/dnsx.uya src/net/tcpx.uya src/net/tlsx.uya src/net/tlsx_conn.uya src/net/httpc.uya tests/test_httpc.uya
run src/foundation/buf.uya src/net/ssex.uya tests/test_ssex.uya
run src/net/httpc_pool.uya tests/test_httpc_pool.uya
run src/foundation/buf.uya src/providers/http.uya tests/test_provider_http.uya
run src/foundation/buf.uya src/net/proxyx.uya tests/test_proxyx.uya
run src/core/money.uya tests/test_money.uya
run src/core/dbx.uya tests/test_dbx.uya
run src/core/dbx.uya src/core/schema.uya tests/test_schema.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya tests/test_store.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya tests/test_provider_store.uya
run src/core/schedule.uya tests/test_schedule.uya
run src/core/dbx.uya src/core/schema.uya src/core/money.uya src/core/schedule.uya src/core/price.uya tests/test_price.uya
run src/core/dbx.uya src/core/schema.uya src/core/backup.uya tests/test_backup.uya
run src/core/dbx.uya src/core/schema.uya src/core/backup.uya src/core/journal.uya tests/test_journal.uya
run src/core/dbx.uya src/core/schema.uya src/core/money.uya src/core/schedule.uya src/core/store.uya src/core/backup.uya src/core/journal.uya src/core/runtime.uya tests/test_runtime.uya
run src/plugins/pool.uya tests/test_pool.uya
run src/core/json.uya tests/test_json.uya
run src/core/dbx.uya src/core/schema.uya src/core/money.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/backup.uya src/core/journal.uya src/core/billing.uya tests/test_billing.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya src/core/money.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/backup.uya src/core/journal.uya src/core/billing.uya src/core/chat.uya tests/test_chat.uya
run src/foundation/buf.uya src/net/httpsrv.uya tests/test_httpsrv.uya
run src/foundation/buf.uya src/core/money.uya src/core/reqlog.uya tests/test_reqlog.uya

echo "== provider e2e (TLS + chain + CL/chunked/SSE)"
./tests/provider_spike.sh 2>&1 | grep -a "PROV-ALL-OK"
echo "== cli probe/pin"
./tests/tls_cli_spike.sh 2>&1 | grep -a "CLI-ALL-OK"
echo "== http server (A1)"
./tests/serve_smoke.sh 2>&1 | grep -a "SERVE-ALL-OK"
echo "ALL GREEN"
