import Foundation
import Synchronization

/// Where lumectl's records go: text or JSON Lines on stdout, and optionally
/// JSON Lines into a file (`--record-events`), so a run can be watched live
/// and attached to an issue afterwards.
///
/// Every record carries `t`, seconds since the run started — the one clock
/// that lines up events, heartbeats and the startup timeline.
public final class Reporter: Sendable {
    /// Receives one finished line (no trailing newline).
    public typealias Sink = @Sendable (String) -> Void

    private let json: Bool
    private let started: TimeInterval
    private let stdout: Sink
    private let recorder: Mutex<FileHandle?>

    /// - Throws: when the record file cannot be created.
    public init(output: OutputOptions, stdout: @escaping Sink) throws {
        json = output.json
        started = ProcessInfo.processInfo.systemUptime
        self.stdout = stdout
        var file: FileHandle?
        if let path = output.recordPath {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw UsageError("cannot create --record-events file '\(path)'")
            }
            file = try FileHandle(forWritingTo: url)
        }
        recorder = Mutex(file)
    }

    /// Seconds since the run started.
    public var elapsed: Double {
        ProcessInfo.processInfo.systemUptime - started
    }

    /// One record: `text` for the terminal, `fields` for JSON (after `t`
    /// and `type`). Multi-line text keeps the timestamp on its first line.
    func emit(_ type: String, text: String, fields: [(String, JSON)] = []) {
        let t = elapsed
        let record = JSON.object([("t", .double(t)), ("type", .string(type))] + fields).encoded
        if json {
            stdout(record)
        } else {
            let stamp = String(format: "[%8.3f] ", t)
            let indent = String(repeating: " ", count: stamp.count)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            stdout(lines.enumerated().map { ($0.offset == 0 ? stamp : indent) + $0.element }.joined(separator: "\n"))
        }
        recorder.withLock { file in
            file?.write(Data((record + "\n").utf8))
        }
    }

    /// Flushes and closes the record file.
    func close() {
        recorder.withLock { file in
            try? file?.synchronize()
            try? file?.close()
            file = nil
        }
    }
}
