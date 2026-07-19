//
//  WaveformView.swift
//  Lively
//
//  A flat waveform rendered with Canvas: normalized peak samples drawn as
//  centered vertical capsule bars. The bar count adapts to the available
//  width (2pt bars with roughly a 1pt gap), an optional progress value dims
//  the already-played portion, and an empty sample set renders as a quiet
//  flat midline so the layout never jumps while samples load.
//

import SwiftUI

// MARK: - WaveformView

struct WaveformView: View {

    // MARK: Metrics

    private enum Metrics {
        /// Width of each capsule bar, in points.
        static let barWidth: CGFloat = 2
        /// Minimum gap between bars; the actual gap adapts to fill the width.
        static let minimumGap: CGFloat = 1
        /// Height of the placeholder midline shown when there are no samples.
        static let midlineHeight: CGFloat = 2
        /// Opacity applied to bars in the played portion.
        static let playedOpacity: Double = 0.35
        /// Opacity of the empty-state midline.
        static let midlineOpacity: Double = 0.3
    }

    // MARK: Configuration

    /// Normalized peak samples, each 0...1.
    private let samples: [Float]
    /// Optional playback progress 0...1; bars at or before it are dimmed.
    private let progress: Double?
    /// Bar color.
    private let color: Color

    init(samples: [Float], progress: Double? = nil, color: Color = FlatTheme.ocean) {
        self.samples = samples
        self.progress = progress
        self.color = color
    }

    // MARK: Body

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let midY = size.height / 2

            guard !samples.isEmpty else {
                drawMidline(in: &context, size: size, midY: midY)
                return
            }

            // Fit as many 2pt bars as the width allows at >= the minimum gap,
            // then spread them evenly so the gap adapts to fill the width.
            let slot = Metrics.barWidth + Metrics.minimumGap
            let barCount = max(1, Int((size.width + Metrics.minimumGap) / slot))
            let step = size.width / CGFloat(barCount)

            for index in 0..<barCount {
                let peak = binPeak(at: index, of: barCount)
                let barHeight = max(Metrics.barWidth, CGFloat(peak) * size.height)
                let centerX = step * (CGFloat(index) + 0.5)
                let rect = CGRect(
                    x: centerX - Metrics.barWidth / 2,
                    y: midY - barHeight / 2,
                    width: Metrics.barWidth,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: Metrics.barWidth / 2),
                    with: .color(fillColor(forBarAt: index, of: barCount))
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio waveform")
    }

    // MARK: - Drawing helpers

    /// Empty state: a flat centered midline in place of the bars.
    private func drawMidline(in context: inout GraphicsContext, size: CGSize, midY: CGFloat) {
        let rect = CGRect(
            x: 0,
            y: midY - Metrics.midlineHeight / 2,
            width: size.width,
            height: Metrics.midlineHeight
        )
        context.fill(
            Path(roundedRect: rect, cornerRadius: Metrics.midlineHeight / 2),
            with: .color(color.opacity(Metrics.midlineOpacity))
        )
    }

    /// Peak of the sample bin that maps onto the bar at `index`, so drawing
    /// stays faithful whether there are more samples than bars or fewer.
    private func binPeak(at index: Int, of barCount: Int) -> Float {
        guard !samples.isEmpty, barCount > 0 else { return 0 }
        let start = index * samples.count / barCount
        let end = max(start + 1, (index + 1) * samples.count / barCount)
        let clampedStart = min(max(0, start), samples.count - 1)
        let clampedEnd = min(max(clampedStart + 1, end), samples.count)
        return samples[clampedStart..<clampedEnd].max() ?? 0
    }

    /// Bars inside the played portion (at or before `progress`) are dimmed.
    private func fillColor(forBarAt index: Int, of barCount: Int) -> Color {
        guard let progress else { return color }
        let fraction = (Double(index) + 0.5) / Double(max(barCount, 1))
        return fraction <= progress ? color.opacity(Metrics.playedOpacity) : color
    }
}
