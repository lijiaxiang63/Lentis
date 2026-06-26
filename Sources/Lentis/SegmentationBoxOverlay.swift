// SegmentationBoxOverlay.swift
// Lentis
//
// Phase 9 — draws the draft calcification region's 3D ROI box as its
// cross-section (a quad through the box's four in-plane corners) plus corner
// markers, on every MPR plane the box intersects. The box lives in voxel space
// on `CalcificationRegion.box`, so its corners are projected through the ONE
// orientation source (`volume.voxelToWorld` → `PlaneGeometry.pixel`) and then
// the same pixel→screen transform the image uses (mirrors CrossReferenceOverlay),
// keeping the box glued to the pixels under zoom/pan/rotate/flip.
//
// Box editing is direct: drag an empty area to redraw the box (replace), or drag
// one of the 8 grabbable handles (4 corners + 4 edge midpoints) to resize it —
// on axial that edits the in-plane extent, on coronal/sagittal the depth. The
// handles are drawn here and hit-tested in MultiPanelContainer through the SAME
// forward transform, so the grab targets line up with the dots. The 3D panel is excluded.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import simd

struct SegmentationBoxOverlay: View {
    @ObservedObject var panel: PanelState
    @ObservedObject var region: CalcificationRegion
    let volume: VolumeData

    var body: some View {
        GeometryReader { geo in
            if panel.panelMode.isMPR, !region.box.isEmpty,
               let g = panel.displayedPlaneGeometry,
               let corners = inPlaneCorners() {
                let color = Color(.sRGB, red: region.color.x, green: region.color.y, blue: region.color.z, opacity: 1)
                let screenPts = corners.map { screenPoint(forVoxel: $0, geometry: g, viewSize: geo.size) }
                let handlePts = region.box.handles(plane: panel.panelMode, sliceIndex: panel.mprSliceIndex)
                    .map { screenPoint(forVoxel: $0.voxel, geometry: g, viewSize: geo.size) }
                ZStack {
                    Path { path in
                        path.addLines(screenPts)
                        path.closeSubpath()
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .opacity(0.95)

                    // Grabbable resize handles (corners + edge midpoints). White
                    // ring over the region color so they read on any background.
                    ForEach(Array(handlePts.enumerated()), id: \.offset) { _, pt in
                        Circle()
                            .fill(color)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .position(pt)
                            .opacity(0.98)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func screenPoint(forVoxel v: SIMD3<Double>, geometry g: PlaneGeometry, viewSize: CGSize) -> CGPoint {
        let world = volume.voxelToWorld(v)
        return panel.viewPoint(forRawPixel: g.pixel(of: world), viewSize: viewSize)
    }

    /// The four box corners (continuous voxel coords) that lie in this panel's
    /// current slice, in winding order — or nil if the box misses the slice.
    private func inPlaneCorners() -> [SIMD3<Double>]? {
        let box = region.box
        let slice = panel.mprSliceIndex
        let x0 = Double(box.xRange.lowerBound), x1 = Double(box.xRange.upperBound - 1)
        let y0 = Double(box.yRange.lowerBound), y1 = Double(box.yRange.upperBound - 1)
        let z0 = Double(box.zRange.lowerBound), z1 = Double(box.zRange.upperBound - 1)
        let s = Double(slice)
        switch panel.panelMode {
        case .mprAxial:
            guard box.zRange.contains(slice) else { return nil }
            return [SIMD3(x0, y0, s), SIMD3(x1, y0, s), SIMD3(x1, y1, s), SIMD3(x0, y1, s)]
        case .mprSagittal:
            guard box.xRange.contains(slice) else { return nil }
            return [SIMD3(s, y0, z0), SIMD3(s, y1, z0), SIMD3(s, y1, z1), SIMD3(s, y0, z1)]
        case .mprCoronal:
            guard box.yRange.contains(slice) else { return nil }
            return [SIMD3(x0, s, z0), SIMD3(x1, s, z0), SIMD3(x1, s, z1), SIMD3(x0, s, z1)]
        default:
            return nil
        }
    }
}

// MARK: - Brush footprint overlay

/// Draws the touch-up Brush's footprint on the current MPR slice — a hollow
/// ring centered on the cursor, sized to `calcBrushRadius` voxels — so the user
/// can see how big the brush is before/while painting (the inspector slider's
/// numeric radius is otherwise hard to translate to the image). The brush
/// paints a sphere in voxel-index space (`dx²+dy²+dz² ≤ r²`), and its center
/// lies on the current slice, so the on-slice footprint is a full disk of
/// radius `r` voxel units. The screen radius is derived by projecting two
/// voxels `r` apart through the SAME `viewPoint(forRawPixel:)` transform the
/// image uses, so the ring stays glued to the pixels under zoom/pan/rotate/
/// flip. The 3D panel is excluded (no cursor voxel readout there). Follows the
/// cursor via `panel.cursorPixelX/Y` (updated in `mouseMoved`); during an
/// active paint-drag the painted voxels themselves are the feedback.
struct BrushFootprintOverlay: View {
    @ObservedObject var panel: PanelState
    @ObservedObject var model: ViewerModel
    let volume: VolumeData

    var body: some View {
        GeometryReader { geo in
            if panel.panelMode.isMPR, panel.showCursorInfo, panel.hasCursorVoxelPosition,
               let g = panel.displayedPlaneGeometry {
                let cx = Double(panel.cursorVoxelX), cy = Double(panel.cursorVoxelY), cz = Double(panel.cursorVoxelZ)
                let center = SIMD3<Double>(cx, cy, cz)
                let r = Double(max(1, model.calcBrushRadius))
                // The on-slice footprint is a disk of `r` voxel units, but the
                // screen radius must be measured along an IN-PLANE axis: the
                // slice-normal axis is dropped by `PlaneGeometry.pixel(of:)`,
                // so projecting +r along it yields the center again (radius 0)
                // — the collapse bug on sagittal, where X is the slice-normal.
                // Measure both in-plane axes per mode and average, so the ring
                // is correct on every plane and roughly right under minor
                // anisotropic spacing (distance is rotation-invariant, so a
                // Circle stays correct under 90° rotation too).
                let centerScreen = screenPoint(forVoxel: center, geometry: g, viewSize: geo.size)
                let inPlaneAxes = self.inPlaneAxes(for: panel.panelMode)
                let rA = screenDistance(from: center, along: inPlaneAxes.0, by: r, geometry: g, viewSize: geo.size, anchor: centerScreen)
                let rB = screenDistance(from: center, along: inPlaneAxes.1, by: r, geometry: g, viewSize: geo.size, anchor: centerScreen)
                let screenRadius = max(2, (rA + rB) / 2)
                Circle()
                    .strokeBorder(brushColor, lineWidth: 1.5)
                    .frame(width: screenRadius * 2, height: screenRadius * 2)
                    .position(centerScreen)
                    // Faint white outer ring for legibility on bright slices.
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
                            .frame(width: screenRadius * 2 + 1, height: screenRadius * 2 + 1)
                            .position(centerScreen)
                    }
            }
        }
        .allowsHitTesting(false)
    }

    /// The two in-plane voxel axes for a plane (the third is the slice-normal,
    /// which `PlaneGeometry.pixel(of:)` drops). axial→(x,y), sagittal→(y,z),
    /// coronal→(x,z) — per `MPREngine.planeGeometry` (canonical RAS: i→R, j→A,
    /// k→S; axial slices along k, sagittal along i, coronal along j).
    private func inPlaneAxes(for mode: PanelMode) -> (SIMD3<Double>, SIMD3<Double>) {
        switch mode {
        case .mprAxial:    return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .mprSagittal: return (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .mprCoronal:  return (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        default:           return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
    }

    /// Screen distance from the center voxel to the voxel `r` units along an
    /// in-plane axis — the per-axis screen radius of the footprint disk.
    private func screenDistance(from center: SIMD3<Double>, along axis: SIMD3<Double>, by r: Double,
                                geometry g: PlaneGeometry, viewSize: CGSize, anchor: CGPoint) -> CGFloat {
        let edge = center + axis * r
        let edgeScreen = screenPoint(forVoxel: edge, geometry: g, viewSize: viewSize)
        return hypot(edgeScreen.x - anchor.x, edgeScreen.y - anchor.y)
    }

    /// The active region's color so the ring matches what will be painted,
    /// falling back to the accent when no region is selected.
    private var brushColor: Color {
        if let id = model.activeRegionID,
           let region = model.calcRegions.first(where: { $0.id == id }) {
            return Color(.sRGB, red: region.color.x, green: region.color.y, blue: region.color.z, opacity: 1)
        }
        return .lentisAccent
    }

    private func screenPoint(forVoxel v: SIMD3<Double>, geometry g: PlaneGeometry, viewSize: CGSize) -> CGPoint {
        let world = volume.voxelToWorld(v)
        return panel.viewPoint(forRawPixel: g.pixel(of: world), viewSize: viewSize)
    }
}
