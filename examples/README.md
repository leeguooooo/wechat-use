# wechat-use-examples

实战示例：用 [`wechat-use`](https://github.com/leeguooooo/wechat-use) 暴露的
Wechaty Puppet gRPC gateway 写 macOS 微信机器人。

## 前置

1. **macOS Apple Silicon + 安装器管理的独立微信 4.1.9**
2. **安装与示例配套的 wechat-use 网关**：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | bash
   wechat-use auth activate <你的激活码>
   wechat-use init
   ```
3. **设置网关凭据并启动 gateway**（默认 127.0.0.1:18401）：
   ```bash
   export WECHATY_GATEWAY_BEARER="$(openssl rand -hex 32)"
   wechat-wechaty-gateway
   ```

> ⚠️ **激活码 gate**：每个 wechaty 数据 RPC 都校验 `wechatuse_` 激活码（不是 transport bearer）。
> 客户端与网关必须使用相同的 `WECHATY_GATEWAY_BEARER`。它与激活码用途不同。远程连接需要 TLS，见 [远程网关说明](../docs/remote-gateway.md)。

## 示例

| 示例 | 说明 | 学到 |
|---|---|---|
| [`01-echo-bot`](./01-echo-bot) | 收到任何消息就回 "你说: <X>" | wechaty 最小可跑形态 + login/message 事件 |
| [`02-group-mention-only`](./02-group-mention-only) | 只在群里被 @ 时才回，DM 全应答 | `isGroup` + `mentionSelf()` filter；不踩群刷屏雷 |
| [`03-llm-bot`](./03-llm-bot) | 接 OpenAI/Claude API，AI 答复 | 真实生产 bot 模式，rate-limit + 上下文记忆 |
| [`04-cloudflare-worker-bot`](./04-cloudflare-worker-bot) | **远程** CF Worker 用 JWT 调用你 Mac 上微信发消息（v1.11+） | Cloudflare Tunnel + REST 桥接入；`wrangler secret put` 管 token |
| [`05-saas-orchestrate-template`](./05-saas-orchestrate-template) | **v1.12 SaaS server 模板** —— CF Worker + D1，实现 4 个 orchestrate 协议端点 | 个人 fork 即起最小可用对接（claim/done/fail/inbound + HMAC + 幂等），自家业务在这上加 |

请保留完整仓库目录：Node 示例会安装仓库中的 `sdk/node` 客户端，并共用 `examples/lib` 配置。

## 跑示例

```bash
cd examples/01-echo-bot
npm install
node bot.js                 # 本终端须设置与网关相同的 WECHATY_GATEWAY_BEARER
```

`login` 事件表示网关提供了账号信息；实际收发仍需分别验证。先使用自己的测试会话验收。

示例使用保留标准 PuppetService API 的 `WechatUsePuppet`，修正上游 1.19.9 的定位读取。`token` 直接使用网关 bearer，不需要自行修改 grpc-js。
本机无 TLS 模式使用 SDK 的 authority 凭据通道，网关仍校验 token。
仅做本机开发且明确不要鉴权时，可在网关和示例中同时设置 `WECHATY_GATEWAY_DEV_INSECURE=1`。

远程客户端还需设置 `WECHATY_GATEWAY_TLS=1`；自签 CA 可通过 `WECHATY_GATEWAY_TLS_CA_PEM` 提供。
示例拒绝在非本机地址上明文传输 token。

## 常见问题

**`Status::Unauthenticated: missing activation`**

→ 先跑 `wechat-use auth activate <激活码>`。激活码经人工审核**免费发放**:跟 [@WechatCliBot](https://t.me/WechatCliBot) 私聊申请,前置关注频道 [WechatCli](https://t.me/wechatuse)。详见 [DISCLAIMER](../DISCLAIMER.md)。

**`Status::Unauthenticated: missing bearer token`**

→ 你 gateway 启动时设了 `WECHATY_GATEWAY_BEARER`，客户端要用同一个。
检查客户端的 `token` 是否与网关 bearer 完全一致，不要使用任意占位 token。

**Login 5s 超时**

→ 大概率 daemon 没起。先 `wechat-use daemon start`，再起 gateway，再起客户端。

**消息收到了但 `m.text()` 是 `<?xml ...>`**

→ 那条消息是 image / video / appmsg，原始 XML 直接落 text。后续版本会按
`messageKind` 提取 title 替代 raw XML（已在 release v1.10.27+ 大部分 type 处理）。

## 反馈

- 频道：https://t.me/wechatuse
- 交流群：https://t.me/Wechatuse_talk
- bot：[@WechatCliBot](https://t.me/WechatCliBot)（贴 `wechat-use doctor` 全输出 + 你想做的事）

## License

MIT。本仓库**只**有示例代码。`wechat-use` 自身（含 LLDB / SQLCipher key 抽取）保持私有协议。
