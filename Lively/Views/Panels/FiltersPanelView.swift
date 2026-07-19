//
//  FiltersPanelView.swift
//  Lively
//
//  The Filters tool panel: a horizontal strip of live preset thumbnails
//  rendered from the current still, plus an intensity slider that blends
//  the selected look over the untouched frame. Selecting a preset routes
//  through the model so the running preview restyles instantly.
//

import SwiftUI
import UIKit

// MARK: - FiltersPanelView

/// Bottom panel for the `.filters` tool: preset strip + intensity control.
struct FiltersPanelView: View {

    @Environment(EditorViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        PanelContainer {
            VStack(alignment: .leading, spacing: FlatTheme.spacing) {
                filterStrip

                if model.editState.filter != .original {
                    FlatSlider(
                        label: "Intensity",
                        value: $model.editState.filterIntensity,
                        range: 0...1,
                        defaultValue: 1
                    )
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Filter strip

    /// Horizontally scrolling row of one thumbnail chip per preset.
    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FlatTheme.spacing) {
                ForEach(FilterPreset.allCases) { preset in
                    FilterChip(
                        preset: preset,
                        thumbnail: model.filterThumbnails[preset],
                        isSelected: model.editState.filter == preset
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        model.select(preset: preset)
                    }
                }
            }
        }
    }
}

// MARK: - FilterChip

/// One tappable preset in the strip: a 64pt rounded-square thumbnail with the
/// preset's name beneath. Selection is marked by a flat 2pt accent border and
/// an accent-colored caption — no shadows, no glows.
private struct FilterChip: View {

    let preset: FilterPreset
    let thumbnail: UIImage?
    let isSelected: Bool
    let action: () -> Void

    /// Edge length of the square thumbnail.
    private static let thumbnailSize: CGFloat = 64
    /// Width of the flat selection border.
    private static let selectionBorderWidth: CGFloat = 2

    var body: some View {
        Button(action: action) {
            VStack(spacing: FlatTheme.spacingTight) {
                thumbnailView
                Text(preset.displayName)
                    .font(FlatTheme.captionFont())
                    .foregroundStyle(isSelected ? FlatTheme.accent : FlatTheme.inkSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.displayName) filter. \(preset.summary)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Thumbnail

    /// The preset preview image, or a flat placeholder well while thumbnails
    /// are still rendering.
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: FlatTheme.chipRadius, style: .continuous)
                .fill(FlatTheme.surfaceSecondary)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: FlatTheme.chipRadius, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: FlatTheme.chipRadius, style: .continuous)
                    .strokeBorder(FlatTheme.accent, lineWidth: Self.selectionBorderWidth)
            }
        }
    }
}
