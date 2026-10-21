/** Options accepted by the standard PuppetService client. */
export function gatewayOptions(env = process.env) {
  const endpoint = env.WECHATY_GATEWAY_ENDPOINT || '127.0.0.1:18401'
  let address
  try { address = new URL(`http://${endpoint}`) } catch { throw new Error('Invalid WECHATY_GATEWAY_ENDPOINT') }
  if (address.username || address.password || address.pathname !== '/' || address.search || address.hash || !address.port) {
    throw new Error('WECHATY_GATEWAY_ENDPOINT must be host:port')
  }
  const loopback = ['127.0.0.1', 'localhost', '[::1]'].includes(address.hostname)
  const useTls = env.WECHATY_GATEWAY_TLS === '1'
  if (!loopback && !useTls) throw new Error('Remote gateways require WECHATY_GATEWAY_TLS=1')
  let token = env.WECHATY_GATEWAY_BEARER?.trim()
  if (!token && loopback && env.WECHATY_GATEWAY_DEV_INSECURE === '1') token = 'local-development-only'
  if (!token) throw new Error('Set WECHATY_GATEWAY_BEARER to the gateway token; this is separate from the activation code')
  return {
    endpoint,
    token,
    tls: {
      disable: !useTls,
      serverName: env.WECHATY_GATEWAY_TLS_SERVER_NAME || address.hostname.replace(/^\[|\]$/g, ''),
      ...(env.WECHATY_GATEWAY_TLS_CA_PEM ? { caCert: env.WECHATY_GATEWAY_TLS_CA_PEM } : {}),
    },
  }
}
