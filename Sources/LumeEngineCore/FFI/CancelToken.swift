import Foundation

/// Cancellation flag shared with FFmpeg's `AVIOInterruptCB`.
///
/// FFmpeg polls the interrupt callback from inside blocking I/O (network reads,
/// `avformat_open_input`, seeks). The callback runs on FFmpeg's threads, so the
/// flag must be safely readable from any thread at any point in the session's
/// life. Lifetime rule (PLAN.md §3.11): the demuxer retains the token via
/// `Unmanaged.passRetained` before installing the callback and balances it only
/// *after* `avformat_close_input` — the callback can never observe a freed token.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}
