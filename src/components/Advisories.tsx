import { useStore, useVisiblePanels } from '../lib/store'
import { getDevice } from '../lib/device'
import { auditView, devicePpd } from '../lib/optics'
import { Card, Stat } from './ui'
import { analysePanel } from '../lib/optics'

/**
 * Live analysis of the current view.
 *
 * Deliberately opinionated: a configurator that lets you build an unreadable
 * workspace and says nothing is not much of a configurator. Every warning names
 * the physical reason it is complaining, so it can be argued with rather than
 * just obeyed.
 */
export function Advisories() {
  const deviceId = useStore((s) => s.profile.deviceId)
  const visible = useVisiblePanels()
  const selectPanel = useStore((s) => s.selectPanel)
  const device = getDevice(deviceId)
  const ppd = devicePpd(device)

  const advisories = auditView(visible, device)
  const warns = advisories.filter((a) => a.severity !== 'info')
  const infos = advisories.filter((a) => a.severity === 'info')

  const coverage = visible.reduce((sum, p) => {
    const a = analysePanel(p, device)
    return sum + a.angularWidthDeg * a.angularHeightDeg
  }, 0)
  const fovArea = ppd.fov.horizontalDeg * ppd.fov.verticalDeg

  const spread = visible.length
    ? Math.max(...visible.map((p) => p.yawDeg)) - Math.min(...visible.map((p) => p.yawDeg))
    : 0

  // Seeded with the first panel rather than a sentinel, so the label names a
  // real panel even when nothing is below par.
  const worst = visible
    .map((p) => ({ sharpness: analysePanel(p, device).sharpness, title: p.title }))
    .reduce<{ sharpness: number; title: string } | undefined>(
      (acc, cur) => (!acc || cur.sharpness < acc.sharpness ? cur : acc),
      undefined,
    ) ?? { sharpness: 1, title: '—' }

  const distances = visible.map((p) => p.distanceM)
  const distinctDistances = new Set(distances.map((d) => d.toFixed(1))).size

  return (
    <div className="space-y-3">
      <Card title="This view">
        <div className="grid grid-cols-2 gap-3">
          <Stat label="Panels" value={visible.length} sub={`${spread.toFixed(0)}° spread`} />
          <Stat
            label="Coverage"
            value={`${(coverage / fovArea).toFixed(1)}× FOV`}
            sub={coverage / fovArea > 2 ? 'needs head turns' : 'glanceable'}
            tone={coverage / fovArea > 3 ? 'warn' : 'neutral'}
            title="Combined angular area of every panel, against the area the glasses can show at once."
          />
          <Stat
            label="Softest"
            value={`${Math.round(worst.sharpness * 100)}%`}
            sub={worst.title}
            tone={worst.sharpness < 0.5 ? 'danger' : worst.sharpness < 0.75 ? 'warn' : 'good'}
            title="The least sharp panel here: display pixels available versus source pixels."
          />
          <Stat
            label="Distances"
            value={distinctDistances}
            sub={distinctDistances > 1 ? 'eyes re-converge' : 'single focal plane'}
            tone={distinctDistances > 2 ? 'warn' : 'good'}
            title="Panels at different distances force your eyes to re-converge every time you switch. One shared distance is calmer."
          />
        </div>
      </Card>

      {(warns.length > 0 || infos.length > 0) && (
        <Card title={`Advisories · ${advisories.length}`} bodyClass="p-2">
          <ul className="space-y-1.5">
            {[...warns, ...infos].map((a) => (
              <li key={a.id}>
                <button
                  className="w-full rounded-md px-2 py-1.5 text-left hover:bg-ink-800"
                  onClick={() => a.panelId && selectPanel(a.panelId)}
                  disabled={!a.panelId}
                >
                  <span className="flex items-start gap-1.5">
                    <span
                      className={`mt-[3px] h-1.5 w-1.5 shrink-0 rounded-full ${
                        a.severity === 'error'
                          ? 'bg-[var(--color-danger)]'
                          : a.severity === 'warn'
                            ? 'bg-[var(--color-warn)]'
                            : 'bg-ink-500'
                      }`}
                    />
                    <span className="min-w-0">
                      <span className="block text-[12px] leading-tight text-ink-200">
                        {a.title}
                      </span>
                      <span className="mt-0.5 block text-[11px] leading-snug text-ink-500">
                        {a.detail}
                      </span>
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </Card>
      )}

      {advisories.length === 0 && (
        <Card title="Advisories">
          <p className="py-2 text-center text-[12px] text-[var(--color-good)]">
            Nothing to flag — this view is inside every comfort and sharpness threshold.
          </p>
        </Card>
      )}
    </div>
  )
}
