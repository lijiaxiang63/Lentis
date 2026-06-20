// LabelVolume.swift
// Lentis
//
// SEAM (Phase 7) for a future intracranial-calcification segmentation feature
// (CT/HU-oriented). A same-grid segmentation label/mask volume that rides
// alongside a VolumeData: identical width×height×depth, indexed in the SAME
// canonical voxel grid, so a label at (i,j,k) tags the same anatomical voxel as
// VolumeData.voxels[(i,j,k)]. It therefore implicitly shares the parent's
// voxelToWorldMatrix and — via the parent's `originalAffine` + `reorientation`
// — its mask write-back mapping to the *original* (pre-canonical) NIfTI grid.
//
// One UInt8 label per voxel: 0 = background, 1…255 = class ids (a single
// calcification class needs only 0/1). Nothing populates this in normal runs;
// it exists so segmentation can be added without reshaping the volume or render
// pipeline. See `VolumeData.labelMask`, `MPREngine.maskSlice`, and the
// `mask:` overload of `MPREngine.renderSlice` for the render seam.
//
// Memory is manually allocated (mirroring VolumeData) to avoid Swift Array
// overhead for large masks, and freed in deinit.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

/// A same-grid segmentation mask for a `VolumeData`. See file header.
final class LabelVolume {
    let width: Int       // columns (X / i)
    let height: Int      // rows (Y / j)
    let depth: Int       // slices (Z / k)

    /// One label per voxel in [z][y][x] (slice-major) order — the SAME layout
    /// as `VolumeData.voxels`, so indices map 1:1 to the parent's voxels.
    let labels: UnsafeMutableBufferPointer<UInt8>

    private let sliceStride: Int  // width * height

    /// Allocate a zeroed (all-background) mask of the given dimensions.
    init(width: Int, height: Int, depth: Int) {
        precondition(width > 0 && height > 0 && depth > 0,
                     "LabelVolume requires positive dimensions")
        self.width = width
        self.height = height
        self.depth = depth
        self.sliceStride = width * height
        let count = width * height * depth
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: count)
        buf.initialize(repeating: 0)
        self.labels = buf
    }

    deinit { labels.deallocate() }

    /// Label at integer voxel coordinates. Returns 0 (background) if out of bounds.
    @inline(__always)
    func labelAt(x: Int, y: Int, z: Int) -> UInt8 {
        guard x >= 0, x < width, y >= 0, y < height, z >= 0, z < depth else { return 0 }
        return labels[z * sliceStride + y * width + x]
    }

    /// Set the label at integer voxel coordinates. No-op if out of bounds.
    @inline(__always)
    func setLabel(_ value: UInt8, x: Int, y: Int, z: Int) {
        guard x >= 0, x < width, y >= 0, y < height, z >= 0, z < depth else { return }
        labels[z * sliceStride + y * width + x] = value
    }

    /// Reset every voxel to background (0).
    func clear() {
        labels.update(repeating: 0)
    }

    /// Total labeled (non-background) voxels. Linear scan — fine for a seam/demo
    /// and for cheap "is anything painted?" checks; segmentation can maintain a
    /// running count if this ever becomes hot.
    var labeledVoxelCount: Int {
        var n = 0
        for v in labels where v != 0 { n += 1 }
        return n
    }
}
