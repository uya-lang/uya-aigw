# 项目状态快照（2026-10-25）

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
- A5（流式工具事件）：`srv_responses_stream` 支持 `delta.tool_calls` 分片 →
  `response.output_item.added` / `response.function_call_arguments.delta` /
  `response.output_item.done`，`completed` 带 `output` 数组；chat e2e mock 与断言覆盖。
- A4（快路径/批量落库）：`chat_scan` 顶层扫描（不建 DOM）+ `src/core/batch.uya`
  （512 行/200ms 事务、journal 批追加、查询前 flush）；`tests/test_batch.uya` 与
  `tests/test_chat.uya` fast_path 组覆盖。
- A3/A8（已落地）：`src/plugins/pool.uya` 插件池（stdio JSONL 子进程）：预热 min、复用、
  扩容到 max、空闲缩容到 min、崩溃指数退避、cancel、ping/pong、进程被杀后同槽重绑并重试；
  非阻塞 fd + poll 超时与按行分帧。`tests/test_pool.uya` 34 断言（`tests/plugin_echo.py` 作最小插件）。
- B1（已落地）：meta.db + `elect.uya` + controller 控制面（register/heartbeat/
  config/status，`--meta`/`--node-id`，standby 不备份）。
- B2（进行中）：`uplink.uya` + `--uplink` 已通（node 注册/心跳）；config 快照与
  slug 归属待做。
- B3（已落地）：epoch/fencing/drain + 控制面（421）+ 批量迁移/清零 + stale 自动
  迁移；controller tick 每 3s 触发 rebalance。
- B2 收尾：config 快照与 slug 归属校验。
- B5（进行中）：幂等 ingest（含 HTTP 入口）+ 区间重算 + 本地 spool + Key 吊销已通；
  spool 自动消费循环待做。
- C1（进行中）：静态壳 `/` + `/ui/app.js`（登录/资料/密钥/接入点 + curl 示例）已落地。
- C2（进行中）：`/v1/usage.csv` + 概览/明细表 + CSV 导出已落地；请求列表/详情待做。
- C2（已完成）：`/v1/usage`、`/v1/usage.csv`、`/v1/requests`（列表/详情分页）与 UI 概览页。
- C3（已完成）：Key 管理、估算器、改价（`/admin/price-entries`，含 `schedule` 分时规则校验与
  回显）、模型绑定、管理后台分时价编辑与价目表。
- C4（已完成）：Playground（流式指标）+ 账单预算（schema v8、`/v1/budget`）+
  站内通知（`notify.uya`、`GET /v1/notifications`、预算超额按日去重）。
- C5（已完成）：`/admin` 页 + 用户/供应商列表 + 改价（含分时）/绑定 + 审计日志
  （`audit.jsonl` 记录 price.put/schedule.put/key.create/key.revoke/bind/drain，带 actor）。
- B2（已完成）：uplink 修复 + config 快照（版本/epoch/归属）+ `/node/status` + slug 归属校验（`/edge/route?self=`）。
  旧问题：uplink 之前其实从未成功（`tcpx_connect_v4` 在事件循环里只空转、点分 IP 未解析、
  请求用了非 NUL 结尾的 cstr 追加）；已改为阻塞 socket/connect + `dnsx_parse_ipv4` + 固定缓冲，
  `make cluster-e2e` 用独立 node id 验证注册。
- B4（已完成）：edge 路由核心 + `GET /edge/route`、`/edge/fail`、`GET /edge/proxy`（节点代理 +
  失败清亲和重试）+ `stream=1` SSE 流式转发（chunked 增量解码，cluster e2e 实测首事件 0.000s、
  总时长 0.389s）+ 1k 并发压测（`make load-sse`）。
- B5（已完成）：幂等 ingest、区间重算、spool 重放循环、Key 吊销、journal 重放 +
  usage 分片（controller `usage-<k>.db`，`hash(user_id)%4`，journal/ingest/查询按 uid 路由与合并）。
- B6（已完成）：`make cluster-e2e` 全绿（1 controller + 3 node、epoch/fencing、config 快照、
  edge 路由/亲和/归属、代理、drain 迁移、ingest 幂等、spool 重放）+ `deploy/nginx.conf`、`docs/deploy.md`。
- C6（已完成）：CSP/nosniff/Referrer-Policy/XFO 安全头、XSS/越权断言、`make ui-e2e`、
  `docs/ui.md`；API 全 Bearer、无 Cookie，故 CSRF 面为零（不做双提交 token）。
- B4（已完成）：edge 路由核心（slug 归属 + session 亲和 + 失败清缓存）+ HTTP/SSE 代理。

## 开发命令（A9）

- `make check`：全量类型检查
- `make selftest`：check + `tests/run_all.sh`（全部单测/端到端，末行 `ALL GREEN`）
- `make e2e`：provider → TLS CLI → serve 冒烟 → chat/responses/admin e2e
- `make db_bench`：SQLite 写入 + rollup 基准（5000 行 ≈41ms）

- A2（已落地）：登录→建 key→调用闭环已通：`/v1/auth/otp`（dev 回显）、
  `/v1/auth/login`、`/v1/keys`、`/v1/me`，e2e 用 HTTP 拿 Key 调 chat。
- A6（已落地）：`usage_daily` 汇总 + `rollup` 重建/查询；billing 实时 upsert；
  `/v1/usage`（data+totals 含 profit）与 `/v1/models`；chat e2e 断言 models/usage/profit。
- A8（进行中）：schema v6 priority/weight + `lb.uya`（优先级/加权/会话亲和/熔断），
  serve 失败自动换 provider 重试；插件级重绑待接。
- A7（已落地）：管理 REST（health/pricing GET+POST/billing/backup）+ MCP
  （initialize/tools/list/tools/call：pricing_get、billing_query、backup_status）。
- A5（进行中）：`/v1/responses` 非流式 + previous_response_id 续轮 + 流式事件
  （created/delta/completed）已通；reasoning/tools 仍未透传。
- A4（已完成）：JSON DOM/构造器、providers/路由、billing 结算、chat 编排、serve 接线
  （非流/流式 SSE、tools 透传、失败转移、无 DOM 快路径、512 行/200ms 批量落库）、
  上游等待事件驱动（`src/core/upwait.uya`，epoll 等 waker fd，不再忙轮询）、
  Key 校验单槽缓存（`store_verify_key_fast`，TTL 2s，撤销即失效）。
- B1（已落地）：meta.db + `elect.uya` + controller 控制面（register/heartbeat/
  config/status，`--meta`/`--node-id`，standby 不备份）。
- B2（进行中）：`uplink.uya` + `--uplink` 已通（node 注册/心跳）；config 快照与
  slug 归属待做。
- B3（已落地）：epoch/fencing/drain + 控制面（421）+ 批量迁移/清零 + stale 自动
  迁移；controller tick 每 3s 触发 rebalance。
- B2 收尾：config 快照与 slug 归属校验。
- B5（进行中）：幂等 ingest（含 HTTP 入口）+ 区间重算 + 本地 spool + Key 吊销已通；
  spool 自动消费循环待做。
- C1（进行中）：静态壳 `/` + `/ui/app.js`（登录/资料/密钥/接入点 + curl 示例）已落地。
- C2（进行中）：`/v1/usage.csv` + 概览/明细表 + CSV 导出已落地；请求列表/详情待做。
- C2（已完成）：`/v1/usage`、`/v1/usage.csv`、`/v1/requests`（列表/详情分页）与 UI 概览页。
- C3（已完成）：Key 管理、估算器、改价（`/admin/price-entries`，含 `schedule` 分时规则校验与
  回显）、模型绑定、管理后台分时价编辑与价目表。
- C4（已完成）：Playground（流式指标）+ 账单预算（schema v8、`/v1/budget`）+
  站内通知（`notify.uya`、`GET /v1/notifications`、预算超额按日去重）。
- C5（已完成）：`/admin` 页 + 用户/供应商列表 + 改价（含分时）/绑定 + 审计日志
  （`audit.jsonl` 记录 price.put/schedule.put/key.create/key.revoke/bind/drain，带 actor）。
- B2（已完成）：uplink 修复 + config 快照（版本/epoch/归属）+ `/node/status` + slug 归属校验（`/edge/route?self=`）。
  旧问题：uplink 之前其实从未成功（`tcpx_connect_v4` 在事件循环里只空转、点分 IP 未解析、
  请求用了非 NUL 结尾的 cstr 追加）；已改为阻塞 socket/connect + `dnsx_parse_ipv4` + 固定缓冲，
  `make cluster-e2e` 用独立 node id 验证注册。
- B4（已完成）：edge 路由核心 + `GET /edge/route`、`/edge/fail`、`GET /edge/proxy`（节点代理 +
  失败清亲和重试）+ `stream=1` SSE 流式转发（chunked 增量解码，cluster e2e 实测首事件 0.000s、
  总时长 0.389s）+ 1k 并发压测（`make load-sse`）。
- B5（已完成）：幂等 ingest、区间重算、spool 重放循环、Key 吊销、journal 重放 +
  usage 分片（controller `usage-<k>.db`，`hash(user_id)%4`，journal/ingest/查询按 uid 路由与合并）。
- B6（已完成）：`make cluster-e2e` 全绿（1 controller + 3 node、epoch/fencing、config 快照、
  edge 路由/亲和/归属、代理、drain 迁移、ingest 幂等、spool 重放）+ `deploy/nginx.conf`、`docs/deploy.md`。
- C6（已完成）：CSP/nosniff/Referrer-Policy/XFO 安全头、XSS/越权断言、`make ui-e2e`、
  `docs/ui.md`；API 全 Bearer、无 Cookie，故 CSRF 面为零（不做双提交 token）。
- B4（已完成）：edge 路由核心（slug 归属 + session 亲和 + 失败清缓存）+ HTTP/SSE 代理。

## 开发命令（A9）

- `make check`：全量类型检查
- `make selftest`：check + `tests/run_all.sh`（全部单测/端到端，末行 `ALL GREEN`）
- `make e2e`：provider → TLS CLI → serve 冒烟 → chat/responses/admin e2e
- `make db_bench`：SQLite 写入 + rollup 基准（5000 行 ≈41ms）

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
5. ~~A4 剩余接线~~（已完成：serve 持有 `HtcCtx`、chat/responses 非流+SSE、tools 透传；
   上游等待改为 `upwait.wait_i32` 事件驱动，chat e2e 带 p99 断言）。
6. A4 拆解（历史）：① `src/core/json.uya`（有界 DOM 解析 + 字符串转义/构造）；
   ② schema v4 `providers`（base_url/host/port/auth/secret/超时/启用）与 store CRUD；
   ③ `POST /v1/chat/completions`：Bearer 鉴权 → `htc_open_async` 上游 → usage 解析 →
   `price_quote` → `usage_ledger` + `journal_append`；④ SSE 透传与 `[DONE]` 对齐。
   测试用 `tests/plugin_echo.py` 同构的 mock provider（Python）跑 e2e。

## 已知边界

- spike 只验证 TLS 1.2（`s_server -tls1_2`）；TLS 1.3 待补测
- 不做 HTTP/2/3、gzip、入站 TLS（建议 nginx/caddy）
- 单线程事件循环：上游等待已事件驱动（`src/core/upwait.uya`），但同一时刻仍只推进一个上游
  请求；吞吐靠多 node 水平扩展（与设计一致）
- controller 每日自动备份只覆盖 runtime DB；usage 分片需用 `aigw backup --db data/usage-<k>.db`
  或外部快照（见 `docs/runbooks/restore.md`）

## 性能基线（本机实测）

| 场景 | 命令 | 结果 |
|---|---|---|
| 网关侧 SSE 并发 | `make load-sse` | 1000 条连接 × 20 事件，全部读完且 10s 内判定，实测 ≈0.55s |
| 集群端到端 | `make cluster-e2e` | 1 controller + 3 node 注册/快照/路由/代理/drain/ingest/spool 全绿 |
| 请求路径回归 | `make ui-e2e` | OTP→登录→建 Key→chat/responses（含 tools 透传与失败转移）→后台接口全绿 |
| chat 请求 p99 | `make ui-e2e` | 20 次顺序 chat（TLS mock 上游），avg≈0.375s、p99≈0.379s |

> 说明：A4 已完成（快路径、批量落库、上游事件驱动等待与 p99 回归）；上表为当前实现的本机基线。
