import Foundation

/// Which stage of the pipeline stopped when `.stalled` fired.
///
/// The app's answer differs by stage: a starved source wants a reconnect,
/// while a decoder or renderer that stopped will do the same again on a
/// fresh session of the same engine, so it wants a different engine.
public enum StallReason: String, Sendable, Equatable {
    /// No media is arriving: the network or the source stopped delivering
    /// (on every lane, or on one — a stream that vanished from the mux).
    case source
    /// Packets are queued for video but no frames come out.
    case videoDecoder
    /// Packets are queued for audio but no frames come out.
    case audioDecoder
    /// Decoded media is ready and the clock is meant to run, but it does not
    /// move: the system renderers stopped consuming.
    case renderer

    /// What one lane held when the stall was confirmed.
    struct Lane: Sendable {
        let isVideo: Bool
        /// Decoded seconds ahead of the playhead (frame queue + renderer lead).
        let decoded: Double
        /// Undecoded seconds queued for the decoder.
        let packets: Double
    }

    /// Pure classification, so every branch is testable without a pipeline
    /// that actually wedges.
    ///
    /// - Parameters:
    ///   - clockShouldRun: the renderer rate is non-zero.
    ///   - clockMoved: seconds the playhead advanced over the stall window.
    static func diagnose(clockShouldRun: Bool, clockMoved: Double, lanes: [Lane]) -> StallReason {
        // A running clock drains the renderers and drops the session to
        // buffering within a buffer's length of the source stopping; one that
        // stayed put for the whole window was never consuming.
        if clockShouldRun, clockMoved < 0.1 {
            return .renderer
        }
        // Input waiting with nothing decoded from it: a healthy decoder turns
        // half a second of packets into frames in milliseconds.
        if let stuck = lanes.first(where: { $0.packets >= 0.5 && $0.decoded < 0.05 }) {
            return stuck.isVideo ? .videoDecoder : .audioDecoder
        }
        return .source
    }
}

/// How long each startup step took, in seconds since `open(url:)` was
/// called; nil for a step not reached yet. Read it when a start takes too
/// long to see where it stands: still opening, opened but not delivering,
/// delivering but not decoding, or decoded but not presented.
public struct StartupTimeline: Sendable, Equatable, CustomStringConvertible {
    /// Source opened and probed (`.opened`).
    public var opened: Double?
    /// The first packet reached a decoder's queue.
    public var firstPacket: Double?
    /// The first decoded video frame reached the renderer.
    public var firstVideoFrame: Double?
    /// The first decoded audio frame reached the renderer.
    public var firstAudioFrame: Double?
    /// The clock reached the first frame and is running: the viewer sees
    /// (or, audio-only, hears) the stream.
    public var firstFrameShown: Double?

    public init() {}

    public var description: String {
        func step(_ name: String, _ value: Double?) -> String {
            "\(name) " + (value.map { String(format: "%.2f", $0) } ?? "-")
        }
        return [
            step("open", opened),
            step("pkt", firstPacket),
            step("v", firstVideoFrame),
            step("a", firstAudioFrame),
            step("shown", firstFrameShown),
        ].joined(separator: " ")
    }
}
