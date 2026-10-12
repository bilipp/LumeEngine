internal import CFFmpeg
import CoreGraphics
import Foundation

/// One bitmap of a DVB, PGS or DVD subtitle, ready to draw over the video.
///
/// `rect` is normalized to the picture the subtitle was authored for: (0, 0)
/// is the top-left corner of the video, (1, 1) the bottom-right, so a host
/// draws the image at `rect` scaled by the size of the video's display area
/// (after aspect fitting). The authoring canvas — a DVB display definition
/// (720×576 without one), a PGS presentation's video size, a DVD's `size:` —
/// need not match the stream's pixel size; normalizing makes that moot.
public struct SubtitleImage: Sendable, Equatable {
    /// Premultiplied RGBA in sRGB.
    public let image: CGImage
    /// Position and size as fractions of the video picture.
    public let rect: CGRect

    public init(image: CGImage, rect: CGRect) {
        self.image = image
        self.rect = rect
    }

    /// Memory the bitmap holds, for the store's budget.
    var byteCount: Int { image.bytesPerRow * image.height }
}

/// Palette-indexed `SUBTITLE_BITMAP` rects to `SubtitleImage`s.
enum SubtitleBitmap {
    /// The canvas when a decoder reports none — DVB's own default (ETSI EN
    /// 300 743), and the PAL DVD frame; NTSC DVDs carry their size.
    static let fallbackCanvas = (width: 720, height: 576)

    /// The images of one decoded subtitle. `canvasWidth`/`canvasHeight` are
    /// the codec context's dimensions after decoding, which the bitmap
    /// decoders set to their authoring canvas.
    static func images(of subtitle: AVSubtitle, canvasWidth: Int32, canvasHeight: Int32) -> [SubtitleImage] {
        var rects: [UnsafeMutablePointer<AVSubtitleRect>] = []
        for index in 0..<Int(subtitle.num_rects) {
            if let rect = subtitle.rects[index], rect.pointee.type == SUBTITLE_BITMAP {
                rects.append(rect)
            }
        }
        guard !rects.isEmpty else { return [] }

        var canvas = (width: Int(canvasWidth), height: Int(canvasHeight))
        if canvas.width <= 0 || canvas.height <= 0 {
            canvas = fallbackCanvas
        }
        // A rect reaching past the canvas means the canvas is wrong (an
        // undeclared HD page); grow it rather than draw off screen.
        for rect in rects {
            canvas.width = max(canvas.width, Int(rect.pointee.x) + Int(rect.pointee.w))
            canvas.height = max(canvas.height, Int(rect.pointee.y) + Int(rect.pointee.h))
        }

        return rects.compactMap { rect in
            image(of: rect.pointee, canvasWidth: canvas.width, canvasHeight: canvas.height)
        }
    }

    private static func image(of rect: AVSubtitleRect, canvasWidth: Int, canvasHeight: Int) -> SubtitleImage? {
        let width = Int(rect.w)
        let height = Int(rect.h)
        let stride = Int(rect.linesize.0)
        guard width > 0, height > 0, stride >= width,
              let indices = rect.data.0, let paletteData = rect.data.1,
              rect.nb_colors > 0
        else { return nil }

        let palette = UnsafeRawPointer(paletteData).withMemoryRebound(
            to: UInt32.self, capacity: Int(rect.nb_colors)
        ) { Array(UnsafeBufferPointer(start: $0, count: Int(rect.nb_colors))) }
        let pixels = premultipliedPixels(
            indices: UnsafeBufferPointer(start: indices, count: stride * height),
            width: width, height: height, stride: stride, palette: palette
        )
        guard pixels.contains(where: { $0 >> 24 != 0 }),
              let image = makeImage(pixels: pixels, width: width, height: height)
        else { return nil } // fully transparent: nothing to draw

        return SubtitleImage(
            image: image,
            rect: normalizedRect(
                x: Int(rect.x), y: Int(rect.y), width: width, height: height,
                canvasWidth: canvasWidth, canvasHeight: canvasHeight
            )
        )
    }

    /// Palette-indexed pixels to premultiplied ARGB words. FFmpeg's palettes
    /// are straight-alpha `0xAARRGGBB`; Core Animation and Core Graphics
    /// composite premultiplied, and straight alpha drawn as premultiplied
    /// shows a bright fringe around every glyph's anti-aliased edge. An index
    /// beyond the palette is transparent.
    static func premultipliedPixels(
        indices: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int,
        palette: [UInt32]
    ) -> [UInt32] {
        let premultiplied = palette.map(premultiply)
        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = row * stride
            let destination = row * width
            guard source + width <= indices.count else { break }
            for column in 0..<width {
                let index = Int(indices[source + column])
                pixels[destination + column] = index < premultiplied.count ? premultiplied[index] : 0
            }
        }
        return pixels
    }

    static func premultiply(_ argb: UInt32) -> UInt32 {
        let alpha = argb >> 24
        func channel(_ shift: UInt32) -> UInt32 {
            ((argb >> shift & 0xFF) * alpha + 127) / 255
        }
        return alpha << 24 | channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    /// ARGB words in native (little-endian) order are BGRA bytes in memory:
    /// `byteOrder32Little` + `premultipliedFirst`, Core Graphics' native layout.
    static func makeImage(pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        guard pixels.count == width * height,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func normalizedRect(
        x: Int, y: Int, width: Int, height: Int,
        canvasWidth: Int, canvasHeight: Int
    ) -> CGRect {
        guard canvasWidth > 0, canvasHeight > 0 else { return .zero }
        let canvasW = Double(canvasWidth)
        let canvasH = Double(canvasHeight)
        return CGRect(
            x: Double(x) / canvasW,
            y: Double(y) / canvasH,
            width: Double(width) / canvasW,
            height: Double(height) / canvasH
        )
    }
}
