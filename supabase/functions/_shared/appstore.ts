// App Store subscriptions. The server never trusts what the app says about a
// purchase: it asks Apple's App Store Server API directly (authenticated with
// the In-App Purchase key), so the answer is authoritative.

export interface AppStoreConfig {
  issuerId: string
  keyId: string
  /** The .p8 key's contents (PKCS#8 PEM). */
  privateKey: string
  bundleId: string
  /** Subscription product IDs that unlock texts. Empty accepts any in the app. */
  productIds: string[]
}

export interface Entitlement {
  originalTransactionId: string
  productId: string
  /** 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked. */
  status: number
  entitledUntil: Date | null
  appAccountToken: string | null
  environment: string
}

type Fetch = typeof fetch

export function appStoreConfigFromEnv(get: (name: string) => string | undefined = (n) => Deno.env.get(n)): AppStoreConfig {
  const required = (name: string) => {
    const value = get(name)
    if (!value) throw new Error(`Missing ${name}`)
    return value
  }
  return {
    issuerId: required('APPSTORE_ISSUER_ID'),
    keyId: required('APPSTORE_KEY_ID'),
    privateKey: required('APPSTORE_PRIVATE_KEY').replace(/\\n/g, '\n'),
    bundleId: required('APPSTORE_BUNDLE_ID'),
    productIds: (get('APPSTORE_PRODUCT_IDS') ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  }
}

/** ES256 JWT for the App Store Server API, valid for 5 minutes. */
export async function appStoreToken(config: AppStoreConfig, now = Date.now()): Promise<string> {
  const header = { alg: 'ES256', kid: config.keyId, typ: 'JWT' }
  const iat = Math.floor(now / 1000)
  const payload = { iss: config.issuerId, iat, exp: iat + 300, aud: 'appstoreconnect-v1', bid: config.bundleId }
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`
  const key = await crypto.subtle.importKey(
    'pkcs8', pemToDer(config.privateKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'],
  )
  // WebCrypto returns the raw r||s form JWS expects.
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(signingInput))
  return `${signingInput}.${base64url(new Uint8Array(signature))}`
}

/** Decodes a JWS payload without verifying it. Only for data fetched from Apple over TLS. */
export function decodeJws<T>(jws: string): T {
  const part = jws.split('.')[1]
  if (!part) throw new Error('Not a JWS')
  return JSON.parse(new TextDecoder().decode(unbase64url(part))) as T
}

interface StatusResponse {
  environment?: string
  bundleId?: string
  data?: {
    lastTransactions?: {
      originalTransactionId?: string
      status?: number
      signedTransactionInfo?: string
      signedRenewalInfo?: string
    }[]
  }[]
}

interface TransactionPayload {
  originalTransactionId?: string
  productId?: string
  bundleId?: string
  expiresDate?: number
  appAccountToken?: string
  environment?: string
  revocationDate?: number
}

interface RenewalPayload {
  gracePeriodExpiresDate?: number
}

/** Get All Subscription Statuses, trying production first and then the sandbox. */
export async function subscriptionStatuses(
  config: AppStoreConfig,
  transactionId: string,
  fetchImpl: Fetch = fetch,
): Promise<StatusResponse | null> {
  if (!/^\d{1,32}$/.test(transactionId)) throw new Error('Invalid transaction ID')
  for (const host of ['https://api.storekit.apple.com', 'https://api.storekit-sandbox.apple.com']) {
    const response = await fetchImpl(`${host}/inApps/v1/subscriptions/${transactionId}`, {
      headers: { Authorization: `Bearer ${await appStoreToken(config)}` },
    })
    if (response.status === 404) continue
    if (!response.ok) throw new Error(`App Store Server API ${response.status}: ${await response.text()}`)
    return await response.json() as StatusResponse
  }
  return null
}

/** The best entitlement in a status response for this app's products. */
export function entitlementFrom(response: StatusResponse, config: AppStoreConfig, now = new Date()): Entitlement | null {
  if (response.bundleId && response.bundleId !== config.bundleId) return null
  const candidates: Entitlement[] = []
  for (const group of response.data ?? []) {
    for (const item of group.lastTransactions ?? []) {
      if (!item.signedTransactionInfo) continue
      const transaction = decodeJws<TransactionPayload>(item.signedTransactionInfo)
      if (transaction.bundleId && transaction.bundleId !== config.bundleId) continue
      if (!transaction.productId || !transaction.originalTransactionId) continue
      if (config.productIds.length > 0 && !config.productIds.includes(transaction.productId)) continue
      const status = item.status ?? 0
      const expires = transaction.expiresDate ? new Date(transaction.expiresDate) : null
      let entitledUntil: Date | null
      if (transaction.revocationDate || status === 5) {
        entitledUntil = null
      } else if (status === 1) {
        entitledUntil = expires
      } else if (status === 4) {
        const renewal = item.signedRenewalInfo ? decodeJws<RenewalPayload>(item.signedRenewalInfo) : {}
        entitledUntil = renewal.gracePeriodExpiresDate
          ? new Date(renewal.gracePeriodExpiresDate)
          : expires && new Date(expires.getTime() + 16 * 86_400_000)
      } else {
        // Expired or billing retry: keep the (past) expiry for the record.
        entitledUntil = expires && expires < now ? expires : now
      }
      candidates.push({
        originalTransactionId: transaction.originalTransactionId,
        productId: transaction.productId,
        status,
        entitledUntil,
        appAccountToken: transaction.appAccountToken?.toLowerCase() ?? null,
        environment: transaction.environment ?? response.environment ?? 'Production',
      })
    }
  }
  candidates.sort((a, b) => (b.entitledUntil?.getTime() ?? 0) - (a.entitledUntil?.getTime() ?? 0))
  return candidates[0] ?? null
}

/** The original transaction ID inside an App Store Server Notification, unverified. */
/**
 * Whether `userId` may claim a purchase. A purchase made while signed in carries
 * that account's ID as its appAccountToken; it can move to a new account only
 * once the original account is gone (deleted, then signed up again).
 */
export async function mayClaim(
  entitlement: Pick<Entitlement, 'appAccountToken'>,
  userId: string,
  userExists: (id: string) => Promise<boolean>,
): Promise<boolean> {
  const token = entitlement.appAccountToken?.toLowerCase()
  if (!token || token === userId.toLowerCase()) return true
  return !(await userExists(token))
}

export function notificationTransactionId(signedPayload: string): string | null {
  const payload = decodeJws<{ data?: { signedTransactionInfo?: string } }>(signedPayload)
  const info = payload.data?.signedTransactionInfo
  if (!info) return null
  return decodeJws<TransactionPayload>(info).originalTransactionId ?? null
}

function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem.replace(/-----(BEGIN|END) [A-Z ]+-----/g, '').replace(/\s+/g, '')
  const binary = atob(body)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

export function base64url(input: string | Uint8Array): string {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : input
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function unbase64url(text: string): Uint8Array<ArrayBuffer> {
  const padded = text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4)
  const binary = atob(padded)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}
