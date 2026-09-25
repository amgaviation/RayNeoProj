// Service-role Supabase client and user lookup for the Edge Functions.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

export function adminClient(): SupabaseClient {
  const url = Deno.env.get('SUPABASE_URL')
  let key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const secretKeys = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (secretKeys) {
    try {
      key = (JSON.parse(secretKeys) as Record<string, string>).default ?? key
    } catch {
      // Keep the legacy key.
    }
  }
  if (!url || !key) throw new Error('Supabase URL or secret key missing')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

/** The signed-in user behind the request's bearer token, checked with Supabase Auth. */
export async function requestUser(admin: SupabaseClient, req: Request): Promise<{ id: string; phone: string } | null> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!token) return null
  const { data, error } = await admin.auth.getUser(token)
  if (error || !data.user) return null
  return { id: data.user.id, phone: data.user.phone ?? '' }
}
