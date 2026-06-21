// OverlayLayerTests.swift
// LentisTests

import Testing
import Foundation
import simd
@testable import Lentis

private func makeBaseVolume(
    width: Int,
    height: Int,
    depth: Int,
    affine: simd_double4x4 = matrix_identity_double4x4
) -> VolumeData {
    let voxels = UnsafeMutableBufferPointer<Int16>.allocate(capacity: width * height * depth)
    voxels.initialize(repeating: 0)
    return VolumeData(
        voxels: voxels,
        width: width, height: height, depth: depth,
        voxelToWorld: affine,
        rescaleSlope: 1, rescaleIntercept: 0,
        seriesUID: "layer-test"
    )
}

@Test func bundledFreeSurferLUTParsesKnownEntry() throws {
    let lut = try ColorLookupTable.bundled()
    #expect(lut.entries.count == 1_804)
    #expect(lut[17]?.name == "Left-Hippocampus")
    #expect(lut[17]?.red == 220)
    #expect(lut[17]?.green == 216)
    #expect(lut[17]?.blue == 20)
    #expect(lut[17]?.opacity == 1)
}

@Test func freeSurferLUTParserHandlesCommentsNamesAndTransparency() throws {
    let text = """
    # comment
    1 Label With Spaces 10 20 30 64 # trailing comment
    2 Other 255 0 128 255
    """
    let lut = try ColorLookupTable.parse(data: Data(text.utf8), name: "Custom")
    #expect(lut[1]?.name == "Label With Spaces")
    #expect(abs((lut[1]?.opacity ?? 0) - (191.0 / 255.0)) < 1e-12)
    #expect(lut[2]?.opacity == 0)
}

@Test func freeSurferLUTParserRejectsDuplicateAndInvalidChannel() {
    #expect(throws: ColorLookupTableError.duplicateLabel(line: 2, label: 1)) {
        try ColorLookupTable.parse(data: Data("1 A 0 0 0 0\n1 B 1 2 3 4\n".utf8), name: "Bad")
    }
    #expect(throws: ColorLookupTableError.invalidChannel(line: 1, value: "999")) {
        try ColorLookupTable.parse(data: Data("1 A 0 999 0 0\n".utf8), name: "Bad")
    }
}

@Test func customLUTRepositoryPersistsDeduplicatesAndRemoves() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("lentis-lut-test-\(UUID().uuidString)", isDirectory: true)
    let root = parent.appendingPathComponent("LUTs", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let source = parent.appendingPathComponent("My Atlas LUT.txt")
    try Data("1 Region One 10 20 30 0\n".utf8).write(to: source)

    let repository = CustomLUTRepository(directoryURL: root)
    let first = try repository.importFile(at: source)
    let duplicate = try repository.importFile(at: source)
    #expect(first.id == duplicate.id)
    #expect(repository.loadAll().count == 1)
    #expect(repository.loadAll().first?.name == "My Atlas LUT")

    let store = LayerStore(lutRepository: repository)
    #expect(store.lookupTable(id: first.id) != nil)
    try store.removePersistedLookupTable(id: first.id)
    #expect(repository.loadAll().isEmpty)
    #expect(store.lookupTable(id: first.id) == nil)
}

@Test func singleNonzeroValueAutoDetectsMask() throws {
    let spec = NiftiSpec(nx: 3, ny: 2, nz: 1, datatype: 4, bitpix: 16)
    let image = try NiftiImage.read(data: buildNifti(spec, voxels: [0, 255, 0, 255, 0, 0]))
    let layer = try OverlayLayerLoader.load(
        image: image,
        sourceURL: URL(fileURLWithPath: "/tmp/binary.nii"),
        matching: makeBaseVolume(width: 3, height: 2, depth: 1)
    )
    #expect(layer.kind == .mask)
    #expect(layer.volume.storage.memoryBytes == 6)
    #expect(layer.volume.labelCounts[1] == 2)
    #expect(layer.canUseAtlas)
    #expect(layer.changeKind(to: .atlas))
    #expect(layer.volume.labelAt(x: 1, y: 0, z: 0) == 255)
}

@Test func multipleIntegerValuesAutoDetectAtlasAndChooseUInt16() throws {
    let spec = NiftiSpec(nx: 3, ny: 2, nz: 1, datatype: 512, bitpix: 16)
    let image = try NiftiImage.read(data: buildNifti(spec, voxels: [0, 17, 0, 255, 1_001, 0]))
    let layer = try OverlayLayerLoader.load(
        image: image,
        sourceURL: URL(fileURLWithPath: "/tmp/atlas.nii"),
        matching: makeBaseVolume(width: 3, height: 2, depth: 1)
    )
    #expect(layer.kind == .atlas)
    if case .uint16 = layer.volume.storage {} else { Issue.record("Expected UInt16 atlas storage") }
    #expect(layer.volume.labelAt(x: 1, y: 0, z: 0) == 17)
    #expect(layer.volume.labelAt(x: 1, y: 1, z: 0) == 1_001)
    #expect(layer.volume.labelCounts[17] == 1)
}

@Test func largeOrNegativeAtlasLabelsUseInt32() {
    let volume = OverlayLayerVolume.makeAtlas(
        width: 3, height: 1, depth: 1,
        voxelToWorldMatrix: matrix_identity_double4x4,
        values: [0, -2, 70_000]
    )
    if case .int32 = volume.storage {} else { Issue.record("Expected Int32 atlas storage") }
    #expect(volume.labelAt(x: 1, y: 0, z: 0) == -2)
    #expect(volume.labelAt(x: 2, y: 0, z: 0) == 70_000)
}

@Test func differingAffineUsesNearestNeighbourWorldMapping() throws {
    let spec = NiftiSpec(
        nx: 2, ny: 1, nz: 1,
        datatype: 4, bitpix: 16,
        srow: [[1, 0, 0, 1], [0, 1, 0, 0], [0, 0, 1, 0]]
    )
    let image = try NiftiImage.read(data: buildNifti(spec, voxels: [7, 8]))
    let layer = try OverlayLayerLoader.load(
        image: image,
        sourceURL: URL(fileURLWithPath: "/tmp/shifted.nii"),
        matching: makeBaseVolume(width: 3, height: 1, depth: 1)
    )
    #expect(layer.kind == .atlas)
    #expect(layer.volume.labelAt(x: 0, y: 0, z: 0) == 0)
    #expect(layer.volume.labelAt(x: 1, y: 0, z: 0) == 7)
    #expect(layer.volume.labelAt(x: 2, y: 0, z: 0) == 8)
}

@Test func nonOverlappingAndFourDimensionalLayersAreRejected() throws {
    let farSpec = NiftiSpec(
        nx: 2, ny: 2, nz: 2,
        datatype: 4, bitpix: 16,
        srow: [[1, 0, 0, 100], [0, 1, 0, 100], [0, 0, 1, 100]]
    )
    let far = try NiftiImage.read(data: buildNifti(farSpec, voxels: [Float](repeating: 1, count: 8)))
    #expect(throws: OverlayLayerLoadError.noSpatialOverlap) {
        try OverlayLayerLoader.load(
            image: far,
            sourceURL: URL(fileURLWithPath: "/tmp/far.nii"),
            matching: makeBaseVolume(width: 2, height: 2, depth: 2)
        )
    }

    let fourDSpec = NiftiSpec(nx: 2, ny: 2, nz: 2, nt: 2, datatype: 4, bitpix: 16)
    let fourD = try NiftiImage.read(data: buildNifti(fourDSpec, voxels: [Float](repeating: 1, count: 16)))
    #expect(throws: OverlayLayerLoadError.fourDimensional(timepoints: 2)) {
        try OverlayLayerLoader.load(
            image: fourD,
            sourceURL: URL(fileURLWithPath: "/tmp/4d.nii"),
            matching: makeBaseVolume(width: 2, height: 2, depth: 2)
        )
    }
}
