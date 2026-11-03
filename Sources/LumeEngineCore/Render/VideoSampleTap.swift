import CoreVideo
import Foundation
import Synchronization

/// A coarse colour reading of the picture, for hosts that drive something
/// from what is on screen (ambient lighting, a UI tint).
///
/// Off by default. When enabled, the video render pump offers every frame it
/// hands the display right after enqueueing it; the tap reads a sparse grid of
/// luma and chroma straight from the pixel buffer (locked read-only, never
/// retained), converts it to linear light, and keeps a short ring of samples
/// stamped with the frame's PTS. Frames are enqueued ahead of the clock, so a
/// host reads `sample(atOrBefore: renderer.currentTime)` — what is being shown
/// now — rather than the newest sample.
///
/// The render queue never waits on it and it never fails playback: a buffer
/// it cannot read (an unexpected pixel format, a lock that fails) is skipped.
/// The ring is emptied on seek and whenever frames of a newer serial arrive,
/// so a reading never comes from before a seek.
///
/// Colours are linear light on BT.709/sRGB primaries, 0...1, where 1 is SDR
/// reference white: PQ is scaled so 203 nits reads as 1, HLG so its
/// reference white (75 % signal) does; brighter highlights clip to 1. BT.2020
/// and P3 primaries are converted, and out-of-gamut values clip to 0.
public final class VideoSampleTap: Sendable {
    /// How finely the picture is sampled and how much is kept.
    public struct Configuration: Sendable, Equatable {
        /// Grid cells across the picture, 1...64.
        public var columns: Int
        /// Grid cells down the picture, 1...64.
        public var rows: Int
        /// Points read per cell along each axis (n×n per cell), 1...8.
        public var pointsPerCell: Int
        /// Samples kept, 1...240. Has to span how far the renderer runs
        /// ahead of the clock, or `sample(atOrBefore:)` finds nothing old
        /// enough; the default covers about a second of 50p.
        public var capacity: Int

        public init(columns: Int = 16, rows: Int = 9, pointsPerCell: Int = 3, capacity: Int = 48) {
            self.columns = min(max(columns, 1), 64)
            self.rows = min(max(rows, 1), 64)
            self.pointsPerCell = min(max(pointsPerCell, 1), 8)
            self.capacity = min(max(capacity, 1), 240)
        }
    }

    /// Linear-light RGB on BT.709/sRGB primaries, each 0...1.
    public struct Color: Sendable, Equatable {
        public var red: Float
        public var green: Float
        public var blue: Float

        public init(red: Float, green: Float, blue: Float) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The grid read from one frame.
    public struct Sample: Sendable, Equatable {
        /// The frame's presentation time, engine µs (comparable to
        /// `SystemRenderer.currentTime`).
        public let pts: Int64
        public let columns: Int
        public let rows: Int
        /// Row-major, top-left cell first; `columns * rows` entries. The cell
        /// grid covers the coded picture (letterbox bars included).
        public let colors: [Color]

        public init(pts: Int64, columns: Int, rows: Int, colors: [Color]) {
            self.pts = pts
            self.columns = columns
            self.rows = rows
            self.colors = colors
        }

        /// The cell at `column`, `row`; nil outside the grid.
        public func color(column: Int, row: Int) -> Color? {
            guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
            let index = row * columns + column
            return colors.indices.contains(index) ? colors[index] : nil
        }

        /// The mean of every cell.
        public var average: Color {
            guard !colors.isEmpty else { return Color(red: 0, green: 0, blue: 0) }
            var red: Float = 0, green: Float = 0, blue: Float = 0
            for color in colors {
                red += color.red
                green += color.green
                blue += color.blue
            }
            let count = Float(colors.count)
            return Color(red: red / count, green: green / count, blue: blue / count)
        }
    }

    private struct State {
        var enabled: Bool
        var configuration: Configuration
        /// Serial of the samples in the ring; older frames are refused.
        var serial: UInt64 = 0
        /// Ascending PTS.
        var ring: [Sample] = []
    }

    private let state: Mutex<State>

    public init(configuration: Configuration = Configuration(), enabled: Bool = false) {
        state = Mutex(State(enabled: enabled, configuration: configuration))
    }

    // MARK: Host side (any thread)

    /// Whether frames are sampled. Turning it off empties the ring.
    public var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set {
            state.withLock { state in
                state.enabled = newValue
                if !newValue { state.ring.removeAll() }
            }
        }
    }

    /// The grid in use. Changing it empties the ring.
    public var configuration: Configuration {
        get { state.withLock { $0.configuration } }
        set {
            state.withLock { state in
                guard state.configuration != newValue else { return }
                state.configuration = newValue
                state.ring.removeAll()
            }
        }
    }

    /// The newest sample presented at or before `pts` (engine µs) — pass
    /// `renderer.currentTime`. Nil when sampling is off, nothing has been
    /// sampled since the last seek, `pts` is invalid, or every sample kept is
    /// still ahead of `pts`.
    public func sample(atOrBefore pts: Int64) -> Sample? {
        guard MediaTime.isValid(pts) else { return nil }
        return state.withLock { state in
            state.ring.last { $0.pts <= pts }
        }
    }

    /// The newest sample taken, whether or not it is on screen yet.
    public var latestSample: Sample? {
        state.withLock { $0.ring.last }
    }

    /// Drops every sample kept.
    public func flush() {
        state.withLock { $0.ring.removeAll() }
    }

    // MARK: Engine side

    /// Seek flush: drop what is kept and refuse frames older than `serial`.
    func flush(acceptingSerial serial: UInt64) {
        state.withLock { state in
            state.ring.removeAll()
            state.serial = max(state.serial, serial)
        }
    }

    /// Render queue: called with each frame right after it was enqueued.
    /// Costs one lock while disabled.
    func offer(_ frame: VideoFrame) {
        let (enabled, configuration, serial) = state.withLock { ($0.enabled, $0.configuration, $0.serial) }
        guard enabled, frame.serial >= serial, MediaTime.isValid(frame.pts),
              let sample = Self.read(frame.pixelBuffer, pts: frame.pts, configuration: configuration)
        else { return }
        record(sample, serial: frame.serial, configuration: configuration)
    }

    private func record(_ sample: Sample, serial: UInt64, configuration: Configuration) {
        state.withLock { state in
            // Disabled, reconfigured or flushed past while the frame was read.
            guard state.enabled, state.configuration == configuration, serial >= state.serial else { return }
            if serial > state.serial {
                state.serial = serial
                state.ring.removeAll()
            }
            // A timeline that went backwards within one serial: what is kept
            // from "after" it would shadow the new frames.
            if let last = state.ring.last, last.pts >= sample.pts {
                state.ring.removeAll { $0.pts >= sample.pts }
            }
            state.ring.append(sample)
            if state.ring.count > configuration.capacity {
                state.ring.removeFirst(state.ring.count - configuration.capacity)
            }
        }
    }

    // MARK: Reading a buffer

    /// Reads the grid from a 4:2:0 bi-planar buffer (8- or 10-bit, video or
    /// full range); nil for any other layout or a buffer that cannot be
    /// locked.
    static func read(_ buffer: CVPixelBuffer, pts: Int64, configuration: Configuration) -> Sample? {
        guard let layout = PlaneLayout(CVPixelBufferGetPixelFormatType(buffer)),
              CVPixelBufferGetPlaneCount(buffer) == 2
        else { return nil }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard lumaWidth > 0, lumaHeight > 0, chromaWidth > 0, chromaHeight > 0 else { return nil }
        let colorimetry = Colorimetry(buffer, height: lumaHeight)

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        let columns = configuration.columns
        let rows = configuration.rows
        let points = configuration.pointsPerCell
        let perCell = Float(points * points)
        var colors: [Color] = []
        colors.reserveCapacity(columns * rows)

        for row in 0..<rows {
            let top = Double(row) * Double(lumaHeight) / Double(rows)
            let cellHeight = Double(lumaHeight) / Double(rows)
            for column in 0..<columns {
                let left = Double(column) * Double(lumaWidth) / Double(columns)
                let cellWidth = Double(lumaWidth) / Double(columns)
                var red: Float = 0, green: Float = 0, blue: Float = 0
                for pointY in 0..<points {
                    let y = min(Int(top + (Double(pointY) + 0.5) * cellHeight / Double(points)), lumaHeight - 1)
                    let chromaY = min(y / 2, chromaHeight - 1)
                    for pointX in 0..<points {
                        let x = min(Int(left + (Double(pointX) + 0.5) * cellWidth / Double(points)), lumaWidth - 1)
                        let chromaX = min(x / 2, chromaWidth - 1)
                        let luma = layout.read(lumaBase, offset: y * lumaStride + x * layout.bytesPerSample)
                        let chromaOffset = chromaY * chromaStride + chromaX * 2 * layout.bytesPerSample
                        let cb = layout.read(chromaBase, offset: chromaOffset)
                        let cr = layout.read(chromaBase, offset: chromaOffset + layout.bytesPerSample)
                        let linear = colorimetry.linear(
                            luma: layout.normalizedLuma(luma),
                            cb: layout.normalizedChroma(cb),
                            cr: layout.normalizedChroma(cr)
                        )
                        red += linear.red
                        green += linear.green
                        blue += linear.blue
                    }
                }
                colors.append(colorimetry.output(Color(red: red / perCell, green: green / perCell, blue: blue / perCell)))
            }
        }
        return Sample(pts: pts, columns: columns, rows: rows, colors: colors)
    }
}

/// Where a 4:2:0 bi-planar format keeps its code values.
private struct PlaneLayout {
    let bitDepth: Int
    let fullRange: Bool
    /// 1 for 8-bit; 2 for 10-bit, whose value sits in the high bits.
    let bytesPerSample: Int

    init?(_ format: OSType) {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            (bitDepth, fullRange, bytesPerSample) = (8, false, 1)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            (bitDepth, fullRange, bytesPerSample) = (8, true, 1)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            (bitDepth, fullRange, bytesPerSample) = (10, false, 2)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            (bitDepth, fullRange, bytesPerSample) = (10, true, 2)
        default:
            return nil
        }
    }

    func read(_ base: UnsafeMutableRawPointer, offset: Int) -> Int {
        if bytesPerSample == 1 {
            return Int(base.load(fromByteOffset: offset, as: UInt8.self))
        }
        return Int(base.loadUnaligned(fromByteOffset: offset, as: UInt16.self) >> 6)
    }

    private var scale: Float { Float(1 << (bitDepth - 8)) }
    private var maxCode: Float { Float((1 << bitDepth) - 1) }

    /// 0...1 (unclamped).
    func normalizedLuma(_ code: Int) -> Float {
        fullRange ? Float(code) / maxCode : (Float(code) - 16 * scale) / (219 * scale)
    }

    /// −0.5...0.5 (unclamped).
    func normalizedChroma(_ code: Int) -> Float {
        fullRange
            ? (Float(code) - 128 * scale) / maxCode
            : (Float(code) - 128 * scale) / (224 * scale)
    }
}

/// The buffer's colour tags, resolved once per frame.
private struct Colorimetry {
    enum Transfer { case sdr, pq, hlg }

    let kr: Float
    let kb: Float
    let transfer: Transfer
    /// Row-major 3×3 to BT.709 primaries; nil when already BT.709.
    let toBT709: [Float]?

    init(_ buffer: CVPixelBuffer, height: Int) {
        func tag(_ key: CFString) -> String? {
            CVBufferCopyAttachment(buffer, key, nil) as? String
        }
        let matrix = tag(kCVImageBufferYCbCrMatrixKey)
        let is2020 = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        if is2020 {
            (kr, kb) = (0.2627, 0.0593)
        } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String {
            (kr, kb) = (0.2126, 0.0722)
        } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            (kr, kb) = (0.299, 0.114)
        } else if matrix == kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String {
            (kr, kb) = (0.212, 0.087)
        } else {
            // Untagged: what the engine and VideoToolbox assume (see
            // `PixelBufferAttachments`).
            (kr, kb) = height <= 576 ? (0.299, 0.114) : (0.2126, 0.0722)
        }

        let transferFunction = tag(kCVImageBufferTransferFunctionKey)
        if transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            transfer = .pq
        } else if transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            transfer = .hlg
        } else {
            transfer = .sdr
        }

        let primaries = tag(kCVImageBufferColorPrimariesKey)
        if primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String {
            toBT709 = Self.bt2020ToBT709
        } else if primaries == kCVImageBufferColorPrimaries_P3_D65 as String {
            toBT709 = Self.p3ToBT709
        } else if primaries == nil, is2020 {
            // Untagged primaries follow the matrix, as the engine tags them.
            toBT709 = Self.bt2020ToBT709
        } else {
            toBT709 = nil
        }
    }

    private static let bt2020ToBT709: [Float] = [
        1.6605, -0.5876, -0.0728,
        -0.1246, 1.1329, -0.0083,
        -0.0182, -0.1006, 1.1187,
    ]

    private static let p3ToBT709: [Float] = [
        1.2249, -0.2247, 0,
        -0.0420, 1.0419, 0,
        -0.0197, -0.0786, 1.0979,
    ]

    /// One point: Y'CbCr → R'G'B' → linear light, still on the source's
    /// primaries.
    func linear(luma: Float, cb: Float, cr: Float) -> VideoSampleTap.Color {
        let kg = 1 - kr - kb
        let red = luma + 2 * (1 - kr) * cr
        let blue = luma + 2 * (1 - kb) * cb
        let green = (luma - kr * red - kb * blue) / kg
        return VideoSampleTap.Color(red: decode(red), green: decode(green), blue: decode(blue))
    }

    /// A cell's average: onto BT.709 primaries and clamped.
    func output(_ color: VideoSampleTap.Color) -> VideoSampleTap.Color {
        var (red, green, blue) = (color.red, color.green, color.blue)
        if let matrix = toBT709, matrix.count == 9 {
            (red, green, blue) = (
                matrix[0] * red + matrix[1] * green + matrix[2] * blue,
                matrix[3] * red + matrix[4] * green + matrix[5] * blue,
                matrix[6] * red + matrix[7] * green + matrix[8] * blue
            )
        }
        return VideoSampleTap.Color(red: clamp(red), green: clamp(green), blue: clamp(blue))
    }

    private func decode(_ value: Float) -> Float {
        let signal = clamp(value)
        switch transfer {
        case .sdr:
            return powf(signal, 2.2)
        case .pq:
            // SMPTE ST 2084 EOTF, scaled so 203 nits (SDR reference white) is 1.
            let m1: Float = 0.1593017578125, m2: Float = 78.84375
            let c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
            let power = powf(signal, 1 / m2)
            let nits = powf(max(power - c1, 0) / (c2 - c3 * power), 1 / m1) * 10_000
            return clamp(nits / 203)
        case .hlg:
            // BT.2100 inverse OETF, scaled so reference white (75 % signal,
            // ≈ 0.265 scene light) is 1.
            let a: Float = 0.17883277, b: Float = 0.28466892, c: Float = 0.55991073
            let scene = signal <= 0.5 ? signal * signal / 3 : (expf((signal - c) / a) + b) / 12
            return clamp(scene / 0.265)
        }
    }

    private func clamp(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
