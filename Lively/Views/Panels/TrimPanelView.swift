//
//  TrimPanelView.swift
//  Lively
//
//  The Trim tool panel: a filmstrip of evenly spaced video frames with a
//  range slider overlaid on top. Dragging the handles updates
//  `EditState.trim`; the lower handle also scrubs the preview player so the
//  user sees exactly where the new in-point lands.
//

import SwiftUI

struct TrimPanelView: View {

    // MARK: - Environment

    @Environment(EditorViewModel.self) private var model

    // MARK: - Constants

    /// Height of the filmstrip strip with its range-slider overlay.
    private let stripHeight: CGFloat = 56

    // MARK: - Body

    var body: some View {
        PanelContainer {
            VStack(alignment: .leading, spacing: FlatTheme.spacing) {
                headerRow
                filmstripWithSlider
                timecodeRow
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            SectionHeader("Trim")
            Spacer()
            if isTrimmed {
                Button("Reset") {
                    model.editState.trim = TrimSettings(end: model.videoDuration)
                }
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.accent)
                .accessibilityLabel("Reset trim to the full clip")
            }
        }
    }

    // MARK: - Filmstrip + range slider

    private var filmstripWithSlider: some View {
        ZStack {
            FilmstripView(frames: model.filmstrip)
            RangeSlider(
                lowerValue: trimStartBinding,
                upperValue: trimEndBinding,
                bounds: 0...max(0.5, model.videoDuration),
                minimumGap: 0.5
            )
        }
        .frame(height: stripHeight)
    }

    // MARK: - Timecode readouts

    private var timecodeRow: some View {
        HStack {
            Text(trimStart.livelyTimecode)
                .font(FlatTheme.timecodeFont())
                .foregroundStyle(FlatTheme.ink)
            Spacer()
            Text(keptDurationLabel)
                .font(FlatTheme.captionFont())
                .foregroundStyle(FlatTheme.inkSecondary)
            Spacer()
            Text(trimEnd.livelyTimecode)
                .font(FlatTheme.timecodeFont())
                .foregroundStyle(FlatTheme.ink)
        }
    }

    // MARK: - Derived state

    private var trimStart: TimeInterval { model.editState.trim?.start ?? 0 }

    private var trimEnd: TimeInterval { model.editState.trim?.end ?? model.videoDuration }

    /// True when the current trim keeps less than the full clip.
    private var isTrimmed: Bool {
        guard let trim = model.editState.trim else { return false }
        return !trim.isFullRange(of: model.videoDuration)
    }

    private var keptDurationLabel: String {
        String(format: "%.1f s kept", max(0, trimEnd - trimStart))
    }

    // MARK: - Bindings

    /// Lower trim handle. Unwraps the optional trim; dragging also scrubs the
    /// preview player to the new in-point.
    private var trimStartBinding: Binding<Double> {
        Binding(
            get: { model.editState.trim?.start ?? 0 },
            set: { newValue in
                guard model.editState.trim != nil else { return }
                model.editState.trim?.start = newValue
                model.seek(to: newValue)
            }
        )
    }

    /// Upper trim handle. Unwraps the optional trim.
    private var trimEndBinding: Binding<Double> {
        Binding(
            get: { model.editState.trim?.end ?? model.videoDuration },
            set: { newValue in
                guard model.editState.trim != nil else { return }
                model.editState.trim?.end = newValue
            }
        )
    }

}
