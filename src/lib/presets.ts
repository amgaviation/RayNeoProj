/**
 * Built-in workspaces.
 *
 * Every distance here is >= 2.5 m on purpose: the Air series has a fixed focal
 * plane several metres out, so nearby virtual screens fight your eyes. Panels
 * are sized to suit that distance rather than to hit a headline inch count.
 */

import type {
  ActionId,
  Binding,
  DeviceSettings,
  Panel,
  Profile,
  TriggerKind,
  View,
  Workspace,
} from './types'
import { diagonalForAngularWidth, matchedSourceResolution } from './optics'
import { DEVICES, DEFAULT_DEVICE_ID } from './device'

let seq = 0
export const uid = (prefix: string) =>
  `${prefix}_${Date.now().toString(36)}${(seq++).toString(36)}${Math.random()
    .toString(36)
    .slice(2, 6)}`

const ACCENTS = [
  '#38bdf8',
  '#a78bfa',
  '#34d399',
  '#fbbf24',
  '#fb7185',
  '#60a5fa',
  '#f472b6',
  '#4ade80',
]

export interface PanelSeed extends Partial<Panel> {
  title: string
  /** Angular width in degrees; converted to a diagonal at the panel distance. */
  angularWidthDeg?: number
}

export function makePanel(seed: PanelSeed, index = 0): Panel {
  const distanceM = seed.distanceM ?? 4
  const aspect = seed.aspect ?? 16 / 9
  const angularWidthDeg = seed.angularWidthDeg ?? 32
  const diagonalIn =
    seed.diagonalIn ??
    Number(diagonalForAngularWidth(angularWidthDeg, distanceM, aspect).toFixed(1))

  // Default the source resolution to whatever the panel's angular size can
  // actually resolve, rather than reflexively 1080p. A 20°-wide panel only
  // receives about 900 display pixels, so a 1920 source would discard half its
  // detail and look softer than a matched one.
  const matched = matchedSourceResolution(
    angularWidthDeg,
    aspect,
    DEVICES[DEFAULT_DEVICE_ID]!,
  )

  return {
    id: seed.id ?? uid('pan'),
    title: seed.title,
    source: seed.source ?? 'usb-c-display',
    detail: seed.detail,
    yawDeg: seed.yawDeg ?? 0,
    pitchDeg: seed.pitchDeg ?? 0,
    rollDeg: seed.rollDeg ?? 0,
    distanceM,
    diagonalIn,
    aspect,
    sourceWidthPx: seed.sourceWidthPx ?? matched.width,
    sourceHeightPx: seed.sourceHeightPx ?? matched.height,
    anchor: seed.anchor ?? 'body',
    stereo: seed.stereo ?? 'mono',
    faceWearer: seed.faceWearer ?? true,
    opacity: seed.opacity ?? 1,
    curvatureDeg: seed.curvatureDeg ?? 0,
    zOrder: seed.zOrder ?? index,
    visible: seed.visible ?? true,
    dimWhenUnfocused: seed.dimWhenUnfocused ?? true,
    color: seed.color ?? ACCENTS[index % ACCENTS.length]!,
    locked: seed.locked ?? false,
  }
}

function view(name: string, panels: Panel[], over: Partial<View> = {}): View {
  return {
    id: over.id ?? uid('view'),
    name,
    panelIds: panels.map((p) => p.id),
    focusedPanelId: over.focusedPanelId ?? panels[0]?.id,
    recenterOnEnter: over.recenterOnEnter ?? false,
    hotkey: over.hotkey,
    notes: over.notes,
    overrides: over.overrides,
  }
}

function workspace(
  name: string,
  description: string,
  panels: Panel[],
  views: View[],
): Workspace {
  return {
    id: uid('ws'),
    name,
    description,
    panels,
    views,
    activeViewId: views[0]!.id,
  }
}

// ---------------------------------------------------------------------------

function buildDesk(): Workspace {
  const main = makePanel(
    {
      title: 'Main',
      source: 'usb-c-display',
      detail: 'Primary desktop over USB-C',
      distanceM: 4,
      angularWidthDeg: 33,
      yawDeg: 0,
    },
    0,
  )
  const left = makePanel(
    {
      title: 'Reference',
      source: 'browser',
      detail: 'Docs / spec',
      distanceM: 4,
      angularWidthDeg: 22,
      yawDeg: -29,
    },
    1,
  )
  const right = makePanel(
    {
      title: 'Comms',
      source: 'cast',
      detail: 'Chat and mail',
      distanceM: 4,
      angularWidthDeg: 22,
      yawDeg: 29,
    },
    2,
  )
  const notes = makePanel(
    {
      title: 'Scratch',
      source: 'widget',
      detail: 'Notes',
      distanceM: 4,
      angularWidthDeg: 20,
      pitchDeg: -20,
      opacity: 0.9,
    },
    3,
  )

  const panels = [main, left, right, notes]
  return workspace(
    'Desk',
    'Three-up arc plus a scratch panel below eye line. The everyday multitasking layout.',
    panels,
    [
      view('Triple', [main, left, right], {
        hotkey: '1',
        notes: 'All three surfaces up. Glance left and right without moving your head much.',
      }),
      view('Focus', [main], {
        hotkey: '2',
        notes: 'Main only, everything else hidden. Use when reading or writing.',
      }),
      view('Deep work', [main, notes], {
        hotkey: '3',
        recenterOnEnter: true,
        notes: 'Main plus scratch pad, recentred on wherever you are looking.',
      }),
    ],
  )
}

function buildCinema(): Workspace {
  const screen = makePanel(
    {
      title: 'Screen',
      source: 'video',
      detail: 'HDR10 video',
      distanceM: 6,
      // 92% of the horizontal FOV — big without pushing content into the
      // corners where the optics soften.
      angularWidthDeg: 38,
      pitchDeg: -2,
      anchor: 'body',
      sourceWidthPx: 1920,
      sourceHeightPx: 1080,
    },
    0,
  )
  const subs = makePanel(
    {
      title: 'Now playing',
      source: 'widget',
      distanceM: 6,
      angularWidthDeg: 14,
      pitchDeg: -16,
      opacity: 0.75,
      aspect: 32 / 9,
    },
    4,
  )
  const panels = [screen, subs]
  return workspace(
    'Cinema',
    'One screen filling most of the field of view at 6 m — the distance where the published 201" figure actually applies.',
    panels,
    [
      view('Theater', [screen], { hotkey: '1', notes: 'Screen only. Nothing to distract.' }),
      view('Screen + info', [screen, subs], {
        hotkey: '2',
        notes: 'Adds a low transport/status strip below the picture.',
      }),
    ],
  )
}

function buildFlightDeck(): Workspace {
  const chart = makePanel(
    {
      title: 'Chart',
      source: 'cast',
      detail: 'Moving map',
      distanceM: 3.5,
      angularWidthDeg: 30,
      anchor: 'body',
    },
    0,
  )
  const instruments = makePanel(
    {
      title: 'Instruments',
      source: 'widget',
      detail: 'Airspeed / altitude / heading',
      distanceM: 3.5,
      angularWidthDeg: 26,
      pitchDeg: -20,
      aspect: 21 / 9,
      opacity: 0.95,
      anchor: 'head',
    },
    1,
  )
  const wx = makePanel(
    {
      title: 'Weather',
      source: 'browser',
      detail: 'METAR / TAF',
      distanceM: 3.5,
      angularWidthDeg: 18,
      yawDeg: -34,
      pitchDeg: 2,
    },
    2,
  )
  const checklist = makePanel(
    {
      title: 'Checklist',
      source: 'widget',
      distanceM: 3.5,
      angularWidthDeg: 18,
      yawDeg: 34,
      pitchDeg: 2,
    },
    3,
  )

  const panels = [chart, instruments, wx, checklist]
  return workspace(
    'Flight deck',
    'Chart ahead, head-locked instrument strip below, weather and checklist flanking. Reference data you glance at rather than read.',
    panels,
    [
      view('Cruise', [chart, instruments], {
        hotkey: '1',
        notes: 'Map and instruments. The quiet configuration.',
      }),
      view('Planning', [chart, wx, checklist], {
        hotkey: '2',
        notes: 'Swap instruments for weather and checklist.',
      }),
      view('All', [chart, instruments, wx, checklist], {
        hotkey: '3',
        notes: 'Everything up. Dense — expect to move your head.',
      }),
    ],
  )
}

function buildGaming(): Workspace {
  const game = makePanel(
    {
      title: 'Game',
      source: 'game',
      detail: 'Console over USB-C, 120 Hz',
      distanceM: 5,
      angularWidthDeg: 36,
      anchor: 'body',
    },
    0,
  )
  const guide = makePanel(
    {
      title: 'Guide',
      source: 'browser',
      distanceM: 5,
      angularWidthDeg: 20,
      yawDeg: 36,
      opacity: 0.9,
    },
    1,
  )
  const chat = makePanel(
    {
      title: 'Party',
      source: 'cast',
      distanceM: 5,
      angularWidthDeg: 14,
      yawDeg: -36,
      pitchDeg: -6,
      opacity: 0.85,
    },
    2,
  )
  const panels = [game, guide, chat]
  return workspace(
    'Gaming',
    'Large central screen at 5 m with optional guide and party panels parked outside it.',
    panels,
    [
      view('Full screen', [game], { hotkey: '1' }),
      view('Game + guide', [game, guide], { hotkey: '2' }),
      view('Co-op', [game, guide, chat], { hotkey: '3' }),
    ],
  )
}

function buildWalk(): Workspace {
  const hud = makePanel(
    {
      title: 'Navigation',
      source: 'widget',
      detail: 'Turn-by-turn',
      distanceM: 4,
      angularWidthDeg: 14,
      pitchDeg: 8,
      anchor: 'head',
      opacity: 0.7,
    },
    0,
  )
  const music = makePanel(
    {
      title: 'Audio',
      source: 'widget',
      distanceM: 4,
      angularWidthDeg: 10,
      yawDeg: 16,
      pitchDeg: -14,
      anchor: 'head',
      opacity: 0.6,
      aspect: 2,
    },
    1,
  )
  const panels = [hud, music]
  return workspace(
    'Walk-safe',
    'Small, dim, head-locked panels kept out of the centre of vision so the real world stays readable. Keep the electrochromic shade clear in this mode.',
    panels,
    [
      view('Minimal', [hud], { hotkey: '1', notes: 'Navigation only, upper field.' }),
      view('Nav + audio', [hud, music], { hotkey: '2' }),
    ],
  )
}

export const DEFAULT_DEVICE_SETTINGS: DeviceSettings = {
  luminanceMode: 2,
  ipdMm: 64,
  fovScale: 0,
  fovControlView: false,
  refreshRateHz: 120,
  hdr: true,
  stereo: 'mono',
  shade: 0.35,
  followDeadzoneDeg: 12,
  followLagS: 0.45,
}

export function buildDefaultProfile(): Profile {
  const workspaces = [
    buildDesk(),
    buildCinema(),
    buildFlightDeck(),
    buildGaming(),
    buildWalk(),
  ]
  return {
    schemaVersion: 2,
    id: uid('prof'),
    name: 'My Air 4 Pro',
    updatedAt: new Date().toISOString(),
    deviceId: 'air-4-pro',
    device: { ...DEFAULT_DEVICE_SETTINGS },
    workspaces,
    activeWorkspaceId: workspaces[0]!.id,
    bindings: defaultBindings(),
    focusMode: false,
  }
}

export function defaultBindings(): Binding[] {
  const b = (
    kind: TriggerKind,
    trigger: string,
    action: ActionId,
    arg?: string | number,
  ): Binding => ({ id: uid('bind'), kind, trigger, action, arg, enabled: true })

  return [
    b('key', '1', 'view.byIndex', 0),
    b('key', '2', 'view.byIndex', 1),
    b('key', '3', 'view.byIndex', 2),
    b('key', '4', 'view.byIndex', 3),
    b('key', 'Tab', 'panel.focusNext'),
    b('key', 'ArrowRight', 'view.next'),
    b('key', 'ArrowLeft', 'view.prev'),
    b('key', 'r', 'device.recenter'),
    b('key', 'f', 'workspace.toggleFocusMode'),
    b('key', ']', 'device.brightnessUp'),
    b('key', '[', 'device.brightnessDown'),
    b('key', 'c', 'panel.pullToComfort'),
    b('headGesture', 'nod', 'device.recenter'),
    b('headGesture', 'shake', 'workspace.toggleFocusMode'),
    b('touchpad', 'swipe-right', 'view.next'),
    b('touchpad', 'swipe-left', 'view.prev'),
    b('touchpad', 'double-tap', 'panel.focusNext'),
    b('phoneButton', 'volume-up', 'device.brightnessUp'),
    b('phoneButton', 'volume-down', 'device.brightnessDown'),
  ]
}
