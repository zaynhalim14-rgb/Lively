//
//  FilterEngine.swift
//  Lively
//
//  The single Core Image pipeline behind every pixel Lively draws. The live
//  preview compositor, the filter-strip thumbnails, and the exported still
//  all run through the same apply(_:to:), so what the user previews is
//  exactly what gets saved.
//

import CoreImage
import Foundation
import ImageIO
import UIKit

// MARK: - FilterEngineError

/// Failures while rendering the filtered still for export.
enum FilterEngineError: LocalizedError {
    /// The source photo could not be decoded as an image.
    case unreadableSource(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let url):
            return "Couldn't read the photo \"\(url.lastPathComponent)\" for rendering."
        }
    }
}

// MARK: - FilterEngine

/// Stateless Core Image renderer shared by the preview compositor, the
/// thumbnail strip, and the exporter.
///
/// `apply(_:to:)` runs once per video frame on the render queue, so the
/// engine keeps no mutable state: every call assembles its own lightweight
/// filter chain from the immutable `VisualState` it is handed. The only
/// stored property is the shared `CIContext`, which Apple documents as
/// safe to use from multiple threads.
final class FilterEngine: @unchecked Sendable {

    // MARK: Shared instance

    static let shared = FilterEngine()

    /// Single rendering context reused for previews, thumbnails, and export.
    /// Intermediate caching is disabled: video frames never repeat, so a
    /// cache would only grow memory without ever hitting.
    let ciContext: CIContext

    private init() {
        ciContext = CIContext(options: [
            .cacheIntermediates: false,
            .name: "Lively.FilterEngine"
        ])
    }

    // MARK: - Per-frame pipeline

    /// Applies the full visual pipeline to one frame:
    /// 1. fine adjustments (exposure, color, sharpening, vignette),
    /// 2. the selected preset's filter chain,
    /// 3. an intensity blend of the styled result over the adjusted frame
    ///    via `CIDissolveTransition` (`inputTime` = `filterIntensity`).
    ///
    /// Adjustments are never attenuated by `filterIntensity` — only the
    /// preset styling is. The result is always cropped back to the source
    /// extent so downstream compositing sees stable geometry.
    func apply(_ state: VisualState, to image: CIImage) -> CIImage {
        let extent = image.extent

        // 1. Adjustments.
        let adjusted = applyingAdjustments(state.adjustments, to: image)

        // 2 & 3. Preset chain, then intensity blend.
        let intensity = min(max(state.filterIntensity, 0), 1)
        guard state.filter != .original, intensity > 0 else {
            return adjusted.cropped(to: extent)
        }

        let styled = applyingPreset(state.filter, to: adjusted)
        guard intensity < 1 else {
            return styled.cropped(to: extent)
        }

        // Dissolve from the adjusted-but-unstyled frame (time 0) toward the
        // fully styled frame (time 1).
        let blended = adjusted.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: styled,
            kCIInputTimeKey: intensity
        ])
        return blended.cropped(to: extent)
    }

    // MARK: - Still decoding

    /// Decodes the still at `url` at a reduced size using ImageIO
    /// thumbnailing, with the EXIF orientation baked into the pixels.
    /// The decode runs off the calling actor.
    func decodedStill(from url: URL, maxDimension: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let sourceOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithURL(
                url as CFURL,
                sourceOptions as CFDictionary
            ) else {
                return nil
            }

            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }

    // MARK: - Preset thumbnails

    /// Renders one small preview per preset from `base`, scaled to roughly
    /// fill `size`. Presets that fail to render are simply omitted; the
    /// filter strip shows a flat placeholder for missing entries.
    func presetThumbnails(from base: UIImage, size: CGSize) async -> [FilterPreset: UIImage] {
        await Task.detached(priority: .userInitiated) { () -> [FilterPreset: UIImage] in
            guard let sourceImage = CIImage(image: base) else { return [:] }
            let extent = sourceImage.extent
            guard extent.width > 0, extent.height > 0,
                  size.width > 0, size.height > 0 else { return [:] }

            // Scale to fill the requested cell, once, then style per preset.
            let scale = max(size.width / extent.width, size.height / extent.height)
            let scaled = sourceImage.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0
            ])

            var thumbnails: [FilterPreset: UIImage] = [:]
            thumbnails.reserveCapacity(FilterPreset.allCases.count)
            for preset in FilterPreset.allCases {
                let state = VisualState(
                    filter: preset,
                    filterIntensity: 1,
                    adjustments: .identity
                )
                let output = self.apply(state, to: scaled)
                if let cgImage = self.ciContext.createCGImage(output, from: output.extent) {
                    thumbnails[preset] = UIImage(cgImage: cgImage)
                }
            }
            return thumbnails
        }.value
    }

    // MARK: - Filtered still export

    /// Loads the full-resolution still (orientation left in metadata, so the
    /// written file keeps the original EXIF orientation semantics), applies
    /// `visual`, and writes the result to `outputURL` — HEIC when the output
    /// path extension is "heic", JPEG otherwise. Uses the source color space
    /// when available, falling back to sRGB.
    func renderFilteredStill(photoURL: URL, visual: VisualState, to outputURL: URL) throws {
        guard let image = CIImage(contentsOf: photoURL) else {
            throw FilterEngineError.unreadableSource(photoURL)
        }
        let output = apply(visual, to: image)

        let colorSpace = image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92
        ]

        if outputURL.pathExtension.lowercased() == "heic" {
            try ciContext.writeHEIFRepresentation(
                of: output,
                to: outputURL,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: options
            )
        } else {
            try ciContext.writeJPEGRepresentation(
                of: output,
                to: outputURL,
                colorSpace: colorSpace,
                options: options
            )
        }
    }

    // MARK: - Adjustment chain

    /// Maps normalized `Adjustments` onto Core Image parameters, skipping
    /// every stage whose inputs sit at identity so the per-frame cost stays
    /// proportional to what the user actually changed.
    private func applyingAdjustments(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        guard !adjustments.isIdentity else { return image }
        var output = image

        if adjustments.exposure != 0 {
            output = output.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: adjustments.exposure * 1.5
            ])
        }
        if adjustments.brightness != 0 || adjustments.contrast != 0 || adjustments.saturation != 0 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adjustments.brightness * 0.15,
                kCIInputContrastKey: 1 + adjustments.contrast * 0.35,
                kCIInputSaturationKey: 1 + adjustments.saturation
            ])
        }
        if adjustments.vibrance != 0 {
            output = output.applyingFilter("CIVibrance", parameters: [
                "inputAmount": adjustments.vibrance
            ])
        }
        if adjustments.warmth != 0 {
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(6500 - adjustments.warmth * 1300), y: 0)
            ])
        }
        if adjustments.sharpness > 0 {
            output = output.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: adjustments.sharpness * 0.7
            ])
        }
        if adjustments.vignette > 0 {
            output = output.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: adjustments.vignette * 1.4,
                kCIInputRadiusKey: 1.8
            ])
        }
        return output
    }

    // MARK: - Preset chains

    /// The recipe for each built-in look, applied at full strength; `apply`
    /// handles blending it down by `filterIntensity`.
    private func applyingPreset(_ preset: FilterPreset, to image: CIImage) -> CIImage {
        switch preset {
        case .original:
            return image

        case .vivid:
            return image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.35])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.12,
                    kCIInputContrastKey: 1.08
                ])

        case .golden:
            return image
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5300, y: 0)
                ])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.2])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.1])

        case .coastal:
            return image
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 7600, y: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.05
                ])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.05])

        case .fade:
            return image.applyingFilter("CIPhotoEffectFade")

        case .matte:
            return image
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0.06),
                    "inputPoint1": CIVector(x: 0.25, y: 0.27),
                    "inputPoint2": CIVector(x: 0.5, y: 0.51),
                    "inputPoint3": CIVector(x: 0.75, y: 0.76),
                    "inputPoint4": CIVector(x: 1, y: 1)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.85,
                    kCIInputContrastKey: 0.98
                ])

        case .dusk:
            return image
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 7200, y: 30)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.08
                ])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.08])
                .applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: 0.25,
                    kCIInputRadiusKey: 1.8
                ])

        case .pop:
            return image
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.35,
                    kCIInputContrastKey: 1.12
                ])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.25])

        case .sepia:
            return image.applyingFilter("CISepiaTone", parameters: [
                kCIInputIntensityKey: 0.85
            ])

        case .chrome:
            return image.applyingFilter("CIPhotoEffectChrome")

        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")

        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        }
    }
}
