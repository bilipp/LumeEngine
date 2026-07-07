import CoreMedia

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
    static func audio(
        from frame: AudioFrame,
        formatCache: inout (description: CMAudioFormatDescription, sampleRate: Int, channels: Int)?
    ) throws -> CMSampleBuffer {
        if formatCache == nil || formatCache!.sampleRate != frame.sampleRate || formatCache!.channels != frame.channels {
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
            var description: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else {
                throw EngineError(code: .internalError, message: "CMAudioFormatDescription failed (\(status))")
            }
            formatCache = (description, frame.sampleRate, frame.channels)
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
            presentationTimeStamp: time(frame.pts),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw EngineError(code: .internalError, message: "audio CMSampleBuffer failed (\(status))")
        }
        return sampleBuffer
    }
}
