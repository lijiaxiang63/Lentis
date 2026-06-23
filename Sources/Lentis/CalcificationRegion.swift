// CalcificationRegion.swift
// Lentis
//
// Phase 9 — one segmented calcification region: its label value in the editable
// mask plus presentation (name/color/visibility) and the parameters/box used to
// (re-)compute it. A plain data model (Combine ObservableObject); it depends
// only on the pure engine types, not on the viewer model.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Combine
import simd

final class CalcificationRegion: ObservableObject, Identifiable {
    let id = UUID()
    /// Distinct value this region occupies in the base volume's `labelMask`.
    let label: UInt8
    @Published var name: String
    @Published var color: SIMD3<Double>
    @Published var parameters: SegmentationParameters
    @Published var box: VoxelBox
    @Published var voxelCount: Int = 0
    @Published var anatomicalName: String? = nil
    @Published var isVisible: Bool = true
    // Draft-only live state (mirrors the last preview run).
    @Published var previewVoxelCount: Int = 0
    @Published var previewTruncated: Bool = false

    var method: SegmentationMethod { parameters.method }

    init(label: UInt8, name: String, color: SIMD3<Double>,
         parameters: SegmentationParameters, box: VoxelBox) {
        self.label = label
        self.name = name
        self.color = color
        self.parameters = parameters
        self.box = box
    }
}
