// SegmentationBoxMappingTests.swift
// Lentis Tests
//
// Phase 9 — locks the ROI-box mapping: an in-plane drag rect on an orthogonal
// MPR panel maps (through the ONE orientation source, PlaneGeometry) to the
// expected voxel ranges on the two in-plane axes, with the slab centered on the
// plane's current slice along the third axis. A drift here would mean the drawn
// box and the segmented voxels disagree.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class SegmentationBoxMappingTests: XCTestCase {

    /// Identity-affine 1 mm canonical volume: voxelToWorld(i,j,k) = (i,j,k).
    private func makeVolume(_ n: Int = 40) -> VolumeData {
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: n * n * n)
        buf.initialize(repeating: 0)
        return VolumeData(
            voxels: buf, width: n, height: n, depth: n,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: SIMD3(0, 0, 0),
            rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
            rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "box-map")
    }

    func testAxialRectMapsToXYRangesWithZSlab() {
        let vol = makeVolume(40)
        let g = MPREngine(volume: vol).planeGeometry(.mprAxial, sliceIndex: 20)!
        let result = VoxelBox.fromPlanePoints(CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 15),
                                              geometry: g, volume: vol,
                                              mode: .mprAxial, sliceIndex: 20, slabDepth: 5)
        guard let result else { return XCTFail("nil box") }
        XCTAssertEqual(result.box.xRange, 10..<21)
        XCTAssertEqual(result.box.yRange, 24..<35)   // row→Anterior flip: 39-15 … 39-5
        XCTAssertEqual(result.box.zRange, 18..<23)    // slab depth 5 centered on z=20
        XCTAssertEqual(result.slabAxis, 2)
    }

    func testSagittalRectMapsToYZRangesWithXSlab() {
        let vol = makeVolume(40)
        let g = MPREngine(volume: vol).planeGeometry(.mprSagittal, sliceIndex: 15)!
        let result = VoxelBox.fromPlanePoints(CGPoint(x: 10, y: 5), CGPoint(x: 18, y: 12),
                                              geometry: g, volume: vol,
                                              mode: .mprSagittal, sliceIndex: 15, slabDepth: 5)
        guard let result else { return XCTFail("nil box") }
        XCTAssertEqual(result.box.xRange, 13..<18)    // slab depth 5 centered on x=15
        XCTAssertEqual(result.box.yRange, 21..<30)
        XCTAssertEqual(result.box.zRange, 27..<35)
        XCTAssertEqual(result.slabAxis, 0)
    }

    func testCoronalRectMapsToXZRangesWithYSlab() {
        let vol = makeVolume(40)
        let g = MPREngine(volume: vol).planeGeometry(.mprCoronal, sliceIndex: 12)!
        let result = VoxelBox.fromPlanePoints(CGPoint(x: 8, y: 6), CGPoint(x: 16, y: 14),
                                              geometry: g, volume: vol,
                                              mode: .mprCoronal, sliceIndex: 12, slabDepth: 3)
        guard let result else { return XCTFail("nil box") }
        XCTAssertEqual(result.box.xRange, 8..<17)
        XCTAssertEqual(result.box.yRange, 11..<14)    // slab depth 3 centered on y=12
        XCTAssertEqual(result.box.zRange, 25..<34)    // row→Superior flip: 39-14 … 39-6
        XCTAssertEqual(result.slabAxis, 1)
    }

    func testSlabClampedToVolumeBounds() {
        let vol = makeVolume(40)
        let g = MPREngine(volume: vol).planeGeometry(.mprAxial, sliceIndex: 0)!
        let result = VoxelBox.fromPlanePoints(CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 10),
                                              geometry: g, volume: vol,
                                              mode: .mprAxial, sliceIndex: 0, slabDepth: 9)!
        XCTAssertEqual(result.box.zRange.lowerBound, 0, "slab clamped at the low edge")
        XCTAssertLessThanOrEqual(result.box.zRange.upperBound, vol.depth)
    }
}
