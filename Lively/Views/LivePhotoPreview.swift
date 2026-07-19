//
//  LivePhotoPreview.swift
//  Lively
//
//  A SwiftUI wrapper around PHLivePhotoView for the editor's "Live" preview
//  mode. PHLivePhotoView already provides the native press-and-hold playback
//  gesture, so this wrapper only manages the displayed live photo, mute
//  state, and aspect-fit content mode.
//

import SwiftUI
import UIKit
import Photos
import PhotosUI

// MARK: - LivePhotoPreview

/// Displays an assembled `PHLivePhoto` with the system press-and-hold
/// playback behavior.
struct LivePhotoPreview: UIViewRepresentable {

    // MARK: Properties

    /// The live photo to display; `nil` shows an empty view (e.g. while the
    /// preview is still being assembled).
    let livePhoto: PHLivePhoto?
    /// Whether playback audio is muted.
    let isMuted: Bool

    // MARK: Init

    init(livePhoto: PHLivePhoto?, isMuted: Bool = false) {
        self.livePhoto = livePhoto
        self.isMuted = isMuted
    }

    // MARK: UIViewRepresentable

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.isMuted = isMuted
        view.livePhoto = livePhoto
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        if uiView.isMuted != isMuted {
            uiView.isMuted = isMuted
        }
        // Only reassign when the photo actually changed so SwiftUI updates
        // don't interrupt an in-progress press-and-hold playback.
        if uiView.livePhoto !== livePhoto {
            uiView.livePhoto = livePhoto
        }
    }
}
