# Lentis — Native macOS NIFTI Brain Viewer

A SwiftUI + Metal macOS app for viewing 3D brain **NIFTI** (`.nii` / `.nii.gz`) images,
supporting **both CT and MRI**. Forked from `jnheo-md/open-dicom-viewer` (MIT) and being
converted from a DICOM viewer into a NIFTI viewer.

**Goal:** load CT/MRI NIFTI (incl. 4D), display in **neurological orientation** (patient-left =
screen-left) per the image affine, **modality-aware window/level** (CT: HU presets incl.
Brain `(0,80)`; MRI: robust auto-window), draggable crosshair linking three orthogonal views,
drag-to-open. Remove all DICOM/DCMTK/OpenJPEG deps. Keep MIT license. Leave clean seams for a
future intracranial-calcification segmentation feature (CT/HU-oriented).

This file is the working record. Update it as phases complete.

---

## Build / Test / Run

```bash
swift build                       # debug build (~20s clean; zero native/system deps)
./scripts/package_app.sh          # release build → Lentis.app + Lentis.dmg (ad-hoc signed)
swift test                        # full suite: MIXED XCTest + swift-testing
swift test --filter nifti --filter dataset   # just the NIFTI tests

# Run + auto-open a file (App.swift handles --benchmark):
open Lentis.app --args --benchmark /abs/path/to/file.nii.gz
```

- **Perf probe:** `--benchmark` writes `~/Desktop/odv_benchmark.csv` (and `[BENCH]` to stderr).
  Useful events: `scroll_main` (synchronous main-thread cost of one scroll tick — must stay sub-ms),
  `mpr_render` / `mip_render` (per-slice render ms, now off-main). Used to prove the scroll-lag fix.

- Toolchain: Swift 6.3, Xcode 26.4, macOS arm64. Bundle id `com.kalicooper.lentis`.
  **Zero native/system dependencies** — pure Swift + Metal/AppKit (DCMTK/OpenJPEG gone in Phase 3).
- `swift build` after adding a `PanelMode` case → the compiler flags every non-exhaustive
  `switch` (~10 sites). Fix each (usually mirror `.mprCoronal` or fold into a combined case).
- **Git state:** Phases 1–4 are committed on branch **`lentis-nifti-conversion`** (off upstream
  `master`); see `git log`. Not pushed (no remote configured). Real patient data
  (`TestData/sub-*`) is gitignored — only synthetic fixtures are tracked. Commit per phase going forward.

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
| `App.swift` | `@main struct LentisApp`. Menus. `--benchmark <path>` auto-open. |
| `ViewerModel.swift` (~1700 lines) | **Central `@ObservableObject` model** (was `DICOMModel`). Panels, volume cache, MPR/MIP, W/L, sync-scroll. **Crosshair (Phase 6):** `crosshairWorld` state + `setCrosshair(_:from:)` (relocates all panels through a world point). DICOM ingestion removed (Phase 3). |
| `ViewerModel+Nifti.swift` | **NIFTI orchestration**: `loadNifti`, `applyNiftiDataset`, `selectTimepoint`, `setModalityOverride`. **Modality-aware W/L (Phase 5):** `modalityDefaultWindow`/`seededWindow` (seed), `applyWindowPreset`/`applyModalityAutoWindow`/`autoWindow(for:)` (UI). |
| `WindowLevel.swift` | **`WindowPreset` + CT HU preset table** (Phase 5). Brain default `(0,80)`, Subdural/Stroke/Bone/Soft-tissue (HU). `storedWindow(slope:intercept:)` maps HU→stored (identity for direct-HU CT). Pure; no deps. |
| `NIfTI.swift` | **NIFTI-1/2 reader**. Header/endianness/4D/9 dtypes, sform/qform affine, **pure-Swift DEFLATE** (`DeflateInflater`). Zero deps. |
| `NiftiVolumeLoader.swift` | **`NiftiDataset`**: modality detection, Int16 quantization, percentile auto-window. **`makeVolume` reorients to canonical RAS** (Phase 4) — folds the relabel/flip into the quantization pass. |
| `Orientation.swift` | **Single source of orientation truth** (Phase 4). `anatomicalDirection(of:)` (RAS labels) + `closestCanonicalReorientation(affine:)` → `CanonicalReorientation` (axis permutation + flips, lossless, invertible). Pure; no deps. |
| `VolumeData.swift` | 3D Int16 voxel buffer + affine. **Two inits**: direction-cosine and full-affine (NIFTI). For NIFTI `voxelToWorldMatrix` is the **canonical RAS** affine; `originalAffine` + `reorientation` are retained for mask write-back. |
| `MPREngine.swift` | CPU slice extraction (`axialSlice`/`sagittalSlice`/`coronalSlice`) + `renderSlice(ww:wc:)` (CPU W/L). **`planeGeometry(mode:sliceIndex:)` is the one place** that defines each plane's neurological flips + display dirs (Phase 4); extractors + cross-ref metadata both read it. **Crosshair geometry (Phase 6):** `PlaneGeometry.world(col:row:)`/`pixel(of:)` (exact-inverse pixel↔world) + `orthogonalSliceIndex(for:containing:)` (world→slice index). (`VolumeBuilder` removed in Phase 3.) |
| `CrossReferenceOverlay.swift` | **3D crosshair overlay (Phase 6, rewritten).** Draws two lines + center dot through `model.crosshairWorld`'s in-plane projection, on MPR panels only; bridges raw→display pixels then reuses the image's `pixelToScreen` transform. `PanelState.displayedPlaneGeometry` helper. (Replaced the old `computeCrossReference` plane-intersection lines.) |
| `MetalVolumeRenderer.swift` | Metal compute, **MIP/MinIP/Average only**. Inline shader strings. Texture `.r16Sint`. W/L on raw stored values. |
| `MultiPanelContainer.swift` (~2000 lines) | Multi-panel views, gestures, overlays, cursor readout, **4D selector**, `OrientationLabelsOverlay` (**RAS-aware** since Phase 4). **Crosshair (Phase 6):** Select-tool `mouseDown`/`mouseDragged` → `crosshairWorld(at:)` → `model.setCrosshair`. |
| `PanelState.swift` | Per-panel state. `PanelMode = .slice2D/.mprAxial/.mprSagittal/.mprCoronal/.mip`. `isMPR` helper. `rescaleSlope/Intercept`, `valueUnitLabel`. (`.slice2D` now inert — NIFTI uses `.mprAxial`.) |
| `ContentView.swift` | Root split view: sidebar (series list) + multi-panel detail. (Legacy single-view subtree deleted in Phase 3.) |

---

## Data & rendering pipeline (must understand)

1. **2D slice rendering is CPU**, not GPU. Axial/sagittal/coronal go through
   `MPREngine.renderSlice` (Swift per-pixel W/L loop); **Metal is used only for MIP**.
   **Extraction + render + NSImage build run on the panel's serial background queue
   (`loadMPRSlice` → `panel.loadingQueue`) and are coalesced** — each navigation
   `cancelAllOperations()` + enqueues, and the main-thread apply drops results whose
   `mprSliceIndex`/`panelMode` no longer match. So fast scrubbing only pays for the in-flight render
   plus the latest target, and the main thread never blocks. **MIP is the same** (`loadMIPForPanel`):
   its GPU `renderProjection` (`commandBuffer.waitUntilCompleted()` + readback) also runs on the
   background queue — that synchronous GPU wait on the main thread was what made the **quad MPR +
   sync-scroll** layout lag (`syncScrollFromPanel` re-renders the MIP panel every tick). **This (not GPU
   W/L) fixed laggy scrolling on the 344×1024×1024 / 721 MB MPRAGE**, whose long plane is a full
   1024×1024 **megapixel** slice; measured per-tick main-thread cost dropped ~15–25 ms → 0.3 ms.
   W/L drag is throttled to 60 Hz and re-renders from the cached slice `rawPixelData` (still on the
   main thread — move async too if it bites on huge volumes). The brief's "windowing = GPU uniform
   only" rule is **still NOT met for slices** — the GPU slice-W/L move was **deferred** (the W/L
   *arithmetic* is cheap; per-slice cost is dominated by extraction + the NSImage alloc, which a
   W/L-only shader wouldn't touch, and a full 3D-texture sample risks the canonical-RAS orientation;
   `MPREngine` stays the single source). Revisit when a live MTKView / mask overlay needs it. Clean
   seam: keep slice *extraction* (the oriented Int16 buffer) in `MPREngine`, upload it to a 2D
   `.r16Sint` input texture, and do W/L in a trivial shader → NSImage — **no flip logic in MSL**, so
   tested orientation can't drift. (`MetalVolumeRenderer` already has the texture + in-shader W/L for MIP.)
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
   to `.mprAxial` → `loadMPRSlice` → `MPREngine.axialSlice` + `renderSlice`. 4D switch replaces the
   cached volume under the same key and re-renders. `VolumeData.seriesUID` is distinct per timepoint
   (for future Metal re-upload); the **cache key** is stable.
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
   MPR). The per-panel `PanelAdjustmentToolbar` shows a CT preset menu vs an MRI "Auto" button by
   `effectiveModality`; presets apply to all panels showing the series (`applyWindowPreset`).
7. **Cursor readout:** `cursorHU = stored * panel.rescaleSlope + panel.rescaleIntercept`, label
   `panel.valueUnitLabel` ("HU" for CT, "Val" for MRI). (On-screen overlay needs a real
   NSTrackingArea mouse event — synthetic computer-use moves may not trigger it.)

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
  dependency-free and correct. Do NOT "simplify" back to the Compression framework.
- **`Data.withUnsafeBytes { $0[0] }` footgun.** The untyped closure infers `UnsafePointer<Int>`,
  so `$0[0]` reads 8 bytes as an `Int`. Always type it: `{ (raw: UnsafeRawBufferPointer) in raw[0] }`.
- **Adding a `PanelMode` case** breaks several exhaustive switches across `ViewerModel.swift`. Build,
  read the compiler notes, add the case (mirror coronal / use `vol.depth`).
- **Orientation lives in ONE place: `MPREngine.planeGeometry`** (Phase 4). The render chain maps
  **buffer row 0 → screen top, col 0 → left** (CGImage row 0 = top; NSImageView draws upright) —
  confirmed on `synthetic_orient` octant markers. Volumes are already canonical RAS (i→R, j→A, k→S),
  so each plane uses a *fixed* flip; do **not** reintroduce per-file/`sliceDirection` heuristics. If
  you add or change a plane/flip, edit `planeGeometry` only — extractors, cross-ref metadata, and
  labels all read it, and the corner-orientation tests in `MPREngineTests` will catch a sign error.
- **Pure-Swift inflate is bit-by-bit** → ~1.5 s for a 35 MB `.nii.gz`, ~20 s for the 445 MB MPRAGE
  (background thread, OK for now). Optimize with table-driven Huffman if it bites.
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

Ordered roughly by priority. None block the build or tests (52 green); these are quality/perf debt.

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
2. **W/L drag re-render is still synchronous on the main thread.** `adjustWindowLevelForPanel`
   re-renders from the cached slice `rawPixelData` (megapixel W/L loop), throttled to 60 Hz. On the
   721 MB MPRAGE a hard W/L drag can feel heavy. Fix = route it through the same async+coalesced path
   as `loadMPRSlice` (the slice is already extracted, so it's render-only). **Note:** `MPREngine.renderSlice`
   itself is also optimizable — the scalar `Double` W/L loop is ~3 ms for a 1 MP slice; a Float +
   precomputed-reciprocal rewrite measured **3.0 → 1.9 ms serial / 0.6 ms parallel** (≈±1 gray-level
   delta from the reassociated arithmetic, imperceptible). Deferred from the scroll fix (extraction was
   the bottleneck; 213 slices/s already exceeds refresh) — fold in here when tackling the W/L drag, since
   both share `renderSlice`.
3. **GPU slice W/L deferred** (the brief's "windowing = GPU uniform only" rule). Decided against for
   now: per-slice cost is dominated by extraction + NSImage alloc, *not* the W/L arithmetic, and a full
   3D-texture sample risks the canonical-RAS orientation (which lives only in `MPREngine.planeGeometry`).
   Clean re-entry seam documented in *Data & rendering pipeline* §1. Revisit for a live MTKView / mask overlay.
4. **[RESOLVED — Phase 6] Quad-MPR cross-panel linkage is now the 3D crosshair.** Click/drag sets
   `crosshairWorld`; `ViewerModel.setCrosshair` relocates each panel via `MPREngine.orthogonalSliceIndex`
   + the existing async `loadMPRSlice`/`loadMIPForPanel`. The old z-only `syncScrollFromPanel` proportional
   mapping is no longer the cross-panel mechanism (it remains only for the mouse-wheel group-scroll path).
   Note the "stuck orthogonal panels" complaint was partly a misread: scrolling S *should not* change which
   sagittal/coronal slice is shown — what was missing (and is now drawn) is the moving crosshair line.
5. **`--benchmark` instrumentation left in** (`scroll_main`, `mpr_render`; `mip_render` pre-existing).
   Gated behind `--benchmark` so it's inert in normal runs, but in benchmark mode it logs to
   `~/Desktop/odv_benchmark.csv` per scroll tick (each `log()` also takes a `task_info` memory snapshot).
   Keep as a perf probe, or strip `scroll_main`/`mpr_render` once perf work settles.
6. **Cosmetic debt (deferred since Phase 3):** stale `// OpenDicomViewer` file headers;
   `PanelDICOMInteractView` / `PanelInteractiveDICOMView` names; the inert `.slice2D` `PanelMode` case;
   vestigial `ImageContext` struct + `ImageSeries.images` (NIfTI series carry an empty `images` stub).

---

## Phase status & roadmap

> **▶ RESUME POINT — Phases 1–6 complete & committed** on branch `lentis-nifti-conversion`
> (not pushed; no remote). The app builds with **zero native deps**, runs, and renders real CT/MRI
> in correct **neurological** orientation with **modality-aware window/level** and **3D crosshair
> linkage**. `swift test` green (**95**: 43 XCTest + 52 swift-testing; the old doc "52" was only the
> swift-testing line). **Next: Phase 7 — UI polish + segmentation seams.**
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
  `DICOMModel` & test-target name intentionally kept. Builds & runs as `Lentis.app`.
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
  synthetic CT (axial + scroll) and real T1 MRI (auto-window). Remaining cosmetic debt (defer):
  stale `// OpenDicomViewer` file headers, `PanelInteractive/DICOMInteractView` names, the inert
  `.slice2D` case + vestigial `ImageSeries.images`/`ImageContext` struct.
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
  proper neurological axial. Cosmetic debt still deferred: `// OpenDicomViewer` headers,
  `PanelDICOMInteractView` names, inert `.slice2D`, vestigial `ImageContext`/`ImageSeries.images`.
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
- [ ] **Phase 7 — UI polish + segmentation seams.** Fix 4D-selector overlap with the "Auto" button;
  modality badge; orientation labels; spacing. Seams (don't implement seg now): same-grid
  mask/label volume in `VolumeData`; Metal mask overlay (color+alpha); keep Eraser/ROI; preserve
  affine for mask write-back.

---

## Test data (`TestData/`)

- Real (user-provided): `sub-zdr_ses-20250312_ct.nii` (CT 512×512×221),
  `sub-16309926_T1w.nii.gz` (T1 MRI), `sub-51458789_…MPRAGE_T1w.nii.gz` (445 MB).
- Synthetic (regenerate: `python3 scripts/gen_synthetic_nifti.py`): `synthetic_ct.nii.gz` (air/tissue/skull +
  calcification blob → reads as CT), `synthetic_mri.nii.gz` (non-negative → MRI),
  `synthetic_mri_4d.nii.gz` (5 timepoints), `synthetic_orient.nii.gz` (octant markers for
  orientation checks). All 64×64×48, 1 mm iso, RAS affine, origin at center.
- Standalone reader check (no DICOM/UI deps), fast real-data validation (entry file must be named
  `main.swift` for top-level code):
  ```bash
  swiftc -O /tmp/main.swift Sources/Lentis/NIfTI.swift Sources/Lentis/NiftiVolumeLoader.swift \
    Sources/Lentis/VolumeData.swift Sources/Lentis/Orientation.swift -o /tmp/realcheck
  ```
