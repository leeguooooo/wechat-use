# 02-group-mention-only

群里**只**在被 @ 时才回应；DM 永远回应。最常见的群机器人形态——避免群刷屏被踢。

## 跑

```bash
npm install
WECHATY_BEARER=<gateway bearer> node bot.js
```

把 bot 拉进任意微信群，群里发 `@Bot 你好`，bot 回 "收到 @：你好"。
不带 @ 的群消息会被静默忽略，DM 任意消息都会被回。

## 代码要点

完整逻辑在 [`bot.js`](./bot.js)。核心是 `mentionSelf()`：

```js
const isGroup = !!msg.room()
const mentioned = isGroup ? await msg.mentionSelf() : false

if (isGroup && !mentioned) return  // 群里没 @ 我，闭嘴
```

**两层 filter，纵深防御**：

1. **客户端**（这里）：`msg.mentionSelf()` 已经准确识别（wechaty 会调
   `MessagePayload.mentionIds.includes(self_wxid)`，daemon 那边在 v1.10.28+
   填的是权威 mention 列表）
2. **gateway 出口**（可选）：在 `wechat-bridge` 进程的 LaunchAgent plist 里设
   `WECHAT_BRIDGE_GROUP_MENTION_ONLY=1`，让群里非 @ 的消息根本不流到客户端
   → 即使你客户端 logic 漏了 filter，wxid 列表也不会泄漏给上层 bot

生产建议**两层都开**：客户端 filter 是最后一道，bridge 出口 filter 减少传输量 +
减少日志噪声。

## 注意

- `mentionSelf()` 在 DM 上恒返回 false（DM 没有 @ 概念），所以条件 `if (isGroup && !mentioned)` 是必须的
- 群里收到 mention 但 `msg.text()` 不带 `@Bot ` 前缀也是正常的——wechaty 会自动 strip mention 前缀，让你拿到纯文本指令
