internal import CFFmpeg
import CoreVideo
import Foundation

/// One decoded video frame, always backed by a `CVPixelBuffer` (zero-copy from
/// VideoToolbox, or pool-converted from software decode). Immutable after
/// construction — the `@unchecked Sendable` justification (PLAN.md D2).
public final class VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Presentation time, engine µs (already wrap-unwrapped).
    public let pts: Int64
    public let duration: Int64
    public let serial: UInt64
    public let width: Int
    public let height: Int
    /// True when the pixel buffer is a VideoToolbox surface handed over
    /// zero-copy. False for anything the CPU had to write, including frames
    /// that were hardware-decoded and then deinterlaced.
    public let isHardwareDecoded: Bool
    /// What the decoded frame declared about its own colour. Reported on every
    /// path, but only *acted on* for CPU-produced buffers: a VideoToolbox
    /// surface is already tagged by VideoToolbox from the bitstream VUI
    /// (measured on an Apple TV 4K), so the engine reads its colorimetry and
    /// changes nothing about it.
    public let colorimetry: VideoColorimetry

    init(
        pixelBuffer: CVPixelBuffer,
        pts: Int64,
        duration: Int64,
        serial: UInt64,
        isHardwareDecoded: Bool,
        colorimetry: VideoColorimetry
    ) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
        self.serial = serial
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
        self.isHardwareDecoded = isHardwareDecoded
        self.colorimetry = colorimetry
    }
}

/// The colour signalling one decoded frame carries: the four `AVCOL_*` code
/// points, plus the two static HDR side-data payloads already converted into
/// the exact byte layout CoreVideo wants.
///
/// The code points are kept **raw**, not folded into an engine enum, and that
/// is deliberate: `AVCOL_*_UNSPECIFIED` (2) has to stay distinguishable from
/// every value the CoreVideo mapping simply has no constant for. Unspecified is
/// the case that must produce *no attachment at all* rather than a guessed
/// default — SD/IPTV streams emit it constantly, and a wrong tag there would
/// regress ordinary channels for every user. An `.unknown` enum case erases
/// exactly that distinction, so there isn't one.
///
/// Immutable after construction; `Data` and the integers are all value types,
/// so the conformance is a real `Sendable`, not an audited exception.
public struct VideoColorimetry: Sendable, Equatable {
    /// `AVCOL_PRI_*`.
    public let primaries: UInt32
    /// `AVCOL_TRC_*`.
    public let transfer: UInt32
    /// `AVCOL_SPC_*` (the YCbCr matrix).
    public let matrix: UInt32
    /// `AVCOL_RANGE_JPEG` rather than `AVCOL_RANGE_MPEG`. CoreVideo expresses
    /// range through the *pixel format* (`420v` vs `420f`), not an attachment,
    /// so this drives the buffer format rather than a tag.
    public let isFullRange: Bool
    /// SMPTE ST 2086 mastering-display colour volume: 24 bytes, big-endian, in
    /// the `mdcv` order (G, B, R) — the payload
    /// `kCVImageBufferMasteringDisplayColorVolumeKey` expects verbatim.
    /// `nil` when the frame carries no such side data, or carries only half of
    /// it (primaries without luminance, or the reverse), which cannot be
    /// expressed in that payload and is not worth inventing values for.
    public let masteringDisplayColorVolume: Data?
    /// CTA-861.3 content light level: 4 bytes, big-endian, MaxCLL then MaxFALL
    /// — the payload `kCVImageBufferContentLightLevelInfoKey` expects verbatim.
    public let contentLightLevel: Data?

    init(
        primaries: UInt32,
        transfer: UInt32,
        matrix: UInt32,
        isFullRange: Bool,
        masteringDisplayColorVolume: Data?,
        contentLightLevel: Data?
    ) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.isFullRange = isFullRange
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevel = contentLightLevel
    }

    /// Reads what this frame actually declares. On the deinterlaced path the
    /// frame handed in is the *filter's output*, so what gets read is what the
    /// filter produced (libavfilter's `av_frame_copy_props` carries the source
    /// signalling across, and a filter that changed it would be reported as
    /// changed) — never the pre-filter frame, and never an assumption.
    init(frame: UnsafePointer<AVFrame>) {
        self.init(
            primaries: frame.pointee.color_primaries.rawValue,
            transfer: frame.pointee.color_trc.rawValue,
            matrix: frame.pointee.colorspace.rawValue,
            isFullRange: frame.pointee.color_range == AVCOL_RANGE_JPEG,
            masteringDisplayColorVolume: Self.masteringDisplayPayload(of: frame),
            contentLightLevel: Self.contentLightPayload(of: frame)
        )
    }

    // MARK: Side-data payloads

    /// Chromaticity is stored in increments of 0.00002 and luminance in
    /// increments of 0.0001 cd/m² — ST 2086's fixed-point units, the same ones
    /// the ISO `mdcv` box uses.
    private static let chromaticityScale = 50000.0
    private static let luminanceScale = 10000.0

    private static func masteringDisplayPayload(of frame: UnsafePointer<AVFrame>) -> Data? {
        guard let side = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA),
              side.pointee.size >= MemoryLayout<AVMasteringDisplayMetadata>.size,
              let raw = side.pointee.data
        else { return nil }
        let metadata = UnsafeRawPointer(raw)
            .assumingMemoryBound(to: AVMasteringDisplayMetadata.self).pointee
        // Both halves or nothing: the payload has no way to say "luminance
        // unknown", and a plausible-looking substitute is exactly the guess
        // this whole path refuses to make.
        guard metadata.has_primaries != 0, metadata.has_luminance != 0 else { return nil }

        // FFmpeg normalises the SEI's G,B,R ordering to R,G,B on the way in
        // (`h2645_sei.c`); the payload wants G,B,R again on the way out.
        let redGreenBlue = withUnsafePointer(to: metadata.display_primaries) { pointer in
            pointer.withMemoryRebound(to: AVRational.self, capacity: 6) { flat in
                (0..<6).map { flat[$0] }
            }
        }
        let greenBlueRedOrder = [1, 2, 0]

        var payload = Data(capacity: 24)
        for component in greenBlueRedOrder {
            payload.appendBigEndian(fixedPoint16(redGreenBlue[component * 2], scale: chromaticityScale))
            payload.appendBigEndian(fixedPoint16(redGreenBlue[component * 2 + 1], scale: chromaticityScale))
        }
        payload.appendBigEndian(fixedPoint16(metadata.white_point.0, scale: chromaticityScale))
        payload.appendBigEndian(fixedPoint16(metadata.white_point.1, scale: chromaticityScale))
        payload.appendBigEndian(fixedPoint32(metadata.max_luminance, scale: luminanceScale))
        payload.appendBigEndian(fixedPoint32(metadata.min_luminance, scale: luminanceScale))
        return payload
    }

    private static func contentLightPayload(of frame: UnsafePointer<AVFrame>) -> Data? {
        guard let side = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL),
              side.pointee.size >= MemoryLayout<AVContentLightMetadata>.size,
              let raw = side.pointee.data
        else { return nil }
        let metadata = UnsafeRawPointer(raw)
            .assumingMemoryBound(to: AVContentLightMetadata.self).pointee
        // 0/0 is how "present but unset" reaches us; it says nothing, so it is
        // not forwarded.
        guard metadata.MaxCLL != 0 || metadata.MaxFALL != 0 else { return nil }

        var payload = Data(capacity: 4)
        payload.appendBigEndian(UInt16(clamping: metadata.MaxCLL))
        payload.appendBigEndian(UInt16(clamping: metadata.MaxFALL))
        return payload
    }

    /// A denominator of zero is FFmpeg's "unset"; `av_q2d` would return NaN and
    /// `UInt16(clamping:)` cannot take one, so it is filtered here.
    private static func fixedPoint16(_ value: AVRational, scale: Double) -> UInt16 {
        guard value.den != 0 else { return 0 }
        let scaled = (av_q2d(value) * scale).rounded()
        guard scaled.isFinite else { return 0 }
        return UInt16(clamping: Int64(scaled.clamped(to: 0...Double(UInt16.max))))
    }

    private static func fixedPoint32(_ value: AVRational, scale: Double) -> UInt32 {
        guard value.den != 0 else { return 0 }
        let scaled = (av_q2d(value) * scale).rounded()
        guard scaled.isFinite else { return 0 }
        return UInt32(clamping: Int64(scaled.clamped(to: 0...Double(UInt32.max))))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

/// One decoded, resampled audio frame: interleaved Float32 at the source sample
/// rate, owned by the wrapped `AVFrame`. Immutable after construction.
public final class AudioFrame: @unchecked Sendable {
    /// Owned `AVFrame` holding interleaved FLT samples; freed in deinit.
    let raw: UnsafeMutablePointer<AVFrame>

    public let pts: Int64
    public let serial: UInt64
    public let sampleRate: Int
    public let channels: Int
    public let sampleCount: Int
    /// Channel mask in WAVE bit order (`AV_CH_*` bits); 0 when the layout is
    /// unknown or not expressible as a native mask.
    public let channelBitmap: UInt64

    /// Duration in engine µs derived from the sample count.
    public var duration: Int64 {
        guard sampleRate > 0 else { return 0 }
        return Int64(sampleCount) * MediaTime.timeBase / Int64(sampleRate)
    }

    /// Interleaved Float32 sample data.
    public var samples: UnsafeBufferPointer<Float> {
        let pointer = raw.pointee.data.0!.withMemoryRebound(
            to: Float.self, capacity: sampleCount * channels
        ) { $0 }
        return UnsafeBufferPointer(start: pointer, count: sampleCount * channels)
    }

    init(adopting raw: UnsafeMutablePointer<AVFrame>, pts: Int64, serial: UInt64) {
        self.raw = raw
        self.pts = pts
        self.serial = serial
        self.sampleRate = Int(raw.pointee.sample_rate)
        self.channels = Int(raw.pointee.ch_layout.nb_channels)
        self.sampleCount = Int(raw.pointee.nb_samples)
        self.channelBitmap = AudioFrame.nativeChannelBitmap(of: raw.pointee.ch_layout)
    }

    /// Falls back to FFmpeg's default layout for the channel count when the
    /// decoder reported no explicit layout (order unspec is routine for PCM).
    private static func nativeChannelBitmap(of layout: AVChannelLayout) -> UInt64 {
        if layout.order == AV_CHANNEL_ORDER_NATIVE, layout.u.mask != 0 {
            return layout.u.mask
        }
        var fallback = AVChannelLayout()
        av_channel_layout_default(&fallback, layout.nb_channels)
        return fallback.order == AV_CHANNEL_ORDER_NATIVE ? fallback.u.mask : 0
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVFrame>? = raw
        av_frame_free(&pointer)
    }

    /// Test support: a silent interleaved-FLT frame with the given geometry.
    static func silence(
        pts: Int64, serial: UInt64, sampleRate: Int32, channels: Int32, sampleCount: Int32
    ) -> AudioFrame? {
        guard let raw = av_frame_alloc() else { return nil }
        raw.pointee.sample_rate = sampleRate
        raw.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
        av_channel_layout_default(&raw.pointee.ch_layout, channels)
        raw.pointee.nb_samples = sampleCount
        guard av_frame_get_buffer(raw, 0) >= 0 else {
            var pointer: UnsafeMutablePointer<AVFrame>? = raw
            av_frame_free(&pointer)
            return nil
        }
        return AudioFrame(adopting: raw, pts: pts, serial: serial)
    }
}
