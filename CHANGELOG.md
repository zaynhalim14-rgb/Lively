# Changelog

All notable changes to Lively will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.0.0] - 2026-07-17

Initial public release — "Golden Hour."

### Added

#### Editor
- Pick a Live Photo with the permissionless system `PhotosPicker` — no photo-library authorization needed to start editing.
- Real-time filtered preview driven by a per-frame Core Image video composition. Visual edits flow through a shared `VisualStateBox`, so filter and adjustment changes appear on the very next frame with zero player rebuilds.
- Smart change routing in `EditorViewModel`: visual edits update the compositor in place, audio-mix edits swap a new `AVAudioMix` onto the current player item, and only structural edits (trim, soundtrack timing) trigger a debounced composition rebuild.
- Motion/Live preview toggle: a looping motion preview with live filters and audio, plus an assembled genuine `PHLivePhoto` preview you play with press-and-hold. The assembled preview is cached and reused until an edit invalidates it.
- Value-typed `EditState` as the single edit document consumed by both the preview pipeline and the exporter, so what you preview is exactly what exports.
- Friendly, human-readable error messages throughout loading, recording, conversion, and export.

#### Filters
- 12 filter presets: Original, Vivid, Golden, Coastal, Fade, Matte, Dusk, Pop, Sepia, Chrome, Mono, and Noir.
- Filter intensity slider that blends the filtered result over the untouched frame.
- Per-preset live thumbnails rendered from the photo's own still.
- 8 fine adjustments layered on top of the preset: exposure, brightness, contrast, saturation, vibrance, warmth, vignette, and sharpness — with one-tap reset.
- Monochrome presets (Mono, Noir) automatically disable the color sliders.

#### Audio
- Add a soundtrack from a music file, or record a voiceover in the app.
- Waveform display with in/out trim handles for the soundtrack.
- Timeline start offset to place the clip anywhere along the video.
- Soundtrack volume plus independent fade-in and fade-out lengths.
- Original-audio volume slider with a separate mute toggle — unmuting restores your previous level.

#### Trim
- Trim the Live Photo's video with a filmstrip of evenly spaced frames and a range slider.

#### Video Conversion
- Convert any video into a Live Photo: choose a segment range and a key frame for the still, then edit the result with the full toolset — converted videos flow through the exact same pipeline as picked Live Photos.

#### Export
- Save as a genuine Live Photo: a paired still (HEIC preserved when the source is HEIC) and QuickTime movie carrying a matching content identifier and a still-image-time metadata track, so Photos recognizes the pair.
- Saving uses add-only photo-library permission — Lively never asks for read access to your library.
- Export a shareable MP4 with filters and the audio mix baked in, handed straight to the share sheet.
- Export progress reporting with distinct rendering and saving phases.

#### Design System
- Flat design language with a coral `#FF6B6B` accent and amber `#FFB84C`, ocean `#3D7DFF`, and mint `#2ECC9B` companions.
- Full light and dark mode support.
- Reusable themed components (buttons, cards, sliders, panels) shared across the app.

#### App
- iOS 17+, Swift 5, built entirely with SwiftUI and the Observation framework.
- Zero third-party dependencies.
- MIT license.

[Unreleased]: https://github.com/shoal-rat/Lively/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/shoal-rat/Lively/releases/tag/v1.0.0
