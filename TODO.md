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

| ID | 任务 | 验收 | 依赖 |
|---|---|---|---|
| A4 | chat 流/非流、快路径、tools、usage、分时 cost/price、批量落库 | SSE 对齐；金额与 preview 一致；落库不影响 p99 | A2/A3/TLS-09 |

A4 进度（子项已完成记录见 `TODO_DONE.md`）：
- A4：chat 非流/流式、鉴权→路由→上游 TLS→分时价→journal/ledger、SSE、金额 e2e、失败转移
  已落地；无 DOM 快路径（顶层扫描 model/stream）与批量落库（512 行/200ms 事务、journal
  批追加、查询前 flush）已完成；剩余：上游异步化（p99）。

---

## Phase B：集群

| ID | 任务 | 验收 | 依赖 |
|---|---|---|---|
全部完成（B1…B6：meta.db/选主、uplink、epoch/fencing/drain、edge 路由与 SSE 流式转发、
ingest 幂等 + usage 分片 `hash(user_id)%4`、spool、journal 重放、集群 e2e 与部署，见 `TODO_DONE.md`）。

---

## Phase C：后台

| ID | 任务 | 验收 | 依赖 |
|---|---|---|---|
全部完成（C1…C6、含分时价编辑、审计动作与站内通知，见 `TODO_DONE.md`）。

---

## 当前建议顺序

1. ~~TLS-01 → … → TLS-05A~~（已完成，见 `TODO_DONE.md`）
2. 并行：A0 spike（SQLite + money）
3. TLS-06 → TLS-07 → TLS-08 → TLS-09 → TLS-10 → TLS-11
4. ~~A1 → A2 → A3 → A6 → A7 → A9 → A8 插件重绑 → A4 快路径/批量落库 → A5 流式工具事件~~ → A4 上游异步化
5. ~~B1 → B2 → B3 → B6 → B4 edge→node 流式转发 → B5 usage 分片~~（Phase B 全部完成）
6. ~~C1 → C2 → C3 → C4 → C5 → C6~~（Phase C 全部完成）

---

## 完成定义（DoD）

- 代码通过 `UYA_ROOT=<lib> uya check <files>` 与 `make build`；
- 新增/修改行为有测试（单测或 e2e），测试通过；
- 文档更新（设计/配置/运行手册，视任务而定）；
- 任务从 `TODO.md` 移到 `TODO_DONE.md`（含日期与 `git log --grep` 提示）；
- 一次提交，工作区干净（`git status --short` 为空）。
