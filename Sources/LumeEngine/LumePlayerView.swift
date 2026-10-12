@preconcurrency import AVFoundation
import LumeEngineCore
import SwiftUI

/// Platform alias for the renderer's display layer.
public typealias LumeDisplayLayer = AVSampleBufferDisplayLayer

/// SwiftUI video surface: hosts the engine's `AVSampleBufferDisplayLayer`.
/// Bare video only — controls/overlays are the app's responsibility (Lume
/// brings its own overlay system).
public struct LumePlayerView: View {
    private let player: LumePlayer
    private let gravity: AVLayerVideoGravity

    public init(player: LumePlayer, gravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        self.gravity = gravity
    }

    public var body: some View {
        ZStack {
            if let layer = player.displayLayer {
                #if os(tvOS)
                LayerHostView(
                    layer: layer,
                    gravity: gravity,
                    displayMatcher: player.matchesDisplayCriteria ? player.displayMatcher : nil
                )
                .accessibilityLabel("Video")
                #else
                LayerHostView(layer: layer, gravity: gravity)
                    .accessibilityLabel("Video")
                #endif
            } else {
                Color.black
            }
        }
        #if os(tvOS)
        // The whole view, not the layer host: that one is swapped out while
        // the player moves to the next stream, which must not hand the
        // display back in between.
        .onDisappear { [player] in player.displayMatcher.reset() }
        #endif
    }
}

#if canImport(UIKit)
import UIKit

private struct LayerHostView: UIViewRepresentable {
    let layer: LumeDisplayLayer
    let gravity: AVLayerVideoGravity
    #if os(tvOS)
    /// Given this view's window, so it knows which display to match.
    var displayMatcher: DisplayCriteriaMatcher?
    #endif

    func makeUIView(context: Context) -> LayerHostUIView {
        let view = LayerHostUIView()
        view.install(layer: layer, gravity: gravity)
        #if os(tvOS)
        view.displayMatcher = displayMatcher
        #endif
        return view
    }

    func updateUIView(_ view: LayerHostUIView, context: Context) {
        view.install(layer: layer, gravity: gravity)
        #if os(tvOS)
        view.displayMatcher = displayMatcher
        #endif
    }
}

final class LayerHostUIView: UIView {
    private weak var hosted: LumeDisplayLayer?

    #if os(tvOS)
    weak var displayMatcher: DisplayCriteriaMatcher? {
        didSet { lendWindow() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        lendWindow()
    }

    /// Only ever sets a window: leaving one is not the end of playback (the
    /// host is swapped while the next stream loads); the player view's
    /// disappearance is.
    private func lendWindow() {
        if let window { displayMatcher?.window = window }
    }
    #endif

    func install(layer: LumeDisplayLayer, gravity: AVLayerVideoGravity) {
        layer.videoGravity = gravity
        guard hosted !== layer else { return }
        hosted?.removeFromSuperlayer()
        layer.frame = bounds
        self.layer.addSublayer(layer)
        hosted = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}

#elseif canImport(AppKit)
import AppKit

private struct LayerHostView: NSViewRepresentable {
    let layer: LumeDisplayLayer
    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> LayerHostNSView {
        let view = LayerHostNSView()
        view.wantsLayer = true
        view.install(layer: layer, gravity: gravity)
        return view
    }

    func updateNSView(_ view: LayerHostNSView, context: Context) {
        view.install(layer: layer, gravity: gravity)
    }
}

final class LayerHostNSView: NSView {
    private weak var hosted: LumeDisplayLayer?

    func install(layer: LumeDisplayLayer, gravity: AVLayerVideoGravity) {
        layer.videoGravity = gravity
        guard hosted !== layer else { return }
        hosted?.removeFromSuperlayer()
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        hosted = layer
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}
#endif
