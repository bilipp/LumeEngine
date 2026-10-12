import LumeEngineCore
import Synchronization

/// What a run has seen so far, and the one-shot signal that ends it.
///
/// Several tasks race to end a run — the duration timer, Ctrl-C, the event
/// stream reporting `.ended` or a failure — and the first one wins; the
/// others find the run already stopping.
final class RunControl: Sendable {
    enum Stop: Sendable, Equatable {
        case duration
        case ended
        case failed
        case interrupted
    }

    struct Tally: Sendable {
        /// One entry per `.stalled`, with the stage `lastStallReason` named.
        var stalls: [StallReason?] = []
        var errors = 0
        var downgrades = 0
        /// The error the session failed with.
        var failure: EngineError?
    }

    private struct State {
        var stop: Stop?
        var waiters: [CheckedContinuation<Stop, Never>] = []
        var sessionState: PlayerSession.State = .idle
        var tally = Tally()
    }

    private let state = Mutex(State())

    /// Ends the run; only the first reason counts.
    func stop(_ reason: Stop) {
        let waiters = state.withLock { state -> [CheckedContinuation<Stop, Never>] in
            guard state.stop == nil else { return [] }
            state.stop = reason
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: reason)
        }
    }

    var stopReason: Stop? {
        state.withLock { $0.stop }
    }

    func waitForStop() async -> Stop {
        await withCheckedContinuation { continuation in
            let stopped = state.withLock { state -> Stop? in
                if let stop = state.stop { return stop }
                state.waiters.append(continuation)
                return nil
            }
            if let stopped { continuation.resume(returning: stopped) }
        }
    }

    var snapshot: Tally {
        state.withLock { $0.tally }
    }

    func setSessionState(_ sessionState: PlayerSession.State) {
        state.withLock { $0.sessionState = sessionState }
    }

    /// Counts an error; true when it is the one the session failed with.
    func recordError(_ error: EngineError) -> Bool {
        state.withLock { state in
            state.tally.errors += 1
            guard state.sessionState == .failed, state.tally.failure == nil else { return false }
            state.tally.failure = error
            return true
        }
    }

    func countStall(_ reason: StallReason?) {
        state.withLock { $0.tally.stalls.append(reason) }
    }

    func countDowngrade() {
        state.withLock { $0.tally.downgrades += 1 }
    }
}

/// Runs `operation` and waits at most `seconds` for it. True when it
/// finished in time; when it did not, it keeps running unobserved.
func finishes(within seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let outcome = Once()
    return await withCheckedContinuation { continuation in
        outcome.arm(continuation)
        Task {
            await operation()
            outcome.resolve(true)
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            outcome.resolve(false)
        }
    }
}

/// A continuation resumed by whichever side gets there first.
private final class Once: Sendable {
    private let continuation = Mutex<CheckedContinuation<Bool, Never>?>(nil)

    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resolve(_ value: Bool) {
        let continuation = self.continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}
