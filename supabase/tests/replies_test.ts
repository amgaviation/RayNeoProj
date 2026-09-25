import { assertEquals } from 'jsr:@std/assert@1'
import { classifyOptOut, parseReply } from '../functions/_shared/replies.ts'

// Same cases as ReminderCore's ReplyParserTests, so the server and the Mac relay agree.
Deno.test('snooze variants', () => {
  const cases: [string, number][] = [
    ['snooze', 10], ['Snooze!', 10], ['SNOOZE 20', 20], ['snooze 20 min', 20], ['snooze 20m', 20],
    ['snooze 2h', 120], ['snooze 1 hour 30', 90], ['snooze an hour', 60], ['snooze half an hour', 30],
    ['snooze for 15 minutes', 15], ['later', 10], ['Remind me later', 10], ['remind me in 45 minutes', 45],
    ['remind me in 2 hours', 120], ['30 min', 30], ['30', 30], ['1h', 60], ['snooze 5000', 1440],
  ]
  for (const [text, minutes] of cases) {
    assertEquals(parseReply(text), { kind: 'snooze', minutes }, text)
  }
})

Deno.test('pause, resume and done', () => {
  for (const text of ['STOP', 'stop please', 'Pause', 'unsubscribe']) assertEquals(parseReply(text), { kind: 'pause' }, text)
  for (const text of ['START', 'resume']) assertEquals(parseReply(text), { kind: 'resume' }, text)
  for (const text of ['done', 'Done!', 'ok', 'Got it', 'thanks', '👍', '✅']) assertEquals(parseReply(text), { kind: 'done' }, text)
})

Deno.test('ordinary messages are ignored', () => {
  for (const text of ['See you at 5', '500', 'what time is it', '', '   ', 'call mom tomorrow about the trip to Denver next week please']) {
    assertEquals(parseReply(text), null, text)
  }
})

Deno.test('opt-out phrases', () => {
  assertEquals(classifyOptOut("Please don't text me anymore"), 'optOut')
  assertEquals(classifyOptOut('stop by at 5 for coffee and bring the charger and the documents'), null)
  assertEquals(classifyOptOut('Opt-in'), 'optIn')
})

Deno.test('HELP and INFO ask for help', () => {
  for (const text of ['HELP', 'help', 'Help!', 'info']) assertEquals(parseReply(text), { kind: 'help' }, text)
  assertEquals(parseReply('help me move the couch'), null)
})
