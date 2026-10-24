# TODO DONE

> 已完成任务，按完成顺序追加。
> 查提交：`git log --grep='<TASK-ID>' --oneline`。
> 未完成任务见 `TODO.md`。

| ID | 完成日期 | 提交 | 说明 |
|---|---|---|---|
| DOC-01 | 2026-10-24 | `git log --grep=DOC-01` | 仓库初始化（git init + .gitignore）、`docs/design/overview.md`、`docs/design/tls-provider.md`、`docs/runbooks/restore.md`、`TODO.md`、`TODO_DONE.md` |
| TLS-01 | 2026-10-24 | `git log --grep=TLS-01` | `src/net/urlx.uya`：URL 解析/归一（https/http、IPv6、fragment、query、userinfo 拒绝、长度上限）；`tests/test_urlx.uya` 30 个用例全过（`uya test src/net/urlx.uya tests/test_urlx.uya`） |
