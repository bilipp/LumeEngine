internal import CFFmpeg

/// The per-frame Dolby Vision metadata needed to turn an IPTPQc2 base layer
/// into displayable pixels: the reshaping curves from the RPU, plus the
/// colour matrices that take the reshaped signal to linear BT.2020.
///
/// Dolby Vision profiles 5, 10.0 and 20 carry a base layer with signal
/// compatibility ID 0 — it is *not* YCbCr. Shown as if it were, it comes out
/// with a pink/green cast, and no colour tag can fix that: the reshaping
/// changes per scene and CoreVideo has no IPT matrix for decoded buffers.
/// `DolbyVisionConverter` applies this metadata on the GPU and hands the
/// renderer HDR10 (PLAN.md §6).
///
/// Everything is normalized here, once per frame, so the shader only does
/// arithmetic: pivots are fractions of the base layer's code range and
/// coefficients are plain values (FFmpeg delivers them as fixed point over
/// `2^coef_log2_denom`, whatever the bitstream used).
struct DolbyVisionMapping: Sendable, Equatable {
    enum Piece: Sendable, Equatable {
        /// `c0 + c1·x + c2·x²` of the component's own input.
        case polynomial([Double])
        /// Multivariate multiple regression over all three inputs `(y, u, v)`:
        /// `constant + Σₖ (a·yᵏ + b·uᵏ + c·vᵏ + d·(yu)ᵏ + e·(yv)ᵏ + f·(uv)ᵏ + g·(yuv)ᵏ)`
        /// for `k` in `1...order`, one row of seven coefficients per order.
        case mmr(constant: Double, coefficients: [[Double]])
    }

    struct Curve: Sendable, Equatable {
        /// Ascending piece boundaries, normalized to `0...1`. One more than
        /// `pieces`.
        var pivots: [Double]
        var pieces: [Piece]
    }

    /// Bit depth of the base layer the curves' pivots refer to.
    var baseLayerBitDepth: Int
    /// Reshaping curves for the three base-layer components (I, P, T).
    var curves: [Curve]
    /// Row-major 3×3: reshaped signal (minus `yccToRGBOffset`) to PQ-coded LMS.
    var yccToRGB: [Double]
    var yccToRGBOffset: [Double]
    /// Row-major 3×3 from the RPU, applied to linear LMS. FFmpeg documents its
    /// output as feeding a Hunt-Pointer-Estevez LMS→RGB matrix *without*
    /// crosstalk — `linearLMSToRGB` composes the two.
    var rgbToLMS: [Double]

    /// Row-major 3×3: linear LMS (after PQ decoding) to linear BT.2020 RGB.
    var linearLMSToRGB: [Double] {
        Matrix3.multiply(Matrix3.hpeLMSToBT2020, rgbToLMS)
    }
}

// MARK: - Extraction from FFmpeg

extension DolbyVisionMapping {
    /// Reads the mapping FFmpeg attached to a decoded frame
    /// (`AV_FRAME_DATA_DOVI_METADATA`). Nil when the frame carries none.
    init?(frame: UnsafePointer<AVFrame>) {
        guard let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA),
              let bytes = sideData.pointee.data
        else { return nil }
        self.init(metadata: UnsafeRawPointer(bytes).assumingMemoryBound(to: AVDOVIMetadata.self))
    }

    /// Reads a mapping from FFmpeg's metadata struct. Nil when it is internally
    /// inconsistent (FFmpeg validates the bitstream, so this is a backstop, not
    /// an expected path).
    init?(metadata: UnsafePointer<AVDOVIMetadata>) {
        guard let header = av_dovi_get_header(metadata)?.pointee,
              let mapping = av_dovi_get_mapping(metadata),
              let color = av_dovi_get_color(metadata)?.pointee
        else { return nil }

        let bitDepth = Int(header.bl_bit_depth)
        guard (8...16).contains(bitDepth) else { return nil }
        let codeMax = Double((1 << bitDepth) - 1)
        let scale = Double(sign: .plus, exponent: -Int(header.coef_log2_denom), significand: 1)

        var curves: [Curve] = []
        for component in 0..<3 {
            let curve = Self.curve(mapping, component)
            let pivotCount = Int(curve.num_pivots)
            guard (2...Int(AV_DOVI_MAX_PIECES) + 1).contains(pivotCount) else { return nil }

            let pieceCount = pivotCount - 1
            let rawPivots: [UInt16] = Self.array(curve.pivots, count: pivotCount)
            let methods: [AVDOVIMappingMethod] = Self.array(curve.mapping_idc, count: pieceCount)
            let mmrOrders: [UInt8] = Self.array(curve.mmr_order, count: pieceCount)
            let mmrConstants: [Int64] = Self.array(curve.mmr_constant, count: pieceCount)
            // Flattened [piece][3] and [piece][order][7].
            let polyCoefficients: [Int64] = Self.array(curve.poly_coef, count: pieceCount * 3)
            let mmrCoefficients: [Int64] = Self.array(curve.mmr_coef, count: pieceCount * 3 * 7)

            var pieces: [Piece] = []
            for index in 0..<pieceCount {
                if methods[index] == AV_DOVI_MAPPING_MMR {
                    let order = Int(mmrOrders[index])
                    guard (1...3).contains(order) else { return nil }
                    let rows = (0..<order).map { row in
                        let start = (index * 3 + row) * 7
                        return mmrCoefficients[start..<(start + 7)].map { Double($0) * scale }
                    }
                    pieces.append(.mmr(constant: Double(mmrConstants[index]) * scale, coefficients: rows))
                } else {
                    // Order 1 leaves the x² coefficient zero, so all three
                    // terms can always be evaluated.
                    let start = index * 3
                    pieces.append(.polynomial(polyCoefficients[start..<(start + 3)].map { Double($0) * scale }))
                }
            }
            curves.append(Curve(pivots: rawPivots.map { Double($0) / codeMax }, pieces: pieces))
        }

        let yccToRGB: [AVRational] = Self.array(color.ycc_to_rgb_matrix, count: 9)
        let yccToRGBOffset: [AVRational] = Self.array(color.ycc_to_rgb_offset, count: 3)
        let rgbToLMS: [AVRational] = Self.array(color.rgb_to_lms_matrix, count: 9)
        self.init(
            baseLayerBitDepth: bitDepth,
            curves: curves,
            yccToRGB: yccToRGB.map(Self.value),
            yccToRGBOffset: yccToRGBOffset.map(Self.value),
            rgbToLMS: rgbToLMS.map(Self.value)
        )
    }

    private static func value(_ rational: AVRational) -> Double {
        rational.den == 0 ? 0 : Double(rational.num) / Double(rational.den)
    }

    // The C arrays import as tuples; these copy them out by reinterpreting the
    // tuple's storage, which is laid out exactly like the C array.

    private static func curve(
        _ mapping: UnsafePointer<AVDOVIDataMapping>, _ component: Int
    ) -> AVDOVIReshapingCurve {
        withUnsafeBytes(of: mapping.pointee.curves) {
            $0.load(fromByteOffset: component * MemoryLayout<AVDOVIReshapingCurve>.stride, as: AVDOVIReshapingCurve.self)
        }
    }

    /// First `count` elements of a C array imported as a (possibly nested)
    /// tuple. Callers name `Element`, and the count never exceeds the array.
    private static func array<Tuple, Element>(_ tuple: Tuple, count: Int) -> [Element] {
        withUnsafeBytes(of: tuple) { bytes in
            (0..<count).map { bytes.load(fromByteOffset: $0 * MemoryLayout<Element>.stride, as: Element.self) }
        }
    }
}

// MARK: - Fixed colour science

/// Row-major 3×3 helpers. Tiny and allocation-happy by design: they run once
/// per frame on nine numbers.
///
/// Written as plain loops with every type spelled out. The closure-and-literal
/// form (`reduce(0) { $0 + a[…] * b[…] }` inside a `map`) type-checks
/// instantly on Swift 6.4 but exceeds Swift 6.2's solver limit ("unable to
/// type-check this expression in reasonable time") — which is what CI's
/// Xcode 26.3 runs.
enum Matrix3 {
    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var product = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum: Double = 0
                for k in 0..<3 {
                    sum += a[row * 3 + k] * b[k * 3 + column]
                }
                product[row * 3 + column] = sum
            }
        }
        return product
    }

    static func inverse(_ m: [Double]) -> [Double] {
        // Cofactor (i, j) of the transpose, i.e. the adjugate, row-major.
        func minor(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double {
            let lhs: Double = m[a] * m[b]
            let rhs: Double = m[c] * m[d]
            return lhs - rhs
        }
        let adjugate: [Double] = [
            minor(4, 8, 5, 7), minor(2, 7, 1, 8), minor(1, 5, 2, 4),
            minor(5, 6, 3, 8), minor(0, 8, 2, 6), minor(2, 3, 0, 5),
            minor(3, 7, 4, 6), minor(1, 6, 0, 7), minor(0, 4, 1, 3),
        ]
        let determinant: Double = m[0] * adjugate[0] + m[1] * adjugate[3] + m[2] * adjugate[6]
        return adjugate.map { (value: Double) -> Double in value / determinant }
    }

    /// Linear LMS (Hunt-Pointer-Estevez, no crosstalk) to linear BT.2020 RGB.
    ///
    /// Derived rather than transcribed: BT.2100 defines ICtCp's RGB→LMS matrix
    /// as this HPE transform with 4 % crosstalk already folded in,
    /// `M = X(0.04) · HPE`, where `X(c)` has `1 − 2c` on the diagonal and `c`
    /// elsewhere. So `HPE⁻¹ = M⁻¹ · X(0.04)`.
    static let hpeLMSToBT2020: [Double] = {
        let ictcpCodes: [Double] = [1688, 2146, 262, 683, 2951, 462, 99, 309, 3688]
        let ictcp = ictcpCodes.map { (code: Double) -> Double in code / 4096 }
        let crosstalk: [Double] = [0.92, 0.04, 0.04, 0.04, 0.92, 0.04, 0.04, 0.04, 0.92]
        return multiply(inverse(ictcp), crosstalk)
    }()
}
