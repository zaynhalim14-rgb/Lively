//
//  AdjustPanelView.swift
//  Lively
//
//  The Adjust tool panel: eight flat sliders bound straight onto
//  `EditState.adjustments`. Every change flows through the model's
//  edit-state router, which pushes the new visual state into the shared
//  box — the running preview restyles on the next frame with no rebuild.
//

import SwiftUI

// MARK: - AdjustPanelView

/// Bottom panel for the `.adjust` tool: header with reset, then a vertical
/// scroll of adjustment sliders. Color sliders are disabled while a
/// monochrome preset is active, since they would have no visible effect.
struct AdjustPanelView: View {

    @Environment(EditorViewModel.self) private var model

    /// Opacity applied to color rows that are inert under a monochrome preset.
    private static let disabledOpacity: Double = 0.35

    var body: some View {
        @Bindable var model = model
        let isMonochrome = model.editState.filter.isMonochrome

        PanelContainer {
            VStack(alignment: .leading, spacing: FlatTheme.spacing) {
                header

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: FlatTheme.spacingTight) {

                        // MARK: Light
                        FlatSlider(
                            label: "Exposure",
                            value: $model.editState.adjustments.exposure
                        )
                        FlatSlider(
                            label: "Brightness",
                            value: $model.editState.adjustments.brightness
                        )
                        FlatSlider(
                            label: "Contrast",
                            value: $model.editState.adjustments.contrast
                        )

                        // MARK: Color (inert under monochrome presets)
                        FlatSlider(
                            label: "Saturation",
                            value: $model.editState.adjustments.saturation
                        )
                        .disabled(isMonochrome)
                        .opacity(isMonochrome ? Self.disabledOpacity : 1)

                        FlatSlider(
                            label: "Vibrance",
                            value: $model.editState.adjustments.vibrance
                        )
                        .disabled(isMonochrome)
                        .opacity(isMonochrome ? Self.disabledOpacity : 1)

                        FlatSlider(
                            label: "Warmth",
                            value: $model.editState.adjustments.warmth
                        )
                        .disabled(isMonochrome)
                        .opacity(isMonochrome ? Self.disabledOpacity : 1)

                        // MARK: Detail
                        FlatSlider(
                            label: "Vignette",
                            value: $model.editState.adjustments.vignette,
                            range: 0...1,
                            defaultValue: 0
                        )
                        FlatSlider(
                            label: "Sharpness",
                            value: $model.editState.adjustments.sharpness,
                            range: 0...1,
                            defaultValue: 0
                        )
                    }
                }
            }
        }
    }

    // MARK: - Header

    /// Section title with a flat "Reset" text button that appears only when
    /// any adjustment differs from identity.
    private var header: some View {
        HStack {
            SectionHeader("Adjust")
            Spacer()
            if !model.editState.adjustments.isIdentity {
                Button("Reset") {
                    model.resetAdjustments()
                }
                .buttonStyle(.plain)
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.accent)
                .accessibilityLabel("Reset all adjustments")
            }
        }
    }
}
