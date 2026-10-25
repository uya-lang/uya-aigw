# TLS 异步握手 spike 结论（TLS-05）

> 日期：2026-10-24　环境：Uya v0.11.0、OpenSSL 3.2.4、本机回环
> 代码：`src/net/tlsx_conn.uya`、`tests/tls_spike_main.uya`、`tests/tls_spike.sh`

## 1. 结论

**`lib/tls/https.uya` 的 `https_handshake_async` 不是可恢复（resumable）的状态机，不能用于非阻塞 fd 上的进程内异步握手。**

现象：客户端反复发送 ClientHello，握手永不完成；服务端日志出现连续多次
`[TLS] Step 1: Sending ClientHello`。15 秒后客户端被 `timeout` 杀掉。

## 2. 根因

`https_handshake_async` 的 `poll` 实现（`lib/tls/https.uya:400` 附近）：

```uya
https_client_handshake(self.fd, self.ctx) catch |err| {
    if @error_id(err) == @error_id(error.ReadWouldBlock) {
        return async_poll_pending_readable_usize(waker, self.fd);
    }
    return Poll<!usize>.Ready(error.ConnectionClosed);
};
```

而 `https_client_handshake` 是**阻塞版**实现，每次调用都从 step 1 开始：

1. `ssl_handshake_step(...)`（INIT）→ 生成 ClientHello；
2. `https_write_all` 发送；
3. `https_read_handshake_burst` 读服务端 flight；
4. 生成并发送 ClientFinished；
5. 读服务端第二 flight。

非阻塞 fd 上第 3 步的 `https_read_some` 返回 `error.ReadWouldBlock`，future 返回
`Pending(readable)`；下一次 `poll` **重新从 step 1 开始**，于是再发一个 ClientHello，
`ctx.hs.state` 仍停在 `CLIENT_HELLO_SENT`，永远不会前进。服务端因此看到一串
ClientHello，每个都从头开始，握手不会完成。

## 3. 可选方案

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A（首选，TLS-05A）** | 自写可恢复握手：`ssl_handshake_step` + 异步读**完整 TLS record** + 累积到 ServerHelloDone + 消费第二 flight | 真正异步、无线程、进程内 | 需要处理 record 分帧与 flight 聚合 |
| B | 握手期间把 fd 切回阻塞并设 `SO_RCVTIMEO`，完成后再切非阻塞 | 改动最小 | 单线程事件循环被阻塞，最坏 5s/连接；高并发不可接受 |
| C | TLS 客户端放子进程（stdio 传流） | 与插件模型一致 | 多一次进程跳转，SSE 首包延迟/吞吐受损 |

**决定：走 A（TLS-05A）**；若 2 个 round 内不能稳定通过，再退 C（不用 B）。

## 4. TLS-05A 的实施要点

1. `tlsx_read_record_async(fd, out, cap, &len)`：
   - 读 5 字节 record header（type/version/len）；
   - 按 len 读满 payload（`https_read_some_async` 循环）；
   - 一次返回**一条完整 record**。
2. 第一条 flight：
   - `ssl_handshake_step(ctx, empty, 0, send, &slen)` → 发 ClientHello；
   - 循环读 record，累积到 `flight_buf`；
   - 扫描未加密的 handshake 消息（record payload 的第 1 字节是 handshake type），
     直到看到 `ServerHelloDone`（type 14）；
   - `ssl_handshake_step(ctx, flight_buf, len, send, &slen)` → 发 ClientFinished。
3. 第二 flight：读 record 直到 `Finished`（type 22）/ `ChangeCipherSpec`（type 20），
   按阻塞版的行为消费掉（不能让它们留在 socket 里污染应用数据）。
4. 之后 `https_read_some_async` / `https_write_all_async` 做应用数据。
5. 超时：每次 await 带 deadline（connect/握手 5s、空闲 120s）。

## 5. 复现

```bash
tests/tls_spike.sh
# 期望：TLS-SPIKE-OK；当前（TLS-05A 前）会在 20s 后失败
```

服务端日志（`openssl s_server`）会连续出现 ClientHello；这就是本节结论的直接证据。

## 6. 对计划的影响

- `TODO.md`：TLS-05（spike）以「负面结论」完成，移入 `TODO_DONE.md`；
  新增 `TLS-05A`（可恢复握手），`TLS-06` 依赖它。
- 设计文档风险项 1 更新为本结论。

## 7. TLS-05A 结果（通过）

自写可恢复握手落地后，本机 s_server 验证通过：

```
TLS-SPIKE-OK n=31
```

实现（`src/net/tlsx_conn.uya`）：

- `tlsx_handshake_async`：`ssl_handshake_step`（INIT → ClientHello）；
- `tlsx_hs_read_record_async`：5 字节 record 头 + payload，按长度读满；
- `tlsx_flight_done`：扫描未加密 flight，看到 ServerHelloDone（type 14）即结束；
- step(flight) → ClientFinished；再消费 CCS/Finished（type 20/22），不污染应用数据；
- 之后 `https_read_some_async` / `https_write_all_async` 读写应用数据；
- 信任：SAN 主机名 + `chainx` 完整链校验，失败 fail-closed。

已知限制：本实现按 TLS 1.2 路径验证（`s_server -tls1_2`）；TLS 1.3 路径尚未覆盖，TLS-06 前补测。
## 8. 后续修正（TLS-09）

- **应用数据必须走 record 层**：`tlsx_read_async`/`tlsx_write_async` 早期直接用了
  `https_read_some_async`/`https_write_all_async`（裸 TLS 记录），导致明文被当密文发出、
  服务端报 `record layer failure`。现改为 `ssl_read`/`ssl_write`。
- **第二 flight 必须经状态机**：Finished 是加密记录，只有 `record_decrypt` 才能把
  `read_seq` 推到 1，否则后续应用数据全部解不开。做法：把 CCS+Finished 拼回一条 flight，
  置 `hs.state = HS_STATE_WAIT_SERVER_FINISHED` 后调用 `ssl_handshake_step`。
- **非应用记录要丢弃**：NewSessionTicket 等解密后按记录类型跳过，alert 视为关闭。
- `tests/tls_spike.sh`（s_server）已被 `tests/provider_spike.sh`（本机 Python TLS 上游，
  覆盖 非流式/ chunked / SSE）取代，后者进入 `tests/run_all.sh`。

## 9. TLS-09E：流式读超时（已落地）

目标：上游半开（连接在但不发数据）时，`htc_next_event_async` 应返回而不是永久挂住。

实测两种写法都失败：

| 写法 | 结果 |
|---|---|
| `async_fd_read_deadline_future` 直接读 record 头/载荷 | 首帧即返回 0（本机 Python 上游上一个 record 被切成多段时语义不符） |
| `async_wait_readable(fd, deadline)` + 普通 record 读 | 流式路径 `events=0` |
| 单层版：`async_wait_readable` 等待 + 同步 `https_read_some` 读完整 record（`tlsx_fill_deadline_async`） | 仍 `events=0`；说明问题不在嵌套等待，而在「先等后读」这个组合本身与调度器的交互 |

两条候选修法（后续任务）：

1. **单层等待**：把 deadline 下沉到 `tlsx_hs_read_record_async` 内部，一处等待同时负责
   「可读」与「超时」，不再嵌套第二层；`https_read_some_async` 需要支持 deadline 变体。
2. **调度器时间轮**：在事件循环里给每个流式连接挂一个 idle 定时器，到点由循环取消该
   协程（`Future` 取消语义已存在），读路径完全不动。

当前兜底：`[DONE]` 收尾 + 客户端断开传播取消 + 连接级超时；`events=4 done=1` 的流式 e2e 通过。
### 补充：poll 切片版（照 uya-agent `httpstream` 的泵点写法）同样返 0

`tlsx_wait_readable_idle_async` 用同步 `sys_poll(fd, POLLIN, ≤50ms)` 累计计时，
再配合同步 `https_read_some` 读完整 record（`tlsx_fill_deadline_async`），
在本机 Python TLS 上游上流式仍 `events=0`（非流式路径用同一份 `tlsx_read_async` 正常）。

说明问题不在「等待原语」的选择，而在 deadline 读这条路径与 `htc_open_async` 留下的
socket 状态/已缓冲数据之间。下一步应打印 `sys_poll` 的返回值与 `https_read_some` 的错误码
定位（一次 instrumentation 即可），而不是再换第五种等待方式。
### 结论修正：事件通知版**能读到数据**，问题不在等待原语

按用户指引用 `async_wait_readable(fd, deadline)`（事件通知 / Waker 注册，非轮询）+
同步 `https_read_some` 组出 `tlsx_fill_deadline_async`，并加临时打印后实测：

```
[DL] readable → filled need=5      (record 头)
[DL] readable → filled need=44     (record 负载)
... 共 4 条 record 全部读到
[DL] wait err id=852389008         (第 5 次等待：deadline 到，正常收尾)
```

即：**等待、超时、按 deadline 退出全部正常**，4 条 record 也都读到并交给 `ssl_read` 了。
但 `htc_next_event_async` 侧最终仍 `events=0`。

所以 TLS-09E 剩下的不是「怎么等」，而是「读到的记录怎么拼回 SSE 事件」：
下一步应在 `htc_next_event_async` 里打印每次 `htc_read_more_async` 的返回值、
`call.body.len`、`httpc_chunk_next` 的返回码与 `sse_feed` 的返回码，
确认是 chunked 帧被 record 边界切断后没有继续解，还是 `plain` 缓冲区没被消费。

代码现状：`tlsx_read_deadline_async` 保持事件通知实现（未接入 `htc_read_more_async`），
`httpcall` 走无超时读，e2e `PROV-ALL-OK`。
### 真正根因（已修复）：`@async_fn` 嵌套太深，Waker IO 槽耗尽

把 `async_wait_readable` 的 **Pending 路径**跑起来之后，错误稳定复现在「需要等」的时刻，
数据已在内核缓冲里时却能直接读成功。原因是 Waker IO 槽是有限资源
（`WAKER_IO_SLOT_MAX = 4`），而当时的调用链是：

```
htc_next_event_async → htc_read_more_async → tlsx_read_deadline_async
                     → tlsx_fill_deadline_async → tlsx_wait_readable_idle_async
                     → async_wait_readable        (这里要注册槽)
```

六层 `@async_fn`，等真正需要注册等待时槽已经被上层占满，于是立刻返回错误 → 上层看到
`rr=0` → `events=0`。四种「换个等待原语」的尝试都因此失败——换的是等待方式，没换嵌套深度。

修复：把等待、record 分帧、解密**压进同一个 `@async_fn`**
（`tlsx_read_deadline_async`），链路降到四层
（`next_event → read_more → read_deadline → async_wait_readable`），并在函数内用
同步 `https_read_some` 读取、would-block 时才 `@await async_wait_readable`。

验证（`tests/provider_spike.sh`）：

```
PROV-OK stream events=4 done=1
PROV-OK stall events=1 idle_timeout=1 elapsed=2041   # 上游发一条后不再发，2 s 空闲预算到点返回
PROV-ALL-OK
```

`stall` 用例是真正的验收点：上游半开时不挂住，按空闲预算收尾。

## 10. A1 服务端（进行中的笔记）

`src/net/serve.uya` 的首版（串行 accept + keep-alive + `/healthz`）在本机手工验证通过：

```
$ ./build/aigw serve --port 18994 &
listen port=18994
$ curl -sv http://127.0.0.1:18994/healthz
< HTTP/1.1 200 OK
< Content-Type: application/json
< Content-Length: 11
< Connection: keep-alive
```

踩到的坑（都已定位）：

1. **`tcpx_sockaddr_v4` 要的是 4 字节二进制 IP，不是点分十进制字符串**。直接传 `"0.0.0.0"`
   会把它当成 `48.46.48.46`，`bind` 报 `EADDRNOTAVAIL(99)`。需要先解析（`serve_parse_ipv4`）。
2. **`@await ... catch |_| {}` 直接写成表达式会生成非法 C**（`err_union_int32_t` 没有
   `.value`）。必须先 `const rf: !T = @await f();`，再 `const v: T = rf catch |_| {...};`。
3. `Future<!void>` 的 async 函数在 `_ = @await f() catch ...` 里同样会炸，改成 `Future<!i32>`。

脚本里那轮「起服务→curl」失败的真因是**上一轮遗留的 `aigw serve` 进程占着端口**，
加上 `[ -x build/aigw ]` 在构建失败时仍会用旧二进制通过检查（见下面运维教训）。修正后
`tests/serve_smoke.sh` 已进 `run_all.sh`，输出 `SERVE-ALL-OK`。

### A1 服务端：单线程 epoll 事件循环（2026-10-24 重写）

首版是「串行 accept + 每连接 `@await` 到底」，能回包但一个连接卡住就堵住整台服务器。
A1 的验收是 **64 MiB body / 512 并发 SSE / 线程数恒 1**，所以第二轮把连接模型换成
显式状态机（`src/net/serve.uya`）：

```
HEAD ──有包体──► BODY ──排空──► WRITE ──写完──► HEAD（keep-alive）
  └──────────────无包体──────────────────────────► SSE（chunked 慢推，20 事件/20 ms）
```

要点：

- **不用 `@async_fn` 写连接**。等待点合并到一个 epoll 事件里，没有嵌套、不抢 Waker 的
  4 个 IO 槽（TLS-09E 那条约束的放大版）。
- 槽表是模块级 `var [SrvConn: 1024]`（.bss，按需提交），每槽 16 KiB 读 + 8 KiB 写。
- 包体从不整块驻留：Content-Length 与 chunked 都按「缓冲区里有多少消费多少」推进，
  64 MiB 只用了固定缓冲。
- SSE 用 chunked，一轮事件发完补 `0\r\n\r\n` 并 close；验收脚本开 512 条连接同时读，
  0.5 s 全绿（串行要几分钟，能过即真并发）。
- 停机：`signal(SIGTERM/SIGINT)` 只置标志，主循环摘掉监听 → 空闲连接直接关、在途连接
  `keep=false` 自然收尾 → 最多等 2 s，返回 0。`SIGPIPE` 置 `SIG_IGN`（对端提前断开不能打死进程）。
- 验收脚本另外断言 `Threads: 1`（`/proc/<pid>/status`）与 SIGTERM 退出码 0。

本轮新踩的两个 Uya 0.11 后端坑（都已绕开，值得回上游修）：

1. `libc.syscall` 没有导出 `EPOLLERR`/`EPOLLHUP`（只有 `EPOLLIN`/`EPOLLOUT`/`EPOLL_CTL_*`），
   直接用会得到 `‘EPOLLHUP’ undeclared`。→ 本地按 Linux 值补常量（0x008 / 0x010）。
2. `const x: usize = if a < b { a } else { b as usize };` —— **分支里带 `as` 强制转换**时，
   生成的 C 是
   `({ const size_t __uya_ifexpr_0; if (...) { __uya_ifexpr_0 = a; } else { __uya_ifexpr_0 = (size_t)b; } ... })`，
   对只读变量赋值，编译失败。两个分支都是裸标识符时不触发。→ 改成 `var x = a; if (...) { x = b as usize; }`。

另外，上一轮那条「`&"lit"[0]` 生成非法 C / 切片字面量赋给变量生成 `&(struct ...)`」的
编译器 bug 已在 uya 侧修掉（`fix(codegen): 切片表达式的 & 生成切片值而不是取地址`，已进 uya `main`），
`src/net/serve.uya` 里保留的 `srv_ptr` 只剩可读性意义，不再是必需。
### A1 服务端：Uya 0.11 的三条硬约束（实测，含踩坑过程）

写 `src/net/serve.uya`（监听 + keep-alive + 包体排空 + 路由）时撞到三件事，
全部是「C 后端生成非法代码」而非业务逻辑问题：

1. **`&"lit"[0]` 生成 `&(uint8_t*)lit[0]`** —— 非法 C（lvalue required）。
   要指针只能 `&"lit"[0: n]`（切片）或先在本地数组里拷贝。
2. **切片字面量只能做函数调用实参**。一旦赋给局部变量、模块常量或 `@await` 调用的帧字段，
   生成 `x = &(struct uya_slice_uint8_t){...}`（指针赋给结构体）：模块常量直接编译失败
   （文件作用域的非恒定初始化），局部变量/帧字段则在编译通过后拿到**零缓冲**——
   症状是「响应头完全正确、Content-Length 也对，body 全是 NUL」。
   → 异步函数一律 `&const byte` + 长度；字面量取指针走普通函数 `srv_ptr(&"lit"[0: n])`。
3. **`if/else` 分支里放多个 `try @await`** 会生成重复的 C 标签
   （`duplicate label '_uya_async_if_exit_...'`）。→ 分支只算「状态码 + 指针 + 长度」，
   真正的 `@await` 只留一处。

顺带两个运维教训：
- 调试期间发现**上一轮遗留的 `aigw serve` 进程**还占着端口，加上脚本里 `uya build` 失败时
  `[ -x build/aigw ]` 仍然通过（旧二进制还在），连续几轮其实是在诊断旧行为。现在
  `tests/serve_smoke.sh` 构建前先 `rm -f build/aigw` 并检查 `uya build` 的退出码。
- `pkill -f "aigw serve"` 会匹配到执行它的那个 `bash -c` 自身（命令行里含该字符串），
  把自己的 shell 杀掉。用 `pkill -x aigw`。
