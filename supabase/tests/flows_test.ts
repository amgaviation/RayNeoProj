import { assertEquals } from 'jsr:@std/assert@1'
import { handleReply, type InboundDeps, whenPhrase } from '../functions/_shared/inbound.ts'
import { DEFAULT_HELP_TEXT, helpTextFromEnv, WELCOME_TEXT } from '../functions/_shared/messages.ts'
import { type OutboxRow, sendDueTexts } from '../functions/_shared/sender.ts'

Deno.test('sendDueTexts sends, records and pauses on STOP', async () => {
  const rows: OutboxRow[] = [
    { id: 1, user_id: 'a', body: 'Vitamins', title: 'Vitamins', fire_at: '' },
    { id: 2, user_id: 'b', body: 'Water', title: 'Water', fire_at: '' },
    { id: 3, user_id: 'c', body: 'Rent', title: 'Rent', fire_at: '' },
  ]
  const results: [number, string, string | undefined][] = []
  const paused: string[] = []
  const summary = await sendDueTexts({
    claim: () => Promise.resolve(rows),
    phones: () => Promise.resolve(new Map([['a', '+15550000001'], ['b', '+15550000002']])),
    send: (to) => Promise.resolve(to.endsWith('1') ? { ok: true, id: 'SM1' } : { ok: false, error: 'blocked', optedOut: true }),
    markResult: (id, status, _provider, error) => { results.push([id, status, error]); return Promise.resolve() },
    pause: (user) => { paused.push(user); return Promise.resolve() },
  })
  assertEquals(summary, { claimed: 3, sent: 1, failed: 2 })
  assertEquals(results[0], [1, 'sent', undefined])
  assertEquals(results[1][1], 'failed')
  assertEquals(results[2], [3, 'failed', 'No verified phone number on the account.'])
  assertEquals(paused, ['b'])
})

Deno.test('sendDueTexts does nothing when nothing is due', async () => {
  let asked = false
  const summary = await sendDueTexts({
    claim: () => Promise.resolve([]),
    phones: () => { asked = true; return Promise.resolve(new Map()) },
    send: () => Promise.reject(new Error('should not send')),
    markResult: () => Promise.resolve(),
    pause: () => Promise.resolve(),
  })
  assertEquals(summary, { claimed: 0, sent: 0, failed: 0 })
  assertEquals(asked, false)
})

function deps(overrides: Partial<InboundDeps> = {}): InboundDeps & { log: string[] } {
  const log: string[] = []
  return {
    log,
    userForPhone: (phone) => Promise.resolve(phone === '+15125550142' ? 'user-1' : null),
    record: () => Promise.resolve(true),
    setPaused: (_user, paused) => { log.push(paused ? 'paused' : 'resumed'); return Promise.resolve() },
    snooze: (_user, minutes) => { log.push(`snooze ${minutes}`); return Promise.resolve({ fireAt: new Date('2026-09-25T14:40:00Z') }) },
    timeZone: () => Promise.resolve('America/Chicago'),
    helpText: 'BlueNudge help',
    ...overrides,
  }
}

Deno.test('SNOOZE replies queue the text and confirm in local time', async () => {
  const d = deps()
  const reply = await handleReply({ id: 'm1', from: '+15125550142', body: 'snooze 20' }, d, new Date('2026-09-25T14:20:00Z'))
  assertEquals(d.log, ['snooze 20'])
  assertEquals(reply, "Okay, I'll text you again at 9:40 AM.")
})

Deno.test('STOP and START pause and resume without a reply', async () => {
  const d = deps()
  assertEquals(await handleReply({ id: 'm1', from: '+15125550142', body: 'STOP' }, d), null)
  assertEquals(await handleReply({ id: 'm2', from: '+15125550142', body: 'start' }, d), null)
  assertEquals(d.log, ['paused', 'resumed'])
})

Deno.test('replies from unknown numbers and retries are ignored', async () => {
  const d = deps({ record: () => Promise.resolve(false) })
  assertEquals(await handleReply({ id: 'm1', from: '+15125550142', body: 'snooze' }, d), null)
  assertEquals(await handleReply({ id: 'm2', from: '+19998887777', body: 'snooze' }, deps()), null)
  assertEquals(d.log, [])
})

Deno.test('nothing to snooze', async () => {
  const d = deps({ snooze: () => Promise.resolve(null) })
  assertEquals(await handleReply({ id: 'm1', from: '+15125550142', body: 'LATER' }, d), "There's nothing to snooze right now.")
})

Deno.test('whenPhrase', () => {
  const now = new Date('2026-09-25T14:00:00Z')
  assertEquals(whenPhrase(new Date('2026-09-25T15:00:00Z'), now, 'UTC'), 'at 3:00 PM')
  assertEquals(whenPhrase(new Date('2026-09-26T09:00:00Z'), now, 'UTC'), 'tomorrow at 9:00 AM')
  assertEquals(whenPhrase(new Date('2026-09-29T09:00:00Z'), now, 'UTC'), 'on Tue, Sep 29 at 9:00 AM')
  assertEquals(whenPhrase(new Date('2026-09-25T15:00:00Z'), now, 'Not/AZone'), 'at 3:00 PM')
})

Deno.test('HELP gets the help text, unless the provider answers it', async () => {
  assertEquals(await handleReply({ id: 'h1', from: '+15125550142', body: 'Help' }, deps()), 'BlueNudge help')
  assertEquals(await handleReply({ id: 'h2', from: '+15125550142', body: 'INFO' }, deps({ helpText: null })), null)
  assertEquals(helpTextFromEnv(undefined), DEFAULT_HELP_TEXT)
  assertEquals(helpTextFromEnv(' off '), null)
  assertEquals(helpTextFromEnv('Help: support@example.com'), 'Help: support@example.com')
})

Deno.test('texts BlueNudge sends on its own stay within one SMS segment budget', () => {
  // GSM-7 only (no curly quotes or emoji), so each costs 1-2 segments, not 3+.
  for (const text of [WELCOME_TEXT, DEFAULT_HELP_TEXT]) {
    assertEquals(/^[A-Za-z0-9 .,:;'&!?()\-]*$/.test(text), true, text)
    assertEquals(text.length <= 306, true, text)
  }
})
