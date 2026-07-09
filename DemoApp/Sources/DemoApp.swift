import SwiftUI

// The demo is a macOS-only tool; the package's library products build for
// every platform and the demo must not block them (CI/simulator test runs).
#if os(macOS)
import LumeEngine

/// Minimal engine demo (macOS): URL bar, transport controls, diagnostics HUD.
/// Run with `swift run LumeEngineDemo` from the repo root.
@main
struct LumeEngineDemoApp: App {
    var body: some Scene {
        WindowGroup("LumeEngine Demo") {
            DemoView()
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

struct DemoView: View {
    @State private var player = LumePlayer()
    @State private var urlText = defaultFixtureURL()
    @State private var statusMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            LumePlayerView(player: player)
                .background(Color.black)
                .overlay(alignment: .topLeading) { hud }

            controls
                .padding(12)
        }
        .task { await loadCurrentURL() }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("state: \(String(describing: player.state))")
            Text(String(format: "position: %.2f s%@", player.position,
                        player.duration.map { String(format: " / %.2f s", $0) } ?? " (live)"))
            if let info = player.mediaInfo {
                Text("format: \(info.formatName)")
                if let video = info.videoTracks.first {
                    Text("video: \(video.codecName) \(video.video?.width ?? 0)x\(video.video?.height ?? 0)")
                }
                if let audio = info.audioTracks.first {
                    Text("audio: \(audio.codecName) \(audio.audio?.channels ?? 0)ch")
                }
            }
            if let error = player.lastError {
                Text("error: \(error.message)").foregroundStyle(.red)
            }
            if !statusMessage.isEmpty {
                Text(statusMessage).foregroundStyle(.yellow)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.6))
        .foregroundStyle(.green)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Media URL", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                Button("Load") { Task { await loadCurrentURL() } }
            }
            HStack(spacing: 16) {
                Button(player.state == .playing ? "Pause" : "Play") {
                    player.state == .playing ? player.pause() : player.play()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("−15 s") { player.skip(by: -15) }
                Button("+15 s") { player.skip(by: 15) }
                Picker("Rate", selection: $player.rate) {
                    ForEach([Float(0.5), 1.0, 1.25, 1.5, 2.0], id: \.self) {
                        Text(String(format: "%.2gx", $0)).tag($0)
                    }
                }
                .frame(width: 120)
                Slider(
                    value: Binding(
                        get: { player.position },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...(player.duration ?? max(player.position, 1))
                )
            }
        }
    }

    private func loadCurrentURL() async {
        statusMessage = ""
        do {
            _ = try await player.load(url: urlText)
            player.play()
        } catch {
            statusMessage = "load failed: \(error)"
        }
    }

    private static func defaultFixtureURL() -> String {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // DemoApp/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("TestStreams/generated/basic.mp4")
        return fixture.path
    }
}
#else
@main
struct LumeEngineDemoApp {
    static func main() {
        fatalError("LumeEngineDemo is macOS-only")
    }
}
#endif
