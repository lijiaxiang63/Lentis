// ViewerModel+Segmentation.swift
// Lentis
//
// Phase 9 — multi-region calcification segmentation on the ViewerModel.
//
// One editable `VolumeData.labelMask` (UInt8) holds every committed region at a
// distinct label value (1…254); label 255 is the reserved transient preview for
// the in-progress draft. `CalcificationRegion` carries each region's metadata.
//
// Synchronization contract: ALL mask mutations happen on the main thread here,
// then `segmentationRevision` is bumped and the affected MPR panels are
// re-driven through the existing async/coalesced `loadMPRSlice`. The off-main
// extraction (`maskSlice`) only reads, and a render whose captured revision no
// longer matches is dropped — so a settled draft preview can't be clobbered by
// a stale in-flight render. (Mirrors the `LayerStore.revision` discipline.)
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Combine
import simd

/// One calcification region: its label value in the mask plus presentation and
/// the parameters/box used to (re-)compute it.
final class CalcificationRegion: ObservableObject, Identifiable {
    let id = UUID()
    /// Distinct value this region occupies in the base volume's `labelMask`.
    let label: UInt8
    @Published var name: String
    @Published var color: SIMD3<Double>
    @Published var parameters: SegmentationParameters
    @Published var box: VoxelBox
    /// Which voxel axis (0=i,1=j,2=k) is the box's slab (the plane it was drawn
    /// on), so the slab-depth slider re-extends the right axis.
    @Published var slabAxis: Int = 2
    @Published var voxelCount: Int = 0
    @Published var anatomicalName: String? = nil
    @Published var isVisible: Bool = true
    // Draft-only live state (mirrors the last preview run).
    @Published var previewVoxelCount: Int = 0
    @Published var previewTruncated: Bool = false

    var method: SegmentationMethod { parameters.method }

    init(label: UInt8, name: String, color: SIMD3<Double>,
         parameters: SegmentationParameters, box: VoxelBox) {
        self.label = label
        self.name = name
        self.color = color
        self.parameters = parameters
        self.box = box
    }
}

extension ViewerModel {

    /// Reserved transient label for the in-progress draft preview.
    static let calcPreviewLabel: UInt8 = 255

    /// Distinct vivid colors assigned to regions in creation order.
    static let calcRegionPalette: [SIMD3<Double>] = [
        SIMD3(1.00, 0.23, 0.19),  // red
        SIMD3(0.20, 0.78, 0.35),  // green
        SIMD3(0.00, 0.48, 1.00),  // blue
        SIMD3(1.00, 0.58, 0.00),  // orange
        SIMD3(0.69, 0.32, 0.87),  // purple
        SIMD3(0.00, 0.78, 0.75),  // teal
        SIMD3(1.00, 0.80, 0.00),  // yellow
        SIMD3(1.00, 0.18, 0.57),  // pink
    ]

    // MARK: - Base volume / mask access

    /// The 3D volume segmentation operates on (the loaded NIfTI series).
    var segmentationVolume: VolumeData? { cachedVolume(forSeriesIndex: niftiSeriesIndex) }
    var baseLabelMask: LabelVolume? { segmentationVolume?.labelMask }

    func makeSegmenter() -> CalcificationSegmenter? {
        guard let vol = segmentationVolume else { return nil }
        return CalcificationSegmenter(volume: vol, brainMask: brainConstraint())
    }

    /// Brain constraint derived from the loaded brain-mask / parcellation layer.
    func brainConstraint() -> BrainConstraint? {
        guard let layer = brainMaskLayer else { return nil }
        return BrainConstraint(layerVolume: layer.volume)   // any nonzero label = brain
    }

    var hasBrainMask: Bool { brainMaskLayer != nil }
    var hasSegmentation: Bool { !calcRegions.isEmpty }

    // MARK: - Per-label render color table

    /// Build the per-label color table for `loadMPRSlice`. Empty when there is
    /// no segmentation (keeps the grayscale fast path).
    func calcMaskColorTable() -> [Int32: LayerRGBA] {
        var table: [Int32: LayerRGBA] = [:]
        let alpha = Float(max(0, min(1, maskOverlayAlpha)))
        for r in calcRegions where r.isVisible {
            table[Int32(r.label)] = LayerRGBA(red: Float(r.color.x), green: Float(r.color.y),
                                              blue: Float(r.color.z), alpha: alpha)
        }
        if let draft = draftRegion {
            // The draft preview reads slightly more opaque so it stands out.
            table[Int32(Self.calcPreviewLabel)] = LayerRGBA(
                red: Float(draft.color.x), green: Float(draft.color.y), blue: Float(draft.color.z),
                alpha: min(1, alpha + 0.25))
        }
        return table
    }

    // MARK: - Region lifecycle

    /// Next unused label value in 1…254 (255 reserved for the preview).
    func nextFreeCalcLabel() -> UInt8? {
        var used = Set<UInt8>()
        for r in calcRegions { used.insert(r.label) }
        if let d = draftRegion { used.insert(d.label) }
        for v in UInt8(1)...UInt8(254) where !used.contains(v) { return v }
        return nil
    }

    /// Begin a new draft region with the given method. Discards any prior draft.
    @discardableResult
    func beginRegion(method: SegmentationMethod) -> CalcificationRegion? {
        cancelActiveRegion()
        guard segmentationVolume != nil, let label = nextFreeCalcLabel() else { return nil }
        var params = SegmentationParameters.defaults(for: method)
        params.constrainToBrainMask = hasBrainMask
        let region = CalcificationRegion(
            label: label,
            name: "Calcification \(calcRegions.count + 1)",
            color: Self.calcRegionPalette[calcRegions.count % Self.calcRegionPalette.count],
            parameters: params,
            box: VoxelBox(xRange: 0..<0, yRange: 0..<0, zRange: 0..<0))
        draftRegion = region
        activeRegionID = region.id
        activeTool = .roiBox   // ready to drag the ROI box
        return region
    }

    /// Set the draft region's ROI box (e.g. from a drag) and refresh the preview.
    /// Seeds Method A's threshold from Otsu over the box.
    func setActiveRegionBox(_ box: VoxelBox) {
        guard let draft = draftRegion, let vol = segmentationVolume else { return }
        let clamped = box.clamped(to: vol)
        draft.box = clamped
        if draft.parameters.method == .thresholdInROI, let seg = makeSegmenter(), !clamped.isEmpty {
            let t = seg.otsuThreshold(in: clamped, constrainToBrainMask: draft.parameters.constrainToBrainMask)
            draft.parameters.lowThresholdHU = t
            draft.parameters.highThresholdHU = t
        }
        updateActiveRegionPreview()
    }

    /// Build the ROI box from a drag's two raw-pixel corners on an MPR panel,
    /// using the panel's plane geometry + the slab depth. Auto-creates a draft
    /// region (threshold method) if none is in progress, so dragging the ROI Box
    /// tool just works.
    func setActiveRegionBox(fromRawCornerA a: CGPoint, cornerB b: CGPoint, panel: PanelState) {
        guard panel.panelMode.isMPR, let vol = segmentationVolume,
              let g = panel.displayedPlaneGeometry else { return }
        if draftRegion == nil { beginRegion(method: .thresholdInROI) }
        guard let draft = draftRegion,
              let result = VoxelBox.fromPlanePoints(a, b, geometry: g, volume: vol,
                                                    mode: panel.panelMode,
                                                    sliceIndex: panel.mprSliceIndex,
                                                    slabDepth: calcSlabDepth) else { return }
        draft.slabAxis = result.slabAxis
        setActiveRegionBox(result.box)
    }

    /// Re-extend the draft box's slab axis to the new depth (centered) and
    /// refresh the preview.
    func setActiveRegionSlabDepth(_ depth: Int) {
        calcSlabDepth = max(1, depth)
        guard let draft = draftRegion, let vol = segmentationVolume, !draft.box.isEmpty else { return }
        let half = max(0, calcSlabDepth / 2)
        let axis = draft.slabAxis
        var box = draft.box
        switch axis {
        case 0:
            let c = (box.xRange.lowerBound + box.xRange.upperBound) / 2
            box.xRange = (c - half)..<(c + half + 1)
        case 1:
            let c = (box.yRange.lowerBound + box.yRange.upperBound) / 2
            box.yRange = (c - half)..<(c + half + 1)
        default:
            let c = (box.zRange.lowerBound + box.zRange.upperBound) / 2
            box.zRange = (c - half)..<(c + half + 1)
        }
        draft.box = box.clamped(to: vol)
        updateActiveRegionPreview()
    }

    /// Re-run the segmenter for the draft and paint the preview (label 255).
    /// Cheap: bounded to the ROI box; re-renders only intersecting slices.
    func updateActiveRegionPreview() {
        guard let draft = draftRegion, let vol = segmentationVolume, !draft.box.isEmpty,
              let seg = makeSegmenter() else {
            clearPreview()
            segmentationRevision &+= 1
            rerenderSegmentation()
            return
        }
        vol.ensureLabelMask()
        let result = seg.segment(in: draft.box, parameters: draft.parameters)
        applyPreview(result.coords)
        draft.previewVoxelCount = result.voxelCount
        draft.previewTruncated = result.truncated
        segmentationRevision &+= 1
        rerenderSegmentation(intersecting: draft.box)
    }

    /// Commit the draft: paint its real label over the preview voxels, finalize
    /// metadata, and move it into the committed list.
    func commitActiveRegion() {
        guard let draft = draftRegion, let mask = baseLabelMask else { return }
        guard !segPreviewBackup.isEmpty else { cancelActiveRegion(); return }

        let coords = segPreviewBackup.map { ($0.x, $0.y, $0.z) }
        for c in coords { mask.setLabel(draft.label, x: c.0, y: c.1, z: c.2) }
        segPreviewBackup.removeAll(keepingCapacity: true)

        draft.voxelCount = coords.count
        draft.anatomicalName = anatomicalName(forVoxels: coords)
        calcRegions.insert(draft, at: 0)   // top-first
        activeRegionID = draft.id
        draftRegion = nil
        recomputeRegionVoxelCounts()
        segmentationRevision &+= 1
        rerenderSegmentation()
    }

    /// Discard the draft and its preview.
    func cancelActiveRegion() {
        let hadDraft = draftRegion != nil || !segPreviewBackup.isEmpty
        clearPreview()
        if hadDraft {
            draftRegion = nil
            segmentationRevision &+= 1
            rerenderSegmentation()
        }
    }

    /// Delete a committed region, clearing its voxels from the mask.
    func deleteRegion(_ id: UUID) {
        guard let idx = calcRegions.firstIndex(where: { $0.id == id }), let mask = baseLabelMask else { return }
        let region = calcRegions[idx]
        forEachVoxel(label: region.label, in: mask) { x, y, z in mask.setLabel(0, x: x, y: y, z: z) }
        calcRegions.remove(at: idx)
        if activeRegionID == id { activeRegionID = calcRegions.first?.id }
        recomputeRegionVoxelCounts()
        segmentationRevision &+= 1
        rerenderSegmentation()
    }

    /// Pull a committed region back into a live draft for re-editing. Its
    /// committed voxels become the preview; re-committing repaints them.
    func reEditRegion(_ id: UUID) {
        cancelActiveRegion()
        guard let idx = calcRegions.firstIndex(where: { $0.id == id }), let mask = baseLabelMask else { return }
        let region = calcRegions.remove(at: idx)
        var coords: [(Int, Int, Int)] = []
        forEachVoxel(label: region.label, in: mask) { x, y, z in
            coords.append((x, y, z)); mask.setLabel(0, x: x, y: y, z: z)
        }
        draftRegion = region
        applyPreview(coords)
        region.previewVoxelCount = coords.count
        activeRegionID = region.id
        segmentationRevision &+= 1
        rerenderSegmentation()
    }

    /// Clear all segmentation state (called on a new base file).
    func resetSegmentation() {
        segPreviewBackup.removeAll()
        calcRegions = []
        draftRegion = nil
        activeRegionID = nil
        brainMaskLayer = nil
        brainMaskStatus = ""
        isRunningSynthSeg = false
        synthSegProgress = 0
        synthSegStatus = ""
        segmentationRevision &+= 1
    }

    // MARK: - Manual touch-up brush (operates on the selected committed region)

    /// Paint or erase a spherical brush of the selected region's label, centered
    /// at a voxel. Erase only removes voxels of that region. Brain-mask
    /// constraint (if any) limits painting to inside the brain.
    func paintBrush(atVoxel center: (Int, Int, Int), radius: Int, erase: Bool) {
        guard let mask = baseLabelMask,
              let id = activeRegionID,
              let region = calcRegions.first(where: { $0.id == id }) else { return }
        let brain = brainConstraint()
        let r = max(0, radius)
        let r2 = r * r
        var delta = 0
        for dz in -r...r {
            for dy in -r...r {
                for dx in -r...r where dx * dx + dy * dy + dz * dz <= r2 {
                    let x = center.0 + dx, y = center.1 + dy, z = center.2 + dz
                    if erase {
                        if mask.labelAt(x: x, y: y, z: z) == region.label {
                            mask.setLabel(0, x: x, y: y, z: z); delta -= 1
                        }
                    } else {
                        guard x >= 0, x < mask.width, y >= 0, y < mask.height, z >= 0, z < mask.depth else { continue }
                        if let brain, !brain.contains(x: x, y: y, z: z) { continue }
                        if mask.labelAt(x: x, y: y, z: z) != region.label {
                            mask.setLabel(region.label, x: x, y: y, z: z); delta += 1
                        }
                    }
                }
            }
        }
        guard delta != 0 else { return }
        region.voxelCount = max(0, region.voxelCount + delta)
        segmentationRevision &+= 1
        // Brush edits land on the active panel's current slice; re-render all
        // MPR panels so the orthogonal views stay consistent.
        rerenderSegmentation()
    }

    // MARK: - Re-render

    /// Re-drive the affected MPR panels. When `box` is given, only panels whose
    /// current slice intersects the box re-render (cheap live preview).
    func rerenderSegmentation(intersecting box: VoxelBox? = nil) {
        for panel in panels where panel.panelMode.isMPR && panel.seriesIndex == niftiSeriesIndex {
            if let box {
                let hit: Bool
                switch panel.panelMode {
                case .mprAxial:    hit = box.zRange.contains(panel.mprSliceIndex)
                case .mprSagittal: hit = box.xRange.contains(panel.mprSliceIndex)
                case .mprCoronal:  hit = box.yRange.contains(panel.mprSliceIndex)
                default:           hit = false
                }
                if !hit { continue }
            }
            loadMPRSlice(for: panel)
        }
    }

    // MARK: - Internals

    /// Restore the voxels under the current preview to their committed values.
    private func clearPreview() {
        guard let mask = baseLabelMask else { segPreviewBackup.removeAll(); return }
        for b in segPreviewBackup { mask.setLabel(b.prev, x: b.x, y: b.y, z: b.z) }
        segPreviewBackup.removeAll(keepingCapacity: true)
    }

    /// Overlay the preview (label 255) on the given voxels, remembering what was
    /// underneath so `clearPreview` can restore committed labels.
    private func applyPreview(_ coords: [(Int, Int, Int)]) {
        clearPreview()
        guard let mask = baseLabelMask else { return }
        segPreviewBackup.reserveCapacity(coords.count)
        for (x, y, z) in coords {
            segPreviewBackup.append((x, y, z, mask.labelAt(x: x, y: y, z: z)))
            mask.setLabel(Self.calcPreviewLabel, x: x, y: y, z: z)
        }
    }

    /// Single-pass tally of each label's voxel count.
    func recomputeRegionVoxelCounts() {
        guard let mask = baseLabelMask else { return }
        var counts = [Int](repeating: 0, count: 256)
        for v in mask.labels { counts[Int(v)] += 1 }
        for r in calcRegions { r.voxelCount = counts[Int(r.label)] }
    }

    private func forEachVoxel(label: UInt8, in mask: LabelVolume, _ body: (Int, Int, Int) -> Void) {
        for z in 0..<mask.depth {
            for y in 0..<mask.height {
                for x in 0..<mask.width where mask.labelAt(x: x, y: y, z: z) == label {
                    body(x, y, z)
                }
            }
        }
    }

    /// Anatomical name from a parcellation brain layer at the region centroid.
    /// nil unless a parcellation (atlas) brain layer with a matching LUT entry
    /// is present (populated by SynthSeg `--parc` in Phase 6).
    func anatomicalName(forVoxels coords: [(Int, Int, Int)]) -> String? {
        guard let layer = brainMaskLayer, layer.kind == .atlas, !coords.isEmpty else { return nil }
        var sx = 0, sy = 0, sz = 0
        for c in coords { sx += c.0; sy += c.1; sz += c.2 }
        let n = coords.count
        let label = layer.volume.labelAt(x: sx / n, y: sy / n, z: sz / n)
        guard label != 0 else { return nil }
        if let lut = layerStore.lookupTables.first(where: { $0.id == layer.lutID }),
           let entry = lut.entries[label] {
            return entry.name
        }
        return "Label \(label)"
    }
}
