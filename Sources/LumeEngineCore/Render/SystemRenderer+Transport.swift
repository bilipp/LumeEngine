@preconcurrency import AVFoundation
import CoreMedia
import Foundation

extension SystemRenderer {
    /// Calls `handler` on `queue` whenever the clock's transport changes: its
    /// rate (play, pause, a rate change, or the system zeroing it on an
    /// audio interruption) or a jump of its time (a seek, a re-anchor after a
    /// mis-landed seek). It does not fire for the clock merely running, so a
    /// main-queue observer stays off the data path. The observation ends when
    /// the returned token is released.
    func observeTransport(on queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) -> TransportObservation {
        TransportObservation(synchronizer: synchronizer, queue: queue, handler: handler)
    }
}

/// Owner of the synchronizer observers behind `SystemRenderer.observeTransport`.
final class TransportObservation {
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let timeObserver: Any
    private let rateObserver: NSObjectProtocol

    fileprivate init(
        synchronizer: AVSampleBufferRenderSynchronizer,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        self.synchronizer = synchronizer
        // A periodic observer also fires whenever time jumps and whenever
        // rendering starts or stops; the jumps are what the rate notification
        // misses (a seek while paused leaves the rate at 0). The period itself
        // is irrelevant, so it is long enough never to matter.
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 3_600, timescale: 1),
            queue: queue
        ) { _ in handler() }
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue
        operationQueue.maxConcurrentOperationCount = 1
        rateObserver = NotificationCenter.default.addObserver(
            forName: AVSampleBufferRenderSynchronizer.rateDidChangeNotification,
            object: synchronizer,
            queue: operationQueue
        ) { _ in handler() }
    }

    deinit {
        synchronizer.removeTimeObserver(timeObserver)
        NotificationCenter.default.removeObserver(rateObserver)
    }
}
