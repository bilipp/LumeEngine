import Foundation

/// Whether the session's audio is reaching the viewer, as far as the engine
/// can tell. Read `PlayerSession.audioHealth`; it is also in `Diagnostics`.
///
/// Exists because audio can die while video plays on: a decoder that gives up
/// leaves its lane at end of stream, and the session — correctly — keeps
/// showing the picture. Without this the only trace was one `.error` event,
/// and the viewer sat in front of a silent channel.
public enum AudioHealth: Sendable, Equatable, CustomStringConvertible {
    /// Audio is playing, or nothing says otherwise yet.
    case healthy
    /// The session has no audio lane: the source carries no audio, or the
    /// host opened it without (`enableAudio`) or turned it off.
    case absent
    /// The audio lane has stopped while the session plays on.
    case lost(AudioLossReason)

    public var description: String {
        switch self {
        case .healthy: "ok"
        case .absent: "none"
        case .lost(let reason): "lost(\(reason.rawValue))"
        }
    }
}

/// Which stage the audio was lost in.
public enum AudioLossReason: String, Sendable, Equatable {
    /// The audio decoder gave up on the stream (its error went out as an
    /// `.error` event). Permanent for the track: switching tracks, or audio
    /// off and on, builds a new decoder.
    case decoderFailed
    /// The system audio renderer failed. The session fails with
    /// `.renderFailed` as well; this records that it was the audio lane.
    case rendererFailed
    /// The clock runs and video plays, but for a while now the audio renderer
    /// has had nothing to play at the playhead: decoded audio stopped reaching
    /// it, or reached it too late to play. Reported once per episode as an
    /// `.error` with `EngineError.Code.audioLost`; clears by itself when audio
    /// comes back.
    case starved
}

/// Decides `AudioHealth` from what the session observes on its monitor tick.
///
/// Pure value logic, so every branch is testable without a pipeline that has
/// to be made to lose its audio.
///
/// The starvation judgement is deliberately narrow, so that moments without
/// audio that are part of normal playback never count: it needs a running
/// clock (not paused, buffering or seeking), a video lane that is itself ahead
/// of the playhead (a whole pipeline running dry is buffering, which the
/// session handles), an audio lane still expecting data (not at its end), and
/// the playhead to have moved `threshold` seconds of media with no audio
/// enqueued beyond it. A gap *inside* the audio does not count either: the
/// renderer's high-water mark is past the gap as soon as audio after it was
/// enqueued.
struct AudioLossDetector {
    /// Seconds of media the playhead must cover without audio ahead of it.
    static let threshold = 2.0

    struct Observation: Equatable {
        /// An audio lane is attached.
        var hasAudioLane: Bool
        /// The audio decoder reached the end of its stream: nothing more is
        /// coming, and silence after it is the source's end, not a loss.
        var audioEnded: Bool
        /// The audio renderer reports `.failed`.
        var audioRendererFailed: Bool
        /// The session plays and the clock rate is non-zero.
        var clockRunning: Bool
        /// Playhead, seconds; nil while the clock has no valid time.
        var playhead: Double?
        /// Audio is enqueued beyond the playhead.
        var audioAhead: Bool
        /// Video is enqueued beyond the playhead; nil without a video lane.
        var videoAhead: Bool?
        /// The session's seek serial: a seek rebuilds every queue, so any
        /// episode in progress is void.
        var serial: UInt64
    }

    private(set) var health: AudioHealth = .absent
    /// A loss only a new decoder clears.
    private var permanent: AudioLossReason?
    /// Playhead when audio was first seen missing; nil while it is not.
    private var dryFrom: Double?
    private var serial: UInt64 = 0

    /// The audio decoder failed for good.
    mutating func decoderFailed() {
        permanent = .decoderFailed
        health = .lost(.decoderFailed)
    }

    /// The audio lane was rebuilt or removed (track switch, audio off/on):
    /// whatever was wrong with the old one is gone with it.
    mutating func laneReplaced() {
        permanent = nil
        dryFrom = nil
        health = .healthy
    }

    /// Updates `health`; returns the reason when a starvation episode begins,
    /// which is the moment to tell the host.
    mutating func observe(_ observation: Observation) -> AudioLossReason? {
        guard observation.hasAudioLane else {
            permanent = nil
            dryFrom = nil
            health = .absent
            return nil
        }
        if health == .absent {
            health = .healthy
        }
        if observation.audioRendererFailed {
            permanent = .rendererFailed
        }
        if let permanent {
            dryFrom = nil
            health = .lost(permanent)
            return nil
        }
        if observation.serial != serial {
            serial = observation.serial
            dryFrom = nil
            health = .healthy
        }
        if observation.audioEnded || observation.audioAhead {
            dryFrom = nil
            health = .healthy
            return nil
        }
        // Not judged: paused, buffering or seeking (the clock does not run),
        // no time yet, or no healthy video to compare against. A standing
        // verdict stays until audio is seen ahead again.
        guard observation.clockRunning,
              let playhead = observation.playhead,
              observation.videoAhead == true
        else {
            dryFrom = nil
            return nil
        }
        guard let start = dryFrom, playhead >= start else {
            dryFrom = playhead
            return nil
        }
        guard playhead - start >= Self.threshold, health != .lost(.starved) else { return nil }
        health = .lost(.starved)
        return .starved
    }
}
