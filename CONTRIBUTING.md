# Contributing to LumeEngine

Thanks for your interest in LumeEngine! This guide takes you from a fresh clone to an
open pull request. For the *why* behind the architecture, read
[**PLAN.md**](PLAN.md) first — it is the authoritative design document, and most review
feedback on this repo is a pointer into it.

> **A note on content** — LumeEngine is a *player engine*. It ships with no streams and
> no content, and contributions must not add any. Bug reports must never contain real
> provider credentials, playlist URLs, or stream links. If a bug only reproduces on a
> specific stream, describe the stream's *properties* (container, codecs, bitrate, how
> the timestamps misbehave) — or better, add a fixture that reproduces it.

---

## Table of contents

- [Code of conduct](#code-of-conduct)
- [Ways to contribute](#ways-to-contribute)
- [Development environment](#development-environment)
- [The invariants](#the-invariants)
- [Project layout](#project-layout)
- [Testing](#testing)
- [Coding style](#coding-style)
- [Commit messages](#commit-messages)
- [Pull requests](#pull-requests)
- [Reporting bugs](#reporting-bugs)
- [License](#license)

---

## Code of conduct

Be respectful, constructive, and welcoming. See
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Harassment or hostile behavior of any kind
is not tolerated.

---

## Ways to contribute

- **Report a bug** — open a [GitHub issue](https://github.com/bilipp/LumeEngine/issues)
  with reproduction steps (see [Reporting bugs](#reporting-bugs)).
- **Propose a feature** — open an issue to discuss it *before* you start coding,
  especially if it touches the data plane. The roadmap is PLAN.md §9.
- **Fix something** — focused fixes are very welcome, ideally with a test.
- **Improve docs** — corrections to the README, PLAN.md, or this guide are appreciated.

---

## Development environment

### Requirements

- **Xcode 26** or later (Swift 6.3 toolchain)
- A host **`ffmpeg`** CLI for test-fixture generation — `brew install ffmpeg`. This is
  a *tool*, unrelated to the FFmpeg the engine links; override its path with the
  `FFMPEG` environment variable if it isn't on `PATH`.
- Roughly **1 GB of free disk** for a single-slice setup (FFmpeg source tree ~170 MB,
  static libs ~30 MB, SwiftPM `.build` ~650 MB), and some patience for the first FFmpeg
  build. Building all 10 slices takes about 3 GB.

### First-time setup

```bash
git clone https://github.com/bilipp/LumeEngine.git
cd LumeEngine
swift build
swift test
```

That works with no FFmpeg build: `Package.swift` falls back to the checksum-pinned
`FFmpeg.xcframework` attached to a release and SwiftPM downloads it (~270 MB, cached
afterwards). Most engine work — demux, decode, session, render, subtitles — needs
nothing more.

**Building FFmpeg yourself** is required only when you change `build/versions.json`, the
configure flags in `build/scripts/build-ffmpeg.sh`, or the patch set — otherwise you
would be testing against the released binary rather than your change:

```bash
curl -sLo build/ffmpeg-8.1.2.tar.xz https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz
build/scripts/build-ffmpeg.sh macos-arm64     # ~10-20 min for one slice
build/scripts/make-xcframework.sh             # -> BinaryDependencies/FFmpeg.xcframework
```

`BinaryDependencies/FFmpeg.xcframework` is gitignored, and the manifest **prefers it
whenever it exists** — that is the development override. Delete the directory to go back
to the released artifact. One slice is enough for local work; the full 10-slice matrix
(`build/scripts/platforms.sh`) is only for release binaries, which CI builds on tags.

If you change anything under `build/`, say so in the PR — CI caches the FFmpeg build on
the hash of `build/versions.json`, `build/scripts/**`, and `build/patches/**`, and the
released artifact URL in `Package.swift` has to move in the same change.

---

## The invariants

PLAN.md §3 catalogs the failure modes of the engines that came before this one, and §4
the architecture decisions (D1–D9) that make them structurally impossible. Those are
**hard requirements, not style preferences.** A PR that violates one will be asked to
change approach, however good the diff looks:

- **Control plane = actors, data plane = dedicated threads.** Blocking FFmpeg calls
  (`av_read_frame`, `avcodec_receive_frame`) run on their own threads and communicate
  only through `Concurrency/Channel`. Never put a blocking FFmpeg call on an actor;
  never bypass channels between stages. The main thread is never on the data path.
- **Session epochs.** A `PlayerSession` opens exactly one URL. A new URL is a new
  session object — there is no rebuild-in-place, ever. Teardown joins data-plane threads
  *before* `avformat_close_input`.
- **Timestamps are unwrapped at the demux boundary.** `Time/TimestampUnwrapper`
  normalizes PTS/DTS to monotonic 64-bit engine time immediately after `av_read_frame`.
  Nothing downstream ever sees raw container time.
- **A/V sync is Apple's job.** Frames go to `AVSampleBufferRenderSynchronizer`. Do not
  add drop-frame heuristics or hand-rolled clocks.
- **RAII around FFI.** `FFI/Packet`, `FFI/Frame`, … own their `AVPacket*`/`AVFrame*` and
  free in `deinit`. `@unchecked Sendable` is allowed *only* on those audited wrappers and
  on `Channel`, never on state-bearing types. No `Unmanaged` outside `FFI/`.
- **No force unwraps, `as!`, or `fatalError` in engine paths.** Failures return a typed
  `EngineError`; misuse in channel/data paths degrades, never crashes.
- **Never scrape `av_log` strings for control flow.** Logs are diagnostics. Stalls are
  detected from playhead ground truth and surface as typed `PlayerEvent`s.
- **Zero global mutable state.** Configuration arrives as `PlayerConfiguration` at
  session creation. No `static var` knobs.
- **Swift 6 strict concurrency, honestly.** `swiftLanguageModes: [.v6]` — don't suppress
  diagnostics to get a build through.

The engine also has a deliberate scope boundary: it reports typed errors and events and
**never retries on its own schedule.** Reconnect policy, backoff, engine fallback, and
UI belong to the consuming app (see PLAN.md §2.1).

---

## Project layout

```
Sources/LumeEngineCore/    The engine — no UI
├── Demux/                 Demuxer thread, options, track/media info
├── Decode/                Video/audio decoders, pixel buffer factory
├── Subtitle/              Embedded + external subtitle decode and parsing
├── Render/                SystemRenderer, CMSampleBuffer construction
├── Session/               PlayerSession actor: lifecycle, seek, tracks, events
├── Time/                  MediaTime, TimestampUnwrapper
├── Concurrency/           Channel (bounded, blocking, PTS-accounted)
├── FFI/                   RAII wrappers around FFmpeg objects
├── Media/                 Now Playing, PiP, audio session
└── Errors/                EngineError
Sources/LumeEngine/        Public facade: LumePlayer, LumePlayerView
build/                     FFmpeg build pipeline (manifest, scripts, patches)
DemoApp/                   macOS demo with diagnostics HUD
Tests/LumeEngineCoreTests/ Suite, fixtures, fault-injecting HTTP server
```

`LumeEngineCore` uses `internal import CFFmpeg` so FFmpeg types stay out of its public
interface, and the `LumeEngine` product is a **dynamic** library whose FFmpeg headers are
nested under `lume_ffmpeg/`. Keep both — together they are what lets an app link
LumeEngine *and* another FFmpeg-based engine without symbol or C-module collisions.

Don't add `-enable-library-evolution` (or any other `unsafeFlags`) to the library targets:
SwiftPM rejects unsafe flags in packages consumed as a versioned dependency, so it would
make the package unusable via `.package(url:from:)`.

---

## Testing

```bash
swift test                                     # full suite (64 tests, 12 suites)
swift test --filter TimestampUnwrapperTests    # one suite
swift test --filter DecoderTests/testName      # one test
```

Fixtures are generated lazily on the first run into `TestStreams/generated/`
(gitignored, idempotent) by `Tests/LumeEngineCoreTests/Fixtures/generate-fixtures.sh`.

**Run the suite before opening a PR**, and add tests for what you change. New work in
`Demux/`, `Decode/`, `Time/`, or `Concurrency/` is expected to come with tests — those
are the historically crash-prone areas and the suite is deliberately densest there:

- Timestamp wraparound runs against a real wrap-seam fixture (`wrap.ts`), not a mock.
- Resilience tests run against `Support/TortureHTTPServer.swift`, which injects
  mid-stream errors, 403 token expiry, stalls, throttling, and disconnects.
- Add new media fixtures to `generate-fixtures.sh` — **never commit binary media.**

---

## Coding style

There is no linter in this repo; match the conventions of the surrounding code —
comment density, naming, and idiom. Read like the neighbors. Beyond that:

- Comments explain *why*, especially where the code looks odd because FFmpeg or an Apple
  framework demanded it. Those comments are load-bearing; don't delete them as "noise".
- Keep the build warning-free.
- Public API changes need a matching README/PLAN.md update in the same PR.

---

## Commit messages

Short, imperative summary describing the observable change, under ~72 characters, with
a body explaining the *why* when it isn't obvious. Bug fixes should say what the user
saw, not just what the code does — the history reads like this:

```
Fix TrueHD playback starving into a 1 Hz crackle-stall loop
Fix external subtitles randomly dropping trailing cues
Overhaul seek, buffering, and supervision for real-world IPTV VOD
```

---

## Pull requests

1. **Open an issue first** for features and anything non-trivial in the data plane.
2. **Fork** and branch off `main` (`fix/…`, `feat/…`).
3. Make focused commits.
4. `swift build` warning-free and `swift test` green before you open the PR.
5. Note which invariants your change touches, and why it doesn't break them.
6. Open the PR against `main`, describing *what* changed and *why*, linked to the issue
   (`Closes #123`). For playback fixes, say what content reproduced the bug.

---

## Reporting bugs

Use the [bug report template](https://github.com/bilipp/LumeEngine/issues/new/choose).
The most useful report includes:

- The stream's **properties**, never its URL: container, video/audio codecs, whether it
  is live or VOD, roughly what bitrate, and anything odd about its timestamps.
- The **typed `PlayerEvent`s** the session emitted, and any `EngineError`.
- Whether the demo app (`swift run LumeEngineDemo`) reproduces it — its diagnostics HUD
  is the fastest way to tell a demux problem from a render problem.
- Platform, OS version, and device (hardware decode paths differ per platform).

Security issues go to [`SECURITY.md`](SECURITY.md), not the public tracker.

---

## License

By contributing to LumeEngine, you agree that your contributions will be licensed under
the **MIT License**, the same license that covers the engine's source
(see [`LICENSE`](LICENSE)). Changes under `build/patches/` modify FFmpeg source and are
therefore contributed under the **LGPL 2.1+** instead — see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
