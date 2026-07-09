import Foundation
import Network

/// Minimal fault-injecting HTTP server for resilience tests (PLAN.md §8.3).
/// One behavior per instance; every incoming connection gets the same treatment.
final class TortureHTTPServer: @unchecked Sendable {
    enum Mode {
        /// Serve the file normally.
        case file(URL)
        /// Reject every request with 403 (expired IPTV token).
        case forbidden
        /// Send headers + the first `prefix` bytes of the file, then go silent
        /// (connection stays open — the classic dead-provider stall).
        case stallAfter(prefix: Int, file: URL)
        /// Send headers + prefix, then hard-close (mid-stream drop).
        case dropAfter(prefix: Int, file: URL)
        /// Serve the file paced at `bytesPerSecond` (rate-limited IPTV
        /// provider): 100 ms chunks with sleeps in between.
        case throttled(file: URL, bytesPerSecond: Int)
    }

    private let listener: NWListener
    private let mode: Mode
    private let queue = DispatchQueue(label: "torture-server")
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    /// Connection handler indirection: NWListener requires a handler BEFORE
    /// start() (it fails with EINVAL otherwise), but `self` isn't available
    /// until init completes.
    private let handlerBox = LockedBox<(@Sendable (NWConnection) -> Void)?>(nil)

    let port: UInt16

    init(mode: Mode) throws {
        self.mode = mode

        // NWListener(on: .any) reports port 0 even when ready, so bind an
        // explicit random high port (with retries against collisions).
        var boundListener: NWListener?
        var boundPort: UInt16 = 0
        var attempts = 0
        while boundListener == nil && attempts < 20 {
            attempts += 1
            let candidate = UInt16.random(in: 49_152..<65_535)
            guard let port = NWEndpoint.Port(rawValue: candidate),
                  let listener = try? NWListener(using: .tcp, on: port)
            else { continue }

            let ready = DispatchSemaphore(value: 0)
            let failed = LockedBox<Bool>(false)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
                if case .failed = state { failed.set(true); ready.signal() }
            }
            let box = handlerBox
            listener.newConnectionHandler = { connection in
                box.get()?(connection)
            }
            listener.start(queue: queue)
            if ready.wait(timeout: .now() + 5) == .success, !failed.get() {
                boundListener = listener
                boundPort = candidate
            } else {
                listener.cancel()
            }
        }
        guard let listener = boundListener else {
            throw NSError(domain: "TortureHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener failed to start"])
        }
        self.listener = listener
        self.port = boundPort
        handlerBox.set { [weak self] connection in
            self?.accept(connection)
        }
    }

    var url: String { "http://127.0.0.1:\(port)/stream.ts" }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections.removeAll()
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()

        connection.start(queue: queue)
        readRequest(connection) { [weak self] in
            self?.respond(on: connection)
        }
    }

    private func readRequest(_ connection: NWConnection, completion: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard error == nil, let data, !data.isEmpty else { return }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                completion()
            } else {
                self?.readRequest(connection, completion: completion)
            }
        }
    }

    private func respond(on connection: NWConnection) {
        switch mode {
        case .forbidden:
            let response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

        case .file(let url):
            guard let payload = try? Data(contentsOf: url) else { return connection.cancel() }
            send(payload: payload, on: connection, closeWhenDone: true)

        case .stallAfter(let prefix, let url):
            guard let payload = try? Data(contentsOf: url) else { return connection.cancel() }
            let headers = header(totalLength: payload.count)
            let body = payload.prefix(prefix)
            connection.send(content: headers + body, completion: .contentProcessed { _ in
                // ...and then nothing, forever. Connection intentionally left open.
            })

        case .dropAfter(let prefix, let url):
            guard let payload = try? Data(contentsOf: url) else { return connection.cancel() }
            let headers = header(totalLength: payload.count)
            let body = payload.prefix(prefix)
            connection.send(content: headers + body, completion: .contentProcessed { _ in
                connection.forceCancel()
            })

        case .throttled(let url, let bytesPerSecond):
            guard let payload = try? Data(contentsOf: url) else { return connection.cancel() }
            let chunk = max(1, bytesPerSecond / 10)
            connection.send(content: header(totalLength: payload.count), completion: .contentProcessed { [weak self] _ in
                self?.sendPaced(payload: payload, offset: 0, chunk: chunk, on: connection)
            })
        }
    }

    private func sendPaced(payload: Data, offset: Int, chunk: Int, on connection: NWConnection) {
        guard offset < payload.count else {
            connection.cancel()
            return
        }
        let end = min(offset + chunk, payload.count)
        let slice = payload.subdata(in: offset..<end)
        connection.send(content: slice, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return connection.cancel() }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                self.sendPaced(payload: payload, offset: end, chunk: chunk, on: connection)
            }
        })
    }

    private func header(totalLength: Int) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(totalLength)\r\nConnection: close\r\n\r\n".utf8)
    }

    private func send(payload: Data, on connection: NWConnection, closeWhenDone: Bool) {
        connection.send(content: header(totalLength: payload.count) + payload, completion: .contentProcessed { _ in
            if closeWhenDone { connection.cancel() }
        })
    }
}
