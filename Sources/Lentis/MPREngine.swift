// MPREngine.swift
// OpenDicomViewer
//
// CPU-based Multi-Planar Reconstruction (MPR) engine. Extracts oblique 2D
// slices from a 3D VolumeData by sampling along orthogonal planes (sagittal,
// coronal) using trilinear interpolation. Converts the sampled voxel values
// to grayscale NSImage via window/level tone mapping.
//
// This is the fallback rendering path; GPU-accelerated rendering is handled
// by MetalVolumeRenderer for MIP projections.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import AppKit
import simd

// MARK: - MPR Engine

/// Result of an MPR slice generation
struct MPRSlice {
    let pixelData: Data     // Raw Int16 values
    let width: Int
    let height: Int
    let planeOrigin: SIMD3<Double>
    let planeRowDir: SIMD3<Double>
    let planeColDir: SIMD3<Double>
    let pixelSpacingX: Double
    let pixelSpacingY: Double
}

/// The displayed geometry of an orthogonal plane, independent of pixels:
/// the world position of the top-left pixel and the world directions toward
/// screen-right / screen-bottom, plus pixel spacing along each. This is the
/// single source of truth for orientation — the slice extractors fill their
/// plane fields from it, and the panel's cross-reference metadata + labels
/// read it back, so display, overlays, and labels can never disagree.
struct PlaneGeometry {
    let origin: SIMD3<Double>      // world coord of displayed top-left pixel
    let rowDir: SIMD3<Double>      // world dir toward screen-right (+column)
    let colDir: SIMD3<Double>      // world dir toward screen-bottom (+row)
    let pixelSpacingX: Double      // mm per column step (along rowDir)
    let pixelSpacingY: Double      // mm per row step (along colDir)
}

class MPREngine {
    let volume: VolumeData

    init(volume: VolumeData) {
        self.volume = volume
    }

    // MARK: - Orthogonal Slices
    //
    // These assume a **canonical-RAS** volume (i→R, j→A, k→S) — guaranteed for
    // NIfTI by NiftiDataset.makeVolume. The displayed buffer's row 0 is the top
    // of the screen and column 0 the left edge, so each plane applies a fixed,
    // deterministic flip to reach the standard neurological layout:
    //   • Axial:    L left / R right, Anterior top, Posterior bottom
    //   • Coronal:  L left / R right, Superior top, Inferior bottom
    //   • Sagittal: Anterior left / Posterior right, Superior top, Inferior bottom
    // Each MPRSlice reports planeRowDir (world dir toward screen-right) and
    // planeColDir (toward screen-bottom) consistent with that layout, so the
    // orientation labels and cross-reference lines derive from one source.

    /// The displayed geometry for an orthogonal plane at `sliceIndex`, without
    /// rendering pixels. Mirrors the flips applied by the extractors below, so
    /// the synchronous cross-reference path and the rendered slice agree.
    func planeGeometry(_ mode: PanelMode, sliceIndex: Int) -> PlaneGeometry? {
        switch mode {
        case .mprAxial:
            // top-left = (i=0=L, j=h−1=Anterior); right→R, down→P
            return PlaneGeometry(
                origin: volume.voxelToWorld(SIMD3(0, Double(volume.height - 1), Double(sliceIndex))),
                rowDir: volume.rowDirection,
                colDir: -volume.colDirection,
                pixelSpacingX: volume.spacingX,
                pixelSpacingY: volume.spacingY)
        case .mprSagittal:
            // top-left = (j=h−1=Anterior, k=d−1=Superior); right→P, down→I
            return PlaneGeometry(
                origin: volume.voxelToWorld(SIMD3(Double(sliceIndex), Double(volume.height - 1), Double(volume.depth - 1))),
                rowDir: -volume.colDirection,
                colDir: -volume.sliceDirection,
                pixelSpacingX: volume.spacingY,
                pixelSpacingY: volume.spacingZ)
        case .mprCoronal:
            // top-left = (i=0=L, k=d−1=Superior); right→R, down→I
            return PlaneGeometry(
                origin: volume.voxelToWorld(SIMD3(0, Double(sliceIndex), Double(volume.depth - 1))),
                rowDir: volume.rowDirection,
                colDir: -volume.sliceDirection,
                pixelSpacingX: volume.spacingX,
                pixelSpacingY: volume.spacingZ)
        default:
            return nil
        }
    }

    /// Generate an axial slice at a given Z (Superior) voxel index.
    func axialSlice(at zIndex: Int) -> MPRSlice? {
        guard zIndex >= 0, zIndex < volume.depth else { return nil }
        let w = volume.width    // i / R  (columns, L→R)
        let h = volume.height   // j / A  (rows; flipped so Anterior is on top)
        let offset = zIndex * w * h

        var data = Data(count: w * h * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for y in 0..<h {
                let dstRow = (h - 1 - y) * w   // Anterior (max j) at top
                let srcRow = offset + y * w
                for x in 0..<w { dst[dstRow + x] = volume.voxels[srcRow + x] }
            }
        }

        guard let g = planeGeometry(.mprAxial, sliceIndex: zIndex) else { return nil }
        return MPRSlice(
            pixelData: data, width: w, height: h,
            planeOrigin: g.origin, planeRowDir: g.rowDir, planeColDir: g.colDir,
            pixelSpacingX: g.pixelSpacingX, pixelSpacingY: g.pixelSpacingY)
    }

    /// Generate a sagittal slice at a given X (Right) voxel index.
    func sagittalSlice(at xIndex: Int) -> MPRSlice? {
        guard xIndex >= 0, xIndex < volume.width else { return nil }
        // cols span j (A); rows span k (S). Anterior at left, Superior at top.
        let w = volume.height   // j / A
        let h = volume.depth    // k / S

        var data = Data(count: w * h * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for z in 0..<volume.depth {
                let outRow = (volume.depth - 1 - z) * w   // Superior at top
                for y in 0..<volume.height {
                    let outCol = volume.height - 1 - y    // Anterior at left
                    dst[outRow + outCol] = volume.voxelAt(x: xIndex, y: y, z: z)
                }
            }
        }

        guard let g = planeGeometry(.mprSagittal, sliceIndex: xIndex) else { return nil }
        return MPRSlice(
            pixelData: data, width: w, height: h,
            planeOrigin: g.origin, planeRowDir: g.rowDir, planeColDir: g.colDir,
            pixelSpacingX: g.pixelSpacingX, pixelSpacingY: g.pixelSpacingY)
    }

    /// Generate a coronal slice at a given Y (Anterior) voxel index.
    func coronalSlice(at yIndex: Int) -> MPRSlice? {
        guard yIndex >= 0, yIndex < volume.height else { return nil }
        // cols span i (R); rows span k (S). L on left, Superior at top.
        let w = volume.width    // i / R
        let h = volume.depth    // k / S

        var data = Data(count: w * h * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for z in 0..<volume.depth {
                let outRow = (volume.depth - 1 - z) * w   // Superior at top
                for x in 0..<volume.width {
                    dst[outRow + x] = volume.voxelAt(x: x, y: yIndex, z: z)
                }
            }
        }

        guard let g = planeGeometry(.mprCoronal, sliceIndex: yIndex) else { return nil }
        return MPRSlice(
            pixelData: data, width: w, height: h,
            planeOrigin: g.origin, planeRowDir: g.rowDir, planeColDir: g.colDir,
            pixelSpacingX: g.pixelSpacingX, pixelSpacingY: g.pixelSpacingY)
    }

    // MARK: - Arbitrary Oblique Slice

    /// Generate an oblique slice through the volume defined by origin, row/col direction, and dimensions
    func obliqueSlice(
        origin: SIMD3<Double>,   // World coordinates of top-left corner
        rowDir: SIMD3<Double>,   // Normalized row direction
        colDir: SIMD3<Double>,   // Normalized column direction
        width: Int,
        height: Int,
        spacing: Double          // Output pixel spacing in mm
    ) -> MPRSlice {
        var data = Data(count: width * height * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            for row in 0..<height {
                for col in 0..<width {
                    let worldPt = origin
                        + Double(col) * spacing * rowDir
                        + Double(row) * spacing * colDir

                    let voxel = volume.worldToVoxel(worldPt)
                    let val = volume.sampleTrilinear(vx: voxel.x, vy: voxel.y, vz: voxel.z)
                    dst[row * width + col] = Int16(clamping: Int(val.rounded()))
                }
            }
        }

        return MPRSlice(
            pixelData: data,
            width: width,
            height: height,
            planeOrigin: origin,
            planeRowDir: rowDir,
            planeColDir: colDir,
            pixelSpacingX: spacing,
            pixelSpacingY: spacing
        )
    }

    // MARK: - Rendering MPR to NSImage

    /// Render an MPR slice to a displayable image with Window/Level
    /// The NSImage size reflects physical dimensions (mm) so non-isotropic pixels display correctly
    static func renderSlice(_ slice: MPRSlice, ww: Double, wc: Double, invert: Bool = false) -> NSImage? {
        let totalPixels = slice.width * slice.height
        guard totalPixels > 0, ww > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: slice.width,
            height: slice.height,
            bitsPerComponent: 8,
            bytesPerRow: slice.width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        guard let destData = context.data else { return nil }
        let destBuffer = destData.bindMemory(to: UInt8.self, capacity: totalPixels)

        let windowBottom = wc - (ww / 2.0)

        slice.pixelData.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Int16.self),
                  slice.pixelData.count >= totalPixels * 2 else { return }

            for i in 0..<totalPixels {
                let val = Double(src[i])
                var norm = (val - windowBottom) / ww * 255.0
                if invert { norm = 255.0 - norm }
                destBuffer[i] = UInt8(max(0, min(255, norm)))
            }
        }

        guard let cgImage = context.makeImage() else { return nil }

        // Scale NSImage size to reflect physical dimensions so non-isotropic
        // pixels (e.g., sagittal/coronal with thick slices) display correctly.
        // Use the ratio of spacingY/spacingX to determine the aspect correction.
        let physicalWidth = Double(slice.width) * slice.pixelSpacingX
        let physicalHeight = Double(slice.height) * slice.pixelSpacingY
        let aspectRatio = physicalHeight / physicalWidth

        // Set display size: keep width as pixel width, scale height by aspect ratio
        let displayWidth = CGFloat(slice.width)
        let displayHeight = CGFloat(Double(slice.width) * aspectRatio)

        return NSImage(cgImage: cgImage, size: NSSize(width: displayWidth, height: displayHeight))
    }
}

// MARK: - Axial Slab Projection (Clinical MIP)

enum ProjectionMode: String, CaseIterable, Identifiable {
    case mip = "MIP"
    case minip = "MinIP"
    case average = "Average"

    var id: String { rawValue }
}

extension MPREngine {
    /// Generate an axial slab MIP/MinIP/Average by projecting consecutive axial slices.
    /// This is the clinical slab-MIP workflow used in CTA/MRA angiography:
    /// take N slices centered at `slabCenter`, max-project them into one 2D image.
    /// Output has the same width×height as a native axial slice.
    func axialSlabProjection(
        mode: ProjectionMode,
        slabCenter: Int,
        slabThickness: Int
    ) -> MPRSlice? {
        let halfSlab = slabThickness / 2
        let zStart = max(0, slabCenter - halfSlab)
        let zEnd = min(volume.depth - 1, slabCenter + halfSlab)
        guard zStart <= zEnd else { return nil }

        let w = volume.width
        let h = volume.height
        let pixelCount = w * h
        var data = Data(count: pixelCount * MemoryLayout<Int16>.stride)

        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            // Initialize based on projection mode
            for i in 0..<pixelCount {
                switch mode {
                case .mip:     dst[i] = Int16.min
                case .minip:   dst[i] = Int16.max
                case .average: dst[i] = 0
                }
            }

            // Project slices through the slab
            for z in zStart...zEnd {
                let sliceOffset = z * pixelCount
                for i in 0..<pixelCount {
                    let val = volume.voxels[sliceOffset + i]
                    switch mode {
                    case .mip:     if val > dst[i] { dst[i] = val }
                    case .minip:   if val < dst[i] { dst[i] = val }
                    case .average: dst[i] = Int16(clamping: Int32(dst[i]) + Int32(val))
                    }
                }
            }

            // Finalize average
            if mode == .average {
                let count = Int32(zEnd - zStart + 1)
                if count > 1 {
                    for i in 0..<pixelCount {
                        dst[i] = Int16(clamping: Int32(dst[i]) / count)
                    }
                }
            }
        }

        let origin = volume.voxelToWorld(SIMD3<Double>(0, 0, Double(slabCenter)))

        return MPRSlice(
            pixelData: data,
            width: w,
            height: h,
            planeOrigin: origin,
            planeRowDir: volume.rowDirection,
            planeColDir: volume.colDirection,
            pixelSpacingX: volume.spacingX,
            pixelSpacingY: volume.spacingY
        )
    }
}

// MARK: - 3D Ray-March Projection (Legacy)

extension MPREngine {
    /// Generate a projection (MIP/MinIP/Average) through the volume along a given view direction
    func generateProjection(
        mode: ProjectionMode,
        viewDirection: SIMD3<Double>,
        upDirection: SIMD3<Double>,
        slabThickness: Double?,      // nil = full volume
        outputWidth: Int,
        outputHeight: Int,
        spacing: Double
    ) -> MPRSlice {
        let viewDir = simd_normalize(viewDirection)
        let right = simd_normalize(simd_cross(viewDir, upDirection))
        let up = simd_normalize(simd_cross(right, viewDir))

        let center = volume.worldCenter
        let bounds = volume.worldBounds

        // Compute ray length through volume (diagonal)
        let diagonal = simd_length(bounds.max - bounds.min)
        let halfLen = (slabThickness != nil) ? slabThickness! / 2.0 : diagonal / 2.0

        // Step size: half the minimum voxel spacing for quality
        let minSpacing = min(volume.spacingX, min(volume.spacingY, volume.spacingZ))
        let stepSize = minSpacing * 0.5
        let numSteps = Int(2.0 * halfLen / stepSize) + 1

        let halfW = Double(outputWidth) / 2.0
        let halfH = Double(outputHeight) / 2.0

        var data = Data(count: outputWidth * outputHeight * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            for row in 0..<outputHeight {
                for col in 0..<outputWidth {
                    let u = (Double(col) - halfW) * spacing
                    let v = (Double(row) - halfH) * spacing

                    let rayOrigin = center + u * right + v * up - halfLen * viewDir

                    var result: Double
                    switch mode {
                    case .mip:   result = -Double.greatestFiniteMagnitude
                    case .minip: result = Double.greatestFiniteMagnitude
                    case .average: result = 0
                    }

                    var sampleCount = 0

                    for step in 0..<numSteps {
                        let t = Double(step) * stepSize
                        let worldPt = rayOrigin + t * viewDir
                        let voxel = volume.worldToVoxel(worldPt)

                        // Bounds check (with small margin)
                        guard voxel.x >= -0.5, voxel.x < Double(volume.width) - 0.5,
                              voxel.y >= -0.5, voxel.y < Double(volume.height) - 0.5,
                              voxel.z >= -0.5, voxel.z < Double(volume.depth) - 0.5 else { continue }

                        let val = volume.sampleTrilinear(vx: voxel.x, vy: voxel.y, vz: voxel.z)
                        sampleCount += 1

                        switch mode {
                        case .mip:     result = max(result, val)
                        case .minip:   result = min(result, val)
                        case .average: result += val
                        }
                    }

                    if mode == .average && sampleCount > 0 {
                        result /= Double(sampleCount)
                    }
                    if sampleCount == 0 { result = 0 }

                    dst[row * outputWidth + col] = Int16(clamping: Int(result.rounded()))
                }
            }
        }

        return MPRSlice(
            pixelData: data,
            width: outputWidth,
            height: outputHeight,
            planeOrigin: center - halfW * spacing * right - halfH * spacing * up,
            planeRowDir: right,
            planeColDir: up,
            pixelSpacingX: spacing,
            pixelSpacingY: spacing
        )
    }
}
