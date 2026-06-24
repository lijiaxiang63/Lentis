// SegmentationBrainMaskTests.swift
// Lentis Tests
//
// Phase 9 — brain-mask constraint + SynthSeg runner (environment-independent):
//   • BrainConstraint built from a resampled overlay volume (nonzero = brain)
//     and the segmenter excludes a high-HU speck outside the brain — the
//     production constraint path (complements the boolean-grid engine test).
//   • SynthSegRunner.locate honors an explicit override; briefStatus reduces a
//     streamed chunk to its last non-empty line.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class SegmentationBrainMaskTests: XCTestCase {

    private func makeCTVolume(_ w: Int, _ h: Int, _ d: Int, _ assign: (Int, Int, Int) -> Int16?) -> VolumeData {
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: w * h * d)
        for z in 0..<d { for y in 0..<h { for x in 0..<w { buf[z * w * h + y * w + x] = assign(x, y, z) ?? 40 } } }
        return VolumeData(
            voxels: buf, width: w, height: h, depth: d,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: SIMD3(0, 0, 0),
            rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
            rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "brain-test")
    }

    private func inCube(_ x: Int, _ y: Int, _ z: Int, _ r: Range<Int>) -> Bool {
        r.contains(x) && r.contains(y) && r.contains(z)
    }

    func testBrainConstraintFromOverlayVolume() {
        let n = 4
        var values = [Int32](repeating: 0, count: n * n * n)
        values[1 + 4 * 1 + 16 * 1] = 5     // one brain voxel labeled
        let lv = OverlayLayerVolume.makeAtlas(width: n, height: n, depth: n,
                                              voxelToWorldMatrix: matrix_identity_double4x4,
                                              values: values)
        let bc = BrainConstraint(layerVolume: lv)
        XCTAssertTrue(bc.contains(x: 1, y: 1, z: 1), "nonzero label = brain")
        XCTAssertFalse(bc.contains(x: 0, y: 0, z: 0), "zero = not brain")
        XCTAssertFalse(bc.contains(x: -1, y: 0, z: 0), "out of bounds = not brain")
    }

    func testSegmenterExcludesSpeckOutsideOverlayBrainMask() {
        // Calc blob inside brain + a high-HU speck outside the brain region.
        let vol = makeCTVolume(40, 40, 40) { x, y, z in
            if inCube(x, y, z, 18..<23) { return 400 }     // 125, brain
            if inCube(x, y, z, 2..<4) { return 400 }       // 8, skull
            return nil
        }
        // Brain mask overlay: nonzero only for the central region [10,30).
        var values = [Int32](repeating: 0, count: 40 * 40 * 40)
        for z in 10..<30 { for y in 10..<30 { for x in 10..<30 { values[z * 1600 + y * 40 + x] = 1 } } }
        let brain = BrainConstraint(layerVolume: OverlayLayerVolume.makeAtlas(
            width: 40, height: 40, depth: 40,
            voxelToWorldMatrix: matrix_identity_double4x4, values: values))

        let seg = CalcificationSegmenter(volume: vol, brainMask: brain)
        var p = SegmentationParameters.defaults(for: .thresholdInROI)
        p.lowThresholdHU = 130; p.highThresholdHU = 130; p.minVoxelCount = 1; p.constrainToBrainMask = true
        let box = VoxelBox(xRange: 0..<40, yRange: 0..<40, zRange: 0..<40)
        XCTAssertEqual(seg.segment(in: box, parameters: p).voxelCount, 125,
                       "overlay-derived brain mask excludes the skull speck")
    }

    func testSynthSegLocateHonorsOverride() {
        // /bin/sh exists and is executable everywhere; the override must win.
        let override = URL(fileURLWithPath: "/bin/sh")
        XCTAssertEqual(SynthSegRunner.locate(userOverride: override), override)
    }

    func testSynthSegBriefStatus() {
        XCTAssertEqual(SynthSegRunner.briefStatus("predicting 1/1\n  done  \n\n"), "done")
        XCTAssertNil(SynthSegRunner.briefStatus("\n  \n"))
    }
}
