/**
 * Device bridge.
 *
 * Read this before wondering why the app cannot just talk to the glasses.
 *
 * The Air 4 Pro is a *display*, not a computer. It attaches over USB-C
 * DisplayPort Alt Mode and the host — phone, PC, console — does all the
 * rendering. The settings that live on the glasses themselves (brightness step,
 * IPD, FOV trim, recentre) are reached through the RayNeo Air Unity SDK's
 * `NativeModule`, which is Android/Unity code running on the host. A browser
 * tab has no path to that: there is no WebUSB or WebHID interface exposed for
 * these controls.
 *
 * So this app talks to a small companion app instead, over a WebSocket on the
 * local network. The companion is a thin Unity/Android shim that receives the
 * JSON ops below and forwards each one to the matching `NativeModule` call.
 * `companion/` in this repo has the C# for it, generated to match this
 * protocol exactly.
 *
 * With no companion running, `SimulatedTransport` handles everything so the
 * designer, the previews and the analysis all work standalone. That is the
 * default, and it is honest about being a simulation rather than pretending a
 * device is attached.
 */

import type { DeviceSettings, Profile, Workspace } from './types'

export const BRIDGE_PROTOCOL_VERSION = 1
export const DEFAULT_BRIDGE_PORT = 8787

export type ConnectionState =
  | 'simulated'
  | 'connecting'
  | 'connected'
  | 'error'
  | 'closed'

/** Head orientation in degrees, as reported by the glasses' 3DoF tracker. */
export interface Pose {
  yawDeg: number
  pitchDeg: number
  rollDeg: number
}

export type BridgeOp =
  | { op: 'device.recenter' }
  | { op: 'device.setLuminance'; mode: number }
  | { op: 'device.setIpd'; ipdMm: number }
  | { op: 'device.changeFov'; scale: number }
  | { op: 'device.fovControlView'; active: boolean }
  | { op: 'device.setShade'; shade: number }
  | { op: 'device.setStereo'; mode: string }
  | { op: 'device.setRefreshRate'; hz: number }
  | { op: 'device.getIpd' }
  | { op: 'workspace.apply'; workspace: Workspace; device: DeviceSettings }
  | { op: 'view.activate'; viewId: string }
  | { op: 'panel.focus'; panelId: string }
  | { op: 'profile.apply'; profile: Profile }

export interface BridgeEvent {
  ev: 'pose' | 'ipd' | 'wearing' | 'log' | 'hello'
  [k: string]: unknown
}

/**
 * How each op maps onto the SDK. Surfaced in the UI so it is obvious which
 * controls are backed by a real SDK call and which are host-side conveniences.
 */
export const SDK_MAPPING: Record<
  string,
  { call: string; note: string; native: boolean }
> = {
  'device.recenter': {
    call: 'NativeModule.Instance.ResetGlassQuat()',
    note: 'Reorients the workspace so straight-ahead becomes wherever you are looking now.',
    native: true,
  },
  'device.setLuminance': {
    call: 'NativeModule.Instance.SetLuminanceMode(int mode)',
    note: 'Four discrete steps, not a continuous slider — the SDK only exposes modes.',
    native: true,
  },
  'device.setIpd': {
    call: 'NativeModule.Instance.SetInterpupilDistance(float 0..1)',
    note: 'The SDK takes a normalised 0–1 value mapped onto 60–70 mm, so the app converts millimetres for you.',
    native: true,
  },
  'device.getIpd': {
    call: 'NativeModule.Instance.GetInterpupilDistance()',
    note: 'Reads back the current IPD in millimetres (60–70).',
    native: true,
  },
  'device.changeFov': {
    call: 'NativeModule.Instance.ChangeFov(int scaleValue)',
    note: 'Note the inverted sign in the SDK: negative widens the FOV, positive narrows it.',
    native: true,
  },
  'device.fovControlView': {
    call: 'NativeModule.Instance.ActiveFovControlView(bool active)',
    note: "Shows or hides the SDK's own FOV adjustment overlay.",
    native: true,
  },
  'device.setShade': {
    call: '—',
    note: 'Electrochromic dimming is a hardware/firmware function; it is not in the Unity SDK surface. The companion approximates it by compositing a dark layer.',
    native: false,
  },
  'device.setStereo': {
    call: '—',
    note: 'Driven by the signal the host sends (3840x1080 side-by-side for full-width 3D), not by an SDK call.',
    native: false,
  },
  'device.setRefreshRate': {
    call: '—',
    note: 'Negotiated by the host display driver over DisplayPort, not settable from the SDK.',
    native: false,
  },
  'workspace.apply': {
    call: 'companion: rebuild panel quads',
    note: 'The companion places one world-space quad per panel and parents it per anchor mode.',
    native: false,
  },
  'view.activate': {
    call: 'companion: toggle quads (+ ResetGlassQuat if the view recentres)',
    note: 'View switching is host-side state; only the optional recentre touches the SDK.',
    native: false,
  },
  'panel.focus': {
    call: 'companion: focus routing',
    note: 'Routes input to one panel and dims the others.',
    native: false,
  },
  'profile.apply': {
    call: 'companion: full sync',
    note: 'Pushes device settings and every workspace in one shot.',
    native: false,
  },
}

/** Convert millimetres of IPD to the normalised value the SDK expects. */
export function ipdMmToNormalised(mm: number, range: [number, number] = [60, 70]) {
  const [lo, hi] = range
  if (hi === lo) return 0
  return Math.min(1, Math.max(0, (mm - lo) / (hi - lo)))
}

export function ipdNormalisedToMm(v: number, range: [number, number] = [60, 70]) {
  const [lo, hi] = range
  return lo + Math.min(1, Math.max(0, v)) * (hi - lo)
}

// ---------------------------------------------------------------------------

interface Transport {
  readonly kind: 'simulated' | 'websocket'
  send(op: BridgeOp): void
  close(): void
}

export interface BridgeCallbacks {
  onState(state: ConnectionState, detail?: string): void
  onPose(pose: Pose): void
  onLog(line: string): void
}

/**
 * Stands in for a real device: replies to every op and generates plausible head
 * motion so the previews are not frozen.
 */
class SimulatedTransport implements Transport {
  readonly kind = 'simulated' as const
  private timer: ReturnType<typeof setInterval> | undefined
  private t = 0

  constructor(private cb: BridgeCallbacks) {
    this.timer = setInterval(() => {
      this.t += 0.05
      // Layered slow sines: reads like someone sitting fairly still rather than
      // a mechanical sweep, and never drifts far enough to be distracting.
      this.cb.onPose({
        yawDeg: Math.sin(this.t * 0.31) * 4.5 + Math.sin(this.t * 0.11) * 2.2,
        pitchDeg: Math.sin(this.t * 0.23 + 1.1) * 2.4,
        rollDeg: Math.sin(this.t * 0.17 + 0.4) * 1.1,
      })
    }, 50)
  }

  send(op: BridgeOp) {
    const map = SDK_MAPPING[op.op]
    this.cb.onLog(
      `simulated · ${op.op}${map?.native ? ` -> ${map.call}` : ''}`,
    )
  }

  close() {
    if (this.timer) clearInterval(this.timer)
    this.timer = undefined
  }
}

class WebSocketTransport implements Transport {
  readonly kind = 'websocket' as const
  private ws: WebSocket | undefined
  private queue: BridgeOp[] = []
  private closedByUs = false

  constructor(
    url: string,
    private cb: BridgeCallbacks,
  ) {
    this.cb.onState('connecting', url)
    try {
      this.ws = new WebSocket(url)
    } catch (err) {
      this.cb.onState('error', String(err))
      return
    }
    this.ws.onopen = () => {
      this.cb.onState('connected', url)
      this.cb.onLog(`connected to ${url}`)
      for (const op of this.queue.splice(0)) this.rawSend(op)
    }
    this.ws.onclose = () => {
      this.cb.onState(this.closedByUs ? 'closed' : 'error', 'socket closed')
    }
    this.ws.onerror = () => {
      // Browsers deliberately withhold the reason for a failed WebSocket
      // handshake, so there is nothing more specific to report here.
      this.cb.onState('error', `could not reach ${url}`)
    }
    this.ws.onmessage = (e) => this.handle(e.data)
  }

  private handle(data: unknown) {
    if (typeof data !== 'string') return
    let msg: BridgeEvent
    try {
      msg = JSON.parse(data) as BridgeEvent
    } catch {
      this.cb.onLog(`unparseable frame: ${String(data).slice(0, 120)}`)
      return
    }
    switch (msg.ev) {
      case 'pose':
        this.cb.onPose({
          yawDeg: Number(msg.yawDeg ?? 0),
          pitchDeg: Number(msg.pitchDeg ?? 0),
          rollDeg: Number(msg.rollDeg ?? 0),
        })
        break
      case 'hello':
        this.cb.onLog(`companion: ${String(msg.name ?? 'unknown')}`)
        break
      case 'log':
        this.cb.onLog(`companion: ${String(msg.line ?? '')}`)
        break
      default:
        this.cb.onLog(`companion event: ${msg.ev}`)
    }
  }

  private rawSend(op: BridgeOp) {
    this.ws?.send(JSON.stringify({ v: BRIDGE_PROTOCOL_VERSION, ...op }))
  }

  send(op: BridgeOp) {
    if (this.ws?.readyState === WebSocket.OPEN) this.rawSend(op)
    else this.queue.push(op)
  }

  close() {
    this.closedByUs = true
    this.ws?.close()
  }
}

export class DeviceBridge {
  private transport: Transport
  private cb: BridgeCallbacks
  state: ConnectionState = 'simulated'

  constructor(cb: BridgeCallbacks) {
    this.cb = {
      ...cb,
      onState: (s, d) => {
        this.state = s
        cb.onState(s, d)
      },
    }
    this.transport = new SimulatedTransport(this.cb)
    this.cb.onState('simulated', 'no companion attached')
  }

  /** Point the bridge at a companion app. Falls back to simulation on failure. */
  connect(host: string, port = DEFAULT_BRIDGE_PORT) {
    this.transport.close()
    const clean = host.replace(/^wss?:\/\//, '').replace(/\/$/, '')
    const url = clean.includes(':') ? `ws://${clean}` : `ws://${clean}:${port}`
    this.transport = new WebSocketTransport(url, this.cb)
  }

  disconnect() {
    this.transport.close()
    this.transport = new SimulatedTransport(this.cb)
    this.cb.onState('simulated', 'disconnected')
  }

  get isSimulated() {
    return this.transport.kind === 'simulated'
  }

  send(op: BridgeOp) {
    this.transport.send(op)
  }

  /** Push the device settings that have real SDK calls behind them. */
  pushDeviceSettings(d: DeviceSettings) {
    this.send({ op: 'device.setLuminance', mode: d.luminanceMode })
    this.send({ op: 'device.setIpd', ipdMm: d.ipdMm })
    this.send({ op: 'device.changeFov', scale: d.fovScale })
    this.send({ op: 'device.fovControlView', active: d.fovControlView })
    this.send({ op: 'device.setShade', shade: d.shade })
    this.send({ op: 'device.setStereo', mode: d.stereo })
    this.send({ op: 'device.setRefreshRate', hz: d.refreshRateHz })
  }
}
