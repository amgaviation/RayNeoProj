// Texts BlueNudge sends on its own, worded for carrier (CTIA) rules: who is
// texting, how often, that rates may apply, and how to get help or opt out.

/** Sent once, when texts are first turned on for an account. */
export const WELCOME_TEXT =
  "BlueNudge: You're set up to get your reminders by text at this number. Msg frequency varies with your reminders. " +
  'Msg & data rates may apply. Reply HELP for help, STOP to opt out.'

/** The answer to HELP unless SMS_HELP_TEXT says otherwise. */
export const DEFAULT_HELP_TEXT =
  'BlueNudge: texts of the reminders you set up in the BlueNudge app. Reply SNOOZE to get the last one again, ' +
  'STOP to opt out, START to resume. Msg & data rates may apply.'

/**
 * SMS_HELP_TEXT: empty for the default, "off" when the SMS provider already
 * answers HELP (so people don't get two answers), or your own text, ideally
 * with a support contact.
 */
export function helpTextFromEnv(value: string | undefined): string | null {
  const text = value?.trim() ?? ''
  if (text.toLowerCase() === 'off') return null
  return text || DEFAULT_HELP_TEXT
}
