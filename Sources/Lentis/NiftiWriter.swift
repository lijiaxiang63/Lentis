// NiftiWriter.swift
// Lentis
//
// Phase 9 — writes a segmentation label volume out as a NIfTI-1 file (.nii or
// .nii.gz). The reader (NIfTI.swift) is decode-only; this is the complementary
// encoder, sharing the exact NIfTI-1 header offsets that `parseHeader` reads.
//
// Write-back: the mask is authored in canonical RAS, but it is written in the
// ORIGINAL input grid/affine (via the retained `reorientation` +
// `originalAffine`, a lossless permutation+flip) so the export drops 1:1 onto
// the source .nii in FreeSurfer/fsleyes. Volumes with no reorientation (already
// canonical / synthetic) are written verbatim with their canonical affine.
//
// gzip: Apple's Compression framework `COMPRESSION_ZLIB` produces a RAW DEFLATE
// stream; we wrap it in an RFC-1952 gzip container (header + deflate + CRC32 +
// ISIZE) that NIfTI.swift's `gunzip` reads back. (The documented decode bug was
// DCMTK's interposed static zlib; DCMTK is gone and this is encode-only.)
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Compression
import simd

enum NiftiMaskKind {
    case binaryMask   // all nonzero labels → 1 (single-value mask)
    case atlas        // each region keeps its distinct label value
}

enum NiftiWriteError: LocalizedError {
    case noMask
    case draftActive
    case compressionFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMask: return "No segmentation mask to export."
        case .draftActive: return "Finish or cancel the in-progress region before exporting."
        case .compressionFailed: return "Failed to gzip-compress the NIfTI output."
        case .writeFailed(let m): return "Failed to write NIfTI file: \(m)"
        }
    }
}

enum NiftiWriter {

    // MARK: - Public API

    /// Write `mask` as a NIfTI-1 file based on `volume`'s grid/affine. `gzip`
    /// produces a `.nii.gz` container; otherwise a plain `.nii`.
    static func writeMask(_ mask: LabelVolume, basedOn volume: VolumeData,
                          kind: NiftiMaskKind, to url: URL, gzip: Bool) throws {
        // --- choose output grid + affine (write-back to original when possible) ---
        let canonW = mask.width, canonH = mask.height, canonD = mask.depth
        let nx: Int, ny: Int, nz: Int
        let affine: simd_double4x4
        let toSource: ((Int, Int, Int)) -> (Int, Int, Int)

        if let reorient = volume.reorientation, let orig = volume.originalAffine {
            var srcArr = [0, 0, 0]
            srcArr[reorient.sourceAxis.0] = canonW
            srcArr[reorient.sourceAxis.1] = canonH
            srcArr[reorient.sourceAxis.2] = canonD
            let srcDims = (srcArr[0], srcArr[1], srcArr[2])
            nx = srcArr[0]; ny = srcArr[1]; nz = srcArr[2]
            affine = orig
            toSource = { reorient.sourceIndex(forCanonical: $0, srcDims: srcDims) }
        } else {
            nx = canonW; ny = canonH; nz = canonD
            affine = volume.voxelToWorldMatrix
            toSource = { $0 }
        }

        // --- fill the source-ordered label buffer ---
        // Labels are UInt8 (regions use 1…254; 255 is the reserved transient
        // preview, never exported), so stage straight into the final UInt8 buffer.
        // A wide Int32 intermediate would spike ~1.4 GB before the byte copy on a
        // documented 344×1024×1024 volume; UInt8 staging avoids that entirely.
        let count = nx * ny * nz
        var labels = [UInt8](repeating: 0, count: count)
        let sliceStride = nx * ny
        for ck in 0..<canonD {
            for cj in 0..<canonH {
                for ci in 0..<canonW {
                    let raw = mask.labelAt(x: ci, y: cj, z: ck)
                    // Never export 0 (background) or 255 (transient preview).
                    guard raw != 0, raw != 255 else { continue }
                    let value: UInt8 = (kind == .binaryMask) ? 1 : raw
                    let s = toSource((ci, cj, ck))
                    labels[s.2 * sliceStride + s.1 * nx + s.0] = value
                }
            }
        }

        // --- datatype: always DT_UINT8 (label storage is UInt8) ---
        let datatypeCode: Int16 = 2, bitpix: Int16 = 8         // DT_UINT8
        let voxelData = Data(labels)

        // --- header + payload ---
        let spacing = spacingOf(affine)
        let header = makeHeader(nx: nx, ny: ny, nz: nz, spacing: spacing,
                                affine: affine, datatype: datatypeCode, bitpix: bitpix)
        var file = Data()
        file.append(header)
        file.append(voxelData)
        let output = gzip ? try gzipContainer(file) : file

        do {
            try output.write(to: url, options: .atomic)
        } catch {
            throw NiftiWriteError.writeFailed(error.localizedDescription)
        }
    }

    /// Write a grayscale `VolumeData` (Int16) as a NIfTI-1 file — used to hand
    /// the loaded CT to an external tool (SynthSeg). Written in the in-memory
    /// canonical grid with the canonical affine + the volume's rescale, so the
    /// tool's same-grid output loads straight back as a layer.
    static func writeVolume(_ volume: VolumeData, to url: URL, gzip: Bool) throws {
        let nx = volume.width, ny = volume.height, nz = volume.depth
        let header = makeHeader(nx: nx, ny: ny, nz: nz,
                                spacing: (volume.spacingX, volume.spacingY, volume.spacingZ),
                                affine: volume.voxelToWorldMatrix, datatype: 4, bitpix: 16,
                                sclSlope: volume.rescaleSlope, sclInter: volume.rescaleIntercept)
        // arm64 macOS is little-endian, matching the NIfTI LE we declare.
        let voxelData = Data(buffer: UnsafeBufferPointer(volume.voxels))
        var file = Data()
        file.append(header)
        file.append(voxelData)
        let output = gzip ? try gzipContainer(file) : file
        do {
            try output.write(to: url, options: .atomic)
        } catch {
            throw NiftiWriteError.writeFailed(error.localizedDescription)
        }
    }

    /// Write a FreeSurfer-format LUT sidecar (`id name R G B T`, T = transparency)
    /// describing the atlas regions, for use as an accompanying color table.
    static func writeLUT(regions: [CalcificationRegion], to url: URL) throws {
        var lines = [
            "# Lentis calcification atlas color lookup table",
            "# No.  Label-Name                       R   G   B   A",
            String(format: "%-5d %-32@ %3d %3d %3d %3d", 0, "Unknown" as NSString, 0, 0, 0, 0),
        ]
        for r in regions.sorted(by: { $0.label < $1.label }) {
            let red = Int((max(0, min(1, r.color.x)) * 255).rounded())
            let green = Int((max(0, min(1, r.color.y)) * 255).rounded())
            let blue = Int((max(0, min(1, r.color.z)) * 255).rounded())
            let raw = r.anatomicalName ?? r.name
            let name = raw.replacingOccurrences(of: " ", with: "_")
            lines.append(String(format: "%-5d %-32@ %3d %3d %3d %3d",
                                Int(r.label), name as NSString, red, green, blue, 0))
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw NiftiWriteError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Header

    /// Serialize a NIfTI-1 single-file header (348 bytes + 4 pad to vox_offset
    /// 352). Offsets match `NIfTI.parseHeader` exactly.
    static func makeHeader(nx: Int, ny: Int, nz: Int, spacing: (Double, Double, Double),
                           affine: simd_double4x4, datatype: Int16, bitpix: Int16,
                           sclSlope: Double = 1, sclInter: Double = 0) -> Data {
        var h = [UInt8](repeating: 0, count: 352)
        func putI16(_ v: Int16, _ o: Int) { withUnsafeBytes(of: v.littleEndian) { for i in 0..<2 { h[o + i] = $0[i] } } }
        func putI32(_ v: Int32, _ o: Int) { withUnsafeBytes(of: v.littleEndian) { for i in 0..<4 { h[o + i] = $0[i] } } }
        func putF32(_ v: Double, _ o: Int) { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { for i in 0..<4 { h[o + i] = $0[i] } } }

        putI32(348, 0)                                   // sizeof_hdr
        // dim[8] @ 40: dim[0]=3 (rank), nx, ny, nz, then 1s.
        putI16(3, 40)
        putI16(Int16(nx), 42); putI16(Int16(ny), 44); putI16(Int16(nz), 46)
        putI16(1, 48); putI16(1, 50); putI16(1, 52); putI16(1, 54)
        putI16(datatype, 70)
        putI16(bitpix, 72)
        // pixdim[8] @ 76: pixdim[0]=qfac=1, then spacing.
        putF32(1, 76)
        putF32(spacing.0, 80); putF32(spacing.1, 84); putF32(spacing.2, 88)
        putF32(352, 108)                                 // vox_offset
        putF32(sclSlope, 112)                            // scl_slope
        putF32(sclInter, 116)                            // scl_inter
        putI16(0, 252)                                   // qform_code
        putI16(1, 254)                                   // sform_code (use srow)
        // srow_* are the ROWS of the voxel→world affine.
        let c = affine.columns
        putF32(c.0.x, 280); putF32(c.1.x, 284); putF32(c.2.x, 288); putF32(c.3.x, 292)  // srow_x
        putF32(c.0.y, 296); putF32(c.1.y, 300); putF32(c.2.y, 304); putF32(c.3.y, 308)  // srow_y
        putF32(c.0.z, 312); putF32(c.1.z, 316); putF32(c.2.z, 320); putF32(c.3.z, 324)  // srow_z
        h[344] = 0x6E; h[345] = 0x2B; h[346] = 0x31; h[347] = 0x00                       // "n+1\0"
        return Data(h)
    }

    private static func spacingOf(_ affine: simd_double4x4) -> (Double, Double, Double) {
        let c = affine.columns
        let dx = simd_length(SIMD3(c.0.x, c.0.y, c.0.z))
        let dy = simd_length(SIMD3(c.1.x, c.1.y, c.1.z))
        let dz = simd_length(SIMD3(c.2.x, c.2.y, c.2.z))
        return (dx == 0 ? 1 : dx, dy == 0 ? 1 : dy, dz == 0 ? 1 : dz)
    }

    // MARK: - gzip

    /// Wrap raw bytes in an RFC-1952 gzip container.
    static func gzipContainer(_ raw: Data) throws -> Data {
        guard let deflated = rawDeflate(raw) else { throw NiftiWriteError.compressionFailed }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])   // header (no flags)
        out.append(deflated)
        let crc = crc32(raw).littleEndian
        withUnsafeBytes(of: crc) { out.append(contentsOf: $0) }
        let isize = UInt32(truncatingIfNeeded: raw.count).littleEndian
        withUnsafeBytes(of: isize) { out.append(contentsOf: $0) }
        return out
    }

    private static func rawDeflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let cap = input.count + input.count / 100 + 4096   // safe margin for incompressible input
        var dst = [UInt8](repeating: 0, count: cap)
        let written = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, cap, srcBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(dst.prefix(written))
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(b)) & 0xFF)] }
        return crc ^ 0xFFFFFFFF
    }
}
