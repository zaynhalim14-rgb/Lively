//
//  HomeView.swift
//  Lively
//
//  The landing screen: a flat coral hero, a PhotosPicker restricted to
//  Live Photos, and three feature cards previewing what the editor does.
//  Picking an item assigns EditorViewModel.pickerItem, which kicks off
//  loading; while that runs a flat overlay covers the screen, and any
//  failure surfaces through the shared error alert.
//

import SwiftUI
import PhotosUI

// MARK: - HomeView

struct HomeView: View {

    @Environment(EditorViewModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ZStack {
            FlatTheme.background
                .ignoresSafeArea()

            VStack(spacing: FlatTheme.spacing) {
                Spacer()
                hero
                Spacer()

                PhotosPicker(
                    selection: $model.pickerItem,
                    matching: .livePhotos,
                    photoLibrary: .shared()
                ) {
                    pickerLabel
                }
                .disabled(model.isLoadingSource)

                PhotosPicker(
                    selection: $model.videoPickerItem,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    videoPickerLabel
                }
                .disabled(model.isLoadingSource)

                featureCards
                    .padding(.top, FlatTheme.spacingTight)
            }
            .padding(FlatTheme.padding)

            if model.isLoadingSource {
                loadingOverlay
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isLoadingSource)
        .sheet(item: $model.pendingVideo, onDismiss: {
            // Interactive swipe-down bypasses the Cancel button; make sure the
            // staged video copy is cleaned up either way.
            model.cancelPendingVideo()
        }) {
            video in
            VideoConvertView(video: video)
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                // While the conversion sheet is up its own alert presents the
                // error; suppress this one so UIKit isn't asked to present
                // from a view that is already presenting.
                get: { model.errorMessage != nil && model.pendingVideo == nil },
                set: { isPresented in
                    if !isPresented { model.errorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Hero

    /// App mark, name, and tagline.
    private var hero: some View {
        VStack(spacing: FlatTheme.spacing) {
            ZStack {
                Circle()
                    .fill(FlatTheme.accent)
                    .frame(width: 140, height: 140)

                Image(systemName: "livephoto")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            Text("Lively")
                .font(FlatTheme.titleFont())
                .foregroundStyle(FlatTheme.ink)

            Text("Give your Live Photos a life of their own.")
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Picker label

    /// Label for the PhotosPicker, drawn to match the flat primary button
    /// look: solid accent fill, white rounded-semibold text.
    private var pickerLabel: some View {
        HStack(spacing: FlatTheme.spacingTight) {
            Image(systemName: "photo.on.rectangle")
            Text("Choose a Live Photo")
        }
        .font(.system(.body, design: .rounded).weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, FlatTheme.spacing)
        .padding(.horizontal, FlatTheme.padding)
        .background(
            FlatTheme.accent,
            in: RoundedRectangle(cornerRadius: FlatTheme.cornerRadius, style: .continuous)
        )
    }

    /// Label for the video PhotosPicker, drawn to match the flat secondary
    /// button look: quiet surface fill with a hairline border.
    private var videoPickerLabel: some View {
        HStack(spacing: FlatTheme.spacingTight) {
            Image(systemName: "film")
            Text("Turn a Video into a Live Photo")
        }
        .font(.system(.body, design: .rounded).weight(.semibold))
        .foregroundStyle(FlatTheme.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, FlatTheme.spacing)
        .padding(.horizontal, FlatTheme.padding)
        .background(
            FlatTheme.surfaceSecondary,
            in: RoundedRectangle(cornerRadius: FlatTheme.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlatTheme.cornerRadius, style: .continuous)
                .strokeBorder(FlatTheme.hairline, lineWidth: FlatTheme.hairlineWidth)
        )
    }

    // MARK: - Feature cards

    /// Three flat cards summarizing the editor's marquee features.
    private var featureCards: some View {
        HStack(alignment: .top, spacing: FlatTheme.spacing) {
            FeatureCard(
                icon: "camera.filters",
                tint: FlatTheme.accent,
                title: "Vivid Filters",
                caption: "Looks that move with you."
            )
            FeatureCard(
                icon: "music.note",
                tint: FlatTheme.ocean,
                title: "Add Soundtrack",
                caption: "Music or a voiceover."
            )
            FeatureCard(
                icon: "livephoto",
                tint: FlatTheme.amber,
                title: "Re-Live It",
                caption: "Save a new Live Photo."
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Loading overlay

    /// Flat overlay shown while the picked Live Photo is being prepared.
    private var loadingOverlay: some View {
        ZStack {
            FlatTheme.canvas.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: FlatTheme.spacing) {
                ProgressView()
                    .tint(FlatTheme.accent)

                Text("Preparing your Live Photo…")
                    .font(FlatTheme.labelFont())
                    .foregroundStyle(FlatTheme.ink)
            }
            .padding(FlatTheme.padding * 1.5)
            .background(
                FlatTheme.surface,
                in: RoundedRectangle(cornerRadius: FlatTheme.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlatTheme.cornerRadius)
                    .strokeBorder(FlatTheme.hairline, lineWidth: FlatTheme.hairlineWidth)
            )
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - FeatureCard

/// One flat surface card with a tinted icon, a two-word title, and a
/// one-line caption. Hairline border, no shadows.
private struct FeatureCard: View {
    let icon: String
    let tint: Color
    let title: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: FlatTheme.spacingTight) {
            Image(systemName: icon)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)

            Text(title)
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.ink)

            Text(caption)
                .font(FlatTheme.captionFont())
                .foregroundStyle(FlatTheme.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(FlatTheme.spacing)
        .background(
            FlatTheme.surface,
            in: RoundedRectangle(cornerRadius: FlatTheme.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlatTheme.cornerRadius)
                .strokeBorder(FlatTheme.hairline, lineWidth: FlatTheme.hairlineWidth)
        )
        .accessibilityElement(children: .combine)
    }
}
