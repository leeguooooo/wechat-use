# 01-echo-bot

最小可跑的 Wechaty 机器人：收到任何文字消息就回 "你说: <原文>"。

## 跑

```bash
npm install
WECHATY_BEARER=<gateway 启动时设的 bearer> node bot.js
```

期望输出：
```
[bot] starting…
[bot] logged in as wxid_xxx
[bot] message: type=Text from=wxid_yyy text="你好"
[bot] replied: 你说: 你好
```

## 代码

完整逻辑在 [`bot.js`](./bot.js)。核心三件事：

1. 用 `wechaty-puppet-service` 直连 `127.0.0.1:18401`（关 TLS，传 bearer）
2. 监听 `wechaty.on('message', ...)`
3. 文本消息直接 `msg.say()`，跳过自发 / 非文本 / 群（避免群刷屏）

## 注意

- **跳过自发**：`msg.self()` 真时直接 return。否则你自己发的消息也会被回，造成无限循环。
- **跳过群**：示例里默认 `msg.room()` 真时不回。生产想在群里玩可以参考 [`02-group-mention-only`](../02-group-mention-only)。
- **跳过非文本**：`msg.type() !== bot.Message.Type.Text` 时不回，不然你会向所有图片 / 红包 / 链接卡片回复 "你说: <xml>"。
