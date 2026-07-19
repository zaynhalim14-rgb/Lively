//
//  EditorViewModel.swift
//  Lively
//
//  The single observable model behind the whole editing session. It owns the
//  source Live Photo pair, the edit state, the AVPlayer preview pipeline, and
//  the export flow. Views mutate `editState` (directly or via bindings); the
//  model classifies each change and takes the cheapest path to refresh the
//  preview:
//
//    visual change   -> update the shared VisualStateBox (zero rebuild)
//    mix change      -> swap a new AVAudioMix onto the current player item
//    structure change-> rebuild the AVComposition (debounced)
//

import SwiftUI
import Observation
import AVFoundation
import Photos
import PhotosUI

// MARK: - Editor enums

/// Bottom tab bar tools in the editor.
enum EditorTool: String, CaseIterable, Identifiable {
    case filters
    case adjust
    case audio
    case trim
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filters: return "Filters"
        case .adjust:  return "Adjust"
        case .audio:   return "Audio"
        case .trim:    return "Trim"
        case .export:  return "Export"
        }
    }

    /// SF Symbol for the tool tab.
    var icon: String {
        switch self {
        case .filters: return "camera.filters"
        case .adjust:  return "slider.horizontal.3"
        case .audio:   return "waveform"
        case .trim:    return "timeline.selection"
        case .export:  return "square.and.arrow.up"
        }
    }
}

/// Which preview the canvas shows.
enum PreviewMode: String {
    /// Looping AVPlayer with real-time filters and audio mix.
    case motion
    /// A true assembled PHLivePhoto (press-and-hold to play).
    case live
}

/// State machine for the export flow, drives the export panel UI.
enum ExportPhase: Equatable {
    case idle
    case preparing(String)
    case exporting(Double)
    case done(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .exporting: return true
        default: return false
        }
    }
}

// MARK: - EditorViewModel

@MainActor
@Observable
final class EditorViewModel {

    // MARK: Source

    /// The untouched Live Photo as picked (used for the "before" preview).
    private(set) var sourceLivePhoto: PHLivePhoto?
    /// Extracted still + paired video file URLs in the working directory.
    private(set) var assetPair: LivePhotoAssetPair?
    /// Duration of the paired video in seconds.
    private(set) var videoDuration: TimeInterval = 0
    /// Whether the original video has an audio track.
    private(set) var originalHasAudio = false
    /// Decoded still, downscaled for on-screen use.
    private(set) var stillImage: UIImage?
    /// Small filtered previews for the filter strip.
    private(set) var filterThumbnails: [FilterPreset: UIImage] = [:]
    /// Evenly spaced frames for the trim filmstrip.
    private(set) var filmstrip: [UIImage] = []
    /// True while the picked item is being loaded and prepared.
    private(set) var isLoadingSource = false

    var hasSource: Bool { assetPair != nil }

    // MARK: Edit state

    var editState = EditState() {
        didSet { applyEditStateChange(from: oldValue, to: editState) }
    }

    // MARK: Preview

    let player = AVPlayer()
    private(set) var isPlaying = false
    var previewMode: PreviewMode = .motion
    /// Assembled Live Photo preview (only when previewMode == .live).
    private(set) var livePreview: PHLivePhoto?
    private(set) var isBuildingLivePreview = false

    // MARK: Audio

    let recorder = AudioRecorder()
    /// Peak samples (0...1) of the current soundtrack for the waveform view.
    private(set) var soundtrackWaveform: [Float] = []

    // MARK: UI state

    var activeTool: EditorTool = .filters
    var exportPhase: ExportPhase = .idle
    /// Non-nil presents the share sheet with the rendered video.
    var shareVideoURL: URL?
    /// Non-nil presents an alert.
    var errorMessage: String?

    /// Set by HomeView's PhotosPicker; kicks off loading.
    var pickerItem: PhotosPickerItem? {
        didSet {
            guard let pickerItem else { return }
            Task { await load(item: pickerItem) }
        }
    }

    /// Set by HomeView's video PhotosPicker; kicks off staging for conversion.
    var videoPickerItem: PhotosPickerItem? {
        didSet {
            guard let videoPickerItem else { return }
            Task { await loadVideo(item: videoPickerItem) }
        }
    }

    /// Non-nil presents the Video → Live Photo conversion sheet.
    var pendingVideo: PendingVideo?
    private(set) var isConvertingVideo = false

    // MARK: Engines

    @ObservationIgnored private let loader = LivePhotoLoader()
    @ObservationIgnored private let builder = CompositionBuilder()
    @ObservationIgnored private let exporter = LivePhotoExporter()
    @ObservationIgnored private let converter = VideoConverter()
    @ObservationIgnored private let visualBox = VisualStateBox()
    @ObservationIgnored private var workingDirectory: URL?
    @ObservationIgnored private var currentBundle: CompositionBundle?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var loopObserver: NSObjectProtocol?
    /// Bumped whenever the session is replaced or torn down; long-running
    /// tasks (export, live-preview assembly) capture it and discard their
    /// results if the session changed underneath them.
    @ObservationIgnored private var sessionGeneration = 0
    /// Bumped whenever an edit invalidates the assembled live preview, so an
    /// in-flight assembly never publishes a stale PHLivePhoto.
    @ObservationIgnored private var previewGeneration = 0
    /// Suppresses per-change preview refreshes while adoptSession installs a
    /// new source (it rebuilds exactly once at the end).
    @ObservationIgnored private var isAdoptingSession = false
    /// The trim start baked into the currently playing composition. The
    /// composition timeline is rebased to zero, so seeks must subtract this.
    @ObservationIgnored private var builtTrimStart: TimeInterval = 0
    /// Local copy of a video staged for conversion; tracked separately from
    /// `pendingVideo` so an interactive sheet dismissal can still clean up.
    @ObservationIgnored private var stagedVideoURL: URL?

    init() {}

    // MARK: - Loading

    /// Loads a picked Live Photo: extracts the still/video pair, decodes the
    /// still, builds thumbnails, and starts the looping preview.
    func load(item: PhotosPickerItem) async {
        guard !isLoadingSource else { return }
        isLoadingSource = true
        defer {
            isLoadingSource = false
            pickerItem = nil
        }
        do {
            guard let livePhoto = try await item.loadTransferable(type: PHLivePhoto.self) else {
                throw LivePhotoLoaderError.notALivePhoto
            }
            let directory = try LivePhotoLoader.makeWorkingDirectory()
            let pair = try await loader.extractPair(from: livePhoto, into: directory)

            // Reset the session around the new source.
            cleanupWorkingDirectory()
            workingDirectory = directory
            try await adoptSession(pair: pair)
            sourceLivePhoto = livePhoto
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Installs a still/video pair as the active editing session and starts
    /// the looping preview. Shared by Live Photo loading and video conversion.
    private func adoptSession(pair: LivePhotoAssetPair) async throws {
        let asset = AVURLAsset(url: pair.videoURL)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        sessionGeneration += 1
        previewGeneration += 1
        rebuildTask?.cancel()
        isAdoptingSession = true
        defer { isAdoptingSession = false }

        sourceLivePhoto = nil
        assetPair = pair
        videoDuration = duration
        originalHasAudio = !audioTracks.isEmpty
        editState = EditState()
        editState.trim = TrimSettings(end: duration)
        visualBox.value = VisualState()
        livePreview = nil
        previewMode = .motion
        activeTool = .filters
        exportPhase = .idle
        soundtrackWaveform = []
        configurePlaybackAudioSession()

        await loadStillAndThumbnails(pair: pair)
        await rebuildPreviewItem()
    }

    /// Media apps are expected to play through the silent switch; the default
    /// ambient category would mute the preview on most iPhones.
    private func configurePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    // MARK: - Video conversion

    /// Stages a picked video in the working directory and opens the
    /// conversion sheet.
    func loadVideo(item: PhotosPickerItem) async {
        guard !isLoadingSource else { return }
        isLoadingSource = true
        defer {
            isLoadingSource = false
            videoPickerItem = nil
        }
        do {
            guard let picked = try await item.loadTransferable(type: PickedVideo.self) else {
                throw VideoConverterError.noVideoTrack
            }
            let directory = try requireWorkingDirectory()
            let ext = picked.url.pathExtension.isEmpty ? "mov" : picked.url.pathExtension
            let localURL = directory.appendingPathComponent("SourceVideo-\(UUID().uuidString).\(ext)")
            try FileManager.default.moveItem(at: picked.url, to: localURL)

            let duration = try await AVURLAsset(url: localURL).load(.duration).seconds
            guard duration >= 0.3 else {
                throw VideoConverterError.exportFailed("This video is too short to convert.")
            }
            stagedVideoURL = localURL
            pendingVideo = PendingVideo(url: localURL, duration: duration)
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Converts the staged video's chosen segment + key frame into a pair and
    /// opens it in the editor.
    func convertPendingVideo(segmentStart: TimeInterval,
                             segmentEnd: TimeInterval,
                             keyTime: TimeInterval) async {
        guard let pendingVideo, !isConvertingVideo else { return }
        isConvertingVideo = true
        defer { isConvertingVideo = false }
        do {
            let directory = try requireWorkingDirectory()
            let segment = CMTimeRange(
                start: CMTime(seconds: segmentStart, preferredTimescale: 600),
                end: CMTime(seconds: segmentEnd, preferredTimescale: 600)
            )
            let pair = try await converter.makePair(
                fromVideo: pendingVideo.url,
                segment: segment,
                keyTime: CMTime(seconds: keyTime, preferredTimescale: 600),
                in: directory,
                progress: nil
            )
            try await adoptSession(pair: pair)
            // The source copy is no longer needed once the pair exists.
            try? FileManager.default.removeItem(at: pendingVideo.url)
            stagedVideoURL = nil
            self.pendingVideo = nil
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Discards the staged video and closes the conversion sheet. Also called
    /// from the sheet's onDismiss so an interactive swipe-down (which nils
    /// `pendingVideo` before we hear about it) still cleans up the file.
    func cancelPendingVideo() {
        if let stagedVideoURL {
            try? FileManager.default.removeItem(at: stagedVideoURL)
        }
        stagedVideoURL = nil
        pendingVideo = nil
    }

    private func loadStillAndThumbnails(pair: LivePhotoAssetPair) async {
        let engine = FilterEngine.shared
        stillImage = await engine.decodedStill(from: pair.photoURL, maxDimension: 1600)
        if let base = stillImage {
            filterThumbnails = await engine.presetThumbnails(
                from: base,
                size: CGSize(width: 120, height: 120)
            )
        }
        filmstrip = await makeFilmstrip(videoURL: pair.videoURL, count: 8)
    }

    private func makeFilmstrip(videoURL: URL, count: Int) async -> [UIImage] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return [] }
        var frames: [UIImage] = []
        for index in 0..<count {
            let seconds = duration.seconds * (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                frames.append(UIImage(cgImage: cgImage))
            }
        }
        return frames
    }

    // MARK: - Session lifecycle

    /// Discards the session and returns to the landing screen.
    func reset() {
        sessionGeneration += 1
        previewGeneration += 1
        rebuildTask?.cancel()
        recorder.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeLoopObserver()
        isPlaying = false
        sourceLivePhoto = nil
        assetPair = nil
        stillImage = nil
        filterThumbnails = [:]
        filmstrip = []
        soundtrackWaveform = []
        livePreview = nil
        currentBundle = nil
        builtTrimStart = 0
        editState = EditState()
        visualBox.value = VisualState()
        exportPhase = .idle
        shareVideoURL = nil
        cleanupWorkingDirectory()
    }

    private func cleanupWorkingDirectory() {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
    }

    // MARK: - Edit-state change routing

    private func applyEditStateChange(from old: EditState, to new: EditState) {
        guard hasSource, !isAdoptingSession else { return }

        // Trimming the timeline can strand the soundtrack past the end of the
        // clip; pull its start offset back inside the audible range.
        if old.trim != new.trim,
           let trim = new.trim,
           let track = new.audio.soundtrack,
           track.startOffset > max(0, trim.duration - 0.1) {
            editState.audio.soundtrack?.startOffset = max(0, trim.duration - 0.1)
            return // the nested didSet pass handles the rebuild
        }

        // 1. Visual changes: push into the box; the running compositor
        //    picks them up on the next frame.
        let newVisual = VisualState(from: new)
        if VisualState(from: old) != newVisual {
            visualBox.value = newVisual
            invalidateLivePreview()
        }

        // 2. Structural changes require rebuilding the composition.
        if isStructuralChange(from: old, to: new) {
            schedulePreviewRebuild()
            invalidateLivePreview()
            return
        }

        // 3. Pure mix changes (volumes, fades, mute) just need a new audio mix.
        if old.audio != new.audio {
            refreshAudioMix()
            invalidateLivePreview()
        }
    }

    /// Any edit makes an assembled Live Photo preview stale. Drop it and fall
    /// back to the motion preview so the user never faces an empty canvas.
    /// Bumping the generation also makes any in-flight assembly discard its
    /// result instead of publishing a stale preview.
    private func invalidateLivePreview() {
        previewGeneration += 1
        livePreview = nil
        if previewMode == .live { previewMode = .motion }
    }

    private func isStructuralChange(from old: EditState, to new: EditState) -> Bool {
        if old.trim != new.trim { return true }
        let oldTrack = old.audio.soundtrack
        let newTrack = new.audio.soundtrack
        if (oldTrack == nil) != (newTrack == nil) { return true }
        if let oldTrack, let newTrack {
            if oldTrack.url != newTrack.url { return true }
            if oldTrack.trimStart != newTrack.trimStart { return true }
            if oldTrack.trimEnd != newTrack.trimEnd { return true }
            if oldTrack.startOffset != newTrack.startOffset { return true }
        }
        return false
    }

    // MARK: - Preview pipeline

    private func schedulePreviewRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.rebuildPreviewItem()
        }
    }

    /// Builds a fresh composition + player item from the current edit state.
    /// Preserves the user's playback intent: a paused preview stays paused,
    /// and nothing auto-plays behind the Live Photo canvas.
    func rebuildPreviewItem() async {
        guard let assetPair else { return }
        let shouldPlay = (isPlaying || player.currentItem == nil) && previewMode == .motion
        do {
            let bundle = try await builder.makeBundle(
                pair: assetPair,
                editState: editState,
                visualBox: visualBox
            )
            currentBundle = bundle

            let item = AVPlayerItem(asset: bundle.composition)
            item.videoComposition = bundle.videoComposition
            item.audioMix = bundle.audioMix
            player.replaceCurrentItem(with: item)
            installLoopObserver(for: item)
            builtTrimStart = editState.trim?.start ?? 0
            if shouldPlay { player.play() }
            isPlaying = shouldPlay
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Applies volume/fade changes to the playing item without a rebuild.
    private func refreshAudioMix() {
        guard let bundle = currentBundle, let item = player.currentItem else { return }
        let mix = builder.makeAudioMix(for: bundle, audio: editState.audio)
        item.audioMix = mix
        currentBundle?.audioMix = mix
    }

    // MARK: - Playback control

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    /// Seeks the preview to a time expressed in *source-clip* seconds. The
    /// playing composition is rebased to start at the trim in-point, so the
    /// baked-in offset is subtracted before seeking.
    func seek(to seconds: TimeInterval) {
        let rebased = max(0, seconds - builtTrimStart)
        let time = CMTime(seconds: rebased, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func installLoopObserver(for item: AVPlayerItem) {
        removeLoopObserver()
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.isPlaying { self.player.play() }
            }
        }
    }

    private func removeLoopObserver() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = nil
    }

    // MARK: - Filters & adjustments

    func select(preset: FilterPreset) {
        editState.filter = preset
        if preset == .original {
            editState.filterIntensity = 1
        }
    }

    func resetAdjustments() {
        editState.adjustments = .identity
    }

    // MARK: - Soundtrack

    /// Installs an imported audio file (already copied into the working
    /// directory by the caller or copied here) as the soundtrack.
    func setSoundtrackFile(url: URL, title: String, source: Soundtrack.Source) async {
        do {
            let directory = try requireWorkingDirectory()
            let localURL: URL
            if url.path.hasPrefix(directory.path) {
                localURL = url
            } else {
                localURL = directory.appendingPathComponent(
                    "soundtrack-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)"
                )
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: url, to: localURL)
            }

            let duration = await WaveformExtractor.duration(of: localURL)
            guard duration > 0 else { throw WaveformError.unreadableAudio }

            var track = Soundtrack(url: localURL, title: title, duration: duration, source: source)
            track.trimEnd = min(duration, max(0.5, videoDuration))
            editState.audio.soundtrack = track

            soundtrackWaveform = (try? await WaveformExtractor.samples(from: localURL, desiredCount: 140)) ?? []
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func removeSoundtrack() {
        editState.audio.soundtrack = nil
        soundtrackWaveform = []
    }

    // MARK: - Voiceover

    func startVoiceover() async {
        guard await recorder.requestPermission() else {
            errorMessage = "Microphone access is needed to record a voiceover. You can enable it in Settings."
            return
        }
        player.pause()
        isPlaying = false
        do {
            let directory = try requireWorkingDirectory()
            try recorder.start(in: directory)
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func stopVoiceover() async {
        let url = await recorder.stop()
        // Recording flipped the session to .playAndRecord; put playback back.
        configurePlaybackAudioSession()
        guard let url else { return }
        await setSoundtrackFile(url: url, title: "Voiceover", source: .voiceover)
    }

    // MARK: - Live preview

    /// Renders the processed pair and assembles a true PHLivePhoto for the
    /// press-and-hold preview. Reuses the previous assembly when no edits
    /// have invalidated it — toggling Motion/Live back and forth is free.
    func generateLivePreview() async {
        guard let assetPair, !isBuildingLivePreview else { return }
        guard livePreview == nil else { return }
        let generation = previewGeneration
        let session = sessionGeneration
        isBuildingLivePreview = true
        defer { isBuildingLivePreview = false }
        do {
            let directory = try requireWorkingDirectory()
            let processed = try await exporter.renderProcessedPair(
                pair: assetPair,
                editState: editState,
                in: directory,
                progress: nil
            )
            // Edits or a session change during the render make this result
            // stale — drop it silently (the mode already fell back to motion).
            guard generation == previewGeneration, session == sessionGeneration else { return }
            livePreview = try await exporter.requestLivePhoto(
                photoURL: processed.photoURL,
                videoURL: processed.videoURL
            )
        } catch {
            guard session == sessionGeneration else { return }
            errorMessage = friendlyMessage(for: error)
            previewMode = .motion
        }
    }

    // MARK: - Export

    /// Renders the full-quality pair and writes it to the photo library as a
    /// new Live Photo. If the session is closed mid-export the orphaned task
    /// discards all further state updates instead of leaking them into the
    /// next session.
    func saveLivePhoto() async {
        guard let assetPair, !exportPhase.isBusy else { return }
        let session = sessionGeneration
        exportPhase = .preparing("Rendering…")
        do {
            let directory = try requireWorkingDirectory()
            let processed = try await exporter.renderProcessedPair(
                pair: assetPair,
                editState: editState,
                in: directory,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionGeneration == session else { return }
                        self.exportPhase = .exporting(fraction)
                    }
                }
            )
            guard session == sessionGeneration else { return }
            exportPhase = .preparing("Saving to Photos…")
            try await exporter.saveToPhotoLibrary(
                photoURL: processed.photoURL,
                videoURL: processed.videoURL
            )
            guard session == sessionGeneration else { return }
            exportPhase = .done("Saved as a new Live Photo")
        } catch {
            guard session == sessionGeneration else { return }
            exportPhase = .failed(friendlyMessage(for: error))
        }
    }

    /// Renders a shareable video (filters + soundtrack baked in) and stages it
    /// for the share sheet.
    func prepareShareVideo() async {
        guard let assetPair, !exportPhase.isBusy else { return }
        let session = sessionGeneration
        exportPhase = .preparing("Rendering video…")
        do {
            let directory = try requireWorkingDirectory()
            let url = try await exporter.exportShareableVideo(
                pair: assetPair,
                editState: editState,
                in: directory,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionGeneration == session else { return }
                        self.exportPhase = .exporting(fraction)
                    }
                }
            )
            guard session == sessionGeneration else { return }
            exportPhase = .idle
            shareVideoURL = url
        } catch {
            guard session == sessionGeneration else { return }
            exportPhase = .failed(friendlyMessage(for: error))
        }
    }

    // MARK: - Helpers

    private func requireWorkingDirectory() throws -> URL {
        if let workingDirectory { return workingDirectory }
        let directory = try LivePhotoLoader.makeWorkingDirectory()
        workingDirectory = directory
        return directory
    }

    private func friendlyMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return "Something went wrong: \(error.localizedDescription)"
    }
}
