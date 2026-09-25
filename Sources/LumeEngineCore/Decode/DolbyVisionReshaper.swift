internal import CFFmpeg
import CoreVideo
import Foundation
import Metal
import simd

/// Turns IPTPQc2 base-layer frames (Dolby Vision profiles 5, 20 and 10.0) into
/// HDR10 on the GPU, using the frame's own RPU. See
/// `DolbyVisionReshapeParameters` for the math and why it is needed at all.
///
/// Input is whatever the decoder produced — a VideoToolbox surface or a
/// `PixelBufferFactory` buffer, 8- or 10-bit biplanar 4:2:0 — read in place
/// through a Metal texture cache. Output is a pooled `x420` buffer (10-bit
/// video range BT.2020 NCL YCbCr, PQ), tagged so the display takes it as the
/// HDR10 it now is.
///
/// Decode-thread only, like `PixelBufferFactory`. Every failure is thrown, and
/// the caller degrades to delivering the untouched frame: a tinted picture is
/// a bug, but a dead pipeline would be a worse one (PLAN.md §3.3).
final class DolbyVisionReshaper {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private var parameterBuffer: MTLBuffer?
    private var packedParameters: DolbyVisionReshapeParameters?

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// `nil` when the platform has no Metal device or the kernel does not
    /// compile — the caller then keeps today's (tinted) behaviour.
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        // Compiled from source at first use instead of shipping a metallib:
        // SwiftPM only compiles `.metal` resources under Xcode, and this runs
        // once per Dolby Vision session, off the main thread.
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let function = library.makeFunction(name: "lume_dovi_reshape"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        textureCache = cache
    }

    func reshape(_ source: CVPixelBuffer, parameters: DolbyVisionReshapeParameters) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        let planeFormats: (luma: MTLPixelFormat, chroma: MTLPixelFormat, scale: Float)
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            // 10 bits left-justified in 16: unorm reads code·64/65535, so this
            // brings it back to code/1023.
            planeFormats = (.r16Unorm, .rg16Unorm, 65535.0 / 65472.0)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            planeFormats = (.r8Unorm, .rg8Unorm, 1)
        default:
            throw EngineError(
                code: .unsupported,
                message: "Dolby Vision reshape: unsupported pixel format \(VideoDecoder.fourCC(format))"
            )
        }
        guard CVPixelBufferGetPlaneCount(source) == 2 else {
            throw EngineError(code: .unsupported, message: "Dolby Vision reshape: source is not biplanar")
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let destination = try dequeueBuffer(width: width, height: height)

        let sourceLuma = try texture(source, plane: 0, format: planeFormats.luma)
        let sourceChroma = try texture(source, plane: 1, format: planeFormats.chroma)
        let destinationLuma = try texture(destination, plane: 0, format: .r16Unorm)
        let destinationChroma = try texture(destination, plane: 1, format: .rg16Unorm)
        defer { CVMetalTextureCacheFlush(textureCache, 0) }

        guard let lumaIn = CVMetalTextureGetTexture(sourceLuma),
              let chromaIn = CVMetalTextureGetTexture(sourceChroma),
              let lumaOut = CVMetalTextureGetTexture(destinationLuma),
              let chromaOut = CVMetalTextureGetTexture(destinationChroma)
        else {
            throw EngineError(code: .internalError, message: "Dolby Vision reshape: texture unavailable")
        }

        let buffer = try uniforms(for: parameters, inputScale: planeFormats.scale)
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else {
            throw EngineError(code: .internalError, message: "Dolby Vision reshape: no command encoder")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(lumaIn, index: 0)
        encoder.setTexture(chromaIn, index: 1)
        encoder.setTexture(lumaOut, index: 2)
        encoder.setTexture(chromaOut, index: 3)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(
            width: (chromaOut.width + group.width - 1) / group.width,
            height: (chromaOut.height + group.height - 1) / group.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        commands.commit()
        // Synchronous on purpose: the decode thread is the data plane, the
        // renderer may take the buffer the moment it is sent, and the frame
        // costs a millisecond or two of GPU time at 4K.
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError(code: .internalError, message: "Dolby Vision reshape: \(error.localizedDescription)")
        }

        tagHDR10(destination, copyingStaticMetadataFrom: source)
        return destination
    }

    // MARK: Support

    private func uniforms(for parameters: DolbyVisionReshapeParameters, inputScale: Float) throws -> MTLBuffer {
        if packedParameters == parameters, let parameterBuffer {
            parameterBuffer.contents().storeBytes(of: inputScale, toByteOffset: 21 * 4, as: Float.self)
            return parameterBuffer
        }
        var values = parameters.packed()
        values[21] = inputScale
        // A fresh buffer per RPU change, never an in-place rewrite: the last
        // command buffer has completed by now, but a fresh one keeps that from
        // being load-bearing.
        guard let buffer = device.makeBuffer(
            bytes: values, length: values.count * MemoryLayout<Float>.stride, options: .storageModeShared
        ) else {
            throw EngineError(code: .internalError, message: "Dolby Vision reshape: parameter buffer allocation failed")
        }
        parameterBuffer = buffer
        packedParameters = parameters
        return buffer
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        // Read-write for every plane: the output planes are written by the
        // kernel, and the cache's default usage is not guaranteed to allow it.
        let attributes = [
            kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue,
        ] as CFDictionary
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, attributes, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane),
            plane, &texture
        )
        guard status == kCVReturnSuccess, let texture else {
            throw EngineError(code: .internalError, message: "Dolby Vision reshape: texture for plane \(plane) failed (\(status))")
        }
        return texture
    }

    private func dequeueBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var newPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            guard status == kCVReturnSuccess, let newPool else {
                throw EngineError(code: .decodeFailed, message: "Dolby Vision reshape: pool creation failed (\(status))")
            }
            pool = newPool
            poolWidth = width
            poolHeight = height
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw EngineError(code: .decodeFailed, message: "Dolby Vision reshape: buffer allocation failed (\(status))")
        }
        return buffer
    }

    /// The reshaped picture *is* HDR10, so it is tagged as such regardless of
    /// `preservesHDRMetadata`: an untagged PQ buffer renders washed out, and
    /// the source's own tag (IPT-C2) has no CoreVideo counterpart to preserve.
    /// Static mastering metadata travels over when the source carried it.
    private func tagHDR10(_ buffer: CVPixelBuffer, copyingStaticMetadataFrom source: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        // Set or removed, never left alone: the pool recycles buffers.
        for key in [kCVImageBufferMasteringDisplayColorVolumeKey, kCVImageBufferContentLightLevelInfoKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(buffer, key)
            }
        }
    }

    // MARK: Kernel

    /// One thread per 2×2 luma block (= one chroma sample). Offsets mirror
    /// `DolbyVisionReshapeParameters.packed()`.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant int kHeader = \(DolbyVisionReshapeParameters.headerFloats);
    constant int kPieceStride = \(DolbyVisionReshapeParameters.pieceStride);
    constant int kCurveStride = \(DolbyVisionReshapeParameters.curveStride);

    constant float m1 = 2610.0 / 16384.0;
    constant float m2 = 2523.0 / 4096.0 * 128.0;
    constant float c1 = 3424.0 / 4096.0;
    constant float c2 = 2413.0 / 4096.0 * 32.0;
    constant float c3 = 2392.0 / 4096.0 * 32.0;

    static float3 pq_eotf(float3 e) {
        e = clamp(e, 0.0, 1.0);
        float3 p = pow(e, 1.0 / m2);
        return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
    }

    static float3 pq_oetf(float3 l) {
        l = clamp(l, 0.0, 1.0);
        float3 p = pow(l, m1);
        return pow((c1 + c2 * p) / (1.0 + c3 * p), m2);
    }

    static float reshape(const device float *params, int component, float value, float3 sig) {
        const device float *curve = params + kHeader + component * kCurveStride;
        int pieces = int(curve[0]);
        int index = 0;
        for (int i = 1; i < pieces; ++i) {
            if (value >= curve[1 + i]) { index = i; }
        }
        const device float *piece = curve + 10 + index * kPieceStride;
        float result;
        if (piece[0] < 0.5) {
            result = piece[1] + value * (piece[2] + value * piece[3]);
        } else {
            float terms[7] = { sig.x, sig.y, sig.z, sig.x * sig.y, sig.x * sig.z, sig.y * sig.z, sig.x * sig.y * sig.z };
            float power[7];
            for (int k = 0; k < 7; ++k) { power[k] = terms[k]; }
            result = piece[5];
            int order = int(piece[4]);
            for (int o = 0; o < order; ++o) {
                for (int k = 0; k < 7; ++k) { result += piece[6 + o * 7 + k] * power[k]; }
                for (int k = 0; k < 7; ++k) { power[k] *= terms[k]; }
            }
        }
        return clamp(result, 0.0, 1.0);
    }

    static float3 row_mul(const device float *m, float3 v) {
        return float3(dot(float3(m[0], m[1], m[2]), v),
                      dot(float3(m[3], m[4], m[5]), v),
                      dot(float3(m[6], m[7], m[8]), v));
    }

    static float quantize10(float code) {
        return floor(clamp(code, 0.0, 1023.0) + 0.5) * 64.0 / 65535.0;
    }

    kernel void lume_dovi_reshape(texture2d<float, access::read> srcLuma [[texture(0)]],
                                  texture2d<float, access::read> srcChroma [[texture(1)]],
                                  texture2d<float, access::write> dstLuma [[texture(2)]],
                                  texture2d<float, access::write> dstChroma [[texture(3)]],
                                  const device float *params [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dstChroma.get_width() || gid.y >= dstChroma.get_height()) { return; }
        const float scale = params[21];
        const uint width = srcLuma.get_width();
        const uint height = srcLuma.get_height();

        uint2 sites[4];
        float luma[4];
        float lumaSum = 0.0;
        for (int i = 0; i < 4; ++i) {
            uint2 site = gid * 2 + uint2(i & 1, i >> 1);
            sites[i] = site;
            luma[i] = srcLuma.read(min(site, uint2(width - 1, height - 1))).r * scale;
            lumaSum += luma[i];
        }
        const float2 chroma = srcChroma.read(gid).rg * scale;
        const float3 sig = float3(lumaSum * 0.25, chroma.x, chroma.y);
        const float p = reshape(params, 1, chroma.x, sig);
        const float t = reshape(params, 2, chroma.y, sig);
        const float3 offset = float3(params[9], params[10], params[11]);
        const float3 kr = float3(0.2627, 0.6780, 0.0593);

        float3 sum = float3(0.0);
        for (int i = 0; i < 4; ++i) {
            float intensity = reshape(params, 0, luma[i], float3(luma[i], chroma.x, chroma.y));
            float3 lms = pq_eotf(row_mul(params, float3(intensity, p, t) - offset));
            float3 rgb = pq_oetf(max(row_mul(params + 12, lms), 0.0));
            if (sites[i].x < width && sites[i].y < height) {
                dstLuma.write(float4(quantize10(64.0 + 876.0 * dot(rgb, kr)), 0.0, 0.0, 0.0), sites[i]);
            }
            sum += rgb;
        }
        const float3 average = sum * 0.25;
        const float y = dot(average, kr);
        const float cb = (average.b - y) / 1.8814;
        const float cr = (average.r - y) / 1.4746;
        dstChroma.write(float4(quantize10(512.0 + 896.0 * cb), quantize10(512.0 + 896.0 * cr), 0.0, 0.0), gid);
    }
    """
}

// MARK: - RPU extraction

extension DolbyVisionReshapeParameters {
    /// Reads `AV_FRAME_DATA_DOVI_METADATA` off a decoded frame. `nil` when the
    /// frame carries none, or carries one that does not describe a usable
    /// reshape (see `isValid`).
    init?(frame: UnsafePointer<AVFrame>) {
        guard let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA),
              let bytes = sideData.pointee.data,
              sideData.pointee.size >= MemoryLayout<AVDOVIMetadata>.size
        else { return nil }
        let base = UnsafeRawPointer(bytes)
        let metadata = base.assumingMemoryBound(to: AVDOVIMetadata.self).pointee
        let header = base.advanced(by: metadata.header_offset)
            .assumingMemoryBound(to: AVDOVIRpuDataHeader.self).pointee
        let mapping = base.advanced(by: metadata.mapping_offset)
            .assumingMemoryBound(to: AVDOVIDataMapping.self).pointee
        let color = base.advanced(by: metadata.color_offset)
            .assumingMemoryBound(to: AVDOVIColorMetadata.self).pointee

        // Pivots are in base-layer code units; coefficients are fixed point
        // with `coef_log2_denom` fractional bits (lavc always converts to it).
        let codeMax = Float((1 << Int(header.bl_bit_depth)) - 1)
        let denominator = Float(pow(2.0, Double(header.coef_log2_denom)))
        let curves = withUnsafeBytes(of: mapping.curves) { raw in
            raw.bindMemory(to: AVDOVIReshapingCurve.self).map {
                Self.curve($0, codeMax: codeMax, denominator: denominator)
            }
        }

        func rationals(_ tuple: some Any, count: Int) -> [Double] {
            withUnsafeBytes(of: tuple) { raw in
                raw.bindMemory(to: AVRational.self).prefix(count).map {
                    $0.den == 0 ? 0 : Double($0.num) / Double($0.den)
                }
            }
        }
        let nonlinear = rationals(color.ycc_to_rgb_matrix, count: 9)
        let offset = rationals(color.ycc_to_rgb_offset, count: 3)
        let linear = rationals(color.rgb_to_lms_matrix, count: 9)
        func matrix(_ values: [Double]) -> simd_double3x3 {
            simd_double3x3(rows: [
                SIMD3(values[0], values[1], values[2]),
                SIMD3(values[3], values[4], values[5]),
                SIMD3(values[6], values[7], values[8]),
            ])
        }
        let linearMatrix = matrix(linear)
        guard abs(linearMatrix.determinant) > 1e-9 else { return nil }

        self.init(
            curves: curves,
            nonlinear: matrix(nonlinear),
            nonlinearOffset: SIMD3(offset[0], offset[1], offset[2]),
            rgbToLMS: linearMatrix
        )
        guard isValid else { return nil }
    }

    private static func curve(_ raw: AVDOVIReshapingCurve, codeMax: Float, denominator: Float) -> Curve {
        let pieceCount = max(Int(raw.num_pivots) - 1, 0)
        let pivots = withUnsafeBytes(of: raw.pivots) { Array($0.bindMemory(to: UInt16.self)) }
        let methods = withUnsafeBytes(of: raw.mapping_idc) { Array($0.bindMemory(to: UInt32.self)) }
        let polyOrders = withUnsafeBytes(of: raw.poly_order) { Array($0.bindMemory(to: UInt8.self)) }
        let poly = withUnsafeBytes(of: raw.poly_coef) { Array($0.bindMemory(to: Int64.self)) }
        let mmrOrders = withUnsafeBytes(of: raw.mmr_order) { Array($0.bindMemory(to: UInt8.self)) }
        let mmrConstants = withUnsafeBytes(of: raw.mmr_constant) { Array($0.bindMemory(to: Int64.self)) }
        let mmr = withUnsafeBytes(of: raw.mmr_coef) { Array($0.bindMemory(to: Int64.self)) }

        var pieces: [Piece] = []
        for index in 0..<min(pieceCount, DolbyVisionReshapeParameters.maxPieces) {
            let isMMR = methods[index] == AV_DOVI_MAPPING_MMR.rawValue
            let order = Int(polyOrders[index])
            let coefficient = { (term: Int) -> Float in
                term <= order ? Float(poly[index * 3 + term]) / denominator : 0
            }
            let mmrOrder = Int(mmrOrders[index])
            let rows = (0..<min(max(mmrOrder, 0), 3)).map { order in
                (0..<7).map { Float(mmr[(index * 3 + order) * 7 + $0]) / denominator }
            }
            pieces.append(Piece(
                isMMR: isMMR,
                poly: SIMD3(coefficient(0), coefficient(1), coefficient(2)),
                mmrOrder: mmrOrder,
                mmrConstant: Float(mmrConstants[index]) / denominator,
                mmr: rows
            ))
        }
        let normalizedPivots = pivots.prefix(pieces.count + 1).map { Float($0) / codeMax }
        return Curve(pivots: normalizedPivots, pieces: pieces)
    }
}

extension VideoColorimetry {
    /// What a frame declares once `DolbyVisionReshaper` has turned its IPT
    /// base layer into HDR10. The static HDR payloads are the source's own.
    func reshapedToHDR10() -> VideoColorimetry {
        VideoColorimetry(
            primaries: AVCOL_PRI_BT2020.rawValue,
            transfer: AVCOL_TRC_SMPTE2084.rawValue,
            matrix: AVCOL_SPC_BT2020_NCL.rawValue,
            isFullRange: false,
            masteringDisplayColorVolume: masteringDisplayColorVolume,
            contentLightLevel: contentLightLevel
        )
    }
}
