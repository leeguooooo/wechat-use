# 远程 Gateway（v1.11）

> **适用版本：wechat-use ≥ v1.11**

v1.11 起可以把本机微信的 REST 桥通过 Cloudflare Tunnel 安全暴露给远程服务（CF Worker、SaaS 后端、服务器脚本等）。

---

## 架构图

```
远程调用方（CF Worker / VPS / SaaS）
        │
        │  1. POST /gateway-token
        ▼
wxp.leeguoo.com (profile-api SaaS)
        │  校验激活码 → 签发 1h ES256 JWT + 返回 tunnel_url
        │
        │  2. fetch https://<tunnel_url>/v1/*
        │     Authorization: Bearer <jwt>
        ▼
Cloudflare 边缘（HTTPS 终结）
        │
        │  cloudflared named tunnel（用户自己的 CF free 账号）
        ▼
你的 Mac  127.0.0.1:18402  (wechat-bridge REST 桥)
        │
        ▼
wechatd daemon  →  WeChat.app（本地进程）
```

**三层安全**：HTTPS（CF 边缘终结）+ JWT（profile-api 签发 + REST 桥校验）+ 激活码校验（profile-api 侧）。

---

## 前提：你需要一个 Cloudflare zone

`<uuid>.cfargotunnel.com` 这类裸 URL **公网 DNS 不解析**。必须用你 CF 账号下拥有的域名做 CNAME。

**步骤（只需一次）：**

1. 在 [Cloudflare Dashboard](https://dash.cloudflare.com) 注册一个免费账号
2. 把你的域名（例如 `yourdomain.com`）的 Nameserver 改为 Cloudflare 提供的 NS（Free 套餐即可）
3. 选一个子域名，例如 `wechat.yourdomain.com`，这就是你的 `--hostname`

> 如果你还没有域名，可以从 Cloudflare Registrar（或任意注册商）购买，注册后在 Dashboard 添加即可。

## 一次性 Setup

```bash
# 必须提供 --hostname，必须是你 CF 账号下已加入的 zone 的子域名
wechat-use tunnel setup --hostname wechat.yourdomain.com
```

命令会：

1. 打开浏览器完成 Cloudflare OAuth（只访问你自己账号的 tunnel 资源）
2. 在你的 CF 账号下创建一个 named tunnel
3. 生成 `~/.cloudflared/<uuid>.json` 凭证文件
4. 自动跑 `cloudflared tunnel route dns <uuid> wechat.yourdomain.com`，把 CNAME 加到你的 CF zone
5. 启动 `cloudflared` 进程，等待 tunnel 连通
6. 把 tunnel 注册到 profile-api（profile-api 会 probe `/health` 验证是真实的 gateway）
7. 把 ai.wechat.bridge 切换到 JWT 鉴权模式，重启，验证 401

成功输出：

```
✓ DNS 路由已创建：wechat.yourdomain.com → <uuid>
✓ tunnel 已连通（https://wechat.yourdomain.com/health → 200）
✓ tunnel 已注册到 profile-api
✓ JWT 鉴权正常（/v1/sessions → 401）
✅ Done. 你的 tunnel URL: wechat.yourdomain.com
```

**只需跑一次**。之后每次 Mac 重启 cloudflared 会自动随 LaunchAgent 启动。

---

## REST 桥端点（`:18402`）

鉴权：除 `/health` 外所有端点要求 `Authorization: Bearer <jwt>`。

| Method | Path | 说明 |
|--------|------|------|
| GET | `/health` | 无需鉴权；返回 `{"ok":true,"mode":"jwt","service":"wechat-wechaty-gateway","version":"..."}` |
| GET | `/v1/sessions?limit=&offset=` | 最近会话列表 |
| GET | `/v1/contacts?limit=&offset=` | 联系人列表 |
| GET | `/v1/history?conversation_id=&limit=&offset=` | 某会话聊天记录 |
| GET | `/v1/new-messages?since_id=&limit=` | 增量新消息 |
| POST | `/v1/send` | 发消息，body: `{"to":"wxid_xxx","text":"..."}` |

所有带 limit 的端点默认 limit=20，最大 200。

---

## JWT 流程

### 获取 JWT

```http
POST https://wxp.leeguoo.com/gateway-token
Content-Type: application/json

{
  "user_token": "wxp_tok_...",
  "machine_id": "mac-..."
}
```

响应：

```json
{
  "jwt": "eyJ...",
  "exp": 1730000000,
  "tunnel_url": "<uuid>.cfargotunnel.com"
}
```

- `jwt`：ES256 签名的 JWT，有效期 **1 小时**
- `exp`：Unix 时间戳（秒），JWT 过期时间
- `tunnel_url`：不含协议前缀；调用 REST 桥时拼 `https://<tunnel_url>/v1/...`

### 过期处理

JWT 过期后 REST 桥返回 `401 Unauthorized`。建议调用方：

1. 在调用前检查本地缓存的 `exp`，提前 5 分钟刷新
2. 或遇到 `401` 时重新调 `/gateway-token` 换新 JWT，然后重试原请求

Cloudflare Worker 可以用 `cache.put` / `cache.match` 缓存 JWT（key 用 `machine_id`，TTL 设 50 分钟留 10 分钟余量）。

### 如何获取 user_token 和 machine_id

```bash
wechat-use auth status
```

输出里找 `user_token`（形如 `wxp_tok_...`）和 `machine_id`（形如 `mac-...`）。

---

## 安全模型

| 层 | 机制 | 说明 |
|---|---|---|
| 传输 | HTTPS | Cloudflare 边缘终结 TLS；`cloudflared` 到 Mac 走本地回路 |
| 调用方身份 | ES256 JWT | profile-api 签发；REST 桥校验签名 + 过期；私钥不离开 profile-api |
| 激活资格 | 激活码 | profile-api `/gateway-token` 先校验 `user_token` 是否有效；过期则拒绝签 JWT |
| Tunnel 归属 | CF 账号 + named tunnel | Tunnel 在用户自己的 Cloudflare 账号下；profile-api 只知道 `tunnel_url`，无权控制 tunnel 本身 |

**聊天内容、联系人、解密密钥永远不出 Mac**。REST 桥只暴露通过 daemon RPC 的结构化数据，raw SQLCipher 数据库从不经过 Tunnel。

---

## Cloudflare Worker 接入示例

完整可跑示例在 [wechat-use-examples/examples/04-cloudflare-worker-bot](https://github.com/leeguooooo/wechat-use-examples/tree/main/examples/04-cloudflare-worker-bot)。

核心逻辑（TypeScript）：

```ts
// 1. 换 JWT
const r = await fetch('https://wxp.leeguoo.com/gateway-token', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ user_token: env.WECHAT_USER_TOKEN, machine_id: env.WECHAT_MACHINE_ID }),
});
const { jwt, tunnel_url } = await r.json();

// 2. 调 REST 桥
const sendResp = await fetch(`https://${tunnel_url}/v1/send`, {
  method: 'POST',
  headers: { authorization: `Bearer ${jwt}`, 'content-type': 'application/json' },
  body: JSON.stringify({ to: 'filehelper', text: 'hello from worker' }),
});
```

完整示例含 JWT 缓存、错误处理、`wrangler.toml` 配置。

---

## v1.11 限制

| 项目 | v1.11 状态 | 计划 |
|---|---|---|
| REST 桥（`:18402`）通过 Tunnel 对外暴露 | **已支持** | — |
| gRPC puppet gateway（`:18401`）通过 Tunnel 对外暴露 | **未支持** | v1.12（grpc-web） |
| wechaty TS SDK 远程接入 | 仅同 LAN（直连 `<mac-ip>:18401`） | v1.12 |

如果你需要 wechaty SDK 远程接入，v1.11 阶段需要和 Mac 同局域网或通过 Tailscale 打洞。

---

## 常见问题

**tunnel setup 卡住 / OAuth 失败**

→ 检查 `cloudflared` 是否在 PATH 里。`wechat-use tunnel setup` 会尝试自动下载，若网络受限需手动安装：https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/

**REST 桥返回 401**

→ JWT 过期。重新调 `/gateway-token` 换新 JWT。

**REST 桥返回 402**

→ 激活码过期或不存在。跑 `wechat-use auth status` 查剩余天数，到期后重新申请。

**Tunnel URL 变了**

→ 每次 `wechat-use tunnel setup --hostname <same-hostname>` 用同一个 machine-id 会复用同一个 tunnel（named tunnel 不变）；重跑不会产生新 UUID。

**`tunnel register` 报 `tunnel_probe_failed`**

→ profile-api 在注册时会 probe `https://<hostname>/health` 验证是真实的 wechat-wechaty-gateway。确认：(1) `cloudflared` 进程正在运行；(2) DNS 已传播（`dig wechat.yourdomain.com` 能解析到 Cloudflare IP）；(3) `curl https://wechat.yourdomain.com/health` 能返回 `{"service":"wechat-wechaty-gateway",...}`。

**`wechat-use doctor` 怎么看 tunnel 状态**

→ v1.11 起 `wechat-use doctor` 输出里有 `tunnel` 一行，显示 tunnel 进程 pid + URL + 健康状态。
