const DEFAULT_BASE_URL = 'http://127.0.0.1:18400'

export class WechatUseBridgeError extends Error {
  constructor(message, options = {}) {
    super(message, options)
    this.name = 'WechatUseBridgeError'
  }
}

export class BridgeHttpError extends WechatUseBridgeError {
  constructor(status, body = '') {
    super(`wechat-use bridge returned HTTP ${status}${body ? `: ${body}` : ''}`)
    this.name = 'BridgeHttpError'
    this.status = status
    this.body = body
  }
}

/**
 * A send error whose delivery outcome is unknown.
 *
 * Callers MUST NOT automatically retry this error: the bridge may have handed
 * the message to WeChat before the connection failed or the response was lost.
 */
export class AmbiguousSendError extends WechatUseBridgeError {
  constructor(message, options = {}) {
    super(message, options)
    this.name = 'AmbiguousSendError'
    this.ambiguous = true
  }
}

function normalizeBaseUrl(value) {
  const raw = String(value || DEFAULT_BASE_URL).trim().replace(/\/+$/, '')
  const url = new URL(raw)
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new TypeError('baseUrl must use http: or https:')
  }
  return url.toString().replace(/\/$/, '')
}

function parseJson(text) {
  if (!text) return null
  return JSON.parse(text)
}

async function readResponseText(response) {
  try {
    return await response.text()
  } catch {
    return ''
  }
}

async function* decodeSse(body) {
  if (!body) throw new WechatUseBridgeError('bridge SSE response has no body')

  const decoder = new TextDecoder()
  let buffer = ''

  const emit = function* (block) {
    const data = []
    for (const line of block.split('\n')) {
      if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''))
    }
    if (!data.length) return
    const raw = data.join('\n')
    if (!raw || raw === '[DONE]') return
    yield parseJson(raw)
  }

  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true })
    buffer = buffer.replace(/\r\n/g, '\n')
    let boundary
    while ((boundary = buffer.indexOf('\n\n')) !== -1) {
      const block = buffer.slice(0, boundary)
      buffer = buffer.slice(boundary + 2)
      yield* emit(block)
    }
  }

  buffer += decoder.decode()
  buffer = buffer.replace(/\r\n/g, '\n').trim()
  if (buffer) yield* emit(buffer)
}

/**
 * Minimal Node.js client for the public wechat-bridge HTTP/SSE surface.
 *
 * The client intentionally does not implement automatic send retries. Native
 * outbound delivery is not safely replayable when a response is lost.
 */
export class WechatUseBridgeClient {
  constructor({
    baseUrl = DEFAULT_BASE_URL,
    bearerToken,
    fetchImpl = globalThis.fetch,
  } = {}) {
    if (typeof fetchImpl !== 'function') {
      throw new TypeError('fetchImpl must be a function (Node.js 18+ has global fetch)')
    }
    this.baseUrl = normalizeBaseUrl(baseUrl)
    this.bearerToken = bearerToken ? String(bearerToken) : ''
    this.fetchImpl = fetchImpl
  }

  _headers(extra = {}) {
    const headers = { ...extra }
    if (this.bearerToken) headers.Authorization = `Bearer ${this.bearerToken}`
    return headers
  }

  /**
   * Send one text message through POST /send.
   *
   * Network/abort failures and undecodable successful responses are surfaced as
   * AmbiguousSendError so an agent cannot accidentally duplicate a real send.
   */
  async sendText(wxid, text, { mention, signal } = {}) {
    const target = String(wxid || '').trim()
    if (!target) throw new TypeError('wxid is required')
    if (typeof text !== 'string' || !text.length) throw new TypeError('text is required')

    const payload = { wxid: target, text }
    if (mention !== undefined) payload.mention = mention

    let response
    try {
      response = await this.fetchImpl(`${this.baseUrl}/send`, {
        method: 'POST',
        headers: this._headers({
          Accept: 'application/json',
          'Content-Type': 'application/json',
        }),
        body: JSON.stringify(payload),
        signal,
      })
    } catch (cause) {
      throw new AmbiguousSendError(
        'wechat-use send outcome is unknown; do not automatically retry',
        { cause },
      )
    }

    const raw = await readResponseText(response)
    if (!response.ok) throw new BridgeHttpError(response.status, raw.slice(0, 1024))

    try {
      return parseJson(raw)
    } catch (cause) {
      throw new AmbiguousSendError(
        'wechat-use accepted the send request but its response could not be decoded; do not automatically retry',
        { cause },
      )
    }
  }

  /**
   * Stream JSON messages from GET /messages/stream.
   *
   * `since` defaults to the current epoch second instead of zero, preventing an
   * agent from accidentally backfilling the entire message history. Self echoes
   * are filtered by default to prevent reply loops.
   */
  async *streamMessages({
    since = Math.floor(Date.now() / 1000),
    includeSelf = false,
    signal,
  } = {}) {
    if (!Number.isFinite(since) || since < 0) throw new TypeError('since must be a non-negative epoch value')

    const url = new URL(`${this.baseUrl}/messages/stream`)
    url.searchParams.set('since', String(Math.floor(since)))

    const response = await this.fetchImpl(url, {
      headers: this._headers({ Accept: 'text/event-stream' }),
      signal,
    })
    if (!response.ok) {
      const raw = await readResponseText(response)
      throw new BridgeHttpError(response.status, raw.slice(0, 1024))
    }

    for await (const message of decodeSse(response.body)) {
      if (!includeSelf && message?.fromSelf === true) continue
      yield message
    }
  }
}
