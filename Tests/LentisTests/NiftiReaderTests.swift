// NiftiReaderTests.swift
// Lentis
//
// Self-contained tests for the NIfTI reader. A minimal in-test NIfTI-1 writer
// and gzip encoder synthesize fixtures on the fly, so no external data is
// required. Validates header parsing, affine (sform/qform), datatypes,
// endianness, 4D, intensity calibration, and the .nii.gz path.

import Testing
import Foundation
import simd
import Compression
@testable import Lentis

// MARK: - In-test NIfTI-1 writer

struct NiftiSpec {
    var nx: Int, ny: Int, nz: Int, nt: Int = 1
    var datatype: Int16          // 4=int16, 16=float32, 512=uint16
    var bitpix: Int16
    var pixdim: [Float] = [1, 1, 1, 1, 0, 0, 0, 0]   // [qfac,dx,dy,dz,...]
    var sclSlope: Float = 0
    var sclInter: Float = 0
    var sformCode: Int16 = 1
    var qformCode: Int16 = 0
    var srow: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]
    var quatern: (Float, Float, Float) = (0, 0, 0)
    var qoffset: (Float, Float, Float) = (0, 0, 0)
    var littleEndian: Bool = true
}

private func putI16(_ b: inout [UInt8], _ o: Int, _ v: Int16, _ le: Bool) {
    let u = UInt16(bitPattern: v)
    let bytes = le ? [UInt8(u & 0xff), UInt8(u >> 8)] : [UInt8(u >> 8), UInt8(u & 0xff)]
    b[o] = bytes[0]; b[o + 1] = bytes[1]
}
private func putU16(_ b: inout [UInt8], _ o: Int, _ u: UInt16, _ le: Bool) {
    putI16(&b, o, Int16(bitPattern: u), le)
}
private func putI32(_ b: inout [UInt8], _ o: Int, _ v: Int32, _ le: Bool) {
    let u = UInt32(bitPattern: v)
    for k in 0..<4 {
        let shift = le ? (8 * k) : (8 * (3 - k))
        b[o + k] = UInt8((u >> shift) & 0xff)
    }
}
private func putF32(_ b: inout [UInt8], _ o: Int, _ v: Float, _ le: Bool) {
    putI32(&b, o, Int32(bitPattern: v.bitPattern), le)
}

func buildNifti(_ s: NiftiSpec, voxels: [Float]) -> Data {
    let le = s.littleEndian
    let voxOffset = 352
    var hdr = [UInt8](repeating: 0, count: voxOffset)
    putI32(&hdr, 0, 348, le)                       // sizeof_hdr
    // dim
    let ndim: Int16 = s.nt > 1 ? 4 : 3
    putI16(&hdr, 40, ndim, le)
    putI16(&hdr, 42, Int16(s.nx), le)
    putI16(&hdr, 44, Int16(s.ny), le)
    putI16(&hdr, 46, Int16(s.nz), le)
    putI16(&hdr, 48, Int16(s.nt), le)
    putI16(&hdr, 50, 1, le); putI16(&hdr, 52, 1, le); putI16(&hdr, 54, 1, le)
    putI16(&hdr, 70, s.datatype, le)               // datatype
    putI16(&hdr, 72, s.bitpix, le)                 // bitpix
    for k in 0..<8 { putF32(&hdr, 76 + k * 4, k < s.pixdim.count ? s.pixdim[k] : 0, le) }
    putF32(&hdr, 108, Float(voxOffset), le)        // vox_offset
    putF32(&hdr, 112, s.sclSlope, le)              // scl_slope
    putF32(&hdr, 116, s.sclInter, le)              // scl_inter
    putI16(&hdr, 252, s.qformCode, le)             // qform_code
    putI16(&hdr, 254, s.sformCode, le)             // sform_code
    putF32(&hdr, 256, s.quatern.0, le)
    putF32(&hdr, 260, s.quatern.1, le)
    putF32(&hdr, 264, s.quatern.2, le)
    putF32(&hdr, 268, s.qoffset.0, le)
    putF32(&hdr, 272, s.qoffset.1, le)
    putF32(&hdr, 276, s.qoffset.2, le)
    for r in 0..<3 { for c in 0..<4 { putF32(&hdr, 280 + r * 16 + c * 4, s.srow[r][c], le) } }
    // magic "n+1\0" at 344
    hdr[344] = 0x6E; hdr[345] = 0x2B; hdr[346] = 0x31; hdr[347] = 0x00

    var data = Data(hdr)
    // voxel payload in declared datatype + endianness
    var payload = [UInt8]()
    payload.reserveCapacity(voxels.count * Int(s.bitpix) / 8)
    for v in voxels {
        switch s.datatype {
        case 4: // int16
            var tmp = [UInt8](repeating: 0, count: 2); putI16(&tmp, 0, Int16(v.rounded()), le); payload.append(contentsOf: tmp)
        case 512: // uint16
            var tmp = [UInt8](repeating: 0, count: 2); putU16(&tmp, 0, UInt16(max(0, v.rounded())), le); payload.append(contentsOf: tmp)
        case 16: // float32
            var tmp = [UInt8](repeating: 0, count: 4); putF32(&tmp, 0, v, le); payload.append(contentsOf: tmp)
        default:
            break
        }
    }
    data.append(contentsOf: payload)
    return data
}

func rampVoxels(_ nx: Int, _ ny: Int, _ nz: Int, base: Float = 0) -> [Float] {
    var v = [Float](repeating: 0, count: nx * ny * nz)
    for i in 0..<v.count { v[i] = base + Float(i) }
    return v
}

// MARK: - In-test gzip encoder (to exercise the gunzip path)

private func crc32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        table[i] = c
    }
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    return crc ^ 0xFFFFFFFF
}

private func gzipCompress(_ data: Data) -> Data {
    let srcCount = data.count
    let dstCap = srcCount * 2 + 1024
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
    defer { dst.deallocate() }
    let written = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
        compression_encode_buffer(dst, dstCap,
                                  raw.bindMemory(to: UInt8.self).baseAddress!, srcCount,
                                  nil, COMPRESSION_ZLIB)
    }
    var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff]) // gzip header (OS=unknown)
    out.append(dst, count: written)
    var crc = crc32(data).littleEndian
    withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
    var isize = UInt32(truncatingIfNeeded: srcCount).littleEndian
    withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
    return out
}

// MARK: - Tests

@Test
func niftiInt16ParsesDimsAndSformAffine() throws {
    let spec = NiftiSpec(nx: 4, ny: 3, nz: 2, datatype: 4, bitpix: 16,
                         srow: [[2, 0, 0, 10], [0, 3, 0, 20], [0, 0, 4, 30]])
    let voxels = rampVoxels(4, 3, 2)
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: voxels))

    #expect(img.nx == 4 && img.ny == 3 && img.nz == 2 && img.nt == 1)
    #expect(img.affineSource == .sform)

    // voxel (1,1,1) -> (12, 23, 34)
    let w = img.affine * SIMD4<Double>(1, 1, 1, 1)
    #expect(abs(w.x - 12) < 1e-6 && abs(w.y - 23) < 1e-6 && abs(w.z - 34) < 1e-6)

    let vol = img.calibratedVolume(timepoint: 0)
    #expect(vol.count == 24)
    #expect(vol[0] == 0 && vol[1] == 1 && vol[23] == 23)
}

@Test
func niftiFloat32AppliesSclSlopeAndInter() throws {
    let spec = NiftiSpec(nx: 2, ny: 2, nz: 2, datatype: 16, bitpix: 32,
                         sclSlope: 2, sclInter: -10)
    let raw: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: raw))
    let vol = img.calibratedVolume(timepoint: 0)
    for i in 0..<8 { #expect(abs(vol[i] - (raw[i] * 2 - 10)) < 1e-4) }
}

@Test
func niftiUint16ReadsUnsignedValues() throws {
    let spec = NiftiSpec(nx: 2, ny: 1, nz: 1, datatype: 512, bitpix: 16)
    let raw: [Float] = [40000, 12345]   // would be negative if misread as signed
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: raw))
    let vol = img.calibratedVolume(timepoint: 0)
    #expect(vol[0] == 40000 && vol[1] == 12345)
}

@Test
func niftiBigEndianInt16ReadsCorrectly() throws {
    var spec = NiftiSpec(nx: 3, ny: 1, nz: 1, datatype: 4, bitpix: 16)
    spec.littleEndian = false
    let raw: [Float] = [100, -200, 300]
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: raw))
    #expect(img.nx == 3)
    let vol = img.calibratedVolume(timepoint: 0)
    #expect(vol[0] == 100 && vol[1] == -200 && vol[2] == 300)
}

@Test
func nifti4DSelectsTimepoint() throws {
    let nx = 2, ny = 2, nz = 2, nt = 3
    var spec = NiftiSpec(nx: nx, ny: ny, nz: nz, nt: nt, datatype: 4, bitpix: 16)
    spec.pixdim = [1, 1, 1, 1, 1, 0, 0, 0]
    // timepoint t has every voxel == 100*(t+1)
    var voxels = [Float]()
    for t in 0..<nt { voxels.append(contentsOf: [Float](repeating: Float(100 * (t + 1)), count: nx * ny * nz)) }
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: voxels))
    #expect(img.nt == 3)
    #expect(img.calibratedVolume(timepoint: 0).allSatisfy { $0 == 100 })
    #expect(img.calibratedVolume(timepoint: 1).allSatisfy { $0 == 200 })
    #expect(img.calibratedVolume(timepoint: 2).allSatisfy { $0 == 300 })
}

@Test
func niftiQformIdentityAffine() throws {
    var spec = NiftiSpec(nx: 2, ny: 2, nz: 2, datatype: 4, bitpix: 16)
    spec.sformCode = 0
    spec.qformCode = 1
    spec.pixdim = [1, 2, 3, 4, 0, 0, 0, 0]   // qfac=1, spacing 2/3/4
    spec.quatern = (0, 0, 0)                  // identity rotation
    spec.qoffset = (5, 6, 7)
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: rampVoxels(2, 2, 2)))
    #expect(img.affineSource == .qform)
    let w = img.affine * SIMD4<Double>(1, 1, 1, 1)
    #expect(abs(w.x - 7) < 1e-6 && abs(w.y - 9) < 1e-6 && abs(w.z - 11) < 1e-6)
}

@Test
func niftiGzipRoundTripMatchesUncompressed() throws {
    let spec = NiftiSpec(nx: 5, ny: 4, nz: 3, datatype: 4, bitpix: 16,
                         srow: [[1, 0, 0, -2], [0, 1, 0, -3], [0, 0, 1, -4]])
    let voxels = rampVoxels(5, 4, 3, base: -50)
    let plain = buildNifti(spec, voxels: voxels)
    #expect(plain.count == 472)                 // diagnostic: header(352)+60*2
    let gz = gzipCompress(plain)
    #expect(gz.count > 18)                       // deflate produced a body

    // Sanity: it really is gzip-framed and smaller-or-different from plain.
    #expect(gz[0] == 0x1f && gz[1] == 0x8b)

    let imgPlain = try NiftiImage.read(data: plain)
    let imgGz = try NiftiImage.read(data: gz)
    #expect(imgGz.nx == imgPlain.nx && imgGz.ny == imgPlain.ny && imgGz.nz == imgPlain.nz)
    let a = imgPlain.calibratedVolume(timepoint: 0)
    let b = imgGz.calibratedVolume(timepoint: 0)
    #expect(a == b)
    #expect(a[0] == -50)
}

@Test
func niftiRejectsNonNifti() {
    let junk = Data([UInt8](repeating: 0x42, count: 400))
    #expect(throws: NiftiError.self) { try NiftiImage.read(data: junk) }
}

// MARK: - NiftiDataset (modality detection + Int16 quantization)

@Test
func datasetDetectsCTFromNegativeAirAndStoresHUExactly() throws {
    let nx = 8, ny = 8, nz = 8
    var vox = [Float](repeating: -1000, count: nx * ny * nz)   // air
    for z in 3..<5 { for y in 0..<ny { for x in 0..<nx { vox[x + nx * (y + ny * z)] = 40 } } }   // tissue
    for z in 3..<5 { for y in 3..<5 { for x in 3..<5 { vox[x + nx * (y + ny * z)] = 400 } } }     // calcification
    let img = try NiftiImage.read(data: buildNifti(NiftiSpec(nx: nx, ny: ny, nz: nz, datatype: 4, bitpix: 16), voxels: vox))
    let ds = NiftiDataset(image: img, seriesID: "ct", displayName: "ct")

    #expect(ds.detectedModality == .ct)
    let vol = ds.makeVolume(timepoint: 0)
    // Direct HU storage ⇒ calibrated values are exact.
    #expect(abs(vol.calibratedValue(x: 0, y: 0, z: 0) - (-1000)) < 0.5)
    #expect(abs(vol.calibratedValue(x: 4, y: 4, z: 4) - 400) < 0.5)
}

@Test
func datasetDetectsMRIFromNonNegative() throws {
    let nx = 8, ny = 8, nz = 8
    var vox = [Float](repeating: 0, count: nx * ny * nz)
    for i in 0..<vox.count { vox[i] = Float(i % 1000) }        // 0…999, non-negative
    let img = try NiftiImage.read(data: buildNifti(NiftiSpec(nx: nx, ny: ny, nz: nz, datatype: 16, bitpix: 32), voxels: vox))
    let ds = NiftiDataset(image: img, seriesID: "mr", displayName: "mr")

    #expect(ds.detectedModality == .mri)
    #expect(ds.detectedModality.unitLabel == "")
    let vol = ds.makeVolume(timepoint: 0)
    #expect(abs(vol.calibratedValue(x: 1, y: 0, z: 0) - 1) < 1)
}

@Test
func datasetQuantizesNormalizedFloatWithLowError() throws {
    let nx = 8, ny = 8, nz = 8
    var vox = [Float](repeating: 0, count: nx * ny * nz)
    for i in 0..<vox.count { vox[i] = Float(i) / Float(vox.count) }   // 0…~1 (forces quantization)
    let img = try NiftiImage.read(data: buildNifti(NiftiSpec(nx: nx, ny: ny, nz: nz, datatype: 16, bitpix: 32), voxels: vox))
    let ds = NiftiDataset(image: img, seriesID: "mrn", displayName: "mrn")

    #expect(ds.detectedModality == .mri)
    let vol = ds.makeVolume(timepoint: 0)
    let idx = 300
    let z = idx / (nx * ny), rem = idx % (nx * ny), y = rem / nx, x = rem % nx
    #expect(abs(vol.calibratedValue(x: x, y: y, z: z) - Double(vox[idx])) < 0.001)
}

@Test
func dataset4DProducesDistinctTimepointVolumes() throws {
    let nx = 4, ny = 4, nz = 4, nt = 3
    var spec = NiftiSpec(nx: nx, ny: ny, nz: nz, nt: nt, datatype: 4, bitpix: 16)
    spec.pixdim = [1, 1, 1, 1, 1, 0, 0, 0]
    var vox = [Float]()
    for t in 0..<nt { vox.append(contentsOf: [Float](repeating: Float(500 * (t + 1)), count: nx * ny * nz)) }
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: vox))
    let ds = NiftiDataset(image: img, seriesID: "4d", displayName: "4d")

    #expect(ds.timepointCount == 3 && ds.isMultiVolume)
    let v0 = ds.makeVolume(timepoint: 0)
    let v2 = ds.makeVolume(timepoint: 2)
    #expect(v0.seriesUID != v2.seriesUID)
    #expect(abs(v0.calibratedValue(x: 0, y: 0, z: 0) - 500) < 1)
    #expect(abs(v2.calibratedValue(x: 0, y: 0, z: 0) - 1500) < 1)
}

// MARK: - Canonical-RAS reorientation (Phase 4)

@Test
func datasetReorientsLASVolumeToCanonicalRAS() throws {
    // LAS storage: voxel-i increases toward patient Left (−x). Voxel values are
    // the source linear index, so we can trace exactly where each one lands.
    let nx = 8, ny = 8, nz = 8
    let spec = NiftiSpec(nx: nx, ny: ny, nz: nz, datatype: 4, bitpix: 16,
                         srow: [[-1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]])
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: rampVoxels(nx, ny, nz)))
    let vol = NiftiDataset(image: img, seriesID: "las", displayName: "las").makeVolume(timepoint: 0)

    // Pure flip on axis 0 ⇒ same dims, axis-0 reversed.
    #expect(vol.width == 8 && vol.height == 8 && vol.depth == 8)
    let reo = try #require(vol.reorientation)
    #expect(reo.sourceAxis == (0, 1, 2))
    #expect(reo.flip == (true, false, false))

    // Canonical voxel (I,J,K) holds source (7−I, J, K): value = (7−I) + 8J + 64K.
    func expected(_ I: Int, _ J: Int, _ K: Int) -> Double { Double((7 - I) + 8 * J + 64 * K) }
    #expect(vol.calibratedValue(x: 0, y: 0, z: 0) == expected(0, 0, 0))   // 7
    #expect(vol.calibratedValue(x: 7, y: 0, z: 0) == expected(7, 0, 0))   // 0
    #expect(vol.calibratedValue(x: 1, y: 2, z: 3) == expected(1, 2, 3))   // 214

    // Canonical voxel-i now points to patient Right (+x).
    let di = vol.voxelToWorld(SIMD3(1, 0, 0)) - vol.voxelToWorld(SIMD3(0, 0, 0))
    #expect(anatomicalDirection(of: di) == .R)

    // World position preserved vs. the original affine + original voxel.
    let p = vol.voxelToWorld(SIMD3(1, 2, 3))
    let q = img.affine * SIMD4<Double>(Double(7 - 1), 2, 3, 1)
    #expect(abs(p.x - q.x) < 1e-6 && abs(p.y - q.y) < 1e-6 && abs(p.z - q.z) < 1e-6)
    #expect(vol.originalAffine != nil)
}

@Test
func datasetReorientsPermutedVolumeToCanonicalRAS() throws {
    // Sagittal-style storage: voxel i→S, j→A, k→R. Distinct dims so the
    // permutation is observable in the canonical extent.
    let nx = 4, ny = 8, nz = 16
    let spec = NiftiSpec(nx: nx, ny: ny, nz: nz, datatype: 4, bitpix: 16,
                         srow: [[0, 0, 1, 0], [0, 1, 0, 0], [1, 0, 0, 0]])
    let img = try NiftiImage.read(data: buildNifti(spec, voxels: rampVoxels(nx, ny, nz)))
    let vol = NiftiDataset(image: img, seriesID: "sag", displayName: "sag").makeVolume(timepoint: 0)

    // canonical (R,A,S) ← source (k,j,i): extent (nz,ny,nx) = (16,8,4).
    #expect(vol.width == 16 && vol.height == 8 && vol.depth == 4)
    let reo = try #require(vol.reorientation)
    #expect(reo.sourceAxis == (2, 1, 0))
    #expect(reo.flip == (false, false, false))

    // Canonical (I,J,K) holds source (i=K, j=J, k=I): value = K + 4J + 32I.
    func expected(_ I: Int, _ J: Int, _ K: Int) -> Double { Double(K + 4 * J + 32 * I) }
    #expect(vol.calibratedValue(x: 0, y: 0, z: 0) == expected(0, 0, 0))     // 0
    #expect(vol.calibratedValue(x: 15, y: 0, z: 0) == expected(15, 0, 0))   // 480
    #expect(vol.calibratedValue(x: 2, y: 3, z: 1) == expected(2, 3, 1))     // 77

    // Canonical axes point to R / A / S.
    let dR = vol.voxelToWorld(SIMD3(1, 0, 0)) - vol.voxelToWorld(SIMD3(0, 0, 0))
    let dA = vol.voxelToWorld(SIMD3(0, 1, 0)) - vol.voxelToWorld(SIMD3(0, 0, 0))
    let dS = vol.voxelToWorld(SIMD3(0, 0, 1)) - vol.voxelToWorld(SIMD3(0, 0, 0))
    #expect(anatomicalDirection(of: dR) == .R)
    #expect(anatomicalDirection(of: dA) == .A)
    #expect(anatomicalDirection(of: dS) == .S)
}
