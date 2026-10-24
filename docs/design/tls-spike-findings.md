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
