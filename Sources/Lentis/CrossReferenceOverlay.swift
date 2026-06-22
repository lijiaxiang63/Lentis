// CrossReferenceOverlay.swift
// Lentis
//
// Draws the shared 3D crosshair (Phase 6) on each MPR panel: two lines through
// the in-plane projection of the model's crosshair world point, plus a center
// dot. The crosshair world coordinate is set by click/drag in any panel
// (ViewerModel.setCrosshair); every panel relocates to contain it and draws its
// lines here, so the three orthogonal views stay linked in true 3D. This
// replaces the earlier dashed plane-plane intersection lines.
//
// Projection uses the panel's stored plane geometry (origin / row+col dirs /
// spacings — all sourced from MPREngine.planeGeometry) so the lines line up
// with the displayed pixels, bridged from raw-pixel to aspect-corrected display
// space, then run through the same zoom/pan/rotate/flip transform as the image
// (pixelToScreen) so they track the view.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// Tiny ObservableObject holding ONLY the shared crosshair world point. It lives
/// apart from `ViewerModel` so that updating the crosshair — which happens on
/// every mouse event during a drag — invalidates just the crosshair overlays and
/// NOT every view that observes the heavyweight model. (Routing it through
/// `model.objectWillChange` re-ran the entire quad's SwiftUI layout per drag
/// event, which was the bulk of the residual crosshair-drag lag — see CLAUDE.md.)
final class CrosshairState: ObservableObject {
    /// Shared 3D crosshair world coordinate (RAS mm). nil = no crosshair placed.
    @Published var world: SIMD3<Double>? = nil
}

/// Draws the shared 3D crosshair on this panel (set by click/drag in any panel).
struct CrossReferenceOverlay: View {
    @ObservedObject var panel: PanelState
    @ObservedObject var crosshair: CrosshairState

    /// Single shared crosshair color (the point is one world coordinate, not
    /// per-panel like the old plane-intersection lines).
    static let crosshairColor = Color(red: 0.3, green: 1.0, blue: 0.5)

    var body: some View {
        GeometryReader { geo in
            if panel.panelMode.isMPR,
               let world = crosshair.world,
               let geometry = panel.displayedPlaneGeometry {
                CrosshairLinesView(
                    panel: panel,
                    geometry: geometry,
                    world: world,
                    color: Self.crosshairColor,
                    viewSize: geo.size
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Renders the two crosshair lines + center dot for one panel, honoring the
/// panel's zoom/pan/rotation/flip via the same transform as the displayed image.
private struct CrosshairLinesView: View {
    @ObservedObject var panel: PanelState
    let geometry: PlaneGeometry
    let world: SIMD3<Double>
    let color: Color
    let viewSize: CGSize

    var body: some View {
        // Project the world point onto this plane → raw pixel (col, row), then
        // bridge to aspect-corrected display-image space (what pixelToScreen
        // fits). The bridge is identity for isotropic in-plane voxels.
        let center = rawToDisplay(geometry.pixel(of: world))
        let dw = displayWidth
        let dh = displayHeight

        let vTop   = pixelToScreen(CGPoint(x: center.x, y: 0))
        let vBot   = pixelToScreen(CGPoint(x: center.x, y: dh))
        let hLeft  = pixelToScreen(CGPoint(x: 0,        y: center.y))
        let hRight = pixelToScreen(CGPoint(x: dw,       y: center.y))
        let dot    = pixelToScreen(center)

        ZStack {
            Path { path in
                path.move(to: vTop);  path.addLine(to: vBot)
                path.move(to: hLeft); path.addLine(to: hRight)
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.0))
            .opacity(0.85)

            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .position(dot)
                .opacity(0.9)
        }
    }

    private var displayWidth: CGFloat {
        panel.displayImageWidth > 0 ? panel.displayImageWidth : CGFloat(max(1, panel.imageWidth))
    }
    private var displayHeight: CGFloat {
        panel.displayImageHeight > 0 ? panel.displayImageHeight : CGFloat(max(1, panel.imageHeight))
    }

    /// Raw pixel coords (col, row) → aspect-corrected display-image space.
    /// displayImageWidth/Height come from the rendered NSImage's size, which is
    /// scaled to physical mm; raw pixel dims are imageWidth/imageHeight.
    private func rawToDisplay(_ p: CGPoint) -> CGPoint {
        let iw = CGFloat(max(1, panel.imageWidth))
        let ih = CGFloat(max(1, panel.imageHeight))
        return CGPoint(x: p.x * displayWidth / iw, y: p.y * displayHeight / ih)
    }

    /// Map display-image coordinates to screen coordinates within the panel,
    /// applying fit + flip + rotation + zoom + pan — identical to the image's
    /// own transform so the crosshair stays glued to the pixels.
    private func pixelToScreen(_ pixel: CGPoint) -> CGPoint {
        let imgW = displayWidth
        let imgH = displayHeight
        let vw = viewSize.width
        let vh = viewSize.height

        // Aspect-ratio-preserving fit (matches .scaleProportionallyUpOrDown)
        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        // Center-relative (transforms applied around view center)
        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        // Flip
        if panel.isFlippedH { x = -x }
        if panel.isFlippedV { y = -y }

        // Rotation (90° steps)
        let steps = panel.rotationSteps % 4
        if steps > 0 {
            let angle = -CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        // Zoom
        x *= panel.scale
        y *= panel.scale

        // Pan (translation is screen-space; Y is inverted between NSView Y-up and SwiftUI Y-down)
        x += panel.translation.x
        y -= panel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

extension PanelState {
    /// Reconstruct the displayed orthogonal-plane geometry from the spatial
    /// metadata stored after the last render (origin = imagePositionPatient,
    /// row/col dirs = imageOrientationPatient, spacings = pixelSpacing). These
    /// were set straight from MPREngine.planeGeometry, so the reconstructed
    /// PlaneGeometry matches the pixels the slice was rendered from — letting
    /// the crosshair project without re-touching the volume.
    var displayedPlaneGeometry: PlaneGeometry? {
        guard let ipp = imagePositionPatient,
              let iop = imageOrientationPatient, iop.count == 6,
              let ps = pixelSpacing else { return nil }
        return PlaneGeometry(
            origin: SIMD3<Double>(ipp.0, ipp.1, ipp.2),
            rowDir: SIMD3<Double>(iop[0], iop[1], iop[2]),
            colDir: SIMD3<Double>(iop[3], iop[4], iop[5]),
            pixelSpacingX: ps.1,   // PanelState.pixelSpacing = (row-step mm, col-step mm)
            pixelSpacingY: ps.0)
    }
}
