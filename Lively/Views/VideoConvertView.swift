//
//  VideoConvertView.swift
//  Lively
//
//  The Video → Live Photo conversion sheet. Shows a looping preview of the
//  staged video, a filmstrip with a range selector for the segment, and a
//  key-frame scrubber that picks the frame used as the Live Photo's still.
//  Conversion hands a LivePhotoAssetPair to the model, which opens the full
//  editor on it.
//

import SwiftUI
import AVFoundation

struct VideoConvertView: View {

    @Environment(EditorViewModel.self) private var model

    /// The staged video this sheet configures.
    let video: PendingVideo

    // MARK: Selection state

    @State private var segmentStart: Double = 0
    @State private var segmentEnd: Double = 3
    @State private var keyTime: Double = 1.5
    @State private var frames: [UIImage] = []

    // MARK: Preview

    @State private var player = AVPlayer()
    @State private var timeObserver: Any?

    private var segmentDuration: Double { max(0, segmentEnd - segmentStart) }

    var body: some View {
        VStack(spacing: 0) {
            header

            previewCanvas
                .padding(FlatTheme.padding)

            VStack(alignment: .leading, spacing: FlatTheme.spacing) {
                segmentSection
                keyFrameSection
            }
            .padding(.horizontal, FlatTheme.padding)

            Spacer(minLength: FlatTheme.spacing)

            convertButton
                .padding(FlatTheme.padding)
        }
        .background(FlatTheme.background)
        .task { await prepare() }
        .onDisappear { teardownPlayer() }
        .interactiveDismissDisabled(model.isConvertingVideo)
        // The sheet covers HomeView, so conversion errors must present from
        // this view's own presentation context or they would be dropped.
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
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

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text("Video to Live Photo")
                .font(FlatTheme.headerFont())
                .foregroundStyle(FlatTheme.ink)

            HStack {
                Button("Cancel") {
                    model.cancelPendingVideo()
                }
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.inkSecondary)
                .disabled(model.isConvertingVideo)

                Spacer()
            }
        }
        .padding(.horizontal, FlatTheme.padding)
        .padding(.vertical, FlatTheme.spacing)
        .overlay(alignment: .bottom) {
            FlatTheme.hairline
                .frame(height: FlatTheme.hairlineWidth)
        }
    }

    // MARK: - Preview

    private var previewCanvas: some View {
        PreviewPlayerView(player: player)
            .frame(maxWidth: .infinity)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .background(
                FlatTheme.canvas,
                in: RoundedRectangle(cornerRadius: FlatTheme.cornerRadius, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: FlatTheme.cornerRadius, style: .continuous))
            .accessibilityLabel("Video preview, playing the selected segment")
    }

    // MARK: - Segment selection

    private var segmentSection: some View {
        VStack(alignment: .leading, spacing: FlatTheme.spacingTight) {
            SectionHeader("Segment")

            ZStack {
                FilmstripView(frames: frames)
                RangeSlider(
                    lowerValue: Binding(
                        get: { segmentStart },
                        set: { newValue in
                            segmentStart = newValue
                            clampKeyTime()
                            seekPreview(to: newValue)
                        }
                    ),
                    upperValue: Binding(
                        get: { segmentEnd },
                        set: { newValue in
                            segmentEnd = newValue
                            clampKeyTime()
                            seekPreview(to: newValue)
                        }
                    ),
                    bounds: 0...max(0.5, video.duration),
                    minimumGap: 0.5
                )
            }
            .frame(height: 56)

            HStack {
                Text(segmentStart.livelyTimecode)
                Spacer()
                Text("\(segmentDuration.livelyTimecode) selected")
                    .foregroundStyle(
                        segmentDuration > 5 ? FlatTheme.amber : FlatTheme.inkSecondary
                    )
                Spacer()
                Text(segmentEnd.livelyTimecode)
            }
            .font(FlatTheme.timecodeFont())
            .foregroundStyle(FlatTheme.inkSecondary)

            Text("Live Photos work best under 5 seconds.")
                .font(FlatTheme.captionFont())
                .foregroundStyle(FlatTheme.inkSecondary)
        }
    }

    // MARK: - Key frame

    private var keyFrameSection: some View {
        VStack(alignment: .leading, spacing: FlatTheme.spacingTight) {
            SectionHeader("Key Frame")

            FlatSlider(
                label: "Still frame",
                value: Binding(
                    get: { keyTime },
                    set: { newValue in
                        keyTime = newValue
                        pauseAndShow(newValue)
                    }
                ),
                range: segmentStart...max(segmentStart + 0.1, segmentEnd),
                defaultValue: (segmentStart + segmentEnd) / 2,
                format: { $0.livelyTimecode }
            )

            Text("This frame becomes the Live Photo's still image.")
                .font(FlatTheme.captionFont())
                .foregroundStyle(FlatTheme.inkSecondary)
        }
    }

    // MARK: - Convert

    private var convertButton: some View {
        Button {
            Task {
                await model.convertPendingVideo(
                    segmentStart: segmentStart,
                    segmentEnd: segmentEnd,
                    keyTime: keyTime
                )
            }
        } label: {
            HStack(spacing: FlatTheme.spacingTight) {
                if model.isConvertingVideo {
                    ProgressView()
                        .tint(.white)
                    Text("Converting…")
                } else {
                    Image(systemName: "livephoto")
                    Text("Create Live Photo")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(FlatPrimaryButtonStyle())
        .disabled(model.isConvertingVideo)
    }

    // MARK: - Player lifecycle

    /// Sets defaults, builds the filmstrip, and starts the segment-looping
    /// preview.
    private func prepare() async {
        segmentStart = 0
        segmentEnd = min(video.duration, 3)
        keyTime = (segmentStart + segmentEnd) / 2

        player.replaceCurrentItem(with: AVPlayerItem(url: video.url))
        installSegmentLoop()
        player.play()

        frames = await makeFilmstrip(url: video.url, count: 10)
    }

    /// Keeps playback inside the selected segment.
    private func installSegmentLoop() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            Task { @MainActor in
                if time.seconds >= segmentEnd || time.seconds < segmentStart - 0.2 {
                    player.seek(
                        to: CMTime(seconds: segmentStart, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
            }
        }
    }

    private func teardownPlayer() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func seekPreview(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Scrubbing the key frame pauses playback so the exact frame is visible.
    private func pauseAndShow(_ seconds: Double) {
        player.pause()
        seekPreview(to: seconds)
    }

    private func clampKeyTime() {
        keyTime = min(max(keyTime, segmentStart), segmentEnd)
    }

    // MARK: - Filmstrip

    private func makeFilmstrip(url: URL, count: Int) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return [] }
        var result: [UIImage] = []
        for index in 0..<count {
            let seconds = duration.seconds * (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                result.append(UIImage(cgImage: cgImage))
            }
        }
        return result
    }
}
