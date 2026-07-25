/**
 * Layout generators.
 *
 * These place panels in angular space around the wearer. They deliberately work
 * in *angles*, not metres: the whole point of the arc layouts is that every
 * panel stays equidistant, so they all share one focal distance and your eyes
 * never have to re-converge when you switch between them.
 */

import type { Panel } from './types'
import {
  COMFORT,
  analysePanel,
  clamp,
  devicePpd,
  diagonalForAngularWidth,
} from './optics'
import type { DeviceProfile } from './types'

export type LayoutId = 'arc' | 'grid' | 'stack' | 'theater' | 'cockpit' | 'sidecar'

export interface LayoutSpec {
  id: LayoutId
  name: string
  description: string
  /** Minimum panels for the layout to make sense. */
  minPanels: number
}

export const LAYOUTS: LayoutSpec[] = [
  {
    id: 'arc',
    name: 'Arc',
    description:
      'Panels sweep left to right at one distance, so every screen is the same focal distance and the same size. The default for multitasking.',
    minPanels: 2,
  },
  {
    id: 'grid',
    name: 'Grid',
    description:
      'Rows and columns on a sphere. Fits more surfaces, at the cost of looking up and down.',
    minPanels: 2,
  },
  {
    id: 'stack',
    name: 'Stack',
    description:
      'All panels share one spot; only the focused one is opaque. Maximum sharpness, one thing at a time — switch with a key or gesture.',
    minPanels: 2,
  },
  {
    id: 'theater',
    name: 'Theater',
    description:
      'One panel scaled to fill the field of view at a cinema distance. Everything else is hidden.',
    minPanels: 1,
  },
  {
    id: 'cockpit',
    name: 'Cockpit',
    description:
      'A primary panel dead ahead with instrument strips below and to the sides, angled inward. Built for reference data you glance at.',
    minPanels: 3,
  },
  {
    id: 'sidecar',
    name: 'Sidecar',
    description:
      'One large primary panel with a narrow companion panel parked off to one side.',
    minPanels: 2,
  },
]

export interface LayoutOptions {
  /** Distance every generated panel is placed at, metres. */
  distanceM: number
  /** Total horizontal sweep for arc/grid, degrees. */
  spreadDeg: number
  /** Gap between neighbouring panels, degrees. */
  gapDeg: number
  /** Rows for the grid layout. */
  rows: number
  /** Angle panels inward to face the wearer. */
  toeIn: boolean
}

export const DEFAULT_LAYOUT_OPTIONS: LayoutOptions = {
  distanceM: 4,
  spreadDeg: 90,
  gapDeg: 2,
  rows: 2,
  toeIn: true,
}

/**
 * Size a panel so `count` of them tile a `spread` sweep without overlapping.
 * Returns the diagonal in inches at the given distance.
 */
function fitDiagonal(
  count: number,
  opts: LayoutOptions,
  aspect: number,
  device: DeviceProfile,
) {
  const fovWide = devicePpd(device).fov.horizontalDeg
  // Never make a tile wider than the FOV itself: past that you cannot see a
  // whole panel at once and the layout stops being a layout.
  const perPanel = clamp(opts.spreadDeg / count - opts.gapDeg, 4, fovWide)
  return diagonalForAngularWidth(perPanel, opts.distanceM, aspect)
}

/**
 * Apply a layout to a set of panels, returning updated copies.
 *
 * Locked panels are returned untouched so the wearer can pin one screen and
 * re-flow the rest around it.
 */
export function applyLayout(
  layout: LayoutId,
  panels: Panel[],
  opts: LayoutOptions,
  device: DeviceProfile,
): Panel[] {
  const movable = panels.filter((p) => !p.locked)
  const n = movable.length
  if (n === 0) return panels

  const updates = new Map<string, Partial<Panel>>()

  switch (layout) {
    case 'arc': {
      const diag = fitDiagonal(n, opts, movable[0]!.aspect, device)
      const step = n > 1 ? opts.spreadDeg / (n - 1) : 0
      const start = n > 1 ? -opts.spreadDeg / 2 : 0
      movable.forEach((p, i) => {
        const yaw = start + step * i
        updates.set(p.id, {
          yawDeg: Number(yaw.toFixed(2)),
          pitchDeg: 0,
          rollDeg: 0,
          distanceM: opts.distanceM,
          diagonalIn: Number(diag.toFixed(1)),
          opacity: 1,
          visible: true,
          zOrder: i,
        })
      })
      break
    }

    case 'grid': {
      const rows = Math.max(1, Math.min(opts.rows, n))
      const cols = Math.ceil(n / rows)
      const diag = fitDiagonal(cols, opts, movable[0]!.aspect, device)
      // Row spacing follows the panel's own angular height so rows never collide.
      const probe = analysePanel(
        { ...movable[0]!, diagonalIn: diag, distanceM: opts.distanceM },
        device,
      )
      const rowStep = probe.angularHeightDeg + opts.gapDeg
      const colStep = cols > 1 ? opts.spreadDeg / (cols - 1) : 0
      movable.forEach((p, i) => {
        const r = Math.floor(i / cols)
        const c = i % cols
        const rowsInThis = Math.min(cols, n - r * cols)
        const rowSpread = colStep * (rowsInThis - 1)
        updates.set(p.id, {
          yawDeg: Number((-rowSpread / 2 + colStep * c).toFixed(2)),
          // Bias the block downward: looking down is less fatiguing than up.
          pitchDeg: Number(
            (((rows - 1) / 2 - r) * rowStep - rowStep * 0.15).toFixed(2),
          ),
          rollDeg: 0,
          distanceM: opts.distanceM,
          diagonalIn: Number(diag.toFixed(1)),
          opacity: 1,
          visible: true,
          zOrder: i,
        })
      })
      break
    }

    case 'stack': {
      // One position, one size, focus decides what you see. Because every panel
      // sits dead ahead it gets the full FOV, which is the sharpest a panel can
      // possibly be on this hardware.
      const diag = diagonalForAngularWidth(
        Math.min(36, opts.spreadDeg),
        opts.distanceM,
        movable[0]!.aspect,
      )
      movable.forEach((p, i) => {
        updates.set(p.id, {
          yawDeg: 0,
          pitchDeg: 0,
          rollDeg: 0,
          distanceM: opts.distanceM,
          diagonalIn: Number(diag.toFixed(1)),
          visible: true,
          dimWhenUnfocused: true,
          opacity: i === 0 ? 1 : 0.25,
          zOrder: n - i,
        })
      })
      break
    }

    case 'theater': {
      const hero = movable[0]!
      const distance = Math.max(opts.distanceM, 5)
      movable.forEach((p, i) => {
        if (p.id === hero.id) {
          updates.set(p.id, {
            yawDeg: 0,
            // Cinema seating sits the screen slightly below eye line.
            pitchDeg: -2,
            rollDeg: 0,
            distanceM: distance,
            // 92% of the FOV: filling it exactly puts content in the corners
            // where the optics are softest and edge fade is visible.
            diagonalIn: Number(
              diagonalForAngularWidth(
                0.92 * devicePpd(device).fov.horizontalDeg,
                distance,
                p.aspect,
              ).toFixed(1),
            ),
            opacity: 1,
            visible: true,
            zOrder: 10,
          })
        } else {
          updates.set(p.id, { visible: false, zOrder: i })
        }
      })
      break
    }

    case 'cockpit': {
      // Primary ahead, instruments below and flanking — the layout that suits
      // glanceable reference data rather than reading.
      const primary = movable[0]!
      updates.set(primary.id, {
        yawDeg: 0,
        pitchDeg: 0,
        rollDeg: 0,
        distanceM: opts.distanceM,
        diagonalIn: Number(
          diagonalForAngularWidth(30, opts.distanceM, primary.aspect).toFixed(1),
        ),
        opacity: 1,
        visible: true,
        zOrder: 5,
      })
      const rest = movable.slice(1)
      const flankYaw = [-34, 34, -34, 34]
      rest.forEach((p, i) => {
        const isBelow = i === 0
        updates.set(p.id, {
          yawDeg: isBelow ? 0 : flankYaw[(i - 1) % flankYaw.length]!,
          pitchDeg: isBelow ? -20 : i > 2 ? -14 : 2,
          rollDeg: 0,
          distanceM: opts.distanceM,
          diagonalIn: Number(
            diagonalForAngularWidth(
              isBelow ? 26 : 18,
              opts.distanceM,
              p.aspect,
            ).toFixed(1),
          ),
          opacity: 0.92,
          visible: true,
          zOrder: i,
        })
      })
      break
    }

    case 'sidecar': {
      const primary = movable[0]!
      updates.set(primary.id, {
        yawDeg: -6,
        pitchDeg: 0,
        rollDeg: 0,
        distanceM: opts.distanceM,
        diagonalIn: Number(
          diagonalForAngularWidth(32, opts.distanceM, primary.aspect).toFixed(1),
        ),
        opacity: 1,
        visible: true,
        zOrder: 5,
      })
      movable.slice(1).forEach((p, i) => {
        updates.set(p.id, {
          yawDeg: 30 + i * 22,
          pitchDeg: 0,
          rollDeg: 0,
          distanceM: opts.distanceM,
          diagonalIn: Number(
            diagonalForAngularWidth(16, opts.distanceM, p.aspect).toFixed(1),
          ),
          opacity: 0.95,
          visible: true,
          zOrder: i,
        })
      })
      break
    }
  }

  return panels.map((p) => {
    const u = updates.get(p.id)
    if (!u) return p
    // Toe-in turns each panel to face the wearer rather than leaving it
    // parallel to the straight-ahead plane. Without it, off-axis panels are
    // seen at a slant: the far edge is foreshortened and reads blurrier.
    return { ...p, ...u, faceWearer: opts.toeIn }
  })
}

/** Push every visible panel to a comfortable distance without resizing apparently. */
export function pullToComfort(panels: Panel[], targetM?: number): Panel[] {
  const target = targetM ?? COMFORT.idealDistanceM[0]
  return panels.map((p) => {
    if (p.locked || !p.visible) return p
    if (p.distanceM >= COMFORT.minDistanceM) return p
    return {
      ...p,
      diagonalIn: Number((p.diagonalIn * (target / p.distanceM)).toFixed(1)),
      distanceM: target,
    }
  })
}
