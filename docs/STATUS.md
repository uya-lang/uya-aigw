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
- A3（已落地）：`src/plugins/pool.uya` 插件池（stdio JSONL 子进程）：预热 min、复用、
  扩容到 max、空闲缩容到 min、崩溃指数退避、cancel、ping/pong；非阻塞 fd + poll 超时
  与按行分帧。`tests/test_pool.uya` 24 断言（`tests/plugin_echo.py` 作最小插件）。
- A6（进行中）：schema v5 `usage_daily` + `src/core/rollup.uya`（聚合/幂等重建/区间查询）；
  billing 实时 upsert 汇总；`/v1/usage` 已返回 data+totals（e2e 断言 requests=2）。
  下一步 `/v1/models` 动态列表与 rollup 定时重建。
- A4（进行中）：`src/core/json.uya` 有界 JSON DOM + 构造器（44 断言）；
  schema v4 `providers`/`provider_models` + store CRUD/路由（33 断言）；
  `src/core/billing.uya` 结算（usage 双风格解析 + 查价 + journal/ledger 幂等，30 断言）；
  `src/core/chat.uya` 编排（解析/路由/上游请求重写/结算，23 断言）；
  `httpsrv` 已捕获 `Authorization` 头（chat 鉴权的前置）。
  下一步把 `ChatPlan` 接到 serve 的 `POST /v1/chat/completions`（含 SSE 透传）。
- A2（已落地）：`schema.uya` 台阶式迁移（v1 身份、v2 价目、v3 用量账本）、`store.uya`
  用户/Key/OTP/会话（`tests/test_store.uya` 含登录→建 key→鉴权端到端）、`schedule.uya`
  分时规则（`tests/test_schedule.uya` 28 断言）、`backup.uya` VACUUM INTO 快照 + 保留
  （`tests/test_backup.uya` 41 断言，快照可独立打开读回）、`price.uya` 版本化价目 +
  用户覆盖 + 分时金额、`journal.uya` 每日分片 journal + fsync + 幂等重放
  （`tests/test_price.uya` 28 断言、`tests/test_journal.uya` 50 断言）。
  **已接线**：`runtime.uya` 把建目录 / `schema_open` / journal 重放与清理 / 每日备份
  接到 `aigw serve`（`--db`、`--data-dir`）；`tests/test_runtime.uya` 14 断言，
  `serve_smoke.sh` 断言启动建库。**剩余**：请求路径（鉴权 → 调用 → usage 落库/journal）
  在 A4 接上。
- A1（服务端）：`src/net/serve.uya` 单线程 epoll 状态机（1024 槽）、64 MiB 包体流式排空、
  chunked SSE、SIGTERM 优雅停机；`tests/serve_smoke.sh` 断言 512 并发 SSE、线程数=1、
  停机退出码 0（`SERVE-ALL-OK`）。

## 下一步

0. ~~A1 事件循环~~（已完成：单线程 epoll + 512 并发 SSE + 优雅停机）

1. ~~TLS-09 → TLS-10 → TLS-11~~（已完成；TLS-09E 流式读超时未落地，findings §9）
2. Phase A：A0 SQLite+money spike、A1 事件循环、A2 schema/认证/备份/journal、A3 插件池、A4 chat … A9 文档/e2e
3. Phase B：controller/node/edge、lease/epoch、ingest/journal
4. Phase C：用户端/管理端后台
5. A4 剩余接线（下轮直接做）：serve 持有 `HtcCtx`（`--ca <pem>` 读入 bundle，
   默认 `TLSX_MODE_CHAIN`），`ChatPlan → HttppConfig` 映射（host/port/auth_type/secret），
   收到完整 body 后 `upstream_post` → 成功则 `chat_settle` → 原样回上游 JSON；
   `stream=true` 时用 `htc_next_event_async` 逐事件 `hsrv_chunk` 透传并在 `[DONE]` 收尾；
   e2e 复用 `tests/provider_spike.sh` 的 TLS mock（root/inter/leaf）造 `/v1/chat/completions`。
6. A4 拆解（历史）：① `src/core/json.uya`（有界 DOM 解析 + 字符串转义/构造）；
   ② schema v4 `providers`（base_url/host/port/auth/secret/超时/启用）与 store CRUD；
   ③ `POST /v1/chat/completions`：Bearer 鉴权 → `htc_open_async` 上游 → usage 解析 →
   `price_quote` → `usage_ledger` + `journal_append`；④ SSE 透传与 `[DONE]` 对齐。
   测试用 `tests/plugin_echo.py` 同构的 mock provider（Python）跑 e2e。

## 已知边界

- spike 只验证 TLS 1.2（`s_server -tls1_2`）；TLS 1.3 待补测
- 不做 HTTP/2/3、gzip、入站 TLS（建议 nginx/caddy）
- 请求路径（chat → usage → 计费/journal）与集群/后台尚未实现（设计与 TODO 已就绪）
