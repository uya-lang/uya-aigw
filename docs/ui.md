# 后台 UI 与安全说明（C1–C6）

## 页面与接口

| 路径 | 说明 |
|---|---|
| `GET /` | 单页控制台（登录/资料/密钥/接入点/概览/用量/请求列表/估算/Playground/账单预算/通知） |
| `GET /ui/app.js` | 控制台脚本（同源加载，无内联脚本） |
| `GET /ui/admin.js` | 管理后台脚本 |
| `GET /admin` | 管理后台页（用户/供应商/节点/备份/定价/改价（含分时价）/价目表/模型绑定） |
| `GET /admin/users`、`GET /admin/providers` | 管理后台列表（需 admin key） |
| `GET/POST /admin/price-entries` | 价目条目列表 / 改价（可带 `schedule` 分时规则，坏规则 400；`per_request` 可选） |
| `GET /admin/models`、`POST /admin/bind` | 模型绑定列表 / 绑定 |
| `GET /v1/requests?limit=&offset=`、`?id=` | 请求列表（分页）/ 详情 |
| `GET /v1/usage`、`/v1/usage.csv`、`POST /v1/estimate` | 用量汇总 / CSV / 估算器 |
| `GET/POST /v1/budget` | 月度预算与告警；超额时写站内通知 |
| `GET /v1/notifications` | 站内通知 JSONL（按用户隔离；预算超额 `budget.over`） |
| `GET /admin/audit` | 审计日志 JSONL（ts/actor/action/target） |
| `GET /node/status`、`/edge/route`、`/edge/fail`、`/edge/proxy` | 集群节点视角与 edge 代理 |

## 认证与越权

- 用户侧：`Authorization: Bearer <api key>`；请求列表/详情只返回**自己**的数据（`where user_id = ?`）。
- 跨用户撤销 Key 返回 404（不泄露存在性）。
- 管理侧：`Authorization: Bearer <admin key>`（`--admin-key`）；未带/错误一律 401。
- 节点侧：`/controller/ingest?node=<id>` 仅接受已在 meta 注册的节点，其余 401。

## CSRF / XSS / CSP

- 全部 API 走 `Authorization` 头，**不使用 Cookie**，因此没有浏览器自动带凭证的 CSRF 面；
  不做双提交 token。
- 前端写入用户数据只用 `textContent`/`textContent =` 拼接，不使用 `innerHTML` 注入；
  `innerHTML=''` 仅用于清空表格。
- HTML/JS 响应带安全头：
  - `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`
  - `X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`、`X-Frame-Options: DENY`

## 端到端验证

```bash
make ui-e2e     # 等价于 ./tests/chat_e2e.sh
```

覆盖：OTP→登录→建 Key→调用（非流/流）→responses（非流/流）→管理 REST→MCP→controller
（register/heartbeat/config/epoch/assign/drain/ingest）→uplink 注册→UI 断言→CSV/估算/预算→
请求列表/详情→改价/绑定→管理后台页与 401→安全头→越权。
