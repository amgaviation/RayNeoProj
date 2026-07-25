import type { DeviceProfile } from './types'

/**
 * Hardware profiles.
 *
 * The Air 4 Pro numbers are the published specs: 1920x1080 per eye from 0.6"
 * micro-OLED panels, 47° diagonal FOV, 120 Hz, 1200 nits peak, HDR10.
 * `dof: 3` is the important one for this app — the Air series reports
 * orientation only, so nothing here can react to the wearer translating.
 */
export const DEVICES: Record<string, DeviceProfile> = {
  'air-4-pro': {
    id: 'air-4-pro',
    name: 'RayNeo Air 4 Pro',
    panelWidthPx: 1920,
    panelHeightPx: 1080,
    fovDiagonalDeg: 47,
    refreshRatesHz: [60, 90, 120],
    peakNits: 1200,
    dof: 3,
    ipdRangeMm: [60, 70],
    luminanceSteps: 4,
    weightG: 76,
    hdr: true,
    notes: [
      '3DoF orientation tracking only — no positional tracking or parallax.',
      'Tethered display over USB-C DisplayPort Alt Mode; the host does the rendering.',
      'Full-width 3D uses a 3840x1080 side-by-side signal (1920 per eye).',
    ],
  },
  'air-3s-pro': {
    id: 'air-3s-pro',
    name: 'RayNeo Air 3s Pro',
    panelWidthPx: 1920,
    panelHeightPx: 1080,
    fovDiagonalDeg: 46,
    refreshRatesHz: [60, 120],
    peakNits: 650,
    dof: 3,
    ipdRangeMm: [60, 70],
    luminanceSteps: 4,
    weightG: 76,
    hdr: false,
    notes: ['3DoF orientation tracking only.', 'Included for profile comparison.'],
  },
}

export const DEFAULT_DEVICE_ID = 'air-4-pro'

export function getDevice(id: string): DeviceProfile {
  return DEVICES[id] ?? (DEVICES[DEFAULT_DEVICE_ID] as DeviceProfile)
}
