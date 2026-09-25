// Sends whatever texts are due. The database decides what's due and hands each
// row to exactly one sender (claim_due_texts); this just delivers and records.

import type { SendResult } from './sms.ts'

export interface OutboxRow {
  id: number
  user_id: string
  body: string
  title: string
  fire_at: string
}

export interface SenderDeps {
  claim(limit: number): Promise<OutboxRow[]>
  phones(userIds: string[]): Promise<Map<string, string>>
  send(to: string, body: string): Promise<SendResult>
  markResult(id: number, status: 'sent' | 'failed', providerId?: string, error?: string): Promise<void>
  pause(userId: string): Promise<void>
}

export interface SendSummary {
  claimed: number
  sent: number
  failed: number
}

export async function sendDueTexts(deps: SenderDeps, limit = 100): Promise<SendSummary> {
  const rows = await deps.claim(limit)
  const summary: SendSummary = { claimed: rows.length, sent: 0, failed: 0 }
  if (rows.length === 0) return summary

  const phones = await deps.phones([...new Set(rows.map((row) => row.user_id))])
  for (const row of rows) {
    const phone = phones.get(row.user_id)
    if (!phone) {
      await deps.markResult(row.id, 'failed', undefined, 'No verified phone number on the account.')
      summary.failed++
      continue
    }
    let result: SendResult
    try {
      result = await deps.send(phone, row.body)
    } catch (error) {
      result = { ok: false, error: error instanceof Error ? error.message : String(error) }
    }
    if (result.ok) {
      await deps.markResult(row.id, 'sent', result.id)
      summary.sent++
    } else {
      if (result.optedOut) {
        // The carrier blocks texts after STOP; mirror that so the app shows it.
        await deps.pause(row.user_id)
      }
      await deps.markResult(
        row.id,
        'failed',
        undefined,
        result.optedOut ? 'You replied STOP to BlueNudge. Reply START to turn texts back on.' : result.error,
      )
      summary.failed++
    }
  }
  return summary
}
