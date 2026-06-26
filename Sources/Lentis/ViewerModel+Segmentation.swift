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
import AppKit

/// Which pane the trailing inspector shows.
enum InspectorTab: String { case layers, segment }

/// Hashable voxel coordinate key for the touch-up brush's per-stroke undo
/// backup (tuples aren't Hashable). Maps a touched voxel to its pre-stroke
/// label so a single undo restores the whole stroke.
struct BrushVoxelKey: Hashable { let x: Int; let y: Int; let z: Int }

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

    // MARK: - Tool context-gating (shared by palette + shortcuts + menus)

    /// Whether `tool` can currently be activated. The two segmentation tools are
    /// context-gated — ROI Box needs a loaded volume to draw into, and the
    /// touch-up Brush only edits a committed region (so it needs a segmentation
    /// and no in-flight draft). Every other tool is always selectable. This is
    /// the ONE gate the tool palette, the keyboard shortcuts, and the Tools menu
    /// all consult, so a shortcut can't enter a mode the palette shows as
    /// disabled (e.g. arming ROI Box with no volume, which then silently no-ops).
    func canActivate(_ tool: ActiveTool) -> Bool {
        switch tool {
        case .roiBox:    return segmentationVolume != nil
        case .calcBrush: return hasSegmentation && draftRegion == nil
        // The Pan tool is meaningless on the 3D panel — there the default
        // pointer (Select) already rotates the camera
        // (rotatesVolumeOnPrimaryDrag), so Pan would only duplicate it under
        // a misleading "move" name. Grey it out on 3D so the palette can't
        // offer a no-op. With no active panel (nothing loaded) Pan stays
        // selectable so the bare palette doesn't show an inconsistent gap.
        case .pan:       return activePanel?.panelMode != .volume3D
        default:         return true
        }
    }

    /// Set `activeTool`, but only when `canActivate(_:)` permits it — the single
    /// choke point user-initiated tool selection (palette / shortcut / menu)
    /// routes through, so context-gating can't be bypassed. Deliberate internal
    /// transitions that *establish* a tool's context (e.g. `beginRegion` arming
    /// ROI Box) keep assigning `activeTool` directly.
    func activateTool(_ tool: ActiveTool) {
        guard canActivate(tool) else { return }
        activeTool = tool
    }

    // MARK: - Physical size readouts

    /// Physical volume of a voxel count using the base volume's spacing — the unit
    /// a radiologist actually reasons about (mm³ under 1 cm³, else cm³). "" when
    /// there is no volume or the count is zero.
    func physicalVolumeString(voxelCount: Int) -> String {
        guard let vol = segmentationVolume, voxelCount > 0 else { return "" }
        let mm3 = Double(voxelCount) * abs(vol.spacingX * vol.spacingY * vol.spacingZ)
        if mm3 < 1000 { return String(format: "%.0f mm³", mm3) }
        return String(format: "%.2f cm³", mm3 / 1000)
    }

    /// "N vox · V mm³" (drops the volume when spacing is unavailable). The voxel
    /// count is grouped (e.g. "393,263") so large regions stay readable.
    func regionSizeString(voxelCount: Int) -> String {
        let vox = "\(voxelCount.formatted(.number.grouping(.automatic))) vox"
        let v = physicalVolumeString(voxelCount: voxelCount)
        return v.isEmpty ? vox : "\(vox) · \(v)"
    }

    /// Approximate physical diameter of the spherical touch-up brush (a voxel
    /// radius → mm), using the base volume's mean spacing. "" when no volume.
    func brushDiameterString(radius: Int) -> String {
        guard let vol = segmentationVolume else { return "" }
        let meanSpacing = (abs(vol.spacingX) + abs(vol.spacingY) + abs(vol.spacingZ)) / 3
        return String(format: "≈%.1f mm", Double(2 * radius + 1) * meanSpacing)
    }

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

    /// Per-label colors to hand `loadMPRSlice`'s mask renderer — or `nil` to fall
    /// back to the legacy single flat-color mask (the Phase-7 demo / generic
    /// overlay, which has no `CalcificationRegion`s).
    ///
    /// Segmentation is "active" whenever any committed region or a live draft
    /// exists. In that mode this is ALWAYS non-nil — *even when empty* (every
    /// region hidden) — so the `labelMask` renders as a per-label ATLAS where a
    /// region absent from the table (i.e. hidden) composites nothing. Returning
    /// `nil` for the all-hidden case would route the mask through the flat
    /// single-color path, which paints EVERY label one color and makes the
    /// per-region visibility toggle a no-op (the bug this guards).
    func segmentationAtlasColors() -> [Int32: LayerRGBA]? {
        guard !calcRegions.isEmpty || draftRegion != nil else { return nil }
        return calcMaskColorTable()
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
        activeTool = .roiBox          // ready to drag the ROI box
        showLayerInspector = true     // surface the Segment controls
        inspectorTab = .segment
        return region
    }

    /// Set the draft region's ROI box (e.g. from a drag) and refresh the preview.
    /// Method B seeds its high-confidence (seed) level from the box's mean HU —
    /// the box is, by that method's contract, entirely calcification. Method A
    /// keeps its fixed-band threshold (default 55 HU; the manual Otsu button is
    /// still available) so the threshold doesn't jump out of its 40–100 range.
    func setActiveRegionBox(_ box: VoxelBox) {
        guard let draft = draftRegion, let vol = segmentationVolume else { return }
        let clamped = box.clamped(to: vol)
        draft.box = clamped
        if !clamped.isEmpty, draft.parameters.method == .growFromSeed, let seg = makeSegmenter() {
            seedGrowThresholdFromBoxMean(draft, segmenter: seg)
        }
        updateActiveRegionPreview()
    }

    /// Seed Method B's high (seed) threshold from the mean HU of the draft box,
    /// and record that mean as the stable center of the "Seed ≥" mean±20 slider.
    /// No-op for an empty box or the threshold method.
    private func seedGrowThresholdFromBoxMean(_ draft: CalcificationRegion, segmenter seg: CalcificationSegmenter) {
        guard draft.parameters.method == .growFromSeed, !draft.box.isEmpty else { return }
        let mean = seg.meanHU(in: draft.box, constrainToBrainMask: draft.parameters.constrainToBrainMask)
        draft.seedMeanHU = mean
        draft.parameters.highThresholdHU = mean
    }

    /// Build the ROI box from a drag's two raw-pixel corners on an MPR panel,
    /// using the panel's plane geometry + a fixed initial through-plane thickness
    /// (`calcSlabDepth`); the user then refines the depth by dragging the box's
    /// handles on coronal/sagittal. Auto-creates a draft region (threshold method)
    /// if none is in progress, so dragging the ROI Box tool just works.
    func setActiveRegionBox(fromRawCornerA a: CGPoint, cornerB b: CGPoint, panel: PanelState) {
        guard panel.panelMode.isMPR, let vol = segmentationVolume,
              let g = panel.displayedPlaneGeometry else { return }
        if draftRegion == nil { beginRegion(method: .thresholdInROI) }
        guard let draft = draftRegion else { return }
        // Redrawing over an existing box keeps its current through-plane depth (so
        // a handle-refined depth isn't discarded); a fresh box uses the default.
        var slabDepth = calcSlabDepth
        if !draft.box.isEmpty, let slabAxis = VoxelBox.slabAxis(forPlane: panel.panelMode) {
            slabDepth = max(1, [draft.box.xRange, draft.box.yRange, draft.box.zRange][slabAxis].count)
        }
        guard let result = VoxelBox.fromPlanePoints(a, b, geometry: g, volume: vol,
                                                    mode: panel.panelMode,
                                                    sliceIndex: panel.mprSliceIndex,
                                                    slabDepth: slabDepth) else { return }
        setActiveRegionBox(result.box)
        // Relocate the OTHER MPR panels onto the box so its cross-section + resize
        // handles are immediately visible there — letting the user refine the 3D
        // extent (depth) from coronal/sagittal without first scrolling to find it.
        let c = draft.box.centerVoxel
        setCrosshair(vol.voxelToWorld(SIMD3(Double(c.x), Double(c.y), Double(c.z))), from: panel)
    }

    /// Resize the draft box by dragging one of its handles on an MPR panel.
    /// `gripA`/`gripB` (from the grabbed `BoxHandle`) say which in-plane bounds
    /// move; the cursor's raw-pixel position fixes their new voxel value. The
    /// plane's slab (through-plane) axis is untouched, so dragging handles on
    /// axial edits i,j and on coronal/sagittal edits the depth — full 3D control.
    /// Method B re-seeds its seed level from the new box's mean HU (the box is
    /// confirmed calcification, so the mean tracks its size); Method A keeps its
    /// Otsu threshold so a refine-drag doesn't jump the threshold around.
    func resizeActiveRegionBox(gripA: BoxGrip, gripB: BoxGrip, rawPixel p: CGPoint, panel: PanelState) {
        guard panel.panelMode.isMPR, let draft = draftRegion, let vol = segmentationVolume,
              !draft.box.isEmpty, let g = panel.displayedPlaneGeometry else { return }
        let world = g.world(col: Double(p.x), row: Double(p.y))
        let v = vol.worldToVoxel(world)
        guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return }
        let target = SIMD3<Int>(Int(v.x.rounded()), Int(v.y.rounded()), Int(v.z.rounded()))
        var box = draft.box
        box.resize(plane: panel.panelMode, gripA: gripA, gripB: gripB, toVoxel: target)
        draft.box = box.clamped(to: vol)
        if draft.parameters.method == .growFromSeed, let seg = makeSegmenter() {
            seedGrowThresholdFromBoxMean(draft, segmenter: seg)
        }
        updateActiveRegionPreview()
    }

    /// Switch the draft's method, adjusting hysteresis/grow defaults, and preview.
    func setActiveRegionMethod(_ method: SegmentationMethod) {
        guard let draft = draftRegion else { return }
        draft.parameters.method = method
        draft.parameters.growBeyondROI = (method == .growFromSeed)
        if method == .thresholdInROI {
            // Pull a carried-over threshold into Method A's fixed 40–100 HU band.
            let r = SegmentationParameters.thresholdHURange
            draft.parameters.lowThresholdHU = min(max(draft.parameters.lowThresholdHU, r.lowerBound), r.upperBound)
            draft.parameters.highThresholdHU = draft.parameters.lowThresholdHU
        } else {
            // The grow boundary lives in a fixed 40–80 HU band; pull a carried-over
            // threshold (e.g. an Otsu value from threshold mode) back into range.
            let r = SegmentationParameters.growBoundaryHURange
            draft.parameters.lowThresholdHU = min(max(draft.parameters.lowThresholdHU, r.lowerBound), r.upperBound)
            // Seed the high (seed) level from the box mean if a box is drawn.
            if let seg = makeSegmenter() { seedGrowThresholdFromBoxMean(draft, segmenter: seg) }
            if draft.parameters.highThresholdHU <= draft.parameters.lowThresholdHU {
                draft.parameters.highThresholdHU = draft.parameters.lowThresholdHU + 150
            }
        }
        updateActiveRegionPreview()
    }

    /// Re-render committed regions after an appearance change (color/visibility).
    func refreshSegmentationRender() {
        segmentationRevision &+= 1
        rerenderSegmentation()
    }

    /// Re-run the segmenter for the draft and paint the preview (label 255).
    /// Cheap: bounded to the ROI box; re-renders only intersecting slices.
    func updateActiveRegionPreview() {
        guard let draft = draftRegion, let vol = segmentationVolume, !draft.box.isEmpty,
              let seg = makeSegmenter() else {
            clearPreview()
            draftRegion?.previewVoxelCount = 0
            draftRegion?.previewTruncated = false
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
        // Re-insert a re-edited region where it came from; new regions go top-first.
        let insertAt = min(max(0, reEditingRegionIndex ?? 0), calcRegions.count)
        calcRegions.insert(draft, at: insertAt)
        clearReEditStash()
        activeRegionID = draft.id
        draftRegion = nil
        // Drawing this region is done — leave ROI-box mode so the next click
        // navigates (relocates the crosshair) instead of starting another box.
        // Picking a method re-enters box mode via `beginRegion`.
        if activeTool == .roiBox { activeTool = .select }
        recomputeRegionVoxelCounts()
        invalidateSegmentationExports()   // regions changed → prior export is stale
        segmentationRevision &+= 1
        rerenderSegmentation()
    }

    /// Discard the draft and its preview. If the draft was a re-edit of a
    /// committed region, restore that region (repaint its label + re-insert it)
    /// rather than destroying it — a Cancel/abandon must never lose committed work.
    func cancelActiveRegion() {
        let hadDraft = draftRegion != nil || !segPreviewBackup.isEmpty
        clearPreview()
        restoreReEditedRegionIfNeeded()
        if hadDraft {
            draftRegion = nil
            segmentationRevision &+= 1
            rerenderSegmentation()
        }
    }

    /// If a re-edit is in flight, repaint the original committed label over the
    /// region's stashed voxels and re-insert it at its prior index, so an
    /// abandoned re-edit leaves the committed list exactly as it was found.
    private func restoreReEditedRegionIfNeeded() {
        guard let draft = draftRegion, let idx = reEditingRegionIndex, let mask = baseLabelMask else {
            clearReEditStash(); return
        }
        for c in reEditingCommittedCoords { mask.setLabel(draft.label, x: c.x, y: c.y, z: c.z) }
        draft.voxelCount = reEditingCommittedCoords.count
        draft.previewVoxelCount = 0
        let insertAt = min(max(0, idx), calcRegions.count)
        calcRegions.insert(draft, at: insertAt)
        activeRegionID = draft.id
        clearReEditStash()
    }

    private func clearReEditStash() {
        reEditingRegionIndex = nil
        reEditingCommittedCoords.removeAll(keepingCapacity: true)
    }

    /// Select a committed region (drives the active highlight + touch-up brush).
    /// While a draft is in progress the draft owns the active state, so a row tap
    /// is ignored — this prevents the dual-active state where the brush would edit
    /// a committed region while a draft preview is still painted.
    func selectRegion(_ id: UUID) {
        guard draftRegion == nil else { return }
        activeRegionID = id
    }

    /// Delete a committed region, clearing its voxels from the mask.
    func deleteRegion(_ id: UUID) {
        guard let idx = calcRegions.firstIndex(where: { $0.id == id }), let mask = baseLabelMask else { return }
        let region = calcRegions[idx]
        forEachVoxel(label: region.label, in: mask) { x, y, z in mask.setLabel(0, x: x, y: y, z: z) }
        calcRegions.remove(at: idx)
        if activeRegionID == id { activeRegionID = calcRegions.first?.id }
        recomputeRegionVoxelCounts()
        invalidateSegmentationExports()   // regions changed → prior export is stale
        segmentationRevision &+= 1
        rerenderSegmentation()
    }

    /// Pull a committed region back into a live draft for re-editing. Its
    /// committed voxels become the preview; re-committing repaints them, while a
    /// Cancel/abandon restores the original (see `restoreReEditedRegionIfNeeded`).
    func reEditRegion(_ id: UUID) {
        cancelActiveRegion()   // settle/restore any prior draft first
        guard let idx = calcRegions.firstIndex(where: { $0.id == id }), let mask = baseLabelMask else { return }
        let region = calcRegions.remove(at: idx)
        var coords: [(x: Int, y: Int, z: Int)] = []
        forEachVoxel(label: region.label, in: mask) { x, y, z in
            coords.append((x, y, z)); mask.setLabel(0, x: x, y: y, z: z)
        }
        // Remember the region's origin so Cancel can put it back unharmed.
        reEditingRegionIndex = idx
        reEditingCommittedCoords = coords
        region.previewTruncated = false
        draftRegion = region
        applyPreview(coords.map { ($0.x, $0.y, $0.z) })
        region.previewVoxelCount = coords.count
        activeRegionID = region.id
        // Don't invalidate the recorded export here: entering a re-edit alone does
        // not change committed content. A commit (`commitActiveRegion`) invalidates,
        // and a Cancel restores the exact original voxels (`restoreReEditedRegionIfNeeded`)
        // so the on-disk export still matches — invalidating on entry would wrongly
        // leave the Export pill "Pending" after a no-op re-edit/cancel (Codex P3).
        // The draft itself shows as "Editing"/"Finish" and blocks export meanwhile.
        segmentationRevision &+= 1
        rerenderSegmentation()
    }

    /// Clear all segmentation state (called on a new base file).
    func resetSegmentation() {
        segPreviewBackup.removeAll()
        // Abandon any in-flight brush stroke: its backup references voxels on
        // the old grid, and a dangling brushStrokeInProgress would make the
        // next paint on the new volume accumulate into a stale undo.
        brushStrokeInProgress = false
        brushStrokeBackup.removeAll(keepingCapacity: true)
        clearReEditStash()
        calcRegions = []
        draftRegion = nil
        activeRegionID = nil
        exportedMaskURL = nil
        exportedAtlasURL = nil
        brainMaskLayer = nil
        brainMaskStatus = ""
        // Stop an in-flight SynthSeg run so its completion can't fire a brain-mask
        // load against the newly opened (different) volume.
        synthSegRunner?.cancel()
        synthSegRunner = nil
        isRunningSynthSeg = false
        synthSegProgress = 0
        synthSegStatus = ""
        synthSegOutputFiles = []
        segmentationRevision &+= 1
    }

    // MARK: - Manual touch-up brush (operates on the selected committed region)

    /// Paint or erase a spherical brush of the selected region's label, centered
    /// at a voxel. Erase only removes voxels of that region. Brain-mask
    /// constraint (if any) limits painting to inside the brain. During an
    /// active stroke (`beginBrushStroke`…`endBrushStroke`), each voxel about to
    /// change is recorded into `brushStrokeBackup` (first touch only) so one
    /// undo restores the whole stroke to its pre-stroke state.
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
                            recordBrushBackup(x: x, y: y, z: z, mask: mask)
                            mask.setLabel(0, x: x, y: y, z: z); delta -= 1
                        }
                    } else {
                        guard x >= 0, x < mask.width, y >= 0, y < mask.height, z >= 0, z < mask.depth else { continue }
                        if let brain, !brain.contains(x: x, y: y, z: z) { continue }
                        if mask.labelAt(x: x, y: y, z: z) != region.label {
                            recordBrushBackup(x: x, y: y, z: z, mask: mask)
                            mask.setLabel(region.label, x: x, y: y, z: z); delta += 1
                        }
                    }
                }
            }
        }
        guard delta != 0 else { return }
        region.voxelCount = max(0, region.voxelCount + delta)
        invalidateSegmentationExports()   // voxels changed → prior export is stale
        segmentationRevision &+= 1
        // Brush edits land on the active panel's current slice; re-render all
        // MPR panels so the orthogonal views stay consistent.
        rerenderSegmentation()
    }

    /// Record a voxel's current label into the stroke backup (first touch only),
    /// so a single undo restores the whole stroke to its pre-stroke state. A
    /// no-op outside an active stroke (so programmatic paints can't accumulate
    /// undo state).
    private func recordBrushBackup(x: Int, y: Int, z: Int, mask: LabelVolume) {
        guard brushStrokeInProgress else { return }
        let key = BrushVoxelKey(x: x, y: y, z: z)
        if brushStrokeBackup[key] == nil {
            brushStrokeBackup[key] = mask.labelAt(x: x, y: y, z: z)
        }
    }

    /// Begin a brush stroke (mouseDown). Clears any prior stroke's backup so
    /// the undo registered on mouseUp covers exactly this stroke's voxels.
    func beginBrushStroke() {
        brushStrokeInProgress = true
        brushStrokeBackup.removeAll(keepingCapacity: true)
    }

    /// End a brush stroke (mouseUp) and register a single undo that restores
    /// every touched voxel to its pre-stroke label. One stroke = one undo step,
    /// so a drag that fires many `paintBrush` calls undoes as a group (⌘Z).
    ///
    /// Staleness guard (layered, strictest-first):
    /// 1. seriesUID match — bail wholesale if the base volume changed (file
    ///    swap / resetSegmentation); the stroke's voxels reference the old grid.
    /// 2. owning region still in calcRegions — bail wholesale if the region was
    ///    deleted or is mid-re-edit (pulled into a draft); restoring would
    ///    orphan its label. (For an erase stroke the post-stroke label is 0 ==
    ///    background, so the per-voxel guard alone can't block re-orphaning
    ///    after deleteRegion, since deleteRegion also zeroes the region's
    ///    remaining voxels to 0. The region-existence check covers that.)
    /// 3. per-voxel post-stroke label match — only restore a voxel whose
    ///    CURRENT label still equals the label captured right after the stroke.
    ///    A later edit to that voxel (another stroke, a re-edit/commit, an
    ///    overlapping region's paint) leaves a different label and is preserved
    ///    — the older undo can't clobber newer work on the same voxel.
    /// `UndoManager` has no per-action invalidation, so the closure
    /// self-invalidates (wholesale via 1+2, per-voxel via 3).
    func endBrushStroke(undoManager: UndoManager?) {
        guard brushStrokeInProgress else { return }
        brushStrokeInProgress = false
        let backup = brushStrokeBackup
        brushStrokeBackup.removeAll(keepingCapacity: true)
        guard let mask = baseLabelMask, !backup.isEmpty else { return }
        let erased = calcBrushErase   // capture for the action name
        // Capture the post-stroke label per voxel — the value the undo expects
        // to still find at undo time. Only voxels still holding this label are
        // restored; a later edit to a voxel (another stroke, a re-edit/commit,
        // an overlapping region) leaves a different label and is preserved.
        var postStroke: [BrushVoxelKey: UInt8] = [:]
        postStroke.reserveCapacity(backup.count)
        for key in backup.keys {
            postStroke[key] = mask.labelAt(x: key.x, y: key.y, z: key.z)
        }
        let seriesUID = segmentationVolume?.seriesUID
        let regionID = activeRegionID
        undoManager?.registerUndo(withTarget: self) { target in
            // (1) Base volume must be unchanged (file swap / resetSegmentation).
            guard target.segmentationVolume?.seriesUID == seriesUID else { return }
            // (2) Owning region must still be committed (not deleted / re-editing).
            guard let id = regionID,
                  target.calcRegions.contains(where: { $0.id == id }),
                  let mask = target.baseLabelMask else { return }
            var restored = 0
            for (key, oldLabel) in backup {
                guard key.x >= 0, key.x < mask.width,
                      key.y >= 0, key.y < mask.height,
                      key.z >= 0, key.z < mask.depth else { continue }
                // (3) Only restore a voxel whose current label still matches the
                // post-stroke label we captured — a later edit to this voxel
                // (another stroke, a re-edit/commit, an overlapping region)
                // left a different label and must NOT be clobbered by the
                // older undo.
                guard mask.labelAt(x: key.x, y: key.y, z: key.z) == postStroke[key] else { continue }
                mask.setLabel(oldLabel, x: key.x, y: key.y, z: key.z)
                restored += 1
            }
            guard restored > 0 else { return }   // nothing was safe to restore
            target.recomputeRegionVoxelCounts()
            target.invalidateSegmentationExports()
            target.segmentationRevision &+= 1
            target.rerenderSegmentation()
        }
        undoManager?.setActionName(erased ? "Erase Brush" : "Paint Brush")
    }

    /// Adjust the touch-up brush radius by a signed delta, clamped to 0...8
    /// (matching the inspector slider's range). Routed through by the `-`/`=`
    /// shortcuts while the Brush tool is active; pure + testable so the key
    /// routing can be locked without a GUI. Returns the new radius.
    @discardableResult
    func adjustBrushRadius(by delta: Int) -> Int {
        let r = max(0, min(8, calcBrushRadius + delta))
        calcBrushRadius = r
        return r
    }

    // MARK: - Brain mask / SynthSeg

    var synthSegAvailable: Bool { SynthSegRunner.isAvailable(userOverride: synthSegBinaryOverride) }

    /// Load a brain mask / parcellation NIfTI as the segmentation constraint
    /// (reusing the overlay loader's affine-aware resampling onto the base grid).
    func loadBrainMask(url: URL, statusLabel: String? = nil) {
        guard let base = segmentationVolume else { brainMaskStatus = "Open a CT first."; return }
        let baseUID = base.seriesUID
        brainMaskStatus = "Loading brain mask…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                let layer = try OverlayLayerLoader.load(url: url, matching: base)
                DispatchQueue.main.async {
                    guard let self else { return }
                    // The base volume may have been swapped (new file / timepoint)
                    // while we loaded — don't attach a mask to the wrong grid.
                    guard self.segmentationVolume?.seriesUID == baseUID else { return }
                    self.brainMaskLayer = layer
                    let kindStr = layer.kind == .atlas
                        ? "parcellation · \(layer.volume.labelsPresent.count) labels"
                        : "mask"
                    self.brainMaskStatus = (statusLabel ?? layer.name) + " · " + kindStr
                    self.draftRegion?.parameters.constrainToBrainMask = true
                    self.updateActiveRegionPreview()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.brainMaskStatus = "Brain mask failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func clearBrainMask() {
        brainMaskLayer = nil
        brainMaskStatus = ""
        updateActiveRegionPreview()
    }

    /// Derive a brain mask + parcellation by running FreeSurfer SynthSeg on the
    /// loaded CT. The CT is written to a temp file; SynthSeg writes its label file
    /// directly into the resolved output directory (next to the source by default,
    /// see `AppSettings`), so the result is findable. On success the parcellation
    /// is loaded as the brain constraint, optionally added as a visible layer, and
    /// a binary brain mask is written alongside.
    func generateBrainMaskWithSynthSeg() {
        guard let vol = segmentationVolume, !isRunningSynthSeg else { return }
        guard synthSegAvailable else {
            synthSegStatus = SynthSegError.notFound.localizedDescription
            return
        }
        let settings = AppSettings.shared
        let fileBase = AppSettings.niftiBaseName(loadedFileName)
        // Honors BIDS-derivatives mode → derivatives/lentis/.../…_desc-synthseg_dseg.nii.gz
        let outputURL = resolveOutputURL(legacyName: "\(fileBase)_synthseg.nii.gz",
                                         bidsDesc: "synthseg", bidsSuffix: "dseg")
        let outDir = outputURL.deletingLastPathComponent()

        isRunningSynthSeg = true
        synthSegProgress = 0
        synthSegOutputFiles = []
        synthSegStatus = "Preparing CT…"
        let runner = SynthSegRunner()
        synthSegRunner = runner
        let tmp = FileManager.default.temporaryDirectory
        let inputURL = tmp.appendingPathComponent("lentis_ct_\(UUID().uuidString).nii.gz")
        let override = synthSegBinaryOverride
        let robust = settings.synthSegRobust
        let parcellation = settings.synthSegParcellation
        let threads = settings.synthSegThreads

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try NiftiWriter.writeVolume(vol, to: inputURL, gzip: true)
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRunningSynthSeg = false
                    self.synthSegRunner = nil
                    self.synthSegStatus = "Failed to write CT: \(error.localizedDescription)"
                }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.synthSegStatus = "Running SynthSeg on CPU… (this takes several minutes)"
                // The segmentation volume is always a brain CT here → pass --ct
                // (clip HU to [0,80]) for correct CT handling.
                runner.run(inputURL: inputURL, outputURL: outputURL,
                           parcellation: parcellation, robust: robust, ct: true, threads: threads,
                           userOverride: override,
                           progress: { [weak self] chunk in
                               if let s = SynthSegRunner.briefStatus(chunk) { self?.synthSegStatus = s }
                           },
                           completion: { [weak self] result in
                               guard let self else { return }
                               try? FileManager.default.removeItem(at: inputURL)
                               // If this run was superseded — a new file was opened
                               // (resetSegmentation) or the user cancelled — its
                               // completion must not overwrite the fresh UI state.
                               guard self.synthSegRunner === runner else { return }
                               self.isRunningSynthSeg = false
                               self.synthSegRunner = nil
                               switch result {
                               case .success(let segURL):
                                   self.synthSegStatus = "SynthSeg complete — saved to \(outDir.lastPathComponent)/"
                                   self.synthSegOutputFiles = [segURL]
                                   self.loadSynthSegResult(parcellationURL: segURL)
                               case .failure(let err):
                                   self.synthSegStatus = err.localizedDescription
                               }
                           })
            }
        }
    }

    /// Load the SynthSeg parcellation as the brain constraint, optionally add it
    /// as a visible atlas layer (so anatomical regions show), and optionally write
    /// a binary brain mask on the original CT grid alongside the label file.
    func loadSynthSegResult(parcellationURL url: URL) {
        guard let base = segmentationVolume else { brainMaskStatus = "Open a CT first."; return }
        let baseUID = base.seriesUID
        let settings = AppSettings.shared
        let autoLoad = settings.autoLoadSynthSegResult
        let writeMaskFile = settings.writeDerivedBrainMask
        let fileBase = AppSettings.niftiBaseName(loadedFileName)
        // Resolve the brain-mask destination on the main thread (BIDS-aware), so
        // it lands beside the label file (…_desc-brain_mask.nii.gz under BIDS).
        let maskTargetURL = writeMaskFile
            ? resolveOutputURL(legacyName: "\(fileBase)_brainmask.nii.gz",
                               bidsDesc: "brain", bidsSuffix: "mask")
            : nil
        brainMaskStatus = "Loading SynthSeg result…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let layer = try OverlayLayerLoader.load(url: url, matching: base)
                // Derive + write a binary brain mask (CT grid) next to the label
                // file. Non-fatal: the label file is the primary output.
                var brainMaskURL: URL? = nil
                if let maskTargetURL,
                   (try? Self.writeBinaryBrainMask(from: layer, base: base, to: maskTargetURL)) != nil {
                    brainMaskURL = maskTargetURL
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    // The base volume may have been swapped (new file / timepoint)
                    // while we loaded — don't attach a mask to the wrong grid.
                    guard self.segmentationVolume?.seriesUID == baseUID else { return }
                    self.brainMaskLayer = layer
                    if autoLoad { self.layerStore.add(layer) }
                    if let brainMaskURL { self.synthSegOutputFiles.append(brainMaskURL) }
                    let kindStr = layer.kind == .atlas
                        ? "parcellation · \(layer.volume.labelsPresent.count) labels"
                        : "mask"
                    self.brainMaskStatus = "SynthSeg · " + kindStr
                    self.draftRegion?.parameters.constrainToBrainMask = true
                    self.updateActiveRegionPreview()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.brainMaskStatus = "SynthSeg result failed to load: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Build a binary brain mask (1 where the parcellation layer is nonzero) on
    /// the base canonical grid and write it back on the ORIGINAL CT grid via the
    /// NIfTI writer's reorientation-aware path.
    private static func writeBinaryBrainMask(from layer: OverlayLayer, base: VolumeData, to url: URL) throws {
        let lv = LabelVolume(width: base.width, height: base.height, depth: base.depth)
        let v = layer.volume
        for z in 0..<base.depth {
            for y in 0..<base.height {
                for x in 0..<base.width where v.labelAt(x: x, y: y, z: z) != 0 {
                    lv.setLabel(1, x: x, y: y, z: z)
                }
            }
        }
        let gzip = url.lastPathComponent.lowercased().hasSuffix(".gz")
        try NiftiWriter.writeMask(lv, basedOn: base, kind: .binaryMask, to: url, gzip: gzip)
    }

    /// Reveal the generated SynthSeg output in Finder (selecting the files, or
    /// opening the directory as a fallback).
    func revealSynthSegOutputInFinder() {
        let existing = synthSegOutputFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        } else if let dir = synthSegOutputDirectory {
            NSWorkspace.shared.open(dir)
        }
    }

    func cancelSynthSeg() {
        synthSegRunner?.cancel()
        synthSegRunner = nil
        isRunningSynthSeg = false
        synthSegStatus = "Cancelled."
    }

    // MARK: - Export

    private func isGzipURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gz" || url.lastPathComponent.lowercased().hasSuffix(".nii.gz")
    }

    // MARK: - Output location (BIDS-aware)

    /// The BIDS-derivative destination URL for the current dataset file, or nil
    /// when BIDS-derivatives mode isn't active / the file isn't a BIDS subject
    /// file. Pure — builds the URL only (no directory creation), so it's safe for
    /// Settings previews as well as the writer. Main-thread only.
    func bidsDerivativeURL(desc: String, suffix: String) -> URL? {
        guard AppSettings.shared.outputMode == .bidsDerivatives,
              let dataset, let file = currentDatasetFile, file.isBIDS,
              let dir = dataset.derivativesDirectory(pipeline: AppSettings.bidsPipelineName, for: file)
        else { return nil }
        // Fold the source modality into the desc so a mask/dseg derived from this
        // subject's T1w can't collide with one from the same subject's ct/FLAIR.
        let fullDesc = file.descIncludingModality(desc)
        return dir.appendingPathComponent(file.entities.derivativeName(desc: fullDesc, suffix: suffix))
    }

    /// Resolve the destination URL for a generated output, honoring the chosen
    /// output mode. In `.bidsDerivatives` (with an open BIDS dataset + a BIDS
    /// source file) the file lands in `derivatives/lentis/sub-XX/[ses-YY/]<dt>/`
    /// with a BIDS-valid derivative name (`…_desc-<desc>_<bidsSuffix>.nii.gz`),
    /// creating the directory tree + pipeline `dataset_description.json`;
    /// otherwise it falls back to the beside-source / custom-folder location with
    /// `legacyName`. Main-thread only (reads the published dataset state).
    func resolveOutputURL(legacyName: String, bidsDesc: String, bidsSuffix: String) -> URL {
        let settings = AppSettings.shared
        if let dataset, let bids = bidsDerivativeURL(desc: bidsDesc, suffix: bidsSuffix) {
            let dir = bids.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.isWritableFile(atPath: dir.path) {
                Self.ensureDerivativesDescription(datasetRoot: dataset.rootURL)
                return bids
            }
        }
        // Fallback: degrade BIDS mode to beside-source so we never recurse.
        let mode: OutputLocationMode = settings.outputMode == .bidsDerivatives ? .besideSource : settings.outputMode
        let dir = AppSettings.resolveOutputDirectory(sourceFile: loadedFileURL, mode: mode,
                                                     customDirectory: settings.customOutputDirectoryURL)
        return dir.appendingPathComponent(legacyName)
    }

    /// Write the BIDS derivatives `dataset_description.json` for the lentis
    /// pipeline if it doesn't exist (required by BIDS for a derivative dataset).
    static func ensureDerivativesDescription(datasetRoot: URL) {
        let pipelineDir = datasetRoot
            .appendingPathComponent("derivatives", isDirectory: true)
            .appendingPathComponent(AppSettings.bidsPipelineName, isDirectory: true)
        let descURL = pipelineDir.appendingPathComponent("dataset_description.json")
        guard !FileManager.default.fileExists(atPath: descURL.path) else { return }
        let dict: [String: Any] = [
            "Name": "Lentis calcification segmentation",
            "BIDSVersion": "1.9.0",
            "DatasetType": "derivative",
            "GeneratedBy": [["Name": "Lentis"]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: pipelineDir, withIntermediateDirectories: true)
        try? data.write(to: descURL)
    }

    /// The destination URL a direct export would write to, given the configured
    /// output location + per-kind suffix (or BIDS derivative naming).
    func exportURL(for kind: NiftiMaskKind) -> URL {
        let settings = AppSettings.shared
        let base = AppSettings.niftiBaseName(loadedFileName)
        let rawSuffix = (kind == .binaryMask) ? settings.exportMaskSuffix : settings.exportAtlasSuffix
        let legacySuffix = AppSettings.sanitizedSuffix(
            rawSuffix,
            fallback: kind == .binaryMask ? AppSettings.defaultMaskSuffix : AppSettings.defaultAtlasSuffix)
        let legacyName = "\(base)\(legacySuffix).nii.gz"
        return resolveOutputURL(legacyName: legacyName,
                                bidsDesc: AppSettings.bidsDescLabel(fromSuffix: rawSuffix),
                                bidsSuffix: kind == .binaryMask ? "mask" : "dseg")
    }

    /// Export the segmentation directly (no save dialog) to the configured output
    /// location, returning the written file's URL. Overwrites a same-named prior
    /// export by design.
    @discardableResult
    func exportSegmentation(kind: NiftiMaskKind) throws -> URL {
        guard segmentationVolume?.labelMask != nil else { throw NiftiWriteError.noMask }
        // A live draft paints its preview as label 255 over committed voxels (the
        // originals stashed in `segPreviewBackup`); the writer skips 255, so
        // exporting now would silently drop any committed voxels under the preview.
        // Require the draft be committed/cancelled first.
        guard draftRegion == nil, segPreviewBackup.isEmpty else { throw NiftiWriteError.draftActive }
        let url = exportURL(for: kind)
        if kind == .binaryMask { try exportMask(to: url); exportedMaskURL = url }
        else { try exportAtlas(to: url); exportedAtlasURL = url }
        return url
    }

    /// Export all regions as a single-value binary mask NIfTI (original grid).
    func exportMask(to url: URL) throws {
        guard let vol = segmentationVolume, let mask = vol.labelMask else { throw NiftiWriteError.noMask }
        try NiftiWriter.writeMask(mask, basedOn: vol, kind: .binaryMask, to: url, gzip: isGzipURL(url))
    }

    /// Export regions as a multi-value atlas NIfTI (each region its own label),
    /// plus a FreeSurfer-format LUT sidecar.
    func exportAtlas(to url: URL) throws {
        guard let vol = segmentationVolume, let mask = vol.labelMask else { throw NiftiWriteError.noMask }
        try NiftiWriter.writeMask(mask, basedOn: vol, kind: .atlas, to: url, gzip: isGzipURL(url))

        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".nii.gz") { name = String(name.dropLast(7)) }
        else if name.lowercased().hasSuffix(".nii") { name = String(name.dropLast(4)) }
        let dir = url.deletingLastPathComponent()

        // The label/color sidecar follows WHERE the atlas actually landed (gate on
        // the resolved name, not just the mode — a non-writable derivatives dir
        // degrades to a legacy `_calcatlas` name beside the source). A BIDS `_dseg`
        // file gets the canonical `…_dseg.tsv`; anything else gets the FreeSurfer
        // `_LUT.txt` (a `_LUT.txt` after a `_dseg` suffix is BIDS-invalid).
        if AppSettings.shared.outputMode == .bidsDerivatives, name.hasSuffix("_dseg") {
            // The `_dseg.tsv` is the only sidecar carrying label names/colors;
            // propagate write failures (like the legacy writeLUT path) so a
            // partial BIDS derivative isn't reported as a successful export.
            try NiftiWriter.writeDsegTSV(regions: calcRegions, to: dir.appendingPathComponent(name + ".tsv"))
        } else {
            try NiftiWriter.writeLUT(regions: calcRegions, to: dir.appendingPathComponent(name + "_LUT.txt"))
        }
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

    /// Single-pass tally of each label's voxel count. Voxels currently hidden
    /// under the live preview (label 255) still belong to their committed regions,
    /// so credit the preview backup back in — otherwise a recount taken while a
    /// draft preview overlaps a region undercounts that region.
    func recomputeRegionVoxelCounts() {
        guard let mask = baseLabelMask else { return }
        var counts = [Int](repeating: 0, count: 256)
        for v in mask.labels { counts[Int(v)] += 1 }
        for b in segPreviewBackup where b.prev != 0 { counts[Int(b.prev)] += 1 }
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
