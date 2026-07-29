# LumeEngine

An FFmpeg 8-based media player engine for Apple platforms, designed from scratch for stability on long-running IPTV streams. Built for [Lume](https://github.com/bilipp/Lume).

[![CI](https://github.com/bilipp/LumeEngine/actions/workflows/ci.yml/badge.svg)](https://github.com/bilipp/LumeEngine/actions/workflows/ci.yml)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2018%20·%20tvOS%2018%20·%20macOS%2015%20·%20visionOS%202-1f1f2e?labelColor=1f1f2e)](#installation)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white&labelColor=1f1f2e)](https://swift.org)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-8.1.2%20LGPL-007808?labelColor=1f1f2e)](THIRD-PARTY-NOTICES.md)
[![License](https://img.shields.io/badge/license-MIT-blue?labelColor=1f1f2e)](LICENSE)

> **Status: pre-1.0, beta.** The engine plays real IPTV content and ships as an opt-in beta engine in Lume, but the public API is not yet frozen — expect breaking changes between 0.x releases.

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

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bilipp/LumeEngine.git", from: "0.1.3")
],
targets: [
    .target(name: "YourApp", dependencies: ["LumeEngine"])
]
```

Or in Xcode: **File ▸ Add Package Dependencies…**, paste
`https://github.com/bilipp/LumeEngine.git`, and add the `LumeEngine` library to your
app target. Xcode embeds and signs it for you; if you wire it up by hand, make sure
`LumeEngine` is in **Embed Frameworks** with *Embed & Sign* — the product is a dynamic
library ([on purpose](#license)).

**You do not need the FFmpeg build pipeline to consume the package.** SwiftPM downloads
a prebuilt, checksum-pinned `FFmpeg.xcframework` from the release attached to this
repository — a 117 MB download that expands to ~270 MB, covering all 10 platform slices,
cached across builds. The `build/` directory matters only if you are
working on the engine itself, or want to build FFmpeg differently — see
[CONTRIBUTING.md](CONTRIBUTING.md).

Requires Xcode 26+, and iOS 18+ / tvOS 18+ / macOS 15+ / visionOS 2+.

> **If your app also links another FFmpeg-based player** (KSPlayer/FFmpegKit, VLCKit, …),
> add LumeEngine as a **path or submodule dependency** rather than by URL. The engine
> normally builds with library evolution, which keeps its FFmpeg C module out of your
> compile — but SwiftPM forbids the flag that enables it in version-resolved
> dependencies, so a URL dependency drops it and your build hits conflicting definitions
> of FFmpeg's C types (`enum AVPixelFormat` from `CFFmpeg` vs `Libavutil`). A path
> dependency keeps evolution on and compiles cleanly. This is how Lume itself integrates.

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

## Building from source

Only needed to work *on* the engine — consumers get the FFmpeg binary from the release (see [Installation](#installation)). Cloning the repo and running `swift build` works the same way: with no `BinaryDependencies/FFmpeg.xcframework` present, the manifest falls back to the released artifact and downloads it.

To build FFmpeg yourself instead — required if you change `build/versions.json`, the configure flags, or the patch set — put the result where the manifest prefers it, and it takes precedence over the download:

```bash
# FFmpeg xcframework (10-20 min for one slice)
curl -sLo build/ffmpeg-8.1.2.tar.xz https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz
build/scripts/build-ffmpeg.sh macos-arm64        # one slice is enough for local dev
build/scripts/make-xcframework.sh                # -> BinaryDependencies/FFmpeg.xcframework

swift build
swift test          # 64 tests: unit, fixture-based decode, playback, torture server
swift run LumeEngineDemo                         # macOS demo with diagnostics HUD
```

Testing needs a host `ffmpeg` CLI (`brew install ffmpeg`) to generate fixtures on first run — a build-time tool, unrelated to the FFmpeg the engine links. The full 10-slice matrix (`build/scripts/platforms.sh`) is only needed for release binaries, which CI builds on tags.

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
