// swift-tools-version: 6.0
import PackageDescription

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
        // FFmpeg 8.1.x static libraries, built by build/scripts (see PLAN.md §5).
        .binaryTarget(
            name: "CFFmpeg",
            path: "BinaryDependencies/FFmpeg.xcframework"
        ),

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
