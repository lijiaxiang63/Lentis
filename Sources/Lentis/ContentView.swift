// ContentView.swift
// Lentis
//
// Root view of the application. Implements a NavigationSplitView with:
//   - Sidebar: file open button, series list with thumbnails and panel indicators
//   - Detail: multi-panel NIfTI viewer with floating layout toolbar
//
// Also handles all keyboard shortcuts and file drag-and-drop.
//
// Key types:
//   ContentView       — Top-level split view + keyboard routing
//   SidebarView       — Open button + series list
//   SeriesListView    — Scrollable list of series with panel assignment indicators
//   SeriesRow         — Single series row: thumbnail, description, panel grid icon
//   PanelPositionIndicator — Miniature grid showing which panels display a series
//   DetailView        — Legacy single-panel detail (used as fallback)
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import UniformTypeIdentifiers
import QuartzCore



struct ContentView: View {
    @ObservedObject var model: ViewerModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            ZStack(alignment: .leading) {
                MultiPanelContainer(model: model, isFocused: $isFocused)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        _ = handleDrop(providers: providers)
                        return true
                    }
                    .onTapGesture {
                        isFocused = true
                    }

                // Floating glass tool capsule, vertically centered on the
                // viewport's leading edge.
                ToolPalette(model: model)
                    .padding(.leading, Spacing.m)

                if model.isLoading || model.isScanningFolder {
                    NiftiLoadingOverlay(scanningFolder: model.isScanningFolder && !model.isLoading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        .zIndex(1_000)
                }
            }
            // Floating glass status pill, bottom-leading (only once a file is open).
            .overlay(alignment: .bottomLeading) {
                if !model.allSeries.isEmpty {
                    ViewerStatusBar(model: model)
                        .padding(.leading, Spacing.m)
                        .padding(.bottom, Spacing.m)
                }
            }
            // Floating glass success banner (top-center), e.g. after a direct export.
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    ToastBanner(toast: toast) { model.revealToastFile() }
                        .padding(.top, Spacing.l)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(2_000)
                        .onTapGesture { model.dismissToast() }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.toast)
            // The window title is now the open file (native macOS pattern) — this
            // replaces the old custom centered-title hack in WindowAccessor.
            .navigationTitle(windowTitle)
            .navigationSubtitle(windowSubtitle)
            .toolbar {
                ViewerToolbar(model: model)

                // Closed-state Layers Inspector drawer toggle. When the drawer is
                // open, the matching Hide toggle moves into LayerInspectorView's
                // toolbar section so it stays pinned to the window's top-right
                // corner above the inspector. Keep the two declarations mutually
                // exclusive: otherwise macOS can render duplicate sidebar buttons.
                if !model.showLayerInspector {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showLayerInspector = true
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help("Show Layers Inspector")
                        .accessibilityLabel("Show Layers inspector")
                    }
                }
            }
        }
        // Keyboard Handlers — route through active panel
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            if let panel = model.activePanel {
                model.navigatePanel(panel, direction: .prevSeries)
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if let panel = model.activePanel {
                model.navigatePanel(panel, direction: .nextSeries)
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if let panel = model.activePanel {
                model.navigatePanel(panel, direction: .prevImage)
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if let panel = model.activePanel {
                model.navigatePanel(panel, direction: .nextImage)
            }
            return .handled
        }
        .onKeyPress(.tab) {
            cyclePanelForward()
            return .handled
        }
        .onKeyPress(.pageUp) {
            if let panel = model.activePanel {
                model.navigatePanelByOffset(panel, offset: -10)
            }
            return .handled
        }
        .onKeyPress(.pageDown) {
            if let panel = model.activePanel {
                model.navigatePanelByOffset(panel, offset: 10)
            }
            return .handled
        }
        .onKeyPress(.home) {
            if let panel = model.activePanel {
                model.navigatePanelToEdge(panel, toFirst: true)
            }
            return .handled
        }
        .onKeyPress(.end) {
            if let panel = model.activePanel {
                model.navigatePanelToEdge(panel, toFirst: false)
            }
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            // Letter/number shortcuts are handled by NSEvent keyDown monitor in ViewerModel
            // (works regardless of input method). This handler covers special keys only.

            // Escape = exit ROI-box mode / discard unsaved draft region, or clear
            // group selection.
            if press.key == .escape {
                if model.draftRegion != nil || model.activeTool == .roiBox {
                    model.cancelActiveRegion()
                    model.activeTool = .select
                    return .handled
                }
                if model.groupSelectedPanels.count > 0 {
                    model.clearGroupSelection()
                    return .handled
                }
            }

            return .ignored
        }
        .sheet(isPresented: $model.showHelp) {
            HelpView()
        }
        .inspector(isPresented: $model.showLayerInspector) {
            LayerInspectorView(model: model)
                .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
        .alert("Couldn’t Add Layer", isPresented: Binding(
            get: { model.layerImportError != nil },
            set: { if !$0 { model.layerImportError = nil } }
        )) {
            Button("OK", role: .cancel) { model.layerImportError = nil }
        } message: {
            Text(model.layerImportError ?? "")
        }
        .alert(model.pendingConfirmation?.title ?? "",
               isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.cancelPendingConfirmation() } }
               )) {
            Button("Cancel", role: .cancel) { model.cancelPendingConfirmation() }
            Button(model.pendingConfirmation?.actionLabel ?? "Continue", role: .destructive) {
                model.performPendingConfirmation()
            }
        } message: {
            Text(model.pendingConfirmation?.message ?? "")
        }
        .animation(.easeInOut(duration: 0.2), value: model.isLoading)
        .preferredColorScheme(.dark)
        // Drive every accent-aware native control (segmented pickers, selection,
        // glass-prominent buttons, toggles) from the signature Lentis accent.
        .tint(.lentisAccent)
        .background(WindowAccessor(model: model))
    }

    // MARK: - Window title

    /// Window title = the open NIfTI file name (or the app name when nothing is
    /// loaded). Replaces the old custom centered-title machinery.
    private var windowTitle: String {
        model.loadedFileName.isEmpty ? "Lentis" : model.loadedFileName
    }

    /// Window subtitle = the active volume's modality · dimensions, when available.
    private var windowSubtitle: String {
        guard let panel = model.activePanel, panel.seriesIndex >= 0,
              let vol = model.cachedVolume(forSeriesIndex: panel.seriesIndex) else { return "" }
        let dims = "\(vol.width)×\(vol.height)×\(vol.depth)"
        if let modality = model.effectiveModality?.rawValue {
            return "\(modality) · \(dims)"
        }
        return dims
    }

    // MARK: - Handlers

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        // Ignore drops while a load/scan is already in flight (mirrors the Open
        // controls' guard) so two rapid drops can't race two concurrent loads.
        guard !model.isLoading && !model.isScanningFolder else { return false }
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        // Route through `requestLoad` so an unsaved segmentation /
                        // layers can be confirmed first (per the
                        // `confirmReplaceOnDiscard` preference). With no prior file
                        // open, requestLoad just loads — same as the Open menu.
                        DispatchQueue.main.async { model.requestLoad(url: url) }
                    }
                }
                return true
            }
        }
        return false
    }

    private func cyclePanelForward() {
        guard model.panels.count > 1 else { return }
        if let currentIndex = model.panels.firstIndex(where: { $0.id == model.activePanelID }) {
            let nextIndex = (currentIndex + 1) % model.panels.count
            model.activePanelID = model.panels[nextIndex].id
        }
    }
}

/// Window-level feedback while a NIfTI file is decompressed, analysed, and
/// converted into the canonical display volume. The loader cannot report
/// byte-accurate progress, so this deliberately uses an indeterminate system
/// progress indicator rather than presenting a misleading percentage.
private struct NiftiLoadingOverlay: View {
    /// True while scanning an opened folder into a dataset (vs. loading a volume).
    var scanningFolder: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                VStack(spacing: 4) {
                    Text(scanningFolder ? "Scanning folder…" : "Loading NIfTI…")
                        .font(.headline)
                    Text(scanningFolder ? "Finding NIfTI images in the dataset"
                                        : "Decompressing and preparing the volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.card))
            .shadow(radius: 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(scanningFolder ? "Scanning folder" : "Loading NIfTI file")
    }
}

struct SidebarView: View {
    @ObservedObject var model: ViewerModel

    /// Sidebar header title: the open dataset name, or "Files" for a single file.
    private var headerTitle: String { model.dataset?.name ?? "Files" }

    /// Subtitle under the header for an open dataset (subject + image counts).
    private var headerSubtitle: String? {
        guard let d = model.dataset else { return nil }
        let images = "\(d.imageCount) \(d.imageCount == 1 ? "image" : "images")"
        if d.isBIDS {
            let subs = "\(d.subjectCount) \(d.subjectCount == 1 ? "subject" : "subjects")"
            return "\(subs) · \(images)"
        }
        return "Folder · \(images)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let sub = headerSubtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                OpenMenu(model: model)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)

            if let dataset = model.dataset {
                BIDSNavigatorView(model: model, dataset: dataset)
            } else {
                SeriesListView(model: model)
            }
        }
    }
}

/// The sidebar's primary Open control: a glass-prominent split button. A direct
/// click opens the unified panel (file *or* folder); the menu offers the two
/// explicit choices.
struct OpenMenu: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        Menu {
            Button { model.openFile() } label: { Label("Open File…", systemImage: "doc") }
            Button { model.openFolder() } label: { Label("Open Folder…", systemImage: "folder.badge.plus") }
        } label: {
            Label("Open", systemImage: "folder")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            model.openFileOrFolder()
        }
        .menuStyle(.button)
        .buttonStyle(.glassProminent)
        .controlSize(.small)
        .fixedSize()
        .help("Open a NIfTI file or a folder / BIDS dataset")
        .disabled(model.isLoading || model.isScanningFolder)
    }
}

struct SeriesListView: View {
    @ObservedObject var model: ViewerModel

    /// The series index shown by the active panel (for highlight)
    private var activeSeriesIndex: Int {
        model.activePanel?.seriesIndex ?? model.currentSeriesIndex
    }

    /// Row background color for a given series index
    private func rowBackground(for index: Int) -> Color? {
        if index == activeSeriesIndex {
            return Color.lentisAccent.opacity(0.18)
        }
        if model.panels.contains(where: { $0.seriesIndex == index }) {
            return Color.lentisAccent.opacity(0.06)
        }
        return nil
    }

    var body: some View {
        List(selection: $model.currentSeriesIndex) {
            ForEach(model.allSeries.indices, id: \.self) { index in
                SeriesRow(model: model, series: model.allSeries[index], isSelected: index == activeSeriesIndex, seriesIndex: index)
                .contentShape(Rectangle())
                .onDrag {
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(
                        forTypeIdentifier: "public.utf8-plain-text",
                        visibility: .all
                    ) { completion in
                        completion("\(index)".data(using: .utf8), nil)
                        return nil
                    }
                    return provider
                }
                .onTapGesture {
                    model.currentImageIndex = 0
                    model.currentSeriesIndex = index
                    if let panel = model.activePanel {
                        model.assignSeriesToPanel(panel, seriesIndex: index)
                    }
                }
                .listRowBackground(rowBackground(for: index))
            }
            
        }
        .listStyle(.sidebar)
        .overlay {
             if model.allSeries.isEmpty {
                 ContentUnavailableView {
                     Label("No file open", systemImage: "doc.badge.plus")
                 } description: {
                     Text("Open a `.nii` / `.nii.gz` file or a folder / BIDS dataset above, or drag one here.")
                 }
             }
        }
    }
}

struct SeriesRow: View {
    @ObservedObject var model: ViewerModel
    let series: ImageSeries
    let isSelected: Bool
    let seriesIndex: Int

    /// Whether any panel is displaying this series
    private var isInAnyPanel: Bool {
        model.panels.contains { $0.seriesIndex == seriesIndex }
    }

    /// True when this row is the loaded NIfTI volume (the only series in NIfTI mode).
    private var isNiftiSeries: Bool {
        model.niftiDataset != nil && seriesIndex == model.niftiSeriesIndex
    }

    /// Row title: the file name for a NIfTI volume, else the legacy series label.
    private var rowTitle: String {
        if isNiftiSeries, !model.loadedFileName.isEmpty { return model.loadedFileName }
        return "Series \(series.seriesNumber)"
    }

    /// Row subtitle: "CT · 512×512×221" for a NIfTI volume, else its description.
    private var rowSubtitle: String {
        if isNiftiSeries, let vol = model.cachedVolume(forSeriesIndex: seriesIndex) {
            let dims = "\(vol.width)×\(vol.height)×\(vol.depth)"
            if let modality = model.effectiveModality?.rawValue {
                return "\(modality) · \(dims)"
            }
            return dims
        }
        return series.seriesDescription
    }

    var body: some View {
        HStack {
            Group {
                if let thumb = model.seriesThumbnails[series.id] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .cornerRadius(4)
                } else {
                    Image(systemName: isNiftiSeries ? "brain.head.profile" : "folder")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !rowSubtitle.isEmpty {
                    Text(rowSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isInAnyPanel {
                PanelPositionIndicator(model: model, seriesIndex: seriesIndex)
            }
        }
    }
}

/// Miniature grid icon showing which panel(s) display a given series.
/// Each cell is a tiny rounded rectangle: filled blue if the panel shows this series, border-only otherwise.
struct PanelPositionIndicator: View {
    @ObservedObject var model: ViewerModel
    let seriesIndex: Int

    private let cellSize: CGFloat = 7
    private let spacing: CGFloat = 2

    var body: some View {
        let rows = model.layout.rows
        let cols = model.layout.columns

        VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<cols, id: \.self) { col in
                        let panelIdx = row * cols + col
                        let isFilled = panelIdx < model.panels.count && model.panels[panelIdx].seriesIndex == seriesIndex
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isFilled ? Color.lentisAccent : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1.5)
                                    .strokeBorder(Color.lentisAccent.opacity(isFilled ? 1 : 0.4), lineWidth: 1)
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
    }
}
