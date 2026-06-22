# Contributing to Lentis

Thanks for your interest in contributing. Lentis is a native macOS NIfTI brain viewer built with SwiftUI, AppKit, and Metal.

## Development Environment

Requirements:

- macOS 14 Sonoma or later
- Apple Silicon Mac (`arm64`)
- Xcode 15+ or a Swift 5.9+ toolchain

No additional package managers, native libraries, or system dependency installs are needed. The app is pure Swift + Metal/AppKit.

## Building

```bash
# Clone the repo
git clone https://github.com/lijiaxiang63/Lentis.git
cd Lentis

# Debug build
swift build

# Debug build + stage dist/Lentis.app + launch
./scripts/build_and_run.sh

# Release app + DMG
./scripts/package_app.sh
```

`swift build` produces a package binary for iteration. Use `./scripts/build_and_run.sh` to run the app during development, and `./scripts/package_app.sh` to assemble `Lentis.app` and `Lentis.dmg` with the resource bundle and app icon.

## Running Tests

```bash
swift test
swift test --filter nifti --filter dataset
swift test --filter SegmentationSeam
```

Tests live in `Tests/LentisTests/` and cover NIfTI parsing, orientation, volume data, MPR rendering, Metal rendering, window/level behavior, overlay layers, and UI-adjacent state logic.

## Code Structure

```text
Sources/Lentis/
├── App.swift                  # Entry point, menus, benchmark launch
├── ContentView.swift          # Root view, sidebar, inspector, keyboard shortcuts
├── ViewerModel.swift          # Core model: panels, rendering, navigation, layers
├── ViewerModel+Nifti.swift    # NIfTI loading, modality, W/L policy, 4D
├── NIfTI.swift                # NIfTI-1/2 parser + pure-Swift gzip/DEFLATE
├── Orientation.swift          # Affine interpretation and canonical RAS orientation
├── VolumeData.swift           # Int16 3D volume, affine transforms, mask seam
├── MPREngine.swift            # CPU MPR extraction/rendering and overlay compositing
├── MetalVolumeRenderer.swift  # Interactive 3D volume renderer
├── LayerInspectorView.swift   # Mask/atlas layer and LUT UI
└── ...                        # State, overlays, resources, helpers
```

For the most detailed working notes, see `AGENTS.md` / `CLAUDE.md`.

## Contribution Guidelines

### Reporting Issues

Open an issue with:

- What you expected vs. what happened
- Steps to reproduce
- The NIfTI modality/type involved, if relevant
- macOS version
- Whether the issue reproduces with synthetic data or only real patient data

Do not attach identifiable patient data to public issues.

### Pull Requests

1. Fork the repository.
2. Create a focused branch.
3. Make your changes.
4. Run `swift test` and at least `swift build`.
5. For packaging or resource changes, also run `./scripts/package_app.sh`.
6. Commit with a clear message describing what changed and why.
7. Push and open a PR against `master`.

Keep PRs focused. One logical change per PR is easier to review than a bundle of unrelated edits.

### Code Style

- Keep orientation logic centralized in `MPREngine.planeGeometry`.
- Preserve nearest-neighbour handling for categorical mask/atlas overlays.
- Use `panel.setDisplayImage()` instead of assigning `panel.image` directly.
- Prefer small, focused tests for spatial, rendering, and W/L changes.
- Avoid introducing native/system dependencies unless there is a very strong reason.

## Contributing with AI Coding Assistants

AI-assisted contributions are welcome. Give the assistant the relevant README/AGENTS context, ask for focused changes, run the tests, and review the diff before committing.

If your contribution was AI-assisted, it is fine to mention that in the PR description. The quality and clarity of the change matters most.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE), the same license that covers the rest of the project.
