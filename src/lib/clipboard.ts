/**
 * Copying text, with fallbacks.
 *
 * `navigator.clipboard.writeText` fails in more situations than is obvious, and
 * a bare "clipboard access denied" is a dead end for the user — especially when
 * the thing they were copying was a diagnostic report meant to be sent onward.
 *
 * It can fail because the page is on a `file://` origin, because the document is
 * not focused, because the browser wants a permission the page never requested,
 * or — as happened here — because an Electron permission handler denied
 * `clipboard-write` while allow-listing something else.
 *
 * So: try the modern API, fall back to the legacy `execCommand` path (which
 * needs no permission but does need a real selection), and if both fail, say so
 * clearly enough that the caller can offer a download instead.
 */

export type CopyResult =
  | { ok: true; method: 'clipboard-api' | 'exec-command' }
  | { ok: false; reason: string }

export async function copyText(text: string): Promise<CopyResult> {
  // Preferred path. Requires a secure context and, usually, transient user
  // activation — so this must be called from a click handler.
  if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return { ok: true, method: 'clipboard-api' }
    } catch {
      // Fall through rather than surfacing this; the legacy path often works
      // where the async API does not.
    }
  }

  // Legacy path. Deprecated, but permission-free and still widely supported.
  try {
    const ta = document.createElement('textarea')
    ta.value = text
    // Keep it off-screen without using display:none or visibility:hidden, which
    // would make the selection impossible.
    ta.setAttribute('readonly', '')
    ta.style.position = 'fixed'
    ta.style.top = '0'
    ta.style.left = '-9999px'
    ta.style.opacity = '0'
    document.body.appendChild(ta)

    const previous = document.activeElement as HTMLElement | null
    ta.select()
    ta.setSelectionRange(0, text.length)
    const ok = document.execCommand('copy')
    document.body.removeChild(ta)
    previous?.focus?.()

    if (ok) return { ok: true, method: 'exec-command' }
    return { ok: false, reason: 'The browser refused the copy command.' }
  } catch (err) {
    return {
      ok: false,
      reason: err instanceof Error ? err.message : String(err),
    }
  }
}

/**
 * Save text as a file. Always available, and the right offer when copying fails —
 * a download needs no permission and no secure context.
 */
export function downloadText(filename: string, text: string, type = 'text/plain') {
  const blob = new Blob([text], { type })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}
