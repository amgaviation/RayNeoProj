// Supabase Auth "Send SMS" hook: sends sign-in codes through the same SMS
// provider as reminders, so there's one number and one bill.
import { Webhook } from 'npm:standardwebhooks@1.0.0'
import { json } from '../_shared/http.ts'
import { sendSms, smsConfigFromEnv } from '../_shared/sms.ts'

Deno.serve(async (req) => {
  const secret = (Deno.env.get('SEND_SMS_HOOK_SECRETS') ?? '').split('|')[0].replace('v1,whsec_', '')
  if (!secret) return json({ error: { http_code: 500, message: 'Hook secret not set' } }, 500)
  const payload = await req.text()
  let event: { user: { phone: string }; sms: { otp: string } }
  try {
    event = new Webhook(secret).verify(payload, Object.fromEntries(req.headers)) as typeof event
  } catch {
    return json({ error: { http_code: 401, message: 'Invalid signature' } }, 401)
  }
  const result = await sendSms(
    smsConfigFromEnv(),
    event.user.phone,
    `${event.sms.otp} is your BlueNudge code. Don't share it with anyone.`,
  )
  if (!result.ok) {
    return json({ error: { http_code: 502, message: `Couldn't send the code: ${result.error}` } }, 502)
  }
  return json({})
})
