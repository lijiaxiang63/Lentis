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
}
