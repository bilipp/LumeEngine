import Foundation
import simd

/// Everything one Dolby Vision RPU says about turning a non-backward-compatible
/// base layer into a displayable picture, as plain floats.
///
/// Profiles whose base layer declares `dv_bl_signal_compatibility_id == 0`
/// (5, 20, 10.0) do not carry YCbCr at all: the samples are IPTPQc2, and FFmpeg
/// reports them as `AVCOL_SPC_IPT_C2`. Nothing on the Apple side displays that
/// as-is — VideoToolbox decodes the samples faithfully and the display then
/// reads IPT as BT.2020 YCbCr, which is the pink/green picture. The RPU carries
/// the per-frame recipe back to real colour:
///
/// 1. **Reshape** each component through its piecewise curve (polynomial for
///    luma, polynomial or MMR for chroma).
/// 2. **Nonlinear matrix**: reshaped IPT, minus the neutral offset, times
///    `ycc_to_rgb_matrix`, gives PQ-encoded LMS.
/// 3. **PQ EOTF** to linear LMS.
/// 4. **Linear matrix**: undo the RPU's `rgb_to_lms_matrix` (the "c2"
///    crosstalk) and apply the fixed BT.2020 Hunt-Pointer-Estevez LMS→RGB
///    matrix, giving linear BT.2020 RGB.
///
/// The output is then ordinary HDR10 (BT.2020 / PQ), which every Apple display
/// path already handles. This is the libplacebo algorithm (`pl_shader_dovi_*`
/// plus the `PL_COLOR_SYSTEM_DOLBYVISION` decode), not an approximation of it.
///
/// Kept free of FFmpeg types so tests can build parameters by hand and so the
/// CPU `reference` below can check the GPU kernel.
struct DolbyVisionReshapeParameters: Equatable {
    struct Piece: Equatable {
        /// `AV_DOVI_MAPPING_MMR` rather than `AV_DOVI_MAPPING_POLYNOMIAL`.
        var isMMR: Bool
        /// x⁰, x¹, x² — unused entries are zero.
        var poly: SIMD3<Float>
        /// 1...3.
        var mmrOrder: Int
        var mmrConstant: Float
        /// `mmrOrder` rows of 7 terms: y, cb, cr, y·cb, y·cr, cb·cr, y·cb·cr.
        var mmr: [[Float]]
    }

    struct Curve: Equatable {
        /// Normalized to the base layer's code range, ascending,
        /// `pieces.count + 1` entries.
        var pivots: [Float]
        var pieces: [Piece]
    }

    /// I (luma), P, T.
    var curves: [Curve]
    /// `ycc_to_rgb_matrix`, row-major.
    var nonlinear: simd_float3x3
    /// `ycc_to_rgb_offset`, already normalized (0.5 is the chroma neutral).
    var nonlinearOffset: SIMD3<Float>
    /// Linear LMS → linear BT.2020 RGB: the HPE matrix times the inverse of the
    /// RPU's `rgb_to_lms_matrix`.
    var lmsToRGB: simd_float3x3

    /// The BT.2020 Hunt-Pointer-Estevez LMS→RGB matrix without crosstalk. Dolby
    /// Vision's LMS is always this one; the RPU only states the crosstalk on
    /// top of it. (Same constant libplacebo hard-codes.)
    static let hpeLMSToBT2020 = simd_double3x3(rows: [
        SIMD3(3.06441879, -2.16597676, 0.10155818),
        SIMD3(-0.65612108, 1.78554118, -0.12943749),
        SIMD3(0.01736321, -0.04725154, 1.03004253),
    ])

    init(
        curves: [Curve],
        nonlinear: simd_double3x3,
        nonlinearOffset: SIMD3<Double>,
        rgbToLMS: simd_double3x3
    ) {
        self.curves = curves
        self.nonlinear = Self.single(nonlinear)
        self.nonlinearOffset = SIMD3<Float>(nonlinearOffset)
        lmsToRGB = Self.single(Self.hpeLMSToBT2020 * rgbToLMS.inverse)
    }

    private static func single(_ matrix: simd_double3x3) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(matrix.columns.0),
            SIMD3<Float>(matrix.columns.1),
            SIMD3<Float>(matrix.columns.2)
        )
    }

    /// A usable RPU names three curves, each with at least one piece, pivots
    /// to bound them, and an invertible LMS matrix. Anything else is treated
    /// as "no RPU on this frame" rather than rendered with a guess.
    var isValid: Bool {
        guard curves.count == 3 else { return false }
        for curve in curves {
            guard !curve.pieces.isEmpty,
                  curve.pieces.count <= Self.maxPieces,
                  curve.pivots.count == curve.pieces.count + 1
            else { return false }
            for piece in curve.pieces where piece.isMMR {
                guard (1...3).contains(piece.mmrOrder), piece.mmr.count >= piece.mmrOrder,
                      piece.mmr.allSatisfy({ $0.count == 7 })
                else { return false }
            }
        }
        let values = (0..<3).flatMap { column in (0..<3).map { lmsToRGB[column][$0] } }
        return values.allSatisfy(\.isFinite)
    }

    // MARK: GPU layout

    static let maxPieces = 8
    static let headerFloats = 32
    static let pieceStride = 28
    static let curveStride = 10 + maxPieces * pieceStride

    /// The flat float buffer the Metal kernel reads (`DolbyVisionReshaper`'s
    /// shader source mirrors these offsets):
    ///
    /// - `[0..<9]` nonlinear matrix, row-major; `[9..<12]` offset;
    ///   `[12..<21]` LMS→RGB matrix, row-major.
    /// - per curve at `headerFloats + c * curveStride`: piece count, 9 pivots,
    ///   then per piece: method, 3 poly coefficients, MMR order, MMR constant,
    ///   21 MMR coefficients.
    func packed() -> [Float] {
        var buffer = [Float](repeating: 0, count: Self.headerFloats + 3 * Self.curveStride)
        for row in 0..<3 {
            for column in 0..<3 {
                buffer[row * 3 + column] = nonlinear[column][row]
                buffer[12 + row * 3 + column] = lmsToRGB[column][row]
            }
            buffer[9 + row] = nonlinearOffset[row]
        }
        for (index, curve) in curves.prefix(3).enumerated() {
            let base = Self.headerFloats + index * Self.curveStride
            buffer[base] = Float(curve.pieces.count)
            for (offset, pivot) in curve.pivots.prefix(Self.maxPieces + 1).enumerated() {
                buffer[base + 1 + offset] = pivot
            }
            for (pieceIndex, piece) in curve.pieces.prefix(Self.maxPieces).enumerated() {
                let pieceBase = base + 10 + pieceIndex * Self.pieceStride
                buffer[pieceBase] = piece.isMMR ? 1 : 0
                buffer[pieceBase + 1] = piece.poly.x
                buffer[pieceBase + 2] = piece.poly.y
                buffer[pieceBase + 3] = piece.poly.z
                buffer[pieceBase + 4] = Float(piece.mmrOrder)
                buffer[pieceBase + 5] = piece.mmrConstant
                for (order, row) in piece.mmr.prefix(3).enumerated() {
                    for (term, value) in row.prefix(7).enumerated() {
                        buffer[pieceBase + 6 + order * 7 + term] = value
                    }
                }
            }
        }
        return buffer
    }

    // MARK: CPU reference

    /// One component through its reshaping curve. `value` is the component's
    /// own normalized code value; `signal` is (luma, cb, cr) at the chroma
    /// site, which only MMR pieces read.
    func reshape(component: Int, value: Float, signal: SIMD3<Float>) -> Float {
        let curve = curves[component]
        var index = 0
        for pivotIndex in 1..<curve.pieces.count where value >= curve.pivots[pivotIndex] {
            index = pivotIndex
        }
        let piece = curve.pieces[index]
        var result: Float
        if piece.isMMR {
            let terms: [Float] = [
                signal.x, signal.y, signal.z,
                signal.x * signal.y, signal.x * signal.z, signal.y * signal.z,
                signal.x * signal.y * signal.z,
            ]
            var power = terms
            result = piece.mmrConstant
            for order in 0..<piece.mmrOrder {
                for term in 0..<7 {
                    result += piece.mmr[order][term] * power[term]
                }
                for term in 0..<7 {
                    power[term] *= terms[term]
                }
            }
        } else {
            result = piece.poly.x + value * (piece.poly.y + value * piece.poly.z)
        }
        return min(max(result, 0), 1)
    }

    /// Normalized base-layer I/P/T code values → PQ-encoded BT.2020 R′G′B′.
    /// What the kernel computes per pixel; tests compare the two.
    func reference(i: Float, p: Float, t: Float) -> SIMD3<Float> {
        let signal = SIMD3<Float>(i, p, t)
        let ipt = SIMD3<Float>(
            reshape(component: 0, value: i, signal: signal),
            reshape(component: 1, value: p, signal: signal),
            reshape(component: 2, value: t, signal: signal)
        ) - nonlinearOffset
        let lms = PQ.eotf(nonlinear * ipt)
        let rgb = simd_max(lmsToRGB * lms, SIMD3(repeating: 0))
        return PQ.oetf(rgb)
    }
}

/// SMPTE ST 2084, normalized: 1.0 is 10 000 cd/m².
enum PQ {
    static let m1: Float = 2610.0 / 16384.0
    static let m2: Float = 2523.0 / 4096.0 * 128.0
    static let c1: Float = 3424.0 / 4096.0
    static let c2: Float = 2413.0 / 4096.0 * 32.0
    static let c3: Float = 2392.0 / 4096.0 * 32.0

    static func eotf(_ encoded: SIMD3<Float>) -> SIMD3<Float> {
        let e = simd_clamp(encoded, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let p = SIMD3(powf(e.x, 1 / m2), powf(e.y, 1 / m2), powf(e.z, 1 / m2))
        let ratio = simd_max(p - c1, SIMD3(repeating: 0)) / (c2 - c3 * p)
        return SIMD3(powf(ratio.x, 1 / m1), powf(ratio.y, 1 / m1), powf(ratio.z, 1 / m1))
    }

    static func oetf(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        let l = simd_clamp(linear, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let p = SIMD3(powf(l.x, m1), powf(l.y, m1), powf(l.z, m1))
        let ratio = (c1 + c2 * p) / (1 + c3 * p)
        return SIMD3(powf(ratio.x, m2), powf(ratio.y, m2), powf(ratio.z, m2))
    }
}
