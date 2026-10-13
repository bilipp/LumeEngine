import Foundation
import LumeEngineCore
import Synchronization

/// lumectl: drives a `PlayerSession` headlessly against one URL, so a
/// provider issue (startup stall, reconnect, replay, seam, decoder downgrade,
/// HTTP error) can be reproduced from a terminal instead of the app.
///
/// It only observes. Like the app, it uses the session's public surface —
/// events, `diagnostics`, `startup`, `lastStallReason` — and never retries:
/// what the engine reports is what gets printed.
public enum LumeCtl {
    public static let usage = """
        usage: lumectl probe <url> [source options] [output options]
               lumectl play  <url> [play options] [source options] [output options]

        probe   open the source, print what it carries, close it
        play    play it headlessly (muted) and print every event, a diagnostics
                heartbeat, the startup timeline and the outcome

        play options:
          --duration S          stop after S seconds of playback (default: to the
                                end, or Ctrl-C for a live source)
          --start S             open at S seconds (the resume path: seeks before
                                the first read)
          --seek S              seek to S seconds once the first frame shows
          --interval S          heartbeat every S seconds, 0 for none (default 2)
          --software            decode video in software (no VideoToolbox)
          --audio-lang de,en    preferred audio languages, in order
          --no-audio            video lane only
          --no-video            audio lane only
          --stall-threshold S   seconds without progress before a stall

        source options:
          --header 'Name: value'  extra HTTP header (repeatable)
          --user-agent UA
          --referer URL
          --no-reconnect          disable FFmpeg's HTTP auto-reconnect
          --io-timeout S          blocking I/O timeout (default 15)
          --open-timeout S        deadline for open + probe (default 30)

        output options:
          --json                  JSON Lines on stdout instead of text
          --record-events FILE    also write every record to FILE as JSON Lines
          --show-urls             print URLs as given (default: scheme and host
                                  only, since IPTV URLs carry credentials)

        exit status:
          0 ok   1 lumectl failed   2 usage   3 open failed
          4 playback failed   5 stalled (and did not fail)   130 Ctrl-C before open

        Ctrl-C ends a run cleanly (the session is shut down and the summary
        printed); a second Ctrl-C exits at once.
        """

    /// Runs a parsed command to completion.
    ///
    /// - Parameter interrupts: yields once per Ctrl-C. The first one ends the
    ///   run the way `--duration` would; handling a second is the caller's.
    public static func run(
        _ command: Command,
        interrupts: AsyncStream<Void>,
        stdout: @escaping Reporter.Sink,
        stderr: @escaping Reporter.Sink
    ) async -> ExitCode {
        switch command {
        case .help:
            stdout(usage)
            return .success
        case .version:
            stdout("lumectl (LumeEngine) — \(FFmpegRuntime.versions)")
            return .success
        case .probe(let options):
            guard let reporter = makeReporter(options.output, stdout: stdout, stderr: stderr) else {
                return .toolFailure
            }
            defer { reporter.close() }
            return await Run(
                source: options.source, output: options.output,
                configuration: options.configuration, reporter: reporter
            ).probe(interrupts: interrupts)
        case .play(let options):
            guard let reporter = makeReporter(options.output, stdout: stdout, stderr: stderr) else {
                return .toolFailure
            }
            defer { reporter.close() }
            return await Run(
                source: options.source, output: options.output,
                configuration: options.configuration, reporter: reporter
            ).play(options, interrupts: interrupts)
        }
    }

    private static func makeReporter(
        _ output: OutputOptions, stdout: @escaping Reporter.Sink, stderr: Reporter.Sink
    ) -> Reporter? {
        do {
            return try Reporter(output: output, stdout: stdout)
        } catch {
            stderr("lumectl: \(error)")
            return nil
        }
    }
}

/// One probe or play run.
private struct Run {
    let source: SourceOptions
    let output: OutputOptions
    let configuration: PlayerConfiguration
    let reporter: Reporter

    private var describe: Describe { Describe(showURLs: output.showURLs) }

    // MARK: probe

    func probe(interrupts: AsyncStream<Void>) async -> ExitCode {
        reportStart("probe", extra: [])
        let session = PlayerSession(configuration: configuration)
        let control = RunControl()
        let forwarder = forward(interrupts, to: control)
        defer { forwarder.cancel() }

        let result = await open(session, control: control)
        control.stop(.ended)
        await shutdown(session)
        switch result {
        case .opened(let info):
            let media = describe.media(info)
            reporter.emit("media", text: media.text, fields: [("media", media.json)])
            return summarize(.success, control: control, position: nil)
        case .failed(let error):
            // Probe does not follow the event stream; tally the failure here.
            control.setSessionState(.failed)
            _ = control.recordError(error)
            let described = describe.error(error)
            reporter.emit("error", text: "open failed: \(described.text)", fields: [
                ("fatal", .bool(true)), ("error", described.json),
            ])
            return summarize(.openFailed, control: control, position: nil)
        case .interrupted:
            return summarize(.interrupted, control: control, position: nil)
        }
    }

    // MARK: play

    func play(_ options: PlayOptions, interrupts: AsyncStream<Void>) async -> ExitCode {
        reportStart("play", extra: [
            ("duration", .optional(options.duration)),
            ("start", .optional(options.start)),
            ("seek", .optional(options.seek)),
            ("software", .bool(options.software)),
            ("audioLanguages", .array(options.audioLanguages.map(JSON.string))),
            ("audio", .bool(!options.noAudio)),
            ("video", .bool(!options.noVideo)),
            ("interval", .double(options.interval)),
            ("stallThreshold", .double(configuration.stallThreshold)),
        ])
        let session = PlayerSession(configuration: configuration)
        let control = RunControl()
        let forwarder = forward(interrupts, to: control)
        defer { forwarder.cancel() }

        // Subscribed before `open`, so the opening state changes print too.
        let events = Task { await consumeEvents(of: session, control: control) }

        switch await open(session, control: control) {
        case .opened:
            break
        case .failed:
            // The session reported the failure on its event stream already.
            control.stop(.failed)
            await shutdown(session, draining: events)
            return summarize(.openFailed, control: control, position: nil)
        case .interrupted:
            await shutdown(session, draining: events)
            return summarize(.interrupted, control: control, position: nil)
        }

        await session.play()
        var helpers: [Task<Void, Never>] = []
        if let duration = options.duration {
            helpers.append(Task {
                try? await Task.sleep(for: .seconds(duration))
                control.stop(.duration)
            })
        }
        if options.interval > 0 {
            helpers.append(Task { await heartbeat(session, every: options.interval) })
        }
        helpers.append(Task { await watchStartup(session, thenSeekTo: options.seek) })

        let reason = await control.waitForStop()
        for helper in helpers { helper.cancel() }
        if reason == .interrupted {
            reporter.emit("note", text: "interrupted, shutting down", fields: [("note", .string("interrupted"))])
        }
        let diagnostics = await session.diagnostics
        let position = await session.position
        let line = describe.diagnostics(diagnostics, inputMbps: nil)
        reporter.emit("diagnostics", text: "final \(line.text)", fields: [("diagnostics", line.json)])
        await shutdown(session, draining: events)

        let tally = control.snapshot
        return summarize(
            .playback(failed: tally.failure != nil, stalls: tally.stalls.count),
            control: control, position: position
        )
    }

    // MARK: Steps

    private enum OpenResult {
        case opened(MediaInfo)
        case failed(EngineError)
        case interrupted
    }

    /// `open`, abandoned on Ctrl-C: cancelling the opening task aborts the
    /// FFmpeg I/O, which can otherwise sit out the whole open timeout.
    private func open(_ session: PlayerSession, control: RunControl) async -> OpenResult {
        let url = source.url
        let opening = Task { try await session.open(url: url) }
        // Waits for the run's stop, which every run reaches; by then the
        // open has long finished unless it was the Ctrl-C that stopped it.
        Task {
            _ = await control.waitForStop()
            opening.cancel()
        }
        do {
            return .opened(try await opening.value)
        } catch {
            if control.stopReason == .interrupted { return .interrupted }
            let engineError = (error as? EngineError) ?? EngineError(code: .openFailed, message: "\(error)")
            return .failed(engineError)
        }
    }

    /// Prints events as they come and turns the terminal ones into a stop.
    private func consumeEvents(of session: PlayerSession, control: RunControl) async {
        for await event in session.events {
            switch event {
            case .stateChanged(let state):
                control.setSessionState(state)
                reporter.emit("state", text: "state \(state)", fields: [("state", .string("\(state)"))])
                if state == .ended { control.stop(.ended) }

            case .opened(let info):
                // Printed from here rather than where `open` returns, so the
                // records keep the order the session reported them in.
                let media = describe.media(info)
                reporter.emit("opened", text: "opened\n\(media.text)", fields: [("media", media.json)])
                await reportSelection(session)

            case .decoderDowngraded(let error):
                control.countDowngrade()
                let described = describe.error(error)
                reporter.emit(
                    "decoderDowngraded", text: "decoder downgraded to software: \(described.text)",
                    fields: [("error", described.json)]
                )

            case .didSeek(let position):
                reporter.emit(
                    "didSeek", text: String(format: "seeked to %.3f s", position),
                    fields: [("position", .double(position))]
                )

            case .stalled(let position):
                let reason = await session.lastStallReason
                control.countStall(reason)
                reporter.emit(
                    "stalled",
                    text: String(format: "STALLED at %.3f s, stage: %@", position, reason?.rawValue ?? "unknown"),
                    fields: [("position", .double(position)), ("reason", .optional(reason?.rawValue))]
                )

            case .error(let error):
                // A session that fails switches to `.failed` before it
                // reports why; any other error left the session running.
                let fatal = control.recordError(error)
                let described = describe.error(error)
                reporter.emit(
                    "error", text: "\(fatal ? "FAILED" : "error") \(described.text)",
                    fields: [("fatal", .bool(fatal)), ("error", described.json)]
                )
                if fatal { control.stop(.failed) }
            }
        }
    }

    private func heartbeat(_ session: PlayerSession, every interval: Double) async {
        // Seeded here, so even the first heartbeat has a delivery rate.
        var previous = (bytes: await session.diagnostics.deliveredBytes, at: reporter.elapsed)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            let diagnostics = await session.diagnostics
            let now = reporter.elapsed
            // What the source delivered since the last beat: the number to
            // hold against a provider's per-connection cap.
            let mbps = now > previous.at
                ? Double(diagnostics.deliveredBytes - previous.bytes) * 8 / 1_000_000 / (now - previous.at)
                : nil
            previous = (diagnostics.deliveredBytes, now)
            let line = describe.diagnostics(diagnostics, inputMbps: mbps)
            reporter.emit("heartbeat", text: "heartbeat \(line.text)", fields: [("diagnostics", line.json)])
        }
    }

    /// Prints the startup timeline once the first frame shows, then makes
    /// the `--seek` (a seek that lands mid-stream, which is the case that
    /// differs from `--start`).
    private func watchStartup(_ session: PlayerSession, thenSeekTo seek: Double?) async {
        while !Task.isCancelled {
            let startup = await session.startup
            if startup.firstFrameShown != nil {
                reporter.emit("startup", text: "startup \(startup)", fields: [("startup", describe.startup(startup))])
                if let seek {
                    reporter.emit(
                        "seek", text: String(format: "seeking to %.3f s", seek),
                        fields: [("position", .double(seek))]
                    )
                    await session.seek(to: seek)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func reportSelection(_ session: PlayerSession) async {
        let video = await session.selectedVideoTrackIndex
        let audio = await session.selectedAudioTrackIndex
        let subtitle = await session.selectedSubtitleTrackIndex
        func name(_ index: Int32?) -> String { index.map { "#\($0)" } ?? "none" }
        func json(_ index: Int32?) -> JSON { index.map { .int(Int64($0)) } ?? .null }
        reporter.emit(
            "selected",
            text: "selected video \(name(video)), audio \(name(audio)), subtitles \(name(subtitle))",
            fields: [("video", json(video)), ("audio", json(audio)), ("subtitle", json(subtitle))]
        )
    }

    /// Shuts the session down, bounded: a wedged teardown must not keep the
    /// terminal hostage. The event stream ends with the session, so the
    /// events still queued are printed before the summary.
    private func shutdown(_ session: PlayerSession, draining events: Task<Void, Never>? = nil) async {
        let finished = await finishes(within: 5) { await session.shutdown() }
        if !finished {
            reporter.emit(
                "note", text: "session shutdown did not finish within 5 s",
                fields: [("note", .string("shutdown-timeout"))]
            )
        }
        if let events {
            _ = await finishes(within: 2) { await events.value }
            events.cancel()
        }
    }

    private func reportStart(_ command: String, extra: [(String, JSON)]) {
        let headerNames = source.headers.map(\.name)
        var text = "lumectl \(command) \(describe.url(source.url))"
        if !headerNames.isEmpty {
            text += "\n  headers: \(headerNames.joined(separator: ", ")) (values hidden)"
        }
        reporter.emit("start", text: text, fields: [
            ("command", .string(command)),
            ("url", .string(describe.url(source.url))),
            // Header values are where tokens and cookies travel.
            ("headers", .array(headerNames.map(JSON.string))),
            ("userAgent", .optional(source.userAgent)),
            ("referer", .optional(source.referer.map(describe.url))),
            ("reconnect", .bool(source.reconnect)),
            ("ioTimeout", .optional(source.ioTimeout)),
            ("openTimeout", .optional(source.openTimeout)),
            ("ffmpeg", .string("\(FFmpegRuntime.versions)")),
        ] + extra)
    }

    private func summarize(_ code: ExitCode, control: RunControl, position: Double?) -> ExitCode {
        let tally = control.snapshot
        let stallReasons = tally.stalls.map { $0?.rawValue ?? "unknown" }
        var text = "summary \(code.outcome) (exit \(code.rawValue))"
        if let position { text += String(format: ", position %.3f s", position) }
        text += ", stalls \(tally.stalls.count)"
        if !stallReasons.isEmpty { text += " [\(stallReasons.joined(separator: ", "))]" }
        text += ", errors \(tally.errors), downgrades \(tally.downgrades)"
        if let failure = tally.failure { text += "\n  failure: \(describe.error(failure).text)" }
        reporter.emit("summary", text: text, fields: [
            ("outcome", .string(code.outcome)),
            ("exitCode", .int(Int64(code.rawValue))),
            ("position", .optional(position)),
            ("stalls", .array(stallReasons.map(JSON.string))),
            ("errors", .int(Int64(tally.errors))),
            ("downgrades", .int(Int64(tally.downgrades))),
            ("failure", tally.failure.map { describe.error($0).json } ?? .null),
        ])
        return code
    }

    private func forward(_ interrupts: AsyncStream<Void>, to control: RunControl) -> Task<Void, Never> {
        Task {
            for await _ in interrupts {
                control.stop(.interrupted)
            }
        }
    }
}
