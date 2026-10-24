# TODO

> 规则
> - 每个任务完成时：代码 + 测试 + 文档 + 从本文件移到 `TODO_DONE.md`，**一次提交**。
> - 提交消息：`<type>(<scope>): <TASK-ID> <summary>`，例如 `feat(tls): TLS-03 non-blocking connect`。
> - 查某任务提交：`git log --grep='TLS-03' --oneline`。
> - 本文件只留未完成任务；完成记录见 `TODO_DONE.md`。
> - 提交前必须通过该阶段的 `make check && make test`；测试失败不提交，禁止 WIP 提交。

## 阶段与依赖

```
Phase 0 (DOC-01) ──► Phase T (TLS-01…TLS-11) ──┐
                                               ├──► Phase A (A0…A9) ──► Phase B (B1…B6) ──► Phase C (C1…C6)
Phase A0 (SQLite spike) 可与 Phase T 并行 ─────┘
```

- Phase T 与 A0 可并行；A1（事件循环）先于 A2–A9；B 依赖 A；C 依赖 A（用户端可先做）。
- TLS-05 spike 已完成（负面结论：`https_handshake_async` 非可恢复）；TLS-05A 自写可恢复握手，若仍失败则退「TLS 客户端子进程」，见 `docs/design/tls-spike-findings.md`。

---

## Phase T：TLS 供应商

| ID | 任务 | 验收 | 依赖 |
|---|---|---|---|
| TLS-04 | `src/net/tlsx.uya`：指纹、pin、TOFU 多证书存储、链门控判定 | 同域多证书：已知通过；新证书链校验通过才追加；`none` 需显式开关 | TLS-03 |

---

## Phase A：单节点

| ID | 任务 | 验收 | 依赖 |
|---|---|---|---|
| A1 | 单线程 epoll 事件循环、0.0.0.0 监听、动态不限 body、chunked、100-continue、keep-alive、SSE、优雅停机 | 64 MiB body；512 并发 SSE；线程数恒 1 | A0 |
| A2 | schema/迁移 + users/keys/OTP/会话 + rate card + schedule 解析 + 每日备份 + journal | 登录→建 key→调用；时段单测；备份/恢复冒烟 | A1 |
| A3 | 插件池：常驻、min/max、idle 回收、崩溃退避、cancel、ping/pong | 复用、缩容、崩溃恢复 | A1 |
| A4 | chat 流/非流、快路径、tools、usage、分时 cost/price、批量落库 | SSE 对齐；金额与 preview 一致；落库不影响 p99 | A2/A3/TLS-09 |
| A5 | responses：`previous_response_id`、reasoning、工具、事件序列 | 事件顺序正确；续轮 | A4 |
| A6 | models、用户查询、rollup（含时段）、成本/收益/毛利 | 查询不扫明细；时段拆分正确 | A4 |
| A7 | 管理 REST + MCP（pricing/schedule/billing/backup） | 改价/改时段/预览/账单/备份状态 | A2/A6 |
| A8 | session 亲和 + priority/加权/熔断/首 token 前转移 | 同 session 固定 provider；杀插件重绑 | A3/A4 |
| A9 | 文档 + e2e + db_bench + billing/schedule/backup test | `make selftest && make e2e` | A1–A8 |

---

## Phase B：集群

| ID | 任务 | 验收 | 依赖 |
|---|---|---|---|
| B1 | controller：`meta.db`、注册/心跳、config 版本 + 长轮询、A/S 选主、journal + 每日备份 | 重启不丢；standby 接管；standby 不备份 | A2/A7 |
| B2 | node 集群模式：uplink 客户端、注册、拉快照、slug 归属校验 | 带 slug 落指定节点；断线回落轮询 | B1 |
| B3 | lease + epoch + fencing + 分配/再平衡/drain | 杀节点 ≤3s 重分配；stale epoch 421；drain 后清零 | B2 |
| B4 | edge：路径/子域、节点代理、SSE 转发、失败重试、session→node | 1k 并发流；故障自动重试 | B2 |
| B5 | ingest 幂等 + 金额/时段重算 + usage 分片 + spool + 吊销 + journal 重放 | 断网 30s 不丢不重；恢复对账一致 | B1/B3 |
| B6 | 集群 e2e + 部署（1 controller + 3 node + 2 edge + nginx） | `cluster_e2e.sh` 全绿 | B1–B5 |

---

## Phase C：后台

| ID | 任务 | 验收 | 依赖 |
|---|---|---|---|
| C1 | 静态壳 + 登录/资料 + 接入点页 | 登录→复制 URL→curl 成功 | A2/A7 |
| C2 | 概览 + 用量/费用（含时段）+ 请求列表/详情 + CSV | 数据与 `/v1/usage` 一致；分页正确 | A6 |
| C3 | 密钥管理 + 模型/价格 + 估算器 | 创建 key 立即能调用；估算 == 实际 | A7 |
| C4 | Playground + 账单 + 设置/通知 | SSE 指标正确；预算告警触发 | C2/C3 |
| C5 | 管理后台（用户/供应商/模型/定价/分时/节点/备份/审计） | 改价/绑定/节点 drain/备份状态可见 | A7/B3 |
| C6 | e2e + 安全（CSRF/XSS/CSP/越权）+ 文档 | `make ui-e2e` 全绿 | C1–C5 |

---

## 当前建议顺序

1. TLS-01 → TLS-02 → TLS-03 → TLS-04 → TLS-04A → TLS-05（spike，负面）→ TLS-05A（可恢复握手，已完成）
2. 并行：A0 spike（SQLite + money）
3. TLS-06 → TLS-07 → TLS-08 → TLS-09 → TLS-10 → TLS-11
4. A1 → A2 → A3 → A4 → A5 → A6 → A7 → A8 → A9
5. B1 → B2 → B3 → B4 → B5 → B6
6. C1 → C2 → C3 → C4 → C5 → C6

---

## 完成定义（DoD）

- 代码通过 `UYA_ROOT=<lib> uya check <files>` 与 `make build`；
- 新增/修改行为有测试（单测或 e2e），测试通过；
- 文档更新（设计/配置/运行手册，视任务而定）；
- 任务从 `TODO.md` 移到 `TODO_DONE.md`（含日期与 `git log --grep` 提示）；
- 一次提交，工作区干净（`git status --short` 为空）。
