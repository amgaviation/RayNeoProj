// Sending and receiving texts through Twilio or Telnyx. Pick one with
// SMS_PROVIDER; both use the same interface so the rest of the code doesn't care.

export type SmsProvider = 'twilio' | 'telnyx'

export interface SmsConfig {
  provider: SmsProvider
  /** Sender number in E.164, or empty when a messaging service/profile picks it. */
  from: string
  twilioAccountSid?: string
  twilioAuthToken?: string
  twilioMessagingServiceSid?: string
  telnyxApiKey?: string
  telnyxMessagingProfileId?: string
  telnyxPublicKey?: string
  /** The public URL of the sms-inbound function, as configured at the provider. */
  inboundUrl?: string
  /**
   * Calling codes texts may go to (SMS_ALLOWED_COUNTRY_CODES, default "1" for
   * the US and Canada; "*" for any). Keeps costs predictable and blunts SMS
   * pumping fraud through the sign-in code.
   */
  allowedCallingCodes?: string[]
}

export interface SendResult {
  ok: boolean
  id?: string
  error?: string
  /** The recipient replied STOP to our number; the carrier blocks further texts. */
  optedOut?: boolean
}

export interface InboundMessage {
  id: string
  from: string
  to: string
  body: string
}

type Fetch = typeof fetch

export function smsConfigFromEnv(get: (name: string) => string | undefined = (n) => Deno.env.get(n)): SmsConfig {
  const provider = (get('SMS_PROVIDER') ?? 'twilio').toLowerCase()
  if (provider !== 'twilio' && provider !== 'telnyx') throw new Error(`Unknown SMS_PROVIDER ${provider}`)
  return {
    provider,
    from: get('SMS_FROM_NUMBER') ?? '',
    twilioAccountSid: get('TWILIO_ACCOUNT_SID'),
    twilioAuthToken: get('TWILIO_AUTH_TOKEN'),
    twilioMessagingServiceSid: get('TWILIO_MESSAGING_SERVICE_SID'),
    telnyxApiKey: get('TELNYX_API_KEY'),
    telnyxMessagingProfileId: get('TELNYX_MESSAGING_PROFILE_ID'),
    telnyxPublicKey: get('TELNYX_PUBLIC_KEY'),
    inboundUrl: get('SMS_INBOUND_URL'),
    allowedCallingCodes: (get('SMS_ALLOWED_COUNTRY_CODES') ?? '1')
      .split(',').map((code) => code.trim().replace(/^\+/, '')).filter(Boolean),
  }
}

/** True when `phone` may be texted under `callingCodes` (any number when none are set, or "*"). */
export function isAllowedNumber(phone: string, callingCodes: string[] | undefined): boolean {
  if (!callingCodes || callingCodes.length === 0 || callingCodes.includes('*')) return true
  const digits = e164(phone).slice(1)
  return callingCodes.some((code) => digits.startsWith(code))
}

export function e164(phone: string): string {
  const trimmed = phone.trim()
  return trimmed.startsWith('+') ? trimmed : `+${trimmed}`
}

export async function sendSms(config: SmsConfig, to: string, body: string, fetchImpl: Fetch = fetch): Promise<SendResult> {
  if (!isAllowedNumber(to, config.allowedCallingCodes)) {
    return { ok: false, error: 'Texts to this country are turned off (SMS_ALLOWED_COUNTRY_CODES).' }
  }
  return config.provider === 'twilio'
    ? await sendTwilio(config, e164(to), body, fetchImpl)
    : await sendTelnyx(config, e164(to), body, fetchImpl)
}

async function sendTwilio(config: SmsConfig, to: string, body: string, fetchImpl: Fetch): Promise<SendResult> {
  const sid = config.twilioAccountSid
  const token = config.twilioAuthToken
  if (!sid || !token) return { ok: false, error: 'Twilio credentials are not set.' }
  const form = new URLSearchParams({ To: to, Body: body })
  if (config.twilioMessagingServiceSid) form.set('MessagingServiceSid', config.twilioMessagingServiceSid)
  else form.set('From', config.from)
  const response = await fetchImpl(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${btoa(`${sid}:${token}`)}`,
    },
    body: form,
  })
  const payload = await response.json().catch(() => ({})) as Record<string, unknown>
  if (response.ok && typeof payload.sid === 'string') return { ok: true, id: payload.sid }
  const code = Number(payload.code)
  return {
    ok: false,
    error: `Twilio ${code || response.status}: ${String(payload.message ?? response.statusText)}`,
    // 21610: the number replied STOP to this sender.
    optedOut: code === 21610,
  }
}

async function sendTelnyx(config: SmsConfig, to: string, body: string, fetchImpl: Fetch): Promise<SendResult> {
  if (!config.telnyxApiKey) return { ok: false, error: 'Telnyx API key is not set.' }
  const message: Record<string, string> = { to, text: body }
  if (config.from) message.from = config.from
  if (config.telnyxMessagingProfileId) message.messaging_profile_id = config.telnyxMessagingProfileId
  const response = await fetchImpl('https://api.telnyx.com/v2/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.telnyxApiKey}` },
    body: JSON.stringify(message),
  })
  const payload = await response.json().catch(() => ({})) as {
    data?: { id?: string }
    errors?: { code?: string; title?: string; detail?: string }[]
  }
  if (response.ok && payload.data?.id) return { ok: true, id: payload.data.id }
  const first = payload.errors?.[0]
  return {
    ok: false,
    error: `Telnyx ${first?.code ?? response.status}: ${first?.detail ?? first?.title ?? response.statusText}`,
    // 40300: blocked because the number replied STOP.
    optedOut: first?.code === '40300',
  }
}

// Receiving ------------------------------------------------------------------

/** Verifies the provider's signature and extracts the message. Null when invalid. */
export async function readInbound(
  config: SmsConfig,
  rawBody: string,
  headers: Headers,
  now: Date = new Date(),
): Promise<InboundMessage | null> {
  if (config.provider === 'twilio') {
    const params = new URLSearchParams(rawBody)
    const signature = headers.get('x-twilio-signature') ?? ''
    if (!config.twilioAuthToken || !config.inboundUrl) return null
    const expected = await twilioSignature(config.twilioAuthToken, config.inboundUrl, params)
    if (!timingSafeEqual(signature, expected)) return null
    return {
      id: params.get('MessageSid') ?? params.get('SmsSid') ?? '',
      from: params.get('From') ?? '',
      to: params.get('To') ?? '',
      body: params.get('Body') ?? '',
    }
  }

  const signature = headers.get('telnyx-signature-ed25519') ?? ''
  const timestamp = headers.get('telnyx-timestamp') ?? ''
  if (!config.telnyxPublicKey || !signature || !timestamp) return null
  const age = Math.abs(now.getTime() / 1000 - Number(timestamp))
  if (!Number.isFinite(age) || age > 300) return null
  if (!(await verifyEd25519(config.telnyxPublicKey, `${timestamp}|${rawBody}`, signature))) return null
  const event = JSON.parse(rawBody) as {
    data?: { event_type?: string; payload?: { id?: string; text?: string; from?: { phone_number?: string }; to?: { phone_number?: string }[] } }
  }
  if (event.data?.event_type !== 'message.received') return null
  const payload = event.data.payload ?? {}
  return {
    id: payload.id ?? '',
    from: payload.from?.phone_number ?? '',
    to: payload.to?.[0]?.phone_number ?? '',
    body: payload.text ?? '',
  }
}

/** Base64 HMAC-SHA1 of the URL followed by the sorted POST parameters. */
export async function twilioSignature(authToken: string, url: string, params: URLSearchParams): Promise<string> {
  const keys = [...new Set(params.keys())].sort()
  let data = url
  for (const key of keys) {
    for (const value of params.getAll(key)) data += key + value
  }
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(authToken), { name: 'HMAC', hash: 'SHA-1' }, false, ['sign'],
  )
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data))
  return base64(new Uint8Array(mac))
}

async function verifyEd25519(publicKeyBase64: string, message: string, signatureBase64: string): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey('raw', unbase64(publicKeyBase64), { name: 'Ed25519' }, false, ['verify'])
    return await crypto.subtle.verify('Ed25519', key, unbase64(signatureBase64), new TextEncoder().encode(message))
  } catch {
    return false
  }
}

/** TwiML reply for Twilio's inbound webhook. */
export function twiml(reply: string | null): Response {
  const body = reply
    ? `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${escapeXml(reply)}</Message></Response>`
    : '<?xml version="1.0" encoding="UTF-8"?><Response/>'
  return new Response(body, { headers: { 'Content-Type': 'text/xml' } })
}

function escapeXml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

export function timingSafeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a)
  const right = new TextEncoder().encode(b)
  let diff = left.length ^ right.length
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0)
  }
  return diff === 0
}

export function base64(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

export function unbase64(text: string): Uint8Array<ArrayBuffer> {
  const binary = atob(text)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}
