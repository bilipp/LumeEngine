internal import CFFmpeg

/// Owned copy of one stream's `AVCodecParameters`, snapshotted at open time so
/// decoders can be created and torn down independently of the demuxer's
/// lifetime (no shared pointers into `AVFormatContext` — PLAN.md §3.1).
public final class CodecParameters: @unchecked Sendable {
    let raw: UnsafeMutablePointer<AVCodecParameters>

    init?(copying source: UnsafePointer<AVCodecParameters>) {
        guard let allocated = avcodec_parameters_alloc() else { return nil }
        guard avcodec_parameters_copy(allocated, source) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = allocated
            avcodec_parameters_free(&pointer)
            return nil
        }
        raw = allocated
    }

    public var codecName: String {
        String(cString: avcodec_get_name(raw.pointee.codec_id))
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVCodecParameters>? = raw
        avcodec_parameters_free(&pointer)
    }
}
