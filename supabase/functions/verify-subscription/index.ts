// The app calls this after a purchase or restore with the transaction ID. The
// subscription is looked up with Apple and linked to the signed-in account.
import { adminClient, requestUser } from '../_shared/admin.ts'
import { appStoreConfigFromEnv, entitlementFrom, mayClaim, subscriptionStatuses } from '../_shared/appstore.ts'
import { json, methodNotAllowed } from '../_shared/http.ts'
import { WELCOME_TEXT } from '../_shared/messages.ts'
import { sendSms, smsConfigFromEnv } from '../_shared/sms.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return methodNotAllowed()
  const admin = adminClient()
  const user = await requestUser(admin, req)
  if (!user) return json({ error: 'Sign in first.' }, 401)

  const { transactionId } = await req.json().catch(() => ({})) as { transactionId?: string }
  if (!transactionId) return json({ error: 'transactionId is required.' }, 400)

  const config = appStoreConfigFromEnv()
  const statuses = await subscriptionStatuses(config, String(transactionId))
  const entitlement = statuses && entitlementFrom(statuses, config)
  if (!entitlement) return json({ subscribed: false, error: 'No BlueNudge subscription found for that purchase.' }, 404)
  const userExists = async (id: string) => {
    const { data } = await admin.auth.admin.getUserById(id)
    return !!data?.user
  }
  if (!(await mayClaim(entitlement, user.id, userExists))) {
    return json({ subscribed: false, error: 'That subscription was bought on another BlueNudge account.' }, 409)
  }

  const { error } = await admin.rpc('upsert_subscription', {
    p_user: user.id,
    p_original_transaction_id: entitlement.originalTransactionId,
    p_product_id: entitlement.productId,
    p_status: entitlement.status,
    p_entitled_until: entitlement.entitledUntil?.toISOString() ?? null,
    p_environment: entitlement.environment,
  })
  if (error) {
    const taken = error.code === '42501'
    return json({ subscribed: false, error: taken ? 'That subscription is linked to another account.' : error.message }, taken ? 409 : 500)
  }
  const subscribed = !!entitlement.entitledUntil && entitlement.entitledUntil > new Date()
  if (subscribed) await sendWelcome(admin, user.id)
  return json({ subscribed, entitledUntil: entitlement.entitledUntil?.toISOString() ?? null })
})

/** The opt-in confirmation carriers expect, once per account. Never fails the request. */
async function sendWelcome(admin: ReturnType<typeof adminClient>, userId: string) {
  try {
    const { data: phone, error } = await admin.rpc('claim_welcome', { p_user: userId })
    if (error) throw error
    if (typeof phone !== 'string' || !phone) return
    const result = await sendSms(smsConfigFromEnv(), phone, WELCOME_TEXT)
    if (!result.ok) console.error('welcome text failed', result.error)
  } catch (error) {
    console.error('welcome text failed', error)
  }
}
