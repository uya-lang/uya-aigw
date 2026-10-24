#!/usr/bin/env python3
"""A1 并发 SSE 压测：一次开 N 条连接，全部读完再判定。

用法: serve_sse_load.py <port> <conns> <events>

每条连接请求 `/v1/_sse`，服务端按 chunked 推 `events` 个 `data: {}`，
相邻事件间隔 20 ms（服务端固定）。判定：
  * 每条连接都收到 `events` 个事件，并且以 chunked 终止块收尾；
  * 全部连接在 10 s 内读完 —— 串行服务 512 条要几分钟，能过就是真并发。

退出码 0 表示全过，1 表示有连接不达标。
"""
import socket
import sys
import time

port = int(sys.argv[1])
conns = int(sys.argv[2])
events = int(sys.argv[3])
line = b"data: {}\n\n"

socks = []
t0 = time.time()
for _ in range(conns):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall(b"GET /v1/_sse HTTP/1.1\r\nHost: aigw\r\n\r\n")
    socks.append(s)

ok = 0
bad = []
for idx, s in enumerate(socks):
    buf = b""
    try:
        while True:
            chunk = s.recv(8192)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    s.close()
    if buf.count(line) == events and b"0\r\n\r\n" in buf:
        ok += 1
    elif len(bad) < 3:
        bad.append((idx, buf.count(line), len(buf)))

elapsed = time.time() - t0
for idx, got, nbytes in bad:
    print(f"SSE-BAD conn={idx} events={got} bytes={nbytes}", file=sys.stderr)
if ok != conns:
    print(f"SSE-FAIL ok={ok}/{conns} elapsed={elapsed:.2f}s", file=sys.stderr)
    sys.exit(1)
if elapsed > 10.0:
    print(f"SSE-FAIL too slow elapsed={elapsed:.2f}s", file=sys.stderr)
    sys.exit(1)
print(f"SSE-OK conns={conns} events={events} elapsed={elapsed:.2f}s")
