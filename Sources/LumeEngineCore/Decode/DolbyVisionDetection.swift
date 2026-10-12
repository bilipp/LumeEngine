internal import CFFmpeg

/// Decides, frame by frame, whether a Dolby Vision frame's base layer is
/// IPTPQc2 — and so has to go through `DolbyVisionConverter` — or is a
/// displayable signal (HDR10, SDR, HLG) that must stay as decoded.
///
/// The stream's configuration record alone is not enough to decide. It is a
/// claim made once at mux time, and live sources break it: remuxes label
/// HDR10-compatible streams as profile 5, and broadcasts drop the RPUs (or
/// splice plain HDR10 between Dolby Vision programmes) without changing it.
/// Converting such a frame as IPT turns correct HDR10 into wrong colours.
/// FFmpeg makes it worse for HEVC: its decoder attaches the *last* RPU's
/// metadata to every frame that follows, RPU or not, so the metadata's mere
/// presence proves nothing either.
///
/// So the frame's own evidence decides, strongest first:
/// 1. A frame tagged `AVCOL_SPC_IPT_C2` is IPT. That matrix code point exists
///    for this signal alone; nothing else writes it.
/// 2. A frame that carries its own RPU is what the RPU says. Its display
///    management block states the signal's colour space (`signal_color_space`:
///    0 YCbCr, 1 RGB, 2 IPT), which is the field that actually tells profile
///    5's base layer from profile 8's — both run through the same reshaping
///    syntax, and the configuration record says nothing about the frame.
/// 3. A frame without an RPU of its own that is tagged with a matrix is that
///    matrix: BT.2020 PQ without an RPU is HDR10, whatever the record claims.
/// 4. Only a frame with no RPU of its own *and* no colour tag falls back to
///    the record. That is a genuine profile 5 encode — many leave the VUI
///    matrix unspecified — whose RPU for this frame was lost, and the
///    previous RPU still describes it.
///
/// HDR10-compatible profiles (8.1, 10.1, …) carry RPUs that say YCbCr, so
/// they stay on the zero-copy path exactly as before.
enum DolbyVisionDetection {
    /// What the stream's Dolby Vision configuration record claims.
    struct Record: Sendable, Equatable {
        var profile: UInt8
        var compatibilityID: UInt8

        /// Profiles 5, 10.0 and 20 declare an IPTPQc2 base layer. Profile 4
        /// also reports compatibility ID 0, but its base layer is SDR plus an
        /// enhancement layer this path does not decode.
        var claimsIPT: Bool {
            compatibilityID == 0 && [5, 10, 20].contains(profile)
        }
    }

    /// The frame's YCbCr matrix as its colour description states it.
    enum Matrix: Sendable, Equatable {
        case iptC2
        /// No colour description, or one that leaves the matrix open.
        case unspecified
        /// Any other matrix the stream states (BT.2020, BT.709, …).
        case stated
    }

    /// What the frame says about its RPU.
    enum RPU: Sendable, Equatable {
        /// No Dolby Vision metadata at all: nothing to convert with.
        case none
        /// Metadata FFmpeg carried over from an earlier frame's RPU; this
        /// frame brought none of its own.
        case carriedOver
        /// The frame's own RPU, with the colour space its display management
        /// block states for the signal.
        case own(signalColorSpace: UInt8)
    }

    /// `signal_color_space` value for IPT (ETSI GS CCM 001; FFmpeg passes the
    /// bitstream's two bits through).
    static let iptSignalColorSpace: UInt8 = 2

    /// The decision itself, pure so it is testable without a stream.
    static func baseLayerIsIPT(record: Record?, matrix: Matrix, rpu: RPU) -> Bool {
        switch (rpu, matrix) {
        case (.none, _):
            return false
        case (_, .iptC2):
            return true
        case (.own(let signalColorSpace), _):
            return signalColorSpace == iptSignalColorSpace
        case (.carriedOver, .stated):
            return false
        case (.carriedOver, .unspecified):
            return record?.claimsIPT ?? false
        }
    }
}

// MARK: - Evidence from FFmpeg

extension DolbyVisionDetection.Record {
    /// The stream's configuration record (`dvcC`/`dvvC`, the Matroska block
    /// addition mapping, or a TS descriptor), if it has one.
    init?(_ parameters: UnsafePointer<AVCodecParameters>) {
        guard let sideData = av_packet_side_data_get(
            parameters.pointee.coded_side_data,
            parameters.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        ), let bytes = sideData.pointee.data,
           sideData.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        else { return nil }
        let record = UnsafeRawPointer(bytes).loadUnaligned(as: AVDOVIDecoderConfigurationRecord.self)
        self.init(profile: record.dv_profile, compatibilityID: record.dv_bl_signal_compatibility_id)
    }
}

extension DolbyVisionDetection.Matrix {
    init(_ colorSpace: AVColorSpace) {
        switch colorSpace {
        case AVCOL_SPC_IPT_C2: self = .iptC2
        case AVCOL_SPC_UNSPECIFIED, AVCOL_SPC_RESERVED: self = .unspecified
        default: self = .stated
        }
    }
}

extension DolbyVisionDetection.RPU {
    /// Classifies a decoded frame's Dolby Vision side data.
    ///
    /// HEVC: FFmpeg attaches the raw RPU (`AV_FRAME_DATA_DOVI_RPU_BUFFER`) only
    /// to the frame whose access unit carried it, but the parsed metadata to
    /// every frame after it — so the raw buffer is what marks an RPU as the
    /// frame's own. AV1 carries the RPU in a metadata OBU and FFmpeg attaches
    /// the parsed metadata only to that frame, without a raw buffer, so there
    /// the metadata is always the frame's own.
    init(frame: UnsafePointer<AVFrame>, codecID: AVCodecID) {
        guard let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA),
              let bytes = sideData.pointee.data
        else {
            self = .none
            return
        }
        let ownRPU = codecID != AV_CODEC_ID_HEVC
            || av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER) != nil
        guard ownRPU else {
            self = .carriedOver
            return
        }
        let metadata = UnsafeRawPointer(bytes).assumingMemoryBound(to: AVDOVIMetadata.self)
        guard let color = av_dovi_get_color(metadata) else {
            self = .carriedOver
            return
        }
        self = .own(signalColorSpace: color.pointee.signal_color_space)
    }
}
