#if os(iOS) || os(macOS) || os(tvOS)
@preconcurrency import AVKit
import CoreMedia
import Foundation

/// Picture-in-Picture for the custom renderer via the sample-buffer content
/// source (PLAN.md §6). The display layer keeps receiving frames from the
/// SystemRenderer while the system hosts it in the PiP window.
@MainActor
public final class PictureInPictureBridge: NSObject {
    private var controller: AVPictureInPictureController?
    private let session: PlayerSession
    private let renderer: SystemRenderer
    // Immutable snapshots for the synchronous nonisolated delegate callbacks.
    private let timelineStart: Int64
    private let timelineDuration: Int64?

    public private(set) var isActive = false

    public init(session: PlayerSession, mediaInfo: MediaInfo) {
        self.session = session
        self.renderer = session.renderer
        self.timelineStart = mediaInfo.startTime
        self.timelineDuration = mediaInfo.duration
        super.init()

        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: renderer.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        self.controller = controller
    }

    public var isSupported: Bool { controller != nil }
    public var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    public func start() {
        controller?.startPictureInPicture()
    }

    public func stop() {
        controller?.stopPictureInPicture()
    }

    public func toggle() {
        isActive ? stop() : start()
    }
}

// Delegate callbacks are nonisolated protocol requirements; AVKit delivers
// them on the main queue, so state mutation hops via assumeIsolated.
extension PictureInPictureBridge: AVPictureInPictureControllerDelegate {
    public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { isActive = true }
    }

    public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { isActive = false }
    }

    public nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        MainActor.assumeIsolated { isActive = false }
    }
}

extension PictureInPictureBridge: AVPictureInPictureSampleBufferPlaybackDelegate {
    public nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        let session = session
        Task {
            if playing {
                await session.play()
            } else {
                await session.pause()
            }
        }
    }

    public nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let duration = timelineDuration else {
            // Live: infinite timeline (system shows a live UI).
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(
            start: SampleBufferBuilder.time(timelineStart),
            duration: SampleBufferBuilder.time(duration)
        )
    }

    public nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        renderer.rate == 0
    }

    public nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    public nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let session = session
        let seconds = skipInterval.seconds
        // completionHandler is not Sendable-annotated in the SDK; box it.
        let completion = UncheckedSendableBox(completionHandler)
        Task {
            let position = await session.position
            await session.seek(to: max(0, position + seconds))
            completion.value()
        }
    }
}

/// Wrapper for SDK closures that lack Sendable annotations but are safe to
/// call once from another context.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
