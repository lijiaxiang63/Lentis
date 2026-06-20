// MPREngineTests.swift
// OpenDicomViewer Tests
//
// Tests for MPR slice extraction using small synthetic volumes.
// Validates axial, sagittal, coronal slices and slab projections.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class MPREngineTests: XCTestCase {

    // MARK: - Helpers

    /// Create a gradient volume where voxel(x,y,z) = x + y*width + z*width*height
    private func makeGradientVolume(width: Int = 4, height: Int = 4, depth: Int = 4) -> VolumeData {
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
            rescaleSlope: 1.0,
            rescaleIntercept: 0.0,
            seriesUID: "test-gradient"
        )
    }

    /// Read Int16 pixel values from MPRSlice data
    private func readPixels(from slice: MPRSlice) -> [Int16] {
        let count = slice.width * slice.height
        var result = [Int16](repeating: 0, count: count)
        slice.pixelData.withUnsafeBytes { buf in
            guard let src = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<count {
                result[i] = src[i]
            }
        }
        return result
    }

    /// Read a single displayed pixel at (col, row); row 0 is the top of the image.
    private func pixelAt(_ slice: MPRSlice, col: Int, row: Int) -> Int16 {
        slice.pixelData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            raw.bindMemory(to: Int16.self)[row * slice.width + col]
        }
    }

    // MARK: - Axial Slice

    func testAxialSliceDimensions() {
        let vol = makeGradientVolume(width: 8, height: 6, depth: 10)
        let engine = MPREngine(volume: vol)
        let slice = engine.axialSlice(at: 0)
        XCTAssertNotNil(slice)
        XCTAssertEqual(slice?.width, 8)
        XCTAssertEqual(slice?.height, 6)
    }

    func testAxialSliceNeurologicalOrientation() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)

        // Axial at z=0: voxel(x,y,0) = x + 4y. Canonical-RAS volume (i→R, j→A),
        // so the neurological layout flips j → Anterior (max y) at top, with
        // L (x=0) on the left.
        let s = engine.axialSlice(at: 0)!
        XCTAssertEqual(pixelAt(s, col: 0, row: 0), 12)  // top-left  (x=0,y=3) L/Anterior
        XCTAssertEqual(pixelAt(s, col: 3, row: 0), 15)  // top-right (x=3,y=3) R/Anterior
        XCTAssertEqual(pixelAt(s, col: 0, row: 3), 0)   // bot-left  (x=0,y=0) L/Posterior
        XCTAssertEqual(pixelAt(s, col: 3, row: 3), 3)   // bot-right (x=3,y=0) R/Posterior

        // z=1 adds 16 to every voxel.
        let s1 = engine.axialSlice(at: 1)!
        XCTAssertEqual(pixelAt(s1, col: 0, row: 3), 16) // (x=0,y=0,z=1)
    }

    func testCoronalSliceNeurologicalOrientation() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)

        // Coronal at y=0: voxel(x,0,z) = x + 16z. cols = i (L→R); rows flipped so
        // Superior (max z) on top.
        let s = engine.coronalSlice(at: 0)!
        XCTAssertEqual(s.width, 4)   // i / R
        XCTAssertEqual(s.height, 4)  // k / S
        XCTAssertEqual(pixelAt(s, col: 0, row: 0), 48)  // top-left  (x=0,z=3) L/Superior
        XCTAssertEqual(pixelAt(s, col: 3, row: 0), 51)  // top-right (x=3,z=3) R/Superior
        XCTAssertEqual(pixelAt(s, col: 0, row: 3), 0)   // bot-left  (x=0,z=0) L/Inferior
        XCTAssertEqual(pixelAt(s, col: 3, row: 3), 3)   // bot-right (x=3,z=0) R/Inferior
    }

    func testSagittalSliceNeurologicalOrientation() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)

        // Sagittal at x=0: voxel(0,y,z) = 4y + 16z. cols flipped so Anterior
        // (max y) on left; rows flipped so Superior (max z) on top.
        let s = engine.sagittalSlice(at: 0)!
        XCTAssertEqual(s.width, 4)   // j / A
        XCTAssertEqual(s.height, 4)  // k / S
        XCTAssertEqual(pixelAt(s, col: 0, row: 0), 60)  // top-left  (y=3,z=3) Anterior/Superior
        XCTAssertEqual(pixelAt(s, col: 3, row: 0), 48)  // top-right (y=0,z=3) Posterior/Superior
        XCTAssertEqual(pixelAt(s, col: 0, row: 3), 12)  // bot-left  (y=3,z=0) Anterior/Inferior
        XCTAssertEqual(pixelAt(s, col: 3, row: 3), 0)   // bot-right (y=0,z=0) Posterior/Inferior
    }

    /// The slice plane directions (which drive the orientation labels) must read
    /// as the expected anatomy for a canonical-RAS volume.
    func testSlicePlaneDirectionsAreNeurological() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)

        let ax = engine.axialSlice(at: 2)!
        XCTAssertEqual(anatomicalDirection(of: ax.planeRowDir), .R)   // screen-right
        XCTAssertEqual(anatomicalDirection(of: ax.planeColDir), .P)   // screen-down

        let cor = engine.coronalSlice(at: 2)!
        XCTAssertEqual(anatomicalDirection(of: cor.planeRowDir), .R)
        XCTAssertEqual(anatomicalDirection(of: cor.planeColDir), .I)

        let sag = engine.sagittalSlice(at: 2)!
        XCTAssertEqual(anatomicalDirection(of: sag.planeRowDir), .P)  // anterior-left ⇒ right is P
        XCTAssertEqual(anatomicalDirection(of: sag.planeColDir), .I)
    }

    func testAxialSliceOutOfBounds() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)
        XCTAssertNil(engine.axialSlice(at: -1))
        XCTAssertNil(engine.axialSlice(at: 4))
    }

    func testAxialSliceSpacing() {
        let count = 4 * 4 * 4
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
        buffer.initialize(repeating: 0)
        let vol = VolumeData(
            voxels: buffer,
            width: 4, height: 4, depth: 4,
            spacingX: 0.5, spacingY: 0.7, spacingZ: 3.0,
            origin: SIMD3<Double>(0, 0, 0),
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1.0,
            rescaleIntercept: 0.0,
            seriesUID: "test"
        )
        let engine = MPREngine(volume: vol)
        let slice = engine.axialSlice(at: 0)!
        XCTAssertEqual(slice.pixelSpacingX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(slice.pixelSpacingY, 0.7, accuracy: 1e-9)
    }

    // MARK: - Sagittal Slice

    func testSagittalSliceDimensions() {
        let vol = makeGradientVolume(width: 4, height: 6, depth: 8)
        let engine = MPREngine(volume: vol)
        let slice = engine.sagittalSlice(at: 0)
        XCTAssertNotNil(slice)
        // Sagittal: width = height dim (Y), height = depth dim (Z)
        XCTAssertEqual(slice?.width, 6)
        XCTAssertEqual(slice?.height, 8)
    }

    func testSagittalSliceOutOfBounds() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)
        XCTAssertNil(engine.sagittalSlice(at: -1))
        XCTAssertNil(engine.sagittalSlice(at: 4))
    }

    func testSagittalSliceSpacing() {
        let count = 4 * 4 * 4
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
        buffer.initialize(repeating: 0)
        let vol = VolumeData(
            voxels: buffer,
            width: 4, height: 4, depth: 4,
            spacingX: 0.5, spacingY: 0.7, spacingZ: 3.0,
            origin: SIMD3<Double>(0, 0, 0),
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1.0,
            rescaleIntercept: 0.0,
            seriesUID: "test"
        )
        let engine = MPREngine(volume: vol)
        let slice = engine.sagittalSlice(at: 0)!
        // Sagittal spacing: X = spacingY, Y = spacingZ
        XCTAssertEqual(slice.pixelSpacingX, 0.7, accuracy: 1e-9)
        XCTAssertEqual(slice.pixelSpacingY, 3.0, accuracy: 1e-9)
    }

    // MARK: - Coronal Slice

    func testCoronalSliceDimensions() {
        let vol = makeGradientVolume(width: 4, height: 6, depth: 8)
        let engine = MPREngine(volume: vol)
        let slice = engine.coronalSlice(at: 0)
        XCTAssertNotNil(slice)
        // Coronal: width = width dim (X), height = depth dim (Z)
        XCTAssertEqual(slice?.width, 4)
        XCTAssertEqual(slice?.height, 8)
    }

    func testCoronalSliceOutOfBounds() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)
        XCTAssertNil(engine.coronalSlice(at: -1))
        XCTAssertNil(engine.coronalSlice(at: 4))
    }

    // MARK: - Axial Slab Projection

    func testMIPProjectionMaximum() {
        // Create a volume where slice 0 has value 10, slice 1 has value 20
        let w = 2, h = 2, d = 2
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: w * h * d)
        // Slice 0: all 10
        for i in 0..<(w * h) { buffer[i] = 10 }
        // Slice 1: all 20
        for i in (w * h)..<(w * h * d) { buffer[i] = 20 }

        let vol = VolumeData(
            voxels: buffer,
            width: w, height: h, depth: d,
            spacingX: 1.0, spacingY: 1.0, spacingZ: 1.0,
            origin: SIMD3<Double>(0, 0, 0),
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1.0,
            rescaleIntercept: 0.0,
            seriesUID: "test"
        )
        let engine = MPREngine(volume: vol)
        let slice = engine.axialSlabProjection(mode: .mip, slabCenter: 0, slabThickness: 4)
        XCTAssertNotNil(slice)

        let pixels = readPixels(from: slice!)
        // MIP should take max value: 20 from all pixels
        for p in pixels {
            XCTAssertEqual(p, 20)
        }
    }

    func testMinIPProjectionMinimum() {
        let w = 2, h = 2, d = 2
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: w * h * d)
        for i in 0..<(w * h) { buffer[i] = 10 }
        for i in (w * h)..<(w * h * d) { buffer[i] = 20 }

        let vol = VolumeData(
            voxels: buffer,
            width: w, height: h, depth: d,
            spacingX: 1.0, spacingY: 1.0, spacingZ: 1.0,
            origin: SIMD3<Double>(0, 0, 0),
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1.0,
            rescaleIntercept: 0.0,
            seriesUID: "test"
        )
        let engine = MPREngine(volume: vol)
        let slice = engine.axialSlabProjection(mode: .minip, slabCenter: 0, slabThickness: 4)
        XCTAssertNotNil(slice)

        let pixels = readPixels(from: slice!)
        for p in pixels {
            XCTAssertEqual(p, 10)
        }
    }

    func testAverageProjection() {
        let w = 2, h = 2, d = 2
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: w * h * d)
        for i in 0..<(w * h) { buffer[i] = 10 }
        for i in (w * h)..<(w * h * d) { buffer[i] = 30 }

        let vol = VolumeData(
            voxels: buffer,
            width: w, height: h, depth: d,
            spacingX: 1.0, spacingY: 1.0, spacingZ: 1.0,
            origin: SIMD3<Double>(0, 0, 0),
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1.0,
            rescaleIntercept: 0.0,
            seriesUID: "test"
        )
        let engine = MPREngine(volume: vol)
        let slice = engine.axialSlabProjection(mode: .average, slabCenter: 0, slabThickness: 4)
        XCTAssertNotNil(slice)

        let pixels = readPixels(from: slice!)
        // Average of 10 and 30 = 20
        for p in pixels {
            XCTAssertEqual(p, 20)
        }
    }

    // MARK: - ProjectionMode enum

    func testProjectionModeAllCases() {
        let modes = ProjectionMode.allCases
        XCTAssertEqual(modes.count, 3)
        XCTAssertTrue(modes.contains(.mip))
        XCTAssertTrue(modes.contains(.minip))
        XCTAssertTrue(modes.contains(.average))
    }

    func testProjectionModeRawValue() {
        XCTAssertEqual(ProjectionMode.mip.rawValue, "MIP")
        XCTAssertEqual(ProjectionMode.minip.rawValue, "MinIP")
        XCTAssertEqual(ProjectionMode.average.rawValue, "Average")
    }

    // MARK: - Oblique Slice

    func testObliqueSliceDimensions() {
        let vol = makeGradientVolume(width: 8, height: 8, depth: 8)
        let engine = MPREngine(volume: vol)
        let slice = engine.obliqueSlice(
            origin: SIMD3<Double>(4, 4, 4),
            rowDir: SIMD3<Double>(1, 0, 0),
            colDir: SIMD3<Double>(0, 1, 0),
            width: 10,
            height: 12,
            spacing: 0.5
        )
        XCTAssertEqual(slice.width, 10)
        XCTAssertEqual(slice.height, 12)
        XCTAssertEqual(slice.pixelSpacingX, 0.5)
        XCTAssertEqual(slice.pixelSpacingY, 0.5)
    }
}
