//
//  VideoConverter.swift
//  Lively
//
//  Turns an ordinary video into Live Photo raw material: a trimmed segment
//  plus a full-resolution key frame. The result is a LivePhotoAssetPair, so
//  a converted video flows through the exact same editing and export
//  pipeline as a picked Live Photo — pairing metadata is injected later by
//  LivePhotoAssembler at save time.
//

import Foundation
import AVFoundation
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers

// MARK: - PendingVideo

/// A video picked from the library, staged in the working directory and
/// awaiting segment/key-frame selection in the conversion sheet.
struct PendingVideo: Identifiable {
    let id: UUID
    /// Local copy inside the session's working directory.
    let url: URL
    /// Full duration of the staged video, in seconds.
    let duration: TimeInterval

    init(url: URL, duration: TimeInterval) {
        self.id = UUID()
        self.url = url
        self.duration = duration
    }
}

// MARK: - PickedVideo

/// Transferable wrapper so a PhotosPickerItem can deliver a movie as a file
/// URL. The received file is copied to a unique temp location because the
/// system deletes its copy once the closure returns.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("LivelyImport-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideo(url: destination)
        }
    }
}

// MARK: - Errors

enum VideoConverterError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)
    case stillGenerationFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "This file doesn't contain a video track."
        case .exportFailed(let reason):
            return "The video segment couldn't be exported. \(reason)"
        case .stillGenerationFailed:
            return "A still frame couldn't be captured from this video."
        }
    }
}

// MARK: - VideoConverter

final class VideoConverter: Sendable {

    init() {}

    /// Produces Live Photo raw material from `videoURL`:
    /// 1. Exports `segment` losslessly (passthrough; falls back to a
    ///    re-encode when the source codec can't be passed through).
    /// 2. Captures a full-resolution still at `keyTime` and writes it as HEIC.
    ///
    /// - Parameters:
    ///   - segment: The chosen range, clamped to the asset's duration.
    ///   - keyTime: Timestamp of the key frame, clamped into `segment`.
    ///   - directory: Output directory (the session's working directory).
    ///   - progress: 0...1 across export and still capture.
    func makePair(fromVideo videoURL: URL,
                  segment: CMTimeRange,
                  keyTime: CMTime,
                  in directory: URL,
                  progress: (@Sendable (Double) -> Void)?) async throws -> LivePhotoAssetPair {
        let asset = AVURLAsset(url: videoURL)
        guard let _ = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoConverterError.noVideoTrack
        }
        let assetDuration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: assetDuration)
        let clampedSegment = segment.intersection(fullRange)
        guard clampedSegment.duration.seconds > 0.1 else {
            throw VideoConverterError.exportFailed("The selected segment is too short.")
        }

        let videoOutput = try await exportSegment(
            of: asset,
            range: clampedSegment,
            to: directory,
            progress: progress
        )

        // Clamp into the segment, then nudge off the exact end: sampling at
        // precisely the last timestamp fails on some assets.
        var clampedKeyTime = CMTimeClampToRange(keyTime, range: clampedSegment)
        let latestSafeKeyTime = clampedSegment.end - CMTime(value: 3, timescale: 60)
        if clampedKeyTime >= latestSafeKeyTime, latestSafeKeyTime > clampedSegment.start {
            clampedKeyTime = latestSafeKeyTime
        }
        let photoOutput = try await captureStill(
            from: asset,
            at: clampedKeyTime,
            to: directory
        )
        progress?(1.0)

        return LivePhotoAssetPair(photoURL: photoOutput, videoURL: videoOutput)
    }

    // MARK: - Segment export

    private func exportSegment(of asset: AVURLAsset,
                               range: CMTimeRange,
                               to directory: URL,
                               progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        // Passthrough keeps the original encoding (fast, lossless); some
        // sources can't be passed through into QuickTime, so fall back to a
        // high-quality re-encode.
        do {
            return try await runExport(
                of: asset,
                preset: AVAssetExportPresetPassthrough,
                range: range,
                to: directory,
                progress: progress
            )
        } catch {
            return try await runExport(
                of: asset,
                preset: AVAssetExportPresetHighestQuality,
                range: range,
                to: directory,
                progress: progress
            )
        }
    }

    private func runExport(of asset: AVURLAsset,
                           preset: String,
                           range: CMTimeRange,
                           to directory: URL,
                           progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoConverterError.exportFailed("The export session couldn't be created.")
        }
        let outputURL = directory.appendingPathComponent("Converted-\(UUID().uuidString).mov")
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.timeRange = range

        let poller = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress) * 0.85)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            return outputURL
        case .cancelled:
            throw VideoConverterError.exportFailed("The export was cancelled.")
        default:
            let reason = session.error?.localizedDescription ?? "Unknown error."
            throw VideoConverterError.exportFailed(reason)
        }
    }

    // MARK: - Key frame capture

    private func captureStill(from asset: AVURLAsset,
                              at time: CMTime,
                              to directory: URL) async throws -> URL {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: time).image
        } catch {
            throw VideoConverterError.stillGenerationFailed
        }

        let outputURL = directory.appendingPathComponent("KeyFrame-\(UUID().uuidString).heic")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw VideoConverterError.stillGenerationFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw VideoConverterError.stillGenerationFailed
        }
        return outputURL
    }
}
