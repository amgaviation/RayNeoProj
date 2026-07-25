# RayNeo Air 4 Pro Workspace Configurator

A web app for designing what you see through RayNeo Air 4 Pro glasses: lay out
virtual screens, set how far away each one sits, build views you can flip
between with a keypress, and tune the display settings the SDK actually exposes.

Every figure it shows is derived from the published hardware specs — 1920×1080
per eye, 47° diagonal FOV, 120 Hz, HDR10 — and the maths is unit-tested. See
[`docs/OPTICS.md`](docs/OPTICS.md) for the reasoning.

## Read this first

**The Air 4 Pro is a display, not a computer.** It attaches over USB-C
DisplayPort Alt Mode; the host phone, PC or console does all the rendering. The
settings that live on the glasses — brightness step, IPD, FOV trim, recentre —
are reached through the RayNeo Air Unity SDK's `NativeModule`, which is
Android/Unity code running on that host.

**No browser API can call it.** Not WebHID, not WebUSB, not WebXR. So this app
does the design and analysis work, and hands the result to something that can:

- **Export** a Unity `MonoBehaviour` with your workspace compiled in, for a
  project using the RayNeo SDK (`companion/`), or
- **Connect** to a companion app over a WebSocket and stream changes live as you
  edit.

With no companion attached, everything works against a simulated device. That is
the default, and the UI labels it as simulated rather than implying a device is
present. Each control also shows whether a real SDK call backs it or whether it
is host-side — because refresh rate and stereo mode come from the DisplayPort
signal, and no amount of UI here changes them.

## What it does

**Screens.** Add panels, set distance in metres and diagonal in inches, place
them by yaw/pitch/roll, curve them, set opacity and z-order. Source resolution is
per-panel, because it should be.

**Distance that behaves.** "Lock apparent size" scales the diagonal as you move a
panel, so pushing a screen further away keeps it looking identical instead of
shrinking. That is the whole trick behind quoting a big inch count, and it is a
toggle rather than a surprise.

**Views, and switching between them fast.** A view records which panels are up
and which has focus. Press `1`–`4` to jump between them. Views share panel
geometry, so resizing a screen once updates it everywhere. A view can recentre
the workspace on your current heading as it activates.

**Multitasking layouts.** Arc, grid, stack, theater, cockpit and sidecar
generators. They re-flow only the panels in the current view and skip locked
ones, so you can pin one screen and rearrange the rest around it. Arc and grid
place everything at one distance so your eyes never re-converge when you switch.

**Two previews.** A through-the-glasses view that is the *exact* rectilinear
projection the headset performs — if a panel touches the border here it touches
the border on the device — and an orbital 3D view for understanding where
everything sits. Panels outside the field of view are drawn faintly in the
margin, so you can see what you would have to turn to reach.

**Device console.** Brightness (4 steps), IPD (60–70 mm), FOV trim, the SDK's FOV
overlay, electrochromic shade, refresh rate, stereo mode, HDR, and body-follow
deadzone and lag.

**Live analysis.** Apparent size in degrees, sharpness against the source
resolution, effective pixels-per-degree, and the smallest legible text size. Plus
advisories that name the physical reason they are complaining — so you can argue
with them instead of just obeying.

**Bindings.** Keys, touchpad gestures, head gestures and phone buttons mapped to
actions. Key bindings are live in the browser, so you can rehearse a switching
workflow before the glasses are anywhere near your face. The other kinds are
recorded for the companion, and labelled as such.

**Export.** Profile JSON (re-importable), Unity C#, the bridge ops with their
SDK calls, a Markdown report, and an `adb` snippet.

## Quick start

```bash
npm install
npm run dev          # http://localhost:5173
```

```bash
npm test             # optics and projection maths
npm run typecheck
npm run build
```

Nothing is uploaded anywhere. The profile lives in `localStorage`; use
**Export → Profile JSON** for a copy you can keep or move.

## Getting a workspace onto the glasses

Either route is fine; the baked one is simpler.

**Baked.** Export → Unity C# → drop `RayNeoWorkspaceApplier.cs` into a Unity
project with the RayNeo Air SDK imported, wire up three fields, build. Geometry
is pre-converted to Unity's left-handed +Z-forward space, so there is no angle
maths at runtime.

**Live.** Run `companion/BridgeServer.cs` on the host, point the Connect tab at
its IP, and edits stream over as you make them. Note that a page served over
HTTPS cannot open a `ws://` socket, so use plain HTTP locally.

Full setup, including the SDK import steps and the manifest activity the SDK
needs: [`companion/README.md`](companion/README.md).

## Layout

```
src/lib/
  optics.ts      FOV splitting, angular size, pixel counting, comfort audits
  project.ts     3D placement and the rectilinear projection both previews use
  layouts.ts     arc / grid / stack / theater / cockpit / sidecar generators
  device.ts      hardware profiles
  types.ts       the profile data model
  presets.ts     built-in workspaces
  store.ts       state, actions, persistence
  bridge.ts      companion transport + the SDK call mapping
  exporters.ts   JSON, Unity C#, bridge reference, Markdown report
src/components/
  GlassesView    through-the-glasses preview (SVG, exact projection)
  SceneView      orbital 3D preview (three.js)
  ...            inspector, device console, views, bindings, export, connect
companion/       Unity C# for the host side
docs/            optics reasoning, bridge protocol
```

`npm run emit:companion` regenerates `companion/RayNeoWorkspaceApplier.cs` from
the built-in presets. It is deterministic, so the generated shape is reviewable
in a diff.

## Built-in workspaces

| Workspace | For |
|---|---|
| **Desk** | Three-up arc plus a scratch panel below eye line. Everyday multitasking. |
| **Cinema** | One screen filling most of the FOV at 6 m — where the 201" figure applies. |
| **Flight deck** | Chart ahead, head-locked instrument strip below, weather and checklist flanking. |
| **Gaming** | Large central screen at 5 m with guide and party panels parked outside it. |
| **Walk-safe** | Small, dim, head-locked panels kept out of the centre of vision. |

All five analyse clean — their source resolutions are matched to each panel's
angular size, which is free sharpness. `docs/OPTICS.md` explains why.

## Known limits

- **3DoF only.** The Air series reports orientation, never position.
  "World-locked" means bearing-locked: walk, and the panel comes with you. No
  parallax, no room-scale.
- **~44 px/deg on axis**, against roughly 60 for 20/20 vision. Comfortable, but
  never desk-monitor crisp, and no configuration changes that.
- **The bridge has no authentication.** Local trusted networks only.
- **Head gestures and touchpad triggers are recorded, not detected.** A browser
  tab cannot see a head nod; the companion has to implement them.
- Panel *contents* are mock-ups. This tool designs the arrangement — it is not a
  window manager and does not stream real application output.

## Reference

- [RayNeo Air Unity SDK](https://rayneo-en.gitbook.io/rayneo-devdoc/air-series/unity-sdk/quick-start/overview)
  · [SDK import](https://rayneo-en.gitbook.io/rayneo-devdoc/air-series/unity-sdk/quick-start/import-sdk)
  · [`NativeModule` API](https://rayneo-en.gitbook.io/rayneo-devdoc/air-series/unity-sdk/api/nativemodule)
- Hardware specs are the published Air 4 Pro figures: 0.6" micro-OLED, 1920×1080
  per eye, 47° diagonal, 120 Hz, 1200 nits peak, 200,000:1, HDR10, 76 g.
