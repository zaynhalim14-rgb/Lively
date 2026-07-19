//
//  EditorView.swift
//  Lively
//
//  The main editing screen: a top bar (close / title / preview-mode toggle /
//  play-pause), the preview canvas, the active tool panel, and the tool tab
//  bar. Also hosts the session-level error alert, the discard-confirmation
//  dialog, and the share sheet for exported videos.
//

import SwiftUI
import UIKit

// MARK: - EditorView

struct EditorView: View {

    // MARK: Environment & state

    @Environment(EditorViewModel.self) private var model
    /// Drives the "Discard edits?" confirmation dialog for the close button.
    @State private var isConfirmingDiscard = false

    // MARK: Body

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            topBar
            canvas
            activePanel
            ToolTabBar(selection: $model.activeTool)
        }
        .background(FlatTheme.background)
        .confirmationDialog(
            "Discard edits?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                model.reset()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your changes to this Live Photo will be lost.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: errorBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: shareItemBinding) { item in
            ActivityView(activityItems: [item.url])
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            Text("Edit")
                .font(FlatTheme.headerFont())
                .foregroundStyle(FlatTheme.ink)

            HStack(spacing: FlatTheme.spacing) {
                FlatIconButton(systemName: "xmark", label: "Close editor") {
                    requestClose()
                }

                Spacer(minLength: 0)

                PreviewModeToggle(mode: model.previewMode) { mode in
                    setPreviewMode(mode)
                }

                FlatIconButton(
                    systemName: model.isPlaying ? "pause.fill" : "play.fill",
                    label: model.isPlaying ? "Pause" : "Play"
                ) {
                    model.togglePlayback()
                }
                .disabled(model.previewMode == .live)
                .opacity(model.previewMode == .live ? 0.4 : 1)
            }
        }
        .padding(.horizontal, FlatTheme.padding)
        .padding(.vertical, FlatTheme.spacingTight)
        .background(FlatTheme.background)
        .overlay(alignment: .bottom) {
            FlatTheme.hairline
                .frame(height: FlatTheme.hairlineWidth)
        }
    }

    /// Close tapped: confirm first when there are unsaved edits.
    private func requestClose() {
        if model.editState.hasEdits(videoDuration: model.videoDuration) {
            isConfirmingDiscard = true
        } else {
            model.reset()
        }
    }

    /// Switches the canvas between the motion preview and the assembled
    /// Live Photo preview, kicking off assembly when entering `.live`.
    private func setPreviewMode(_ mode: PreviewMode) {
        guard model.previewMode != mode else { return }
        if mode == .live, model.isPlaying {
            model.togglePlayback()
        }
        model.previewMode = mode
        if mode == .live {
            Task { await model.generateLivePreview() }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            FlatTheme.canvas

            switch model.previewMode {
            case .motion:
                PreviewPlayerView(player: model.player)
            case .live:
                LivePhotoPreview(livePhoto: model.livePreview)
                if model.isBuildingLivePreview {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(FlatTheme.accent)
                        .accessibilityLabel("Building Live Photo preview")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) {
            LiveBadge()
                .padding(FlatTheme.padding)
        }
    }

    // MARK: - Active panel

    @ViewBuilder
    private var activePanel: some View {
        switch model.activeTool {
        case .filters:
            FiltersPanelView()
        case .adjust:
            AdjustPanelView()
        case .audio:
            AudioPanelView()
        case .trim:
            TrimPanelView()
        case .export:
            ExportPanelView()
        }
    }

    // MARK: - Bindings

    /// Presents the error alert whenever the model publishes a message;
    /// dismissal clears it.
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )
    }

    /// Wraps `model.shareVideoURL` in an `Identifiable` item so the share
    /// sheet can be driven by `.sheet(item:)`; dismissal clears the URL.
    private var shareItemBinding: Binding<ShareVideoItem?> {
        Binding(
            get: { model.shareVideoURL.map(ShareVideoItem.init(url:)) },
            set: { item in
                if item == nil {
                    model.shareVideoURL = nil
                }
            }
        )
    }
}

// MARK: - ShareVideoItem

/// Identifiable wrapper for the exported video URL, used to drive the
/// share sheet via `.sheet(item:)`.
private struct ShareVideoItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - PreviewModeToggle

/// A flat, segmented-style two-option control switching between the motion
/// preview and the assembled Live Photo preview.
private struct PreviewModeToggle: View {
    let mode: PreviewMode
    let onSelect: (PreviewMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(for: .motion, systemName: "play.rectangle", label: "Motion preview")
            segment(for: .live, systemName: "livephoto", label: "Live Photo preview")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: FlatTheme.chipRadius, style: .continuous)
                .fill(FlatTheme.surfaceSecondary)
        )
    }

    private func segment(for target: PreviewMode, systemName: String, label: String) -> some View {
        let isSelected = mode == target
        return Button {
            onSelect(target)
        } label: {
            Image(systemName: systemName)
                .font(FlatTheme.headerFont())
                .foregroundStyle(isSelected ? Color.white : FlatTheme.inkSecondary)
                .frame(width: 40, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: FlatTheme.chipRadius - 2, style: .continuous)
                        .fill(isSelected ? FlatTheme.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - ActivityView

/// UIKit share sheet bridged into SwiftUI for sharing the exported video.
private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // The share sheet is fully configured at creation; nothing to update.
    }
}
