# TODO DONE

> 已完成任务，按完成顺序追加。
> 查提交：`git log --grep='<TASK-ID>' --oneline`。
> 未完成任务见 `TODO.md`。

| ID | 完成日期 | 提交 | 说明 |
|---|---|---|---|
| DOC-01 | 2026-10-24 | `git log --grep=DOC-01` | 仓库初始化（git init + .gitignore）、`docs/design/overview.md`、`docs/design/tls-provider.md`、`docs/runbooks/restore.md`、`TODO.md`、`TODO_DONE.md` |
| TLS-01 | 2026-10-24 | `git log --grep=TLS-01` | `src/net/urlx.uya`：URL 解析/归一（https/http、IPv6、fragment、query、userinfo 拒绝、长度上限）；`tests/test_urlx.uya` 30 个用例全过（`uya test src/net/urlx.uya tests/test_urlx.uya`） |
| TLS-02 | 2026-10-24 | `git log --grep=TLS-02` | `src/net/dnsx.uya`：IPv4 解析、`/etc/hosts` 解析、`resolv.conf` 扫描、正/负缓存 + LRU、`@async_fn` A/AAAA 查询；`tests/test_dnsx.uya` 5 组用例全过（`uya test src/net/dnsx.uya tests/test_dnsx.uya`） |
| TLS-03 | 2026-10-24 | `git log --grep=TLS-03` | `src/net/tcpx.uya`：sockaddr_in 构造、非阻塞 connect（复用 `std.async.async_connect`）、超时/错误分类、NODELAY/KEEPALIVE、同步包装；`tests/test_tcpx.uya` 4 组用例全过（本机回环，不依赖外网） |
| TLS-04 | 2026-10-24 | `git log --grep=TLS-04` | `src/net/tlsx.uya`：SHA-256 指纹、leaf 解析、pin（多值/大小写折叠）、TOFU 多证书库（同一 host 多条）、链门控判定（新证书只有链校验通过才追加，fail-closed）、TSV 存取；`tests/test_tlsx.uya` 4 组用例全过（含同域多证书场景） |
| TLS-04A | 2026-10-24 | `git log --grep=TLS-04A` | `src/net/chainx.uya`（移植 uya-agent `cachain`）、`src/net/x509min.uya`、`src/net/rsav.uya`、`src/foundation/buf.uya`：完整链校验（逐跳签名/SAN/pathLen/keyCertSign/有效期/未知 critical 扩展 fail-closed）；openssl 三级链 fixture，6 组用例全过（有效/错主机/缺中间/不可信锚/篡改签名/空库） |
| TLS-05 | 2026-10-24 | `git log --grep=TLS-05` | spike（**负面结论**）：`https_handshake_async` 每次 poll 重跑阻塞版握手，非阻塞 fd 上反复重发 ClientHello、永不完成；证据/复现/三条备选见 `docs/design/tls-spike-findings.md`；转为 TLS-05A（自写可恢复握手） |
| TLS-05A | 2026-10-24 | `git log --grep=TLS-05A` | `src/net/tlsx_conn.uya` 可恢复握手：`ssl_handshake_step` + 异步读完整 TLS record + ServerHelloDone 聚合 + 消费 CCS/Finished；本机 openssl s_server 端到端 `TLS-SPIKE-OK`；配合 chainx 完成 SAN + 完整链校验 |
| TLS-06 | 2026-10-24 | `git log --grep=TLS-06` | `src/net/httpc.uya`：请求构造（Host/Content-Length/keep-alive）、响应头解析（状态码/头/Content-Length/chunked/Connection）、1xx 跳过、分块解码（完整/部分/0 块/trailer/畸形）、异步写请求/读头/按 CL 读体；`tests/test_httpc.uya` 5 组用例全过 |
| TLS-07 | 2026-10-24 | `git log --grep=TLS-07` | `src/net/ssex.uya`：增量 SSE 解析（多行 data/event/id/注释/CRLF）、`[DONE]` 判定、跨包分帧、行/数据上限；`tests/test_ssex.uya` 6 组用例全过 |
| TLS-08 | 2026-10-24 | `git log --grep=TLS-08` | `src/net/httpc_pool.uya`：SSRF 私网拒绝（RFC1918/loopback/link-local/CGNAT/保留段）、可重试状态码分类、指数退避（Retry-After 优先）、按 (host,port,trust) 连接池 + idle TTL + LRU；`tests/test_httpc_pool.uya` 6 组用例全过；代理 CONNECT 因需 TlsxConn 并入 TLS-09 |
| TLS-09A | 2026-10-24 | `git log --grep=TLS-09A` | `src/providers/http.uya`：密钥解析（env/file/literal）、模型别名、鉴权头（Bearer/x-api-key/api-key/query）、OpenAI 风格错误体（最小转义）；`tests/test_provider_http.uya` 6 组用例全过；异步 chat 调用留在 TLS-09 |
