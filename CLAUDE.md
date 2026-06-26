# Lentis — Native macOS NIFTI Brain Viewer

A SwiftUI + Metal macOS app for viewing 3D brain **NIFTI** (`.nii` / `.nii.gz`) images,
supporting **both CT and MRI**. Forked from `jnheo-md/open-dicom-viewer` (MIT) and fully
converted from a DICOM viewer into a NIFTI viewer (all DCMTK/OpenJPEG removed, Phase 3).

**What it does:** load CT/MRI NIFTI (incl. 4D) → display in **neurological orientation**
(patient-left = screen-left) per the image affine → **modality-aware window/level**
(CT HU presets incl. Brain `(0,80)`; MRI robust percentile auto-window). Three
orthogonal MPR views linked by a draggable 3D crosshair, plus an interactive Metal
**3D volume-rendering** fourth view. Drag-to-open (file or BIDS folder), drag-to-resize
ROI segmentation (Method A threshold / Method B seed-grow), SynthSeg brain-mask +
parcellation, NIfTI mask/atlas export, external Mask/Atlas layers, FreeSurfer LUTs,
Sparkle auto-update. MIT license.

This file is the working record. Update it as phases complete.

---

## Build / Test / Run

```bash
swift build                       # debug build (~20s clean)
./scripts/build_and_run.sh        # debug build + stage dist/Lentis.app + launch
./scripts/package_app.sh          # release build → Lentis.app + Lentis.dmg (ad-hoc signed)
swift test                        # full suite: 244 tests (158 XCTest + 86 swift-testing)
swift test --filter nifti --filter dataset   # just the NIFTI tests
swift test --filter SegmentationSeam         # Phase-7 mask-seam tests
swift test --filter windowLevelRenderIsAsync # W/L-drag async/off-main regression test

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
```

- **Perf probe:** `--benchmark` writes `~/Desktop/lentis_benchmark.csv` (and `[BENCH]` to
  stderr). Main-thread-cost events (must stay sub-ms): `scroll_main`, `crosshair_set`,
  `wl_drag`. Off-main render events: `mpr_render` / `volume_render`. `--perf-stress`
  fires 80 each of W/L flushes (sagittal MPR + 3D), crosshair relocations, and scroll
  ticks so interactive perf can be measured without a GUI. Add `--wl-hold` for a
  sustained ~15 s W/L drive that can be attached to with `sample` (catches SwiftUI
  layout after the flush returns). Latest MPRAGE quad numbers: `wl_drag` 0.10 ms,
  `crosshair_set` 0.15 ms, `scroll_main` 0.30 ms — all off-main render.

- **Toolchain:** Swift 6.3, Xcode 26.4, macOS arm64. Deployment target **macOS 26**
  (Tahoe) for native Liquid Glass APIs; Swift 5 language mode pinned. Bundle id
  `com.kalicooper.lentis`, marketing version `2.2.0`. **One native dependency: Sparkle
  2.x** (auto-update, bundled into the `.app` by `package_app.sh`); imaging stays pure
  Swift + Metal/AppKit.
- `swift build` after adding a `PanelMode` case → the compiler flags every
  non-exhaustive `switch`. Fix each intentionally (usually mirror `.mprCoronal`).
- **Git state:** default branch is **`master`** (single main checkout). Real patient
  data (`TestData/sub-*`) is gitignored — only synthetic fixtures are tracked. Commit
  per logical step; branch off `master` and open a PR.

### Auto-update (Sparkle) one-time key setup

Do this **before** the first tagged release that should auto-update; until both keys
are set, releases publish a DMG-only Release and in-app auto-check silently no-ops.

```bash
swift scripts/sparkle_tools.swift generate   # Apple CryptoKit Ed25519, no deps
#   PUBLIC (base64)  → GitHub repo variable LENTIS_SPARKLE_PUBLIC_KEY
#   PRIVATE (base64) → GitHub repo secret   SPARKLE_PRIVATE_KEY
```

`package_app.sh` bakes `SUPublicEDKey` + `SUFeedURL` (`releases/latest/download/appcast.xml`)
into `Info.plist`; `.github/workflows/release.yml` signs the DMG with Ed25519 and emits
`appcast.xml` next to the DMG. The Release workflow **hard-gates the appcast on both
keys being set and matching** — a private-key-only config, or a mismatched keypair,
is a hard CI error (can't strand installs). Local release builds can also set
`LENTIS_SPARKLE_PUBLIC_KEY=<pub>` env before `./scripts/package_app.sh`.

---

## Repository layout

- SPM package/product/executable target = **`Lentis`**, sources in `Sources/Lentis/`.
  Plain `executableTarget`; only the tests target alongside it.
- Test target = **`LentisTests`** (`Tests/LentisTests/`), uses `@testable import Lentis`.
- DCMTK/OpenJPEG fully removed (Phase 3); `Sources/DCMTKWrapper/` and `libs/` gone
  (recoverable from git history before commit `1e4f5da` if ever needed).
- `scripts/package_app.sh` builds the bundle (no `dicom.dic` copy, no Sparkle XPC services).
- `TestData/` holds real + synthetic NIFTI (see bottom). Gitignored: `.build/`, `*.app`, `*.dmg`.

### Key source files

| File | Role |
|---|---|
| `App.swift` | `@main LentisApp`. Menus, `--benchmark <path>` auto-open, plain `WindowGroup` (title via `.navigationTitle`), owns `UpdaterController` (`@StateObject`); app-menu **Check for Updates…**. |
| `UpdaterController.swift` | Sparkle 2.x wrapper. `@MainActor ObservableObject` owning `SPUStandardUpdaterController(startingUpdater:true)`, created lazily once `NSApplication` is ready. Auto-checks on launch (24 h); `checkForUpdates()` is the manual entry. |
| `ViewerModel.swift` (~1700 lines) | Central `@ObservableObject`. Panels, volume cache, MPR/3D, W/L, sync-scroll. Crosshair (`setCrosshair` — `.volume3D` excluded) backed by a decoupled `CrosshairState`. 3D (`loadVolumeRendering` async/coalesced on `panel.loadingQueue`). W/L drag re-drives `loadMPRSlice`/`loadVolumeRendering` off-main. |
| `ViewerModel+Nifti.swift` | NIFTI orchestration: `loadNifti`, `applyNiftiDataset`, `selectTimepoint`, `setModalityOverride`. Modality-aware W/L seed/reseed (`modalityDefaultWindow`/`seededWindow`/`applyWindowPreset`/`autoWindow(for:)`). |
| `ViewerModel+Segmentation.swift` | Multi-region orchestration: region lifecycle (begin/setBox/preview/commit/cancel/delete/re-edit), per-label color table, touch-up `paintBrush`, brain-mask load + SynthSeg drive, mask/atlas export. Editable mask = `VolumeData.labelMask` (1…254 = regions, 255 = transient preview); all mask writes on main then bump `segmentationRevision` (drops stale in-flight renders). **`exportSegmentation` throws `.draftActive` while a draft preview (label 255) is live** — the writer skips 255, so exporting mid-draft would silently drop overlapped committed voxels. |
| `BIDSDataset.swift` | Pure BIDS model (no UI/AppKit): `BIDSEntities.parse`/`derivativeName` (filename ↔ entities/suffix/ext; alphanumeric-sanitized), `BIDSImageFile` (`descIncludingModality` folds the source suffix into `desc`), subject→session→known-datatype file tree, derivative naming. Unit-tested via on-disk temp trees. |
| `BIDSNavigatorView.swift` | Sidebar dataset navigator (folder open). Outline of subjects → sessions → image rows with datatype-aware icons, a filter field, accent highlight + `eye.fill` on the loaded image. Tapping loads via `selectDatasetFile` (re-tapping the loaded row is a guarded no-op — must not wipe segmentation/layers). |
| `WindowLevel.swift` | `WindowPreset` + CT HU preset table. Brain default `(0,80)`, Subdural/Stroke/Bone/Soft-tissue. `storedWindow(slope:intercept:)` maps HU→stored (identity for direct-HU CT). Pure; no deps. |
| `Theme.swift` | Liquid-Glass design system (macOS 26). Indigo `lentisAccent` + semantic tokens (CT amber, MRI teal, crosshair, viewport, annotations), `Spacing`/`Radius`/`Font`, glass helpers (`glassChrome`, `lentisChip`, `GlassIconButton`). Image viewport stays pure black. |
| `NIfTI.swift` | NIFTI-1/2 reader. Header/endianness/4D/9 dtypes, sform/qform affine, **table-driven pure-Swift DEFLATE** (`DeflateInflater`): direct mapped-input reads + zero-copy output `Data`. Zero deps — do NOT "simplify" back to `Compression.framework` (see gotchas). |
| `NiftiVolumeLoader.swift` | `NiftiDataset`: modality detection, Int16 quantization, percentile auto-window. `makeVolume` reorients to canonical RAS (Phase 4) — folds the relabel/flip into the quantization pass. |
| `Orientation.swift` | Single source of orientation truth (Phase 4). `anatomicalDirection(of:)` (RAS labels) + `closestCanonicalReorientation(affine:)` → `CanonicalReorientation` (axis permutation + flips, lossless, invertible). Pure; no deps. |
| `VolumeData.swift` | 3D Int16 voxel buffer + affine. `voxelToWorldMatrix` is the canonical RAS affine; `originalAffine` + `reorientation` retained for mask write-back. Phase-7 seam: optional same-grid `labelMask: LabelVolume?` + `ensureLabelMask()`. |
| `LabelVolume.swift` | Segmentation seam (Phase 7). Same-grid UInt8 mask (slice-major, identical dims) on `VolumeData.labelMask`; shares the volume grid so write-back reuses `reorientation` + `originalAffine`. |
| `OverlayLayer.swift` / `LayerStore.swift` | Session-scoped external Mask/Atlas layers. Immutable label storage (`UInt8` mask; `UInt16`/`Int32` atlas) + observable visibility, opacity, color/LUT, per-label visibility, ordering, selection, render revision. UI list top-first; render snapshots reversed so the top row composites last. |
| `OverlayLayerLoader.swift` | Background NIfTI layer loader + classifier. One 3D timepoint, auto-detects Mask vs Atlas by nonzero integer labels, same-grid fast path or affine-aware nearest-neighbour resampling onto canonical RAS, rejects non-overlapping volumes. |
| `ColorLookupTable.swift` / `CustomLUTRepository.swift` | Strict FreeSurfer-format LUT parser (`ID Name R G B T`, `opacity = 1 - T/255`) + content-deduplicated custom LUT persistence in `~/Library/Application Support/Lentis/LUTs/`. Bundled default: `Resources/FreeSurferColorLUT.txt`. |
| `LayerInspectorView.swift` | Native trailing SwiftUI Inspector for Mask/Atlas layers: add/drop, select, reorder, hide, delete/undo; Mask color/opacity; Atlas LUT pick, searchable actual-label legend, voxel counts, per-label visibility, LUT import/manage. Toolbar-owned add/remove + Show/Hide (gated on `showLayerInspector`) so the main toolbar stays confined to the viewport (Keynote pattern). |
| `MPREngine.swift` | CPU slice extraction (`axialSlice`/`sagittalSlice`/`coronalSlice`) + `renderSlice(ww:wc:mask:…)` (Float + precomputed-reciprocal, parallelised across 8 bands for ≥512² slices; RGBA composite when a mask is present). **`planeGeometry(mode:sliceIndex:)` is the ONE place** defining each plane's neurological flips + display dirs (Phase 4); extractors, cross-ref metadata, and `maskSlice` all read it. Crosshair geometry: `PlaneGeometry.world(col:row:)`/`pixel(of:)` + `orthogonalSliceIndex(for:containing:)`. |
| `CrossReferenceOverlay.swift` | 3D crosshair overlay (Phase 6). Lines + center dot through `crosshair.world`'s in-plane projection, MPR panels only. **Hosts `CrosshairState`** and observes *it* (not the model) → a drag invalidates only this overlay, not the whole quad (drag-lag fix). |
| `MetalVolumeRenderer.swift` | Phase-8 direct volume renderer. Metal compute ray marcher over cached `.r16Sint` 3D texture; physical-spacing-aware ray/AABB, window-selective transfer function, front-to-back alpha compositing, early termination, gradient lighting, W/L in stored units. 192² interactive preview / 512² final render. |
| `CalcificationSegmenter.swift` | Phase-9 segmentation engine (pure). `VoxelBox` (+ `fromPlanePoints`, `handles(plane:sliceIndex:)`/`resize(...)`, `inPlaneAxes`/`slabAxis` for interactive 3D resize), `SegmentationMethod`/`Connectivity`/`Parameters`, one configurable hysteresis dual-threshold + 3D connected-component + brain-mask AND + min-size grower, Otsu, `meanHU`, ROI histogram, `BrainConstraint`. Works in canonical voxel HU via `calibratedValue`. `growMarginVoxels: Int?` (nil = unlimited, the `.growFromSeed` default); fixed bands `growBoundaryHURange` (40…80) + `thresholdHURange` (40…100) back the sliders. |
| `CalcificationRegion.swift` | One region's data model (`ObservableObject`): label, name/color/visibility, `parameters`, `box` + `slabAxis`, voxel/anatomical name. |
| `SegmentationBoxOverlay.swift` | Draft box cross-section + 8 grab handles (corners + edge mids) on each intersecting MPR plane; reuses the `CrossReferenceOverlay` pixel→screen transform. 3D excluded. |
| `SegmentInspectorView.swift` | Segment tab of the trailing inspector. Body is a conditional `Group` (empty state REPLACES the sections — never an `.overlay` over them). `statusStrip`: three glass pills Brain·Regions·Export reading existing published state. Brain Mask cluster with state-aware glyph + collapse-to-done-summary. Active Region editor (method, ROI histogram, threshold sliders, Otsu/Mean, live preview) in a faint `lentisAccent` glass card. Regions list (recolor/rename/re-edit/delete/brush; right-click + ellipsis both gated during a draft). Export buttons disabled while a draft is active; green reveal-in-Finder card on success. |
| `NiftiWriter.swift` | NIfTI-1 writer. `writeMask` stages straight into a `UInt8` buffer (labels 1…254, 255 reserved → always DT_UINT8; no ~1.4 GB Int32 intermediate), **write-back to the original input grid** via `reorientation`+`originalAffine`, gzip (raw DEFLATE + RFC-1952 + CRC32), `writeVolume` (gray CT for SynthSeg), FreeSurfer LUT sidecar. |
| `SynthSegRunner.swift` | Runs `mri_synthseg --parc --robust --ct --cpu --threads N` via `Foundation.Process` (off-main, streamed progress, cancel). Locates the binary (user override → persisted → `AppSettings` FreeSurfer home → `$FREESURFER_HOME/bin` → PATH → `/Applications/freesurfer/<ver>/bin`) and sets a **clean** child env (writable HOME/TMPDIR, strips toxic inherited `PYTHON*`/`CONDA*`). Reports **signal-vs-exit** (`status 6` = SIGABRT, a TF abort) and surfaces the captured stderr tail. |
| `AppSettings.swift` | App-wide preferences (UserDefaults-backed `ObservableObject` singleton): FreeSurfer home / `mri_synthseg` path, SynthSeg flags + threads, output-location mode (next-to-source / custom / BIDS derivatives) + auto-load + write-brain-mask, overlay opacity, export filename suffixes. `resolveOutputDirectory` (pure, tested) picks a writable dir with fallbacks. |
| `SettingsView.swift` | The Settings window (⌘,). `TabView`: **General** (overlay opacity, output location + folder picker with a live "Files go to" preview, auto-load / write-brain-mask, **Export File Names** builder rows + live both-files Preview) and **FreeSurfer** (live `mri_synthseg` status, home/binary pickers, `--robust`/`--parc`/threads). |
| `Toast.swift` | Liquid-Glass success/info HUD. `ViewerToast` + `ToastBanner`, glass capsule with optional "Show in Finder". Top-center `ContentView` overlay; driven by `ViewerModel.toast` (auto-dismisses after 4 s). Confirms a direct (no-dialog) segmentation export. |
| `MultiPanelContainer.swift` (~1960 lines) | Multi-panel views + gestures. MPR panels keep pixel-bound orientation/crosshair/ROI-box/scroller overlays + brush-footprint overlay + directional resize cursors. Cursor tracking maps aspect-corrected display pixels back to raw slice pixels before HU lookup, then uses `PlaneGeometry` + cached volume affine to publish canonical voxel `x,y,z` for the status bar. `.volume3D` Select-drag = 60 Hz coalesced trackball-style yaw/pitch (derives motion from absolute cursor-position differences, not `NSEvent.deltaX/Y`); mouse-up settles at full quality. 3D hides 2D overlays, cursor sampling, slice scroller. |
| `ViewerToolbar.swift` | Native macOS Liquid Glass `ToolbarContent`. Leading: layout segmented Picker + MPR + sync/crosshair toggles. Trailing: per-active-panel cluster (plane `Picker`, `ModalityBadge`, W/L popover with histogram + presets/Auto, transform menu) + 4D stepper. The plane `Picker` is intentionally `.disabled` while `model.isMPRLayout` (fixed quad roles the crosshair linkage relies on) — not a bug. Inspector show/hide is owned by `ContentView`/`LayerInspectorView`, not here. |
| `ViewerStatusBar.swift` | Floating Liquid Glass status pill (bottom-leading), non-interactive, shown once a file is open. Active-panel readout once (file · slice · `WL/WW` (+`HU` for CT)); cursor readout (RAS mm / value / canonical voxel `px`) follows the hovered panel. |
| `PanelState.swift` | Per-panel state. `PanelMode = .mprAxial/.mprSagittal/.mprCoronal/.volume3D`. Cursor display pixels, canonical volume voxel `x,y,z`, RAS mm, calibrated value. 3D owns yaw/pitch/density + non-published render revision (drops stale GPU results). |
| `ContentView.swift` | Root `NavigationSplitView` (sidebar + detail) + native trailing `.inspector` (`LayerInspectorView`). Detail = `ZStack` { panel grid · floating glass `ToolPalette` · `NiftiLoadingOverlay` · `ViewerStatusBar` } + `.navigationTitle`/`.navigationSubtitle` + `.toolbar { ViewerToolbar }`. Owns the closed-state "Show Layers Inspector" toolbar button. Global `.tint(.lentisAccent)`; `.preferredColorScheme(.dark)`. |
| `WindowAccessor.swift` | AppKit bridge: window config (`isMovableByWindowBackground`, `.unified` toolbar) + the IME-independent `KeyInterceptorView` (with a testable `handle(key:)` seam). No centered-title machinery — `.navigationTitle` owns the title. `configure(window:model:)` is idempotent + unit-tested. |
| `scripts/sparkle_tools.swift` | EdDSA keygen + DMG signing via Apple CryptoKit (`Curve25519.Signing` = RFC 8032 Ed25519, interoperable with Sparkle's libsodium). `generate` (print public+private base64), `sign <file>` (env `SPARKLE_PRIVATE_KEY` → base64 signature), `public-key` (derive public from private — used by the Release workflow to verify the repo variable matches the secret). |

---

## Data & rendering pipeline (must understand)

1. **2D slices = CPU; 3D volume = Metal.** Axial/sagittal/coronal render through
   `MPREngine.renderSlice` (per-pixel Float W/L loop, parallelised across 8 bands for
   ≥512²). `.volume3D` renders through `MetalVolumeRenderer.renderVolume`: orthographic
   physical-space ray marcher, window-selective opacity, front-to-back alpha
   compositing, early termination, gradient lighting.
   **Extraction + render + NSImage build run on the panel's serial background queue
   (`loadMPRSlice`/`loadVolumeRendering` → `panel.loadingQueue`) and are coalesced** —
   each navigation `cancelAllOperations()` + enqueues, and the main-thread apply drops
   stale results whose `mprSliceIndex`/`panelMode`/`volumeRenderRevision` no longer
   match. Fast scrubbing only pays for the in-flight render plus the latest target; the
   main thread never blocks. Drag rotation renders a coalesced 192² preview at 60 Hz
   and a 512² final frame on mouse-up. W/L drag is throttled to 60 Hz and re-drives
   the same async+coalesced loaders, so W/L stays off-main for every rendered panel.
   GPU slice W/L (the brief's "windowing = GPU uniform" rule) is **deliberately not
   pursued** — the CPU W/L loop is now 0.46 ms for a 1 MP slice (off-main), and a
   per-slice-readback GPU path would only break even on upload + wait + readback. The
   genuine GPU payoff needs the readback gone — a live `MTKView` with W/L as a shader
   uniform (no NSImage), deferred until a concrete driver appears. Clean seam still
   holds: keep slice *extraction* (the oriented Int16 buffer) in `MPREngine`, upload it
   to a 2D `.r16Sint` texture, W/L in a trivial shader — no flip logic in MSL.
2. **W/L units = RAW STORED Int16 values.** The shader/CPU window on stored voxels;
   `scl`/rescale is NOT applied in window math. Presets & auto-window are in stored units.
3. **VolumeData stores Int16.** NIFTI float32/uint16 are quantized to Int16 by
   `NiftiDataset`, with quantization folded into `rescaleSlope/Intercept` so
   `calibratedValue()` reconstructs the true value. **CT stores HU directly** (slope 1,
   intercept 0) when the range fits Int16 and spans ≥256 levels → **HU presets need no
   conversion**. Float data with small range is scaled across ~64000 levels. 4D uses
   the **global** range over all timepoints (every volume on one scale).
4. **NIFTI display path:** `loadNifti` → `NiftiDataset` → `makeVolume(t)` (reorients to
   canonical RAS, §5) → `registerStandaloneVolume(cacheKey: dataset.seriesID, …)` (stable
   cache key + stub `ImageSeries`) → panel set into the quad: three MPR modes render via
   `loadMPRSlice`; `.volume3D` via `loadVolumeRendering`. A 4D switch replaces the cached
   volume under the same key + re-renders all four panels. `VolumeData.seriesUID` is
   distinct per timepoint (forces 3D texture re-upload); the cache key is stable.
5. **Orientation = canonical RAS + fixed neurological flips (Phase 4).** NIFTI world is
   RAS+ (+x=R, +y=A, +z=S). `Orientation.closestCanonicalReorientation` computes the
   axis permutation + flips to bring the voxel grid to closest-canonical RAS (i→R,
   j→A, k→S); `makeVolume` applies it losslessly (no resampling) and stores
   `originalAffine` + `reorientation` for mask write-back. Because every volume is then
   canonical, `MPREngine.planeGeometry` applies a **fixed** flip per plane (buffer row 0
   = screen top, col 0 = left): axial L-left/R-right, A-top/P-bottom; coronal
   L-left/R-right, S-top/I-bottom; sagittal A-left/P-right, S-top/I-bottom. Extractors,
   cross-ref metadata, and labels all read this one definition → pixels + lines +
   labels can't diverge. No per-file/`sliceDirection` heuristics.
6. **Modality** lives on the model: `niftiDataset.detectedModality`, `modalityOverride`,
   `effectiveModality`. Detection: `min ≤ -500 && fraction(v < -200) ≥ 2%` ⇒ CT.
   **Modality drives W/L (Phase 5):** CT → the Brain HU preset (via the volume's
   rescale); MRI → `suggestedWindow` percentile. `seededWindow` prefers a saved manual
   window (per-series in `seriesStates`); `assignSeriesToPanel` / `applyNiftiDataset`
   seed **every** panel from it (fixes the dark quad MPR). The CT/MRI switch is the
   `ModalityBadge` in `ViewerToolbar` (click swaps + reseeds); the W/L popover then
   shows a CT preset menu or an MRI "Auto" button by `effectiveModality`, acting on
   `model.activePanel`; presets apply to all panels showing the series.
7. **Cursor readout:** `cursorHU = stored * slope + intercept` with unit label "HU" (CT)
   or "Intensity" (MRI); shows canonical volume voxel `px [x,y,z]` + RAS `mm`.
   `MultiPanelContainer` maps aspect-corrected display cursor → raw slice pixels before
   HU lookup, then uses `PanelState.displayedPlaneGeometry` for RAS and the cached
   volume's `worldToVoxel` affine for voxel `x,y,z`. Rendered in `ViewerStatusBar` and
   follows the hovered panel. (Needs a real NSTrackingArea mouse event — synthetic moves
   may not trigger it.)
8. **Segmentation mask overlay (Phase 7 seam).** A same-grid `LabelVolume` rides on
   `VolumeData.labelMask` (UInt8, identical voxel grid → write-back via `reorientation`
   + `originalAffine`). `MPREngine.maskSlice(mode:sliceIndex:)` extracts it in the
   **same (col,row) layout as the gray slice** by mirroring `planeGeometry`'s flips
   (locked by `SegmentationSeamTests` in all 3 planes). `loadMPRSlice` passes the mask
   to `renderSlice`, which composites a translucent color (model `maskOverlayColor`/
   `Alpha`, default calcification red) over labeled pixels — **CPU RGBA path, taken
   only when a mask exists**, so the grayscale fast path is untouched. **3D is
   excluded** (Metal path; documented seam). A future Metal entry would upload the
   mask as a 2nd R8 texture and blend in the W/L shader (see `renderSlice` /
   `MetalVolumeRenderer`). Demo: `--benchmark` paints `installDemoSphereMask` so the
   overlay is visible once; inert otherwise.
9. **External Mask/Atlas layers.** `ViewerModel` owns a session-only `LayerStore`;
   adding NIfTI layers parses + aligns them off-main through `OverlayLayerLoader`.
   Same-grid files retain categorical values without interpolation; differing affines
   map target canonical-RAS voxel centers through world space and sample nearest
   neighbour, with zero outside the source. `MPREngine` extracts every visible layer
   with the same `planeGeometry` as grayscale, then composites bottom-to-top using the
   immutable render snapshot/revision. Label 0 is always transparent. Masks use one
   selectable color; atlases use the bundled/custom LUT, per-label visibility, and a
   stable hashed fallback for missing entries. Zero visible layers stay on the
   grayscale fast path. External layers are MPR-only; the 3D panel is unchanged.

---

## Critical gotchas (hard-won)

- **`MPREngine.sagittalSlice` is a perf-sensitive parallel raw-pointer walk** (commit
  `cb12693`). It is the worst-case extraction (fixes i, spans j×k → cache-missing gather;
  1 MP on the MPRAGE). It does the **same gather byte-for-byte** as a `voxelAt` loop
  (orientation unchanged — flips still come from `planeGeometry`, guarded by
  `testSagittalSliceNeurologicalOrientation`) but via a bounds-check-free pointer walk
  parallelised across z-planes (disjoint writes, read-only source). Do **not** "simplify"
  it back to a `voxelAt` triple-loop — that re-introduces ~15 ms / ~57-slices/s lag. If
  you touch its flips, edit `planeGeometry` (the one orientation source), not the loop.
  Profile with the standalone throughput harness pattern (load `NiftiDataset` →
  `makeVolume` → time `axial/sagittal/coronalSlice` + `renderSlice`).
- **gzip decode = pure-Swift DEFLATE.** `DeflateInflater` in `NIfTI.swift` (validated vs
  real Python gzip: small/all-zero/70 KB multi-block + 34 MB `.nii.gz` all match). Keep
  it dependency-free and correct — do **not** "simplify" back to `Compression.framework`
  (its `COMPRESSION_ZLIB` decode was broken by DCMTK's static zlib `inflate` interposing;
  DCMTK is gone but the pure-Swift decoder stays). Large-file perf fix (2026-06-21):
  prefix-table Huffman, local bit reader value type, direct mapped-input reads, exact-size
  raw output buffer. Real 445.9 MB MPRAGE: read **16 → ~4.95 s**, full pipeline ~**8 s**.
  Keep `scripts/NiftiLoadBenchmark.swift` when changing the decoder; Int16 checksum
  `166302106370` matches Python gzip/numpy.
- **`Data.withUnsafeBytes { $0[0] }` footgun.** The untyped closure infers
  `UnsafePointer<Int>`, so `$0[0]` reads 8 bytes. Always type it:
  `{ (raw: UnsafeRawBufferPointer) in raw[0] }`.
- **Adding a `PanelMode` case** breaks several exhaustive switches in `ViewerModel.swift`.
  Build, read the compiler notes, add the case (mirror coronal / use `vol.depth`).
- **The window title comes from `.navigationTitle`/`.navigationSubtitle`.** `App.swift`
  uses a plain `WindowGroup`; `ContentView`'s detail sets the title to the open file name
  + `modality · dims` subtitle. Do **not** reintroduce a custom centered title or set a
  non-empty `WindowGroup("…")` scene title. Regression coverage in `WindowAccessorTests`.
- **Overlay labels are categorical.** Never use linear/trilinear interpolation for
  Mask/Atlas import or slice extraction. Keep affine-aware nearest-neighbour resampling
  in `OverlayLayerLoader`, label 0 transparent, all display flips from
  `MPREngine.planeGeometry`. A layer-list top row is visually topmost and renders
  **last**, even though the UI array is stored top-first.
- **Orientation lives in ONE place: `MPREngine.planeGeometry`** (Phase 4). Render chain
  maps **buffer row 0 → screen top, col 0 → left** (CGImage row 0 = top; NSImageView
  draws upright) — confirmed on `synthetic_orient` octant markers. Volumes are already
  canonical RAS, so each plane uses a *fixed* flip; do **not** reintroduce per-file/
  `sliceDirection` heuristics. Edit `planeGeometry` only — corner-orientation tests in
  `MPREngineTests` catch a sign error.
- **`CrosshairState` is decoupled from the model** (commit `fbe5b1d`). A crosshair drag
  fires `CrosshairState.objectWillChange`, **not** `model.objectWillChange` — only
  `CrossReferenceOverlay` invalidates. Do not `@Publish` the crosshair world point on
  the model or you'll relayout the whole quad per mouse event. `model.crosshairWorld` is
  a computed shim forwarding to `crosshair.world` (call sites unchanged).
- **Sliders must avoid `step:`** when their range is large (e.g. ~1024 slab or HU bands).
  On macOS a *stepped* SwiftUI `Slider` renders one tick-mark label per step →
  `SliderMarkLabels…place` lays out ~thousands of marks per pass (the documented ~2 s
  drag-lag root cause). Round to the desired precision in the binding instead.
- **RTK shell proxy** (user's global `~/.claude`) rewrites `grep`→`rg` and can mangle
  `find … $(...)` / regex alternation. Prefer `rg`-native syntax or absolute
  `/usr/bin/...` paths.

---

## Known issues / open problems (as of HEAD)

None block the build or tests; these are quality/perf debt.

1. **`--benchmark` instrumentation left in** (`scroll_main`, `mpr_render`,
   `volume_render`, `crosshair_set`, `wl_drag`). Gated behind `--benchmark` so it's
   inert in normal runs. Keep as a perf probe, or strip once perf work settles.
2. **Metal mask-texture overlay on the 3D panel is deferred** (Phase 7/9). The 3D panel
   shows only the grayscale volume; segmentation regions and external Mask/Atlas
   layers are MPR-only. Documented seam in `renderSlice` / `MetalVolumeRenderer`.
3. **4D-timepoint segmentation is deferred.** The editable mask + regions are tied to the
   current 3D timepoint; `selectTimepoint` carries `labelMask` across (identical canonical
   grid) but a 4D-aware segmentation UX (per-timepoint regions, timepoint linking) is
   not built. CT is 3D in practice.
4. **GPU slice W/L deliberately not done** — CPU is fast enough (0.46 ms, off-main); the
   real win (live `MTKView`, no readback) awaits a concrete driver. See pipeline §1.
5. **BIDS validation of writes is best-effort**, not a full BIDS validator. Output naming
   is sanitised + collision-free (modality folded into `desc`), but no schema check.

---

## Phase status & roadmap

All phases below are **DONE and merged to `master`** unless noted.

- [x] **Phase 1 — Rebrand to Lentis.** SPM/target/dir/app renamed; menus/About/Help;
  `package_app.sh` + bundle id; Phase-1 `UpdateChecker` (browser to DMG) later replaced
  by Sparkle (Phase 10). Builds & runs as `Lentis.app`.
- [x] **Phase 2 — NIFTI loader (CT+MRI) + first render.** Reader/converter/orchestration.
  Verified on real CT + real T1; 13 NIFTI unit tests added.
- [x] **Phase 3 — Remove DICOM/DCMTK/OpenJPEG.** Deleted DICOM-only UI (~648 lines),
  `Sources/DCMTKWrapper/`, `libs/`, `SimpleDICOM.swift`, `MultiFrameDecoder.swift`, and
  gutted DICOM ingestion (~45 methods). Renamed `DICOMModel`→`ViewerModel`,
  `DicomSeries`→`ImageSeries`, test target→`LentisTests`. File-open dialog became
  NIfTI-only. `otool -L` shows no DCMTK/OpenJPEG linkage.
- [x] **Phase 4 — Neurological orientation + tri-view.** `Orientation.swift` (RAS labels
  + closest-canonical reorientation); `makeVolume` reorients every volume to canonical
  RAS losslessly; `MPREngine.planeGeometry` centralises the per-plane flips; `Orientation
  LabelsOverlay` is RAS. Verified on `synthetic_orient` + real CT/T1.
- [x] **Phase 5 — Modality-aware W/L (CPU).** `WindowLevel.swift` CT HU preset table;
  `modalityDefaultWindow`/`seededWindow` seed every panel (fixes dark quad MPR); CT
  preset menu / MRI "Auto" button. GPU slice W/L deferred (pipeline §1).
- [x] **Perf — async MPR/MIP + sagittal extraction + W/L-drag off-main.** `loadMPRSlice`
  /`loadMIPForPanel` (later MIP removed in Phase 8) render async+coalesced off-main on
  `panel.loadingQueue` (per-tick main cost ~15–25 ms → 0.3 ms). `sagittalSlice` rewritten
  as a bounds-check-free parallel pointer walk (extract 15.25 → 1.54 ms = 57 → 213
  slices/s, byte-identical). `renderSlice`'s W/L loop is Float + reciprocal + parallel
  (3.14 → 0.46 ms, gray delta 0); `adjustWindowLevelForPanel` keeps W/L state sync but
  re-drives the async loader. `--perf-stress` self-drives 80× each of W/L + crosshair +
  scroll → all sub-ms. Locked by `windowLevelRenderIsAsyncOffMainThread`. A pathological
  `Slider(step:1)` over ~1024 slab steps + a per-event `model.objectWillChange` caused
  ~1.98 s/event crosshair drag-lag → fixed by dropping `step:` + decoupling
  `CrosshairState` (commit `fbe5b1d`).
- [x] **Phase 6 — 3D crosshair drag linkage.** Click/drag in any MPR panel sets
  `crosshairWorld` (RAS) via `PlaneGeometry.world`; every other panel relocates through
  `orthogonalSliceIndex` + async `loadMPRSlice`; `CrossReferenceOverlay` draws two lines
  + center dot; `.volume3D` excluded. Subsumes the old z-only `syncScrollFromPanel`.
- [x] **Phase 7 — UI polish + segmentation seams.** `ModalityBadge` (CT amber/MRI teal
  + 4D stepper), orientation-label dark halo, NIfTI wording. Seams (no seg behavior):
  `LabelVolume` on `VolumeData.labelMask` + `ensureLabelMask()`, `MPREngine.maskSlice`
  mirroring `planeGeometry` (locked by `SegmentationSeamTests`), `renderSlice(mask:)`
  RGBA composite (CPU, only when a mask exists), model `maskOverlayColor`/`Alpha`.
  `--benchmark` `installDemoSphereMask` makes the overlay visible once.
- [x] **Phase 8 — Interactive 3D volume rendering.** Removed `.mip`, `ProjectionMode`,
  slab state/UI, `loadMIPForPanel`, and the CPU MIP/MinIP/Average helpers. The fourth
  quad panel is `.volume3D` rendering a cached `.r16Sint` 3D texture through a
  physical-spacing-aware Metal ray marcher with window-selective transfer (CT Brain W/L
  makes high-HU skull transparent), front-to-back compositing, early termination, gradient
  lighting. 60 Hz coalesced 192² preview / 512² final on mouse-up; `volumeRenderRevision`
  drops stale GPU results. Camera = `pitchRotation * yawRotation`; pitch normalized (no
  ±89° clamp) for orbit-through; drag delta inverted so the model follows the pointer.
  Tests incl. real Metal compile + 16³ dispatch + non-black assertion.
- [x] **External Mask/Atlas layers + native trailing Inspector.** One add/drop entry
  accepts 3D NIfTI overlays, auto-detects Mask vs Atlas by nonzero integer labels, uses
  same-grid fast path or affine-aware nearest-neighbour resampling, rejects overlaps.
  `LayerStore` is session-only (survives 4D swap, clears on new base file). `MPREngine`
  composites bottom-to-top; label 0 transparent; missing LUT labels get deterministic
  hashed colors. `LayerInspectorView` is native List/Form/Menu/ColorPicker with searchable
  legend, LUT import/manage, drag reorder, delete/undo. Bundled `Resources/FreeSurferColor
  LUT.txt` + `THIRD_PARTY_NOTICES.md`.
- [x] **Phase 9 — Intracranial-calcification segmentation.** ROI-box Method A (threshold
  in ROI) / Method B (grow from seed) over one configurable engine: hysteresis
  dual-threshold + 3D connected-component + brain-mask AND + min-size + Otsu. Multiple
  regions in one editable `VolumeData.labelMask` (255 = transient preview), per-label
  render via the atlas path (sagittal `maskSlice` parallelised), export as single-value
  mask or multi-value atlas NIfTI (+ FreeSurfer LUT) **written back to the original input
  grid**. Brain mask via NIfTI or FreeSurfer SynthSeg; a parcellation auto-names regions.
  UX: `roiBox` (B) + `calcBrush` (K) tools, `SegmentationBoxOverlay` with 8 grab handles
  for 3D resize, `SegmentInspectorView` tab (Layers · Segment). All mask writes on main
  then bump `segmentationRevision`. Exported `.nii.gz` reads back correctly in nibabel
  (shape, dtype, labels, zooms, sform, affine) → FreeSurfer/fsleyes-compatible.
  - **Resizable ROI box** (8 handles per MPR plane, full 3D reshape from any view; pure
    geometry `VoxelBox.handles`/`resize`/`inPlaneAxes`/`slabAxis`).
  - **SynthSeg crash hardening** (`--ct --cpu --threads 1`, clean env stripping toxic
    `PYTHON*`/`CONDA*`, signal-vs-exit reporting, stderr tail).
  - **Parameter tuning** ("box IS calcification" workflow): configurable `growMarginVoxels`
    (nil = unlimited grow, the `.growFromSeed` default); Method B auto-seeds from the box
    mean HU (stable `seedMeanHU`); Method A is a fixed 40–100 HU band; sliders avoid
    `step:` (round to 0.1).
  - **Data-loss hardening:** `reEditRegion` stashes prior index + committed coords;
    cancel/commit/4D-swap preserve regions. Region-row ellipsis Menu + right-click both
    gated during a draft. Selecting a row is a no-op while a draft is live. Brush + K gated
    on `hasSegmentation && draftRegion == nil`.
  - **Visibility toggle fix:** `segmentationAtlasColors()` returns `nil` only when no
    region/draft exists (Phase-7 demo path); when segmentation is active it returns the
    per-label table (possibly empty) so a hidden label composites nothing, not flat red.
  - **Findable SynthSeg output:** `<base>_synthseg.nii.gz` + (optional) `<base>_brainmask
    .nii.gz` beside the source (or AppSettings folder); auto-loaded as a shared
    `OverlayLayer` (FreeSurfer-LUT colored); Show-in-Finder card.
  - **Settings window (⌘,):** `AppSettings` singleton (UserDefaults), `SettingsView` TabView
    (General · FreeSurfer); `$overlayOpacity` → live re-render; `SynthSegRunner.locate`
    also consults the persisted FreeSurfer home. Entry via Settings menu, toolbar gear,
    Segment inspector.
  - **Direct (no-dialog) export + toast:** `exportSegmentation` writes to
    `AppSettings.resolveOutputDirectory` with configurable `_calcmask`/`_calcatlas`
    suffixes; success shows a `Toast` HUD with Show-in-Finder. Export blocked while a
    draft is live (`NiftiWriteError.draftActive`); region-row Re-edit/Delete gated; `writeMask`
    stages straight into `UInt8` (no ~1.4 GB Int32 intermediate).
- [x] **BIDS dataset support (PR #3).** Open a BIDS dataset folder (or any folder of
  loose NIfTI) via a sidebar navigator; `OutputLocationMode.bidsDerivatives` writes
  `derivatives/lentis/sub-XX/[ses-YY/]<datatype>/…_desc-<label>_{mask|dseg}.nii.gz` (+
  `dataset_description.json`, `_dseg.tsv`). Unified `Open…` (⌘O) accepts file or folder;
  drag-drop accepts folders. Source modality folded into `desc` so sibling-modality
  derivatives can't collide. Re-tapping the loaded row is a guarded no-op (won't wipe
  segmentation/layers); BIDS rows `.disabled` while a load is in flight (race guard); atlas
  `_dseg.tsv` writes use `try` (no silent failure).
- [x] **Segment-panel redesign (PR #4).** Empty-state overlap fix — `SegmentInspectorView
  .body` is a conditional `Group { emptyState : loadedBody }`. New `statusStrip` (Brain ·
  Regions · Export glass pills) reading existing published state. `exportedMaskURL`/
  `exportedAtlasURL`/`hasExportedSegmentation`/`invalidateSegmentationExports()` set on
  export, cleared on every voxel-content change (commit/delete/brush/reset); atlas-only
  invalidation on region rename/recolor; re-edit entry deliberately does NOT invalidate
  (cancel restores exact voxels). Compact green done-summary once a brain mask is loaded.
- [x] **Auto-update via Sparkle (PR #6, 2026-06-26).** `Package.swift` adds the Sparkle
  SPM binary target; `UpdaterController.swift` wraps `SPUStandardUpdaterController`
  (`@StateObject`, auto-check on launch, manual menu). `package_app.sh` embeds the
  framework (no XPC services — Lentis is non-sandboxed), adds `@executable_path/../
  Frameworks` rpath, bakes `SUFeedURL` + conditional `SUPublicEDKey` + auto-check/auto-
  install flags, signs component-by-component (not `--deep`). `.github/workflows/
  release.yml` signs the DMG with Ed25519 + emits `appcast.xml` (CryptoKit
  `Curve25519.Signing`, no external deps). Verified locally end-to-end: a low-version app
  auto-checked, downloaded the DMG, and `OK: EdDSA signature is correct for update`.
  Future delta updates / rich release notes deferred.
- [x] **Tool tooltips + Reset View (PR-like fast-forward merge, 2026-06-26).** Tool-
  palette hover descriptions; one-shot **Reset View** button ( Resets 3D zoom/pan, not
  just the camera). Version bumped to **2.2.0** (covering PR #8 — brush undo +
  ROI resize cursor, plus the doc cleanup / AGENTS.md compression).
- [x] **UI polish + brush undo + ROI resize cursor (PR #8, 2026-06-27).**
  - **UI polish A/B/C:** group + context-gate the left tool palette; Layers-tab empty
    state + inline Add + z-order wording; Segment tab de-emphasizes brain mask, folds
    advanced, clarifies export.
  - **Pan tool repair:** dead Pan tool fixed via absolute-coordinate deltas; greyed out
    on 3D.
  - **Brush enhancements:** size shortcuts (`-`/`=`); canvas footprint overlay; brush
    undo (one stroke = one ⌘Z) with staleness guard, sagittal footprint, B/K global
    routing, post-stroke per-voxel guard, orphaned-pre-stroke-label remap.
  - **ROI resize cursor:** directional resize cursor on ROI handle hover (corner grips
    get a diagonal cursor, edge grips an axis-aligned one); cursor stack swap invariant
    (no stuck tool cursor); corner vectors summed in full signed form.
  - **Layer list polish:** row context-menu delete + selection highlight.
  - **Brain-mask errors surfaced:** `loadBrainMask` failures now show in the UI (Codex
    P2); the tool gate is shared across tools (Codex P3).
  - **Draft-period row affordance + brush-not-selected hint.**

---

## Test data (`TestData/`)

- **Real (user-provided, gitignored):** `sub-zdr_ses-20250312_ct.nii` (CT 512×512×221),
  `sub-16309926_T1w.nii.gz` (T1 MRI), `sub-51458789_…MPRAGE_T1w.nii.gz` (445 MB).
- **Synthetic** (regenerate: `python3 scripts/gen_synthetic_nifti.py`): `synthetic_ct.nii.gz`
  (air/tissue/skull + calcification → reads as CT), `synthetic_mri.nii.gz` (non-negative →
  MRI), `synthetic_mri_4d.nii.gz` (5 timepoints), `synthetic_orient.nii.gz` (octant markers
  for orientation checks), `synthetic_calc.nii.gz` (Phase 9: tissue + dense skull shell +
  three separated calcification blobs of known HU) + `synthetic_calc_brainmask.nii.gz`
  (matching interior mask). All 64×64×48, 1 mm iso, RAS affine, origin at center.
- **Standalone reader check** (no DICOM/UI deps), fast real-data validation (entry file
  must be named `main.swift` for top-level code):
  ```bash
  swiftc -O /tmp/main.swift Sources/Lentis/NIfTI.swift Sources/Lentis/NiftiVolumeLoader.swift \
    Sources/Lentis/VolumeData.swift Sources/Lentis/Orientation.swift -o /tmp/realcheck
  ```