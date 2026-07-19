//
//  WaveformExtractor.swift
//  Lively
//
//  Decodes an audio file into a compact array of normalized peak samples for
//  the flat waveform view, plus a safe duration helper. Decoding streams
//  through AVAssetReader in fixed windows, so even long songs use very
//  little memory.
//

import Foundation
import AVFoundation
import CoreMedia

// MARK: - WaveformError

/// Failures reading an audio file for waveform display.
enum WaveformError: LocalizedError {
    case unreadableAudio

    var errorDescription: String? {
        switch self {
        case .unreadableAudio:
            return "This audio file could not be read. Try a different file."
        }
    }
}

// MARK: - WaveformExtractor

/// Stateless audio analysis helpers for the audio panel.
struct WaveformExtractor {

    /// Samples per coarse decode window before re-bucketing — about 43 peaks
    /// per second at 44.1 kHz, which keeps memory tiny while staying well
    /// above display resolution.
    private static let decodeWindowSize = 1024

    // MARK: - Public API

    /// Decodes `url` to linear PCM (Int16, mono, non-interleaved), buckets
    /// absolute sample peaks into `desiredCount` bins, and normalizes the
    /// result to 0...1 by the global maximum peak. An all-silent file yields
    /// all zeros.
    static func samples(from url: URL, desiredCount: Int) async throws -> [Float] {
        guard desiredCount > 0 else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let audioTracks: [AVAssetTrack]
            do {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                throw WaveformError.unreadableAudio
            }
            guard let track = audioTracks.first else {
                throw WaveformError.unreadableAudio
            }
            let coarsePeaks = try Self.decodePeaks(asset: asset, track: track)
            return Self.bucketAndNormalize(coarsePeaks, into: desiredCount)
        }.value
    }

    /// Duration of the audio file in seconds via the async `.duration` load;
    /// 0 when the file cannot be read.
    static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return 0 }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    // MARK: - Decoding

    /// Streams the track as Int16 mono PCM and records the absolute peak of
    /// every `decodeWindowSize`-sample window.
    private static func decodePeaks(asset: AVAsset, track: AVAssetTrack) throws -> [Float] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WaveformError.unreadableAudio
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WaveformError.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else { throw WaveformError.unreadableAudio }

        var peaks: [Float] = []
        var windowPeak: Float = 0
        var windowFill = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount >= MemoryLayout<Int16>.size else { continue }

            var chunk = Data(count: byteCount)
            let copyStatus = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: base
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else { continue }

            chunk.withUnsafeBytes { raw in
                let sampleView = raw.bindMemory(to: Int16.self)
                for sample in sampleView {
                    // `.magnitude` avoids the abs(Int16.min) overflow trap.
                    let magnitude = Float(sample.magnitude)
                    if magnitude > windowPeak { windowPeak = magnitude }
                    windowFill += 1
                    if windowFill == decodeWindowSize {
                        peaks.append(windowPeak)
                        windowPeak = 0
                        windowFill = 0
                    }
                }
            }
        }

        if windowFill > 0 {
            peaks.append(windowPeak)
        }

        switch reader.status {
        case .completed:
            return peaks
        default:
            reader.cancelReading()
            throw WaveformError.unreadableAudio
        }
    }

    // MARK: - Bucketing

    /// Distributes coarse peaks across `desiredCount` bins (max per bin) and
    /// normalizes by the global maximum. All-zero input returns all zeros.
    private static func bucketAndNormalize(_ coarsePeaks: [Float], into desiredCount: Int) -> [Float] {
        var bins = [Float](repeating: 0, count: desiredCount)
        guard !coarsePeaks.isEmpty else { return bins }

        for (index, peak) in coarsePeaks.enumerated() {
            let bin = min(desiredCount - 1, index * desiredCount / coarsePeaks.count)
            if peak > bins[bin] { bins[bin] = peak }
        }

        guard let maxPeak = bins.max(), maxPeak > 0 else { return bins }
        return bins.map { $0 / maxPeak }
    }
}
