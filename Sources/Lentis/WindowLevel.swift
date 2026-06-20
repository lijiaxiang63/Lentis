// WindowLevel.swift
// Lentis
//
// Modality-aware window/level presets.
//
// Window width/center are expressed in each modality's native intensity unit.
// For CT that is Hounsfield Units (HU); Lentis stores HU directly in the Int16
// voxel buffer (rescaleSlope 1 / intercept 0) for in-range scans (see
// NiftiVolumeLoader), so these HU values map straight onto the stored voxels the
// renderer windows. `storedWindow(slope:intercept:)` converts to stored units
// for the rare quantized CT and is the identity for direct-HU CT.
//
// MRI has no standard intensity scale, so it uses a data-derived percentile
// auto-window (NiftiDataset.suggestedWindow) rather than fixed presets.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

/// A named CT window/level preset, in Hounsfield Units (HU).
struct WindowPreset: Identifiable, Equatable {
    let name: String
    /// Window width (HU): the span of HU mapped from black to white.
    let width: Double
    /// Window center / level (HU): the HU mapped to mid-grey.
    let center: Double

    var id: String { name }

    /// Lower HU bound of the window (mapped to black).
    var low: Double { center - width / 2 }
    /// Upper HU bound of the window (mapped to white).
    var high: Double { center + width / 2 }

    /// Convert this HU preset to the (width, center) in *stored* units the
    /// renderer windows on, given a volume's calibration (stored·slope + inter = HU).
    /// Identity for direct-HU CT (slope 1, intercept 0).
    func storedWindow(slope: Double, intercept: Double) -> (width: Double, center: Double) {
        let s = (slope == 0 ? 1 : slope)
        return (max(width / s, 1), (center - intercept) / s)
    }
}

extension WindowPreset {
    /// Standard head-CT window presets (HU). Extensible: add a row here and it
    /// appears in the CT preset menu automatically. `Brain` is the clinical default.
    static let ctPresets: [WindowPreset] = [
        WindowPreset(name: "Brain",       width: 80,   center: 40),   // (0, 80) low/high
        WindowPreset(name: "Subdural",    width: 215,  center: 75),
        WindowPreset(name: "Stroke",      width: 40,   center: 40),
        WindowPreset(name: "Bone",        width: 2800, center: 600),
        WindowPreset(name: "Soft Tissue", width: 375,  center: 40),
    ]

    /// The default CT preset (head/brain).
    static var defaultCT: WindowPreset { ctPresets[0] }
}
