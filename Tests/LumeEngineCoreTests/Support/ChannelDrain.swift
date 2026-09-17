import Foundation
import Testing
@testable import LumeEngineCore

/// Drains a data-plane `Channel` on a dedicated thread and hands the collected
/// value back to an `async` test body.
///
/// Never drain a channel from `Task.detached` — or straight from an `async`
/// test body. `Channel.receive` *blocks*, and a blocked task holds one of the
/// Swift runtime's cooperative threads for as long as it waits. With a dozen
/// decode suites in flight the pool runs dry, the tests' own `await`s stop
/// being scheduled — including the `signalEndOfStream()` that tells a decoder
/// to drain its codec — and a collector that ends on a wall-clock timeout then
/// quietly returns a *short* list of frames.
///
/// That is not hypothetical. It is why CI once saw 196 of 200 deinterlaced
/// frames from a commit that produced 200 on every developer machine: on a
/// three-core runner the collector's 5 s timeout expired before the starved
/// test body could ask for the end-of-stream drain. The same starvation is
/// visible in the timings — every decode test took "just over 5 seconds".
/// Blocking work belongs on a thread of its own here for exactly the reason it
/// does in the engine (PLAN.md D1).
///
/// The drain ends when the producer *closes* the channel, which is the real
/// end-of-data signal, so nothing is ever lost to a timeout that fired early.
/// `deadline` is only a backstop against a wedged pipeline, and it fails the
/// test instead of silently truncating.
final class ChannelDrain<Output: Sendable>: @unchecked Sendable {
    /// `stalled` travels with the value rather than being read separately:
    /// `NSLock` cannot be taken from an `async` context, so everything the
    /// awaiting side needs has to come through the continuation.
    private typealias Result = (output: Output, stalled: Bool)

    private let lock = NSLock()
    private var result: Result?
    private var waiter: CheckedContinuation<Result, Never>?

    private let deadline: TimeInterval

    /// Starts draining `channel` immediately, on its own thread.
    ///
    /// - Parameters:
    ///   - channel: the channel to drain. Its producer must close it — every
    ///     decoder does so from `shutdown()`.
    ///   - initial: the accumulator elements are folded into.
    ///   - deadline: how long a silent but still-open channel is tolerated
    ///     before the drain gives up and fails the test.
    ///   - step: run on the drain thread for every element received.
    init<Element: Sendable>(
        _ channel: Channel<Element>,
        into initial: Output,
        deadline: TimeInterval = 30,
        step: @escaping @Sendable (inout Output, Element) -> Void
    ) {
        self.deadline = deadline
        let thread = Thread { [self] in
            var collected = initial
            var expiry = Date(timeIntervalSinceNow: deadline)
            var gaveUp = false
            while true {
                if let element = channel.receive(timeout: 0.25) {
                    step(&collected, element)
                    expiry = Date(timeIntervalSinceNow: deadline)
                    continue
                }
                // `receive` returns nil both for "closed and drained" and for
                // "nothing arrived yet", so the channel's own state decides
                // which of the two this is.
                if channel.closed { break }
                if Date() >= expiry {
                    gaveUp = true
                    break
                }
            }
            finish(collected, gaveUp: gaveUp)
        }
        thread.name = "test.channel-drain"
        thread.start()
    }

    /// The collected value, once the producer has closed the channel. Fails the
    /// test — from the test's own context, where Swift Testing can attribute it
    /// — if the drain had to give up on a channel that never closed.
    var value: Output {
        get async {
            let result: Result = await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
            if result.stalled {
                Issue.record("channel drain gave up after \(deadline) s: the producer never closed the channel")
            }
            return result.output
        }
    }

    private func finish(_ collected: Output, gaveUp: Bool) {
        let result = (output: collected, stalled: gaveUp)
        lock.lock()
        let waiter = self.waiter
        self.waiter = nil
        if waiter == nil { self.result = result }
        lock.unlock()
        waiter?.resume(returning: result)
    }
}
