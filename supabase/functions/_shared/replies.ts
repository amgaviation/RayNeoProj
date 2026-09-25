// Reads replies to reminder texts. Mirrors ReminderCore's ReplyParser and
// OptOutDetector (Swift) so the Mac relay and the server agree on commands;
// HELP is server-only, since carriers expect an answer to it.

export type ReplyCommand =
  | { kind: 'snooze'; minutes: number }
  | { kind: 'pause' }
  | { kind: 'resume' }
  | { kind: 'done' }
  | { kind: 'help' }

export const DEFAULT_SNOOZE_MINUTES = 10
export const MAX_SNOOZE_MINUTES = 24 * 60

const OPT_OUT_KEYWORDS = new Set([
  'STOP', 'STOPALL', 'STOP ALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT',
  'OPTOUT', 'OPT OUT', 'OPT-OUT', 'REVOKE', 'REMOVE', 'REMOVE ME',
])
const OPT_IN_KEYWORDS = new Set(['START', 'UNSTOP', 'SUBSCRIBE', 'RESUME', 'OPTIN', 'OPT IN', 'OPT-IN'])
const OPT_OUT_PHRASES = [
  'STOP TEXTING', 'STOP MESSAGING', 'STOP SENDING', 'STOP CONTACTING',
  'DONT TEXT', 'DO NOT TEXT', 'DONT MESSAGE', 'DO NOT MESSAGE',
  'UNSUBSCRIBE', 'OPT ME OUT', 'TAKE ME OFF', 'REMOVE ME FROM', 'NO MORE MESSAGES', 'NO MORE TEXTS',
]
const TRAILING_FILLERS = new Set(['PLEASE', 'PLS', 'NOW', 'THANKS', 'THANK YOU', 'THX', 'IT'])
const PAUSE_WORDS = new Set(['PAUSE', 'MUTE'])
const HELP_WORDS = new Set(['HELP', 'INFO'])
const DONE_WORDS = new Set([
  'DONE', 'DID IT', 'COMPLETED', 'COMPLETE', 'FINISHED', 'OK', 'OKAY', 'K', 'GOT IT', 'THANKS', 'THANK YOU', 'TY',
])
const DONE_SYMBOLS = new Set(['👍', '✅', '✔️', '👌'])

/** Uppercase, apostrophes removed, punctuation turned into spaces, spaces collapsed. */
export function normalize(text: string): string {
  let cleaned = ''
  for (const char of text.toUpperCase()) {
    if (char === "'" || char === '’' || char === '‘') continue
    if (char === '-' || /[\p{L}\p{N}]/u.test(char)) cleaned += char
    else cleaned += ' '
  }
  return cleaned.split(' ').filter(Boolean).join(' ')
}

export function classifyOptOut(text: string): 'optOut' | 'optIn' | null {
  const normalized = normalize(text)
  if (!normalized) return null
  if (OPT_OUT_KEYWORDS.has(normalized)) return 'optOut'
  if (OPT_IN_KEYWORDS.has(normalized)) return 'optIn'
  for (const keyword of OPT_OUT_KEYWORDS) {
    if (normalized.startsWith(keyword + ' ') && TRAILING_FILLERS.has(normalized.slice(keyword.length + 1))) return 'optOut'
  }
  for (const keyword of OPT_IN_KEYWORDS) {
    if (normalized.startsWith(keyword + ' ') && TRAILING_FILLERS.has(normalized.slice(keyword.length + 1))) return 'optIn'
  }
  if (normalized.length <= 80 && OPT_OUT_PHRASES.some((phrase) => normalized.includes(phrase))) return 'optOut'
  return null
}

export function parseReply(text: string): ReplyCommand | null {
  const trimmed = text.trim()
  if (!trimmed || [...trimmed].length > 60) return null
  if (DONE_SYMBOLS.has(trimmed)) return { kind: 'done' }

  const normalized = normalize(trimmed)
  if (!normalized) return null

  const minutes = snoozeMinutes(normalized)
  if (minutes !== null) return { kind: 'snooze', minutes }
  if (PAUSE_WORDS.has(normalized)) return { kind: 'pause' }
  if (HELP_WORDS.has(normalized)) return { kind: 'help' }
  const optOut = classifyOptOut(trimmed)
  if (optOut === 'optOut') return { kind: 'pause' }
  if (optOut === 'optIn') return { kind: 'resume' }
  if (DONE_WORDS.has(normalized)) return { kind: 'done' }
  return null
}

/** Minutes asked for by "SNOOZE", "SNOOZE 20", "LATER", "REMIND ME IN 2 HOURS" or "30 MIN". */
export function snoozeMinutes(normalized: string): number | null {
  let words = normalized.split(' ')
  let isCommand = false
  if (words[0] === 'SNOOZE' || words[0] === 'LATER') {
    words = words.slice(1)
    isCommand = true
  } else if (words[0] === 'REMIND' && words[1] === 'ME') {
    words = words.slice(2)
    if (words[0] === 'LATER') words = words.slice(1)
    isCommand = true
  }
  if (words[0] === 'IN' || words[0] === 'FOR') words = words.slice(1)

  if (words.length === 0) return isCommand ? DEFAULT_SNOOZE_MINUTES : null
  const minutes = duration(words)
  if (minutes === null) return isCommand ? DEFAULT_SNOOZE_MINUTES : null
  if (!isCommand && words.length === 1 && /^\d+$/.test(words[0]) && minutes > 240) return null
  return Math.min(Math.max(minutes, 1), MAX_SNOOZE_MINUTES)
}

function unitMinutes(word: string): number | null {
  if (['M', 'MIN', 'MINS', 'MINUTE', 'MINUTES'].includes(word)) return 1
  if (['H', 'HR', 'HRS', 'HOUR', 'HOURS'].includes(word)) return 60
  return null
}

export function duration(words: string[]): number | null {
  const text = words.join(' ')
  switch (text) {
    case 'AN HOUR': case 'A HOUR': case '1 HOUR': case 'ONE HOUR': return 60
    case 'HALF AN HOUR': case 'HALF HOUR': case 'HALF HR': return 30
    case 'A MINUTE': case 'A MIN': return 1
    case 'A FEW MINUTES': case 'A FEW MIN': case 'FEW MINUTES': case 'A BIT': case 'A WHILE': return DEFAULT_SNOOZE_MINUTES
  }
  let total = 0
  let pending: number | null = null
  let sawAny = false
  for (const word of words) {
    if (/^\d+$/.test(word)) {
      if (pending !== null) total += pending
      pending = parseInt(word, 10)
      sawAny = true
      continue
    }
    const combined = /^(\d+)([A-Z]+)$/.exec(word)
    if (combined) {
      const unit = unitMinutes(combined[2])
      if (unit === null) return null
      total += parseInt(combined[1], 10) * unit
      sawAny = true
      continue
    }
    const unit = unitMinutes(word)
    if (unit !== null) {
      if (pending === null) return null
      total += pending * unit
      pending = null
      continue
    }
    return null
  }
  if (pending !== null) total += pending
  return sawAny && total > 0 ? total : null
}
