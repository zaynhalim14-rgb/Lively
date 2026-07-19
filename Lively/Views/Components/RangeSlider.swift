//
//  RangeSlider.swift
//  Lively
//
//  A flat two-handle range selector used for trimming (audio clips and the
//  video timeline). The region outside the selection is dimmed with the
//  canvas color, the selection is outlined in accent, and each edge carries
//  a flat accent handle with a white grabber bar. Handles expose 44pt hit
//  targets, clamp to the bounds and a minimum gap, and report drag begin/end
//  through `onEditingChanged`.
//

import SwiftUI

// MARK: - RangeSlider

struct RangeSlider: View {

    // MARK: Metrics

    private enum Metrics {
        /// Visible width of each edge handle.
        static let handleWidth: CGFloat = 14
        /// Corner radius of the handles and selection outline.
        static let cornerRadius: CGFloat = 5
        /// Minimum touch target width per Apple HIG.
        static let hitWidth: CGFloat = 44
        /// Minimum touch target height per Apple HIG.
        static let hitHeight: CGFloat = 44
        /// White grabber bar inside each handle.
        static let grabberSize = CGSize(width: 3, height: 14)
        /// Stroke width of the selection outline.
        static let selectionBorderWidth: CGFloat = 2
        /// Opacity of the dim overlay outside the selection.
        static let dimOpacity: Double = 0.55
    }

    private enum ActiveHandle {
        case lower
        case upper
    }

    // MARK: Configuration

    @Binding private var lowerValue: Double
    @Binding private var upperValue: Double
    private let bounds: ClosedRange<Double>
    private let minimumGap: Double
    private let onEditingChanged: ((Bool) -> Void)?

    // MARK: Drag state

    @State private var activeHandle: ActiveHandle?
    @State private var dragOriginValue: Double = 0

    init(lowerValue: Binding<Double>,
         upperValue: Binding<Double>,
         bounds: ClosedRange<Double>,
         minimumGap: Double = 0.1,
         onEditingChanged: ((Bool) -> Void)? = nil) {
        self._lowerValue = lowerValue
        self._upperValue = upperValue
        self.bounds = bounds
        self.minimumGap = minimumGap
        self.onEditingChanged = onEditingChanged
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let trackWidth = usableTrackWidth(in: width)
            let lowerX = xPosition(for: lowerValue, in: width)
            let upperX = xPosition(for: upperValue, in: width)

            ZStack(alignment: .leading) {
                dimRegions(lowerX: lowerX, upperX: upperX, width: width, height: height)
                selectionBorder(lowerX: lowerX, upperX: upperX, height: height)
                handle(.lower, at: lowerX, height: height, trackWidth: trackWidth)
                handle(.upper, at: upperX, height: height, trackWidth: trackWidth)
            }
        }
    }

    // MARK: - Subviews

    /// Flat canvas-colored overlays covering everything outside the selection.
    @ViewBuilder
    private func dimRegions(lowerX: CGFloat, upperX: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(FlatTheme.canvas.opacity(Metrics.dimOpacity))
            .frame(width: max(0, lowerX), height: height)
            .allowsHitTesting(false)
        Rectangle()
            .fill(FlatTheme.canvas.opacity(Metrics.dimOpacity))
            .frame(width: max(0, width - upperX), height: height)
            .offset(x: upperX)
            .allowsHitTesting(false)
    }

    /// Accent outline around the kept range.
    private func selectionBorder(lowerX: CGFloat, upperX: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .strokeBorder(FlatTheme.accent, lineWidth: Metrics.selectionBorderWidth)
            .frame(width: max(Metrics.selectionBorderWidth, upperX - lowerX), height: height)
            .offset(x: lowerX)
            .allowsHitTesting(false)
    }

    /// One edge handle: a flat accent rounded rect with a white grabber bar,
    /// wrapped in an invisible 44pt hit target centered on the edge.
    private func handle(_ kind: ActiveHandle, at x: CGFloat, height: CGFloat, trackWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .fill(FlatTheme.accent)
            .frame(width: Metrics.handleWidth, height: height)
            .overlay(
                Capsule()
                    .fill(.white)
                    .frame(width: Metrics.grabberSize.width, height: Metrics.grabberSize.height)
            )
            .frame(width: Metrics.hitWidth, height: max(height, Metrics.hitHeight))
            .contentShape(Rectangle())
            .position(x: x, y: height / 2)
            .gesture(dragGesture(for: kind, trackWidth: trackWidth))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind == .lower ? "Range start" : "Range end")
            .accessibilityValue(accessibilityValue(for: kind))
            .accessibilityAdjustableAction { direction in
                adjust(kind, direction: direction)
            }
    }

    // MARK: - Gesture

    private func dragGesture(for kind: ActiveHandle, trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if activeHandle == nil {
                    activeHandle = kind
                    dragOriginValue = kind == .lower ? lowerValue : upperValue
                    onEditingChanged?(true)
                }
                guard activeHandle == kind, trackWidth > 0, span > 0 else { return }
                let delta = Double(gesture.translation.width / trackWidth) * span
                let proposed = dragOriginValue + delta
                switch kind {
                case .lower: lowerValue = clampLower(proposed)
                case .upper: upperValue = clampUpper(proposed)
                }
            }
            .onEnded { _ in
                guard activeHandle == kind else { return }
                activeHandle = nil
                onEditingChanged?(false)
            }
    }

    // MARK: - Geometry

    private var span: Double { bounds.upperBound - bounds.lowerBound }

    /// The handles sit fully inside the view, so the draggable track is the
    /// width minus one handle (half a handle inset on each side).
    private func usableTrackWidth(in width: CGFloat) -> CGFloat {
        max(1, width - Metrics.handleWidth)
    }

    /// Maps a value onto the handle's center x, clamped into the view.
    private func xPosition(for value: Double, in width: CGFloat) -> CGFloat {
        guard span > 0, width > 0 else { return Metrics.handleWidth / 2 }
        let fraction = min(1, max(0, (value - bounds.lowerBound) / span))
        return Metrics.handleWidth / 2 + usableTrackWidth(in: width) * CGFloat(fraction)
    }

    // MARK: - Clamping

    private func clampLower(_ proposed: Double) -> Double {
        let upperLimit = max(bounds.lowerBound, upperValue - minimumGap)
        return min(max(bounds.lowerBound, proposed), upperLimit)
    }

    private func clampUpper(_ proposed: Double) -> Double {
        let lowerLimit = min(bounds.upperBound, lowerValue + minimumGap)
        return max(min(bounds.upperBound, proposed), lowerLimit)
    }

    // MARK: - Accessibility

    private func accessibilityValue(for kind: ActiveHandle) -> String {
        let value = kind == .lower ? lowerValue : upperValue
        return String(format: "%.1f", value)
    }

    /// VoiceOver adjustable support: nudge the handle by 5% of the span.
    private func adjust(_ kind: ActiveHandle, direction: AccessibilityAdjustmentDirection) {
        guard span > 0 else { return }
        let step = span / 20
        let delta = direction == .increment ? step : -step
        switch kind {
        case .lower: lowerValue = clampLower(lowerValue + delta)
        case .upper: upperValue = clampUpper(upperValue + delta)
        }
    }
}
