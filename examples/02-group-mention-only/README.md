# 02-group-mention-only

群里**只**在被 @ 时才回应；DM 永远回应。最常见的群机器人形态——避免群刷屏被踢。

## 跑

```bash
npm install
WECHATY_GATEWAY_BEARER='same-token-as-gateway' node bot.js
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

群 @ 过滤在本示例客户端执行，私聊也会跳过当前账号自己发的消息。
HTTP/SSE 接入另外支持 `WECHAT_BRIDGE_GROUP_MENTION_ONLY=1`；Wechaty gRPC 示例使用上面的 `mentionSelf()` 判断。
