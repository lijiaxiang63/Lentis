// MetalVolumeRendererTests.swift
// Pure camera/state tests for the 3D direct-volume rendering seam.

import XCTest
import simd
@testable import Lentis

final class MetalVolumeRendererTests: XCTestCase {
    @MainActor
    func testVolumeWindowLevelRerenderIsAsynchronous() async throws {
        let size = 8
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: size * size * size)
        for index in 0..<buffer.count { buffer[index] = Int16(index % 200) }
        let volume = VolumeData(
            voxels: buffer,
            width: size, height: size, depth: size,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: .zero,
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1,
            rescaleIntercept: 0,
            seriesUID: "volume-async-test"
        )
        let model = ViewerModel()
        let seriesIndex = model.registerStandaloneVolume(
            volume,
            cacheKey: "volume-async-test",
            description: "volume-async-test"
        )
        let panel = model.panels[0]
        panel.seriesIndex = seriesIndex
        panel.panelMode = .volume3D
        panel.windowWidth = 200
        panel.windowCenter = 100

        model.loadVolumeRendering(for: panel)
        await waitUntil { panel.image != nil }
        let baseline = try XCTUnwrap(panel.image)

        model.adjustWindowLevelForPanel(panel, deltaWidth: 50, deltaCenter: 10)
        XCTAssertTrue(panel.image === baseline)

        await waitUntil { panel.image !== baseline }
        XCTAssertFalse(panel.image === baseline)
    }

    func testMetalShaderRendersNonEmptyVolume() throws {
        let renderer = try XCTUnwrap(MetalVolumeRenderer())
        let size = 16
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: size * size * size)
        for z in 0..<size {
            for y in 0..<size {
                for x in 0..<size {
                    let dx = x - size / 2, dy = y - size / 2, dz = z - size / 2
                    buffer[z * size * size + y * size + x] =
                        (dx * dx + dy * dy + dz * dz < 25) ? 100 : -1000
                }
            }
        }
        let volume = VolumeData(
            voxels: buffer,
            width: size, height: size, depth: size,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: .zero,
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1,
            rescaleIntercept: 0,
            seriesUID: "metal-render-test"
        )

        let image = try XCTUnwrap(renderer.renderVolume(
            volume: volume,
            cameraToVolume: matrix_identity_float4x4,
            outputWidth: 64,
            outputHeight: 64,
            windowWidth: 200,
            windowCenter: 50,
            opacity: 1,
            invert: false
        ))
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        XCTAssertGreaterThan(center.redComponent, 0.05)
    }

    func testYawRotationChangesAsymmetricVolumeProjection() throws {
        let renderer = try XCTUnwrap(MetalVolumeRenderer())
        let size = 24
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: size * size * size)
        for index in 0..<buffer.count { buffer[index] = -1000 }
        for z in 4..<20 {
            for y in 8..<16 {
                for x in 10..<14 {
                    buffer[z * size * size + y * size + x] = 100
                }
            }
        }
        let volume = VolumeData(
            voxels: buffer,
            width: size, height: size, depth: size,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: .zero,
            rowDirection: SIMD3<Double>(1, 0, 0),
            colDirection: SIMD3<Double>(0, 1, 0),
            rescaleSlope: 1,
            rescaleIntercept: 0,
            seriesUID: "metal-yaw-projection-test"
        )

        let front = try XCTUnwrap(renderer.renderVolume(
            volume: volume,
            cameraToVolume: MetalVolumeRenderer.cameraToVolumeMatrix(yawDegrees: 0, pitchDegrees: 0),
            outputWidth: 64,
            outputHeight: 64,
            windowWidth: 200,
            windowCenter: 50,
            opacity: 1,
            invert: false
        ))
        let side = try XCTUnwrap(renderer.renderVolume(
            volume: volume,
            cameraToVolume: MetalVolumeRenderer.cameraToVolumeMatrix(yawDegrees: 90, pitchDegrees: 0),
            outputWidth: 64,
            outputHeight: 64,
            windowWidth: 200,
            windowCenter: 50,
            opacity: 1,
            invert: false
        ))

        let frontWidth = try brightnessExtentWidth(front)
        let sideWidth = try brightnessExtentWidth(side)
        XCTAssertGreaterThan(sideWidth, frontWidth + 12)
    }

    func testZeroCameraAnglesProduceIdentityRotation() {
        let matrix = MetalVolumeRenderer.cameraToVolumeMatrix(
            yawDegrees: 0,
            pitchDegrees: 0
        )
        XCTAssertEqual(matrix, matrix_identity_float4x4)
    }

    func testYawRotatesCameraForwardIntoVolumeSpace() {
        let matrix = MetalVolumeRenderer.cameraToVolumeMatrix(
            yawDegrees: 90,
            pitchDegrees: 0
        )
        let forward = matrix * SIMD4<Float>(0, 0, -1, 0)
        XCTAssertEqual(forward.x, -1, accuracy: 1e-5)
        XCTAssertEqual(forward.y, 0, accuracy: 1e-5)
        XCTAssertEqual(forward.z, 0, accuracy: 1e-5)
    }

    func testYawStillTurnsCameraAfterPitchingToAnteriorView() {
        let faceOn = MetalVolumeRenderer.cameraToVolumeMatrix(
            yawDegrees: 0,
            pitchDegrees: -90
        )
        let turned = MetalVolumeRenderer.cameraToVolumeMatrix(
            yawDegrees: 45,
            pitchDegrees: -90
        )

        let faceForward = faceOn * SIMD4<Float>(0, 0, -1, 0)
        let turnedForward = turned * SIMD4<Float>(0, 0, -1, 0)

        XCTAssertLessThan(faceForward.y, -0.999)
        XCTAssertLessThan(turnedForward.y, -0.65)
        XCTAssertGreaterThan(abs(turnedForward.x), 0.65)
        XCTAssertEqual(turnedForward.z, 0, accuracy: 1e-5)
    }

    func testVolumePitchCanContinuePastAnteriorView() {
        let model = ViewerModel()
        let panel = PanelState()
        panel.panelMode = .volume3D
        panel.volumePitchDegrees = -88

        model.rotateVolumeRendering(panel, deltaYaw: 0, deltaPitch: -20, interactive: true)

        XCTAssertLessThan(panel.volumePitchDegrees, -90)
    }

    func testPanelResetRestoresVolumeCameraDefaults() {
        let panel = PanelState()
        panel.volumeYawDegrees = 120
        panel.volumePitchDegrees = -60
        panel.volumeOpacity = 2.2

        panel.reset()

        XCTAssertEqual(panel.volumeYawDegrees, -25)
        XCTAssertEqual(panel.volumePitchDegrees, 18)
        XCTAssertEqual(panel.volumeOpacity, 1)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func brightnessExtentWidth(_ image: NSImage) throws -> Int {
    let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    var minX = bitmap.pixelsWide
    var maxX = -1
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            let brightness = color.redComponent + color.greenComponent + color.blueComponent
            if brightness > 0.02 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
    }
    return maxX >= minX ? maxX - minX + 1 : 0
}
