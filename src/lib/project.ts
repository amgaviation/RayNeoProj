/**
 * Geometry for the previews.
 *
 * Panels are stored as angles, but to draw them honestly you need their actual
 * corners in 3D and then a real perspective projection — otherwise off-axis
 * panels look wrong in exactly the way that matters. A panel 35° to the left is
 * foreshortened and trapezoidal, and pretending it is a neat rectangle would
 * hide the very problem the wearer is trying to spot.
 *
 * Convention throughout: right-handed, Y up, **forward is -Z**, yaw positive to
 * the right, pitch positive up. (The Unity exporter converts to left-handed
 * +Z-forward on the way out.)
 */

import type { AnchorMode, Panel } from './types'
import { panelSizeM, rad } from './optics'

export interface Vec3 {
  x: number
  y: number
  z: number
}

export const v3 = (x: number, y: number, z: number): Vec3 => ({ x, y, z })
const add = (a: Vec3, b: Vec3): Vec3 => v3(a.x + b.x, a.y + b.y, a.z + b.z)
const scale = (a: Vec3, k: number): Vec3 => v3(a.x * k, a.y * k, a.z * k)
const len = (a: Vec3) => Math.hypot(a.x, a.y, a.z)
const norm = (a: Vec3): Vec3 => {
  const l = len(a)
  return l > 1e-9 ? scale(a, 1 / l) : v3(0, 0, -1)
}
const cross = (a: Vec3, b: Vec3): Vec3 =>
  v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)

/** Spherical to Cartesian with forward = -Z. */
export function polar(yawDeg: number, pitchDeg: number, distanceM: number): Vec3 {
  const yaw = rad(yawDeg)
  const pitch = rad(pitchDeg)
  const cp = Math.cos(pitch)
  return v3(
    distanceM * Math.sin(yaw) * cp,
    distanceM * Math.sin(pitch),
    -distanceM * Math.cos(yaw) * cp,
  )
}

/** Rotate a vector into head-local space, i.e. apply the inverse head rotation. */
export function toHeadSpace(p: Vec3, yawDeg: number, pitchDeg: number, rollDeg: number): Vec3 {
  // Inverse of Ry(yaw) * Rx(pitch) * Rz(roll) applied in reverse order.
  const cy = Math.cos(-rad(yawDeg))
  const sy = Math.sin(-rad(yawDeg))
  let x = cy * p.x - sy * p.z
  let z = sy * p.x + cy * p.z
  let y = p.y

  const cx = Math.cos(-rad(pitchDeg))
  const sx = Math.sin(-rad(pitchDeg))
  const y2 = cx * y - sx * z
  const z2 = sx * y + cx * z
  y = y2
  z = z2

  const cz = Math.cos(-rad(rollDeg))
  const sz = Math.sin(-rad(rollDeg))
  const x2 = cz * x - sz * y
  const y3 = sz * x + cz * y
  x = x2
  y = y3

  return v3(x, y, z)
}

/** Orthonormal basis for a panel's plane. */
function panelBasis(centre: Vec3, faceWearer: boolean, rollDeg: number) {
  let right: Vec3
  let up: Vec3
  if (faceWearer) {
    // Normal points from the panel back toward the wearer.
    const n = norm(scale(centre, -1))
    const worldUp = v3(0, 1, 0)
    // Degenerate when a panel is directly overhead or underfoot; fall back to a
    // fixed reference so the basis stays finite instead of collapsing.
    let r = cross(worldUp, n)
    if (len(r) < 1e-6) r = cross(v3(0, 0, -1), n)
    right = norm(r)
    up = norm(cross(n, right))
  } else {
    right = v3(1, 0, 0)
    up = v3(0, 1, 0)
  }
  if (rollDeg !== 0) {
    const c = Math.cos(rad(rollDeg))
    const s = Math.sin(rad(rollDeg))
    const r2 = add(scale(right, c), scale(up, s))
    const u2 = add(scale(up, c), scale(right, -s))
    right = norm(r2)
    up = norm(u2)
  }
  return { right, up }
}

/**
 * The panel outline in 3D, as a closed loop of points.
 *
 * `segments` subdivides the horizontal edges so curvature can be drawn. A
 * curved panel is treated as a section of a cylinder centred on the wearer at
 * the panel's own distance, and `curvatureDeg` blends between flat and fully
 * cylindrical — the blend is what makes a partial curve meaningful rather than
 * an on/off switch.
 */
export function panelOutline(panel: Panel, segments = 12): Vec3[] {
  const centre = polar(panel.yawDeg, panel.pitchDeg, panel.distanceM)
  const { widthM, heightM } = panelSizeM(panel.diagonalIn, panel.aspect)
  const { right, up } = panelBasis(centre, panel.faceWearer, panel.rollDeg)

  const angularWidthDeg =
    2 * Math.atan(widthM / 2 / panel.distanceM) * (180 / Math.PI)
  const bend =
    angularWidthDeg > 0
      ? Math.min(1, Math.max(0, panel.curvatureDeg / angularWidthDeg))
      : 0

  const n = Math.max(2, panel.curvatureDeg > 0 ? segments : 2)

  const pointAt = (u: number, vSign: 1 | -1): Vec3 => {
    const flat = add(
      add(centre, scale(right, u * widthM)),
      scale(up, (vSign * heightM) / 2),
    )
    if (bend <= 0) return flat
    // Cylindrical placement: same arc length along the wearer's sphere, so the
    // curved panel keeps its angular width instead of shrinking as it bends.
    const theta = rad(u * angularWidthDeg)
    const curved = add(
      add(
        scale(norm(centre), panel.distanceM * Math.cos(theta)),
        scale(right, panel.distanceM * Math.sin(theta)),
      ),
      scale(up, (vSign * heightM) / 2),
    )
    return add(scale(flat, 1 - bend), scale(curved, bend))
  }

  const top: Vec3[] = []
  const bottom: Vec3[] = []
  for (let i = 0; i < n; i++) {
    const u = -0.5 + i / (n - 1)
    top.push(pointAt(u, 1))
    bottom.push(pointAt(u, -1))
  }
  return [...top, ...bottom.reverse()]
}

export interface Projected {
  /** Normalised device coords: ±1 is the edge of the field of view. */
  points: { x: number; y: number }[]
  /** Panel centre in NDC. */
  centre: { x: number; y: number }
  /** True when any part of the outline is behind the wearer. */
  clipped: boolean
  /** True when the whole outline lies inside the field of view. */
  fullyVisible: boolean
  /** True when nothing is inside the field of view. */
  offscreen: boolean
  /** Distance from the eye to the panel centre, metres. */
  depth: number
}

/**
 * Project a panel into normalised device coordinates for the glasses view.
 *
 * `±1` on each axis is exactly the edge of the field of view, so the caller can
 * draw the viewport as a plain rectangle and everything lines up.
 */
export function projectPanel(
  panel: Panel,
  head: { yawDeg: number; pitchDeg: number; rollDeg: number },
  fov: { horizontalDeg: number; verticalDeg: number },
  segments = 12,
): Projected {
  const outline = panelOutline(panel, segments)
  const tanH = Math.tan(rad(fov.horizontalDeg) / 2)
  const tanV = Math.tan(rad(fov.verticalDeg) / 2)

  // A head-anchored panel is rigidly attached to the wearer, so head rotation
  // must not move it — it is already expressed in head space.
  const applyHead = (p: Vec3) =>
    panel.anchor === 'head' ? p : toHeadSpace(p, head.yawDeg, head.pitchDeg, head.rollDeg)

  let clipped = false
  const points = outline.map((p0) => {
    const p = applyHead(p0)
    // Guard the near plane: a panel edge swinging behind the eye would otherwise
    // project to a wild coordinate and tear the polygon across the viewport.
    const depth = -p.z
    if (depth <= 0.01) {
      clipped = true
      return { x: Math.sign(p.x || 1) * 9, y: Math.sign(p.y || 1) * 9 }
    }
    return { x: p.x / depth / tanH, y: p.y / depth / tanV }
  })

  const c3 = applyHead(polar(panel.yawDeg, panel.pitchDeg, panel.distanceM))
  const cDepth = -c3.z
  const centre =
    cDepth > 0.01
      ? { x: c3.x / cDepth / tanH, y: c3.y / cDepth / tanV }
      : { x: 0, y: 0 }

  const inside = points.filter((p) => Math.abs(p.x) <= 1 && Math.abs(p.y) <= 1)
  const anyNear = points.some((p) => Math.abs(p.x) <= 1.6 && Math.abs(p.y) <= 1.6)

  return {
    points,
    centre,
    clipped,
    fullyVisible: !clipped && inside.length === points.length,
    offscreen: inside.length === 0 && !anyNear,
    depth: cDepth > 0 ? cDepth : panel.distanceM,
  }
}

/**
 * Where a panel sits on a plan (top-down) view, in metres.
 * Used by the minimap, which is the quickest way to read a layout's spread.
 */
export function planPosition(panel: Panel, headYawDeg: number) {
  const yaw = panel.anchor === 'head' ? panel.yawDeg : panel.yawDeg - headYawDeg
  const r = panel.distanceM
  return {
    x: r * Math.sin(rad(yaw)),
    z: -r * Math.cos(rad(yaw)),
    yawDeg: yaw,
  }
}

/** Effective anchor description, for UI copy. */
export function anchorLabel(a: AnchorMode) {
  return a === 'head' ? 'Head-locked' : a === 'body' ? 'Body-follow' : 'World-locked'
}
