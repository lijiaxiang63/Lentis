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
}
