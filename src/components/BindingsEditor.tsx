import { useStore } from '../lib/store'
import { Card, Empty } from './ui'
import type { ActionId, TriggerKind } from '../lib/types'

const ACTIONS: { value: ActionId; label: string; needsArg?: boolean }[] = [
  { value: 'view.next', label: 'Next view' },
  { value: 'view.prev', label: 'Previous view' },
  { value: 'view.byIndex', label: 'Jump to view #', needsArg: true },
  { value: 'panel.focusNext', label: 'Focus next panel' },
  { value: 'panel.focusPrev', label: 'Focus previous panel' },
  { value: 'panel.toggleVisible', label: 'Show/hide focused panel' },
  { value: 'panel.pullToComfort', label: 'Push panels to comfort distance' },
  { value: 'device.recenter', label: 'Recentre (ResetGlassQuat)' },
  { value: 'device.brightnessUp', label: 'Brightness up' },
  { value: 'device.brightnessDown', label: 'Brightness down' },
  { value: 'device.toggleShade', label: 'Toggle shade' },
  { value: 'workspace.toggleFocusMode', label: 'Toggle focus mode' },
]

const KINDS: { value: TriggerKind; label: string; hint: string }[] = [
  { value: 'key', label: 'Key', hint: 'Works right here in the browser.' },
  { value: 'touchpad', label: 'Touchpad', hint: 'Phone/host touch gesture.' },
  { value: 'headGesture', label: 'Head gesture', hint: 'Derived from the 3DoF tracker.' },
  { value: 'phoneButton', label: 'Phone button', hint: 'Hardware key on the host.' },
]

/**
 * Trigger bindings.
 *
 * Key bindings are live in this app — pressing the key does the thing, so you
 * can rehearse a switching workflow before ever putting the glasses on. The
 * other three kinds are recorded for the companion to implement, and labelled
 * as such rather than pretending the browser can see a head nod.
 */
export function BindingsEditor() {
  const bindings = useStore((s) => s.profile.bindings)
  const add = useStore((s) => s.addBinding)
  const update = useStore((s) => s.updateBinding)
  const remove = useStore((s) => s.deleteBinding)
  const run = useStore((s) => s.runAction)

  const grouped = KINDS.map((k) => ({
    ...k,
    items: bindings.filter((b) => b.kind === k.value),
  }))

  return (
    <div className="space-y-3">
      <Card
        title="Bindings"
        right={
          <button className="btn btn-sm" onClick={() => add()}>
            + Binding
          </button>
        }
        bodyClass="p-2"
      >
        {bindings.length === 0 && <Empty>No bindings yet.</Empty>}

        <div className="space-y-3">
          {grouped.map(
            (g) =>
              g.items.length > 0 && (
                <div key={g.value}>
                  <div className="flex items-baseline gap-2 px-1 pb-1">
                    <span className="label">{g.label}</span>
                    <span className="text-[10.5px] text-ink-600">{g.hint}</span>
                  </div>
                  <div className="space-y-1">
                    {g.items.map((b) => {
                      const action = ACTIONS.find((a) => a.value === b.action)
                      return (
                        <div
                          key={b.id}
                          className={`flex items-center gap-1.5 rounded-md border border-ink-800 bg-ink-850 px-1.5 py-1 ${
                            b.enabled ? '' : 'opacity-50'
                          }`}
                        >
                          <input
                            type="checkbox"
                            checked={b.enabled}
                            onChange={(e) => update(b.id, { enabled: e.target.checked })}
                            title="Enable this binding"
                          />
                          <input
                            className="input num w-24 shrink-0 px-1.5 py-0.5 text-[12px]"
                            value={b.trigger}
                            placeholder="trigger"
                            onChange={(e) => update(b.id, { trigger: e.target.value })}
                          />
                          <select
                            className="input min-w-0 flex-1 px-1.5 py-0.5 text-[12px]"
                            value={b.action}
                            onChange={(e) =>
                              update(b.id, { action: e.target.value as ActionId })
                            }
                          >
                            {ACTIONS.map((a) => (
                              <option key={a.value} value={a.value}>
                                {a.label}
                              </option>
                            ))}
                          </select>
                          {action?.needsArg && (
                            <input
                              className="input num w-11 shrink-0 px-1 py-0.5 text-[12px]"
                              type="number"
                              min={0}
                              value={Number(b.arg ?? 0)}
                              onChange={(e) => update(b.id, { arg: Number(e.target.value) })}
                              title="View index, starting at 0"
                            />
                          )}
                          <button
                            className="btn btn-sm btn-ghost"
                            title="Run this action now"
                            onClick={() => run(b.action, b.arg)}
                          >
                            ▶
                          </button>
                          <button
                            className="btn btn-sm btn-ghost"
                            title="Delete binding"
                            onClick={() => remove(b.id)}
                          >
                            ✕
                          </button>
                        </div>
                      )
                    })}
                  </div>
                </div>
              ),
          )}
        </div>
      </Card>

      <Card title="Live keys">
        <p className="text-[11.5px] leading-relaxed text-ink-400">
          Key bindings are active in this window, so you can practise a switching
          workflow before the glasses are anywhere near your face. Try{' '}
          <Kbd>1</Kbd>–<Kbd>4</Kbd> for views, <Kbd>Tab</Kbd> to walk the focus around,{' '}
          <Kbd>R</Kbd> to recentre, <Kbd>F</Kbd> for focus mode and{' '}
          <Kbd>[</Kbd>/<Kbd>]</Kbd> for brightness. Keys are ignored while you are typing
          in a field.
        </p>
        <p className="mt-2 text-[11.5px] leading-relaxed text-ink-500">
          Touchpad, head-gesture and phone-button triggers are recorded in the profile for
          the companion app to implement — a browser tab cannot see a head nod, so this
          app does not pretend to.
        </p>
      </Card>
    </div>
  )
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="num rounded border border-ink-700 bg-ink-850 px-1 py-px text-[11px] text-ink-200">
      {children}
    </kbd>
  )
}
