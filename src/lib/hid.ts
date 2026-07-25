/**
 * WebHID probe.
 *
 * Why this exists.
 *
 * The working assumption in this app has been that nothing on macOS can reach
 * the glasses, because RayNeo ships no macOS software and their SDK is
 * Android/Unity. That is true of RayNeo's *own* stack — but it is not the whole
 * picture. AR glasses in this class generally expose a USB HID interface for
 * their MCU and IMU, and those have been reverse-engineered for several brands
 * (XREAL Air, Rokid Max, Grawoow G530). There is also an open-source RayNeo Air
 * 3s Pro SDK that talks to the glasses through macOS IOKit HID, which means the
 * Air series does present a HID interface reachable from macOS.
 *
 * What that does *not* tell us is whether the **Air 4 Pro** exposes the same
 * thing, and whether a browser is allowed to open it. WebHID enforces a
 * blocklist, and macOS may claim some interfaces exclusively. Rather than guess
 * from a different model's notes, this probe asks the actual hardware.
 *
 * It is read-only and deliberately so: enumerate, describe, listen. Writing
 * unknown byte sequences to an MCU is how firmware gets bricked, and nothing
 * here does it.
 *
 * Availability: Chrome, Edge and Opera. **Safari does not implement WebHID**, so
 * the single-file build cannot probe there — the desktop app can, because
 * Electron does.
 */

export interface HidReportInfo {
  reportId: number
  /** Total bytes across the report's items, excluding the report ID. */
  byteLength: number
  itemCount: number
}

export interface HidCollectionInfo {
  usagePage?: number
  usage?: number
  /** True for the vendor-defined range, where custom MCU/IMU protocols live. */
  vendorDefined: boolean
  inputReports: HidReportInfo[]
  outputReports: HidReportInfo[]
  featureReports: HidReportInfo[]
}

export interface HidDeviceInfo {
  productName: string
  vendorId: number
  productId: number
  vendorIdHex: string
  productIdHex: string
  collections: HidCollectionInfo[]
  opened: boolean
  /** Input reports observed while listening, keyed by report ID. */
  observed: { reportId: number; byteLength: number; count: number; sample: string }[]
  /** Populated when opening or listening failed. */
  error?: string
}

/** WebHID is not in every browser, and notably not in Safari. */
export function hidSupported(): boolean {
  return typeof navigator !== 'undefined' && 'hid' in navigator
}

const hex = (n: number, width = 4) =>
  `0x${n.toString(16).padStart(width, '0').toUpperCase()}`

/**
 * Usage pages 0xFF00–0xFFFF are vendor-defined. Reverse-engineered glasses
 * protocols live here, so it is the strongest signal that an interface is worth
 * pursuing.
 */
function isVendorDefined(usagePage?: number) {
  return usagePage !== undefined && usagePage >= 0xff00 && usagePage <= 0xffff
}

function sumReportBytes(report: HIDReportInfo): number {
  let bits = 0
  for (const item of report.items ?? []) {
    bits += (item.reportSize ?? 0) * (item.reportCount ?? 0)
  }
  return Math.ceil(bits / 8)
}

function describeReports(reports: HIDReportInfo[] | undefined): HidReportInfo[] {
  return (reports ?? []).map((r) => ({
    reportId: r.reportId ?? 0,
    byteLength: sumReportBytes(r),
    itemCount: r.items?.length ?? 0,
  }))
}

function describeDevice(d: HIDDevice): HidDeviceInfo {
  return {
    productName: d.productName || '(no product name)',
    vendorId: d.vendorId,
    productId: d.productId,
    vendorIdHex: hex(d.vendorId),
    productIdHex: hex(d.productId),
    collections: (d.collections ?? []).map((c) => ({
      usagePage: c.usagePage,
      usage: c.usage,
      vendorDefined: isVendorDefined(c.usagePage),
      inputReports: describeReports(c.inputReports),
      outputReports: describeReports(c.outputReports),
      featureReports: describeReports(c.featureReports),
    })),
    opened: false,
    observed: [],
  }
}

/** Devices this page has already been granted access to. */
export async function alreadyPermitted(): Promise<HidDeviceInfo[]> {
  if (!hidSupported()) return []
  try {
    const devices = await navigator.hid.getDevices()
    return devices.map(describeDevice)
  } catch {
    return []
  }
}

/**
 * Prompt the user to pick a device.
 *
 * An empty filter list is intentional: we do not know the Air 4 Pro's IDs, and
 * discovering them is the point. The browser's own chooser is the gate, so the
 * user always sees exactly what they are granting.
 */
export async function requestDevice(): Promise<HIDDevice[]> {
  if (!hidSupported()) throw new Error('WebHID is not available in this browser')
  return navigator.hid.requestDevice({ filters: [] })
}

/**
 * Open a device and watch for unsolicited input reports.
 *
 * Some glasses stream IMU data as soon as the interface opens; others need a
 * command written first (the XREAL Air wants `[0x02, 0x19, 0x01]`, for
 * instance). This probe never writes, so silence here means "not streaming
 * unprompted" — not "no IMU".
 */
export async function probeDevice(
  device: HIDDevice,
  listenMs = 1500,
): Promise<HidDeviceInfo> {
  const info = describeDevice(device)
  const seen = new Map<number, { byteLength: number; count: number; sample: string }>()

  const onReport = (event: HIDInputReportEvent) => {
    // The DataView may be a window onto a larger buffer, so respect its offset
    // and length — constructing from `.buffer` alone would report the wrong
    // size and splice in bytes belonging to another report.
    const bytes = new Uint8Array(
      event.data.buffer,
      event.data.byteOffset,
      event.data.byteLength,
    )
    const prev = seen.get(event.reportId)
    if (prev) {
      prev.count++
      return
    }
    seen.set(event.reportId, {
      byteLength: bytes.byteLength,
      count: 1,
      // First few bytes only — enough to recognise a header, not a data dump.
      sample: [...bytes.slice(0, 12)]
        .map((b) => b.toString(16).padStart(2, '0'))
        .join(' '),
    })
  }

  try {
    if (!device.opened) await device.open()
    info.opened = device.opened
    device.addEventListener('inputreport', onReport)
    await new Promise((resolve) => setTimeout(resolve, listenMs))
  } catch (err) {
    info.error = err instanceof Error ? err.message : String(err)
  } finally {
    device.removeEventListener('inputreport', onReport)
    // Leave the device closed; holding it open can block other software from
    // claiming the interface.
    try {
      if (device.opened) await device.close()
    } catch {
      // Nothing useful to do if closing fails.
    }
  }

  info.observed = [...seen.entries()].map(([reportId, v]) => ({ reportId, ...v }))
  return info
}

/** A verdict, in the terms that actually matter for building on this. */
export function summarise(devices: HidDeviceInfo[]): {
  verdict: 'promising' | 'reachable-but-quiet' | 'nothing' | 'unsupported'
  detail: string
} {
  if (!hidSupported()) {
    return {
      verdict: 'unsupported',
      detail:
        'This browser has no WebHID. Chrome, Edge or the desktop app can probe; Safari cannot.',
    }
  }
  if (devices.length === 0) {
    return {
      verdict: 'nothing',
      detail:
        'No device selected yet. Plug the glasses in, press Probe, and pick them from the browser chooser.',
    }
  }

  const streaming = devices.filter((d) => d.observed.length > 0)
  const vendor = devices.filter((d) => d.collections.some((c) => c.vendorDefined))

  if (streaming.length > 0) {
    return {
      verdict: 'promising',
      detail: `${streaming.length} device(s) streamed input reports without being asked. That is very likely sensor or button data, and it means live control from this machine is worth building.`,
    }
  }
  if (vendor.length > 0) {
    return {
      verdict: 'reachable-but-quiet',
      detail: `${vendor.length} device(s) expose a vendor-defined interface that opened successfully, but sent nothing unprompted. Many glasses need a command written to start streaming, so this is still a viable path — it just needs the right wake-up sequence.`,
    }
  }
  const opened = devices.filter((d) => d.opened)
  return {
    verdict: opened.length > 0 ? 'reachable-but-quiet' : 'nothing',
    detail:
      opened.length > 0
        ? 'The device opened but exposes only standard usage pages and sent nothing. Probably the audio or display control interface rather than a sensor one.'
        : 'The device could not be opened. macOS or the browser blocklist may be claiming it — the shell diagnostic will show the full descriptor.',
  }
}

/** A copyable report, so findings can be pasted somewhere useful. */
export function formatReport(devices: HidDeviceInfo[]): string {
  const lines: string[] = [
    '# RayNeo HID probe',
    '',
    `platform: ${typeof navigator !== 'undefined' ? navigator.userAgent : 'unknown'}`,
    `webhid: ${hidSupported() ? 'available' : 'NOT available'}`,
    `devices: ${devices.length}`,
    '',
  ]
  for (const d of devices) {
    lines.push(`## ${d.productName}`)
    lines.push(`vendorId: ${d.vendorIdHex}  productId: ${d.productIdHex}`)
    lines.push(`opened: ${d.opened}${d.error ? `  error: ${d.error}` : ''}`)
    for (const [i, c] of d.collections.entries()) {
      lines.push(
        `  collection ${i}: usagePage=${c.usagePage !== undefined ? hex(c.usagePage) : '?'} usage=${
          c.usage !== undefined ? hex(c.usage, 2) : '?'
        }${c.vendorDefined ? ' (vendor-defined)' : ''}`,
      )
      const fmt = (label: string, rs: HidReportInfo[]) =>
        rs.length
          ? `    ${label}: ${rs
              .map((r) => `id=${r.reportId} ${r.byteLength}B`)
              .join(', ')}`
          : null
      for (const line of [
        fmt('input', c.inputReports),
        fmt('output', c.outputReports),
        fmt('feature', c.featureReports),
      ]) {
        if (line) lines.push(line)
      }
    }
    if (d.observed.length) {
      lines.push('  observed input reports:')
      for (const o of d.observed) {
        lines.push(
          `    id=${o.reportId} ${o.byteLength}B x${o.count}  first bytes: ${o.sample}`,
        )
      }
    } else {
      lines.push('  observed input reports: none (device sent nothing unprompted)')
    }
    lines.push('')
  }
  const s = summarise(devices)
  lines.push(`verdict: ${s.verdict}`, s.detail)
  return lines.join('\n')
}
