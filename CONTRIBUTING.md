# Contributing to Lively

Thanks for your interest in making Lively better. It's a small, focused app — a flat-design SwiftUI Live Photo editor — and contributions that keep it small and focused are the most welcome kind.

## Filing issues

Bug reports are most useful when they let us reproduce the problem on the first try. Please include:

- **Device** (e.g., iPhone 15 Pro) and whether you were on device or in the Simulator — note that the Simulator has no Live Photos in its library by default, so most flows need a real iPhone.
- **iOS version** (Lively targets iOS 17+).
- **Steps to reproduce**, numbered, starting from a fresh launch when possible.
- What you expected, and what actually happened. Screenshots or screen recordings help a lot, especially for preview or export issues.

For export bugs, mention which path you used (Save as Live Photo vs. Share as Video) and whether the source was a picked Live Photo or a converted video.

## Proposing features

Open an issue before opening a PR. Describe the problem the feature solves, not just the mechanism, and how it fits Lively's flat design language and its zero-dependency, preview-equals-export philosophy. Small, well-scoped proposals are far more likely to land than broad ones.

## Development setup

1. Install **Xcode 16 or later**.
2. Clone the repository and open `Lively.xcodeproj`.
3. Build and run. That's it — Lively has **zero third-party dependencies**, so there is no package resolution, no lockfiles, and nothing to install.

For the full experience, run on a real iPhone: the Simulator's photo library contains no Live Photos by default, and features like the microphone voiceover and the press-and-hold `PHLivePhoto` preview behave best on device. The video-to-Live-Photo conversion flow does work in the Simulator with any video in the library.

## Code style

Lively's codebase is deliberately consistent. Before opening a PR, please match the existing conventions:

- **FlatTheme tokens only.** All colors, spacing, corner radii, and fonts come from `Lively/Theme/FlatTheme.swift`. Never hard-code a hex color, a padding constant, or a font in a view. If a token you need doesn't exist, add it to `FlatTheme` with a doc comment.
- **No third-party dependencies.** Lively ships with none, and PRs that add a package will be declined. Everything is built on SwiftUI, Observation, AVFoundation, Core Image, and PhotoKit.
- **Doc comments.** Every type and every non-obvious property or method carries a `///` comment explaining *why*, not just *what* — see `EditorViewModel.swift` for the house style. Each file opens with a short header comment describing its role.
- **MARK sections.** Group members under `// MARK: -` headings the way existing files do (Source, Edit state, Preview, Export, Helpers, …).
- **Parse-clean.** Changed files must compile without errors or new warnings. A quick `swiftc -parse` on the files you touched is a good pre-flight check before pushing.
- **Value-typed edit model.** Edits flow through `EditState` (a value type) so preview and export can never drift apart. New editing features should extend `EditState` rather than adding parallel state.

## Pull requests and review

The review bar is simple: **small, focused PRs**. One change per PR, with a description of what it does and how you verified it (device + iOS version). Large PRs that mix refactoring with behavior changes will be asked to split. Screenshots or a short recording are appreciated for anything user-visible.

Before writing view or model code, read **`docs/ARCHITECTURE.md`** — the contracts between views, `EditorViewModel`, and the Core engines (composition building, filtering, export) live there, including how edit-state changes are classified into visual, mix, and structural updates. PRs that respect those contracts review quickly.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE) that covers the project.
