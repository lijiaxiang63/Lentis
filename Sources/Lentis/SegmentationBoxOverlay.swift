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
                let screenPts = corners.map { voxel -> CGPoint in
                    let world = volume.voxelToWorld(SIMD3(Double(voxel.0), Double(voxel.1), Double(voxel.2)))
                    return pixelToScreen(rawToDisplay(g.pixel(of: world)), viewSize: geo.size)
                }
                ZStack {
                    Path { path in
                        path.addLines(screenPts)
                        path.closeSubpath()
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .opacity(0.95)

                    ForEach(Array(screenPts.enumerated()), id: \.offset) { _, pt in
                        Rectangle()
                            .fill(color)
                            .frame(width: 6, height: 6)
                            .position(pt)
                            .opacity(0.95)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The four box corners (voxel coords) that lie in this panel's current
    /// slice, in winding order — or nil if the box doesn't intersect the slice.
    private func inPlaneCorners() -> [(Int, Int, Int)]? {
        let box = region.box
        let slice = panel.mprSliceIndex
        let x0 = box.xRange.lowerBound, x1 = box.xRange.upperBound - 1
        let y0 = box.yRange.lowerBound, y1 = box.yRange.upperBound - 1
        let z0 = box.zRange.lowerBound, z1 = box.zRange.upperBound - 1
        switch panel.panelMode {
        case .mprAxial:
            guard box.zRange.contains(slice) else { return nil }
            return [(x0, y0, slice), (x1, y0, slice), (x1, y1, slice), (x0, y1, slice)]
        case .mprSagittal:
            guard box.xRange.contains(slice) else { return nil }
            return [(slice, y0, z0), (slice, y1, z0), (slice, y1, z1), (slice, y0, z1)]
        case .mprCoronal:
            guard box.yRange.contains(slice) else { return nil }
            return [(x0, slice, z0), (x1, slice, z0), (x1, slice, z1), (x0, slice, z1)]
        default:
            return nil
        }
    }

    // MARK: - Pixel→screen transform (mirrors CrossReferenceOverlay)

    private var displayWidth: CGFloat {
        panel.displayImageWidth > 0 ? panel.displayImageWidth : CGFloat(max(1, panel.imageWidth))
    }
    private var displayHeight: CGFloat {
        panel.displayImageHeight > 0 ? panel.displayImageHeight : CGFloat(max(1, panel.imageHeight))
    }

    /// Raw pixel coords (col,row) → aspect-corrected display-image space.
    private func rawToDisplay(_ p: CGPoint) -> CGPoint {
        let iw = CGFloat(max(1, panel.imageWidth))
        let ih = CGFloat(max(1, panel.imageHeight))
        return CGPoint(x: p.x * displayWidth / iw, y: p.y * displayHeight / ih)
    }

    /// Map display-image coordinates to panel screen coordinates, applying the
    /// same fit + flip + rotation + zoom + pan as the image itself.
    private func pixelToScreen(_ pixel: CGPoint, viewSize: CGSize) -> CGPoint {
        let imgW = displayWidth
        let imgH = displayHeight
        let vw = viewSize.width
        let vh = viewSize.height

        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        if panel.isFlippedH { x = -x }
        if panel.isFlippedV { y = -y }

        let steps = panel.rotationSteps % 4
        if steps > 0 {
            let angle = -CGFloat(steps) * .pi / 2
            let cosA = cos(angle), sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx; y = ry
        }

        x *= panel.scale
        y *= panel.scale
        x += panel.translation.x
        y -= panel.translation.y
        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}
