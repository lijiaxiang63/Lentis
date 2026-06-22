// NIfTI.swift
// Lentis
//
// Self-contained reader for NIfTI-1 and NIfTI-2 neuroimaging volumes
// (.nii and gzip-compressed .nii.gz). Zero external dependencies — header
// parsing, endianness handling, gzip inflation (via the Compression
// framework), affine construction (sform preferred, qform fallback), and
// 4D support are all implemented here.
//
// Design notes:
//   - Voxel linear order matches NIfTI storage: i (x) fastest, then j (y),
//     then k (z), then t. This is identical to VolumeData's [z][y][x]
//     slice-major layout, so a timepoint can be copied across without
//     transposing (orientation is handled later via the affine).
//   - `scl_slope` / `scl_inter` are applied on extraction
//     (displayed = stored * slope + inter); this is modality-independent.
//   - World coordinates follow the NIfTI convention (RAS+, millimetres).
//     The original affine is preserved verbatim for later mask write-back.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import simd

// MARK: - Errors

enum NiftiError: Error, CustomStringConvertible {
    case tooSmall
    case badMagic
    case unsupportedDatatype(Int)
    case inconsistentDimensions
    case decompressionFailed
    case dataTruncated

    var description: String {
        switch self {
        case .tooSmall: return "File is too small to be a NIfTI volume."
        case .badMagic: return "Not a NIfTI file (missing n+1/ni1/n+2 magic)."
        case .unsupportedDatatype(let c): return "Unsupported NIfTI datatype code \(c)."
        case .inconsistentDimensions: return "NIfTI header has invalid dimensions."
        case .decompressionFailed: return "Failed to gunzip the .nii.gz payload."
        case .dataTruncated: return "NIfTI pixel data is shorter than the header declares."
        }
    }
}

// MARK: - Datatype

/// Supported NIfTI datatype codes (DT_*). Complex/RGB are intentionally unsupported.
enum NiftiDatatype: Int {
    case uint8   = 2
    case int16   = 4
    case int32   = 8
    case float32 = 16
    case float64 = 64
    case int8    = 256
    case uint16  = 512
    case uint32  = 768
    case int64   = 1024
    case uint64  = 1280

    var byteCount: Int {
        switch self {
        case .uint8, .int8: return 1
        case .int16, .uint16: return 2
        case .int32, .uint32, .float32: return 4
        case .float64, .int64, .uint64: return 8
        }
    }

    var name: String {
        switch self {
        case .uint8: return "uint8";   case .int8: return "int8"
        case .int16: return "int16";   case .uint16: return "uint16"
        case .int32: return "int32";   case .uint32: return "uint32"
        case .int64: return "int64";   case .uint64: return "uint64"
        case .float32: return "float32"; case .float64: return "float64"
        }
    }
}

// MARK: - Header

struct NiftiHeader {
    var version: Int          // 1 or 2
    var littleEndian: Bool
    var dim: [Int]            // length 8; dim[0] = number of dimensions
    var datatype: NiftiDatatype
    var bitpix: Int
    var pixdim: [Double]      // length 8; pixdim[0] = qfac
    var voxOffset: Int
    var sclSlope: Double
    var sclInter: Double
    var calMin: Double
    var calMax: Double
    var qformCode: Int
    var sformCode: Int
    var quaternB: Double, quaternC: Double, quaternD: Double
    var qoffsetX: Double, qoffsetY: Double, qoffsetZ: Double
    var srowX: SIMD4<Double>, srowY: SIMD4<Double>, srowZ: SIMD4<Double>

    var nx: Int { dim[0] >= 1 ? max(1, dim[1]) : 1 }
    var ny: Int { dim[0] >= 2 ? max(1, dim[2]) : 1 }
    var nz: Int { dim[0] >= 3 ? max(1, dim[3]) : 1 }
    var nt: Int { dim[0] >= 4 ? max(1, dim[4]) : 1 }
}

// MARK: - NiftiImage

/// A parsed NIfTI volume. Holds the decompressed payload and lazily extracts
/// calibrated voxel values per timepoint.
final class NiftiImage {
    enum AffineSource: String { case sform, qform, fallback }

    let header: NiftiHeader
    /// voxel (i,j,k,1) → world (x,y,z,1) in millimetres (RAS+). Preserved verbatim.
    let affine: simd_double4x4
    let affineSource: AffineSource
    private let payload: Data

    var nx: Int { header.nx }
    var ny: Int { header.ny }
    var nz: Int { header.nz }
    var nt: Int { header.nt }
    var voxelsPerVolume: Int { nx * ny * nz }

    private init(header: NiftiHeader, affine: simd_double4x4, affineSource: AffineSource, payload: Data) {
        self.header = header
        self.affine = affine
        self.affineSource = affineSource
        self.payload = payload
    }

    // MARK: Loading

    static func read(contentsOf url: URL) throws -> NiftiImage {
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(data: raw)
    }

    static func read(data rawData: Data) throws -> NiftiImage {
        let payload = try gunzipIfNeeded(rawData)
        guard payload.count >= 348 else { throw NiftiError.tooSmall }

        let header = try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> NiftiHeader in
            try parseHeader(raw, totalBytes: payload.count)
        }

        // Validate the pixel data fits.
        let need = header.voxOffset + header.nt * header.nx * header.ny * header.nz * header.datatype.byteCount
        guard need <= payload.count else { throw NiftiError.dataTruncated }

        let (affine, source) = Self.makeAffine(header)
        return NiftiImage(header: header, affine: affine, affineSource: source, payload: payload)
    }

    // MARK: Voxel extraction

    /// Extract one timepoint as calibrated Float values (scl_slope/scl_inter applied).
    /// Linear index = i + nx*(j + ny*k), i.e. directly usable as VolumeData voxel order.
    func calibratedVolume(timepoint t: Int) -> [Float] {
        let n = voxelsPerVolume
        let tp = min(max(0, t), nt - 1)
        let elem = header.datatype.byteCount
        let base = header.voxOffset + tp * n * elem
        let fileLE = header.littleEndian
        var out = [Float](repeating: 0, count: n)

        out.withUnsafeMutableBufferPointer { dst in
            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                switch header.datatype {
                case .uint8:
                    for i in 0..<n { dst[i] = Float(raw.loadUnaligned(fromByteOffset: base + i, as: UInt8.self)) }
                case .int8:
                    for i in 0..<n { dst[i] = Float(raw.loadUnaligned(fromByteOffset: base + i, as: Int8.self)) }
                case .int16:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 2, as: Int16.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Float(v)
                    }
                case .uint16:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 2, as: UInt16.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Float(v)
                    }
                case .int32:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 4, as: Int32.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Float(v)
                    }
                case .uint32:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Float(v)
                    }
                case .int64:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 8, as: Int64.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Float(v)
                    }
                case .uint64:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 8, as: UInt64.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Float(v)
                    }
                case .float32:
                    for i in 0..<n {
                        var b = raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                        if !fileLE { b = b.byteSwapped }
                        dst[i] = Float(bitPattern: b)
                    }
                case .float64:
                    for i in 0..<n {
                        var b = raw.loadUnaligned(fromByteOffset: base + i * 8, as: UInt64.self)
                        if !fileLE { b = b.byteSwapped }
                        dst[i] = Float(Double(bitPattern: b))
                    }
                }
            }
        }

        // Apply intensity calibration (modality-independent).
        let slope = header.sclSlope == 0 ? 1.0 : header.sclSlope
        let inter = header.sclInter
        if !(slope == 1.0 && inter == 0.0) {
            let s = Float(slope), b = Float(inter)
            for i in 0..<n { out[i] = out[i] * s + b }
        }
        return out
    }

    /// Double-precision extraction for categorical label volumes. Unlike the
    /// display-oriented Float path above, this preserves every Int32 label ID
    /// exactly before optional NIfTI scaling is applied.
    func calibratedDoubleVolume(timepoint t: Int) -> [Double] {
        let n = voxelsPerVolume
        let tp = min(max(0, t), nt - 1)
        let elem = header.datatype.byteCount
        let base = header.voxOffset + tp * n * elem
        let fileLE = header.littleEndian
        var out = [Double](repeating: 0, count: n)

        out.withUnsafeMutableBufferPointer { dst in
            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                switch header.datatype {
                case .uint8:
                    for i in 0..<n { dst[i] = Double(raw.loadUnaligned(fromByteOffset: base + i, as: UInt8.self)) }
                case .int8:
                    for i in 0..<n { dst[i] = Double(raw.loadUnaligned(fromByteOffset: base + i, as: Int8.self)) }
                case .int16:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 2, as: Int16.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Double(v)
                    }
                case .uint16:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 2, as: UInt16.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Double(v)
                    }
                case .int32:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 4, as: Int32.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Double(v)
                    }
                case .uint32:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Double(v)
                    }
                case .int64:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 8, as: Int64.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Double(v)
                    }
                case .uint64:
                    for i in 0..<n {
                        var v = raw.loadUnaligned(fromByteOffset: base + i * 8, as: UInt64.self)
                        if !fileLE { v = v.byteSwapped }
                        dst[i] = Double(v)
                    }
                case .float32:
                    for i in 0..<n {
                        var b = raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                        if !fileLE { b = b.byteSwapped }
                        dst[i] = Double(Float(bitPattern: b))
                    }
                case .float64:
                    for i in 0..<n {
                        var b = raw.loadUnaligned(fromByteOffset: base + i * 8, as: UInt64.self)
                        if !fileLE { b = b.byteSwapped }
                        dst[i] = Double(bitPattern: b)
                    }
                }
            }
        }

        let slope = header.sclSlope == 0 ? 1.0 : header.sclSlope
        let inter = header.sclInter
        if !(slope == 1.0 && inter == 0.0) {
            for i in 0..<n { out[i] = out[i] * slope + inter }
        }
        return out
    }

    // MARK: - Affine

    private static func makeAffine(_ h: NiftiHeader) -> (simd_double4x4, AffineSource) {
        if h.sformCode > 0 {
            // srow_* are the rows of the affine; assemble columns explicitly.
            let col0 = SIMD4<Double>(h.srowX.x, h.srowY.x, h.srowZ.x, 0)
            let col1 = SIMD4<Double>(h.srowX.y, h.srowY.y, h.srowZ.y, 0)
            let col2 = SIMD4<Double>(h.srowX.z, h.srowY.z, h.srowZ.z, 0)
            let col3 = SIMD4<Double>(h.srowX.w, h.srowY.w, h.srowZ.w, 1)
            return (simd_double4x4(columns: (col0, col1, col2, col3)), .sform)
        }
        if h.qformCode > 0 {
            let b = h.quaternB, c = h.quaternC, d = h.quaternD
            let a2 = 1.0 - (b * b + c * c + d * d)
            let a = a2 > 0 ? sqrt(a2) : 0.0
            // Rotation matrix R (rows r0,r1,r2)
            let r00 = a * a + b * b - c * c - d * d
            let r01 = 2 * (b * c - a * d)
            let r02 = 2 * (b * d + a * c)
            let r10 = 2 * (b * c + a * d)
            let r11 = a * a + c * c - b * b - d * d
            let r12 = 2 * (c * d - a * b)
            let r20 = 2 * (b * d - a * c)
            let r21 = 2 * (c * d + a * b)
            let r22 = a * a + d * d - b * b - c * c

            var qfac = h.pixdim[0]
            qfac = (qfac < 0) ? -1.0 : 1.0
            let dx = h.pixdim[1] == 0 ? 1 : h.pixdim[1]
            let dy = h.pixdim[2] == 0 ? 1 : h.pixdim[2]
            let dz = h.pixdim[3] == 0 ? 1 : h.pixdim[3]

            let col0 = SIMD4<Double>(r00 * dx, r10 * dx, r20 * dx, 0)
            let col1 = SIMD4<Double>(r01 * dy, r11 * dy, r21 * dy, 0)
            let col2 = SIMD4<Double>(r02 * dz * qfac, r12 * dz * qfac, r22 * dz * qfac, 0)
            let col3 = SIMD4<Double>(h.qoffsetX, h.qoffsetY, h.qoffsetZ, 1)
            return (simd_double4x4(columns: (col0, col1, col2, col3)), .qform)
        }
        // Fallback: diagonal pixdim spacing, origin at 0 (analyze-style).
        let dx = h.pixdim[1] == 0 ? 1 : h.pixdim[1]
        let dy = h.pixdim[2] == 0 ? 1 : h.pixdim[2]
        let dz = h.pixdim[3] == 0 ? 1 : h.pixdim[3]
        let m = simd_double4x4(columns: (
            SIMD4<Double>(dx, 0, 0, 0),
            SIMD4<Double>(0, dy, 0, 0),
            SIMD4<Double>(0, 0, dz, 0),
            SIMD4<Double>(0, 0, 0, 1)
        ))
        return (m, .fallback)
    }

    // MARK: - Header parsing

    private static func parseHeader(_ raw: UnsafeRawBufferPointer, totalBytes: Int) throws -> NiftiHeader {
        // Detect version + endianness from sizeof_hdr.
        let sizeofHdrNative = raw.loadUnaligned(fromByteOffset: 0, as: Int32.self)
        let version: Int
        let littleEndian: Bool
        if sizeofHdrNative == 348 { version = 1; littleEndian = true }
        else if sizeofHdrNative.byteSwapped == 348 { version = 1; littleEndian = false }
        else if sizeofHdrNative == 540 { version = 2; littleEndian = true }
        else if sizeofHdrNative.byteSwapped == 540 { version = 2; littleEndian = false }
        else { throw NiftiError.badMagic }

        func i16(_ o: Int) -> Int16 { let v = raw.loadUnaligned(fromByteOffset: o, as: Int16.self); return littleEndian ? v : v.byteSwapped }
        func i32(_ o: Int) -> Int32 { let v = raw.loadUnaligned(fromByteOffset: o, as: Int32.self); return littleEndian ? v : v.byteSwapped }
        func i64(_ o: Int) -> Int64 { let v = raw.loadUnaligned(fromByteOffset: o, as: Int64.self); return littleEndian ? v : v.byteSwapped }
        func f32(_ o: Int) -> Double { let b = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self); return Double(Float(bitPattern: littleEndian ? b : b.byteSwapped)) }
        func f64(_ o: Int) -> Double { let b = raw.loadUnaligned(fromByteOffset: o, as: UInt64.self); return Double(bitPattern: littleEndian ? b : b.byteSwapped) }

        var h: NiftiHeader

        if version == 1 {
            guard totalBytes >= 348 else { throw NiftiError.tooSmall }
            // magic at 344
            let m0 = raw.loadUnaligned(fromByteOffset: 344, as: UInt8.self)
            let m1 = raw.loadUnaligned(fromByteOffset: 345, as: UInt8.self)
            let m2 = raw.loadUnaligned(fromByteOffset: 346, as: UInt8.self)
            let okMagic = (m0 == 0x6E /*n*/ && (m1 == 0x2B /*+*/ || m1 == 0x69 /*i*/) && m2 == 0x31 /*1*/)
            guard okMagic else { throw NiftiError.badMagic }

            var dim = [Int](repeating: 0, count: 8)
            for k in 0..<8 { dim[k] = Int(i16(40 + k * 2)) }
            let dtCode = Int(i16(70))
            guard let dt = NiftiDatatype(rawValue: dtCode) else { throw NiftiError.unsupportedDatatype(dtCode) }
            var pixdim = [Double](repeating: 0, count: 8)
            for k in 0..<8 { pixdim[k] = f32(76 + k * 4) }

            h = NiftiHeader(
                version: 1, littleEndian: littleEndian,
                dim: dim, datatype: dt, bitpix: Int(i16(72)),
                pixdim: pixdim, voxOffset: Int(f32(108)),
                sclSlope: f32(112), sclInter: f32(116),
                calMin: f32(128), calMax: f32(124),
                qformCode: Int(i16(252)), sformCode: Int(i16(254)),
                quaternB: f32(256), quaternC: f32(260), quaternD: f32(264),
                qoffsetX: f32(268), qoffsetY: f32(272), qoffsetZ: f32(276),
                srowX: SIMD4<Double>(f32(280), f32(284), f32(288), f32(292)),
                srowY: SIMD4<Double>(f32(296), f32(300), f32(304), f32(308)),
                srowZ: SIMD4<Double>(f32(312), f32(316), f32(320), f32(324))
            )
        } else {
            guard totalBytes >= 540 else { throw NiftiError.tooSmall }
            // magic at 4: "n+2" or "ni2"
            let m0 = raw.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            let m1 = raw.loadUnaligned(fromByteOffset: 5, as: UInt8.self)
            let m2 = raw.loadUnaligned(fromByteOffset: 6, as: UInt8.self)
            let okMagic = (m0 == 0x6E && (m1 == 0x2B || m1 == 0x69) && m2 == 0x32 /*2*/)
            guard okMagic else { throw NiftiError.badMagic }

            let dtCode = Int(i16(12))
            guard let dt = NiftiDatatype(rawValue: dtCode) else { throw NiftiError.unsupportedDatatype(dtCode) }
            var dim = [Int](repeating: 0, count: 8)
            for k in 0..<8 { dim[k] = Int(i64(16 + k * 8)) }
            var pixdim = [Double](repeating: 0, count: 8)
            for k in 0..<8 { pixdim[k] = f64(104 + k * 8) }

            h = NiftiHeader(
                version: 2, littleEndian: littleEndian,
                dim: dim, datatype: dt, bitpix: Int(i16(14)),
                pixdim: pixdim, voxOffset: Int(i64(168)),
                sclSlope: f64(176), sclInter: f64(184),
                calMin: f64(200), calMax: f64(192),
                qformCode: Int(i32(344)), sformCode: Int(i32(348)),
                quaternB: f64(352), quaternC: f64(360), quaternD: f64(368),
                qoffsetX: f64(376), qoffsetY: f64(384), qoffsetZ: f64(392),
                srowX: SIMD4<Double>(f64(400), f64(408), f64(416), f64(424)),
                srowY: SIMD4<Double>(f64(432), f64(440), f64(448), f64(456)),
                srowZ: SIMD4<Double>(f64(464), f64(472), f64(480), f64(488))
            )
        }

        guard h.dim[0] >= 1, h.dim[0] <= 7, h.nx > 0, h.ny > 0, h.nz > 0 else {
            throw NiftiError.inconsistentDimensions
        }
        // A vox_offset of 0 is only legal for the detached .hdr/.img ("ni1") form;
        // for single-file volumes default to the minimum header size.
        if h.voxOffset <= 0 { h.voxOffset = (version == 1) ? 352 : 544 }
        return h
    }
}

// MARK: - Gzip (Compression framework)

/// Inflate a gzip (.gz) payload. Returns the input unchanged if it is not gzipped.
private func gunzipIfNeeded(_ data: Data) throws -> Data {
    guard data.count > 18 else { return data }
    let isGzip = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        raw.count >= 2 && raw[0] == 0x1f && raw[1] == 0x8b
    }
    guard isGzip else { return data }
    return try gunzip(data)
}

private func gunzip(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Data in
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw NiftiError.decompressionFailed
        }
        let flg = bytes[3]
        var idx = 10
        if flg & 0x04 != 0 { // FEXTRA
            guard idx + 1 < bytes.count else { throw NiftiError.decompressionFailed }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flg & 0x08 != 0 { // FNAME
            while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flg & 0x10 != 0 { // FCOMMENT
            while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flg & 0x02 != 0 { idx += 2 } // FHCRC
        guard idx < bytes.count - 8 else { throw NiftiError.decompressionFailed }

        // ISIZE (uncompressed size mod 2^32) — used to pre-size the output buffer.
        let n = bytes.count
        let isize = Int(bytes[n - 4]) | (Int(bytes[n - 3]) << 8) | (Int(bytes[n - 2]) << 16) | (Int(bytes[n - 1]) << 24)
        let deflateRange = idx ..< (n - 8)

        guard let out = DeflateInflater.inflate(
            bytes,
            range: deflateRange,
            expectedSize: isize > 0 ? isize : deflateRange.count * 4
        ) else {
            throw NiftiError.decompressionFailed
        }
        return out
    }
}

/// Pure-Swift DEFLATE (RFC 1951) decompressor. Self-contained so .nii.gz works
/// without linking to platform compression or external native libraries.
private enum DeflateInflater {
    // RFC 1951 §3.2.5 length/distance base values and extra-bit counts.
    static let lenBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
    static let lenExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
    static let distBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
    static let distExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
    static let clOrder = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]

    /// Canonical Huffman table built from per-symbol code lengths.
    final class Huffman {
        /// Packed `(symbol << 4) | bitLength`, indexed by the next `maxBits`
        /// LSB-first bits in the DEFLATE stream. Short codes fill every table
        /// entry sharing that prefix, so decoding is one lookup instead of a
        /// branchy bit-at-a-time walk through up to 15 code lengths.
        let lookup: UnsafeMutablePointer<UInt16>
        let lookupCount: Int
        let maxBits: Int

        init(_ lengths: [Int]) {
            var count = [Int](repeating: 0, count: 16)
            for len in lengths where len > 0 { count[len] += 1 }

            maxBits = lengths.max() ?? 0
            lookupCount = max(1, 1 << maxBits)
            lookup = .allocate(capacity: lookupCount)
            lookup.initialize(repeating: 0, count: lookupCount)
            guard maxBits > 0 else {
                return
            }

            var nextCode = [Int](repeating: 0, count: 16)
            var code = 0
            for bits in 1...maxBits {
                code = (code + count[bits - 1]) << 1
                nextCode[bits] = code
            }

            for (s, len) in lengths.enumerated() where len > 0 {
                let canonicalCode = nextCode[len]
                nextCode[len] += 1

                var value = canonicalCode
                var reversed = 0
                for _ in 0..<len {
                    reversed = (reversed << 1) | (value & 1)
                    value >>= 1
                }

                let packed = UInt16((s << 4) | len)
                let step = 1 << len
                for index in stride(from: reversed, to: lookupCount, by: step) {
                    lookup[index] = packed
                }
            }
        }

        deinit {
            lookup.deallocate()
        }
    }

    /// LSB-first bit reader over the deflate stream.
    struct BitReader {
        let bytes: UnsafePointer<UInt8>
        let end: Int
        var pos: Int
        private var bitBuf = 0
        private var bitCnt = 0
        init(_ bytes: UnsafeRawBufferPointer, range: Range<Int>) {
            self.bytes = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            pos = range.lowerBound
            end = range.upperBound
        }

        @inline(__always)
        mutating func bits(_ need: Int) -> Int? {
            if need == 0 { return 0 }
            while bitCnt < need {
                guard pos < end else { return nil }
                bitBuf |= Int(bytes[pos]) << bitCnt
                pos += 1
                bitCnt += 8
            }
            let val = bitBuf & ((1 << need) - 1)
            bitBuf >>= need
            bitCnt -= need
            return val
        }

        /// Returns the currently available prefix, zero-padded above the end
        /// of the stream. The caller must verify that the decoded code length
        /// does not exceed `available`; this lets a short final Huffman code be
        /// decoded even when fewer than `need` padding bits remain.
        @inline(__always)
        mutating func paddedPrefix(_ need: Int) -> (value: Int, available: Int) {
            while bitCnt < need, pos < end {
                bitBuf |= Int(bytes[pos]) << bitCnt
                pos += 1
                bitCnt += 8
            }
            return (bitBuf & ((1 << need) - 1), bitCnt)
        }

        @inline(__always)
        mutating func dropBits(_ count: Int) {
            bitBuf >>= count
            bitCnt -= count
        }

        /// Discard the partial byte, leaving `pos` at the next byte boundary.
        /// Whole bytes prefetched into `bitBuf` must become input again.
        mutating func alignToByte() {
            pos -= bitCnt / 8
            bitBuf = 0
            bitCnt = 0
        }
    }

    @inline(__always)
    static func decodeSymbol(_ r: inout BitReader, _ h: Huffman) -> Int? {
        guard h.maxBits > 0 else { return nil }
        let prefix = r.paddedPrefix(h.maxBits)
        let packed = h.lookup[prefix.value]
        let length = Int(packed & 0x0f)
        guard length > 0, length <= prefix.available else { return nil }
        r.dropBits(length)
        return Int(packed >> 4)
    }

    static func inflate(
        _ src: UnsafeRawBufferPointer,
        range: Range<Int>,
        expectedSize: Int
    ) -> Data? {
        var r = BitReader(src, range: range)
        let outputCapacity = max(expectedSize, 1 << 12)
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        var outputOwned = true
        defer {
            if outputOwned { out.deallocate() }
        }
        var outputCount = 0

        // Fixed Huffman tables (RFC 1951 §3.2.6).
        var fixedLitLens = [Int](repeating: 8, count: 288)
        for i in 144..<256 { fixedLitLens[i] = 9 }
        for i in 256..<280 { fixedLitLens[i] = 7 }
        let fixedLit = Huffman(fixedLitLens)
        let fixedDist = Huffman([Int](repeating: 5, count: 30))

        while true {
            guard let bfinal = r.bits(1), let btype = r.bits(2) else { return nil }

            switch btype {
            case 0: // stored / uncompressed
                r.alignToByte()
                guard r.pos + 4 <= r.end else { return nil }
                let len = Int(src[r.pos]) | (Int(src[r.pos + 1]) << 8)
                r.pos += 4 // skip LEN(2) + NLEN(2)
                guard r.pos + len <= r.end else { return nil }
                guard outputCount + len <= outputCapacity else { return nil }
                let source = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                out.advanced(by: outputCount).update(from: source.advanced(by: r.pos), count: len)
                outputCount += len
                r.pos += len

            case 1, 2:
                let litTable: Huffman
                let distTable: Huffman
                if btype == 1 {
                    litTable = fixedLit
                    distTable = fixedDist
                } else {
                    guard let hlit = r.bits(5), let hdist = r.bits(5), let hclen = r.bits(4) else { return nil }
                    let numLit = hlit + 257, numDist = hdist + 1, numCL = hclen + 4
                    var clLens = [Int](repeating: 0, count: 19)
                    for i in 0..<numCL {
                        guard let v = r.bits(3) else { return nil }
                        clLens[clOrder[i]] = v
                    }
                    let clTable = Huffman(clLens)
                    var lens = [Int]()
                    lens.reserveCapacity(numLit + numDist)
                    while lens.count < numLit + numDist {
                        guard let sym = decodeSymbol(&r, clTable) else { return nil }
                        if sym < 16 {
                            lens.append(sym)
                        } else if sym == 16 {
                            guard let rep = r.bits(2), let last = lens.last else { return nil }
                            for _ in 0..<(rep + 3) { lens.append(last) }
                        } else if sym == 17 {
                            guard let rep = r.bits(3) else { return nil }
                            for _ in 0..<(rep + 3) { lens.append(0) }
                        } else { // 18
                            guard let rep = r.bits(7) else { return nil }
                            for _ in 0..<(rep + 11) { lens.append(0) }
                        }
                    }
                    guard lens.count == numLit + numDist else { return nil }
                    litTable = Huffman(Array(lens[0..<numLit]))
                    distTable = Huffman(Array(lens[numLit..<(numLit + numDist)]))
                }

                // Decode literal/length + distance symbols.
                while true {
                    guard let sym = decodeSymbol(&r, litTable) else { return nil }
                    if sym == 256 { break }
                    if sym < 256 {
                        guard outputCount < outputCapacity else { return nil }
                        out[outputCount] = UInt8(sym)
                        outputCount += 1
                        continue
                    }
                    let li = sym - 257
                    guard li < 29, let ex = r.bits(lenExtra[li]) else { return nil }
                    let length = lenBase[li] + ex
                    guard let dsym = decodeSymbol(&r, distTable), dsym < 30, let dex = r.bits(distExtra[dsym]) else { return nil }
                    let dist = distBase[dsym] + dex
                    guard dist <= outputCount, outputCount + length <= outputCapacity else { return nil }
                    var sourceIndex = outputCount - dist
                    let outputEnd = outputCount + length
                    while outputCount < outputEnd {
                        out[outputCount] = out[sourceIndex]
                        outputCount += 1
                        sourceIndex += 1
                    }
                }

            default:
                return nil // reserved BTYPE
            }

            if bfinal == 1 { break }
        }

        outputOwned = false
        return Data(
            bytesNoCopy: out,
            count: outputCount,
            deallocator: .custom { pointer, _ in pointer.deallocate() }
        )
    }
}
