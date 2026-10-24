# TLS 供应商设计（内置 `kind:"http"`）

> 状态：设计基线，待 TLS-05 spike 验证后锁定。
> 参考实现：`~/uya-agent/src/net/httpc.uya`（URL/DNS/TCP/TLS/四档信任）、
> `~/uya-agent/src/net/httpstream.uya`（响应头/分块/流式）、
> `~/uya-agent/src/net/sse.uya`（SSE 帧）、`~/uya/uya/lib/tls/*`（TLS 1.2/1.3 原语）。

## 0. 结论摘要

- 新增供应商类型 `kind: "http"`：网关**进程内**直接以 HTTPS 调 OpenAI 兼容 API。
- **全程异步**：DNS、connect、TLS 握手、读写都返回 `Future`，由单线程 epoll 调度；不引入线程。
- 复用 `lib/tls` 已导出的原语（`https_handshake_async` / `https_read_some_async` /
  `https_write_all_async`），不重写密码学。
- 信任四档：`pin` / `tofu` / `chain` / `none`；同一域名允许多张证书，已知指纹直接通过，**新指纹必须链校验通过才追加**；默认 `tofu`，生产建议 `pin` + 链校验。
- `chain` 档保留但标注限制：stdlib 的 `verify_chain_rsa` 要求服务端发送根证书，真实站点通常不发，
  因此**不能作为默认信任方案**（与 uya-agent 的结论一致）。
- 先做 **TLS-05 spike**：验证 async 握手/读写能在自建事件循环里稳定跑通；不通过则退回
  「TLS 客户端放子进程」，并在本文记录原因与替代方案。

## 1. 背景与范围

### 1.1 为什么需要

v1 早期设计只支持 stdio 插件，供应商由插件实现 HTTP。问题：

- 每家供应商都要写一个插件，运维和部署成本高；
- 插件多一次进程跳转，SSE 首包延迟和吞吐都受影响；
- 主流供应商都是 OpenAI 兼容 HTTPS，内置即可覆盖大多数场景。

### 1.2 范围

**做**：

- 出站 HTTPS（TLS 1.2/1.3），HTTP/1.1，流式 SSE；
- OpenAI 兼容的 `chat/completions`、`responses`、`models`；
- 认证头风格：Bearer、`x-api-key`、`api-key`、query；
- 四档 TLS 信任 + 指纹记录；
- 连接池、超时、重试、代理（CONNECT）；
- 错误分类与可观测字段。

**不做**：

- 入站 TLS（由 nginx/caddy 终结）；
- HTTP/2、HTTP/3、WebSocket、gzip 解压；
- 客户端证书（mTLS）——v2 可加；
- 自动证书轮换（pin 轮换走 CLI/配置更新）。

## 2. 拓扑与数据流

```
client ──► node ──► provider router ──► http provider ──► urlx/dnsx/tcpx/tlsx
                                                          │
                                                          ├─ DNS(A/AAAA, 缓存)
                                                          ├─ TCP(non-blocking connect)
                                                          ├─ TLS(async handshake + verify)
                                                          └─ HTTP/1.1 + SSE
```

调用链（流式）：

1. `provider_http_chat(req, sink)` 协程启动；
2. `urlx_parse(base_url + path)`；
3. `dnsx_resolve(host)`（缓存命中则直接返回）；
4. `tcpx_connect(ip, port, timeout)`；
5. `tlsx_handshake(fd, host, trust)`；
6. `httpc_write_request(...)`；
7. `httpc_read_head(...)`；
8. `ssex_next(...)` 循环，逐事件 `sink(event)`；
9. 结束/取消：`tlsx_close(fd)` 或放回池。

## 3. URL / DNS / TCP

### 3.1 URL

- 只接受 `https://`（`http://` 仅本机/mock，需显式 `allow_plaintext: true`）。
- 解析 `scheme / host / port / path+query`；IPv6 字面量 `[::1]`；默认端口 443。
- 拒绝 userinfo（`user:pass@`）；host 做小写归一；path 为空时用 `/`。
- 长度上限：URL 8 KiB，host 253 字节。

### 3.2 DNS

- 使用 `std.net.dns` 的异步接口（`dns_client_query_a_async` / `..._aaaa_async`），
  不调用阻塞的 `getaddrinfo`。
- 缓存：`host → {addrs, expire_at}`，TTL 取 DNS 记录 TTL（下限 30s、上限 300s）；
  负缓存 5s；容量 4096，LRU。
- `/etc/hosts` 优先；`localhost` 直接回环。
- 连接时按 A/AAAA 顺序尝试（Happy Eyeballs 简化为串行 + 总超时）。
- 错误：`TlsDnsFailed`（可重试，属于基础设施问题，与证书错误分开）。

### 3.3 TCP

- `socket(AF_INET/AF_INET6, SOCK_STREAM | SOCK_NONBLOCK)`。
- `connect` 返回 `EINPROGRESS` → 注册可写 → `getsockopt(SO_ERROR)` 判定成功/失败。
- `SO_KEEPALIVE=1`；`TCP_NODELAY=1`（SSE 低延迟）。
- 连接超时 5s；失败 `TlsConnectFailed`。
- 不做本地 bind；不做 `SO_REUSEPORT`（客户端不需要）。

## 4. TLS

### 4.1 上下文与握手

参考 `tls_open` 的上下文初始化（`HandshakeCtx` / `RecordCtx` / `SslContext`），但把阻塞调用替换为：

```uya
// 伪代码
ssl_init(ctx);
ssl_set_hostname(ctx, host, host_len);          // SNI + 证书主机名校验
handshake_ctx_init(hs, HS_ROLE_CLIENT);
handshake_set_hostname(hs, host, host_len);
// 会话复用：命中则 handshake_set_resume_session_id
const f: Future<!usize> = https_handshake_async(fd, ctx, HS_ROLE_CLIENT);
const r: !usize = await f;
```

- TLS 版本：1.2 / 1.3（由 `lib/tls` 决定）。
- ALPN：只声明 `http/1.1`。
- SNI：必须设置（除非 host 是 IP 字面量，此时跳过 SNI 并只允许 `pin`/`none`）。
- 握手完成后再做信任判定（见 4.2），失败立即关闭，不发送任何应用数据。

### 4.2 四档信任

| 档位 | 判据 | 适用 | 风险 |
|---|---|---|---|
| `pin` | leaf 证书 DER 的 SHA-256 与本机配置的 64 位 hex 完全一致（可配多个，轮换窗口） | 生产推荐；供应商证书稳定 | 证书轮换需更新配置，否则连接失败 |
| `tofu` | 同 host 可存**多条**指纹；已知任一 sha 直接通过；同一 host 的**新 sha 仅当链校验通过才追加**；首用记录到 `data/tls_pins.tsv` | 默认；快速接入 | 首连可能被 MITM；新证书必须有链校验 |
| `chain` | 完整链校验（逐跳签名、SAN、有效期、basicConstraints/pathLen/keyCertSign）+ 系统/自定义 CA bundle | 有私有 CA / 多证书轮换 | 由 `chainx`（TLS-04A）实现；stdlib `verify_chain_rsa` 不验签，不使用 |
| `none` | 不校验 | 仅本机 mock / 排障 | 可被任意 MITM；必须显式 `allow_insecure: true` 并打警告日志 |

实现要点（对齐 uya-agent）：

- leaf 从 `HandshakeCtx.server_flight_msg` 中解析 Certificate 消息（type 11），不依赖 `cert_parse` 的 RSA 前提；
- 指纹 = `sha256(leaf_der)` 的 64 位小写 hex（`std.crypto.sha256`）；
- `pin` 长度必须正好 64，比较时大小写折叠；`pin_sha256` 支持 1..4 个值（轮换窗口）；
- **同一域名多证书**（用户要求）：TOFU 库按 `(host, sha256)` 存多条（4 条/host、64 条全局）；
  - 库里有该 host + 该 sha ⇒ 通过；
  - 库里有该 host 但没有该 sha ⇒ **只有链校验通过才追加并通过**，否则拒绝（`TlsVerifyFailed`）；
  - 库里没有该 host ⇒ 首用记录（无先验，风险已知；`tofu_strict=true` 时首用也要求链校验）；
- `tofu` 存储：`data/tls_pins.tsv`（每行 `host<TAB>sha256<TAB>first_seen_ms<TAB>updated_at_ms`），文件 0600；
- **链校验实现**：stdlib 的 `verify_chain_rsa` **不验证签名**（只查有效期/basicConstraints/锚点公钥相等），不能作为门禁；
  TLS-04A 已移植 `chainx`（uya-agent `cachain` + `x509min`：逐跳验签、SAN、pathLen、keyCertSign、未知 critical 扩展 fail-closed）；
  TLS-05 把 `chainx_verify_flight_bundle/_system` 的结论作为 `chain_ok`，绝不静默放行；
- `none`：`ssl_set_insecure_skip_verify(ctx, true)`，日志 `tls_verify=none`。

### 4.3 证书轮换

- `aigw tls probe https://host`：连接并打印 leaf SHA-256、颁发者、有效期、SNI、协议版本。
- `aigw tls pin https://host --write`：把指纹追加到 `data/tls_pins.tsv`（同一 host 可多条；或输出配置片段）。
- 配置里 `pin_sha256` 支持多个值（轮换窗口）：`["<old>", "<new>"]`，任一匹配即通过。
- 证书变更时：先 probe 拿新指纹 → 加到列表 → 观察一周 → 删除旧值。

### 4.4 会话复用

- 按 host 缓存 session id + master secret + cipher suite（`tls_session_cache_store/lookup`）。
- 缓存条目上限 256，TTL 10 分钟；命中则在 ClientHello 里带 session id，服务器拒绝时自动回退完整握手。
- 只用于同一 host 的新连接；连接池复用时不需要重新握手。

## 5. HTTP/1.1

### 5.1 请求

```http
POST /v1/chat/completions HTTP/1.1
Host: api.deepseek.com
Authorization: Bearer <key>
Content-Type: application/json
Accept: text/event-stream        (流式时)
Content-Length: <n>
Connection: keep-alive
User-Agent: uya-aigw/<version>
```

- 不发送 `Accept-Encoding`（避免 gzip 解码）。
- 请求体已在网关侧缓冲（body 不限大小，动态增长），这里一次写出。
- header 名大小写不敏感；值不允许 CR/LF（防注入）。
- `auth.type` 映射：
  - `bearer` → `Authorization: Bearer <secret>`
  - `x-api-key` → `x-api-key: <secret>`
  - `api-key` → `api-key: <secret>`（Azure）
  - `query` → `?key=<secret>`（避免记录到日志）
- 自定义 headers 与供应商 headers 合并，禁止覆盖 `Host`/`Content-Length`。

### 5.2 响应

- 状态行解析：`HTTP/1.1 <code> <reason>`；1xx 跳过（100-continue）。
- 头：上限 32 KiB，最多 100 个；重复头按逗号合并（`set-cookie` 除外，v1 不需要）。
- 体：
  - `Content-Length`：精确读；
  - `Transfer-Encoding: chunked`：按块解码，支持 trailer 丢弃；
  - 无长度：读到 EOF（仅非 keep-alive）。
- 上限：非流式响应默认 64 MiB（可配）；流式不设总量上限，但设 idle 超时。
- 非 keep-alive 或 `Connection: close`：读完后关闭。

### 5.3 重定向

- 301/302/303/307/308，最多 5 跳。
- 303 改 GET；307/308 保留方法与体；跨 host 重定向时重新做 DNS/TLS 与信任判定（pin 按新 host）。
- 重定向目标必须仍是 https（除非显式允许明文）。

### 5.4 连接池

- key：`(scheme, host, port, proxy, trust_mode)`。
- 每 key：`max_idle=8`、`idle_ttl=60s`、`max_conns=64`；超出时关最旧。
- 取连接：优先空闲且未过期；否则新建（受 `max_conns` 限制）。
- 归还：响应完整且 keep-alive 时归还；异常/半包/超时直接关闭。
- 健康：空闲连接在复用时先 `poll(POLLIN)` 一下，若可读且读到 EOF 则丢弃重建。
- 不做 HTTP pipelining。

## 6. SSE 与流式

- 请求头 `Accept: text/event-stream`，响应 `Content-Type: text/event-stream`。
- 解析：按行读（`\n`，兼容 `\r\n`），空行分帧；字段 `data:` / `event:` / `id:` / `retry:`；
  只处理 `data`，`[DONE]` 结束；`:` 开头为注释。
- 每帧立即交给上层（`sink`），由上层转成 chat chunk 或 responses 事件并写出。
- 背压：上层写不出去时暂停读上游（不注册可读），避免内存膨胀；缓冲上限 1 MiB。
- 空闲超时 120s（可配）；总超时 30min；客户端断开 → 取消 future → 关闭上游 socket。
- 供应商中途断流：若已输出内容，发送 `finish_reason=null` 的结束事件并记录 `upstream_truncated`；
  未输出则可按重试策略换绑定。

## 7. 异步集成

- 每个上游请求是一个 `@async_fn` 协程，`await` DNS/connect/handshake/read/write 的 `Future`。
- `Waker` 取消：客户端断连或超时 → `waker.cancel()` → future 返回 `error.Cancelled` → 关闭 fd。
- 事件循环：与 `uyagin` 的槽位循环共用一套 epoll；TLS fd 注册 `EPOLLIN|EPOLLOUT|EPOLLRDHUP`。
- 关键约束：**不调用任何阻塞函数**（`https_client_handshake`、`https_read_some`、`https_write_all`
  是阻塞版，仅用于测试/CLI，不在请求路径使用）。
- 帧分配：`@frame(provider_http_call)` 固定大小（含 64 KiB 读写缓冲），避免堆分配；
  `@size_of(@frame(...))` 编译期常量，纳入连接帧池预算。

## 8. 超时、重试、取消

| 阶段 | 超时 | 失败处理 |
|---|---|---|
| DNS | 3s | 重试 1 次（换 resolver 结果），仍失败 `TlsDnsFailed` |
| TCP connect | 5s | 可重试（换 IP/换绑定） |
| TLS 握手 | 5s | 不重试同一 host；换绑定 |
| 等响应头 | 60s | 可重试（未发送/未输出） |
| 流空闲 | 120s | 断开，记录 `upstream_idle_timeout` |
| 总时长 | 30min | 断开 |
| 客户端 | 无 | 断连即取消 |

- 重试条件：DNS/连接失败、429、500/502/503/504、连接在首字节前中断。
- 不重试：4xx（除 429）、证书校验失败、已开始输出。
- 退避：`500ms × 2^n` + 抖动，最大 3 次；尊重 `Retry-After`（≤60s）。
- 每次重试换一个候选绑定（不同 provider/连接），并记录 `attempt`。

## 9. 配置与密钥

```json
{
  "providers": [
    {
      "id": "deepseek",
      "kind": "http",
      "api": "openai-chat",
      "base_url": "https://api.deepseek.com",
      "auth": { "type": "bearer", "secret": "env:DEEPSEEK_API_KEY" },
      "tls": {
        "mode": "pin",
        "pin_sha256": ["<hex>"],
        "sni": "api.deepseek.com",
        "ca_bundle": null,
        "allow_insecure": false
      },
      "headers": { "x-title": "aigw" },
      "timeouts": { "connect_ms": 5000, "header_ms": 60000, "idle_ms": 120000, "total_ms": 1800000 },
      "retry": { "max": 2, "backoff_ms": 500 },
      "pool": { "max_idle": 8, "idle_ttl_ms": 60000, "max_conns": 64 },
      "proxy": { "url": "env:HTTPS_PROXY", "no_proxy": ["localhost", "127.0.0.1"] },
      "models": { "deepseek-chat": "deepseek-v4.1-flash" }
    }
  ]
}
```

- `secret` 支持 `env:NAME`、`file:/path`、`literal:<value>`（literal 仅测试）；
  解析后只在内存，日志/错误体/审计一律脱敏为 `sk-***`。
- 配置热更新：controller 版本化下发；节点收到新版本后原子替换 provider 表；
  在飞请求继续用旧配置（记录 `config_version`）。
- 校验：`base_url` 必须 https（除非 `allow_plaintext`）、`auth.type` 枚举、pin 必须 64 hex、
  `mode=none` 必须同时 `allow_insecure=true`。

## 10. 错误分类与可观测

| 错误 | 含义 | 映射到客户端 |
|---|---|---|
| `TlsDnsFailed` | 域名解析失败 | 502 `upstream_dns_error` |
| `TlsConnectFailed` | TCP 连不上 | 502 `upstream_connect_error` |
| `TlsHandshakeFailed` | TLS 握手失败 | 502 `upstream_tls_error` |
| `TlsVerifyFailed` | 证书/指纹校验失败 | 502 `upstream_tls_verify_error` |
| `HttpProtocolError` | 响应畸形 | 502 `upstream_protocol_error` |
| `HttpStatusError` | 上游 4xx/5xx | 透传状态码 + 原始错误体（脱敏） |
| `HttpTimeout` | 超时 | 504 `upstream_timeout` |
| `HttpTooLarge` | 响应超限 | 502 `upstream_too_large` |
| `HttpCanceled` | 客户端断开 | 不返回 |

记录字段：`provider_id`、`tls_mode`、`leaf_sha256`、`sni`、`http_status`、`attempt`、
`dns_ms`、`connect_ms`、`tls_ms`、`ttfb_ms`、`reused`、`bytes_in/out`、`upstream_request_id`。
其中 `dns_ms/connect_ms/tls_ms` 只在 debug 级别记录（采样）。

## 11. 安全威胁模型

| 威胁 | 缓解 |
|---|---|
| 中间人（公网） | 默认 `tofu`；生产 `pin`；`chain` 实验性；`none` 需显式开关 |
| 首连 MITM（TOFU） | 生产用 `pin`；或首次 pin 由管理员在可信网络执行 |
| 证书轮换失败 | 支持多 pin 值；上线前 `tls probe` |
| API key 泄漏到日志 | 统一脱敏；错误体过滤 `Authorization`/`x-api-key`/query key |
| 恶意供应商响应 | 头/体上限、行长度上限、JSON 解析深度/大小限制 |
| SSRF（base_url 指向内网） | 默认禁止私网 IP（RFC1918/loopback/link-local），需显式 `allow_private_network` |
| 重定向到内网 | 每跳重新做私网检查 |
| TLS 降级 | 只允许 1.2/1.3；不接受 `none` 之外的跳过校验 |
| 代理凭据泄漏 | 代理 URL 从 env/file 读；日志脱敏 |

## 12. 测试矩阵

| 类别 | 用例 |
|---|---|
| URL | 默认端口、IPv6、query、userinfo 拒绝、超长 |
| DNS | A/AAAA、缓存命中/过期、负缓存、`/etc/hosts`、NXDOMAIN |
| TCP | 拒绝连接、超时、非阻塞 connect 成功/失败、IPv6 |
| TLS | pin 匹配/不匹配、tofu 首用/变更、chain 成功/失败、none、SNI、过期证书、Host 不匹配、会话复用 |
| HTTP | Content-Length、chunked、EOF、1xx、重复头、超大响应、畸形状态行 |
| 重定向 | 301/302/303/307/308、跨 host、超 5 跳、重定向到私网拒绝 |
| SSE | 多行 data、注释、`[DONE]`、分帧跨包、空闲超时、断流、取消 |
| 池 | 复用、空闲过期、max_conns、半包丢弃 |
| 重试 | 503/429/连接中断、不重试 4xx、退避上限、已输出不重试 |
| 集成 | 本地 TLS mock 上游（流式/非流式）、真实 provider（env 门控） |

本地 fixture：用 `tls.https` 的 `https_server_listen` + 测试证书（`tests/fixtures/tls/`）
起一个回环 TLS 服务；证书用 openssl 生成并提交（自签，测试用）。
真实 provider 测试需要 `AIGW_TEST_PROVIDER_URL` / `AIGW_TEST_PROVIDER_KEY`，CI 默认跳过。

## 13. 任务拆分与验收

| ID | 内容 | 验收 |
|---|---|---|
| TLS-01 | `urlx`：解析、归一、IPv6、拒绝 userinfo | 单测覆盖边界 |
| TLS-02 | `dnsx`：异步 A/AAAA、TTL 缓存、hosts | 不阻塞；缓存命中率测试 |
| TLS-03 | `tcpx`：非阻塞 connect、超时、keepalive | 连接失败分类正确 |
| TLS-04 | `tlsx`：指纹、pin、TOFU 多证书存储、链门控判定 | 同域多证书：已知通过；新证书链校验通过才追加；none 需显式 |
| TLS-04A | `chainx`：移植 `cachain`/`x509min` 完整链校验（逐跳签名/SAN/pathLen/keyCertSign） | 本地 fixture 链通过/失败；新证书门控生效 |
| TLS-05 | spike：异步握手/读写接入自建循环 + 把 `chainx` 接进握手 | 流式 1k 并发不阻塞；否则回退方案 |
| TLS-06 | `httpc`：请求构造、响应解析、chunked、限长 | 大响应/畸形响应用例 |
| TLS-07 | `ssex`：SSE 解析、取消、背压 | `[DONE]`、断连取消、空闲超时 |
| TLS-08 | 连接池、重试/退避、代理 CONNECT | 复用命中、重试不重复写 |
| TLS-09 | provider `kind:"http"`、密钥解析、模型映射、错误映射 | 配置即用；错误体正确 |
| TLS-10 | mock TLS 上游 + e2e（真实 provider 门控） | 流式/非流式通过 |
| TLS-11 | `aigw tls probe/pin`、健康检查、文档 | 运维可自检 |

## 14. 风险与备选方案

1. **异步 TLS 原语不兼容**：`https_handshake_async` 依赖 `async_poll_pending_readable_usize` 的
   `Waker` 注册；若与自建循环的 fd 槽冲突，退回「TLS 客户端跑在子进程，stdio 传流」，
  进程模型与插件一致，性能损失可接受。
2. **`chain` 档的 stdlib 实现不完整**：`verify_chain_rsa` 不验签 → 已由 TLS-04A 的 `chainx` 替代（逐跳验签 + SAN + pathLen）；stdlib 版不再使用。
3. **TOFU 首连风险**：生产建议 `pin`；文档给出上线流程（可信网络 probe → 写 pin）。
4. **DNS 阻塞**：异步 + 缓存 + 超时；极端情况下用 `/etc/hosts` 兜底。
5. **证书轮换**：多 pin 值 + probe + 观察期。
6. **SSRF**：默认禁私网；每跳重定向重新检查。
