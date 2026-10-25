# 集群部署（B6）

## 拓扑

```
nginx (80) ──┬─► edge node 127.0.0.1:8081 ┐
             ├─► edge node 127.0.0.1:8082 ├─ uplink ─► controller 127.0.0.1:8080 (meta.db)
             └─► ...                     ┘
```

- controller 持有 `meta.db`（节点/归属/epoch/config/lease），`--node-id` 必填。
- 每个 node 用 `--uplink <controller-ip:port> --node-id <id>` 注册并每 3s 拉 config 快照；
  断网时 usage 走本地 spool，恢复后由 tick 自动重放（`spool_pending` 可见）。
- nginx 参考配置见 `deploy/nginx.conf`：SSE 需 `proxy_buffering off`，`/controller/` 只允许内网。

## 启动顺序

1. controller：`aigw serve --host 0.0.0.0 --port 8080 --db /data/aigw.db --data-dir /data --meta /data/meta.db --node-id ctrl --admin-key <key>`
2. node ×N：`aigw serve --host 0.0.0.0 --port 8081 --db /data/n1.db --data-dir /data/n1 --uplink 10.0.0.1:8080 --node-id n1`
3. 分配归属：`POST /controller/epoch {"id":"n1"}` → `POST /controller/assign {"slug":"s1","node_id":"n1","epoch":1}`
4. drain：`POST /controller/drain {"id":"n1"}`（把该节点 slug 迁到 active 节点并返回 `moved`/`to`）

## 自检

```bash
make cluster-e2e    # 1 controller + 3 node：注册/epoch/fencing/快照/edge 路由/代理/drain/ingest/spool
```
