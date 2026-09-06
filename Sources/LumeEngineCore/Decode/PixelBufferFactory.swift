internal import CFFmpeg
import CoreVideo
import Foundation

/// Converts software-decoded `AVFrame`s into pooled `CVPixelBuffer`s (NV12 for
/// 8-bit, P010 for higher bit depths) via swscale. The hardware path never
/// touches this — VideoToolbox frames are already `CVPixelBuffer`s (zero-copy,
/// PLAN.md §7 "no sws_scale on the hot path" applies to HW-decodable content;
/// this factory exists for the exotic-format software fallback).
final class PixelBufferFactory {
    /// Whether the buffers this factory hands back carry the source's colour
    /// signalling (`PlayerConfiguration.preservesHDRMetadata`). Off restores
    /// the pre-#207 behaviour — bare buffers, whatever the source declared —
    /// which is the escape hatch for a display that mishandles a correct tag.
    private let attachesColorMetadata: Bool

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat: OSType = 0
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var swsSourceFormat = AV_PIX_FMT_NONE
    private var swsTargetFormat = AV_PIX_FMT_NONE

    init(attachesColorMetadata: Bool = true) {
        self.attachesColorMetadata = attachesColorMetadata
    }

    deinit {
        sws_freeContext(swsContext)
    }

    /// Converts one software `AVFrame` to a pooled `CVPixelBuffer`, tagged with
    /// the colorimetry the caller read off that same frame.
    func makePixelBuffer(
        from frame: UnsafeMutablePointer<AVFrame>,
        colorimetry: VideoColorimetry
    ) throws -> CVPixelBuffer {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let sourceFormat = AVPixelFormat(rawValue: frame.pointee.format)

        let bitDepth = av_pix_fmt_desc_get(sourceFormat).map { Int($0.pointee.comp.0.depth) } ?? 8
        let wide = bitDepth > 8
        let targetFFmpeg = wide ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
        let fullRange = colorimetry.isFullRange
        let targetCV: OSType = wide
            ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let buffer = try dequeueBuffer(width: width, height: height, format: targetCV)
        try convert(frame: frame, from: sourceFormat, to: targetFFmpeg, into: buffer, width: width, height: height)
        apply(colorimetry, to: buffer)
        return buffer
    }

    /// Tags the buffer so `CMVideoFormatDescriptionCreateForImageBuffer` builds
    /// a correctly described format — which is the whole fix: without these the
    /// sample buffer reaches the display carrying no colour information and
    /// HDR renders washed out.
    ///
    /// Every managed key is either **set or removed**, never left alone. Pool
    /// buffers are recycled, and a recycled buffer keeps the attachments its
    /// previous life set: skipping the removal would let a stale BT.2020/PQ tag
    /// ride out on an SDR frame after a mid-stream format change, which is the
    /// same wrong-tag failure this code exists to avoid, only harder to see.
    ///
    /// `.shouldPropagate` is the required mode: it is exactly the set that
    /// travels into the `CMSampleBuffer` the renderer enqueues.
    private func apply(_ colorimetry: VideoColorimetry, to buffer: CVPixelBuffer) {
        func set(_ key: CFString, _ value: CFTypeRef?) {
            if let value {
                CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(buffer, key)
            }
        }
        guard attachesColorMetadata else {
            set(kCVImageBufferColorPrimariesKey, nil)
            set(kCVImageBufferTransferFunctionKey, nil)
            set(kCVImageBufferYCbCrMatrixKey, nil)
            set(kCVImageBufferMasteringDisplayColorVolumeKey, nil)
            set(kCVImageBufferContentLightLevelInfoKey, nil)
            return
        }
        set(kCVImageBufferColorPrimariesKey, CoreVideoColor.primaries(colorimetry.primaries))
        set(kCVImageBufferTransferFunctionKey, CoreVideoColor.transferFunction(colorimetry.transfer))
        set(kCVImageBufferYCbCrMatrixKey, CoreVideoColor.yCbCrMatrix(colorimetry.matrix))
        set(
            kCVImageBufferMasteringDisplayColorVolumeKey,
            colorimetry.masteringDisplayColorVolume.map { $0 as CFData }
        )
        set(
            kCVImageBufferContentLightLevelInfoKey,
            colorimetry.contentLightLevel.map { $0 as CFData }
        )
    }

    private func dequeueBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        if pool == nil || poolWidth != width || poolHeight != height || poolFormat != format {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var newPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            guard status == kCVReturnSuccess, let newPool else {
                throw EngineError(code: .decodeFailed, message: "CVPixelBufferPoolCreate failed (\(status))")
            }
            pool = newPool
            poolWidth = width
            poolHeight = height
            poolFormat = format
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw EngineError(code: .decodeFailed, message: "pixel buffer allocation failed (\(status))")
        }
        return buffer
    }

    private func convert(
        frame: UnsafeMutablePointer<AVFrame>,
        from sourceFormat: AVPixelFormat,
        to targetFormat: AVPixelFormat,
        into buffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws {
        if swsContext == nil || swsSourceFormat != sourceFormat || swsTargetFormat != targetFormat {
            sws_freeContext(swsContext)
            swsContext = sws_getContext(
                Int32(width), Int32(height), sourceFormat,
                Int32(width), Int32(height), targetFormat,
                Int32(SWS_BILINEAR.rawValue), nil, nil, nil
            )
            swsSourceFormat = sourceFormat
            swsTargetFormat = targetFormat
        }
        guard let swsContext else {
            throw EngineError(
                code: .unsupported,
                message: "swscale cannot convert \(av_get_pix_fmt_name(sourceFormat).map { String(cString: $0) } ?? "?")"
            )
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        var destinationPlanes: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self),
            nil, nil,
        ]
        var destinationStrides: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)),
            0, 0,
        ]

        let sourcePlanes: [UnsafePointer<UInt8>?] = [
            frame.pointee.data.0.map { UnsafePointer($0) },
            frame.pointee.data.1.map { UnsafePointer($0) },
            frame.pointee.data.2.map { UnsafePointer($0) },
            frame.pointee.data.3.map { UnsafePointer($0) },
        ]
        let sourceStrides: [Int32] = [
            frame.pointee.linesize.0, frame.pointee.linesize.1,
            frame.pointee.linesize.2, frame.pointee.linesize.3,
        ]

        let scaled = sws_scale(
            swsContext, sourcePlanes, sourceStrides, 0, Int32(height),
            &destinationPlanes, &destinationStrides
        )
        guard scaled == Int32(height) else {
            throw EngineError(code: .decodeFailed, message: "sws_scale produced \(scaled)/\(height) rows")
        }
    }
}

/// The `AVCOL_*` → CoreVideo attachment table, and the one rule that governs
/// it: **a code point with no exact CoreVideo counterpart maps to `nil`, and
/// `nil` means no attachment at all.**
///
/// `AVCOL_*_UNSPECIFIED` is the case that makes this rule load-bearing rather
/// than pedantic. SD and IPTV streams emit it constantly — `basic.mp4` in the
/// fixtures declares nothing at all — and the tempting "well, unspecified
/// probably means BT.709" would stamp a guess onto every such channel. A buffer
/// carrying no tag is rendered with the display's own default handling, which
/// is what those streams get today and look correct with; a buffer carrying a
/// *wrong* tag is colour-shifted, and the user has no way to turn it off.
///
/// Inputs are raw `UInt32` rather than the FFmpeg enums so the table can be
/// exercised across its whole domain from tests, which do not see `CFFmpeg`.
enum CoreVideoColor {
    static func primaries(_ raw: UInt32) -> CFString? {
        switch raw {
        case AVCOL_PRI_BT709.rawValue: kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT470BG.rawValue: kCVImageBufferColorPrimaries_EBU_3213
        // 170M and 240M share the SMPTE RP 145 ("SMPTE C") primaries; this is
        // an identity, not an approximation.
        case AVCOL_PRI_SMPTE170M.rawValue: kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_SMPTE240M.rawValue: kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT2020.rawValue: kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE431.rawValue: kCVImageBufferColorPrimaries_DCI_P3
        case AVCOL_PRI_SMPTE432.rawValue: kCVImageBufferColorPrimaries_P3_D65
        // Unspecified (2), reserved (0, 3), BT.470M (4), FILM (8),
        // SMPTE 428 (10), JEDEC P22 (22): no counterpart, so no attachment.
        default: nil
        }
    }

    static func transferFunction(_ raw: UInt32) -> CFString? {
        switch raw {
        case AVCOL_TRC_BT709.rawValue: kCVImageBufferTransferFunction_ITU_R_709_2
        // The 170M and BT.1361 curves *are* the 709 curve; CoreVideo has no
        // separate constant because there is no separate function.
        case AVCOL_TRC_SMPTE170M.rawValue: kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_BT1361_ECG.rawValue: kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE240M.rawValue: kCVImageBufferTransferFunction_SMPTE_240M_1995
        case AVCOL_TRC_LINEAR.rawValue: kCVImageBufferTransferFunction_Linear
        case AVCOL_TRC_IEC61966_2_1.rawValue: kCVImageBufferTransferFunction_sRGB
        // The two BT.2020 entries differ only in coded bit depth, not in curve.
        case AVCOL_TRC_BT2020_10.rawValue: kCVImageBufferTransferFunction_ITU_R_2020
        case AVCOL_TRC_BT2020_12.rawValue: kCVImageBufferTransferFunction_ITU_R_2020
        case AVCOL_TRC_SMPTE2084.rawValue: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_SMPTE428.rawValue: kCVImageBufferTransferFunction_SMPTE_ST_428_1
        case AVCOL_TRC_ARIB_STD_B67.rawValue: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        // Unspecified (2) and the pure-gamma/log curves (4, 5, 9, 10, 11, 12)
        // get nothing. Gamma 2.2 and 2.8 would need
        // `kCVImageBufferTransferFunction_UseGamma` plus a matching
        // `kCVImageBufferGammaLevelKey`, i.e. a second attachment the source
        // never asked for; leaving them bare keeps SD broadcast exactly as it
        // renders today.
        default: nil
        }
    }

    static func yCbCrMatrix(_ raw: UInt32) -> CFString? {
        switch raw {
        case AVCOL_SPC_BT709.rawValue: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        // 470BG and 170M are both BT.601; CoreVideo has one constant for it.
        case AVCOL_SPC_BT470BG.rawValue: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE170M.rawValue: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M.rawValue: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        case AVCOL_SPC_BT2020_NCL.rawValue: kCVImageBufferYCbCrMatrix_ITU_R_2020
        // Unspecified (2), RGB/GBR (0), FCC (4), YCgCo (8), and the ICtCp /
        // chroma-derived variants get nothing. BT.2020 *constant* luminance
        // (10) is deliberately absent too: CoreVideo's `ITU_R_2020` constant
        // names the non-constant-luminance matrix, so mapping CL onto it would
        // be the guess this table refuses to make.
        default: nil
        }
    }
}
