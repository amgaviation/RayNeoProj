/**
 * Core data model for the RayNeo Air 4 Pro configurator.
 *
 * Everything the user builds lives in a `Profile`, which is a single
 * serialisable object: it is what gets stored locally, exported to JSON, and
 * pushed to the companion app over the bridge.
 */

/** Anchoring behaviour of a panel relative to the wearer. */
export type AnchorMode =
  /** Rigidly attached to the head — always in view, never moves. HUD style. */
  | 'head'
  /** Follows head yaw with lag/deadzone, so it drifts back into view. */
  | 'body'
  /**
   * Fixed in space. The Air series is 3DoF (orientation only), so this pins
   * yaw/pitch but cannot react to you walking around — there is no parallax.
   */
  | 'world'

/** What is being shown inside a panel. */
export type PanelSource =
  | 'usb-c-display'
  | 'cast'
  | 'browser'
  | 'video'
  | 'game'
  | 'widget'
  | 'camera'

/** Stereo presentation for a panel. */
export type StereoMode = 'mono' | 'sbs-half' | 'sbs-full' | 'anaglyph'

export interface Panel {
  id: string
  title: string
  source: PanelSource
  /** Optional free-text hint (URL, app name, input label). */
  detail?: string

  /** Horizontal angle from straight-ahead, degrees. Negative = left. */
  yawDeg: number
  /** Vertical angle from straight-ahead, degrees. Negative = down. */
  pitchDeg: number
  /** Rotation of the panel about its own normal, degrees. */
  rollDeg: number
  /** Distance from the eyes, metres. Drives apparent size and comfort. */
  distanceM: number

  /** Diagonal size of the panel, inches, at its physical distance. */
  diagonalIn: number
  /** Width / height. 1.777… for 16:9. */
  aspect: number

  /** Source resolution feeding the panel, used for sharpness analysis. */
  sourceWidthPx: number
  sourceHeightPx: number

  anchor: AnchorMode
  stereo: StereoMode
  /**
   * Turn the panel to face the wearer. When false it stays parallel to the
   * straight-ahead plane, so off-axis panels are seen at a slant.
   */
  faceWearer: boolean

  /** 0–1. */
  opacity: number
  /** Horizontal curvature in degrees of arc across the panel. 0 = flat. */
  curvatureDeg: number
  /** Higher draws in front. */
  zOrder: number
  visible: boolean
  /** Dim this panel automatically when it is not the focused one. */
  dimWhenUnfocused: boolean
  /** Accent colour used in the editor and for the focus outline. */
  color: string
  /** Locked panels are skipped by layout generators and drag edits. */
  locked: boolean
}

/**
 * A saved arrangement the wearer can jump to instantly.
 *
 * A view does not duplicate panel geometry — it stores which panels are up,
 * which one has focus, and optional per-panel overrides. That way editing a
 * panel's size once updates it everywhere it appears.
 */
export interface View {
  id: string
  name: string
  /** Optional single-character hint shown in the switcher (1–9). */
  hotkey?: string
  /** Panels visible in this view, in draw order. */
  panelIds: string[]
  /** Which panel receives input. */
  focusedPanelId?: string
  /**
   * Recenter the whole workspace on the wearer's current heading when this
   * view is activated.
   */
  recenterOnEnter: boolean
  /** Per-panel overrides applied only while this view is active. */
  overrides?: Record<string, PanelOverride>
  notes?: string
}

export type PanelOverride = Partial<
  Pick<Panel, 'yawDeg' | 'pitchDeg' | 'distanceM' | 'diagonalIn' | 'opacity' | 'visible'>
>

export interface Workspace {
  id: string
  name: string
  description?: string
  panels: Panel[]
  views: View[]
  activeViewId: string
}

/**
 * Display and comfort settings that map onto the RayNeo Air Unity SDK's
 * `NativeModule` calls. See docs/SDK_MAPPING.md for the exact correspondence.
 */
export interface DeviceSettings {
  /**
   * Brightness step. The SDK exposes `SetLuminanceMode(int mode)` with four
   * discrete steps rather than a continuous value.
   */
  luminanceMode: 0 | 1 | 2 | 3
  /** Interpupillary distance in millimetres. The SDK clamps this to 60–70. */
  ipdMm: number
  /**
   * FOV trim passed to `ChangeFov(int scaleValue)`. Note the SDK's inverted
   * sign: negative widens, positive narrows.
   */
  fovScale: number
  /** Whether the SDK's built-in FOV adjustment overlay is shown. */
  fovControlView: boolean
  /** Panel refresh rate, Hz. */
  refreshRateHz: 60 | 90 | 120
  /** HDR10 passthrough. */
  hdr: boolean
  /** Global stereo mode for the whole output. */
  stereo: StereoMode
  /** Electrochromic shade level, 0 = clear, 1 = fully dimmed. */
  shade: number
  /** Degrees of head yaw tolerated before a `body`-anchored panel follows. */
  followDeadzoneDeg: number
  /** Seconds for a `body`-anchored panel to catch up. */
  followLagS: number
}

export type ActionId =
  | 'view.next'
  | 'view.prev'
  | 'view.byIndex'
  | 'panel.focusNext'
  | 'panel.focusPrev'
  | 'panel.toggleVisible'
  | 'panel.pullToComfort'
  | 'device.recenter'
  | 'device.brightnessUp'
  | 'device.brightnessDown'
  | 'device.toggleShade'
  | 'workspace.toggleFocusMode'

export type TriggerKind = 'key' | 'headGesture' | 'touchpad' | 'phoneButton'

export interface Binding {
  id: string
  kind: TriggerKind
  /** e.g. "1", "Alt+ArrowRight", "nod", "swipe-left", "double-tap". */
  trigger: string
  action: ActionId
  /** Argument for actions that need one, e.g. the view index. */
  arg?: string | number
  enabled: boolean
}

export interface Profile {
  schemaVersion: 2
  id: string
  name: string
  /** ISO timestamp of the last edit. */
  updatedAt: string
  /** Hardware the profile targets. */
  deviceId: string
  device: DeviceSettings
  workspaces: Workspace[]
  activeWorkspaceId: string
  bindings: Binding[]
  /** Dim and defocus everything except the focused panel. */
  focusMode: boolean
}

/** Immutable hardware description used by all the optics math. */
export interface DeviceProfile {
  id: string
  name: string
  /** Per-eye panel resolution. */
  panelWidthPx: number
  panelHeightPx: number
  /** Diagonal field of view, degrees. */
  fovDiagonalDeg: number
  refreshRatesHz: number[]
  peakNits: number
  /** Degrees of freedom the tracker reports. The Air series is 3DoF. */
  dof: 3 | 6
  ipdRangeMm: [number, number]
  luminanceSteps: number
  weightG: number
  hdr: boolean
  notes: string[]
}
