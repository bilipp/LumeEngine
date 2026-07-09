import Foundation

/// A bounded, blocking MPSC/SPSC channel — the only conduit between data-plane
/// stages (demux → decode → render).
///
/// Design requirements (PLAN.md D1, D7, §3.4):
/// - Bounded: producers block when full (backpressure), so memory is capped.
/// - PTS-accounted: buffered duration is exact math over element durations,
///   never a packets-per-fps estimate.
/// - No `assertionFailure` in production paths: misuse degrades, never crashes.
/// - `close()` and `flush()` are callable from any thread and wake all waiters —
///   this is what makes teardown-under-deadline possible.
public final class Channel<Element: Sendable>: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public let count: Int
        /// Sum of element durations in engine microseconds (0 when unmeasured).
        public let bufferedDuration: Int64
        /// True when the channel cannot accept more elements — a full lane is
        /// "as buffered as it can get" regardless of duration targets.
        public let isFull: Bool
    }

    private let condition = NSCondition()
    private var storage: [Element?]
    private var head = 0
    private var elementCount = 0
    private var durationSum: Int64 = 0
    private var isClosed = false
    private let capacity: Int
    private let durationBudget: Int64?
    private let measure: (@Sendable (Element) -> Int64)?

    /// - Parameters:
    ///   - capacity: maximum element count before `send` blocks. Clamped to ≥ 1.
    ///   - durationBudget: optional cap on buffered duration (engine µs). The
    ///     channel is also "full" once the measured sum reaches this budget —
    ///     count alone is meaningless across codecs (256 TrueHD packets are
    ///     0.2 s, 256 AC-3 packets are 8 s), so read-ahead must be budgeted in
    ///     media time with the count as the memory backstop for elements that
    ///     report no duration. At least one element is always accepted.
    ///   - measure: optional per-element duration (engine µs) for PTS accounting.
    public init(
        capacity: Int,
        durationBudget: Int64? = nil,
        measure: (@Sendable (Element) -> Int64)? = nil
    ) {
        self.capacity = max(1, capacity)
        self.durationBudget = durationBudget
        self.measure = measure
        storage = [Element?](repeating: nil, count: self.capacity)
    }

    /// Full = cannot accept more. Callers must hold `condition`.
    private var isAtCapacity: Bool {
        if elementCount >= capacity { return true }
        if let durationBudget, elementCount > 0, durationSum >= durationBudget { return true }
        return false
    }

    // MARK: Producer

    /// Blocks while the channel is full. Throws `EngineError(.cancelled)` if the
    /// channel is closed before space becomes available.
    public func send(_ element: Element) throws {
        condition.lock()
        defer { condition.unlock() }
        while isAtCapacity && !isClosed {
            condition.wait()
        }
        if isClosed {
            throw EngineError(code: .cancelled, message: "channel closed")
        }
        enqueueLocked(element)
        condition.broadcast()
    }

    /// Non-blocking send. Returns `false` when full or closed.
    public func trySend(_ element: Element) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !isClosed, !isAtCapacity else { return false }
        enqueueLocked(element)
        condition.broadcast()
        return true
    }

    /// Bounded-blocking send: waits up to `timeout` for space. Returns `false`
    /// (element NOT enqueued) if the channel is still full at the deadline —
    /// the caller keeps ownership and can retry after servicing other work.
    /// Producers that must stay responsive to commands (the demuxer's read
    /// loop) use this instead of `send`: parking forever under backpressure
    /// deafens them to everything but a channel close.
    public func send(_ element: Element, timeout: TimeInterval) throws -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while isAtCapacity && !isClosed {
            if !condition.wait(until: deadline) { return false }
        }
        if isClosed {
            throw EngineError(code: .cancelled, message: "channel closed")
        }
        enqueueLocked(element)
        condition.broadcast()
        return true
    }

    // MARK: Consumer

    /// Blocks until an element is available, the deadline passes (returns `nil`),
    /// or the channel is closed and drained (returns `nil`).
    public func receive(timeout: TimeInterval? = nil) -> Element? {
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        condition.lock()
        defer { condition.unlock() }
        while elementCount == 0 && !isClosed {
            if let deadline {
                if !condition.wait(until: deadline) { return nil }
            } else {
                condition.wait()
            }
        }
        guard elementCount > 0 else { return nil } // closed and drained
        let element = dequeueLocked()
        condition.broadcast()
        return element
    }

    /// Non-blocking receive.
    public func tryReceive() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        guard elementCount > 0 else { return nil }
        let element = dequeueLocked()
        condition.broadcast()
        return element
    }

    // MARK: Control (any thread)

    /// Discards all buffered elements and wakes blocked producers.
    /// Returns the number of discarded elements.
    @discardableResult
    public func flush() -> Int {
        condition.lock()
        defer { condition.unlock() }
        let discarded = elementCount
        storage = [Element?](repeating: nil, count: capacity)
        head = 0
        elementCount = 0
        durationSum = 0
        condition.broadcast()
        return discarded
    }

    /// Closes the channel. Producers fail fast; consumers drain the remainder.
    /// Idempotent.
    public func close() {
        condition.lock()
        defer { condition.unlock() }
        isClosed = true
        condition.broadcast()
    }

    public var closed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isClosed
    }

    public var stats: Stats {
        condition.lock()
        defer { condition.unlock() }
        return Stats(count: elementCount, bufferedDuration: durationSum, isFull: isAtCapacity)
    }

    // MARK: Ring buffer (condition lock held)

    private func enqueueLocked(_ element: Element) {
        storage[(head + elementCount) % capacity] = element
        elementCount += 1
        if let measure { durationSum += measure(element) }
    }

    private func dequeueLocked() -> Element {
        let element = storage[head]!
        storage[head] = nil
        head = (head + 1) % capacity
        elementCount -= 1
        if let measure { durationSum -= measure(element) }
        if elementCount == 0 { durationSum = 0 }
        return element
    }
}
