// Called every minute by pg_cron. Sends the texts that are due.
import { adminClient } from '../_shared/admin.ts'
import { json } from '../_shared/http.ts'
import { sendDueTexts } from '../_shared/sender.ts'
import { sendSms, smsConfigFromEnv, timingSafeEqual } from '../_shared/sms.ts'

Deno.serve(async (req) => {
  const secret = Deno.env.get('CRON_SECRET')
  if (!secret || !timingSafeEqual(req.headers.get('Authorization') ?? '', `Bearer ${secret}`)) {
    return json({ error: 'Unauthorized' }, 401)
  }
  const admin = adminClient()
  const sms = smsConfigFromEnv()

  const summary = await sendDueTexts({
    async claim(limit) {
      const { data, error } = await admin.rpc('claim_due_texts', { p_limit: limit })
      if (error) throw error
      return data ?? []
    },
    async phones(userIds) {
      const { data, error } = await admin.from('profiles').select('user_id, phone').in('user_id', userIds)
      if (error) throw error
      return new Map((data ?? []).filter((row) => row.phone).map((row) => [row.user_id as string, row.phone as string]))
    },
    send: (to, body) => sendSms(sms, to, body),
    async markResult(id, status, providerId, errorText) {
      const { error } = await admin.rpc('mark_text_result', {
        p_id: id,
        p_status: status,
        p_provider_message_id: providerId ?? null,
        p_error: errorText ?? null,
      })
      if (error) console.error('mark_text_result failed', id, error)
    },
    async pause(userId) {
      const { error } = await admin.rpc('set_paused_for_user', { p_user: userId, p_paused: true })
      if (error) console.error('pause failed', userId, error)
    },
  })
  if (summary.claimed > 0) console.log('send-due', summary)
  return json(summary)
})
