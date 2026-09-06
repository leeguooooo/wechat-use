import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import vm from 'node:vm'

async function fixture(name, llmReply = 'fixture reply') {
  const listeners = new Map()
  const errors = []
  const prompts = []
  const bot = {
    currentUser: { id: 'fixture-account' },
    Message: { Type: { Text: 6 } },
    on: (name, fn) => listeners.set(name, fn),
    start: async () => {}, stop: async () => {},
  }
  const context = vm.createContext({
    console: { log() {}, error: (...args) => errors.push(args) },
    process: { env: { OPENAI_API_KEY: 'fixture-key' }, on() {}, exit() { throw new Error('unexpected exit') } },
  })
  const modules = {
    wechaty: { WechatyBuilder: { build: () => bot } },
    '@wechat-use/client': { WechatUsePuppet: class {} },
    '../lib/gateway-options.mjs': { gatewayOptions: () => ({}) },
    openai: { default: class {
      chat = { completions: { create: async request => {
        prompts.push(JSON.parse(JSON.stringify(request)))
        return { choices: [{ message: { content: llmReply } }] }
      } } }
    } },
  }
  const source = await readFile(new URL(`../${name}/bot.js`, import.meta.url), 'utf8')
  const module = new vm.SourceTextModule(source, { context })
  await module.link(name => {
    const values = modules[name]
    assert.ok(values, `unexpected import ${name}`)
    return new vm.SyntheticModule(Object.keys(values), function () {
      for (const [key, value] of Object.entries(values)) this.setExport(key, value)
    }, { context })
  })
  await module.evaluate()
  return { bot, errors, prompts, receive: listeners.get('message') }
}

const drain = () => new Promise(resolve => setImmediate(resolve))
function message(text, options = {}) {
  const sent = []
  return {
    sent,
    self: () => options.self ?? false,
    type: () => 6,
    room: () => options.group ? { id: 'fixture-room' } : null,
    mentionSelf: async () => { if (options.mentionError) throw new Error('fixture mention error'); return options.mentioned ?? true },
    talker: () => ({ id: 'fixture-peer' }),
    text: () => text,
    say: async value => { sent.push(value); if (options.sendError) throw new Error('status_unknown') },
  }
}

test('echo preserves the complete message and ignores own outgoing messages', async () => {
  const f = await fixture('01-echo-bot')
  const long = message('x'.repeat(250))
  f.receive(long); await drain()
  assert.deepEqual(long.sent, [`你说: ${'x'.repeat(250)}`])
  const own = message('own message', { self: true })
  f.receive(own); await drain(); assert.deepEqual(own.sent, [])
})
test('uncertain LLM delivery is not followed by an error-message send', async () => {
  const f = await fixture('03-llm-bot', 'x'.repeat(2000))
  const input = message('question', { sendError: true })
  f.receive(input); await drain()
  assert.equal(f.prompts.length, 1)
  assert.equal(input.sent.length, 1, 'stop chunk delivery after the first uncertain send')
  assert.equal(f.errors.length, 1)
})
test('mention lookup errors are contained by the bot event handler', async () => {
  const f = await fixture('02-group-mention-only')
  const input = message('question', { group: true, mentionError: true })
  f.receive(input); await drain()
  assert.deepEqual(input.sent, [])
  assert.equal(f.errors.length, 1)
})
test('LLM context is isolated when the current account changes', async () => {
  const f = await fixture('03-llm-bot')
  f.receive(message('first account question')); await drain()
  f.bot.currentUser = { id: 'another-fixture-account' }
  f.receive(message('second account question')); await drain()
  assert.equal(f.prompts.length, 2)
  assert.equal(f.prompts[1].messages.some(m => m.content === 'first account question'), false)
})
