// group-mention-only: DM 全应答，群里只在被 @ 时应答
import { WechatyBuilder } from 'wechaty'
import { WechatUsePuppet } from '@wechat-use/client'
import { gatewayOptions } from '../lib/gateway-options.mjs'



const puppet = new WechatUsePuppet(gatewayOptions())

const wechaty = WechatyBuilder.build({ puppet })

wechaty.on('login', user => console.log(`[bot] logged in as ${user.id}`))
wechaty.on('error', err => console.error('[bot] error:', err?.message ?? err))

async function handleMessage(msg) {
  if (msg.self()) return
  if (msg.type() !== wechaty.Message.Type.Text) return

  const isGroup = !!msg.room()
  const mentioned = isGroup ? await msg.mentionSelf() : false

  // 群里没 @ 我 → 闭嘴
  if (isGroup && !mentioned) return

  const text = msg.text()
  const reply = isGroup
    ? `收到 @：${text}`
    : `DM 收到：${text}`
  await msg.say(reply)
  console.log(`[bot] replied (${isGroup ? 'group@' : 'dm'}): ${reply.slice(0, 60)}`)
}

wechaty.on('message', msg => {
  handleMessage(msg).catch(error => console.error('[bot] message handling failed:', error?.message ?? error))
})

await wechaty.start()
console.log('[bot] started — DM 全回；群里只 @ 才回')

process.on('SIGINT', async () => {
  await wechaty.stop()
  process.exit(0)
})
