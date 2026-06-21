// OverlayLayer.swift
// Lentis
//
// Session-scoped mask and atlas label layers. Layer voxel data is immutable;
// presentation state is observable and captured into immutable render snapshots.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Combine
import simd

enum OverlayLayerKind: String, CaseIterable, Identifiable, Sendable {
    case mask = "Mask"
    case atlas = "Atlas"
    var id: String { rawValue }
}

enum LayerVoxelStorage: Sendable {
    case uint8([UInt8])
    case uint16([UInt16])
    case int32([Int32])

    var count: Int {
        switch self {
        case .uint8(let values): values.count
        case .uint16(let values): values.count
        case .int32(let values): values.count
        }
    }

    var memoryBytes: Int {
        switch self {
        case .uint8(let values): values.count
        case .uint16(let values): values.count * MemoryLayout<UInt16>.stride
        case .int32(let values): values.count * MemoryLayout<Int32>.stride
        }
    }

    @inline(__always)
    func label(at index: Int) -> Int32 {
        switch self {
        case .uint8(let values): return Int32(values[index])
        case .uint16(let values): return Int32(values[index])
        case .int32(let values): return values[index]
        }
    }
}

final class OverlayLayerVolume: @unchecked Sendable {
    let width: Int
    let height: Int
    let depth: Int
    let voxelToWorldMatrix: simd_double4x4
    let storage: LayerVoxelStorage
    let labelCounts: [Int32: Int]
    let sourceWasInteger: Bool
    let sourceSingleLabel: Int32?

    private let sliceStride: Int

    init(
        width: Int,
        height: Int,
        depth: Int,
        voxelToWorldMatrix: simd_double4x4,
        storage: LayerVoxelStorage,
        labelCounts: [Int32: Int],
        sourceWasInteger: Bool = true,
        sourceSingleLabel: Int32? = nil
    ) {
        precondition(width > 0 && height > 0 && depth > 0)
        precondition(storage.count == width * height * depth)
        self.width = width
        self.height = height
        self.depth = depth
        self.voxelToWorldMatrix = voxelToWorldMatrix
        self.storage = storage
        self.labelCounts = labelCounts
        self.sourceWasInteger = sourceWasInteger
        self.sourceSingleLabel = sourceSingleLabel
        self.sliceStride = width * height
    }

    @inline(__always)
    func labelAt(x: Int, y: Int, z: Int) -> Int32 {
        guard x >= 0, x < width, y >= 0, y < height, z >= 0, z < depth else { return 0 }
        return storage.label(at: z * sliceStride + y * width + x)
    }

    var labelsPresent: [Int32] { labelCounts.keys.filter { $0 != 0 }.sorted() }
    var memoryBytes: Int { storage.memoryBytes }

    func asBinaryMask() -> OverlayLayerVolume {
        var mask = [UInt8](repeating: 0, count: storage.count)
        var nonzero = 0
        for i in mask.indices where storage.label(at: i) != 0 {
            mask[i] = 1
            nonzero += 1
        }
        return OverlayLayerVolume(
            width: width, height: height, depth: depth,
            voxelToWorldMatrix: voxelToWorldMatrix,
            storage: .uint8(mask),
            labelCounts: nonzero == 0 ? [:] : [1: nonzero],
            sourceWasInteger: sourceWasInteger,
            sourceSingleLabel: sourceSingleLabel
        )
    }

    func promotedToAtlas() -> OverlayLayerVolume? {
        guard sourceWasInteger, let label = sourceSingleLabel, label != 0 else { return nil }
        let values = (0..<storage.count).map { storage.label(at: $0) == 0 ? Int32(0) : label }
        return OverlayLayerVolume.makeAtlas(
            width: width, height: height, depth: depth,
            voxelToWorldMatrix: voxelToWorldMatrix,
            values: values,
            sourceSingleLabel: label
        )
    }

    static func makeAtlas(
        width: Int,
        height: Int,
        depth: Int,
        voxelToWorldMatrix: simd_double4x4,
        values: [Int32],
        sourceSingleLabel: Int32? = nil
    ) -> OverlayLayerVolume {
        var counts: [Int32: Int] = [:]
        var minLabel = Int32.max
        var maxLabel = Int32.min
        for value in values where value != 0 {
            counts[value, default: 0] += 1
            minLabel = min(minLabel, value)
            maxLabel = max(maxLabel, value)
        }
        let storage: LayerVoxelStorage
        if minLabel >= 0 && maxLabel <= 255 {
            storage = .uint8(values.map { UInt8($0) })
        } else if minLabel >= 0 && maxLabel <= 65_535 {
            storage = .uint16(values.map { UInt16($0) })
        } else {
            storage = .int32(values)
        }
        return OverlayLayerVolume(
            width: width, height: height, depth: depth,
            voxelToWorldMatrix: voxelToWorldMatrix,
            storage: storage,
            labelCounts: counts,
            sourceWasInteger: true,
            sourceSingleLabel: sourceSingleLabel
        )
    }
}

final class OverlayLayer: ObservableObject, Identifiable {
    let id: UUID
    let sourceURL: URL
    @Published var name: String
    @Published var kind: OverlayLayerKind
    @Published var isVisible: Bool
    @Published var opacity: Double
    @Published var maskColor: SIMD3<Double>
    @Published var lutID: String
    @Published var hiddenLabelIDs: Set<Int32>
    @Published private(set) var volume: OverlayLayerVolume

    private var atlasBackup: OverlayLayerVolume?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        name: String,
        kind: OverlayLayerKind,
        volume: OverlayLayerVolume,
        isVisible: Bool = true,
        opacity: Double = 0.45,
        maskColor: SIMD3<Double> = SIMD3(1.0, 0.23, 0.19),
        lutID: String = ColorLookupTable.bundledID,
        hiddenLabelIDs: Set<Int32> = []
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.name = name
        self.kind = kind
        self.volume = volume
        self.isVisible = isVisible
        self.opacity = opacity
        self.maskColor = maskColor
        self.lutID = lutID
        self.hiddenLabelIDs = hiddenLabelIDs
    }

    var canUseAtlas: Bool {
        kind == .atlas || atlasBackup != nil || (volume.sourceWasInteger && volume.sourceSingleLabel != nil)
    }

    @discardableResult
    func changeKind(to newKind: OverlayLayerKind) -> Bool {
        guard newKind != kind else { return true }
        switch newKind {
        case .mask:
            atlasBackup = volume
            volume = volume.asBinaryMask()
            hiddenLabelIDs.removeAll()
            kind = .mask
            return true
        case .atlas:
            guard let atlas = atlasBackup ?? volume.promotedToAtlas() else { return false }
            volume = atlas
            atlasBackup = nil
            hiddenLabelIDs.removeAll()
            kind = .atlas
            return true
        }
    }
}
