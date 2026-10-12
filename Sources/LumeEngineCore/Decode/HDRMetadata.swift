internal import CFFmpeg
import CoreVideo
import Foundation

/// HDR10's static metadata — the mastering display's colour volume (SMPTE ST
/// 2086) and the content light levels (MaxCLL/MaxFALL, CTA-861.3) — in the
/// form Apple's renderers read it: big-endian payloads attached to the pixel
/// buffer, which `SampleBufferBuilder` then carries into the format
/// description (both keys are among CoreMedia's extensions common with image
/// buffers).
///
/// Without it the display pipeline has to assume how bright the master was,
/// and tone maps a 1000-nit grade and a 4000-nit grade the same way: on a TV
/// that cannot reach the master's peak, highlights clip or the whole picture
/// comes out dim. No decode path attaches it by itself — VideoToolbox, as
/// FFmpeg drives it, leaves its surfaces without either key even when the
/// bitstream repeats the SEI on every keyframe, and the engine's own buffers
/// (software decode, deinterlacer output, Dolby Vision conversion) carry only
/// what the engine writes. So it is read from the frame, where FFmpeg puts
/// both the bitstream's SEI and the container's boxes (`mdcv`/`clli`, the
/// Matroska colour elements), and written on every delivered buffer.
struct HDRMetadata: Sendable, Equatable {
    /// A CIE 1931 chromaticity in units of 0.00002, as ST 2086 codes it.
    struct Chromaticity: Sendable, Equatable {
        var x: UInt16
        var y: UInt16
    }

    struct MasteringDisplay: Sendable, Equatable {
        var red: Chromaticity
        var green: Chromaticity
        var blue: Chromaticity
        var whitePoint: Chromaticity
        /// In units of 0.0001 cd/m².
        var maxLuminance: UInt32
        var minLuminance: UInt32

        /// The 24-byte payload of `kCVImageBufferMasteringDisplayColorVolumeKey`:
        /// HEVC's mastering display colour volume SEI (ISO/IEC 23008-2 D.2.28)
        /// verbatim, big-endian. The SEI lists the primaries green, blue, red
        /// — ST 2086's order, not FFmpeg's red, green, blue — then the white
        /// point, then maximum before minimum luminance.
        var payload: Data {
            var data = Data(capacity: 24)
            for value in [green.x, green.y, blue.x, blue.y, red.x, red.y, whitePoint.x, whitePoint.y] {
                data.appendBigEndian(value)
            }
            data.appendBigEndian(maxLuminance)
            data.appendBigEndian(minLuminance)
            return data
        }
    }

    struct ContentLightLevel: Sendable, Equatable {
        /// Brightest pixel of the whole programme, cd/m².
        var maxCLL: UInt16
        /// Brightest frame average of the whole programme, cd/m².
        var maxFALL: UInt16

        /// The 4-byte payload of `kCVImageBufferContentLightLevelInfoKey`: the
        /// content light level SEI (ISO/IEC 23008-2 D.2.35), big-endian.
        var payload: Data {
            var data = Data(capacity: 4)
            data.appendBigEndian(maxCLL)
            data.appendBigEndian(maxFALL)
            return data
        }
    }

    var masteringDisplay: MasteringDisplay?
    var contentLightLevel: ContentLightLevel?

    /// Writes or removes both keys. Removal matters as much as writing: pool
    /// buffers are recycled — the engine's and VideoToolbox's alike — and
    /// would otherwise keep the previous stream's values.
    func apply(to buffer: CVPixelBuffer) {
        if let masteringDisplay {
            CVBufferSetAttachment(
                buffer, kCVImageBufferMasteringDisplayColorVolumeKey,
                masteringDisplay.payload as CFData, .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey)
        }
        if let contentLightLevel {
            CVBufferSetAttachment(
                buffer, kCVImageBufferContentLightLevelInfoKey,
                contentLightLevel.payload as CFData, .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferContentLightLevelInfoKey)
        }
    }
}

// MARK: - Extraction from FFmpeg

extension HDRMetadata {
    /// The static metadata a decoded frame carries. FFmpeg's decoders attach
    /// stream-level side data (container boxes) to every frame and let the
    /// bitstream's SEI override it, so the frame is the one place to look.
    init(frame: UnsafePointer<AVFrame>) {
        self.init(
            masteringDisplay: av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA)
                .flatMap { $0.pointee.data }
                .flatMap { MasteringDisplay(UnsafeRawPointer($0).assumingMemoryBound(to: AVMasteringDisplayMetadata.self).pointee) },
            contentLightLevel: av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL)
                .flatMap { $0.pointee.data }
                .flatMap { ContentLightLevel(UnsafeRawPointer($0).assumingMemoryBound(to: AVContentLightMetadata.self).pointee) }
                ?? Self.dolbyVisionLightLevel(frame)
        )
    }

    /// Dolby Vision streams often carry no HDR10 SEI of their own: the RPU's
    /// level 6 block holds the same MaxCLL/MaxFALL. Used only when the frame
    /// has no content light level otherwise — notably for profile 5 output,
    /// which the engine converts to HDR10 and would leave without any.
    private static func dolbyVisionLightLevel(_ frame: UnsafePointer<AVFrame>) -> ContentLightLevel? {
        guard let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA),
              let bytes = sideData.pointee.data,
              let level6 = av_dovi_find_level(UnsafeRawPointer(bytes).assumingMemoryBound(to: AVDOVIMetadata.self), 6)
        else { return nil }
        let values = level6.pointee.l6
        // Zero is "unknown" in both fields (CTA-861.3); a block of zeros says
        // nothing.
        guard values.max_cll > 0 || values.max_fall > 0 else { return nil }
        return ContentLightLevel(maxCLL: values.max_cll, maxFALL: values.max_fall)
    }
}

extension HDRMetadata.MasteringDisplay {
    /// Nil unless FFmpeg has both the primaries and the luminance range: the
    /// payload has no way to say "unknown" for either half, and a made-up
    /// value would steer the tone mapping wrong rather than not at all.
    init?(_ metadata: AVMasteringDisplayMetadata) {
        guard metadata.has_primaries != 0, metadata.has_luminance != 0 else { return nil }
        let primaries = metadata.display_primaries
        guard let red = Self.chromaticity(primaries.0.0, primaries.0.1),
              let green = Self.chromaticity(primaries.1.0, primaries.1.1),
              let blue = Self.chromaticity(primaries.2.0, primaries.2.1),
              let white = Self.chromaticity(metadata.white_point.0, metadata.white_point.1),
              let max = Self.luminance(metadata.max_luminance),
              let min = Self.luminance(metadata.min_luminance)
        else { return nil }
        self.init(red: red, green: green, blue: blue, whitePoint: white, maxLuminance: max, minLuminance: min)
    }

    /// FFmpeg keeps the values as rationals (the SEI's integers over 50000
    /// and 10000, or whatever a container stored); they go back to the SEI's
    /// fixed units here, rounded. ST 2086 caps chromaticities at 50000.
    private static func chromaticity(_ x: AVRational, _ y: AVRational) -> HDRMetadata.Chromaticity? {
        guard let x = scaled(x, by: 50_000, limit: 50_000),
              let y = scaled(y, by: 50_000, limit: 50_000)
        else { return nil }
        return HDRMetadata.Chromaticity(x: UInt16(x), y: UInt16(y))
    }

    private static func luminance(_ value: AVRational) -> UInt32? {
        scaled(value, by: 10_000, limit: Double(UInt32.max)).map { UInt32($0) }
    }

    private static func scaled(_ value: AVRational, by unit: Double, limit: Double) -> Double? {
        guard value.den != 0 else { return nil }
        let result = (Double(value.num) / Double(value.den) * unit).rounded()
        guard result.isFinite, result >= 0 else { return nil }
        return Swift.min(result, limit)
    }
}

extension HDRMetadata.ContentLightLevel {
    init(_ metadata: AVContentLightMetadata) {
        self.init(
            maxCLL: UInt16(clamping: metadata.MaxCLL),
            maxFALL: UInt16(clamping: metadata.MaxFALL)
        )
    }
}

// MARK: - HDR10+

/// HDR10+ (SMPTE ST 2094-40) dynamic metadata: per-scene tone-mapping
/// guidance, which a display that supports it uses instead of the static
/// MaxCLL. Apple takes it per sample (`kCMSampleAttachmentKey_HDR10PlusPerFrameData`)
/// as the ITU-T T.35 message an HEVC user-data-registered SEI carries,
/// starting with the country code.
enum HDR10Plus {
    /// The T.35 header FFmpeg's serializer leaves out: country code (United
    /// States), terminal provider code 0x003C, provider-oriented code 0x0001,
    /// application identifier 4 — the 48 bits CTA-861-H prefixes every HDR10+
    /// message with.
    static let t35Header: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    /// The frame's HDR10+ metadata as Apple's attachment wants it, or nil
    /// when the frame carries none or it does not serialize.
    static func t35Message(from frame: UnsafePointer<AVFrame>) -> Data? {
        guard let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS),
              let bytes = sideData.pointee.data
        else { return nil }
        return t35Message(UnsafeRawPointer(bytes).assumingMemoryBound(to: AVDynamicHDRPlus.self))
    }

    static func t35Message(_ metadata: UnsafePointer<AVDynamicHDRPlus>) -> Data? {
        var buffer: UnsafeMutablePointer<UInt8>?
        var size = 0
        guard av_dynamic_hdr_plus_to_t35(metadata, &buffer, &size) >= 0, let buffer else { return nil }
        defer { av_free(buffer) }
        var message = Data(t35Header)
        message.append(buffer, count: size)
        return message
    }
}

private extension Data {
    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
