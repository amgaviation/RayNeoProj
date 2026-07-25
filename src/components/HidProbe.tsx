import { useEffect, useState } from 'react'
import {
  alreadyPermitted,
  formatReport,
  hidSupported,
  probeDevice,
  requestDevice,
  summarise,
  type HidDeviceInfo,
} from '../lib/hid'
import { Card } from './ui'

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
  const [copied, setCopied] = useState(false)

  const supported = hidSupported()

  // Devices already granted to this page persist across reloads, so show them
  // without making the user re-pick.
  useEffect(() => {
    if (!supported) return
    void alreadyPermitted().then((d) => {
      if (d.length) setDevices(d)
    })
  }, [supported])

  const probe = async () => {
    setError(undefined)
    setBusy(true)
    try {
      const picked = await requestDevice()
      if (picked.length === 0) {
        setError('No device chosen.')
        return
      }
      const results: HidDeviceInfo[] = []
      for (const d of picked) results.push(await probeDevice(d))
      setDevices(results)
    } catch (e) {
      // A user dismissing the chooser throws; that is not worth an alarm.
      const msg = e instanceof Error ? e.message : String(e)
      setError(/cancel|no device selected/i.test(msg) ? 'Chooser dismissed.' : msg)
    } finally {
      setBusy(false)
    }
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
          <button
            className="btn btn-sm"
            onClick={async () => {
              try {
                await navigator.clipboard.writeText(formatReport(devices))
                setCopied(true)
                setTimeout(() => setCopied(false), 1400)
              } catch {
                setError('Clipboard access was refused.')
              }
            }}
          >
            {copied ? 'Copied' : 'Copy report'}
          </button>
        ) : undefined
      }
    >
      <p className="text-[11.5px] leading-relaxed text-ink-400">
        RayNeo ship no macOS software, but that is not the same as the hardware being
        unreachable. Glasses in this class usually expose a USB HID interface for their
        MCU and sensors, and those have been reverse-engineered for several brands —
        including an open-source RayNeo Air 3s Pro driver that uses macOS IOKit HID.
      </p>
      <p className="mt-2 text-[11.5px] leading-relaxed text-ink-400">
        Whether the <strong className="text-ink-200">Air 4 Pro</strong> does the same, and
        whether a browser is permitted to open it, is a question about your hardware. So
        ask it. This is read-only — it enumerates and listens, and never writes.
      </p>

      {!supported ? (
        <p className="mt-2.5 rounded-md border border-ink-800 bg-ink-850 p-2 text-[11.5px] leading-relaxed text-[var(--color-warn)]">
          This browser has no WebHID, so it cannot probe. Safari does not implement it at
          all. Use Chrome or Edge, or the desktop app — Electron supports it.
        </p>
      ) : (
        <>
          <div className="mt-2.5 flex gap-1.5">
            <button className="btn btn-primary flex-1" onClick={probe} disabled={busy}>
              {busy ? 'Probing…' : 'Probe for the glasses'}
            </button>
            {devices.length > 0 && (
              <button className="btn" onClick={() => setDevices([])}>
                Clear
              </button>
            )}
          </div>
          <p className="mt-1.5 text-[10.5px] leading-snug text-ink-600">
            Plug the glasses in first. The browser will ask which device to allow — pick
            anything that looks like the glasses. If several appear, probe each: they
            usually present separate interfaces for audio, display control and sensors.
          </p>
        </>
      )}

      {error && (
        <p className="mt-2 text-[11px] text-[var(--color-danger)]">{error}</p>
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
          Full descriptor from Terminal (shows what the browser cannot)
        </summary>
        <p className="mt-1.5 text-[11px] leading-relaxed text-ink-500">
          WebHID only reveals interfaces it is allowed to open. For everything the Mac
          sees — every interface, endpoint and its driver — run:
        </p>
        <pre className="num mt-1.5 overflow-x-auto rounded-md border border-ink-800 bg-ink-950 p-2 text-[10.5px] leading-relaxed text-ink-300">
          system_profiler SPUSBDataType
        </pre>
        <p className="mt-1.5 text-[11px] leading-relaxed text-ink-500">
          Look for the glasses under whichever USB bus they are on. The useful details are
          the vendor and product IDs, and whether any interface is listed as HID rather
          than only audio or video. Paste that alongside the copied report above.
        </p>
      </details>
    </Card>
  )
}
