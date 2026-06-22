// ViewerStatusBar.swift
// Lentis
//
// The single, docked status bar at the bottom of the viewer. It shows the
// readouts that used to be repeated in every panel's floating overlays — file
// name, slice position, window/level, and the cursor HU/RAS/pixel readout — but
// only ONCE, for the active panel (cursor portion follows the hovered panel).
// This removes the bottom-left duplication (W/L shown as both text and a
// histogram, ×4 across the MPR quad).
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// Floating Liquid Glass status pill — the one place viewer readouts now live.
/// Anchored bottom-leading over the viewport (out of the diagnostic center) and
/// content-sized rather than a full-width docked bar. Non-interactive so it never
/// steals events from the panel beneath it.
struct ViewerStatusBar: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        HStack(spacing: Spacing.m) {
            // StatusBarPanelInfo observes the panel itself, so it updates when the
            // panel's async render lands its image (which fires the panel's
            // objectWillChange, not the model's). Gating on panel.image here in the
            // model observer would leave it stuck on the initial empty state.
            if let panel = model.activePanel {
                StatusBarPanelInfo(panel: panel)
            }

            // Cursor readout follows whichever panel the mouse is over. Each row
            // observes its own panel, because a panel's @Published change does not
            // invalidate a model observer; at most one panel has showCursorInfo set.
            ForEach(model.panels) { p in
                StatusBarCursorInfo(panel: p)
            }
        }
        .font(.lentisReadout)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .glassChrome(in: Capsule())
        .allowsHitTesting(false)
    }
}

/// Active-panel identity + window: file name · slice position · W/L numbers.
private struct StatusBarPanelInfo: View {
    @ObservedObject var panel: PanelState

    var body: some View {
        if panel.image != nil, panel.seriesIndex >= 0 {
            HStack(spacing: 12) {
                if !panel.currentSeriesInfo.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "brain.head.profile").font(.caption2).foregroundStyle(.secondary)
                        Text(panel.currentSeriesInfo).truncationMode(.middle)
                    }
                }
                if !panel.currentImageInfo.isEmpty {
                    Text(panel.currentImageInfo).foregroundStyle(.secondary)
                }
                if panel.windowWidth != 0 {
                    Text(String(format: "WL %.0f  WW %.0f", panel.windowCenter, panel.windowWidth)
                         + (panel.valueUnitLabel == "HU" ? " HU" : ""))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No volume loaded").foregroundStyle(.secondary)
        }
    }
}

/// Cursor readout for one panel — renders only while the cursor is over it.
private struct StatusBarCursorInfo: View {
    @ObservedObject var panel: PanelState

    var body: some View {
        if panel.showCursorInfo {
            HStack(spacing: 12) {
                if panel.hasCursorPatientPosition {
                    Text(String(format: "RAS %.1f, %.1f, %.1f mm",
                                panel.cursorPatientX, panel.cursorPatientY, panel.cursorPatientZ))
                        .foregroundStyle(.secondary)
                }
                Text("\(panel.valueUnitLabel): " + String(format: "%.0f", panel.cursorHU))
                if panel.hasCursorVoxelPosition {
                    Text(String(format: "px [%d, %d, %d]",
                                panel.cursorVoxelX, panel.cursorVoxelY, panel.cursorVoxelZ))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: "px [%d, %d]", panel.cursorPixelX, panel.cursorPixelY))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
