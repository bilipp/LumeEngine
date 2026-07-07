# LumeEngine — Implementation Plan

A ground-up FFmpeg-based player engine for Apple platforms (iOS, iPadOS, tvOS, macOS, visionOS), built as a standalone Swift package and integrated into Lume as its primary engine. Not a fork of any existing player — an original architecture designed for stability first, with feature parity against the most capable commercial FFmpeg players on the platform.

---

## 1. Goals & non-goals

**Goals**

1. **Stability over everything.** Every failure mode Lume works around in the third-party engines it shipped with must be impossible by design (see §3).
2. **Latest FFmpeg.** Pinned to FFmpeg **8.1.2** (current stable, 2026-06), with our own upgrade path — never stuck on an old fork.
3. **Full modern feature set**: HW decode, HDR10/HLG/DV, libass subtitles, PiP, Now Playing, trickplay, live rewind, zero-delay switching, upscaling, 360°/VR, Blu-ray ISO.
4. **Reusable**: engine code MIT/Apache-2.0, FFmpeg built in LGPL configuration, libass (ISC) — usable beyond AGPL Lume.
5. **First-class Lume integration**: drop-in `PlayerEngineKind` case conforming to Lume's existing engine contract and `TVPlaybackEngine`.

**Non-goals (v1)**

- Recording/remux to disk (explicitly deferred).
- An opinionated full-screen UI with controls — Lume owns overlays. The package ships a bare video surface view + a demo app only.
- AVPlayer wrapping/fallback inside the engine. Lume's engine-priority chain already handles fallback; the engine is FFmpeg-only and honest about failures.
- Encoding, transcoding, casting protocols (Chromecast).

**Platform floor:** iOS/iPadOS 18, tvOS 18, macOS 15, visionOS 2 — matches Lume, unlocks Swift 6 strict concurrency, `CAMetalDisplayLink`, `AVSampleBufferVideoRenderer`, MetalFX on all targets.

---

## 2. Requirements

### 2.1 From Lume (the consumer contract)

Sources: `Lume/Views/Player/FullScreenPlayerView.swift`, `TVPlaybackEngine.swift`, `PlaybackClock.swift`, `PlaybackRetryController.swift`, `PlayableMedia.swift`.

- **Engine view contract**: SwiftUI view constructed with `media: PlayableMedia`, `clock: PlaybackClock`, `nextUpMedia`, `skipSegments`, `reportsStartupFailure`, `usesQuickStartupTimeout`, `onPlaybackFailed`, `onSelectMedia`.
- **Coordinator surface**: `isPlaying`, buffering state, `videoInfo (width/height/fps/codec)`, `playbackRate`, `togglePlay`, `skip(by:)`, `seek(to:)`, PiP toggle + state, audio/text track lists (`PlayerTrackOption`) + selection, startup timeout, failure callback.
- **tvOS**: conform to `TVPlaybackEngine` (`@MainActor`, ObservableObject) so the shared Apple TV overlay drives it.
- **Content**: IPTV — live MPEG-TS & HLS (incl. hour-long uptimes, provider hiccups, 403 token expiry), VOD MKV/MP4/TS, Xtream catch-up (seekable VOD), local downloaded files, Stalker short-lived URLs (engine must support cheap full reload with new URL).
- **Behavioral requirements**: resume-at-position (`startTime`), reconnect via bounded backoff (engine reports errors; app schedules retries), initial-load failure reporting for the fallback chain, VOD rate menu 0.5–2.0×, fit/fill video gravity.
- **Gaps in Lume the engine must close**: external subtitle file loading, **Now Playing / lock-screen integration** (explicit requirement — including metadata on the iPhone lock screen while content AirPlays to an Apple TV), trickplay thumbnails, chapters.

### 2.2 Feature parity targets

Committed (per scope decision): everything in the stability core, plus:

| Pack | Features |
|---|---|
| **Core** | FFmpeg 8.1 demux/decode all formats, VideoToolbox HW decode + SW fallback, HDR10/HLG/DV Profile 5 & 8, AV1 (dav1d + HW), 8K/120fps capable pipeline, audio/subtitle track selection, libass full ASS rendering, PGS/DVB/VobSub bitmap subs, external subtitle files (SRT/VTT/ASS/SUP), main+secondary subtitles, word-by-word cues, accurate & fast seek, memory cache fast-seek, playback rate w/ pitch correction, seamless loop, de-interlace auto-detect, multichannel/spatial audio, PiP (with subtitles), Now Playing + remote commands, custom AVIO protocols, adaptive multi-bitrate, low-latency live |
| **Premium UX** | Scrub-preview thumbnails (trickplay), live rewind (time-shift DVR), zero-delay stream switching, disk precache of upcoming content |
| **Visual** | MetalFX upscaling, brightness/contrast/saturation, HDR10+ dynamic metadata, HDR-rendered subtitles |
| **Exotic** | 360°/VR panorama, Blu-ray ISO/DVD playback, offline AI subtitles (whisper.cpp), Dolby AC-4 *(investigation — see risks)*, audio passthrough *(investigation)* |

---

## 3. Stability doctrine — designing out known failure modes

Every item below is a failure mode documented in the FFmpeg-based engines Lume shipped before (from Lume's workarounds and a source audit), mapped to a structural countermeasure. These are **requirements**, not aspirations.

| # | Legacy-engine failure | LumeEngine countermeasure |
|---|---|---|
| 1 | Use-after-free on rebuild: re-opening a running session frees `AVStream`s under live decode threads | **Session epochs.** All lifecycle ops serialized on the `PlayerSession` actor; each open gets a generation token; teardown joins data-plane threads *before* `avformat_close_input`. A new open is a new session object — old sessions can only die, never restart. |
| 2 | MPEG-TS 33-bit PTS wraparound → frozen video after ~26.5 h | **Timestamp unwrapping at the demux boundary.** All PTS/DTS normalized to monotonic 64-bit engine time immediately after `av_read_frame`; wraparound and discontinuities (`AV_PKT_FLAG_DISCARD`, DISCONT) handled in one tested module. Nothing downstream ever sees raw container time. |
| 3 | Decode thread dies silently on corrupt packet → eternal buffering, no error | **Supervised pipelines.** Every data-plane thread runs under a supervisor that converts crashes/exits into typed `PlayerEvent.pipelineFailed`; built-in stall watchdog (playhead not advancing while nominally playing) emits events — apps never need their own watchdogs. |
| 4 | Stale buffer-state callbacks from the previous session → infinite reconnect loops | **No cross-session state.** State machine lives in the session object; a new session starts at `.idle` by construction. Buffer state is *derived* from actual PTS depth, never cached flags. |
| 5 | Two divergent VideoToolbox paths with ad-hoc recovery | **One HW decode path**: FFmpeg-managed VideoToolbox hwaccel (`get_format` + `av_hwdevice_ctx`). One recovery policy: on decoder error, flush → retry once → software fallback with `PlayerEvent.decoderDowngraded`. |
| 6 | Control flow scraped from FFmpeg log strings (idet, DNS timing) | **Forbidden.** Deinterlace detection via `AV_FRAME_FLAG_INTERLACED` on decoded frames; network timing via explicit AVIO callbacks. `av_log` goes to `os_log` for diagnostics only. |
| 7 | `Sendable` slapped on a class with ~30 unlocked mutable vars | **Honest concurrency.** Swift 6 language mode, strict concurrency, zero `@unchecked Sendable` on state-bearing types (only on audited RAII wrappers around FFmpeg refcounted buffers). Control plane = actors; data plane = dedicated threads + bounded SPSC channels carrying `Sendable` frame values. |
| 8 | Dozens of `static var` global config knobs | **Zero global mutable state.** All configuration is a `PlayerConfiguration` value passed at session creation. Two players in one process can have different configs. |
| 9 | Force unwraps / `as!` / `fatalError` in render & setup paths | Lint-enforced ban in engine target. Failable setup returns typed `EngineError`. |
| 10 | Audio clock updated via main-thread hops; main-thread jank breaks A/V sync | Clock updates on the audio render path via atomics; **main thread is never on the data path**. UI observation is a read-only 10 Hz publisher decoupled from sync. |
| 11 | Teardown via deliberate retain cycle + cancellation-by-polling | Structured teardown: interrupt flag → join with deadline → escalate to `AVIOInterruptCB` abort → assert-free forced close. `deinit` is trivial. |
| 12 | Near-zero test coverage of concurrency/seek/fallback | **Test-first for the risk areas** (§8): clock/sync, wraparound, seek storms, corrupt-stream fuzzing, TSan in CI, 24 h+ soak against a local stream torture server. |
| 13 | XCFramework bundle-ID/packaging hacks needed to embed | Build pipeline emits App Store-clean xcframeworks (valid bundle IDs, deep macOS layout, code-signing-ready) — verified by an integration test that archives a dummy app. |

---

## 4. Architecture

### 4.1 System overview

```
                        ┌────────────────────────── Control plane (Swift actors) ─┐
  LumePlayer (facade)   │  PlayerSession (actor)                                  │
  LumePlayerView (UI)   │   ├─ state machine (idle→opening→ready→playing→…)       │
  Events: AsyncStream   │   ├─ session epoch/generation tokens                    │
                        │   ├─ TrackController (select audio/video/sub)           │
                        │   └─ Watchdogs (stall, sync-drift, buffer)              │
                        └────────────┬────────────────────────────────────────────┘
                                     │ owns / supervises
     ┌───────────────────────────────┴───────────────── Data plane (threads) ─────┐
     │                                                                            │
     │  Demuxer ──packets──▶ VideoDecoder ──frames──▶ ┐                           │
     │  (AVFormat,           (FFmpeg + VT hwaccel)    │                           │
     │   ts-unwrap,                                   ▼                           │
     │   AVIO cache) ──packets──▶ AudioDecoder ──▶ RenderCoordinator              │
     │                        └──▶ SubtitleDecoder    │ (sync policy)             │
     │                             + libass           ▼                           │
     │            ┌─────────────────────────────────────────────┐                 │
     │            │ SystemRenderer (default)                    │                 │
     │            │  AVSampleBufferRenderSynchronizer           │                 │
     │            │   ├─ AVSampleBufferVideoRenderer (HDR, PiP) │                 │
     │            │   └─ AVSampleBufferAudioRenderer (spatial)  │                 │
     │            │ MetalRenderer (VR/filters/HDR subs)         │                 │
     │            │  CAMetalLayer + CAMetalDisplayLink          │                 │
     │            └─────────────────────────────────────────────┘                 │
     └────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Package layout (SPM)

```
LumeEngine/
├── Package.swift
├── Sources/
│   ├── CLumeFFmpeg/            # module maps + shims over xcframework binary targets
│   ├── LumeEngineCore/         # no UI: session, demux, decode, clock, buffers
│   ├── LumeEngineRender/       # SystemRenderer, MetalRenderer, shaders
│   ├── LumeEngineSubtitles/    # libass bridge, parsers, cue model, styling
│   ├── LumeEngineMedia/        # Now Playing, PiP, audio session, route handling
│   └── LumeEngine/             # public facade: LumePlayer, LumePlayerView, config, events
├── BinaryDependencies/         # generated Package targets for ffmpeg/libass/dav1d xcframeworks
├── build/                      # FFmpeg build pipeline (scripts, patches, configs)
├── DemoApp/                    # multiplatform SwiftUI demo (streams menu, diagnostics HUD)
└── Tests/ + TestStreams/       # fixtures + stream torture server
```

### 4.3 Key design decisions

**D1 — Data plane on dedicated threads, control plane on actors.**
`av_read_frame`, `avcodec_receive_frame`, and audio render callbacks block or run real-time — they cannot be actor-isolated. Each stage owns one thread; stages communicate through **bounded, lock-based MPSC/SPSC channels** (small, heavily tested, no `assertionFailure` in production paths, PTS-depth accounting built in). The `PlayerSession` actor owns lifecycle, seeks, track switching, and receives events; it never touches frames.

**D2 — RAII wrappers over FFmpeg objects.**
`Packet`, `VideoFrame`, `AudioFrame` are final classes wrapping `AVPacket*`/`AVFrame*` with `av_*_ref` semantics, deinit-based free, and `@unchecked Sendable` justified by immutability-after-construction. CVPixelBuffers from hwaccel are retained CF objects. No `Unmanaged` outside these wrappers and the audited AVIO/interrupt bridges.

**D3 — A/V sync delegated to `AVSampleBufferRenderSynchronizer` (SystemRenderer, default).**
Instead of a hand-rolled audio-master clock + frame-drop heuristics, the default path enqueues decoded audio into `AVSampleBufferAudioRenderer` and video (as `CMSampleBuffer` with real PTS) into `AVSampleBufferVideoRenderer`, both attached to a `AVSampleBufferRenderSynchronizer` (`CMTimebase`-driven). Apple's clock does sync, rate (with `audioTimePitchAlgorithm`), and frame scheduling. This buys us: system-quality sync, HDR/Dolby Vision tone mapping, PiP via `AVPictureInPictureController(contentSource:)`, spatial audio, and far less code to get wrong. Requirement: timestamps must be clean — guaranteed by the demux-boundary unwrapper (§3.2).

**D4 — MetalRenderer as the second backend, one abstraction.**
`VideoRenderer` protocol with exactly two implementations. Metal path (CAMetalLayer + `CAMetalDisplayLink`, engine clock = audio renderer's timebase) activates only for: 360°/VR projection, HDR-composited subtitles, and filter chains that must bypass sample-buffer enqueueing. Pixel pipeline: YUV→RGB via Metal compute/vImage matrices (601/709/2020, video/full range, 8/10-bit), EDR via `CAEDRMetadata`.

**D5 — GPU pre-processing stage keeps the default renderer.**
Brightness/contrast/saturation and MetalFX spatial upscaling operate CVPixelBuffer→CVPixelBuffer *before* enqueue (Metal compute; zero-copy IOSurface), so the SystemRenderer (and thus PiP/HDR) keeps working with filters active.

**D6 — One subtitle engine, composited as overlay.**
libass renders ASS/SSA (full effects, embedded fonts via attachment streams, word-by-word \k tags); PGS/DVB/VobSub decoded by FFmpeg to bitmaps; SRT/VTT parsed to styled cues rendered through the same layout box. Output = time-tagged `SubtitleImage` cues composited on a CALayer above the video surface (and into the PiP content when active; into Metal for HDR subtitle mode). Dual subtitle slots (main + secondary). External files attach as additional demux sessions.
**System caption respect:** map `MACaptionAppearance` (user's Style settings) onto text-cue styling by default.

**D7 — Buffering is PTS-math, not heuristics.**
`BufferController` computes buffered duration per track from channel PTS depth (not packet-count/fps estimates). Targets configurable (live vs VOD presets mirroring Lume's current tunables). Backpressure: demux thread parks when max buffer reached; channels never grow unbounded.

**D8 — Typed events, no delegate soup.**
`AsyncStream<PlayerEvent>`: state changes, buffering %, first frame, track lists, decoder downgrades, stall/drift watchdog reports, network telemetry, terminal errors (`EngineError` with FFmpeg error codes + context). `@Observable PlayerObservableState` (10 Hz coalesced) for SwiftUI.

**D9 — Networking stays inside FFmpeg, TLS via SecureTransport.**
`http/https/tcp/udp/rtsp/rtmp/hls` via FFmpeg with `--enable-securetransport` (no OpenSSL — smaller, LGPL-clean). Reconnect flags on; custom protocols via an `AVIOProtocol` Swift protocol (backing Stalker re-resolution, precache, ISO reading later). Headers/UA/cookies/proxy per session config.

### 4.4 Public API sketch

```swift
let player = LumePlayer(configuration: .init(
    bufferPolicy: .live(target: 4, max: 30),
    hardwareDecode: .videoToolbox(fallback: .software),
    subtitles: .init(style: .systemCaptionAppearance, secondarySlot: true)
))
try await player.open(url, options: .init(headers: [...], startTime: 132.5))
player.play()
for await event in player.events { ... }
player.view          // LumePlayerView (SwiftUI) / LumePlayerLayerView (UIKit/AppKit)
await player.select(track: audioTracks[1])
await player.seek(to: 300, accurate: true)
player.rate = 1.5
player.nowPlaying.isEnabled = true   // publishes MPNowPlayingInfoCenter + remote commands
```

---

## 5. FFmpeg 8.1.2 build pipeline (own, in-repo)

Modeled on mpvkit/ffmpeg-build's approach but owned by us, under `build/`:

- **Pinned versions manifest** (`build/versions.json`): ffmpeg 8.1.2, dav1d, libass + freetype + harfbuzz + fribidi + libunibreak, (later: libbluray, libdvdread/nav; whisper.cpp ships as a separate SPM dep).
- **Config: LGPL** — `--disable-gpl --disable-nonfree --disable-programs --disable-doc --disable-encoders --disable-muxers` (keep a whitelist for HLS/TS demux side), `--enable-videotoolbox --enable-audiotoolbox --enable-securetransport --enable-libdav1d --enable-network`, full decoder/demuxer/protocol set otherwise. Size budget tracked per platform (~25–35 MB/slice expected).
- **Targets**: iOS arm64 + sim (arm64), tvOS arm64 + sim, macOS arm64 + x86_64, visionOS arm64 + sim. Static libs → per-library **xcframeworks** with clean bundle identifiers and deep macOS layout (App Store-validated — this kills Lume's `fix-ksplayer-frameworks.sh` hack).
- **Distribution**: GitHub Actions workflow builds, checksums, and attaches artifacts to releases; `Package.swift` consumes them as `binaryTarget(url:checksum:)` with a local-path override for development.
- **Upgrade drill documented**: bump manifest → CI builds → engine test suite runs against new binaries. Staying current is a process, not a project.

Licensing note: engine code Apache-2.0/MIT; FFmpeg LGPL 2.1+ and libass ISC as binary deps. For AGPL Lume this is trivially fine; for other consumers we document LGPL §6 obligations (dynamic xcframework linking satisfies relinkability).

---

## 6. Feature implementation notes (selected)

- **Now Playing (explicit requirement):** `NowPlayingCenter` module in `LumeEngineMedia` — `MPNowPlayingInfoCenter` (title/artwork/elapsed/duration/rate, live-stream flag) + `MPRemoteCommandCenter` (play/pause/seek/skip/next-episode hook), audio-session lifecycle, route-change and interruption handling. Works on the lock screen/Control Center including while audio/video routes to an Apple TV. Note: full-screen *video* AirPlay of FFmpeg-decoded content is not possible for third parties (system limitation); Lume's existing switch-to-AVPlayer-on-AirPlay stays, and the integration phase adds a shared app-level Now Playing service so lock-screen metadata is present in **both** engines (closing today's gap).
- **PiP:** `AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer:playbackDelegate:))` from the SystemRenderer; subtitle cues composited into the sample buffers during PiP so subs survive.
- **Trickplay:** a `ThumbnailSession` — separate lightweight demux+decode (keyframes only, HW decode, downscale to ~320 px) filling a time-indexed cache; API `thumbnails(at:interval:)`. Works for VOD/catch-up; live uses the rewind buffer.
- **Live rewind (time-shift DVR):** disk-backed packet spool behind a custom AVIO layer; seeking within spool = local demux, seeking to live edge = passthrough. Configurable size/duration caps.
- **Zero-delay switching:** `prepare(next:)` opens a second session through first-frame-decoded, then atomically swaps renderer attachment; old session torn down async. (Also powers Lume's next-episode auto-advance and channel zapping.)
- **Precache:** same AVIO disk-cache layer, `precache(url:leadingSeconds:)` background task with LRU budget.
- **Upscaling:** MetalFX spatial scaler stage (D5), quality/perf switch, auto-disable on thermal pressure (`ProcessInfo.thermalState`).
- **HDR:** HDR10/HLG passthrough via sample-buffer attachments; DV P5/P8: preserve `dvcC` config + RPU side data into CMSampleBuffer format description extensions (VideoToolbox tone-maps); HDR10+ dynamic metadata via per-frame attachments. EDR headroom handling on macOS/visionOS Metal path.
- **360°/VR:** MetalRenderer projection (equirect sphere / fisheye), CoreMotion + gesture camera; visionOS immersive presentation later.
- **Blu-ray ISO/DVD:** libbluray/libdvdnav behind the `AVIOProtocol` seam; menu-less title playback first (longest-title heuristic), chapters mapped to the chapter API.
- **AI subtitles:** whisper.cpp (Metal) tapping the decoded-audio channel; streaming word-level segments feed the subtitle model as a synthetic track; on-device translation via Translation.framework.
- **Chapters:** read from container (`AVChapter`) + exposed in API (feeds Lume's skip-intro as a second source).

---

## 7. Risks & open investigations

| Risk | Assessment | Mitigation |
|---|---|---|
| Dolby Vision P5 (proprietary IPT-PQ-C2) | Hard. VideoToolbox handles DV streams only when correctly signaled; P5 has no BL fallback. | Phase-gated spike: test `dvh1/dvhe` signaling through `AVSampleBufferVideoRenderer` on-device early (Phase 3). If VT won't tone-map P5, fall back to libplacebo-style Metal tone mapping (stretch) or document as limitation. |
| Dolby AC-4 | No FFmpeg decoder (patent-encumbered); Apple decodes AC-4 only via its own frameworks. | Investigation ticket: attempt `AVSampleBufferAudioRenderer` passthrough of AC-4 `CMSampleBuffer`s (compressed enqueue). If rejected → out of scope, documented. |
| Audio passthrough (compressed Dolby out) | Apple exposes no raw bitstream-out API; `AVSampleBufferAudioRenderer` *can* accept some compressed formats. | Same compressed-enqueue spike (EAC-3/Atmos-in-EAC3 first — that's the one that matters for AVRs). |
| `AVSampleBufferRenderSynchronizer` edge cases (rate ≠ 1 with filters, very high fps) | Medium. | MetalRenderer is the escape hatch; sync-policy abstraction keeps both backends behind one interface. |
| libass performance at 4K/120 (heavy karaoke ASS) | Known cost center. | Render at video resolution cap, async rasterization thread, cue caching, blur-region limits — same tricks mpv uses. |
| Whisper real-time on A-series/tvOS | tvOS memory limits. | Model size selection by device class; explicitly best-effort. |
| Build pipeline maintenance burden | Real but bounded. | Version manifest + CI drill (§5); binary artifacts mean consumers never build FFmpeg. |
| 8K/120fps ambitions vs channel copies | Copies are the killer. | Zero-copy discipline: hwaccel CVPixelBuffers end-to-end, IOSurface-backed Metal textures, no sws_scale on the hot path (only for SW-decode exotic formats). |

---

## 8. Testing & verification strategy

In the legacy engines, the crash-prone areas are exactly the untested ones. Inverting that:

1. **Unit (pure, fast):** timestamp unwrapper (wraparound seams, discontinuities), channels (backpressure, teardown, PTS accounting), state machine transitions, clock math, buffer controller, ASS/SRT/VTT parsers, error mapping.
2. **Fixture-based integration:** `TestStreams/` generated by ffmpeg CLI in CI — TS with a synthetic 33-bit wraparound seam, corrupt-packet streams, HDR10/HLG/DV samples, multi-track MKV (audio langs + PGS + ASS + fonts attachments), AV1, 10-bit, interlaced H.264. Golden tests: open → decode N frames → assert PTS monotonicity, no drops, correct color properties.
3. **Stream torture server:** local HTTP/HLS server with scriptable faults — mid-stream 403, stalls, slow-loris, segment gaps, resolution changes, PAT/PMT changes. Assert: engine emits the right events, never hangs, teardown completes < 2 s.
4. **Soak:** 24 h live-TS run in CI (nightly), asserting zero sync drift (>200 ms), zero stalls, flat memory (leak gate).
5. **Sanitizers:** TSan job on every PR for Core targets; ASan/UBSan nightly. Strict concurrency = the compile-time layer.
6. **Seek storm / lifecycle fuzz:** randomized rapid seek/pause/rate/track-switch/close sequences (the classic UAF reproducer) run under TSan.
7. **On-device checklist per release:** PiP, lock-screen controls, AirPlay-audio route, backgrounding, HDR on OLED, thermal soak on Apple TV 4K.
8. **Packaging test:** archive + validate a dummy app embedding the xcframeworks (guards §3.13).

---

## 9. Roadmap

Phases are sequential milestones; each ends demoable in the DemoApp. (P0–P4 are the critical path to "plays video well"; P5–P7 reach Lume-integration quality; P8 ships it; P9+ are the differentiators.)

- **P0 — Foundations:** repo scaffolding, FFmpeg 8.1.2 build pipeline for all 5 platform slices, SPM binary targets, CI (build + TSan + fixtures), DemoApp shell. *Exit: `avformat_version()` callable from the demo app on every platform.*
- **P1 — Demux core:** RAII wrappers, channels, Demuxer thread (open/read/seek/interrupt), timestamp unwrapper, typed errors, track model, chapters. *Exit: packet-level inspection of MKV/TS/HLS in demo; wraparound unit tests green.*
- **P2 — Decode:** video decode with single VT hwaccel path + SW fallback policy, audio decode + swresample negotiation, supervisor + downgrade events. *Exit: decoded-frame dumps correct for the whole fixture matrix.*
- **P3 — Render & sync:** SystemRenderer (synchronizer + audio/video renderers), session state machine, play/pause/seek(accurate & fast)/rate, buffer controller, first-frame fast path, fit/fill. **Early DV P5/P8 spike here.** *Exit: smooth playback incl. HDR fixtures; seek storm test green.*
- **P4 — Facade & UI:** `LumePlayer` API, events stream, `LumePlayerView`, DemoApp with diagnostics HUD (buffer depth, clocks, decoder path, drops). *Exit: public API frozen for v1.*
- **P5 — Tracks & subtitles:** runtime track switching, libass integration, bitmap subs, external files, dual slots, system caption appearance, subtitle delay/position controls.
- **P6 — Resilience:** watchdogs (stall, sync drift), reconnect semantics for live, torture-server suite, 24 h soak gate, memory/leak gates.
- **P7 — Platform integration:** PiP (with subtitles), Now Playing + remote commands + audio session/route handling, background audio behavior, tvOS focus/idle specifics, visionOS window presentation.
- **P8 — Lume integration:** new `PlayerEngineKind.lumeEngine`, engine view + coordinator conforming to Lume's contract + `TVPlaybackEngine`, shared app-level Now Playing service (covers the AVPlayer/AirPlay path too), external-subtitle UI, A/B via engine priority setting. Ships as an opt-in beta engine appended to the priority list; promotion to default follows once the beta bakes. *Exit: Lume builds run LumeEngine alongside the existing engines with the fallback chain intact.*
- **P9 — Premium UX:** trickplay thumbnails, zero-delay switching (wired to Lume next-episode & channel zapping), live rewind spool, precache API.
- **P10 — Visual pack:** GPU pre-processing stage (adjustments), MetalFX upscaling, HDR10+ metadata, MetalRenderer completion, HDR subtitles.
- **P11 — Exotic:** 360°/VR, Blu-ray ISO/DVD, whisper.cpp AI subtitles + translation, AC-4/passthrough investigation results.

**Suggested v1.0 cut:** end of P8. P9–P11 ship as minor releases.

---

## 10. Success criteria

1. Lume runs LumeEngine as default engine with **fewer than 10 % of sessions** ever touching the fallback chain.
2. Zero engine-attributed crashes in a full TestFlight cycle; 24 h live-TS soak with no stall/drift.
3. All of Lume's legacy-engine workarounds (stream-rebuild hacks, clock-drift and stall watchdogs, stale-state guards, framework-fixing script) become unnecessary for LumeEngine playback.
4. Feature checklist §2.2 core + premium demonstrably working in DemoApp on all five platforms.
5. FFmpeg upgrade 8.1.x → next stable executed once via the documented drill in < 1 day of work.
