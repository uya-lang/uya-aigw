# aigw — Uya AI Gateway
# 当前阶段：TLS 栈（DNS/TCP/TLS/链校验/HTTP/SSE/池/代理）
UYA ?= /home/winger/uya/uya/bin/uya
UYA_ROOT ?= /home/winger/uya/uya/lib
SRC := $(shell find src -name '*.uya' | sort)
export UYA_ROOT

.PHONY: check test spike clean

# 类型检查全部源文件（合并命名空间）
check:
	$(UYA) check $(SRC)

# 单测 + 本机 TLS 端到端
test:
	./tests/run_all.sh

spike:
	./tests/tls_spike.sh

clean:
	rm -rf build .uyacache
