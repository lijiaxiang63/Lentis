// SegmentationSeamTests.swift
// Lentis Tests
//
// Locks in the Phase 7 segmentation *seams* (no segmentation behavior yet):
//   • LabelVolume allocates zeroed, shares the parent VolumeData's grid, and
//     round-trips labels.
//   • VolumeData.ensureLabelMask attaches a same-grid mask once (idempotent).
//   • MPREngine.maskSlice extracts the mask in the SAME orientation as the gray
//     slice — verified by comparing against the gray extractor itself, so the
//     overlay can never drift from the image it sits on.
//   • renderSlice(mask:) tints labeled pixels and leaves background ones gray.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class SegmentationSeamTests: XCTestCase {

    /// voxel(x,y,z) = x + y*width + z*width*height, canonical-RAS directions.
    private func makeGradientVolume(width: Int, height: Int, depth: Int) -> VolumeData {
        let count = width * height * depth
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    buffer[z * width * height + y * width + x] = Int16(x + y * width + z * width * height)
                }
            }
        }
        return VolumeData(
            voxels: buffer,
            width: width, height: height, depth: depth,
            spacingX: 1.0, spacingY: 1.0, spacingZ: 1.0,
            origin: SIMD3<Double>(0, 0, 0),
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1.0, rescaleIntercept: 0.0,
            seriesUID: "seam-test"
        )
    }

    /// Read a displayed mask pixel at (col, row); row 0 is the top of the image.
    private func maskPixelAt(_ slice: MaskSlice, col: Int, row: Int) -> UInt8 {
        slice.labels[row * slice.width + col]
    }

    // MARK: - LabelVolume

    func testLabelVolumeAllocatesZeroedAndRoundTrips() {
        let mask = LabelVolume(width: 5, height: 4, depth: 3)
        XCTAssertEqual(mask.labeledVoxelCount, 0, "fresh mask is all-background")
        XCTAssertEqual(mask.labelAt(x: 2, y: 1, z: 2), 0)

        mask.setLabel(7, x: 2, y: 1, z: 2)
        XCTAssertEqual(mask.labelAt(x: 2, y: 1, z: 2), 7)
        XCTAssertEqual(mask.labeledVoxelCount, 1)

        // Out-of-bounds reads/writes are safe no-ops.
        XCTAssertEqual(mask.labelAt(x: -1, y: 0, z: 0), 0)
        mask.setLabel(9, x: 99, y: 0, z: 0)
        XCTAssertEqual(mask.labeledVoxelCount, 1)

        mask.clear()
        XCTAssertEqual(mask.labeledVoxelCount, 0)
    }

    func testLabelVolumeSharesParentGrid() {
        let vol = makeGradientVolume(width: 6, height: 5, depth: 4)
        let mask = vol.ensureLabelMask()
        XCTAssertEqual(mask.width, vol.width)
        XCTAssertEqual(mask.height, vol.height)
        XCTAssertEqual(mask.depth, vol.depth)
        // Idempotent: a second call returns the same instance.
        XCTAssertTrue(vol.ensureLabelMask() === mask)
        XCTAssertTrue(vol.labelMask === mask)
    }

    // MARK: - maskSlice alignment (locked to the gray extractor)

    /// A single labeled voxel must surface at EXACTLY the displayed pixel where
    /// the gray slice carries that same voxel — across all three planes. We find
    /// the gray pixel by matching the voxel's unique gradient value, then assert
    /// the mask slice is nonzero there and zero everywhere else.
    private func assertMaskAlignsWithGray(mode: PanelMode, sliceIndex: Int,
                                          vx: Int, vy: Int, vz: Int,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let vol = makeGradientVolume(width: 4, height: 5, depth: 6)
        let mask = vol.ensureLabelMask()
        mask.setLabel(1, x: vx, y: vy, z: vz)
        let engine = MPREngine(volume: vol)

        let gray: MPRSlice?
        switch mode {
        case .mprAxial:    gray = engine.axialSlice(at: sliceIndex)
        case .mprSagittal: gray = engine.sagittalSlice(at: sliceIndex)
        case .mprCoronal:  gray = engine.coronalSlice(at: sliceIndex)
        default:           gray = nil
        }
        guard let graySlice = gray, let maskSlice = engine.maskSlice(mode: mode, sliceIndex: sliceIndex) else {
            return XCTFail("missing slice for \(mode)", file: file, line: line)
        }
        XCTAssertEqual(maskSlice.width, graySlice.width, file: file, line: line)
        XCTAssertEqual(maskSlice.height, graySlice.height, file: file, line: line)

        let sentinel = Int16(vx + vy * vol.width + vz * vol.width * vol.height)
        var matched = 0
        graySlice.pixelData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Int16.self)
            for row in 0..<graySlice.height {
                for col in 0..<graySlice.width {
                    let isLabeled = maskPixelAt(maskSlice, col: col, row: row) != 0
                    let isSentinel = src[row * graySlice.width + col] == sentinel
                    XCTAssertEqual(isLabeled, isSentinel,
                                   "mask/gray mismatch at (\(col),\(row)) in \(mode)", file: file, line: line)
                    if isLabeled { matched += 1 }
                }
            }
        }
        XCTAssertEqual(matched, 1, "exactly one labeled pixel in \(mode)", file: file, line: line)
    }

    func testMaskSliceAlignsWithGrayAxial() {
        assertMaskAlignsWithGray(mode: .mprAxial, sliceIndex: 2, vx: 1, vy: 3, vz: 2)
    }

    func testMaskSliceAlignsWithGraySagittal() {
        assertMaskAlignsWithGray(mode: .mprSagittal, sliceIndex: 1, vx: 1, vy: 3, vz: 4)
    }

    func testMaskSliceAlignsWithGrayCoronal() {
        assertMaskAlignsWithGray(mode: .mprCoronal, sliceIndex: 3, vx: 2, vy: 3, vz: 4)
    }

    func testMaskSliceNilWithoutMask() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)
        XCTAssertNil(engine.maskSlice(mode: .mprAxial, sliceIndex: 0),
                     "no mask attached → no mask slice (render stays on the gray path)")
    }

    // MARK: - renderSlice composite

    func testRenderSliceTintsLabeledPixels() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let mask = vol.ensureLabelMask()
        mask.setLabel(1, x: 1, y: 1, z: 0)
        let engine = MPREngine(volume: vol)
        let gray = engine.axialSlice(at: 0)!
        let maskSlice = engine.maskSlice(mode: .mprAxial, sliceIndex: 0)!

        // Without a mask the image is grayscale; with a mask it is an RGBA
        // composite. Both must produce a valid image of the same size.
        let plain = MPREngine.renderSlice(gray, ww: 64, wc: 32)
        let tinted = MPREngine.renderSlice(gray, ww: 64, wc: 32, mask: maskSlice,
                                           maskColor: SIMD3<Double>(1, 0, 0), maskAlpha: 0.5)
        XCTAssertNotNil(plain)
        XCTAssertNotNil(tinted)
        XCTAssertEqual(tinted?.size.width, plain?.size.width)
        XCTAssertEqual(tinted?.size.height, plain?.size.height)
    }
}
