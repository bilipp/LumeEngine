import Foundation
import Testing
@testable import LumeEngineCore

@Suite("Channel")
struct ChannelTests {
    @Test("FIFO ordering")
    func fifo() throws {
        let channel = Channel<Int>(capacity: 8)
        for i in 0..<8 { try channel.send(i) }
        for i in 0..<8 { #expect(channel.receive(timeout: 1) == i) }
    }

    @Test("backpressure blocks producer until consumer drains")
    func backpressure() throws {
        let channel = Channel<Int>(capacity: 2)
        try channel.send(1)
        try channel.send(2)
        #expect(!channel.trySend(3), "full channel must reject trySend")

        let producerDone = expectationFlag()
        Thread.detachNewThread {
            try? channel.send(3) // blocks until a slot frees
            producerDone.set()
        }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(!producerDone.isSet, "producer must be blocked while full")

        #expect(channel.receive(timeout: 1) == 1)
        #expect(producerDone.wait(timeout: 2), "producer must unblock after drain")
        #expect(channel.receive(timeout: 1) == 2)
        #expect(channel.receive(timeout: 1) == 3)
    }

    @Test("close wakes blocked producer with error")
    func closeWakesProducer() throws {
        let channel = Channel<Int>(capacity: 1)
        try channel.send(0)

        let sawError = expectationFlag()
        Thread.detachNewThread {
            do {
                try channel.send(1)
            } catch {
                sawError.set()
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
        channel.close()
        #expect(sawError.wait(timeout: 2), "blocked send must throw on close")
    }

    @Test("close lets consumer drain the remainder")
    func closeDrains() throws {
        let channel = Channel<Int>(capacity: 4)
        try channel.send(1)
        try channel.send(2)
        channel.close()
        #expect(channel.receive(timeout: 1) == 1)
        #expect(channel.receive(timeout: 1) == 2)
        #expect(channel.receive(timeout: 0.1) == nil, "drained closed channel returns nil")
    }

    @Test("receive timeout returns nil")
    func receiveTimeout() {
        let channel = Channel<Int>(capacity: 1)
        let start = Date()
        #expect(channel.receive(timeout: 0.1) == nil)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test("flush empties buffer, wakes producers, resets accounting")
    func flush() throws {
        let channel = Channel<Int64>(capacity: 2, measure: { $0 })
        try channel.send(10)
        try channel.send(20)
        #expect(channel.stats.bufferedDuration == 30)

        let producerDone = expectationFlag()
        Thread.detachNewThread {
            try? channel.send(30)
            producerDone.set()
        }
        Thread.sleep(forTimeInterval: 0.05)
        let discarded = channel.flush()
        #expect(discarded == 2)
        #expect(producerDone.wait(timeout: 2), "flush must unblock producers")
        // The unblocked element (30) is now buffered.
        #expect(channel.stats.count == 1)
        #expect(channel.stats.bufferedDuration == 30)
    }

    @Test("PTS accounting tracks sum of measured durations")
    func accounting() throws {
        let channel = Channel<Int64>(capacity: 16, measure: { $0 })
        for duration in [Int64(100), 200, 300] { try channel.send(duration) }
        #expect(channel.stats.bufferedDuration == 600)
        _ = channel.receive(timeout: 1)
        #expect(channel.stats.bufferedDuration == 500)
        _ = channel.receive(timeout: 1)
        _ = channel.receive(timeout: 1)
        #expect(channel.stats.bufferedDuration == 0)
    }

    @Test("concurrent producer/consumer transfers everything exactly once")
    func stress() {
        let channel = Channel<Int>(capacity: 7)
        let total = 10_000
        let received = LockedBox<[Int]>([])

        let consumerDone = expectationFlag()
        Thread.detachNewThread {
            var collected: [Int] = []
            while collected.count < total {
                guard let value = channel.receive(timeout: 5) else { break }
                collected.append(value)
            }
            received.set(collected)
            consumerDone.set()
        }
        Thread.detachNewThread {
            for i in 0..<total { try? channel.send(i) }
        }
        #expect(consumerDone.wait(timeout: 15))
        #expect(received.get() == Array(0..<total), "in-order, exactly-once delivery")
    }
}

// MARK: - Tiny test primitives

/// Thread-safe latch for cross-thread assertions without XCTest expectations.
final class ExpectationFlag: @unchecked Sendable {
    private let condition = NSCondition()
    private var flagged = false

    var isSet: Bool {
        condition.lock()
        defer { condition.unlock() }
        return flagged
    }

    func set() {
        condition.lock()
        flagged = true
        condition.unlock()
        condition.broadcast()
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !flagged {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}

func expectationFlag() -> ExpectationFlag { ExpectationFlag() }

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
