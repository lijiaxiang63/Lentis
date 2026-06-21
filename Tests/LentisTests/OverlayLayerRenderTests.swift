// OverlayLayerRenderTests.swift
// LentisTests

import XCTest
import AppKit
import Combine
import simd
@testable import Lentis

final class OverlayLayerRenderTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()
    private func makeVolume(width: Int = 4, height: Int = 5, depth: Int = 6) -> VolumeData {
        let count = width * height * depth
        let voxels = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
        for i in 0..<count { voxels[i] = Int16(i) }
        return VolumeData(
            voxels: voxels,
            width: width, height: height, depth: depth,
            voxelToWorld: matrix_identity_double4x4,
            rescaleSlope: 1, rescaleIntercept: 0,
            seriesUID: "overlay-render-test"
        )
    }

    private func descriptor(width: Int, height: Int, depth: Int,
                            voxel: (Int, Int, Int), label: Int32 = 17) -> LayerRenderDescriptor {
        var values = [Int32](repeating: 0, count: width * height * depth)
        values[voxel.2 * width * height + voxel.1 * width + voxel.0] = label
        let layerVolume = OverlayLayerVolume.makeAtlas(
            width: width, height: height, depth: depth,
            voxelToWorldMatrix: matrix_identity_double4x4,
            values: values
        )
        return LayerRenderDescriptor(
            layerID: UUID(), volume: layerVolume, kind: .atlas,
            maskColor: LayerRGBA(red: 0, green: 0, blue: 0, alpha: 0),
            atlasColors: [label: LayerRGBA(red: 1, green: 0, blue: 0, alpha: 1)]
        )
    }

    private func assertAlignment(mode: PanelMode, sliceIndex: Int, voxel: (Int, Int, Int), label: Int32 = 17,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let volume = makeVolume()
        let engine = MPREngine(volume: volume)
        let layer = engine.layerSlice(
            descriptor(width: volume.width, height: volume.height, depth: volume.depth,
                       voxel: voxel, label: label),
            mode: mode,
            sliceIndex: sliceIndex
        )
        let gray: MPRSlice?
        switch mode {
        case .mprAxial: gray = engine.axialSlice(at: sliceIndex)
        case .mprSagittal: gray = engine.sagittalSlice(at: sliceIndex)
        case .mprCoronal: gray = engine.coronalSlice(at: sliceIndex)
        default: gray = nil
        }
        guard let gray, let layer else { return XCTFail("Missing slices", file: file, line: line) }
        let sentinel = Int16(voxel.0 + voxel.1 * volume.width + voxel.2 * volume.width * volume.height)
        gray.pixelData.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: Int16.self)
            for i in pixels.indices {
                XCTAssertEqual(layer.labels[i] == label, pixels[i] == sentinel, file: file, line: line)
            }
        }
    }

    func testExternalLayerAlignsWithAllNeurologicalPlanes() {
        assertAlignment(mode: .mprAxial, sliceIndex: 2, voxel: (1, 3, 2))
        assertAlignment(mode: .mprSagittal, sliceIndex: 1, voxel: (1, 3, 4))
        assertAlignment(mode: .mprCoronal, sliceIndex: 3, voxel: (2, 3, 4))
    }

    func testLayerStoreRevisionAndPerLabelVisibility() {
        let store = LayerStore()
        let volume = OverlayLayerVolume.makeAtlas(
            width: 2, height: 1, depth: 1,
            voxelToWorldMatrix: matrix_identity_double4x4,
            values: [17, 18]
        )
        let layer = OverlayLayer(
            sourceURL: URL(fileURLWithPath: "/tmp/atlas.nii"),
            name: "Atlas", kind: .atlas, volume: volume
        )
        let initial = store.revision
        store.add(layer)
        XCTAssertGreaterThan(store.revision, initial)
        XCTAssertNotNil(store.renderSnapshot().layers.first?.atlasColors[17])

        store.setLabel(17, visible: false, in: layer.id)
        XCTAssertNil(store.renderSnapshot().layers.first?.atlasColors[17])
        XCTAssertNotNil(store.renderSnapshot().layers.first?.atlasColors[18])

        store.isolateLabel(17, in: layer.id)
        XCTAssertNotNil(store.renderSnapshot().layers.first?.atlasColors[17])
        XCTAssertNil(store.renderSnapshot().layers.first?.atlasColors[18])
    }

    func testMultipleLayersCompositeBottomToTop() throws {
        var data = Data(count: MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { $0.bindMemory(to: Int16.self)[0] = 0 }
        let slice = MPRSlice(
            pixelData: data, width: 1, height: 1,
            planeOrigin: .zero, planeRowDir: SIMD3(1, 0, 0), planeColDir: SIMD3(0, 1, 0),
            pixelSpacingX: 1, pixelSpacingY: 1
        )
        let red = LayerRenderSlice(
            labels: [1], width: 1, height: 1, kind: .mask,
            maskColor: LayerRGBA(red: 1, green: 0, blue: 0, alpha: 1), atlasColors: [:]
        )
        let blue = LayerRenderSlice(
            labels: [1], width: 1, height: 1, kind: .mask,
            maskColor: LayerRGBA(red: 0, green: 0, blue: 1, alpha: 0.75), atlasColors: [:]
        )
        let image = try XCTUnwrap(MPREngine.renderSlice(slice, ww: 2, wc: 0, layers: [red, blue]))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let color = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        // TIFF conversion applies color management, so assert channel ordering
        // rather than comparing nonlinear components to the linear blend value.
        XCTAssertGreaterThan(color.blueComponent, color.redComponent + 0.2)
        XCTAssertGreaterThan(color.redComponent, color.greenComponent + 0.1)
    }

    func testLayerMutationDoesNotInvalidateWholeViewerModel() {
        let model = ViewerModel()
        let invalidated = expectation(description: "ViewerModel must remain decoupled")
        invalidated.isInverted = true
        model.objectWillChange.sink { invalidated.fulfill() }.store(in: &cancellables)

        let volume = OverlayLayerVolume(
            width: 1, height: 1, depth: 1,
            voxelToWorldMatrix: matrix_identity_double4x4,
            storage: .uint8([1]), labelCounts: [1: 1]
        )
        model.layerStore.add(OverlayLayer(
            sourceURL: URL(fileURLWithPath: "/tmp/mask.nii"),
            name: "Mask", kind: .mask, volume: volume
        ))
        wait(for: [invalidated], timeout: 0.05)
    }
}
