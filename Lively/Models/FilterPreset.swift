//
//  FilterPreset.swift
//  Lively
//
//  The set of built-in looks. Each preset describes itself; the actual
//  Core Image chain lives in FilterEngine so the recipe is applied
//  identically to stills, preview video frames, and the final export.
//

import Foundation

enum FilterPreset: String, CaseIterable, Identifiable {
    case original
    case vivid
    case golden
    case coastal
    case fade
    case matte
    case dusk
    case pop
    case sepia
    case chrome
    case mono
    case noir

    var id: String { rawValue }

    /// Short name shown under the thumbnail in the filter strip.
    var displayName: String {
        switch self {
        case .original: return "Original"
        case .vivid:    return "Vivid"
        case .golden:   return "Golden"
        case .coastal:  return "Coastal"
        case .fade:     return "Fade"
        case .matte:    return "Matte"
        case .dusk:     return "Dusk"
        case .pop:      return "Pop"
        case .sepia:    return "Sepia"
        case .chrome:   return "Chrome"
        case .mono:     return "Mono"
        case .noir:     return "Noir"
        }
    }

    /// One-line description used for accessibility labels.
    var summary: String {
        switch self {
        case .original: return "No filter"
        case .vivid:    return "Punchy color and contrast"
        case .golden:   return "Warm golden-hour glow"
        case .coastal:  return "Cool, airy blues"
        case .fade:     return "Soft faded film"
        case .matte:    return "Lifted blacks, muted color"
        case .dusk:     return "Moody twilight tones"
        case .pop:      return "Maximum color energy"
        case .sepia:    return "Classic sepia warmth"
        case .chrome:   return "Bright vintage chrome"
        case .mono:     return "Balanced black and white"
        case .noir:     return "High-contrast black and white"
        }
    }

    /// Presets that produce a grayscale image (used to disable color sliders).
    var isMonochrome: Bool {
        switch self {
        case .mono, .noir: return true
        default: return false
        }
    }
}
