import { useState } from 'react'
import { useStore } from '../lib/store'
import { DEFAULT_BRIDGE_PORT, SDK_MAPPING } from '../lib/bridge'
import { Card, Toggle } from './ui'
import { HidProbe } from './HidProbe'

/**
 * Companion connection.
 *
 * The honest framing lives here: the browser cannot reach the glasses directly,
 * so either a companion app is listening or everything is simulated. Both states
 * are useful; conflating them is not.
 */
export function ConnectPanel() {
  const connection = useStore((s) => s.connection)
  const detail = useStore((s) => s.connectionDetail)
  const connect = useStore((s) => s.connect)
  const disconnect = useStore((s) => s.disconnect)
  const pushAll = useStore((s) => s.pushAll)
  const log = useStore((s) => s.log)
  const followPose = useStore((s) => s.followPose)
  const setFollowPose = useStore((s) => s.setFollowPose)
  const pose = useStore((s) => s.pose)

  const [host, setHost] = useState('192.168.1.50')
  const [port, setPort] = useState(DEFAULT_BRIDGE_PORT)

  const live = connection === 'connected'

  return (
    <div className="space-y-3">
      <PlatformReality />
      <HidProbe />

      <Card title="Why a companion app is needed">
        <p className="text-[11.5px] leading-relaxed text-ink-400">
          The Air 4 Pro is a display, not a computer. It attaches over USB-C DisplayPort
          and the host — your phone, PC or console — does all the rendering. The settings
          that live on the glasses are reached through the RayNeo Air SDK's{' '}
          <code className="num text-ink-300">NativeModule</code>, which is Android/Unity
          code on that host. No browser API can call it.
        </p>
        <p className="mt-2 text-[11.5px] leading-relaxed text-ink-400">
          So this app edits and analyses, then hands the result to a small companion that
          makes the SDK calls. Point it at one below, or export a profile from the Export
          tab. Everything works without a companion — it is just simulated, and labelled
          that way.
        </p>
      </Card>

      <Card
        title="Bridge"
        right={
          <span
            className="chip"
            style={{
              borderColor: live
                ? 'var(--color-good)'
                : connection === 'error'
                  ? 'var(--color-danger)'
                  : undefined,
              color: live
                ? 'var(--color-good)'
                : connection === 'error'
                  ? 'var(--color-danger)'
                  : undefined,
            }}
          >
            {connection}
          </span>
        }
      >
        <div className="space-y-3">
          <div className="grid grid-cols-[1fr_84px] gap-2">
            <label className="block">
              <span className="label">Companion host</span>
              <input
                className="input num mt-1"
                value={host}
                onChange={(e) => setHost(e.target.value)}
                placeholder="192.168.1.50"
              />
            </label>
            <label className="block">
              <span className="label">Port</span>
              <input
                className="input num mt-1"
                type="number"
                value={port}
                onChange={(e) => setPort(Number(e.target.value))}
              />
            </label>
          </div>

          <div className="flex gap-1.5">
            <button
              className="btn btn-primary flex-1"
              onClick={() => connect(host, port)}
              disabled={connection === 'connecting'}
            >
              {connection === 'connecting' ? 'Connecting…' : 'Connect'}
            </button>
            <button className="btn" onClick={disconnect} disabled={!live && connection !== 'error'}>
              Simulate
            </button>
            <button className="btn" onClick={pushAll} title="Send the whole profile now">
              Push all
            </button>
          </div>

          {detail && <p className="text-[11px] text-ink-500">{detail}</p>}

          {connection === 'error' && (
            <p className="text-[11px] leading-snug text-[var(--color-warn)]">
              Could not reach the companion. Browsers do not report why a WebSocket
              handshake failed, so check that the companion is running, that the host and
              port are right, and that both devices are on the same network. Note that a
              page served over HTTPS cannot open a plain <code>ws://</code> socket — run
              this app over HTTP for local bridging.
            </p>
          )}

          <div className="border-t border-ink-800 pt-3">
            <Toggle
              label="Mirror head motion in the previews"
              checked={followPose}
              onChange={setFollowPose}
              hint={
                live
                  ? 'Using live pose from the glasses tracker.'
                  : 'Using simulated drift so the previews are not frozen.'
              }
            />
            <p className="num mt-1.5 text-[11px] text-ink-500">
              yaw {pose.yawDeg >= 0 ? '+' : ''}
              {pose.yawDeg.toFixed(2)}° · pitch {pose.pitchDeg >= 0 ? '+' : ''}
              {pose.pitchDeg.toFixed(2)}° · roll {pose.rollDeg >= 0 ? '+' : ''}
              {pose.rollDeg.toFixed(2)}°
            </p>
          </div>
        </div>
      </Card>

      <Card title="SDK surface" bodyClass="p-2">
        <div className="space-y-1">
          {Object.entries(SDK_MAPPING).map(([op, m]) => (
            <div key={op} className="rounded-md border border-ink-800 bg-ink-850 px-2 py-1.5">
              <div className="flex items-center gap-1.5">
                <span
                  className="h-1.5 w-1.5 shrink-0 rounded-full"
                  style={{
                    background: m.native ? 'var(--color-good)' : 'var(--color-warn)',
                  }}
                />
                <code className="num text-[11.5px] text-ink-200">{op}</code>
              </div>
              {m.native && (
                <code className="num mt-0.5 block break-all text-[10.5px] text-[var(--color-accent)]">
                  {m.call}
                </code>
              )}
              <p className="mt-0.5 text-[10.5px] leading-snug text-ink-500">{m.note}</p>
            </div>
          ))}
        </div>
        <p className="mt-2 px-1 text-[10.5px] leading-snug text-ink-600">
          Green means a documented SDK call backs it. Amber means the companion or the host
          display pipeline handles it — the profile records the intent either way.
        </p>
      </Card>

      <Card title="Log" bodyClass="p-2">
        <div className="num max-h-52 overflow-auto text-[10.5px] leading-relaxed text-ink-500">
          {log.length === 0 ? (
            <p className="px-1 py-2 text-center">Nothing sent yet.</p>
          ) : (
            [...log].reverse().map((l, i) => (
              <div key={`${i}-${l}`} className="border-b border-ink-900 px-1 py-0.5">
                {l}
              </div>
            ))
          )}
        </div>
      </Card>
    </div>
  )
}

/**
 * What can and cannot reach the glasses from *this* machine.
 *
 * This exists because the constraint used to be buried in prose, and people
 * reasonably expected a button marked "Connect" to connect. On macOS the answer
 * is a flat no, and it is not this app's limitation: RayNeo ships no macOS
 * control software at all. Saying so plainly, on the platform actually being
 * used, beats a paragraph the user has to infer it from.
 */
function PlatformReality() {
  const platform = detectPlatform()

  return (
    <Card title="Can this machine control the glasses?">
      {platform === 'apple' ? (
        <>
          <p className="text-[12px] leading-relaxed text-[var(--color-warn)]">
            Not through any official route, no.
          </p>
          <p className="mt-2 text-[11.5px] leading-relaxed text-ink-400">
            macOS sees the glasses as a plain external monitor over USB-C DisplayPort:
            no driver, no control API, no head-tracker access. RayNeo's own desktop
            software is Windows-only, the RayNeo XR app is phone-only, and the Air SDK
            this app targets is Android/Unity. The bridge below reaches a companion on an
            Android host — pointing it at your Mac will find nothing.
          </p>
          <p className="mt-2 text-[11.5px] leading-relaxed text-ink-400">
            An <em>unofficial</em> route does exist, though, and it is no longer
            speculative:{' '}
            <span className="text-[var(--color-good)]">
              macOS binds these glasses as a HID device
            </span>{' '}
            — confirmed via ioreg on a real Air 4 Pro, two HID nodes at{' '}
            <span className="num">0x1BBB:0xAF50</span>. Glasses in this class have been
            reverse-engineered through exactly that interface for several brands. Whether
            either node carries anything useful is what the probe below determines.
          </p>
          <div className="mt-2.5 space-y-1.5 border-t border-ink-800 pt-2.5">
            <p className="label">What does change a setting on a Mac</p>
            <Row what="Brightness" how="The physical buttons on the glasses — 10 steps." />
            <Row
              what="3D / XR mode"
              how="Brightness + volume up together, then confirm in the RayNeo phone app."
            />
            <Row
              what="Refresh rate"
              how="System Settings → Displays → select the glasses → Refresh Rate."
            />
            <Row
              what="Layout, size, distance"
              how="Designed here, then applied by a Unity/Android app built from the Export tab."
            />
          </div>
          <p className="mt-2.5 text-[11.5px] leading-relaxed text-ink-500">
            So on this machine the app is a planner and a code generator: work out the
            layout, check the optics against the real hardware limits, export it.
            Everything except live device control is fully functional.
          </p>
        </>
      ) : platform === 'android' ? (
        <>
          <p className="text-[12px] leading-relaxed text-[var(--color-good)]">
            Android is the one host that can. The Air SDK is Android/Unity, so a
            companion here can make the real calls.
          </p>
          <p className="mt-2 text-[11.5px] leading-relaxed text-ink-400">
            Run the companion from <code className="num text-ink-300">companion/</code>,
            then connect to it below — or export the Unity applier and build it into your
            own app.
          </p>
        </>
      ) : (
        <>
          <p className="text-[12px] leading-relaxed text-ink-200">Not directly from here.</p>
          <p className="mt-2 text-[11.5px] leading-relaxed text-ink-400">
            The Air SDK is Android/Unity, so live control needs a companion running on an
            Android host — connect to it below. On Windows, RayNeo's own Mirror Studio
            drives the glasses as a display. Everything else in this app works
            regardless: design the layout, check the optics, export it.
          </p>
        </>
      )}
    </Card>
  )
}

function detectPlatform(): 'apple' | 'windows' | 'android' | 'other' {
  if (typeof navigator === 'undefined') return 'other'
  const s = `${navigator.platform ?? ''} ${navigator.userAgent ?? ''}`
  // Android must be tested before Apple: Android user agents contain "Linux",
  // not "Mac", but checking Apple first would still be a needless coin flip.
  if (/Android/i.test(s)) return 'android'
  if (/Mac|iPhone|iPad|iPod/i.test(s)) return 'apple'
  if (/Win/i.test(s)) return 'windows'
  return 'other'
}

function Row({ what, how }: { what: string; how: string }) {
  return (
    <div className="grid grid-cols-[104px_1fr] gap-2">
      <span className="text-[11px] leading-snug text-ink-300">{what}</span>
      <span className="text-[11px] leading-snug text-ink-500">{how}</span>
    </div>
  )
}
