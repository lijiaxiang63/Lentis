# Lentis — Native macOS NIFTI Brain Viewer

A SwiftUI + Metal macOS app for viewing 3D brain **NIFTI** (`.nii` / `.nii.gz`) images,
supporting **both CT and MRI**. Forked from `jnheo-md/open-dicom-viewer` (MIT) and being
converted from a DICOM viewer into a NIFTI viewer.

**Goal:** load CT/MRI NIFTI (incl. 4D), display in **neurological orientation** (patient-left =
screen-left) per the image affine, **modality-aware window/level** (CT: HU presets incl.
Brain `(0,80)`; MRI: robust auto-window), draggable crosshair linking three orthogonal views,
an interactive Metal **3D brain volume-rendering** fourth view, drag-to-open. Remove all
DICOM/DCMTK/OpenJPEG deps. Keep MIT license. Leave clean seams for a
future intracranial-calcification segmentation feature (CT/HU-oriented).

This file is the working record. Update it as phases complete.

---

## Build / Test / Run

```bash
swift build                       # debug build (~20s clean; zero native/system deps)
./scripts/build_and_run.sh        # debug build + stage dist/Lentis.app + launch
./scripts/package_app.sh          # release build → Lentis.app + Lentis.dmg (ad-hoc signed)
swift test                        # full suite: MIXED XCTest + swift-testing (181: 114 XCTest + 67 swift-testing)
swift test --filter nifti --filter dataset   # just the NIFTI tests
swift test --filter SegmentationSeam         # just the Phase-7 mask-seam tests
swift test --filter windowLevelRenderIsAsync # the W/L-drag async/off-main regression test

# Release-mode end-to-end NIFTI load benchmark (read + dataset + canonical volume):
xcrun swiftc -O Sources/Lentis/{NIfTI,Orientation,LabelVolume,VolumeData,NiftiVolumeLoader}.swift \
  scripts/NiftiLoadBenchmark.swift -o /tmp/lentis-nifti-load-benchmark
/tmp/lentis-nifti-load-benchmark /abs/path/to/file.nii.gz

# Release-mode 3D rotation preview throughput (fails if p95 misses target FPS):
xcrun swiftc -O Sources/Lentis/{NIfTI,Orientation,LabelVolume,VolumeData,NiftiVolumeLoader,MetalVolumeRenderer}.swift \
  scripts/VolumeRenderBenchmark.swift -o /tmp/lentis-volume-render-benchmark
/tmp/lentis-volume-render-benchmark /abs/path/to/file.nii.gz 192 16 60

# Run + auto-open a file (App.swift handles --benchmark):
open Lentis.app --args --benchmark /abs/path/to/file.nii.gz
# Deterministic, GUI-free interactive-perf benchmark (W/L + crosshair + scroll):
open Lentis.app --args --benchmark /abs/path/to/file.nii.gz --perf-stress

# --- Auto-update (Sparkle) one-time key setup (DO THIS BEFORE the first tagged
#     release that should auto-update; until then releases publish a DMG-only
#     Release and in-app auto-check silently no-ops). ---
# 1. Generate an Ed25519 keypair (Apple CryptoKit, no deps):
swift scripts/sparkle_tools.swift generate
#    -> prints PUBLIC (base64) and PRIVATE (base64 32-byte seed).
# 2. Add the PRIVATE key as a GitHub repo secret named SPARKLE_PRIVATE_KEY.
# 3. Add the PUBLIC key as a GitHub repo variable named LENTIS_SPARKLE_PUBLIC_KEY
#    (used by .github/workflows/release.yml to bake SUPublicEDKey into Info.plist).
# Local release builds can also set LENTIS_SPARKLE_PUBLIC_KEY=<pub> env before
# ./scripts/package_app.sh. Releases then sign the DMG + emit appcast.xml
# (hosted as a Release asset; SUFeedURL = releases/latest/download/appcast.xml).
# NOTE: the Release workflow hard-gates the appcast on BOTH keys being set —
# a signed appcast is only published when the matching public key is also
# baked into the app's Info.plist (otherwise installs can't verify updates,
# so a private-key-only config is a hard CI error, not a silent mis-release).
# The workflow also derives the public key from the private key and compares
# it to the repo variable, so a copy/paste from the WRONG keypair (both keys
# present but mismatched) is a hard CI error too — it can't strand installs.
```

- **Perf probe:** `--benchmark` writes `~/Desktop/lentis_benchmark.csv` (and `[BENCH]` to stderr).
  Main-thread-cost events (must stay sub-ms): `scroll_main` (one scroll tick), `crosshair_set` (one
  crosshair relocation), `wl_drag` (one W/L flush). Off-main render events: `mpr_render` / `volume_render`
  (per-slice render ms). `--perf-stress` (with `--benchmark`) is a **self-driving** harness that loads
  the file, builds the brain quad, and fires 80 each of W/L flushes (sagittal MPR + 3D), crosshair
  relocations, and scroll ticks — logging the four main-thread-cost events — so interactive perf can be
  measured **without GUI/computer-use** (which coalesces a synthetic drag to ~2 events). Latest MPRAGE
  quad numbers: `wl_drag` 0.10 ms, `crosshair_set` 0.15 ms, `scroll_main` 0.30 ms — all off-main render.
  Add `--wl-hold` for a sustained ~15 s W/L drive that can be attached to with `sample`; unlike the
  cheap synchronous timer, this catches SwiftUI layout after the flush returns. The stress loop mirrors
  the real gesture (`persist:false` per flush, one `seriesStates` commit at drag end; `f952678`).

- Toolchain: Swift 6.3, Xcode 26.4, macOS arm64. Bundle id `com.kalicooper.lentis`.
  **One native dependency: Sparkle 2.x** (the macOS auto-update framework, bundled
  into the `.app` by `package_app.sh`) — see *Auto-update (Sparkle)* below. Imaging
  remains pure Swift + Metal/AppKit (DCMTK/OpenJPEG gone in Phase 3).
- `swift build` after adding a `PanelMode` case → the compiler flags every non-exhaustive
  `switch`. Fix each intentionally (usually mirror `.mprCoronal` or fold into a combined case).
- **Git state (2026-06-25):** work is on **`master`** in the single main checkout
  `/Users/jiaxiangli/neuroimaging/mriscript/Lentis`. **Phase 9 + the Segment/Settings UI polish merged
  via PR #1, the Codex export-safety fixes via PR #2 (`master` @ `285e872`), BIDS dataset support +
  Settings polish via PR #3 (`master` @ `6a4c208`), and the Segment-panel redesign via PR #4
  (`master` @ `f99e216`).** The `feature/calcification-segmentation`, `feature/bids-dataset-support`,
  and `feature/segment-panel-redesign` branches (and the old `Lentis-segmentation` worktree) were
  deleted after merge — no separate worktree anymore; future work happens here. Real patient data
  (`TestData/sub-*`) is gitignored — only synthetic fixtures are tracked. Commit per phase/logical step;
  branch off `master` for changes (it's the default branch) and open a PR.
  **Segment-panel redesign — DONE, merged to `master` @ `f99e216` (PR #4); incl. Codex P2/P3
  export-staleness fixes.** See the roadmap entry below; `swift build` clean, **204 tests** green
  (118 XCTest + 86 swift-testing).

---

## Repository layout

- SPM package/product/executable target = **`Lentis`**, sources in `Sources/Lentis/`. Plain
  `executableTarget`, no native deps; only the tests target alongside it.
- Test target = **`LentisTests`** (`Tests/LentisTests/`), uses `@testable import Lentis`.
- **DCMTK fully removed (Phase 3):** `Sources/DCMTKWrapper/` and `libs/` (~52 MB static libs)
  are deleted; recoverable from git history (before commit `1e4f5da`) if ever needed.
- `scripts/package_app.sh` builds the bundle (no `dicom.dic` copy anymore).
- `TestData/` holds real + synthetic NIFTI (see bottom). Gitignored: `.build/`, `*.app`, `*.dmg`.

### Key source files
| File | Role |
|---|---|
| `App.swift` | `@main struct LentisApp`. Menus. `--benchmark <path>` auto-open. **UI redesign (Liquid Glass, macOS 26):** plain `WindowGroup` — the window title comes from the detail's `.navigationTitle` (open file name) + `.navigationSubtitle` (modality · dims), replacing the old centered-title hack. **Auto-update (Sparkle):** holds an `UpdaterController` (`@StateObject`); the app menu's **Check for Updates…** calls `updater.checkForUpdates()`. |
| `UpdaterController.swift` | **Sparkle 2.x wrapper (auto-update).** Thin `@MainActor ObservableObject` owning `SPUStandardUpdaterController(startingUpdater:true,…)` — created lazily via `@StateObject` once `NSApplication` is ready (the safe point to start the updater). Auto-checks on launch (24 h interval; Sparkle's native update window handles download / EdDSA-verify / install / relaunch). `checkForUpdates()` is the manual entry point. `SUFeedURL` + `SUPublicEDKey` + `SUEnableAutomaticChecks`/`SUAutomaticallyUpdate` in `Info.plist` (set by `package_app.sh`) drive the feed, signature verification, and auto-check/auto-install behavior. |
| `sparkle_tools.swift` (`scripts/`) | **EdDSA keygen + DMG signing** for Sparkle, using Apple CryptoKit (`Curve25519.Signing` = RFC 8032 Ed25519, interoperable with Sparkle's libsodium). `generate` prints the public (→ `LENTIS_SPARKLE_PUBLIC_KEY` repo var / `SUPublicEDKey`) + private (→ `SPARKLE_PRIVATE_KEY` secret) base64 keys. `sign <file>` reads `SPARKLE_PRIVATE_KEY` env + prints the base64 signature for the appcast `sparkle:edSignature`. `public-key` derives the public key from the private key (used by the Release workflow to verify the repo variable matches the secret before publishing an appcast). No pip / no external deps — runs on the macOS runner. |
| `ViewerModel.swift` (~1700 lines) | **Central `@ObservableObject` model**. Panels, volume cache, MPR/3D, W/L, sync-scroll. **Crosshair (Phase 6):** `setCrosshair(_:from:)` relocates the orthogonal panels through a world point; `.volume3D` is deliberately excluded. The world point lives in a **decoupled `CrosshairState`**. **3D (Phase 8):** `loadVolumeRendering` is async/coalesced on `panel.loadingQueue`; `rotateVolumeRendering` drives preview/final camera renders. **W/L drag:** re-drives `loadMPRSlice`/`loadVolumeRendering` off-main. |
| `ViewerModel+Nifti.swift` | **NIFTI orchestration**: `loadNifti`, `applyNiftiDataset`, `selectTimepoint`, `setModalityOverride`. **Modality-aware W/L (Phase 5):** `modalityDefaultWindow`/`seededWindow` (seed), `applyWindowPreset`/`applyModalityAutoWindow`/`autoWindow(for:)` (UI). **Phase 7 seam:** `installDemoSphereMask` (`--benchmark`-only mask demo). |
| `BIDSDataset.swift` | **Pure BIDS model (no UI/AppKit).** `BIDSEntities.parse`/`derivativeName` (filename ↔ entities/suffix/ext; BIDS-valid derivative names, alphanumeric-sanitized), `BIDSImageFile` (+ `descIncludingModality` folds the source suffix into `desc` so sibling-modality derivatives can't collide), `BIDSSubject`/`BIDSSession`, `BIDSDataset.scan` (subject→session→**known-datatype** file tree; sidecars/`derivatives/` excluded; subject-root files kept as an implicit session; loose-folder fallback) + `derivativesDirectory`. Unit-tested via on-disk temp trees. |
| `BIDSNavigatorView.swift` | **Sidebar dataset navigator** (folder open). Outline of subjects → (named sessions) → image rows with datatype-aware icons, a filter field (flat search results), and an accent highlight + `eye.fill` on the loaded image. Tapping loads via `selectDatasetFile` (re-tapping the loaded row is a no-op — it must not wipe segmentation/layers). Loose folders list flat. |
| `WindowLevel.swift` | **`WindowPreset` + CT HU preset table** (Phase 5). Brain default `(0,80)`, Subdural/Stroke/Bone/Soft-tissue (HU). `storedWindow(slope:intercept:)` maps HU→stored (identity for direct-HU CT). Pure; no deps. |
| `Theme.swift` | **Design system (Liquid Glass UI redesign).** Signature indigo `lentisAccent` + semantic color tokens (CT amber, MRI teal, crosshair, link, group, viewport, annotations), `Spacing`/`Radius`/`Font` tokens, glass helpers (`glassChrome`, `lentisChip`), and the reusable `GlassIconButton`. All chrome sources its visuals here; the image viewport stays pure black. |
| `NIfTI.swift` | **NIFTI-1/2 reader**. Header/endianness/4D/9 dtypes, sform/qform affine, **table-driven pure-Swift DEFLATE** (`DeflateInflater`): direct mapped-input reads + zero-copy output `Data`. Zero deps. |
| `NiftiVolumeLoader.swift` | **`NiftiDataset`**: modality detection, Int16 quantization, percentile auto-window. **`makeVolume` reorients to canonical RAS** (Phase 4) — folds the relabel/flip into the quantization pass. |
| `Orientation.swift` | **Single source of orientation truth** (Phase 4). `anatomicalDirection(of:)` (RAS labels) + `closestCanonicalReorientation(affine:)` → `CanonicalReorientation` (axis permutation + flips, lossless, invertible). Pure; no deps. |
| `VolumeData.swift` | 3D Int16 voxel buffer + affine. **Two inits**: direction-cosine and full-affine (NIFTI). For NIFTI `voxelToWorldMatrix` is the **canonical RAS** affine; `originalAffine` + `reorientation` are retained for mask write-back. **Seg seam (Phase 7):** optional same-grid `labelMask: LabelVolume?` + `ensureLabelMask()`. |
| `LabelVolume.swift` | **Segmentation seam (Phase 7).** Same-grid UInt8 mask (slice-major, identical dims) riding on `VolumeData.labelMask`; shares the volume's voxel grid so write-back reuses its `reorientation` + `originalAffine`. `labelAt`/`setLabel`/`clear`/`labeledVoxelCount`. Inert in normal runs. |
| `OverlayLayer.swift` / `LayerStore.swift` | Session-scoped external Mask/Atlas layers. Immutable adaptive label storage (`UInt8` mask; `UInt16`/`Int32` atlas) is paired with observable visibility, opacity, color/LUT, per-label visibility, ordering, selection, and render revision state. The UI list is top-first; render snapshots reverse it so the top row composites last. |
| `OverlayLayerLoader.swift` | Background NIfTI layer loader and classifier. Accepts one 3D timepoint, auto-detects Mask vs Atlas from nonzero integer labels, uses a same-grid fast path or affine-aware world-coordinate nearest-neighbour resampling onto canonical RAS, and rejects non-overlapping volumes. |
| `ColorLookupTable.swift` / `CustomLUTRepository.swift` | Strict FreeSurfer-format LUT parser (`ID Name R G B T`, line-numbered errors, `opacity = 1 - T/255`) plus content-deduplicated custom LUT persistence in `~/Library/Application Support/Lentis/LUTs/`. The bundled default is `Resources/FreeSurferColorLUT.txt`. |
| `LayerInspectorView.swift` | Native trailing SwiftUI Inspector for adding/dropping, selecting, reordering, hiding, deleting/undoing Mask/Atlas layers; Mask color/opacity controls; Atlas LUT selection, searchable actual-label legend, voxel counts, per-label visibility actions, and LUT management. **UI redesign:** the forced opaque `.background(.background)` was removed — it tinted the inspector's toolbar segment a different shade and split the unified toolbar into two backgrounds; it now uses the system glass backing so the toolbar reads as one continuous surface (Keynote-style). **Toolbar-owned controls:** the add/remove-layer buttons + the open-state **Hide** toggle are declared in the inspector's **own** `.toolbar` section (gated on `showLayerInspector`); that inserts macOS's tracking separator, which confines the main content's toolbar to the viewport (the Keynote pattern) so the per-panel plane/modality/W-L controls no longer spill over the inspector. Body is `VSplitView{ layersPane · detailsPane }`; borderless `InspectorSectionHeader`/`InspectorSection` replace the old `GroupBox`/header/footer chrome. |
| `MPREngine.swift` | CPU slice extraction (`axialSlice`/`sagittalSlice`/`coronalSlice`) + `renderSlice(ww:wc:mask:…)` (CPU W/L — **Float + precomputed-reciprocal, parallelised across 8 bands** for ≥512² slices, `parallelToneMapThreshold`; RGBA composite when a mask is present). **`planeGeometry(mode:sliceIndex:)` is the one place** that defines each plane's neurological flips + display dirs (Phase 4); extractors, cross-ref metadata, **and `maskSlice` (Phase 7 seam)** all read it. **Crosshair geometry (Phase 6):** `PlaneGeometry.world(col:row:)`/`pixel(of:)` (exact-inverse pixel↔world) + `orthogonalSliceIndex(for:containing:)` (world→slice index). (`VolumeBuilder` removed in Phase 3.) |
| `CrossReferenceOverlay.swift` | **3D crosshair overlay (Phase 6, rewritten).** Draws two lines + center dot through `crosshair.world`'s in-plane projection, on MPR panels only; bridges raw→display pixels then reuses the image's `pixelToScreen` transform. `PanelState.displayedPlaneGeometry` helper. **Hosts `CrosshairState`** (tiny ObservableObject) and observes **it** (not the model) — so a crosshair drag invalidates only this overlay, not the whole quad (drag-lag fix). (Replaced the old `computeCrossReference` lines.) |
| `MetalVolumeRenderer.swift` | **Phase-8 direct volume renderer.** Metal compute ray marching over a cached `.r16Sint` 3D texture; physical-spacing-aware ray/AABB geometry, window-selective transfer function, front-to-back alpha compositing, early termination, gradient lighting, W/L in stored units. 192² interactive preview / 512² final render. |
| `CalcificationSegmenter.swift` | **Phase-9 segmentation engine** (pure). `VoxelBox` (+ `fromPlanePoints` rect→slab-box, **+ `handles(plane:sliceIndex:)`/`resize(plane:gripA:gripB:toVoxel:)`/`inPlaneAxes`/`slabAxis` for interactive 3D resize** — all on the ONE orientation source), `SegmentationMethod`/`Connectivity`/`Parameters`, and one configurable hysteresis dual-threshold + 3D connected-component + brain-mask AND + min-size grower (`segment`), Otsu (plateau-midpoint), `meanHU` (Method-B seed), ROI histogram, `BrainConstraint`. Works in canonical voxel HU via `VolumeData.calibratedValue`. `Parameters.growMarginVoxels: Int?` (nil = unlimited grow, the `.growFromSeed` default); `growBoundaryHURange` 40…80 + `thresholdHURange` 40…100 back the fixed-band sliders. |
| `CalcificationRegion.swift` | One region's data model (ObservableObject): label value, name/color/visibility, `parameters`, `box` + `slabAxis`, voxel/anatomical name. |
| `ViewerModel+Segmentation.swift` | **Multi-region orchestration.** Region lifecycle (begin/setBox/preview/commit/cancel/delete/re-edit), per-label color table for `loadMPRSlice`, touch-up `paintBrush`, brain-mask load + SynthSeg drive, mask/atlas export. Editable mask = `VolumeData.labelMask` (1…254 = regions, 255 = transient preview); all mask writes on main, then bump `segmentationRevision` + re-render (sync contract). **`exportSegmentation` throws `.draftActive` while a draft preview (label 255) is live** — the writer skips 255, so exporting mid-draft would silently drop overlapped committed voxels. |
| `SegmentationBoxOverlay.swift` | Draws the draft box's cross-section + corner markers on each intersecting MPR plane, reusing the `CrossReferenceOverlay` pixel→screen transform. 3D excluded. |
| `SegmentInspectorView.swift` | Segment tab of the trailing inspector. **Body is a conditional `Group` (empty state REPLACES the sections — never an `.overlay` over them, the old overlap bug):** no volume → a centered hand-built `emptyState` (cube glyph + "No Volume"); else `loadedBody`. **`statusStrip`** — the canonical at-a-glance status indicator: three equal-width glass pills (Brain · Regions · Export), each a `StatusCellModel {glyph,tint,title,value}` reading existing published state (no new state). Legend: green=ready/done, `lentisAccent`=active, orange=needs-setup/pending/finish-draft, secondary=none (amber/teal stay reserved for CT/MRI). **Brain Mask** — state-aware glyph (`BrainMaskState`); when a mask is loaded it collapses to a compact green done-summary (glyph + status + overflow `Menu`: Load/Regenerate/Clear); no mask → full cluster (**Generate with SynthSeg** `.glassProminent` hero + quiet **Load Existing…**) under an "Optional…" caption; running strip + reveal-in-Finder card. Active Region (method, ROI histogram, threshold sliders, Otsu/Mean, connectivity/min-size, live preview, Add/Cancel) wrapped in a faint `lentisAccent` glass card. Regions list (recolor/rename/re-edit/delete/brush; right-click + ellipsis both gated during a draft). **Export** — Mask/Atlas `.glass` buttons (disabled while a draft is active, with a hint) → after a successful export, a green reveal-in-Finder card (`hasExportedSegmentation`). |
| `NiftiWriter.swift` | **NIfTI-1 writer** (the reader is decode-only). Header serialize (offsets match `parseHeader`); **`writeMask` stages straight into a `UInt8` buffer** (mask/atlas labels are 1…254, 255 reserved → always DT_UINT8; no ~1.4 GB Int32 intermediate on big volumes), **write-back to the original input grid** via `reorientation`+`originalAffine`, gzip (Compression raw DEFLATE wrapped in an RFC-1952 container + CRC32) read by the pure-Swift inflater, `writeVolume` (gray CT for SynthSeg), FreeSurfer LUT sidecar. |
| `SynthSegRunner.swift` | Runs FreeSurfer `mri_synthseg --parc --robust --ct --cpu --threads N` via `Foundation.Process` (off-main, streamed progress, cancel). Locates the binary (user override → persisted binary → **`AppSettings` FreeSurfer home** → $FREESURFER_HOME/bin → PATH → /Applications/freesurfer/<ver>/bin) and sets a **clean** child env (writable HOME/TMPDIR, strips toxic inherited `PYTHON*`/`CONDA*`) so it works when launched from Finder. Reports **signal-vs-exit** (`status 6` = SIGABRT, a TF abort) and surfaces the captured stderr tail. |
| `AppSettings.swift` | **App-wide preferences** (UserDefaults-backed `ObservableObject` singleton `AppSettings.shared`): FreeSurfer home / `mri_synthseg` path (reuses `SynthSegRunner.defaultsKey`), SynthSeg `--robust`/`--parc`/threads, output-location mode (next-to-source / custom folder) + auto-load + write-brain-mask toggles, overlay opacity. `resolveOutputDirectory` (pure, tested) picks a writable dir with fallbacks; `niftiBaseName` strips `.nii`/`.nii.gz`. The viewer reads it on demand (SynthSeg) or subscribes (`$overlayOpacity` → live re-render). |
| `SettingsView.swift` | **The Settings window (⌘,).** A `TabView` of grouped forms in the dark Liquid-Glass idiom: **General** (overlay opacity, output location + folder picker with a live "Files go to" preview, auto-load / write-brain-mask toggles, **Export File Names** — filename-builder rows (`exportNameRow`: editable suffix in an accent capsule + `.nii.gz` chip) with a live both-files **Preview** (`composedFilename`)) and **FreeSurfer** (live `mri_synthseg` found/not-found status, FreeSurfer-home + binary pickers, `--robust`/`--parc`/threads). Binds `AppSettings`; reads `model.loadedFileURL` for the resolved-dir/preview. |
| `Toast.swift` | **Liquid-Glass success/info HUD.** `ViewerToast` (icon/tint/title/subtitle/optional `fileURL`) + `ToastBanner` (glass capsule, optional "Show in Finder"). Hosted as a top-center `ContentView` overlay; driven by `ViewerModel.toast` (`presentToast` auto-dismisses after 4 s). Used to confirm a direct (no-dialog) segmentation export. |
| `MultiPanelContainer.swift` (~1960 lines) | Multi-panel views + gestures. MPR panels keep pixel-bound orientation/crosshair/annotation/scroller overlays. Cursor tracking maps aspect-corrected display pixels back to raw slice pixels before HU lookup and then uses the panel geometry + cached volume affine to publish canonical voxel `x,y,z` for the status bar. **Phase 8:** Select-drag on `.volume3D` is a 60 Hz coalesced trackball-style yaw/pitch camera; it derives motion from absolute cursor-position differences (not unreliable `NSEvent.deltaX/Y`), and mouse-up settles at full quality. 3D deliberately hides 2D overlays, cursor sampling, and slice scroller. |
| `ViewerToolbar.swift` | **Native macOS Liquid Glass toolbar** (UI redesign; replaced the docked `ViewerControlBar`). `ToolbarContent` attached via `.toolbar` on the `NavigationSplitView` detail — the chrome gets glass/overflow/customization for free. Leading: layout segmented `Picker` + MPR + sync/crosshair toggles. Trailing: per-active-panel cluster (plane `Picker`, `ModalityBadge`, a W/L popover with histogram + presets/Auto, a transform menu) and the 4D stepper. Per-panel sub-views observe the panel (async image arrival). **The plane `Picker` is intentionally `.disabled` while `model.isMPRLayout` is true** — in the coordinated MPR tri-planar layout (`setupMPRLayout`) the four panels have fixed axial/sagittal/coronal/3D roles the crosshair linkage relies on, so per-panel plane switching is locked; any plain `setLayout` (layout picker, ⌘1–4, context menu) clears the flag and re-enables it. Not a bug — don't "fix" the greyed-out picker. 3D density lives in a popover (the no-`step:` slider is preserved). **The inspector show/hide toggle is intentionally NOT declared here** — to keep it pinned to the window's top-right corner above the inspector, `ContentView` owns the closed-state Show button and `LayerInspectorView` owns the open-state Hide button; keeping it out of this nested `ToolbarContent` also avoids stale re-evaluation and duplicate drawer buttons. |
| `ViewerStatusBar.swift` | **Floating Liquid Glass status pill** (UI redesign; was a docked bar). Content-sized capsule anchored bottom-leading over the viewport, non-interactive (`allowsHitTesting(false)`), shown only once a file is open. Active-panel readout once (file · slice · `WL/WW` +`HU` for CT); cursor readout (RAS mm / value / canonical voxel `px`) follows the hovered panel via `ForEach(model.panels)` of `StatusBarCursorInfo` — both observe their `@ObservedObject panel`. |
| `PanelState.swift` | Per-panel state. `PanelMode = .mprAxial/.mprSagittal/.mprCoronal/.volume3D` (the old inert `.slice2D` mode was removed in the repository-hygiene cleanup). Stores cursor display pixels, canonical volume voxel `x,y,z`, RAS mm position, and calibrated value for the docked status bar. 3D owns yaw/pitch/density plus a non-published render revision used to drop stale GPU results. |
| `ContentView.swift` | Root = `NavigationSplitView` (sidebar + detail) with a native trailing `.inspector` (`LayerInspectorView`). The detail is a `ZStack` { panel grid · floating glass `ToolPalette` (leading) · `NiftiLoadingOverlay` } with the floating glass `ViewerStatusBar` as a bottom-leading overlay, plus `.navigationTitle`/`.navigationSubtitle` + `.toolbar { ViewerToolbar }` (and **owns the closed-state "Show Layers Inspector" toolbar button**, gated on `!model.showLayerInspector`; the open-state Hide lives in `LayerInspectorView`). A root `.tint(.lentisAccent)` drives native controls; `.preferredColorScheme(.dark)`. Sidebar header is **Files** (glass-prominent Open); rows show file name + `modality · WxHxD` + brain icon (`model.loadedFileName`). |
| `WindowAccessor.swift` | AppKit bridge: window config (`isMovableByWindowBackground`, `.unified` toolbar style) + the IME-independent `KeyInterceptorView` (now with a testable `handle(key:)` seam). **The centered-title machinery was removed** — `.navigationTitle` owns the title now (UI redesign). `configure(window:model:)` is idempotent and unit-tested in `WindowAccessorTests`. |

---

## Data & rendering pipeline (must understand)

1. **2D slice rendering is CPU; 3D volume rendering is Metal.** Axial/sagittal/coronal go through
   `MPREngine.renderSlice` (Swift per-pixel W/L loop). `.volume3D` goes through
   `MetalVolumeRenderer.renderVolume`: orthographic physical-space ray marching,
   window-selective opacity, front-to-back alpha compositing, early termination, and gradient lighting.
   **Extraction + render + NSImage build run on the panel's serial background queue
   (`loadMPRSlice` → `panel.loadingQueue`) and are coalesced** — each navigation
   `cancelAllOperations()` + enqueues, and the main-thread apply drops results whose
   `mprSliceIndex`/`panelMode` no longer match. So fast scrubbing only pays for the in-flight render
   plus the latest target, and the main thread never blocks. **3D uses the same queue discipline**
   (`loadVolumeRendering`): GPU `waitUntilCompleted()` + readback run on `panel.loadingQueue`, and a
   `volumeRenderRevision` drops stale in-flight results. 3D has no slice index and is excluded from
   synchronized scrolling/crosshair relocation. Drag rotation renders a coalesced 192² preview at
   60 Hz and a 512² final frame on mouse-up.
   W/L drag is throttled to 60 Hz and is **also off-main now** — `adjustWindowLevelForPanel` updates
   the W/L state synchronously (the toolbar binds it) and re-drives the panel's async+coalesced loader
   (`loadMPRSlice` / `loadVolumeRendering`), so W/L remains off-main for every rendered panel.
   `renderSlice`'s W/L loop is **Float + precomputed-reciprocal + parallelised** across 8 bands (1 MP
   slice 3.14 → 0.46 ms end-to-end, max gray delta 0). The brief's "windowing = GPU uniform only" rule
   is **still NOT met for slices, and is deliberately not pursued** (see *Known issues* #3): the earlier
   rationale here ("W/L arithmetic is cheap; cost is the extraction + NSImage alloc") was **measured to
   be wrong** — the W/L loop was ~80% of `renderSlice` (CGContext alloc 0.008 ms, makeImage/NSImage
   0.018 ms). Now that the loop is fast on CPU, a GPU **per-slice-readback** path would only break even
   (upload + `waitUntilCompleted` + readback ≈ the whole CPU render) while adding orientation-plumbing
   risk. The real GPU win needs the readback gone — a **live `MTKView`** with W/L as a shader uniform
   (no NSImage), a real NSImageView→MTKView migration deferred until a concrete driver appears. If ever
   pursued, the clean seam still holds: keep slice *extraction* (the oriented Int16 buffer) in
   `MPREngine`, upload it to a 2D `.r16Sint` texture, W/L in a trivial shader — **no flip logic in MSL**,
   so tested orientation can't drift. (`MetalVolumeRenderer` owns the 3D texture + in-shader transfer function.)
2. **W/L units = RAW STORED Int16 values.** The shader/CPU window on stored voxels; `scl`/rescale
   is NOT applied in the window math. So presets & auto-window are expressed in **stored units**.
3. **VolumeData stores Int16.** NIFTI float32/uint16 are **quantized to Int16** by `NiftiDataset`,
   with the quantization folded into `VolumeData.rescaleSlope/Intercept` so `calibratedValue()`
   reconstructs the true value. **CT stores HU directly** (slope 1, intercept 0) when the range
   fits Int16 and spans ≥256 levels → **HU presets need no conversion**. Float data with small
   range is scaled across ~64000 levels. 4D quantization uses the **global** range over all
   timepoints (so every volume displays on one scale).
4. **Volume display path for NIFTI:** `loadNifti` → `NiftiDataset` → `makeVolume(t)` (**reorients
   to canonical RAS**, see 5) → `registerStandaloneVolume(volume, cacheKey: dataset.seriesID, …)`
   (caches under a **stable key** + appends a stub `ImageSeries` with empty `images`) → panel set
   into the quad: three MPR modes render through `loadMPRSlice`; `.volume3D` renders through
   `loadVolumeRendering`. A 4D switch replaces the cached volume under the same key and re-renders all
   four panels. `VolumeData.seriesUID` is distinct per timepoint (forcing the 3D texture re-upload);
   the **cache key** is stable.
5. **Orientation = canonical RAS + fixed neurological flips (Phase 4).** NIFTI world space is RAS+
   (+x=R, +y=A, +z=S). `Orientation.closestCanonicalReorientation` computes the axis permutation +
   flips that bring the voxel grid to closest-canonical RAS (i→R, j→A, k→S); `makeVolume` applies it
   (lossless whole-axis relabel, **no resampling**) and stores `originalAffine` + `reorientation` for
   mask write-back. Because every volume is then canonical, `MPREngine.planeGeometry` applies a
   **fixed** flip per plane for the standard neurological layout (buffer row 0 = screen top, col 0 =
   left): axial L-left/R-right, A-top/P-bottom; coronal L-left/R-right, S-top/I-bottom; sagittal
   A-left/P-right, S-top/I-bottom. The extractors, the cross-ref/label metadata (`loadMPRSlice`,
   `updateMPRSpatialMetadata`), and `OrientationLabelsOverlay` (RAS) all read this one definition, so
   pixels + lines + labels can't diverge. The old `flipZ` heuristic + per-plane sign-flip blocks are gone.
   (`isSeriesVolumetric` is now a cached-volume check, so the per-panel MPR toolbar works for NIFTI.)
6. **Modality** lives on the model: `niftiDataset.detectedModality`, `modalityOverride`,
   `effectiveModality`. Detection heuristic: `min ≤ -500 && fraction(v < -200) ≥ 2%` ⇒ CT.
   **Modality drives W/L (Phase 5):** `modalityDefaultWindow` → CT = the Brain HU preset
   (`WindowPreset`, converted to stored units via the volume's rescale), MRI = `suggestedWindow`
   percentile. `seededWindow` prefers a saved manual window (`seriesStates`) over the default, and
   `assignSeriesToPanel` / `applyNiftiDataset` seed **every** panel from it (fixes the dark quad
   MPR). The CT/MRI switch is the `ModalityBadge` in the native `ViewerToolbar` (click to swap
   modality + reseed W/L); the bar's window control then shows a CT preset menu vs an MRI "Auto" button
   by `effectiveModality` — all acting on `model.activePanel`; presets apply to all panels showing the
   series (`applyWindowPreset`). (UI-unify pass: these moved off the per-panel floating toolbars.)
7. **Cursor readout:** `cursorHU = stored * panel.rescaleSlope + panel.rescaleIntercept`, label
   `panel.valueUnitLabel` ("HU" for CT, "Intensity" for MRI); shows canonical volume voxel
   `px [x,y,z]` + RAS `mm`. `MultiPanelContainer` converts the aspect-corrected display cursor back
   to raw slice pixels before HU lookup, then uses `PanelState.displayedPlaneGeometry` for RAS and
   the cached volume's `worldToVoxel` affine for voxel `x,y,z`. Now rendered in the docked
   `ViewerStatusBar` (was the floating `CursorInfoOverlay`), following the hovered panel; the status
   bar's W/L readout appends `HU` for CT (dropped for MRI). (Readout still needs a real NSTrackingArea
   mouse event — synthetic computer-use moves may not trigger it.)
8. **Segmentation mask overlay (Phase 7 seam; dormant).** A same-grid `LabelVolume` rides on
   `VolumeData.labelMask` (UInt8, identical voxel grid → write-back via the volume's `reorientation`
   + `originalAffine`). `MPREngine.maskSlice(mode:sliceIndex:)` extracts it in the **same (col,row)
   layout as the gray slice** by mirroring `planeGeometry`'s flips (so the overlay can't drift —
   `SegmentationSeamTests` locks all 3 planes against the gray extractor). `loadMPRSlice` passes the
   mask to `renderSlice`, which composites a translucent color (model `maskOverlayColor`/`Alpha`,
   default calcification red) over labeled pixels — **CPU RGBA path, taken only when a mask exists**,
   so the grayscale fast path is untouched in normal runs. **3D is excluded** (Metal path; documented
   seam). The CPU composite is the live-display seam; a future **Metal** entry would upload the mask as a 2nd R8
   texture, blend in the W/L shader) is documented in `renderSlice`/`MetalVolumeRenderer`. Demo:
   `--benchmark` paints `installDemoSphereMask` so the overlay is visible once; inert otherwise.
9. **External Mask/Atlas layers (2026-06-22).** `ViewerModel` owns a session-only `LayerStore`; adding
   NIfTI layers parses and aligns them off-main through `OverlayLayerLoader`. Same-grid files retain
   categorical values without interpolation; differing affines map target canonical-RAS voxel centers
   through world space and sample nearest neighbour, with zero outside the source. `MPREngine` extracts
   every visible layer with the same `planeGeometry` as grayscale, then composites bottom-to-top using
   the immutable render snapshot/revision. Label 0 is always transparent. Masks use one selectable
   color; atlases use the bundled/custom LUT, per-label visibility, and a stable hashed fallback for
   missing entries. Zero visible layers stay on the original grayscale fast path. External layers are
   currently MPR-only; the fourth Metal 3D panel remains unchanged.

---

## Critical gotchas (hard-won)

- **`MPREngine.sagittalSlice` is a perf-sensitive parallel raw-pointer walk** (commit `cb12693`) — it is
  the worst-case extraction (fixes i, spans j×k → cache-missing gather over the whole buffer; 1 MP on the
  MPRAGE). It does the **same gather byte-for-byte** as a `voxelAt` loop (orientation is identical — the
  flips still come from `planeGeometry`, guarded by `testSagittalSliceNeurologicalOrientation`) but via a
  bounds-check-free pointer walk parallelised across z-planes (disjoint writes, read-only source). Do
  **not** "simplify" it back to a `voxelAt` triple-loop — that re-introduces the ~15 ms / ~57-slices/s
  fast-scroll lag. If you ever touch its flips, edit `planeGeometry` (the one orientation source), not the
  loop. Profile with the standalone throughput harness pattern (load `NiftiDataset` → `makeVolume` → time
  `axial/sagittal/coronalSlice` + `renderSlice`); axial/coronal are already contiguous + fast, leave them.
- **gzip decode = pure-Swift DEFLATE.** `DeflateInflater` in `NIfTI.swift` (validated vs. real
  Python gzip: small/all-zero/70 KB multi-block + real 34 MB `.nii.gz` all match). Originally
  written because Apple `Compression` `COMPRESSION_ZLIB` *decode* was broken by DCMTK's bundled
  static zlib `inflate` interposing. DCMTK is gone now, but keep the pure-Swift decoder — it's
  dependency-free and correct. Do NOT "simplify" back to the Compression framework. **Large-file
  perf fix (2026-06-21):** canonical Huffman prefix lookup replaced per-symbol bit walking; the
  bit reader is a local value type; input is read directly from mapped `Data`; and an exact-size raw
  output buffer is handed to `Data` without copying. Real 445.9 MB MPRAGE: NIFTI read **16.00 →
  4.94–4.99 s**, full read + statistics + quantize/RAS volume **~19 s inferred → 8.00 s measured**.
  `scripts/NiftiLoadBenchmark.swift` is the release-mode regression harness. Its full-volume Int16
  checksum `166302106370` matches streaming Python gzip/numpy exactly.
- **`Data.withUnsafeBytes { $0[0] }` footgun.** The untyped closure infers `UnsafePointer<Int>`,
  so `$0[0]` reads 8 bytes as an `Int`. Always type it: `{ (raw: UnsafeRawBufferPointer) in raw[0] }`.
- **Adding a `PanelMode` case** breaks several exhaustive switches across `ViewerModel.swift`. Build,
  read the compiler notes, add the case (mirror coronal / use `vol.depth`).
- **The window title comes from `.navigationTitle`/`.navigationSubtitle` (UI redesign).** `App.swift`
  uses a plain `WindowGroup`; `ContentView`'s detail sets the title to the open file name plus a
  `modality · dims` subtitle — the native macOS pattern. The old centered-title hack and the
  `WindowAccessor` title-syncing machinery it required were **removed**; `WindowAccessor` now only
  configures the window (movable-by-background, `.unified` toolbar) and retains `Lentis` for the
  accessibility/minimized-window name. Do **not** reintroduce a custom centered title or set a non-empty
  `WindowGroup("…")` scene title. Regression coverage is in `WindowAccessorTests`.
- **Overlay labels are categorical.** Never use linear/trilinear interpolation for Mask/Atlas import or
  slice extraction. Keep affine-aware nearest-neighbour resampling in `OverlayLayerLoader`, label 0
  transparent, and all display flips sourced from `MPREngine.planeGeometry`. A layer-list top row is
  visually topmost and therefore renders **last**, even though the UI array is stored top-first.
- **Orientation lives in ONE place: `MPREngine.planeGeometry`** (Phase 4). The render chain maps
  **buffer row 0 → screen top, col 0 → left** (CGImage row 0 = top; NSImageView draws upright) —
  confirmed on `synthetic_orient` octant markers. Volumes are already canonical RAS (i→R, j→A, k→S),
  so each plane uses a *fixed* flip; do **not** reintroduce per-file/`sliceDirection` heuristics. If
  you add or change a plane/flip, edit `planeGeometry` only — extractors, cross-ref metadata, and
  labels all read it, and the corner-orientation tests in `MPREngineTests` will catch a sign error.
- **[RESOLVED] Large `.nii.gz` load latency.** Huffman decode is now prefix-table driven and the
  inflate path avoids the old large intermediate arrays/output copy. Keep the benchmark above when
  changing the decoder; the 445.9 MB MPRAGE read budget is 8 s in release mode (latest ~4.95 s).
- **MPR *and* MIP render are async + coalesced (`loadMPRSlice`, `loadMIPForPanel`).** Extraction / GPU
  MIP + W/L + NSImage build run on `panel.loadingQueue` (serial, background); each navigation
  `cancelAllOperations()` + enqueues, and the main-thread apply **drops stale results** whose
  `mprSliceIndex` / `mipSlabPosition` / `panelMode` no longer match. Do **not** revert either to
  synchronous main-thread rendering — it froze scrolling on the 344×1024×1024 / 721 MB MPRAGE. **The MIP
  path was the subtle one:** `renderProjection` does `commandBuffer.waitUntilCompleted()` (a synchronous
  GPU wait) + readback, and in the **quad MPR + synchronized-scroll** layout `syncScrollFromPanel`
  re-rendered the MIP panel on the main thread *every tick* (~15–20 ms steady, ~180 ms on the first
  721 MB→GPU upload). Off-main it's ~1–2 ms. `MetalVolumeRenderer.renderProjection` is now
  `renderLock`-serialized since it's driven from background queues. The captured `volume` is held
  strongly through the render (survives a 4D swap); the previous slice stays on screen until the new one
  lands (no spinner flicker — the `isLoading` ProgressView only shows when `panel.image == nil`).
  **Measured (`--benchmark`, `scroll_main`): per-tick main-thread cost ~15–25 ms → 0.3 ms** on the
  MPRAGE quad layout (also `mpr_render` / `mip_render` log per-render ms).
- **RTK shell proxy** (user's global `~/.claude`) rewrites `grep`→`rg` and can mangle
  `find … $(...)` / regex alternation. Prefer `rg`-native syntax or absolute `/usr/bin/...` paths.

---

## Known issues / open problems (as of HEAD)

Ordered roughly by priority. None block the build or tests; these are quality/perf debt.

> **✓ RESOLVED — Phase-6 crosshair DRAG lag** (commits `04e7290` Slider + `fbe5b1d` decouple).
> **The documented prime hypothesis was WRONG** — a cautionary tale. The redundant
> `updateNSView`/`applyFilters` re-application I suspected measured **0.0 ms** (instrumented per
> sub-call with `CLOCK_THREAD_CPUTIME`); guarding it would have done nothing. The real cost was found
> only by a CPU **`sample`** of the main thread during a drag-rate stress run.
> **Actual root cause — a pathological SwiftUI `Slider`.** The MIP panel's "Slab" slider
> (`VolumeToolbar.swift`) used `in: 1...maxSlabSlices, step: 1`, where `maxSlabSlices` = volume depth
> (**~1024** for the MPRAGE). On macOS a *stepped* `Slider` renders one tick-mark **label per step**, so
> SwiftUI laid out **~1024 marks** (`SliderMarkLabels.LabelLayout.LabelLayoutResolver.place`) on every
> layout pass of that toolbar — **~2 s of main-thread layout**. `crosshairWorld` was `@Published` on the
> model, so a drag fired `model.objectWillChange` **per mouse event** → the MIP `VolumeToolbar`
> re-evaluated → that ~2 s layout ran every event. (This is exactly why **scroll was fine but the
> crosshair thrashed**: scroll mutates *panel* state; the crosshair mutated *model* state, hitting the
> MIP toolbar's slider.)
> **Fix 1 (root cause) — `04e7290`:** drop `step:` from the Slab slider → continuous slider, no marks
> (setter snaps to `Int`, so slab stays integer). **~1980 → ~100 ms/event.**
> **Fix 2 (residual) — `fbe5b1d`:** the remaining ~100 ms/event was generic quad relayout from the
> per-event `model.objectWillChange`. Moved the crosshair world point into its own `CrosshairState`
> `ObservableObject` (in `CrossReferenceOverlay.swift`) observed **only** by `CrossReferenceOverlay`;
> `model.crosshairWorld` is now a computed shim forwarding to `crosshair.world` (call sites unchanged).
> Also removed the obsolete `self.objectWillChange.send()` in the MPR/MIP render completions (its only
> job — refresh all overlays — is moot now that overlays observe `CrosshairState` + their own panel).
> **~100 → ~1.7 ms/event** (steady; 42 ms first-event warmup). Overall **~1980 → ~1.7 ms/event**, ~1000×.
> **How measured (computer-use CANNOT reproduce this** — it coalesces a synthetic drag to ~2 events):
> a deterministic in-app `--xhair-stress` harness (since removed) fired N `setCrosshair` calls along a
> slice sweep, draining the run loop after each, timing **main-thread CPU** (`CLOCK_THREAD_CPUTIME`, not
> wall — wall includes a render-server forcing artifact) per event + a CPU `sample`. A permanent
> `crosshair_set` `--benchmark` probe (scroll_main-style) was kept.
> **Verified (real T1, GUI):** patient-LEFT axial click → Sagittal **47/176** (left hemisphere); drag to
> patient-R + anterior → Sagittal **135/176**, Coronal **160/240** — laterality + A-P intact, crosshair
> tracks, MIP excluded. Slice labels still update (confirms the `objectWillChange.send()` removal is
> safe). **99 tests green** (43 XCTest + 56 swift-testing; +4 in `CrosshairDecouplingTests.swift` lock
> in "a crosshair write must NOT fire `model.objectWillChange`"). Orientation untouched.
> **Lesson:** for a SwiftUI "lag", `sample` the main thread before trusting a hypothesis — the cost was
> in layout of an unrelated control, not the code that *triggered* the invalidation.
> **(Not done — deliberately skipped):** throttling `setCrosshairFromEvent` (lead 2) is unnecessary at
> ~1.7 ms/event and would make the crosshair feel less responsive; guarding `updateNSView` (lead 1) is
> moot (measured 0 ms, and the overlay is decoupled so drags no longer call it).

1. **[FIXED — commit `cb12693`] MPRAGE fast-scroll lag = sagittal slice extraction.** Diagnosed with a
   deterministic standalone harness over the real `MPREngine` code (differential: MPRAGE vs CT/T1). The
   344×1024×1024 MPRAGE's **sagittal** plane is a 1-megapixel slice extracted by a cache-hostile gather
   through `voxelAt` (688-byte stride, per-voxel bounds check + index multiply) — **~15 ms**, capping the
   serial render queue at **~57 slices/s** so fast scroll dropped frames (both single-panel sagittal and
   the quad where group/sync scroll re-renders it). Axial (1.3 ms) and coronal (2.3 ms) were already
   fine — matching "CT/T1 scroll fine". Fix: `sagittalSlice` now does the **same gather byte-for-byte**
   (orientation unchanged — guarded by `testSagittalSliceNeurologicalOrientation` corner checks + harness
   equality) via a raw-pointer walk parallelised across z-planes (disjoint writes). **Measured: sagittal
   extract 15.25 → 1.54 ms (10×); end-to-end 17.9 → 4.70 ms = 57 → 213 slices/s (above refresh).** App
   cross-check: in-app axial `mpr_render` = 1.5 ms matches the harness, so harness numbers reflect the
   real path. **GUI-verified (real app, `--benchmark`):** sagittal `mpr_render` ~5.0–6.7 ms warm (8.4 ms
   cold), `scroll_main` 0.1–0.5 ms/tick; orientation correct in single-panel **and** the one-click quad
   (S/I/A/P labels, no tearing → parallel extraction is race-free); all four quad panels W/L-seeded/bright.
2. **[RESOLVED — W/L-drag perf]** Two commits (`de07903` renderSlice, `9399a6a` async). The W/L-drag
   re-render used to run synchronously on the main thread — MPR ran `MPREngine.renderSlice` on the
   megapixel slice; **MIP ran `renderProjection`'s `waitUntilCompleted` GPU block directly on main**
   (the same block the scroll fix moved off-main, ~15–20 ms steady / ~200 ms first upload). Fix:
   (a) `renderSlice`'s W/L loop is now Float + precomputed-reciprocal + parallelised across 8 bands —
   the loop was **~80% of renderSlice's cost** (CGContext alloc 0.008 ms + makeImage/NSImage 0.018 ms
   are negligible; see §1), measured **3.14 → 0.46 ms end-to-end** on a 1 MP slice (max gray delta 0).
   (b) `adjustWindowLevelForPanel` keeps the W/L *state* update synchronous (the toolbar binds it) but
   pushes the re-render off-main by re-driving the panel's own async+coalesced loader (MPR →
   `loadMPRSlice`, MIP → `loadMIPForPanel`). Re-driving `loadMPRSlice` (vs a render-only path over the
   cached `rawPixelData`) re-extracts the *current* slice fresh — cheap off-main, correct by
   construction (can't show a stale slice if a scroll was in flight). **Measured (`--perf-stress`,
   MPRAGE quad): `wl_drag` main-thread cost 0.10 ms (MPR + MIP)** — down from a synchronous render of
   ~3 ms (MPR) / ~15–200 ms (MIP). Locked by `windowLevelRenderIsAsyncOffMainThread` (verified red on
   `de07903`). The `renderSliceMasked` composite got the same Float+parallel treatment (`8b9919b`).
   **Follow-up toolbar relayout — FIXED (`4250965`).** The remaining 48–72 ms happened after this
   function returned: a flexible quad propagated ideal-size queries to sibling panels, then the bottom
   toolbar's AppKit-backed segmented `Picker` (`SystemSegmentedControl`) recursively measured an embedded
   SwiftUI graph on every W/L publication. Cells now have exact geometry and CT/MRI uses two fixed-size
   buttons. On the 344×1024×1024 MPRAGE `--wl-hold` sample, layout-pattern stacks fell **48,886 →
   1,105**, the top `LayoutEngineBox.sizeThatFits` weight **1,215 → 156**, and
   `explicitAlignment` **623 → 139**; `SystemSegmentedControl` disappeared. GUI-verified that CT/MRI,
   Auto/Preset, quad geometry, and sagittal W/L drag still work. There is no reliable unit-test seam for
   private SwiftUI layout; the permanent `--wl-hold` + `sample` harness is the regression signal.
3. **GPU slice W/L — EVALUATED, deliberately NOT done (CPU wins make it pointless).** The old premise
   here was **wrong**: it claimed per-slice cost is "dominated by extraction + NSImage alloc, *not* the
   W/L arithmetic." Measured the opposite — the W/L **arithmetic** was ~80% of `renderSlice`; the
   NSImage alloc is 0.018 ms. Having now optimized that arithmetic on CPU (Float+parallel, **0.46 ms**
   for a 1 MP grayscale slice, fully off-main), a GPU per-slice path (upload Int16 → `.r16Sint` texture,
   W/L shader, **readback** → NSImage) offers **no win**: the texture upload + `waitUntilCompleted` +
   readback round-trip alone costs ≈ the entire CPU render, while adding complexity and orientation risk
   (extraction/flips would stay in `MPREngine.planeGeometry`, but the upload/readback plumbing is new
   surface). **Recommendation: do not do the per-slice-readback GPU variant.** The genuine GPU payoff
   needs the **readback eliminated** — render straight into a live `MTKView`/`CAMetalLayer` per MPR
   panel, with W/L as a shader uniform (no CPU re-render, no NSImage). That is a real architectural
   change (NSImageView → MTKView; crosshair / cursor / orientation / ROI overlays re-plumbed onto the
   Metal layer) and should wait for a concrete driver — there is none today (W/L drag is already
   0.10 ms main-thread). It would also unlock the Phase-7 Metal mask-texture overlay. **When
   segmentation goes live (Phase 9):** the masked path's real cost is `maskSlice`'s *serial* sagittal
   gather (~13 ms — the cache-hostile pattern the gray extractor had before `cb12693`), NOT the W/L
   arithmetic (the masked render loop is ~1.7 ms). Parallelise `maskSlice` first (mirror `sagittalSlice`)
   — bigger win than GPU, keeps orientation in `MPREngine`.
4. **[RESOLVED — Phase 6] Quad-MPR cross-panel linkage is now the 3D crosshair.** Click/drag sets
   `crosshairWorld`; `ViewerModel.setCrosshair` relocates each orthogonal panel via
   `MPREngine.orthogonalSliceIndex` + async `loadMPRSlice`; `.volume3D` is excluded. The old z-only `syncScrollFromPanel` proportional
   mapping is no longer the cross-panel mechanism (it remains only for the mouse-wheel group-scroll path).
   Note the "stuck orthogonal panels" complaint was partly a misread: scrolling S *should not* change which
   sagittal/coronal slice is shown — what was missing (and is now drawn) is the moving crosshair line.
5. **`--benchmark` instrumentation left in** (`scroll_main`, `mpr_render`, `volume_render`, `crosshair_set`).
   Gated behind `--benchmark` so it's inert in normal runs, but in benchmark mode it logs to
   `~/Desktop/lentis_benchmark.csv` per scroll tick (each `log()` also takes a `task_info` memory snapshot).
   Keep as a perf probe, or strip `scroll_main`/`mpr_render` once perf work settles.
6. **[RESOLVED — repository hygiene cleanup, 2026-06-22] Phase-3 cosmetic debt.**
   Stale `// OpenDicomViewer` source headers were replaced with `// Lentis`; the
   interactive panel/scroller types are now `PanelInteractiveImageView`,
   `PanelImageInteractView`, and `PanelSliceScroller`; the inert `.slice2D`
   `PanelMode` case was removed; vestigial `ImageContext` and `ImageSeries.images`
   were deleted; the old DICOM grouping tests were removed; the W/L persistence
   tests now use the current series model; the obsolete native dependency setup
   script, old entitlements file, and compatibility `build_native.sh` wrapper were
   deleted; CONTRIBUTING/HELP/docs now describe the NIfTI app. Historical fork
   attribution and Phase-3 removal notes remain.

---

## Phase status & roadmap

> **▶ UI REDESIGN (2026-06-22, branch `ui-redesign` / worktree) — Liquid Glass, macOS 26.**
> Bold chrome restructure on a dedicated branch (image viewport untouched, stays pure black):
> deployment target bumped to **macOS 26** (Swift 5 language mode pinned); new **`Theme.swift`**
> design system (signature indigo accent + tokens + glass helpers); the docked control bar became a
> **native window toolbar** (`ViewerToolbar.swift`); the window title is the open file via
> `.navigationTitle` (the centered-title hack + its machinery were deleted from `WindowAccessor`,
> which kept the IME `KeyInterceptorView` + a testable `handle(key:)` seam); the tool palette is a
> **floating glass capsule**; panels are **rounded inset cards** with an accent active-glow on
> `Color.lentisViewport`; the status bar is a **floating glass pill**; sidebar = **Files** + a
> glass-prominent Open; global `.tint(.lentisAccent)`. `swift test` green (**122: 63 XCTest + 59
> swift-testing**; `WindowAccessorTests` rewritten). GUI-verified on real T1 (toolbar/title/sidebar/
> tool capsule/rounded panels/status pill/inspector/modality toggle/crosshair/3D), incl. the
> Inspector-toggle title-regression check (one title, no flash). **Post-feedback toolbar/inspector
> polish (final):** `LayerInspectorView`'s forced opaque background was removed so the unified toolbar
> no longer splits into two shades over the inspector column; the inspector toggle was then moved out of
> `ViewerToolbar` entirely — `ContentView` owns the closed-state Show button and `LayerInspectorView`
> owns the open-state Hide button + the add/remove-layer buttons in its **own** `.toolbar` section,
> whose tracking separator confines the main toolbar to the viewport (the Keynote pattern) so per-panel
> controls no longer spill over the inspector; `GroupBox` chrome became borderless `InspectorSection`
> headers. `swift build` clean, `swift test` green (**122: 63 XCTest + 59 swift-testing**).
> **Merged to `master` (fast-forward) on 2026-06-22.**
>
> **▶ RESUME POINT (2026-06-22) — Phases 1–8, performance fixes, native external Mask/Atlas layers,
> LUT management, centered-title/Inspector fixes, and repository-hygiene cleanup are on `master`.**
> `master` was synchronized with `origin/master` before the current cleanup changes.
> The app builds with **zero native dependencies**, renders CT/MRI in neurological orientation, keeps
> MPR and 3D interaction off-main/coalesced, and now composites ordered affine-aligned Mask/Atlas
> layers in all three MPR planes. The bundled FreeSurfer LUT and third-party notice are packaged in the
> SwiftPM resource bundle; custom LUTs persist in Application Support. `swift test` is green
> after the cleanup (**121 total: 62 XCTest + 59 swift-testing**; old DICOM grouping tests removed).
> Release `Lentis.app`/DMG packaging and codesign verification
> pass. GUI regression on the packaged app covers layer selection/deselection, Inspector close/reopen,
> and inactive/active titlebar states; only one centered `Lentis` remains and the native window title
> stays empty.
> **UI unify + default MPR (2026-06-21) — DONE, GUI-verified, committed on `lentis-nifti-conversion`.** Collapsed
> the 8 floating per-panel/over-image toolbars into **one docked top `ViewerControlBar`** + **one docked
> bottom `ViewerStatusBar`** (nothing floats over the image now); the bottom-left readout is shown
> ONCE for the active panel (was repeated ×4 across the quad, plus text+histogram dup). Opening a file
> now lands directly in the **MPR quad** (`applyNiftiDataset` → `setupMPRLayout(seriesIndex: idx)`; the
> new optional param pins the just-loaded series). Removed `LayoutToolbar.swift`, `VolumeToolbar.swift`
> and the `PanelAdjustmentToolbar`/`PanelStatusCluster`/`CursorInfoOverlay` structs; kept + reused
> `ModalityBadge` + `PanelHistogramView`. **Key reactivity lesson:** the bars observe `model`, but a
> panel's image/W-L are `@Published` on `PanelState` and fire the *panel's* `objectWillChange`, not the
> model's — so panel-dependent content lives in child views that take `@ObservedObject var panel`
> (`ControlBarActivePanelGroups`, `StatusBarPanelInfo`, `StatusBarCursorInfo`); a guard in the
> model-observing parent stayed stuck at the initial nil image (caught in GUI: "No volume loaded" + a
> bar missing its plane group — fixed). **GUI-verified (real app, synthetic CT):** default MPR quad,
> no floating menus, status bar shows `synthetic_ct.nii.gz Axial 25/48 WL 40 WW 80 HU` once; clicking
> the Sagittal panel updated the bar's plane group → **Sagittal** + status → `Sagittal 33/64`; the
> `CT⇄`→`MRI` badge swapped the window control Preset→Auto; crosshair + orientation intact. `swift test`
> **109** green. Preserved: slab `Slider` no-`step:`, fixed-size modality buttons (no AppKit segmented
> `Picker`), and all orientation/crosshair/async-render code. **macOS menu bar kept** as the
> shortcut/command entry. (Cursor RAS/HU/px readout not GUI-verifiable — needs a real NSTrackingArea
> event, as before.)
> **W/L-drag perf (2026-06-21) — DONE** (commits `de07903` renderSlice Float+parallel, `9399a6a` async
> W/L, `8804548` regression test, `8b9919b` masked composite, `a67be70` `--perf-stress` harness). The
> W/L re-render no longer blocks the main thread (MPR `renderSlice` was on main; **MIP ran a
> `waitUntilCompleted` GPU block on main**). `renderSlice`'s W/L loop is Float+reciprocal+parallel
> (**3.14 → 0.46 ms** on a 1 MP slice, gray delta 0; it was ~80% of render cost — the NSImage-alloc
> premise in the old doc was wrong), and `adjustWindowLevelForPanel` keeps W/L *state* sync but pushes
> the render off-main via `loadMPRSlice`/`loadMIPForPanel`. **Measured (`--perf-stress`, MPRAGE quad):
> main-thread `wl_drag` 0.10 ms, `crosshair_set` 0.15 ms, `scroll_main` 0.30 ms — all sub-ms, renders
> off-main.** GPU slice W/L **evaluated and deliberately NOT done** — CPU is fast enough that a
> per-slice-readback GPU path only breaks even; the real win (live MTKView, no readback) awaits a
> concrete driver (see *Known issues* #3). Orientation/crosshair code untouched; corner tests green.
> **W/L toolbar relayout follow-up (2026-06-21) — DONE** (`f952678`, `4250965`). Corrected
> `--perf-stress --wl-hold` to use the production `persist:false` drag path, pinned quad cells to exact
> geometry, and replaced the pathological AppKit-backed segmented modality picker with fixed-size
> CT/MRI buttons. The mandatory 6 s `sample` on the real 344×1024×1024 MPRAGE dropped layout-pattern
> stacks **48,886 → 1,105** and top `sizeThatFits` weight **1,215 → 156**. GUI-verified CT↔MRI,
> Auto↔Preset, quad geometry, and a sagittal W/L drag; `swift test` is **109 green**.
> **Re-validated 2026-06-21 at HEAD `c514e9a` (working tree clean):** `swift build` clean, `swift test`
> 106 green, and the Phase-7 seam symbols all present in committed code — `installDemoSphereMask`,
> `LabelVolume` on `VolumeData.labelMask` (+ `ensureLabelMask`), `MPREngine.maskSlice` (3-plane
> alignment locked by `SegmentationSeamTests`), `renderSlice(mask:maskColor:maskAlpha:)` wired through
> `loadMPRSlice`, model `showMaskOverlay`/`maskOverlayColor`/`maskOverlayAlpha`, and the Eraser
> mask-edit seam comment in `MultiPanelContainer`.
> **Phase 7 — DONE** (UI: top-leading `ModalityBadge` CT=amber/MRI=teal + 4D timepoint cluster stacked
> under `VolumeToolbar`, replacing the bottom-center 4D pill that overlapped the W/L toolbar;
> orientation-label dark halo; 2px panel gaps; NIfTI wording. Seams: same-grid `LabelVolume` on
> `VolumeData.labelMask`, `MPREngine.maskSlice` mirroring `planeGeometry`, `renderSlice(mask:)` RGBA
> composite wired through `loadMPRSlice`, Eraser/ROI kept as the mask-edit surface, `originalAffine`
> preserved for write-back). **GUI-verified** on real-ish synthetic CT/MRI: badge color + no-overlap in
> single & quad; the `--benchmark` demo sphere composites translucent-red and registers in axial/
> sagittal/coronal (MIP excluded by design). Orientation untouched. See the Phase-7 roadmap entry below.
> **▶ Phase 9 — DONE (2026-06-23, branch `feature/calcification-segmentation` / worktree):
> intracranial-calcification segmentation.** Real multi-region segmentation, NIfTI mask/atlas export,
> brain-mask + FreeSurfer SynthSeg, and a tabbed Segment inspector. See the Phase-9 roadmap entry below.
> The Metal mask-texture overlay (3D panel) remains the one deferred piece (3D excluded, as for Phase 7).
> Phase 5 outcome (verified in GUI on real CT + real T1): CT defaults to the **Brain** HU preset
> (WL 40/WW 80) with a preset menu (Brain/Subdural/Stroke/Bone/Soft-tissue, applied to all linked
> panels); MRI auto-detects and uses a percentile auto-window (WL 899/WW 1798 on the T1, via an
> "Auto" button). The one-click **MPR quad no longer renders dark** — every panel is W/L-seeded by
> modality. **Post-Phase-5 perf fix:** both **MPR and MIP** render are now **async + coalesced** off the
> main thread (`loadMPRSlice` / `loadMIPForPanel` → `panel.loadingQueue`) — fixed laggy scrolling on the
> 721 MB / megapixel-slice MPRAGE, including the **quad-MPR + sync-scroll** case where the MIP panel's
> synchronous `waitUntilCompleted` blocked the main thread every tick. Measured per-tick main-thread
> cost **~15–25 ms → 0.3 ms** (`scroll_main`, `--benchmark`). **Deferred:** GPU slice W/L (wouldn't help
> scroll — extraction/alloc dominate, not the W/L math). Slice rendering is still CPU. Phase-4 orientation intact.
> **Latest perf fix (commit `cb12693`):** the *residual* MPRAGE fast-scroll lag (old Known-issue #1) was
> diagnosed to the **sagittal slice extraction** — a 1-megapixel cache-hostile `voxelAt` gather (~15 ms,
> ~57 slices/s). `MPREngine.sagittalSlice` now uses a byte-identical parallel raw-pointer walk: **57 → 213
> slices/s** (extract 15.25 → 1.54 ms). Orientation unchanged (corner tests + harness equality). 52 tests green.
> **Phase 6 (3D crosshair linkage) — DONE** (commits Phase 6 1/5–5/5): click/drag in any MPR panel
> (default Select tool) sets a shared `crosshairWorld` (RAS); every other panel relocates so its slice
> passes through it and draws a green crosshair through the in-plane projection. Geometry lives with the
> ONE orientation source: `PlaneGeometry.world(col:row:)`/`pixel(of:)` (exact-inverse pixel↔world) +
> `MPREngine.orthogonalSliceIndex(for:containing:)` (world→slice index; axial→k, sagittal→i, coronal→j),
> both unit-tested. The crosshair **replaces** the old dashed plane-intersection lines. `setupMPRLayout`
> turns the crosshair on for the one-click quad. MIP panel: slab tracks the crosshair's z but no lines
> drawn (its slab metadata is unflipped — deferred). **GUI-verified on real T1** (`--benchmark`): clicking
> patient-LEFT in axial relocated Sagittal 89→42/176 (left hemisphere) with the coronal crosshair on the
> left; dragging toward patient-R + anterior moved Sagittal→132/176 and Coronal→160/240 — laterality and
> A-P correct, crosshair tracks the cursor, MIP excluded. **This subsumes old Known-issue #4** (the z-only
> `syncScrollFromPanel`): orthogonal planes correctly stay put unless the in-plane click moved their index.

- [x] **Phase 1 — Rebrand to Lentis.** SPM/target/dir/app-struct renamed; menus/About/Help show
  Lentis; `package_app.sh` + bundle id updated; `UpdateChecker` removed (phoned home to upstream).
  Early compatibility names were intentionally kept at the time, then cleaned up in the
  2026-06-22 repository-hygiene pass. Builds & runs as `Lentis.app`.
- [x] **Phase 2 — NIFTI loader (CT+MRI) + open + first render.** Reader/converter/orchestration
  added (above). Verified on **real CT + real T1 MRI** (correct modality, affine, HU/intensity) and
  via GUI (CT loads/renders axial/scrolls; 4D MRI loads with auto-window + timepoint selector).
  13 NIFTI unit tests + full suite green.
- [x] **Phase 3 — Remove DICOM/DCMTK/OpenJPEG.** Done in 6 commits on `lentis-nifti-conversion`.
  Deleted: DICOM-only UI (CineToolbar, TagView, series thumbnails, the legacy single-view
  ContentView subtree ~648 lines), `SimpleDICOM.swift`, `MultiFrameDecoder.swift`,
  `Sources/DCMTKWrapper/`, `libs/`, DCMTK-dependent tests. Gutted DICOM ingestion from the model
  (45 methods, ~2500 lines) and made all panel navigation volumetric-only; removed `VolumeBuilder`
  from `MPREngine`. Unlinked DCMTK from `Package.swift`; dropped `dicom.dic` from
  `package_app.sh`. Renamed `DICOMModel`→`ViewerModel`, `DicomSeries`→`ImageSeries`,
  `DicomImageContext`→`ImageContext`, test target→`LentisTests`; the file-open dialog is now
  NIfTI-only (`openFile`, replaces `openFolder`). **Verified:** clean `swift build`
  (no static-lib warnings), 31 tests green, `otool -L` shows no DCMTK/OpenJPEG linkage, GUI renders
  synthetic CT (axial + scroll) and real T1 MRI (auto-window). The remaining cosmetic debt was
  later resolved in the 2026-06-22 repository-hygiene cleanup.
- [x] **Phase 4 — Neurological orientation + tri-view.** Done in 6 commits on `lentis-nifti-conversion`.
  Added `Orientation.swift` (RAS labels + closest-canonical reorientation); `NiftiDataset.makeVolume`
  reorients every volume to canonical RAS (i→R, j→A, k→S) — lossless, original affine + reorientation
  retained for write-back. Centralized the per-plane neurological flips + display dirs in
  `MPREngine.planeGeometry` (replacing the `flipZ` heuristic); `loadMPRSlice` /
  `updateMPRSpatialMetadata` now take cross-ref/label metadata from that one source. Fixed the
  orientation labels to **RAS** (`anatomicalDirection`, was LPS). Wired `setupMPRLayout` panel 0 →
  `.mprAxial`; fixed `isSeriesVolumetric` (cached-volume check) so the MPR toolbar enables for NIFTI.
  Reconciliation decision: world space stays **RAS** (NIFTI-native); only the one LPS label site was
  fixed — no global LPS conversion. **Verified:** 42 tests green (added Orientation + canonical-volume
  + neurological-slice tests); GUI on `synthetic_orient` shows correct octant intensities + L/R/A/P/S/I
  in all three planes; real CT (was radiological) + real T1 (was "coronal-looking") now render as
  proper neurological axial. The cosmetic debt noted at the time was later resolved in the
  2026-06-22 repository-hygiene cleanup.
- [x] **Phase 5 — Modality-aware W/L (CPU; GPU slice move deferred).** Done in 2 commits on
  `lentis-nifti-conversion`. Added `WindowLevel.swift` (`WindowPreset` + CT HU preset table: Brain
  `(0,80)` default, Subdural, Stroke, Bone, Soft-tissue, all HU). `modalityDefaultWindow` seeds
  CT → Brain preset (HU→stored via the volume's rescale) and MRI → `suggestedWindow` percentile;
  `seededWindow` prefers a saved manual window; `assignSeriesToPanel` / `applyNiftiDataset` /
  `setModalityOverride` seed/reseed through them — **fixing the dark one-click quad MPR** (Sagittal/
  Coronal/MIP no longer fall back to the hardcoded `2000/500`). UI: per-panel CT/MRI toggle + a CT
  preset menu or an MRI "Auto" button, chosen by `effectiveModality`; presets apply to all linked
  panels; the `A` shortcut + Auto button route through `autoWindow(for:)`. **Verified:** 52 tests
  green (10 new in `WindowLevelTests`); GUI on real CT (Brain default WL40/WW80, Bone preset
  re-windows all four panels, MPR quad bright) and real T1 (auto-detected MRI, percentile
  WL899/WW1798, MPR quad bright), Phase-4 orientation intact.
  **Deferred:** moving 2D-slice W/L onto the GPU (the brief's "windowing = GPU uniform" rule) — no
  visible speedup over the sub-ms CPU loop and it risks the canonical-RAS orientation; revisit when a
  live MTKView / mask overlay needs it (clean seam noted in *Data & rendering pipeline* §1).
- [x] **Perf — async MPR/MIP rendering (post-Phase-5).** 2 commits (`d98fc58`, `f78b51f`). `loadMPRSlice`
  *and* `loadMIPForPanel` now render off the main thread on `panel.loadingQueue`, coalesced (cancel +
  drop-stale); `MetalVolumeRenderer.renderProjection` is `renderLock`-serialized (now called from
  background queues). Fixed laggy slice scrolling on the 721 MB MPRAGE — both single-panel and the
  quad-MPR + sync-scroll layout (where the MIP panel's synchronous `waitUntilCompleted` was the real
  blocker). **Measured:** per-tick main-thread cost ~15–25 ms → **0.3 ms** (`scroll_main`, `--benchmark`).
  Residual fast-scroll lag (then undiagnosed) was the *sagittal extraction* — see next entry.
- [x] **Perf — sagittal slice extraction (post-Phase-5).** 1 commit (`cb12693`; docs `8db7a16`,
  `22161aa`). Diagnosed the residual MPRAGE fast-scroll lag with a deterministic standalone harness
  over the real `MPREngine` code (differential vs CT/T1): the 344×1024×1024 MPRAGE's **sagittal** plane
  is a 1-megapixel cache-hostile `voxelAt` gather (~15 ms → ~57 slices/s); axial (1.3 ms) / coronal
  (2.3 ms) were already fine. Rewrote `MPREngine.sagittalSlice` as a bounds-check-free raw-pointer walk
  parallelised across z-planes (disjoint writes → race-free), **byte-for-byte identical** output
  (orientation unchanged; `testSagittalSliceNeurologicalOrientation` corner checks + harness `==`).
  **Measured:** sagittal extract 15.25 → **1.54 ms** (10×), end-to-end 17.9 → **4.7 ms = 57 → 213
  slices/s**. **GUI-verified (real app, `--benchmark`):** sagittal `mpr_render` ~5–6.7 ms warm (was
  ~18 ms), `scroll_main` 0.1–0.5 ms; single-panel + one-click quad render correct (S/I/A/P, no tearing)
  and bright. 52 tests green. **Deferred (not needed for scroll):** the `renderSlice` W/L loop
  (Float+reciprocal measured 3.0 → 0.6 ms parallel / 1.9 ms serial, ±1 gray-level) — fold into the
  W/L-drag fix (*Known issues* #2), as both share `renderSlice`.
- [x] **Perf — W/L-drag off-main + renderSlice loop (post-crosshair).** 5 commits (`de07903` renderSlice
  Float+parallel, `9399a6a` async W/L + `wl_drag` probe, `8804548` regression test, `8b9919b` masked
  composite, `a67be70` `--perf-stress`). Diagnosed with the standalone harness: `renderSlice`'s scalar
  `Double` W/L loop was **~80% of per-slice render cost** (CGContext alloc 0.008 ms + makeImage/NSImage
  0.018 ms negligible — **the old "NSImage alloc dominates" premise was wrong**). Rewrote the loop as
  Float + precomputed-reciprocal, parallelised across 8 bands (≥512² via `parallelToneMapThreshold`):
  **3.14 → 0.46 ms** end-to-end on a 1 MP slice, **max gray-level delta 0** (Int16 exact in Float). Then
  `adjustWindowLevelForPanel` keeps W/L *state* synchronous (toolbar binds it) but re-drives the panel's
  async+coalesced `loadMPRSlice`/`loadMIPForPanel` — moving both the MPR render **and the MIP
  `renderProjection waitUntilCompleted` GPU block** off the main thread. `renderSliceMasked` got the
  same Float+parallel composite (the masked path is the Phase-8 segmentation hot path; its residual cost
  is `maskSlice`'s serial sagittal gather ~13 ms, flagged for Phase 8). **Verified (deterministic, no
  GUI — access was unavailable; `--perf-stress` self-driving harness on the MPRAGE quad):** main-thread
  `wl_drag` **0.10 ms** (MPR + MIP, was ~3 ms MPR / ~15–200 ms MIP synchronous), `crosshair_set`
  **0.15 ms**, `scroll_main` **0.30 ms** — all sub-ms, renders off-main. `WindowLevelAsyncRenderTests`
  locks the async behavior (verified red on `de07903`). **107 tests** (50 XCTest + 57 swift-testing).
  GPU slice W/L **evaluated, deliberately deferred** — CPU is now fast enough that a per-slice-readback
  GPU path only breaks even; the real win (live MTKView, W/L as a uniform, no readback) awaits a concrete
  driver (*Known issues* #3). Orientation/crosshair code untouched. **Not GUI-verified** (computer-use
  can't drive a high-rate drag + the system access dialog was unresponsive) — correctness is preserved by
  construction (no orientation/crosshair code touched; `renderSlice` output is gray-delta-0) + the
  regression test; a by-hand GUI pass (W/L visibly changes, patient-LEFT → left-hemisphere sagittal) is
  the one outstanding belt-and-suspenders check.
- [x] **Perf — W/L toolbar relayout follow-up.** 2 commits (`f952678` honest stress persistence,
  `4250965` layout/control fix). The synchronous `wl_drag` probe could not see the lag because SwiftUI
  laid out after `adjustWindowLevelForPanel` returned. `--wl-hold` + a 6 s main-thread `sample` exposed
  flexible-grid sibling propagation and, most importantly, `SystemSegmentedControl._overrideSizeThatFits`
  recursively measuring its embedded SwiftUI graph. Exact grid cells stop cross-panel ideal-size
  propagation; fixed-size CT/MRI buttons preserve the modality UI without that native intrinsic-size
  query. Real MPRAGE sample: layout-pattern stacks **48,886 → 1,105**, top `sizeThatFits` **1,215 →
  156**, `explicitAlignment` **623 → 139**. GUI: CT/MRI + Auto/Preset + sagittal W/L verified; 109 tests
  green. No orientation, crosshair, or async-render code changed.
- [x] **Phase 6 — Crosshair drag linkage.** Done in 5 commits on `lentis-nifti-conversion`. Click/drag
  in any MPR panel (default **Select** tool) sets `ViewerModel.crosshairWorld` (RAS mm); every other panel
  relocates so its slice/MIP-slab passes through the point (`setCrosshair` → `MPREngine.orthogonalSliceIndex`
  → the existing async+coalesced `loadMPRSlice`/`loadMIPForPanel`), and a green crosshair is drawn through
  the in-plane projection (`CrossReferenceOverlay`, rewritten — **replaces** the dashed plane-intersection
  lines it subsumes). Pure geometry on the ONE orientation source: `PlaneGeometry.world(col:row:)` /
  `pixel(of:)` (exact-inverse pixel↔world) + `MPREngine.orthogonalSliceIndex(for:containing:)`, both
  unit-tested (4 new in `MPREngineTests`). Click→world maps display-space pixel → raw pixel →
  `PlaneGeometry.world`; `PanelState.displayedPlaneGeometry` reconstructs the plane from stored metadata.
  `setupMPRLayout` enables the crosshair for the one-click quad; `applyNiftiDataset` clears it on load.
  MIP panel: slab tracks the crosshair's z, but no lines drawn (its slab geometry is unflipped — deferred).
  **Verified:** XCTest 43 (incl. +4) + swift-testing 52 green; **GUI on real T1** — patient-LEFT axial click
  relocated Sagittal 89→42/176 (left hemisphere) + coronal crosshair on the left; drag toward patient-R +
  anterior moved Sagittal→132/176, Coronal→160/240; laterality + A-P correct, MIP excluded, orientation
  intact. Subsumes old *Known issues* #4 (the z-only `syncScrollFromPanel`). Cosmetic debt still deferred.
- [x] **Crosshair drag-lag fix (post-Phase-6).** 2 commits (`04e7290` Slider, `fbe5b1d` decouple).
  Diagnosed a real continuous-drag stutter (relocation correctness was always fine). **The documented
  prime hypothesis was WRONG** — the redundant `applyFilters`/`updateNSView` re-application measured
  **0.0 ms** (per-sub-call `CLOCK_THREAD_CPUTIME`). A CPU **`sample`** of the main thread during a
  deterministic in-app `--xhair-stress` run found the cost in SwiftUI **layout**: the MIP "Slab"
  `Slider` used `step: 1` over `1...~1024` (volume depth) → macOS renders **~1024 tick-mark labels**
  (`SliderMarkLabels…place`) → **~2 s layout** per `model.objectWillChange`, and a drag fired that per
  mouse event (`crosshairWorld` was `@Published` on the model; scroll was fine because it mutates
  *panel* state, not the model). Fix: drop the slider `step:` (no marks; setter snaps to Int) **+**
  decouple `crosshairWorld` into its own `CrosshairState` `ObservableObject` observed only by
  `CrossReferenceOverlay` (+ remove the obsolete `objectWillChange.send()` in the MPR/MIP completions).
  **Measured per-event main-thread CPU ~1980 → ~1.7 ms** (~1000×). **Verified (real T1, GUI):**
  patient-LEFT axial click → Sagittal 47/176 (left hemisphere); drag → Sagittal 135/176, Coronal
  160/240; laterality + A-P + orientation intact. **99 tests** (43 XCTest + 56 swift-testing; +4 in
  `CrosshairDecouplingTests.swift`). Throttling (lead 2) skipped — unneeded at 1.7 ms/event. Note:
  **computer-use can't reproduce the lag** (coalesces a synthetic drag to ~2 events); measured by probe.
- [x] **Phase 7 — UI polish + segmentation seams.** Done in 5 commits on `lentis-nifti-conversion`.
  **UI polish:** (1) Fixed the 4D-selector / W/L-toolbar overlap — both were bottom-center overlays;
  introduced a top-leading `PanelStatusCluster` (a read-only color-coded `ModalityBadge` — CT=amber,
  MRI=teal — plus, for 4D, a compact timepoint stepper) stacked under `VolumeToolbar`, and removed the
  bottom-center 4D pill so the bottom holds only the W/L toolbar. (2) `OrientationLabelsOverlay` letters
  got a dark halo for legibility on bright slices; inter-panel grid gap 1→2px; stale "DICOM folder"
  user strings (empty-panel + Help) corrected to NIfTI. **Segmentation seams (no seg behavior):**
  `LabelVolume.swift` (same-grid UInt8 mask) on `VolumeData.labelMask` + `ensureLabelMask()` — shares
  the volume's voxel grid so write-back reuses `reorientation` + `originalAffine`; `MPREngine.maskSlice`
  extracts it in the SAME (col,row) layout as the gray slice (mirrors `planeGeometry`, locked by
  `SegmentationSeamTests` against the gray extractor in all 3 planes); `renderSlice(mask:maskColor:
  maskAlpha:)` RGBA-composites a translucent color over labeled pixels (taken only when a mask exists,
  so the grayscale fast path is untouched), wired through `loadMPRSlice` with model config
  `showMaskOverlay`/`maskOverlayColor`/`maskOverlayAlpha`. Eraser/ROI retained as the future mask-edit
  surface (seam comment at the `.eraser` handler). The **Metal** mask-overlay path (2nd R8 texture in
  the W/L shader) is documented as the live-MTKView entry; the CPU composite is the current seam. A
  `--benchmark`-only `installDemoSphereMask` makes the overlay visually verifiable; inert otherwise.
  **Verified:** 106 tests green (50 XCTest incl. +7 seam, 56 swift-testing); GUI on synthetic CT
  (amber badge, demo red sphere composited in axial/sagittal/coronal of the one-click quad, MIP
  excluded) + synthetic 4D MRI (teal badge, "Vol 1/5" stepper in the top cluster, no bottom overlap);
  Phase-4 orientation + Phase-6 crosshair intact. **Deferred:** real segmentation, mask write-back/
  persistence, and the Metal mask texture. The cosmetic debt noted at the time was later resolved.
- [x] **UI clarity pass (post-Phase-7).** Audited the UI for confusing/misleading elements and fixed
  them in 3 groups (no new tests; **109 green**; `swift build` clean; GUI-verified on real CT incl. a
  live CT↔MRI badge toggle + MPR quad). **(1) Misleading/dead UI:** HelpView no longer calls Lentis a
  "DICOM viewer" and drops the phantom `T`=DICOM-tags shortcut; empty-state + sidebar use NIfTI wording
  (file name + `CT · WxHxD` + brain icon, not "Series 1 / 0 Images"); per-panel info shows the file
  name (`ViewerModel.loadedFileName`) instead of "Series 1/1"; the inert `.slice2D` "Slice" mode button
  is hidden on volumetric panels; the **`A` key now routes through `autoWindow(for:)` everywhere** —
  `performKeyEquivalent` + the menu were calling the generic `autoWindowLevelForPanel`, disagreeing with
  the Auto button for NIfTI. **(2) Naming/readouts:** `ActiveTool.displayName` ("Window/Level"); the MIP
  menu label tracks `PanelState.mipProjection`; `ViewerLayout.description` drives descriptive layout
  tooltips; the group-select overlay is reworded to distinguish it from `L` Synchronized Scrolling; the
  W/L readout gains a `HU` unit for CT (dropped for MRI); the cursor readout gains `mm`/`px`; the MRI
  value label `Val`→`Intensity`. **(3) Discoverability/legends:** `ModalityBadge` is now the CT/MRI
  **toggle** (click swaps modality + reseeds W/L; the old bottom CT/MRI buttons removed — preset/Auto
  only) — kept as a plain `Button` (not a `Menu`, whose `.borderlessButton` style stripped the
  amber/teal capsule); an **MPR** button added to `LayoutToolbar`; a fullscreen button added to each
  `VolumeToolbar` (surfaces the double-click gesture); a histogram `.help`; a new Help **"Display Guide"**
  section (orientation letters, CT/MRI colors, histogram, readouts) + gesture rows (double-click
  fullscreen, right-drag W/L). `// OpenDicomViewer` headers fixed in the 4 touched views. Orientation,
  crosshair, and async-render code untouched. The remaining cosmetic debt noted at the time was later
  resolved in the 2026-06-22 repository-hygiene cleanup.
- [x] **UI unify — one docked toolbar + status bar, default MPR (post-clarity).** Committed on
  `lentis-nifti-conversion`. The image had **8 floating control/readout clusters**, most repeated per-panel in the
  quad (`VolumeToolbar`, `PanelStatusCluster`/`ModalityBadge`, `PanelAdjustmentToolbar`, the bottom-left
  Info text, the bottom-right slice text, `CursorInfoOverlay`, the top-right `LayoutToolbar`). Collapsed
  them into **one docked top `ViewerControlBar`** (`ViewerControlBar.swift`) + **one docked bottom
  `ViewerStatusBar`** (`ViewerStatusBar.swift`); the panel `ZStack` now holds only pixel-bound overlays.
  **Sidebar toggle polish (2026-06-22):** GUI-verified that relying on the system `NavigationSplitView`
  titlebar toggle looked wrong in Lentis because it created a second toolbar row above the app's docked
  viewer controls. The app now keeps one stable `sidebar.left` button at the far-left of
  `ViewerControlBar`, suppresses the system titlebar toggle, and leaves `SidebarView`'s header to content
  actions only (`Series` + `Open`), so collapsing/restoring the sidebar does not move the control.
  Per-panel controls/readouts act on / show `model.activePanel` (shown once, killing the ×4 quad
  repetition + the W/L text-vs-histogram dup the user flagged). Opening a file lands in the **MPR quad**
  (`applyNiftiDataset` → `setupMPRLayout(seriesIndex: idx)`; added the optional `seriesIndex` param so a
  2nd open can't pick a stale series, since `registerStandaloneVolume` *appends* per load) + broadcasts
  `rescaleSlope/Intercept/valueUnitLabel` to all 4 panels. Deleted `LayoutToolbar.swift` +
  `VolumeToolbar.swift` and the 3 now-unused structs; kept/reused `ModalityBadge` + `PanelHistogramView`;
  removed dead `initialWindow(for:)`. Left `ToolPalette` (left tool column) and the macOS menu bar as-is
  (per user: menu bar = shortcut entry). **Reactivity gotcha (caught only in GUI):** the bars
  `@ObservedObject` the *model*, but `PanelState` is its own `ObservableObject` — a panel's async image /
  W-L fires the *panel's* `objectWillChange`, not the model's — so gating panel content with
  `panel.image != nil` in the model-observing parent left it stuck on the initial nil ("No volume loaded"
  + missing plane group). Fix: panel-dependent content lives in child views that take
  `@ObservedObject var panel` (`ControlBarActivePanelGroups`, `StatusBarPanelInfo`, `StatusBarCursorInfo`).
  **GUI-verified** (real app, synthetic CT): default MPR quad, nothing floating, status `…Axial 25/48 WL
  40 WW 80 HU` once; Sagittal-panel click → bar **Sagittal** + status `Sagittal 33/64`; `CT⇄`→`MRI`
  swapped Preset→Auto; crosshair/orientation intact. `swift build` clean, **109** tests green. Preserved
  the slab `Slider` no-`step:` + fixed-size modality buttons (both perf-critical) and all
  orientation/crosshair/async-render code. **Deferred:** cursor RAS/HU/px not GUI-verifiable (real
  NSTrackingArea event needed); same older cosmetic debt.
- [x] **Phase 8 — replace the MIP view with interactive 3D brain rendering.**
  Removed `.mip`, `ProjectionMode`, slab state/UI, `loadMIPForPanel`, and the unused CPU
  MIP/MinIP/Average projection helpers/tests. The fourth quad panel is now `.volume3D` and renders a
  canonical-RAS `.r16Sint` texture through a physical-spacing-aware Metal compute ray marcher with a
  window-selective transfer function (CT Brain W/L makes high-HU skull transparent), front-to-back
  compositing, early ray termination, and gradient lighting. Select-drag rotates yaw/pitch at a
  coalesced 60 Hz / 192² preview; mouse-up settles at 512². `volumeRenderRevision` drops stale GPU
  results; all GPU waits/readback stay on `panel.loadingQueue`. The 3D panel has Density + camera-reset
  controls, follows modality W/L and 4D volume swaps, and deliberately has no slice scroller,
  crosshair relocation, cursor voxel readout, orientation letters, or 2D annotations. Added pure camera
  tests plus a real Metal test that compiles the inline MSL, uploads a 16³ volume, dispatches the shader,
  and asserts non-black output. Added `scripts/build_and_run.sh` + Codex Run action; launch with
  `./scripts/build_and_run.sh --verify --benchmark /abs/path.nii.gz`.
  **Rotation/Density follow-up (2026-06-21):** fixed horizontal drag stalls by deriving deltas from
  consecutive absolute `locationInWindow` values; coalesced/synthetic NSEvents can report zero
  `deltaX/Y`. The same automated drag now moves yaw `-25° → 51°` and reverses to `-25°` (previously
  stayed at `-25°`). The first 320²/30 Hz preview measured p95 **32.82 ms** on the real
  344×1024×1024 MPRAGE and looked stepped; 192² measured p95 **10.29 ms**, passing the 60 Hz 16.67 ms
  budget (`scripts/VolumeRenderBenchmark.swift`). Density UI now hides the Slider's duplicated label,
  holds a fixed 104pt track, shows a live `1.0×` value, and uses a clear reset icon; GUI verified as a
  single line and via accessibility increment `1.0× → 1.2×`.
  **3D camera interaction follow-up (2026-06-21):** fixed the remaining camera semantics after GUI use.
  The camera matrix now composes `pitchRotation * yawRotation`, so horizontal yaw still turns the head
  after pitching to the anterior/front view instead of degenerating into screen-space roll. Pitch is no
  longer clamped at `±89°`; it is normalized like yaw, so dragging can continue through the front view
  for a natural "look down"/orbit-through motion. The drag delta mapping is inverted (`previous-current`)
  so the model follows the pointer direction for both horizontal and vertical drags. Bottom status stays
  `yaw/pitch` only: there is no explicit roll state, and the prior roll-like behavior was a matrix-order
  bug rather than an intended third camera axis. Regression coverage lives in
  `MetalVolumeRendererTests` (front-view yaw + pitch-through-front) and `PanelStateTests` (drag direction).
- [x] **External Mask/Atlas layers + native trailing Inspector (2026-06-22).** Three logical commits:
  `e9d3d53` (data/LUT/import), `74d7c2e` (ordered MPR rendering), and `ef401d1` (Inspector/resources/
  packaging). A single add/drop entry accepts 3D NIfTI overlays, detects a single nonzero integer value
  as Mask and multiple values as Atlas, permits manual type changes, and aligns each source affine to
  the current canonical-RAS base grid with categorical nearest-neighbour sampling. Non-overlapping and
  multi-timepoint overlays are rejected with per-file errors. `LayerStore` is session-only, survives a
  4D base timepoint change, clears when a different base file opens, publishes a render revision without
  invalidating the full viewer model, and supports visibility, top-first ordering, remove/Undo, opacity,
  Mask color, Atlas LUT, and per-label visibility. MPR composition is bottom-to-top, label 0 is
  transparent, missing LUT labels get deterministic hashed colors/`Label <ID>`, and the no-layer
  grayscale fast path is unchanged. The fourth 3D Metal panel intentionally remains unchanged.
  `LayerInspectorView` uses native `List`/`Form`/`Menu`/`Slider`/`ColorPicker`, searchable actual-label
  rows with voxel counts, show/hide/invert/solo actions, LUT import/manage/delete, drag reorder, Delete,
  VoiceOver labels, `InspectorCommands`, and automatic presentation after the first successful import.
  The original FreeSurfer LUT is bundled at `Sources/Lentis/Resources/FreeSurferColorLUT.txt`; custom
  FreeSurfer-format LUTs are content-deduplicated under Application Support. `THIRD_PARTY_NOTICES.md`
  is bundled and linked from Help; no local FreeSurfer `license.txt` is copied. Debug/release staging
  copies the SwiftPM resource bundle. Tests cover parsing/transparency/errors, persistence/dedup,
  classification/storage, affine resampling/rejection, 3-plane alignment, ordering/alpha/visibility,
  revision isolation, and the bundled known entry. GUI-verified with real T1 + brainmask/synthseg and
  the deterministic synthetic benchmark layer. Release app/DMG build and ad-hoc codesign verification
  pass.
- [x] **Centered title survives Inspector changes without a duplicate/flash (2026-06-22).** Commits
  `19b4168` and `b853a49`. The original window intentionally installed a custom centered `Lentis` but
  also left SwiftUI's non-empty native scene title available; activating the layer list or rebuilding
  the trailing Inspector could expose the native leading title, first as a persistent duplicate and
  then as a one-frame flash. `App.swift` now declares `WindowGroup("")` so the native title is empty at
  the SwiftUI source of truth. `WindowAccessor.Coordinator` keeps it empty/hidden across AppKit updates,
  retains `Lentis` separately for accessibility/minimized-window naming, and ensures exactly one custom
  centered label remains attached to the current titlebar. `WindowAccessorTests` simulates SwiftUI
  restoring a visible native title and locks synchronous suppression. GUI-verified on the packaged app
  through inactive→active, layer select→blank deselect, and Inspector close→reopen transitions; Cua
  window enumeration reported an empty native title throughout and screenshots showed only the centered
  title. Full suite: **130 tests green (62 XCTest + 68 swift-testing)**.
- [x] **Phase 9 — intracranial-calcification segmentation (2026-06-23, branch
  `feature/calcification-segmentation` / worktree).** 7 commits (engine → per-label render →
  multi-region model → ROI box+brush → NIfTI writer → brain mask/SynthSeg → inspector). The user
  draws a 3D ROI box around a calcification and segments it by **Method A (threshold in ROI)** or
  **Method B (grow from seed)** — both are one configurable engine: hysteresis dual-threshold + 3D
  connected-component + brain-mask AND + min-size + Otsu (`CalcificationSegmenter`). Multiple
  **regions** each take a distinct label in one editable `VolumeData.labelMask` (255 = transient
  preview), render per-label-colored via the atlas path (`renderSlice(maskAtlasColors:)`; sagittal
  `maskSlice` parallelised), and export as a **single-value mask** or **multi-value atlas** NIfTI
  (+ FreeSurfer LUT) **written back to the original input grid** (`reorientation`+`originalAffine`,
  gzip via Compression). A **brain mask** loads from NIfTI (reusing `OverlayLayerLoader`) or is
  generated by **FreeSurfer SynthSeg** (`SynthSegRunner`, off-main `--parc --robust`); a parcellation
  also auto-names regions by anatomy. UX: `ActiveTool.roiBox` (B, drag rect + slab) + `.calcBrush`
  (K, touch-up), `SegmentationBoxOverlay` (box cross-section on all MPR planes), and a tabbed
  **Layers · Segment** trailing inspector (`SegmentInspectorView`: brain mask, active-region
  threshold/Otsu/histogram, regions list, export). All mask writes are main-thread then bump
  `segmentationRevision` (drops stale in-flight renders). The 3D Metal panel is excluded (deferred,
  as in Phase 7). **Verified:** 92 XCTest + swift-testing green (engine, per-label render alignment,
  multi-region lifecycle, ROI-box mapping, NIfTI writer round-trip incl. write-back orientation +
  gzip, brain-constraint); a standalone E2E on a real `.nii.gz`; and exported `.nii`/`.nii.gz` read
  back correctly by **nibabel** (shape, dtype, labels/counts, zooms, sform, affine) — confirming
  FreeSurfer/fsleyes compatibility.
  - **Follow-up (2026-06-23) — resizable ROI box + SynthSeg crash hardening.**
    **(1) ROI box is now draggable-to-resize in 3D.** After drawing, the draft box shows 8 grab
    handles (4 corners + 4 edge mids) on every MPR plane it intersects (`SegmentationBoxOverlay`).
    Dragging a handle on **axial** resizes the in-plane i,j extent; dragging on **coronal/sagittal**
    resizes the through-plane depth (coronal edits i,k; sagittal edits j,k) — the slab axis for the
    dragged plane is left untouched, so the box is fully reshapeable in 3D from any view. The pure
    geometry (`VoxelBox.handles(plane:sliceIndex:)` + `resize(plane:gripA:gripB:toVoxel:)` +
    `inPlaneAxes`/`slabAxis`) is in `CalcificationSegmenter` and locked by
    `SegmentationBoxResizeTests` (8 tests). Hit-testing (`roiHandleGrip` in `MultiPanelContainer`)
    and the overlay both project handles through ONE shared forward transform,
    `PanelState.viewPoint(forRawPixel:viewSize:)` (the inverse of `screenToPixel`), so grab targets
    can't drift from the drawn dots under zoom/pan/rotate/flip. Empty-space drag still draws a new box
    (replace); handle drag resizes. On draw, the other MPR panels relocate to the box center
    (`setCrosshair`) so handles are immediately visible on coronal/sagittal. Resize re-runs the
    bounded preview but does **not** re-seed Otsu (preserves the user's threshold). **The Slab
    slider was removed** — a freshly drawn box gets a fixed initial through-plane thickness
    (`ViewerModel.calcSlabDepth = 5`, now a constant) and depth is refined via the handles;
    `setActiveRegionSlabDepth` + `CalcificationRegion.slabAxis` were deleted as dead.
    **(2) SynthSeg "exited with status 6" → diagnosed + hardened.** Status 6 is **SIGABRT** (a
    TensorFlow/Apple-Silicon abort), NOT a clean exit — the `mri_synthseg` Python script only ever
    `sys.exit(1)`. Confirmed by reproduction: the CLI succeeds (exit 0) on both the original CT and
    the app's *exact* `NiftiWriter.writeVolume` output with `--parc --robust`, and even under the
    app's minimal env-derivation + a sparse launchd-style env — so the abort is specific to the GUI
    launch context (not reproducible headlessly). `SynthSegRunner` now: passes **`--ct`** (the
    documented correct CT mode, clips HU to [0,80]) since the segmentation volume is always a brain
    CT; pins **`--cpu --threads 1`**; provides a clean complete environment (guarantees writable
    `HOME`/`TMPDIR`, strips toxic inherited `PYTHONHOME`/`PYTHONPATH`/`VIRTUAL_ENV`/`CONDA_*` that
    hijack fspython, sets `TF_CPP_MIN_LOG_LEVEL`/`OMP_NUM_THREADS`); and **distinguishes signal-vs-exit**
    (`SynthSegError.aborted(signal:tail:)` names SIGABRT/SIGILL/etc.) while surfacing the captured
    stderr **tail** so the real abort message is shown instead of "status 6". The new arg combo
    (`--parc --robust --ct --cpu --threads 1`) was verified to still produce a valid parcellation on
    the real CT. The `cancelled` flag and output tail are lock-guarded (read from the termination
    queue). **Not GUI-verified** (the live drag can't be reliably driven by synthetic events, and
    ScreenCaptureKit was failing in the verify environment); correctness of the resize is held by the
    unit tests + the shared-transform construction, and the SynthSeg path by the CLI repro — the next
    real GUI run will now show the actual crash cause if it still aborts. **159 tests green.**
  - **GUI-verified end-to-end on the real CT
  (`sub-zdr_ses-20250312_ct.nii`, 512×512×221, real bilateral basal-ganglia calcifications):** open →
  quad renders → ROI Box tool → drag box → draft auto-created, Segment tab auto-opened, Otsu seeded
  (361 HU), **live red preview of 2916 voxels on all three MPR planes** → Add Region → "Calcification 1
  · 2916 vox" in the Regions list → Export Mask → the written `.nii.gz`, re-read by **nibabel**, has
  the **same shape + affine as the source CT** (overlays 1:1) with all labeled voxels high-HU
  (362–1754, median 606) — i.e. the calcifications, with a few skull-edge voxels the "no brain mask"
  warning correctly flagged. **Deferred:** Metal mask-texture overlay on the 3D panel; 4D-timepoint
  segmentation (CT is 3D).
  - **Follow-up (2026-06-24) — parameter tuning for the "the box IS calcification" workflow.** 1 commit.
    **(1) Grow reach is configurable + unlimited by default.** New per-region
    `SegmentationParameters.growMarginVoxels: Int?` — `nil` (the **default** for `.growFromSeed`) floods
    the **whole volume**, bounded by the brain mask when constrained else only by the `maxResultVoxels`
    safety cap; a finite value dilates the box by that many voxels. The Segment inspector gains an
    **"Unlimited grow" toggle** + a **Reach** slider (shown when finite; disabled when the brain mask
    bounds the flood). `defaultGrowMarginVoxels = 24` is the finite fallback.
    **(2) Method B seeds from the box mean.** Since the drawn box is, by Method B's contract, entirely
    calcification, the **seed (high) threshold auto-seeds from the box's mean HU** (`CalcificationSegmenter.meanHU`),
    and the **"Seed ≥" slider spans mean±20** (anchored on a stable `CalcificationRegion.seedMeanHU`, not
    the live value, so dragging doesn't drift the range). The mean is (re)computed on box **draw,
    method-switch, AND resize** via `seedGrowThresholdFromBoxMean`. The **"Grow ≥" boundary** slider is a
    fixed **40–80 HU** band at **0.1-HU** precision (initial **55**). In grow mode the **Otsu button
    becomes "Mean"** (re-center the seed on the box mean — Otsu is meaningless when the box is all calc).
    **(3) Method A is a fixed low band.** The **"Threshold ≥"** slider is a fixed **40–100 HU** band at
    **0.1-HU** precision (initial **55**); **box-draw no longer auto-runs Otsu** (kept as a manual,
    range-clamped button) so the fixed initial value holds. Shared engine constants
    `growBoundaryHURange` (40…80) + `thresholdHURange` (40…100) back the sliders, the `setActiveRegionMethod`
    clamps, and the Otsu clamp. **Sliders avoid `step:`** (round to 0.1 in the binding) to dodge the
    documented SwiftUI tick-mark layout cost. **Not GUI-verified** (no real-CT GUI pass yet); locked by
    unit tests — engine `meanHU`, reach finite-vs-unlimited flood, box-mean seeding + re-tracking, and the
    fixed Method-A default. **swift test green (105 XCTest + 59 swift-testing = 164).**
  - **Follow-up (2026-06-24) — segmentation UX/flow + data-loss hardening.** Driven by an
    adversarially-verified multi-lens review of the create/select/add/delete flow. **(1) No silent data
    loss (the must-fix):** `reEditRegion` previously `remove`d the region + zeroed its mask voxels on
    entry, so a Cancel / click-away / "+ New Region" after re-editing destroyed it permanently (the
    cancel path restored the post-zero backup, i.e. 0). Now `reEditRegion` stashes the region's prior
    list index + its committed voxel coords (`reEditingRegionIndex`/`reEditingCommittedCoords` on the
    model); `cancelActiveRegion` → `restoreReEditedRegionIfNeeded` repaints the original label + re-inserts
    the region at its index; `commitActiveRegion` inserts at that index + clears the stash;
    `resetSegmentation` clears the stash and **cancels an in-flight SynthSeg** (its completion now no-ops
    via `synthSegRunner === runner` so a superseded run can't overwrite fresh state or attach a wrong-grid
    mask — `loadBrainMask` also guards on the captured `seriesUID`). **4D:** `selectTimepoint` settles the
    draft then **carries `labelMask` across timepoints** (identical canonical grid) instead of orphaning
    committed regions. **(2) Discoverable, unambiguous flow:** every region row gets a visible trailing
    ellipsis **Menu (Re-edit / Delete)** (the right-click contextMenu stays as the shortcut); the Segment
    toolbar gains a **`minus`** button (▲ +/- symmetry with the Layers tab); a row tap routes through
    `selectRegion`, which is a **no-op while a draft is live** (kills the dual-active draft+committed
    state); the touch-up brush UI + the **K** shortcut are gated on `hasSegmentation && draftRegion == nil`
    so the brush can't silently no-op. **(3) Legible science:** region rows + the live preview show
    **physical volume (mm³/cm³)** next to the voxel count (`physicalVolumeString`/`regionSizeString` off
    the volume spacing); the ROI **histogram** gains HU value labels above the threshold markers + min/max
    axis ticks; an **always-visible, method-specific caption** explains each method (esp. Method B's "box
    ENTIRELY inside the calcification" contract); a **non-CT advisory** + an `effectiveModality`-driven
    unit string ("HU" vs "Intensity") replace the unconditional "HU"; the New-Region prompt is reworded.
    **(4) Cheap correctness + cleanup:** `recomputeRegionVoxelCounts` credits the preview backup so a
    recount under a live preview doesn't undercount overlapped regions; the empty-box preview branch resets
    `previewVoxelCount`/`previewTruncated`; a **redraw preserves the box's refined through-plane depth**;
    the brush shows an approximate **mm diameter**; stale slab-slider comments fixed. Orientation
    (`MPREngine.planeGeometry`), the main-thread-write + `segmentationRevision` sync contract, and the
    excluded 3D panel are all untouched. **Adversarially self-reviewed (no correctness regressions found);
    locked by +5 `SegmentationModelTests` (re-edit→cancel restore, re-edit→new restore, re-edit→commit
    no-dup, select-ignored-during-draft, recount-credits-preview). swift build clean; swift test green
    (110 XCTest + 59 swift-testing = 169). Not yet GUI-verified — user to test.** Deferred (verified but
    larger / behavioral): box translate-drag + handle-overlap tie-break + an inspector Depth stepper;
    on-canvas brush-footprint overlay; widening Method-A's 40–100 HU band toward the 130-HU floor (needs
    fixture + test re-validation).
  - **Follow-up (2026-06-24) — region visibility-toggle bug + Regions-list polish + add-exits-box.**
    **(1) Visibility toggle was a no-op when it mattered (the bug):** `loadMPRSlice` chose the mask
    render path with `maskAtlasColors: segColors.isEmpty ? nil : segColors`. Hiding a region drops it
    from `calcMaskColorTable()`; when that emptied the table (the common single-region case, or all
    regions hidden), `maskAtlasColors` went `nil`, and `MPREngine.renderSlice` reads `nil` as the legacy
    **flat single-color mask** — which paints **every** non-zero label one color, so the "hidden" region
    stayed on screen in flat red. Fix: a guarded seam `ViewerModel.segmentationAtlasColors()` returns
    `nil` **only** when no region/draft exists (the Phase-7 demo mask); whenever segmentation is active it
    returns the (possibly empty) per-label table, so the `labelMask` always renders as a per-label
    **atlas** and a hidden label composites nothing. `loadMPRSlice` also skips the mask entirely when the
    atlas is empty (all hidden) → grayscale fast path. **(2) Add-Region exits ROI-box mode:**
    `commitActiveRegion` now sets `activeTool = .select` (from `.roiBox`), so the next click navigates
    instead of starting a new box; picking a method re-enters box mode via `beginRegion`. **(3) Regions
    list polish:** section header shows the region count; each `RegionRow` gains a method badge
    (`THRESHOLD`/`GROW`, mirroring the Layers kind badge), grouped voxel counts (`393,263`), a
    dim-when-hidden row + clearer selection (accent fill **+** ring), a consistent eye toggle
    (help/VoiceOver), and a **compact circular color swatch** (an opaque `Circle` over a hit-through
    invisible `ColorPicker`) replacing the bulky native well that crowded the name. Orientation + the
    main-thread-write/`segmentationRevision` sync contract untouched; the flat Phase-7 demo-mask path is
    preserved (no `CalcificationRegion`s ⇒ `nil` ⇒ flat). **Locked by +3 `SegmentationModelTests`
    (hidden-region renders nothing not everything, atlas excludes only hidden, commit-exits-box). swift
    build clean; swift test green (113 XCTest + 59 swift-testing = 172).** Color-dot click (opens the
    system color panel via the hit-through well) is the one item left for a by-hand GUI check.
  - **Follow-up (2026-06-24) — findable SynthSeg output + auto-loaded layer + a Settings window.**
    Driven by the user: SynthSeg "ran but took forever and the output vanished" (it wrote to a temp dir),
    and FreeSurfer was only locatable from a one-off inspector panel. **(1) Output beside the source +
    Show in Finder:** `generateBrainMaskWithSynthSeg` now resolves a writable directory
    (`AppSettings.resolveOutputDirectory`: next-to-source by default, else a chosen folder, falling back
    source → `~/Documents/Lentis` → temp) and points SynthSeg's `--o` straight at
    `<base>_synthseg.nii.gz` there (no more temp output). `loadedFileURL` is retained on load to anchor
    "beside source". The model tracks `synthSegOutputFiles`; the Segment inspector shows a **"Saved N
    files · <dir>"** row with a **Show in Finder** button (`revealSynthSegOutputInFinder` →
    `NSWorkspace.activateFileViewerSelecting`). **(2) Auto-load the label as a layer:** on success
    `loadSynthSegResult` loads the parcellation once via `OverlayLayerLoader`, sets it as the brain
    constraint (`brainMaskLayer`) **and** (when `autoLoadSynthSegResult`) adds the *same* `OverlayLayer`
    instance to `layerStore` — shared, so no second full-grid allocation — so it shows in the Layers tab
    (atlas → FreeSurfer-LUT colored regions; phantom collapses to a mask). When `writeDerivedBrainMask`
    is on it also binarizes the parcellation (nonzero→1) on the base grid and writes
    `<base>_brainmask.nii.gz` back on the **original CT grid** via `NiftiWriter.writeMask`. **(3) Settings
    window (⌘,):** new `AppSettings` (UserDefaults-backed `ObservableObject` singleton; the SynthSeg
    binary key reuses `SynthSegRunner.defaultsKey` for back-compat) is the single source of truth, read
    by the viewer and bound by `SettingsView` (a `TabView`: **General** = overlay opacity + output
    location/auto-load toggles; **FreeSurfer** = live `mri_synthseg` status, FreeSurfer-home/binary
    pickers, `--robust`/`--parc`/threads). `SynthSegRunner.locate` now also consults the persisted
    FreeSurfer home (so a Finder-launched app finds the binary). The model subscribes to
    `$overlayOpacity` to re-render live. Entry points: the macOS Settings menu item, a toolbar **gear**
    (`SettingsLink` in `ViewerToolbar`), and `SettingsLink`s in the Segment inspector (a gear by
    "Generate", and "Set Up FreeSurfer…" when not found — the old NSOpenPanel "Locate" path was removed).
    New files: `AppSettings.swift`, `SettingsView.swift`. **GUI-verified end-to-end** on `synthetic_calc`:
    a real CPU SynthSeg run wrote `_synthseg`+`_brainmask` next to the source, the inspector showed
    "Saved 2 files" + Show in Finder, the result auto-appeared in the Layers tab (Mask · 229 vox), and
    both Settings tabs render in the dark Liquid-Glass idiom (the FreeSurfer tab live-detected the binary;
    "Files go to" resolved to the source folder). **+8 `AppSettingsTests` (base-name strip, output-dir
    resolution incl. fallbacks, persistence round-trip, defaults). swift build clean; swift test green
    (113 XCTest + 66 swift-testing = 179).** Note: derived files use a fixed `<base>_{synthseg,brainmask}`
    name → a re-run overwrites a prior run's output beside the source (intended).
  - **Follow-up (2026-06-24) — direct (no-dialog) export + a Liquid-Glass success toast.** The
    mask/atlas export `NSSavePanel` is gone. `ViewerModel.exportSegmentation(kind:)` writes straight to
    `exportURL(for:)` — the same `AppSettings.resolveOutputDirectory` location as SynthSeg, named
    `<base><suffix>.nii.gz` with configurable suffixes (`exportMaskSuffix`/`exportAtlasSuffix`, default
    `_calcmask`/`_calcatlas`; `AppSettings.sanitizedSuffix` strips separators + empties). Success shows a
    **floating glass banner** (`Toast.swift`: `ViewerToast` + `ToastBanner`, the macOS "it worked" HUD
    idiom) at the viewport top-center — green check, "Mask/Atlas exported", filename, and a **Show in
    Finder** button — auto-dismissing after 4 s (`ViewerModel.presentToast`/`dismissToast`/
    `revealToastFile`, rendered as a `ContentView` overlay with a spring transition). The Segment
    inspector's Export buttons are relabeled "Export Mask/Atlas" (no ellipsis) with a "Saves to <dir>/ —
    change … in Settings" caption; Settings gains an **Export File Names** section (suffix fields +
    `.nii.gz` + a live `<base><suffix>.nii.gz` footer preview). New file: `Toast.swift`. **GUI-verified
    end-to-end** on `synthetic_calc`: drew + committed a Threshold region, clicked Export Mask → **no
    dialog**, the toast appeared, and `synthetic_calc_calcmask.nii.gz` landed in `TestData/` (valid gzip
    NIfTI). **+1 `AppSettingsTests` (suffix sanitize) + suffix coverage in persistence/defaults. swift
    build clean; swift test green (113 XCTest + 67 swift-testing = 180).**
  - **Follow-up (2026-06-24) — Segment inspector + Settings UI polish (PR #1, on `master`).** Two
    sections redesigned in the Liquid-Glass idiom. **Brain Mask** (`SegmentInspectorView`): removed the
    inline SynthSeg gear `SettingsLink` (Settings still on the toolbar gear + ⌘,); added a state-aware
    tinted-glass status glyph (`BrainMaskState`: ready=green check / generating=hourglass / canGenerate=
    accent wand / needsSetup=orange wrench) + a clear hierarchy — **Generate with SynthSeg** is the
    full-width hero (`.glassProminent`), **Load Existing…** the quiet secondary, **Clear** a compact
    trash button shown only when a mask is loaded; the active run moved to a tinted-glass `runningStrip`
    and the output became one tappable reveal-in-Finder glass card. **Export File Names** (`SettingsView`):
    the unbalanced label+trailing-field rows became a **filename-builder** (`exportNameRow`: icon + role
    label, editable suffix in an accent capsule, `.nii.gz` chip) + a live **Preview** row assembling both
    output names (`composedFilename`, dimmed base + accented suffix + dimmed ext, monospaced/selectable;
    uses `Text` interpolation, NOT the macOS-26-deprecated `Text +`). The Settings teal/amber are
    deliberately avoided here (those mean MRI/CT) — uses the neutral `lentisAccent`.
  - **Follow-up (2026-06-24) — Codex review fixes: export safety (PR #2, merge `285e872`, on `master`).**
    Addressed all 3 Codex findings on PR #1 (each verified real). **(P1)** A live draft paints its preview
    as label 255 over committed voxels (originals in `segPreviewBackup`); `NiftiWriter.writeMask` skips
    255, so exporting mid-draft silently dropped overlapped committed voxels. `exportSegmentation` now
    throws `NiftiWriteError.draftActive` and the Export buttons are disabled (with a hint) while
    `draftRegion != nil`. **(P2)** The region-row right-click Re-edit/Delete are now gated on
    `draftRegion == nil` like the ellipsis menu (deleting mid-draft could orphan voxels `clearPreview`
    later restores). **(P2)** `writeMask` stages straight into a `UInt8` buffer (labels are 1…254; 255
    reserved) instead of a ~1.4 GB `Int32` intermediate on a 344×1024×1024 volume — the unreachable
    UInt16/Int32 datatype branches removed; output byte-identical for real inputs. **+1
    `SegmentationModelTests.testExportBlockedWhileDraftActive`. swift build clean; swift test green
    (114 XCTest + 67 swift-testing = 181).**

- [x] **BIDS dataset support + Settings polish (2026-06-24, merged to `master` @ `6a4c208` via PR #3).** Open a **BIDS dataset folder**
  (or any folder of loose NIfTI) via a sidebar **dataset navigator** and a **BIDS-derivatives** output mode,
  plus a fix to the Settings "Export File Names" doubled-suffix chip. New pure model `BIDSDataset.swift`
  (entity parse / scan / derivative naming) + UI `BIDSNavigatorView.swift`. **Open flow:** `load(url:)` now
  routes directories to `loadFolder` (off-main scan → auto-load first image); `openFolder`/`openFileOrFolder`
  + a sidebar split-`Menu`("Open File…" / "Open Folder…") + File-menu **Open Folder…** (⌥⌘O); the unified
  **Open…** (⌘O) accepts a file or a folder; drag-drop accepts folders. `dataset`/`currentDatasetFile` state
  drives the navigator + naming; selecting a navigator file uses `selectDatasetFile` (`preserveDataset`).
  **Output coordination:** `OutputLocationMode.bidsDerivatives` (auto-default-able) writes
  `derivatives/lentis/sub-XX/[ses-YY/]<datatype>/…_desc-<label>_{mask|dseg}.nii.gz` (+ `dataset_description.json`,
  `_dseg.tsv`) via `ViewerModel.resolveOutputURL`/`bidsDerivativeURL`; SynthSeg parcellation/brain-mask +
  segmentation export all flow through it (falls back to beside-source when no BIDS file). The source modality
  is folded into the `desc` (`descIncludingModality`) so sibling-modality derivatives can't collide; carried
  entity values are alphanumeric-sanitized. **Settings:** `exportNameRow` `.labelsHidden()` fixes the
  duplicated `_calcmask` chip; the Preview + "Files go to" are mode-aware (BIDS name with the `desc-` accented).
  **Adversarially reviewed** (5-dimension workflow → 10 confirmed findings, all fixed): the HIGH one — re-tapping
  the loaded navigator row reloaded + wiped segmentation/layers — is now a guarded no-op; plus collision-free
  naming, datatype whitelisting, subject-root images kept as an implicit session, in-flight-open gating, no
  `_LUT.txt` inside the BIDS tree, and overlay-flicker/stuck-overlay fixes. **+8 BIDS/AppSettings tests; swift
  build clean; swift test green (114 XCTest + 86 swift-testing = 200).** **Not yet GUI-verified** (computer-use
  screen access timed out in this environment); a synthetic fixture is at `/tmp/lentis-bids` —
  `./scripts/build_and_run.sh run --benchmark /tmp/lentis-bids` opens it. **Deferred:** a 3D-panel mask overlay
  (unchanged); BIDS validation of writes is best-effort, not a full validator.
  - **Follow-up (2026-06-25) — Codex review fixes on PR #3 (commit `9193744`, in the PR #3 merge).**
    Addressed both Codex findings (each verified real). **(P1)** The BIDS navigator row was the only Open
    path not gated on `isLoading`/`isScanningFolder`; since `loadNifti` decodes off-main with no request
    token and `applyNiftiDataset` has no staleness check, a second row-click mid-decode could race two
    loads and install the wrong volume under a now-stale `loadedFileURL`/`currentDatasetFile` (wrong BIDS
    export name). `BIDSFileRow` now `.disabled(model.isLoading || model.isScanningFolder)` — no second load
    can start while one is in flight, so the race can't occur. **(P2)** Atlas export's `_dseg.tsv` write
    (the only sidecar carrying label names/colors) used `try?`, swallowing failures while the legacy
    `writeLUT` path uses `try`; changed to `try` so a failed write throws instead of reporting a successful
    export of an incomplete BIDS derivative. Codex re-reviewed the fix commit clean ("no major issues").
    `swift build` clean; `swift test` green (114 XCTest + 86 swift-testing = 200).

- [x] **Segment-panel redesign — empty-state fix + status strip + layout polish (2026-06-25, merged to
  `master` @ `f99e216` via PR #4).** Driven by
  the user (with a screenshot of the broken empty state). Three asks, all done: **(1) empty-state overlap
  bug** — when no volume was loaded the "No Volume" `ContentUnavailableView` was a transparent `.overlay`
  drawn ON TOP of the still-visible Brain Mask / New Region / Regions / Export sections, so they overlapped
  and looked broken. `SegmentInspectorView.body` is now a conditional `Group { segmentationVolume == nil ?
  emptyState : loadedBody }` so the sections are simply NOT in the tree without a volume — the overlap is
  structurally impossible; `emptyState` is a hand-built centered cube glyph + "No Volume" + caption (a bare
  `ContentUnavailableView` renders flush-left and clashes with the column). **(2) status indicator** — a new
  `statusStrip`, the first child of `loadedBody`: three equal-width glass pills **Brain · Regions · Export**,
  each a pure read of EXISTING published state (`StatusCellModel{glyph,tint,title,value}`; no segmenter
  calls). Brain: none→ready(green "Mask"/"Parcellation")→running→needs-setup; Regions: none→`N · V cm³`
  (committed count + summed physical volume)→"Editing" (draft); Export: `—`→Pending(orange)→**Saved**
  (green)→"Finish" (draft blocks export). This is requirement #2's brain-mask + export indicators in one
  deliberate surface. Backed by **new model state** `ViewerModel.exportedMaskURL`/`exportedAtlasURL` +
  `hasExportedSegmentation` + `invalidateSegmentationExports()` (set on a successful `exportSegmentation`,
  cleared on every voxel-content change — commit/delete/brush/reset — so "Saved" never claims a
  stale on-disk file). **`reEditRegion` deliberately does NOT invalidate on entry (Codex P3 fix):** a
  re-edit alone changes no committed content — a *commit* invalidates (its voxels may have changed) and a
  *cancel* restores the exact original voxels (`restoreReEditedRegionIfNeeded`) so the export still
  matches; invalidating on entry would wrongly strand the Export pill at "Pending" after a no-op
  re-edit/cancel. (The draft meanwhile reads "Editing"/"Finish" and blocks export, so the still-recorded
  URL is never shown as "Saved" mid-draft.) **Atlas-only invalidation (`invalidateAtlasExport()`, Codex P2 fix):** a region
  rename/recolor (`RegionRow` name `onChange` + the color binding) clears only `exportedAtlasURL` — the
  atlas `_LUT.txt`/`_dseg.tsv` sidecar serializes names/colors, while the binary mask has no metadata so
  `exportedMaskURL` stays valid. **(3) layout polish** — Brain Mask collapses to a compact green done-summary (glyph
  + status + overflow Menu) once a mask is loaded, reclaiming space for the tall editor; the no-mask cluster
  gains an "Optional…" caption; the Active Region editor is wrapped in a faint `lentisAccent` glass card;
  Export shows a green reveal-in-Finder card after a successful export. **Design** chosen via a judge-panel
  of three divergent proposals (workflow-stepper / native-minimal / summary-card) → native-minimal spine +
  a single consolidated status strip. **GUI-verified** on `synthetic_calc.nii.gz`: the empty state is clean
  (no overlap); the loaded Segment tab shows the strip + all sections with no clipping in the ~300pt column;
  loading the brain mask flipped the Brain pill to green "Mask" + the compact done-summary live. **+3
  `SegmentationModelTests` (export records URL + brush/delete invalidate + atlas-only metadata invalidation;
  +1 for the P3 canceled-re-edit-preserves-export fix).
  swift build clean; swift test green (118 XCTest + 86 swift-testing = 204).** Deferred (synthetic input can't drive a SwiftUI
  `DragGesture`/segmented Picker): GUI screenshots of the regions-committed / exported "green" pill states —
  they reuse the verified `statusCell` primitives and are covered by the export-status unit test.
  **Follow-up fixes in PR #4:** (a) the Active Region editor's segmented **Method** `Picker` label wrapped
  to "Metho/d" in the narrow column → `.labelsHidden()` (full-width, no squeeze; commit `9b7bad5`);
  (b) Codex P2 — atlas export staleness on region rename/recolor (`invalidateAtlasExport()`, commit
  `18fa811`); (c) Codex P3 — a canceled re-edit restores exact voxels so the export stays valid → don't
  invalidate on `reEditRegion` entry (commit `933c99f`).

- [x] **Auto-update via Sparkle (2026-06-26, branch `feature/sparkle-auto-update` / worktree).**
  In-app automatic update checking + download + install, using the **Sparkle 2.x** framework (the
  macOS auto-update standard — "don't reinvent the wheel"). Replaces the Phase-1 `UpdateChecker` that
  only opened a browser to the DMG; Sparkle does the actual download / EdDSA-verify / extract / replace
  / relaunch with its native update window. **Implementation:** `Package.swift` adds the Sparkle SPM
  binary target; `UpdaterController.swift` wraps `SPUStandardUpdaterController(startingUpdater:true,…)`
  as a `@StateObject` (created lazily so `NSApplication` is ready) — auto-checks on launch (24 h
  interval, hidden until 2nd launch) and the app-menu **Check for Updates…** is the manual entry.
  `package_app.sh` embeds `Sparkle.framework` into `Contents/Frameworks/` (preserving the versioned
  symlinks), adds the `@executable_path/../Frameworks` rpath (idempotent), bakes `SUFeedURL`
  (`releases/latest/download/appcast.xml` — hosted as a Release asset, no GitHub Pages dep) + the
  conditional `SUPublicEDKey` into `Info.plist`, and signs the framework inside-out on the `--notarize`
  path. **CI (`.github/workflows/release.yml`):** signs the DMG with Ed25519 and emits `appcast.xml`
  (one `<item>`: `sparkle:version` = build #, `sparkle:shortVersionString` = marketing, enclosure =
  the Release DMG URL + `sparkle:edSignature` + length), uploaded alongside the DMG. Signing uses
  `scripts/sparkle_tools.swift` (Apple **CryptoKit** `Curve25519.Signing`, no pip/external deps —
  interoperable with Sparkle's libsodium Ed25519). **Keys (one-time, manual):** `swift scripts/sparkle_tools.swift generate`
  → PUBLIC key → GitHub repo var `LENTIS_SPARKLE_PUBLIC_KEY`; PRIVATE key → GitHub secret `SPARKLE_PRIVATE_KEY`.
  Until both are set, releases publish a DMG-only Release (the sign/appcast step no-ops) and in-app
  auto-check silently no-ops — the first release after key setup enables it. **Verified end-to-end
  locally:** a low-version (0.9.0/build 1) app pointed at a local HTTP-served appcast + DMG (both
  baked with the test public key) → Sparkle auto-checked on launch, found the update, showed its
  update window, downloaded the DMG, and **`OK: EdDSA signature is correct for update`** (CryptoKit
  signature verified by Sparkle's libsodium). `swift build` clean, **204 tests green** (118 XCTest +
  86 swift-testing, unchanged). The only unverified step is the final click-Install→replace→relaunch
  (a GUI action that can't be synthetic-event-driven); all validation up to that point passed.
  **Cost:** the app's "zero native deps" property is relaxed to **one** native dep (Sparkle.framework,
  ~3 MB, bundled — imaging stays pure Swift). **Deferred:** delta updates (single-item appcast);
  embedding rich release notes (currently `sparkle:releaseNotesLink` → the GitHub release page).

---

## Test data (`TestData/`)

- Real (user-provided): `sub-zdr_ses-20250312_ct.nii` (CT 512×512×221),
  `sub-16309926_T1w.nii.gz` (T1 MRI), `sub-51458789_…MPRAGE_T1w.nii.gz` (445 MB).
- Synthetic (regenerate: `python3 scripts/gen_synthetic_nifti.py`): `synthetic_ct.nii.gz` (air/tissue/skull +
  calcification blob → reads as CT), `synthetic_mri.nii.gz` (non-negative → MRI),
  `synthetic_mri_4d.nii.gz` (5 timepoints), `synthetic_orient.nii.gz` (octant markers for
  orientation checks), `synthetic_calc.nii.gz` (Phase 9: tissue + dense skull shell + three separated
  calcification blobs of known HU) + `synthetic_calc_brainmask.nii.gz` (matching interior mask). All
  64×64×48, 1 mm iso, RAS affine, origin at center.
- Standalone reader check (no DICOM/UI deps), fast real-data validation (entry file must be named
  `main.swift` for top-level code):
  ```bash
  swiftc -O /tmp/main.swift Sources/Lentis/NIfTI.swift Sources/Lentis/NiftiVolumeLoader.swift \
    Sources/Lentis/VolumeData.swift Sources/Lentis/Orientation.swift -o /tmp/realcheck
  ```
