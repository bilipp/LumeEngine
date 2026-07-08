# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

LumeEngine is an FFmpeg 8-based media player engine for Apple platforms (iOS 18+, tvOS 18+, macOS 15+, visionOS 2+), built as a Swift 6 package for the Lume IPTV app. It is an original architecture designed around a stability doctrine: **PLAN.md is the authoritative design document** — §3 catalogs legacy-engine failure modes and the structural countermeasures that are hard requirements, §4 covers architecture decisions (D1–D9), §9 the roadmap. When making design decisions, check PLAN.md first.

## Relationship to Lume (`../Lume`)

The consumer app lives in the sibling repo `../Lume`. Most bug reports and feature requests arrive in Lume terms (channels, EPG, IPTV providers, engine fallback) — when triaging one, first decide whether it belongs in the engine or in the app, and read the relevant Lume code before changing engine behavior.

- Lume ships four engines behind an engine-priority fallback chain: LumeEngine (beta), KSPlayer, VLC, and AVPlayer. The LumeEngine integration code lives in `../Lume/Lume/Views/Player/` (`LumeEngineEngineView.swift`, `LumeEngineCoordinator.swift`, `LumeEngineControlsOverlay.swift`) — engine-side fixes go here, app-side wiring there.
- The consumer contract LumeEngine must satisfy (PLAN.md §2.1) is defined by `../Lume/Lume/Views/Player/` (`TVPlaybackEngine.swift`, `PlaybackClock.swift`, `PlaybackRetryController.swift`, the other `*EngineView.swift` implementations) and `../Lume/Lume/Services/Player/PlayableMedia.swift`.
- Division of responsibility: the engine reports typed errors/events and never retries on its own schedule — reconnect/backoff policy, engine fallback, and UI overlays are Lume's job.
- Lume has its own `CLAUDE.md`; consult it when working on that side.

## Commands

```bash
swift build
swift test                                    # full suite
swift test --filter TimestampUnwrapperTests   # one suite
swift test --filter DecoderTests/testName     # one test
swift run LumeEngineDemo                      # macOS demo app with diagnostics HUD
```

Prerequisites:
- `BinaryDependencies/FFmpeg.xcframework` must exist before anything compiles. Build it once (or after bumping `build/versions.json`):
  ```bash
  curl -sLo build/ffmpeg-8.1.2.tar.xz https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz
  build/scripts/build-ffmpeg.sh macos-arm64    # one slice is enough for local dev
  build/scripts/make-xcframework.sh
  ```
- Tests need a host `ffmpeg` CLI (Homebrew) — fixtures are generated lazily on first test run by `Tests/LumeEngineCoreTests/Fixtures/generate-fixtures.sh` into `TestStreams/generated/` (gitignored, idempotent). `Fixtures.swift` finds Homebrew ffmpeg automatically; override with the `FFMPEG` env var.

CI (`.github/workflows/ci.yml`) builds the macOS FFmpeg slice (cached on `build/versions.json` + scripts + patches hashes) and runs `swift test`; tagged releases build all 10 platform slices and attach the xcframework.

## Architecture

Three-layer target structure (`Package.swift`):

- **`CFFmpeg`** — binary target wrapping `BinaryDependencies/FFmpeg.xcframework` (FFmpeg 8.1.x static libs, LGPL config, built by `build/scripts/`).
- **`Sources/LumeEngineCore`** — the engine, no UI. Uses `internal import CFFmpeg` + library evolution so FFmpeg types never leak into consumers' compiles (apps can link other FFmpeg-based engines without symbol/module collisions — this is why the product is a **dynamic** library; don't change that).
- **`Sources/LumeEngine`** — public facade: `LumePlayer` (`@MainActor @Observable`), `LumePlayerView` (SwiftUI).

### Control plane vs data plane (PLAN.md D1)

This split is the core invariant of the codebase:

- **Control plane = actors.** `PlayerSession` (actor, `Session/`) owns lifecycle, seek, track switching, and event emission. It never touches frames.
- **Data plane = dedicated threads.** Blocking FFmpeg calls (`av_read_frame`, `avcodec_receive_frame`) run on their own threads: `Demuxer` → `VideoDecoder`/`AudioDecoder`/`SubtitleDecoder` → `SystemRenderer`. Stages communicate only through `Concurrency/Channel` — a bounded, blocking, PTS-accounted channel that provides backpressure (producers park when full) and wakeable teardown. Never put a blocking FFmpeg call on an actor; never bypass channels between stages.
- **The main thread is never on the data path.** UI state is a decoupled low-rate observation.

### Key invariants (from PLAN.md §3 — requirements, not style preferences)

- **Session epochs:** a `PlayerSession` opens exactly one URL; a new URL is a new session object. There is no rebuild-in-place, ever. Teardown joins data-plane threads before `avformat_close_input`.
- **Timestamp unwrapping at the demux boundary:** `Time/TimestampUnwrapper` normalizes all PTS/DTS to monotonic 64-bit engine time immediately after `av_read_frame` (handles MPEG-TS 33-bit wraparound). Nothing downstream ever sees raw container time.
- **RAII FFI wrappers:** `FFI/Packet`, `FFI/Frame` etc. wrap `AVPacket*`/`AVFrame*` with deinit-based free. `@unchecked Sendable` is allowed **only** on these audited immutable-after-construction wrappers and on `Channel` — never on state-bearing types. No `Unmanaged` outside FFI.
- **A/V sync is Apple's job:** decoded frames are enqueued into `AVSampleBufferRenderSynchronizer` (`Render/SystemRenderer`). Do not add drop-frame heuristics or hand-rolled clocks.
- **Zero global mutable state:** all configuration is `PlayerConfiguration` passed at session creation. No `static var` knobs.
- **No force unwraps / `as!` / `fatalError` in engine paths**; failures return typed `EngineError`. No `assertionFailure` in production channel/data paths — misuse degrades, never crashes.
- **Never scrape FFmpeg log strings for control flow** (`av_log` is diagnostics only). Silence is never a failure mode: pipelines are supervised, stalls are detected from playhead ground truth, and failures surface as typed `PlayerEvent`s on the session's `AsyncStream`.
- Swift 6 strict concurrency (`swiftLanguageModes: [.v6]`) — keep it honest, don't suppress diagnostics.

### Tests

`Tests/LumeEngineCoreTests/` covers the historically crash-prone areas by design: timestamp wraparound (against a real wrap-seam fixture `wrap.ts`), channel backpressure/teardown, fixture-based decode, playback, and resilience via `Support/TortureHTTPServer.swift` (a fault-injecting local HTTP server — mid-stream errors, stalls, disconnects). New work in demux/decode/time/concurrency should come with tests here; add new media fixtures to `generate-fixtures.sh`, not as committed binaries.
