// ViewerControlBar.swift
// Lentis
//
// The single, docked control bar at the top of the viewer. It replaces every
// toolbar that used to float over the image (LayoutToolbar, the per-panel
// VolumeToolbar, the bottom-center PanelAdjustmentToolbar, and the modality /
// 4D PanelStatusCluster). Global controls (layout, sync, crosshair) act on the
// whole viewer; per-panel controls (plane, window, transform) act on the
// current *active* panel — selected by clicking a panel, shown by its border.
//
// Reuses ModalityBadge + PanelHistogramView (kept in MultiPanelContainer.swift).
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// Docked top control bar — the one place all viewer menus now live.
struct ViewerControlBar: View {
    @ObservedObject var model: ViewerModel
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        HStack(spacing: 10) {
            sidebarToggle

            Divider().frame(height: 22)

            ControlBarLayoutGroup(model: model)

            // Per-active-panel groups. The active panel itself is observed inside
            // ControlBarActivePanelGroups (not here) — its image arrives from an
            // async render that fires the *panel's* objectWillChange, not the
            // model's, so the guard must live in a panel observer or the groups
            // would never appear.
            if let panel = model.activePanel {
                ControlBarActivePanelGroups(model: model, panel: panel)
            }

            Spacer(minLength: 8)

            // 4D timepoint stepper (right side, NIfTI multi-volume only).
            if let ds = model.niftiDataset, ds.isMultiVolume {
                ControlBarTimepointGroup(model: model, dataset: ds)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// Re-show / hide the series sidebar. Lives here instead of floating over the
    /// image (replaces the old top-left floating button in ContentView).
    private var sidebarToggle: some View {
        Button(action: {
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        }) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
    }
}

// MARK: - Active-panel groups (plane + window + transform)

/// Observes the active panel so the plane/window/transform groups appear as soon
/// as that panel's async render lands its image — a guard placed in the parent
/// (which observes only the model) would stay stuck at the initial nil image.
private struct ControlBarActivePanelGroups: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState

    var body: some View {
        if panel.image != nil, panel.seriesIndex >= 0 {
            Divider().frame(height: 22)
            ControlBarPlaneGroup(model: model, panel: panel)

            Divider().frame(height: 22)
            ControlBarWindowGroup(model: model, panel: panel)

            Divider().frame(height: 22)
            ControlBarTransformGroup(model: model, panel: panel)
        }
    }
}

// MARK: - Layout + view toggles (global)

private struct ControlBarLayoutGroup: View {
    @ObservedObject var model: ViewerModel

    private static let layoutKeys = ["1", "2", "3", "4"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ViewerLayout.allCases.enumerated()), id: \.element.id) { idx, layout in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(layout) }
                }) {
                    Image(systemName: layout.iconName)
                        .font(.system(size: 13))
                        .foregroundStyle(model.layout == layout ? .white : .secondary)
                        .frame(width: 26, height: 26)
                        .background(model.layout == layout ? Color.accentColor.opacity(0.3) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("\(layout.description) — \(layout.rawValue) (\(Self.layoutKeys[idx]))")
            }

            // MPR tri-planar quad.
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) { model.setupMPRLayout() }
            }) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("MPR Tri-Planar Layout (⌘⇧M)")

            Divider().frame(height: 18)

            Button(action: { model.synchronizedScrolling.toggle() }) {
                Image(systemName: model.synchronizedScrolling ? "link" : "link.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(model.synchronizedScrolling ? .yellow : .secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(model.synchronizedScrolling
                  ? "Disable Synchronized Scrolling (L)"
                  : "Enable Synchronized Scrolling (L)")

            Button(action: { model.showCrossReference.toggle() }) {
                Image(systemName: "cross")
                    .font(.system(size: 13))
                    .foregroundStyle(model.showCrossReference ? .cyan : .secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(model.showCrossReference
                  ? "Hide Cross-Reference Lines (X)"
                  : "Show Cross-Reference Lines (X)")
        }
    }
}

// MARK: - Plane / 3D volume (active panel)

private struct ControlBarPlaneGroup: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState

    private var isVolumetric: Bool {
        model.isSeriesVolumetric(seriesIndex: panel.seriesIndex)
    }
    var body: some View {
        HStack(spacing: 4) {
            // Hide the inert 2D "Slice" mode on volumetric (NIfTI) panels.
            ForEach(PanelMode.allCases.filter { !($0 == .slice2D && isVolumetric) }) { mode in
                modeButton(mode)
            }

            if panel.panelMode == .volume3D {
                Divider().frame(height: 16)
                HStack(spacing: 6) {
                    Text("Density")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Slider(
                        value: Binding(
                            get: { panel.volumeOpacity },
                            set: {
                                panel.volumeOpacity = $0
                                model.loadVolumeRendering(for: panel, interactive: true)
                            }
                        ),
                        in: 0.25...2.5
                    ) {
                        Text("Volume density")
                    } onEditingChanged: { editing in
                        if !editing { model.loadVolumeRendering(for: panel) }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 104)

                    Text(String(format: "%.1f×", panel.volumeOpacity))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)

                    Button(action: { model.resetVolumeCamera(panel) }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(.caption))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Reset 3D camera and density")
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if model.isVolumeBuildingInProgress {
                Divider().frame(height: 16)
                ProgressView(value: model.volumeBuildProgress).frame(width: 60)
                Text(String(format: "%.0f%%", model.volumeBuildProgress * 100))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modeButton(_ mode: PanelMode) -> some View {
        let needsVolume = mode != .slice2D
        let modeDisabled = needsVolume && !isVolumetric
        let foreground: Color = modeDisabled ? .gray.opacity(0.35) :
            panel.panelMode == mode ? .white : .secondary
        Button(action: { model.setPanelMode(panel, mode: mode) }) {
            Text(mode.rawValue)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundColor(foreground)
                .background(panel.panelMode == mode ? Color.accentColor.opacity(0.4) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(modeDisabled)
    }
}

// MARK: - Modality + window (active panel)

private struct ControlBarWindowGroup: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState

    private var isNiftiPanel: Bool {
        model.niftiDataset != nil && panel.seriesIndex == model.niftiSeriesIndex
    }

    var body: some View {
        HStack(spacing: 8) {
            if isNiftiPanel, let modality = model.effectiveModality {
                ModalityBadge(model: model, modality: modality)
            }

            if !panel.histogramData.isEmpty {
                PanelHistogramView(
                    data: panel.histogramData,
                    minVal: panel.minPixelValue,
                    maxVal: panel.maxPixelValue,
                    windowWidth: panel.windowWidth,
                    windowCenter: panel.windowCenter
                )
                .frame(width: 90, height: 32)
                .background(Color.black.opacity(0.5))
                .border(Color.white.opacity(0.2), width: 1)
                .help("Intensity histogram — yellow band = current window, white line = level (center)")
            }

            if isNiftiPanel {
                modalityControls
            } else {
                autoButton
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// CT HU preset menu, or the MRI percentile auto-window button.
    @ViewBuilder
    private var modalityControls: some View {
        if model.effectiveModality == .ct {
            Menu {
                ForEach(WindowPreset.ctPresets) { preset in
                    Button("\(preset.name)  (W \(Int(preset.width)) / L \(Int(preset.center)))") {
                        model.applyWindowPreset(preset)
                    }
                }
            } label: {
                Label("Preset", systemImage: "dial.medium")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("CT window presets (HU)")
        } else {
            Button(action: { model.applyModalityAutoWindow() }) { autoLabel }
                .help("MRI percentile auto-window (A)")
        }
    }

    private var autoButton: some View {
        Button(action: { model.autoWindow(for: panel) }) { autoLabel }
            .help("Auto W/L (A)")
    }

    private var autoLabel: some View {
        HStack(spacing: 4) {
            Text("Auto")
            Text("A")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.15))
                .cornerRadius(3)
        }
    }
}

// MARK: - Rotate / flip / fullscreen (active panel)

private struct ControlBarTransformGroup: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState

    var body: some View {
        HStack(spacing: 4) {
            if panel.panelMode != .volume3D {
                Button(action: { panel.rotationSteps = (panel.rotationSteps + 1) % 4 }) {
                    Image(systemName: "rotate.right").font(.system(.caption)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Rotate 90° clockwise (])")

                Button(action: { panel.isFlippedH.toggle() }) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.system(.caption))
                        .foregroundStyle(panel.isFlippedH ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Flip horizontal (H)")

                Button(action: { panel.isFlippedV.toggle() }) {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        .font(.system(.caption))
                        .foregroundStyle(panel.isFlippedV ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Flip vertical")
            }

            Button(action: { model.toggleFullscreen(for: panel) }) {
                Image(systemName: model.fullscreenPanelID == panel.id
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(.caption))
                    .foregroundStyle(model.fullscreenPanelID == panel.id ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(model.fullscreenPanelID == panel.id ? "Exit fullscreen (double-click)" : "Fullscreen (double-click)")
        }
    }
}

// MARK: - 4D timepoint stepper (global, NIfTI multi-volume)

private struct ControlBarTimepointGroup: View {
    @ObservedObject var model: ViewerModel
    let dataset: NiftiDataset

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill").font(.caption2)
            Text("Vol \(model.currentTimepoint + 1)/\(dataset.timepointCount)")
                .font(.system(.caption, design: .monospaced))
            Stepper("", value: Binding(
                get: { model.currentTimepoint },
                set: { model.selectTimepoint($0) }
            ), in: 0...(dataset.timepointCount - 1))
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.black.opacity(0.4), in: Capsule())
        .foregroundStyle(.white)
    }
}
