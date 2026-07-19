//
//  ExportPanelView.swift
//  Lively
//
//  The Export tool panel — a small state machine over
//  `EditorViewModel.exportPhase`: idle actions, an indeterminate preparation
//  spinner, determinate export progress, and flat success / failure states.
//

import SwiftUI

struct ExportPanelView: View {

    // MARK: - Environment

    @Environment(EditorViewModel.self) private var model

    // MARK: - Body

    var body: some View {
        PanelContainer {
            switch model.exportPhase {
            case .idle:
                idleContent
            case .preparing(let message):
                preparingContent(message: message)
            case .exporting(let fraction):
                exportingContent(fraction: fraction)
            case .done(let message):
                doneContent(message: message)
            case .failed(let message):
                failedContent(message: message)
            }
        }
    }

    // MARK: - Idle

    private var idleContent: some View {
        VStack(spacing: FlatTheme.spacing) {
            Button {
                Task { await model.saveLivePhoto() }
            } label: {
                Label("Save Live Photo", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FlatPrimaryButtonStyle())

            Button {
                Task { await model.prepareShareVideo() }
            } label: {
                Label("Share as Video", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FlatSecondaryButtonStyle())

            Text("Saves as a new Live Photo — your original stays untouched.")
                .font(FlatTheme.captionFont())
                .foregroundStyle(FlatTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Preparing

    private func preparingContent(message: String) -> some View {
        VStack(spacing: FlatTheme.spacing) {
            ProgressView()
                .tint(FlatTheme.accent)
            Text(message)
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Exporting

    private func exportingContent(fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return VStack(spacing: FlatTheme.spacing) {
            ProgressView(value: clamped)
                .progressViewStyle(.linear)
                .tint(FlatTheme.accent)
            HStack {
                Text("Exporting")
                    .font(FlatTheme.labelFont())
                    .foregroundStyle(FlatTheme.inkSecondary)
                Spacer()
                Text("\(Int(clamped * 100))%")
                    .font(FlatTheme.timecodeFont())
                    .foregroundStyle(FlatTheme.ink)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Done

    private func doneContent(message: String) -> some View {
        VStack(spacing: FlatTheme.spacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(FlatTheme.mint)
                .accessibilityHidden(true)
            Text(message)
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.ink)
                .multilineTextAlignment(.center)
            Button("Done") {
                model.exportPhase = .idle
            }
            .buttonStyle(FlatSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Failed

    private func failedContent(message: String) -> some View {
        VStack(spacing: FlatTheme.spacing) {
            Text(message)
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.ink)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                model.exportPhase = .idle
            }
            .buttonStyle(FlatSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }
}
