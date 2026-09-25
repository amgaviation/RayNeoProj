// Deletes the signed-in account and, through cascades, everything stored for
// it. The App Store subscription itself is managed by the customer in Settings.
import { adminClient, requestUser } from '../_shared/admin.ts'
import { json, methodNotAllowed } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return methodNotAllowed()
  const admin = adminClient()
  const user = await requestUser(admin, req)
  if (!user) return json({ error: 'Sign in first.' }, 401)
  const { error } = await admin.auth.admin.deleteUser(user.id)
  if (error) return json({ error: error.message }, 500)
  return json({ deleted: true })
})
