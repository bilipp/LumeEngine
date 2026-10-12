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
        /// Reject every request with this HTTP status.
        case status(Int)
        /// Serve the file the way many live channels arrive: chunked transfer
        /// encoding, no Content-Length — and then the terminating chunk once
        /// the file is out, the source ending. FFmpeg cannot tell that from a
        /// lost connection (a body of unknown length always ends
        /// "prematurely") and reports an I/O error.
        case unbounded(file: URL)
        /// A live channel that drops and is reconnected: chunked like
        /// `.unbounded`, the first connection breaks off after the bytes up
        /// to `dropAt`, and every later one starts again at `resumeAt` —
        /// earlier, the way a server answers a reconnect from its buffer — and
        /// runs to the end. Both offsets are rounded down to 188-byte TS packets.
        case reconnectReplay(file: URL, dropAt: Int, resumeAt: Int)
        /// Serve an HLS directory (`index.m3u8` + segments) as a live channel
        /// that ends: the first playlist request gets the playlist without its
        /// `#EXT-X-ENDLIST`, every later one with it. Use `hlsURL`.
        case hlsLiveThenEnded(directory: URL)
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
    var hlsURL: String { "http://127.0.0.1:\(port)/index.m3u8" }

    /// Playlist requests served so far (HLS mode). Guarded by `lock`.
    private var playlistRequests = 0
    /// Connections accepted so far. Guarded by `lock`.
    private var accepted = 0

    /// Connections accepted so far: more than one means the client reconnected.
    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

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
        accepted += 1
        lock.unlock()

        connection.start(queue: queue)
        lock.lock()
        let index = accepted
        lock.unlock()
        readRequest(connection, received: Data()) { [weak self] path in
            self?.respond(on: connection, path: path, connectionIndex: index)
        }
    }

    /// Reads the request head and hands over its path.
    private func readRequest(_ connection: NWConnection, received: Data, completion: @escaping @Sendable (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard error == nil, let data, !data.isEmpty else { return }
            let head = received + data
            if head.range(of: Data("\r\n\r\n".utf8)) != nil {
                let requestLine = String(decoding: head.prefix { $0 != 0x0D }, as: UTF8.self)
                let parts = requestLine.split(separator: " ")
                completion(parts.count > 1 ? String(parts[1]) : "/")
            } else {
                self?.readRequest(connection, received: head, completion: completion)
            }
        }
    }

    /// `connectionIndex`: 1 for the first connection accepted, and so on.
    private func respond(on connection: NWConnection, path: String, connectionIndex: Int) {
        switch mode {
        case .forbidden:
            reject(connection, status: 403)

        case .status(let status):
            reject(connection, status: status)

        case .unbounded(let url):
            guard let payload = try? Data(contentsOf: url) else { return connection.cancel() }
            connection.send(content: chunked(payload, terminated: true), completion: .contentProcessed { _ in
                connection.cancel()
            })

        case .reconnectReplay(let url, let dropAt, let resumeAt):
            guard let payload = try? Data(contentsOf: url) else { return connection.cancel() }
            if connectionIndex == 1 {
                let end = min(dropAt / 188 * 188, payload.count)
                connection.send(content: chunked(payload.prefix(end), terminated: false), completion: .contentProcessed { _ in
                    connection.forceCancel()
                })
            } else {
                let start = min(resumeAt / 188 * 188, payload.count)
                connection.send(content: chunked(payload.suffix(from: start), terminated: true), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }

        case .file(let url):
            guard let payload = try? Data(contentsOf: url) else { return connection.cancel() }
            send(payload: payload, on: connection, closeWhenDone: true)

        case .hlsLiveThenEnded(let directory):
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            guard let payload = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                return reject(connection, status: 404)
            }
            guard name.hasSuffix(".m3u8") else {
                return send(payload: payload, on: connection, closeWhenDone: true)
            }
            lock.lock()
            playlistRequests += 1
            let first = playlistRequests == 1
            lock.unlock()
            var playlist = String(decoding: payload, as: UTF8.self)
            if first {
                playlist = playlist.replacingOccurrences(of: "#EXT-X-ENDLIST\n", with: "")
            }
            let body = Data(playlist.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })

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
            let interval = Double(chunk) / Double(bytesPerSecond)
            connection.send(content: header(totalLength: payload.count), completion: .contentProcessed { [weak self] _ in
                // Timeline starts when the body starts, so chunk N is due at
                // start + N * interval regardless of how long sends take.
                self?.sendPaced(payload: payload, offset: 0, chunk: chunk, interval: interval, start: .now(), index: 0, on: connection)
            })
        }
    }

    /// Delivers `payload` at `chunk / interval` bytes per second.
    ///
    /// Each chunk is scheduled against an **absolute** timeline (`start + index *
    /// interval`) rather than "wait `interval` after the previous send finished".
    /// The naive form silently under-delivers: its real period is `interval` *plus*
    /// send-completion latency and dispatch slop, so on a loaded machine a nominal
    /// 1.4×-realtime feed degrades toward 1.0× and tests that depend on the surplus
    /// (`readAheadAccumulation`) fail for want of CPU rather than for a real defect.
    /// Chaining on the completion handler is kept deliberately: at most one send is
    /// outstanding, so a client that stops reading applies backpressure instead of
    /// letting chunks pile up inside `NWConnection` and burst later. A late chunk
    /// gets a past deadline and fires immediately, which catches drift back up
    /// without ever exceeding the nominal rate.
    private func sendPaced(
        payload: Data,
        offset: Int,
        chunk: Int,
        interval: Double,
        start: DispatchTime,
        index: Int,
        on connection: NWConnection
    ) {
        guard offset < payload.count else {
            connection.cancel()
            return
        }
        let end = min(offset + chunk, payload.count)
        let slice = payload.subdata(in: offset..<end)
        connection.send(content: slice, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return connection.cancel() }
            let next = index + 1
            let due = start + .nanoseconds(Int(Double(next) * interval * 1_000_000_000))
            self.queue.asyncAfter(deadline: due) {
                self.sendPaced(payload: payload, offset: end, chunk: chunk, interval: interval, start: start, index: next, on: connection)
            }
        })
    }

    /// A 200 response head plus `payload` in chunked transfer encoding;
    /// `terminated` adds the final zero-length chunk (the body ended cleanly).
    private func chunked(_ payload: Data, terminated: Bool) -> Data {
        var body = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
        var offset = payload.startIndex
        while offset < payload.endIndex {
            let chunk = payload[offset..<min(offset + 64 * 1024, payload.endIndex)]
            body += Data("\(String(chunk.count, radix: 16))\r\n".utf8) + chunk + Data("\r\n".utf8)
            offset += chunk.count
        }
        if terminated { body += Data("0\r\n\r\n".utf8) }
        return body
    }

    private func reject(_ connection: NWConnection, status: Int) {
        let response = "HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
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
