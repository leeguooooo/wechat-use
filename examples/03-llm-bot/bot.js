// llm-bot: 接 OpenAI 兼容 LLM 端点，DM 全应答 + 群里 @ 应答，每会话 5 轮上下文。
import { WechatyBuilder } from 'wechaty'
import { WechatUsePuppet } from '@wechat-use/client'
import { gatewayOptions } from '../lib/gateway-options.mjs'
import OpenAI from 'openai'

const OPENAI_API_KEY = process.env.OPENAI_API_KEY
const OPENAI_BASE_URL = process.env.OPENAI_BASE_URL  // optional
const OPENAI_MODEL = process.env.OPENAI_MODEL || 'gpt-4o-mini'
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT
  || '你是微信里一个简洁友好的助手。回答尽量短，最多 3 段。中文优先。'

if (!OPENAI_API_KEY) {
  console.error('[bot] missing OPENAI_API_KEY')
  process.exit(1)
}


const llm = new OpenAI({
  apiKey: OPENAI_API_KEY,
  ...(OPENAI_BASE_URL ? { baseURL: OPENAI_BASE_URL } : {}),
})

const puppet = new WechatUsePuppet(gatewayOptions())
const wechaty = WechatyBuilder.build({ puppet })

// per-conversation 5-round LRU + rate-limit
const HISTORY_LIMIT = 10  // 5 轮 = 5 user + 5 assistant
const RATE_WINDOW_MS = 3000
const sessions = new Map()  // talkerId → { history: [{role,content}], lastAt: ms }

function sessionFor(id) {
  let s = sessions.get(id)
  if (!s) { s = { history: [], lastAt: 0 }; sessions.set(id, s) }
  return s
}

async function askLLM(history) {
  const resp = await llm.chat.completions.create({
    model: OPENAI_MODEL,
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      ...history,
    ],
    temperature: 0.7,
  })
  return resp.choices[0]?.message?.content?.trim() ?? '(LLM 没返回内容)'
}

wechaty.on('login', user => console.log(`[bot] logged in as ${user.id}; model=${OPENAI_MODEL}`))
wechaty.on('error', err => console.error('[bot] error:', err?.message ?? err))

async function handleMessage(msg) {
  if (msg.self()) return
  if (msg.type() !== wechaty.Message.Type.Text) return

  const isGroup = !!msg.room()
  const mentioned = isGroup ? await msg.mentionSelf() : false
  if (isGroup && !mentioned) return

  const text = msg.text().trim()
  if (!text) return

  const talkerId = msg.talker()?.id ?? 'unknown'
  const conversationId = isGroup ? `${msg.room().id}:${talkerId}` : talkerId
  const sessionId = `${wechaty.currentUser.id}:${conversationId}`
  const session = sessionFor(sessionId)

  // /reset clears history
  if (text === '/reset') {
    session.history = []
    await msg.say('上下文已清空。')
    return
  }

  // rate-limit
  const now = Date.now()
  if (now - session.lastAt < RATE_WINDOW_MS) {
    await msg.say('处理中…请稍等')
    return
  }
  session.lastAt = now

  session.history.push({ role: 'user', content: text })
  // trim
  while (session.history.length > HISTORY_LIMIT) session.history.shift()

  let reply
  try {
    reply = await askLLM(session.history)
  } catch (error) {
    console.error('[bot] LLM request failed:', error?.message ?? error)
    await msg.say('LLM 调用失败，稍后再试。')
    return
  }
  try {
    // WeChat 4096 字符上限——长 reply 拆段
    const CHUNK = 1500
    for (let i = 0; i < reply.length; i += CHUNK) {
      await msg.say(reply.slice(i, i + CHUNK))
    }
    session.history.push({ role: 'assistant', content: reply })
    while (session.history.length > HISTORY_LIMIT) session.history.shift()
    console.log(`[bot] reply completed: in=${text.length}ch out=${reply.length}ch`)
  } catch (error) {
    // A transport error can follow an accepted send. Stop the chunk loop;
    // never send a second notification or automatically retry this reply.
    console.error('[bot] delivery needs verification:', error?.message ?? error)
  }
}

wechaty.on('message', msg => {
  handleMessage(msg).catch(error => console.error('[bot] message handling failed:', error?.message ?? error))
})

await wechaty.start()
console.log(`[bot] started; model=${OPENAI_MODEL}; sessions=per-talker, ${HISTORY_LIMIT/2}-round window`)

process.on('SIGINT', async () => {
  await wechaty.stop()
  process.exit(0)
})
