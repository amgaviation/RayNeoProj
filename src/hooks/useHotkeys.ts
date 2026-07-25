import { useEffect } from 'react'
import { eventToTrigger, useStore } from '../lib/store'

/**
 * Make the profile's key bindings live in this window.
 *
 * Being able to rehearse view switching with the actual keys — before the
 * glasses are involved — is most of the value of editing bindings at all.
 *
 * Typing in a field must never fire an action, so anything focused on an input,
 * textarea, select or contenteditable is left alone.
 */
export function useHotkeys() {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null
      if (t) {
        const tag = t.tagName
        if (
          tag === 'INPUT' ||
          tag === 'TEXTAREA' ||
          tag === 'SELECT' ||
          t.isContentEditable
        ) {
          return
        }
      }
      // Leave browser and OS shortcuts alone.
      if (e.ctrlKey || e.metaKey) return

      const { profile, runAction } = useStore.getState()
      const trigger = eventToTrigger(e)
      const match = profile.bindings.find(
        (b) =>
          b.enabled &&
          b.kind === 'key' &&
          (b.trigger === trigger ||
            b.trigger.toLowerCase() === trigger.toLowerCase()),
      )
      if (!match) return
      e.preventDefault()
      runAction(match.action, match.arg)
    }

    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])
}
