# 数据库恢复手册（restore runbook）

> 适用：controller 的 `meta.db`、`usage-<k>.db`，node 的 `node-<id>.db`。
> 备份策略：每天 `daily_at`（默认 03:00）一次，保留最近 **7 份**；计费 journal 保留 8 天。
> 设计背景见 `docs/design/overview.md` §9。

## 0. 什么时候用

| 场景 | 动作 |
|---|---|
| 误删/误改用户、密钥、价格、分时规则 | 恢复 `meta.db`（会丢备份之后的管理变更，见 §8） |
| 某个 `usage-<k>.db` 损坏 | 只恢复该分片 + 重放 journal |
| 磁盘故障/整机重建 | 恢复全部 DB + 重放 journal |
| 升级/迁移前 | 不是恢复，先 `aigw backup run --all` 留一份现场备份 |
| 想验证备份可用 | 在隔离目录做演练（§9），不要动生产 |

## 1. 前置检查

```bash
# 1) 确认服务已停（恢复期间禁止任何写入）
systemctl status aigw-controller     # 应为 inactive
ls -l data/*.db-wal data/*.db-shm    # 存在也没关系，恢复时会被移走

# 2) 集群：先停 standby，避免它抢 flock 接管
systemctl stop aigw-controller-standby

# 3) 磁盘空间 ≥ 2 × 目标 DB 大小
df -h data/

# 4) 备份清单与校验
aigw backup list --db meta
aigw backup verify --file data/backups/meta-20260213T030000Z.db
#    期望：integrity_check ok / sha256 与 manifest 一致 / users、api_keys 等 count 合理

# 5) journal 覆盖区间
aigw journal info --dir data/journal
#    期望 earliest_ts ≤ 备份 ts；否则只能恢复到备份时点（见 §8）
```

## 2. 文件位置与命名

```
data/
├── meta.db                  # 元数据（用户/密钥/模型/价目/分配）
├── meta.db-wal / -shm
├── usage-0.db ... usage-3.db
├── node-<id>.db
├── backups/
│   ├── meta-20260213T030000Z.db
│   ├── usage-0-20260213T030010Z.db
│   └── manifest.jsonl
├── journal/
│   ├── 20260213.jsonl
│   └── ...
└── quarantine/              # 恢复前的现场，保留到确认无误
    └── 20260213T041500Z/
```

- 备份文件只读、0600；目录 0700。
- `manifest.jsonl` 每行一条：`{run_id, ts, db, file, bytes, sha256, integrity_ok, table_counts, ...}`。
- journal 一行一批：`{seq, node_id, ts, records:[...]}`。

## 3. 恢复决策树

```
只坏了 meta？ ──是──► 恢复 meta（§4.1）→ generation+1 → 启动
    │否
只坏了一个 usage 分片？ ──是──► 恢复该分片（§4.2）→ 重放 journal
    │否
整机/全量？ ──是──► 恢复全部（§4.3）→ 重放 journal → generation+1 → 启动
```

## 4. 标准流程

### 4.1 恢复 meta.db

```bash
# 1) 隔离现场（不要覆盖，回滚要用）
ts=$(date +%Y%m%dT%H%M%S)
mkdir -p data/quarantine/$ts
mv data/meta.db data/meta.db-wal data/meta.db-shm data/quarantine/$ts/ 2>/dev/null

# 2) 放入备份
cp data/backups/meta-20260213T030000Z.db data/meta.db
chmod 600 data/meta.db

# 3) 完整性 + 外键
aigw db check --db data/meta.db
#    integrity_check / foreign_key_check / schema_version

# 4) 提升 generation（节点会因此全量重拉配置）
aigw restore finish --mode controller --db data/meta.db

# 5) 启动
systemctl start aigw-controller
curl -fsS http://127.0.0.1:8080/healthz
```

> `meta.db` 没有计费 journal 可重放；备份之后的管理变更会丢（最多 24h），见 §8。

### 4.2 恢复单个 usage 分片

```bash
k=2   # 要恢复的分片
aigw backup list --db usage-$k
aigw backup verify --file data/backups/usage-$k-20260213T030010Z.db

ts=$(date +%Y%m%dT%H%M%S); mkdir -p data/quarantine/$ts
mv data/usage-$k.db data/usage-$k.db-wal data/usage-$k.db-shm data/quarantine/$ts/ 2>/dev/null
cp data/backups/usage-$k-20260213T030010Z.db data/usage-$k.db
chmod 600 data/usage-$k.db

# 重放时只写该分片（按 hash(user_id)%K 路由，其他分片自动跳过）
aigw restore --journal data/journal --since 2026-02-13T03:00:00Z \
             --db-dir data/usage --only-shard $k

aigw db check --db data/usage-$k.db
systemctl start aigw-controller
```

### 4.3 全量恢复（一键）

```bash
# 先 dry-run 看会做什么：选哪些文件、覆盖什么、journal 覆盖区间
aigw restore --auto --from-latest --dir data/backups \
             --journal data/journal --dry-run

# 确认后执行
aigw restore --auto --from-latest --dir data/backups \
             --journal data/journal --yes
#   步骤：停服检查 → 逐库校验 → 隔离 → 替换 → 重放 journal
#        → generation+1 → integrity/foreign_key → 打印报告

systemctl start aigw-controller
curl -fsS http://127.0.0.1:8080/healthz
```

### 4.4 恢复 node 本地库（可选）

```bash
# node 库只存本地日志/待上报；丢失不影响账本（controller 有幂等 ingest）
# 如确需恢复：
systemctl stop aigw-node
mv data/node-<id>.db data/quarantine/node-<id>.db.$ts
cp data/backups/node-<id>-....db data/node-<id>.db
systemctl start aigw-node
```

## 5. 集群恢复

1. **停 standby**（或确认 `flock` 未被抢）；只在 active controller 上操作。
2. 按 §4 恢复 controller 的 `meta.db` 与 `usage-*.db`。
3. `aigw restore finish` 会 **generation+1**；节点/edge 看到 generation 变化后：
   - 节点全量重拉配置（而不是按 `config_version` 增量）；
   - edge 2s 内刷新 slug→node 路由；
   - 若分配/epoch 回退，controller 重新下发分配并 `epoch+1`；旧 epoch 的请求返回 421。
4. 建议恢复前先 `aigw node drain --all`，恢复后再 `undrain`，避免恢复窗口内的在飞请求受影响。
5. 启动顺序：controller → node → edge；确认 `/cluster/health` 全绿后再放流量。

## 6. 验证清单

- [ ] `aigw db check`：`integrity_check=ok`、`foreign_key_check` 无行、`user_version` 正确。
- [ ] 关键表 count 与 manifest 记录一致（users / api_keys / models / price_cards）。
- [ ] `SELECT max(ts) FROM requests_*` 接近备份时间（+ journal 重放后的时间）。
- [ ] `sum(cost_nano)`、`sum(price_nano)` 与 journal 总量一致（允许 0.1% 误差，超出告警）。
- [ ] `GET /api/admin/backup/status`：generation 已增长、journal 覆盖区间正确。
- [ ] 用测试 key 发一条 chat（流式 + 非流式）成功，日志与计费落库。
- [ ] 管理端能看到恢复后的用户/模型/价格；用户端用量可查。
- [ ] 节点心跳正常，无 421/403 激增。

## 7. 回滚

```bash
systemctl stop aigw-controller
mv data/meta.db data/quarantine/restored-meta.db
cp data/quarantine/$ts/meta.db data/meta.db          # 放回恢复前的现场
chmod 600 data/meta.db
systemctl start aigw-controller
```

- journal 重放幂等，必要时可再次执行；不会重复计费。
- 回滚后同样需要 `aigw restore finish` 或启动时自动 bump generation，避免节点持有旧快照。

## 8. 已知边界

1. **`meta.db` 的 RPO 是 24h**：journal 只覆盖计费/用量，不覆盖管理变更。
   恢复后，备份之后的用户/密钥/价格/分时规则变更会丢失。缓解：
   - 变更前执行 `aigw backup run --db meta`；
   - 或启用 `meta_journal`（v1.1，逻辑操作日志，按 `seq` 重放）；
   - 紧急情况下用审计表人工补齐（`audit` 表记录了操作，但需人工重放）。
2. **journal 缺口**：若 `journal earliest_ts > 备份 ts`，`restore` 会打印缺口区间并拒绝执行，
   必须显式 `--accept-gap`；此时缺口内的计费无法恢复。
3. **journal 关闭**：`backup.journal=false` 时没有重放能力，恢复只能到备份时点。
4. **跨版本恢复**：备份的 `user_version` 高于当前二进制 → 拒绝启动；
   低于当前 → 启动时自动迁移（迁移前会自动再做一份备份）。
5. **恢复期间不要跑备份**：`restore` 会持有恢复锁，备份任务会跳过并告警。

## 9. 演练（每月一次）

```bash
# 在隔离目录恢复，不碰生产
mkdir -p /tmp/aigw-restore-drill && cd /tmp/aigw-restore-drill
aigw restore --auto --from-latest --dir /srv/aigw/data/backups \
             --journal /srv/aigw/data/journal --target-dir ./drill --yes
aigw db check --db ./drill/meta.db
aigw doctor --data-dir ./drill --report
```

记录：备份文件、校验结果、重放条数、耗时、发现的问题。演练失败视为 P1。
