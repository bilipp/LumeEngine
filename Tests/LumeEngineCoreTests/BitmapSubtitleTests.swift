import CoreGraphics
import Foundation
import Testing
@testable import LumeEngineCore

/// Reads one pixel of a `SubtitleBitmap` image as (r, g, b, a), premultiplied.
private func pixel(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    let offset = y * image.bytesPerRow + x * 4
    guard offset + 4 <= data.count else { return nil }
    // byteOrder32Little + premultipliedFirst: B, G, R, A in memory.
    return (Int(data[offset + 2]), Int(data[offset + 1]), Int(data[offset]), Int(data[offset + 3]))
}

@Suite("Bitmap subtitle conversion")
struct BitmapSubtitleConversionTests {
    @Test("palette colours are premultiplied")
    func premultiply() {
        #expect(SubtitleBitmap.premultiply(0xFF_FF_FF_FF) == 0xFF_FF_FF_FF)
        #expect(SubtitleBitmap.premultiply(0x00_FF_FF_FF) == 0)
        // Half-transparent red: colour scaled by alpha, alpha kept.
        #expect(SubtitleBitmap.premultiply(0x80_FF_00_00) == 0x80_80_00_00)
        #expect(SubtitleBitmap.premultiply(0x40_80_40_20) == 0x40_20_10_08)
    }

    @Test("indexed rows honour the stride; indices past the palette are transparent")
    func indexedPixels() {
        // Two rows of three pixels, stride four (one byte of padding each).
        let indices: [UInt8] = [0, 1, 2, 9, 2, 1, 7, 9]
        let palette: [UInt32] = [0x00_00_00_00, 0xFF_FF_FF_FF, 0x80_FF_00_00]
        let pixels = indices.withUnsafeBufferPointer {
            SubtitleBitmap.premultipliedPixels(indices: $0, width: 3, height: 2, stride: 4, palette: palette)
        }
        #expect(pixels == [0, 0xFF_FF_FF_FF, 0x80_80_00_00, 0x80_80_00_00, 0xFF_FF_FF_FF, 0])
    }

    @Test("an image round-trips as premultiplied BGRA")
    func imageLayout() throws {
        let image = try #require(SubtitleBitmap.makeImage(pixels: [0xFF_FF_FF_FF, 0x80_80_00_00], width: 2, height: 1))
        #expect(image.width == 2 && image.height == 1)
        #expect(image.alphaInfo == .premultipliedFirst)
        let white = try #require(pixel(of: image, x: 0, y: 0))
        #expect(white == (255, 255, 255, 255))
        let red = try #require(pixel(of: image, x: 1, y: 0))
        #expect(red == (128, 0, 0, 128))
    }

    @Test("rects are normalized to the authoring canvas")
    func normalizedRect() {
        let rect = SubtitleBitmap.normalizedRect(x: 480, y: 900, width: 960, height: 108, canvasWidth: 1920, canvasHeight: 1080)
        #expect(rect == CGRect(x: 0.25, y: 0.8333333333333334, width: 0.5, height: 0.1))
        #expect(SubtitleBitmap.normalizedRect(x: 0, y: 0, width: 1, height: 1, canvasWidth: 0, canvasHeight: 0) == .zero)
    }

    private func image(width: Int, height: Int) throws -> SubtitleImage {
        let image = try #require(SubtitleBitmap.makeImage(
            pixels: [UInt32](repeating: 0xFF_FF_FF_FF, count: width * height), width: width, height: height
        ))
        return SubtitleImage(image: image, rect: CGRect(x: 0.4, y: 0.9, width: 0.1, height: 0.05))
    }

    @Test("a bitmap update is a cue, not a clear, and a re-read does not double it")
    func bitmapCuesInTimeline() throws {
        var timeline = SubtitleTimeline()
        let bitmap = try image(width: 8, height: 4)
        timeline.apply(SubtitleEvent(start: 1_000_000, end: nil, text: "", replacesPrevious: true, images: [bitmap]))
        timeline.apply(SubtitleEvent(start: 3_000_000, end: nil, text: "", replacesPrevious: true))
        let shown = timeline.activeCues(at: 2_000_000)
        #expect(shown.count == 1)
        #expect(shown.first?.images.map(\.rect) == [bitmap.rect])
        #expect(shown.first?.text == "")
        #expect(timeline.activeCues(at: 3_000_000).isEmpty)

        // The same update decoded again makes a new CGImage of the same size.
        let again = try image(width: 8, height: 4)
        timeline.apply(SubtitleEvent(start: 1_000_000, end: nil, text: "", replacesPrevious: true, images: [again]))
        #expect(timeline.count == 1)
    }

    @Test("bitmap memory is bounded, dropping the oldest cues")
    func imageBudget() throws {
        var timeline = SubtitleTimeline()
        // 1 MB per cue: the budget holds 64 of them.
        let bitmap = try image(width: 512, height: 512)
        for index in 0..<100 {
            timeline.apply(SubtitleEvent(
                start: Int64(index) * 1_000_000, end: nil, text: "", replacesPrevious: true, images: [bitmap]
            ))
        }
        #expect(timeline.imageBytes <= SubtitleTimeline.imageByteBudget)
        #expect(timeline.count == SubtitleTimeline.imageByteBudget / bitmap.byteCount)
        #expect(timeline.activeCues(at: 99_500_000).count == 1)
        #expect(timeline.activeCues(at: 500_000).isEmpty)
        timeline.removeAll()
        #expect(timeline.imageBytes == 0)
    }
}

@Suite("Bitmap subtitles in playback", .serialized)
struct BitmapSubtitlePlaybackTests {
    private func eventually(
        timeout: TimeInterval = 10,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// The fixtures carry the same two bitmaps (see `generate-fixtures.sh`):
    /// 64x16 at (928, 1000) for 1–3 s, 48x8 at (936, 960) for 4–6 s, on a
    /// 1920x1080 canvas over a 320x180 video — so a canvas taken from the
    /// video instead of the subtitle would put them far off screen.
    @Test(
        "bitmap subtitles become positioned image cues",
        .timeLimit(.minutes(1)),
        arguments: ["pgs.mkv", "dvbsub.ts", "dvdsub.mkv"]
    )
    func bitmapCues(fixture: String) async throws {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        let session = PlayerSession(configuration: configuration)
        let info = try await session.open(url: try Fixtures.path(fixture))
        let track = try #require(info.subtitleTracks.first)

        await session.selectSubtitleTrack(track.index)
        let start = info.startTime
        let decoded = await eventually {
            session.subtitles.activeCues(at: start + 5_000_000).first?.images.isEmpty == false
        }
        #expect(decoded, "\(fixture): cues should decode, store has \(session.subtitles.count)")

        let first = try #require(session.subtitles.activeCues(at: start + 2_000_000).first, "\(fixture): first cue")
        #expect(first.text.isEmpty, "bitmap cues carry no text, so text consumers show nothing")
        let image = try #require(first.images.first)
        #expect(first.images.count == 1)
        #expect(abs(first.start - (start + 1_000_000)) <= 40_000, "\(fixture): starts at \(first.start - start)")
        #expect(abs(first.end - (start + 3_000_000)) <= 40_000, "\(fixture): ends at \(first.end - start)")

        // Decoders may crop fully transparent borders (FFmpeg's DVD decoder
        // drops the 8 transparent columns); the visible part must still land
        // within a few canvas pixels of the original.
        let tolerance = 4.0 / 1080
        #expect(abs(image.rect.maxX - 992.0 / 1920) <= tolerance, "\(fixture): \(image.rect)")
        #expect(abs(image.rect.maxY - 1016.0 / 1080) <= tolerance, "\(fixture): \(image.rect)")
        #expect(image.rect.minX >= 928.0 / 1920 - tolerance, "\(fixture): \(image.rect)")
        #expect(image.rect.minX <= 936.0 / 1920 + tolerance, "\(fixture): \(image.rect)")
        #expect(abs(image.rect.minY - 1000.0 / 1080) <= tolerance, "\(fixture): \(image.rect)")
        #expect(image.image.width == Int((image.rect.width * 1920).rounded()), "\(fixture): one image pixel per canvas pixel")

        // Column 2 is transparent, column 16 opaque white, column 48
        // half-transparent red (premultiplied). The DVB and DVD encoders
        // requantize the palette, hence the tolerances.
        let offsetX = Int(((image.rect.minX - 928.0 / 1920) * 1920).rounded())
        let offsetY = Int(((image.rect.minY - 1000.0 / 1080) * 1080).rounded())
        let row = 8 - offsetY
        if offsetX <= 2 {
            let clear = try #require(pixel(of: image.image, x: 2 - offsetX, y: row))
            #expect(clear.a <= 16, "\(fixture): \(clear)")
        }
        let white = try #require(pixel(of: image.image, x: 16 - offsetX, y: row))
        #expect(white.a >= 240 && white.r >= 220 && white.g >= 220 && white.b >= 220, "\(fixture): \(white)")
        let red = try #require(pixel(of: image.image, x: 48 - offsetX, y: row))
        #expect((100...160).contains(red.a) && red.r >= red.a - 30 && red.g <= 30 && red.b <= 30, "\(fixture): \(red)")
        #expect(red.r <= red.a, "\(fixture): premultiplied colour never exceeds alpha")

        #expect(session.subtitles.activeCues(at: start + 3_500_000).isEmpty, "\(fixture): cleared at 3 s")
        let second = try #require(session.subtitles.activeCues(at: start + 5_000_000).first?.images.first)
        #expect(abs(second.rect.width - 48.0 / 1920) <= tolerance, "\(fixture): \(second.rect)")
        #expect(session.subtitles.activeCues(at: start + 6_500_000).isEmpty, "\(fixture): cleared at 6 s")

        await session.shutdown()
    }
}
