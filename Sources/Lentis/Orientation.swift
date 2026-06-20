// Orientation.swift
// Lentis
//
// The single source of truth for anatomical orientation. NIfTI world space is
// RAS+ (+x = patient Right, +y = Anterior, +z = Superior). A volume's voxel
// axes, however, may map to those world axes in any permutation and sign
// (e.g. a radiologically-stored CT has voxel-i → Left; a sagittally-acquired
// MPRAGE permutes axes entirely).
//
// This file derives, purely from the affine:
//   1. `anatomicalDirection(of:)` — RAS-aware label for any world direction.
//   2. `closestCanonicalReorientation(affine:)` — the axis permutation + flips
//      that bring the voxel axes to closest-canonical RAS (i→R, j→A, k→S),
//      à la nibabel `as_closest_canonical`. The reorientation is a pure
//      relabel/flip of whole axes (no resampling) — lossless and exactly
//      invertible, so a segmentation mask built in canonical space maps back
//      to the original voxel grid for write-back.
//
// Reorienting every loaded NIfTI to canonical RAS means the orthogonal MPR
// planes (axial/sagittal/coronal) and the neurological display flips become
// fixed, deterministic transforms instead of per-file heuristics.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import simd

/// One of the six signed anatomical directions in NIfTI RAS world space.
enum AnatomicalDirection: String {
    case R, L, A, P, S, I

    var opposite: AnatomicalDirection {
        switch self {
        case .R: return .L
        case .L: return .R
        case .A: return .P
        case .P: return .A
        case .S: return .I
        case .I: return .S
        }
    }

    /// Single-letter label as displayed in the orientation overlay.
    var letter: String { rawValue }
}

/// Map a world-space direction vector (RAS+) to its dominant anatomical label.
/// +x = R, +y = A, +z = S (and their negatives). This is the RAS-correct
/// replacement for the legacy LPS label mapping.
func anatomicalDirection(of v: SIMD3<Double>) -> AnatomicalDirection {
    let ax = abs(v.x), ay = abs(v.y), az = abs(v.z)
    if ax >= ay && ax >= az { return v.x >= 0 ? .R : .L }
    if ay >= ax && ay >= az { return v.y >= 0 ? .A : .P }
    return v.z >= 0 ? .S : .I
}

/// Describes how to reorder/flip a volume's voxel axes so the resulting
/// (canonical) axes map to RAS: canonical axis 0 → R, 1 → A, 2 → S.
///
/// `sourceAxis.w` is the original voxel axis (0=i, 1=j, 2=k) that supplies
/// canonical axis `w`; `flip.w` reverses that axis when the original increases
/// toward the *negative* world direction.
struct CanonicalReorientation: Equatable {
    /// Original voxel axis feeding canonical (R, A, S).
    let sourceAxis: (Int, Int, Int)
    /// Whether each source axis is reversed.
    let flip: (Bool, Bool, Bool)

    static func == (lhs: CanonicalReorientation, rhs: CanonicalReorientation) -> Bool {
        lhs.sourceAxis == rhs.sourceAxis && lhs.flip == rhs.flip
    }

    /// True when the volume is already canonical RAS (no relabel, no flip).
    var isIdentity: Bool {
        sourceAxis == (0, 1, 2) && flip == (false, false, false)
    }

    /// Canonical (width, height, depth) given the source voxel dims (nx, ny, nz).
    func canonicalDims(_ src: (Int, Int, Int)) -> (Int, Int, Int) {
        let sd = [src.0, src.1, src.2]
        return (sd[sourceAxis.0], sd[sourceAxis.1], sd[sourceAxis.2])
    }

    /// Map a canonical voxel index → the source voxel index it came from.
    /// Used both to fill the reoriented buffer and (in reverse, via the same
    /// descriptor) to write segmentation labels back to the original grid.
    func sourceIndex(forCanonical c: (Int, Int, Int), srcDims: (Int, Int, Int)) -> (Int, Int, Int) {
        let sd = [srcDims.0, srcDims.1, srcDims.2]
        let cidx = [c.0, c.1, c.2]
        let sa = [sourceAxis.0, sourceAxis.1, sourceAxis.2]
        let fl = [flip.0, flip.1, flip.2]
        var src = [0, 0, 0]
        for w in 0..<3 {
            let a = sa[w]
            src[a] = fl[w] ? (sd[a] - 1 - cidx[w]) : cidx[w]
        }
        return (src[0], src[1], src[2])
    }

    /// 4×4 matrix mapping a canonical voxel (homogeneous) → source voxel
    /// (homogeneous). Composing the source affine with this yields the
    /// canonical affine that maps canonical voxels to the *same* world points:
    /// `canonicalAffine = sourceAffine * canonicalToSourceMatrix(...)`.
    func canonicalToSourceMatrix(srcDims: (Int, Int, Int)) -> simd_double4x4 {
        let sd = [srcDims.0, srcDims.1, srcDims.2]
        let sa = [sourceAxis.0, sourceAxis.1, sourceAxis.2]
        let fl = [flip.0, flip.1, flip.2]
        var col = [SIMD4<Double>(repeating: 0), SIMD4<Double>(repeating: 0), SIMD4<Double>(repeating: 0)]
        var t = SIMD4<Double>(0, 0, 0, 1)
        for w in 0..<3 {
            let a = sa[w]
            var c4 = SIMD4<Double>(repeating: 0)
            c4[a] = fl[w] ? -1.0 : 1.0
            col[w] = c4
            if fl[w] { t[a] = Double(sd[a] - 1) }
        }
        return simd_double4x4(columns: (col[0], col[1], col[2], t))
    }

    /// The canonical (RAS) voxel→world affine for a volume with this
    /// reorientation, given its source affine and source dims.
    func canonicalAffine(source: simd_double4x4, srcDims: (Int, Int, Int)) -> simd_double4x4 {
        source * canonicalToSourceMatrix(srcDims: srcDims)
    }
}

/// Compute the reorientation that brings `affine`'s voxel axes to closest-
/// canonical RAS. Greedy dominant-axis assignment (each world axis used once),
/// which is exact for the well-conditioned affines clinical data carries.
func closestCanonicalReorientation(affine: simd_double4x4) -> CanonicalReorientation {
    // M[worldRow][voxelCol]: column c is the world direction of voxel axis c.
    let cols = [affine.columns.0, affine.columns.1, affine.columns.2]
    var M = [[Double]](repeating: [0, 0, 0], count: 3)
    for c in 0..<3 {
        M[0][c] = cols[c].x
        M[1][c] = cols[c].y
        M[2][c] = cols[c].z
    }

    // Greedily pair each voxel axis with the world axis it aligns with most.
    var worldOf = [Int](repeating: -1, count: 3)   // voxel axis → world axis
    var signOf = [Double](repeating: 1, count: 3)  // voxel axis → +1/-1
    var rowUsed = [Bool](repeating: false, count: 3)
    var colUsed = [Bool](repeating: false, count: 3)
    for _ in 0..<3 {
        var bestR = -1, bestC = -1, bestAbs = -1.0
        for r in 0..<3 where !rowUsed[r] {
            for c in 0..<3 where !colUsed[c] {
                let a = abs(M[r][c])
                if a > bestAbs { bestAbs = a; bestR = r; bestC = c }
            }
        }
        worldOf[bestC] = bestR
        signOf[bestC] = M[bestR][bestC] < 0 ? -1 : 1
        rowUsed[bestR] = true
        colUsed[bestC] = true
    }

    // Invert the pairing: for each world axis, which voxel axis feeds it.
    var srcAxis = [0, 0, 0]
    var flip = [false, false, false]
    for c in 0..<3 {
        let w = worldOf[c]
        srcAxis[w] = c
        flip[w] = signOf[c] < 0
    }
    return CanonicalReorientation(
        sourceAxis: (srcAxis[0], srcAxis[1], srcAxis[2]),
        flip: (flip[0], flip[1], flip[2])
    )
}
