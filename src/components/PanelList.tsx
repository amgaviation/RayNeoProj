import { useStore, useView, useWorkspace } from '../lib/store'
import { getDevice } from '../lib/device'
import { COMFORT, analysePanel } from '../lib/optics'
import { LAYOUTS, type LayoutId } from '../lib/layouts'
import { Card, Empty, Slider, Toggle } from './ui'
import { findOrphanPanels } from '../lib/exporters'

/** Panel list plus the layout generators that arrange them. */
export function PanelList() {
  const ws = useWorkspace()
  const view = useView()
  const selectedId = useStore((s) => s.selectedPanelId)
  const selectPanel = useStore((s) => s.selectPanel)
  const addPanel = useStore((s) => s.addPanel)
  const update = useStore((s) => s.updatePanel)
  const deviceId = useStore((s) => s.profile.deviceId)
  const device = getDevice(deviceId)

  const inView = new Set(view?.panelIds ?? [])
  const orphans = findOrphanPanels(ws)

  return (
    <div className="space-y-3">
      <LayoutBar />

      <Card
        title={`Panels · ${ws.panels.length}`}
        right={
          <button className="btn btn-sm" onClick={() => addPanel()}>
            + Panel
          </button>
        }
        bodyClass="p-2"
      >
        <div className="space-y-1">
          {ws.panels.map((p) => {
            const a = analysePanel(p, device)
            const isSel = p.id === selectedId
            const shown = inView.has(p.id) && p.visible
            const bad =
              a.sharpness < 0.5 || p.distanceM < COMFORT.minDistanceM || a.exceedsFov
            return (
              <button
                key={p.id}
                onClick={() => selectPanel(p.id)}
                className={`flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors ${
                  isSel ? 'bg-ink-700' : 'hover:bg-ink-800'
                } ${shown ? '' : 'opacity-50'}`}
              >
                <span
                  className="h-3.5 w-3.5 shrink-0 rounded-sm"
                  style={{ background: p.color }}
                />
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-1.5">
                    <span className="truncate text-[13px] leading-tight text-ink-100">
                      {p.title}
                    </span>
                    {p.locked && (
                      <span className="text-[10px] text-ink-500" title="Locked — layouts skip it">
                        locked
                      </span>
                    )}
                    {bad && (
                      <span
                        className="text-[10px] text-[var(--color-warn)]"
                        title="This panel has a comfort or sharpness warning"
                      >
                        ⚠
                      </span>
                    )}
                  </span>
                  <span className="num block truncate text-[10.5px] text-ink-500">
                    {p.yawDeg > 0 ? '+' : ''}
                    {p.yawDeg.toFixed(0)}°/{p.pitchDeg > 0 ? '+' : ''}
                    {p.pitchDeg.toFixed(0)}° · {p.distanceM.toFixed(1)} m ·{' '}
                    {p.diagonalIn.toFixed(0)}" · {Math.round(a.sharpness * 100)}%
                  </span>
                </span>
                <span
                  role="button"
                  tabIndex={0}
                  className="btn btn-sm btn-ghost"
                  onClick={(e) => {
                    e.stopPropagation()
                    update(p.id, { visible: !p.visible })
                  }}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.stopPropagation()
                      update(p.id, { visible: !p.visible })
                    }
                  }}
                  title={p.visible ? 'Hide this panel' : 'Show this panel'}
                >
                  {p.visible ? '◉' : '○'}
                </span>
              </button>
            )
          })}
          {ws.panels.length === 0 && <Empty>No panels. Add one to get started.</Empty>}
        </div>

        {orphans.length > 0 && (
          <p className="mt-2 border-t border-ink-800 px-1 pt-2 text-[11px] leading-snug text-ink-500">
            {orphans.length} panel{orphans.length === 1 ? '' : 's'} (
            {orphans.map((o) => o.title).join(', ')}) belong to no view, so they will never
            appear. Tick them into a view or delete them.
          </p>
        )}
      </Card>
    </div>
  )
}

function LayoutBar() {
  const opts = useStore((s) => s.layoutOptions)
  const setOpts = useStore((s) => s.setLayoutOptions)
  const runLayout = useStore((s) => s.runLayout)
  const pullToComfort = useStore((s) => s.pullVisibleToComfort)
  const view = useView()
  const panelCount = view?.panelIds.length ?? 0

  return (
    <Card title="Arrange">
      <div className="space-y-3">
        <div className="grid grid-cols-3 gap-1.5">
          {LAYOUTS.map((l) => {
            const ok = panelCount >= l.minPanels
            return (
              <button
                key={l.id}
                className="btn btn-sm"
                disabled={!ok}
                title={
                  ok
                    ? l.description
                    : `${l.description}\n\nNeeds at least ${l.minPanels} panels in the view.`
                }
                onClick={() => runLayout(l.id as LayoutId)}
              >
                {l.name}
              </button>
            )
          })}
        </div>

        <p className="text-[11px] leading-snug text-ink-500">
          Layouts re-flow only the panels in the current view, and skip locked ones — so
          you can pin one screen and rearrange the rest around it.
        </p>

        <Slider
          label="Distance"
          value={opts.distanceM}
          min={1.5}
          max={12}
          step={0.5}
          unit=" m"
          format={(v) => v.toFixed(1)}
          onChange={(distanceM) => setOpts({ distanceM })}
          hint="Every generated panel lands at this distance, so your eyes never re-converge when switching between them."
        />
        <Slider
          label="Spread"
          value={opts.spreadDeg}
          min={20}
          max={180}
          step={5}
          unit="°"
          onChange={(spreadDeg) => setOpts({ spreadDeg })}
          hint="Total horizontal sweep. Past about 90° you are turning your head to reach the outer panels."
        />
        <div className="grid grid-cols-2 gap-2">
          <Slider
            label="Gap"
            value={opts.gapDeg}
            min={0}
            max={12}
            step={0.5}
            unit="°"
            format={(v) => v.toFixed(1)}
            onChange={(gapDeg) => setOpts({ gapDeg })}
          />
          <Slider
            label="Grid rows"
            value={opts.rows}
            min={1}
            max={4}
            step={1}
            onChange={(rows) => setOpts({ rows })}
          />
        </div>
        <Toggle
          label="Toe panels in toward you"
          checked={opts.toeIn}
          onChange={(toeIn) => setOpts({ toeIn })}
          hint="Turns each panel to face you. Without it, side panels are seen at a slant and their far edges read blurry."
        />

        <button className="btn w-full" onClick={pullToComfort}>
          Push everything past the comfort floor
        </button>
      </div>
    </Card>
  )
}
