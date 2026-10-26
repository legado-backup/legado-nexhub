# comic_motion_flutter

[English](README.md) | [简体中文](README_zh-CN.md)

Flutter companion package for
[**comic_motion**](../comic_motion) — ready-made widgets that consume the
engine's rendered output so embedding apps write no decoding/animation code.

The core package stays **pure Dart** (zero Flutter deps); this package is a
one-way dependent companion:

```
comic_motion (pure Dart engine)  ←  comic_motion_flutter (widgets)
                                 ←  comic_motion_server (CLI / HTTP)
                                 ←  comic_motion_shaders (GPU realtime)
```

## Widgets

### MotionGifView — playback of the full-render output

| Capability | Detail |
|---|---|
| Seamless placeholder | `firstFramePng` shown instantly, crossfades out (default 150ms, `Duration.zero` = hard cut) when the GIF's first frame finishes decoding |
| Playback control | `playing` externally driven pause/resume; `loop: false` holds on the last frame |
| Reduced motion | Honors `MediaQuery.disableAnimations` — static placeholder, no codec (`respectReducedMotion`) |
| Entrance frames | Optional V2 entrance PNG sequence plays first (blur → sharp reveal), then hands over to the GIF loop |
| Power awareness (W4) | Auto-freeze on `AppLifecycleState` leaving resumed; optional `pauseWhenNotVisible` (freeze off-viewport on scroll notifications, resume when visible again); `enableMotion` hook hands the policy to the app (e.g. low battery) — **no battery dependency in this package** |

```dart
MotionGifView(
  gifBytes: gif,            // MemoryPipelineResult.gifBytes / anim.gif
  firstFramePng: cover,     // MemoryPipelineResult.firstFramePng
  entranceFrames: entrance, // optional: exportEntranceFrames output
)
```

### ParallaxGyroView — interactive parallax over V1 frame sets

Three input drivers (injected stream wins if provided):

1. **Gyroscope** (default) — accelerometer → normalized tilt phase
   (`maxTiltDeg`, default 15°), throttled to ~60fps with a 0.01 dead zone;
2. **Touch fallback** (`touchFallback`) — pan gesture maps half-viewport drag
   to full phase; desktops and gyro-less devices work out of the box;
3. **Injected stream** (`tiltStream`) — `Stream<Offset>` in [-1,1]; no sensor
   subscription. This is the test/mock and custom-driver (joystick etc.) hook.

Interpolation (`smooth`): `true` (default) blends the two neighboring frames
with alpha; `false` switches to the nearest frame (zero-overhead baseline).

Power awareness (W4): same trio as MotionGifView — lifecycle freeze (default),
`pauseWhenNotVisible` scroll-based viewport check (opt-in), and the
`enableMotion` app hook; suppression disconnects the sensor/stream
subscription entirely (zero standing cost), restoration reconnects.

```dart
final sets = await loadInteractionSets(interactiveDir); // disk
// or: loadInteractionSetsFromIndexJson(indexBytes, loadFrame: ...) // assets

ParallaxGyroView(frames: sets.first) // both-export: pick axis per view
```

### PageCurlView — simulated page-curl page turn (W1)

Port of `realtime/index.html`'s Canvas reference to Flutter, matching the
HarmonyOS reader page-turn feel:

- **Curl curvature** — the front page is drawn in vertical strips with
  cylinder-projection compression toward the fold axis; drag speed controls
  page stiffness (`curlStrips`, default 28);
- **Drag tracking** — progress = horizontal offset / view width, clamped [0,1];
- **Overshoot release** — past `commitThreshold` (0.32) or fling velocity,
  the turn lands with a 1.045-peak rubber-band ease; otherwise it springs back;
- **Layered lighting** — strip highlight, paper back-tint, fold shadow cast on
  the next page, edge shadow;
- **Idle breathing** — the whole page sways ±0.4% on a 6s cycle
  (`idleBreath`).

Content is captured **on demand at turn start** (RepaintBoundary → `ui.Image`
snapshots of front/back); gestures repaint through `CustomPainter` with a
repaint listenable — no widget rebuilds, no builder re-invocations per frame.
`onPageTurnStart` / `onPageTurnEnd` are hooks for sound/haptics (the package
does not pull audio/vibration deps). Reduced motion falls back to a plain
slide+fade turn.

```dart
PageCurlView(
  pageCount: chapters.length,
  frontBuilder: (context, i) => ChapterPage(i),
  backBuilder: (context, i) => ChapterPage(i),
  onPageTurnStart: (from, to) => Haptics.lightImpact(),
)
```

### InteractivePageLayer — focus-and-tear interactive reading

Opt-in overlay from a separate entrypoint
(`package:comic_motion_flutter/reader.dart`). Tap the center of a page or
panel: the focused region stays sharp and animated while the rest dims, and
the animation is revealed with a 420ms zigzag tear. Tap again to dismiss.
Three tiers:

- **T0 whole page** — no manifest; uses the existing full-page GIF;
- **T1 panels** — `comic_panels` JSON with normalized rects; focus one panel,
  dim the rest, clip the full-page GIF to the focused panel;
- **T2 per-panel clips** — manifest `clip.asset` plus host-loaded bytes.

```dart
InteractivePageLayer(
  gifBytes: gif,
  firstFramePng: cover,
  child: page,            // omit for a pure overlay (host already draws the page)
  // manifest: PanelManifest.fromBytes(jsonBytes),
  // imageSize: pageSize, // required for T1
  // controller: focusController,
  // gazeStream: gaze,    // normalized [0,1] page coordinates
  // interactive: true,   // host has no gesture layer
)
```

Hosts that own the reader gesture layer call
`state.handleTap(globalPosition)` through a `GlobalKey` instead of enabling
`interactive`. Reduced motion keeps the static first frame and the focus
outline without tear/breathing/scale; power suppression pauses GIF playback
and breathing. `PanelManifest`, `PanelLayout`, and `PanelFocusController` are
plain-Dart pieces and unit-testable without a widget tree.

## Pure-Dart helpers (unit-testable without Flutter)

- `loadInteractionSets(dir)` — load `<...>_interactive/` from disk;
- `loadInteractionSetsFromIndexJson(bytes, loadFrame:)` — load from any
  byte store (assets, network, WASM) via a fetch callback;
- `tiltToPhase(ax, ay, az, maxTiltRad)` — accelerometer → `(phaseX, phaseY)`,
  the reference tilt model (roll/pitch atan2 normalization).

## Memory notes

- Frame-set PNGs stay resident via `Image`'s decode cache (global
  `ImageCache` bound). Keep frame-set resolution ≤ ~1.5× the display size.
- `MotionGifView` decodes through `ui.instantiateImageCodec`; heavy render
  work belongs to the core package's background entry points
  (`processFileInBackground` etc.) — see the core README's threading model.

## Installation

```yaml
dependencies:
  comic_motion_flutter: ^0.2.0
```

Inside this monorepo the packages wire up with `pubspec_overrides.yaml`
path deps; see `comic_motion_flutter/pubspec_overrides.yaml`.

## Requirements

| Item | Requirement |
|---|---|
| Flutter | ≥ 3.22 (Dart ≥ 3.4.0) |
| Core package | `comic_motion: ^1.3.0` |
| Sensors (optional) | `sensors_plus ^6.1.1` — only used when `tiltStream` is null |

## License

Apache-2.0. See [LICENSE](LICENSE).
