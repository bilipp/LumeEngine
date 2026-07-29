# LumeEngine

An FFmpeg 8-based media player engine for Apple platforms, designed from scratch for stability on long-running IPTV streams. Built for [Lume](https://github.com/bilipp/Lume).

[![CI](https://github.com/bilipp/LumeEngine/actions/workflows/ci.yml/badge.svg)](https://github.com/bilipp/LumeEngine/actions/workflows/ci.yml)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2018%20·%20tvOS%2018%20·%20macOS%2015%20·%20visionOS%202-1f1f2e?labelColor=1f1f2e)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white&labelColor=1f1f2e)](https://swift.org)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-8.1.2%20LGPL-007808?labelColor=1f1f2e)](THIRD-PARTY-NOTICES.md)
[![License](https://img.shields.io/badge/license-MIT-blue?labelColor=1f1f2e)](LICENSE)

> **Status: pre-1.0, beta.** The engine plays real IPTV content and ships as an opt-in beta engine in Lume, but the public API is not yet frozen and there is no tagged release. Expect breaking changes on `main`.

An original architecture, not a fork of an existing player. See [PLAN.md](PLAN.md) for the full design document, including the catalog of legacy-engine failure modes this engine makes structurally impossible (§3), the architecture decisions (§4), and the roadmap (§9).

## Highlights

- **FFmpeg 8.1.x**, LGPL configuration, built by an in-repo pipeline (`build/`) into a single `FFmpeg.xcframework` with App Store-clean slices for all platforms — no bundle-ID patching scripts.
- **System-quality A/V sync**: decoded frames feed `AVSampleBufferRenderSynchronizer` — Apple's clock owns sync, rate, HDR tone mapping, and PiP. No hand-rolled drop-frame heuristics.
- **One hardware decode path** (FFmpeg-managed VideoToolbox) with a single, tested software-fallback policy.
- **Honest Swift 6 concurrency**: actors for control, dedicated threads + bounded PTS-accounted channels for data, RAII wrappers around FFmpeg objects, session epochs instead of rebuild-in-place.
- **MPEG-TS 33-bit wraparound** handled at the demux boundary — engine time is monotonic 64-bit, verified by tests against a real wrap-seam fixture.
- **Watchdogs built in**: stall detection from playhead ground truth, supervised decode threads, typed `PlayerEvent`s. Silence is never a failure mode.
- Subtitles (embedded + external files), runtime audio-track switching, Now Playing / remote commands, Picture-in-Picture, audio session lifecycle.

## Scope

The engine decodes and renders, and reports what happened. It does **not** retry on its own schedule: reconnect policy, backoff, engine fallback, and UI belong to the consuming app. Failures surface as typed `EngineError`s and `PlayerEvent`s on the session's `AsyncStream` — never as a log line you have to parse, and never as silence. See PLAN.md §2.

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

## Requirements

- Xcode 26+ (Swift 6.3 toolchain)
- iOS 18+, tvOS 18+, macOS 15+, visionOS 2+
- A host `ffmpeg` CLI for test-fixture generation (`brew install ffmpeg`) — a build-time tool, unrelated to the FFmpeg the engine links

## Building

`BinaryDependencies/FFmpeg.xcframework` must exist before anything compiles. It is built from source by the in-repo pipeline and is deliberately not committed, so **the first build is not a plain `swift build`** — budget 10–20 minutes for the one slice you need:

```bash
# 1. FFmpeg xcframework (once, or after bumping build/versions.json)
curl -sLo build/ffmpeg-8.1.2.tar.xz https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz
build/scripts/build-ffmpeg.sh macos-arm64        # one slice is enough for local dev
build/scripts/make-xcframework.sh

# 2. Engine
swift build
swift test          # 63 tests: unit, fixture-based decode, playback, torture server

# 3. Demo app (macOS)
swift run LumeEngineDemo
```

The full 10-slice matrix (`build/scripts/platforms.sh`) is only needed for release binaries, which CI builds on tags. Test fixtures are generated on first test run via the host `ffmpeg`.

## Layout

- `Sources/LumeEngineCore` — demux, decode, render, session, subtitles, media integration (no UI)
- `Sources/LumeEngine` — public facade: `LumePlayer`, `LumePlayerView`
- `build/` — FFmpeg build pipeline (versions manifest, scripts, patches)
- `DemoApp/` — macOS demo with diagnostics HUD
- `Tests/` — including a fault-injecting HTTP torture server

## Contributing

Contributions are welcome — start with [CONTRIBUTING.md](CONTRIBUTING.md), and read PLAN.md §3–§4 before touching the data plane. The invariants there (control-plane/data-plane split, session epochs, timestamp unwrapping at the demux boundary, Apple owning A/V sync) are hard requirements rather than style preferences, and they are the reason this engine exists.

Security issues: see [SECURITY.md](SECURITY.md) — please don't open a public issue.

## License

Engine source: **MIT** — see [LICENSE](LICENSE).

LumeEngine links **FFmpeg** under the **LGPL 2.1+**, and ships one patch to FFmpeg source under that same license. If you distribute an app built on this engine, [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) tells you exactly what that obliges you to do — and how this repository is arranged to keep it straightforward. The build is verifiably LGPL, not GPL (`--disable-gpl --disable-nonfree`), and the `LumeEngine` product is dynamic so FFmpeg stays relinkable.
