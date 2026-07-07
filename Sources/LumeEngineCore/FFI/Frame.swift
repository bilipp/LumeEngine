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
    /// True when this frame came off the hardware (VideoToolbox) path.
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
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVFrame>? = raw
        av_frame_free(&pointer)
    }
}
