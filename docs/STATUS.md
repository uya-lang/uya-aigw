# 项目状态快照（2026-10-24）

## 已完成（TLS 栈）

- DOC-01：git 仓库、设计文档（overview / tls-provider / restore runbook / spike findings）、TODO/TODO_DONE
- TLS-01 URL 解析；TLS-02 异步 DNS + 缓存；TLS-03 非阻塞 connect
- TLS-04 多证书信任（同域多指纹、新证书链门控）；TLS-04A 完整链校验（移植 chainx/x509min/rsav/buf）
- TLS-05 spike（负面：`https_handshake_async` 不可恢复）；TLS-05A 自写可恢复握手
- TLS-06 HTTP/1.1 请求/响应/chunked；TLS-07 增量 SSE
- TLS-08 连接池/重试/SSRF；TLS-09A 配置/密钥/错误体；TLS-09B 代理 CONNECT；TLS-09C 请求构造；TLS-09D 状态码映射

**验收命令**：`make check` 与 `./tests/run_all.sh`（含本机 openssl s_server 端到端 `TLS-SPIKE-OK`）。

## 进行中

- TLS-09E：流式**读超时**（两种写法实测失败，候选修法与证据见
  `docs/design/tls-spike-findings.md` §9；当前靠 `[DONE]` 收尾 + 断开取消兜底）。

## Phase A 进展

- A0（money 部分）：`src/core/money.c` + `src/core/money.uya`，nano-USD + `__int128` 助手，
  `tests/test_money.uya` 全过。**SQLite 部分未做**：本机没有 `sqlite3.c/h`，需要 vendor
  amalgamation（离线不可得），见 TODO A0。
- A4（日志部分）：`src/core/reqlog.uya`，一行 `k=v` 的每请求日志（含 cost/tok-s），
  `tests/test_reqlog.uya` 全过。
- A2（已落地）：`schema.uya` 台阶式迁移（users/api_keys/otp_codes/sessions）、`store.uya`
  用户/Key/OTP/会话（`tests/test_store.uya` 含登录→建 key→鉴权端到端）、`schedule.uya`
  分时规则（`tests/test_schedule.uya` 28 断言）、`backup.uya` VACUUM INTO 快照 + 保留
  （`tests/test_backup.uya` 41 断言，快照可独立打开读回）。
  **剩余**：价目表（price_cards/price_entries）落库与查询、计费 journal 追加/重放、
  以及把 store/backup 接到 `aigw serve` 的启动流程。
- A1（服务端）：`src/net/serve.uya` 单线程 epoll 状态机（1024 槽）、64 MiB 包体流式排空、
  chunked SSE、SIGTERM 优雅停机；`tests/serve_smoke.sh` 断言 512 并发 SSE、线程数=1、
  停机退出码 0（`SERVE-ALL-OK`）。

## 下一步

0. ~~A1 事件循环~~（已完成：单线程 epoll + 512 并发 SSE + 优雅停机）

1. ~~TLS-09 → TLS-10 → TLS-11~~（已完成；TLS-09E 流式读超时未落地，findings §9）
2. Phase A：A0 SQLite+money spike、A1 事件循环、A2 schema/认证/备份 … A9 文档/e2e
3. Phase B：controller/node/edge、lease/epoch、ingest/journal
4. Phase C：用户端/管理端后台

## 已知边界

- spike 只验证 TLS 1.2（`s_server -tls1_2`）；TLS 1.3 待补测
- 不做 HTTP/2/3、gzip、入站 TLS（建议 nginx/caddy）
- 备份/journal/计费/集群/后台尚未实现（设计与 TODO 已就绪）
