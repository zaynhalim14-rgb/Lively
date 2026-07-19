//
//  VisualState.swift
//  Lively
//
//  A thread-safe box holding the current visual edit (filter + adjustments).
//  The AVVideoComposition's per-frame Core Image handler reads this box on
//  the video render queue, so moving a slider re-styles the running preview
//  immediately — no player item rebuild, no stutter.
//

import Foundation

/// The visual portion of `EditState` — everything that affects pixels.
struct VisualState: Equatable {
    var filter: FilterPreset = .original
    var filterIntensity: Double = 1
    var adjustments: Adjustments = .identity

    init(filter: FilterPreset = .original,
         filterIntensity: Double = 1,
         adjustments: Adjustments = .identity) {
        self.filter = filter
        self.filterIntensity = filterIntensity
        self.adjustments = adjustments
    }

    init(from editState: EditState) {
        self.filter = editState.filter
        self.filterIntensity = editState.filterIntensity
        self.adjustments = editState.adjustments
    }

    var isIdentity: Bool {
        (filter == .original || filterIntensity == 0) && adjustments.isIdentity
    }
}

/// Lock-protected mutable holder shared between the main actor (writes on
/// slider changes) and the video compositor's render queue (reads per frame).
final class VisualStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: VisualState

    init(_ state: VisualState = VisualState()) {
        self.state = state
    }

    var value: VisualState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            state = newValue
        }
    }
}
