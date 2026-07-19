//
//  AudioRecorder.swift
//  Lively
//
//  Voiceover capture for the audio panel. Wraps AVAudioRecorder behind the
//  iOS 17 permission API, publishes elapsed time and a normalized metering
//  level roughly ten times per second while recording, and hands back the
//  finished m4a file URL on stop.
//

import Foundation
import AVFoundation
import Observation

// MARK: - AudioRecorderError

/// Failures starting a voiceover recording.
enum AudioRecorderError: LocalizedError {
    /// `AVAudioRecorder.record()` returned false.
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "The voiceover recording could not be started. Please try again."
        }
    }
}

// MARK: - AudioRecorder

/// Records mono AAC voiceovers into the session's working directory and
/// exposes live metering for the record UI.
@MainActor
@Observable
final class AudioRecorder {

    // MARK: Observable state

    /// True from a successful `start(in:)` until `stop()` completes.
    private(set) var isRecording = false
    /// Seconds recorded so far; updated ~10x per second while recording.
    private(set) var elapsed: TimeInterval = 0
    /// Normalized microphone level 0...1, derived from average power metering.
    private(set) var level: Float = 0

    // MARK: Private state

    /// The active recorder, non-nil only while a recording session is open.
    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// Drives `elapsed` / `level` updates while recording.
    @ObservationIgnored private var meterTimer: Timer?
    /// Destination of the recording currently in flight.
    @ObservationIgnored private var fileURL: URL?
    /// NSObject bridge for AVAudioRecorderDelegate callbacks.
    @ObservationIgnored private let delegateProxy = RecorderDelegateProxy()

    init() {}

    // MARK: - Permission

    /// Asks for (or returns the already-decided) microphone record permission.
    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Recording

    /// Configures the shared audio session for play-and-record and starts a
    /// new AAC (m4a, 44.1 kHz, mono, high quality) recording inside
    /// `directory`, then begins metering.
    func start(in directory: URL) throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = directory.appendingPathComponent("voiceover-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let newRecorder: AVAudioRecorder
        do {
            newRecorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            deactivateSession()
            throw error
        }
        newRecorder.delegate = delegateProxy
        newRecorder.isMeteringEnabled = true

        guard newRecorder.record() else {
            deactivateSession()
            throw AudioRecorderError.couldNotStart
        }

        recorder = newRecorder
        fileURL = url
        elapsed = 0
        level = 0
        isRecording = true
        startMeterTimer()
    }

    /// Stops the recording, waits for the file to finalize, deactivates the
    /// audio session, and returns the recorded file URL — or nil when nothing
    /// usable was captured.
    func stop() async -> URL? {
        stopMeterTimer()

        guard let recorder else {
            isRecording = false
            level = 0
            return nil
        }
        self.recorder = nil
        isRecording = false

        var finishedCleanly = true
        if recorder.isRecording {
            finishedCleanly = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                delegateProxy.installCompletion { success in
                    continuation.resume(returning: success)
                }
                recorder.stop()
            }
        } else {
            // The recording already ended on its own (e.g. an encode error);
            // make sure the recorder is fully torn down anyway.
            recorder.stop()
            finishedCleanly = false
        }
        level = 0
        deactivateSession()

        let url = fileURL
        fileURL = nil

        guard finishedCleanly,
              let url,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue > 0
        else {
            return nil
        }
        return url
    }

    /// Synchronously abandons an in-flight recording: stops the hardware,
    /// deletes the partial file, and deactivates the audio session. Used when
    /// the editor session is torn down so the microphone never stays live
    /// after the editor closes.
    func cancel() {
        stopMeterTimer()
        level = 0
        elapsed = 0
        isRecording = false

        if let recorder {
            recorder.stop()
            self.recorder = nil
            deactivateSession()
        }
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }

    // MARK: - Metering

    private func startMeterTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            // The timer is scheduled on the main run loop, so its callbacks
            // arrive on the main thread and the main actor is safe to assume.
            MainActor.assumeIsolated {
                self?.updateMeters()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeters() {
        guard let recorder, isRecording else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        level = AudioRecorder.normalizedLevel(fromDecibels: recorder.averagePower(forChannel: 0))
    }

    /// Maps average power in dBFS onto 0...1, treating -50 dB as silence and
    /// 0 dB as full scale.
    private static func normalizedLevel(fromDecibels decibels: Float) -> Float {
        let clamped = min(max(decibels, -50), 0)
        return (clamped + 50) / 50
    }

    // MARK: - Session teardown

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// MARK: - RecorderDelegateProxy

/// NSObject delegate bridge. AVAudioRecorder's delegate callbacks may arrive
/// off the main actor, so the completion hand-off is lock-protected and is
/// guaranteed to fire at most once per installed handler.
private final class RecorderDelegateProxy: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?

    /// Installs a one-shot completion invoked by the next finish or error callback.
    func installCompletion(_ handler: @escaping (Bool) -> Void) {
        lock.lock()
        completion = handler
        lock.unlock()
    }

    private func finish(success: Bool) {
        lock.lock()
        let handler = completion
        completion = nil
        lock.unlock()
        handler?(success)
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        finish(success: flag)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        finish(success: false)
    }
}
