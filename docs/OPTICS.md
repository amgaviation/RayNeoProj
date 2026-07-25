# The optics behind the numbers

Everything the app claims about size, distance and sharpness comes from
`src/lib/optics.ts`, which is covered by tests in `optics.test.ts`. This
explains the reasoning, because several of these results are counter-intuitive
and a couple of them contradict how the specs are usually quoted.

## The mental model

The glasses paint a **fixed window** on the world: 1920×1080 per eye spread
across a 47° diagonal cone. A "virtual screen" is a rectangle placed somewhere
inside that cone.

The consequence people miss: **making a screen bigger and moving it closer are
the same operation.** Your eye responds to the *angle* a thing subtends, not to
its diagonal in inches. A 100" screen at 3 m and a 200" screen at 6 m are
indistinguishable — same angle, same pixels, same everything.

So the honest questions are:

1. What angle does this panel subtend?
2. How many display pixels land inside that angle?

## Splitting the diagonal FOV

A 47° diagonal has to be decomposed into horizontal and vertical components. The
common shortcut is to scale the angle linearly by aspect ratio. That is wrong.

The display is a flat rectangle behind a rectilinear projection, so it is the
**tangents** that carry the aspect ratio, not the angles:

```
tan(diag/2)² = tan(h/2)² + tan(v/2)²      with tan(h/2) = aspect · tan(v/2)
```

For the Air 4 Pro this gives **41.5° × 24.1°**. Linear angle-splitting gives
about 41.0° × 23.0° — off by more than a degree vertically, which is enough to
misjudge whether a panel fits.

## Pixels per degree, and why one number is a lie

Divide 1920 by 41.5° and you get 46.3 px/deg. Divide 1080 by 24.1° and you get
44.9. Same square pixels, same panel — so why do the axes disagree?

Because pixel density is **not uniform across the field of view**. Screen
position goes as tan(θ), so density goes as sec²(θ): it *rises* toward the
periphery. Dividing total pixels by total angle averages over that curve, and
the horizontal axis reaches further out, so its average lands higher.

The number that means something is the **on-axis** density:

```
ppd_centre = (width_px / 2) / tan(h_fov / 2) · (π / 180)  =  44.2 px/deg
```

Both axes agree there, as they must for square pixels. And because density only
rises off-axis, the centre figure is the **floor** — no part of the display is
sparser. That makes it the conservative, honest sharpness figure, and it is what
the app reports.

For reference, 20/20 vision resolves about 60 px/deg. At 44.2 the Air 4 Pro is
comfortable but cannot deliver desk-monitor crispness, and no setting changes
that. The app says so rather than implying a configuration exists that fixes it.

## Counting pixels across a panel

Given a panel subtending angle θ, how many display pixels cover it? Not
`θ × ppd` — that inherits the same linearisation error. Exactly:

```
px(θ) = width_px · tan(θ/2) / tan(h_fov/2)
```

Sanity checks, all of which the tests assert:

- θ = full FOV → exactly `width_px`.
- θ → 0 → converges on the centre density.
- θ = half the FOV → **48.3%** of the pixels, not 50%. The central half of your
  vision gets slightly *fewer* pixels than a linear estimate suggests.

## Where "201 inches" comes from

RayNeo markets the Air 4 Pro as a 201" screen. A size with no distance is
meaningless, so what is the implied distance?

A 201" 16:9 diagonal is 5.11 m. For it to subtend 47°:

```
d = 5.11 / 2 / tan(47°/2) ≈ 5.9 m
```

So **201" at roughly 6 m** — the size that exactly fills the field of view. The
figure is real, not marketing invention, but it is one point on a curve: 100" at
2.9 m is the identical experience. The app shows the fill-the-FOV diagonal for
whatever distance you pick, so the relationship is visible instead of implied.

## Sharpness

```
sharpness = min(display_px_across, panel_width_px) / source_width_px
```

- **1.0** — pixel-for-pixel. The sharpest possible.
- **< 1** — the source is being downscaled; that fraction of the detail is
  discarded before it reaches your eye.
- **> 1** — the source is upscaled; the panel is bigger than its resolution
  justifies and will look soft.

The `min` matters: a panel larger than the FOV cannot receive more pixels than
the FOV contains, so overflow buys nothing.

### The pixel budget

This is the insight that changes how you lay out a workspace. You have **1920
horizontal pixels, total, across 41.5°**. Every panel in view is spending part of
that budget. Three panels side by side means each gets roughly a third of it —
about 640 pixels — no matter what resolution you feed them.

So sending a 1920-wide source to a panel occupying a third of your vision throws
away two thirds of the data *and looks worse* than a matched source, because
downscaling costs contrast at the pixel level. `matchedSourceResolution()`
computes the right size, and the inspector offers it as a one-click fix. Less
data, sharper result.

This is also why the built-in workspaces default to matched resolutions rather
than reflexively 1080p, and why they all analyse at 100%.

## Comfort thresholds

These are judgement calls, and the app states the reasoning so you can disagree
with them.

**Minimum distance 1.5 m.** These are fixed-focus displays with a focal plane
several metres out. Place a panel at 0.5 m and your eyes converge for near work
while still accommodating for far — a vergence-accommodation conflict, and the
main driver of eye strain on this class of hardware. There is no software fix;
the only remedy is to move the panel back and scale it up.

**Comfortable yaw ±30°.** Past that you turn your neck instead of your eyes.
Fine for a glanceable reference panel, tiring as a primary surface.

**Pitch: +15° up, −25° down.** Sustained upward gaze fatigues faster than
downward, so the layout generators bias content below eye level.

**Legible text ≈ 16 arcminutes of cap height.** Converted back into source
pixels, this gives the "smallest legible text" figure, which is far more
actionable than a raw px/deg number when you are deciding whether a panel can
hold a terminal.

**One focal distance per view.** Panels at mixed distances force your eyes to
re-converge on every switch. The arc and grid generators place everything at a
single distance for exactly this reason, and the app counts distinct distances
and flags it.

## Off-axis panels are trapezoids

The previews project actual corners rather than drawing rectangles, and the
`faceWearer` toggle changes the result in a way worth understanding:

- **Off** — the panel stays parallel to the straight-ahead plane. Every corner
  sits at the same depth, so it projects as a plain rectangle, just shifted
  sideways.
- **On** — the panel turns to face you. That rotation puts its near and far
  vertical edges at *different depths*, and since a rectilinear projection
  divides by depth, the result is a genuine trapezoid: the inner edge projects
  taller than the outer one.

Facing the wearer is almost always right — an unturned side panel is viewed at a
slant and its far edge reads blurrier. But the distortion is real either way, and
drawing neat rectangles would hide it.

## 3DoF, and what world-locking cannot do

The Air series tracks **orientation only**. `GetGlassesQualternion()` returns a
quaternion and there is no position anywhere in the SDK.

So "world-locked" means *bearing*-locked. A panel holds its heading when you
look around, which is most of what you want. But walk, and it travels with you.
There is no parallax, no occlusion, no room-scale anything. The app labels this
on every world-anchored panel rather than letting the word "world" imply
capability the hardware does not have.
