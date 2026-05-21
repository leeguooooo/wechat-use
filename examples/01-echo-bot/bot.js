// echo-bot: 收到 DM 文本消息回复 "你说: <原文>"
//
// 跑(loopback 模式,gateway 在本机默认信任 127.0.0.1):
//   node bot.js
//
// 期望:start() 后看到 "logged in as wxid_xxx",再给自己 (filehelper) 私发任意
// 文字,bot 应即时回 "你说: <原文>"。
//
// 如果你启动 gateway 时设了 WECHATY_GATEWAY_BEARER(对外暴露场景),需要用底层
// grpc-js 客户端走 metadata 传 Authorization: Bearer 头 —— wechaty-puppet-service
// 默认管线没暴露这个口子。loopback 场景跳过 bearer 即可。
import { WechatyBuilder } from 'wechaty'
import { PuppetService } from 'wechaty-puppet-service'

const ENDPOINT = process.env.WECHATY_GATEWAY_ENDPOINT || '127.0.0.1:18401'

// wechaty-puppet-service v1 强制要 TLS 除非显式 disable。
process.env.WECHATY_PUPPET_SERVICE_NO_TLS_INSECURE_CLIENT = '1'
process.env.WECHATY_PUPPET_SERVICE_NO_TLS_INSECURE_SERVER = '1'

const puppet = new PuppetService({
  // wechaty 的 token 字段是 puppet-service 自己的标识符，不是我们 gateway 的
  // bearer。任意非空字符串即可；bearer 由 grpc metadata 传，见下面 authority。
  token: 'puppet_workpro_local',
  endpoint: ENDPOINT,
  tls: { disable: true, serverName: 'localhost' },
  // wechaty-puppet-service v1.19 没有直接传 bearer 的字段；用 grpc 默认凭证管线
  // 走自定义 metadata。最简单做法是开 gateway 时不带 --bearer（信任本机
  // loopback），这样 gateway 不要求 Authorization header。生产建议 bearer +
  // 反代或上 Tailscale，把 wechat-wechaty-gateway 限制在 trusted 子网。
})

const wechaty = WechatyBuilder.build({ puppet })

wechaty.on('login', user => console.log(`[bot] logged in as ${user.id} (${user.name?.() ?? '?'})`))
wechaty.on('error', err => console.error('[bot] error:', err?.message ?? err))

wechaty.on('message', async (msg) => {
  const type = msg.type()
  const from = msg.talker()?.id ?? '?'
  const text = msg.text()?.slice(0, 80) ?? ''
  console.log(`[bot] message: type=${type} from=${from} text=${JSON.stringify(text)}`)

  // skip self-sent (会无限循环)
  if (msg.self()) return
  // skip 非文本
  if (type !== wechaty.Message.Type.Text) return
  // skip 群（演示在 02-group-mention-only 处理）
  if (msg.room()) return

  const reply = `你说: ${text}`
  await msg.say(reply)
  console.log(`[bot] replied: ${reply}`)
})

await wechaty.start()
console.log('[bot] started, listening for messages…')

// graceful shutdown
process.on('SIGINT', async () => {
  console.log('\n[bot] shutting down…')
  await wechaty.stop()
  process.exit(0)
})
