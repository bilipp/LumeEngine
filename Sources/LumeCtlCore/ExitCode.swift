/// lumectl's exit status: scripts reproducing a provider issue in a loop
/// branch on these, so each failure class gets its own code.
public enum ExitCode: Int32, Sendable {
    /// Played for the requested time, to the end, or until Ctrl-C, with no
    /// stall and no failure. Probe: the source opened.
    case success = 0
    /// lumectl itself could not run (e.g. the record file).
    case toolFailure = 1
    /// Bad command line.
    case usage = 2
    /// The source never opened (DNS, connect, HTTP status, probe, timeout).
    case openFailed = 3
    /// The session opened and then failed.
    case playbackFailed = 4
    /// The session stalled at least once and did not fail.
    case stalled = 5
    /// Ctrl-C before the source opened: no verdict to report.
    case interrupted = 130

    /// The verdict of a playback that got past `open`: a failure outranks a
    /// stall (the stall usually preceded it), and Ctrl-C is how a live run
    /// ends, so it is not a verdict of its own.
    static func playback(failed: Bool, stalls: Int) -> ExitCode {
        if failed { return .playbackFailed }
        if stalls > 0 { return .stalled }
        return .success
    }

    /// Short name used in the summary record.
    var outcome: String {
        switch self {
        case .success: "ok"
        case .toolFailure: "tool-failure"
        case .usage: "usage"
        case .openFailed: "open-failed"
        case .playbackFailed: "playback-failed"
        case .stalled: "stalled"
        case .interrupted: "interrupted"
        }
    }
}
