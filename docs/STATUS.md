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

- TLS-09：异步 chat 调用（DNS→TCP→握手→写请求→读头→SSE 转发 / 非流式聚合）。

## 下一步

1. TLS-09 异步调用 → TLS-10 mock 上游 e2e → TLS-11 `aigw tls probe/pin`
2. Phase A：A0 SQLite+money spike、A1 事件循环、A2 schema/认证/备份 … A9 文档/e2e
3. Phase B：controller/node/edge、lease/epoch、ingest/journal
4. Phase C：用户端/管理端后台

## 已知边界

- spike 只验证 TLS 1.2（`s_server -tls1_2`）；TLS 1.3 待补测
- 不做 HTTP/2/3、gzip、入站 TLS（建议 nginx/caddy）
- 备份/journal/计费/集群/后台尚未实现（设计与 TODO 已就绪）
