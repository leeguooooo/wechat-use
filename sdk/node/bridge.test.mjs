import assert from 'node:assert/strict'
import test from 'node:test'

import {
  AmbiguousSendError,
  WechatUseBridgeClient,
} from './bridge.mjs'

test('sendText sends once and includes bearer auth', async () => {
  const calls = []
  const client = new WechatUseBridgeClient({
    bearerToken: 'test-token',
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init })
      return new Response(JSON.stringify({ status: 'ok' }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })
    },
  })

  const result = await client.sendText('filehelper', 'hello')
  assert.deepEqual(result, { status: 'ok' })
  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, 'http://127.0.0.1:18400/send')
  assert.equal(calls[0].init.headers.Authorization, 'Bearer test-token')
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    wxid: 'filehelper',
    text: 'hello',
  })
})

test('sendText never retries an ambiguous transport failure', async () => {
  let calls = 0
  const client = new WechatUseBridgeClient({
    fetchImpl: async () => {
      calls += 1
      throw new Error('connection reset after write')
    },
  })

  await assert.rejects(
    client.sendText('filehelper', 'hello'),
    error => error instanceof AmbiguousSendError && error.ambiguous === true,
  )
  assert.equal(calls, 1)
})

test('streamMessages defaults since to now and filters self echoes', async () => {
  const before = Math.floor(Date.now() / 1000)
  let requestedUrl = ''
  const body = [
    'data: {"fromSelf":true,"text":"self"}',
    '',
    'data: {"fromSelf":false,"text":"incoming"}',
    '',
    '',
  ].join('\n')

  const client = new WechatUseBridgeClient({
    fetchImpl: async url => {
      requestedUrl = String(url)
      return new Response(body, {
        status: 200,
        headers: { 'content-type': 'text/event-stream' },
      })
    },
  })

  const messages = []
  for await (const message of client.streamMessages()) messages.push(message)

  const since = Number(new URL(requestedUrl).searchParams.get('since'))
  const after = Math.floor(Date.now() / 1000)
  assert.ok(since >= before && since <= after)
  assert.deepEqual(messages, [{ fromSelf: false, text: 'incoming' }])
})

test('streamMessages can explicitly include self echoes and historical events', async () => {
  let requestedUrl = ''
  const client = new WechatUseBridgeClient({
    fetchImpl: async url => {
      requestedUrl = String(url)
      return new Response('data: {"fromSelf":true,"text":"self"}\n\n', {
        status: 200,
        headers: { 'content-type': 'text/event-stream' },
      })
    },
  })

  const messages = []
  for await (const message of client.streamMessages({ since: 0, includeSelf: true })) {
    messages.push(message)
  }

  assert.equal(new URL(requestedUrl).searchParams.get('since'), '0')
  assert.deepEqual(messages, [{ fromSelf: true, text: 'self' }])
})
