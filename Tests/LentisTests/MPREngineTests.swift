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

    // MARK: - Crosshair Geometry (Phase 6)

    /// `world(col:row:)` and `pixel(of:)` must be exact inverses for every
    /// orthogonal plane (so a click maps to a world point that projects back to
    /// the same pixel).
    func testPlaneGeometryPixelWorldRoundTrip() {
        let vol = makeGradientVolume(width: 8, height: 6, depth: 10)
        let engine = MPREngine(volume: vol)
        for mode in [PanelMode.mprAxial, .mprSagittal, .mprCoronal] {
            guard let g = engine.planeGeometry(mode, sliceIndex: 3) else {
                XCTFail("no plane geometry for \(mode)"); continue
            }
            let w = g.world(col: 2.0, row: 1.5)
            let p = g.pixel(of: w)
            XCTAssertEqual(p.x, 2.0, accuracy: 1e-9, "\(mode) col round-trip")
            XCTAssertEqual(p.y, 1.5, accuracy: 1e-9, "\(mode) row round-trip")
        }
    }

    /// With the identity-affine gradient volume, world == voxel, so a world
    /// point maps to the obvious per-axis slice index.
    func testOrthogonalSliceIndexFromWorld() {
        let vol = makeGradientVolume(width: 8, height: 6, depth: 10)
        let engine = MPREngine(volume: vol)
        let world = SIMD3<Double>(2, 1, 3)  // x=2, y=1, z=3
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprAxial, containing: world), 3)     // k
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprSagittal, containing: world), 2)  // i
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprCoronal, containing: world), 1)   // j
        XCTAssertNil(engine.orthogonalSliceIndex(for: .volume3D, containing: world))
        XCTAssertNil(engine.orthogonalSliceIndex(for: .slice2D, containing: world))
    }

    func testOrthogonalSliceIndexClampsOutOfBounds() {
        let vol = makeGradientVolume(width: 4, height: 4, depth: 4)
        let engine = MPREngine(volume: vol)
        let far = SIMD3<Double>(100, -100, 100)
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprAxial, containing: far), 3)     // depth-1
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprSagittal, containing: far), 3)  // width-1
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprCoronal, containing: far), 0)   // y<0 → 0
    }

    /// End-to-end crosshair mapping: clicking a pixel in the axial plane yields
    /// a world point that (a) leaves the axial slice unchanged, (b) relocates
    /// the sagittal/coronal planes to the matching indices, and (c) projects
    /// back onto the axial plane at the same pixel.
    func testCrosshairClickMapsAcrossPlanes() {
        let vol = makeGradientVolume(width: 8, height: 6, depth: 10)
        let engine = MPREngine(volume: vol)
        guard let ax = engine.planeGeometry(.mprAxial, sliceIndex: 5) else { return XCTFail() }
        let world = ax.world(col: 2, row: 1)  // axial top-left=(0,h-1,k); colDir=-A ⇒ y=(h-1)-row
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprAxial, containing: world), 5)
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprSagittal, containing: world), 2) // x = col
        XCTAssertEqual(engine.orthogonalSliceIndex(for: .mprCoronal, containing: world), 4)  // y = (6-1)-1
        let p = ax.pixel(of: world)
        XCTAssertEqual(p.x, 2, accuracy: 1e-9)
        XCTAssertEqual(p.y, 1, accuracy: 1e-9)
    }
}
