import Foundation
import Synchronization
import Testing
@testable import LumeEngineCore

/// The trigger behind the PiP window's `invalidatePlaybackState`: it must fire
/// for every transport change the window shows (play, pause, rate, a seek
/// while paused) and stay quiet while the clock merely runs.
@Suite("SystemRenderer transport observation")
struct TransportObservationTests {
    private final class Counter: Sendable {
        let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var current: Int { value.withLock { $0 } }
    }

    private let queue = DispatchQueue(label: "test.transport")

    /// Waits until the counter moves past `previous`; returns the new count.
    private func waitForChange(_ counter: Counter, from previous: Int) async -> Int {
        for _ in 0..<100 where counter.current == previous {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Let any notification posted alongside the first one land too.
        try? await Task.sleep(for: .milliseconds(50))
        return counter.current
    }

    @Test("play, pause, rate changes and seeks while paused each fire")
    func firesOnTransportChanges() async {
        let renderer = SystemRenderer(muted: true)
        defer { renderer.shutdown() }
        let counter = Counter()
        let observation = renderer.observeTransport(on: queue) { counter.increment() }
        // Registration itself may report the initial state.
        var seen = await waitForChange(counter, from: -1)

        renderer.setRate(1, anchoredAt: 0)
        var now = await waitForChange(counter, from: seen)
        #expect(now > seen, "play")
        seen = now

        renderer.setRate(1.5)
        now = await waitForChange(counter, from: seen)
        #expect(now > seen, "rate change")
        seen = now

        renderer.setRate(0)
        now = await waitForChange(counter, from: seen)
        #expect(now > seen, "pause")
        seen = now

        // A seek while paused moves the time without touching the rate.
        renderer.setRate(0, anchoredAt: 30_000_000)
        now = await waitForChange(counter, from: seen)
        #expect(now > seen, "seek while paused")
        seen = now

        // A running clock alone is not a transport change.
        renderer.setRate(1)
        seen = await waitForChange(counter, from: seen)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(counter.current == seen, "fired while the clock merely ran")
        withExtendedLifetime(observation) {}
    }

    @Test("releasing the token ends the observation")
    func endsOnRelease() async {
        let renderer = SystemRenderer(muted: true)
        defer { renderer.shutdown() }
        let counter = Counter()
        var observation: TransportObservation? = renderer.observeTransport(on: queue) { counter.increment() }
        _ = await waitForChange(counter, from: -1)
        observation = nil
        _ = observation
        let before = counter.current
        renderer.setRate(1, anchoredAt: 0)
        renderer.setRate(0, anchoredAt: 10_000_000)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(counter.current == before)
    }
}
