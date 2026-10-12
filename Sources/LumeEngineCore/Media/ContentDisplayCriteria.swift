import CoreMedia
import CoreVideo
import Foundation

/// The display mode a session's video wants: refresh rate and dynamic range,
/// as an Apple TV with Match Content switches the TV for it.
///
/// Describes what the engine *outputs*, which is not what the container says.
/// The deinterlacer at field rate turns 1080i50 into 50p, so the TV should
/// run at 50 Hz, not 25; Dolby Vision with an IPT base layer (profiles 5,
/// 10.0, 20) is converted to HDR10 before it is enqueued, so the TV should be
/// in HDR10, not Dolby Vision. Frames the renderer has been handed decide when
/// there are any (`basis == .output`); before that the stream's own metadata,
/// with the deinterlacer's effect predicted, stands in (`.stream`).
///
/// Cross-platform and pure: tvOS applies it with `DisplayCriteriaMatcher`,
/// anything else can log or show it.
public struct ContentDisplayCriteria: Sendable, Equatable, CustomStringConvertible {
    public enum DynamicRange: String, Sendable {
        case sdr
        case hdr10
        case hlg
        case dolbyVision
    }

    /// What the criteria were derived from.
    public enum Basis: String, Sendable {
        /// Stream metadata, with the deinterlacer's effect predicted.
        case stream
        /// Frames handed to the renderer: their colour tags and measured
        /// cadence.
        case output
    }

    /// The refresh rate to ask for: one of the film and broadcast rates
    /// (23.976, 24, 25, 29.97, 30, 50, 59.94, 60 — NTSC rates exact, e.g.
    /// 24000/1001). Nil when the content's rate is unknown or off that grid
    /// (variable, 12.5, 48, 100 fps): a TV asked for an odd rate either
    /// refuses or picks something worse than the mode it is already in.
    public let refreshRate: Double?
    public let dynamicRange: DynamicRange
    public let width: Int
    public let height: Int
    public let basis: Basis

    // Ingredients of `makeFormatDescription()`.
    let codecType: CMVideoCodecType
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let masteringDisplayColorVolume: Data?
    let contentLightLevel: Data?
    let dolbyVision: DolbyVisionConfiguration?

    /// Whether the two ask the TV for the same mode — the only thing that
    /// decides whether applying one after the other switches the TV again.
    public func asksForSameMode(as other: ContentDisplayCriteria) -> Bool {
        refreshRate == other.refreshRate && dynamicRange == other.dynamicRange
    }

    public var description: String {
        let rate = refreshRate.map { String(format: "%.3gHz", $0) } ?? "anyHz"
        return "\(rate)/\(dynamicRange.rawValue)(\(basis.rawValue))"
    }

    /// A video format description carrying these criteria, for
    /// `AVDisplayCriteria(refreshRate:formatDescription:)`. Colour tags come
    /// from the enqueued frames when there are any. Dolby Vision is signalled
    /// the way a `dvh1` sample entry signals it: that codec type plus the
    /// configuration record's box. The codec type is `dvh1` whatever the base
    /// layer's codec, because the description exists only to select a display
    /// mode, and that is the type the system knows Dolby Vision by.
    public func makeFormatDescription() -> CMVideoFormatDescription? {
        var extensions: [CFString: Any] = [:]
        if let colorPrimaries { extensions[kCMFormatDescriptionExtension_ColorPrimaries] = colorPrimaries }
        if let transferFunction { extensions[kCMFormatDescriptionExtension_TransferFunction] = transferFunction }
        if let yCbCrMatrix { extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = yCbCrMatrix }
        if let masteringDisplayColorVolume {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = masteringDisplayColorVolume
        }
        if let contentLightLevel {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = contentLightLevel
        }
        if dynamicRange == .dolbyVision, let dolbyVision {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [
                dolbyVision.boxType: dolbyVision.boxPayload,
            ]
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(clamping: width),
            height: Int32(clamping: height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }
}

// MARK: - Resolution

extension ContentDisplayCriteria {
    /// What the stream says about itself (from `TrackInfo`).
    struct Stream: Sendable, Equatable {
        var codecName: String
        var width: Int
        var height: Int
        /// Frames per second as the container guesses it; 0 when unknown.
        var frameRate: Double
        var isInterlaced: Bool?
        /// Raw transfer characteristics (ITU-T H.273 code point).
        var colorTransfer: UInt32
        var dolbyVision: DolbyVisionConfiguration?

        init(
            codecName: String,
            width: Int,
            height: Int,
            frameRate: Double,
            isInterlaced: Bool? = nil,
            colorTransfer: UInt32 = 2,
            dolbyVision: DolbyVisionConfiguration? = nil
        ) {
            self.codecName = codecName
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.isInterlaced = isInterlaced
            self.colorTransfer = colorTransfer
            self.dolbyVision = dolbyVision
        }

        init?(track: TrackInfo) {
            guard let video = track.video else { return nil }
            self.init(
                codecName: track.codecName,
                width: video.width,
                height: video.height,
                frameRate: video.fps,
                isInterlaced: video.isInterlaced,
                colorTransfer: video.colorTransfer,
                dolbyVision: video.dolbyVision
            )
        }
    }

    /// What the renderer has actually been handed.
    struct Output: Sendable, Equatable {
        var width: Int
        var height: Int
        var colorPrimaries: String?
        var transferFunction: String?
        var yCbCrMatrix: String?
        var masteringDisplayColorVolume: Data?
        var contentLightLevel: Data?
        /// Measured interval between frames, engine µs; nil until known.
        var frameInterval: Double?
        /// Frames are going through the deinterlacer.
        var isDeinterlacing: Bool

        init(
            width: Int,
            height: Int,
            colorPrimaries: String? = nil,
            transferFunction: String? = nil,
            yCbCrMatrix: String? = nil,
            masteringDisplayColorVolume: Data? = nil,
            contentLightLevel: Data? = nil,
            frameInterval: Double? = nil,
            isDeinterlacing: Bool = false
        ) {
            self.width = width
            self.height = height
            self.colorPrimaries = colorPrimaries
            self.transferFunction = transferFunction
            self.yCbCrMatrix = yCbCrMatrix
            self.masteringDisplayColorVolume = masteringDisplayColorVolume
            self.contentLightLevel = contentLightLevel
            self.frameInterval = frameInterval
            self.isDeinterlacing = isDeinterlacing
        }

        /// Reads the tags the enqueued frames carried into their format
        /// description (pixel buffer attachments propagate into it).
        init(formatDescription: CMFormatDescription, frameInterval: Double?, isDeinterlacing: Bool) {
            func string(_ key: CFString) -> String? {
                CMFormatDescriptionGetExtension(formatDescription, extensionKey: key) as? String
            }
            func data(_ key: CFString) -> Data? {
                CMFormatDescriptionGetExtension(formatDescription, extensionKey: key) as? Data
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            self.init(
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                colorPrimaries: string(kCMFormatDescriptionExtension_ColorPrimaries),
                transferFunction: string(kCMFormatDescriptionExtension_TransferFunction),
                yCbCrMatrix: string(kCMFormatDescriptionExtension_YCbCrMatrix),
                masteringDisplayColorVolume: data(kCMFormatDescriptionExtension_MasteringDisplayColorVolume),
                contentLightLevel: data(kCMFormatDescriptionExtension_ContentLightLevelInfo),
                frameInterval: frameInterval,
                isDeinterlacing: isDeinterlacing
            )
        }
    }

    /// The criteria for a stream, refined by its output once there is any.
    static func resolve(
        stream: Stream,
        deinterlacing: VideoDecoder.Deinterlacing,
        output: Output?
    ) -> ContentDisplayCriteria {
        let frameRate: Double
        let basis: Basis
        if let interval = output?.frameInterval, interval > 0 {
            // The cadence of what is enqueued already includes whatever the
            // deinterlacer did to it.
            frameRate = Double(MediaTime.timeBase) / interval
            basis = .output
        } else {
            let deinterlaced = output?.isDeinterlacing ?? willDeinterlace(stream, deinterlacing)
            let fieldRate = deinterlaced && deinterlacing.rate == .field
            frameRate = stream.frameRate * (fieldRate ? 2 : 1)
            basis = .stream
        }

        let range = dynamicRange(stream: stream, output: output)
        let tags = output.map {
            ColorTags(primaries: $0.colorPrimaries, transfer: $0.transferFunction, matrix: $0.yCbCrMatrix)
        } ?? ColorTags.canonical(for: range)

        return ContentDisplayCriteria(
            refreshRate: nominalRefreshRate(for: frameRate),
            dynamicRange: range,
            width: output?.width ?? stream.width,
            height: output?.height ?? stream.height,
            basis: basis,
            codecType: codecType(codecName: stream.codecName, range: range),
            colorPrimaries: tags.primaries,
            transferFunction: tags.transfer,
            yCbCrMatrix: tags.matrix,
            masteringDisplayColorVolume: output?.masteringDisplayColorVolume,
            contentLightLevel: output?.contentLightLevel,
            dolbyVision: range == .dolbyVision ? stream.dolbyVision : nil
        )
    }

    /// Before the first frame: whether the deinterlacer is going to engage.
    /// `.auto` engages on the first frame the decoder flags interlaced, which
    /// the stream's field order predicts; an unknown field order predicts
    /// progressive, the common case.
    private static func willDeinterlace(_ stream: Stream, _ policy: VideoDecoder.Deinterlacing) -> Bool {
        switch policy.mode {
        case .off: false
        case .always: true
        case .auto: stream.isInterlaced == true
        }
    }

    /// Dolby Vision decides first: an IPT base layer is converted to HDR10;
    /// any other Dolby Vision stream (8.1's HDR10 base, 8.4's HLG base, …)
    /// keeps asking for Dolby Vision, the mode its RPU was mastered for, and
    /// the system maps the base layer into it. Otherwise the transfer function
    /// of what is enqueued decides, or the stream's before there is any.
    static func dynamicRange(stream: Stream, output: Output?) -> DynamicRange {
        if let dolbyVision = stream.dolbyVision {
            return dolbyVision.baseLayerIsIPT ? .hdr10 : .dolbyVision
        }
        if let output {
            // An untagged frame is shown as SDR, so it is SDR.
            let transfer = output.transferFunction
            if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return .hdr10 }
            if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return .hlg }
            return .sdr
        }
        // H.273 transfer characteristics, which FFmpeg's enum mirrors:
        // 16 is SMPTE ST 2084 (PQ), 18 is ARIB STD-B67 (HLG).
        switch stream.colorTransfer {
        case 16: return .hdr10
        case 18: return .hlg
        default: return .sdr
        }
    }

    // MARK: Refresh rates

    /// The rates an Apple TV offers a TV: film, PAL and NTSC, at frame and
    /// field rate.
    static let nominalRefreshRates: [Double] = [
        24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60,
    ]

    /// Relative distance within which a measured rate counts as nominal.
    /// Wide enough for timestamp jitter, narrow enough that nothing between
    /// two grid rates (25.5, 48) is pulled onto one. 23.976 and 24 are 0.1 %
    /// apart; nearest-wins keeps them apart.
    static let refreshRateTolerance = 0.005

    static func nominalRefreshRate(for frameRate: Double) -> Double? {
        guard frameRate.isFinite, frameRate > 0 else { return nil }
        guard let nearest = nominalRefreshRates.min(by: { abs($0 - frameRate) < abs($1 - frameRate) }),
              abs(nearest - frameRate) / nearest <= refreshRateTolerance
        else { return nil }
        return nearest
    }

    // MARK: Format description ingredients

    private struct ColorTags {
        var primaries: String?
        var transfer: String?
        var matrix: String?

        /// What a stream of that range is tagged as, for the criteria built
        /// before any frame exists.
        static func canonical(for range: DynamicRange) -> ColorTags {
            switch range {
            case .sdr:
                ColorTags(
                    primaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                    transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                    matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
                )
            case .hdr10, .dolbyVision:
                ColorTags(
                    primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                    transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
                    matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
                )
            case .hlg:
                ColorTags(
                    primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                    transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                    matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
                )
            }
        }
    }

    /// The sample entry type of the stream's codec. The display mode does not
    /// depend on it; a familiar type keeps the description ordinary, so an
    /// unknown codec is described as H.264.
    static func codecType(codecName: String, range: DynamicRange) -> CMVideoCodecType {
        if range == .dolbyVision { return kCMVideoCodecType_DolbyVisionHEVC }
        switch codecName {
        case "hevc": return kCMVideoCodecType_HEVC
        case "av1": return kCMVideoCodecType_AV1
        case "vp9": return kCMVideoCodecType_VP9
        case "mpeg2video": return kCMVideoCodecType_MPEG2Video
        default: return kCMVideoCodecType_H264
        }
    }
}
