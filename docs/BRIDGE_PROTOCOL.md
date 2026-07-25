# Bridge protocol v1

A WebSocket carrying JSON, one object per text frame. The web app is the client;
the companion app is the server, listening on `8787` by default.

## Framing

Every op from the app carries `v` (protocol version) and `op`:

```json
{ "v": 1, "op": "device.setLuminance", "mode": 2 }
```

Every event from the companion carries `ev`:

```json
{ "ev": "pose", "yawDeg": 1.4, "pitchDeg": -0.2, "rollDeg": 0.1 }
```

No request/response correlation and no acks. Ops are fire-and-forget, and state
is reconciled by resending everything (`profile.apply`) rather than by tracking
deltas — with one editor and one device that is simpler and impossible to get
out of sync. A companion seeing an unknown `op` should log it and continue, not
close the connection.

## Ops

### Backed by a real SDK call

| Op | Fields | SDK call |
|---|---|---|
| `device.recenter` | — | `ResetGlassQuat()` |
| `device.setLuminance` | `mode` 0–3 | `SetLuminanceMode(int)` |
| `device.setIpd` | `ipdMm` 60–70 | `SetInterpupilDistance(float 0–1)` |
| `device.getIpd` | — | `GetInterpupilDistance()` → `ipd` event |
| `device.changeFov` | `scale` −10–10 | `ChangeFov(int)` |
| `device.fovControlView` | `active` bool | `ActiveFovControlView(bool)` |

Three details that will bite you:

- **`setIpd` takes millimetres on the wire, but the SDK wants a normalised
  0–1** across the 60–70 mm range. The companion converts:
  `(mm − 60) / (70 − 60)`.
- **`ChangeFov`'s sign is inverted.** Negative widens the field of view,
  positive narrows it. This is the SDK's convention, not a mistake here.
- **`ChangeFov` is a relative nudge, not an absolute setting.** The app sends
  the absolute value it wants; the companion must apply the difference from what
  it last sent, or repeated ops will walk the FOV away.

### Host-side, no SDK equivalent

| Op | Fields | Reality |
|---|---|---|
| `device.setShade` | `shade` 0–1 | Electrochromic dimming is a hardware/firmware function. Not in the Unity SDK. |
| `device.setStereo` | `mode` | A property of the signal the host sends. Full-width 3D is a 3840×1080 side-by-side frame. |
| `device.setRefreshRate` | `hz` | Negotiated by the host display driver over DisplayPort. |

These are recorded so a companion can act on them by other means, and the app
labels them as host-side rather than implying the SDK can set them.

### Workspace

| Op | Fields | Effect |
|---|---|---|
| `workspace.apply` | `workspace`, `device` | Rebuild every panel quad. |
| `view.activate` | `viewId` | Toggle panel visibility; recentre if the view asks for it. |
| `panel.focus` | `panelId` | Route input to one panel, dim the rest. |
| `profile.apply` | `profile` | Full sync: device settings plus every workspace. |

## Events

| Event | Fields | Notes |
|---|---|---|
| `hello` | `name`, `protocol` | Sent on connect. |
| `pose` | `yawDeg`, `pitchDeg`, `rollDeg` | Signed degrees about zero. From `GetGlassesQualternion()`. ~20 Hz is plenty. |
| `ipd` | `ipdMm` | Read back from the device, in millimetres. |
| `wearing` | `on` bool | Optional; the Air series does not document wear detection. |
| `log` | `line` | Free text, shown in the app's Connect tab. |

`pose` reports **orientation only**. The Air series is 3DoF, so there is no
position to report and no parallax to render.

## Constraints

- **A page served over HTTPS cannot open a `ws://` socket.** Browsers block
  mixed content with no user override. Serve the app over plain HTTP for local
  bridging, or terminate TLS at the companion and use `wss://`.
- **Browsers never reveal why a WebSocket handshake failed.** A connection error
  in the app means "unreachable" and nothing more specific; check the companion
  is running, the host and port are right, and both devices share a network.
- **There is no authentication.** Anything that can reach the port can drive the
  glasses. Keep it on a trusted local network, and do not ship the bridge in a
  release build.

## Why not talk to the glasses directly?

Worth stating plainly, because it is the first thing anyone asks.

The Air 4 Pro is a display. It attaches over USB-C DisplayPort Alt Mode; the
host does the rendering, and the glasses show the frames. Device settings live
behind the RayNeo Air Unity SDK's `NativeModule`, which is Android/Unity code
running on the host.

The browser APIs that could plausibly reach hardware do not help:

- **WebHID / WebUSB** — no documented HID interface for these controls, and the
  USB link is claimed by the platform's DisplayPort driver.
- **WebXR** — the Air series presents as an external monitor, not an XR device.
  There is no runtime to bind to.
- **DisplayPort AUX / DDC** — unreachable from a browser at any level.

So a companion is not a workaround, it is the only correct architecture. Without
one, the app still does the whole design and analysis job against a simulated
device, and says so rather than pretending otherwise.
