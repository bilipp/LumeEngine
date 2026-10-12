import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import LumeEngineCore
import CFFmpeg

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

    /// AV1 is the codec where "try hardware, fall back to software" used to
    /// have nothing to fall back to: FFmpeg's native AV1 decoder only drives
    /// VideoToolbox, most Apple chips have no AV1 hardware, and the stream
    /// played as a black picture with sound. dav1d is the software path.
    @Test("video: AV1 decodes with or without AV1 hardware", .timeLimit(.minutes(1)))
    func av1Decode() async throws {
        var (demuxer, info, demuxEvents) = try await open("av1.mkv")
        defer { demuxer.shutdown() }

        let track = try #require(info.videoTracks.first)
        #expect(track.codecName == "av1")
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames)
        var decodeEvents = decoder.events.makeAsyncIterator()
        decoder.start()
        demuxer.resume()

        let collector = ChannelDrain(frames, into: [DecodedVideoFrame]()) { collected, frame in
            collected.append(DecodedVideoFrame(
                pts: frame.pts,
                width: frame.width,
                height: frame.height,
                format: CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
                hardware: frame.isHardwareDecoded
            ))
        }

        while let event = await demuxEvents.next() {
            if case .endOfStream = event {
                decoder.signalEndOfStream()
                break
            }
        }
        var failure: EngineError?
        var reachedEndOfStream = false
        var downgraded = false
        while let event = await decodeEvents.next() {
            if case .failed(let error) = event { failure = error; break }
            if case .downgradedToSoftware = event { downgraded = true }
            if case .endOfStream = event { reachedEndOfStream = true; break }
        }
        let hardwareActive = decoder.isHardwareActive
        decoder.shutdown()

        #expect(failure == nil, "AV1 must decode on this host: \(failure.map(String.init(describing:)) ?? "")")
        #expect(reachedEndOfStream)
        let collected = await collector.value
        #expect(collected.allSatisfy { $0.width == 320 && $0.height == 180 })
        let ptsValues = collected.map(\.pts)
        #expect(zip(ptsValues, ptsValues.dropFirst()).allSatisfy { $0 < $1 }, "output PTS must be monotonic")

        let chipDecodesAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        if !chipDecodesAV1 {
            // The case that played black: no AV1 hardware (Apple TV 4K, M1,
            // …). dav1d from the first frame — no failed hardware attempt,
            // nothing lost.
            #expect(!downgraded, "without AV1 hardware the hardware path must not even be tried")
            #expect(!hardwareActive)
            #expect(collected.allSatisfy { !$0.hardware })
            #expect(collected.count >= 90, "4 s @ 24 fps ≈ 96 frames, got \(collected.count)")
        } else if downgraded {
            // VideoToolbox claimed AV1 but failed — CI's virtualized macOS
            // does exactly that. The engine's ordinary recovery: rebuild on
            // dav1d, report it, resume at the next keyframe (one GOP, 24
            // frames, of the fixture).
            #expect(!hardwareActive)
            let afterOneLostGOP: Int = 66 // 96 frames − one 24-frame GOP − slack
            #expect(collected.count >= afterOneLostGOP, "at most one GOP lost to the recovery, got \(collected.count)")
        } else {
            #expect(hardwareActive)
            #expect(collected.allSatisfy { $0.hardware })
            #expect(collected.count >= 90, "4 s @ 24 fps ≈ 96 frames, got \(collected.count)")
        }
        // 10-bit stays 10-bit on either path.
        #expect(Set(collected.map(\.format)).isSubset(of: [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        ]))
    }

    @Test("video: corrupt packets do not cost the hardware decoder", .timeLimit(.minutes(1)))
    func corruptPacketsStayInHardware() async throws {
        // An IPTV feed with an occasional corrupt packet: hardware decoding
        // must resync at the next keyframe, not hand the stream to software.
        guard VideoDecoder.decoder(for: AV_CODEC_ID_H264, hardware: true) != nil else { return }
        let (demuxer, info, _) = try await open("basic.mp4")
        defer { demuxer.shutdown() }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let demuxed = Channel<Packet>(capacity: 64)
        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16)
        demuxer.attach(channel: demuxed, toStream: track.index)

        // Garble the slice header of every 90th packet on its way to the
        // decoder (one every 3 s, each in its own GOP), on a thread of its
        // own like any data-plane stage. Much more often than that and the
        // decoder rightly gives hardware up: software conceals corruption,
        // where every hardware resync freezes the picture until a keyframe.
        let corrupted = LockedBox<Int>(0)
        let forwarder = Thread {
            var index = 0
            while let packet = demuxed.receive(timeout: 5) {
                index += 1
                if index % 90 == 0, !packet.isKeyframe,
                   let data = packet.raw.pointee.data, packet.raw.pointee.size > 16 {
                    for offset in 4..<16 { data[offset] = 0xFF }
                    corrupted.set(corrupted.get() + 1)
                }
                guard (try? packets.send(packet)) != nil else { break }
            }
            packets.close()
        }
        forwarder.start()

        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames)
        let downgraded = LockedBox<Bool>(false)
        let downgradeReasons = LockedBox<[String]>([])
        let eventTask = Task {
            for await event in decoder.events {
                if case .downgradedToSoftware(let error) = event {
                    downgraded.set(true)
                    downgradeReasons.set(downgradeReasons.get() + [error.message])
                }
            }
        }
        defer { eventTask.cancel() }
        decoder.start()
        demuxer.resume()

        // `receive` blocks: read on a thread of its own, never on the test's
        // cooperative thread (see `ChannelDrain`).
        let (count, softwareFrames) = await DedicatedThread.run(named: "test.frame-reader") {
            var count = 0
            var softwareFrames = 0
            while let frame = frames.receive(timeout: 5) {
                count += 1
                if !frame.isHardwareDecoded { softwareFrames += 1 }
            }
            return (count, softwareFrames)
        }
        #expect(corrupted.get() >= 2, "the test must actually corrupt packets")
        #expect(count > 200, "decoding must continue past the corrupt packets, got \(count) frames")
        #expect(!downgraded.get(), "isolated corrupt packets must not downgrade to software: \(downgradeReasons.get())")
        #expect(softwareFrames == 0)
        decoder.shutdown()
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

        let (count, sawHardwareFrame) = await DedicatedThread.run(named: "test.frame-reader") {
            var count = 0
            var sawHardwareFrame = false
            while let frame = frames.receive(timeout: 5) {
                count += 1
                sawHardwareFrame = sawHardwareFrame || frame.isHardwareDecoded
                if count == 60 { break }
            }
            return (count, sawHardwareFrame)
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

        let frame = try #require(await DedicatedThread.run(named: "test.frame-reader") { frames.receive(timeout: 5) })
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

        // Take a few serial-0 frames, then seek. Reading happens on a thread
        // of its own (`receive` blocks); the assertions stay in the test.
        let initialSerials = await DedicatedThread.run(named: "test.frame-reader") {
            var serials: [UInt64] = []
            while serials.count < 10, let frame = frames.receive(timeout: 5) {
                serials.append(frame.serial)
            }
            return serials
        }
        #expect(initialSerials.count == 10)
        #expect(initialSerials.allSatisfy { $0 == 0 })

        // Session-style seek: flush downstream, then reposition the demuxer.
        packets.flush()
        frames.flush()
        demuxer.seek(to: info.startTime + MediaTime.microseconds(7.0))

        // Frames still in flight may carry serial 0; once serial 1 appears,
        // nothing may ever regress to serial 0.
        let (sawNewSerial, post) = await DedicatedThread.run(named: "test.frame-reader") {
            var sawNewSerial = false
            var post: [VideoFrame] = []
            while post.count < 30, let frame = frames.receive(timeout: 5) {
                if frame.serial == 1 { sawNewSerial = true }
                if sawNewSerial { post.append(frame) }
            }
            return (sawNewSerial, post)
        }
        #expect(post.allSatisfy { $0.serial == 1 }, "no stale-serial frame may follow a new-serial frame")
        #expect(sawNewSerial, "expected serial-1 frames after seek")
        if let first = post.first {
            let position = MediaTime.seconds(first.pts - info.startTime)
            #expect(position >= 5.5 && position <= 7.1, "first post-seek frame should be near 7 s (keyframe-backward), got \(position)")
        }

        decoder.shutdown()
    }
}
