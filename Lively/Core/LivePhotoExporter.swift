//
//  LivePhotoExporter.swift
//  Lively
//
//  The export pipeline: renders the edited composition to a processed video,
//  bakes the visual edits into a matching still, stitches the two back into a
//  recognized Live Photo pair, and hands the results to Photos or the share
//  sheet. Orchestrates CompositionBuilder + FilterEngine + LivePhotoAssembler
//  so preview and export share one code path.
//

import Foundation
import AVFoundation
import Photos
import UIKit

// MARK: - ExportError

/// Failures surfaced by the export pipeline, with user-facing descriptions.
enum ExportError: LocalizedError {
    /// Photo-library add permission was denied or restricted.
    case photoLibraryDenied
    /// The AVFoundation export failed; the payload is a human-readable reason.
    case exportFailed(String)
    /// The processed pair could not be assembled into a PHLivePhoto.
    case livePhotoAssemblyFailed

    var errorDescription: String? {
        switch self {
        case .photoLibraryDenied:
            return "Allow Lively to add to your photo library in Settings."
        case .exportFailed(let reason):
            return "The export didn't finish. \(reason)"
        case .livePhotoAssemblyFailed:
            return "The edited Live Photo couldn't be assembled. Please try again."
        }
    }
}

// MARK: - LivePhotoExporter

/// Renders full-quality output from a `LivePhotoAssetPair` + `EditState`.
///
/// Two products are supported:
/// - a processed still/video pair assembled as a true Live Photo
///   (`renderProcessedPair` → `saveToPhotoLibrary` / `requestLivePhoto`)
/// - a flat shareable video with everything baked in (`exportShareableVideo`)
final class LivePhotoExporter {

    // MARK: Dependencies

    private let builder = CompositionBuilder()
    private let assembler = LivePhotoAssembler()

    init() {}

    // MARK: - Processed pair

    /// Renders the fully processed still + video pair into `directory`.
    ///
    /// Progress spans: video export maps to 0...0.65, the filtered still
    /// reports 0.8, and the assembled Live Photo pair reports 1.0.
    ///
    /// - Parameters:
    ///   - pair: The extracted source still/video pair.
    ///   - editState: The complete edit document to bake in.
    ///   - directory: Working directory that receives all intermediate and
    ///     final files.
    ///   - progress: Optional overall-progress callback (0...1), invoked on
    ///     arbitrary threads.
    /// - Returns: File URLs of the assembled Live Photo still and video.
    func renderProcessedPair(pair: LivePhotoAssetPair,
                             editState: EditState,
                             in directory: URL,
                             progress: (@Sendable (Double) -> Void)?) async throws
        -> (photoURL: URL, videoURL: URL) {

        progress?(0)

        // Snapshot the visual state so slider changes made while exporting
        // cannot leak into the render.
        let visual = VisualState(from: editState)
        let snapshotBox = VisualStateBox(visual)

        let bundle = try await builder.makeBundle(
            pair: pair,
            editState: editState,
            visualBox: snapshotBox
        )

        // 1. Processed video (progress 0...0.65).
        let processedMovURL = directory.appendingPathComponent(
            "processed-\(UUID().uuidString).mov"
        )
        try await exportComposition(
            bundle: bundle,
            to: processedMovURL,
            fileType: .mov,
            progressSpan: 0...0.65,
            progress: progress
        )

        // 2. Filtered still, matching the source container format (0.8).
        let stillExtension = pair.photoURL.pathExtension.lowercased() == "heic" ? "heic" : "jpg"
        let processedStillURL = directory.appendingPathComponent(
            "processed-\(UUID().uuidString).\(stillExtension)"
        )
        try FilterEngine.shared.renderFilteredStill(
            photoURL: pair.photoURL,
            visual: visual,
            to: processedStillURL
        )
        progress?(0.8)

        // 3. Stitch into a recognized Live Photo pair (1.0).
        let assembled = try await assembler.makePair(
            photoURL: processedStillURL,
            metadataSourceURL: pair.photoURL,
            videoURL: processedMovURL,
            in: directory
        )
        progress?(1.0)

        return (photoURL: assembled.photoURL, videoURL: assembled.videoURL)
    }

    // MARK: - Live Photo assembly

    /// Builds an in-memory `PHLivePhoto` from an assembled still/video pair,
    /// for the press-and-hold preview.
    ///
    /// `PHLivePhoto.request` may call its handler twice — first with a
    /// degraded placeholder, then with the final result — so the continuation
    /// is resumed exactly once, on the non-degraded callback.
    func requestLivePhoto(photoURL: URL, videoURL: URL) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            _ = PHLivePhoto.request(
                withResourceFileURLs: [photoURL, videoURL],
                placeholderImage: nil,
                targetSize: .zero,
                contentMode: .aspectFit
            ) { livePhoto, info in
                let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue ?? false
                guard !isDegraded, !hasResumed else { return }
                hasResumed = true
                if let livePhoto {
                    continuation.resume(returning: livePhoto)
                } else {
                    continuation.resume(throwing: ExportError.livePhotoAssemblyFailed)
                }
            }
        }
    }

    // MARK: - Photo library

    /// Saves an assembled pair to the photo library as a new Live Photo.
    /// Requires add-only authorization (`.authorized` or `.limited`).
    func saveToPhotoLibrary(photoURL: URL, videoURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photoLibraryDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                creation.addResource(with: .photo, fileURL: photoURL, options: options)
                creation.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
            }
        } catch {
            throw ExportError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: - Shareable video

    /// Renders a flat `.mp4` with filters, trim, and the audio mix baked in,
    /// suitable for the share sheet. Progress maps the full 0...1 span.
    func exportShareableVideo(pair: LivePhotoAssetPair,
                              editState: EditState,
                              in directory: URL,
                              progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        progress?(0)

        let snapshotBox = VisualStateBox(VisualState(from: editState))
        let bundle = try await builder.makeBundle(
            pair: pair,
            editState: editState,
            visualBox: snapshotBox
        )

        let outputURL = directory.appendingPathComponent(
            "Lively-Share-\(UUID().uuidString).mp4"
        )
        try await exportComposition(
            bundle: bundle,
            to: outputURL,
            fileType: .mp4,
            progressSpan: 0...1,
            progress: progress
        )
        return outputURL
    }

    // MARK: - Export session plumbing

    /// Exports a bundle's composition (with its video composition and audio
    /// mix) to `outputURL`, polling session progress into `progressSpan`.
    private func exportComposition(bundle: CompositionBundle,
                                   to outputURL: URL,
                                   fileType: AVFileType,
                                   progressSpan: ClosedRange<Double>,
                                   progress: (@Sendable (Double) -> Void)?) async throws {
        guard let session = AVAssetExportSession(
            asset: bundle.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportFailed("An export session couldn't be created.")
        }

        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = fileType
        session.videoComposition = bundle.videoComposition
        session.audioMix = bundle.audioMix
        session.shouldOptimizeForNetworkUse = true

        // Poll the session's progress every 200 ms while the export runs,
        // mapping the raw 0...1 fraction into the caller's span.
        var poller: Task<Void, Never>?
        if let progress {
            poller = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    let fraction = Double(min(max(session.progress, 0), 1))
                    let mapped = progressSpan.lowerBound
                        + fraction * (progressSpan.upperBound - progressSpan.lowerBound)
                    progress(mapped)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }

        // exportAsynchronously always invokes its handler exactly once, so
        // bridging with a non-throwing continuation and checking status
        // afterwards is safe (and remains iOS 17 compatible).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        poller?.cancel()

        switch session.status {
        case .completed:
            progress?(progressSpan.upperBound)
        case .cancelled:
            throw ExportError.exportFailed("The export was cancelled.")
        default:
            let reason = session.error?.localizedDescription ?? "The video couldn't be written."
            throw ExportError.exportFailed(reason)
        }
    }
}
