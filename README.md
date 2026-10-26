# aigw — Uya AI Gateway

单进程、单线程事件循环的 AI 网关：**OpenAI 兼容的 chat / responses 接口**，多供应商路由
（内置 HTTPS 客户端或 stdio 插件），带计费（成本/售价/利润）、预算与通知、请求日志、
管理后台与集群模式（controller + edge）。

- 语言/运行时：Uya 0.11（生成 C，`cc` 编译），Linux x86_64
- 存储：SQLite（`src/core/dbx.uya`，WAL + journal 批追加 + 每日备份）
- 网络：自带 TLS 栈（DNS → TCP → TLS 1.2/1.3 → HTTP/1.1 → SSE），不依赖 libcurl/OpenSSL
- 上游：连接池复用、429/5xx 退避重试、HTTP 代理 CONNECT、stdio 插件供应商

> 架构与设计取舍见 [`docs/design/overview.md`](docs/design/overview.md)；
> 进度/验收见 [`docs/STATUS.md`](docs/STATUS.md) 与 [`TODO_DONE.md`](TODO_DONE.md)。

---

## 目录

1. [构建](#1-构建)
2. [快速开始](#2-快速开始)
3. [命令行参考](#3-命令行参考)
4. [环境变量](#4-环境变量)
5. [数据与文件布局](#5-数据与文件布局)
6. [配置手册](#6-配置手册)
   - [6.1 认证与会话](#61-认证与会话)
   - [6.2 供应商](#62-供应商)
   - [6.3 价目、分时与计费](#63-价目分时与计费)
   - [6.4 预算与通知](#64-预算与通知)
   - [6.5 出站代理](#65-出站代理)
   - [6.6 插件供应商（kind=stdio）](#66-插件供应商kindstdio)
   - [6.7 TLS / CA / 指纹固定](#67-tls--ca--指纹固定)
   - [6.8 集群模式](#68-集群模式)
   - [6.9 OTP 邮件投递（内置 SMTP 客户端）](#69-otp-邮件投递内置-smtp-客户端)
7. [HTTP API 参考](#7-http-api-参考)
8. [运维](#8-运维)
9. [开发与测试](#9-开发与测试)
10. [已知限制](#10-已知限制)
11. [相关文档](#11-相关文档)

---

## 1. 构建

### 依赖

| 依赖 | 用途 | 说明 |
|---|---|---|
| Uya 0.11 工具链 | 编译 | 默认 `/home/winger/uya/uya/bin/uya`，用 `UYA=` 覆盖 |
| Uya 标准库 | 编译 | 默认 `/home/winger/uya/uya/lib`，用 `UYA_ROOT=` 覆盖（Makefile 会 export） |
| `cc` | 生成 C 的编译链接 | 系统自带即可 |
| `make` | 便捷目标 | 可选 |
| `openssl`、`python3` | **仅测试**（自签证书、mock 上下游） | 生产运行不需要 |

### 构建二进制

仓库没有单独的 `build` 目标（e2e 脚本各自显式列模块），整仓构建用：

```bash
export UYA_ROOT=/home/winger/uya/uya/lib
UYA=/home/winger/uya/uya/bin/uya

make check                      # 全量类型检查（合并命名空间）
$UYA build $(find src -name '*.uya' | sort) -o build/aigw
./build/aigw                    # 没参数时打印 usage
```

产物：`build/aigw`（约 2 MB），生成 C 缓存在 `.uyacache/`（`make clean` 清理）。

---

## 2. 快速开始

### 2.1 启动

```bash
mkdir -p data
./build/aigw serve --host 127.0.0.1 --port 8080 \
  --db data/aigw.db --data-dir data \
  --dev-otp --admin-key dev-admin
```

启动后 stdout 打印一行 `listen port=8080`（`--port 0` 时由内核挑端口，这行给出真实端口，
脚本常用它取值）。

### 2.2 登录 → 建 Key → 调用

```bash
B=http://127.0.0.1:8080

# 1) 取验证码（--dev-otp 时响应里回显 code；生产见 6.1）
CODE=$(curl -s -X POST -d '{"email":"me@example.com"}' $B/v1/auth/otp \
       | sed -n 's/.*"code":"\([0-9]*\)".*/\1/p')

# 2) 换会话 token
SESSION=$(curl -s -X POST -d "{\"email\":\"me@example.com\",\"code\":\"$CODE\"}" $B/v1/auth/login \
          | sed -n 's/.*"session":"\([^"]*\)".*/\1/p')

# 3) 建 API Key（明文只在响应里出现一次）
KEY=$(curl -s -X POST -H "Authorization: Bearer $SESSION" -d '{"name":"cli"}' $B/v1/keys \
      | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')

# 4) 用 Key 调接口
curl -s -H "Authorization: Bearer $KEY" $B/v1/models
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}' \
  $B/v1/chat/completions
```

此时调用会返回 `404`/`400`：**还没有供应商和价目**。接着做 2.3。

### 2.3 配置一个真实上游（最短路径）

供应商目前**没有创建 API**（只有 `GET /admin/providers` 列表），引导方式是在 SQLite 里
插入一行，再用管理接口挂模型和价目：

```bash
# 供应商（host/port 必填；secret 支持 env:NAME / file:PATH / 明文）
sqlite3 data/aigw.db "
insert into providers(name, kind, scheme, host, port, base_path,
                      auth_type, auth_name, secret, timeout_ms,
                      enabled, priority, weight)
values('openai','openai','https','api.openai.com',443,'',
       1,'Authorization','env:OPENAI_API_KEY',60000,1,100,100);"

export OPENAI_API_KEY=sk-...

# 模型绑定：对外 model → 供应商（upstream_model 省略时同名）
curl -s -X POST -H "Authorization: Bearer dev-admin" \
  -d '{"provider":"openai","model":"gpt-4o-mini","upstream_model":"gpt-4o-mini"}' \
  $B/admin/bind

# 价目：/admin/pricing 的写入路径目前有缺陷（见 §10），先用 SQL 建卡 + 写价目
#   卖价卡 kind=0（按模型），进价卡 kind=1（按 provider+model）
sqlite3 data/aigw.db "
insert into price_cards(kind,version,effective_from,created_at,note)
  values(0,1,0,0,'bootstrap');
insert into price_entries(card_id,provider,model,user_id,
                          input_nano_per_mtok,output_nano_per_mtok,
                          cache_read_nano_per_mtok,per_request_nano,schedule)
  select id,'','gpt-4o-mini',0,150000000,600000000,75000000,0,''
  from price_cards where kind=0 and version=1;
insert into price_cards(kind,version,effective_from,created_at,note)
  values(1,1,0,0,'bootstrap');
insert into price_entries(card_id,provider,model,user_id,
                          input_nano_per_mtok,output_nano_per_mtok,
                          cache_read_nano_per_mtok,per_request_nano,schedule)
  select id,'openai','gpt-4o-mini',0,100000000,400000000,50000000,0,''
  from price_cards where kind=1 and version=1;"

然后重跑 2.2 的第 4 步即可拿到真实上游的响应；用量与利润查 `GET /v1/usage`。

> 自签/私有 CA 的上游：启动时加 `--ca <pem>`，或见 [6.7](#67-tls--ca--指纹固定)。

---

## 3. 命令行参考

```
aigw serve [--host 0.0.0.0] [--port 8080] [--db data/aigw.db] [--data-dir data]
           [--ca <pem>] [--dev-otp] [--admin-key <key>]
           [--meta <db>] [--node-id <id>] [--uplink host:port]
           [--proxy http://host:port] [--no-proxy a,b] [--max-body <bytes>]
           [--plugin-cmd "cmd args"]
aigw tls probe <host> [--port N] [--ca <pem>]
aigw tls pin   <host> <sha256hex> [--file <tsv>]
```

### `aigw serve`

| 参数 | 默认 | 说明 |
|---|---|---|
| `--host` | `0.0.0.0` | 监听地址 |
| `--port` | `8080` | 监听端口；`0` = 内核分配（看 stdout 的 `listen port=`）。监听开了 `SO_REUSEPORT`，**多个进程可绑同一端口**，内核做连接均衡（单进程吞吐受上游等待串行化限制，见 §10.1） |
| `--db` | `data/aigw.db` | SQLite 数据库路径（自动建库 + 迁移 + journal 重放） |
| `--data-dir` | `data` | 运行目录：journal、备份、`requests.log`、`audit.jsonl`、`spool.jsonl` |
| `--ca` | 空 | 额外的 PEM 信任根（上游自签/私有 CA 用） |
| `--dev-otp` | 关 | 开发模式：`/v1/auth/otp` 在响应里回显验证码 |
| `--admin-key` | 空 | 管理接口的 Bearer key；**空 = 管理接口全部 401** |
| `--meta` | 空 | 集群模式：controller 元数据库（`meta.db`），空 = 单机 |
| `--node-id` | 空 | 集群模式：本节点 id（standby 不备份、不接管） |
| `--uplink` | 空 | 集群模式：`host:port`，node 向 controller 注册/心跳、拉 config |
| `--proxy` | 空 | 出站 HTTP 代理 `http://host:port`（覆盖 `HTTPS_PROXY`） |
| `--no-proxy` | 空 | 代理白名单（逗号分隔，支持 `*` 与后缀匹配）；显式给空串 = 全部走代理 |
| `--plugin-cmd` | 空 | stdio 插件启动命令（`/bin/sh -c` 执行），覆盖 `AIGW_PLUGIN_CMD` |
| `--max-body` | `8388608` | 请求体上限（字节，下限 1024）。抓包与上游转发共用这个值；超出回 413，大包在途超过 32 个回 503。也可用 `AIGW_MAX_BODY`（命令行优先） |
| `--smtp` | 空 | SMTP 地址：`smtp://host[:port]`（STARTTLS，默认 587）、`smtps://host[:port]`（隐式 TLS，默认 465）、`host:port`（明文 25，内网 relay/测试）。**空 = 不发邮件**（OTP 只能靠 `--dev-otp`） |
| `--smtp-user` / `--smtp-pass` | 空 | 登录凭据，覆盖 URL 里的 `user:pass` |
| `--mail-from` | 空 | 发信人地址；默认取 `--smtp-user`（多数服务商要求 From 与登录账号同域） |
| `--mail-hostname` | `localhost` | EHLO 里报的名字 |
| `--mail-ca` | 空 | 额外的 PEM 信任根（内网自签中继用） |
| `--mail-relay-cmd` | `<argv0> smtp-relay` | 投递子进程的命令；一般不用改 |

### `aigw tls probe` / `aigw tls pin`

| 命令 | 说明 |
|---|---|
| `tls probe <host> [--port 443] [--ca <pem>]` | 手工握手一次：打印证书链校验结果与叶子证书 sha256 指纹 |
| `tls pin <host> <sha256hex> [--file data/tls_pins.tsv]` | 把指纹写进 TOFU 固定表（同一 host 允许多条，便于轮换） |

---

## 4. 环境变量

| 变量 | 作用 | 读取方 |
|---|---|---|
| `HTTPS_PROXY` / `https_proxy` | 出站代理（`--proxy` 优先） | serve 启动 |
| `NO_PROXY` / `no_proxy` | 代理白名单（`--no-proxy` 优先） | serve 启动 |
| `AIGW_PLUGIN_CMD` | stdio 插件命令（`--plugin-cmd` 优先） | serve 启动 |
| `SSL_CERT_FILE` | 额外的 PEM 信任根（与 `--ca` 叠加） | 上游 TLS 校验 |
| `AIGW_ASYNC_OFF` | 空 | `1` = 关闭 handler 协程化，强制走阻塞实现（排障/对比用） |
| `HTTPS_PROXY` / `https_proxy` / `NO_PROXY` | 空 | 出站代理（D4）。**注意**：环境里有代理而代理不可用，上游会 `ECONNREFUSED(111)` 并秒回 502 —— 本机实例请 `unset` 或配 `NO_PROXY` |
| `AIGW_ASYNC_DEBUG` | 空 | `1` = 打印在途请求的 spawn/fail 细节（含错误 id） |
| `AIGW_UPSTREAM_HEADER` | 给所有上游请求追加一条头，格式 `Name: Value`（如 opencode 的 `x-opencode-session`） | 上游请求构造 |
| `AIGW_SMTP_URL` / `AIGW_SMTP_USER` / `AIGW_SMTP_PASS` | 同上（`--smtp*` 优先） | serve 启动 |
| `AIGW_MAIL_FROM` / `AIGW_MAIL_HOSTNAME` / `AIGW_MAIL_CA` / `AIGW_MAIL_RELAY_CMD` | 同上（对应 `--mail-*`） | serve 启动 |
| `UYA` / `UYA_ROOT` | 编译期工具链与标准库路径 | Makefile / e2e 脚本 |

测试脚本另用私有变量（不参与生产）：`AIGW_MODE`、`AIGW_DB`、`AIGW_UPSTREAM_PORT`、
`AIGW_TLS_PORT`、`AIGW_TLS_ROOT`。

---

## 5. 数据与文件布局

```
data/
  aigw.db                     # SQLite 主库（providers/provider_models/users/api_keys/
                              #   price_cards/price_entries/usage_*/budgets/responses/audit...）
  aigw-journal-YYYYMMDD.log   # 结算 journal（按 UTC 日分片，批追加）
  aigw-YYYYMMDD.db            # 每日备份（VACUUM INTO，保留 7 天）
  requests.log                # 每请求一行 k=v（见下）
  audit.jsonl                 # 管理侧写操作审计
  spool.jsonl                 # 本地 spool（集群 ingest 失败时的落盘缓冲）
  meta.db                     # 集群元数据（--meta 指向这里）
  tls_pins.tsv                # TOFU/指纹固定表
```

`requests.log` 每行的字段（`k=v`，空格分隔）：

```
request_id status endpoint method stream protocol product ttft_ms duration_ms
model provider stop effort max_tokens input output cache_read cost_nano
toks_x100 email user session ua loc headers
```

---

## 6. 配置手册

### 6.1 认证与会话

| 凭证 | 用途 | 传递 |
|---|---|---|
| API Key | 业务接口（`/v1/chat/completions`、`/v1/responses`、`/v1/usage`…） | `Authorization: Bearer <key>` |
| 会话 token | 自助接口（建/撤销 Key、`/v1/me`、预算、通知） | `Authorization: Bearer <session>` |
| Admin key | `/admin/*` 全部管理接口 | `Authorization: Bearer <--admin-key>` |

- 用户不存在时 `POST /v1/auth/login` 会自动建用户（`users.status` 0=正常）。
- OTP 有效期 600s，一次性。
- 验证码投递：配了 `--smtp` 就**内置 SMTP 直投**（见 §6.8），没配则只有 `--dev-otp`
  会在响应里回显 `code`（先用会话/管理面预置用户与 Key 也可以）。
- API Key 只在创建响应里出现一次明文，库里只存 sha256；`POST /v1/keys/revoke {"key_id":N}`
  之后**最迟 2s 生效**（校验走单槽缓存，TTL = 2s）。

### 6.2 供应商

两种 `kind`：

| kind | 实现 | 适用 |
|---|---|---|
| `openai`（默认，走内置 HTTPS） | `src/providers/httpcall.uya` | OpenAI / DeepSeek / 兼容网关 / Azure 风格头 |
| `stdio` | `src/providers/plug.uya` + 插件池 | 私有 SDK、非标协议、需要进程隔离的供应商 |

`providers` 表字段（SQL 引导或迁移脚本写入）：

| 字段 | 说明 |
|---|---|
| `name` | 唯一名；`/admin/bind`、价目进价卡按名字引用 |
| `kind` | `openai`（内置 HTTPS）或 `stdio`（插件） |
| `scheme` | `https`。内置传输只做 TLS；明文需在配置层放开 `allow_plaintext`（默认 false，未暴露为 provider 字段） |
| `host` / `port` | 上游主机与端口（`stdio` 用占位值即可，如 `plugin:1`） |
| `base_path` | 追加在 `/chat/completions` 前；空 = `/v1/chat/completions` |
| `auth_type` | `0` 无；`1` `Authorization: Bearer`；`2` `X-Api-Key:`；`3` `api-key:`（`4`=query 仅内部支持，配置校验接受 0–3） |
| `auth_name` | 凭证头名（`auth_type` 为 0 时忽略） |
| `secret` | 凭证：明文，或 `env:NAME`、`file:/path` |
| `timeout_ms` | 单次上游超时（默认 60000） |
| `enabled` | 1/0，停用后不参与路由 |
| `priority` / `weight` | 越小优先级越高；同优先级按权重分摊（`weight=0` 不参与） |

模型绑定：`POST /admin/bind`，可一个对外模型挂到多个供应商（同 weight 时按会话亲和 +
加权选一家）；`GET /admin/models` 查看全部绑定。

```bash
curl -s -X POST -H "Authorization: Bearer $ADMIN" \
  -d '{"provider":"openai","model":"gpt-4o-mini","upstream_model":"gpt-4o-mini"}' \
  $B/admin/bind
```

> **注意**：`/admin/providers` 目前只有 `GET`（列表）。如需要“HTTP 建供应商”，可在
> 管理面按同一 schema 扩展；当前引导走 SQL（见 2.3）。

#### 出站行为（内置 HTTPS）

- DNS 缓存 + TCP/TLS 异步握手，等待用 epoll（不忙等）。
- **连接池**：非流式请求复用 `(host,port,trust)` 的活连接，空闲 60s 回收，最多 8 条；
  池内连接被上游关掉时自动换新连接重试一次。
- **重试**：`408/425/429/500/502/503/504` 按 `Retry-After` 或指数退避（100ms 起、封顶 30s）
  重试同一家，最多 3 次；传输层失败则熔断该家 30s 并换下一家（最多 3 家）。
- 流式（SSE）请求不复用连接、不重试（已开始输出后无法重试）。
- 有的上游要求额外路由头（如 `opencode.ai/zen` 的 `x-opencode-session`）：用
  `AIGW_UPSTREAM_HEADER="x-opencode-session: <id>"` 统一追加一条。

### 6.3 价目、分时与计费

金额一律 **nano-USD 整数**（`1 USD = 1_000_000_000`）；单价是 **每百万 token 的 nano 数**。

- `price_cards`：`kind=0` 卖价（按用户/模型），`kind=1` 进价（按 provider+model）；
  `version` 单调递增，`effective_from`（unix 秒，0 = 立即）决定生效时间。
- `price_entries`：`input_*`、`output_*`、`cache_read_*`（per Mtok）+ `per_request_nano`
  （每次请求固定加价），可选 `schedule` 分时倍率。
- 结算：`cost = 进价用量成本`，`price = 卖价用量成本`，`profit = price - cost`；
  用量落在 `usage_*` 汇总与明细，`GET /v1/usage` 同时返回 `cost_nano/price_nano/profit_nano`。

**分时规则**（`schedule` 字段，`;` 分隔多条，首条命中生效，都不命中按 1x）：

```
<days> <HH:MM>-<HH:MM> <factor>

days    mon|tue|wed|thu|fri|sat|sun，可写区间 mon-fri，或 daily / weekend / workday
factor  120% = 1.2 倍；2x = 2 倍；不带单位按百分比
例：workday 09:00-18:00 120%; weekend 00:00-24:00 80%
    daily 22:00-06:00 60%        # 跨零点窗口
```

窗口 `[from, to)` 左闭右开；`from == to` 视为空窗口；判定用**请求开始时间**，node 与
controller 用同一 ts 重算，保证逐 permille 一致（集群重算的前提）。

写入方式：

| 方式 | 说明 |
|---|---|
| `POST /admin/bind` | 模型绑定（**已验证可用**） |
| SQL（`price_cards` + `price_entries`） | 当前**唯一可靠**的建卡/写价目方式，见 §2.3 |
| `POST /admin/pricing` | 新建卡 + 一条价目；目前固定返回 400（见 §10） |
| `POST /admin/price-entries` | 往“当前生效卡”追加价目；走同一条 `price_entry_put`，见 §10 |
| `GET /admin/price-entries`、`GET /admin/pricing?model=…` | 查询 |

### 6.4 预算与通知

- 预算按月：`POST /v1/budget {"monthly_nano": 2000000000}`（= $2，注意 §10 的 32 位截断，
  当前可用上限约 `2147483647` nano）；`GET /v1/budget` 返回本月已花 `spent_nano`、
  额度 `monthly_nano` 与 `over_budget` 标志。
- **预算是提示型、不拦截请求**：超额（`spent >= limit`）时在预算接口标记 `over_budget`，
  并按「用户 + 日期」去重写一条站内通知；`GET /v1/notifications` 读取。
  需要硬拦截时在上层（如反向代理/业务侧）按 `/v1/budget` 结果做闸门。
- 成本估算（不产生请求）：`POST /v1/estimate {"model":"gpt-4o-mini","prompt_tokens":1000,
  "completion_tokens":500,"cached_tokens":0}`。

### 6.5 出站代理

```bash
# 显式指定（覆盖环境变量）；--no-proxy "" 表示连内网也走代理
./build/aigw serve ... --proxy http://127.0.0.1:3128 --no-proxy "localhost,127.0.0.1,.internal"

# 或者只给环境变量（NO_PROXY 大小写都认）
export HTTPS_PROXY=http://127.0.0.1:3128
export NO_PROXY=localhost,127.0.0.1
```

- 只支持 `http://` 代理（CONNECT 隧道）；隧道内仍是端到端 TLS，SNI/校验都用目标域。
- `no_proxy` 支持 `*`（全绕过）、逗号分隔、`.suffix` / `suffix` 后缀匹配、`host:port`。
- 代理返回非 `200`（如 `407`）按连接失败处理，走熔断/换家逻辑。
- 流式与非流式都走代理；连接池的 key 仍是目标 `(host,port,trust)`，隧道按目标复用。

### 6.6 插件供应商（kind=stdio）

插件是常驻子进程，按行 JSONL 通信（一行一条，**上限 8 KB**）：

```jsonc
// 网关 → 插件
{"id":1,"method":"chat","params":{"model":"<上游模型名>","stream":false,"body":{ /* 原始 chat 请求体 */ }}}
// 插件 → 网关（成功）
{"id":1,"event":"done","data":{"status":200,"body":"{\"id\":\"...\",\"choices\":[...]}"}}
// 事件名不是 done 或解析失败 → 网关按 502 处理
```

- `body` 是**响应体 JSON 的字符串**（转义由插件负责），网关还原后原样回给客户端。
- 启动：`--plugin-cmd "python3 /abs/path/plugin.py --flag"` 或 `AIGW_PLUGIN_CMD`；
  用 `/bin/sh -c` 执行，**全局只有一个插件命令**。
- 池行为：预热 1 个，最多 4 个；空闲 60s 回收（保底 1）；崩溃按 `500ms × 崩溃次数`
  退避（封顶 30s）；同一进程可反复复用（对插件侧 prompt cache 友好）。
- **不支持流式**：客户端带 `stream:true` 时网关回落为一次性 JSON（不会输出 SSE）。
- 最小示例见 [`tests/plugin_chat.py`](tests/plugin_chat.py)；协议实现见
  [`src/providers/plug.uya`](src/providers/plug.uya)。

### 6.7 TLS / CA / 指纹固定

- 上游默认做完整链校验 + 主机名校验（`--ca` 追加信任根，`SSL_CERT_FILE` 叠加）。
- TOFU：首次见面把叶子证书 sha256 记入 `data/tls_pins.tsv`；同 host 换指纹只有链校验
  通过才追加（轮换窗口）。
- 手工固定：

```bash
./build/aigw tls probe api.openai.com            # 看链校验结果与指纹
./build/aigw tls pin   api.openai.com <sha256hex> # 写进 data/tls_pins.tsv
```

### 6.8 集群模式

单机模式忽略 `--meta/--node-id/--uplink`。一个最小集群：

```bash
# controller（1 个，带 meta）
./build/aigw serve --meta data/meta.db --node-id ctl --admin-key $ADMIN --port 8080 ...

# node（N 个，用 --uplink 指向 controller）
./build/aigw serve --uplink 10.0.0.1:8080 --node-id node-a --port 8081 ...
```

能力：node 注册/心跳、epoch + fencing、config 快照下发、slug 归属校验、edge 路由/会话亲和、
drain 迁移、ingest 幂等 + 区间重算、本地 spool 重放。拓扑、启动顺序与 nginx 配置见
[`docs/deploy.md`](docs/deploy.md)。

---

### 6.9 OTP 邮件投递（内置 SMTP 客户端）

`/v1/auth/otp` 的验证码可以直接由网关发出去，不需要外部脚本：

```bash
# 1) 明文内网中继（测试用；生产一般用 587 + STARTTLS）
./build/aigw serve --smtp smtp://127.0.0.1:25 --mail-from ops@example.com

# 2) 主流服务商：587 + STARTTLS + 登录
./build/aigw serve --smtp smtp://smtp.example.com --smtp-user bot@example.com \
  --smtp-pass '********' --mail-from bot@example.com

# 3) 465 隐式 TLS（也可以把凭据写在 URL 里：smtps://bot:pass@host）
./build/aigw serve --smtp smtps://smtp.example.com --smtp-user bot@example.com \
  --smtp-pass '********'
```

- 环境变量等价物：`AIGW_SMTP_URL`、`AIGW_SMTP_USER`、`AIGW_SMTP_PASS`、`AIGW_MAIL_FROM`、
  `AIGW_MAIL_HOSTNAME`、`AIGW_MAIL_CA`、`AIGW_MAIL_RELAY_CMD`（命令行优先）。
- **投递在子进程里做**：父进程 `fork` 出 `aigw smtp-relay`，把作业 JSON 从 stdin 灌进去
  就返回，所以慢 SMTP（限速、握手慢、干脆连不通）都不会拖住事件循环 ——
  `tests/mail_e2e.sh` 里第三条用例就是拿 3 秒延迟的假服务器压着跑 `/healthz` 验证的。
- 在途作业上限 **4**；超过时 `/v1/auth/otp` 直接 503。单个作业 30s 没结束会被 SIGKILL。
- 结果只进日志：`smtp-relay: sent to=<addr>` / `smtp-relay: send failed err=<id>`；
  失败不自动重试（用户重新点一次即可）。
- 协议范围：单收件人、纯文本、正文 UTF-8 走 base64（RFC 2045 折行）、`Date`/`Message-ID`
  自带；**主题只收可打印 ASCII**（非 ASCII 要 RFC 2047 编码字，没做，直接塞会乱码）；
  不做 DKIM/管道化/SMTPUTF8/多收件人/IPv6 字面量。
- **安全闸**：收件人与主题里出现 CR/LF 一律拒绝（头注入），地址先做语法校验；
  密码也可以放在 URL 里（`%40`、`%3A` 需要转义）。
- 自签/内网 CA 用 `--mail-ca <pem>`（有就用它，没有走系统信任库）。
- 验证：`tests/test_smtp.uya`（URL/应答/日期/组包单测）+ `tests/mail_e2e.sh`
  （真投递、头注入、慢服务器不阻塞、不可达降级）。

---

## 7. HTTP API 参考

除标注外都需要 `Authorization: Bearer <api key>`。请求体上限默认 **8 MiB**（超出 413；
`--max-body <bytes>` / `AIGW_MAX_BODY` 可调，下限 1 KB），请求头上限 64 KB；响应不压缩。

请求体不落盘也不按连接常驻：≤ 32 KiB 用连接内联缓冲（BSS，不分配），更大的按
`Content-Length` 一次分配到位的堆缓冲，请求结束立即归还；同时在途的大包最多 32 个，
超了回 **503**（负载保护）而不是把内存吃光。`chat`/`responses` 的 OpenAI 兼容路径
**不建 JSON DOM**，所以几 MiB 的长上下文也能原样转发给上游；上游请求体上限与这里是同一个值。
`/v1/responses` 的 `input` 文本另有 4 KB 的结构化存储上限（`previous_response_id` 续轮用）。

### 业务接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 存活探针（不需要鉴权） |
| GET | `/v1/models` | 可用模型列表（OpenAI 兼容 `object/list`） |
| GET | `/v1/me` | 当前用户 + 生效价目 + 计费倍率 |
| POST | `/v1/chat/completions` | OpenAI 兼容 chat；`stream:true` 走 SSE |
| POST | `/v1/responses` | Responses API：`model`、`input`、`previous_response_id`、`stream` |
| POST | `/v1/estimate` | 成本估算：`model`、`prompt_tokens`、`completion_tokens`、`cached_tokens` |
| GET | `/v1/usage` | 用量汇总（`from_day`/`to_day`，含 cost/price/profit） |
| GET | `/v1/usage.csv` | 同上，CSV 导出 |
| GET | `/v1/requests` | 请求明细（`limit`/`offset`/`id`） |

### 自助接口（会话 token，也接受 API Key）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/v1/auth/otp` | `{"email":...}` 发验证码（`--dev-otp` 回显 `code`） |
| POST | `/v1/auth/login` | `{"email","code"}` → `{"session":...}` |
| GET/POST | `/v1/keys` | 列出 / 新建 Key（`{"name":...}`，响应含一次性明文 `key`） |
| POST | `/v1/keys/revoke` | `{"key_id":N}` |
| GET/POST | `/v1/budget` | 查看 / 设置月预算（`{"monthly_nano":N}`） |
| GET | `/v1/notifications` | 站内通知（预算超额、改价等） |

### 管理接口（`Bearer <--admin-key>`）

| 方法 | 路径 | 关键字段 / 说明 |
|---|---|---|
| GET | `/admin/health` | `ok`、`schema`、`ts`、用户/供应商/Key/模型计数、`last_backup_day` |
| GET | `/admin/users` | 用户列表（`id/email/status/created_at`） |
| GET | `/admin/providers` | 供应商列表（含 `priority/weight/enabled`） |
| GET | `/admin/models` | 模型绑定列表 |
| POST | `/admin/bind` | `{"provider","model","upstream_model"?}` |
| GET | `/admin/pricing` | 当前生效卡 + 价目 |
| POST | `/admin/pricing` | 新建卡并写一条价目：`{"kind","version","effective_from","model","provider"?,"input_nano_per_mtok","output_nano_per_mtok","cache_read_nano_per_mtok","per_request_nano","schedule"?,"user_id"?}` |
| GET/POST | `/admin/price-entries` | 当前卡价目列表 / 追加 `{"model","provider"?,"input","output","cache_read","per_request","schedule"?}` |
| GET | `/admin/billing` | 用量汇总（`user_id`/`from_day`/`to_day`） |
| GET | `/admin/backup` | `last_backup_day`、`keep`（每日自动备份，保留 7 天） |
| GET | `/admin/audit` | 最近的 `audit.jsonl` 记录 |
| GET | `/admin`、`/ui/app.js`、`/ui/admin.js` | 管理后台静态页（CSP/安全头已开） |
| POST | `/mcp` | JSON-RPC over HTTP：`initialize`、`tools/list`、`tools/call`；凭据决定工具集（见 §7.1） |

### 7.1 MCP（`POST /mcp`）

无状态 JSON-RPC：一次 POST 一条请求，`Authorization: Bearer <key>`。
同一端点按凭据分权：

| 凭据 | 角色 | 可用工具 |
|---|---|---|
| `--admin-key` | 管理员 | `pricing_get` / `billing_query`（可查任意 `user_id`）、`backup_status`、`admin_health`、`admin_users`、`admin_providers`、`admin_models`、`admin_bind`、`admin_pricing_create`、`admin_price_entries_get`、`admin_price_entries_put`、`admin_audit` |
| 普通 API Key（`aigw_sk_...`） | 账号自助 | `pricing_get`（仅卖价）、`billing_query` / `usage_get` / `requests_list`（强制本账号）、`me`、`models_list`、`estimate_get`、`budget_get` / `budget_set`、`keys_list` / `keys_create` / `keys_revoke`、`notifications_list`；调用任何 `admin_*` 返回 `-32001 permission denied` |

接入 Claude Code：

```sh
claude mcp add --transport http aigw http://127.0.0.1:8080/mcp \
  --header "Authorization: Bearer <admin-key 或 API Key>"
```


### 集群内部接口

`/controller/{register,heartbeat,config,status,epoch,assign,drain,ingest}`、
`/edge/{route,proxy,fail}`、`/node/{status,spool}`：node ↔ controller 之间的内部协议，
单机模式不对外暴露（需 `--meta`/`--uplink` 才会被使用）。

---

## 8. 运维

| 事项 | 做法 |
|---|---|
| 存活/健康 | `GET /healthz`（无鉴权）；`GET /admin/health`（schema、计数、备份进度） |
| 备份 | 每日自动 `VACUUM INTO data/aigw-YYYYMMDD.db`，保留 7 天；`GET /admin/backup` 查状态 |
| 恢复 | 停服务 → 用备份文件替换 `aigw.db` → 启动（journal 自动重放未落库批次）；详见 `docs/runbooks/` |
| 请求日志 | `data/requests.log`（每请求一行，字段见 §5），按 request_id 可与账单明细对应 |
| 审计 | `data/audit.jsonl`（改价、绑定、Key 撤销等管理写操作） |
| 结算积压 | 结算先入队，事件循环每 200ms / 512 行批量落库；`/admin/billing` 查前会先 flush |
| 优雅停机 | `SIGTERM`/`SIGINT`：摘监听 → 收尾在途连接 → flush 批量队列 → 关闭插件池 |

### 8.1 性能基线（单机实测）

44 核容器，客户端与网关同机（`ab` 与服务端抢 CPU，数值偏保守）：

| 场景 | 吞吐 | 尾延迟 |
|---|---|---|
| `GET /healthz` keep-alive，1 进程 | 95k–101k rps | p99 1 ms |
| `GET /healthz` 短连接（每请求一次握手），1 进程 | ≈16k rps | p99 3–5 ms |
| `GET /v1/models`（Key 校验 + 库查询 + 模型 JSON），keep-alive，1 进程 | ≈22k rps | p99 1 ms |
| `GET /healthz` keep-alive，4 进程（`SO_REUSEPORT`） | ≈376k rps（3.9×） | — |
| `GET /v1/models` keep-alive，4 进程 | ≈87k rps（4×） | p99 1 ms |
| `POST /v1/chat/completions` 非流式，上游 opencode，8 并发 | 3.0 rps | p50 2.2 s |
| `POST /v1/chat/completions` 流式，8 并发 | 1.7 rps | TTFT p50 4.0 s |
| `POST /v1/responses` 非流式 / 流式，8 并发 | 3.7 / 1.6 rps | p50 2.0 s / TTFT 4.0 s |

复现：`ab -n 100000 -c 50 -k http://127.0.0.1:PORT/healthz`（静态接口务必开 keep-alive）。

怎么读这张表：

- `/healthz` 是无依赖的“空转基线”——只做「读请求头 → 路由匹配 → 写固定 200」，不碰库和上游，
  所以 ~10 µs/请求 ≈ 单核事件循环的每请求成本，也是任何单进程接口的吞吐上限。
- 短连接只有 16k rps，差距全在 `accept` + 握手 + 关闭（~60 µs/连接）。探针与压测客户端都应
  复用连接；K8s 探针、LB 后端健康检查同理。
- 协程化（E2–E4c）对静态路由**没有回归**：`AIGW_ASYNC_OFF=1` 与默认各测 3 轮，分别
  92k–99k 与 93k–101k rps，落在同一噪声区间（±5%）。
- 静态接口可线性水平扩展（1→4 进程 ≈3.9×，`--port` 相同即可让内核分担连接）；但**上游变慢时
  加进程没用**：chat/responses 的墙钟由上游决定，网关自身 CPU <1%。协程化的收益体现在并发
  不再互相排队——同样 8 并发 × 16 请求，墙钟从 25 s 降到 5.4 s。

---

## 9. 开发与测试

```bash
make check        # 全量类型检查（唯一“编译期”验收）
make test         # tests/run_all.sh：单测 + 本机 TLS 端到端
make selftest     # check + run_all
make e2e          # provider spike → TLS CLI → serve 冒烟 → chat/responses/admin 全链路
make ui-e2e       # 后台 UI/安全头/越权 + 代理 CONNECT e2e
make cluster-e2e  # controller + 3 node：注册/epoch/assign/edge/drain/ingest/spool
make mail-e2e     # OTP 邮件投递：mock SMTP 真对话 + 慢服务器不阻塞 /healthz
make load-sse     # 网关侧 1000 并发 SSE × 20 事件（尾延迟基线）
make db_bench     # SQLite 写入 + rollup 基准
make spike        # TLS 栈与本机 openssl s_server 的互操作
make clean        # 清 build/ 与 .uyacache/
```

e2e 脚本各自**显式列模块**（合并命名空间，没有 `import`）：新增模块依赖时，要同时加到
`tests/*.sh` 的 `uya build` 列表里。需要 `openssl`（自签 CA/叶子证书）与 `python3`
（mock 上下游、CONNECT 代理）。

新增/修改后建议的最小验证顺序：`make check` → 受影响单测（`tests/test_*.uya`）→ 对应
`tests/*_e2e.sh`。

### 目录结构

```
src/
  app.uya                 # 入口：serve / tls probe / tls pin
  foundation/buf.uya      # 字节缓冲
  net/                    # httpsrv、serve（路由/计费/管理面）、tls*、dnsx、tcpx、httpc、
                          #   httpc_pool（策略）、proxyx（代理）、ssex（SSE）、ui、
                          #   smtp/smtp_msg（OTP 邮件直投）
  providers/              # httpcall（内置 HTTPS 传输 + 连接池 + 代理）、upstream（一次 POST）、
                          #   plug（stdio 插件供应商）、http/upstream_cfg（配置与出站头）
  core/                   # store/dbx/schema（存储）、chat/responses（编排）、billing/budget/
                          #   price/schedule/money（计费）、lb（路由）、batch/journal/runtime
                          #   （落库与恢复）、reqlog、json、notify、rollup、backup、mailer
  cluster/                # meta、elect、uplink、edge、assign(shard)、ingest、spool
  plugins/                # pool（stdio 子进程池）+ pool_shim.c
tests/                    # test_*.uya（单测）、*_e2e.sh（端到端）、fixtures
docs/                     # overview、tls-provider、spike findings、deploy、ui、runbooks
```

---

## 10. 已知限制

- **OTP 只内置了邮件投递**：配了 `--smtp` 就走内置 SMTP 客户端（单收件人、纯文本、
  正文 base64），没配则只有 `--dev-otp` 回显。短信需要自己接。
- **邮件是「尽力投递」**：`/v1/auth/otp` 把作业塞给子进程就返回 200，投递结果只进日志
  （`smtp-relay: sent to=...` / `send failed err=...`）；在途上限 4，超了 OTP 直接 503。
  失败不会重试，重试由用户重新点「发送验证码」触发。
- **供应商 / 用户没有写接口**：`/admin/providers`、`/admin/users` 只读；引导走 SQL
  （见 §2.3），模型绑定、价目、预算、Key 都有 HTTP 写接口。
- **插件路径**：一行 ≤ 8 KB、不支持流式（回落非流式）、全局只有一个 `--plugin-cmd`
  （即所有 `kind=stdio` 供应商共用一个插件程序）。
- **代理**：仅 `http://` + CONNECT；不支持 SOCKS / HTTPS 代理；不支持 `Proxy-Authorization`
  之外的认证方式（Basic 已支持）。
- **传输**：内置 HTTPS 只做 TLS（`scheme=http` 需显式允许明文，默认关闭）；HTTP/1.1 +
  keep-alive，无 HTTP/2。
- **上游失败语义**：传输层失败会熔断该 provider 30s（单 provider 时这段时间请求返回 400）；
  复用连接被对端关闭（`HtcStale`）会换新连接立即重试一次，不计故障。
- **并发模型**：单线程 epoll 事件循环。`/v1/chat/completions` 与 `/v1/responses`（含流式）
  已协程化：上游等待期间主循环继续服务其它连接，单进程最多 **32 个在途请求**
  （`SRV_UP_MAX`），超出的请求退回阻塞实现。实测（opencode 上游，8 并发）改造前 0.64 rps、
  延迟线性涨到 8×；改造后 2.8–4.0 rps，延迟≈单请求延迟；4 进程 + `SO_REUSEPORT`
  可继续线性扩展。复现：`python3 tests/bench_gateway.py <url> <key> <model> 16 8`。
- **预算不硬拦截**：只做 `over_budget` 标记 + 站内通知（见 §6.4）。
- **计费精度**：nano-USD 整数，单 token 成本向下取整的累计误差在 `1e-9 USD/token` 量级。
- 无 Prometheus `/metrics`：用 `requests.log`、`/admin/health`、`/v1/usage` 观测。

---

## 10.1 已知缺陷（README 校验时实测发现，待修）

| 现象 | 复现 | 影响 / 变通 |
|---|---|---|
| `POST /admin/pricing` 恒返回 `400 bad request`，卡与价目都没写进库 | 见 §2.3 原 curl 示例 | 用 SQL 引导价目（§2.3 已验证可行）；价目写入路径待修 |
| `POST /v1/budget` 金额 ≥ 2147483648 被截断成 32 位 | `{"monthly_nano":10000000000}` → 读回 `1410065408`；`4294967295` 直接 400 | 预算上限暂用 ≤ `2147483647`（≈ $2.14） |
| 只写 SQL 价目时，`/v1/models`、`/v1/me` 的价格段、`/v1/estimate` 仍空/502，`GET /admin/pricing?model=…` 返回 404 | 见上 | 完整可用配置参考 `tests/seed_main.uya`（`make e2e` 走通的就是这套）；模型/价目解析的引导路径待查 |

> 这三项不影响已通过 e2e 的能力（chat/responses/流式/重试/代理/插件/集群），但会影响
> “从零手工配置一个模型”的体验；修复后应同步更新本节与 §2.3。

## 11. 相关文档

| 文档 | 内容 |
|---|---|
| [`docs/design/overview.md`](docs/design/overview.md) | 架构、请求流程、计费模型、关键决策 |
| [`docs/design/tls-provider.md`](docs/design/tls-provider.md) | 上游 TLS/HTTP 传输设计与取舍 |
| [`docs/design/tls-spike-findings.md`](docs/design/tls-spike-findings.md) | TLS 栈实测结论（含流式读超时等） |
| [`docs/deploy.md`](docs/deploy.md) | 集群拓扑、启动顺序、nginx 反代 |
| [`docs/ui.md`](docs/ui.md) | 管理后台页面、认证与 CSP/XSS 说明 |
| [`docs/runbooks/`](docs/runbooks) | 恢复/运维手册 |
| [`docs/STATUS.md`](docs/STATUS.md) | 各阶段落地情况与验收命令 |
| [`TODO.md`](TODO.md) / [`TODO_DONE.md`](TODO_DONE.md) | 待做 / 已完成明细（含每项提交） |
