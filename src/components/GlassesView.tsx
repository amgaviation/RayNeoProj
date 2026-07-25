import { useMemo } from 'react'
import { useStore, useView, useVisiblePanels } from '../lib/store'
import { getDevice } from '../lib/device'
import { analysePanel, devicePpd } from '../lib/optics'
import { projectPanel } from '../lib/project'
import type { Projected } from '../lib/project'
import type { Panel } from '../lib/types'

/**
 * Through-the-glasses preview.
 *
 * Deliberately not a 3D scene: this is the exact rectilinear projection the
 * headset performs, so the viewport rectangle *is* the field of view. If a panel
 * touches the border here, it touches the border on the device. Panels are drawn
 * as polygons rather than rectangles so off-axis foreshortening shows up
 * honestly — a screen 35° to the side really is a trapezoid.
 *
 * Panels are drawn twice: faintly outside the FOV rectangle, then at full
 * strength clipped to it. The faint pass is what makes an off-screen panel
 * findable — a workspace that spreads past 41° has content you have to turn to
 * see, and the preview should show where it went rather than silently dropping
 * it.
 */
export function GlassesView({ compact = false }: { compact?: boolean }) {
  const profile = useStore((s) => s.profile)
  const pose = useStore((s) => s.pose)
  const view = useView()
  const visible = useVisiblePanels()
  const selectedId = useStore((s) => s.selectedPanelId)
  const selectPanel = useStore((s) => s.selectPanel)
  const focusPanel = useStore((s) => s.focusPanel)

  const device = getDevice(profile.deviceId)
  const ppd = devicePpd(device)
  const fov = ppd.fov

  // The SVG viewport is the display's own pixel grid, so distances read in the
  // same units a developer would use in Unity.
  const W = device.panelWidthPx
  const H = device.panelHeightPx

  // Margin around the FOV rectangle, where off-screen panels are shown. Wide
  // enough to be informative, tight enough that the FOV stays dominant.
  const MX = 0.17
  const MY = 0.2

  const toPx = (p: { x: number; y: number }) => ({
    x: (p.x * 0.5 + 0.5) * W,
    // SVG y grows downward; the projection has y up.
    y: (0.5 - p.y * 0.5) * H,
  })

  const pathOf = (proj: Projected) => {
    const pts = proj.points.map(toPx)
    return `M ${pts.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' L ')} Z`
  }

  const drawn = useMemo(() => {
    return visible
      .map((panel) => ({
        panel,
        proj: projectPanel(panel, pose, fov, panel.curvatureDeg > 0 ? 16 : 2),
        analysis: analysePanel(panel, device),
      }))
      .sort((a, b) => {
        // Nearer panels and higher z-order paint last.
        if (a.panel.zOrder !== b.panel.zOrder) return a.panel.zOrder - b.panel.zOrder
        return b.proj.depth - a.proj.depth
      })
  }, [visible, pose, fov, device])

  const focusedId = view?.focusedPanelId
  const dimFactor = profile.focusMode ? 0.18 : 0.4

  return (
    <div className="relative h-full w-full overflow-hidden bg-ink-950">
      <svg
        viewBox={`${-W * MX} ${-H * MY} ${W * (1 + MX * 2)} ${H * (1 + MY * 2)}`}
        className="h-full w-full"
        role="img"
        aria-label="Through-the-glasses preview"
      >
        <defs>
          <clipPath id="gv-fov">
            <rect x={0} y={0} width={W} height={H} rx={10} />
          </clipPath>
          {/* The world seen through the lenses. */}
          <linearGradient id="gv-world" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#1b2430" />
            <stop offset="55%" stopColor="#141b25" />
            <stop offset="100%" stopColor="#0d1219" />
          </linearGradient>
        </defs>

        <rect
          x={-W * MX}
          y={-H * MY}
          width={W * (1 + MX * 2)}
          height={H * (1 + MY * 2)}
          fill="#06080c"
        />

        {/* --- peripheral pass: where everything is, including what you cannot
            currently see. Unclipped and faint. --- */}
        <g opacity={0.3}>
          {drawn.map(({ panel, proj }) =>
            proj.clipped ? null : (
              <path
                key={`periph-${panel.id}`}
                d={pathOf(proj)}
                fill={panel.color}
                fillOpacity={0.05}
                stroke={panel.color}
                strokeWidth={2}
                strokeDasharray="10 9"
              />
            ),
          )}
        </g>

        {/* Panels beyond even the margin get a marker pinned to the edge, so
            there is always some hint of which way to turn. */}
        {drawn.map(({ panel, proj }) => {
          const c = toPx(proj.centre)
          const outX = c.x < -W * MX || c.x > W * (1 + MX)
          const outY = c.y < -H * MY || c.y > H * (1 + MY)
          if (!outX && !outY && !proj.clipped) return null
          const cx = Math.max(-W * (MX - 0.03), Math.min(W * (1 + MX - 0.03), c.x))
          const cy = Math.max(-H * (MY - 0.04), Math.min(H * (1 + MY - 0.04), c.y))
          return (
            <g key={`edge-${panel.id}`} opacity={0.65}>
              <circle cx={cx} cy={cy} r={15} fill={panel.color} opacity={0.2} />
              <circle cx={cx} cy={cy} r={6} fill={panel.color} />
              <text
                x={cx}
                y={cy - 22}
                textAnchor="middle"
                fill="#6b7c90"
                fontSize={28}
                fontFamily="ui-monospace, monospace"
              >
                {panel.title}
                {proj.clipped ? ' (behind)' : ''}
              </text>
            </g>
          )
        })}

        {/* --- the field of view itself --- */}
        <g clipPath="url(#gv-fov)">
          <rect x={0} y={0} width={W} height={H} fill="url(#gv-world)" />
          {/* Electrochromic shade darkens what you see through the lenses. */}
          <rect
            x={0}
            y={0}
            width={W}
            height={H}
            fill="#000"
            opacity={profile.device.shade * 0.72}
          />

          <HorizonLines pose={pose} fov={fov} W={W} H={H} />

          {drawn.map(({ panel, proj, analysis }) => {
            if (proj.clipped) return null
            const isFocused = panel.id === focusedId
            const isSelected = panel.id === selectedId
            const dim = panel.dimWhenUnfocused && !isFocused ? dimFactor : 1
            const c = toPx(proj.centre)
            const d = pathOf(proj)
            return (
              <g
                key={panel.id}
                opacity={panel.opacity * dim}
                onClick={() => {
                  selectPanel(panel.id)
                  focusPanel(panel.id)
                }}
                className="cursor-pointer"
              >
                <path d={d} fill={panel.color} fillOpacity={0.14} />
                <path
                  d={d}
                  fill="none"
                  stroke={panel.color}
                  strokeWidth={isFocused || isSelected ? 5 : 2.5}
                  strokeDasharray={proj.fullyVisible ? undefined : '14 8'}
                />
                <PanelContent
                  panel={panel}
                  cx={c.x}
                  cy={c.y}
                  sharpness={analysis.sharpness}
                  angular={analysis.angularWidthDeg}
                />
              </g>
            )
          })}
        </g>

        {/* FOV border, on top so panels appear to be clipped by it. */}
        <rect
          x={0}
          y={0}
          width={W}
          height={H}
          rx={10}
          fill="none"
          stroke="#3d4a5a"
          strokeWidth={3}
        />

        {!compact && (
          <>
            <text
              x={0}
              y={-16}
              fill="#4d5c6e"
              fontSize={28}
              fontFamily="ui-monospace, monospace"
            >
              {fov.horizontalDeg.toFixed(1)}° × {fov.verticalDeg.toFixed(1)}° visible ·{' '}
              {W}×{H} per eye
            </text>
            <text
              x={W}
              y={-16}
              textAnchor="end"
              fill="#4d5c6e"
              fontSize={28}
              fontFamily="ui-monospace, monospace"
            >
              head {pose.yawDeg >= 0 ? '+' : ''}
              {pose.yawDeg.toFixed(1)}° / {pose.pitchDeg >= 0 ? '+' : ''}
              {pose.pitchDeg.toFixed(1)}°
            </text>
            <text
              x={W / 2}
              y={H + 40}
              textAnchor="middle"
              fill="#354251"
              fontSize={26}
              fontFamily="ui-monospace, monospace"
            >
              dashed outlines outside the box are panels you would have to turn to see
            </text>
          </>
        )}
      </svg>

      {visible.length === 0 && (
        <div className="pointer-events-none absolute inset-0 grid place-items-center">
          <p className="text-[12px] text-ink-500">
            No panels in this view. Add one, or enable one from the view list.
          </p>
        </div>
      )}
    </div>
  )
}

/**
 * Horizon and centre reticle.
 *
 * Placed by the same projection as the panels, so when the head pitches the
 * horizon moves exactly as far as the content does.
 */
function HorizonLines({
  pose,
  fov,
  W,
  H,
}: {
  pose: { yawDeg: number; pitchDeg: number }
  fov: { horizontalDeg: number; verticalDeg: number }
  W: number
  H: number
}) {
  const tanV = Math.tan((fov.verticalDeg * Math.PI) / 360)
  const horizonNdc = -Math.tan((pose.pitchDeg * Math.PI) / 180) / tanV
  const y = (0.5 - horizonNdc * 0.5) * H

  const ticks: number[] = []
  for (let a = -60; a <= 60; a += 10) ticks.push(a)
  const tanH = Math.tan((fov.horizontalDeg * Math.PI) / 360)

  return (
    <g>
      {y > -H && y < H * 2 && (
        <line x1={0} y1={y} x2={W} y2={y} stroke="#232c39" strokeWidth={2} />
      )}
      {ticks.map((a) => {
        const rel = ((a - pose.yawDeg + 540) % 360) - 180
        if (Math.abs(rel) > 80) return null
        const ndc = Math.tan((rel * Math.PI) / 180) / tanH
        if (Math.abs(ndc) > 1.05) return null
        const x = (ndc * 0.5 + 0.5) * W
        return (
          <g key={a}>
            <line x1={x} y1={y - 8} x2={x} y2={y + 8} stroke="#2b3543" strokeWidth={2} />
            <text
              x={x}
              y={y + 32}
              textAnchor="middle"
              fill="#354251"
              fontSize={22}
              fontFamily="ui-monospace, monospace"
            >
              {a}°
            </text>
          </g>
        )
      })}
      {/* Centre reticle: where you are actually pointed. */}
      <g stroke="#354251" strokeWidth={2} opacity={0.8}>
        <line x1={W / 2 - 14} y1={H / 2} x2={W / 2 - 5} y2={H / 2} />
        <line x1={W / 2 + 5} y1={H / 2} x2={W / 2 + 14} y2={H / 2} />
        <line x1={W / 2} y1={H / 2 - 14} x2={W / 2} y2={H / 2 - 5} />
        <line x1={W / 2} y1={H / 2 + 5} x2={W / 2} y2={H / 2 + 14} />
      </g>
    </g>
  )
}

/**
 * Mock content inside a panel.
 *
 * The text scale is tied to the panel's real angular size, so a panel that is
 * too small to read looks too small to read. That is the point of the preview —
 * a fixed-size label would hide the problem.
 */
function PanelContent({
  panel,
  cx,
  cy,
  sharpness,
  angular,
}: {
  panel: Panel
  cx: number
  cy: number
  sharpness: number
  angular: number
}) {
  const base = Math.max(12, angular * 2.0)
  const soft = sharpness < 0.75
  return (
    <g pointerEvents="none">
      <text
        x={cx}
        y={cy - base * 0.15}
        textAnchor="middle"
        fill="#e6ebf1"
        fontSize={base}
        fontWeight={600}
        opacity={soft ? 0.55 : 0.95}
        fontFamily="ui-sans-serif, system-ui, sans-serif"
      >
        {panel.title}
      </text>
      <text
        x={cx}
        y={cy + base * 0.9}
        textAnchor="middle"
        fill={panel.color}
        fontSize={base * 0.55}
        opacity={0.8}
        fontFamily="ui-monospace, monospace"
      >
        {panel.detail ?? panel.source}
      </text>
      <text
        x={cx}
        y={cy + base * 1.75}
        textAnchor="middle"
        fill="#6b7c90"
        fontSize={base * 0.45}
        fontFamily="ui-monospace, monospace"
      >
        {panel.distanceM.toFixed(1)} m · {panel.diagonalIn.toFixed(0)}" ·{' '}
        {Math.round(sharpness * 100)}%
      </text>
    </g>
  )
}
