// CalcificationSegmenter.swift
// Lentis
//
// Phase 9 — intracranial-calcification segmentation engine (CT/HU-oriented).
//
// A single pure, UI-free engine that unifies the two user-facing methods into
// one configurable hysteresis + 3D-connected-component region grower:
//
//   • Method A — Threshold in ROI: the user draws a 3D box around a
//     calcification and picks an HU threshold. The result is every box voxel
//     at/above the threshold (∩ brain mask), grouped into connected components
//     and size-filtered to drop specks. Modeled as hysteresis collapsed to one
//     level (high == low) seeded from the whole box and bounded to the box.
//
//   • Method B — Grow from seed: the user draws a 3D box that is *entirely*
//     calcification. The confident high-HU interior seeds a region grow that
//     extends PAST the box, down to a lower boundary threshold, hard-AND-ed with
//     the brain mask. high ≥ low is classic hysteresis, robust to the fuzzy
//     partial-volume rim of a calcification.
//
// HU comes from `VolumeData.calibratedValue` (= stored*slope + intercept); for
// CT the stored Int16 IS HU (slope 1, intercept 0). All work is bounded to the
// ROI box (Method A) or the box plus a grow region (Method B), so the live
// threshold preview stays cheap. `segment` is non-mutating — it returns voxel
// coordinates; the caller paints the chosen region's label into the mask.
//
// Orientation is irrelevant here: the engine operates purely in the canonical
// voxel grid shared by `VolumeData` and `LabelVolume`. Write-back to the
// original NIfTI grid happens later in the writer via `reorientation`.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import simd

// MARK: - Geometry

/// A half-open voxel-space axis-aligned box (canonical-RAS voxel grid). Ranges
/// are always normalized so `lowerBound <= upperBound`.
struct VoxelBox: Equatable, Codable {
    var xRange: Range<Int>
    var yRange: Range<Int>
    var zRange: Range<Int>

    init(xRange: Range<Int>, yRange: Range<Int>, zRange: Range<Int>) {
        self.xRange = xRange
        self.yRange = yRange
        self.zRange = zRange
    }

    /// Build from two inclusive corner voxels (any ordering) — the natural
    /// result of a click-drag plus a slab span.
    init(corner a: (x: Int, y: Int, z: Int), corner b: (x: Int, y: Int, z: Int)) {
        self.xRange = min(a.x, b.x)..<(max(a.x, b.x) + 1)
        self.yRange = min(a.y, b.y)..<(max(a.y, b.y) + 1)
        self.zRange = min(a.z, b.z)..<(max(a.z, b.z) + 1)
    }

    var isEmpty: Bool { xRange.isEmpty || yRange.isEmpty || zRange.isEmpty }

    /// Number of voxels enclosed (0 when empty).
    var voxelCount: Int { isEmpty ? 0 : xRange.count * yRange.count * zRange.count }

    @inline(__always)
    func contains(x: Int, y: Int, z: Int) -> Bool {
        xRange.contains(x) && yRange.contains(y) && zRange.contains(z)
    }

    /// Clamp to a volume's bounds, keeping ranges valid (never inverted).
    func clamped(to volume: VolumeData) -> VoxelBox {
        VoxelBox(
            xRange: clampRange(xRange, 0, volume.width),
            yRange: clampRange(yRange, 0, volume.height),
            zRange: clampRange(zRange, 0, volume.depth))
    }

    /// Expand by `margin` voxels on every side (caller should re-clamp).
    func dilated(by margin: Int) -> VoxelBox {
        VoxelBox(
            xRange: (xRange.lowerBound - margin)..<(xRange.upperBound + margin),
            yRange: (yRange.lowerBound - margin)..<(yRange.upperBound + margin),
            zRange: (zRange.lowerBound - margin)..<(zRange.upperBound + margin))
    }

    /// Center voxel (rounded), used for anatomical-name lookup at a centroid.
    var centerVoxel: (x: Int, y: Int, z: Int) {
        ((xRange.lowerBound + xRange.upperBound) / 2,
         (yRange.lowerBound + yRange.upperBound) / 2,
         (zRange.lowerBound + zRange.upperBound) / 2)
    }
}

private func clampRange(_ r: Range<Int>, _ lo: Int, _ hi: Int) -> Range<Int> {
    let l = max(lo, min(r.lowerBound, hi))
    let u = max(l, min(r.upperBound, hi))
    return l..<u
}

extension VoxelBox {
    /// Build a 3D slab box from two opposite raw-pixel corners of an in-plane
    /// drag on an orthogonal MPR plane. The two in-plane axes come from the rect
    /// (via `PlaneGeometry` → world → voxel, using the ONE orientation source);
    /// the third (slab) axis is centered on the plane's current slice with the
    /// given depth. Returns the box plus which voxel axis (0=i,1=j,2=k) is the
    /// slab, so the inspector slab slider knows which axis to re-extend.
    static func fromPlanePoints(_ a: CGPoint, _ b: CGPoint,
                                geometry g: PlaneGeometry, volume: VolumeData,
                                mode: PanelMode, sliceIndex: Int, slabDepth: Int)
        -> (box: VoxelBox, slabAxis: Int)? {
        let worldA = g.world(col: Double(a.x), row: Double(a.y))
        let worldB = g.world(col: Double(b.x), row: Double(b.y))
        let va = volume.worldToVoxel(worldA)
        let vb = volume.worldToVoxel(worldB)
        guard va.x.isFinite, va.y.isFinite, va.z.isFinite,
              vb.x.isFinite, vb.y.isFinite, vb.z.isFinite else { return nil }
        let lo = simd_min(va, vb), hi = simd_max(va, vb)
        var box = VoxelBox(
            corner: (Int(lo.x.rounded()), Int(lo.y.rounded()), Int(lo.z.rounded())),
            corner: (Int(hi.x.rounded()), Int(hi.y.rounded()), Int(hi.z.rounded())))

        let half = max(0, slabDepth / 2)
        let slab = (sliceIndex - half)..<(sliceIndex + half + 1)
        let slabAxis: Int
        switch mode {
        case .mprAxial:    box.zRange = slab; slabAxis = 2
        case .mprSagittal: box.xRange = slab; slabAxis = 0
        case .mprCoronal:  box.yRange = slab; slabAxis = 1
        default: return nil
        }
        return (box.clamped(to: volume), slabAxis)
    }
}

// MARK: - Method / parameters

enum SegmentationMethod: String, Codable, CaseIterable, Identifiable {
    case thresholdInROI = "Threshold in ROI"
    case growFromSeed   = "Grow from Seed"
    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .thresholdInROI: return "Threshold"
        case .growFromSeed:   return "Grow"
        }
    }
}

enum Connectivity: Int, Codable, CaseIterable, Identifiable {
    case six = 6
    case twentySix = 26
    var id: Int { rawValue }
    var label: String { self == .six ? "6 (faces)" : "26 (faces+edges+corners)" }
}

struct SegmentationParameters: Equatable, Codable {
    var method: SegmentationMethod
    /// Boundary / grow-to threshold (HU). Also the single threshold for Method A.
    var lowThresholdHU: Double
    /// Seed / high-confidence threshold (HU). Equals `lowThresholdHU` for Method A.
    var highThresholdHU: Double
    var connectivity: Connectivity
    /// Connected components smaller than this are dropped (speck removal).
    var minVoxelCount: Int
    /// AND every candidate with the brain mask when one is present.
    var constrainToBrainMask: Bool
    /// Method B grows past the ROI box; Method A stays box-bounded.
    var growBeyondROI: Bool

    /// Typical lower bound for intracranial calcification on CT.
    static let defaultCalcificationHU: Double = 130

    static func defaults(for method: SegmentationMethod) -> SegmentationParameters {
        switch method {
        case .thresholdInROI:
            return SegmentationParameters(
                method: .thresholdInROI,
                lowThresholdHU: defaultCalcificationHU,
                highThresholdHU: defaultCalcificationHU,
                connectivity: .twentySix,
                minVoxelCount: 3,
                constrainToBrainMask: true,
                growBeyondROI: false)
        case .growFromSeed:
            return SegmentationParameters(
                method: .growFromSeed,
                lowThresholdHU: 100,
                highThresholdHU: 300,
                connectivity: .twentySix,
                minVoxelCount: 1,
                constrainToBrainMask: true,
                growBeyondROI: true)
        }
    }
}

struct SegmentationResult {
    /// Selected voxels in the canonical voxel grid. The label is not written —
    /// the caller paints the region's label value.
    let coords: [(Int, Int, Int)]
    let voxelCount: Int
    /// Tight bounding box of the selected voxels (falls back to the input box).
    let boundingBox: VoxelBox
    /// True when the safety cap stopped a runaway grow (Method B, no brain mask).
    let truncated: Bool

    static let empty = SegmentationResult(coords: [], voxelCount: 0,
                                          boundingBox: VoxelBox(xRange: 0..<0, yRange: 0..<0, zRange: 0..<0),
                                          truncated: false)
}

// MARK: - Brain constraint

/// A same-grid boolean brain constraint. Built either from a resampled overlay
/// volume (a loaded brain mask or a SynthSeg parcellation — nonzero, optionally
/// restricted to a set of brain labels, counts as brain) or from a flat boolean
/// grid (tests / programmatic masks). `contains` is the AND predicate the
/// segmenter applies to every candidate voxel.
final class BrainConstraint {
    let width: Int
    let height: Int
    let depth: Int

    private let layerVolume: OverlayLayerVolume?
    /// nil means "any nonzero label is brain"; otherwise only these labels.
    private let brainLabels: Set<Int32>?
    private let boolMask: [Bool]?
    private let sliceStride: Int

    /// Brain = nonzero label in the overlay volume (optionally restricted to
    /// `brainLabels`). The overlay volume is already resampled onto the base grid.
    init(layerVolume: OverlayLayerVolume, brainLabels: Set<Int32>? = nil) {
        self.width = layerVolume.width
        self.height = layerVolume.height
        self.depth = layerVolume.depth
        self.layerVolume = layerVolume
        self.brainLabels = brainLabels
        self.boolMask = nil
        self.sliceStride = layerVolume.width * layerVolume.height
    }

    /// Brain = `true` in a flat slice-major boolean grid.
    init(width: Int, height: Int, depth: Int, mask: [Bool]) {
        precondition(mask.count == width * height * depth)
        self.width = width
        self.height = height
        self.depth = depth
        self.layerVolume = nil
        self.brainLabels = nil
        self.boolMask = mask
        self.sliceStride = width * height
    }

    @inline(__always)
    func contains(x: Int, y: Int, z: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height, z >= 0, z < depth else { return false }
        if let lv = layerVolume {
            let label = lv.labelAt(x: x, y: y, z: z)
            if label == 0 { return false }
            if let set = brainLabels { return set.contains(label) }
            return true
        }
        if let m = boolMask { return m[z * sliceStride + y * width + x] }
        return true
    }
}

// MARK: - Segmenter

final class CalcificationSegmenter {
    let volume: VolumeData
    let brainMask: BrainConstraint?

    private let width: Int
    private let height: Int
    private let depth: Int
    private let sliceStride: Int

    /// Margin (voxels) the grow region extends past the box for Method B when no
    /// brain mask is present — caps the flood so it can't wander into the skull.
    static let growMarginVoxels = 24
    /// Safety cap on a single grow's voxel count (runaway Method B w/o brain mask).
    static let maxResultVoxels = 5_000_000
    /// Otsu / threshold results are never returned below soft tissue.
    static let softTissueFloorHU: Double = 80

    init(volume: VolumeData, brainMask: BrainConstraint?) {
        self.volume = volume
        self.brainMask = brainMask
        self.width = volume.width
        self.height = volume.height
        self.depth = volume.depth
        self.sliceStride = volume.width * volume.height
    }

    @inline(__always)
    private func inBrain(_ x: Int, _ y: Int, _ z: Int, _ enabled: Bool) -> Bool {
        guard enabled, let b = brainMask else { return true }
        return b.contains(x: x, y: y, z: z)
    }

    @inline(__always)
    private func hu(_ x: Int, _ y: Int, _ z: Int) -> Double {
        volume.calibratedValue(x: x, y: y, z: z)
    }

    // MARK: Core segmentation

    /// The live-preview hot path. Non-mutating: returns the selected voxels.
    func segment(in rawBox: VoxelBox, parameters p: SegmentationParameters) -> SegmentationResult {
        let box = rawBox.clamped(to: volume)
        guard !box.isEmpty else { return .empty }

        // The region the grow is allowed to expand into.
        let growBounds: VoxelBox
        if p.growBeyondROI {
            if p.constrainToBrainMask, brainMask != nil {
                growBounds = VoxelBox(xRange: 0..<width, yRange: 0..<height, zRange: 0..<depth)
            } else {
                growBounds = box.dilated(by: Self.growMarginVoxels).clamped(to: volume)
            }
        } else {
            growBounds = box
        }

        let low = min(p.lowThresholdHU, p.highThresholdHU)
        let high = max(p.lowThresholdHU, p.highThresholdHU)
        let useBrain = p.constrainToBrainMask
        let offsets = Self.neighborOffsets(p.connectivity)
        let minSize = max(1, p.minVoxelCount)

        @inline(__always)
        func isCandidate(_ x: Int, _ y: Int, _ z: Int) -> Bool {
            growBounds.contains(x: x, y: y, z: z) && inBrain(x, y, z, useBrain) && hu(x, y, z) >= low
        }
        @inline(__always)
        func isSeed(_ x: Int, _ y: Int, _ z: Int) -> Bool {
            box.contains(x: x, y: y, z: z) && inBrain(x, y, z, useBrain) && hu(x, y, z) >= high
        }

        var visited = Set<Int>()
        var kept: [(Int, Int, Int)] = []
        var truncated = false

        outer: for z in box.zRange {
            for y in box.yRange {
                for x in box.xRange {
                    guard isSeed(x, y, z) else { continue }
                    let sIdx = z * sliceStride + y * width + x
                    if visited.contains(sIdx) { continue }

                    // Flood this component over candidates (region growing).
                    var component: [(Int, Int, Int)] = []
                    var stack: [(Int, Int, Int)] = [(x, y, z)]
                    visited.insert(sIdx)
                    while let (cx, cy, cz) = stack.popLast() {
                        component.append((cx, cy, cz))
                        for o in offsets {
                            let nx = cx + o.0, ny = cy + o.1, nz = cz + o.2
                            guard growBounds.contains(x: nx, y: ny, z: nz) else { continue }
                            let nIdx = nz * sliceStride + ny * width + nx
                            if visited.contains(nIdx) { continue }
                            if isCandidate(nx, ny, nz) {
                                visited.insert(nIdx)
                                stack.append((nx, ny, nz))
                            }
                        }
                        if visited.count > Self.maxResultVoxels { truncated = true; break }
                    }

                    if truncated {
                        kept.append(contentsOf: component)
                        break outer
                    }
                    if component.count >= minSize {
                        kept.append(contentsOf: component)
                    }
                }
            }
        }

        let bb = Self.boundingBox(of: kept) ?? box
        return SegmentationResult(coords: kept, voxelCount: kept.count, boundingBox: bb, truncated: truncated)
    }

    // MARK: Otsu + histogram (ROI inspector helpers)

    /// Otsu between-class-variance threshold (HU) over the in-box, brain-
    /// constrained voxels. Clamped to never return below soft tissue, so it
    /// separates calcification from parenchyma rather than tissue from air.
    func otsuThreshold(in rawBox: VoxelBox, constrainToBrainMask: Bool = true) -> Double {
        let box = rawBox.clamped(to: volume)
        guard !box.isEmpty else { return SegmentationParameters.defaultCalcificationHU }

        let bins = 256
        let (counts, minHU, maxHU) = histogram(in: box, bins: bins, constrainToBrainMask: constrainToBrainMask)
        let total = counts.reduce(0, +)
        guard total > 0, maxHU > minHU else { return SegmentationParameters.defaultCalcificationHU }

        let binWidth = (maxHU - minHU) / Double(bins)
        @inline(__always) func binCenterHU(_ b: Int) -> Double { minHU + (Double(b) + 0.5) * binWidth }

        var sumAll = 0.0
        for b in 0..<bins { sumAll += Double(b) * Double(counts[b]) }

        // A clean bimodal histogram has an empty gap between the two modes, and
        // every split bin inside that gap yields the SAME maximal between-class
        // variance. Track the full plateau of (near-)maximal bins and return its
        // midpoint, so the threshold lands in the middle of the gap rather than
        // hugging the lower mode.
        var wB = 0, sumB = 0.0
        var bestVar = -1.0
        var firstBest = bins / 2, lastBest = bins / 2
        let totalD = Double(total)
        for b in 0..<bins {
            wB += counts[b]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(b) * Double(counts[b])
            let mB = sumB / Double(wB)
            let mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) / totalD * Double(wF) / totalD * (mB - mF) * (mB - mF)
            if between > bestVar * (1 + 1e-12) {
                bestVar = between; firstBest = b; lastBest = b
            } else if between >= bestVar * (1 - 1e-12) {
                lastBest = b
            }
        }

        let threshold = binCenterHU((firstBest + lastBest) / 2)
        // Never below soft tissue; never above a dense-calcification ceiling.
        return min(max(threshold, Self.softTissueFloorHU), 2000)
    }

    /// HU histogram over the box (∩ brain), for the inspector's ROI histogram.
    func histogram(in rawBox: VoxelBox, bins: Int, constrainToBrainMask: Bool = true)
        -> (counts: [Int], minHU: Double, maxHU: Double) {
        let box = rawBox.clamped(to: volume)
        guard !box.isEmpty, bins > 0 else { return ([], 0, 0) }

        var minHU = Double.greatestFiniteMagnitude
        var maxHU = -Double.greatestFiniteMagnitude
        var any = false
        for z in box.zRange {
            for y in box.yRange {
                for x in box.xRange {
                    if constrainToBrainMask, !inBrain(x, y, z, true) { continue }
                    let v = hu(x, y, z)
                    if v < minHU { minHU = v }
                    if v > maxHU { maxHU = v }
                    any = true
                }
            }
        }
        guard any else { return ([], 0, 0) }
        if maxHU <= minHU { maxHU = minHU + 1 }

        var counts = [Int](repeating: 0, count: bins)
        let span = maxHU - minHU
        for z in box.zRange {
            for y in box.yRange {
                for x in box.xRange {
                    if constrainToBrainMask, !inBrain(x, y, z, true) { continue }
                    let v = hu(x, y, z)
                    var b = Int((v - minHU) / span * Double(bins))
                    if b < 0 { b = 0 } else if b >= bins { b = bins - 1 }
                    counts[b] += 1
                }
            }
        }
        return (counts, minHU, maxHU)
    }

    // MARK: Helpers

    private static func neighborOffsets(_ connectivity: Connectivity) -> [(Int, Int, Int)] {
        switch connectivity {
        case .six:
            return [(-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)]
        case .twentySix:
            var out: [(Int, Int, Int)] = []
            out.reserveCapacity(26)
            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0 && dz == 0) {
                        out.append((dx, dy, dz))
                    }
                }
            }
            return out
        }
    }

    private static func boundingBox(of coords: [(Int, Int, Int)]) -> VoxelBox? {
        guard let first = coords.first else { return nil }
        var minX = first.0, minY = first.1, minZ = first.2
        var maxX = first.0, maxY = first.1, maxZ = first.2
        for c in coords {
            if c.0 < minX { minX = c.0 }; if c.0 > maxX { maxX = c.0 }
            if c.1 < minY { minY = c.1 }; if c.1 > maxY { maxY = c.1 }
            if c.2 < minZ { minZ = c.2 }; if c.2 > maxZ { maxZ = c.2 }
        }
        return VoxelBox(xRange: minX..<(maxX + 1), yRange: minY..<(maxY + 1), zRange: minZ..<(maxZ + 1))
    }
}
