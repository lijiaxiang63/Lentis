// NiftiVolumeLoader.swift
// Lentis
//
// Bridges a parsed NiftiImage into the app's VolumeData representation.
//
// VolumeData stores voxels as Int16 (the format the Metal texture and CPU
// renderers expect). NIfTI data is often float32/uint16, so we quantize the
// calibrated values into Int16 while folding the quantization back into
// VolumeData.rescaleSlope/Intercept, so calibratedValue() reconstructs the
// true intensity. For CT (HU values comfortably inside Int16) we store HU
// directly (slope 1, intercept 0) — so HU window presets need no conversion.
//
// Also performs modality auto-detection (CT vs MRI) from the intensity
// distribution: a CT scan carries a large population of strongly-negative
// air voxels (≈ −1000 HU); MRI intensity is non-negative.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import simd

/// Imaging modality. NIfTI has no standard modality field, so this is inferred
/// (with manual override available in the UI).
enum ImagingModality: String, CaseIterable, Identifiable {
    case ct = "CT"
    case mri = "MRI"
    var id: String { rawValue }

    /// Unit label for cursor/value readouts.
    var unitLabel: String { self == .ct ? "HU" : "" }
}

/// Wraps a NiftiImage and vends Int16 VolumeData for any timepoint, using a
/// single consistent quantization so 4D timepoints share a display scale.
final class NiftiDataset {
    let image: NiftiImage
    let seriesID: String
    let displayName: String
    let detectedModality: ImagingModality

    var timepointCount: Int { image.nt }
    var isMultiVolume: Bool { image.nt > 1 }

    // Quantization: stored Int16 → calibrated value is `stored * storeSlope + storeInter`.
    private let storeDirect: Bool
    private let storeSlope: Double
    private let storeInter: Double
    private let quantLo: Double
    private let quantScale: Double

    /// Suggested display window (low, high) in STORED units, derived from a
    /// robust 1–99% percentile of the first timepoint. Used as the initial
    /// MRI auto-window; CT overrides with HU presets.
    let suggestedWindow: (low: Double, high: Double)

    init(image: NiftiImage, seriesID: String, displayName: String) {
        self.image = image
        self.seriesID = seriesID
        self.displayName = displayName

        let v0 = image.calibratedVolume(timepoint: 0)

        // Robust statistics over finite samples across ALL timepoints, so a
        // single quantization scale displays every 4D volume consistently.
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        var negCount = 0
        var finiteCount = 0
        func accumulate(_ samples: [Float]) {
            for f in samples where f.isFinite {
                let d = Double(f)
                if d < lo { lo = d }
                if d > hi { hi = d }
                if d < -200 { negCount += 1 }
                finiteCount += 1
            }
        }
        accumulate(v0)
        if image.nt > 1 {
            for t in 1..<image.nt { accumulate(image.calibratedVolume(timepoint: t)) }
        }
        if finiteCount == 0 { lo = 0; hi = 1 }
        if hi <= lo { hi = lo + 1 }

        // Modality heuristic: substantial strongly-negative population ⇒ CT.
        let negFrac = Double(negCount) / Double(max(1, finiteCount))
        self.detectedModality = (lo <= -500 && negFrac >= 0.02) ? .ct : .mri

        // Choose storage mapping. Store directly when the calibrated range fits
        // Int16 and spans enough levels that integer rounding is lossless-enough
        // for display (true for CT HU and most integer MRI). Otherwise quantize.
        let fitsDirect = lo >= -32768 && hi <= 32767 && (hi - lo) >= 256
        if fitsDirect {
            self.storeDirect = true
            self.storeSlope = 1
            self.storeInter = 0
            self.quantLo = 0
            self.quantScale = 1
        } else {
            // Map [lo, hi] → roughly [-32000, 32000] (64000 levels).
            let span = max(hi - lo, 1e-6)
            let scale = span / 64000.0
            self.storeDirect = false
            self.storeSlope = scale
            self.storeInter = lo + 32000.0 * scale
            self.quantLo = lo
            self.quantScale = scale
        }

        // Robust percentile window from a coarse histogram of v0 (in stored units).
        self.suggestedWindow = NiftiDataset.percentileWindow(
            v0, lo: lo, hi: hi,
            toStored: { value in
                if fitsDirect { return (value as Double).rounded() }
                return (((value as Double) - lo) / max(hi - lo, 1e-6) * 64000.0).rounded() - 32000
            }
        )
    }

    /// Effective modality given an optional manual override.
    func modality(override: ImagingModality?) -> ImagingModality { override ?? detectedModality }

    /// Build an Int16 VolumeData for one timepoint, preserving the NIfTI affine.
    func makeVolume(timepoint t: Int) -> VolumeData {
        let values = image.calibratedVolume(timepoint: t)
        let n = values.count
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: n)

        if storeDirect {
            for i in 0..<n {
                let f = values[i].isFinite ? Double(values[i]) : 0
                let clamped = max(-32768.0, min(32767.0, f.rounded()))
                buffer[i] = Int16(clamped)
            }
        } else {
            let lo = quantLo, scale = quantScale
            for i in 0..<n {
                let f = values[i].isFinite ? Double(values[i]) : lo
                let q = (((f - lo) / scale).rounded()) - 32000
                let clamped = max(-32768.0, min(32767.0, q))
                buffer[i] = Int16(clamped)
            }
        }

        let uid = isMultiVolume ? "\(seriesID)#t\(t)" : seriesID
        return VolumeData(
            voxels: buffer,
            width: image.nx, height: image.ny, depth: image.nz,
            voxelToWorld: image.affine,
            rescaleSlope: storeSlope,
            rescaleIntercept: storeInter,
            seriesUID: uid
        )
    }

    // MARK: - Helpers

    /// 1–99% percentile window via a 1024-bin histogram, returned in stored units.
    private static func percentileWindow(
        _ values: [Float], lo: Double, hi: Double,
        toStored: (Double) -> Double
    ) -> (low: Double, high: Double) {
        let bins = 1024
        let span = max(hi - lo, 1e-6)
        var hist = [Int](repeating: 0, count: bins)
        var total = 0
        for f in values where f.isFinite {
            let t = (Double(f) - lo) / span
            let b = min(bins - 1, max(0, Int(t * Double(bins - 1))))
            hist[b] += 1
            total += 1
        }
        if total == 0 { return (toStored(lo), toStored(hi)) }
        let loTarget = Int(Double(total) * 0.01)
        let hiTarget = Int(Double(total) * 0.99)
        var cum = 0
        var p1 = lo, p99 = hi
        var setP1 = false
        for b in 0..<bins {
            cum += hist[b]
            let value = lo + (Double(b) + 0.5) / Double(bins) * span
            if !setP1 && cum >= loTarget { p1 = value; setP1 = true }
            if cum >= hiTarget { p99 = value; break }
        }
        if p99 <= p1 { p99 = p1 + 1 }
        return (low: toStored(p1), high: toStored(p99))
    }
}
