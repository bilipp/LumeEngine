# LumeEngine

An FFmpeg 8-based media player engine for Apple platforms (iOS 18+, tvOS 18+, macOS 15+, visionOS 2+), built for [Lume](https://github.com/bilipp/Lume) and designed from scratch for stability on long-running IPTV streams.

An original architecture, not a fork of an existing player. See [PLAN.md](PLAN.md) for the full design document, including the catalog of legacy-engine failure modes this engine makes structurally impossible (§3) and the roadmap (§9).

## Highlights

- **FFmpeg 8.1.x**, LGPL configuration, built by an in-repo pipeline (`build/`) into a single `FFmpeg.xcframework` with App Store-clean slices for all platforms — no bundle-ID patching scripts.
- **System-quality A/V sync**: decoded frames feed `AVSampleBufferRenderSynchronizer` — Apple's clock owns sync, rate, HDR tone mapping, and PiP. No hand-rolled drop-frame heuristics.
- **One hardware decode path** (FFmpeg-managed VideoToolbox) with a single, tested software-fallback policy.
- **Honest Swift 6 concurrency**: actors for control, dedicated threads + bounded PTS-accounted channels for data, RAII wrappers around FFmpeg objects, session epochs instead of rebuild-in-place.
- **MPEG-TS 33-bit wraparound** handled at the demux boundary — engine time is monotonic 64-bit, verified by tests against a real wrap-seam fixture.
- **Watchdogs built in**: stall detection from playhead ground truth, supervised decode threads, typed `PlayerEvent`s. Silence is never a failure mode.
- Subtitles (embedded + external files), runtime audio-track switching, Now Playing / remote commands, Picture-in-Picture, audio session lifecycle.

## Usage

```swift
import LumeEngine

let player = LumePlayer()                    // @MainActor @Observable
try await player.load(url: "https://example.com/stream.m3u8")
player.play()

// SwiftUI
LumePlayerView(player: player)

// Lower-level control plane
let session = PlayerSession(configuration: .init())
let info = try await session.open(url: url)
await session.play()
for await event in session.events { ... }
```

## Building

```bash
# 1. FFmpeg xcframework (once, or after bumping build/versions.json)
curl -sLo build/ffmpeg-8.1.2.tar.xz https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz
build/scripts/build-ffmpeg.sh macos-arm64        # + other slices as needed
build/scripts/make-xcframework.sh

# 2. Engine
swift build
swift test          # 51 tests: unit, fixture-based decode, playback, torture server

# 3. Demo app (macOS)
swift run LumeEngineDemo
```

Test fixtures are generated on first test run via the host `ffmpeg` (Homebrew).

## Layout

- `Sources/LumeEngineCore` — demux, decode, render, session, subtitles, media integration (no UI)
- `Sources/LumeEngine` — public facade: `LumePlayer`, `LumePlayerView`
- `build/` — FFmpeg build pipeline (versions manifest, scripts, patches)
- `DemoApp/` — macOS demo with diagnostics HUD
- `Tests/` — including a fault-injecting HTTP torture server

## License

Engine code: MIT. Binary dependencies: FFmpeg (LGPL 2.1+, dynamic-linking obligations documented in PLAN.md §5).
