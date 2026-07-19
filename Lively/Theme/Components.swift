//
//  Components.swift
//  Lively
//
//  The shared flat design system: button styles, panel chrome, labeled
//  sliders, badges, and the editor's tool tab bar. Every visual constant
//  comes from FlatTheme — solid fills and hairline borders only, no
//  shadows, gradients, or materials. Views compose these components plus
//  plain SwiftUI and nothing else.
//

import SwiftUI

// MARK: - FlatPrimaryButtonStyle

/// Solid accent-filled button for the primary action on a screen.
/// White rounded-semibold label, flat corner radius, and a subtle
/// pressed state (0.96 scale + slight dim). Stretches to fill the
/// available width so it reads as a full-width call to action.
struct FlatPrimaryButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, FlatTheme.spacing)
            .padding(.horizontal, FlatTheme.padding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: FlatTheme.cornerRadius, style: .continuous)
                    .fill(FlatTheme.accent)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - FlatSecondaryButtonStyle

/// Quiet companion to the primary style: secondary-surface fill, ink
/// label, and a hairline border. Same pressed behavior so the two styles
/// feel like one family.
struct FlatSecondaryButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(FlatTheme.ink)
            .padding(.vertical, FlatTheme.spacing)
            .padding(.horizontal, FlatTheme.padding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: FlatTheme.cornerRadius, style: .continuous)
                    .fill(FlatTheme.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlatTheme.cornerRadius, style: .continuous)
                    .strokeBorder(FlatTheme.hairline, lineWidth: FlatTheme.hairlineWidth)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - FlatIconButton

/// A 36-point circular icon button used for toolbar-style controls
/// (close, play/pause, delete). Secondary-surface fill, ink glyph,
/// hairline ring, and the standard pressed state. The `label` argument
/// doubles as the accessibility label since the button shows no text.
struct FlatIconButton: View {
    private let systemName: String
    private let label: String
    private let action: () -> Void

    init(systemName: String, label: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FlatTheme.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(FlatTheme.surfaceSecondary))
                .overlay(
                    Circle()
                        .strokeBorder(FlatTheme.hairline, lineWidth: FlatTheme.hairlineWidth)
                )
        }
        .buttonStyle(FlatIconPressStyle())
        .accessibilityLabel(label)
    }
}

/// Internal press style shared by icon buttons: scale + dim, no other chrome.
private struct FlatIconPressStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - PanelContainer

/// The chrome around every tool panel: a fixed-height surface slab with a
/// hairline top edge separating it from the canvas above. Content gets the
/// standard padding and fills the panel from the top.
struct PanelContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(FlatTheme.hairline)
                .frame(height: FlatTheme.hairlineWidth)
            content
                .padding(FlatTheme.padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: FlatTheme.panelHeight)
        .background(FlatTheme.surface)
    }
}

// MARK: - SectionHeader

/// Uppercase tracked section title used inside panels.
struct SectionHeader: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(FlatTheme.headerFont())
            .kerning(1.1)
            .foregroundStyle(FlatTheme.inkSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - FlatSlider

/// A one-row labeled slider: label on the left, accent-tinted track in the
/// middle, and a right-aligned value readout in monospaced digits. The value
/// is rendered through the optional `format` closure, or to one decimal
/// place by default. Double-tapping the label snaps the value back to
/// `defaultValue`.
struct FlatSlider: View {
    private let label: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let defaultValue: Double
    private let format: ((Double) -> String)?

    init(label: String,
         value: Binding<Double>,
         range: ClosedRange<Double> = -1...1,
         defaultValue: Double = 0,
         format: ((Double) -> String)? = nil) {
        self.label = label
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.format = format
    }

    var body: some View {
        HStack(spacing: FlatTheme.spacingTight) {
            Text(label)
                .font(FlatTheme.labelFont())
                .foregroundStyle(FlatTheme.ink)
                .lineLimit(1)
                .frame(minWidth: 68, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { resetToDefault() }
                .accessibilityHidden(true)

            Slider(value: $value, in: range)
                .tint(FlatTheme.accent)
                .accessibilityLabel(label)
                .accessibilityValue(formattedValue)

            Text(formattedValue)
                .font(FlatTheme.timecodeFont())
                .foregroundStyle(FlatTheme.inkSecondary)
                .lineLimit(1)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Reset \(label)") { resetToDefault() }
    }

    private var formattedValue: String {
        if let format {
            return format(value)
        }
        return String(format: "%.1f", value)
    }

    private func resetToDefault() {
        withAnimation(.easeOut(duration: 0.2)) {
            value = defaultValue
        }
    }
}

// MARK: - LiveBadge

/// The amber "LIVE" pill shown over the preview canvas, mirroring the
/// system Live Photo badge with the concentric-circles glyph.
struct LiveBadge: View {

    init() {}

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "livephoto")
                .font(.system(size: 11, weight: .semibold))
            Text("LIVE")
                .font(FlatTheme.captionFont())
                .kerning(0.8)
        }
        .foregroundStyle(FlatTheme.canvas)
        .padding(.vertical, 4)
        .padding(.horizontal, FlatTheme.spacingTight)
        .background(Capsule().fill(FlatTheme.amber))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live Photo")
    }
}

// MARK: - ToolTabBar

/// The editor's flat bottom bar: five icon-and-title tabs over the surface
/// color with a hairline top edge. The selected tab is tinted accent, the
/// rest ink-secondary.
struct ToolTabBar: View {
    @Binding private var selection: EditorTool

    init(selection: Binding<EditorTool>) {
        self._selection = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(FlatTheme.hairline)
                .frame(height: FlatTheme.hairlineWidth)
            HStack(spacing: 0) {
                ForEach(EditorTool.allCases) { tool in
                    tab(for: tool)
                }
            }
            .padding(.top, FlatTheme.spacingTight)
            .padding(.bottom, FlatTheme.spacingTight)
        }
        .background(FlatTheme.surface)
    }

    private func tab(for tool: EditorTool) -> some View {
        let isSelected = tool == selection
        return Button {
            selection = tool
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tool.icon)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                Text(tool.title)
                    .font(FlatTheme.captionFont())
            }
            .foregroundStyle(isSelected ? FlatTheme.accent : FlatTheme.inkSecondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
