#!/usr/bin/env python3
"""tests/plugin_echo.py — A3 插件池回归用的最小 JSONL 插件（无第三方依赖）。

协议：
  {"id":1,"method":"ping"}   -> {"id":1,"event":"pong"}
  {"id":2,"method":"crash"}  -> 进程立刻 exit(3)（测崩溃退避）
  {"id":3,"method":"slow"}   -> 睡 30s 不回（测 cancel）
  其它                        -> {"id":<id>,"event":"done","data":<params>}
"""
import json
import sys
import time


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        mid = req.get("id")
        method = req.get("method", "run")
        if method == "ping":
            sys.stdout.write(json.dumps({"id": mid, "event": "pong"}) + "\n")
            sys.stdout.flush()
        elif method == "crash":
            return 3
        elif method == "slow":
            time.sleep(30)
        else:
            sys.stdout.write(
                json.dumps({"id": mid, "event": "done", "data": req.get("params")}) + "\n"
            )
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
