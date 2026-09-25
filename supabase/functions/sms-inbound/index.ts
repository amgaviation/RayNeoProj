// The SMS provider's webhook for replies to BlueNudge's number.
import { adminClient } from '../_shared/admin.ts'
import { json, methodNotAllowed } from '../_shared/http.ts'
import { handleReply } from '../_shared/inbound.ts'
import { helpTextFromEnv } from '../_shared/messages.ts'
import { readInbound, sendSms, smsConfigFromEnv, twiml } from '../_shared/sms.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return methodNotAllowed()
  const sms = smsConfigFromEnv()
  const raw = await req.text()
  const message = await readInbound(sms, raw, req.headers)
  if (!message) return json({ error: 'Invalid signature' }, 401)

  const admin = adminClient()
  const reply = await handleReply(message, {
    async userForPhone(phone) {
      const { data } = await admin.rpc('user_for_phone', { p_phone: phone })
      return (data as string | null) ?? null
    },
    async record(userId, from, body, command, providerId) {
      const { data, error } = await admin.rpc('record_inbound', {
        p_user: userId, p_from: from, p_body: body, p_command: command, p_provider_message_id: providerId || null,
      })
      if (error) throw error
      return data === true
    },
    async setPaused(userId, paused) {
      const { error } = await admin.rpc('set_paused_for_user', { p_user: userId, p_paused: paused })
      if (error) throw error
    },
    async snooze(userId, minutes) {
      const { data, error } = await admin.rpc('snooze_last_text', { p_user: userId, p_minutes: minutes })
      if (error) throw error
      const row = data as { fire_at?: string } | null
      return row?.fire_at ? { fireAt: new Date(row.fire_at) } : null
    },
    async timeZone(userId) {
      const { data } = await admin.from('profiles').select('time_zone').eq('user_id', userId).maybeSingle()
      return (data?.time_zone as string | undefined) ?? 'UTC'
    },
    helpText: helpTextFromEnv(Deno.env.get('SMS_HELP_TEXT')),
  })

  if (sms.provider === 'twilio') return twiml(reply)
  if (reply) {
    const result = await sendSms(sms, message.from, reply)
    if (!result.ok) console.error('reply failed', result.error)
  }
  return json({ ok: true })
})
