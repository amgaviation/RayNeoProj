// What to do with a reply from a subscriber: SNOOZE queues the last text again,
// STOP/START pause and resume (the carrier also enforces these), HELP says what
// the texts are, DONE is logged.

import { parseReply, type ReplyCommand } from './replies.ts'

export interface InboundDeps {
  userForPhone(phone: string): Promise<string | null>
  /** False when this provider message was already handled (webhook retry). */
  record(userId: string, from: string, body: string, command: string | null, providerId: string): Promise<boolean>
  setPaused(userId: string, paused: boolean): Promise<void>
  snooze(userId: string, minutes: number): Promise<{ fireAt: Date } | null>
  timeZone(userId: string): Promise<string>
  /** The answer to HELP, or null when the SMS provider answers it. */
  helpText: string | null
}

export interface InboundMessageInput {
  id: string
  from: string
  body: string
}

/** Returns the text to send back, or null for no reply. */
export async function handleReply(message: InboundMessageInput, deps: InboundDeps, now = new Date()): Promise<string | null> {
  const userId = await deps.userForPhone(message.from)
  if (!userId) return null
  const command = parseReply(message.body)
  const isNew = await deps.record(userId, message.from, message.body, command?.kind ?? null, message.id)
  if (!isNew || !command) return null
  return await apply(command, userId, deps, now)
}

async function apply(command: ReplyCommand, userId: string, deps: InboundDeps, now: Date): Promise<string | null> {
  switch (command.kind) {
    case 'pause':
      await deps.setPaused(userId, true)
      // The carrier sends its own STOP confirmation.
      return null
    case 'resume':
      await deps.setPaused(userId, false)
      return null
    case 'done':
      return null
    case 'help':
      return deps.helpText
    case 'snooze': {
      const snoozed = await deps.snooze(userId, command.minutes)
      if (!snoozed) return "There's nothing to snooze right now."
      return `Okay, I'll text you again ${whenPhrase(snoozed.fireAt, now, await deps.timeZone(userId))}.`
    }
  }
}

/** "at 9:40 AM", "tomorrow at 9:00 AM" or "on Fri, Oct 3 at 9:00 AM", in the user's time zone. */
export function whenPhrase(date: Date, now: Date, timeZone: string): string {
  const zone = safeZone(timeZone)
  const time = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', timeZone: zone }).format(date)
  const day = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: zone }).format(d)
  if (day(date) === day(now)) return `at ${time}`
  if (day(date) === day(new Date(now.getTime() + 86_400_000))) return `tomorrow at ${time}`
  const label = new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: zone }).format(date)
  return `on ${label} at ${time}`
}

function safeZone(timeZone: string): string {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone })
    return timeZone
  } catch {
    return 'UTC'
  }
}
