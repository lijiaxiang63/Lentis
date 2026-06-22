// MPREngine.swift
// Lentis
//
// CPU-based Multi-Planar Reconstruction (MPR) engine. Extracts oblique 2D
// slices from a 3D VolumeData by sampling along orthogonal planes (sagittal,
// coronal) using trilinear interpolation. Converts the sampled voxel values
// to grayscale NSImage via window/level tone mapping.
//
// This is the fallback rendering path; GPU-accelerated rendering is handled
// by MetalVolumeRenderer for direct 3D volume rendering.
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

/// A segmentation-mask slice (Phase 7 seam): one UInt8 label per displayed
/// pixel, laid out in the SAME (col,row) order as the gray `MPRSlice` of the
/// same plane/index — `MPREngine.maskSlice` mirrors each gray extractor's
/// neurological flips byte-for-byte, so the colored overlay registers exactly
/// over the image it sits on. 0 = background.
struct MaskSlice {
    let labels: [UInt8]
    let width: Int
    let height: Int
}

/// One immutable external layer slice plus the colors resolved on the main
/// thread for its current LUT/visibility state. Labels use Int32 so FreeSurfer
/// IDs above 255 remain exact.
struct LayerRenderSlice: Sendable {
    let labels: [Int32]
    let width: Int
    let height: Int
    let kind: OverlayLayerKind
    let maskColor: LayerRGBA
    let atlasColors: [Int32: LayerRGBA]
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

extension PlaneGeometry {
    /// World coordinate of the (continuous) displayed pixel at `col`/`row`.
    /// This is the forward map used by the cursor readout and the crosshair's
    /// click→world step; `pixel(of:)` is its exact inverse.
    func world(col: Double, row: Double) -> SIMD3<Double> {
        origin + col * pixelSpacingX * rowDir + row * pixelSpacingY * colDir
    }

    /// Project a world point onto this plane, returning continuous pixel
    /// coordinates (x = column, y = row). Exact inverse of `world(col:row:)`
    /// because `rowDir ⟂ colDir` for every orthogonal MPR plane (the only
    /// planes the crosshair draws on). Any out-of-plane component of `world`
    /// is dropped — the crosshair always relocates each plane to contain the
    /// point first, so in practice the point lies on the plane.
    func pixel(of world: SIMD3<Double>) -> CGPoint {
        let d = world - origin
        let col = simd_dot(d, rowDir) / pixelSpacingX
        let row = simd_dot(d, colDir) / pixelSpacingY
        return CGPoint(x: col, y: row)
    }
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

    /// The orthogonal-plane slice index (along the plane's fixed voxel axis)
    /// whose slice passes through `world`, for the given MPR mode — i.e. the
    /// `mprSliceIndex` a panel must show to contain that world point. Used by
    /// the crosshair to relocate the other panels. Because volumes are
    /// canonical RAS (i→R, j→A, k→S), each plane indexes one voxel axis:
    /// axial→k, sagittal→i, coronal→j. Result is rounded + clamped to bounds.
    /// Returns nil for non-orthogonal modes (e.g. `.volume3D`).
    func orthogonalSliceIndex(for mode: PanelMode, containing world: SIMD3<Double>) -> Int? {
        let v = volume.worldToVoxel(world)
        switch mode {
        case .mprAxial:    return min(max(0, Int(v.z.rounded())), volume.depth - 1)
        case .mprSagittal: return min(max(0, Int(v.x.rounded())), volume.width - 1)
        case .mprCoronal:  return min(max(0, Int(v.y.rounded())), volume.height - 1)
        default:           return nil
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
    ///
    /// Sagittal fixes i (=x) and spans j (cols) × k (rows), so it reads the
    /// volume on the worst stride — j steps by `width`, k by a whole z-plane —
    /// a cache-missing gather over the entire buffer. On the 1024² MPRAGE
    /// sagittal plane the naïve `voxelAt` gather cost ~15 ms (vs ~1 ms for the
    /// contiguous axial/coronal planes); that was the per-slice throughput
    /// ceiling (~57 slices/s) that made fast scrolling drop frames on the big
    /// MPRAGE — both single-panel sagittal and the quad layout, where
    /// `syncScrollFromPanel` re-renders this panel every tick.
    ///
    /// This performs the **same gather, byte-for-byte** (so the neurological
    /// flips defined in `planeGeometry` are unchanged — see MPREngineTests) but
    /// (1) via a raw pointer walk with running offsets instead of per-voxel
    /// bounds checks + index multiplies, and (2) parallelised across z-planes.
    /// Each z owns a disjoint output row band, so the writes never race. The
    /// read source is read-only. Measured ~15 ms → ~1.5 ms on the MPRAGE; small
    /// volumes are unaffected (GCD runs few iterations near-serially).
    func sagittalSlice(at xIndex: Int) -> MPRSlice? {
        guard xIndex >= 0, xIndex < volume.width else { return nil }
        // cols span j (A); rows span k (S). Anterior at left, Superior at top.
        let w = volume.height   // j / A
        let h = volume.depth    // k / S
        let width = volume.width
        let sliceStride = volume.width * volume.height
        let depth = volume.depth
        let height = volume.height

        var data = Data(count: w * h * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let src = volume.voxels.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: depth) { z in
                let outRow = (depth - 1 - z) * w     // Superior at top
                var s = z * sliceStride + xIndex     // (x=xIndex, y=0, z)
                var outCol = w - 1                   // y=0 → Anterior at left
                for _ in 0..<height {
                    dst[outRow + outCol] = src[s]
                    s += width                       // y += 1
                    outCol -= 1
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

    // MARK: - Mask Slice (segmentation seam)

    /// Extract the volume's same-grid label mask for an orthogonal plane, in the
    /// SAME displayed (col,row) layout as the gray slice of that plane/index.
    /// Each case mirrors the matching gray extractor's neurological flip exactly
    /// (axial: Anterior on top; sagittal/coronal: Superior on top, with the
    /// sagittal Anterior-left flip), so a labeled voxel lands on the same pixel
    /// as its gray counterpart — see `SegmentationSeamTests`. Returns nil when no
    /// mask is attached, which keeps `renderSlice` on its plain grayscale path.
    func maskSlice(mode: PanelMode, sliceIndex: Int) -> MaskSlice? {
        guard let mask = volume.labelMask else { return nil }
        switch mode {
        case .mprAxial:
            guard sliceIndex >= 0, sliceIndex < volume.depth else { return nil }
            let w = volume.width, h = volume.height
            var out = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                let dstRow = (h - 1 - y) * w   // Anterior (max j) at top
                for x in 0..<w { out[dstRow + x] = mask.labelAt(x: x, y: y, z: sliceIndex) }
            }
            return MaskSlice(labels: out, width: w, height: h)
        case .mprSagittal:
            // Sagittal is the cache-hostile gather (fixes i, spans j×k). Mirror
            // the gray `sagittalSlice` raw-pointer walk parallelised across
            // z-planes (disjoint output rows), byte-identical to the `labelAt`
            // loop above — orientation still comes from `planeGeometry`, locked
            // by SegmentationSeamTests. This is the masked-path hot spot flagged
            // in CLAUDE.md Known-issue #3.
            guard sliceIndex >= 0, sliceIndex < volume.width else { return nil }
            let w = volume.height    // j / A
            let h = volume.depth     // k / S
            let width = volume.width
            let height = volume.height
            let depth = volume.depth
            let stride = width * height
            var out = [UInt8](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { dstBuf in
                guard let dst = dstBuf.baseAddress, let src = mask.labels.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: depth) { z in
                    let outRow = (depth - 1 - z) * w   // Superior at top
                    var s = z * stride + sliceIndex    // (x=sliceIndex, y=0, z)
                    var outCol = w - 1                  // y=0 → Anterior at left
                    for _ in 0..<height {
                        dst[outRow + outCol] = src[s]
                        s += width                      // y += 1
                        outCol -= 1
                    }
                }
            }
            return MaskSlice(labels: out, width: w, height: h)
        case .mprCoronal:
            guard sliceIndex >= 0, sliceIndex < volume.height else { return nil }
            let w = volume.width, h = volume.depth
            var out = [UInt8](repeating: 0, count: w * h)
            for z in 0..<volume.depth {
                let outRow = (volume.depth - 1 - z) * w   // Superior at top
                for x in 0..<volume.width { out[outRow + x] = mask.labelAt(x: x, y: sliceIndex, z: z) }
            }
            return MaskSlice(labels: out, width: w, height: h)
        default:
            return nil
        }
    }

    /// Extract an external layer in exactly the same displayed pixel layout as
    /// the gray MPR slice. The integer voxel origin/steps are derived from
    /// `planeGeometry`, keeping neurological orientation in one place rather
    /// than duplicating the per-plane flips for every overlay type.
    func layerSlice(_ descriptor: LayerRenderDescriptor, mode: PanelMode, sliceIndex: Int) -> LayerRenderSlice? {
        guard descriptor.volume.width == volume.width,
              descriptor.volume.height == volume.height,
              descriptor.volume.depth == volume.depth,
              let geometry = planeGeometry(mode, sliceIndex: sliceIndex) else { return nil }

        let size: (width: Int, height: Int)
        switch mode {
        case .mprAxial: size = (volume.width, volume.height)
        case .mprSagittal: size = (volume.height, volume.depth)
        case .mprCoronal: size = (volume.width, volume.depth)
        default: return nil
        }

        func transformed(_ point: SIMD4<Double>) -> SIMD3<Double> {
            let value = volume.worldToVoxelMatrix * point
            return SIMD3(value.x, value.y, value.z)
        }
        let origin = transformed(SIMD4(geometry.origin.x, geometry.origin.y, geometry.origin.z, 1))
        let columnWorld = geometry.rowDir * geometry.pixelSpacingX
        let rowWorld = geometry.colDir * geometry.pixelSpacingY
        let columnStep = transformed(SIMD4(columnWorld.x, columnWorld.y, columnWorld.z, 0))
        let rowStep = transformed(SIMD4(rowWorld.x, rowWorld.y, rowWorld.z, 0))
        let o = SIMD3<Int>(Int(origin.x.rounded()), Int(origin.y.rounded()), Int(origin.z.rounded()))
        let dc = SIMD3<Int>(Int(columnStep.x.rounded()), Int(columnStep.y.rounded()), Int(columnStep.z.rounded()))
        let dr = SIMD3<Int>(Int(rowStep.x.rounded()), Int(rowStep.y.rounded()), Int(rowStep.z.rounded()))

        var labels = [Int32](repeating: 0, count: size.width * size.height)
        for row in 0..<size.height {
            let rowStart = o &+ dr &* SIMD3<Int>(repeating: row)
            var voxel = rowStart
            let outputStart = row * size.width
            for column in 0..<size.width {
                labels[outputStart + column] = descriptor.volume.labelAt(x: voxel.x, y: voxel.y, z: voxel.z)
                voxel = voxel &+ dc
            }
        }
        return LayerRenderSlice(
            labels: labels,
            width: size.width,
            height: size.height,
            kind: descriptor.kind,
            maskColor: descriptor.maskColor,
            atlasColors: descriptor.atlasColors
        )
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

    /// Slices at or above this pixel count split the W/L tone-map across GCD
    /// worker bands; smaller ones run serially (parallel setup would dominate).
    /// 512×512 — below the 1 MP MPRAGE planes, above CT/synthetic test slices.
    static let parallelToneMapThreshold = 262_144

    /// Render an MPR slice to a displayable image with Window/Level. The NSImage
    /// size reflects physical dimensions (mm) so non-isotropic pixels display
    /// correctly. When a same-size `mask` is supplied (Phase 7 segmentation
    /// seam), labeled pixels are alpha-composited with `maskColor`; otherwise the
    /// original fast grayscale path runs unchanged.
    ///
    /// Metal seam: slice rendering is CPU here (see CLAUDE.md §Data & rendering).
    /// A future live-MTKView path would upload this mask as a second R8 texture
    /// and blend it in the W/L shader (MetalVolumeRenderer) rather than via this
    /// CPU composite — orientation still comes from `maskSlice` mirroring
    /// `planeGeometry`, so no flip logic moves into MSL.
    static func renderSlice(_ slice: MPRSlice, ww: Double, wc: Double, invert: Bool = false,
                            mask: MaskSlice? = nil,
                            maskColor: SIMD3<Double> = SIMD3<Double>(1.0, 0.23, 0.19),
                            maskAlpha: Double = 0.45,
                            maskAtlasColors: [Int32: LayerRGBA]? = nil,
                            layers: [LayerRenderSlice] = []) -> NSImage? {
        let totalPixels = slice.width * slice.height
        guard totalPixels > 0, ww > 0 else { return nil }

        var compositeLayers = layers.filter {
            $0.width == slice.width && $0.height == slice.height && $0.labels.count == totalPixels
        }
        // Compatibility adapter for the editable UInt8 segmentation mask. It
        // becomes an ordinary top layer without copying the 3D mask. When a
        // per-label color table is supplied (multi-region calcification, Phase 9)
        // the mask renders as an ATLAS — each label value gets its own color;
        // otherwise it stays the original single flat-color mask (Phase 7 demo +
        // grayscale fast path unchanged).
        if let mask = mask, mask.width == slice.width, mask.height == slice.height,
           mask.labels.count == totalPixels {
            let flat = LayerRGBA(
                red: Float(max(0, min(1, maskColor.x))),
                green: Float(max(0, min(1, maskColor.y))),
                blue: Float(max(0, min(1, maskColor.z))),
                alpha: Float(max(0, min(1, maskAlpha))))
            compositeLayers.append(LayerRenderSlice(
                labels: mask.labels.map(Int32.init),
                width: mask.width,
                height: mask.height,
                kind: maskAtlasColors == nil ? .mask : .atlas,
                maskColor: flat,
                atlasColors: maskAtlasColors ?? [:]
            ))
        }
        if !compositeLayers.isEmpty {
            return renderSliceLayered(slice, ww: ww, wc: wc, invert: invert, layers: compositeLayers)
        }

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

        // W/L tone-map: stored Int16 → 8-bit gray. Float math with a precomputed
        // reciprocal (one multiply per pixel, no per-pixel divide); reassociated
        // from the old (v−windowBottom)/ww*255 but byte-identical on real data
        // (max gray-level delta 0 over a 1 MP slice — Int16 is exact in Float).
        // This loop is ~80% of renderSlice's cost (CGContext alloc + makeImage are
        // both <0.02 ms), so it is the one thing worth speeding up here — and it
        // is shared by scroll AND the W/L-drag re-render. Parallelised across pixel
        // bands for megapixel slices; small slices stay serial (GCD setup would
        // dominate). Safe to parallelise from the background loadingQueue (disjoint
        // writes, read-only source) — same discipline as `sagittalSlice`.
        let windowBottom = Float(wc - (ww / 2.0))
        let scale = Float(255.0) / Float(ww)

        slice.pixelData.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Int16.self),
                  slice.pixelData.count >= totalPixels * 2 else { return }

            @inline(__always) func toneMap(_ lo: Int, _ hi: Int) {
                var i = lo
                while i < hi {
                    var norm = (Float(src[i]) - windowBottom) * scale
                    if invert { norm = 255.0 - norm }
                    if norm < 0 { norm = 0 } else if norm > 255 { norm = 255 }
                    destBuffer[i] = UInt8(norm)
                    i += 1
                }
            }
            if totalPixels >= parallelToneMapThreshold {
                let bands = 8
                let chunk = (totalPixels + bands - 1) / bands
                DispatchQueue.concurrentPerform(iterations: bands) { b in
                    let lo = b * chunk
                    let hi = min(totalPixels, lo + chunk)
                    if lo < hi { toneMap(lo, hi) }
                }
            } else {
                toneMap(0, totalPixels)
            }
        }

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: displaySize(for: slice))
    }

    /// Display size (points) for a slice: pixel width, with height scaled by the
    /// physical aspect ratio so non-isotropic (e.g. sagittal/coronal) pixels are
    /// not squashed. Shared by the grayscale and masked render paths.
    private static func displaySize(for slice: MPRSlice) -> NSSize {
        let physicalWidth = Double(slice.width) * slice.pixelSpacingX
        let physicalHeight = Double(slice.height) * slice.pixelSpacingY
        let aspectRatio = physicalWidth > 0 ? physicalHeight / physicalWidth : 1
        return NSSize(width: CGFloat(slice.width),
                      height: CGFloat(Double(slice.width) * aspectRatio))
    }

    /// RGBA compositing path for zero or more ordered mask/atlas layers. Layer
    /// zero is the bottom overlay and the last layer is composited last.
    private static func renderSliceLayered(_ slice: MPRSlice, ww: Double, wc: Double, invert: Bool,
                                           layers: [LayerRenderSlice]) -> NSImage? {
        let totalPixels = slice.width * slice.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: slice.width,
            height: slice.height,
            bitsPerComponent: 8,
            bytesPerRow: slice.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        guard let destData = context.data else { return nil }
        let dst = destData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)

        // Same Float + precomputed-reciprocal W/L as the grayscale path. Layer
        // dictionaries are immutable snapshots, so concurrent reads are safe.
        let windowBottom = Float(wc - (ww / 2.0))
        let scale = Float(1.0) / Float(ww)

        slice.pixelData.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Int16.self),
                  slice.pixelData.count >= totalPixels * 2 else { return }
            @inline(__always) func composite(_ lo: Int, _ hi: Int) {
                var i = lo
                while i < hi {
                    var g = (Float(src[i]) - windowBottom) * scale
                    if invert { g = 1.0 - g }
                    if g < 0 { g = 0 } else if g > 1 { g = 1 }
                    var r = g, green = g, b = g
                    for layer in layers {
                        let label = layer.labels[i]
                        guard label != 0 else { continue }
                        let color: LayerRGBA?
                        switch layer.kind {
                        case .mask: color = layer.maskColor
                        case .atlas: color = layer.atlasColors[label]
                        }
                        guard let color, color.alpha > 0 else { continue }
                        let inverseAlpha = 1 - color.alpha
                        r = r * inverseAlpha + color.red * color.alpha
                        green = green * inverseAlpha + color.green * color.alpha
                        b = b * inverseAlpha + color.blue * color.alpha
                    }
                    let output = i * 4
                    dst[output] = UInt8(max(0, min(255, r * 255)))
                    dst[output + 1] = UInt8(max(0, min(255, green * 255)))
                    dst[output + 2] = UInt8(max(0, min(255, b * 255)))
                    dst[output + 3] = 255
                    i += 1
                }
            }
            if totalPixels >= parallelToneMapThreshold {
                let bands = 8
                let chunk = (totalPixels + bands - 1) / bands
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let lo = band * chunk, hi = min(totalPixels, lo + chunk)
                    if lo < hi { composite(lo, hi) }
                }
            } else {
                composite(0, totalPixels)
            }
        }

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: displaySize(for: slice))
    }
}
