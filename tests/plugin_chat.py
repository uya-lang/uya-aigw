#!/usr/bin/env python3
"""tests/plugin_chat.py — D5：stdio 插件供应商的最小 fixture（无第三方依赖）。

协议（见 src/providers/plug.uya）：
  {"id":1,"method":"ping"} -> {"id":1,"event":"pong"}
  {"id":N,"method":"chat","params":{"model":"...","body":{...}}}
      -> {"id":N,"event":"done","data":{"status":200,"body":"<响应体 JSON 字符串>"}}
启动时把 pid 追加到 argv[1]（用于断言进程复用）。
"""
import json
import os
import sys

BODY = json.dumps({
    "id": "chatcmpl-plugin",
    "object": "chat.completion",
    "choices": [{
        "index": 0,
        "message": {"role": "assistant", "content": "hello-from-plugin"},
        "finish_reason": "stop",
    }],
    "usage": {"prompt_tokens": 10, "completion_tokens": 5},
}, separators=(",", ":"))


def main() -> int:
    pidfile = sys.argv[1] if len(sys.argv) > 1 else ""
    if pidfile:
        with open(pidfile, "a") as f:
            f.write("%d\n" % os.getpid())
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        mid = req.get("id", 1)
        method = req.get("method", "run")
        if method == "ping":
            out = {"id": mid, "event": "pong"}
        elif method == "chat":
            out = {"id": mid, "event": "done", "data": {"status": 200, "body": BODY}}
        else:
            out = {"id": mid, "event": "done", "data": {"status": 400, "body": "{}"}}
        sys.stdout.write(json.dumps(out) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
