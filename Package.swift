// swift-tools-version: 6.0
import Foundation
import PackageDescription

// FFmpeg comes from a checksum-pinned xcframework attached to a GitHub release, so
// consuming this package requires nothing from build/ — SwiftPM just downloads it
// (PLAN.md §5).
//
// The artifact is versioned by the FFmpeg build it contains, not by the engine's
// release it happens to hang off: this URL only moves when build/versions.json, the
// configure flags, or the patch set change. Engine releases in between keep pointing
// at the same binary.
//
// A locally built xcframework wins when present, which is the development override —
// build/scripts/make-xcframework.sh writes exactly there, so anyone iterating on the
// FFmpeg build tests their own binary rather than silently linking the released one.
// Consumers never have that directory, so their resolution is unconditional.
let ffmpegArtifactURL = "https://github.com/bilipp/LumeEngine/releases/download/v0.1.0/FFmpeg.xcframework.zip"
let ffmpegArtifactChecksum = "f07e91971f9330520f6968116083d01d15352090184f21a60e7fe502adf63ce4"

let localFFmpegPath = "BinaryDependencies/FFmpeg.xcframework"
let hasLocalFFmpeg = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(localFFmpegPath)
        .path
)

let ffmpegTarget: Target = hasLocalFFmpeg
    ? .binaryTarget(name: "CFFmpeg", path: localFFmpegPath)
    : .binaryTarget(name: "CFFmpeg", url: ffmpegArtifactURL, checksum: ffmpegArtifactChecksum)

// `-enable-library-evolution` is load-bearing, and it can only be expressed as an
// unsafe flag — this toolchain's SwiftSetting has no library-evolution option.
//
// Why it matters: with evolution, LumeEngineCore's module interface does not pull the
// CFFmpeg C module into a consumer's compile. Without it, an app that links LumeEngine
// *and* another FFmpeg-based engine compiles two conflicting definitions of the same C
// types and Clang refuses:
//
//     'AV_PIX_FMT_OHCODEC' from module 'CFFmpeg' is not present in definition of
//     'enum AVPixelFormat' in module 'Libavutil'
//
// That is precisely Lume's configuration (LumeEngine alongside KSPlayer/FFmpegKit), so
// dropping the flag broke it. Nesting the headers under lume_ffmpeg/ prevents header
// path collisions but cannot prevent C-namespace type redefinition.
//
// The catch: SwiftPM rejects unsafeFlags in any package resolved as a *versioned*
// dependency, which makes `.package(url:from:)` fail outright. So the flag is applied
// everywhere except there — path dependencies (Lume, and engine development) keep it,
// while version-resolved consumers go without.
//
// Consequence worth knowing: a consumer that adds this package by URL *and* links a
// second FFmpeg will hit the collision above. Such a consumer should vendor the package
// as a path/submodule dependency instead, which restores evolution. Revisit if SwiftPM
// ever exposes library evolution as a safe setting.
let isVersionedDependency = #filePath.contains("/checkouts/")
let evolutionSettings: [SwiftSetting] = isVersionedDependency
    ? []
    : [.unsafeFlags(["-enable-library-evolution"])]

// System libraries/frameworks required by the static FFmpeg xcframework.
let ffmpegLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("z"),
    .linkedLibrary("bz2"),
    .linkedLibrary("iconv"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("CoreMedia"),
    .linkedFramework("CoreVideo"),
    .linkedFramework("VideoToolbox"),
    .linkedFramework("AudioToolbox"),
    .linkedFramework("Security"),
]

let package = Package(
    name: "LumeEngine",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        // Dynamic: FFmpeg 8 symbols stay inside LumeEngine.framework (two-level
        // namespace), so apps can also link engines embedding other FFmpeg builds
        // without symbol collisions.
        .library(name: "LumeEngine", type: .dynamic, targets: ["LumeEngine"]),
    ],
    targets: [
        // FFmpeg 8.1.x static libraries: released artifact, or a local build when
        // one is present (resolved above).
        ffmpegTarget,

        // Data plane + control plane core: demux, decode, clock, channels. No UI.
        // Library evolution + `internal import CFFmpeg` keep the FFmpeg module
        // out of consumers' compiles entirely — apps can link other FFmpeg-based
        // engines without C-module type collisions.
        .target(
            name: "LumeEngineCore",
            dependencies: ["CFFmpeg"],
            swiftSettings: evolutionSettings,
            linkerSettings: ffmpegLinkerSettings
        ),

        // Public facade (LumePlayer, events, SwiftUI view).
        .target(
            name: "LumeEngine",
            dependencies: ["LumeEngineCore"],
            swiftSettings: evolutionSettings
        ),

        // macOS demo app: `swift run LumeEngineDemo`.
        .executableTarget(
            name: "LumeEngineDemo",
            dependencies: ["LumeEngine"],
            path: "DemoApp/Sources"
        ),

        .testTarget(
            name: "LumeEngineCoreTests",
            dependencies: ["LumeEngineCore", "LumeEngine"],
            exclude: ["Fixtures/generate-fixtures.sh"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
