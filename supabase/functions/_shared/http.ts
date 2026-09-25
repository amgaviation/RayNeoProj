export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

export function methodNotAllowed(): Response {
  return json({ error: 'Method not allowed' }, 405)
}
