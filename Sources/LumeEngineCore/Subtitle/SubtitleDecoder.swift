internal import CFFmpeg
import Foundation

/// Text subtitle decode stage: `Channel<Packet>` in, `SubtitleStore` out.
/// Runs `avcodec_decode_subtitle2`, so every FFmpeg text subtitle codec
/// (subrip, ass, webvtt, mov_text, eia_608 CC) feeds one cue model.
/// Bitmap codecs (PGS/DVB/VobSub) are recognized but skipped for now.
public final class SubtitleDecoder: @unchecked Sendable {
    public let store: SubtitleStore

    private let parameters: CodecParameters
    private let input: Channel<Packet>

    private let lock = NSCondition()
    private var started = false
    private var finished = false
    private var stopRequested = false

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?

    public init(parameters: CodecParameters, input: Channel<Packet>, store: SubtitleStore = SubtitleStore()) {
        self.parameters = parameters
        self.input = input
        self.store = store
    }

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let thread = Thread { [self] in threadMain() }
        thread.name = "engine.lume.subtitle-decoder"
        thread.start()
    }

    @discardableResult
    public func shutdown(deadline: TimeInterval = 5.0) -> Bool {
        lock.lock()
        stopRequested = true
        let wasStarted = started
        lock.unlock()
        input.close()

        let limit = Date(timeIntervalSinceNow: deadline)
        lock.lock()
        defer { lock.unlock() }
        if !wasStarted {
            finished = true
            return true
        }
        while !finished {
            if !lock.wait(until: limit) { return false }
        }
        return true
    }

    private func threadMain() {
        FFmpegRuntime.initialize()

        guard setupCodec() else {
            finishThread()
            return
        }

        while true {
            lock.lock()
            let stop = stopRequested
            lock.unlock()
            if stop { break }

            guard let packet = input.receive(timeout: 0.1) else {
                if input.closed { break }
                continue
            }
            decode(packet: packet)
        }

        finishThread()
    }

    private func decode(packet: Packet) {
        guard let context = codecContext else { return }

        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        let result = avcodec_decode_subtitle2(context, &subtitle, &gotSubtitle, packet.raw)
        guard result >= 0, gotSubtitle != 0 else { return }
        defer { avsubtitle_free(&subtitle) }

        // Packet timestamps are engine µs; display offsets are milliseconds.
        let basePTS = MediaTime.isValid(packet.pts) ? packet.pts : 0
        let start = basePTS + Int64(subtitle.start_display_time) * 1_000
        var end = basePTS + Int64(subtitle.end_display_time) * 1_000
        if subtitle.end_display_time == 0 || end <= start {
            end = packet.duration > 0 ? basePTS + packet.duration : start + 3_000_000
        }

        var lines: [String] = []
        for i in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[i] else { continue }
            switch rect.pointee.type {
            case SUBTITLE_ASS:
                if let ass = rect.pointee.ass {
                    lines.append(SubtitleTextParser.text(fromASSEvent: String(cString: ass)))
                }
            case SUBTITLE_TEXT:
                if let text = rect.pointee.text {
                    lines.append(String(cString: text))
                }
            default:
                break // bitmap subtitle — deferred (libass/PGS pack)
            }
        }
        let text = lines.joined(separator: "\n")
        store.insert(start: start, end: end, text: text)
    }

    private func setupCodec() -> Bool {
        guard let codec = avcodec_find_decoder(parameters.raw.pointee.codec_id),
              let context = avcodec_alloc_context3(codec)
        else { return false }
        guard avcodec_parameters_to_context(context, parameters.raw) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return false
        }
        context.pointee.pkt_timebase = lume_av_time_base_q()
        guard avcodec_open2(context, codec, nil) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return false
        }
        codecContext = context
        return true
    }

    private func finishThread() {
        avcodec_free_context(&codecContext)
        lock.lock()
        finished = true
        lock.unlock()
        lock.broadcast()
    }
}
