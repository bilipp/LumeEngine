internal import CFFmpeg

/// Speaker positions in FFmpeg's native channel-mask bit order (`AV_CH_*`),
/// which is also WAVE order and Core Audio's `AudioChannelBitmap` for bits
/// 0...17. Kept free of FFmpeg types so the layout policy is testable as plain
/// values.
struct SpeakerSet: OptionSet, Hashable, Sendable {
    let rawValue: UInt64

    static let frontLeft = SpeakerSet(rawValue: 1 << 0)
    static let frontRight = SpeakerSet(rawValue: 1 << 1)
    static let frontCenter = SpeakerSet(rawValue: 1 << 2)
    static let lowFrequency = SpeakerSet(rawValue: 1 << 3)
    static let backLeft = SpeakerSet(rawValue: 1 << 4)
    static let backRight = SpeakerSet(rawValue: 1 << 5)
    static let sideLeft = SpeakerSet(rawValue: 1 << 9)
    static let sideRight = SpeakerSet(rawValue: 1 << 10)

    static let mono: SpeakerSet = [.frontCenter]
    static let stereo: SpeakerSet = [.frontLeft, .frontRight]
    /// 5.1 with the surrounds on the side pair (`AV_CH_LAYOUT_5POINT1`,
    /// "5.1(side)"): the layout the AC-3 and E-AC-3 decoders — most surround
    /// on IPTV — already hand the renderer.
    static let surround51: SpeakerSet = [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight]
    static let surround71: SpeakerSet = surround51.union([.backLeft, .backRight])

    /// Positions a format description can name with a channel bitmap
    /// (`SampleBufferBuilder`). Anything outside reaches the renderer without
    /// a layout, and the renderer cannot place untagged multichannel audio.
    static let bitmapExpressible = SpeakerSet(rawValue: 0x3FFFF)

    var count: Int { rawValue.nonzeroBitCount }
}

/// What the audio lane hands the renderer, for diagnostics: the source's
/// channel count, the count after the engine's remix, and the route width the
/// remix was chosen for.
public struct AudioOutputLayout: Sendable, Equatable, CustomStringConvertible {
    public let sourceChannels: Int
    public let outputChannels: Int
    public let routeChannels: Int

    /// The engine folds the source down to fit the route.
    public var isDownmixed: Bool { outputChannels < sourceChannels }

    public var description: String {
        "\(sourceChannels)>\(outputChannels)ch@\(routeChannels)"
    }
}

/// Which speaker layout the engine hands the audio renderer, given the
/// source's layout and how many channels the output route carries.
///
/// The route width is the audio session's *negotiated* output
/// (`AVAudioSession.outputNumberOfChannels`), not what the hardware could do:
/// handing `AVSampleBufferAudioRenderer` more channels than the session
/// outputs failed it outright on tvOS — silence and a wedged pipeline — which
/// is why the engine mixes instead of leaving it to the system (see
/// `AudioOutputRoute`).
///
/// Pure value logic: the decoder asks it once per source format and route
/// width, and swresample does what it says.
enum AudioLayoutPolicy {
    struct Plan: Equatable, Sendable {
        /// Speakers the renderer receives.
        let output: SpeakerSet
        /// The engine mixes the channels (down, or mono up to stereo) rather
        /// than passing them through as decoded.
        let remixes: Bool
    }

    /// - Parameters:
    ///   - source: the decoded layout, resolved to native positions.
    ///   - routeChannels: channels the output route carries.
    static func plan(source: SpeakerSet, routeChannels: Int) -> Plan {
        let route = max(1, routeChannels)
        let channels = source.count

        // A lone centre channel is placed on two speakers by the engine, not
        // by whatever the route does with a centre it may not have: a stereo
        // pair (two HomePods, a TV's speakers) has no centre speaker at all.
        // Equal power on each side, the standard pan law.
        if source == .mono, route >= 2 {
            return Plan(output: .stereo, remixes: true)
        }

        // Fits the route and the renderer can name every channel: hand it
        // over untouched. A receiver on HDMI gets discrete surround.
        if channels <= route, source.isSubset(of: .bitmapExpressible) {
            return Plan(output: source, remixes: false)
        }

        // Fold down to the widest standard layout both the route and the
        // source fill. A layout the renderer cannot name (wide or top
        // channels, a matrix-encoded stereo pair) is remixed to the standard
        // one of its own width rather than passed through untagged.
        let width = min(route, channels)
        var target: SpeakerSet = width >= 8 ? .surround71
            : width >= 6 ? .surround51
            : width >= 2 ? .stereo
            : .mono
        // Never invent an LFE channel the source does not have.
        if !source.contains(.lowFrequency) {
            target.remove(.lowFrequency)
        }
        return Plan(output: target, remixes: true)
    }
}

/// The coefficients the engine's remix uses, built by swresample's own
/// matrix builder with the levels below.
///
/// Levels follow ITU-R BS.775 fold-down: centre and surrounds at −3 dB into
/// their front side, LFE omitted (it carries nothing a stereo programme needs,
/// and full-range speakers rarely reproduce it). The dialogue channel thus
/// always reaches both front speakers — the failure this exists to prevent is
/// a downmix that drops channels instead of mixing them, which loses the
/// centre and with it the dialogue.
///
/// The matrix is not normalized, matching what swresample does on its own for
/// float output: a 5.1 fold-down plays as loud as a stereo channel next to it
/// on the same IPTV list. Normalizing would make every surround channel
/// ~7.7 dB quieter than its stereo neighbours, which viewers hear as a volume
/// jump on every zap; the cost is that peaks where every channel is near full
/// scale at once can exceed 1.0 and clip at the output.
enum DownmixMatrix {
    static let centerLevel = 0.707_106_781_186_547_6
    static let surroundLevel = 0.707_106_781_186_547_6
    static let lfeLevel = 0.0

    /// swresample's matrix bound (`SWR_CH_MAX`); its builder walks the full
    /// square, so the buffer must span it whatever the layouts are.
    static let stride = 64

    /// Row-major coefficients, `[output][input]`, in native channel order;
    /// nil when swresample cannot build a matrix between the two layouts
    /// (e.g. a source without any front channel).
    static func coefficients(from source: SpeakerSet, to output: SpeakerSet) -> [[Double]]? {
        guard let flat = flatCoefficients(from: source, to: output) else { return nil }
        return (0..<output.count).map { row in
            Array(flat[(row * stride)..<(row * stride + source.count)])
        }
    }

    /// The matrix in the shape `swr_set_matrix` takes (stride `stride`).
    static func flatCoefficients(from source: SpeakerSet, to output: SpeakerSet) -> [Double]? {
        var inputLayout = AVChannelLayout()
        var outputLayout = AVChannelLayout()
        defer {
            av_channel_layout_uninit(&inputLayout)
            av_channel_layout_uninit(&outputLayout)
        }
        guard av_channel_layout_from_mask(&inputLayout, source.rawValue) >= 0,
              av_channel_layout_from_mask(&outputLayout, output.rawValue) >= 0
        else { return nil }

        var matrix = [Double](repeating: 0, count: stride * stride)
        let result = matrix.withUnsafeMutableBufferPointer { buffer in
            swr_build_matrix2(
                &inputLayout, &outputLayout,
                centerLevel, surroundLevel, lfeLevel,
                Double(Int32.max), // no normalization, see the type docs
                1.0, buffer.baseAddress, stride,
                AV_MATRIX_ENCODING_NONE, nil
            )
        }
        return result >= 0 ? matrix : nil
    }
}
