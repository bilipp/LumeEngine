import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import LumeEngineCore

@Suite("Decoders", .serialized)
struct DecoderTests {
    /// What a video drain keeps per frame — the frame itself holds a pixel
    /// buffer the test has no reason to retain for the length of a stream.
    private struct DecodedVideoFrame: Sendable {
        let pts: Int64
        let width: Int
        let height: Int
        let format: OSType
        let hardware: Bool
    }

    /// What an audio drain keeps: everything the assertions need, folded as
    /// frames arrive.
    private struct DecodedAudio: Sendable {
        var totalSamples = 0
        var ptsValues: [Int64] = []
        var channels: Set<Int> = []
        var rates: Set<Int> = []
        var peak: Float = 0
    }

    /// Opens a fixture and returns (demuxer, info) ready for track attachment.
    private func open(_ fixture: String) async throws -> (Demuxer, MediaInfo, AsyncStream<DemuxEvent>.Iterator) {
        let demuxer = Demuxer(url: try Fixtures.path(fixture))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            demuxer.shutdown()
            throw EngineError(code: .openFailed, message: "fixture \(fixture) failed to open")
        }
        return (demuxer, info, events)
    }

    @Test("video: full decode of H.264 produces monotonic CVPixelBuffers", .timeLimit(.minutes(1)))
    func videoDecode() async throws {
        var (demuxer, info, demuxEvents) = try await open("basic.mp4")
        defer { demuxer.shutdown() }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames)
        var decodeEvents = decoder.events.makeAsyncIterator()
        decoder.start()
        demuxer.resume()

        // Consume frames on a dedicated thread while awaiting decoder EOF —
        // never on the concurrency pool, which this body's `await`s need (see
        // `ChannelDrain`).
        let collector = ChannelDrain(frames, into: [DecodedVideoFrame]()) { collected, frame in
            collected.append(DecodedVideoFrame(
                pts: frame.pts,
                width: frame.width,
                height: frame.height,
                format: CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
                hardware: frame.isHardwareDecoded
            ))
        }

        // Demux hits EOF → tell the decoder to drain.
        while let event = await demuxEvents.next() {
            if case .endOfStream = event {
                decoder.signalEndOfStream()
                break
            }
        }
        guard case .endOfStream? = await decodeEvents.next() else {
            Issue.record("expected decoder .endOfStream")
            decoder.shutdown()
            return
        }
        decoder.shutdown() // closes the frame channel; collector drains and ends

        let collected = await collector.value
        #expect(collected.count >= 295, "10 s @ 30 fps ≈ 300 frames, got \(collected.count)")
        #expect(collected.allSatisfy { $0.width == 640 && $0.height == 360 })

        let ptsValues = collected.map(\.pts)
        #expect(zip(ptsValues, ptsValues.dropFirst()).allSatisfy { $0 < $1 }, "output PTS must be monotonic")

        // All frames must come from ONE path — no silent per-frame flapping.
        let hardwareFlags = Set(collected.map(\.hardware))
        #expect(hardwareFlags.count == 1, "decode path must be consistent for the whole stream")

        // NV12-family output on either path (VT gives 420v/420f; factory gives NV12).
        let formats = Set(collected.map(\.format))
        let allowed: Set<OSType> = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        #expect(formats.isSubset(of: allowed), "unexpected pixel formats: \(formats)")
    }

    @Test("video: software-only policy decodes identically", .timeLimit(.minutes(1)))
    func videoSoftwareDecode() async throws {
        let (demuxer, info, _) = try await open("basic.mp4")
        defer { demuxer.shutdown() }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16)
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames, policy: .software)
        decoder.start()
        demuxer.resume()

        var count = 0
        var sawHardwareFrame = false
        while let frame = frames.receive(timeout: 5) {
            count += 1
            sawHardwareFrame = sawHardwareFrame || frame.isHardwareDecoded
            if count == 60 { break }
        }
        #expect(count == 60)
        #expect(!sawHardwareFrame, "software policy must never touch VideoToolbox")
        #expect(!decoder.isHardwareActive)

        decoder.shutdown()
    }

    @Test("audio: AAC decodes to interleaved Float32 covering the full duration", .timeLimit(.minutes(1)))
    func audioDecode() async throws {
        var (demuxer, info, demuxEvents) = try await open("basic.mp4")
        defer { demuxer.shutdown() }

        let track = try #require(info.audioTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 128)
        let frames = Channel<AudioFrame>(capacity: 64, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = AudioDecoder(parameters: parameters, input: packets, output: frames)
        var decodeEvents = decoder.events.makeAsyncIterator()
        decoder.start()
        demuxer.resume()

        let collector = ChannelDrain(frames, into: DecodedAudio()) { collected, frame in
            collected.totalSamples += frame.sampleCount
            collected.ptsValues.append(frame.pts)
            collected.channels.insert(frame.channels)
            collected.rates.insert(frame.sampleRate)
            for sample in frame.samples { collected.peak = max(collected.peak, abs(sample)) }
        }

        while let event = await demuxEvents.next() {
            if case .endOfStream = event {
                decoder.signalEndOfStream()
                break
            }
        }
        guard case .endOfStream? = await decodeEvents.next() else {
            Issue.record("expected decoder .endOfStream")
            decoder.shutdown()
            return
        }
        decoder.shutdown()

        let collected = await collector.value
        let rate = try #require(collected.rates.first)
        #expect(collected.rates.count == 1)
        #expect(collected.channels == [1], "sine fixture is mono")
        let seconds = Double(collected.totalSamples) / Double(rate)
        #expect(abs(seconds - 10.0) < 0.3, "expected ~10 s of audio, got \(seconds)")
        let ptsValues = collected.ptsValues
        #expect(zip(ptsValues, ptsValues.dropFirst()).allSatisfy { $0 < $1 }, "audio PTS must be monotonic")
        #expect(collected.peak > 0.1, "a sine wave must have non-silent samples (peak \(collected.peak))")
    }

    @Test("audio: 7.1 channel layout survives into the CMSampleBuffer", .timeLimit(.minutes(1)))
    func audioMultichannelLayout() async throws {
        var (demuxer, info, demuxEvents) = try await open("surround71.mkv")
        defer { demuxer.shutdown() }

        let track = try #require(info.audioTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 128)
        let frames = Channel<AudioFrame>(capacity: 64, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = AudioDecoder(
            parameters: parameters, input: packets, output: frames,
            maxOutputChannels: 8 // multichannel-capable route
        )
        decoder.start()
        demuxer.resume()

        let frame = try #require(frames.receive(timeout: 5))
        defer { decoder.shutdown() }
        _ = demuxEvents

        #expect(frame.channels == 8)
        // FL FR FC LFE BL BR SL SR — FFmpeg's native 7.1 mask.
        #expect(frame.channelBitmap == 0x63F)
        #expect(frame.samples.count == frame.sampleCount * 8)

        var cache: (description: CMAudioFormatDescription, sampleRate: Int, channels: Int, channelBitmap: UInt64)?
        var timeline = AudioTimeline()
        let sample = try SampleBufferBuilder.audio(
            from: frame,
            presentationTime: timeline.presentationTime(for: frame),
            formatCache: &cache
        )
        let description = try #require(CMSampleBufferGetFormatDescription(sample))

        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mChannelsPerFrame == 8)

        var layoutSize = 0
        let layout = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize))
        #expect(layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap)
        #expect(layout.pointee.mChannelBitmap.rawValue == 0x63F)
    }

    @Test("seek mid-decode: only new-serial frames after flush", .timeLimit(.minutes(1)))
    func serialFlush() async throws {
        let (demuxer, info, _) = try await open("basic.mp4")
        defer { demuxer.shutdown() }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 256)
        let frames = Channel<VideoFrame>(capacity: 256)
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames)
        decoder.start()
        demuxer.resume()

        // Take a few serial-0 frames, then seek.
        var initialFrames = 0
        while initialFrames < 10, let frame = frames.receive(timeout: 5) {
            #expect(frame.serial == 0)
            initialFrames += 1
        }
        #expect(initialFrames == 10)

        // Session-style seek: flush downstream, then reposition the demuxer.
        packets.flush()
        frames.flush()
        demuxer.seek(to: info.startTime + MediaTime.microseconds(7.0))

        // Frames still in flight may carry serial 0; once serial 1 appears,
        // nothing may ever regress to serial 0.
        var sawNewSerial = false
        var post: [VideoFrame] = []
        while post.count < 30, let frame = frames.receive(timeout: 5) {
            if frame.serial == 1 { sawNewSerial = true }
            if sawNewSerial {
                #expect(frame.serial == 1, "no stale-serial frame may follow a new-serial frame")
                post.append(frame)
            }
        }
        #expect(sawNewSerial, "expected serial-1 frames after seek")
        if let first = post.first {
            let position = MediaTime.seconds(first.pts - info.startTime)
            #expect(position >= 5.5 && position <= 7.1, "first post-seek frame should be near 7 s (keyframe-backward), got \(position)")
        }

        decoder.shutdown()
    }
}
