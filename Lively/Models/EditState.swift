//
//  EditState.swift
//  Lively
//
//  The complete, value-typed description of every edit the user has made.
//  This is the single source of truth the preview pipeline and the exporter
//  both consume, so preview and export can never drift apart.
//

import Foundation

// MARK: - Adjustments

/// Fine image adjustments layered on top of the selected filter preset.
/// All values are normalized; `FilterEngine` maps them onto Core Image
/// parameter ranges.
struct Adjustments: Equatable {
    /// Exposure in normalized EV, -1...1 (maps to about -1.5...+1.5 EV).
    var exposure: Double = 0
    /// Brightness offset, -1...1.
    var brightness: Double = 0
    /// Contrast, -1...1 around neutral.
    var contrast: Double = 0
    /// Saturation, -1...1 around neutral (-1 is grayscale).
    var saturation: Double = 0
    /// Vibrance, -1...1.
    var vibrance: Double = 0
    /// Color temperature shift, -1 (cool) ... 1 (warm).
    var warmth: Double = 0
    /// Vignette strength, 0...1.
    var vignette: Double = 0
    /// Luminance sharpening, 0...1.
    var sharpness: Double = 0

    static let identity = Adjustments()

    var isIdentity: Bool { self == .identity }
}

// MARK: - Soundtrack

/// An audio clip mixed over (or replacing) the Live Photo's original audio.
struct Soundtrack: Equatable, Identifiable {
    enum Source: String, Equatable {
        case importedFile
        case voiceover
    }

    let id: UUID
    /// Local file URL inside the session's working directory.
    var url: URL
    /// Human-readable title shown in the audio panel.
    var title: String
    /// Full duration of the audio file, in seconds.
    var duration: TimeInterval
    /// Where playback begins inside the audio file (trim in-point), seconds.
    var trimStart: TimeInterval = 0
    /// Where playback ends inside the audio file (trim out-point), seconds.
    var trimEnd: TimeInterval
    /// Delay from the start of the video timeline before the clip begins, seconds.
    var startOffset: TimeInterval = 0
    /// Linear gain 0...1.
    var volume: Double = 1
    /// Fade-in length in seconds (0 = no fade).
    var fadeIn: TimeInterval = 0
    /// Fade-out length in seconds (0 = no fade).
    var fadeOut: TimeInterval = 0
    /// Where the clip came from (file import vs. recorded voiceover).
    var source: Source

    init(url: URL, title: String, duration: TimeInterval, source: Source) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.duration = duration
        self.trimEnd = duration
        self.source = source
    }

    /// Length of the trimmed clip, in seconds.
    var trimmedDuration: TimeInterval { max(0, trimEnd - trimStart) }
}

// MARK: - Audio settings

/// Everything about the audio mix: original track level plus optional soundtrack.
struct AudioSettings: Equatable {
    /// Linear gain applied to the Live Photo's original audio, 0...1.
    var originalVolume: Double = 1
    /// Hard mute for the original audio (kept separate so unmuting restores the slider).
    var isOriginalMuted: Bool = false
    /// Optional soundtrack mixed on top.
    var soundtrack: Soundtrack?

    var effectiveOriginalVolume: Double { isOriginalMuted ? 0 : originalVolume }

    var isDefault: Bool {
        originalVolume == 1 && !isOriginalMuted && soundtrack == nil
    }
}

// MARK: - Trim

/// The retained range of the Live Photo's video, in seconds from the start
/// of the original clip.
struct TrimSettings: Equatable {
    var start: TimeInterval
    var end: TimeInterval

    init(start: TimeInterval = 0, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    var duration: TimeInterval { max(0, end - start) }

    func isFullRange(of totalDuration: TimeInterval, epsilon: TimeInterval = 0.05) -> Bool {
        start <= epsilon && end >= totalDuration - epsilon
    }
}

// MARK: - EditState

/// The full edit document. Value semantics make undo/reset and
/// preview-vs-export consistency trivial.
struct EditState: Equatable {
    var filter: FilterPreset = .original
    /// Blend of the filtered result over the untouched frame, 0...1.
    var filterIntensity: Double = 1
    var adjustments: Adjustments = .identity
    var audio: AudioSettings = AudioSettings()
    /// nil until a source is loaded; then always a concrete range.
    var trim: TrimSettings?

    /// True when anything differs from a freshly loaded Live Photo.
    func hasEdits(videoDuration: TimeInterval) -> Bool {
        if filter != .original { return true }
        if !adjustments.isIdentity { return true }
        if !audio.isDefault { return true }
        if let trim, !trim.isFullRange(of: videoDuration) { return true }
        return false
    }

    /// True when the visual pipeline (filter or adjustments) does anything.
    var hasVisualEdits: Bool {
        (filter != .original && filterIntensity > 0) || !adjustments.isIdentity
    }
}
