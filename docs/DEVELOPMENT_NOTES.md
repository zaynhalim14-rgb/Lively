# Development Notes

The lab notebook for Lively maintainers. This is the place for the knowledge that
isn't obvious from reading any single file: how Live Photo pairing actually works,
why the permission model is the way it is, which design decisions were deliberate,
and what we know is imperfect. If you change something covered here, update this
document in the same PR.

Companion reading: the header comment at the top of each source file, which states
that file's intent and contracts. File references below are relative to `Lively/`.

---

## 1. How Live Photo pairing actually works

A Live Photo is not a file format. It is two ordinary files — a still (HEIC or JPEG)
and a QuickTime movie — that Photos treats as one asset because they carry matching
metadata. Everything Lively does to earn the "Live" badge lives in
`Core/LivePhotoAssembler.swift`, and it comes down to one shared UUID written in
three places.

### 1.1 The still: MakerApple key `"17"`

The still image carries the pairing identifier inside its EXIF `MakerApple`
dictionary under the key `"17"`:

```swift
var makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
makerApple["17"] = identifier   // the shared UUID string
properties[kCGImagePropertyMakerAppleDictionary] = makerApple
```

`writeStill(from:metadataSourceURL:identifier:to:)` copies the filtered still
through `CGImageDestinationAddImageFromSource`, merging this key into the property
dictionary. When a `metadataSourceURL` is supplied (the original picked still), its
full property set — EXIF, TIFF, GPS, orientation — is carried over onto the output,
so an edited Live Photo keeps its capture metadata. Existing `MakerApple` entries
are preserved; only key `"17"` is added or replaced.

### 1.2 The video, part one: the asset-level content identifier

The movie carries the same UUID as an asset-level QuickTime metadata item:

- key space: `quickTimeMetadata` (`mdta`)
- identifier: `mdta/com.apple.quicktime.content.identifier`
- data type: UTF-8 string
- value: the shared UUID

`writeVideo(from:identifier:to:)` sets this via `AVAssetWriter.metadata` before any
samples are written. See `contentIdentifierItem(_:)`.

### 1.3 The video, part two: the timed still-image-time track

The identifier alone is not enough — Photos also requires a **timed metadata track**
telling it which video frame corresponds to the still. Lively builds it with an
`AVAssetWriterInputMetadataAdaptor` whose format description is created from a
metadata specification (`makeStillImageTimeAdaptor()`):

- format type: `kCMMetadataFormatType_Boxed`
- identifier: `mdta/com.apple.quicktime.still-image-time`
- data type: `com.apple.metadata.datatype.int8`
- payload: a single `Int8(0)` sample

Exactly one `AVTimedMetadataGroup` is appended, with a time range starting at the
**midpoint of the clip** and lasting 1/30 s. The sample's *position on the timeline*
is the information; its value is always 0. (See §3.4 and §4.1 for why the midpoint.)

The remux is passthrough: video and audio sample buffers are copied through an
`AVAssetReader`/`AVAssetWriter` pair without re-encoding (both tracks drain
concurrently in a task group), so assembly is fast and lossless. The processed
video was already encoded by the export step; the assembler only adds metadata.

### 1.4 How Photos matches the pair

`Core/LivePhotoExporter.swift` saves with a single `PHAssetCreationRequest`:

```swift
let creation = PHAssetCreationRequest.forAsset()
creation.addResource(with: .photo,       fileURL: photoURL, options: options)
creation.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
```

Photos accepts the two resources as one Live Photo when (a) both are attached to
the same creation request as `.photo` + `.pairedVideo`, (b) the still's
`MakerApple["17"]` equals the video's `content.identifier`, and (c) the video
contains a still-image-time metadata track. If any leg is missing or mismatched,
the save typically fails or the asset lands as a plain still — so if a future
change breaks the badge, check those three legs in that order. The same assembled
pair also feeds `PHLivePhoto.request(withResourceFileURLs:...)` for the in-app
press-and-hold preview; that API validates the same metadata, which makes it a
convenient smoke test without touching the library.

---

## 2. Why Lively never needs read access to the photo library

Lively ships with **no** `NSPhotoLibraryUsageDescription`. Only two privacy strings
exist in the project (see `project.pbxproj`): microphone (voiceover) and
photo-library **add** (export). This is deliberate and worth protecting.

**Reading is picker-scoped.** `HomeView` uses SwiftUI's `PhotosPicker`
(`matching: .livePhotos`, and `.videos` for conversion), which runs out of process.
The app never enumerates the library; it receives only the item the user chose.
`EditorViewModel.load(item:)` calls
`item.loadTransferable(type: PHLivePhoto.self)` — the picker vends a real
`PHLivePhoto` object for the selected asset without any authorization prompt.

**Extraction works on the picker-vended object.** The non-obvious part, in
`Core/LivePhotoLoader.swift`: `PHAssetResource.assetResources(for: livePhoto)`
accepts a `PHLivePhoto` directly (not just a `PHAsset`), and
`PHAssetResourceManager.writeData(for:toFile:options:)` streams the `.photo` and
`.pairedVideo` resources to files in the session's working directory —
`isNetworkAccessAllowed = true` covers iCloud-resident originals. From that point
on, the entire pipeline works from plain file URLs; nothing downstream touches
Photos until export.

**Writing is add-only.** `LivePhotoExporter.saveToPhotoLibrary` requests
`PHPhotoLibrary.requestAuthorization(for: .addOnly)` and accepts both `.authorized`
and `.limited`. Add-only permission can create assets but never read existing ones.

The net effect: the scariest permission dialog Lively ever shows is "allow adding
to your photos." Keep it that way — if a future feature seems to need read access,
look for a picker-scoped path first.

---

## 3. Design decisions worth remembering

### 3.1 Intensity blends the preset only; adjustments stay full-strength

In `Core/FilterEngine.swift`, `apply(_:to:)` runs in a fixed order: fine
adjustments first, then the preset chain, then a `CIDissolveTransition` blend of
the styled frame over the *adjusted* frame with `inputTime = filterIntensity`.
The intensity slider therefore fades the preset's look in and out, but never
attenuates the user's exposure/contrast/etc. Rationale: each adjustment already
has its own continuous slider; routing them through intensity as well would make
two controls fight over the same pixels, and dragging intensity to zero would
silently discard adjustment work.

### 3.2 The VisualStateBox: three tiers of preview refresh

`EditorViewModel.applyEditStateChange(from:to:)` classifies every edit and takes
the cheapest path:

| Change | Cost | Mechanism |
| --- | --- | --- |
| Filter / intensity / adjustments | ~free | Write `VisualStateBox.value`; the running `AVVideoComposition`'s per-frame Core Image handler reads the box on the next frame |
| Volume / fade / mute | cheap | Build a new `AVAudioMix`, swap it onto the current player item |
| Trim, soundtrack file/trim/offset | expensive | Debounced (250 ms) rebuild of the whole `AVComposition` |

The box (`Models/VisualState.swift`) is an `NSLock`-guarded value shared between
the main actor and the video render queue. This is why slider drags never stutter:
no player item is ever rebuilt for a visual change. If you add a new edit
property, decide its tier consciously — `isStructuralChange` is the routing table.

### 3.3 Passthrough segment export, re-encode fallback

`Core/VideoConverter.swift` exports the chosen segment of a converted video with
`AVAssetExportPresetPassthrough` first (fast, lossless, no generation loss) and
falls back to `AVAssetExportPresetHighestQuality` only when passthrough fails
(some codec/container combinations can't be passed through into QuickTime). The
trade: passthrough can only cut on sync frames, so cut points may shift slightly
(§4.2). We chose lossless speed for the common case over keyframe-precise cuts.

### 3.4 Still-image-time is written at the clip midpoint

The assembler stamps the still-image-time marker at `duration / 2` for *every*
pair it writes. By assembly time, the video has already been trimmed, filtered,
and re-encoded, so the original capture timestamp of the still is no longer
meaningful — and for edited Live Photos the midpoint matches what iOS's own
editor produces. The known cost for converted videos is described in §4.1.

### 3.5 One render path for preview and export

`EditState` (`Models/EditState.swift`) is a value type and the single source of
truth; `CompositionBuilder` + `FilterEngine.shared` serve both the live preview
player and `LivePhotoExporter`. What the user sees is what gets rendered. One
subtlety in `renderProcessedPair`: the exporter snapshots the visual state into
a *fresh* `VisualStateBox` before rendering, so slider movements made while an
export is running cannot leak into the output file.

### 3.6 Session state lives in a throwaway working directory

Every session gets `<tmp>/LivelySession-<UUID>` (`LivePhotoLoader.makeWorkingDirectory`).
Extracted sources, staged conversion videos, soundtracks, voiceovers, processed
intermediates, and assembled pairs all land there, and `reset()` deletes the whole
directory. Nothing is ever written outside it except the final save into Photos.

### 3.7 The legacy export API is intentional

`exportComposition` uses `AVAssetExportSession.exportAsynchronously` plus progress
polling, bridged with a continuation. The modern async `states(updateInterval:)`
API is iOS 18+; Lively targets iOS 17. Expect deprecation warnings when building
with newer SDKs — they are known and accepted until the deployment target moves.

---

## 4. Known limitations

An honest list. None of these are hidden from users by design; most are trade-offs
documented above.

1. **Still-image-time is the midpoint, not the user's key frame, for converted
   videos.** The conversion sheet lets the user pick a key frame, and that frame
   *does* become the still image — but the timed marker in the paired video still
   points at the clip midpoint (§3.4). In Photos, the press-and-hold animation
   settles on the midpoint frame rather than the chosen key frame. Cosmetic, but
   visible on clips with fast motion. Fixing it means plumbing `keyTime` from
   `VideoConverter` through the pair into `LivePhotoAssembler.makePair`, and
   re-mapping it through any subsequent trim.

2. **Passthrough segment export snaps to sync frames.** The converter's lossless
   path can shift the requested cut points to the nearest sync sample — up to a
   GOP length (often 0.5–1 s) on some sources. The re-encode fallback is
   frame-accurate but only triggers when passthrough fails outright, not when it
   is merely imprecise.

3. **The assembled Live preview is a full render.** Toggling the canvas to "Live"
   runs the entire export pipeline (video export, filtered still, metadata remux)
   via `generateLivePreview()` before `PHLivePhoto.request` can assemble the
   result — several seconds for long clips. The result is cached and reused until
   any edit invalidates it (`invalidateLivePreview`), so toggling back and forth
   is free, but the first switch after an edit always pays full price.

4. **The project was authored without an iOS SDK build environment.** All Swift
   files are parse-verified and went through multi-agent adversarial review, but
   no `xcodebuild` has ever run against them. The first build in Xcode may surface
   type-checker issues — likely candidates are strict-concurrency/`Sendable`
   diagnostics around the AVFoundation bridging code and API-availability edges.
   Treat the first successful device build as a milestone, and file anything the
   compiler finds.

5. **Deprecation warnings on newer SDKs.** See §3.7 — the export-session API
   choice trades warnings for an iOS 17 floor.

6. **The simulator is a poor test bed.** Its photo library contains no Live
   Photos by default, and press-and-hold playback behaves differently. The
   checklist below assumes a real iPhone.

---

## 5. On-device testing checklist

Run on a physical iPhone (iOS 17+) with at least a few Live Photos and one
ordinary video in the library. A fresh install exercises the permission prompts;
delete the app first to reset them.

### Picking and loading

- [ ] Launch → home screen shows with no permission prompt of any kind
- [ ] Pick a Live Photo → editor opens with looping motion preview; filmstrip and filter thumbnails populate
- [ ] Pick an iCloud-optimized Live Photo (not locally cached) → loads (slower is fine, spinner shows)
- [ ] Cancel the picker → home screen unaffected

### Filters panel

- [ ] Each of the 12 presets applies to the *moving* preview instantly, without playback hitching
- [ ] Intensity slider blends the preset smoothly; at 0 the preset visually disappears
- [ ] Selecting Original resets intensity to full

### Adjust panel

- [ ] Each of the 8 sliders (exposure, brightness, contrast, saturation, vibrance, warmth, vignette, sharpness) restyles the running preview with no rebuild stutter
- [ ] Reset returns all sliders to neutral
- [ ] Adjustments persist while switching presets, and are *not* faded by the intensity slider

### Audio panel

- [ ] Import a music file → waveform renders; trim, offset, volume, fade in/out all audibly work in the preview
- [ ] Record a voiceover → microphone permission prompt appears with the correct usage string; recording meters live; stop installs it as the soundtrack
- [ ] Deny microphone permission → friendly error, no crash; re-enabling in Settings recovers
- [ ] Original-audio volume slider and mute toggle behave independently; unmuting restores the previous slider value
- [ ] Remove soundtrack → original audio returns

### Trim panel

- [ ] Handles drag with filmstrip feedback; preview rebuilds to the trimmed range
- [ ] Trimming to a very short range still previews and exports

### Live preview

- [ ] Toggle to Live → assembly progress, then press-and-hold plays the edited Live Photo
- [ ] Toggle Live → Motion → Live with no intervening edit → second switch is instant (cached)
- [ ] Any edit while in Live mode drops back to Motion (never an empty canvas)

### Export

- [ ] Save Live Photo → add-only photo permission prompt (first time), progress, success state
- [ ] In Photos: the saved asset shows the **Live** badge, press-and-hold plays, filters/trim/soundtrack are all baked in, still frame is filtered
- [ ] Deny add permission → friendly error pointing at Settings
- [ ] Share as video → MP4 renders with edits and audio mix baked in; share sheet presents; file plays in Messages/Files

### Converted video round-trip

- [ ] Pick a regular video → conversion sheet: segment range and key-frame selection work
- [ ] Convert → editor opens; edit, then save as Live Photo
- [ ] In Photos: converted asset has the Live badge and plays; still image matches the chosen key frame
- [ ] Re-pick the just-saved Live Photo in Lively → it loads and edits like any other (round-trip integrity)
- [ ] A video with no audio track converts and edits without errors (audio panel shows no original track)

### Appearance and hygiene

- [ ] Full pass through every screen in dark mode; flat palette (coral/amber/ocean/mint) reads correctly in both modes
- [ ] Background and relaunch mid-session → no crash
- [ ] After Reset/closing a session, `tmp` does not accumulate `LivelySession-*` directories
