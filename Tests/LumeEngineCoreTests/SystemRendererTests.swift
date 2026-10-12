import CoreVideo
import Foundation
import Testing
@testable import LumeEngineCore

/// The render pumps against a live renderer with empty decode channels — the
/// steady state of live TV, where frames arrive in real time and the
/// renderer never fills up.
@Suite("SystemRenderer")
struct SystemRendererTests {
    /// `requestMediaDataWhenReady` calls its block straight back while the
    /// renderer is ready, so a pump that just returned on an empty channel ran
    /// millions of times a second — a core per lane, pegged.
    @Test func starvedPumpsIdleOnTheirRetry() async throws {
        let renderer = SystemRenderer(muted: true)
        defer { renderer.shutdown() }
        renderer.attach(video: Channel<VideoFrame>(capacity: 8), audio: Channel<AudioFrame>(capacity: 8))

        try await Task.sleep(for: .milliseconds(500))

        let counts = renderer.pumpCounts
        // The 10 ms retry is ~50 runs per lane here; the spin was millions.
        #expect(counts.video < 250)
        #expect(counts.audio < 250)
    }

    /// Idling must not mean dead: a frame that lands after the pump went quiet
    /// still reaches the renderer (PLAN.md §3.3, the stuck-spinner failure).
    @Test func starvedVideoPumpPicksUpALateFrame() async throws {
        let renderer = SystemRenderer(muted: true)
        defer { renderer.shutdown() }
        let video = Channel<VideoFrame>(capacity: 8)
        renderer.attach(video: video, audio: nil)

        try await Task.sleep(for: .milliseconds(200))
        #expect(renderer.enqueuedHighWaterMark.video == MediaTime.noTimestamp)

        let frame = try #require(Self.blackFrame(pts: 40_000))
        try video.send(frame)

        let deadline = ContinuousClock.now + .seconds(2)
        while renderer.enqueuedHighWaterMark.video != frame.pts, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(renderer.enqueuedHighWaterMark.video == frame.pts)
    }

    private static func blackFrame(pts: Int64) -> VideoFrame? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        return VideoFrame(pixelBuffer: buffer, pts: pts, duration: 40_000, serial: 0, isHardwareDecoded: false)
    }
}
