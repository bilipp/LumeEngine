internal import CFFmpeg
import CoreVideo

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

    init(
        pixelBuffer: CVPixelBuffer,
        pts: Int64,
        duration: Int64,
        serial: UInt64,
        isHardwareDecoded: Bool
    ) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
        self.serial = serial
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
        self.isHardwareDecoded = isHardwareDecoded
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
