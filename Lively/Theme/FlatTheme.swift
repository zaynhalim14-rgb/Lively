//
//  FlatTheme.swift
//  Lively
//
//  Design tokens for Lively's flat visual language: solid fills, hairline
//  borders, no shadows or gradients, generous whitespace, rounded type.
//  Every view pulls color/spacing/typography from here — never hard-coded.
//

import SwiftUI
import UIKit

enum FlatTheme {

    // MARK: Palette

    /// Coral — primary accent, used for selection, primary buttons, the record dot.
    static let accent = Color(hex: 0xFF6B6B)
    /// Amber — secondary accent, used for the Live badge and waveforms.
    static let amber = Color(hex: 0xFFB84C)
    /// Ocean blue — tertiary accent, used for audio elements and links.
    static let ocean = Color(hex: 0x3D7DFF)
    /// Mint — success states and export confirmation.
    static let mint = Color(hex: 0x2ECC9B)

    /// App background.
    static let background = Color(light: Color(hex: 0xF7F8FA), dark: Color(hex: 0x0F1115))
    /// Cards, panels, sheets.
    static let surface = Color(light: .white, dark: Color(hex: 0x1A1D24))
    /// Nested surfaces: wells, thumbnails, slider tracks.
    static let surfaceSecondary = Color(light: Color(hex: 0xEEF0F4), dark: Color(hex: 0x252A33))
    /// Primary text.
    static let ink = Color(light: Color(hex: 0x1B1F27), dark: Color(hex: 0xF2F4F8))
    /// Secondary text and inactive icons.
    static let inkSecondary = Color(light: Color(hex: 0x6B7280), dark: Color(hex: 0x9AA1AD))
    /// Hairline separators and flat borders.
    static let hairline = Color(light: Color(hex: 0xE2E5EA), dark: Color(hex: 0x2E333D))
    /// The preview canvas behind the photo (always near-black for contrast).
    static let canvas = Color(light: Color(hex: 0x14161A), dark: Color(hex: 0x0A0C0F))

    // MARK: Metrics

    /// Corner radius for cards and buttons.
    static let cornerRadius: CGFloat = 14
    /// Corner radius for small chips and thumbnails.
    static let chipRadius: CGFloat = 10
    /// Standard content padding.
    static let padding: CGFloat = 16
    /// Tight spacing inside grouped controls.
    static let spacingTight: CGFloat = 8
    /// Standard vertical rhythm.
    static let spacing: CGFloat = 12
    /// Height of the tool panel above the tool tab bar.
    static let panelHeight: CGFloat = 224
    /// Hairline width for flat borders.
    static let hairlineWidth: CGFloat = 1

    // MARK: Typography

    /// Large screen titles.
    static func titleFont() -> Font { .system(.title2, design: .rounded).weight(.bold) }
    /// Panel section headers.
    static func headerFont() -> Font { .system(.subheadline, design: .rounded).weight(.semibold) }
    /// Control labels.
    static func labelFont() -> Font { .system(.footnote, design: .rounded).weight(.medium) }
    /// Small captions (filter names, timestamps).
    static func captionFont() -> Font { .system(.caption2, design: .rounded).weight(.medium) }
    /// Monospaced digits for time readouts.
    static func timecodeFont() -> Font { .system(.caption, design: .monospaced).weight(.medium) }
}

// MARK: - Timecode formatting

extension TimeInterval {
    /// The one true timecode: `m:ss.t` (minutes, zero-padded seconds, tenths).
    /// Every duration/offset readout in the app uses this so adjacent panels
    /// never disagree on formatting.
    var livelyTimecode: String {
        let totalTenths = Int((max(0, self) * 10).rounded())
        let minutes = totalTenths / 600
        let seconds = (totalTenths / 10) % 60
        let tenths = totalTenths % 10
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

// MARK: - Color helpers

extension Color {
    /// Flat color from a 0xRRGGBB literal.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    /// Dynamic color that adapts to light/dark appearance.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
