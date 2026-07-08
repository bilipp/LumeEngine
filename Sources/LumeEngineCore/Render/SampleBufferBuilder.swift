internal import CFFmpeg
import CoreMedia

/// Regenerates sample-contiguous presentation times for audio buffers.
///
/// Container audio PTS carry container-timebase quantization (MKV stores
/// milliseconds: up to ±0.5 ms per packet). The audio renderer aligns each
/// buffer to its timestamp, so stamping buffers with quantized PTS makes it
/// splice — drop or insert samples — at every buffer boundary, which is
/// audible as continuous crackling. Like mpv's ao_avfoundation, anchor once
/// and advance by exact sample counts; fall back to the container PTS only on
/// genuine discontinuities (seek flush, stream gap, format change).
struct AudioTimeline {
    /// Anything below this is timestamp quantization/jitter to be absorbed;
    /// anything above is a real gap the synchronizer must see.
    private static let discontinuityToleranceUs: Int64 = 40_000

    private var anchorSampleValue: Int64 = 0
    private var samplesSinceAnchor: Int64 = 0
    private var sampleRate = 0
    private var serial: UInt64 = 0
    private var hasAnchor = false

    mutating func reset() {
        hasAnchor = false
    }

    /// Sample-accurate presentation time for `frame` (timescale = sample rate,
    /// so buffer boundaries land exactly on the sample grid).
    mutating func presentationTime(for frame: AudioFrame) -> CMTime {
        if hasAnchor, frame.sampleRate == sampleRate, frame.serial == serial {
            let expectedValue = anchorSampleValue + samplesSinceAnchor
            let expectedUs = av_rescale(expectedValue, 1_000_000, Int64(sampleRate))
            if !MediaTime.isValid(frame.pts) || abs(frame.pts - expectedUs) <= Self.discontinuityToleranceUs {
                samplesSinceAnchor += Int64(frame.sampleCount)
                return CMTime(value: expectedValue, timescale: CMTimeScale(sampleRate))
            }
        }
        sampleRate = frame.sampleRate
        serial = frame.serial
        let pts = MediaTime.isValid(frame.pts) ? frame.pts : 0
        anchorSampleValue = av_rescale(pts, Int64(sampleRate), 1_000_000)
        samplesSinceAnchor = Int64(frame.sampleCount)
        hasAnchor = true
        return CMTime(value: anchorSampleValue, timescale: CMTimeScale(sampleRate))
    }
}

/// Builds `CMSampleBuffer`s from decoded engine frames. All timestamps use the
/// engine timescale (microseconds), so the render synchronizer's timeline is
/// exactly the demux-normalized timeline.
enum SampleBufferBuilder {
    static let timescale: CMTimeScale = 1_000_000

    static func time(_ us: Int64) -> CMTime {
        CMTime(value: us, timescale: timescale)
    }

    /// Wraps a decoded video frame. `formatCache` avoids re-creating the format
    /// description for every frame of the same stream configuration.
    static func video(
        from frame: VideoFrame,
        formatCache: inout CMVideoFormatDescription?
    ) throws -> CMSampleBuffer {
        if formatCache == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatCache!, imageBuffer: frame.pixelBuffer) {
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else {
                throw EngineError(code: .internalError, message: "CMVideoFormatDescription failed (\(status))")
            }
            formatCache = description
        }

        var timing = CMSampleTimingInfo(
            duration: frame.duration > 0 ? time(frame.duration) : .invalid,
            presentationTimeStamp: time(frame.pts),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatCache!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw EngineError(code: .internalError, message: "video CMSampleBuffer failed (\(status))")
        }
        return sampleBuffer
    }

    /// Wraps a decoded audio frame (interleaved Float32) by copying its samples
    /// into a block buffer.
    /// `AudioChannelBitmap` bit positions match the `AV_CH_*` mask (both follow
    /// WAVE order) for bits 0...17, which covers every standard layout up to 7.1.
    private static let waveCompatibleChannelBits: UInt64 = 0x3FFFF

    static func audio(
        from frame: AudioFrame,
        presentationTime: CMTime,
        formatCache: inout (description: CMAudioFormatDescription, sampleRate: Int, channels: Int, channelBitmap: UInt64)?
    ) throws -> CMSampleBuffer {
        if formatCache == nil
            || formatCache!.sampleRate != frame.sampleRate
            || formatCache!.channels != frame.channels
            || formatCache!.channelBitmap != frame.channelBitmap {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(frame.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * frame.channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * frame.channels),
                mChannelsPerFrame: UInt32(frame.channels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            // The audio renderer needs the channel layout to map and downmix
            // anything beyond stereo; without it multichannel renders as noise.
            let useBitmap = frame.channelBitmap != 0
                && frame.channelBitmap & ~waveCompatibleChannelBits == 0
                && frame.channelBitmap.nonzeroBitCount == frame.channels
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
            layout.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(truncatingIfNeeded: frame.channelBitmap))
            var description: CMAudioFormatDescription?
            let status = withUnsafePointer(to: layout) { layoutPointer in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: useBitmap ? MemoryLayout<AudioChannelLayout>.size : 0,
                    layout: useBitmap ? layoutPointer : nil,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
            guard status == noErr, let description else {
                throw EngineError(code: .internalError, message: "CMAudioFormatDescription failed (\(status))")
            }
            formatCache = (description, frame.sampleRate, frame.channels, frame.channelBitmap)
        }

        let byteCount = frame.sampleCount * frame.channels * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw EngineError(code: .internalError, message: "CMBlockBuffer failed (\(status))")
        }
        status = frame.samples.withMemoryRebound(to: UInt8.self) { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == noErr else {
            throw EngineError(code: .internalError, message: "CMBlockBuffer copy failed (\(status))")
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatCache!.description,
            sampleCount: frame.sampleCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw EngineError(code: .internalError, message: "audio CMSampleBuffer failed (\(status))")
        }
        return sampleBuffer
    }
}
