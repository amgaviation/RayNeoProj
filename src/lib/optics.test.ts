import { describe, expect, it } from 'vitest'
import {
  ACUITY_PPD_2020,
  analysePanel,
  angularSizeDeg,
  devicePpd,
  diagonalForAngularWidth,
  diagonalInFromWidthM,
  displayPxForAngle,
  matchedSourceResolution,
  fovFillingDiagonalIn,
  lengthMForAngle,
  panelSizeM,
  rescaleForDistance,
  splitFov,
} from './optics'
import { DEVICES } from './device'
import type { Panel } from './types'

const air4 = DEVICES['air-4-pro']!

function panel(over: Partial<Panel> = {}): Panel {
  return {
    id: 'p',
    title: 'Test',
    source: 'usb-c-display',
    yawDeg: 0,
    pitchDeg: 0,
    rollDeg: 0,
    distanceM: 4,
    diagonalIn: 130,
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
    color: '#38bdf8',
    locked: false,
    ...over,
  }
}

describe('splitFov', () => {
  it('decomposes a diagonal FOV consistently in tangent space', () => {
    const aspect = 16 / 9
    const { horizontalDeg, verticalDeg } = splitFov(47, aspect)
    // Recombining the half-tangents must return the original diagonal.
    const tw = Math.tan((horizontalDeg * Math.PI) / 360)
    const th = Math.tan((verticalDeg * Math.PI) / 360)
    const diag = (2 * Math.atan(Math.hypot(tw, th)) * 180) / Math.PI
    expect(diag).toBeCloseTo(47, 6)
    // And the tangents must carry the aspect ratio, not the angles.
    expect(tw / th).toBeCloseTo(aspect, 9)
  })

  it('puts the Air 4 Pro FOV at about 41.5 x 24.1 degrees', () => {
    const { horizontalDeg, verticalDeg } = splitFov(47, 16 / 9)
    expect(horizontalDeg).toBeCloseTo(41.5, 1)
    expect(verticalDeg).toBeCloseTo(24.1, 1)
  })
})

describe('displayPxForAngle', () => {
  const { horizontalDeg } = splitFov(47, 16 / 9)

  it('returns the full panel resolution for the full FOV', () => {
    expect(displayPxForAngle(horizontalDeg, horizontalDeg, 1920)).toBeCloseTo(1920, 6)
  })

  it('converges on the centre pixel density for small angles', () => {
    const tiny = 0.01
    expect(displayPxForAngle(tiny, horizontalDeg, 1920) / tiny).toBeCloseTo(
      devicePpd(air4).center,
      3,
    )
  })

  it('is non-linear in angle, unlike an angle x ppd approximation', () => {
    // Pixel density rises toward the periphery (dx/dθ goes as sec²θ), so the
    // central half of the FOV gets *less* than half the pixels — about 48%.
    // A linear angle x avgPpd estimate would overstate it by ~3.5%.
    const half = displayPxForAngle(horizontalDeg / 2, horizontalDeg, 1920)
    expect(half).toBeLessThan(960)
    expect(half / 1920).toBeCloseTo(0.483, 2)
  })

  it('makes centre density the floor, not the average', () => {
    // Consequence of the above: quoting the centre figure is the honest choice,
    // because no part of the display is sparser than on-axis.
    const ppd = devicePpd(air4)
    for (const angle of [1, 5, 10, 20, horizontalDeg]) {
      const avgOverAngle = displayPxForAngle(angle, horizontalDeg, 1920) / angle
      expect(avgOverAngle).toBeGreaterThanOrEqual(ppd.center - 1e-6)
    }
  })
})

describe('panel geometry', () => {
  it('round-trips diagonal -> size -> diagonal', () => {
    const { widthM } = panelSizeM(201, 16 / 9)
    expect(diagonalInFromWidthM(widthM, 16 / 9)).toBeCloseTo(201, 6)
  })

  it('matches a known 16:9 diagonal', () => {
    // A 100" 16:9 screen is 2.2136 m wide, 1.2452 m tall.
    const { widthM, heightM } = panelSizeM(100, 16 / 9)
    expect(widthM).toBeCloseTo(2.2136, 3)
    expect(heightM).toBeCloseTo(1.2452, 3)
  })

  it('round-trips angular size against length', () => {
    const a = angularSizeDeg(2.5, 4)
    expect(lengthMForAngle(a, 4)).toBeCloseTo(2.5, 9)
  })
})

describe('the published "201 inch" figure', () => {
  it('fills the 47 degree FOV at roughly 6 m', () => {
    // RayNeo markets the Air 4 Pro as a 201" virtual screen. A size alone is
    // meaningless without a distance; the distance implied by the FOV is ~5.9 m.
    const { widthM, heightM } = panelSizeM(201, 16 / 9)
    const diagM = Math.hypot(widthM, heightM)
    const distance = diagM / 2 / Math.tan((47 * Math.PI) / 360)
    expect(distance).toBeGreaterThan(5.5)
    expect(distance).toBeLessThan(6.2)
  })

  it('is reproduced by fovFillingDiagonalIn at that distance', () => {
    expect(fovFillingDiagonalIn(air4, 5.87)).toBeCloseTo(201, 0)
  })
})

describe('devicePpd', () => {
  it('reports the same on-axis density on both axes', () => {
    // The panels have square pixels, so centre density cannot differ by axis.
    // This is the invariant that actually holds; pixels-divided-by-total-angle
    // does not, and asserting it would be asserting a bug.
    const ppd = devicePpd(air4)
    expect(ppd.center).toBeCloseTo(44.2, 1)
  })

  it('shows average density diverging from centre density', () => {
    const ppd = devicePpd(air4)
    expect(ppd.avgHorizontal).toBeGreaterThan(ppd.center)
    expect(ppd.avgVertical).toBeGreaterThan(ppd.center)
    // The wider axis diverges further, which is why the two averages disagree.
    expect(ppd.avgHorizontal).toBeGreaterThan(ppd.avgVertical)
  })

  it('sits below the 60 px/deg 20/20 threshold', () => {
    // Worth keeping honest about: this hardware is comfortable but cannot
    // resolve 20/20 detail, so no configuration will make text desk-sharp.
    expect(devicePpd(air4).center).toBeLessThan(ACUITY_PPD_2020)
  })
})

describe('analysePanel', () => {
  it('reports pixel-perfect sharpness when the panel fills the FOV', () => {
    const d = 5
    const a = analysePanel(
      panel({ distanceM: d, diagonalIn: fovFillingDiagonalIn(air4, d) }),
      air4,
    )
    expect(a.sharpness).toBeCloseTo(1, 2)
    expect(a.exceedsFov).toBe(false)
  })

  it('downscales when the panel is small in the FOV', () => {
    const a = analysePanel(panel({ distanceM: 6, diagonalIn: 60 }), air4)
    expect(a.sharpness).toBeLessThan(0.5)
    // A downscaled panel is limited by the display, so it lands between the
    // on-axis floor and the whole-FOV average.
    const ppd = devicePpd(air4)
    expect(a.effectivePpd).toBeGreaterThanOrEqual(ppd.center - 1e-6)
    expect(a.effectivePpd).toBeLessThanOrEqual(ppd.avgHorizontal + 1e-6)
  })

  it('flags panels that overflow the FOV', () => {
    const d = 4
    const a = analysePanel(
      panel({ distanceM: d, diagonalIn: fovFillingDiagonalIn(air4, d) * 1.5 }),
      air4,
    )
    expect(a.exceedsFov).toBe(true)
    // Overflow cannot buy extra pixels — the display budget is the ceiling.
    expect(a.sharpness).toBeLessThanOrEqual(1.0001)
  })

  it('keeps apparent size and sharpness invariant under distance+scale', () => {
    const near = analysePanel(panel({ distanceM: 3, diagonalIn: 100 }), air4)
    const scaled = rescaleForDistance(panel({ distanceM: 3, diagonalIn: 100 }), 6)
    const far = analysePanel(panel({ distanceM: 6, diagonalIn: scaled }), air4)
    expect(far.angularWidthDeg).toBeCloseTo(near.angularWidthDeg, 6)
    expect(far.sharpness).toBeCloseTo(near.sharpness, 6)
    // Doubling the distance doubles the required diagonal.
    expect(scaled).toBeCloseTo(200, 6)
  })

  it('derives a legible text floor that grows as the panel shrinks', () => {
    const big = analysePanel(panel({ distanceM: 4, diagonalIn: 140 }), air4)
    const small = analysePanel(panel({ distanceM: 4, diagonalIn: 70 }), air4)
    expect(small.minLegibleTextPx).toBeGreaterThan(big.minLegibleTextPx)
  })
})

describe('matchedSourceResolution', () => {
  it('returns the full panel width for a panel filling the FOV', () => {
    const { horizontalDeg } = splitFov(47, 16 / 9)
    const m = matchedSourceResolution(horizontalDeg, 16 / 9, air4)
    expect(m.width).toBe(1920)
    expect(m.height).toBe(1080)
  })

  it('scales down for a smaller panel', () => {
    // A 20-degree panel gets under half the FOV width, so a 1080p source would
    // be throwing away more than half its detail.
    const m = matchedSourceResolution(20, 16 / 9, air4)
    expect(m.width).toBeGreaterThan(700)
    expect(m.width).toBeLessThan(1000)
  })

  it('produces a source that analyses as pixel-perfect', () => {
    for (const angle of [12, 20, 28, 36]) {
      const m = matchedSourceResolution(angle, 16 / 9, air4)
      const diag = diagonalForAngularWidth(angle, 4, 16 / 9)
      const a = analysePanel(
        panel({
          distanceM: 4,
          diagonalIn: diag,
          sourceWidthPx: m.width,
          sourceHeightPx: m.height,
        }),
        air4,
      )
      expect(a.sharpness).toBeGreaterThan(0.97)
      expect(a.sharpness).toBeLessThan(1.03)
    }
  })

  it('keeps dimensions even, and respects a floor', () => {
    for (const angle of [0.5, 3, 7, 19, 33]) {
      const m = matchedSourceResolution(angle, 16 / 9, air4)
      expect(m.width % 2).toBe(0)
      expect(m.height % 2).toBe(0)
      expect(m.width).toBeGreaterThanOrEqual(160)
      expect(m.height).toBeGreaterThanOrEqual(90)
    }
  })

  it('honours non-16:9 aspects', () => {
    const ultra = matchedSourceResolution(26, 21 / 9, air4)
    expect(ultra.width / ultra.height).toBeCloseTo(21 / 9, 1)
  })
})

describe('diagonalForAngularWidth', () => {
  it('inverts the angular width calculation', () => {
    const p = panel({ distanceM: 4.5, diagonalIn: 0 })
    const target = 30
    const diag = diagonalForAngularWidth(target, p.distanceM, p.aspect)
    const a = analysePanel(panel({ distanceM: 4.5, diagonalIn: diag }), air4)
    expect(a.angularWidthDeg).toBeCloseTo(target, 6)
  })
})
