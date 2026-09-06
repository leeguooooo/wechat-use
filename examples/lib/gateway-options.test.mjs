import { test } from 'node:test'
import assert from 'node:assert/strict'
import { gatewayOptions } from './gateway-options.mjs'

test('standard client receives the real gateway credential on loopback', () => {
  const options = gatewayOptions({ WECHATY_GATEWAY_BEARER: 'fixture-token' })
  assert.equal(options.token, 'fixture-token')
  assert.equal(options.endpoint, '127.0.0.1:18401')
  assert.equal(options.tls.disable, true)
})
test('missing credentials require an explicit local development opt-in', () => {
  assert.throws(() => gatewayOptions({}), /WECHATY_GATEWAY_BEARER/)
  assert.equal(gatewayOptions({ WECHATY_GATEWAY_DEV_INSECURE: '1' }).token, 'local-development-only')
})
test('remote endpoints use TLS and retain CA/server-name configuration', () => {
  const env = { WECHATY_GATEWAY_ENDPOINT: 'gateway.example:443', WECHATY_GATEWAY_BEARER: 'fixture-token' }
  assert.throws(() => gatewayOptions(env), /require.*TLS/)
  const options = gatewayOptions({ ...env, WECHATY_GATEWAY_TLS: '1', WECHATY_GATEWAY_TLS_CA_PEM: 'fixture-ca' })
  assert.equal(options.tls.disable, false)
  assert.equal(options.tls.caCert, 'fixture-ca')
  assert.equal(options.tls.serverName, 'gateway.example')
})
test('ambiguous endpoints and embedded credentials are rejected', () => {
  for (const endpoint of ['user:pass@localhost:18401', 'localhost:18401/path', 'localhost', 'localhost:18401?x=1']) {
    assert.throws(() => gatewayOptions({ WECHATY_GATEWAY_ENDPOINT: endpoint, WECHATY_GATEWAY_BEARER: 'fixture-token' }))
  }
  assert.equal(gatewayOptions({ WECHATY_GATEWAY_ENDPOINT: '[::1]:18401', WECHATY_GATEWAY_BEARER: 'fixture-token' }).tls.disable, true)
})
