// SegmentationModelTests.swift
// Lentis Tests
//
// Phase 9 — multi-region lifecycle on ViewerModel: begin → set box → live
// preview (label 255) → commit (real label) → multiple regions at distinct
// labels → delete clears voxels → re-edit pulls a region back to a draft. Also
// the per-label color table and the preview-restores-committed-labels contract.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class SegmentationModelTests: XCTestCase {

    private func makeCTVolume(_ w: Int, _ h: Int, _ d: Int, _ assign: (Int, Int, Int) -> Int16?) -> VolumeData {
        let count = w * h * d
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w { buf[z * w * h + y * w + x] = assign(x, y, z) ?? 40 }
            }
        }
        return VolumeData(
            voxels: buf, width: w, height: h, depth: d,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: SIMD3(0, 0, 0),
            rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
            rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "seg-model")
    }

    private func inCube(_ x: Int, _ y: Int, _ z: Int, _ r: Range<Int>) -> Bool {
        r.contains(x) && r.contains(y) && r.contains(z)
    }

    /// Build a model with a single registered NIfTI volume carrying one calc cube.
    private func makeModel(blob: Range<Int> = 18..<23) -> (ViewerModel, VolumeData) {
        let vol = makeCTVolume(40, 40, 40) { x, y, z in inCube(x, y, z, blob) ? 400 : nil }
        let model = ViewerModel()
        let idx = model.registerStandaloneVolume(vol, cacheKey: "seg", description: "seg")
        model.niftiSeriesIndex = idx
        return (model, vol)
    }

    private func count(_ mask: LabelVolume?, label: UInt8) -> Int {
        guard let mask else { return 0 }
        var n = 0
        for v in mask.labels where v == label { n += 1 }
        return n
    }

    func testPreviewThenCommitPaintsRealLabel() {
        let (model, vol) = makeModel()
        model.beginRegion(method: .thresholdInROI)
        guard let draft = model.draftRegion else { return XCTFail("no draft") }
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))

        XCTAssertEqual(draft.previewVoxelCount, 125, "preview is the 5³ calc cube")
        XCTAssertEqual(count(vol.labelMask, label: ViewerModel.calcPreviewLabel), 125, "preview painted as label 255")
        XCTAssertEqual(count(vol.labelMask, label: draft.label), 0, "real label not yet written")

        let label = draft.label
        model.commitActiveRegion()
        XCTAssertNil(model.draftRegion)
        XCTAssertEqual(model.calcRegions.count, 1)
        XCTAssertEqual(model.calcRegions.first?.voxelCount, 125)
        XCTAssertEqual(count(vol.labelMask, label: label), 125, "committed as the real label")
        XCTAssertEqual(count(vol.labelMask, label: ViewerModel.calcPreviewLabel), 0, "no preview left")
    }

    func testMultipleRegionsGetDistinctLabels() {
        // Two separate calc cubes; one region around each.
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            if inCube(x, y, z, 8..<12) { return 400 }
            if inCube(x, y, z, 28..<32) { return 400 }
            return nil
        }
        let model = ViewerModel()
        let idx = model.registerStandaloneVolume(vol, cacheKey: "seg", description: "seg")
        model.niftiSeriesIndex = idx

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 6..<14, yRange: 6..<14, zRange: 6..<14))
        let label1 = model.draftRegion!.label
        model.commitActiveRegion()

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 26..<34, yRange: 26..<34, zRange: 26..<34))
        let label2 = model.draftRegion!.label
        model.commitActiveRegion()

        XCTAssertEqual(model.calcRegions.count, 2)
        XCTAssertNotEqual(label1, label2, "regions occupy distinct label values")
        XCTAssertEqual(count(vol.labelMask, label: label1), 4 * 4 * 4)
        XCTAssertEqual(count(vol.labelMask, label: label2), 4 * 4 * 4)

        // Color table maps each visible region's label to its color.
        let table = model.calcMaskColorTable()
        XCTAssertNotNil(table[Int32(label1)])
        XCTAssertNotNil(table[Int32(label2)])
    }

    func testDeleteRegionClearsVoxels() {
        let (model, vol) = makeModel()
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        let label = model.draftRegion!.label
        model.commitActiveRegion()
        let id = model.calcRegions.first!.id

        model.deleteRegion(id)
        XCTAssertTrue(model.calcRegions.isEmpty)
        XCTAssertEqual(count(vol.labelMask, label: label), 0, "deleted region's voxels cleared")
    }

    func testCancelRestoresUnderlyingCommittedLabels() {
        // Region A committed; a second draft whose box OVERLAPS A is canceled —
        // the overlap must remain A, not become background.
        let (model, vol) = makeModel(blob: 18..<23)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        let labelA = model.draftRegion!.label
        model.commitActiveRegion()
        XCTAssertEqual(count(vol.labelMask, label: labelA), 125)

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))   // same box → preview overlaps A
        XCTAssertGreaterThan(count(vol.labelMask, label: ViewerModel.calcPreviewLabel), 0)
        model.cancelActiveRegion()

        XCTAssertNil(model.draftRegion)
        XCTAssertEqual(count(vol.labelMask, label: ViewerModel.calcPreviewLabel), 0)
        XCTAssertEqual(count(vol.labelMask, label: labelA), 125, "canceling the overlapping draft restores region A's voxels")
    }

    func testReEditPullsRegionBackToDraft() {
        let (model, vol) = makeModel()
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        let label = model.draftRegion!.label
        model.commitActiveRegion()
        let id = model.calcRegions.first!.id

        model.reEditRegion(id)
        XCTAssertNotNil(model.draftRegion)
        XCTAssertEqual(model.draftRegion?.label, label)
        XCTAssertTrue(model.calcRegions.isEmpty, "region moved out of the committed list while editing")
        XCTAssertEqual(count(vol.labelMask, label: ViewerModel.calcPreviewLabel), 125, "its voxels are now the preview")
        XCTAssertEqual(count(vol.labelMask, label: label), 0)

        model.commitActiveRegion()
        XCTAssertEqual(model.calcRegions.count, 1)
        XCTAssertEqual(count(vol.labelMask, label: label), 125, "re-committing repaints the real label")
    }

    func testGrowFromSeedSeedsHighFromBoxMean() {
        // The box is, by Method B's contract, entirely calcification → the seed
        // (high) threshold is seeded to the box's mean HU, and that mean is the
        // stable center of the Seed slider's mean±20 range.
        let (model, _) = makeModel(blob: 18..<23)   // 5³ cube of 400 HU
        model.beginRegion(method: .growFromSeed)
        guard let draft = model.draftRegion else { return XCTFail("no draft") }

        model.setActiveRegionBox(VoxelBox(xRange: 18..<23, yRange: 18..<23, zRange: 18..<23))   // exactly the cube
        XCTAssertEqual(draft.seedMeanHU ?? .nan, 400, accuracy: 0.001, "seed mean = box mean HU")
        XCTAssertEqual(draft.parameters.highThresholdHU, 400, accuracy: 0.001,
                       "high (seed) threshold seeded to the box mean")

        // The grow boundary stays in its fixed 40–80 HU band.
        XCTAssertTrue(SegmentationParameters.growBoundaryHURange.contains(draft.parameters.lowThresholdHU),
                      "grow boundary remains within 40–80 HU")
    }

    func testThresholdInROIKeepsFixedDefaultOnBoxDraw() {
        // Method A starts at a fixed 55 HU and no longer auto-seeds Otsu on box
        // draw, so the threshold stays in its 40–100 band.
        let (model, _) = makeModel(blob: 18..<23)   // 5³ cube of 400 HU, rest 40
        model.beginRegion(method: .thresholdInROI)
        guard let draft = model.draftRegion else { return XCTFail("no draft") }
        XCTAssertEqual(draft.parameters.lowThresholdHU, 55, accuracy: 0.001, "default threshold is 55 HU")

        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        XCTAssertEqual(draft.parameters.lowThresholdHU, 55, accuracy: 0.001, "box draw doesn't move the threshold")
        XCTAssertEqual(draft.previewVoxelCount, 125, "55 HU keeps the 400-HU cube, drops the 40-HU background")
    }

    func testGrowSeedReTracksWhenBoxChanges() {
        // Changing the box re-seeds the grow mean (the same helper resize uses):
        // a tight box on the 400-HU cube means 400; a box padded with 40-HU
        // background pulls the mean down.
        let (model, _) = makeModel(blob: 18..<23)
        model.beginRegion(method: .growFromSeed)
        guard let draft = model.draftRegion else { return XCTFail("no draft") }

        model.setActiveRegionBox(VoxelBox(xRange: 18..<23, yRange: 18..<23, zRange: 18..<23))   // exactly the cube
        XCTAssertEqual(draft.seedMeanHU ?? .nan, 400, accuracy: 0.001)

        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))   // padded with background
        let mean = draft.seedMeanHU ?? .nan
        XCTAssertLessThan(mean, 400, "mean re-tracks the larger box")
        XCTAssertGreaterThan(mean, 40)
        XCTAssertEqual(draft.parameters.highThresholdHU, mean, accuracy: 0.001, "seed follows the re-tracked mean")
    }

    func testTouchUpBrushAddsAndErases() {
        let (model, vol) = makeModel()
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        let label = model.draftRegion!.label
        model.commitActiveRegion()
        model.activeRegionID = model.calcRegions.first?.id
        let base = count(vol.labelMask, label: label)

        // Paint a radius-0 brush at a background voxel → +1.
        model.paintBrush(atVoxel: (5, 5, 5), radius: 0, erase: false)
        XCTAssertEqual(count(vol.labelMask, label: label), base + 1)

        // Erase it again → back to base.
        model.paintBrush(atVoxel: (5, 5, 5), radius: 0, erase: true)
        XCTAssertEqual(count(vol.labelMask, label: label), base)
    }

    // MARK: - Re-edit recovery (no silent data loss)

    func testReEditThenCancelRestoresRegion() {
        // The data-loss regression: re-editing a committed region then canceling
        // (or clicking away) must restore it intact, not destroy it.
        let (model, vol) = makeModel()
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        let label = model.draftRegion!.label
        model.draftRegion!.name = "Right BG"
        model.commitActiveRegion()
        let id = model.calcRegions.first!.id

        model.reEditRegion(id)
        XCTAssertNotNil(model.draftRegion, "region pulled into a draft")
        XCTAssertTrue(model.calcRegions.isEmpty, "out of the committed list while editing")

        model.cancelActiveRegion()
        XCTAssertNil(model.draftRegion)
        XCTAssertEqual(model.calcRegions.count, 1, "canceling a re-edit restores the region")
        XCTAssertEqual(model.calcRegions.first?.id, id, "same region object/id")
        XCTAssertEqual(model.calcRegions.first?.label, label)
        XCTAssertEqual(model.calcRegions.first?.name, "Right BG", "metadata preserved")
        XCTAssertEqual(model.calcRegions.first?.voxelCount, 125)
        XCTAssertEqual(count(vol.labelMask, label: label), 125, "committed voxels repainted")
        XCTAssertEqual(count(vol.labelMask, label: ViewerModel.calcPreviewLabel), 0, "no preview left")
    }

    func testReEditThenBeginNewRestoresPriorRegion() {
        // Starting a fresh region while one is being re-edited must not lose the
        // re-edited region (beginRegion → cancelActiveRegion → restore).
        let (model, vol) = makeModel(blob: 18..<23)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        let label = model.draftRegion!.label
        model.commitActiveRegion()
        let id = model.calcRegions.first!.id

        model.reEditRegion(id)
        model.beginRegion(method: .growFromSeed)   // abandons the re-edit
        XCTAssertTrue(model.calcRegions.contains { $0.id == id }, "prior region restored, not lost")
        XCTAssertEqual(count(vol.labelMask, label: label), 125, "its voxels are back")
    }

    func testReEditCommitKeepsSingleRegion() {
        // Committing a re-edit must not double-insert or leave a stale stash.
        let (model, vol) = makeModel()
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        let label = model.draftRegion!.label
        model.commitActiveRegion()
        let id = model.calcRegions.first!.id

        model.reEditRegion(id)
        model.commitActiveRegion()
        XCTAssertEqual(model.calcRegions.count, 1, "no duplicate region after re-edit + commit")
        XCTAssertEqual(count(vol.labelMask, label: label), 125)

        // A subsequent cancel with no draft must be a clean no-op (stash cleared).
        model.cancelActiveRegion()
        XCTAssertEqual(model.calcRegions.count, 1)
    }

    // MARK: - Draft protection + selection

    func testSelectRegionIgnoredDuringDraft() {
        // Tapping a committed region while a draft is live must NOT switch the
        // active selection (which would create a dual-active draft+committed state).
        let (model, _) = makeModel(blob: 8..<12)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 6..<14, yRange: 6..<14, zRange: 6..<14))
        model.commitActiveRegion()
        let committedID = model.calcRegions.first!.id

        model.beginRegion(method: .thresholdInROI)   // a new draft is now active
        let draftID = model.draftRegion!.id
        model.selectRegion(committedID)
        XCTAssertEqual(model.activeRegionID, draftID, "selection stays on the draft while drafting")

        model.cancelActiveRegion()
        model.selectRegion(committedID)
        XCTAssertEqual(model.activeRegionID, committedID, "selection works once the draft is gone")
    }

    // MARK: - Tool mode after commit

    func testCommitExitsROIBoxMode() {
        // Adding a region must drop ROI-box mode so the next click navigates the
        // crosshair instead of starting another box.
        let (model, _) = makeModel()
        model.beginRegion(method: .thresholdInROI)
        XCTAssertEqual(model.activeTool, .roiBox, "drawing a region enters ROI-box mode")
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))

        model.commitActiveRegion()
        XCTAssertEqual(model.activeTool, .select, "Add Region returns to Select (exits box mode)")
    }

    // MARK: - Visibility → render color table

    func testHidingRegionRendersNothingNotEverything() {
        // The visibility-toggle bug: hiding the *only* region used to empty the
        // color table, which made loadMPRSlice fall back to the flat single-color
        // mask that paints EVERY label — so the "hidden" region stayed on screen.
        // The atlas-colors seam must stay NON-nil (so the renderer uses the
        // per-label atlas) while excluding the hidden label.
        let (model, _) = makeModel(blob: 18..<23)

        // No regions → nil ⇒ legacy flat mask path (Phase-7 demo only).
        XCTAssertNil(model.segmentationAtlasColors(), "no segmentation ⇒ flat-mask path")

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        let label = model.draftRegion!.label
        model.commitActiveRegion()
        let region = model.calcRegions.first!

        // Visible → atlas path carries the region's label.
        let visible = model.segmentationAtlasColors()
        XCTAssertNotNil(visible)
        XCTAssertNotNil(visible?[Int32(label)], "visible region is in the atlas")

        // Hidden → STILL the atlas path (non-nil) but the label is absent, so the
        // renderer composites nothing for it. nil here would re-show everything.
        region.isVisible = false
        let hidden = model.segmentationAtlasColors()
        XCTAssertNotNil(hidden, "segmentation stays on the atlas path even when all hidden")
        XCTAssertTrue(hidden!.isEmpty, "the hidden region contributes no color")
        XCTAssertNil(hidden?[Int32(label)], "hidden region's label is not colored")
    }

    func testAtlasColorsExcludeOnlyHiddenRegions() {
        // Two regions; hiding one keeps the other rendered (atlas path), and the
        // hidden one's label is dropped from the table.
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            if inCube(x, y, z, 8..<12) { return 400 }
            if inCube(x, y, z, 28..<32) { return 400 }
            return nil
        }
        let model = ViewerModel()
        let idx = model.registerStandaloneVolume(vol, cacheKey: "seg", description: "seg")
        model.niftiSeriesIndex = idx

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 6..<14, yRange: 6..<14, zRange: 6..<14))
        let label1 = model.draftRegion!.label
        model.commitActiveRegion()

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 26..<34, yRange: 26..<34, zRange: 26..<34))
        let label2 = model.draftRegion!.label
        model.commitActiveRegion()

        // Hide region 1.
        model.calcRegions.first { $0.label == label1 }!.isVisible = false
        let table = model.segmentationAtlasColors()
        XCTAssertNotNil(table)
        XCTAssertNil(table?[Int32(label1)], "hidden region 1 dropped")
        XCTAssertNotNil(table?[Int32(label2)], "visible region 2 kept")
    }

    // MARK: - Voxel count integrity under a live preview

    func testRecomputeCreditsPreviewBackup() {
        // Region A committed; a second draft's preview overlaps it. A recount taken
        // while the preview is live must still report A's full committed size.
        let (model, _) = makeModel(blob: 18..<23)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        model.commitActiveRegion()
        let regionA = model.calcRegions.first!

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))  // overlaps A
        XCTAssertGreaterThan(model.draftRegion!.previewVoxelCount, 0)

        model.recomputeRegionVoxelCounts()
        XCTAssertEqual(regionA.voxelCount, 125, "region under the live preview keeps its full count")
    }

    // MARK: - Export is blocked while a draft preview is live

    func testExportBlockedWhileDraftActive() {
        // P1 regression: a live draft paints its preview as label 255 over a
        // committed region's voxels (the originals stashed in segPreviewBackup).
        // The NIfTI writer skips 255, so exporting mid-draft would silently drop
        // those committed voxels — exportSegmentation must refuse until the draft
        // is committed or cancelled.
        let (model, _) = makeModel(blob: 18..<23)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        model.commitActiveRegion()
        XCTAssertTrue(model.hasSegmentation)

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))  // overlaps the committed region
        XCTAssertNotNil(model.draftRegion)

        for kind in [NiftiMaskKind.binaryMask, .atlas] {
            XCTAssertThrowsError(try model.exportSegmentation(kind: kind)) { error in
                guard case NiftiWriteError.draftActive = error else {
                    return XCTFail("expected NiftiWriteError.draftActive, got \(error)")
                }
            }
        }

        // Resolving the draft lifts the block; the committed mask still writes.
        model.cancelActiveRegion()
        XCTAssertNil(model.draftRegion)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-export-test-\(UUID().uuidString).nii.gz")
        XCTAssertNoThrow(try model.exportMask(to: tmpURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path))
        try? FileManager.default.removeItem(at: tmpURL)
    }

    // MARK: - Export status (the Segment-panel "Saved" indicator)

    func testExportStatusSetThenInvalidatedByEdits() throws {
        // A successful export records its URL (driving the "Export · Saved" pill);
        // any later voxel edit must invalidate it so the pill honestly reverts to
        // "Pending" rather than claiming a stale on-disk file is current.
        let (model, _) = makeModel(blob: 18..<23)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        model.commitActiveRegion()
        XCTAssertFalse(model.hasExportedSegmentation, "nothing exported yet")

        // Export into a private temp dir (beside a fake source file) so the test
        // never writes to the user's Documents.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-export-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prevMode = AppSettings.shared.outputMode
        AppSettings.shared.outputMode = .besideSource
        defer { AppSettings.shared.outputMode = prevMode }
        model.loadedFileName = "case.nii.gz"
        model.loadedFileURL = dir.appendingPathComponent("case.nii.gz")

        let url = try model.exportSegmentation(kind: .binaryMask)
        XCTAssertEqual(model.exportedMaskURL, url, "export records the written mask URL")
        XCTAssertTrue(model.hasExportedSegmentation)

        // A touch-up brush edit changes voxels → the recorded export is stale.
        model.activeRegionID = model.calcRegions.first?.id
        model.paintBrush(atVoxel: (5, 5, 5), radius: 0, erase: false)
        XCTAssertFalse(model.hasExportedSegmentation, "editing voxels invalidates the export")
        XCTAssertNil(model.exportedMaskURL)
    }

    func testDeleteRegionInvalidatesExport() throws {
        let (model, _) = makeModel(blob: 18..<23)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        model.commitActiveRegion()
        let id = model.calcRegions.first!.id
        // Simulate a recorded export, then delete a region.
        model.exportedAtlasURL = URL(fileURLWithPath: "/tmp/case_calcatlas.nii.gz")
        XCTAssertTrue(model.hasExportedSegmentation)
        model.deleteRegion(id)
        XCTAssertFalse(model.hasExportedSegmentation, "deleting a region invalidates the export")
    }

    func testRegionMetadataChangeInvalidatesAtlasExportOnly() throws {
        // Codex P2: region name/color are serialized into the atlas LUT/dseg
        // sidecar, so a rename/recolor makes a prior ATLAS export stale — but the
        // binary mask carries no metadata, so its export stays valid.
        let (model, _) = makeModel(blob: 18..<23)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        model.commitActiveRegion()

        model.exportedMaskURL = URL(fileURLWithPath: "/tmp/case_calcmask.nii.gz")
        model.exportedAtlasURL = URL(fileURLWithPath: "/tmp/case_calcatlas.nii.gz")
        XCTAssertTrue(model.hasExportedSegmentation)

        model.invalidateAtlasExport()
        XCTAssertNil(model.exportedAtlasURL, "metadata change invalidates the atlas export")
        XCTAssertNotNil(model.exportedMaskURL, "binary mask export is unaffected by metadata")
        XCTAssertTrue(model.hasExportedSegmentation, "mask still counts as exported")
    }

    func testCanceledReEditPreservesExportButCommitInvalidates() throws {
        // Codex P3: re-editing an exported region and then CANCELING restores the
        // exact original voxels, so the on-disk export still matches — the recorded
        // export URL must survive a no-op re-edit/cancel. A re-edit that is COMMITTED
        // may have changed voxels, so that path still invalidates.
        let (model, _) = makeModel(blob: 18..<23)
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        model.commitActiveRegion()
        let id = model.calcRegions.first!.id

        // Simulate a recorded export of the committed segmentation.
        model.exportedMaskURL = URL(fileURLWithPath: "/tmp/case_calcmask.nii.gz")
        XCTAssertTrue(model.hasExportedSegmentation)

        // Re-edit then cancel: voxels are restored unchanged → export stays valid.
        model.reEditRegion(id)
        XCTAssertNotNil(model.draftRegion, "re-edit pulls the region into a draft")
        XCTAssertEqual(model.exportedMaskURL?.path, "/tmp/case_calcmask.nii.gz",
                       "entering a re-edit must not clear the recorded export")
        model.cancelActiveRegion()
        XCTAssertNil(model.draftRegion)
        XCTAssertEqual(model.exportedMaskURL?.path, "/tmp/case_calcmask.nii.gz",
                       "a canceled re-edit restores the voxels → export still matches disk")

        // Re-edit then COMMIT: this finalizes (possibly changed) content → invalidate.
        let id2 = model.calcRegions.first!.id
        model.reEditRegion(id2)
        model.commitActiveRegion()
        XCTAssertFalse(model.hasExportedSegmentation,
                       "committing a re-edit invalidates the prior export")
    }

    // MARK: - Tool context-gating (P3)

    /// The ONE gate the palette + every shortcut/menu consult. ROI Box needs a
    /// loaded volume; Brush needs a committed region and no in-flight draft; all
    /// other tools are always selectable.
    func testCanActivateGatesSegmentationToolsByContext() {
        let bare = ViewerModel()
        XCTAssertFalse(bare.canActivate(.roiBox), "ROI Box needs a loaded volume")
        XCTAssertFalse(bare.canActivate(.calcBrush), "Brush needs a committed region")
        XCTAssertTrue(bare.canActivate(.windowLevel), "plain tools are always selectable")
        XCTAssertTrue(bare.canActivate(.select))

        let (model, _) = makeModel()   // a volume is registered
        XCTAssertTrue(model.canActivate(.roiBox), "with a volume, ROI Box is available")
        XCTAssertFalse(model.canActivate(.calcBrush), "no committed region yet → Brush gated")
    }

    /// `activateTool` is the choke point shortcuts/menus route through — it must
    /// REFUSE a gated tool (so a `b`/`k` keypress can't enter a mode the palette
    /// shows as disabled) and accept it once the context is satisfied.
    func testActivateToolHonorsGate() {
        // No volume: the `b` shortcut path must not arm ROI Box.
        let bare = ViewerModel()
        bare.activeTool = .select
        bare.activateTool(.roiBox)
        XCTAssertEqual(bare.activeTool, .select, "no-volume `b` is ignored, matching the disabled palette button")
        bare.activateTool(.windowLevel)
        XCTAssertEqual(bare.activeTool, .windowLevel, "ungated tools still switch with no volume")

        // With a volume, `b` arms ROI Box.
        let (model, _) = makeModel()
        model.activeTool = .select
        model.activateTool(.roiBox)
        XCTAssertEqual(model.activeTool, .roiBox, "with a volume, `b` arms ROI Box")

        // Brush: gated until a region is committed, and re-gated during a draft.
        model.activeTool = .select
        model.activateTool(.calcBrush)
        XCTAssertEqual(model.activeTool, .select, "Brush needs a committed region")

        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        model.commitActiveRegion()
        XCTAssertTrue(model.hasSegmentation)
        model.activeTool = .select
        model.activateTool(.calcBrush)
        XCTAssertEqual(model.activeTool, .calcBrush, "committed region + no draft → `k` arms the Brush")

        model.beginRegion(method: .thresholdInROI)   // new in-flight draft
        model.activeTool = .select                   // isolate the gate from beginRegion's .roiBox
        model.activateTool(.calcBrush)
        XCTAssertEqual(model.activeTool, .select, "an in-flight draft blocks the Brush")
    }

    /// The Pan tool is greyed out on the 3D panel (where the default pointer
    /// already rotates the camera — `rotatesVolumeOnPrimaryDrag`), and selectable
    /// on MPR / when no panel is focused. This is the ONE gate the palette and
    /// the `p` shortcut both consult, so they can't disagree.
    func testCanActivateGatesPanOnVolume3DPanel() {
        let model = ViewerModel()

        // No panels → no active panel → Pan stays selectable (no inconsistent
        // gap in the bare palette).
        XCTAssertTrue(model.canActivate(.pan), "Pan selectable with no active panel")

        // MPR active panel → Pan available.
        let mpr = PanelState()
        mpr.panelMode = .mprAxial
        model.panels = [mpr]
        model.activePanelID = mpr.id
        XCTAssertTrue(model.canActivate(.pan), "Pan available on an MPR panel")

        // 3D active panel → Pan greyed out (Select already rotates there).
        mpr.panelMode = .volume3D
        XCTAssertFalse(model.canActivate(.pan), "Pan greyed out on the 3D panel")

        // And activateTool honors the gate (the `p` shortcut path).
        model.activeTool = .select
        model.activateTool(.pan)
        XCTAssertEqual(model.activeTool, .select, "`p` is ignored on the 3D panel, matching the disabled palette button")

        // Switch back to MPR → Pan selectable again, and `p` arms it.
        mpr.panelMode = .mprCoronal
        XCTAssertTrue(model.canActivate(.pan))
        model.activateTool(.pan)
        XCTAssertEqual(model.activeTool, .pan, "`p` arms Pan on an MPR panel")
    }

    /// The `-`/`=` brush-size shortcuts route through `adjustBrushRadius(by:)`,
    /// which clamps to 0...8 (matching the inspector slider). Pure + testable so
    /// the key routing can be locked without driving a GUI key event.
    func testAdjustBrushRadiusClampsToValidRange() {
        let model = ViewerModel()
        model.calcBrushRadius = 2

        // Increase / decrease within range.
        XCTAssertEqual(model.adjustBrushRadius(by: 1), 3)
        XCTAssertEqual(model.calcBrushRadius, 3)
        XCTAssertEqual(model.adjustBrushRadius(by: -1), 2)
        XCTAssertEqual(model.calcBrushRadius, 2)

        // Large delta clamps to the upper bound (8, matching the slider max).
        XCTAssertEqual(model.adjustBrushRadius(by: 100), 8)
        XCTAssertEqual(model.calcBrushRadius, 8)

        // Large negative delta clamps to 0 (no negative radius).
        XCTAssertEqual(model.adjustBrushRadius(by: -100), 0)
        XCTAssertEqual(model.calcBrushRadius, 0)

        // Boundary: 8 + 1 stays 8; 0 - 1 stays 0.
        model.calcBrushRadius = 8
        XCTAssertEqual(model.adjustBrushRadius(by: 1), 8)
        model.calcBrushRadius = 0
        XCTAssertEqual(model.adjustBrushRadius(by: -1), 0)
    }

    // MARK: - Brush stroke Undo

    /// Helper: commit a 5³ calc region so the brush has a selected region.
    private func commitRegionForBrush(_ model: ViewerModel) -> CalcificationRegion? {
        model.beginRegion(method: .thresholdInROI)
        model.setActiveRegionBox(VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25))
        model.commitActiveRegion()
        return model.calcRegions.first
    }

    /// A paint stroke (mouseDown→up) registers ONE undo that restores every
    /// painted voxel to its pre-stroke (background) label.
    func testBrushStrokeUndoRestoresPaintedVoxels() {
        let (model, vol) = makeModel()
        guard let region = commitRegionForBrush(model),
              let mask = vol.labelMask else { return XCTFail("no committed region") }
        let before = count(mask, label: region.label)
        XCTAssertGreaterThan(before, 0)

        let undo = UndoManager()
        // Paint a dot at a background voxel (5,5,5 is air in the 40³ volume).
        model.beginBrushStroke()
        model.paintBrush(atVoxel: (5, 5, 5), radius: 2, erase: false)
        model.endBrushStroke(undoManager: undo)

        let after = count(mask, label: region.label)
        XCTAssertGreaterThan(after, before, "paint added voxels of the region's label")
        XCTAssertTrue(undo.canUndo, "the stroke registered an undo")
        XCTAssertEqual(undo.undoActionName, "Paint Brush")

        undo.undo()
        XCTAssertEqual(count(mask, label: region.label), before,
                       "undo restored the painted voxels to their pre-stroke label")
    }

    /// An erase stroke registers ONE undo that restores the erased region voxels.
    func testBrushStrokeUndoRestoresErasedVoxels() {
        let (model, vol) = makeModel()
        guard let region = commitRegionForBrush(model),
              let mask = vol.labelMask else { return XCTFail("no committed region") }
        let before = count(mask, label: region.label)

        let undo = UndoManager()
        model.calcBrushErase = true
        model.beginBrushStroke()
        // Erase at the region's center (20,20,20 is inside the 18..<23 cube).
        model.paintBrush(atVoxel: (20, 20, 20), radius: 1, erase: true)
        model.endBrushStroke(undoManager: undo)

        XCTAssertLessThan(count(mask, label: region.label), before, "erase removed region voxels")
        XCTAssertEqual(undo.undoActionName, "Erase Brush")

        undo.undo()
        XCTAssertEqual(count(mask, label: region.label), before,
                       "undo restored the erased voxels")
    }

    /// Multiple paintBrush calls within one stroke (a drag fires many) register
    /// a SINGLE undo step — one stroke = one ⌘Z, not one per paint call.
    func testBrushStrokeGroupsMultiplePaintsIntoOneUndo() {
        let (model, _) = makeModel()
        _ = commitRegionForBrush(model)

        let undo = UndoManager()
        model.beginBrushStroke()
        model.paintBrush(atVoxel: (5, 5, 5), radius: 1, erase: false)
        model.paintBrush(atVoxel: (8, 8, 8), radius: 1, erase: false)
        model.paintBrush(atVoxel: (11, 11, 11), radius: 1, erase: false)
        model.endBrushStroke(undoManager: undo)

        XCTAssertTrue(undo.canUndo, "the stroke registered an undo")
        undo.undo()
        XCTAssertFalse(undo.canUndo, "one stroke = one undo step, not one per paint call")
    }

    /// A stroke that paints nothing (e.g. paint on voxels already the region's
    /// label) registers NO undo — no backup, no undo entry, no clutter.
    func testBrushStrokeWithNoChangeRegistersNoUndo() {
        let (model, _) = makeModel()
        _ = commitRegionForBrush(model)

        let undo = UndoManager()
        model.beginBrushStroke()
        // Paint at the region's center where the label already equals the
        // region's label → paintBrush is a no-op (delta 0), backup stays empty.
        model.paintBrush(atVoxel: (20, 20, 20), radius: 1, erase: false)
        model.endBrushStroke(undoManager: undo)

        XCTAssertFalse(undo.canUndo, "a no-op stroke registers no undo")
    }

    // MARK: - Brush undo staleness guard (P2)

    /// A brush undo must NOT replay its labels after the owning region is
    /// deleted — the voxels would orphan (no region owns the label anymore).
    /// The undo closure self-invalidates by checking the region still exists.
    func testBrushUndoBailsAfterRegionDeleted() {
        let (model, vol) = makeModel()
        guard let region = commitRegionForBrush(model),
              let mask = vol.labelMask else { return XCTFail("no committed region") }
        let label = region.label
        let before = count(mask, label: label)

        let undo = UndoManager()
        model.calcBrushErase = true
        model.beginBrushStroke()
        model.paintBrush(atVoxel: (20, 20, 20), radius: 1, erase: true)
        model.endBrushStroke(undoManager: undo)
        let erased = count(mask, label: label)
        XCTAssertLessThan(erased, before, "erase removed some region voxels")
        XCTAssertTrue(undo.canUndo)

        // Delete the region AFTER the stroke — its label is cleared from the
        // mask and it's gone from calcRegions.
        model.deleteRegion(region.id)
        XCTAssertFalse(model.calcRegions.contains { $0.id == region.id })
        XCTAssertFalse(model.calcRegions.contains { $0.label == label })
        // After deleteRegion the region's label is cleared from the mask, so the
        // count of label-`label` voxels is 0. Capture it so the post-undo check
        // is a real comparison (the old assertion compared the value to itself).
        let postDelete = count(mask, label: label)
        XCTAssertEqual(postDelete, 0, "deleteRegion cleared the region's label")

        // Undoing now must NOT restore the stroke's voxels. Guard (2) — the
        // owning region must still be in calcRegions — blocks this wholesale:
        // for an erase stroke the post-stroke label is 0 == background, and
        // after deleteRegion the erased voxels are also 0, so the per-voxel
        // guard (3) alone would naively restore them to the region's label
        // (re-orphaning). The region-existence check is the real defense here.
        undo.undo()
        XCTAssertEqual(count(mask, label: label), postDelete,
                       "undo did not restore orphaned label-`label` voxels after delete")
        XCTAssertFalse(undo.canRedo, "the stale undo performed no mutation (nothing to redo)")
    }

    /// A brush undo must NOT replay after the base volume is reset/swapped —
    /// the stroke's voxels reference the old grid/series. The guard checks the
    /// segmentation volume's seriesUID still matches.
    func testBrushUndoBailsAfterSegmentationReset() {
        let (model, vol) = makeModel()
        guard let region = commitRegionForBrush(model),
              let mask = vol.labelMask else { return XCTFail("no committed region") }
        let label = region.label
        let before = count(mask, label: label)

        let undo = UndoManager()
        model.calcBrushErase = true
        model.beginBrushStroke()
        model.paintBrush(atVoxel: (20, 20, 20), radius: 1, erase: true)
        model.endBrushStroke(undoManager: undo)
        let erased = count(mask, label: label)
        XCTAssertLessThan(erased, before, "erase removed some region voxels")

        // Reset segmentation (as a new base file would): clears regions + mask
        // state. The undo's captured seriesUID/regionID are now stale.
        model.resetSegmentation()
        XCTAssertNil(model.draftRegion)
        XCTAssertFalse(model.calcRegions.contains { $0.id == region.id })

        // Undo must bail — restoring into the reset state would resurrect
        // orphaned label voxels for a region that no longer exists.
        undo.undo()
        XCTAssertEqual(count(mask, label: label), erased,
                       "the stale undo did not restore the erased voxels")
        XCTAssertFalse(undo.canRedo, "the stale undo performed no mutation")
    }

    /// A brush undo must NOT clobber a LATER edit to the same voxels. The
    /// per-voxel post-stroke-label guard (3) blocks this: after the stroke,
    /// another edit changes a touched voxel's label, so at undo time the
    /// current label no longer matches the captured post-stroke label and that
    /// voxel is skipped (preserved as-is). This is the Codex P2 scenario:
    /// stroke → overlapping commit / re-edit-commit / another stroke on the
    /// same voxels → old ⌘Z would otherwise overwrite the newer mask labels.
    func testBrushUndoPreservesLaterEditOnSameVoxels() {
        let (model, vol) = makeModel()
        guard let region = commitRegionForBrush(model),
              let mask = vol.labelMask else { return XCTFail("no committed region") }
        let label = region.label

        // Stroke 1: erase a few voxels of the region (post-stroke label 0).
        let undo1 = UndoManager()
        model.calcBrushErase = true
        model.beginBrushStroke()
        model.paintBrush(atVoxel: (20, 20, 20), radius: 1, erase: true)
        model.endBrushStroke(undoManager: undo1)
        let afterStroke1 = count(mask, label: label)
        let bgAfterStroke1 = count(mask, label: 0)

        // Stroke 2: paint the SAME voxels back (and maybe more) — a later edit
        // on the voxels stroke 1 touched. Its own undo is separate.
        let undo2 = UndoManager()
        model.calcBrushErase = false
        model.beginBrushStroke()
        model.paintBrush(atVoxel: (20, 20, 20), radius: 1, erase: false)
        model.endBrushStroke(undoManager: undo2)
        let afterStroke2 = count(mask, label: label)
        XCTAssertGreaterThan(afterStroke2, afterStroke1,
                             "stroke 2 re-painted the erased voxels back to the region label")

        // Undo stroke 1 — it must NOT clobber stroke 2's re-paint. The per-voxel
        // guard sees the voxels are now `label` (not the post-stroke-1 label 0),
        // so it skips them; stroke 2's edit is preserved.
        undo1.undo()
        XCTAssertEqual(count(mask, label: label), afterStroke2,
                       "undo of stroke 1 did not clobber stroke 2's re-paint")
        XCTAssertEqual(count(mask, label: 0), bgAfterStroke1 - (afterStroke2 - afterStroke1),
                       "background voxels unchanged by the stale undo (stroke 2 preserved)")

        // Undo stroke 2 — its own undo still works (it's the most recent edit).
        undo2.undo()
        XCTAssertEqual(count(mask, label: label), afterStroke1,
                       "undo of stroke 2 (the latest) correctly reverts it")
    }
}
