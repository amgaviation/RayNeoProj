import { useStore, useView, useWorkspace } from '../lib/store'
import { Card, Empty, TextField, Toggle } from './ui'
import { getDevice } from '../lib/device'
import { analysePanel } from '../lib/optics'

/**
 * Views and quick switching.
 *
 * The switcher row is the feature this app exists for: hitting `1` should snap
 * the whole workspace to a different arrangement instantly. Everything here is
 * built so that jump is one keystroke, and so building the arrangement is a
 * matter of ticking panels rather than dragging them around again.
 */
export function ViewSwitcher() {
  const ws = useWorkspace()
  const view = useView()
  const selectView = useStore((s) => s.selectView)
  const addView = useStore((s) => s.addView)
  const updateView = useStore((s) => s.updateView)
  const deleteView = useStore((s) => s.deleteView)
  const duplicateView = useStore((s) => s.duplicateView)
  const togglePanel = useStore((s) => s.togglePanelInView)
  const focusPanel = useStore((s) => s.focusPanel)
  const selectPanel = useStore((s) => s.selectPanel)
  const deviceId = useStore((s) => s.profile.deviceId)
  const device = getDevice(deviceId)

  return (
    <div className="space-y-3">
      <Card
        title="Views"
        right={
          <button className="btn btn-sm" onClick={() => addView()}>
            + View
          </button>
        }
        bodyClass="p-2"
      >
        <div className="space-y-1">
          {ws.views.map((v, i) => {
            const active = v.id === view?.id
            const count = v.panelIds.length
            return (
              <button
                key={v.id}
                onClick={() => selectView(v.id)}
                className={`flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors ${
                  active ? 'bg-ink-700' : 'hover:bg-ink-800'
                }`}
              >
                <kbd
                  className={`num grid h-5 w-5 shrink-0 place-items-center rounded border text-[11px] ${
                    active
                      ? 'border-[var(--color-accent-dim)] bg-ink-850 text-[var(--color-accent-glow)]'
                      : 'border-ink-700 text-ink-500'
                  }`}
                >
                  {v.hotkey || i + 1}
                </kbd>
                <span className="min-w-0 flex-1">
                  <span
                    className={`block truncate text-[13px] leading-tight ${
                      active ? 'text-ink-100' : 'text-ink-300'
                    }`}
                  >
                    {v.name}
                  </span>
                  <span className="block truncate text-[11px] text-ink-500">
                    {count} panel{count === 1 ? '' : 's'}
                    {v.recenterOnEnter && ' · recentres'}
                  </span>
                </span>
              </button>
            )
          })}
          {ws.views.length === 0 && <Empty>No views yet.</Empty>}
        </div>
      </Card>

      {view && (
        <Card
          title="Edit view"
          right={
            <div className="flex gap-1">
              <button className="btn btn-sm" onClick={() => duplicateView(view.id)}>
                Duplicate
              </button>
              <button
                className="btn btn-sm btn-danger"
                onClick={() => deleteView(view.id)}
                disabled={ws.views.length <= 1}
                title={
                  ws.views.length <= 1
                    ? 'A workspace needs at least one view'
                    : 'Delete this view'
                }
              >
                Delete
              </button>
            </div>
          }
        >
          <div className="space-y-3">
            <div className="grid grid-cols-[1fr_72px] gap-2">
              <TextField
                label="Name"
                value={view.name}
                onChange={(name) => updateView(view.id, { name })}
              />
              <TextField
                label="Hotkey"
                value={view.hotkey ?? ''}
                onChange={(hotkey) => updateView(view.id, { hotkey: hotkey.slice(0, 1) })}
              />
            </div>

            <Toggle
              label="Recentre on entering this view"
              checked={view.recenterOnEnter}
              onChange={(recenterOnEnter) => updateView(view.id, { recenterOnEnter })}
              hint="Calls ResetGlassQuat so the arrangement snaps to wherever you are looking. Good for a focus view you want in front of you regardless of how you were sitting."
            />

            <TextField
              label="Notes"
              placeholder="What is this view for?"
              value={view.notes ?? ''}
              onChange={(notes) => updateView(view.id, { notes })}
            />

            <div>
              <span className="label">Panels in this view</span>
              <div className="mt-1.5 space-y-1">
                {ws.panels.map((p) => {
                  const on = view.panelIds.includes(p.id)
                  const focused = view.focusedPanelId === p.id
                  const a = analysePanel(p, device)
                  return (
                    <div
                      key={p.id}
                      className={`flex items-center gap-2 rounded-md border px-2 py-1.5 ${
                        on ? 'border-ink-700 bg-ink-850' : 'border-transparent opacity-55'
                      }`}
                    >
                      <input
                        type="checkbox"
                        checked={on}
                        onChange={() => togglePanel(view.id, p.id)}
                        aria-label={`Include ${p.title}`}
                      />
                      <span
                        className="h-3 w-3 shrink-0 rounded-sm"
                        style={{ background: p.color }}
                      />
                      <button
                        className="min-w-0 flex-1 text-left"
                        onClick={() => selectPanel(p.id)}
                      >
                        <span className="block truncate text-[12.5px] leading-tight text-ink-200">
                          {p.title}
                        </span>
                        <span className="num block truncate text-[10.5px] text-ink-500">
                          {p.yawDeg > 0 ? '+' : ''}
                          {p.yawDeg.toFixed(0)}° · {p.distanceM.toFixed(1)} m ·{' '}
                          {a.angularWidthDeg.toFixed(0)}° wide
                        </span>
                      </button>
                      {on && (
                        <button
                          className={`btn btn-sm ${focused ? 'btn-primary' : 'btn-ghost'}`}
                          onClick={() => focusPanel(p.id)}
                          title="Give this panel input focus in this view"
                        >
                          {focused ? 'Focused' : 'Focus'}
                        </button>
                      )}
                    </div>
                  )
                })}
              </div>
            </div>
          </div>
        </Card>
      )}
    </div>
  )
}

/** Compact horizontal switcher for the top bar. */
export function ViewTabs() {
  const ws = useWorkspace()
  const view = useView()
  const selectView = useStore((s) => s.selectView)

  return (
    <div className="flex items-center gap-1 overflow-x-auto">
      {ws.views.map((v, i) => {
        const active = v.id === view?.id
        return (
          <button
            key={v.id}
            onClick={() => selectView(v.id)}
            title={v.notes ?? v.name}
            className={`flex shrink-0 items-center gap-1.5 rounded-md border px-2 py-1 text-[12.5px] transition-colors ${
              active
                ? 'border-[var(--color-accent-dim)] bg-[color-mix(in_oklab,var(--color-accent)_14%,var(--color-ink-800))] text-[var(--color-accent-glow)]'
                : 'border-ink-750 bg-ink-850 text-ink-400 hover:text-ink-100'
            }`}
          >
            <kbd className="num text-[10px] opacity-70">{v.hotkey || i + 1}</kbd>
            {v.name}
          </button>
        )
      })}
    </div>
  )
}
