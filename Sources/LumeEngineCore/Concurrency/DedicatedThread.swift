import Foundation

/// Runs blocking work — joining data-plane threads, mostly — on a thread of
/// its own, so the control plane can wait for it without blocking.
///
/// Every stage's `shutdown(deadline:)` parks its caller until the stage's
/// thread has exited. Called straight from `PlayerSession`, that parks one of
/// the Swift runtime's cooperative threads — the pool every actor, every
/// event pump and the app's own tasks run on — for as long as the join takes,
/// up to the full deadline when FFmpeg is slow to come out of a dead
/// connection. A handful of sessions tearing down at once (zapping, a
/// Multi-View grid closing) can hold the whole pool, and nothing else in the
/// process is scheduled meanwhile. Actors never block (PLAN.md D1); they hand
/// the join to one of these and await it, or don't wait at all.
///
/// CI runs the test suite with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, which
/// shrinks the pool to a single thread so that a blocking wait reached from
/// async code shows up as a hang instead of hiding behind spare threads.
enum DedicatedThread {
    /// Starts `work` on a new thread and returns at once. For teardown nobody
    /// needs to wait for: a retired track lane, whose stages are already
    /// disconnected from everything the session still uses.
    static func start(named name: String, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.name = name
        // Teardown sits on the zapping path: the old session closes its
        // source while the next one opens.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs `work` on a new thread and resumes with its result once it
    /// returns. The awaiting task is suspended, not blocked, meanwhile.
    @discardableResult
    static func run<Result: Sendable>(
        named name: String,
        _ work: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            start(named: name) {
                continuation.resume(returning: work())
            }
        }
    }
}
