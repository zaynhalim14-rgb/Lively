//
//  AudioPanelView.swift
//  Lively
//
//  The audio tool panel: level control (and mute) for the Live Photo's
//  original audio, plus an optional soundtrack — imported music or a
//  recorded voiceover — with waveform trimming, timeline offset, volume,
//  and fade in/out. All mutations flow through EditorViewModel's edit
//  state, which routes them to the cheapest preview refresh path.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - AudioPanelView

struct AudioPanelView: View {

    @Environment(EditorViewModel.self) private var model

    /// Presents the system audio file importer.
    @State private var isImportingMusic = false
    /// Drives the recording indicator's pulse animation.
    @State private var isPulsing = false

    // MARK: Body

    var body: some View {
        @Bindable var model = model
        PanelContainer {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: FlatTheme.spacing) {
                    originalAudioSection(volume: $model.editState.audio.originalVolume)
                    sectionDivider
                    soundtrackSection
                }
                .padding(.bottom, FlatTheme.spacingTight)
            }
        }
        .fileImporter(
            isPresented: $isImportingMusic,
            allowedContentTypes: [.audio]
        ) { result in
            handleMusicImport(result)
        }
    }

    // MARK: - Original audio

    @ViewBuilder
    private func originalAudioSection(volume: Binding<Double>) -> some View {
        SectionHeader("Original Audio")
        if model.originalHasAudio {
            HStack(spacing: FlatTheme.spacingTight) {
                muteButton
                FlatSlider(
                    label: "Volume",
                    value: volume,
                    range: 0...1,
                    defaultValue: 1,
                    format: percentFormat
                )
                .disabled(model.editState.audio.isOriginalMuted)
                .opacity(model.editState.audio.isOriginalMuted ? 0.4 : 1)
            }
        } else {
            Text("This Live Photo has no audio")
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.inkSecondary)
        }
    }

    private var muteButton: some View {
        let isMuted = model.editState.audio.isOriginalMuted
        return FlatIconButton(
            systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            label: isMuted ? "Unmute original audio" : "Mute original audio"
        ) {
            model.editState.audio.isOriginalMuted.toggle()
        }
    }

    // MARK: - Soundtrack

    @ViewBuilder
    private var soundtrackSection: some View {
        SectionHeader("Soundtrack")
        if let track = model.editState.audio.soundtrack {
            soundtrackEditor(for: track)
        } else if model.recorder.isRecording {
            recordingRow
        } else {
            emptySoundtrackButtons
        }
    }

    /// Empty state: import a music file or record a voiceover.
    private var emptySoundtrackButtons: some View {
        HStack(spacing: FlatTheme.spacing) {
            Button {
                isImportingMusic = true
            } label: {
                Label("Add Music", systemImage: "music.note")
                    .lineLimit(1)
            }
            .buttonStyle(FlatSecondaryButtonStyle())

            Button {
                Task { await model.startVoiceover() }
            } label: {
                Label("Record Voiceover", systemImage: "mic.fill")
                    .lineLimit(1)
            }
            .buttonStyle(FlatSecondaryButtonStyle())
        }
    }

    // MARK: - Voiceover recording

    /// Shown while the microphone is live: pulsing record dot, elapsed time,
    /// a live level meter, and a stop button.
    private var recordingRow: some View {
        HStack(spacing: FlatTheme.spacing) {
            Circle()
                .fill(FlatTheme.accent)
                .frame(width: 12, height: 12)
                .scaleEffect(isPulsing ? 0.7 : 1)
                .opacity(isPulsing ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
                .onDisappear { isPulsing = false }
                .accessibilityHidden(true)

            Text(model.recorder.elapsed.livelyTimecode)
                .font(FlatTheme.timecodeFont())
                .foregroundStyle(FlatTheme.ink)

            levelMeter

            stopButton
        }
        .padding(.vertical, FlatTheme.spacingTight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording voiceover")
    }

    /// Flat capsule meter whose fill scales with the microphone level.
    private var levelMeter: some View {
        Capsule()
            .fill(FlatTheme.surfaceSecondary)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(FlatTheme.accent)
                    .scaleEffect(x: max(0.03, CGFloat(model.recorder.level)), y: 1, anchor: .leading)
                    .animation(.linear(duration: 0.1), value: model.recorder.level)
            }
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .frame(height: 6)
            .accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int((model.recorder.level * 100).rounded())) percent")
    }

    private var stopButton: some View {
        Button {
            Task { await model.stopVoiceover() }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(FlatTheme.labelFont())
                .foregroundStyle(.white)
                .padding(.vertical, FlatTheme.spacingTight)
                .padding(.horizontal, FlatTheme.spacing)
                .background(
                    RoundedRectangle(cornerRadius: FlatTheme.chipRadius, style: .continuous)
                        .fill(FlatTheme.accent)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }

    // MARK: - Soundtrack editor

    @ViewBuilder
    private func soundtrackEditor(for track: Soundtrack) -> some View {
        // Title row: source icon, name, remove.
        HStack(spacing: FlatTheme.spacingTight) {
            Image(systemName: track.source == .voiceover ? "mic.fill" : "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlatTheme.ocean)
                .accessibilityHidden(true)
            Text(track.title)
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.ink)
                .lineLimit(1)
            Spacer(minLength: FlatTheme.spacingTight)
            FlatIconButton(systemName: "trash", label: "Remove soundtrack") {
                model.removeSoundtrack()
            }
        }

        trimWell(for: track)
        trimReadouts(for: track)

        // Offsets are placed on the *trimmed* timeline — capping the range at
        // the kept duration keeps the soundtrack from being pushed past the
        // end of the clip where it would never be heard.
        FlatSlider(
            label: "Starts at",
            value: soundtrackBinding(\.startOffset),
            range: 0...max(0.1, (model.editState.trim?.duration ?? model.videoDuration) - 0.1),
            defaultValue: 0,
            format: { $0.livelyTimecode }
        )
        FlatSlider(
            label: "Volume",
            value: soundtrackBinding(\.volume),
            range: 0...1,
            defaultValue: 1,
            format: percentFormat
        )
        FlatSlider(
            label: "Fade in",
            value: soundtrackBinding(\.fadeIn),
            range: 0...2,
            defaultValue: 0,
            format: secondsFormat
        )
        FlatSlider(
            label: "Fade out",
            value: soundtrackBinding(\.fadeOut),
            range: 0...2,
            defaultValue: 0,
            format: secondsFormat
        )
    }

    /// Waveform in a flat well with the trim range slider on top.
    private func trimWell(for track: Soundtrack) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: FlatTheme.chipRadius, style: .continuous)
                .fill(FlatTheme.surfaceSecondary)
            WaveformView(samples: model.soundtrackWaveform, color: FlatTheme.ocean)
                .padding(.horizontal, FlatTheme.spacingTight)
                .padding(.vertical, 6)
            RangeSlider(
                lowerValue: soundtrackBinding(\.trimStart),
                upperValue: soundtrackBinding(\.trimEnd),
                bounds: 0...max(track.duration, 0.1)
            )
        }
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: FlatTheme.chipRadius, style: .continuous))
    }

    /// In-point, kept duration, and out-point readouts under the waveform.
    private func trimReadouts(for track: Soundtrack) -> some View {
        HStack {
            Text(track.trimStart.livelyTimecode)
            Spacer()
            Text("\(track.trimmedDuration.livelyTimecode) kept")
            Spacer()
            Text(track.trimEnd.livelyTimecode)
        }
        .font(FlatTheme.timecodeFont())
        .foregroundStyle(FlatTheme.inkSecondary)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bindings

    /// Guard-let binding into the optional soundtrack: reads fall back to 0
    /// when the track is gone, writes are dropped instead of crashing.
    private func soundtrackBinding(_ keyPath: WritableKeyPath<Soundtrack, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let track = model.editState.audio.soundtrack else { return 0 }
                return track[keyPath: keyPath]
            },
            set: { newValue in
                guard var track = model.editState.audio.soundtrack else { return }
                track[keyPath: keyPath] = newValue
                model.editState.audio.soundtrack = track
            }
        )
    }

    // MARK: - Import handling

    private func handleMusicImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                await model.setSoundtrackFile(
                    url: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    source: .importedFile
                )
            }
        case .failure(let error):
            model.errorMessage = "Couldn't import that audio file: \(error.localizedDescription)"
        }
    }

    // MARK: - Formatting

    private func percentFormat(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func secondsFormat(_ value: Double) -> String {
        String(format: "%.1fs", value)
    }

    // MARK: - Chrome

    private var sectionDivider: some View {
        Rectangle()
            .fill(FlatTheme.hairline)
            .frame(height: FlatTheme.hairlineWidth)
    }
}
