// NiftiWriterTests.swift
// Lentis Tests
//
// Phase 9 — NIfTI writer round-trips through the existing reader:
//   • Canonical mask: dims, labels, and affine survive write → read.
//   • Atlas: distinct label values are preserved.
//   • gzip: a .nii.gz written here decodes through the pure-Swift inflater.
//   • Write-back: a non-canonical volume (reorientation + originalAffine) is
//     written in the ORIGINAL grid — a canonical label lands at the original
//     source voxel and the affine is the original.
//   • LUT sidecar parses back via ColorLookupTable.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class NiftiWriterTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeCanonicalVolume(_ w: Int, _ h: Int, _ d: Int) -> VolumeData {
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: w * h * d)
        buf.initialize(repeating: 0)
        return VolumeData(
            voxels: buf, width: w, height: h, depth: d,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: SIMD3(-3, 5, 7),
            rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
            rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "writer")
    }

    private func nonzero(_ vals: [Double]) -> Int { vals.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } }

    private func assertAffineEqual(_ a: simd_double4x4, _ b: simd_double4x4,
                                   accuracy: Double = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(a[col][row], b[col][row], accuracy: accuracy,
                               "affine[\(col)][\(row)]", file: file, line: line)
            }
        }
    }

    // MARK: - Canonical round-trip

    func testCanonicalMaskRoundTrip() throws {
        let vol = makeCanonicalVolume(4, 5, 6)
        let mask = vol.ensureLabelMask()
        mask.setLabel(1, x: 1, y: 2, z: 3)
        mask.setLabel(1, x: 2, y: 2, z: 3)

        let url = tmpDir.appendingPathComponent("mask.nii")
        try NiftiWriter.writeMask(mask, basedOn: vol, kind: .binaryMask, to: url, gzip: false)

        let img = try NiftiImage.read(contentsOf: url)
        XCTAssertEqual(img.nx, 4); XCTAssertEqual(img.ny, 5); XCTAssertEqual(img.nz, 6)
        let vals = img.calibratedDoubleVolume(timepoint: 0)
        XCTAssertEqual(nonzero(vals), 2)
        XCTAssertEqual(vals[1 + 4 * 2 + 20 * 3], 1)   // (1,2,3)
        XCTAssertEqual(vals[2 + 4 * 2 + 20 * 3], 1)   // (2,2,3)
        assertAffineEqual(img.affine, vol.voxelToWorldMatrix)
    }

    func testAtlasPreservesDistinctLabels() throws {
        let vol = makeCanonicalVolume(4, 4, 4)
        let mask = vol.ensureLabelMask()
        mask.setLabel(3, x: 0, y: 0, z: 0)
        mask.setLabel(7, x: 3, y: 3, z: 3)

        let url = tmpDir.appendingPathComponent("atlas.nii")
        try NiftiWriter.writeMask(mask, basedOn: vol, kind: .atlas, to: url, gzip: false)
        let vals = try NiftiImage.read(contentsOf: url).calibratedDoubleVolume(timepoint: 0)
        XCTAssertEqual(vals[0], 3)
        XCTAssertEqual(vals[3 + 4 * 3 + 16 * 3], 7)

        // The same mask as a binary mask collapses both to 1.
        let maskURL = tmpDir.appendingPathComponent("atlas_as_mask.nii")
        try NiftiWriter.writeMask(mask, basedOn: vol, kind: .binaryMask, to: maskURL, gzip: false)
        let mvals = try NiftiImage.read(contentsOf: maskURL).calibratedDoubleVolume(timepoint: 0)
        XCTAssertEqual(mvals[0], 1)
        XCTAssertEqual(mvals[3 + 4 * 3 + 16 * 3], 1)
    }

    func testGzipRoundTrip() throws {
        let vol = makeCanonicalVolume(5, 6, 7)
        let mask = vol.ensureLabelMask()
        mask.setLabel(2, x: 1, y: 1, z: 1)
        mask.setLabel(2, x: 4, y: 5, z: 6)

        let url = tmpDir.appendingPathComponent("mask.nii.gz")
        try NiftiWriter.writeMask(mask, basedOn: vol, kind: .atlas, to: url, gzip: true)
        // Sanity: it's really gzipped.
        let raw = try Data(contentsOf: url)
        XCTAssertEqual(raw[0], 0x1f); XCTAssertEqual(raw[1], 0x8b)

        let vals = try NiftiImage.read(contentsOf: url).calibratedDoubleVolume(timepoint: 0)
        XCTAssertEqual(nonzero(vals), 2)
        XCTAssertEqual(vals[1 + 5 * 1 + 30 * 1], 2)
        XCTAssertEqual(vals[4 + 5 * 5 + 30 * 6], 2)
    }

    // MARK: - Write-back to the original grid

    func testWriteBackToOriginalGrid() throws {
        // Canonical (4,5,6); reorientation swaps i↔k → source dims (6,5,4).
        let reorient = CanonicalReorientation(sourceAxis: (2, 1, 0), flip: (false, false, false))
        let identity = matrix_identity_double4x4
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: 4 * 5 * 6)
        buf.initialize(repeating: 0)
        let vol = VolumeData(
            voxels: buf, width: 4, height: 5, depth: 6,
            voxelToWorld: identity, rescaleSlope: 1, rescaleIntercept: 0,
            seriesUID: "wb", originalAffine: identity, reorientation: reorient)
        let mask = vol.ensureLabelMask()
        mask.setLabel(7, x: 1, y: 2, z: 3)   // canonical voxel (1,2,3)

        let url = tmpDir.appendingPathComponent("wb.nii")
        try NiftiWriter.writeMask(mask, basedOn: vol, kind: .atlas, to: url, gzip: false)
        let img = try NiftiImage.read(contentsOf: url)

        // Source dims are the ORIGINAL grid, not the canonical grid.
        XCTAssertEqual(img.nx, 6); XCTAssertEqual(img.ny, 5); XCTAssertEqual(img.nz, 4)
        let vals = img.calibratedDoubleVolume(timepoint: 0)
        XCTAssertEqual(nonzero(vals), 1)

        // canonical (1,2,3) → source (3,2,1) → linear 3 + 6*2 + 30*1 = 45.
        let src = reorient.sourceIndex(forCanonical: (1, 2, 3), srcDims: (6, 5, 4))
        XCTAssertEqual(src.0, 3); XCTAssertEqual(src.1, 2); XCTAssertEqual(src.2, 1)
        XCTAssertEqual(vals[src.0 + 6 * src.1 + 30 * src.2], 7)
        assertAffineEqual(img.affine, identity)
    }

    // MARK: - LUT sidecar

    func testLUTSidecarParsesBack() throws {
        let r1 = CalcificationRegion(label: 1, name: "Calcification 1", color: SIMD3(1, 0, 0),
                                     parameters: .defaults(for: .thresholdInROI),
                                     box: VoxelBox(xRange: 0..<1, yRange: 0..<1, zRange: 0..<1))
        let r2 = CalcificationRegion(label: 2, name: "Left Basal Ganglia", color: SIMD3(0, 1, 0),
                                     parameters: .defaults(for: .growFromSeed),
                                     box: VoxelBox(xRange: 0..<1, yRange: 0..<1, zRange: 0..<1))
        let url = tmpDir.appendingPathComponent("atlas_LUT.txt")
        try NiftiWriter.writeLUT(regions: [r2, r1], to: url)

        let lut = try ColorLookupTable.parse(data: Data(contentsOf: url), name: "test")
        XCTAssertEqual(lut.entries[1]?.name, "Calcification_1")
        XCTAssertEqual(lut.entries[1]?.red, 255)
        XCTAssertEqual(lut.entries[2]?.name, "Left_Basal_Ganglia")
        XCTAssertEqual(lut.entries[2]?.green, 255)
        XCTAssertEqual(lut.entries[0]?.name, "Unknown")
    }
}
