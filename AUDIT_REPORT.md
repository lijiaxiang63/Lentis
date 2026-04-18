# OpenDicomViewer Pre-Release Code Audit Report

**Date:** 2026-04-18
**Audited by:** 20 specialized review agents (parallel analysis)
**Codebase:** ~12,000 lines across Swift, Objective-C++, C++, Metal shaders

---

## Executive Summary

20 specialized agents reviewed the entire codebase in parallel, each focusing on a different domain (memory, concurrency, security, DICOM parsing, Metal GPU, overlays, etc.). Findings confirmed by multiple independent agents are marked with corroboration count.

**Totals:** 5 CRITICAL, 10 HIGH, 22 MEDIUM, 11 LOW

---

## CRITICAL (Must Fix Before Release)

### C1. Integer Overflow -> Buffer Overflow in JPEG2000 Decoding (RCE Risk)
- **Confirmed by:** 3 agents (C++ Wrapper, Security, Rendering)
- **File:** `Sources/DCMTKWrapper/DCMTKHelper.mm` lines 187, 492, 514
- **Issue:** `imgWidth * imgHeight * numComps` can overflow size_t. malloc allocates tiny buffer, subsequent loops write out of bounds.
- **Impact:** A malicious DICOM file could trigger remote code execution.
- **Fix:** Add overflow-checked multiplication before malloc; validate decoded dimensions against DICOM header; add maximum dimension limits.

### C2. Cine Timer Leak on Panel Removal
- **Confirmed by:** 4 agents (Cine, Multi-panel, App Lifecycle, Memory)
- **File:** `Sources/OpenDicomViewer/DICOMModel.swift` lines 2429-2433
- **Issue:** `setLayout()` calls `panel.reset()` but never `stopCinePlayback()`. Orphaned Timer objects run indefinitely.
- **Also missing:** No timer cleanup in `deinit` (line 345-349).
- **Impact:** CPU and memory leak; timers reference destroyed panels.
- **Fix:** Call `stopCinePlayback(panel)` before removing panels in `setLayout()`; add timer cleanup to `deinit`.

### C3. Potential Deadlock: `DispatchQueue.main.sync` from Background Thread
- **Confirmed by:** 2 agents (Concurrency, App Lifecycle)
- **File:** `Sources/OpenDicomViewer/DICOMModel.swift` line 891
- **Issue:** Synchronous main-thread dispatch from `loadingQueue`. If main thread is blocked waiting for this operation, app deadlocks.
- **Fix:** Replace with `DispatchQueue.main.async` or restructure data access pattern.

### C4. Division by Zero in Metal Shader (Ray-AABB Intersection)
- **Confirmed by:** 1 agent (Metal)
- **File:** `Sources/OpenDicomViewer/MetalVolumeRenderer.swift` line 272
- **Issue:** `float3 invDir = 1.0 / rayDir` with no zero check. Rays parallel to volume faces produce inf/-inf.
- **Fix:** Clamp rayDir components to minimum epsilon before division.

### C5. Division by Zero in `renderImage` when `windowWidth=0`
- **Confirmed by:** 2 agents (Rendering, Error Handling)
- **File:** `Sources/OpenDicomViewer/DICOMModel.swift` lines 1603, 1625, 1639
- **Issue:** `(val - windowBottom) / w * 255.0` with no guard on `w` being zero.
- **Fix:** Guard `windowWidth > 0` at function entry; clamp to minimum value.

---

## HIGH (Should Fix Before Release)

### H1. `screenToPixel`/`pixelToScreen` Are NOT Exact Inverses
- **Confirmed by:** 2 agents (Overlay Math, Rendering)
- **Files:** `MultiPanelContainer.swift` lines 601-631 (screenToPixel), `CrossReferenceOverlay.swift` lines 78-125 (pixelToScreen)
- **Issue:** CALayer transform decomposition extracts only m11,m41,m42 from complex matrix. Three separate pixelToScreen implementations exist.
- **Impact:** Annotations, rulers, ROIs misaligned after rotation/flip at non-1.0 zoom.

### H2. W/L Completely Bypassed During Cine Playback
- **Confirmed by:** 2 agents (Cine, SwiftUI State)
- **File:** `MultiPanelContainer.swift` line 341
- **Issue:** `guard !panel.isPlaying else { return }` skips all filter application. Frames rendered raw to CALayer.
- **Impact:** Users cannot adjust W/L during playback.

### H3. ROI Statistics Ignore Display Scaling in MPR Views
- **Confirmed by:** 2 agents (Overlay Math, Rendering)
- **File:** `DICOMModel.swift` lines 3348-3351
- **Issue:** ROI rect in display coordinates clipped against raw pixel dimensions. For non-isotropic voxels, statistics computed on wrong region.

### H4. Unprotected Dictionary Access from Multiple Threads
- **Confirmed by:** 2 agents (Concurrency, App Lifecycle)
- **File:** `DICOMModel.swift` — `multiFrameDecoders`, `volumeCache`, `imagePixelMeta`
- **Issue:** TOCTOU race conditions; potential crash from concurrent dictionary mutation.

### H5. HighBit Ignored; YBR/PALETTE COLOR Not Handled
- **Confirmed by:** 3 agents (DICOM Parsing, Rendering, Special DICOM)
- **File:** `DICOMModel.swift` lines 1469-1480
- **Issue:** HighBit (0028,0102) never extracted. 12-bit data in 16-bit allocation not properly masked. YBR treated as grayscale.

### H6. Multi-Frame Decoder Assumes JPEG Encapsulation Only
- **Confirmed by:** 2 agents (Special DICOM, DICOM Parsing)
- **File:** `MultiFrameDecoder.swift` lines 296-318
- **Issue:** Only looks for Item tags (FFFE,E000). Raw and RLE multi-frame files fail.

### H7. Unbounded Cache/Dictionary Growth
- **Confirmed by:** 2 agents (Memory, File I/O)
- **File:** `DICOMModel.swift` — `imageCacheParams`, `imagePixelMeta`, `seriesThumbnails`, `volumeCache`, `multiFrameDecoders`
- **Issue:** Plain dictionaries never cleared; memory grows indefinitely with extended use.

### H8. Predictable Temp File Path — Symlink Attack
- **Confirmed by:** 2 agents (Security, File I/O)
- **File:** `MultiFrameDecoder.swift` line 14
- **Issue:** Hardcoded `/tmp/odv_cine_debug.log`. Race condition; no permission control.

### H9. Fullscreen Panel ID Not Cleared on Layout Shrink
- **Confirmed by:** 2 agents (Multi-panel, App Lifecycle)
- **File:** `DICOMModel.swift` lines 2415-2440
- **Issue:** `fullscreenPanelID` not validated after panel removal. Can reference destroyed panel.

### H10. Pixel Spacing Axis Order Confusion
- **Confirmed by:** 1 agent (Overlay Math) — HIGH confidence
- **File:** `MultiPanelContainer.swift` lines 1159-1162
- **Issue:** `ps.0` (row spacing) multiplies `col` vector and vice versa. Patient coordinate calculation may be systematically incorrect.

---

## MEDIUM (Should Address, Low Breakage Risk)

### M1. Dual state management (DICOMModel + PanelState) sync gaps
- **File:** `DICOMModel.swift` lines 2221-2261

### M2. Nested `DispatchQueue.main.async` without `[weak self]`
- **File:** `DICOMModel.swift` lines 808-815

### M3. `panel.image = nil` skips `setDisplayImage()` — stale display dimensions
- **File:** `DICOMModel.swift` line 2230

### M4. NSLock without defer/withLock — deadlock if exception between lock/unlock
- **File:** `DICOMModel.swift` lines 790-802

### M5. Slab MIP centering uses mixed coordinate spaces
- **File:** `MetalVolumeRenderer.swift` lines 329-333

### M6. Metal: synchronous GPU wait blocks main thread
- **File:** `MetalVolumeRenderer.swift` lines 185-186

### M7. Metal: output texture creation failure not null-checked
- **File:** `MetalVolumeRenderer.swift` line 139

### M8. Metal: pixel buffer allocated on stack every frame (~4MB)
- **File:** `MetalVolumeRenderer.swift` lines 201-211

### M9. Update checker URL from JSON opened without validation
- **File:** `UpdateChecker.swift` lines 84-94

### M10. `setenv("DCMDICTPATH")` not thread-safe
- **File:** `DCMTKHelper.mm` line 47

### M11. OpenJPEG memory stream offset overflow
- **File:** `DCMTKHelper.mm` lines 275, 285

### M12. Force unwrap of `imagePosition` in MPREngine
- **File:** `MPREngine.swift` line 154

### M13. FileHandle not closed on error path (no defer)
- **File:** `DICOMModel.swift` lines 849-851

### M14. Scroll accumulator reset logic edge case
- **File:** `MultiPanelContainer.swift` lines 838-840

### M15. Drag state persists across panel switches
- **File:** `MultiPanelContainer.swift` lines 352-358

### M16. Menu items never disabled — all always clickable
- **File:** `App.swift` lines 48-164

### M17. CI missing native dependency setup
- **File:** `.github/workflows/ci.yml`

### M18. Two build scripts with inconsistent Info.plist / version strings
- **File:** `scripts/`

### M19. `lazy var metalRenderer` not thread-safe
- **File:** `DICOMModel.swift` line 309

### M20. `seriesStates` W/L persistence ignores panel mode (MPR vs 2D)
- **File:** `DICOMModel.swift` line 3199

### M21. No memory pressure notification handling during cine playback
- **File:** `MultiFrameDecoder.swift`

### M22. Silent failures throughout — ~40+ catch blocks swallow errors
- **File:** Multiple files

---

## LOW / Enhancement Notes (Defer — Risk of Breakage)

### L1. No DICOMDIR support (design decision)
### L2. No "Open Recent" menu (UX enhancement)
### L3. No app state restoration on relaunch (UX enhancement)
### L4. Test coverage ~30-35% (grade D+) — core pipeline untested
### L5. Cine tests skip in CI (fixture-dependent) — false green
### L6. 8 navigation methods with mixed naming (code quality)
### L7. Code duplication (histogram, min/max, auto W/L)
### L8. Potential dead code: model-level `adjustWindowLevel()`
### L9. Bare letter keys (1-4) could conflict with text input
### L10. Escape doesn't clear in-progress ruler/angle annotations
### L11. Architecture hardcoded to arm64 only (intentional)

---

## Cross-Validation Summary

| Finding | Agents Confirming |
|---------|:-:|
| Cine timer leak on panel removal | 4 |
| Integer overflow in JPEG2000 decoding | 3 |
| HighBit ignored / YBR not handled | 3 |
| Deadlock risk (main.sync from background) | 2 |
| W/L bypassed during playback | 2 |
| ROI ignores display scaling | 2 |
| screenToPixel/pixelToScreen mismatch | 2 |
| Unprotected dictionary access | 2 |
| Unbounded cache growth | 2 |
| Temp file symlink attack | 2 |
| Fullscreen ID not cleared | 2 |
| Division by zero in renderImage | 2 |
