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
    private let measure: (@Sendable (Element) -> Int64)?

    /// - Parameters:
    ///   - capacity: maximum element count before `send` blocks. Clamped to ≥ 1.
    ///   - measure: optional per-element duration (engine µs) for PTS accounting.
    public init(capacity: Int, measure: (@Sendable (Element) -> Int64)? = nil) {
        self.capacity = max(1, capacity)
        self.measure = measure
        storage = [Element?](repeating: nil, count: self.capacity)
    }

    // MARK: Producer

    /// Blocks while the channel is full. Throws `EngineError(.cancelled)` if the
    /// channel is closed before space becomes available.
    public func send(_ element: Element) throws {
        condition.lock()
        defer { condition.unlock() }
        while elementCount == capacity && !isClosed {
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
        guard !isClosed, elementCount < capacity else { return false }
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
        return Stats(count: elementCount, bufferedDuration: durationSum, isFull: elementCount == capacity)
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
