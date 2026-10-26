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
run src/foundation/buf.uya src/net/rsav.uya src/net/x509min.uya src/net/chainx.uya src/net/urlx.uya src/net/dnsx.uya src/net/tcpx.uya src/net/tlsx.uya src/net/tlsx_conn.uya src/net/httpc.uya src/net/ssex.uya src/net/httpc_pool.uya src/net/proxyx.uya src/providers/http.uya src/providers/httpcall.uya tests/test_htcpool.uya
run src/foundation/buf.uya src/providers/http.uya tests/test_provider_http.uya
run src/foundation/buf.uya src/providers/http.uya src/providers/upstream_cfg.uya tests/test_upstream_cfg.uya
run src/foundation/buf.uya src/net/proxyx.uya tests/test_proxyx.uya
run src/core/money.uya tests/test_money.uya
run src/core/dbx.uya tests/test_dbx.uya
run src/core/dbx.uya src/core/schema.uya tests/test_schema.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya tests/test_store.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya tests/test_provider_store.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya src/core/lb.uya tests/test_lb.uya
run src/core/schedule.uya tests/test_schedule.uya
run src/core/dbx.uya src/core/schema.uya src/core/money.uya src/core/schedule.uya src/core/price.uya tests/test_price.uya
run src/core/dbx.uya src/core/schema.uya src/core/rollup.uya tests/test_rollup.uya
run src/core/dbx.uya src/cluster/meta.uya tests/test_meta.uya
run src/core/dbx.uya src/cluster/meta.uya tests/test_epoch.uya
run src/core/dbx.uya src/cluster/meta.uya tests/test_rebalance.uya
run src/core/dbx.uya src/cluster/meta.uya tests/test_rebalance_auto.uya
run src/core/dbx.uya src/core/schema.uya src/core/json.uya src/core/rollup.uya src/cluster/ingest.uya src/cluster/shard.uya tests/test_ingest.uya
run src/core/dbx.uya src/core/schema.uya src/core/json.uya src/core/rollup.uya src/cluster/ingest.uya src/cluster/shard.uya tests/test_shard.uya
run src/core/dbx.uya src/cluster/meta.uya src/cluster/edge.uya tests/test_edge.uya
run src/cluster/spool.uya tests/test_spool.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya tests/test_keys.uya
run src/core/dbx.uya src/core/schema.uya src/core/budget.uya tests/test_budget.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya tests/test_admin_list.uya
run src/core/json.uya src/core/dbx.uya src/core/schema.uya src/core/responses.uya tests/test_responses.uya
run src/core/dbx.uya src/cluster/meta.uya src/cluster/elect.uya tests/test_elect.uya
run src/core/dbx.uya src/core/schema.uya src/core/backup.uya tests/test_backup.uya
run src/core/dbx.uya src/core/schema.uya src/core/backup.uya src/core/journal.uya src/cluster/shard.uya tests/test_journal.uya
run src/core/dbx.uya src/core/schema.uya src/core/money.uya src/core/schedule.uya src/core/store.uya src/core/backup.uya src/core/journal.uya src/core/runtime.uya src/cluster/shard.uya tests/test_runtime.uya
run src/plugins/pool.uya tests/test_pool.uya
run src/foundation/buf.uya src/core/json.uya src/plugins/pool.uya src/providers/plug.uya tests/test_plug.uya
run src/core/json.uya tests/test_json.uya
run src/core/dbx.uya src/core/schema.uya src/core/money.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/backup.uya src/core/journal.uya src/core/billing.uya src/cluster/shard.uya tests/test_billing.uya
run src/core/dbx.uya src/core/schema.uya src/core/store.uya src/core/money.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/backup.uya src/core/journal.uya src/core/billing.uya src/core/batch.uya src/cluster/shard.uya tests/test_batch.uya
run src/core/notify.uya src/cluster/spool.uya src/core/json.uya tests/test_notify.uya
run src/net/smtp_msg.uya tests/test_smtp.uya
run src/foundation/buf.uya src/core/dbx.uya src/core/schema.uya src/core/store.uya src/core/money.uya src/core/schedule.uya src/core/price.uya src/core/json.uya src/core/backup.uya src/core/journal.uya src/core/billing.uya src/core/batch.uya src/core/lb.uya src/core/responses.uya src/core/chat.uya src/cluster/shard.uya tests/test_chat.uya
run src/foundation/buf.uya src/net/httpsrv.uya tests/test_httpsrv.uya
run src/foundation/buf.uya src/core/money.uya src/core/reqlog.uya tests/test_reqlog.uya

echo "== provider e2e (TLS + chain + CL/chunked/SSE)"
./tests/provider_spike.sh 2>&1 | grep -a "PROV-ALL-OK"
echo "== cli probe/pin"
./tests/tls_cli_spike.sh 2>&1 | grep -a "CLI-ALL-OK"
# 每个 e2e 脚本编译的文件集合不同，而 uya 0.11 的 `.uyacache` 按
# `uya_cimport_N.o` **位置**命名，跨脚本复用会错配（manifest 已记录旧对象，
# make 按 mtime 认为不用重编）。Makefile 的 e2e 目标同样是每个脚本前清一次。
rm -rf .uyacache
echo "== http server (A1)"
./tests/serve_smoke.sh 2>&1 | grep -a "SERVE-ALL-OK"
rm -rf .uyacache
echo "== chat e2e (auth/route/upstream/ledger)"
./tests/chat_e2e.sh 2>&1 | grep -a "CHAT-ALL-OK"
rm -rf .uyacache
./tests/cluster_e2e.sh 2>&1 | grep -a "CLUSTER-ALL-OK"
rm -rf .uyacache
echo "== mail (SMTP 投递)"
./tests/mail_e2e.sh 2>&1 | grep -a "MAIL-OK"
rm -rf .uyacache
./tests/sse_load.sh 1000 20 2>&1 | grep -a "LOAD-OK"
echo "ALL GREEN"
