import { useStore } from '../lib/store'
import { DEVICES, getDevice } from '../lib/device'
import { devicePpd } from '../lib/optics'
import { SDK_MAPPING, ipdMmToNormalised } from '../lib/bridge'
import { Card, Segmented, Select, Slider, Stat, Toggle } from './ui'
import type { StereoMode } from '../lib/types'

const LUMINANCE_LABELS = ['Dim', 'Low', 'Standard', 'Bright']

/**
 * Device settings.
 *
 * Each control is tagged with whether a real SDK call backs it. That distinction
 * matters: `SetLuminanceMode` genuinely changes the glasses, while refresh rate
 * is negotiated by the host's display driver and no amount of UI here will move
 * it. Hiding the difference would make the app feel more capable than it is.
 */
export function DeviceConsole() {
  const profile = useStore((s) => s.profile)
  const setDevice = useStore((s) => s.setDevice)
  const setDeviceId = useStore((s) => s.setDeviceId)
  const recenter = useStore((s) => s.recenter)
  const d = profile.device
  const device = getDevice(profile.deviceId)
  const ppd = devicePpd(device)

  const fovAfterTrim = device.fovDiagonalDeg - d.fovScale * 0.8

  return (
    <div className="space-y-3">
      <Card
        title="Hardware"
        right={
          <button className="btn btn-sm btn-primary" onClick={recenter} title="Press R">
            Recentre
          </button>
        }
      >
        <div className="space-y-3">
          <Select
            label="Target device"
            value={profile.deviceId}
            options={Object.values(DEVICES).map((x) => ({ value: x.id, label: x.name }))}
            onChange={setDeviceId}
          />
          <div className="grid grid-cols-2 gap-3">
            <Stat
              label="Per-eye panel"
              value={`${device.panelWidthPx}×${device.panelHeightPx}`}
              sub={`${device.hdr ? 'HDR10' : 'SDR'} · ${device.peakNits} nits peak`}
            />
            <Stat
              label="Field of view"
              value={`${device.fovDiagonalDeg}° diag`}
              sub={`${ppd.fov.horizontalDeg.toFixed(1)}° × ${ppd.fov.verticalDeg.toFixed(1)}°`}
            />
            <Stat
              label="On-axis density"
              value={`${ppd.center.toFixed(1)} px/°`}
              sub="20/20 needs ~60"
              tone="warn"
              title="Pixels per degree at the centre of vision — the sparsest point, and the honest sharpness figure."
            />
            <Stat
              label="Tracking"
              value={`${device.dof}DoF`}
              sub="orientation only"
              title="The Air series reports head orientation. There is no positional tracking, so no parallax."
            />
          </div>
          <ul className="space-y-1 border-t border-ink-800 pt-2">
            {device.notes.map((n) => (
              <li key={n} className="text-[11px] leading-snug text-ink-500">
                {n}
              </li>
            ))}
          </ul>
        </div>
      </Card>

      <Card title="Display">
        <div className="space-y-3">
          <div>
            <div className="flex items-baseline justify-between">
              <span className="label">Brightness</span>
              <span className="num text-[13px]">
                {LUMINANCE_LABELS[d.luminanceMode]}
                <span className="text-ink-400"> · mode {d.luminanceMode}</span>
              </span>
            </div>
            <div className="mt-1">
              <Segmented
                value={d.luminanceMode}
                options={LUMINANCE_LABELS.map((l, i) => ({ value: i, label: l }))}
                onChange={(v) => setDevice({ luminanceMode: v as 0 | 1 | 2 | 3 })}
              />
            </div>
            <SdkNote op="device.setLuminance" />
          </div>

          <Slider
            label="Interpupillary distance"
            value={d.ipdMm}
            min={device.ipdRangeMm[0]}
            max={device.ipdRangeMm[1]}
            step={0.5}
            unit=" mm"
            format={(v) => v.toFixed(1)}
            onChange={(ipdMm) => setDevice({ ipdMm })}
            hint={
              <>
                Sent to the SDK as a normalised{' '}
                <span className="num">
                  {ipdMmToNormalised(d.ipdMm, device.ipdRangeMm).toFixed(3)}
                </span>{' '}
                across the {device.ipdRangeMm[0]}–{device.ipdRangeMm[1]} mm range. Getting
                this wrong is the most common cause of doubled or eye-straining images.
              </>
            }
          />
          <SdkNote op="device.setIpd" />

          <Slider
            label="Field of view trim"
            value={d.fovScale}
            min={-10}
            max={10}
            step={1}
            format={(v) => (v === 0 ? 'neutral' : v > 0 ? `+${v} narrower` : `${v} wider`)}
            onChange={(fovScale) => setDevice({ fovScale })}
            hint={
              <>
                The SDK inverts the sign here — negative widens, positive narrows.
                Roughly {fovAfterTrim.toFixed(1)}° effective diagonal.
              </>
            }
          />
          <SdkNote op="device.changeFov" />

          <Toggle
            label="Show the SDK's FOV overlay"
            checked={d.fovControlView}
            onChange={(fovControlView) => setDevice({ fovControlView })}
            hint="Displays the SDK's own adjustment interface on the glasses."
          />
          <SdkNote op="device.fovControlView" />

          <div className="grid grid-cols-2 gap-2 border-t border-ink-800 pt-3">
            <Select
              label="Refresh rate"
              value={d.refreshRateHz}
              options={device.refreshRatesHz.map((hz) => ({
                value: hz as 60 | 90 | 120,
                label: `${hz} Hz`,
              }))}
              onChange={(refreshRateHz) => setDevice({ refreshRateHz })}
            />
            <Select
              label="Stereo output"
              value={d.stereo}
              options={[
                { value: 'mono' as StereoMode, label: 'Mono (2D)' },
                { value: 'sbs-half' as StereoMode, label: 'SBS half' },
                { value: 'sbs-full' as StereoMode, label: 'SBS full 3840×1080' },
                { value: 'anaglyph' as StereoMode, label: 'Anaglyph' },
              ]}
              onChange={(stereo) => setDevice({ stereo })}
            />
          </div>
          <p className="text-[11px] leading-snug text-ink-500">
            Both of these are properties of the signal the host sends over DisplayPort,
            not SDK calls. They are recorded in the profile so the companion can request
            the right mode.
          </p>

          <Toggle
            label="HDR10"
            checked={d.hdr}
            onChange={(hdr) => setDevice({ hdr })}
            hint={
              device.hdr
                ? 'Requires an HDR10 source and a host that passes it through untouched.'
                : 'This device does not support HDR.'
            }
          />
        </div>
      </Card>

      <Card title="Comfort">
        <div className="space-y-3">
          <Slider
            label="Electrochromic shade"
            value={d.shade}
            min={0}
            max={1}
            step={0.05}
            format={(v) =>
              v < 0.05 ? 'clear' : v > 0.95 ? 'blackout' : `${Math.round(v * 100)}%`
            }
            onChange={(shade) => setDevice({ shade })}
            hint="Darkens the lenses so the panels look richer. Keep it low when you need to see where you are walking."
          />
          <SdkNote op="device.setShade" />

          <Slider
            label="Body-follow deadzone"
            value={d.followDeadzoneDeg}
            min={0}
            max={40}
            step={1}
            unit="°"
            onChange={(followDeadzoneDeg) => setDevice({ followDeadzoneDeg })}
            hint="How far you can turn before body-anchored panels start following. Too small and the workspace feels like it is chasing you."
          />
          <Slider
            label="Body-follow lag"
            value={d.followLagS}
            min={0}
            max={2}
            step={0.05}
            unit=" s"
            format={(v) => v.toFixed(2)}
            onChange={(followLagS) => setDevice({ followLagS })}
            hint="Time constant for catching up. Longer is calmer; too long feels like dragging the panels through treacle."
          />
        </div>
      </Card>
    </div>
  )
}

/** Shows which SDK call, if any, a control resolves to. */
function SdkNote({ op }: { op: string }) {
  const m = SDK_MAPPING[op]
  if (!m) return null
  return (
    <p className="text-[10.5px] leading-snug text-ink-600">
      {m.native ? (
        <>
          <span className="text-[var(--color-good)]">SDK</span>{' '}
          <code className="num text-ink-400">{m.call}</code>
        </>
      ) : (
        <span className="text-[var(--color-warn)]">host-side</span>
      )}{' '}
      — {m.note}
    </p>
  )
}
