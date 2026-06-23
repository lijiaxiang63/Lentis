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
// Box editing is redraw-to-replace (drag a new rect) + the inspector slab-depth
// slider; the corner markers are visual only. The 3D panel is excluded.
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
