import { assert, assertEquals } from 'jsr:@std/assert@1'
import {
  type AppStoreConfig, appStoreToken, base64url, decodeJws, entitlementFrom, mayClaim, notificationTransactionId, subscriptionStatuses,
} from '../functions/_shared/appstore.ts'

async function testConfig(): Promise<{ config: AppStoreConfig; publicKey: CryptoKey }> {
  const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', keys.privateKey))
  let binary = ''
  for (const byte of der) binary += String.fromCharCode(byte)
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(binary).replace(/(.{64})/g, '$1\n')}\n-----END PRIVATE KEY-----`
  return {
    config: { issuerId: 'issuer', keyId: 'KEY1', privateKey: pem, bundleId: 'com.example.app', productIds: ['texts.monthly', 'texts.yearly'] },
    publicKey: keys.publicKey,
  }
}

const jws = (payload: unknown) => `${base64url(JSON.stringify({ alg: 'ES256' }))}.${base64url(JSON.stringify(payload))}.sig`

Deno.test('App Store token is a valid ES256 JWT', async () => {
  const { config, publicKey } = await testConfig()
  const token = await appStoreToken(config, 1_790_000_000_000)
  const [header, payload, signature] = token.split('.')
  assertEquals(decodeJws<Record<string, unknown>>(`x.${header}.x`), { alg: 'ES256', kid: 'KEY1', typ: 'JWT' })
  assertEquals(decodeJws<Record<string, unknown>>(token), {
    iss: 'issuer', iat: 1_790_000_000, exp: 1_790_000_300, aud: 'appstoreconnect-v1', bid: 'com.example.app',
  })
  const sig = Uint8Array.from(atob(signature.replace(/-/g, '+').replace(/_/g, '/') + '=='.slice(0, (4 - signature.length % 4) % 4)), (c) => c.charCodeAt(0))
  assert(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, sig, new TextEncoder().encode(`${header}.${payload}`)))
})

Deno.test('entitlement picks the active subscription for this app', async () => {
  const { config } = await testConfig()
  const now = new Date('2026-09-25T12:00:00Z')
  const response = {
    environment: 'Sandbox',
    bundleId: 'com.example.app',
    data: [{
      lastTransactions: [
        { status: 2, signedTransactionInfo: jws({ originalTransactionId: '100', productId: 'texts.monthly', bundleId: 'com.example.app', expiresDate: Date.parse('2026-08-01T00:00:00Z') }) },
        { status: 1, signedTransactionInfo: jws({ originalTransactionId: '200', productId: 'texts.yearly', bundleId: 'com.example.app', expiresDate: Date.parse('2027-09-01T00:00:00Z'), appAccountToken: 'ABCDEF00-0000-0000-0000-000000000000', environment: 'Sandbox' }) },
        { status: 1, signedTransactionInfo: jws({ originalTransactionId: '300', productId: 'other.product', bundleId: 'com.example.app', expiresDate: Date.parse('2028-01-01T00:00:00Z') }) },
      ],
    }],
  }
  const entitlement = entitlementFrom(response, config, now)!
  assertEquals(entitlement.originalTransactionId, '200')
  assertEquals(entitlement.productId, 'texts.yearly')
  assertEquals(entitlement.status, 1)
  assertEquals(entitlement.entitledUntil?.toISOString(), '2027-09-01T00:00:00.000Z')
  assertEquals(entitlement.appAccountToken, 'abcdef00-0000-0000-0000-000000000000')
})

Deno.test('grace period uses the renewal info; revoked and other apps are refused', async () => {
  const { config } = await testConfig()
  const grace = entitlementFrom({
    data: [{ lastTransactions: [{
      status: 4,
      signedTransactionInfo: jws({ originalTransactionId: '1', productId: 'texts.monthly', expiresDate: Date.parse('2026-09-20T00:00:00Z') }),
      signedRenewalInfo: jws({ gracePeriodExpiresDate: Date.parse('2026-10-06T00:00:00Z') }),
    }] }],
  }, config)!
  assertEquals(grace.entitledUntil?.toISOString(), '2026-10-06T00:00:00.000Z')

  const revoked = entitlementFrom({
    data: [{ lastTransactions: [{ status: 5, signedTransactionInfo: jws({ originalTransactionId: '1', productId: 'texts.monthly', expiresDate: Date.parse('2027-01-01T00:00:00Z'), revocationDate: 1 }) }] }],
  }, config)!
  assertEquals(revoked.entitledUntil, null)

  assertEquals(entitlementFrom({ bundleId: 'com.other.app', data: [] }, config), null)
})

Deno.test('status lookup falls back to the sandbox', async () => {
  const { config } = await testConfig()
  const hosts: string[] = []
  const fakeFetch = ((url: string) => {
    hosts.push(new URL(url).host)
    return Promise.resolve(url.includes('sandbox')
      ? new Response(JSON.stringify({ environment: 'Sandbox', data: [] }), { status: 200 })
      : new Response('{}', { status: 404 }))
  }) as typeof fetch
  const response = await subscriptionStatuses(config, '2000000123', fakeFetch)
  assertEquals(response?.environment, 'Sandbox')
  assertEquals(hosts, ['api.storekit.apple.com', 'api.storekit-sandbox.apple.com'])
  let threw = false
  try { await subscriptionStatuses(config, '../etc', fakeFetch) } catch { threw = true }
  assert(threw)
})

Deno.test('notification transaction ID', () => {
  const payload = jws({ notificationType: 'DID_RENEW', data: { signedTransactionInfo: jws({ originalTransactionId: '777' }) } })
  assertEquals(notificationTransactionId(payload), '777')
  assertEquals(notificationTransactionId(jws({ notificationType: 'TEST' })), null)
})

Deno.test('a purchase moves to a new account only once its account is gone', async () => {
  const exists = (ids: string[]) => (id: string) => Promise.resolve(ids.includes(id))
  const owner = '6f1c1a52-7d0e-4f8e-9a57-1b7f0c9d2e31'
  const other = '0b6f4d7e-2c1a-4e33-8f90-5a1d2c3b4e5f'
  assert(await mayClaim({ appAccountToken: null }, other, exists([owner])))
  assert(await mayClaim({ appAccountToken: owner.toUpperCase() }, owner, exists([owner])))
  assert(!(await mayClaim({ appAccountToken: owner }, other, exists([owner, other]))))
  assert(await mayClaim({ appAccountToken: owner }, other, exists([other])))
})
