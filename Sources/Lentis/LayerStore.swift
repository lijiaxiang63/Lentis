// LayerStore.swift
// Lentis
//
// Observable session state for mask/atlas layers. Mutations flow through this
// store so each visible change advances a render revision and re-drives the
// existing asynchronous/coalesced MPR renderer.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Combine
import simd

struct LayerRGBA: Sendable, Equatable {
    let red: Float
    let green: Float
    let blue: Float
    let alpha: Float
}

struct LayerRenderDescriptor: Sendable {
    let layerID: UUID
    let volume: OverlayLayerVolume
    let kind: OverlayLayerKind
    let maskColor: LayerRGBA
    let atlasColors: [Int32: LayerRGBA]
}

struct LayerRenderSnapshot: Sendable {
    let revision: UInt64
    let layers: [LayerRenderDescriptor]
}

final class LayerStore: ObservableObject {
    @Published private(set) var layers: [OverlayLayer] = []
    @Published var selectedLayerID: UUID?
    @Published private(set) var lookupTables: [ColorLookupTable]
    @Published private(set) var revision: UInt64 = 0
    private let lutRepository: CustomLUTRepository

    /// Installed by ViewerModel. This deliberately isn't @Published on the
    /// model, avoiding a full viewer relayout during opacity slider drags.
    var onRenderChange: (() -> Void)?

    init(lutRepository: CustomLUTRepository = .shared) {
        self.lutRepository = lutRepository
        let customTables = lutRepository.loadAll()
        if let bundled = try? ColorLookupTable.bundled() {
            lookupTables = [bundled] + customTables
        } else {
            lookupTables = [ColorLookupTable(
                id: ColorLookupTable.bundledID,
                name: "FreeSurfer",
                entries: [:],
                isBundled: true
            )] + customTables
        }
    }

    var selectedLayer: OverlayLayer? {
        guard let selectedLayerID else { return nil }
        return layers.first { $0.id == selectedLayerID }
    }

    func lookupTable(id: String) -> ColorLookupTable? {
        lookupTables.first { $0.id == id }
    }

    func add(_ layer: OverlayLayer) {
        // Conventional layer stack: the first row is topmost/newest.
        layers.insert(layer, at: 0)
        selectedLayerID = layer.id
        changed()
    }

    @discardableResult
    func remove(id: UUID) -> (layer: OverlayLayer, index: Int)? {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = layers.remove(at: index)
        if selectedLayerID == id {
            selectedLayerID = layers.indices.contains(index) ? layers[index].id : layers.last?.id
        }
        changed()
        return (removed, index)
    }

    func restore(_ layer: OverlayLayer, at index: Int) {
        layers.insert(layer, at: min(max(0, index), layers.count))
        selectedLayerID = layer.id
        changed()
    }

    func removeAll() {
        guard !layers.isEmpty else { return }
        layers.removeAll()
        selectedLayerID = nil
        changed()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        layers.move(fromOffsets: fromOffsets, toOffset: toOffset)
        changed()
    }

    func move(layerID: UUID, to destinationIndex: Int) {
        guard let source = layers.firstIndex(where: { $0.id == layerID }) else { return }
        let layer = layers.remove(at: source)
        let adjusted = source < destinationIndex ? destinationIndex - 1 : destinationIndex
        layers.insert(layer, at: min(max(0, adjusted), layers.count))
        changed()
    }

    func setVisible(_ visible: Bool, for id: UUID) {
        guard let layer = layer(id) else { return }
        layer.isVisible = visible
        changed()
    }

    func setOpacity(_ opacity: Double, for id: UUID) {
        guard let layer = layer(id) else { return }
        layer.opacity = min(1, max(0, opacity))
        changed()
    }

    func setMaskColor(_ color: SIMD3<Double>, for id: UUID) {
        guard let layer = layer(id) else { return }
        layer.maskColor = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1))
        changed()
    }

    @discardableResult
    func setKind(_ kind: OverlayLayerKind, for id: UUID) -> Bool {
        guard let layer = layer(id), layer.changeKind(to: kind) else { return false }
        changed()
        return true
    }

    func setLookupTable(_ lutID: String, for id: UUID) {
        guard lookupTable(id: lutID) != nil, let layer = layer(id) else { return }
        layer.lutID = lutID
        changed()
    }

    func setLabel(_ label: Int32, visible: Bool, in id: UUID) {
        guard label != 0, let layer = layer(id), layer.kind == .atlas else { return }
        if visible { layer.hiddenLabelIDs.remove(label) }
        else { layer.hiddenLabelIDs.insert(label) }
        changed()
    }

    func showAllLabels(in id: UUID) {
        guard let layer = layer(id), layer.kind == .atlas else { return }
        layer.hiddenLabelIDs.removeAll()
        changed()
    }

    func hideAllLabels(in id: UUID) {
        guard let layer = layer(id), layer.kind == .atlas else { return }
        layer.hiddenLabelIDs = Set(layer.volume.labelsPresent)
        changed()
    }

    func invertLabelVisibility(in id: UUID) {
        guard let layer = layer(id), layer.kind == .atlas else { return }
        let all = Set(layer.volume.labelsPresent)
        layer.hiddenLabelIDs = all.subtracting(layer.hiddenLabelIDs)
        changed()
    }

    func isolateLabel(_ label: Int32, in id: UUID) {
        guard let layer = layer(id), layer.kind == .atlas else { return }
        layer.hiddenLabelIDs = Set(layer.volume.labelsPresent.filter { $0 != label })
        changed()
    }

    func installLookupTable(_ table: ColorLookupTable) {
        if let index = lookupTables.firstIndex(where: { $0.id == table.id }) {
            lookupTables[index] = table
        } else {
            lookupTables.append(table)
        }
    }

    @discardableResult
    func importLookupTable(from url: URL) throws -> ColorLookupTable {
        let table = try lutRepository.importFile(at: url)
        installLookupTable(table)
        return table
    }

    func removePersistedLookupTable(id: String) throws {
        try lutRepository.remove(id: id)
        removeLookupTable(id: id)
    }

    func removeLookupTable(id: String) {
        guard id != ColorLookupTable.bundledID else { return }
        lookupTables.removeAll { $0.id == id }
        var affected = false
        for layer in layers where layer.lutID == id {
            layer.lutID = ColorLookupTable.bundledID
            affected = true
        }
        if affected { changed() }
    }

    func renderSnapshot() -> LayerRenderSnapshot {
        // UI order is top-to-bottom; rendering is bottom-to-top.
        let descriptors = layers.reversed().compactMap { layer -> LayerRenderDescriptor? in
            guard layer.isVisible, layer.opacity > 0 else { return nil }
            let alpha = Float(min(1, max(0, layer.opacity)))
            switch layer.kind {
            case .mask:
                return LayerRenderDescriptor(
                    layerID: layer.id,
                    volume: layer.volume,
                    kind: .mask,
                    maskColor: LayerRGBA(
                        red: Float(layer.maskColor.x),
                        green: Float(layer.maskColor.y),
                        blue: Float(layer.maskColor.z),
                        alpha: alpha
                    ),
                    atlasColors: [:]
                )
            case .atlas:
                let lut = lookupTable(id: layer.lutID)
                var colors: [Int32: LayerRGBA] = [:]
                colors.reserveCapacity(layer.volume.labelCounts.count)
                for label in layer.volume.labelsPresent where !layer.hiddenLabelIDs.contains(label) {
                    let entry = lut?[label] ?? ColorLookupTable.fallbackEntry(for: label)
                    colors[label] = LayerRGBA(
                        red: Float(entry.red) / 255,
                        green: Float(entry.green) / 255,
                        blue: Float(entry.blue) / 255,
                        alpha: alpha * Float(entry.opacity)
                    )
                }
                return LayerRenderDescriptor(
                    layerID: layer.id,
                    volume: layer.volume,
                    kind: .atlas,
                    maskColor: LayerRGBA(red: 0, green: 0, blue: 0, alpha: 0),
                    atlasColors: colors
                )
            }
        }
        return LayerRenderSnapshot(revision: revision, layers: descriptors)
    }

    private func layer(_ id: UUID) -> OverlayLayer? { layers.first { $0.id == id } }

    private func changed() {
        revision &+= 1
        onRenderChange?()
    }
}
