# Changelog

All notable changes to this project are documented in this file. Versioning
follows [SemVer](https://semver.org/).

## 0.3.0 (2026-10-23)

### `PageMotionMode` — motion only when it matters (interactive layer)

`InteractivePageLayer` gains `motionMode` (default `PageMotionMode.always` —
previous behavior unchanged):

- `onDemand`: the breathing glow plays ONE cycle (~2.4 s forward + reverse)
  on each focus entrance, then rests as a steady outline; unfocus + refocus
  replays it. The page GIF's own rest-after-motion is handled at container
  level by the engine's `EffectConfig.holdSec` (1.7.0).
- New `InteractivePageLayerState.breathing` getter exposes the glow state.
- Runtime mode switches stop/restore the glow (`didUpdateWidget`).
- Gyro/touch parallax (`ParallaxGyroView`) is user-input-driven and
  unaffected by this switch.
- Example app: choice chips toggle both modes live.

## 0.2.0 (2026-10-23)

- **Interactive reading entrypoint** (`package:comic_motion_flutter/reader.dart`,
  kept separate from the main exports): `PanelManifest` / `PanelSpec`
  (`comic_panels` JSON with strict validation), `PanelLayout` (all `BoxFit`
  modes, q0–q3 rotation mapping, smallest-panel hit test), and
  `PanelFocusController` (exclusive/multi focus, tap toggle, gaze dwell and
  release with manual takeover, timer-safe disposal).
- **`InteractivePageLayer`** — three tiers: T0 whole page (no manifest, uses
  the existing full-page GIF), T1 panels (`comic_panels` rects clip the
  full-page GIF to the focused panel), T2 per-panel clips via `panelClips`.
  Tap center to focus and tear-reveal, tap again to dismiss; the rest dims.
  Optional `hoverToFocus`, normalized `gazeStream`, external controller, and
  `handleTap(globalPosition)` for hosts that own the gesture layer (avoids
  fighting a transparent reader overlay).
- **Motion**: 220ms focus (`Cubic(0.2, 0, 0, 1)`), 0.42 dim, 0.22 glow with
  2.4s breathing, 1.012 panel scale, 420ms zigzag tear with a 1.5px
  highlight, 280ms unfocus. Reduced motion keeps the static first frame and
  the focus outline without tear/breathing/scale (no GIF decode); power
  awareness stops GIF playback and breathing when suppressed.
- Tests: manifest validation/round-trip, layout across fit modes and
  rotations, focus timers, T0/T1/T2 widget behavior, reduced motion, dispose.

## 0.1.1 (2026-09-29)

- **Dependencies**: `sensors_plus` `^6.1.1` → `^7.0.0`. The 7.0.0 breaking
  changes are Android build-side only (AGP ≥8.12.1, Gradle wrapper ≥8.13,
  Kotlin 2.2.0); the Dart event API is unchanged. Apps building for Android
  must meet the new toolchain requirements; iOS/desktop/Web are unaffected.
- **Metadata**: package description shortened; changelog fully in English.

## 0.1.0

Initial release. Flutter companion package; depends one-way on the core
`comic_motion` engine (which stays pure Dart with zero Flutter dependencies).

- **MotionGifView**: GIF playback view — `firstFramePng` placeholder with
  seamless crossfade (default 150ms, `Duration.zero` for a hard cut),
  external `playing`/`loop` control (`loop: false` holds the last frame),
  system reduce-motion static frame (`MediaQuery.disableAnimations`, no
  decode), entrance frame sequence played before the GIF loop, automatic
  rebuild on byte change.
- **ParallaxGyroView**: touch/gyro parallax over interaction frame sets —
  three drivers: sensors_plus gyroscope (`tiltToPhase` euler-angle
  normalization, `maxTiltDeg` default 15°, ~60fps throttle + 0.01 dead
  zone), touch drag fallback ("half viewport = full phase") with
  `returnToCenter`, and a `tiltStream` injection stream (when non-null the
  sensors are not subscribed — test mocks and custom drivers); `smooth`
  alpha blending between adjacent frames or nearest-frame hard cut.
- **Pure Dart helpers** (unit-testable without Flutter): `loadInteractionSets`
  (disk directory) / `loadInteractionSetsFromIndexJson` (index.json bytes +
  frame-fetch callback, usable from assets/network/WASM), `tiltToPhase` /
  `degToRad`.
- Tests: tilt-phase mapping, frame-set loading contract (kind/axis validation,
  frame-count consistency), widget tests (injected phase→frame mapping,
  smooth blending, touch fallback and re-centering, empty frame-set fallback,
  placeholder transition, reduce motion, entrance sequence, rebuild on byte
  change).

### Power-aware motion strategy

- **Three-signal aggregation mixin `MotionPowerAware`** (new file
  `lib/src/power_aware.dart`, reusable by custom views): lifecycle
  (suppress when leaving `resumed`, on by default), viewport
  (`pauseWhenNotVisible` opt-in — lazy self-check driven by scroll
  notifications: intersect the RenderBox global rect with the window, freeze
  when scrolled out and restore when back; scroll-based visibility only,
  static occlusion is not detected), and an app policy hook
  (`enableMotion: bool Function()?` — low-battery and other policies are up
  to the app; **this package adds no battery dependency**). Aggregation
  changes fire `onMotionSuppressed` / `onMotionRestored`.
- **MotionGifView**: suppression terminates the frame pump loop (generation
  invalidation, same path as `playing: false`); the bootstrap pump checks
  the aggregated state first. Default parameters
  (`pauseWhenNotVisible: false`, null hook) behave exactly as before.
- **ParallaxGyroView**: suppression fully disconnects sensor/injected
  subscriptions (zero ongoing cost) and reconnects automatically on restore;
  subscription state is driven uniformly by `_syncInput`.
- Tests: freeze-restore transitions across all three paths (viewport /
  lifecycle / hook), 3 cases each (GIF asserted via multi-frame pump
  advance, Gyro via injected phase→frame mapping).

### PageCurlView simulated page-curl turn

- **PageCurlView**: Flutter port of the Canvas reference implementation,
  matching five behaviors of the target page-turn feel — curl curvature
  (vertical strips + cylindrical-projection compression approximation, drag
  speed controls stiffness, `curlStrips` default 28), drag tracking (progress
  = displacement / viewport width), release overshoot (threshold + velocity
  dual criteria, 1.045 peak rubber-band, plain bounce-back below threshold),
  dual-layer lighting (strip highlight / paper back / fold shadow / page-edge
  shadow), and idle breathing micro-motion (±0.4%, 6s period, zero raster
  cost via canvas transform).
- **On-demand page snapshot** (confirmed during design): normally shows the
  native widget; the instant a drag/tap turn starts, both front/back pages
  are captured through a RepaintBoundary as `ui.Image` (pixelRatio clamped to
  [1,3], long edge capped at 2048); capture failure degrades to an instant
  page switch; committing a turn promotes the target snapshot to the current
  page snapshot (zero duplicate capture).
- **Performance**: gesture frames use `CustomPainter` + repaint listenable
  partial repaints — zero widget rebuilds; builder subtrees are cached per
  page; page-index/content-source changes invalidate and re-capture
  automatically.
- **Hooks and fallbacks**: `onPageTurnStart`/`onPageTurnEnd` let apps attach
  their own sound/haptics (no audio/vibration dependencies); system
  reduce-motion falls back to a translate+fade transition (no capture, no
  breathing); `enableTapTurn` tap-half-screen turning, page boundary
  protection, adjustable `initialPage`/`turnDuration`/`commitThreshold`/
  `commitVelocity`.
- Tests: tap-turn callback ordering (Start fired at gesture start, End after
  the commit tween), page boundary protection, short-drag bounce
  (committed=false), long-drag commit, progress tracking (`progressOf` test
  probe), reduce-motion page change, zero builder rebuilds during drags,
  dispose smoke test. The example app gained a page-curl demo page.

> Release ordering: this package consumes the engine's interaction/entrance
> APIs (`exportInteractionFrames` / `exportEntranceFrames`); the engine must
> publish a version containing them first, and this package's
> `pubspec.yaml` lower bound must be raised accordingly (see the core
> package's `doc/release_checklist.md`, section 2).
