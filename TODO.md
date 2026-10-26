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

全部完成（TLS-01…TLS-11、TLS-04A 等见 `TODO_DONE.md`）。

---

## Phase A：单节点

全部完成（A1…A9：事件循环、schema/认证/备份/journal、插件池、chat 非流/流式与 tools、快路径、
批量落库、上游等待事件驱动 + p99 回归，见 `TODO_DONE.md`）。

---

## Phase B：集群

全部完成（B1…B6：meta.db/选主、uplink、epoch/fencing/drain、edge 路由与 SSE 流式转发、
ingest 幂等 + usage 分片 `hash(user_id)%4`、spool、journal 重放、集群 e2e 与部署，见 `TODO_DONE.md`）。

---

## Phase C：后台

全部完成（C1…C6、含分时价编辑、审计动作与站内通知，见 `TODO_DONE.md`）。

---

## Phase D：接线补完（已完成）

> C 之后核对「模块 + 单测已完成」与「serve 生产请求路径实际调用」，发现的功能未接线
> 已全部补完（D1 每请求日志、D2 连接池、D3 重试退避、D4 代理 CONNECT、
> D5 `kind=stdio` 插件供应商），每项一次提交，明细见 `TODO_DONE.md`。

## Phase E：handler 协程化（并发吞吐）

> 压测结论（2026-10-26，本机 ab + opencode 上游）：改造前单进程吞吐 ≈ 1/上游延迟
> （约 0.8 rps），8 并发时客户端延迟线性涨到 8×，CPU 0.2%；纯本地端点 `/healthz`
> 无 keep-alive 17k rps、`/v1/usage` 5k rps。根因：请求处理在事件循环里同步
> `wait_i32` 等上游。

已完成（E1–E3，非流式 chat）：在途槽 + waker fd 挂主 epoll + 无 fd 可等时自旋，
8 并发吞吐 0.64 → 3.2 rps（5×），延迟不再随并发线性膨胀。

- ~~E1 `upstream_post` 的 future 化~~（done：直接 `htc_open_async` / `htc_body_async`）
- ~~E2 `SrvConn` 在途状态 + 槽表~~（done：`ST_WAIT` + `SrvUpJob`，上限 32）
- ~~E3 主循环 epoll 接管 future 的 waker fd~~（done：`srv_up_arm` / `srv_up_tick` / `srv_up_need_spin`）
- E4 把 responses / 流式 SSE 也搬到同一套在途机制（现在这两条路径仍会阻塞事件循环）。
- E5 验收：`make test` 全绿 + 并发基准（8/32 并发吞吐随并发上升、延迟不线性膨胀）。

## 当前建议顺序

全部阶段（T / A / B / C / D1）已完成；D2→D5 按上面顺序补接线。

---

## 完成定义（DoD）

- 代码通过 `UYA_ROOT=<lib> uya check <files>` 与 `make build`；
- 新增/修改行为有测试（单测或 e2e），测试通过；
- 文档更新（设计/配置/运行手册，视任务而定）；
- 任务从 `TODO.md` 移到 `TODO_DONE.md`（含日期与 `git log --grep` 提示）；
- 一次提交，工作区干净（`git status --short` 为空）。
