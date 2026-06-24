// ViewerToolbar.swift
// Lentis
//
// The viewer's controls expressed as native macOS toolbar content. Replaces the
// old custom docked ViewerControlBar: on macOS 26 the window toolbar gets the
// Liquid Glass treatment for free, plus automatic overflow and customization.
//
// Global controls (layout, view toggles) sit at the leading edge; per-active-
// panel controls (plane, modality, window/level, transform) and the 4D stepper
// + inspector toggle sit at the trailing edge. Per-panel views observe the
// *panel* (its async image/W-L fires the panel's objectWillChange, not the
// model's), mirroring the proven reactivity split from the old control bar.
//
// Reuses ModalityBadge + PanelHistogramView (defined in MultiPanelContainer).
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// All viewer toolbar items. Attach via `.toolbar { ViewerToolbar(model:) }`.
struct ViewerToolbar: ToolbarContent {
    @ObservedObject var model: ViewerModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            LayoutToolbarControls(model: model)
            ViewToggleControls(model: model)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let panel = model.activePanel {
                ActivePanelToolbarControls(model: model, panel: panel)
            }
            if let ds = model.niftiDataset, ds.isMultiVolume {
                TimepointToolbarControls(model: model, dataset: ds)
            }
        }

        // NOTE: the inspector show/hide toggle is intentionally NOT declared here.
        // ContentView owns the closed-state Show control; LayerInspectorView owns
        // the open-state Hide control so it can sit at the window's top-right
        // corner above the inspector. Keeping it out of this nested ToolbarContent
        // avoids stale re-evaluation and duplicate drawer buttons.
    }
}

// MARK: - Global: layout + view toggles

private struct LayoutToolbarControls: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        Picker("Layout", selection: Binding(
            get: { model.layout },
            set: { newValue in withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(newValue) } }
        )) {
            ForEach(ViewerLayout.allCases) { layout in
                Image(systemName: layout.iconName).tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Panel layout (1–4)")

        Button {
            withAnimation(.easeInOut(duration: 0.25)) { model.setupMPRLayout() }
        } label: {
            Image(systemName: "cube.transparent")
        }
        .help("MPR Tri-Planar Layout (⌘⇧M)")
    }
}

private struct ViewToggleControls: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        Button {
            model.synchronizedScrolling.toggle()
        } label: {
            Image(systemName: model.synchronizedScrolling ? "link" : "link.badge.plus")
                .foregroundStyle(model.synchronizedScrolling ? Color.lentisLink : .secondary)
        }
        .help(model.synchronizedScrolling
              ? "Disable Synchronized Scrolling (L)"
              : "Enable Synchronized Scrolling (L)")

        Button {
            model.showCrossReference.toggle()
        } label: {
            Image(systemName: "cross")
                .foregroundStyle(model.showCrossReference ? Color.lentisCrosshair : .secondary)
        }
        .help(model.showCrossReference ? "Hide Crosshair (X)" : "Show Crosshair (X)")

        SettingsLink {
            Image(systemName: "gearshape")
        }
        .help("Settings (⌘,)")
    }
}

// MARK: - Active-panel cluster (plane · modality · window/level · transform)

/// One cohesive trailing cluster for the active panel. Observes the panel so it
/// appears as soon as that panel's async render lands its image.
private struct ActivePanelToolbarControls: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState

    private var isNiftiPanel: Bool {
        model.niftiDataset != nil && panel.seriesIndex == model.niftiSeriesIndex
    }

    var body: some View {
        if panel.image != nil, panel.seriesIndex >= 0 {
            HStack(spacing: Spacing.s) {
                PlaneToolbarControl(model: model, panel: panel)

                if isNiftiPanel, let modality = model.effectiveModality {
                    ModalityBadge(model: model, modality: modality)
                }

                WindowLevelToolbarControl(model: model, panel: panel)
                TransformToolbarControl(model: model, panel: panel)
            }
        }
    }
}

// MARK: - Plane / 3D

private struct PlaneToolbarControl: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState
    @State private var showVolumeControls = false

    private var isVolumetric: Bool {
        model.isSeriesVolumetric(seriesIndex: panel.seriesIndex)
    }

    var body: some View {
        Picker("Plane", selection: Binding(
            get: { panel.panelMode },
            set: { model.setPanelMode(panel, mode: $0) }
        )) {
            ForEach(PanelMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!isVolumetric)
        .help("Viewing plane")

        if panel.panelMode == .volume3D {
            Button { showVolumeControls.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("3D density & camera")
            .popover(isPresented: $showVolumeControls, arrowEdge: .bottom) {
                VolumeControlsPopover(model: model, panel: panel)
            }
        }
    }
}

private struct VolumeControlsPopover: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("3D Volume").font(.headline)

            HStack(spacing: Spacing.s) {
                Text("Density").font(.lentisReadout).foregroundStyle(.secondary)
                // NOTE: no `step:` — a stepped Slider over the volume depth caused
                // ~2 s of mark layout per event (see CLAUDE.md). Keep it continuous.
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
                .frame(width: 160)

                Text(String(format: "%.1f×", panel.volumeOpacity))
                    .font(.lentisReadout)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            Button { model.resetVolumeCamera(panel) } label: {
                Label("Reset Camera & Density", systemImage: "arrow.counterclockwise")
            }
        }
        .padding(Spacing.l)
        .frame(width: 280)
    }
}

// MARK: - Window / level (modality-aware), with histogram + presets in a popover

private struct WindowLevelToolbarControl: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            Label {
                Text(panel.windowWidth != 0
                     ? "WL \(Int(panel.windowCenter))  WW \(Int(panel.windowWidth))"
                     : "Window")
                    .font(.lentisReadout)
            } icon: {
                Image(systemName: "dial.medium")
            }
        }
        .help("Window / Level")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            WindowLevelPopover(model: model, panel: panel)
        }
    }
}

private struct WindowLevelPopover: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState

    private var isNiftiPanel: Bool {
        model.niftiDataset != nil && panel.seriesIndex == model.niftiSeriesIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Window / Level").font(.headline)

            if !panel.histogramData.isEmpty {
                PanelHistogramView(
                    data: panel.histogramData,
                    minVal: panel.minPixelValue,
                    maxVal: panel.maxPixelValue,
                    windowWidth: panel.windowWidth,
                    windowCenter: panel.windowCenter
                )
                .frame(width: 240, height: 64)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }

            if panel.windowWidth != 0 {
                Text(String(format: "WL %.0f   WW %.0f%@",
                            panel.windowCenter, panel.windowWidth,
                            panel.valueUnitLabel == "HU" ? "  HU" : ""))
                    .font(.lentisReadout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if isNiftiPanel, model.effectiveModality == .ct {
                Text("CT Presets (HU)").font(.caption).foregroundStyle(.secondary)
                ForEach(WindowPreset.ctPresets) { preset in
                    Button {
                        model.applyWindowPreset(preset)
                    } label: {
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Text("W \(Int(preset.width)) · L \(Int(preset.center))")
                                .font(.lentisReadout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    if isNiftiPanel { model.applyModalityAutoWindow() }
                    else { model.autoWindow(for: panel) }
                } label: {
                    Label("Auto Window (A)", systemImage: "wand.and.stars")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(Spacing.l)
        .frame(width: 280)
    }
}

// MARK: - Transform (rotate / flip / fullscreen) consolidated into a menu

private struct TransformToolbarControl: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState

    var body: some View {
        Menu {
            if panel.panelMode != .volume3D {
                Button { model.rotateClockwiseForPanel(panel) } label: {
                    Label("Rotate 90° Clockwise (])", systemImage: "rotate.right")
                }
                Button { model.rotateCounterClockwiseForPanel(panel) } label: {
                    Label("Rotate 90° Counter-Clockwise ([)", systemImage: "rotate.left")
                }
                Toggle(isOn: $panel.isFlippedH) {
                    Label("Flip Horizontal (H)", systemImage: "arrow.left.and.right")
                }
                Toggle(isOn: $panel.isFlippedV) {
                    Label("Flip Vertical", systemImage: "arrow.up.and.down")
                }
                Divider()
            }
            Button { model.toggleFullscreen(for: panel) } label: {
                Label(model.fullscreenPanelID == panel.id ? "Exit Fullscreen" : "Fullscreen",
                      systemImage: model.fullscreenPanelID == panel.id
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
            }
        } label: {
            Image(systemName: "crop.rotate")
        }
        .help("Rotate · flip · fullscreen")
    }
}

// MARK: - 4D timepoint stepper

private struct TimepointToolbarControls: View {
    @ObservedObject var model: ViewerModel
    let dataset: NiftiDataset

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "square.stack.3d.up.fill").font(.caption2)
            Text("Vol \(model.currentTimepoint + 1)/\(dataset.timepointCount)")
                .font(.lentisReadout)
            Stepper("", value: Binding(
                get: { model.currentTimepoint },
                set: { model.selectTimepoint($0) }
            ), in: 0...(dataset.timepointCount - 1))
            .labelsHidden()
        }
        .help("4D timepoint")
    }
}
