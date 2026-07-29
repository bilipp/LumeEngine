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
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"])],
            linkerSettings: ffmpegLinkerSettings
        ),

        // Public facade (LumePlayer, events, SwiftUI view).
        .target(
            name: "LumeEngine",
            dependencies: ["LumeEngineCore"],
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]
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
