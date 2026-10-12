internal import CFFmpeg
import CoreVideo

/// Colour and geometry tags for pixel buffers the engine fills itself:
/// software-decoded frames and deinterlacer output.
///
/// VideoToolbox tags its own surfaces from the bitstream. A buffer from the
/// engine's pool carries nothing unless it is tagged here, and the display
/// layer then guesses: SD broadcast (BT.601) shifts colour, HDR10 or HLG
/// decoded in software renders as SDR, and an anamorphic 720x576 channel
/// (pixel aspect 64:45, a 16:9 picture) shows as 5:4. The deinterlacer puts
/// every frame of an interlaced channel, hardware-decoded or not, through
/// such a buffer, so most European SD and 1080i IPTV takes this path.
///
/// Every key is written or removed on every frame, because pool buffers are
/// recycled and would otherwise keep the previous frame's tags.
enum PixelBufferAttachments {
    static func apply(from frame: UnsafePointer<AVFrame>, to buffer: CVPixelBuffer) {
        let height = Int(frame.pointee.height)

        let matrix = av_map_videotoolbox_color_matrix_from_av(frame.pointee.colorspace)?.takeUnretainedValue()
            ?? defaultMatrix(height: height)
        let primaries = av_map_videotoolbox_color_primaries_from_av(frame.pointee.color_primaries)?.takeUnretainedValue()
            ?? defaultPrimaries(height: height, matrix: matrix)
        let transfer = av_map_videotoolbox_color_trc_from_av(frame.pointee.color_trc)?.takeUnretainedValue()
            ?? kCVImageBufferTransferFunction_ITU_R_709_2
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)

        if let chroma = av_map_videotoolbox_chroma_loc_from_av(frame.pointee.chroma_location)?.takeUnretainedValue() {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, chroma, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, chroma, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey)
            CVBufferRemoveAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey)
        }

        if let aspect = pixelAspectRatio(of: frame) {
            let value: [CFString: Int32] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: aspect.num,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: aspect.den,
            ]
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, value as CFDictionary, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferPixelAspectRatioKey)
        }
    }

    /// The frame's pixel aspect ratio when it is known, not square, and
    /// plausible. A ratio that would stretch the picture past 4:1 either way
    /// is a broken stream header, not a picture shape; square pixels are what
    /// an untagged buffer means already.
    static func pixelAspectRatio(of frame: UnsafePointer<AVFrame>) -> (num: Int32, den: Int32)? {
        let ratio = frame.pointee.sample_aspect_ratio
        guard ratio.num > 0, ratio.den > 0, ratio.num != ratio.den else { return nil }
        let width = Double(frame.pointee.width)
        let height = Double(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }
        let displayAspect = width * Double(ratio.num) / (height * Double(ratio.den))
        guard (0.25...4).contains(displayAspect) else { return nil }
        var num: Int32 = 0
        var den: Int32 = 0
        av_reduce(&num, &den, Int64(ratio.num), Int64(ratio.den), Int64(Int32.max))
        return (num, den)
    }

    /// What an untagged stream most likely is: SD is BT.601, everything
    /// larger BT.709 — the same assumption VideoToolbox makes for its own
    /// untagged output.
    private static func defaultMatrix(height: Int) -> CFString {
        height <= 576 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }

    private static func defaultPrimaries(height: Int, matrix: CFString) -> CFString {
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 { return kCVImageBufferColorPrimaries_ITU_R_2020 }
        // 576-line SD is PAL/SECAM (EBU 3213), 480-line SD is NTSC (SMPTE C).
        if height <= 480 { return kCVImageBufferColorPrimaries_SMPTE_C }
        if height <= 576 { return kCVImageBufferColorPrimaries_EBU_3213 }
        return kCVImageBufferColorPrimaries_ITU_R_709_2
    }
}
