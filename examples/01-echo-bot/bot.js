// DM echo bot. Set WECHATY_GATEWAY_BEARER to the gateway credential.
import { WechatyBuilder } from 'wechaty'
import { WechatUsePuppet } from '@wechat-use/client'
import { gatewayOptions } from '../lib/gateway-options.mjs'



const puppet = new WechatUsePuppet(gatewayOptions())

const wechaty = WechatyBuilder.build({ puppet })

wechaty.on('login', user => console.log(`[bot] logged in as ${user.id} (${user.name?.() ?? '?'})`))
wechaty.on('error', err => console.error('[bot] error:', err?.message ?? err))

async function handleMessage(msg) {
  const type = msg.type()
  const text = msg.text() ?? ''
  console.log(`[bot] message: type=${type} chars=${text.length}`)

  // skip self-sent (会无限循环)
  if (msg.self()) return
  // skip 非文本
  if (type !== wechaty.Message.Type.Text) return
  // skip 群（演示在 02-group-mention-only 处理）
  if (msg.room()) return

  const reply = `你说: ${text}`
  await msg.say(reply)
  console.log('[bot] reply completed')
}

wechaty.on('message', msg => {
  handleMessage(msg).catch(error => console.error('[bot] message handling failed:', error?.message ?? error))
})

await wechaty.start()
console.log('[bot] started, listening for messages…')

// graceful shutdown
process.on('SIGINT', async () => {
  console.log('\n[bot] shutting down…')
  await wechaty.stop()
  process.exit(0)
})
