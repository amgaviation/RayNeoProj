# Controlling the glasses from a Mac

## The short version

There is **no official way**. RayNeo ship no macOS control software, and their
Air SDK is Android/Unity. macOS treats the Air 4 Pro as a plain external monitor
over USB-C DisplayPort — no driver, no control API, no head-tracker access.

There is a plausible **unofficial** way, and the app can now test for it on your
hardware. Whether it works on the Air 4 Pro is genuinely unknown, and this
document is honest about which parts are established fact and which are not.

## What RayNeo actually provide

| Platform | Software | Can it change display settings? |
|---|---|---|
| Windows | Mirror Studio | Yes — it is the desktop app for these glasses |
| Android | RayNeo app / Air Unity SDK | Yes — `NativeModule` is the documented API |
| iOS | RayNeo XR app | Partially (XR space, 3D mode) |
| **macOS** | **none** | **No** |

On a Mac, settings change through the hardware or the phone:

| Setting | How |
|---|---|
| Brightness | Physical buttons on the glasses — 10 steps |
| 3D / XR mode | Brightness + volume up together, then confirm in the RayNeo phone app |
| Refresh rate | System Settings → Displays → the glasses → Refresh Rate |

That is why this app's device console is honest about which controls map to a
real SDK call: on macOS, none of them can fire, because the SDK is not there.

## The unofficial route: USB HID

Established facts:

- AR glasses in this class expose USB HID interfaces for their MCU and IMU, and
  several have been reverse-engineered without vendor documentation — the
  [XREAL Air Linux driver](https://github.com/calendulish/xrealAirLinuxDriver),
  a [macOS port of it](https://github.com/adidoes/xrealair-sdk-macos), and
  [Void Computing's protocol write-ups](https://voidcomputing.hu/blog/good-bad-ugly/)
  covering the XREAL Air, Rokid Max and Grawoow G530.
- The XREAL Air keeps the MCU and the IMU/DSP pair on separate USB interfaces,
  driven with ordinary HID reads and writes. Its IMU does not stream unprompted —
  you write `[0x02, 0x19, 0x01]` to start it.
- Those drivers read brightness and display mode, not just sensors, so the MCU
  interface is writable in principle.
- A [RayNeo Air 3s Pro SDK](https://github.com/verncat/RayNeo-Air-3S-Pro-OpenVR)
  exists and uses **macOS IOKit HID** directly. So at least one RayNeo Air model
  presents a HID interface that macOS can open.

What is **not** established:

- Whether the **Air 4 Pro** exposes the same interfaces. It is a later model on a
  different chip (Vision 4000), and nothing guarantees protocol continuity.
- Whether a **browser** may open it. WebHID enforces a blocklist, and macOS can
  claim interfaces exclusively.
- Whether anything is **writable** in practice, which is what "configure my
  glasses" actually needs. Reading an IMU is a much lower bar than changing a
  setting.

## Finding out

The app has a probe: **Connect → Probe the USB connection**. It enumerates the
device's HID collections, reports which use vendor-defined usage pages, opens the
interface, and listens for unsolicited input reports. Then it gives a verdict and
a copyable report.

It is **read-only on purpose**. It never calls `sendReport` or
`sendFeatureReport`. Writing speculative bytes to an unknown MCU is how firmware
gets bricked, and no amount of curiosity justifies risking someone's hardware.

Requires Chrome, Edge, or the desktop app. **Safari has no WebHID at all.**

For everything the browser cannot see — every interface and its driver, including
ones WebHID refuses to open — run:

```bash
system_profiler SPUSBDataType
```

### Reading the result

| Probe says | Meaning | Next step |
|---|---|---|
| Streamed input reports | Almost certainly sensor or button data. Live control is worth building. | Decode the reports; work out which bytes are what |
| Vendor-defined interface, opened, silent | Viable. Many glasses need a wake-up command first. | Identify the wake-up sequence — carefully, and on hardware you accept the risk of |
| Opened, only standard usage pages | Probably the audio or display-control interface | Check the other interfaces the device presents |
| Could not open | macOS or the WebHID blocklist is claiming it | `system_profiler` to see whether the interface exists at all |

## If it does work

A HID path would make live control possible on a Mac, and would fold in cleanly:
`DeviceBridge` in `src/lib/bridge.ts` already abstracts the transport behind
`SimulatedTransport` and `WebSocketTransport`, so a `HidTransport` would sit
alongside them without disturbing the rest of the app.

It would remain **unofficial and unsupported**, could break with any firmware
update, and each command would need to be verified rather than assumed. But it is
the only route to native Mac control that is not simply closed.

## If it does not

The honest fallback, and what this app is built to do well: design the workspace
on the Mac, verify it against the real optical limits, and export it — Unity C#
for an Android/Unity app built with the RayNeo SDK, or a JSON profile for a
companion. The optics analysis, the layout tools and the previews never needed a
device connection to be useful.
