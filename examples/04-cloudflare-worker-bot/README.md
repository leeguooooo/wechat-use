# 04-cloudflare-worker-bot

用 Cloudflare Worker 远程调用你自己 Mac 上的微信，发送消息。  
底层走 **v1.11 远程 gateway**：Cloudflare Tunnel + JWT + REST 桥。

---

## 前置条件

1. **wechat-skill ≥ v1.11** 已装好，Mac 上微信正在跑：
   ```bash
   wechat --version     # 确认 ≥ v1.11
   wechat doctor        # 全绿才继续
   ```

2. **一次性跑 tunnel setup**（你自己的 CF free 账号，OAuth 授权即可，需要一个 CF zone 下的 hostname）：
   ```bash
   wechat tunnel setup --hostname wechat.yourdomain.com
   ```
   命令会引导你完成 Cloudflare OAuth → 在你 zone 下创建 named tunnel + DNS CNAME → 启动 tunnel 进程。
   bare `<uuid>.cfargotunnel.com` 公网不路由(v1.11.0 实测踩过的坑,见 docs/remote-gateway.md),所以 `--hostname` 必填，要指向你拥有的 zone。
   成功后输出类似:
   ```
   ✓ tunnel created: wechat.yourdomain.com (CNAME → <uuid>.cfargotunnel.com)
   ✓ tunnel process running (pid 12345)
   ```
   **`TUNNEL_URL=https://wechat.yourdomain.com`**。

3. **查激活 token 和 machine ID**：
   ```bash
   wechat auth status
   ```
   输出里拿：
   - `user_token`（形如 `wxp_tok_...`）→ 即 `WECHAT_USER_TOKEN`
   - `machine_id`（形如 `mac-...`）→ 即 `WECHAT_MACHINE_ID`

4. **Node.js ≥ 18** + **wrangler ≥ 3**（全局或 npx）：
   ```bash
   npm install -g wrangler
   ```

---

## 快速部署

### 1. 安装依赖

```bash
cd examples/04-cloudflare-worker-bot
npm install
```

### 2. 写本地开发变量（不要 commit！）

```bash
cp .dev.vars.example .dev.vars
# 编辑 .dev.vars，填入真实值
```

### 3. 把 secret 上传到 Cloudflare

```bash
wrangler secret put WECHAT_USER_TOKEN    # 粘贴 wxp_tok_...
wrangler secret put WECHAT_MACHINE_ID   # 粘贴 mac-...
wrangler secret put TARGET_WXID          # 粘贴目标 wxid（如 filehelper）
```

`PROFILE_API_URL` 默认 `https://wxp.leeguoo.com`，无需覆盖。

### 4. 部署

```bash
wrangler deploy
```

输出会给你 `https://wechat-skill-bot-example.<你的 CF 子域>.workers.dev`。

### 5. 触发测试

```bash
curl https://wechat-skill-bot-example.<你的 CF 子域>.workers.dev/
```

看到 `{"ok":true,...}` 且微信收到 "hello from worker" 就成了。

---

## 工作原理

```
Cloudflare Worker
  ├─ 1. POST /gateway-token → profile-api (wxp.leeguoo.com)
  │       body: { user_token, machine_id }
  │       → 返回 { jwt, exp, tunnel_url }   ← 1h TTL ES256 JWT
  │
  ├─ 2. GET https://<tunnel_url>/v1/sessions  ← 验通
  │
  └─ 3. POST https://<tunnel_url>/v1/send     ← 发消息
          headers: Authorization: Bearer <jwt>
          body: { to: TARGET_WXID, text: "hello from worker" }
```

Tunnel 是你 CF 账号下的 named tunnel，入站 HTTPS 由 CF 终结，  
出站走 cloudflared 进程打到你 Mac 上 `127.0.0.1:18402`（REST 桥）。  
JWT 由 profile-api 签发，REST 桥校验，过期后 Worker 下次调用会自动重新换。

---

## 环境变量说明

| 变量 | 必须 | 说明 |
|---|---|---|
| `WECHAT_USER_TOKEN` | ✅ | `wechat auth status` 里的 `user_token` |
| `WECHAT_MACHINE_ID` | ✅ | `wechat auth status` 里的 `machine_id` |
| `TARGET_WXID` | ✅ | 发消息的目标 wxid（测试用 `filehelper`） |
| `PROFILE_API_URL` | 可选 | 默认 `https://wxp.leeguoo.com` |

---

## v1.11 限制

- REST 桥（`:18402`）已通过 Cloudflare Tunnel 对外暴露。  
- **gRPC（`:18401`）不暴露** —— 远程跑 wechaty TS SDK bot 暂时只能跟 Mac 同 LAN（直连 `<mac-ip>:18401`），公网接入留 v1.12。  
  详见 [wechat-skill docs/remote-gateway.md](https://github.com/leeguooooo/wechat-skill/blob/main/docs/remote-gateway.md)。

---

## 文件说明

```
04-cloudflare-worker-bot/
├── src/index.ts          # Worker 主逻辑（~80 行，有注释）
├── wrangler.toml         # CF Worker 配置
├── package.json          # 依赖声明
├── tsconfig.json         # TS 配置（CF Workers target）
├── .dev.vars.example     # 本地 wrangler dev 环境变量样例
└── README.md             # 本文件
```
