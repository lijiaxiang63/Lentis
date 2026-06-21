// OverlayLayerLoader.swift
// Lentis
//
// Loads a 3D NIfTI mask/atlas and maps it into the displayed volume's canonical
// RAS grid. Differing grids use affine-aware nearest-neighbour sampling so
// categorical labels are never interpolated.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import simd

enum OverlayLayerLoader {
    static func load(url: URL, matching base: VolumeData) throws -> OverlayLayer {
        let image = try NiftiImage.read(contentsOf: url)
        return try load(image: image, sourceURL: url, matching: base)
    }

    static func load(image: NiftiImage, sourceURL: URL, matching base: VolumeData) throws -> OverlayLayer {
        guard image.nt == 1 else {
            throw OverlayLayerLoadError.fourDimensional(timepoints: image.nt)
        }
        guard abs(simd_determinant(image.affine)) > 1e-12 else {
            throw OverlayLayerLoadError.singularAffine
        }
        guard worldBoundsOverlap(image: image, volume: base) else {
            throw OverlayLayerLoadError.noSpatialOverlap
        }

        let sourceValues = image.calibratedDoubleVolume(timepoint: 0)
        let classification = try classify(sourceValues)
        let sampler = SourceSampler(image: image, destination: base)
        let count = base.width * base.height * base.depth

        let layerVolume: OverlayLayerVolume
        switch classification.kind {
        case .mask:
            var mask = [UInt8](repeating: 0, count: count)
            var nonzero = 0
            sampler.forEachDestination { destination, source in
                guard let source else { return }
                let value = sourceValues[source]
                if value.isFinite && abs(value) > 1e-6 {
                    mask[destination] = 1
                    nonzero += 1
                }
            }
            layerVolume = OverlayLayerVolume(
                width: base.width, height: base.height, depth: base.depth,
                voxelToWorldMatrix: base.voxelToWorldMatrix,
                storage: .uint8(mask),
                labelCounts: nonzero == 0 ? [:] : [1: nonzero],
                sourceWasInteger: classification.allInteger,
                sourceSingleLabel: classification.singleLabel
            )
        case .atlas:
            var labels = [Int32](repeating: 0, count: count)
            sampler.forEachDestination { destination, source in
                guard let source else { return }
                let value = sourceValues[source]
                if value.isFinite { labels[destination] = Int32(value.rounded()) }
            }
            layerVolume = OverlayLayerVolume.makeAtlas(
                width: base.width, height: base.height, depth: base.depth,
                voxelToWorldMatrix: base.voxelToWorldMatrix,
                values: labels
            )
        }

        let filename = sourceURL.lastPathComponent
        let displayName: String
        if filename.lowercased().hasSuffix(".nii.gz") {
            displayName = String(filename.dropLast(7))
        } else {
            displayName = sourceURL.deletingPathExtension().lastPathComponent
        }
        return OverlayLayer(
            sourceURL: sourceURL,
            name: displayName,
            kind: classification.kind,
            volume: layerVolume
        )
    }

    private struct Classification {
        let kind: OverlayLayerKind
        let allInteger: Bool
        let singleLabel: Int32?
    }

    private static func classify(_ values: [Double]) throws -> Classification {
        var distinctNonzero = Set<Int32>()
        var allInteger = true
        for value in values where value.isFinite && abs(value) > 1e-6 {
            let rounded = value.rounded()
            guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else {
                throw OverlayLayerLoadError.labelOutOfRange(value)
            }
            if abs(value - rounded) > max(1e-5, abs(value) * 1e-6) {
                allInteger = false
                break
            }
            distinctNonzero.insert(Int32(rounded))
            if distinctNonzero.count > 1 { break }
        }
        if allInteger && distinctNonzero.count > 1 {
            return Classification(kind: .atlas, allInteger: true, singleLabel: nil)
        }
        return Classification(
            kind: .mask,
            allInteger: allInteger,
            singleLabel: allInteger ? distinctNonzero.first : nil
        )
    }

    private static func worldBoundsOverlap(image: NiftiImage, volume: VolumeData) -> Bool {
        func bounds(affine: simd_double4x4, dims: (Int, Int, Int)) -> (SIMD3<Double>, SIMD3<Double>) {
            var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
            for k in [0, dims.2 - 1] {
                for j in [0, dims.1 - 1] {
                    for i in [0, dims.0 - 1] {
                        let p = affine * SIMD4<Double>(Double(i), Double(j), Double(k), 1)
                        let xyz = SIMD3(p.x, p.y, p.z)
                        lo = simd_min(lo, xyz)
                        hi = simd_max(hi, xyz)
                    }
                }
            }
            return (lo, hi)
        }
        let source = bounds(affine: image.affine, dims: (image.nx, image.ny, image.nz))
        let destination = volume.worldBounds
        let tolerance = 1e-3
        return source.1.x + tolerance >= destination.min.x && destination.max.x + tolerance >= source.0.x
            && source.1.y + tolerance >= destination.min.y && destination.max.y + tolerance >= source.0.y
            && source.1.z + tolerance >= destination.min.z && destination.max.z + tolerance >= source.0.z
    }
}

private struct SourceSampler {
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceDepth: Int
    let destinationWidth: Int
    let destinationHeight: Int
    let destinationDepth: Int
    let destinationToWorld: simd_double4x4
    let worldToSource: simd_double4x4
    let fastReorientation: CanonicalReorientation?
    let sourceDims: (Int, Int, Int)

    init(image: NiftiImage, destination: VolumeData) {
        sourceWidth = image.nx
        sourceHeight = image.ny
        sourceDepth = image.nz
        destinationWidth = destination.width
        destinationHeight = destination.height
        destinationDepth = destination.depth
        destinationToWorld = destination.voxelToWorldMatrix
        worldToSource = image.affine.inverse
        sourceDims = (image.nx, image.ny, image.nz)

        let reorientation = closestCanonicalReorientation(affine: image.affine)
        let dims = reorientation.canonicalDims(sourceDims)
        let canonicalAffine = reorientation.canonicalAffine(source: image.affine, srcDims: sourceDims)
        fastReorientation = dims == (destination.width, destination.height, destination.depth)
            && Self.approximatelyEqual(canonicalAffine, destination.voxelToWorldMatrix)
            ? reorientation : nil
    }

    func forEachDestination(_ body: (_ destinationLinearIndex: Int, _ sourceLinearIndex: Int?) -> Void) {
        var destination = 0
        if let reorientation = fastReorientation {
            for k in 0..<destinationDepth {
                for j in 0..<destinationHeight {
                    for i in 0..<destinationWidth {
                        let source = reorientation.sourceIndex(forCanonical: (i, j, k), srcDims: sourceDims)
                        let linear = source.0 + sourceWidth * (source.1 + sourceHeight * source.2)
                        body(destination, linear)
                        destination += 1
                    }
                }
            }
            return
        }

        for k in 0..<destinationDepth {
            for j in 0..<destinationHeight {
                for i in 0..<destinationWidth {
                    let world = destinationToWorld * SIMD4<Double>(Double(i), Double(j), Double(k), 1)
                    let source = worldToSource * world
                    let x = Int(source.x.rounded()), y = Int(source.y.rounded()), z = Int(source.z.rounded())
                    if x >= 0, x < sourceWidth, y >= 0, y < sourceHeight, z >= 0, z < sourceDepth {
                        body(destination, x + sourceWidth * (y + sourceHeight * z))
                    } else {
                        body(destination, nil)
                    }
                    destination += 1
                }
            }
        }
    }

    private static func approximatelyEqual(_ lhs: simd_double4x4, _ rhs: simd_double4x4) -> Bool {
        for column in 0..<4 {
            let a = lhs[column], b = rhs[column]
            for row in 0..<4 where abs(a[row] - b[row]) > 1e-4 { return false }
        }
        return true
    }
}

enum OverlayLayerLoadError: LocalizedError, Equatable {
    case fourDimensional(timepoints: Int)
    case singularAffine
    case noSpatialOverlap
    case labelOutOfRange(Double)

    var errorDescription: String? {
        switch self {
        case .fourDimensional(let timepoints):
            return "Layer files must be 3D; this file contains \(timepoints) timepoints."
        case .singularAffine:
            return "The layer NIfTI has a singular affine and cannot be positioned."
        case .noSpatialOverlap:
            return "The layer does not overlap the currently displayed image in world space."
        case .labelOutOfRange(let value):
            return "Layer label \(value) is outside the supported Int32 range."
        }
    }
}
