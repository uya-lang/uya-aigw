#!/usr/bin/env python3
"""aigw 并发压测（E5）。

用法：
  python3 tests/bench_gateway.py <base_url> <api_key> <model> <total> <concurrency> [stream]

环境变量：
  BENCH_KIND=responses      打 /v1/responses（默认 /v1/chat/completions）
  BENCH_EXTRA_HEADER="K: V" 追加一个请求头（如上游要求 x-opencode-session）
  BENCH_PROXY=1             走系统代理（测公网上游时需要；本机网关不要开）

输出：状态码分布、墙钟吞吐（rps）、延迟 avg/p50/p90/p99、流式时的 TTFT。
直连 127.0.0.1 时脚本会禁用环境里的 http_proxy，避免被代理劫持。
"""
import json
import os
import statistics
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# 环境里的 http_proxy 会把 127.0.0.1 也代理走，这里直连
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
_OPENER_PROXY = urllib.request.build_opener()


def pct(xs, p):
    if not xs:
        return 0.0
    xs = sorted(xs)
    i = min(len(xs) - 1, int(round((p / 100.0) * (len(xs) - 1))))
    return xs[i]


HEADERS = {}


def one(base, key, model, stream):
    if os.environ.get("BENCH_KIND") == "responses":
        body = {"model": model, "input": "用一句话说明什么是网关。", "stream": stream}
        path = "/v1/responses"
    else:
        body = {
            "model": model,
            "messages": [{"role": "user", "content": "用一句话说明什么是网关。"}],
            "max_tokens": 32,
            "stream": stream,
        }
        path = "/v1/chat/completions"
    req = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode(),
        headers=HEADERS,
    )
    t0 = time.perf_counter()
    ttft = 0.0
    nbytes = 0
    status = 0
    try:
        op = _OPENER_PROXY if os.environ.get("BENCH_PROXY") == "1" else _OPENER
        with op.open(req, timeout=180) as r:
            status = r.status
            if stream:
                first = True
                while True:
                    chunk = r.read(1)
                    if not chunk:
                        break
                    if first:
                        ttft = time.perf_counter() - t0
                        first = False
                    nbytes += 1
                    # 读掉整行，减少 syscall
                    r.readline()
            else:
                data = r.read()
                nbytes = len(data)
    except Exception as e:  # noqa: BLE001
        status = getattr(e, "code", -1)
    dt = time.perf_counter() - t0
    return status, dt, ttft, nbytes


def main():
    base, key, model, total, conc = (
        sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]))
    global HEADERS
    HEADERS = {"Authorization": "Bearer " + key, "Content-Type": "application/json"}
    octx = os.environ.get("BENCH_EXTRA_HEADER", "")
    if octx:
        k, _, v = octx.partition(":")
        HEADERS[k.strip()] = v.strip()
    stream = len(sys.argv) > 6 and sys.argv[6] == "stream"
    lat, ttfts, errs, sizes = [], [], {}, []
    lock = threading.Lock()

    def task(_):
        st, dt, ttft, nb = one(base, key, model, stream)
        with lock:
            lat.append(dt)
            sizes.append(nb)
            if ttft:
                ttfts.append(ttft)
            errs[st] = errs.get(st, 0) + 1

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=conc) as ex:
        list(ex.map(task, range(total)))
    wall = time.perf_counter() - t0

    ok = errs.get(200, 0)
    print(json.dumps({
        "mode": "stream" if stream else "json",
        "total": total,
        "concurrency": conc,
        "ok": ok,
        "status_counts": errs,
        "wall_s": round(wall, 3),
        "rps": round(total / wall, 2),
        "lat_ms": {
            "avg": round(1000 * statistics.mean(lat), 1) if lat else 0,
            "p50": round(1000 * pct(lat, 50), 1),
            "p90": round(1000 * pct(lat, 90), 1),
            "p99": round(1000 * pct(lat, 99), 1),
            "max": round(1000 * max(lat), 1) if lat else 0,
        },
        "ttft_ms": {
            "p50": round(1000 * pct(ttfts, 50), 1),
            "p90": round(1000 * pct(ttfts, 90), 1),
            "p99": round(1000 * pct(ttfts, 99), 1),
        } if stream else None,
        "resp_bytes_avg": round(sum(sizes) / len(sizes)) if sizes else 0,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
