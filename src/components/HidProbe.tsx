import { useEffect, useState } from 'react'
import {
  KNOWN_VENDOR_IDS,
  alreadyPermitted,
  formatReport,
  hidSupported,
  probeAllPermitted,
  recogniseDevice,
  requestDevice,
  summarise,
  type HidDeviceInfo,
} from '../lib/hid'
import { copyText, downloadText } from '../lib/clipboard'
import { Card } from './ui'

const hex = (n: number) => `0x${n.toString(16).padStart(4, '0').toUpperCase()}`

/**
 * USB probe.
 *
 * Settles a question this app previously answered from assumption: can anything
 * on this machine actually reach the glasses?
 *
 * Read-only by design. It enumerates interfaces and listens; it never writes.
 * Sending speculative bytes to an unknown MCU is how firmware gets bricked.
 */
export function HidProbe() {
  const [devices, setDevices] = useState<HidDeviceInfo[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()
  const [notice, setNotice] = useState<string>()
  const [copied, setCopied] = useState(false)
  // Some glasses stream sensor data only intermittently, so a short window can
  // miss it. Long is opt-in because it blocks the button for that whole time.
  const [listenLong, setListenLong] = useState(false)

  const supported = hidSupported()

  // Devices already granted to this page persist across reloads, so show them
  // without making the user re-pick.
  useEffect(() => {
    if (!supported) return
    void alreadyPermitted().then((d) => {
      if (d.length) setDevices(d)
    })
  }, [supported])

  const probe = async (scope: 'rayneo' | 'all') => {
    setError(undefined)
    setNotice(undefined)
    setBusy(true)
    try {
      const picked = await requestDevice(scope)
      if (picked.length === 0) {
        setError(
          scope === 'rayneo'
            ? `No device matching vendor ${hex(KNOWN_VENDOR_IDS[0] ?? 0)} was offered. That is a result in itself — macOS or the WebHID blocklist is withholding it, since ioreg confirms the glasses bind as a HID device. Try "any device" to see what is on offer.`
            : 'No device chosen.',
        )
        return
      }
      // Probe everything granted so far, not only what was just picked. The
      // Air 4 Pro exposes two HID nodes and a chooser returns one at a time, so
      // picking the second should add to the picture rather than replace it.
      const results = await probeAllPermitted(listenLong ? 10_000 : 1500)
      setDevices(results)
      if (results.length === 1) {
        setNotice(
          'One node probed. ioreg shows the glasses expose two HID nodes, so probe again and pick the other entry — usually one is the frame buttons and the other the vendor-defined interface.',
        )
      }
    } catch (e) {
      // A user dismissing the chooser throws; that is not worth an alarm.
      const msg = e instanceof Error ? e.message : String(e)
      setError(/cancel|no device selected/i.test(msg) ? 'Chooser dismissed.' : msg)
    } finally {
      setBusy(false)
    }
  }

  const onCopy = async () => {
    const report = formatReport(devices)
    const result = await copyText(report)
    if (result.ok) {
      setCopied(true)
      setError(undefined)
      setTimeout(() => setCopied(false), 1400)
      return
    }
    // Copying can fail for reasons the user cannot act on, so save the file
    // instead rather than leaving them stuck with an error.
    downloadText('rayneo-hid-probe.txt', report)
    setNotice(
      `Clipboard was blocked (${result.reason}) so the report was downloaded as rayneo-hid-probe.txt instead.`,
    )
  }

  const verdict = summarise(devices)
  const tone =
    verdict.verdict === 'promising'
      ? 'var(--color-good)'
      : verdict.verdict === 'reachable-but-quiet'
        ? 'var(--color-warn)'
        : 'var(--color-ink-400)'

  return (
    <Card
      title="Probe the USB connection"
      right={
        devices.length > 0 ? (
          <div className="flex gap-1.5">
            <button className="btn btn-sm" onClick={onCopy}>
              {copied ? 'Copied' : 'Copy'}
            </button>
            <button
              className="btn btn-sm"
              onClick={() => downloadText('rayneo-hid-probe.txt', formatReport(devices))}
              title="Save the probe report as a file — always works, even where the clipboard is blocked"
            >
              Save
            </button>
          </div>
        ) : undefined
      }
    >
      <p className="text-[11.5px] leading-relaxed text-ink-400">
        <span className="text-[var(--color-good)]">Confirmed on a real Air 4 Pro:</span>{' '}
        macOS binds these glasses as a HID device —{' '}
        <span className="num text-ink-300">0x1BBB:0xAF50</span>, two HID nodes, on a
        12 Mb/s full-speed interface that is far too slow to be carrying video. So the
        browser route is not closed.
      </p>
      <p className="mt-2 text-[11.5px] leading-relaxed text-ink-400">
        What is still open is whether either node is <em>useful</em>. A{' '}
        <strong className="text-ink-200">vendor-defined usage page</strong> (0xFF00–0xFFFF)
        is the MCU and sensor interface — head tracking, display state. A standard
        consumer-control page would just be the buttons on the frame. Two nodes makes one
        of each plausible; this probe reports which is which.
      </p>
      <p className="mt-2 text-[11.5px] leading-relaxed text-ink-500">
        Read-only. It enumerates and listens, and never writes — sending speculative bytes
        to an unknown MCU is how firmware gets bricked.
      </p>

      {!supported ? (
        <p className="mt-2.5 rounded-md border border-ink-800 bg-ink-850 p-2 text-[11.5px] leading-relaxed text-[var(--color-warn)]">
          This browser has no WebHID, so it cannot probe. Safari does not implement it at
          all. Use Chrome or Edge, or the desktop app — Electron supports it.
        </p>
      ) : (
        <>
          <div className="mt-2.5 flex gap-1.5">
            <button
              className="btn btn-primary flex-1"
              onClick={() => probe('rayneo')}
              disabled={busy}
              title={`Filters the chooser to vendor ${hex(KNOWN_VENDOR_IDS[0] ?? 0)} (TCL)`}
            >
              {busy ? 'Probing…' : 'Probe RayNeo glasses'}
            </button>
            <button className="btn" onClick={() => probe('all')} disabled={busy}>
              Any device
            </button>
            {devices.length > 0 && (
              <button className="btn" onClick={() => setDevices([])}>
                Clear
              </button>
            )}
          </div>
          <label className="mt-1.5 flex cursor-pointer items-start gap-2">
            <input
              type="checkbox"
              className="mt-0.5 shrink-0"
              checked={listenLong}
              onChange={(e) => setListenLong(e.target.checked)}
            />
            <span className="text-[11px] leading-snug text-ink-500">
              Listen for 10 seconds instead of 1.5 — worth trying if nothing streams. Move
              your head while it runs; sensor data may only appear on motion.
            </span>
          </label>
          <p className="mt-1.5 text-[10.5px] leading-snug text-ink-600">
            Plug the glasses in first. The first button filters the chooser to{' '}
            <span className="num">{hex(KNOWN_VENDOR_IDS[0] ?? 0)}</span> (TCL), the vendor
            confirmed on a real Air 4 Pro. If nothing is offered, that is informative in
            itself — try "any device" to see the full list, since glasses often present
            separate interfaces for audio, display control and sensors.
          </p>
        </>
      )}

      {error && (
        <p className="mt-2 text-[11px] leading-snug text-[var(--color-danger)]">{error}</p>
      )}
      {notice && (
        <p className="mt-2 text-[11px] leading-snug text-[var(--color-warn)]">{notice}</p>
      )}

      {devices.length > 0 && (
        <div className="mt-3 space-y-2 border-t border-ink-800 pt-3">
          <p className="text-[11.5px] leading-relaxed" style={{ color: tone }}>
            {verdict.detail}
          </p>

          {devices.map((d, i) => (
            <div
              key={`${d.vendorId}-${d.productId}-${i}`}
              className="rounded-md border border-ink-800 bg-ink-850 p-2"
            >
              <div className="flex items-baseline justify-between gap-2">
                <span className="truncate text-[12.5px] text-ink-100">
                  {d.productName}
                </span>
                <span className="num shrink-0 text-[10.5px] text-ink-500">
                  {d.vendorIdHex}:{d.productIdHex}
                </span>
              </div>
              {recogniseDevice(d.vendorId, d.productId) && (
                <p className="mt-0.5 text-[10.5px] leading-snug text-[var(--color-accent)]">
                  Recognised — {recogniseDevice(d.vendorId, d.productId)!.label}
                </p>
              )}

              <div className="num mt-1 text-[10.5px] leading-relaxed text-ink-500">
                {d.opened ? (
                  <span className="text-[var(--color-good)]">opened ok</span>
                ) : (
                  <span className="text-[var(--color-warn)]">could not open</span>
                )}
                {d.error && <span className="text-[var(--color-danger)]"> · {d.error}</span>}
              </div>

              {d.collections.map((c, ci) => (
                <div key={ci} className="num mt-1 text-[10.5px] leading-relaxed text-ink-500">
                  collection {ci}: usagePage=
                  {c.usagePage !== undefined
                    ? `0x${c.usagePage.toString(16).toUpperCase()}`
                    : '?'}
                  {c.vendorDefined && (
                    <span className="text-[var(--color-accent)]"> vendor-defined</span>
                  )}
                  {c.inputReports.length > 0 && ` · in:${c.inputReports.length}`}
                  {c.outputReports.length > 0 && ` · out:${c.outputReports.length}`}
                  {c.featureReports.length > 0 && ` · feat:${c.featureReports.length}`}
                </div>
              ))}

              {d.observed.length > 0 ? (
                <div className="mt-1.5 border-t border-ink-800 pt-1.5">
                  <p className="label">Live input reports</p>
                  {d.observed.map((o) => (
                    <p
                      key={o.reportId}
                      className="num text-[10.5px] leading-relaxed text-[var(--color-good)]"
                    >
                      id={o.reportId} · {o.byteLength}B · ×{o.count} · {o.sample}
                    </p>
                  ))}
                </div>
              ) : (
                <p className="num mt-1.5 text-[10.5px] text-ink-600">
                  nothing streamed unprompted — may need a wake-up command
                </p>
              )}
            </div>
          ))}
        </div>
      )}

      <details className="mt-3 border-t border-ink-800 pt-2.5">
        <summary className="cursor-pointer text-[11.5px] text-ink-300">
          What Terminal shows that the browser cannot
        </summary>

        <p className="mt-1.5 text-[11px] leading-relaxed text-ink-500">
          Already established on a real Air 4 Pro:{' '}
          <span className="num text-ink-300">0x1BBB:0xAF50</span> at{' '}
          <span className="num text-ink-300">12 Mb/s</span>. That speed is USB full-speed,
          which cannot carry video — DisplayPort runs on separate high-speed lanes. So this
          node is a low-bandwidth control interface, exactly where an MCU or sensor
          endpoint would live.
        </p>

        <p className="mt-2 text-[11px] leading-relaxed text-ink-500">
          The open question is whether macOS binds it as a <em>HID</em> device, which
          System Information does not show. This does — if the glasses appear, they have a
          HID interface:
        </p>
        <pre className="num mt-1.5 overflow-x-auto rounded-md border border-ink-800 bg-ink-950 p-2 text-[10.5px] leading-relaxed text-ink-300">
          {'ioreg -c IOHIDDevice -r -l | grep -iE \'rayneo|"VendorID" = 7099\''}
        </pre>
        <p className="mt-1 text-[10.5px] leading-snug text-ink-600">
          7099 is 0x1BBB in decimal, which is how ioreg prints it.
        </p>

        <p className="mt-2 text-[11px] leading-relaxed text-ink-500">
          And for the full picture — every interface, endpoint and the driver bound to each:
        </p>
        <pre className="num mt-1.5 overflow-x-auto rounded-md border border-ink-800 bg-ink-950 p-2 text-[10.5px] leading-relaxed text-ink-300">
          {'ioreg -p IOUSB -w0 -l | grep -A 30 -i rayneo'}
        </pre>
        <p className="mt-1.5 text-[11px] leading-relaxed text-ink-500">
          No output from the first command means macOS is not exposing a HID interface,
          which would close the browser route regardless of what the hardware supports.
        </p>
      </details>
    </Card>
  )
}
