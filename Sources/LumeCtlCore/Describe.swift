import Foundation
import LumeEngineCore

/// Text and JSON renderings of the engine's public types. Anything that can
/// carry a URL goes through `redact` first.
struct Describe {
    /// Redacts URLs inside free text unless the user asked to see them.
    let showURLs: Bool

    func url(_ url: String) -> String {
        showURLs ? url : URLScrubber.redact(url)
    }

    func text(_ text: String) -> String {
        showURLs ? text : URLScrubber.redactText(text)
    }

    // MARK: Media

    func media(_ info: MediaInfo) -> (text: String, json: JSON) {
        var lines: [String] = []
        let duration = info.duration.map { String(format: "%.3f s", seconds($0)) } ?? "unknown (live)"
        lines.append("format    \(info.formatName)")
        lines.append("duration  \(duration)")
        lines.append(String(format: "start     %.3f s", seconds(info.startTime)))
        lines.append("live      \(info.isLive ? "yes" : "no")   seekable \(info.isSeekable ? "yes" : "no")")
        if info.bitrate >= 1_000_000 {
            lines.append(String(format: "bitrate   %.2f Mbit/s", Double(info.bitrate) / 1_000_000))
        } else if info.bitrate >= 1000 {
            lines.append(String(format: "bitrate   %.0f kbit/s", Double(info.bitrate) / 1000))
        } else if info.bitrate > 0 {
            lines.append("bitrate   \(info.bitrate) bit/s")
        }
        lines.append("tracks")
        for track in info.tracks {
            lines.append("  " + trackLine(track))
        }
        if !info.chapters.isEmpty {
            lines.append("chapters")
            for chapter in info.chapters {
                lines.append(String(
                    format: "  %.3f–%.3f s %@",
                    seconds(chapter.start), seconds(chapter.end), text(chapter.title ?? "")
                ))
            }
        }
        if !info.metadata.isEmpty {
            lines.append("metadata")
            for key in info.metadata.keys.sorted() {
                lines.append("  \(key): \(text(info.metadata[key] ?? ""))")
            }
        }

        let json = JSON.object([
            ("format", .string(info.formatName)),
            ("duration", .optional(info.duration.map(seconds))),
            ("startTime", .double(seconds(info.startTime))),
            ("live", .bool(info.isLive)),
            ("seekable", .bool(info.isSeekable)),
            ("bitrate", .int(info.bitrate)),
            ("tracks", .array(info.tracks.map(trackJSON))),
            ("chapters", .array(info.chapters.map { chapter in
                .object([
                    ("title", .optional(chapter.title.map(text))),
                    ("start", .double(seconds(chapter.start))),
                    ("end", .double(seconds(chapter.end))),
                ])
            })),
            ("metadata", .object(info.metadata.keys.sorted().map { ($0, .string(text(info.metadata[$0] ?? ""))) })),
        ])
        return (lines.joined(separator: "\n"), json)
    }

    private func trackLine(_ track: TrackInfo) -> String {
        var parts = ["#\(track.index)", track.kind.rawValue, track.codecName]
        if let language = track.language { parts.append(language) }
        if let video = track.video {
            parts.append("\(video.width)x\(video.height)")
            if video.fps > 0 { parts.append(String(format: "%.6g fps", video.fps)) }
            if video.bitDepth > 0 { parts.append("\(video.bitDepth)-bit") }
            if let pixelFormat = video.pixelFormatName { parts.append(pixelFormat) }
            parts.append(colour(video))
            if video.rotation != 0 { parts.append("rotated \(video.rotation)°") }
        }
        if let audio = track.audio {
            parts.append("\(audio.channels) ch")
            parts.append("\(audio.sampleRate) Hz")
        }
        if track.bitrate > 0 {
            parts.append(String(format: "%.0f kbit/s", Double(track.bitrate) / 1000))
        }
        if let title = track.title, !title.isEmpty { parts.append("\"\(text(title))\"") }
        if track.isDefault { parts.append("[default]") }
        if track.isForced { parts.append("[forced]") }
        return parts.joined(separator: " ")
    }

    /// `HDR PQ bt2020/bt2020nc full` — enough to tell HDR10 from HLG from
    /// SDR, and to spot an IPT base layer (Dolby Vision profile 5) that the
    /// matrix tag gives away.
    private func colour(_ video: TrackInfo.Video) -> String {
        let range = video.colorRangeFull ? "full" : "limited"
        let unspecified: UInt32 = 2
        if video.colorPrimaries == unspecified, video.colorTransfer == unspecified, video.colorSpace == unspecified {
            return "\(video.isHDR ? "HDR" : "SDR") untagged \(range)"
        }
        let dynamicRange: String
        switch ColourNames.transfer(video.colorTransfer) {
        case "pq": dynamicRange = "HDR PQ"
        case "hlg": dynamicRange = "HDR HLG"
        default: dynamicRange = video.isHDR ? "HDR" : "SDR"
        }
        return "\(dynamicRange) \(ColourNames.primaries(video.colorPrimaries))/\(ColourNames.matrix(video.colorSpace))"
            + "/\(ColourNames.transfer(video.colorTransfer)) \(range)"
    }

    private func trackJSON(_ track: TrackInfo) -> JSON {
        var members: [(String, JSON)] = [
            ("index", .int(Int64(track.index))),
            ("kind", .string(track.kind.rawValue)),
            ("codec", .string(track.codecName)),
            ("language", .optional(track.language)),
            ("title", .optional(track.title.map(text))),
            ("default", .bool(track.isDefault)),
            ("forced", .bool(track.isForced)),
            ("bitrate", .int(track.bitrate)),
        ]
        if let video = track.video {
            members.append(("video", .object([
                ("width", .int(Int64(video.width))),
                ("height", .int(Int64(video.height))),
                ("fps", .double(video.fps)),
                ("bitDepth", .int(Int64(video.bitDepth))),
                ("pixelFormat", .optional(video.pixelFormatName)),
                ("rotation", .int(Int64(video.rotation))),
                ("hdr", .bool(video.isHDR)),
                ("primaries", .string(ColourNames.primaries(video.colorPrimaries))),
                ("transfer", .string(ColourNames.transfer(video.colorTransfer))),
                ("matrix", .string(ColourNames.matrix(video.colorSpace))),
                ("fullRange", .bool(video.colorRangeFull)),
            ])))
        }
        if let audio = track.audio {
            members.append(("audio", .object([
                ("channels", .int(Int64(audio.channels))),
                ("sampleRate", .int(Int64(audio.sampleRate))),
            ])))
        }
        return .object(members)
    }

    // MARK: Errors

    func error(_ error: EngineError) -> (text: String, json: JSON) {
        var detail: [String] = []
        if let ffmpegCode = error.ffmpegCode { detail.append("ffmpeg \(ffmpegCode)") }
        if let http = error.httpFailure { detail.append("http \(http.rawValue)") }
        let suffix = detail.isEmpty ? "" : " (\(detail.joined(separator: ", ")))"
        let message = text(error.message)
        let json = JSON.object([
            ("code", .string(error.code.rawValue)),
            ("ffmpegCode", error.ffmpegCode.map { .int(Int64($0)) } ?? .null),
            ("http", .optional(error.httpFailure?.rawValue)),
            ("message", .string(message)),
        ])
        return ("\(error.code.rawValue)\(suffix): \(message)", json)
    }

    // MARK: Session state

    func startup(_ startup: StartupTimeline) -> JSON {
        .object([
            ("opened", .optional(startup.opened)),
            ("firstPacket", .optional(startup.firstPacket)),
            ("firstVideoFrame", .optional(startup.firstVideoFrame)),
            ("firstAudioFrame", .optional(startup.firstAudioFrame)),
            ("firstFrameShown", .optional(startup.firstFrameShown)),
        ])
    }

    func diagnostics(_ diagnostics: PlayerSession.Diagnostics, inputMbps: Double?) -> (text: String, json: JSON) {
        func lane(_ queue: (count: Int, seconds: Double)?) -> JSON {
            guard let queue else { return .null }
            return .object([("count", .int(Int64(queue.count))), ("seconds", .double(queue.seconds))])
        }
        let health = diagnostics.rendererHealth
        var line = text(diagnostics.description)
        if let inputMbps { line += String(format: " in=%.2fMbit/s", inputMbps) }
        let json = JSON.object([
            ("state", .string(diagnostics.state)),
            ("playhead", .double(diagnostics.playheadSeconds)),
            ("videoFrames", lane(diagnostics.videoQueue)),
            ("videoPackets", lane(diagnostics.videoPacketQueue)),
            ("videoLead", .double(diagnostics.videoLeadSeconds)),
            ("audioFrames", lane(diagnostics.audioQueue)),
            ("audioPackets", lane(diagnostics.audioPacketQueue)),
            ("audioLead", .double(diagnostics.audioLeadSeconds)),
            ("renderers", .object([
                ("video", .int(Int64(health.videoStatus))),
                ("audio", .int(Int64(health.audioStatus))),
                ("videoError", .optional(health.videoError.map(text))),
                ("audioError", .optional(health.audioError.map(text))),
            ])),
            ("demuxEOF", .bool(diagnostics.demuxAtEOF)),
            ("sourceLost", .bool(diagnostics.sourceLost)),
            ("deliveredBytes", .int(diagnostics.deliveredBytes)),
            ("inputMbps", .optional(inputMbps)),
            ("timelineSeams", .int(Int64(diagnostics.timelineSeams))),
            ("replayedPackets", .int(Int64(diagnostics.replayedPackets))),
            ("lastStallReason", .optional(diagnostics.lastStallReason?.rawValue)),
            ("startup", startup(diagnostics.startup)),
        ])
        return (line, json)
    }

    private func seconds(_ microseconds: Int64) -> Double {
        Double(microseconds) / 1_000_000
    }
}

/// Names for the ITU-T H.273 code points `TrackInfo.Video` carries raw.
enum ColourNames {
    static func primaries(_ value: UInt32) -> String {
        switch value {
        case 1: "bt709"
        case 2: "unspecified"
        case 5: "bt470bg"
        case 6: "smpte170m"
        case 9: "bt2020"
        case 11: "dci-p3"
        case 12: "display-p3"
        default: "pri\(value)"
        }
    }

    static func transfer(_ value: UInt32) -> String {
        switch value {
        case 1: "bt709"
        case 2: "unspecified"
        case 6: "smpte170m"
        case 8: "linear"
        case 13: "srgb"
        case 14: "bt2020-10"
        case 15: "bt2020-12"
        case 16: "pq"
        case 18: "hlg"
        default: "trc\(value)"
        }
    }

    static func matrix(_ value: UInt32) -> String {
        switch value {
        case 0: "rgb"
        case 1: "bt709"
        case 2: "unspecified"
        case 5: "bt470bg"
        case 6: "smpte170m"
        case 9: "bt2020nc"
        case 10: "bt2020c"
        case 14: "ictcp"
        // Dolby Vision's IPT base layer (profiles 5, 10.0, 20) when the
        // stream tags it; many such encodes leave the matrix unspecified.
        case 15: "ipt-c2"
        default: "spc\(value)"
        }
    }
}
