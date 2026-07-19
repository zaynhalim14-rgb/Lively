//
//  LivePhotoLoader.swift
//  Lively
//
//  Extracts the two on-disk halves of a picked PHLivePhoto — the still
//  image (.photo resource) and its paired video (.pairedVideo resource) —
//  into the session's working directory. Every downstream stage (preview,
//  filtering, export) works from these plain file URLs, never from the
//  opaque PHLivePhoto itself.
//

import Foundation
import Photos
import UniformTypeIdentifiers

// MARK: - LivePhotoAssetPair

/// The extracted file pair backing a Live Photo editing session.
struct LivePhotoAssetPair: Sendable {
    /// Extracted still image (heic/jpg) inside the working directory.
    let photoURL: URL
    /// Extracted paired video (mov) inside the working directory.
    let videoURL: URL
}

// MARK: - LivePhotoLoaderError

/// Failures that can occur while turning a picked item into an editable pair.
enum LivePhotoLoaderError: LocalizedError {
    /// The picked item could not be loaded as a Live Photo.
    case notALivePhoto
    /// The Live Photo lacks a photo and/or paired video resource.
    case missingResources
    /// Copying a resource to disk failed; the payload is a short detail string.
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notALivePhoto:
            return "That item isn't a Live Photo. Please choose a Live Photo from your library."
        case .missingResources:
            return "This Live Photo is missing its photo or video data, so it can't be edited."
        case .extractionFailed(let detail):
            return "The Live Photo couldn't be prepared for editing. \(detail)"
        }
    }
}

// MARK: - LivePhotoLoader

/// Stateless service that copies a `PHLivePhoto`'s resources to local files.
final class LivePhotoLoader: Sendable {

    init() {}

    // MARK: Working directory

    /// Creates a unique per-session scratch directory:
    /// `<NSTemporaryDirectory()>/LivelySession-<UUID>`.
    static func makeWorkingDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LivelySession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    // MARK: Extraction

    /// Extracts the still and paired-video resources of `livePhoto` into
    /// `directory` and returns their file URLs.
    ///
    /// Uses `PHAssetResource.assetResources(for:)` to locate the `.photo`
    /// and `.pairedVideo` resources, then streams each to disk with
    /// `PHAssetResourceManager.writeData(for:toFile:options:)` with network
    /// access allowed (the original may live in iCloud).
    func extractPair(from livePhoto: PHLivePhoto, into directory: URL) async throws -> LivePhotoAssetPair {
        let resources = PHAssetResource.assetResources(for: livePhoto)

        guard let photoResource = resources.first(where: { $0.type == .photo }),
              let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
            throw LivePhotoLoaderError.missingResources
        }

        let photoURL = directory.appendingPathComponent(
            "source-still.\(Self.fileExtension(for: photoResource, fallback: "heic"))"
        )
        let videoURL = directory.appendingPathComponent(
            "source-video.\(Self.fileExtension(for: videoResource, fallback: "mov"))"
        )

        try await write(resource: photoResource, to: photoURL)
        try await write(resource: videoResource, to: videoURL)

        return LivePhotoAssetPair(photoURL: photoURL, videoURL: videoURL)
    }

    // MARK: Private helpers

    /// Streams one resource to `destination`, bridging the callback API with
    /// a checked continuation. Any pre-existing file at the destination is
    /// removed first because `writeData` refuses to overwrite.
    private func write(resource: PHAssetResource, to destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                throw LivePhotoLoaderError.extractionFailed(error.localizedDescription)
            }
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: destination,
                    options: options
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch let error as LivePhotoLoaderError {
            throw error
        } catch {
            throw LivePhotoLoaderError.extractionFailed(error.localizedDescription)
        }
    }

    /// Best-effort file extension for a resource: prefer the original
    /// filename's extension, then the resource's uniform type identifier,
    /// then the supplied fallback. "jpeg" is normalized to "jpg" so the
    /// export pipeline's extension checks stay simple.
    private static func fileExtension(for resource: PHAssetResource, fallback: String) -> String {
        let fromFilename = (resource.originalFilename as NSString).pathExtension.lowercased()
        if !fromFilename.isEmpty {
            return fromFilename == "jpeg" ? "jpg" : fromFilename
        }
        if let type = UTType(resource.uniformTypeIdentifier),
           let preferred = type.preferredFilenameExtension?.lowercased(),
           !preferred.isEmpty {
            return preferred == "jpeg" ? "jpg" : preferred
        }
        return fallback
    }
}
