export interface WechatUseBridgeClientOptions {
  baseUrl?: string
  bearerToken?: string
  fetchImpl?: typeof fetch
}

export interface SendTextOptions {
  mention?: unknown
  signal?: AbortSignal
}

export interface StreamMessagesOptions {
  /** Epoch seconds. Defaults to the current time rather than zero. */
  since?: number
  /** Include messages emitted by the current account. Defaults to false. */
  includeSelf?: boolean
  signal?: AbortSignal
}

export class WechatUseBridgeError extends Error {}

export class BridgeHttpError extends WechatUseBridgeError {
  status: number
  body: string
}

export class AmbiguousSendError extends WechatUseBridgeError {
  readonly ambiguous: true
}

export class WechatUseBridgeClient {
  constructor(options?: WechatUseBridgeClientOptions)
  readonly baseUrl: string
  readonly bearerToken: string
  sendText(wxid: string, text: string, options?: SendTextOptions): Promise<unknown>
  streamMessages(options?: StreamMessagesOptions): AsyncGenerator<any, void, unknown>
}
