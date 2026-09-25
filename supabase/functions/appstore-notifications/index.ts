// App Store Server Notifications V2 (renewals, expirations, refunds). The
// notification only says which subscription changed; its state is then read
// from Apple's API, so a forged notification can't grant anything.
import { adminClient } from '../_shared/admin.ts'
import { appStoreConfigFromEnv, entitlementFrom, notificationTransactionId, subscriptionStatuses } from '../_shared/appstore.ts'
import { json, methodNotAllowed } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return methodNotAllowed()
  const { signedPayload } = await req.json().catch(() => ({})) as { signedPayload?: string }
  if (!signedPayload) return json({ error: 'signedPayload is required' }, 400)

  let transactionId: string | null
  try {
    transactionId = notificationTransactionId(signedPayload)
  } catch {
    return json({ error: 'Unreadable payload' }, 400)
  }
  // TEST notifications and app-level events carry no transaction.
  if (!transactionId) return json({ ok: true })

  const config = appStoreConfigFromEnv()
  const statuses = await subscriptionStatuses(config, transactionId)
  const entitlement = statuses && entitlementFrom(statuses, config)
  if (!entitlement) return json({ ok: true })

  // The account it's linked to wins over the purchase's appAccountToken: a
  // subscription moves to a new account when the original one was deleted.
  const admin = adminClient()
  const { data: linked } = await admin.rpc('user_for_transaction', { p_original_transaction_id: entitlement.originalTransactionId })
  const userId = (linked as string | null) ?? entitlement.appAccountToken
  if (!userId) return json({ ok: true })

  const { error } = await admin.rpc('upsert_subscription', {
    p_user: userId,
    p_original_transaction_id: entitlement.originalTransactionId,
    p_product_id: entitlement.productId,
    p_status: entitlement.status,
    p_entitled_until: entitlement.entitledUntil?.toISOString() ?? null,
    p_environment: entitlement.environment,
  })
  // A failure makes Apple retry the notification later.
  if (error && error.code !== '42501' && error.code !== '23503') return json({ error: error.message }, 500)
  return json({ ok: true })
})
