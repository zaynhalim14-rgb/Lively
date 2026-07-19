//
//  FilmstripView.swift
//  Lively
//
//  A flat strip of evenly spaced video frames shown behind the trim range
//  slider. Frames sit edge-to-edge in equal-width cells and the whole strip
//  is clipped to a single rounded container. While frames are still being
//  generated the strip shows a plain secondary-surface placeholder.
//

import SwiftUI
import UIKit

struct FilmstripView: View {

    // MARK: - Input

    /// Evenly spaced frames sampled from the source video, in timeline order.
    let frames: [UIImage]

    init(frames: [UIImage]) {
        self.frames = frames
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            Group {
                if frames.isEmpty {
                    placeholder
                } else {
                    strip(in: proxy.size)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: FlatTheme.chipRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: - Content

    /// Equal-width frame cells laid edge to edge across the available width.
    private func strip(in size: CGSize) -> some View {
        let cellWidth = size.width / CGFloat(max(1, frames.count))
        return HStack(spacing: 0) {
            ForEach(frames.indices, id: \.self) { index in
                Image(uiImage: frames[index])
                    .resizable()
                    .scaledToFill()
                    .frame(width: cellWidth, height: size.height)
                    .clipped()
            }
        }
    }

    /// Flat placeholder shown until frame generation finishes.
    private var placeholder: some View {
        Rectangle()
            .fill(FlatTheme.surfaceSecondary)
    }
}
