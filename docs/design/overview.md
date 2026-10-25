# aigw 架构设计（overview）

> 状态：v1 设计基线。实施顺序与任务拆分见仓库根目录 `TODO.md`，完成记录见 `TODO_DONE.md`。
> 本文是总纲；TLS 供应商细节见 `docs/design/tls-provider.md`，数据库恢复见
> `docs/runbooks/restore.md`。

## 1. 目标

用 Uya 实现一个多租户 LLM API 网关，兼容 OpenAI 的：

- `POST /v1/chat/completions`（流式 / 非流式）
- `POST /v1/responses`（事件流 / 非流式，支持 `previous_response_id`）
- `GET /v1/models`

核心能力：

| 能力 | 说明 |
|---|---|
| 多供应商 | stdio 插件 + 内置 HTTPS（`kind:"http"`），同一模型可挂多个供应商 |
| 多模型 | 一个供应商可暴露多个模型，模型别名映射到上游模型名 |
| 负载均衡 | priority + least-inflight + 权重 + 熔断 + 首 token 前转移 |
| 会话亲和 | 同一 session 固定供应商/连接，避免 prompt cache 失效 |
| 多用户 | 邮箱验证码登录、API Key、按用户接入点 URL |
| 集群 | controller + node + edge，按用户动态分配节点 |
| 计费 | 进价（绑定级）/ 卖价（模型级 + 用户覆盖）、分时计价、成本与毛利 |
| 可观测 | 逐请求日志（TTFT、tok/s、tokens、费用、session、节点等） |
| 管理 | REST + MCP + Web 控制台（用户端 / 管理端） |
| 数据安全 | 每天定时备份、保留 7 份、计费 journal 可回放、恢复手册 |

## 2. 非目标（v1）

- 不内置入站 TLS（由 nginx/caddy 终结；如需入站 HTTPS 另开设计）。
- 不做 HTTP/2、HTTP/3、WebSocket、gzip 解压。
- 不做 embeddings / 图片 / 音频 / 视频接口。
- 不做 GeoIP、跨地域多活、Redis、每请求跨节点 RPC。
- 不做多币种与在线支付（v1 只记账）。
- 不做 DST 自动时区（分时计价用固定 UTC 偏移）。

## 3. 总体架构

```
                         DNS / L4
                            │
                    ┌───────▼────────┐
                    │ nginx / caddy  │  TLS 终结、限流（可选）
                    └───────┬────────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
      ┌───────▼────────┐          ┌───────▼────────┐
      │  aigw edge ×N  │          │  aigw edge ×N  │
      └───┬────────┬───┘          └────────────────┘
          │        │
  chat/responses   account / query / console / MCP
          │        │  routes: slug → node（2s 快照）
   ┌──────▼───┐   ┌▼──────────────────────────────┐
   │ node ×K  │◀──┤ aigw controller (active/standby)│
   │ 插件池    │   │ meta.db + usage-<k>.db         │
   └──────────┘   └────────────────────────────────┘
        │ 心跳 / 配置长轮询 / 幂等 ingest
        └──────────────────────────────────────────►
```

- **node**：数据面，单进程单线程，跑 HTTP framing、插件池/内置 TLS 客户端、SSE 转发。
- **controller**：控制面，用户/密钥/模型/价目/分配/计费账本；active/standby 通过 `flock` 选主。
- **edge**：接入层，按 slug 把请求代理到 node；控制台与账户类请求转发到 controller。SSE 请求（`/edge/proxy?...&stream=1`）边读节点响应边刷客户端，chunked 增量解码、不等整个响应。
- **内部接口**：`/cluster/{register,heartbeat,config,routes,route,ingest,drain,health}`，集群内明文 + `X-Cluster-Token`（可选 stunnel）。

## 4. 运行时模型

- **单进程、单线程、无锁**：所有 I/O 走 epoll；协程用 `@async_fn` / `Future` / `Waker`。
- **连接级协程**：每个连接一个 `@frame(conn_serve)` 帧（默认 1024 槽），状态机解析请求、转发上游、写响应。
- **不阻塞**：DNS、TCP connect、TLS 握手、读写、上游 SSE 全部异步；插件子进程用 `fork+execve` + 非阻塞管道。
- **上游等待**：`src/core/upwait.uya` 的 `wait_i32` 把 waker 登记的 fd（可读/可写/双向 + eventfd）
  加进 epoll，Pending 时阻塞等待而不是忙轮询。
- **背压**：客户端慢时停止读上游；插件池满时请求排队或快速失败。
- **超时**：连接空闲读 60s；请求总 deadline 30min；上游首字节 60s、流空闲 120s。
- **优雅停机**：`signalfd` 收到 SIGTERM/SIGINT 后停止 accept、排空在飞请求、回收插件、退出。

## 5. 供应商模型

两种 `kind`：

| kind | 说明 | 适用 |
|---|---|---|
| `stdio` | JSON-RPC/JSONL 子进程插件，一行一条消息 | 非标协议、私有 SDK、需要隔离的供应商 |
| `http` | 内置 HTTPS 客户端，OpenAI 兼容 | OpenAI / DeepSeek / 兼容网关 / Azure 风格头 |

插件协议（简版）：

```json
{"id":1,"method":"chat","params":{"model":"...","messages":[...],"stream":true}}
{"id":1,"event":"delta","data":{"content":"..."}}
{"id":1,"event":"usage","data":{"input_tokens":301,"output_tokens":688}}
{"id":1,"event":"done","data":{"stop_reason":"stop"}}
{"id":1,"event":"error","data":{"code":"upstream_error","message":"..."}}
```

插件池：常驻、`min/max`、空闲回收、崩溃退避、取消、`ping/pong`、被杀后同槽重绑并重试一次；v1 每进程 1 条在飞。

内置 HTTP 供应商：设计见 `docs/design/tls-provider.md`。

## 6. 请求流程（chat 为例）

1. **接入**：edge 按 `/p/<slug>/v1/chat/completions` 解析 slug → node；或 node 直接接流量。
2. **鉴权**：`Authorization: Bearer aigw_sk_...`；查内存快照（key → user/限额/模型权限）；slug 与 key 必须同用户。
3. **限流**：节点本地令牌桶（RPM/TPM/并发），单属主保证精确。
4. **规范**：chat 快路径不建 DOM（顶层扫描定位 `model`/`stream`，只按 span 改写 model），形态不安全才回退完整解析；responses 做全量翻译。
5. **选路**：按模型取候选绑定，priority → 健康 → 权重/least-inflight → session 亲和；按会话哈希固定供应商。
6. **调用**：插件池或内置 HTTP + TLS；记录首 token 时间。
7. **转发**：流式逐事件写 SSE（chunked、逐事件 flush）；非流式聚合后一次写。responses 的工具调用流额外发 `response.output_item.added` / `response.function_call_arguments.delta` / `response.output_item.done`，`completed` 里带 `output` 数组。
8. **计量**：usage（供应商优先，缺失则估算）+ 分时价目 → `cost_nano` / `price_nano`。
9. **日志**：请求行写入进程内队列 → 批量落 node.db → 批量上报 controller（幂等）。
10. **收尾**：断连取消上游；释放连接/插件；更新熔断与 session 绑定。

## 7. 集群与一致性

- **每用户接入点**：slug `u` + 10 位 base32；路径式 `/p/<slug>/v1/...`，可选子域式。
- **分配**：controller 维护 `user → node`；心跳 5s、`inflight/capacity` EWMA + 粘性（1.5× 才迁）；先切后排空。
- **session 亲和**：键 `hash(user_id, session_id, model)`；来源 `X-AIGW-Session` → `metadata.session_id` → `previous_response_id` → `user`；TTL 30min、LRU 100k、节点内存。
- **一致性**：不共享内存、不用 Redis、不用分布式锁；权威只在 controller 单写 DB；节点拿版本化快照（长轮询，变更通常 <100ms，断线回落 2s）。
- **fencing**：分配变更 `epoch+1`；心跳下发撤销；节点拒绝 stale epoch（421）；lease TTL 15s、宽限期 5min。
- **计费**：node 先算展示；controller 按 `request_id` 幂等并**重算**为账本口径；`INSERT OR IGNORE` 且 `changes()==1` 才累加 rollup。
- **故障语义**：controller 宕机时节点用最后快照继续服务，用量落本地 spool，恢复后重放；standby 抢 `flock` 接管并 `epoch+1`。

## 8. 计费

- **进价**：绑定级（provider + upstream_model），可含 `per_request_cost`，可挂分时 schedule。
- **卖价**：模型默认 + 用户覆盖（`'*'` 为全局折扣/加价），可挂用户级 schedule。
- **分时**：规则表 + 节假日；按请求开始时间解析时段；倍率或绝对价；node 与 controller 用同一时间戳重算，逐 nano 一致。
- **精度**：整数 nano-USD（1 USD = 1e9）；`mul_div` 用 `__int128` C 助手；显示 6 位小数；账单按分。
- **版本化**：`price_cards(version, effective_from)`；请求记录 `rate_version`、`period`、金额快照；改价不改历史。
- **对账**：日汇总 vs 请求明细 vs 节点上报；偏差告警。

## 9. 存储、备份与恢复

| 数据 | 位置 |
|---|---|
| 元数据（用户/密钥/模型/价目/分配） | controller `meta.db` |
| 计费明细 + rollup | controller `usage-<k>.db`，`hash(user_id) % K`，K=4；journal 重放/ingest/查询都按 uid 路由或合并（已落地） |
| 节点本地日志/待上报 | node `node-<id>.db` |

- SQLite 3（`@c_import` 编入二进制），WAL、`synchronous=NORMAL`、`busy_timeout=5000`。
- 热路径不碰库：`batch.uya` 队列 + 事件循环按 512 行/200ms 单事务写 `usage_ledger`/`usage_daily`，journal 批追加只 fsync 一次；查询前先 flush 保证可见；读只走 rollup。
- **每天 03:00 备份**（`VACUUM INTO` 子进程），**保留 7 份**。
- **计费 journal**：每批 ingest 后追加 + fsync，保留 8 天，恢复时重放，RPO ≈ 5s。
- 恢复流程见 `docs/runbooks/restore.md`。

## 10. 后台

- **用户端**：登录/账户、概览、接入点、API Key、用量（含时段）、请求日志、模型与价格、Playground、文档、设置。
- **管理端**：平台概览、用户/密钥、供应商（含 TLS 指纹）、模型/绑定/优先级、价目与分时、账单、节点/分配/drain、session、检索、审计、备份。
- 无依赖 SPA，`@embed_dir` 编入二进制；Cookie 会话 + CSRF；CSP；用户端不显示进价/毛利。

## 11. 关键决策

| 决策 | 理由 |
|---|---|
| 单线程 epoll，不用线程 | 无锁、可预测；LLM 网关是 I/O 密集，不是 CPU 密集 |
| 插件 + 内置 HTTP 两种供应商 | 插件解耦非标协议；内置 HTTP 省一次进程跳转，流式更直接 |
| 进价/卖价分离 | 同一模型多供应商成本不同；卖价对用户稳定 |
| nano-USD 整数 | 避免浮点误差；小额请求不丢精度 |
| 每日备份 + journal | 备份简单；journal 把计费 RPO 压到秒级 |
| SQLite 起步 | 零运维、单文件、可嵌入；超阈值再换 Postgres |
| 版本化快照 + 幂等上报 | 跨节点不共享内存，也不需要分布式锁 |

## 12. 里程碑

- **Phase 0**：仓库 + 设计文档 + TODO（本文件所在提交）。
- **Phase T**：TLS 供应商（TLS-01…TLS-11）。
- **Phase A**：单节点（A0…A9）。
- **Phase B**：集群（B1…B6）。
- **Phase C**：后台（C1…C6）。

任务与验收见 `TODO.md`；完成记录见 `TODO_DONE.md`。
