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

## Phase D：接线补完（2026-10-26 核对发现）

> C 之后核对「模块 + 单测已完成」与「serve 生产请求路径实际调用」，发现以下功能未接线。
> 按顺序逐项补，每项一次提交。

- D4 代理 CONNECT：`src/net/proxyx.uya` 接入出站（`HTTPS_PROXY` + `no_proxy`）。
- D5 插件供应商：`providers.kind=stdio` 接 `src/plugins/pool.uya`（与内置 HTTP 二选一）。

（D1 每请求日志、D2 连接池、D3 重试退避已落地，见 `TODO_DONE.md`。）

---

## 当前建议顺序

全部阶段（T / A / B / C / D1）已完成；D2→D5 按上面顺序补接线。

---

## 完成定义（DoD）

- 代码通过 `UYA_ROOT=<lib> uya check <files>` 与 `make build`；
- 新增/修改行为有测试（单测或 e2e），测试通过；
- 文档更新（设计/配置/运行手册，视任务而定）；
- 任务从 `TODO.md` 移到 `TODO_DONE.md`（含日期与 `git log --grep` 提示）；
- 一次提交，工作区干净（`git status --short` 为空）。
