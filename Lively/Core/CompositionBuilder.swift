//
//  CompositionBuilder.swift
//  Lively
//
//  Turns the source Live Photo video plus the current EditState into an
//  AVComposition bundle: trimmed video + original audio, an optional
//  soundtrack track, a per-frame Core Image video composition that reads
//  the shared VisualStateBox, and an AVAudioMix with volume and fades.
//  The same bundle powers both the live preview player and the exporter,
//  so what the user sees is exactly what gets rendered.
//

import Foundation
import AVFoundation
import CoreImage
import CoreMedia

// MARK: - CompositionBundle

/// Everything needed to play or export the current edit.
struct CompositionBundle {
    /// The assembled (trimmed, multi-track) composition.
    let composition: AVComposition
    /// Per-frame Core Image filtering composition (always present).
    let videoComposition: AVVideoComposition?
    /// Volume/fade mix. Mutable so a mix-only change can be swapped in place.
    var audioMix: AVAudioMix?
    /// Total timeline duration of the composition.
    let duration: CMTime
    /// Track ID of the original audio inside `composition`; nil if the
    /// source video has no audio track.
    let originalAudioTrackID: CMPersistentTrackID?
    /// Track ID of the soundtrack inside `composition`; nil if no soundtrack
    /// was added (or it fell entirely outside the timeline).
    let soundtrackTrackID: CMPersistentTrackID?
    /// Where the soundtrack sits on the composition timeline.
    let soundtrackRange: CMTimeRange?
}

// MARK: - CompositionError

enum CompositionError: LocalizedError {
    case noVideoTrack
    case buildFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "This Live Photo's video has no video track, so it can't be edited."
        case .buildFailed(let reason):
            return "Couldn't prepare the preview: \(reason)"
        }
    }
}

// MARK: - CompositionBuilder

/// Stateless factory for `CompositionBundle`s and `AVAudioMix`es.
final class CompositionBuilder: Sendable {

    /// Common timescale for all timeline math (600 divides evenly by every
    /// common frame rate).
    private static let timescale: CMTimeScale = 600

    init() {}

    // MARK: - Bundle building

    /// Builds the full composition bundle for the given edit state.
    ///
    /// - Timeline: the trim range from `editState.trim`, clamped to the real
    ///   asset duration (nil trim = the whole clip).
    /// - Video: inserted at `.zero`, carrying over the source's preferred
    ///   transform so orientation is preserved.
    /// - Original audio: inserted for the same range when the source has an
    ///   audio track.
    /// - Soundtrack: the trimmed clip inserted at its start offset, capped to
    ///   the remaining timeline.
    /// - Video composition: per-frame Core Image handler that reads
    ///   `visualBox.value`, so slider changes restyle the running preview
    ///   without any rebuild.
    func makeBundle(pair: LivePhotoAssetPair,
                    editState: EditState,
                    visualBox: VisualStateBox) async throws -> CompositionBundle {
        let sourceAsset = AVURLAsset(url: pair.videoURL)

        // Load everything we need from the source up front (modern async API).
        let assetDuration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            assetDuration = try await sourceAsset.load(.duration)
            videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
            audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        } catch {
            throw CompositionError.buildFailed(error.localizedDescription)
        }
        guard let sourceVideoTrack = videoTracks.first else {
            throw CompositionError.noVideoTrack
        }
        let preferredTransform: CGAffineTransform
        do {
            preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        } catch {
            throw CompositionError.buildFailed(error.localizedDescription)
        }

        let totalSeconds = assetDuration.seconds
        guard totalSeconds > 0 else {
            throw CompositionError.buildFailed("The source video is empty.")
        }

        // Clamp the trim range against the actual asset duration.
        let timeRange = Self.clampedTimeRange(trim: editState.trim, totalSeconds: totalSeconds)

        // Assemble the composition.
        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CompositionError.buildFailed("Couldn't create a video track.")
        }
        do {
            try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
        } catch {
            throw CompositionError.buildFailed(error.localizedDescription)
        }
        compositionVideoTrack.preferredTransform = preferredTransform

        var originalAudioTrackID: CMPersistentTrackID?
        if let sourceAudioTrack = audioTracks.first {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw CompositionError.buildFailed("Couldn't create an audio track.")
            }
            do {
                try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
            } catch {
                throw CompositionError.buildFailed(error.localizedDescription)
            }
            originalAudioTrackID = compositionAudioTrack.trackID
        }

        var soundtrackTrackID: CMPersistentTrackID?
        var soundtrackRange: CMTimeRange?
        if let soundtrack = editState.audio.soundtrack {
            (soundtrackTrackID, soundtrackRange) = try await insertSoundtrack(
                soundtrack,
                into: composition,
                timelineDuration: timeRange.duration
            )
        }

        // Per-frame Core Image styling. The handler runs on the video render
        // queue; VisualStateBox and FilterEngine are both thread-safe.
        let videoComposition: AVMutableVideoComposition
        do {
            videoComposition = try await AVMutableVideoComposition.videoComposition(
                with: composition,
                applyingCIFiltersWithHandler: { request in
                    let state = visualBox.value
                    let styled = FilterEngine.shared
                        .apply(state, to: request.sourceImage)
                        .cropped(to: request.sourceImage.extent)
                    request.finish(with: styled, context: FilterEngine.shared.ciContext)
                }
            )
        } catch {
            throw CompositionError.buildFailed(error.localizedDescription)
        }

        var bundle = CompositionBundle(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: nil,
            duration: timeRange.duration,
            originalAudioTrackID: originalAudioTrackID,
            soundtrackTrackID: soundtrackTrackID,
            soundtrackRange: soundtrackRange
        )
        bundle.audioMix = makeAudioMix(for: bundle, audio: editState.audio)
        return bundle
    }

    // MARK: - Audio mix

    /// Rebuilds only the `AVAudioMix` for an existing bundle, so volume,
    /// mute, and fade changes never require re-inserting tracks.
    ///
    /// Returns nil when the bundle contains no audio tracks at all.
    func makeAudioMix(for bundle: CompositionBundle, audio: AudioSettings) -> AVAudioMix? {
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        // Original audio: flat gain (0 when muted) from the very start.
        if let originalID = bundle.originalAudioTrackID,
           let originalTrack = bundle.composition.tracks.first(where: { $0.trackID == originalID }) {
            let parameters = AVMutableAudioMixInputParameters(track: originalTrack)
            parameters.setVolume(Float(audio.effectiveOriginalVolume), at: .zero)
            inputParameters.append(parameters)
        }

        // Soundtrack: base gain plus optional fade-in/out ramps.
        if let soundtrack = audio.soundtrack,
           let soundtrackID = bundle.soundtrackTrackID,
           let range = bundle.soundtrackRange,
           let soundtrackTrack = bundle.composition.tracks.first(where: { $0.trackID == soundtrackID }) {
            let parameters = AVMutableAudioMixInputParameters(track: soundtrackTrack)
            let volume = Float(min(max(soundtrack.volume, 0), 1))
            parameters.setVolume(volume, at: range.start)

            let rangeSeconds = range.duration.seconds
            var fadeIn = max(0, soundtrack.fadeIn)
            var fadeOut = max(0, soundtrack.fadeOut)
            // If the fades overlap, cap each to half the clip so they never cross.
            if fadeIn + fadeOut > rangeSeconds {
                fadeIn = min(fadeIn, rangeSeconds / 2)
                fadeOut = min(fadeOut, rangeSeconds / 2)
            }

            if fadeIn > 0 {
                let fadeDuration = CMTime(seconds: fadeIn, preferredTimescale: Self.timescale)
                parameters.setVolumeRamp(
                    fromStartVolume: 0,
                    toEndVolume: volume,
                    timeRange: CMTimeRange(start: range.start, duration: fadeDuration)
                )
            }
            if fadeOut > 0 {
                let fadeDuration = CMTime(seconds: fadeOut, preferredTimescale: Self.timescale)
                let fadeStart = CMTimeMaximum(CMTimeSubtract(range.end, fadeDuration), range.start)
                parameters.setVolumeRamp(
                    fromStartVolume: volume,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(start: fadeStart, duration: fadeDuration)
                )
            }
            inputParameters.append(parameters)
        }

        guard !inputParameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputParameters
        return mix
    }

    // MARK: - Soundtrack insertion

    /// Inserts the trimmed soundtrack clip at its timeline offset.
    ///
    /// Returns (nil, nil) — rather than throwing — when the clip contributes
    /// nothing: zero trimmed length, an offset past the end of the timeline,
    /// or an audio file with no readable audio track. Throws only when track
    /// creation or insertion genuinely fails.
    private func insertSoundtrack(_ soundtrack: Soundtrack,
                                  into composition: AVMutableComposition,
                                  timelineDuration: CMTime) async throws
        -> (trackID: CMPersistentTrackID?, range: CMTimeRange?) {
        let timelineSeconds = timelineDuration.seconds
        let startOffset = max(0, soundtrack.startOffset)
        guard soundtrack.trimmedDuration > 0, startOffset < timelineSeconds else {
            return (nil, nil)
        }

        let audioAsset = AVURLAsset(url: soundtrack.url)
        let sourceTracks: [AVAssetTrack]
        let audioDuration: CMTime
        do {
            sourceTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            audioDuration = try await audioAsset.load(.duration)
        } catch {
            throw CompositionError.buildFailed(error.localizedDescription)
        }
        guard let sourceTrack = sourceTracks.first else { return (nil, nil) }

        // Clamp the source window against the real audio file duration and
        // cap the inserted length to the remaining timeline.
        let audioSeconds = audioDuration.seconds
        let sourceStart = min(max(0, soundtrack.trimStart), audioSeconds)
        let available = audioSeconds - sourceStart
        let insertSeconds = min(soundtrack.trimmedDuration, timelineSeconds - startOffset, available)
        guard insertSeconds > 0 else { return (nil, nil) }

        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CompositionError.buildFailed("Couldn't create a soundtrack track.")
        }

        let sourceRange = CMTimeRange(
            start: CMTime(seconds: sourceStart, preferredTimescale: Self.timescale),
            duration: CMTime(seconds: insertSeconds, preferredTimescale: Self.timescale)
        )
        let insertionTime = CMTime(seconds: startOffset, preferredTimescale: Self.timescale)
        do {
            try compositionTrack.insertTimeRange(sourceRange, of: sourceTrack, at: insertionTime)
        } catch {
            throw CompositionError.buildFailed(error.localizedDescription)
        }

        let timelineRange = CMTimeRange(start: insertionTime, duration: sourceRange.duration)
        return (compositionTrack.trackID, timelineRange)
    }

    // MARK: - Trim clamping

    /// Clamps the user's trim range against the actual asset duration.
    /// A nil trim — or a range that collapses to nothing after clamping —
    /// yields the full clip.
    private static func clampedTimeRange(trim: TrimSettings?, totalSeconds: Double) -> CMTimeRange {
        var startSeconds: Double = 0
        var endSeconds = totalSeconds
        if let trim {
            startSeconds = min(max(0, trim.start), totalSeconds)
            endSeconds = min(max(startSeconds, trim.end), totalSeconds)
        }
        // Degenerate range after clamping: fall back to the whole clip.
        if endSeconds - startSeconds <= 0 {
            startSeconds = 0
            endSeconds = totalSeconds
        }
        return CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: timescale),
            end: CMTime(seconds: endSeconds, preferredTimescale: timescale)
        )
    }
}
