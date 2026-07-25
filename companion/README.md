# Companion app

The web app is an editor. This is the piece that actually talks to the glasses.

## Why it exists

The RayNeo Air 4 Pro is a display, not a computer. It attaches over USB-C
DisplayPort Alt Mode and the host — an Android phone, a PC, a console — does all
the rendering. The settings that live on the glasses (brightness step, IPD, FOV
trim, recentre) are reached through the RayNeo Air Unity SDK's `NativeModule`,
which is Android/Unity code running on that host.

A browser tab cannot call into it. There is no WebUSB or WebHID interface for
these controls, and inventing one is not an option. So the split is:

| Job | Where it runs |
|---|---|
| Design workspaces, analyse optics, edit bindings | The web app |
| Render panels, call `NativeModule`, read head pose | This companion |

Two ways to get a profile across:

1. **Live bridge** — the companion runs a WebSocket server; the web app connects
   and streams ops as you edit. Best for tuning, since you see changes on your
   face immediately.
2. **Baked export** — the web app's Export tab emits
   `RayNeoWorkspaceApplier.cs` with the whole workspace compiled in. No network,
   no runtime parsing. Best for shipping.

## Prerequisites

Per the [RayNeo Air SDK docs](https://rayneo-en.gitbook.io/rayneo-devdoc/air-series/unity-sdk/quick-start/import-sdk):

- Unity 2020.3.37 LTS or newer
- `AirSDK+XR+Unity` package (1.0.3 at time of writing)
- `Cardboard XR Plugin` package (a dependency, installed separately)
- An Android phone on 8.0+ with the glasses attached over USB-C

Setup, in order:

1. Unzip both packages. In **Window → Package Manager → + → Add package from
   disk**, add each one's `package.json`.
2. When the **XR SDK Settings** window appears, click **Accept All**.
3. **Project Settings → Player → Active Input Handling → Both**.
4. **Project Settings → XR Plug-in Management** → enable **Cardboard XR Plugin**.
5. Import the TCLAR SDK samples and copy the sample project's `Plugins` folder
   into yours.
6. Set the launcher activity in your manifest — the SDK will not initialise
   without it:

   ```xml
   <activity android:name="com.tcl.unity.unityadapter.UnityXRSupportActivity"
             android:screenOrientation="portrait"
             android:launchMode="singleTask"
             android:hardwareAccelerated="false"
             android:theme="@style/Theme.UnityAdapter.NoActionBar"
             android:exported="true" />
   ```

7. In `gradle.properties`, add `android.useAndroidX=true` and
   `android.enableJetifier=true`.

## Option 1 — baked export

1. Build your workspace in the web app.
2. **Export → Unity C# → Download**.
3. Drop `RayNeoWorkspaceApplier.cs` into `Assets/Scripts/`.
4. Add an empty GameObject, attach `RayNeoWorkspaceApplier`, and wire up:
   - **Head** → the `Head` transform inside the XRPlugin prefab
   - **BodyRig** → an empty GameObject at the origin, parent for body-anchored panels
   - **PanelPrefab** → a quad with a `MeshRenderer` (it falls back to a built-in
     quad if you leave this empty, which is enough to check placement)
5. Build and run.

Panel geometry is baked to metres in Unity's left-handed, +Z-forward space, so
there is no angle maths at runtime and nothing to get out of sync.

## Option 2 — live bridge

Add `BridgeServer.cs` alongside the applier and set its **Applier** field. It
listens on `0.0.0.0:8787`, and the web app's Connect tab points at the phone's
IP.

Caveats worth knowing before you debug the wrong thing:

- **Both devices must be on the same network.** Phone hotspot works.
- **A page served over HTTPS cannot open a `ws://` socket.** Browsers block
  mixed content with no override. Run the web app over plain HTTP (`npm run
  dev` is fine) or terminate TLS on the companion.
- Add `android.permission.INTERNET` to the manifest.
- Browsers never report *why* a WebSocket handshake failed, so a failure in the
  web app means "unreachable", not anything more specific.

`BridgeServer.cs` here implements the framing and dispatch and is deliberately
minimal — a single connection, no auth. **Do not expose it beyond a trusted
local network**: any client that can reach the port can drive the glasses.

## Protocol

JSON, one object per WebSocket text frame. Full reference:
[`../docs/BRIDGE_PROTOCOL.md`](../docs/BRIDGE_PROTOCOL.md).

Ops in (web app → companion):

```json
{"v":1,"op":"device.setLuminance","mode":2}
{"v":1,"op":"device.setIpd","ipdMm":64}
{"v":1,"op":"device.changeFov","scale":-2}
{"v":1,"op":"device.recenter"}
{"v":1,"op":"view.activate","viewId":"view_abc"}
{"v":1,"op":"profile.apply","profile":{…}}
```

Events out (companion → web app):

```json
{"ev":"hello","name":"rayneo-companion","protocol":1}
{"ev":"pose","yawDeg":1.4,"pitchDeg":-0.2,"rollDeg":0.1}
{"ev":"ipd","ipdMm":64}
{"ev":"log","line":"applied 4 panels"}
```

## The SDK surface

Everything the Air series SDK documents for device control, and what this
companion does with it:

| `NativeModule` call | Used for | Notes |
|---|---|---|
| `GetGlassesQualternion()` | `pose` events | 3DoF orientation. There is no positional tracking. |
| `ResetGlassQuat()` | `device.recenter` | Makes the current heading straight-ahead. |
| `ResetMobileQuat()` | — | Resets the phone-as-pointer ray; not used here. |
| `SetLuminanceMode(int)` | `device.setLuminance` | Four discrete steps, not a continuous value. |
| `GetInterpupilDistance()` | `ipd` events | Returns millimetres, 60–70. |
| `SetInterpupilDistance(float)` | `device.setIpd` | Takes a **normalised 0–1** mapped onto 60–70 mm. |
| `ChangeFov(int)` | `device.changeFov` | **Sign is inverted**: negative widens, positive narrows. |
| `ActiveFovControlView(bool)` | `device.fovControlView` | Shows the SDK's own FOV overlay. |

Not in the SDK, and handled elsewhere:

- **Refresh rate** and **stereo mode** are properties of the DisplayPort signal
  the host sends. Full-width 3D means driving a 3840×1080 side-by-side frame.
- **Electrochromic shade** is a hardware/firmware function. The companion
  approximates it by compositing a dark layer, which dims the *content* but does
  not actually tint the lenses.

## Panel anchoring

Three modes, and the third one has a caveat that matters:

- **Head** — parented to `Head`. Never leaves your view. HUD material only;
  anything you have to read becomes unpleasant fast.
- **Body** — parented to `BodyRig`, which trails head yaw past a deadzone and
  eases in with a time constant. The right default for work surfaces.
- **World** — holds its bearing as you look around. But the Air series is
  **3DoF**: it reports orientation only. Walk, and the panel comes with you.
  There is no parallax, and no amount of code here changes that.
