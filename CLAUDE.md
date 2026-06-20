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
swift build                       # debug build (first run slow: compiles DCMTK .mm)
./scripts/package_app.sh          # release build → Lentis.app + Lentis.dmg (ad-hoc signed)
swift test                        # full suite: MIXED XCTest + swift-testing
swift test --filter nifti --filter dataset   # just the NIFTI tests

# Run + auto-open a file (App.swift handles --benchmark):
open Lentis.app --args --benchmark /abs/path/to/file.nii.gz
```

- Toolchain: Swift 6.3, Xcode 26.4, macOS arm64. Bundle id `com.kalicooper.lentis`.
- `swift build` after adding a `PanelMode` case → the compiler flags every non-exhaustive
  `switch` (~10 sites). Fix each (usually mirror `.mprCoronal` or fold into a combined case).
- Linker warns "built for newer macOS" from the prebuilt static libs — harmless.
- **Git state:** Phases 1–2 are committed on branch **`lentis-nifti-conversion`** (off upstream
  `master`); see `git log`. Not pushed (no remote configured). Real patient data
  (`TestData/sub-*`) is gitignored — only synthetic fixtures are tracked. Commit per phase going forward.

---

## Repository layout

- SPM package/product/executable target = **`Lentis`**, sources in `Sources/Lentis/`.
- Test target still named `OpenDicomViewerTests` (`Tests/OpenDicomViewerTests/`), uses
  `@testable import Lentis`. (Rename deferred to Phase 3.)
- `DCMTKWrapper/` target = Obj-C++ wrapper linking ~30 DCMTK + OpenJPEG **static libs in `libs/`**
  (~40 MB). **To be deleted in Phase 3.**
- `scripts/package_app.sh` builds the bundle; still copies `libs/.../dicom.dic` (drop in Phase 3).
- `TestData/` holds real + synthetic NIFTI (see bottom). Gitignored: `.build/`, `*.app`, `*.dmg`.

### Key source files
| File | Role |
|---|---|
| `App.swift` | `@main struct LentisApp`. Menus. `--benchmark <path>` auto-open. |
| `DICOMModel.swift` (~4400 lines) | **Central `@ObservableObject` model.** Still named `DICOMModel` (Phase 3 rename). Loading, panels, volume cache, MPR/MIP, W/L, sync-scroll. |
| `DICOMModel+Nifti.swift` | **NIFTI orchestration** (added): `loadNifti`, `applyNiftiDataset`, `selectTimepoint`, `setModalityOverride`. |
| `NIfTI.swift` | **NIFTI-1/2 reader** (added). Header/endianness/4D/9 dtypes, sform/qform affine, **pure-Swift DEFLATE** (`DeflateInflater`). Zero deps. |
| `NiftiVolumeLoader.swift` | **`NiftiDataset`** (added): modality detection, Int16 quantization, percentile auto-window. |
| `VolumeData.swift` | 3D Int16 voxel buffer + affine. **Two inits**: direction-cosine (DICOM) and full-affine (NIFTI, preserves matrix incl. handedness). |
| `MPREngine.swift` | CPU slice extraction (`axialSlice`/`sagittalSlice`/`coronalSlice`) + `renderSlice(ww:wc:)` (CPU W/L). `VolumeBuilder.build` (DICOM→VolumeData, Phase 3 removal). |
| `MetalVolumeRenderer.swift` | Metal compute, **MIP/MinIP/Average only**. Inline shader strings. Texture `.r16Sint`. W/L on raw stored values. |
| `MultiPanelContainer.swift` (~2000 lines) | Multi-panel views, gestures, overlays, cursor readout, **4D selector** (added). |
| `PanelState.swift` | Per-panel state. `PanelMode = .slice2D/.mprAxial/.mprSagittal/.mprCoronal/.mip` (`.mprAxial` added). `isMPR` helper. `rescaleSlope/Intercept`, `valueUnitLabel` (added). |
| `SimpleDICOM.swift`, `MultiFrameDecoder.swift`, `TagView.swift` | DICOM-specific. **Phase 3 removal.** |

---

## Data & rendering pipeline (must understand)

1. **2D slice rendering is CPU**, not GPU. Axial/sagittal/coronal go through
   `MPREngine.renderSlice` (Swift per-pixel W/L loop) or DCMTK; **Metal is used only for MIP**.
   W/L drag is throttled to 60 Hz. The brief's "windowing = GPU uniform only" rule is **NOT yet
   met for slices** → that is the Phase 5 job (`MetalVolumeRenderer` already has the texture +
   in-shader W/L for MIP; extend it to render ortho slices → NSImage, or live MTKView).
2. **W/L units = RAW STORED Int16 values.** The shader/CPU window on stored voxels; `scl`/rescale
   is NOT applied in the window math. So presets & auto-window are expressed in **stored units**.
3. **VolumeData stores Int16.** NIFTI float32/uint16 are **quantized to Int16** by `NiftiDataset`,
   with the quantization folded into `VolumeData.rescaleSlope/Intercept` so `calibratedValue()`
   reconstructs the true value. **CT stores HU directly** (slope 1, intercept 0) when the range
   fits Int16 and spans ≥256 levels → **HU presets need no conversion**. Float data with small
   range is scaled across ~64000 levels. 4D quantization uses the **global** range over all
   timepoints (so every volume displays on one scale).
4. **Volume display path for NIFTI:** `loadNifti` → `NiftiDataset` → `makeVolume(t)` →
   `registerStandaloneVolume(volume, cacheKey: dataset.seriesID, …)` (caches under a **stable
   key** + appends a stub `DicomSeries` with empty `images`) → panel set to `.mprAxial` →
   `loadMPRSlice` → `MPREngine.axialSlice` + `renderSlice`. 4D switch replaces the cached volume
   under the same key and re-renders. `VolumeData.seriesUID` is distinct per timepoint (for future
   Metal re-upload); the **cache key** is stable.
5. **Modality** lives on the model: `niftiDataset.detectedModality`, `modalityOverride`,
   `effectiveModality`. Detection heuristic: `min ≤ -500 && fraction(v < -200) ≥ 2%` ⇒ CT.
6. **Cursor readout:** `cursorHU = stored * panel.rescaleSlope + panel.rescaleIntercept`, label
   `panel.valueUnitLabel` ("HU" for CT, "Val" for MRI). (On-screen overlay needs a real
   NSTrackingArea mouse event — synthetic computer-use moves may not trigger it.)

---

## Critical gotchas (hard-won)

- **gzip + DCMTK zlib interposition.** Apple `Compression` `COMPRESSION_ZLIB` *decode* is broken
  inside the DCMTK-linked binary (DCMTK's bundled static zlib `inflate` interposes). The fix is a
  **pure-Swift DEFLATE decoder** (`DeflateInflater` in `NIfTI.swift`) — keep it even after Phase 3
  removes DCMTK (validated vs. real Python gzip: small/all-zero/70 KB multi-block all match).
  Do NOT "simplify" back to the Compression framework.
- **`Data.withUnsafeBytes { $0[0] }` footgun.** The untyped closure infers `UnsafePointer<Int>`,
  so `$0[0]` reads 8 bytes as an `Int`. Always type it: `{ (raw: UnsafeRawBufferPointer) in raw[0] }`.
- **Adding a `PanelMode` case** breaks ~10 exhaustive switches across `DICOMModel.swift`. Build,
  read the compiler notes, add the case (mirror coronal / use `vol.depth`).
- **Pure-Swift inflate is bit-by-bit** → ~1.5 s for a 35 MB `.nii.gz`, ~20 s for the 445 MB MPRAGE
  (background thread, OK for now). Optimize with table-driven Huffman if it bites.
- **RTK shell proxy** (user's global `~/.claude`) rewrites `grep`→`rg` and can mangle
  `find … $(...)` / regex alternation. Prefer `rg`-native syntax or absolute `/usr/bin/...` paths.

---

## Phase status & roadmap

- [x] **Phase 1 — Rebrand to Lentis.** SPM/target/dir/app-struct renamed; menus/About/Help show
  Lentis; `package_app.sh` + bundle id updated; `UpdateChecker` removed (phoned home to upstream).
  `DICOMModel` & test-target name intentionally kept. Builds & runs as `Lentis.app`.
- [x] **Phase 2 — NIFTI loader (CT+MRI) + open + first render.** Reader/converter/orchestration
  added (above). Verified on **real CT + real T1 MRI** (correct modality, affine, HU/intensity) and
  via GUI (CT loads/renders axial/scrolls; 4D MRI loads with auto-window + timepoint selector).
  13 NIFTI unit tests + full suite green.
- [ ] **Phase 3 — Remove DICOM/DCMTK/OpenJPEG.** Delete `SimpleDICOM.swift`,
  `MultiFrameDecoder.swift`, `TagView.swift`/tag inspector, `Sources/DCMTKWrapper/`, `libs/`, and
  DCMTK-dependent tests (`SimpleDICOMTests`, `MultiFrameCineTests`, parts of `MPREngineTests`).
  Strip DCMTK from `DICOMModel` (gut the DICOM file-loading + `VolumeBuilder.build`; keep the
  VolumeData/MPR rendering path); drop the `DCMTKWrapper` target + linkage from `Package.swift`;
  drop `dicom.dic` copy from `package_app.sh`. Rename `DICOMModel`→neutral (e.g. `ViewerModel`),
  `DicomSeries`→`ImageSeries`, drop `dcmtkImage`. **Work incrementally, stay compilable.** Accept:
  `package_app.sh` builds with NO static libs; NIFTI display unaffected.
- [ ] **Phase 4 — Neurological orientation + tri-view.** Orient axial/sagittal/coronal from the
  affine (patient-left = screen-left; currently **radiological**, R on screen-left), L/R/A/P/S/I
  labels. Centralize voxel↔world↔screen transforms in one place. NIFTI affine is **RAS**; legacy
  world space is **LPS** — reconcile. Wire `setupMPRLayout` to use `.mprAxial` for the tri-view.
  Verify with `TestData/synthetic_orient.nii.gz` (known octant markers).
- [ ] **Phase 5 — Modality-aware W/L (GPU).** Move 2D-slice W/L into a Metal shader (uniform-driven
  from raw voxels) — fixes the CPU-render deviation. CT: extensible HU preset table incl.
  **Brain `(0,80)`** (low/high), bone/subdural/stroke; instant. MRI: percentile auto-window
  (`NiftiDataset.suggestedWindow` exists) + manual drag. Add CT/MRI toggle (`setModalityOverride`
  exists). UI switches preset-vs-auto by `effectiveModality`.
- [ ] **Phase 6 — Crosshair drag linkage.** Click/drag sets crosshair **world** coord; all three
  views relocate + draw crosshair lines. Build on `CrossReferenceOverlay` + sync-scroll.
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
- Standalone reader check (no DICOM/UI deps), fast real-data validation:
  ```bash
  swiftc -O /tmp/main.swift Sources/Lentis/NIfTI.swift \
    Sources/Lentis/NiftiVolumeLoader.swift Sources/Lentis/VolumeData.swift -o /tmp/realcheck
  ```
