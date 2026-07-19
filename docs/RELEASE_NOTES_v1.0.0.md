# Lively 1.0.0 — "Golden Hour"

Lively's first release is here. Lively is a polished, open-source Live Photo editor for iPhone: pick a Live Photo (or turn any video into one), grade it with filters and fine adjustments you see in real time, lay a soundtrack or voiceover under it, and save the result back to your library as a genuine Live Photo — press-and-hold and it plays, just like the ones your camera makes. It's built entirely with SwiftUI and the Observation framework, with zero third-party dependencies, and released under the MIT license.

## Highlights

- 🎞️ **Edit real Live Photos** — pick one with the permissionless system photo picker; no library access required to start.
- 🎬 **Turn any video into a Live Photo** — choose a segment and a key frame for the still, then edit it like any other.
- 🎨 **12 filter presets with intensity blending**, from Golden and Coastal to Mono and Noir, plus 8 fine adjustments (exposure, brightness, contrast, saturation, vibrance, warmth, vignette, sharpness).
- ⚡ **True real-time preview** — filters render per frame through a Core Image video composition, so slider changes appear on the next frame with no player rebuilds.
- 🎙️ **Soundtracks and voiceovers** — import a music file or record your voice, then trim on a waveform, offset it along the timeline, set volume, and add fades. Mix or mute the original audio.
- ✂️ **Video trim** with a filmstrip, and an assembled press-and-hold `PHLivePhoto` preview of your edit.
- 📤 **Genuine Live Photo export** — a paired still and movie with the content identifier and still-image-time metadata Photos expects, saved with add-only permission. Or export a shareable MP4 with everything baked in.
- 🌗 **Flat design, light and dark** — coral, amber, ocean, and mint, consistent across every screen.

## Requirements

- iOS 17 or later
- Xcode 16 or later to build
- A real iPhone is recommended for the full experience — the simulator's photo library has no Live Photos by default

## Install from source

1. Clone the repository:
   ```sh
   git clone https://github.com/shoal-rat/Lively.git
   cd Lively
   ```
2. Open `Lively.xcodeproj` in Xcode 16 or later.
3. Select your development team under Signing & Capabilities.
4. Choose your iPhone as the run destination and press Run.

Found a bug, or have an idea? [Issues](https://github.com/shoal-rat/Lively/issues) and pull requests are very welcome — we'd love to see what you make.
