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
            SidebarView(model: model, columnVisibility: $columnVisibility)
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(spacing: 0) {
                // Fixed tool palette column
                ToolPalette(model: model)
                    .padding(.vertical, 8)

                // Main viewer area
                ZStack(alignment: .topLeading) {
                    // Multi-panel container replaces old single DetailView
                    MultiPanelContainer(model: model, isFocused: $isFocused)
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            _ = handleDrop(providers: providers)
                            return true
                        }
                        .onTapGesture {
                            isFocused = true
                        }

                    // Floating controls overlay
                    VStack {
                        HStack(alignment: .top) {
                            // Sidebar toggle (when hidden)
                            if columnVisibility == .detailOnly {
                                Button(action: { columnVisibility = .all }) {
                                    Image(systemName: "sidebar.right")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                        .padding(8)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .help("Show Sidebar")
                            }

                            Spacer()

                            // Layout toolbar
                            LayoutToolbar(model: model)
                        }
                        .padding()

                        Spacer()
                    }

                    if model.isLoading {
                        NiftiLoadingOverlay()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                            .zIndex(1_000)
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

            // Escape = Clear group selection
            if press.key == .escape {
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
        .animation(.easeInOut(duration: 0.2), value: model.isLoading)
        .preferredColorScheme(.dark)
        .background(WindowAccessor(model: model))
    }

    // MARK: - Handlers

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async { model.load(url: url) }
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
    var body: some View {
        ZStack {
            Color.black.opacity(0.5)

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                VStack(spacing: 4) {
                    Text("Loading NIfTI…")
                        .font(.headline)
                    Text("Decompressing and preparing the volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading NIfTI file")
    }
}

struct SidebarView: View {
    @ObservedObject var model: ViewerModel
    @Binding var columnVisibility: NavigationSplitViewVisibility
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom Toolbar / Header
            HStack {
                Button(action: { columnVisibility = .detailOnly }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide Sidebar")
                
                Spacer()
                
                Button(action: openFile) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Open")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open NIfTI File")
                .disabled(model.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Remove background or make it very subtle
            // .background(Color.black.opacity(0.4))
            
            SeriesListView(model: model)
        }
    }
    
    private func openFile() {
        model.openFile()
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
            return Color.blue.opacity(0.15)
        }
        if model.panels.contains(where: { $0.seriesIndex == index }) {
            return Color.blue.opacity(0.05)
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
                     Text("Click Open above, or drag a .nii / .nii.gz file here.")
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
                            .fill(isFilled ? Color.blue : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1.5)
                                    .strokeBorder(Color.blue.opacity(isFilled ? 1 : 0.4), lineWidth: 1)
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
    }
}
