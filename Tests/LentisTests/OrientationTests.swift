// OrientationTests.swift
// Lentis
//
// Tests the pure orientation math: RAS-aware anatomical labelling and the
// closest-canonical reorientation (permutation + flips) derived from an affine.
// No app/UI dependencies — exercises Orientation.swift in isolation.

import Testing
import simd
@testable import Lentis

// MARK: - Helpers

/// Build a voxel→world affine from three world-space rows (NIfTI `srow` form:
/// each row is [m_x, m_y, m_z, translation]).
private func affine(_ rows: [[Double]]) -> simd_double4x4 {
    let r = rows
    return simd_double4x4(columns: (
        SIMD4<Double>(r[0][0], r[1][0], r[2][0], 0),
        SIMD4<Double>(r[0][1], r[1][1], r[2][1], 0),
        SIMD4<Double>(r[0][2], r[1][2], r[2][2], 0),
        SIMD4<Double>(r[0][3], r[1][3], r[2][3], 1)
    ))
}

private func approxEqual(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tol: Double = 1e-9) -> Bool {
    simd_length(a - b) <= tol
}

private func worldOf(_ m: simd_double4x4, _ v: SIMD3<Double>) -> SIMD3<Double> {
    let h = m * SIMD4<Double>(v.x, v.y, v.z, 1)
    return SIMD3<Double>(h.x, h.y, h.z)
}

// MARK: - anatomicalDirection (RAS)

@Test func anatomicalDirectionMapsCardinalAxes() {
    #expect(anatomicalDirection(of: SIMD3(1, 0, 0)) == .R)
    #expect(anatomicalDirection(of: SIMD3(-1, 0, 0)) == .L)
    #expect(anatomicalDirection(of: SIMD3(0, 1, 0)) == .A)
    #expect(anatomicalDirection(of: SIMD3(0, -1, 0)) == .P)
    #expect(anatomicalDirection(of: SIMD3(0, 0, 1)) == .S)
    #expect(anatomicalDirection(of: SIMD3(0, 0, -1)) == .I)
}

@Test func anatomicalDirectionPicksDominantAxisOfObliqueVector() {
    // Slightly tilted "Right" direction still reads as R.
    #expect(anatomicalDirection(of: SIMD3(0.97, 0.12, -0.08)) == .R)
    #expect(anatomicalDirection(of: SIMD3(0.05, -0.99, 0.10)) == .P)
}

@Test func anatomicalDirectionOpposites() {
    #expect(AnatomicalDirection.R.opposite == .L)
    #expect(AnatomicalDirection.A.opposite == .P)
    #expect(AnatomicalDirection.S.opposite == .I)
}

// MARK: - Identity (already canonical RAS)

@Test func identityAffineIsCanonical() {
    let a = affine([[1, 0, 0, -32], [0, 1, 0, -32], [0, 0, 1, -24]])
    let r = closestCanonicalReorientation(affine: a)
    #expect(r.isIdentity)
    #expect(r.canonicalDims((64, 64, 48)) == (64, 64, 48))

    // Canonical affine equals the source affine column-for-column.
    let ca = r.canonicalAffine(source: a, srcDims: (64, 64, 48))
    #expect(approxEqual(worldOf(ca, SIMD3(0, 0, 0)), worldOf(a, SIMD3(0, 0, 0))))
    #expect(approxEqual(worldOf(ca, SIMD3(63, 63, 47)), worldOf(a, SIMD3(63, 63, 47))))
}

// MARK: - LAS (radiologically-stored CT: voxel-i → Left)

@Test func lasAffineFlipsFirstAxisOnly() {
    // Mimics the real CT: i→L (negative x), j→A, k→S.
    let a = affine([[-0.409, 0, 0, 104.5], [0, 0.409, 0, 105.0], [0, 0, 0.7, -739.7]])
    let r = closestCanonicalReorientation(affine: a)
    #expect(r.sourceAxis == (0, 1, 2))
    #expect(r.flip == (true, false, false))
    #expect(!r.isIdentity)

    // After canonicalisation, voxel-i must increase toward +x (Right).
    let ca = r.canonicalAffine(source: a, srcDims: (512, 512, 221))
    let di = worldOf(ca, SIMD3(1, 0, 0)) - worldOf(ca, SIMD3(0, 0, 0))
    #expect(anatomicalDirection(of: di) == .R)
}

@Test func lasCanonicalPreservesWorldPoints() {
    let a = affine([[-0.409, 0, 0, 104.5], [0, 0.409, 0, 105.0], [0, 0, 0.7, -739.7]])
    let dims = (512, 512, 221)
    let r = closestCanonicalReorientation(affine: a)
    let ca = r.canonicalAffine(source: a, srcDims: dims)

    // Each canonical voxel maps to the same physical point as its source voxel.
    for canon in [(0, 0, 0), (511, 0, 0), (0, 511, 0), (0, 0, 220), (100, 200, 50)] {
        let src = r.sourceIndex(forCanonical: canon, srcDims: dims)
        let wCanon = worldOf(ca, SIMD3(Double(canon.0), Double(canon.1), Double(canon.2)))
        let wSrc = worldOf(a, SIMD3(Double(src.0), Double(src.1), Double(src.2)))
        #expect(approxEqual(wCanon, wSrc, tol: 1e-6))
    }
}

// MARK: - Fully permuted (sagittally-stored: i→S, j→A, k→R)

@Test func permutedAffineReordersAxes() {
    // voxel-i → S, voxel-j → A, voxel-k → R  (a sagittal acquisition order).
    let a = affine([[0, 0, 1, 5], [0, 1, 0, -10], [1, 0, 0, 7]])
    let r = closestCanonicalReorientation(affine: a)
    // canonical R←k(2), A←j(1), S←i(0)
    #expect(r.sourceAxis == (2, 1, 0))
    #expect(r.flip == (false, false, false))
    #expect(r.canonicalDims((176, 240, 240)) == (240, 240, 176))
}

@Test func permutedCanonicalAxesPointRAS() {
    let a = affine([[0, 0, 1, 5], [0, 1, 0, -10], [1, 0, 0, 7]])
    let dims = (40, 50, 60)
    let r = closestCanonicalReorientation(affine: a)
    let ca = r.canonicalAffine(source: a, srcDims: dims)
    let dR = worldOf(ca, SIMD3(1, 0, 0)) - worldOf(ca, SIMD3(0, 0, 0))
    let dA = worldOf(ca, SIMD3(0, 1, 0)) - worldOf(ca, SIMD3(0, 0, 0))
    let dS = worldOf(ca, SIMD3(0, 0, 1)) - worldOf(ca, SIMD3(0, 0, 0))
    #expect(anatomicalDirection(of: dR) == .R)
    #expect(anatomicalDirection(of: dA) == .A)
    #expect(anatomicalDirection(of: dS) == .S)

    // World-point preservation under permutation.
    for canon in [(0, 0, 0), (39, 0, 0), (0, 49, 0), (0, 0, 59), (10, 20, 30)] {
        let src = r.sourceIndex(forCanonical: canon, srcDims: dims)
        let wCanon = worldOf(ca, SIMD3(Double(canon.0), Double(canon.1), Double(canon.2)))
        let wSrc = worldOf(a, SIMD3(Double(src.0), Double(src.1), Double(src.2)))
        #expect(approxEqual(wCanon, wSrc, tol: 1e-6))
    }
}

// MARK: - Permutation + flip together (e.g. i→S, j→P, k→L)

@Test func permutedAndFlippedAxes() {
    // voxel-i → S(+), voxel-j → P(-y), voxel-k → L(-x)
    let a = affine([[0, 0, -1, 7], [0, -1, 0, 3], [1, 0, 0, -2]])
    let dims = (30, 30, 30)
    let r = closestCanonicalReorientation(affine: a)
    // canonical R←k(flip), A←j(flip), S←i(no flip)
    #expect(r.sourceAxis == (2, 1, 0))
    #expect(r.flip == (true, true, false))

    let ca = r.canonicalAffine(source: a, srcDims: dims)
    let dR = worldOf(ca, SIMD3(1, 0, 0)) - worldOf(ca, SIMD3(0, 0, 0))
    let dA = worldOf(ca, SIMD3(0, 1, 0)) - worldOf(ca, SIMD3(0, 0, 0))
    let dS = worldOf(ca, SIMD3(0, 0, 1)) - worldOf(ca, SIMD3(0, 0, 0))
    #expect(anatomicalDirection(of: dR) == .R)
    #expect(anatomicalDirection(of: dA) == .A)
    #expect(anatomicalDirection(of: dS) == .S)

    for canon in [(0, 0, 0), (29, 0, 0), (0, 29, 0), (0, 0, 29), (5, 15, 25)] {
        let src = r.sourceIndex(forCanonical: canon, srcDims: dims)
        let wCanon = worldOf(ca, SIMD3(Double(canon.0), Double(canon.1), Double(canon.2)))
        let wSrc = worldOf(a, SIMD3(Double(src.0), Double(src.1), Double(src.2)))
        #expect(approxEqual(wCanon, wSrc, tol: 1e-6))
    }
}
