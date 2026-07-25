import { useState } from 'react'
import { usePanels, useStore, useView } from '../lib/store'
import { getDevice } from '../lib/device'
import {
  COMFORT,
  analysePanel,
  auditPanel,
  devicePpd,
  diagonalForAngularWidth,
  fovFillingDiagonalIn,
  matchedSourceResolution,
} from '../lib/optics'
import { Card, Empty, NumberField, Segmented, Select, Slider, Stat, TextField, Toggle } from './ui'
import type { AnchorMode, PanelSource, StereoMode } from '../lib/types'
import { anchorLabel } from '../lib/project'

const SOURCES: { value: PanelSource; label: string }[] = [
  { value: 'usb-c-display', label: 'USB-C display' },
  { value: 'cast', label: 'Cast / mirror' },
  { value: 'browser', label: 'Browser' },
  { value: 'video', label: 'Video' },
  { value: 'game', label: 'Game' },
  { value: 'widget', label: 'Widget' },
  { value: 'camera', label: 'Camera passthrough' },
]

const ASPECTS = [
  { value: 16 / 9, label: '16:9' },
  { value: 16 / 10, label: '16:10' },
  { value: 3 / 2, label: '3:2' },
  { value: 4 / 3, label: '4:3' },
  { value: 21 / 9, label: '21:9 ultrawide' },
  { value: 32 / 9, label: '32:9 super ultrawide' },
  { value: 9 / 16, label: '9:16 portrait' },
]

const RESOLUTIONS = [
  { w: 960, h: 540, label: '960×540' },
  { w: 1280, h: 720, label: '1280×720' },
  { w: 1600, h: 900, label: '1600×900' },
  { w: 1920, h: 1080, label: '1920×1080' },
  { w: 2560, h: 1440, label: '2560×1440' },
  { w: 3840, h: 2160, label: '3840×2160' },
]

/**
 * The standard list, plus whatever the panel is currently set to and the
 * size-matched suggestion — otherwise a matched non-standard resolution would
 * make the dropdown look empty.
 */
function resolutionOptions(
  currentW: number,
  currentH: number,
  matched: { width: number; height: number },
) {
  const seen = new Map<string, string>()
  for (const r of RESOLUTIONS) seen.set(`${r.w}x${r.h}`, r.label)
  seen.set(`${matched.width}x${matched.height}`, `${matched.width}×${matched.height} · matched`)
  const cur = `${currentW}x${currentH}`
  if (!seen.has(cur)) seen.set(cur, `${currentW}×${currentH}`)
  return [...seen.entries()]
    .map(([value, label]) => ({ value, label, w: Number(value.split('x')[0]) }))
    .sort((a, b) => a.w - b.w)
    .map(({ value, label }) => ({ value, label }))
}

export function PanelInspector() {
  const selectedId = useStore((s) => s.selectedPanelId)
  const panels = usePanels()
  const deviceId = useStore((s) => s.profile.deviceId)
  const update = useStore((s) => s.updatePanel)
  const setDistance = useStore((s) => s.setPanelDistance)
  const remove = useStore((s) => s.deletePanel)
  const duplicate = useStore((s) => s.duplicatePanel)
  const view = useView()
  const focusPanel = useStore((s) => s.focusPanel)

  const [lockApparent, setLockApparent] = useState(true)

  const panel = panels.find((p) => p.id === selectedId)
  const device = getDevice(deviceId)

  if (!panel) {
    return (
      <Card title="Panel">
        <Empty>
          Select a panel in either preview, or from the panel list, to edit its
          placement and size.
        </Empty>
      </Card>
    )
  }

  const a = analysePanel(panel, device)
  const ppd = devicePpd(device)
  const advisories = auditPanel(panel, device)
  const fillDiagonal = fovFillingDiagonalIn(device, panel.distanceM)
  const isFocused = view?.focusedPanelId === panel.id
  const matched = matchedSourceResolution(a.angularWidthDeg, panel.aspect, device)
  // Within a couple of percent counts as matched; exact equality would leave the
  // suggestion button showing forever after any small nudge of the size slider.
  const sourceIsMatched = Math.abs(panel.sourceWidthPx - matched.width) <= matched.width * 0.03

  const sharpTone =
    a.sharpness >= COMFORT.softSharpness && a.sharpness <= COMFORT.upscaleSharpness
      ? 'good'
      : a.sharpness < 0.5
        ? 'danger'
        : 'warn'

  return (
    <div className="space-y-3">
      <Card
        title="Panel"
        right={
          <div className="flex items-center gap-1">
            {!isFocused && (
              <button className="btn btn-sm" onClick={() => focusPanel(panel.id)}>
                Focus
              </button>
            )}
            <button className="btn btn-sm" onClick={() => duplicate(panel.id)}>
              Duplicate
            </button>
            <button
              className="btn btn-sm btn-danger"
              onClick={() => remove(panel.id)}
              title="Delete this panel from the workspace"
            >
              Delete
            </button>
          </div>
        }
      >
        <div className="space-y-3">
          <div className="grid grid-cols-2 gap-2">
            <TextField
              label="Title"
              value={panel.title}
              onChange={(title) => update(panel.id, { title })}
            />
            <label className="block">
              <span className="label">Accent</span>
              <input
                type="color"
                className="input mt-1 h-[30px] cursor-pointer p-0.5"
                value={panel.color}
                onChange={(e) => update(panel.id, { color: e.target.value })}
              />
            </label>
          </div>

          <Select
            label="Source"
            value={panel.source}
            options={SOURCES}
            onChange={(source) => update(panel.id, { source })}
          />
          <TextField
            label="Detail"
            placeholder="URL, app name, input label…"
            value={panel.detail ?? ''}
            onChange={(detail) => update(panel.id, { detail })}
          />
        </div>
      </Card>

      {/* ------------------------------------------------------------------ */}
      <Card title="Distance & size">
        <div className="space-y-3">
          <Slider
            label="Distance"
            value={panel.distanceM}
            min={0.5}
            max={COMFORT.maxDistanceM}
            step={0.1}
            unit=" m"
            format={(v) => v.toFixed(1)}
            onChange={(v) => setDistance(panel.id, v, lockApparent)}
            hint={
              panel.distanceM < COMFORT.minDistanceM
                ? 'Closer than the comfort floor — these are fixed-focus displays, so near screens cause strain.'
                : `Comfort band is ${COMFORT.idealDistanceM[0]}–${COMFORT.idealDistanceM[1]} m.`
            }
          />

          <Toggle
            label="Lock apparent size while moving"
            checked={lockApparent}
            onChange={setLockApparent}
            hint="Scales the diagonal with the distance so the screen looks identical, just further away. This is almost always what you want — it is the whole trick behind quoting a big inch count."
          />

          <Slider
            label="Diagonal"
            value={panel.diagonalIn}
            min={10}
            max={Math.max(320, Math.ceil(fillDiagonal * 1.6))}
            step={1}
            unit='"'
            onChange={(diagonalIn) => update(panel.id, { diagonalIn })}
            hint={
              <>
                {fillDiagonal.toFixed(0)}" would exactly fill the field of view at{' '}
                {panel.distanceM.toFixed(1)} m.
              </>
            }
          />

          <div className="flex flex-wrap gap-1.5">
            <button
              className="btn btn-sm"
              onClick={() =>
                update(panel.id, { diagonalIn: Number(fillDiagonal.toFixed(1)) })
              }
              title="Size the panel so its diagonal exactly matches the field of view"
            >
              Fill FOV
            </button>
            <button
              className="btn btn-sm"
              onClick={() =>
                update(panel.id, {
                  diagonalIn: Number(
                    diagonalForAngularWidth(
                      ppd.fov.horizontalDeg,
                      panel.distanceM,
                      panel.aspect,
                    ).toFixed(1),
                  ),
                })
              }
              title="Match the source resolution 1:1 against the display — the sharpest a panel can be"
            >
              Pixel-perfect
            </button>
            <button
              className="btn btn-sm"
              onClick={() =>
                update(panel.id, {
                  diagonalIn: Number(
                    diagonalForAngularWidth(24, panel.distanceM, panel.aspect).toFixed(1),
                  ),
                })
              }
              title="A comfortable reading size that leaves room for other panels"
            >
              Reading size
            </button>
            {panel.distanceM < COMFORT.minDistanceM && (
              <button
                className="btn btn-sm btn-primary"
                onClick={() => setDistance(panel.id, COMFORT.idealDistanceM[0], true)}
              >
                Move to comfort
              </button>
            )}
          </div>

          <div className="grid grid-cols-2 gap-2">
            <Select
              label="Aspect"
              value={panel.aspect}
              options={ASPECTS}
              onChange={(aspect) => update(panel.id, { aspect })}
            />
            <Select
              label="Source resolution"
              value={`${panel.sourceWidthPx}x${panel.sourceHeightPx}`}
              options={resolutionOptions(panel.sourceWidthPx, panel.sourceHeightPx, matched)}
              onChange={(v) => {
                const [w, h] = String(v).split('x').map(Number)
                if (w && h) update(panel.id, { sourceWidthPx: w, sourceHeightPx: h })
              }}
              hint="What the host renders into this panel."
            />
          </div>

          {!sourceIsMatched && (
            <button
              className="btn btn-sm w-full"
              onClick={() =>
                update(panel.id, {
                  sourceWidthPx: matched.width,
                  sourceHeightPx: matched.height,
                })
              }
              title="Set the source resolution to exactly what this panel's angular size can resolve — less data and a sharper result"
            >
              Match source to size · {matched.width}×{matched.height}
            </button>
          )}
        </div>
      </Card>

      {/* ------------------------------------------------------------------ */}
      <Card title="Placement">
        <div className="space-y-3">
          <Slider
            label="Yaw · left / right"
            value={panel.yawDeg}
            min={-90}
            max={90}
            step={0.5}
            unit="°"
            format={(v) => (v > 0 ? `+${v.toFixed(1)}` : v.toFixed(1))}
            onChange={(yawDeg) => update(panel.id, { yawDeg })}
            hint={
              Math.abs(panel.yawDeg) > COMFORT.comfortableYawDeg
                ? 'Beyond about 30° you turn your neck rather than your eyes.'
                : undefined
            }
          />
          <Slider
            label="Pitch · up / down"
            value={panel.pitchDeg}
            min={-45}
            max={45}
            step={0.5}
            unit="°"
            format={(v) => (v > 0 ? `+${v.toFixed(1)}` : v.toFixed(1))}
            onChange={(pitchDeg) => update(panel.id, { pitchDeg })}
            hint={
              panel.pitchDeg > COMFORT.maxComfortablePitchUpDeg
                ? 'Sustained upward gaze tires faster than looking down.'
                : undefined
            }
          />
          <Slider
            label="Roll"
            value={panel.rollDeg}
            min={-45}
            max={45}
            step={0.5}
            unit="°"
            onChange={(rollDeg) => update(panel.id, { rollDeg })}
          />
          <Slider
            label="Curvature"
            value={panel.curvatureDeg}
            min={0}
            max={Math.max(10, Math.round(a.angularWidthDeg))}
            step={1}
            unit="° of arc"
            onChange={(curvatureDeg) => update(panel.id, { curvatureDeg })}
            hint="Wraps the panel around you at its own distance. Matching the panel's angular width makes it fully cylindrical, which keeps every part of a wide screen the same distance from your eye."
          />

          <div>
            <span className="label">Anchor</span>
            <div className="mt-1">
              <Segmented<AnchorMode>
                value={panel.anchor}
                options={[
                  { value: 'head', label: 'Head', title: 'Rigidly attached — always in view' },
                  { value: 'body', label: 'Body', title: 'Follows head yaw with lag' },
                  { value: 'world', label: 'World', title: 'Holds its bearing in space' },
                ]}
                onChange={(anchor) => update(panel.id, { anchor })}
              />
            </div>
            <p className="mt-1 text-[11px] leading-snug text-ink-500">
              {panel.anchor === 'head'
                ? 'Stays put in your vision no matter where you look. Right for a HUD, wrong for anything you read.'
                : panel.anchor === 'body'
                  ? 'Holds still for small movements, then eases back into view. The best default for work surfaces.'
                  : `Holds its bearing when you look around. On a ${device.dof}DoF device this is orientation only — walk and it travels with you, with no parallax.`}
            </p>
          </div>

          <Toggle
            label="Face the wearer"
            checked={panel.faceWearer}
            onChange={(faceWearer) => update(panel.id, { faceWearer })}
            hint="Turns the panel toward you instead of leaving it parallel to straight-ahead. Off-axis panels look slanted and read blurrier without it."
          />
        </div>
      </Card>

      {/* ------------------------------------------------------------------ */}
      <Card title="Appearance">
        <div className="space-y-3">
          <Slider
            label="Opacity"
            value={panel.opacity}
            min={0.1}
            max={1}
            step={0.05}
            format={(v) => `${Math.round(v * 100)}%`}
            onChange={(opacity) => update(panel.id, { opacity })}
          />
          <Select
            label="Stereo"
            value={panel.stereo}
            options={[
              { value: 'mono' as StereoMode, label: 'Mono (2D)' },
              { value: 'sbs-half' as StereoMode, label: 'Side-by-side, half width' },
              { value: 'sbs-full' as StereoMode, label: 'Side-by-side, full width (3840×1080)' },
              { value: 'anaglyph' as StereoMode, label: 'Anaglyph' },
            ]}
            onChange={(stereo) => update(panel.id, { stereo })}
            hint="Stereo comes from the signal the host sends, not from an SDK call."
          />
          <div className="grid grid-cols-2 gap-2">
            <NumberField
              label="Z-order"
              value={panel.zOrder}
              onChange={(zOrder) => update(panel.id, { zOrder })}
            />
            <div className="space-y-1.5 pt-4">
              <Toggle
                label="Visible"
                checked={panel.visible}
                onChange={(visible) => update(panel.id, { visible })}
              />
              <Toggle
                label="Locked"
                checked={panel.locked}
                onChange={(locked) => update(panel.id, { locked })}
              />
            </div>
          </div>
          <Toggle
            label="Dim when not focused"
            checked={panel.dimWhenUnfocused}
            onChange={(dimWhenUnfocused) => update(panel.id, { dimWhenUnfocused })}
          />
        </div>
      </Card>

      {/* ------------------------------------------------------------------ */}
      <Card title="Analysis">
        <div className="grid grid-cols-2 gap-3">
          <Stat
            label="Apparent size"
            value={`${a.angularWidthDeg.toFixed(1)}° × ${a.angularHeightDeg.toFixed(1)}°`}
            sub={`${(a.fovCoverageW * 100).toFixed(0)}% of the visible width`}
            tone={a.exceedsFov ? 'warn' : 'neutral'}
            title="The angle the panel subtends. This, not the inch count, is what your eye responds to."
          />
          <Stat
            label="Sharpness"
            value={`${Math.round(a.sharpness * 100)}%`}
            sub={`${Math.round(a.displayPxAcross)} display px across ${panel.sourceWidthPx}`}
            tone={sharpTone}
            title="Display pixels available versus source pixels. 100% is pixel-for-pixel."
          />
          <Stat
            label="Effective density"
            value={`${a.effectivePpd.toFixed(1)} px/°`}
            sub={`device floor ${ppd.center.toFixed(1)} px/°`}
            title="Pixels per degree actually delivered to your eye on this panel."
          />
          <Stat
            label="Smallest legible text"
            value={Number.isFinite(a.minLegibleTextPx) ? `${Math.ceil(a.minLegibleTextPx)} px` : '—'}
            sub="in source pixels"
            tone={a.minLegibleTextPx > 24 ? 'warn' : 'good'}
            title="Roughly the smallest text height that stays comfortable to read at this size and distance."
          />
          <Stat
            label="Physical size"
            value={`${a.widthM.toFixed(2)} × ${a.heightM.toFixed(2)} m`}
            sub={`${panel.diagonalIn.toFixed(0)}" diagonal`}
          />
          <Stat label="Anchor" value={anchorLabel(panel.anchor)} sub={`${device.dof}DoF device`} />
        </div>

        {advisories.length > 0 && (
          <ul className="mt-3 space-y-1.5 border-t border-ink-800 pt-3">
            {advisories.map((ad) => (
              <li key={ad.id} className="text-[11px] leading-snug">
                <span
                  className={
                    ad.severity === 'warn'
                      ? 'text-[var(--color-warn)]'
                      : ad.severity === 'error'
                        ? 'text-[var(--color-danger)]'
                        : 'text-ink-300'
                  }
                >
                  {ad.title}
                </span>
                <span className="text-ink-500"> — {ad.detail}</span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  )
}
