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
