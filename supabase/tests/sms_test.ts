import { assert, assertEquals } from 'jsr:@std/assert@1'
import { createHmac } from 'node:crypto'
import {
  base64, isAllowedNumber, readInbound, sendSms, type SmsConfig, smsConfigFromEnv, twilioSignature,
} from '../functions/_shared/sms.ts'

const twilio: SmsConfig = {
  provider: 'twilio', from: '+15550001111', twilioAccountSid: 'AC123', twilioAuthToken: 'secret-token',
  inboundUrl: 'https://ref.supabase.co/functions/v1/sms-inbound',
}
const telnyx: SmsConfig = { provider: 'telnyx', from: '+15550001111', telnyxApiKey: 'KEY123' }

function fakeFetch(status: number, body: unknown, seen: { url?: string; init?: RequestInit }[]): typeof fetch {
  return ((url: string, init?: RequestInit) => {
    seen.push({ url, init })
    return Promise.resolve(new Response(JSON.stringify(body), { status }))
  }) as typeof fetch
}

Deno.test('Twilio send posts the message with basic auth', async () => {
  const seen: { url?: string; init?: RequestInit }[] = []
  const result = await sendSms(twilio, '15125550142', 'Take your vitamins', fakeFetch(201, { sid: 'SM1', status: 'queued' }, seen))
  assertEquals(result, { ok: true, id: 'SM1' })
  assertEquals(seen[0].url, 'https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json')
  const form = seen[0].init?.body as URLSearchParams
  assertEquals(form.get('To'), '+15125550142')
  assertEquals(form.get('From'), '+15550001111')
  assertEquals(form.get('Body'), 'Take your vitamins')
  assertEquals((seen[0].init?.headers as Record<string, string>).Authorization, `Basic ${btoa('AC123:secret-token')}`)
})

Deno.test('Twilio opt-out error is recognised', async () => {
  const result = await sendSms(twilio, '+15125550142', 'x', fakeFetch(400, { code: 21610, message: 'Unsubscribed recipient' }, []))
  assertEquals(result.ok, false)
  assertEquals(result.optedOut, true)
})

Deno.test('Telnyx send and opt-out', async () => {
  const seen: { url?: string; init?: RequestInit }[] = []
  const ok = await sendSms(telnyx, '+15125550142', 'Hi', fakeFetch(200, { data: { id: 'tx-1' } }, seen))
  assertEquals(ok, { ok: true, id: 'tx-1' })
  assertEquals(seen[0].url, 'https://api.telnyx.com/v2/messages')
  assertEquals(JSON.parse(seen[0].init?.body as string), { to: '+15125550142', text: 'Hi', from: '+15550001111' })
  const blocked = await sendSms(telnyx, '+15125550142', 'Hi', fakeFetch(400, { errors: [{ code: '40300', title: 'Blocked due to STOP message' }] }, []))
  assertEquals(blocked.optedOut, true)
})

Deno.test('Twilio signature matches an independent HMAC', async () => {
  const params = new URLSearchParams({ From: '+15125550142', Body: 'snooze 20', MessageSid: 'SM9', To: '+15550001111' })
  const expected = createHmac('sha1', 'secret-token')
    .update(twilio.inboundUrl + 'Bodysnooze 20' + 'From+15125550142' + 'MessageSidSM9' + 'To+15550001111')
    .digest('base64')
  assertEquals(await twilioSignature('secret-token', twilio.inboundUrl!, params), expected)

  const headers = new Headers({ 'x-twilio-signature': expected })
  const message = await readInbound(twilio, params.toString(), headers)
  assertEquals(message, { id: 'SM9', from: '+15125550142', to: '+15550001111', body: 'snooze 20' })

  const forged = await readInbound(twilio, params.toString().replace('snooze', 'STOP'), headers)
  assertEquals(forged, null)
})

Deno.test('Telnyx Ed25519 webhook verification', async () => {
  const keys = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']) as CryptoKeyPair
  const publicKey = base64(new Uint8Array(await crypto.subtle.exportKey('raw', keys.publicKey)))
  const config: SmsConfig = { ...telnyx, telnyxPublicKey: publicKey }
  const body = JSON.stringify({
    data: { event_type: 'message.received', payload: { id: 'msg-1', text: 'LATER', from: { phone_number: '+15125550142' }, to: [{ phone_number: '+15550001111' }] } },
  })
  const now = new Date('2026-09-25T12:00:00Z')
  const timestamp = String(Math.floor(now.getTime() / 1000))
  const signature = base64(new Uint8Array(await crypto.subtle.sign('Ed25519', keys.privateKey, new TextEncoder().encode(`${timestamp}|${body}`))))
  const headers = new Headers({ 'telnyx-signature-ed25519': signature, 'telnyx-timestamp': timestamp })

  assertEquals(await readInbound(config, body, headers, now), { id: 'msg-1', from: '+15125550142', to: '+15550001111', body: 'LATER' })
  assertEquals(await readInbound(config, body.replace('LATER', 'STOP'), headers, now), null)
  assertEquals(await readInbound(config, body, headers, new Date(now.getTime() + 10 * 60_000)), null)
  assert(await readInbound({ ...config, telnyxPublicKey: undefined }, body, headers, now) === null)
})

Deno.test('only allowed calling codes are texted', async () => {
  assertEquals(smsConfigFromEnv(() => undefined).allowedCallingCodes, ['1'])
  const env: Record<string, string> = { SMS_ALLOWED_COUNTRY_CODES: '+1, 44' }
  assertEquals(smsConfigFromEnv((name) => env[name]).allowedCallingCodes, ['1', '44'])

  assert(isAllowedNumber('+15125550142', ['1']))
  assert(!isAllowedNumber('+447700900123', ['1']))
  assert(isAllowedNumber('+447700900123', ['1', '44']))
  assert(isAllowedNumber('+882123456', ['*']))
  assert(isAllowedNumber('+882123456', undefined))

  const seen: { url?: string; init?: RequestInit }[] = []
  const result = await sendSms({ ...twilio, allowedCallingCodes: ['1'] }, '+447700900123', 'Hi', fakeFetch(201, { sid: 'SM1' }, seen))
  assertEquals(result.ok, false)
  assertEquals(seen.length, 0)
})
