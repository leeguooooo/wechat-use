# wechat-use-examples

实战示例：用 [`wechat-use`](https://github.com/leeguooooo/wechat-use) 暴露的
Wechaty Puppet gRPC gateway 写 macOS 微信机器人。

## 前置

1. **macOS Apple Silicon + WeChat 4.x**（4.0.1.52 / 4.1.8 已 calibrate，其他版本可能需要重抓 offset）
2. **wechat-use ≥ v1.13 装好**（示例 04 需要 ≥ v1.11；建议直接用 latest）：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | bash
   wechat-use auth activate <你的激活码>
   wechat-use init        # 抽 SQLCipher key
   wechat-use send "hi" filehelper   # 首次需要在 WeChat 里手动发一条 warmup InputView
   ```
3. **跑 gateway**（默认 127.0.0.1:18401，loopback 模式不需要 bearer）：
   ```bash
   wechat-wechaty-gateway
   ```

> ⚠️ **激活码 gate**：每个 wechaty 数据 RPC 都校验 `wechatuse_` 激活码（不是 transport bearer）。
> 本机 loopback 默认信任,不需要 transport bearer。要把 gateway 暴露公网才需要加 bearer + 反代/Tailscale,见 `docs/remote-gateway.md`。

## 示例

| 示例 | 说明 | 学到 |
|---|---|---|
| [`01-echo-bot`](./examples/01-echo-bot) | 收到任何消息就回 "你说: <X>" | wechaty 最小可跑形态 + login/message 事件 |
| [`02-group-mention-only`](./examples/02-group-mention-only) | 只在群里被 @ 时才回，DM 全应答 | `isGroup` + `mentionSelf()` filter；不踩群刷屏雷 |
| [`03-llm-bot`](./examples/03-llm-bot) | 接 OpenAI/Claude API，AI 答复 | 真实生产 bot 模式，rate-limit + 上下文记忆 |
| [`04-cloudflare-worker-bot`](./examples/04-cloudflare-worker-bot) | **远程** CF Worker 用 JWT 调用你 Mac 上微信发消息（v1.11+） | Cloudflare Tunnel + REST 桥接入；`wrangler secret put` 管 token |
| [`05-saas-orchestrate-template`](./examples/05-saas-orchestrate-template) | **v1.12 SaaS server 模板** —— CF Worker + D1，实现 4 个 orchestrate 协议端点 | 个人 fork 即起最小可用对接（claim/done/fail/inbound + HMAC + 幂等），自家业务在这上加 |

每个目录有独立 `README.md` + `package.json` + 一个可跑 `bot.js`。

## 跑示例

```bash
cd examples/01-echo-bot
npm install
node bot.js                 # loopback 模式不需要 bearer
```

第一条 log 出现 `logged in as <你的wxid>` 就说明 gateway → daemon → WeChat
全链路通了。

> 如果 gateway 启动时设了 `WECHATY_GATEWAY_BEARER=<x>`(对外暴露场景),客户端
> 必须用同一串走 grpc metadata `Authorization: Bearer <x>`。这需要在 bot.js 里
> 用底层 grpc-js client 而非 wechaty-puppet-service 默认管线 —— 见
> `examples/04-cloudflare-worker-bot` 远程接入参考。

## 常见问题

**`Status::Unauthenticated: missing activation`**

→ 先跑 `wechat-use auth activate <激活码>`。激活码经人工审核**免费发放**:跟 [@WechatCliBot](https://t.me/WechatCliBot) 私聊申请,前置关注频道 [WechatCli](https://t.me/+4PuAO3lB9R82ZTVh)。详见 [DISCLAIMER](../DISCLAIMER.md)。

**`Status::Unauthenticated: missing bearer token`**

→ 你 gateway 启动时设了 `WECHATY_GATEWAY_BEARER`，客户端要用同一个。
Node 客户端的 `token` 字段不是这个 bearer，是 wechaty puppet token（任意非空字符串占位即可）。

**Login 5s 超时**

→ 大概率 daemon 没起。先 `wechat-use daemon start`，再起 gateway，再起客户端。

**消息收到了但 `m.text()` 是 `<?xml ...>`**

→ 那条消息是 image / video / appmsg，原始 XML 直接落 text。后续版本会按
`messageKind` 提取 title 替代 raw XML（已在 release v1.10.27+ 大部分 type 处理）。

## 反馈

- 频道：https://t.me/+4PuAO3lB9R82ZTVh
- bot：[@WechatCliBot](https://t.me/WechatCliBot)（贴 `wechat-use doctor` 全输出 + 你想做的事）

## License

MIT。本仓库**只**有示例代码。`wechat-use` 自身（含 LLDB / SQLCipher key 抽取）保持私有协议。
