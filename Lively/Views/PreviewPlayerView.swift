//
//  PreviewPlayerView.swift
//  Lively
//
//  A SwiftUI wrapper around an AVPlayerLayer-backed UIView. The editor's
//  motion preview renders through this layer so the shared AVPlayer owned by
//  EditorViewModel can keep playing across SwiftUI updates without being
//  re-attached or interrupted.
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - PreviewPlayerView

/// Hosts an `AVPlayer` inside SwiftUI using an `AVPlayerLayer` backing layer.
struct PreviewPlayerView: UIViewRepresentable {

    // MARK: Properties

    /// The player driving the preview (owned by `EditorViewModel`).
    let player: AVPlayer
    /// How video is fitted inside the layer's bounds.
    let videoGravity: AVLayerVideoGravity

    // MARK: Init

    init(player: AVPlayer, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        self.videoGravity = videoGravity
    }

    // MARK: UIViewRepresentable

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerLayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
}

// MARK: - PlayerLayerHostView

/// A plain `UIView` whose backing layer is an `AVPlayerLayer`, so video
/// renders and resizes with the view itself — no manual layout needed.
final class PlayerLayerHostView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    /// The backing layer, typed. The force cast is provably safe because
    /// `layerClass` guarantees the layer's concrete type.
    var playerLayer: AVPlayerLayer {
        // swiftlint-style note: safe by construction (see layerClass above).
        layer as! AVPlayerLayer
    }
}
