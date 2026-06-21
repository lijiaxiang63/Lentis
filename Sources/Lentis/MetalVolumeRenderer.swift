// MetalVolumeRenderer.swift
// Lentis
//
// GPU direct-volume renderer. A canonical-RAS Int16 volume is uploaded once to
// a 3D Metal texture, then rendered with orthographic ray marching,
// front-to-back alpha compositing, and gradient lighting. Window/level stays in
// stored Int16 units, matching the MPR path. Rendering is serialized and may be
// called from panel background queues.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Metal
import AppKit
import simd

final class MetalVolumeRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private var volumePipeline: MTLComputePipelineState?
    private var volumeTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private let renderLock = NSLock()

    private var currentVolumeUID: String?
    private var outputWidth = 0
    private var outputHeight = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            print("MetalVolumeRenderer: Metal not available")
            return nil
        }
        self.device = device
        self.commandQueue = queue

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let function = library.makeFunction(name: "volume_render_kernel") else {
                print("MetalVolumeRenderer: Failed to find volume_render_kernel")
                return nil
            }
            volumePipeline = try device.makeComputePipelineState(function: function)
        } catch {
            print("MetalVolumeRenderer: Shader compilation failed: \(error)")
            return nil
        }
    }

    // MARK: - Camera

    /// Camera-to-volume rotation used by the ray marcher. Keeping this pure makes
    /// the interaction convention testable without a Metal device.
    static func cameraToVolumeMatrix(yawDegrees: Float, pitchDegrees: Float) -> simd_float4x4 {
        let yaw = yawDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180
        let cy = cos(yaw), sy = sin(yaw)
        let cx = cos(pitch), sx = sin(pitch)

        let yawRotation = simd_float4x4(
            SIMD4<Float>(cy, 0, -sy, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sy, 0, cy, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let pitchRotation = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, cx, sx, 0),
            SIMD4<Float>(0, -sx, cx, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        return pitchRotation * yawRotation
    }

    // MARK: - Volume upload

    private func uploadVolume(_ volume: VolumeData) {
        guard currentVolumeUID != volume.seriesUID else { return }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = volume.width
        descriptor.height = volume.height
        descriptor.depth = volume.depth
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor),
              let baseAddress = volume.voxels.baseAddress else {
            print("MetalVolumeRenderer: Failed to create 3D texture")
            return
        }

        let bytesPerRow = volume.width * MemoryLayout<Int16>.stride
        let bytesPerImage = bytesPerRow * volume.height
        for z in 0..<volume.depth {
            texture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: z),
                    size: MTLSize(width: volume.width, height: volume.height, depth: 1)
                ),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress + z * volume.width * volume.height,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        volumeTexture = texture
        currentVolumeUID = volume.seriesUID
    }

    // MARK: - Rendering

    func renderVolume(
        volume: VolumeData,
        cameraToVolume: simd_float4x4,
        outputWidth: Int,
        outputHeight: Int,
        windowWidth: Float,
        windowCenter: Float,
        opacity: Float,
        invert: Bool
    ) -> NSImage? {
        renderLock.lock()
        defer { renderLock.unlock() }

        uploadVolume(volume)
        guard let volumeTexture, let pipeline = volumePipeline else { return nil }

        if self.outputWidth != outputWidth || self.outputHeight != outputHeight || outputTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: outputWidth,
                height: outputHeight,
                mipmapped: false
            )
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .managed
            outputTexture = device.makeTexture(descriptor: descriptor)
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
        }

        guard let outputTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        var uniforms = VolumeRenderUniforms(
            cameraToVolume: cameraToVolume,
            volumeDims: SIMD3<Float>(Float(volume.width), Float(volume.height), Float(volume.depth)),
            voxelSpacing: SIMD3<Float>(Float(volume.spacingX), Float(volume.spacingY), Float(volume.spacingZ)),
            outputSize: SIMD2<Float>(Float(outputWidth), Float(outputHeight)),
            windowWidth: max(windowWidth, 1),
            windowCenter: windowCenter,
            opacity: max(0.05, opacity),
            invert: invert ? 1 : 0,
            padding: 0
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volumeTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<VolumeRenderUniforms>.stride, index: 0)

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (outputWidth + 7) / 8, height: (outputHeight + 7) / 8, depth: 1),
            threadsPerThreadgroup: threadsPerGroup
        )
        encoder.endEncoding()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: outputTexture)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return textureToNSImage(outputTexture, width: outputWidth, height: outputHeight)
    }

    private func textureToNSImage(_ texture: MTLTexture, width: Int, height: Int) -> NSImage? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0
        )

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}

struct VolumeRenderUniforms {
    var cameraToVolume: simd_float4x4
    var volumeDims: SIMD3<Float>
    var voxelSpacing: SIMD3<Float>
    var outputSize: SIMD2<Float>
    var windowWidth: Float
    var windowCenter: Float
    var opacity: Float
    var invert: Int32
    var padding: Int32
}

extension MetalVolumeRenderer {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VolumeRenderUniforms {
        float4x4 cameraToVolume;
        float3 volumeDims;
        float3 voxelSpacing;
        float2 outputSize;
        float windowWidth;
        float windowCenter;
        float opacity;
        int invert;
        int padding;
    };

    bool intersectBox(float3 rayOrigin, float3 rayDirection,
                      float3 boxMin, float3 boxMax,
                      thread float &nearT, thread float &farT) {
        float3 safeDirection = select(rayDirection, float3(1e-6), abs(rayDirection) < 1e-6);
        float3 inverseDirection = 1.0 / safeDirection;
        float3 t0 = (boxMin - rayOrigin) * inverseDirection;
        float3 t1 = (boxMax - rayOrigin) * inverseDirection;
        float3 tMin = min(t0, t1);
        float3 tMax = max(t0, t1);
        nearT = max(max(tMin.x, tMin.y), tMin.z);
        farT = min(min(tMax.x, tMax.y), tMax.z);
        return nearT <= farT && farT > 0.0;
    }

    float voxelValue(texture3d<short, access::read> volume, int3 coordinate, int3 maxCoordinate) {
        int3 clamped = clamp(coordinate, int3(0), maxCoordinate);
        return float(volume.read(uint3(clamped)).r);
    }

    kernel void volume_render_kernel(
        texture3d<short, access::read> volume [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant VolumeRenderUniforms &uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= uint(uniforms.outputSize.x) || gid.y >= uint(uniforms.outputSize.y)) return;

        float2 ndc = (float2(gid) + 0.5) / uniforms.outputSize * 2.0 - 1.0;
        float3 dims = uniforms.volumeDims;
        float3 spacing = max(uniforms.voxelSpacing, float3(1e-4));
        float3 halfSize = max((dims - 1.0) * spacing * 0.5, spacing * 0.5);
        float radius = length(halfSize) * 1.08;

        // Pixel row zero is screen-top. At zero camera rotation this looks down
        // canonical +S toward -S with L on the left and A at the top.
        float3 cameraOrigin = float3(ndc.x * radius, -ndc.y * radius, radius * 2.25);
        float3 cameraDirection = float3(0.0, 0.0, -1.0);
        float3 rayOrigin = (uniforms.cameraToVolume * float4(cameraOrigin, 1.0)).xyz;
        float3 rayDirection = normalize((uniforms.cameraToVolume * float4(cameraDirection, 0.0)).xyz);

        float nearT, farT;
        if (!intersectBox(rayOrigin, rayDirection, -halfSize, halfSize, nearT, farT)) {
            output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
            return;
        }
        nearT = max(nearT, 0.0);

        float minSpacing = min(spacing.x, min(spacing.y, spacing.z));
        float stepSize = max(minSpacing * 0.85, 1e-4);
        int stepCount = min(int(ceil((farT - nearT) / stepSize)), 2048);
        float windowWidth = max(uniforms.windowWidth, 1.0);
        float windowBottom = uniforms.windowCenter - windowWidth * 0.5;
        int3 maxCoordinate = max(int3(dims) - 1, int3(0));

        float3 accumulatedColor = float3(0.0);
        float accumulatedAlpha = 0.0;

        for (int step = 0; step < stepCount && accumulatedAlpha < 0.985; ++step) {
            float t = nearT + (float(step) + 0.5) * stepSize;
            float3 physicalPosition = rayOrigin + rayDirection * t;
            float3 voxelPosition = (physicalPosition + halfSize) / spacing;
            if (any(voxelPosition < 0.0) || any(voxelPosition > dims - 1.0)) continue;

            int3 coordinate = int3(round(voxelPosition));
            float rawValue = voxelValue(volume, coordinate, maxCoordinate);
            float windowed = (rawValue - windowBottom) / windowWidth;

            // Window-selective transfer function. Values well above the window
            // (for example CT skull while using the Brain preset) become
            // transparent, exposing the tissue selected by W/L instead of
            // collapsing back into a maximum-intensity projection.
            float lowerGate = smoothstep(-0.08, 0.18, windowed);
            float upperGate = 1.0 - smoothstep(1.15, 1.75, windowed);
            float band = lowerGate * upperGate;
            if (band < 0.002) continue;

            float luminance = clamp(windowed, 0.0, 1.0);
            float sampleAlpha = band * uniforms.opacity * (0.025 + 0.055 * luminance);
            sampleAlpha = 1.0 - pow(max(0.0, 1.0 - clamp(sampleAlpha, 0.0, 0.95)),
                                    stepSize / minSpacing);

            float gx = voxelValue(volume, coordinate + int3(1, 0, 0), maxCoordinate)
                     - voxelValue(volume, coordinate - int3(1, 0, 0), maxCoordinate);
            float gy = voxelValue(volume, coordinate + int3(0, 1, 0), maxCoordinate)
                     - voxelValue(volume, coordinate - int3(0, 1, 0), maxCoordinate);
            float gz = voxelValue(volume, coordinate + int3(0, 0, 1), maxCoordinate)
                     - voxelValue(volume, coordinate - int3(0, 0, 1), maxCoordinate);
            float3 gradient = float3(gx / spacing.x, gy / spacing.y, gz / spacing.z);
            float gradientLength = length(gradient);
            float facing = gradientLength > 1e-4
                ? abs(dot(gradient / gradientLength, -rayDirection))
                : 0.55;
            float lighting = 0.28 + 0.72 * facing + 0.12 * pow(facing, 12.0);

            float displayLuminance = uniforms.invert != 0 ? 1.0 - luminance : luminance;
            float3 sampleColor = float3(0.18 + 0.82 * displayLuminance) * lighting;
            float contribution = (1.0 - accumulatedAlpha) * sampleAlpha;
            accumulatedColor += contribution * sampleColor;
            accumulatedAlpha += contribution;
        }

        // Composite over the viewer's black background and keep output opaque.
        output.write(float4(clamp(accumulatedColor, 0.0, 1.0), 1.0), gid);
    }
    """
}
