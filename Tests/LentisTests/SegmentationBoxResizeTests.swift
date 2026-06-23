// SegmentationBoxResizeTests.swift
// Lentis Tests
//
// Phase 9 — locks the interactive ROI-box resize geometry: the per-plane handle
// enumeration (4 corners + 4 edge mids) and the resize op that moves the grabbed
// in-plane bounds while leaving the slab (through-plane) axis untouched. This is
// the pure core behind dragging a box's handles to reshape it in 3D from any of
// the three orthogonal planes; a drift here means the drawn handle and the voxels
// it edits disagree.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class SegmentationBoxResizeTests: XCTestCase {

    /// Box: x 10..20, y 24..34, z 18..22 (half-open 10..<21, 24..<35, 18..<23).
    private func sampleBox() -> VoxelBox {
        VoxelBox(xRange: 10..<21, yRange: 24..<35, zRange: 18..<23)
    }

    // MARK: - Axis mapping

    func testSlabAndInPlaneAxesPerPlane() {
        XCTAssertEqual(VoxelBox.slabAxis(forPlane: .mprAxial), 2)
        XCTAssertEqual(VoxelBox.slabAxis(forPlane: .mprSagittal), 0)
        XCTAssertEqual(VoxelBox.slabAxis(forPlane: .mprCoronal), 1)
        XCTAssertNil(VoxelBox.slabAxis(forPlane: .volume3D))
        XCTAssertEqual(VoxelBox.inPlaneAxes(forPlane: .mprAxial).map { [$0.0, $0.1] }, [0, 1])
        XCTAssertEqual(VoxelBox.inPlaneAxes(forPlane: .mprSagittal).map { [$0.0, $0.1] }, [1, 2])
        XCTAssertEqual(VoxelBox.inPlaneAxes(forPlane: .mprCoronal).map { [$0.0, $0.1] }, [0, 2])
    }

    // MARK: - Handle enumeration

    func testAxialHandlesAreEightOnContainingSlice() {
        let box = sampleBox()
        let h = box.handles(plane: .mprAxial, sliceIndex: 20)
        XCTAssertEqual(h.count, 8)
        // The slab axis (z) coordinate is the displayed slice for every handle.
        XCTAssertTrue(h.allSatisfy { $0.voxel.z == 20 })
        // The four corners cover both bounds of x and y.
        let corner = h.first { $0.gripA == .lower && $0.gripB == .lower }!
        XCTAssertEqual(corner.voxel.x, 10)
        XCTAssertEqual(corner.voxel.y, 24)
        // An edge midpoint fixes one axis (center) and moves the other.
        let edge = h.first { $0.gripA == .fixed && $0.gripB == .upper }!
        XCTAssertEqual(edge.voxel.x, 15)   // center of x: (10+20)/2
        XCTAssertEqual(edge.voxel.y, 34)   // upper of y
    }

    func testHandlesEmptyWhenSliceOutsideSlab() {
        let box = sampleBox()
        XCTAssertTrue(box.handles(plane: .mprAxial, sliceIndex: 25).isEmpty) // 25 ∉ 18..<23
        XCTAssertTrue(box.handles(plane: .volume3D, sliceIndex: 20).isEmpty)
        let empty = VoxelBox(xRange: 0..<0, yRange: 0..<0, zRange: 0..<0)
        XCTAssertTrue(empty.handles(plane: .mprAxial, sliceIndex: 0).isEmpty)
    }

    // MARK: - Resize op

    func testAxialCornerResizeMovesXYLeavesZ() {
        var box = sampleBox()
        // Drag the (x-upper, y-upper) corner out to (30, 40).
        box.resize(plane: .mprAxial, gripA: .upper, gripB: .upper, toVoxel: SIMD3(30, 40, 99))
        XCTAssertEqual(box.xRange, 10..<31)
        XCTAssertEqual(box.yRange, 24..<41)
        XCTAssertEqual(box.zRange, 18..<23, "slab axis (z) is untouched by an axial resize")
    }

    func testAxialEdgeResizeMovesOnlyOneAxis() {
        var box = sampleBox()
        // Edge handle: move x-lower only (y is fixed).
        box.resize(plane: .mprAxial, gripA: .lower, gripB: .fixed, toVoxel: SIMD3(4, 99, 99))
        XCTAssertEqual(box.xRange, 4..<21)
        XCTAssertEqual(box.yRange, 24..<35)
        XCTAssertEqual(box.zRange, 18..<23)
    }

    func testSagittalResizeEditsDepthZ() {
        var box = sampleBox()
        // On sagittal the in-plane axes are (y, z); the z handle edits DEPTH.
        // Grab (y fixed, z upper) and drag z out to 30.
        box.resize(plane: .mprSagittal, gripA: .fixed, gripB: .upper, toVoxel: SIMD3(99, 99, 30))
        XCTAssertEqual(box.zRange, 18..<31, "sagittal handle extends the through-plane depth")
        XCTAssertEqual(box.xRange, 10..<21, "sagittal slab axis (x) is untouched")
        XCTAssertEqual(box.yRange, 24..<35)
    }

    func testCoronalResizeEditsDepthZAndX() {
        var box = sampleBox()
        // Coronal in-plane axes (x, z); grab the (x-lower, z-lower) corner.
        box.resize(plane: .mprCoronal, gripA: .lower, gripB: .lower, toVoxel: SIMD3(2, 99, 5))
        XCTAssertEqual(box.xRange, 2..<21)
        XCTAssertEqual(box.zRange, 5..<23)
        XCTAssertEqual(box.yRange, 24..<35, "coronal slab axis (y) is untouched")
    }

    func testResizeDraggingPastOppositeEdgeNormalizes() {
        var box = sampleBox()
        // Drag x-lower past the upper bound; setSpan should keep ranges valid.
        box.resize(plane: .mprAxial, gripA: .lower, gripB: .fixed, toVoxel: SIMD3(40, 99, 99))
        XCTAssertEqual(box.xRange.lowerBound, 20)
        XCTAssertEqual(box.xRange.upperBound, 41)
        XCTAssertFalse(box.isEmpty)
    }
}
