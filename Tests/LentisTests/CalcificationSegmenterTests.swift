// CalcificationSegmenterTests.swift
// Lentis Tests
//
// Phase 9 — locks in the calcification segmentation engine behavior on
// deterministic in-memory CT volumes (no fixture file dependency):
//   • Method A (threshold in ROI) extracts exactly the above-threshold blob,
//     over-grows when the threshold is too low, and is empty when too high.
//   • Brain-mask AND excludes a high-HU speck outside the brain.
//   • Hysteresis (seed-high / boundary-low) catches a faint rim connected to a
//     bright core while rejecting a disconnected faint blob a single low
//     threshold would grab.
//   • Connected-component min-size drops specks.
//   • Otsu lands in the tissue/calcification gap (≥ soft tissue).
//   • Method B (grow from seed) grows PAST the ROI box to the blob boundary.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class CalcificationSegmenterTests: XCTestCase {

    // MARK: - Builders

    /// Build a 1 mm isotropic canonical-RAS CT volume (HU == stored Int16).
    /// `assign` returns nil to keep the `background` value.
    private func makeCTVolume(_ w: Int, _ h: Int, _ d: Int,
                              background: Int16 = 40,
                              _ assign: (Int, Int, Int) -> Int16?) -> VolumeData {
        let count = w * h * d
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    buf[z * w * h + y * w + x] = assign(x, y, z) ?? background
                }
            }
        }
        return VolumeData(
            voxels: buf, width: w, height: h, depth: d,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: SIMD3(0, 0, 0),
            rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
            rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "calc-test")
    }

    private func inCube(_ x: Int, _ y: Int, _ z: Int,
                        _ xr: Range<Int>, _ yr: Range<Int>, _ zr: Range<Int>) -> Bool {
        xr.contains(x) && yr.contains(y) && zr.contains(z)
    }

    /// A brain mask that is `true` inside the given box, `false` elsewhere.
    private func boxBrainMask(_ w: Int, _ h: Int, _ d: Int, box: VoxelBox) -> BrainConstraint {
        var mask = [Bool](repeating: false, count: w * h * d)
        for z in box.zRange {
            for y in box.yRange {
                for x in box.xRange { mask[z * w * h + y * w + x] = true }
            }
        }
        return BrainConstraint(width: w, height: h, depth: d, mask: mask)
    }

    private func coordSet(_ r: SegmentationResult) -> Set<[Int]> {
        Set(r.coords.map { [$0.0, $0.1, $0.2] })
    }

    // MARK: - VoxelBox

    func testVoxelBoxBasics() {
        let b = VoxelBox(corner: (3, 9, 1), corner: (1, 2, 5))
        XCTAssertEqual(b.xRange, 1..<4)
        XCTAssertEqual(b.yRange, 2..<10)
        XCTAssertEqual(b.zRange, 1..<6)
        XCTAssertTrue(b.contains(x: 2, y: 5, z: 3))
        XCTAssertFalse(b.contains(x: 4, y: 5, z: 3))
        XCTAssertEqual(b.voxelCount, 3 * 8 * 5)
        XCTAssertFalse(b.isEmpty)

        let vol = makeCTVolume(10, 10, 10) { _, _, _ in nil }
        let clamped = VoxelBox(xRange: -5..<50, yRange: 3..<7, zRange: 8..<20).clamped(to: vol)
        XCTAssertEqual(clamped.xRange, 0..<10)
        XCTAssertEqual(clamped.yRange, 3..<7)
        XCTAssertEqual(clamped.zRange, 8..<10)
        XCTAssertFalse(clamped.xRange.lowerBound > clamped.xRange.upperBound)

        XCTAssertTrue(VoxelBox(xRange: 5..<5, yRange: 0..<3, zRange: 0..<3).isEmpty)
        XCTAssertEqual(b.dilated(by: 2).xRange, -1..<6)
    }

    // MARK: - Method A: threshold in ROI

    func testThresholdExtractsBlobExactly() {
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            inCube(x, y, z, 18..<23, 18..<23, 18..<23) ? 400 : nil
        }
        let seg = CalcificationSegmenter(volume: vol, brainMask: nil)
        let box = VoxelBox(xRange: 16..<25, yRange: 16..<25, zRange: 16..<25)

        var p = SegmentationParameters.defaults(for: .thresholdInROI)
        p.lowThresholdHU = 130; p.highThresholdHU = 130; p.minVoxelCount = 1; p.constrainToBrainMask = false
        let r = seg.segment(in: box, parameters: p)
        XCTAssertEqual(r.voxelCount, 5 * 5 * 5, "threshold extracts exactly the 5³ calc cube")
        for c in r.coords {
            XCTAssertTrue(inCube(c.0, c.1, c.2, 18..<23, 18..<23, 18..<23))
        }

        // Too low → grabs surrounding tissue (40 ≥ 20) → fills the box.
        p.lowThresholdHU = 20; p.highThresholdHU = 20
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, box.voxelCount)

        // Too high → nothing.
        p.lowThresholdHU = 600; p.highThresholdHU = 600
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, 0)
    }

    // MARK: - Brain-mask exclusion

    func testBrainMaskExcludesSkullSpeck() {
        // Center calc cube (in brain) + a high-HU speck near the corner (skull).
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            if inCube(x, y, z, 18..<23, 18..<23, 18..<23) { return 400 }       // 125 voxels, brain
            if inCube(x, y, z, 2..<4, 2..<4, 2..<4) { return 400 }             // 8 voxels, skull
            return nil
        }
        let brain = boxBrainMask(40, 40, 40, box: VoxelBox(xRange: 10..<30, yRange: 10..<30, zRange: 10..<30))
        let seg = CalcificationSegmenter(volume: vol, brainMask: brain)
        let box = VoxelBox(xRange: 0..<40, yRange: 0..<40, zRange: 0..<40)

        var p = SegmentationParameters.defaults(for: .thresholdInROI)
        p.lowThresholdHU = 130; p.highThresholdHU = 130; p.minVoxelCount = 1

        p.constrainToBrainMask = true
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, 125, "skull speck excluded by brain mask")

        p.constrainToBrainMask = false
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, 133, "without the mask the skull speck is included")
    }

    // MARK: - Hysteresis

    func testHysteresisCatchesRimRejectsDisconnectedFaintBlob() {
        // Bright core (400) + faint rim shell (160) connected to it, plus a
        // disconnected faint blob (160) elsewhere in the box.
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            if inCube(x, y, z, 18..<22, 18..<22, 18..<22) { return 400 }   // core 4³ = 64
            if inCube(x, y, z, 17..<23, 17..<23, 17..<23) { return 160 }   // rim shell = 152
            if inCube(x, y, z, 25..<28, 18..<21, 18..<21) { return 160 }   // faint blob 3³ = 27 (disconnected)
            return nil
        }
        let seg = CalcificationSegmenter(volume: vol, brainMask: nil)
        let box = VoxelBox(xRange: 16..<29, yRange: 16..<24, zRange: 16..<24)
        let faint = Set((25..<28).flatMap { x in (18..<21).flatMap { y in (18..<21).map { z in [x, y, z] } } })

        var p = SegmentationParameters.defaults(for: .thresholdInROI)
        p.minVoxelCount = 1; p.constrainToBrainMask = false

        // Single low threshold: grabs core + rim + the disconnected faint blob.
        p.lowThresholdHU = 130; p.highThresholdHU = 130
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, 64 + 152 + 27)

        // Single high threshold: only the bright core (misses the rim).
        p.lowThresholdHU = 300; p.highThresholdHU = 300
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, 64)

        // Hysteresis: seed at high, grow to low → core + rim, but NOT the
        // disconnected faint blob (no high seed in it).
        p.lowThresholdHU = 130; p.highThresholdHU = 300; p.growBeyondROI = false
        let r = seg.segment(in: box, parameters: p)
        XCTAssertEqual(r.voxelCount, 64 + 152)
        XCTAssertTrue(coordSet(r).isDisjoint(with: faint), "hysteresis excludes the disconnected faint blob")
    }

    // MARK: - Connected-component min-size

    func testMinSizeDropsSpecks() {
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            if inCube(x, y, z, 18..<23, 18..<23, 18..<23) { return 400 }   // main blob 125
            if inCube(x, y, z, 10..<12, 10..<11, 10..<11) { return 400 }   // 2-voxel speck
            return nil
        }
        let seg = CalcificationSegmenter(volume: vol, brainMask: nil)
        let box = VoxelBox(xRange: 8..<25, yRange: 8..<25, zRange: 8..<25)
        var p = SegmentationParameters.defaults(for: .thresholdInROI)
        p.lowThresholdHU = 130; p.highThresholdHU = 130; p.constrainToBrainMask = false

        p.minVoxelCount = 3
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, 125, "2-voxel speck dropped")

        p.minVoxelCount = 1
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, 127, "speck kept when min size = 1")
    }

    // MARK: - Otsu

    func testOtsuLandsInTissueCalcificationGap() {
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            inCube(x, y, z, 18..<24, 18..<24, 18..<24) ? 400 : nil   // calc in tissue (40)
        }
        let seg = CalcificationSegmenter(volume: vol, brainMask: nil)
        let box = VoxelBox(xRange: 14..<28, yRange: 14..<28, zRange: 14..<28)
        let t = seg.otsuThreshold(in: box, constrainToBrainMask: false)
        XCTAssertGreaterThan(t, CalcificationSegmenter.softTissueFloorHU, "Otsu never below soft tissue")
        XCTAssertGreaterThan(t, 100)
        XCTAssertLessThan(t, 400, "Otsu separates 40-HU tissue from 400-HU calcification")
    }

    // MARK: - Method B: grow from seed past the box

    func testGrowFromSeedExtendsPastBox() {
        // A calcification much larger than the box the user draws inside it.
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            inCube(x, y, z, 15..<26, 15..<26, 15..<26) ? 400 : nil   // 11³ = 1331
        }
        let seg = CalcificationSegmenter(volume: vol, brainMask: nil)
        let innerBox = VoxelBox(xRange: 18..<23, yRange: 18..<23, zRange: 18..<23)   // 125, inside the blob

        var grow = SegmentationParameters.defaults(for: .growFromSeed)
        grow.lowThresholdHU = 130; grow.highThresholdHU = 300
        grow.constrainToBrainMask = false; grow.minVoxelCount = 1
        XCTAssertEqual(seg.segment(in: innerBox, parameters: grow).voxelCount, 11 * 11 * 11,
                       "grow-from-seed reaches the whole blob beyond the box")

        // Method A on the same box stays inside the box.
        var thresh = SegmentationParameters.defaults(for: .thresholdInROI)
        thresh.lowThresholdHU = 130; thresh.highThresholdHU = 130
        thresh.constrainToBrainMask = false; thresh.minVoxelCount = 1
        XCTAssertEqual(seg.segment(in: innerBox, parameters: thresh).voxelCount, 125,
                       "threshold-in-ROI stays bounded to the box")
    }
}
