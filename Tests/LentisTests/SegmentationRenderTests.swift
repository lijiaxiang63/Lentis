// SegmentationRenderTests.swift
// Lentis Tests
//
// Phase 9 — per-label segmentation rendering:
//   • renderSlice with a per-label color table (maskAtlasColors) colors each
//     mask label value distinctly (multi-region calcification), while the
//     no-table path stays the original single flat-color mask.
//   • The parallelized sagittal maskSlice matches a serial reference for a
//     multi-label mask (the cache-hostile gather, now concurrentPerform — must
//     stay byte-identical; alignment is also locked by SegmentationSeamTests).
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class SegmentationRenderTests: XCTestCase {

    private func makeVolume(_ w: Int, _ h: Int, _ d: Int) -> VolumeData {
        let count = w * h * d
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
        for i in 0..<count { buf[i] = Int16(i % 97) }   // arbitrary gray content
        return VolumeData(
            voxels: buf, width: w, height: h, depth: d,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: SIMD3(0, 0, 0),
            rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
            rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "render-test")
    }

    /// Copy out the rendered NSImage's RGBA bytes (top-down rows).
    private func rgbaBytes(of image: NSImage) -> (w: Int, h: Int, bytes: [UInt8])? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h * 4) { bytes[i] = p[i] }
        return (w, h, bytes)
    }

    // MARK: - Per-label atlas colors

    func testPerLabelAtlasColorsRenderDistinctColors() {
        let vol = makeVolume(8, 8, 4)
        let mask = vol.ensureLabelMask()
        // Two regions in axial slice z = 1.
        mask.setLabel(1, x: 2, y: 2, z: 1)
        mask.setLabel(1, x: 3, y: 2, z: 1)   // label 1 ×2
        mask.setLabel(2, x: 5, y: 5, z: 1)   // label 2 ×1

        let engine = MPREngine(volume: vol)
        let gray = engine.axialSlice(at: 1)!
        let maskSlice = engine.maskSlice(mode: .mprAxial, sliceIndex: 1)!

        let colors: [Int32: LayerRGBA] = [
            1: LayerRGBA(red: 1, green: 0, blue: 0, alpha: 1),   // opaque red
            2: LayerRGBA(red: 0, green: 1, blue: 0, alpha: 1),   // opaque green
        ]
        let image = MPREngine.renderSlice(gray, ww: 200, wc: 50, mask: maskSlice,
                                          maskAtlasColors: colors)
        guard let image, let (_, _, bytes) = rgbaBytes(of: image) else {
            return XCTFail("render produced no inspectable image")
        }

        var red = 0, green = 0, gray0 = 0
        for px in stride(from: 0, to: bytes.count, by: 4) {
            let r = bytes[px], g = bytes[px + 1], b = bytes[px + 2]
            if r > 200 && g < 60 && b < 60 { red += 1 }
            else if g > 200 && r < 60 && b < 60 { green += 1 }
            else if r == g && g == b { gray0 += 1 }
        }
        XCTAssertEqual(red, 2, "label-1 voxels render red")
        XCTAssertEqual(green, 1, "label-2 voxels render green")
        XCTAssertEqual(gray0, 8 * 8 - 3, "every other pixel stays grayscale")
    }

    func testNoColorTableKeepsFlatMaskPath() {
        // Without a color table, multiple label VALUES all render in the single
        // flat mask color (the Phase 7 behavior) — verified by there being only
        // one non-gray color present.
        let vol = makeVolume(6, 6, 3)
        let mask = vol.ensureLabelMask()
        mask.setLabel(1, x: 1, y: 1, z: 0)
        mask.setLabel(2, x: 4, y: 4, z: 0)
        let engine = MPREngine(volume: vol)
        let gray = engine.axialSlice(at: 0)!
        let maskSlice = engine.maskSlice(mode: .mprAxial, sliceIndex: 0)!

        let image = MPREngine.renderSlice(gray, ww: 200, wc: 50, mask: maskSlice,
                                          maskColor: SIMD3(0, 0, 1), maskAlpha: 1.0)   // flat blue
        guard let image, let (_, _, bytes) = rgbaBytes(of: image) else {
            return XCTFail("render produced no inspectable image")
        }
        var blue = 0
        for px in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[px] < 60 && bytes[px + 1] < 60 && bytes[px + 2] > 200 { blue += 1 }
        }
        XCTAssertEqual(blue, 2, "both label values share the single flat mask color")
    }

    // MARK: - Parallelized sagittal mask extraction

    func testSagittalMaskSliceMatchesSerialReference() {
        let w = 5, h = 6, d = 7
        let vol = makeVolume(w, h, d)
        let mask = vol.ensureLabelMask()
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    mask.setLabel(UInt8((x * 7 + y * 3 + z * 2) % 5), x: x, y: y, z: z)
                }
            }
        }
        let engine = MPREngine(volume: vol)

        for xIndex in 0..<w {
            guard let slice = engine.maskSlice(mode: .mprSagittal, sliceIndex: xIndex) else {
                return XCTFail("missing sagittal mask slice \(xIndex)")
            }
            let sw = h, sh = d
            XCTAssertEqual(slice.width, sw)
            XCTAssertEqual(slice.height, sh)
            var ref = [UInt8](repeating: 0, count: sw * sh)
            for z in 0..<d {
                let outRow = (d - 1 - z) * sw
                for y in 0..<h {
                    let outCol = (sw - 1) - y
                    ref[outRow + outCol] = mask.labelAt(x: xIndex, y: y, z: z)
                }
            }
            XCTAssertEqual(slice.labels, ref, "parallel sagittal mask must equal serial reference at i=\(xIndex)")
        }
    }
}
