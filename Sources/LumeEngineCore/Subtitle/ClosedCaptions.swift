internal import CFFmpeg
import Foundation
import Synchronization

/// Closed captions carried inside the video stream.
///
/// US broadcast (ATSC) and much IPTV ship captions not as a subtitle stream
/// but as A/53 user data in the video itself — SEI messages in H.264/HEVC,
/// picture user data in MPEG-2 — which FFmpeg's video decoders hand out as
/// `AV_FRAME_DATA_A53_CC` side data on the decoded frame: a run of 3-byte
/// `cc_data` triples. The tap lifts those payloads off the video lane and
/// feeds them, as packets stamped with the frame's PTS, to an ordinary
/// `SubtitleDecoder` running FFmpeg's `ccaption` decoder. That keeps captions
/// on the video's own timestamps (engine µs, display order), and keeps
/// caption decoding — and its failures — off the video thread.
///
/// The video thread never waits on it: payloads go out with `trySend`, and a
/// caption lane that falls behind loses captions, never frames.
final class ClosedCaptionTap: Sendable {
    private struct State {
        var detected = false
        var sink: Channel<Packet>?
    }

    private let state = Mutex(State())

    /// True once the video carried caption data with content (null padding
    /// alone does not count — broadcast encoders send it on every frame).
    var hasDetectedCaptions: Bool {
        state.withLock { $0.detected }
    }

    /// Starts (or with `nil` stops) forwarding caption payloads.
    func attach(_ sink: Channel<Packet>?) {
        state.withLock { $0.sink = sink }
    }

    /// Video decode thread: called with every decoded frame, before any
    /// filtering. A frame without caption data costs one side-data lookup.
    func offer(_ frame: UnsafeMutablePointer<AVFrame>, serial: UInt64) {
        guard let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_A53_CC),
              let data = sideData.pointee.data,
              sideData.pointee.size > 0
        else { return }
        let payload = UnsafeRawBufferPointer(start: data, count: Int(sideData.pointee.size))

        let (detected, sink) = state.withLock { ($0.detected, $0.sink) }
        if !detected, ClosedCaptionData.carriesCaptions(payload) {
            state.withLock { $0.detected = true }
        }

        let pts = frame.pointee.best_effort_timestamp
        guard let sink, MediaTime.isValid(pts),
              let packet = Packet(copying: payload, pts: pts, serial: serial)
        else { return }
        _ = sink.trySend(packet)
    }
}

/// Reading A/53 `cc_data` (CEA-708 §4.4: `cc_valid`, `cc_type`, two data
/// bytes per triple).
enum ClosedCaptionData {
    /// Whether the payload holds caption data for CC1/CC2 (CEA-608 field 1)
    /// beyond null padding — what decides that a stream has captions to
    /// offer. Field 2 (CC3/CC4, mostly XDS metadata) and DTVCC (708) packets
    /// do not count: the caption decoder shows field 1 only.
    static func carriesCaptions(_ payload: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset + 3 <= payload.count {
            let header = payload[offset]
            let valid = header & 0x04 != 0
            let fieldOne = header & 0x03 == 0
            if valid, fieldOne, payload[offset + 1] & 0x7F != 0 || payload[offset + 2] & 0x7F != 0 {
                return true
            }
            offset += 3
        }
        return false
    }
}

extension TrackInfo {
    /// The synthetic track for captions found in the video stream.
    static let embeddedClosedCaptions = TrackInfo(
        index: embeddedClosedCaptionsIndex,
        kind: .subtitle,
        codecName: String(cString: avcodec_get_name(AV_CODEC_ID_EIA_608)),
        codecID: AV_CODEC_ID_EIA_608.rawValue,
        language: nil,
        title: "CC1",
        isDefault: false,
        isForced: false,
        bitrate: 0,
        video: nil,
        audio: nil,
        wrapBits: 64
    )
}

extension CodecParameters {
    /// Parameters for the caption lane: no container stream describes it.
    static func closedCaptions() -> CodecParameters? {
        guard let scratch = avcodec_parameters_alloc() else { return nil }
        defer {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = scratch
            avcodec_parameters_free(&pointer)
        }
        scratch.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        scratch.pointee.codec_id = AV_CODEC_ID_EIA_608
        return CodecParameters(copying: scratch)
    }
}

extension Packet {
    /// A packet owning a copy of `bytes`, on the engine timeline already.
    convenience init?(copying bytes: UnsafeRawBufferPointer, pts: Int64, serial: UInt64) {
        guard let base = bytes.baseAddress, !bytes.isEmpty,
              let raw = av_packet_alloc()
        else { return nil }
        guard av_new_packet(raw, Int32(bytes.count)) >= 0, let destination = raw.pointee.data else {
            var pointer: UnsafeMutablePointer<AVPacket>? = raw
            av_packet_free(&pointer)
            return nil
        }
        destination.update(from: base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        raw.pointee.pts = pts
        raw.pointee.dts = pts
        self.init(adopting: raw, pts: pts, dts: pts, duration: 0, serial: serial)
    }
}
