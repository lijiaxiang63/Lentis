// LayerInspectorView.swift
// Lentis
//
// Native trailing inspector for session mask/atlas layers.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import UniformTypeIdentifiers

struct LayerInspectorView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject private var store: LayerStore
    @Environment(\.undoManager) private var undoManager

    init(model: ViewerModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.layerStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VSplitView {
                layerList
                    .frame(minHeight: 130, idealHeight: 220)

                if let layer = store.selectedLayer {
                    LayerDetailsView(model: model, store: store, layer: layer)
                        .id(layer.id)
                        .frame(minHeight: 260)
                } else {
                    ContentUnavailableView(
                        "No Layer Selected",
                        systemImage: "square.3.layers.3d",
                        description: Text(store.layers.isEmpty
                                          ? "Add a mask or atlas label NIfTI file."
                                          : "Select a layer to edit its appearance.")
                    )
                    .frame(minHeight: 220)
                }
            }

            footer
        }
        .background(.background)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .onDeleteCommand(perform: removeSelectedLayer)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layers inspector")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Layers")
                .font(.headline)
            Spacer()
            if model.isImportingLayers {
                ProgressView()
                    .controlSize(.small)
                    .help("Loading and aligning layers")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var layerList: some View {
        List(selection: Binding(
            get: { store.selectedLayerID },
            set: { store.selectedLayerID = $0 }
        )) {
            ForEach(store.layers) { layer in
                LayerRow(store: store, layer: layer)
                    .tag(layer.id)
            }
            .onMove(perform: store.move)
        }
        .listStyle(.inset)
        .overlay {
            if store.layers.isEmpty {
                ContentUnavailableView {
                    Label("No Layers", systemImage: "square.3.layers.3d")
                } description: {
                    Text(model.niftiDataset == nil
                         ? "Open a base NIfTI image first."
                         : "Add or drop a 3D mask or atlas NIfTI here.")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: model.openLayerFiles) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.niftiDataset == nil || model.isImportingLayers)
            .help("Add Mask or Atlas Layer")
            .accessibilityLabel("Add layer")

            Button(action: removeSelectedLayer) {
                Image(systemName: "minus")
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(store.selectedLayerID == nil)
            .help("Remove Layer")
            .accessibilityLabel("Remove selected layer")

            Spacer()
            Text("Top layer renders last")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
    }

    private func removeSelectedLayer() {
        guard let id = store.selectedLayerID,
              let removed = store.remove(id: id) else { return }
        undoManager?.registerUndo(withTarget: store) { target in
            target.restore(removed.layer, at: removed.index)
        }
        undoManager?.setActionName("Remove Layer")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                guard let url = object else { return }
                DispatchQueue.main.async { model.addLayerFiles([url]) }
            }
        }
        return accepted
    }
}

private struct LayerRow: View {
    @ObservedObject var store: LayerStore
    @ObservedObject var layer: OverlayLayer

    private var subtitle: String {
        let count = layer.volume.labelCounts.values.reduce(0, +)
        if layer.kind == .mask { return "Mask · \(count.formatted()) voxels" }
        let total = layer.volume.labelsPresent.count
        let visible = max(0, total - layer.hiddenLabelIDs.count)
        return "Atlas · \(visible)/\(total) labels"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.setVisible(!layer.isVisible, for: layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(layer.isVisible ? "Hide Layer" : "Show Layer")
            .accessibilityLabel(layer.isVisible ? "Hide \(layer.name)" : "Show \(layer.name)")

            LayerSwatch(store: store, layer: layer)

            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(layer.kind.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .contentShape(Rectangle())
        .opacity(layer.isVisible ? 1 : 0.62)
    }
}

private struct LayerSwatch: View {
    @ObservedObject var store: LayerStore
    @ObservedObject var layer: OverlayLayer

    var body: some View {
        Group {
            if layer.kind == .mask {
                Circle().fill(Color(rgb: layer.maskColor))
            } else {
                HStack(spacing: -4) {
                    ForEach(Array(layer.volume.labelsPresent.prefix(3)), id: \.self) { label in
                        let entry = store.lookupTable(id: layer.lutID)?[label]
                            ?? ColorLookupTable.fallbackEntry(for: label)
                        Circle()
                            .fill(Color(lutEntry: entry))
                            .overlay(Circle().stroke(.background, lineWidth: 1))
                    }
                }
            }
        }
        .frame(width: 24, height: 18)
        .accessibilityHidden(true)
    }
}

private struct LayerDetailsView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var store: LayerStore
    @ObservedObject var layer: OverlayLayer
    @State private var searchText = ""
    @State private var showLUTManager = false
    @State private var errorMessage: String?

    private var filteredLabels: [Int32] {
        guard layer.kind == .atlas else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return layer.volume.labelsPresent }
        let lut = store.lookupTable(id: layer.lutID)
        return layer.volume.labelsPresent.filter { label in
            let entry = lut?[label] ?? ColorLookupTable.fallbackEntry(for: label)
            return String(label).contains(query) || entry.name.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    appearanceSection
                    if layer.kind == .atlas {
                        HoveredAtlasLabel(model: model, store: store, layer: layer)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: layer.kind == .atlas ? 260 : .infinity)

            if layer.kind == .atlas {
                Divider()
                atlasHeader
                List(filteredLabels, id: \.self) { label in
                    AtlasLabelRow(store: store, layer: layer, label: label)
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showLUTManager) {
            LUTManagerView(store: store)
        }
        .alert("Layer Settings Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var appearanceSection: some View {
        GroupBox("Appearance") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Type").foregroundStyle(.secondary)
                    Picker("Type", selection: Binding(
                        get: { layer.kind },
                        set: { newValue in
                            if !store.setKind(newValue, for: layer.id) {
                                errorMessage = "This non-integer mask cannot be reinterpreted as an atlas."
                            }
                        }
                    )) {
                        Text("Mask").tag(OverlayLayerKind.mask)
                        Text("Atlas").tag(OverlayLayerKind.atlas)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                GridRow {
                    Text("Opacity").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { layer.opacity },
                            set: { store.setOpacity($0, for: layer.id) }
                        ), in: 0...1)
                        Text(layer.opacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                if layer.kind == .mask {
                    GridRow {
                        Text("Color").foregroundStyle(.secondary)
                        ColorPicker("Mask Color", selection: Binding(
                            get: { Color(rgb: layer.maskColor) },
                            set: { color in
                                if let converted = NSColor(color).usingColorSpace(.deviceRGB) {
                                    store.setMaskColor(
                                        SIMD3(Double(converted.redComponent),
                                              Double(converted.greenComponent),
                                              Double(converted.blueComponent)),
                                        for: layer.id
                                    )
                                }
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                } else {
                    GridRow {
                        Text("Color LUT").foregroundStyle(.secondary)
                        Picker("Color LUT", selection: Binding(
                            get: { layer.lutID },
                            set: { store.setLookupTable($0, for: layer.id) }
                        )) {
                            ForEach(store.lookupTables) { lut in
                                Text(lut.name).tag(lut.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        HStack {
                            Button("Import LUT…", action: importLUT)
                            Button("Manage…") { showLUTManager = true }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var atlasHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Labels")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Show All") { store.showAllLabels(in: layer.id) }
                    Button("Hide All") { store.hideAllLabels(in: layer.id) }
                    Button("Invert Visibility") { store.invertLabelVisibility(in: layer.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Label Visibility Actions")
            }
            TextField("Search labels", text: $searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func importLUT() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a FreeSurfer-format color LUT"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let table = try store.importLookupTable(from: url)
            store.setLookupTable(table.id, for: layer.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HoveredAtlasLabel: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var store: LayerStore
    @ObservedObject var layer: OverlayLayer

    var body: some View {
        ForEach(model.panels) { panel in
            HoveredAtlasLabelForPanel(panel: panel, store: store, layer: layer)
        }
    }
}

private struct HoveredAtlasLabelForPanel: View {
    @ObservedObject var panel: PanelState
    @ObservedObject var store: LayerStore
    @ObservedObject var layer: OverlayLayer

    var body: some View {
        if panel.showCursorInfo, panel.hasCursorVoxelPosition {
            let label = layer.volume.labelAt(
                x: panel.cursorVoxelX, y: panel.cursorVoxelY, z: panel.cursorVoxelZ
            )
            let entry = store.lookupTable(id: layer.lutID)?[label]
                ?? ColorLookupTable.fallbackEntry(for: label)
            GroupBox("Cursor Label") {
                HStack(spacing: 8) {
                    Circle().fill(label == 0 ? Color.clear : Color(lutEntry: entry))
                        .overlay(Circle().stroke(.separator, lineWidth: 1))
                        .frame(width: 12, height: 12)
                    Text(label == 0 ? "Background" : entry.name)
                        .lineLimit(1)
                    Spacer()
                    Text("\(label)").monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            }
        }
    }
}

private struct AtlasLabelRow: View {
    @ObservedObject var store: LayerStore
    @ObservedObject var layer: OverlayLayer
    let label: Int32

    private var entry: LUTEntry {
        store.lookupTable(id: layer.lutID)?[label] ?? ColorLookupTable.fallbackEntry(for: label)
    }
    private var isVisible: Bool { !layer.hiddenLabelIDs.contains(label) }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.setLabel(label, visible: !isVisible, in: layer.id)
            } label: {
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(isVisible ? .primary : .tertiary)
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isVisible ? "Hide \(entry.name)" : "Show \(entry.name)")

            RoundedRectangle(cornerRadius: 3)
                .fill(Color(lutEntry: entry))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text("ID \(label) · \((layer.volume.labelCounts[label] ?? 0).formatted()) voxels")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(isVisible ? 1 : 0.55)
        .contextMenu {
            Button(isVisible ? "Hide Label" : "Show Label") {
                store.setLabel(label, visible: !isVisible, in: layer.id)
            }
            Button("Show Only This Label") { store.isolateLabel(label, in: layer.id) }
        }
    }
}

private struct LUTManagerView: View {
    @ObservedObject var store: LayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Color LUTs").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            List(store.lookupTables) { table in
                HStack {
                    Image(systemName: table.isBundled ? "shippingbox.fill" : "doc.text")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(table.name)
                        Text("\(table.entries.count.formatted()) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if table.isBundled {
                        Text("Built-in").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(role: .destructive) {
                            do { try store.removePersistedLookupTable(id: table.id) }
                            catch { errorMessage = error.localizedDescription }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove Custom LUT")
                    }
                }
            }
        }
        .frame(width: 440, height: 320)
        .alert("Couldn’t Remove LUT", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private extension Color {
    init(rgb: SIMD3<Double>) {
        self.init(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    init(lutEntry: LUTEntry) {
        self.init(
            red: Double(lutEntry.red) / 255,
            green: Double(lutEntry.green) / 255,
            blue: Double(lutEntry.blue) / 255,
            opacity: lutEntry.opacity
        )
    }
}
