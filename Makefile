# aigw — Uya AI Gateway
# 当前阶段：TLS 栈（DNS/TCP/TLS/链校验/HTTP/SSE/池/代理）
UYA ?= /home/winger/uya/uya/bin/uya
UYA_ROOT ?= /home/winger/uya/uya/lib
SRC := $(shell find src -name '*.uya' | sort)
export UYA_ROOT

.PHONY: check test spike clean selftest e2e db_bench ui-e2e cluster-e2e load-sse

# 类型检查全部源文件（合并命名空间）
check:
	$(UYA) check $(SRC)

# 单测 + 本机 TLS 端到端
test:
	./tests/run_all.sh

spike:
	./tests/tls_spike.sh

# 全量自检：类型检查 + 全部单测/端到端
selftest: check
	./tests/run_all.sh

# 后台 e2e：静态壳 + 管理后台 + 安全头/越权（C1–C6）
ui-e2e:
	rm -rf .uyacache
	./tests/chat_e2e.sh
	rm -rf .uyacache
	./tests/proxy_e2e.sh

# 网关侧 SSE 并发（默认 1000 连接 × 20 事件）
load-sse: check
	./tests/sse_load.sh 1000 20

# 集群端到端：controller + uplink 注册 + epoch/assign + edge 路由 + drain + ingest（B6）
cluster-e2e:
	rm -rf .uyacache
	./tests/cluster_e2e.sh

# 网关端到端：TLS 上游、CLI、事件循环、chat/responses/admin
e2e:
	./tests/provider_spike.sh
	rm -rf .uyacache
	./tests/tls_cli_spike.sh
	rm -rf .uyacache
	./tests/serve_smoke.sh
	rm -rf .uyacache
	./tests/chat_e2e.sh

# SQLite 写入与汇总基准
db_bench:
	rm -rf .uyacache
	mkdir -p build
	$(UYA) build src/core/dbx.uya src/core/schema.uya src/core/rollup.uya tests/db_bench.uya -o build/db_bench
	./build/db_bench
	rm -rf .uyacache

clean:
	rm -rf build .uyacache
