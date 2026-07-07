internal import CFFmpeg
import CoreVideo

/// Converts software-decoded `AVFrame`s into pooled `CVPixelBuffer`s (NV12 for
/// 8-bit, P010 for higher bit depths) via swscale. The hardware path never
/// touches this — VideoToolbox frames are already `CVPixelBuffer`s (zero-copy,
/// PLAN.md §7 "no sws_scale on the hot path" applies to HW-decodable content;
/// this factory exists for the exotic-format software fallback).
final class PixelBufferFactory {
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat: OSType = 0
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var swsSourceFormat = AV_PIX_FMT_NONE
    private var swsTargetFormat = AV_PIX_FMT_NONE

    deinit {
        sws_freeContext(swsContext)
    }

    /// Converts one software `AVFrame` to a pooled `CVPixelBuffer`.
    func makePixelBuffer(from frame: UnsafeMutablePointer<AVFrame>) throws -> CVPixelBuffer {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let sourceFormat = AVPixelFormat(rawValue: frame.pointee.format)

        let bitDepth = av_pix_fmt_desc_get(sourceFormat).map { Int($0.pointee.comp.0.depth) } ?? 8
        let wide = bitDepth > 8
        let targetFFmpeg = wide ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
        let fullRange = frame.pointee.color_range == AVCOL_RANGE_JPEG
        let targetCV: OSType = wide
            ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let buffer = try dequeueBuffer(width: width, height: height, format: targetCV)
        try convert(frame: frame, from: sourceFormat, to: targetFFmpeg, into: buffer, width: width, height: height)
        return buffer
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
