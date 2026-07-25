/**
 * Optics and legibility math.
 *
 * This is the part of the app that has to be right. Everything the UI claims
 * about screen size, distance and sharpness comes from here.
 *
 * The mental model: the glasses paint a fixed-size window on the world —
 * 1920x1080 per eye spread across a 47° diagonal cone. A "virtual screen" is
 * just a rectangle placed somewhere in that cone. Making it bigger and making
 * it closer are the same operation as far as your eye is concerned; what
 * actually matters is the *angle* it subtends and how many display pixels land
 * inside that angle.
 */

import type { DeviceProfile, Panel } from './types'

export const INCH_M = 0.0254

export const deg = (rad: number) => (rad * 180) / Math.PI
export const rad = (d: number) => (d * Math.PI) / 180

export function clamp(v: number, lo: number, hi: number) {
  return Math.min(hi, Math.max(lo, v))
}

/**
 * Split a diagonal FOV into horizontal and vertical components for a given
 * aspect ratio.
 *
 * Done in tangent space rather than by scaling the angle linearly, because the
 * projection is a rectilinear pinhole: the panel is a flat rectangle at a fixed
 * distance, so it is the *tangents* that share the aspect ratio, not the
 * angles. Linear angle-splitting is a common shortcut and it is wrong by ~1° at
 * these FOVs.
 */
export function splitFov(fovDiagonalDeg: number, aspect: number) {
  const halfDiagTan = Math.tan(rad(fovDiagonalDeg) / 2)
  // For a rectangle with width:height = aspect, the half-diagonal in tangent
  // space decomposes as halfDiagTan^2 = tw^2 + th^2 with tw = aspect * th.
  const th = halfDiagTan / Math.sqrt(1 + aspect * aspect)
  const tw = aspect * th
  return {
    horizontalDeg: 2 * deg(Math.atan(tw)),
    verticalDeg: 2 * deg(Math.atan(th)),
  }
}

/** Physical width/height in metres of a panel given its diagonal and aspect. */
export function panelSizeM(diagonalIn: number, aspect: number) {
  const diagM = diagonalIn * INCH_M
  const h = diagM / Math.sqrt(1 + aspect * aspect)
  return { widthM: aspect * h, heightM: h }
}

/** The inverse: what diagonal in inches gives this width at this aspect? */
export function diagonalInFromWidthM(widthM: number, aspect: number) {
  const h = widthM / aspect
  return Math.hypot(widthM, h) / INCH_M
}

/** Angle subtended by a length viewed head-on at a distance. */
export function angularSizeDeg(lengthM: number, distanceM: number) {
  if (distanceM <= 0) return 0
  return 2 * deg(Math.atan(lengthM / 2 / distanceM))
}

/** The inverse: what length subtends this angle at this distance? */
export function lengthMForAngle(angleDeg: number, distanceM: number) {
  return 2 * distanceM * Math.tan(rad(angleDeg) / 2)
}

/**
 * Native pixels per degree of the headset itself — the ceiling on any detail
 * the wearer can possibly resolve.
 *
 * Two numbers, because they answer different questions:
 *
 * - `center` is the on-axis density, and it is the honest "how sharp is this
 *   headset" figure. Because the panels have square pixels, it is identical on
 *   both axes.
 * - `avgHorizontal` / `avgVertical` are just pixels ÷ total angle. They differ
 *   from each other and from `center` because a rectilinear projection
 *   compresses more angle into each pixel toward the periphery, and the
 *   horizontal axis reaches further out. Useful for coverage bookkeeping, not
 *   for judging sharpness.
 */
export function devicePpd(device: DeviceProfile) {
  const aspect = device.panelWidthPx / device.panelHeightPx
  const fov = splitFov(device.fovDiagonalDeg, aspect)
  const center =
    (device.panelWidthPx / 2 / Math.tan(rad(fov.horizontalDeg) / 2)) * rad(1)
  return {
    center,
    avgHorizontal: device.panelWidthPx / fov.horizontalDeg,
    avgVertical: device.panelHeightPx / fov.verticalDeg,
    fov,
  }
}

/**
 * How many display pixels land across an on-axis feature of a given angular
 * size.
 *
 * Exact rather than `angle * ppd`: the display is a flat panel behind a
 * rectilinear projection, so screen position goes as tan(θ), not θ. Feeding the
 * full FOV in returns exactly the panel resolution, and small angles converge
 * on the centre density — both of which the linear approximation gets wrong by
 * several percent at 47°.
 *
 * Computed for a feature centred on the optical axis. A panel pushed out to the
 * edge of the FOV covers slightly more pixels than this for the same angular
 * size; on-axis is the conservative reference case.
 */
export function displayPxForAngle(
  angularDeg: number,
  fovDeg: number,
  panelPx: number,
) {
  if (angularDeg <= 0) return 0
  return (panelPx * Math.tan(rad(angularDeg) / 2)) / Math.tan(rad(fovDeg) / 2)
}

/**
 * The diagonal size, in inches, that exactly fills the FOV at a given
 * distance. This is where marketing numbers like "201 inches" come from —
 * they are a size *and* an implied distance, and quoting either alone is
 * meaningless.
 */
export function fovFillingDiagonalIn(device: DeviceProfile, distanceM: number) {
  return (lengthMForAngle(device.fovDiagonalDeg, distanceM) / INCH_M)
}

export interface PanelAnalysis {
  widthM: number
  heightM: number
  /** Angle the panel subtends. */
  angularWidthDeg: number
  angularHeightDeg: number
  /** Fraction of the available FOV consumed, 0–1+. */
  fovCoverageW: number
  fovCoverageH: number
  /** Display pixels available across the panel's angular footprint. */
  displayPxAcross: number
  displayPxDown: number
  /**
   * Ratio of available display pixels to source pixels.
   * 1 = pixel-perfect, <1 = the source is being downscaled and detail is lost,
   * >1 = the source is upscaled and will look soft/blocky.
   */
  sharpness: number
  /** Effective pixels per degree the wearer actually receives on this panel. */
  effectivePpd: number
  /** True when the panel is wider or taller than the FOV. */
  exceedsFov: boolean
  /**
   * Fraction of the panel visible with the head at rest, 0–1.
   *
   * The metric that actually predicts whether a layout is comfortable. A panel
   * can sit inside every other threshold and still be unreadable without turning
   * your neck, because the field of view is only ±20.8° horizontally — narrower
   * than people assume from a "47 inch diagonal" figure.
   */
  visibleFractionAtRest: number
  /**
   * True when the panel's centre falls outside the field of view, so reaching it
   * means turning your head rather than moving your eyes.
   */
  centreOutsideFov: boolean
  /** Equivalent diagonal that would exactly fill the FOV at this distance. */
  fovFillingDiagonalIn: number
  /** Smallest legible text size, in source pixels, at this configuration. */
  minLegibleTextPx: number
}

/**
 * The angular acuity limit we design against, in cycles per degree.
 *
 * 30 cpd (= 60 px/deg) is the classic 20/20 threshold. The Air 4 Pro's ~47
 * px/deg sits below it, which is why text on these glasses is comfortable but
 * never quite as crisp as a desk monitor — worth surfacing honestly rather
 * than pretending otherwise.
 */
export const ACUITY_PPD_2020 = 60

/**
 * Rule of thumb for legibility: a lowercase character needs roughly 16
 * arcminutes of visual angle to read comfortably for long stretches.
 */
const COMFORT_CAP_HEIGHT_ARCMIN = 16

export function analysePanel(panel: Panel, device: DeviceProfile): PanelAnalysis {
  const { widthM, heightM } = panelSizeM(panel.diagonalIn, panel.aspect)
  const angularWidthDeg = angularSizeDeg(widthM, panel.distanceM)
  const angularHeightDeg = angularSizeDeg(heightM, panel.distanceM)

  const ppd = devicePpd(device)
  const displayPxAcross = displayPxForAngle(
    angularWidthDeg,
    ppd.fov.horizontalDeg,
    device.panelWidthPx,
  )
  const displayPxDown = displayPxForAngle(
    angularHeightDeg,
    ppd.fov.verticalDeg,
    device.panelHeightPx,
  )

  // A panel bigger than the FOV cannot use more pixels than the FOV holds, so
  // clamp the available budget before comparing against the source.
  const usablePxAcross = Math.min(displayPxAcross, device.panelWidthPx)
  const sharpness = panel.sourceWidthPx > 0 ? usablePxAcross / panel.sourceWidthPx : 0

  const effectivePpd =
    angularWidthDeg > 0 ? Math.min(displayPxAcross, panel.sourceWidthPx) / angularWidthDeg : 0

  // How tall must a glyph be, in source pixels, to clear the comfort threshold?
  const arcminPerSourcePx =
    panel.sourceHeightPx > 0 ? (angularHeightDeg * 60) / panel.sourceHeightPx : 0
  const minLegibleTextPx =
    arcminPerSourcePx > 0 ? COMFORT_CAP_HEIGHT_ARCMIN / arcminPerSourcePx : Infinity

  // How much of the panel falls inside the FOV with the head at rest. Computed
  // on the horizontal axis, which is where layouts overflow in practice.
  const halfFovH = ppd.fov.horizontalDeg / 2
  const halfFovV = ppd.fov.verticalDeg / 2
  const spanLo = panel.yawDeg - angularWidthDeg / 2
  const spanHi = panel.yawDeg + angularWidthDeg / 2
  const overlapW = Math.max(
    0,
    Math.min(spanHi, halfFovH) - Math.max(spanLo, -halfFovH),
  )
  const vLo = panel.pitchDeg - angularHeightDeg / 2
  const vHi = panel.pitchDeg + angularHeightDeg / 2
  const overlapH = Math.max(0, Math.min(vHi, halfFovV) - Math.max(vLo, -halfFovV))
  const visibleFractionAtRest =
    angularWidthDeg > 0 && angularHeightDeg > 0
      ? (overlapW / angularWidthDeg) * (overlapH / angularHeightDeg)
      : 0

  return {
    widthM,
    heightM,
    angularWidthDeg,
    angularHeightDeg,
    fovCoverageW: angularWidthDeg / ppd.fov.horizontalDeg,
    fovCoverageH: angularHeightDeg / ppd.fov.verticalDeg,
    displayPxAcross,
    displayPxDown,
    sharpness,
    effectivePpd,
    exceedsFov:
      angularWidthDeg > ppd.fov.horizontalDeg + 0.01 ||
      angularHeightDeg > ppd.fov.verticalDeg + 0.01,
    visibleFractionAtRest,
    centreOutsideFov:
      Math.abs(panel.yawDeg) > halfFovH || Math.abs(panel.pitchDeg) > halfFovV,
    fovFillingDiagonalIn: fovFillingDiagonalIn(device, panel.distanceM),
    minLegibleTextPx,
  }
}

/**
 * Resize a panel so its apparent size stays constant while its distance
 * changes. This is what the "lock apparent size" toggle uses: pushing a screen
 * further away without shrinking it is almost never what someone means.
 */
export function rescaleForDistance(panel: Panel, newDistanceM: number): number {
  if (panel.distanceM <= 0 || newDistanceM <= 0) return panel.diagonalIn
  return panel.diagonalIn * (newDistanceM / panel.distanceM)
}

/**
 * The source resolution that lands 1:1 on the display for a panel of a given
 * angular width.
 *
 * This is the single most useful derived number in the app, and the least
 * obvious. The glasses have a fixed pixel budget — 1920 across 41.5° — and every
 * panel in view is spending part of it. A panel occupying a third of your field
 * of view receives roughly a third of those pixels, so feeding it a 1920-wide
 * source throws away two thirds of the detail and makes text mushy for no
 * benefit. Matching the source to the panel's actual angular footprint is free
 * sharpness: less data, and it looks better.
 *
 * Rounded to even numbers because odd-width video surfaces upset many encoders.
 */
export function matchedSourceResolution(
  angularWidthDeg: number,
  aspect: number,
  device: DeviceProfile,
) {
  const fov = devicePpd(device).fov
  const px = displayPxForAngle(angularWidthDeg, fov.horizontalDeg, device.panelWidthPx)
  const width = Math.max(160, Math.round(Math.min(px, device.panelWidthPx) / 2) * 2)
  const height = Math.max(90, Math.round(width / aspect / 2) * 2)
  return { width, height }
}

/**
 * The widest arc spread that still keeps every panel fully inside the field of
 * view at rest.
 *
 * Worth having because the intuition is badly wrong. The horizontal FOV is about
 * 41.5°, so three panels spread over the default 90° put their outer centres at
 * ±45° — more than twice as far out as you can see without turning your head.
 * The arithmetic, with the arc layout's own sizing (`w = spread/n - gap`) and the
 * outermost centres at ±spread/2:
 *
 *   spread/2 + w/2 <= fov/2   =>   spread <= (fov + gap) · n/(n+1)
 *
 * For three panels at a 2° gap that is ~32.6°, giving ~8.9° per panel. Which
 * exposes the real trade-off: everything visible at once means small panels.
 * There is no spread that makes three big panels simultaneously readable, and the
 * app should say so rather than let you discover it while wearing the glasses.
 */
export function maxSpreadForFullVisibility(
  count: number,
  device: DeviceProfile,
  gapDeg = 0,
) {
  if (count <= 1) return 0
  const fov = devicePpd(device).fov.horizontalDeg
  return Math.max(0, (fov + gapDeg) * (count / (count + 1)))
}

/** Diagonal, in inches, that reproduces a target angular width at a distance. */
export function diagonalForAngularWidth(
  angularWidthDeg: number,
  distanceM: number,
  aspect: number,
) {
  return diagonalInFromWidthM(lengthMForAngle(angularWidthDeg, distanceM), aspect)
}

// ---------------------------------------------------------------------------
// Comfort and ergonomics
// ---------------------------------------------------------------------------

export type Severity = 'info' | 'warn' | 'error'

export interface Advisory {
  id: string
  severity: Severity
  title: string
  detail: string
  panelId?: string
}

/**
 * Comfort thresholds.
 *
 * `MIN_COMFORT_DISTANCE_M` is the one worth explaining: these are fixed-focus
 * displays with focal planes around 4-6 m, so a virtual screen placed at 0.5 m
 * asks your eyes to converge for near work while still focusing far. That
 * vergence-accommodation conflict is the main driver of eye strain in this
 * class of hardware, so the app pushes back below ~1.5 m.
 */
export const COMFORT = {
  minDistanceM: 1.5,
  idealDistanceM: [2.5, 6] as [number, number],
  maxDistanceM: 20,
  /** Sustained yaw beyond this means turning your neck, not your eyes. */
  comfortableYawDeg: 30,
  /** Looking up is markedly more fatiguing than looking down. */
  maxComfortablePitchUpDeg: 15,
  maxComfortablePitchDownDeg: 25,
  /** Below this the source is being downscaled enough to notice. */
  softSharpness: 0.75,
  /** Above this the source is being upscaled and looks blocky. */
  upscaleSharpness: 1.35,
}

export function auditPanel(panel: Panel, device: DeviceProfile): Advisory[] {
  const out: Advisory[] = []
  const a = analysePanel(panel, device)
  const tag = panel.title || 'Panel'

  if (panel.distanceM < COMFORT.minDistanceM) {
    out.push({
      id: `${panel.id}:near`,
      panelId: panel.id,
      severity: 'warn',
      title: `${tag} is closer than ${COMFORT.minDistanceM} m`,
      detail:
        'These are fixed-focus displays. Placing a screen this close forces your eyes to converge for near work while still focusing at infinity, which is the main cause of eye strain on this hardware. Push it back and scale it up to keep the same apparent size.',
    })
  }

  if (a.exceedsFov) {
    const fov = devicePpd(device).fov
    out.push({
      id: `${panel.id}:fov`,
      panelId: panel.id,
      severity: 'warn',
      title: `${tag} overflows the field of view`,
      detail: `It subtends ${a.angularWidthDeg.toFixed(
        1,
      )}° x ${a.angularHeightDeg.toFixed(1)}° but the glasses only show ${fov.horizontalDeg.toFixed(
        1,
      )}° x ${fov.verticalDeg.toFixed(
        1,
      )}°. You will have to move your head to read the edges. Fine for immersive video, poor for a work surface.`,
    })
  }

  if (a.sharpness < COMFORT.softSharpness && panel.visible) {
    out.push({
      id: `${panel.id}:soft`,
      panelId: panel.id,
      severity: 'warn',
      title: `${tag} is downscaled to ${Math.round(a.sharpness * 100)}%`,
      detail: `Only ~${Math.round(a.displayPxAcross)} display pixels cover a ${
        panel.sourceWidthPx
      } px source, so roughly ${Math.round(
        (1 - a.sharpness) * 100,
      )}% of the detail is thrown away. Text under ~${Math.ceil(
        a.minLegibleTextPx,
      )} px will be hard to read. Enlarge the panel or reduce the source resolution.`,
    })
  } else if (a.sharpness > COMFORT.upscaleSharpness) {
    out.push({
      id: `${panel.id}:upscaled`,
      panelId: panel.id,
      severity: 'info',
      title: `${tag} is upscaled ${a.sharpness.toFixed(2)}x`,
      detail:
        'The panel is larger than its source resolution justifies. Raising the source resolution would use the display fully.',
    })
  }

  /*
   * Reachability, which matters more than raw off-axis angle and is easy to miss.
   *
   * A panel can clear every other threshold and still be unreadable without
   * turning your neck, because the horizontal field of view is only ±20.8° —
   * far narrower than a "big virtual screen" framing suggests. A panel centred
   * at 29° passes a 30° off-axis check while sitting almost entirely outside
   * what you can see. Checking the centre angle alone missed exactly that case.
   */
  const fov = devicePpd(device).fov
  if (a.centreOutsideFov) {
    const pct = Math.round(a.visibleFractionAtRest * 100)
    out.push({
      id: `${panel.id}:unreachable`,
      panelId: panel.id,
      severity: panel.anchor === 'head' ? 'error' : 'warn',
      title:
        panel.anchor === 'head'
          ? `${tag} is head-locked outside the field of view`
          : `${tag} needs a head turn — only ${pct}% of it is visible at rest`,
      detail:
        panel.anchor === 'head'
          ? `Its centre sits at ${panel.yawDeg.toFixed(0)}°/${panel.pitchDeg.toFixed(
              0,
            )}°, outside the ±${(fov.horizontalDeg / 2).toFixed(1)}° × ±${(
              fov.verticalDeg / 2
            ).toFixed(
              1,
            )}° visible area. A head-locked panel moves with you, so it will never come into view — it is effectively invisible.`
          : `Its centre is at ${panel.yawDeg.toFixed(0)}°/${panel.pitchDeg.toFixed(
              0,
            )}°, beyond the ±${(fov.horizontalDeg / 2).toFixed(1)}° × ±${(
              fov.verticalDeg / 2
            ).toFixed(
              1,
            )}° you can see at once. You will turn your head to read it, not just your eyes. Fine for something you consult occasionally; wrong for anything you switch to often.`,
    })
  } else if (a.visibleFractionAtRest < 0.9) {
    out.push({
      id: `${panel.id}:clipped`,
      panelId: panel.id,
      severity: 'info',
      title: `${tag} is ${Math.round(
        (1 - a.visibleFractionAtRest) * 100,
      )}% clipped at rest`,
      detail:
        'Its centre is in view but the edges are not, so you will make small head movements to read all of it. Reduce its size or bring it closer to the centre to fix.',
    })
  } else if (Math.abs(panel.yawDeg) > COMFORT.comfortableYawDeg) {
    out.push({
      id: `${panel.id}:yaw`,
      panelId: panel.id,
      severity: 'info',
      title: `${tag} sits ${Math.abs(panel.yawDeg).toFixed(0)}° off-axis`,
      detail: `Past about ${COMFORT.comfortableYawDeg}° you turn your neck rather than your eyes. Good for a glanceable reference panel, tiring as a primary surface.`,
    })
  }

  if (panel.pitchDeg > COMFORT.maxComfortablePitchUpDeg) {
    out.push({
      id: `${panel.id}:pitchUp`,
      panelId: panel.id,
      severity: 'info',
      title: `${tag} is ${panel.pitchDeg.toFixed(0)}° above eye level`,
      detail:
        'Sustained upward gaze fatigues faster than downward. Consider dropping it to eye level or slightly below.',
    })
  }

  if (panel.anchor === 'world' && device.dof === 3) {
    out.push({
      id: `${panel.id}:3dof`,
      panelId: panel.id,
      severity: 'info',
      title: `${tag} is world-anchored on a 3DoF device`,
      detail:
        'The Air series tracks orientation only. The panel will hold its bearing when you look around, but it will travel with you if you walk — there is no positional tracking and no parallax.',
    })
  }

  return out
}

export function auditView(
  panels: Panel[],
  device: DeviceProfile,
): Advisory[] {
  const out: Advisory[] = []
  const visible = panels.filter((p) => p.visible)

  for (const p of visible) out.push(...auditPanel(p, device))

  // Overlap check in angular space — two panels fighting for the same part of
  // the FOV is the most common thing people get wrong when laying out an arc.
  for (let i = 0; i < visible.length; i++) {
    for (let j = i + 1; j < visible.length; j++) {
      const a = visible[i]!
      const b = visible[j]!
      const aa = analysePanel(a, device)
      const ab = analysePanel(b, device)
      const dYaw = Math.abs(a.yawDeg - b.yawDeg)
      const dPitch = Math.abs(a.pitchDeg - b.pitchDeg)
      const halfW = (aa.angularWidthDeg + ab.angularWidthDeg) / 2
      const halfH = (aa.angularHeightDeg + ab.angularHeightDeg) / 2
      if (dYaw < halfW && dPitch < halfH) {
        out.push({
          id: `overlap:${a.id}:${b.id}`,
          severity: 'info',
          title: `${a.title} and ${b.title} overlap`,
          detail: `Their angular footprints intersect. The higher z-order (${
            a.zOrder >= b.zOrder ? a.title : b.title
          }) draws in front. Intentional for a stack, a mistake in an arc.`,
        })
      }
    }
  }

  const totalCoverage = visible.reduce((sum, p) => {
    const an = analysePanel(p, device)
    return sum + an.angularWidthDeg * an.angularHeightDeg
  }, 0)
  const fov = devicePpd(device).fov
  const fovArea = fov.horizontalDeg * fov.verticalDeg
  if (totalCoverage > fovArea * 3) {
    out.push({
      id: 'view:dense',
      severity: 'info',
      title: 'This view spans a lot of head movement',
      detail: `The panels cover about ${(totalCoverage / fovArea).toFixed(
        1,
      )}x the visible FOV, so most of them are off-screen at any moment. Consider splitting them across two views you can switch between instead.`,
    })
  }

  if (visible.length === 0) {
    out.push({
      id: 'view:empty',
      severity: 'warn',
      title: 'No visible panels',
      detail: 'This view will show an empty display. Add a panel or mark one visible.',
    })
  }

  return out
}
