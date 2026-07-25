import { describe, expect, it } from 'vitest'
import { panelOutline, polar, projectPanel, toHeadSpace } from './project'
import { DEVICES } from './device'
import { devicePpd, panelSizeM } from './optics'
import type { Panel } from './types'

const air4 = DEVICES['air-4-pro']!
const fov = devicePpd(air4).fov
const level = { yawDeg: 0, pitchDeg: 0, rollDeg: 0 }

function panel(over: Partial<Panel> = {}): Panel {
  return {
    id: 'p',
    title: 'T',
    source: 'usb-c-display',
    yawDeg: 0,
    pitchDeg: 0,
    rollDeg: 0,
    distanceM: 4,
    diagonalIn: 100,
    aspect: 16 / 9,
    sourceWidthPx: 1920,
    sourceHeightPx: 1080,
    anchor: 'body',
    stereo: 'mono',
    faceWearer: true,
    opacity: 1,
    curvatureDeg: 0,
    zOrder: 0,
    visible: true,
    dimWhenUnfocused: true,
    color: '#fff',
    locked: false,
    ...over,
  }
}

describe('polar', () => {
  it('puts zero yaw and pitch straight ahead down -Z', () => {
    const p = polar(0, 0, 4)
    expect(p.x).toBeCloseTo(0, 9)
    expect(p.y).toBeCloseTo(0, 9)
    expect(p.z).toBeCloseTo(-4, 9)
  })

  it('sends positive yaw to the right and positive pitch up', () => {
    expect(polar(90, 0, 3).x).toBeCloseTo(3, 6)
    expect(polar(0, 90, 3).y).toBeCloseTo(3, 6)
  })

  it('preserves distance at any bearing', () => {
    for (const [yaw, pitch] of [
      [0, 0],
      [37, -12],
      [-80, 25],
      [140, 40],
    ]) {
      const p = polar(yaw!, pitch!, 5.5)
      expect(Math.hypot(p.x, p.y, p.z)).toBeCloseTo(5.5, 9)
    }
  })
})

describe('toHeadSpace', () => {
  it('is a no-op for a level head', () => {
    const p = polar(20, 10, 4)
    const q = toHeadSpace(p, 0, 0, 0)
    expect(q.x).toBeCloseTo(p.x, 9)
    expect(q.y).toBeCloseTo(p.y, 9)
    expect(q.z).toBeCloseTo(p.z, 9)
  })

  it('cancels a matching head yaw, bringing the panel to dead ahead', () => {
    // Looking 25 degrees right at a panel 25 degrees right => it is centred.
    const q = toHeadSpace(polar(25, 0, 4), 25, 0, 0)
    expect(q.x).toBeCloseTo(0, 6)
    expect(q.z).toBeCloseTo(-4, 6)
  })

  it('cancels a matching head pitch', () => {
    const q = toHeadSpace(polar(0, 15, 4), 0, 15, 0)
    expect(q.y).toBeCloseTo(0, 6)
    expect(q.z).toBeCloseTo(-4, 6)
  })

  it('preserves length, being a pure rotation', () => {
    const p = polar(33, -8, 6)
    const q = toHeadSpace(p, 12, 5, 3)
    expect(Math.hypot(q.x, q.y, q.z)).toBeCloseTo(6, 9)
  })
})

describe('panelOutline', () => {
  it('produces a closed loop whose centroid is the panel centre', () => {
    const p = panel({ yawDeg: 30, pitchDeg: -10 })
    const o = panelOutline(p)
    const c = o.reduce((a, v) => ({ x: a.x + v.x, y: a.y + v.y, z: a.z + v.z }), {
      x: 0,
      y: 0,
      z: 0,
    })
    const n = o.length
    const centre = polar(p.yawDeg, p.pitchDeg, p.distanceM)
    expect(c.x / n).toBeCloseTo(centre.x, 6)
    expect(c.y / n).toBeCloseTo(centre.y, 6)
    expect(c.z / n).toBeCloseTo(centre.z, 6)
  })

  it('gives a flat panel the right physical dimensions', () => {
    const p = panel({ curvatureDeg: 0 })
    const o = panelOutline(p)
    const { widthM, heightM } = panelSizeM(p.diagonalIn, p.aspect)
    // Corners come back as [topLeft, topRight, bottomRight, bottomLeft].
    const topL = o[0]!
    const topR = o[1]!
    const botR = o[2]!
    expect(Math.hypot(topR.x - topL.x, topR.y - topL.y, topR.z - topL.z)).toBeCloseTo(
      widthM,
      6,
    )
    expect(Math.hypot(botR.x - topR.x, botR.y - topR.y, botR.z - topR.z)).toBeCloseTo(
      heightM,
      6,
    )
  })

  it('pulls the edges onto the wearer sphere when fully curved', () => {
    // A fully cylindrical panel keeps every horizontal point at one distance,
    // which is the entire reason to curve a wide screen.
    const p = panel({ diagonalIn: 200, curvatureDeg: 360, distanceM: 4 })
    const o = panelOutline(p, 16)
    const half = o.length / 2
    const heightM = panelSizeM(p.diagonalIn, p.aspect).heightM
    for (let i = 0; i < half; i++) {
      const v = o[i]!
      // Distance measured in the horizontal plane, with the vertical offset removed.
      const horiz = Math.hypot(v.x, v.z)
      expect(horiz).toBeCloseTo(p.distanceM, 4)
      expect(Math.abs(v.y)).toBeCloseTo(heightM / 2, 6)
    }
  })

  it('leaves a flat panel"s edges further away than its centre', () => {
    const p = panel({ diagonalIn: 200, curvatureDeg: 0, distanceM: 4 })
    const o = panelOutline(p)
    const edge = Math.hypot(o[0]!.x, o[0]!.y, o[0]!.z)
    expect(edge).toBeGreaterThan(p.distanceM)
  })
})

describe('projectPanel', () => {
  it('centres a straight-ahead panel at the origin of the viewport', () => {
    const r = projectPanel(panel(), level, fov)
    expect(r.centre.x).toBeCloseTo(0, 9)
    expect(r.centre.y).toBeCloseTo(0, 9)
  })

  it('maps a panel filling the FOV to exactly the viewport edges', () => {
    // A panel whose angular width equals the horizontal FOV must land on ±1.
    const widthM = 2 * 4 * Math.tan((fov.horizontalDeg * Math.PI) / 360)
    const heightM = widthM / (16 / 9)
    const diagonalIn = Math.hypot(widthM, heightM) / 0.0254
    const r = projectPanel(panel({ diagonalIn, distanceM: 4, faceWearer: false }), level, fov)
    const xs = r.points.map((p) => p.x)
    expect(Math.max(...xs)).toBeCloseTo(1, 6)
    expect(Math.min(...xs)).toBeCloseTo(-1, 6)
  })

  it('reports a panel behind the wearer as clipped, not as a wild rectangle', () => {
    const r = projectPanel(panel({ yawDeg: 180 }), level, fov)
    expect(r.clipped).toBe(true)
    expect(r.fullyVisible).toBe(false)
    // Every coordinate must stay finite so the SVG path cannot break.
    for (const p of r.points) {
      expect(Number.isFinite(p.x)).toBe(true)
      expect(Number.isFinite(p.y)).toBe(true)
    }
  })

  it('marks a far off-axis panel offscreen', () => {
    expect(projectPanel(panel({ yawDeg: 75 }), level, fov).offscreen).toBe(true)
  })

  it('moves a body-anchored panel when the head turns', () => {
    const still = projectPanel(panel({ anchor: 'body' }), level, fov)
    const turned = projectPanel(
      panel({ anchor: 'body' }),
      { yawDeg: 15, pitchDeg: 0, rollDeg: 0 },
      fov,
    )
    // Turning right pushes a fixed panel to the left of the viewport.
    expect(turned.centre.x).toBeLessThan(still.centre.x - 0.1)
  })

  it('keeps a head-anchored panel pinned however the head moves', () => {
    const a = projectPanel(panel({ anchor: 'head', yawDeg: 10 }), level, fov)
    const b = projectPanel(
      panel({ anchor: 'head', yawDeg: 10 }),
      { yawDeg: -32, pitchDeg: 14, rollDeg: 6 },
      fov,
    )
    expect(b.centre.x).toBeCloseTo(a.centre.x, 9)
    expect(b.centre.y).toBeCloseTo(a.centre.y, 9)
  })

  it('recentres a panel when the head turns to face it', () => {
    const r = projectPanel(
      panel({ yawDeg: 28, anchor: 'world' }),
      { yawDeg: 28, pitchDeg: 0, rollDeg: 0 },
      fov,
    )
    expect(r.centre.x).toBeCloseTo(0, 6)
    expect(r.fullyVisible).toBe(true)
  })

  /**
   * These two cases are the whole point of the `faceWearer` toggle, and they
   * are easy to get backwards.
   *
   * A panel that is *not* turned toward the wearer keeps its own plane parallel
   * to straight-ahead, so every corner sits at the same depth and it projects as
   * a plain rectangle — just shifted sideways.
   *
   * Turning it to face the wearer rotates that plane, which puts its near and far
   * vertical edges at different depths. Since a rectilinear projection divides by
   * depth, the result is a trapezoid. Drawing either case as a rectangle would
   * hide real distortion, which is why the preview projects corners rather than
   * placing boxes.
   */
  const edges = (r: ReturnType<typeof projectPanel>) => {
    const [topL, topR, botR, botL] = r.points as {
      x: number
      y: number
    }[] as [
      { x: number; y: number },
      { x: number; y: number },
      { x: number; y: number },
      { x: number; y: number },
    ]
    return {
      left: Math.abs(topL.y - botL.y),
      right: Math.abs(topR.y - botR.y),
    }
  }

  it('projects a non-facing off-axis panel as a rectangle', () => {
    const e = edges(projectPanel(panel({ yawDeg: 18, faceWearer: false }), level, fov))
    expect(e.left).toBeCloseTo(e.right, 9)
  })

  it('projects a wearer-facing off-axis panel as a trapezoid', () => {
    const e = edges(projectPanel(panel({ yawDeg: 18, faceWearer: true }), level, fov))
    expect(e.left).not.toBeCloseTo(e.right, 3)
    // The inner edge is nearer the eye, so it projects taller.
    expect(e.right).toBeGreaterThan(e.left)
  })

  it('leaves a wearer-facing panel symmetric when it is dead ahead', () => {
    const e = edges(projectPanel(panel({ yawDeg: 0, faceWearer: true }), level, fov))
    expect(e.left).toBeCloseTo(e.right, 9)
  })
})
