// SegmentInspectorView.swift
// Lentis
//
// Phase 9 — the Segment tab of the trailing inspector. Brain mask (load /
// SynthSeg), the active draft region's method + threshold + ROI histogram +
// options, the committed-regions list (recolor / rename / re-edit / delete /
// brush), and mask/atlas export. Matches the Liquid-Glass inspector idiom
// (InspectorSection, glass buttons, Theme tokens).
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SegmentInspectorView: View {
    @ObservedObject var model: ViewerModel
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                brainMaskSection
                Divider().padding(.horizontal, Spacing.m)
                activeRegionSection
                Divider().padding(.horizontal, Spacing.m)
                regionsSection
                Divider().padding(.horizontal, Spacing.m)
                exportSection
            }
            .padding(.vertical, Spacing.s)
        }
        .overlay {
            if model.segmentationVolume == nil {
                ContentUnavailableView("No Volume",
                                       systemImage: "cube.transparent",
                                       description: Text("Open a brain CT to segment calcifications."))
            }
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil },
                                                     set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    // MARK: - Brain mask

    private var brainMaskSection: some View {
        InspectorSection(title: "Brain Mask") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(model.brainMaskStatus.isEmpty ? "No brain mask — skull may be included." : model.brainMaskStatus)
                    .font(.caption)
                    .foregroundStyle(model.brainMaskLayer == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.s) {
                    Button { loadBrainMaskPanel() } label: { Label("Load…", systemImage: "square.dashed") }
                        .buttonStyle(.glass)
                        .disabled(model.segmentationVolume == nil)
                    if model.brainMaskLayer != nil {
                        Button(role: .destructive) { model.clearBrainMask() } label: {
                            Label("Clear", systemImage: "xmark")
                        }
                        .buttonStyle(.glass)
                    }
                }

                if model.isRunningSynthSeg {
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(model.synthSegStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Cancel") { model.cancelSynthSeg() }.buttonStyle(.glass)
                    }
                } else if model.synthSegAvailable {
                    Button { model.generateBrainMaskWithSynthSeg() } label: {
                        Label("Generate with SynthSeg", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.segmentationVolume == nil)
                    if !model.synthSegStatus.isEmpty {
                        Text(model.synthSegStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else {
                    Button { locateSynthSegPanel() } label: {
                        Label("Locate mri_synthseg…", systemImage: "questionmark.folder")
                    }
                    .buttonStyle(.glass)
                    Text("FreeSurfer SynthSeg not found.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Active region

    @ViewBuilder
    private var activeRegionSection: some View {
        if let draft = model.draftRegion {
            ActiveRegionEditor(model: model, draft: draft)
        } else {
            InspectorSection(title: "New Region") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Pick a method, then drag a box on a plane (ROI Box tool, B).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Spacing.s) {
                        Button { model.beginRegion(method: .thresholdInROI) } label: {
                            Label("Threshold", systemImage: "slider.horizontal.below.square.filled.and.square")
                        }.buttonStyle(.glass)
                        Button { model.beginRegion(method: .growFromSeed) } label: {
                            Label("Grow", systemImage: "drop.fill")
                        }.buttonStyle(.glass)
                    }
                    .disabled(model.segmentationVolume == nil)
                }
            }
        }
    }

    // MARK: - Regions list

    private var regionsSection: some View {
        InspectorSection(title: "Regions") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if model.calcRegions.isEmpty {
                    Text("No regions yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.calcRegions) { region in
                        RegionRow(model: model, region: region)
                    }
                    brushControls
                }
            }
        }
    }

    @ViewBuilder
    private var brushControls: some View {
        if model.activeRegionID != nil {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Divider().padding(.vertical, Spacing.xs)
                HStack {
                    Text("Touch-up brush").font(.caption.weight(.medium))
                    Spacer()
                    Button {
                        model.activeTool = model.activeTool == .calcBrush ? .select : .calcBrush
                    } label: {
                        Label(model.activeTool == .calcBrush ? "Brushing" : "Use Brush (K)",
                              systemImage: "paintbrush.pointed.fill")
                    }
                    .buttonStyle(.glass)
                    .tint(model.activeTool == .calcBrush ? .lentisAccent : nil)
                }
                Picker("", selection: $model.calcBrushErase) {
                    Text("Add").tag(false)
                    Text("Erase").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                HStack {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(model.calcBrushRadius) },
                                          set: { model.calcBrushRadius = Int($0.rounded()) }),
                           in: 0...8)
                    Text("\(model.calcBrushRadius)").font(.lentisReadout).foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        InspectorSection(title: "Export") {
            HStack(spacing: Spacing.s) {
                Button { export(kind: .binaryMask) } label: { Label("Mask…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.glass)
                Button { export(kind: .atlas) } label: { Label("Atlas…", systemImage: "square.and.arrow.down.on.square") }
                    .buttonStyle(.glass)
            }
            .disabled(!model.hasSegmentation)
        }
    }

    // MARK: - Panels

    private func niftiTypes() -> [UTType] {
        ["nii", "gz"].compactMap { UTType(filenameExtension: $0) }
    }

    private func loadBrainMaskPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a brain mask or parcellation NIfTI (.nii / .nii.gz)"
        let t = niftiTypes(); if !t.isEmpty { panel.allowedContentTypes = t }
        if panel.runModal() == .OK, let url = panel.url { model.loadBrainMask(url: url) }
    }

    private func locateSynthSegPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Locate the mri_synthseg executable (FreeSurfer)"
        if panel.runModal() == .OK, let url = panel.url {
            SynthSegRunner.setUserBinary(url)
            model.synthSegBinaryOverride = url
            model.objectWillChange.send()
        }
    }

    private func defaultExportName(_ suffix: String) -> String {
        var base = model.loadedFileName
        if base.lowercased().hasSuffix(".nii.gz") { base = String(base.dropLast(7)) }
        else if base.lowercased().hasSuffix(".nii") { base = String(base.dropLast(4)) }
        if base.isEmpty { base = "segmentation" }
        return base + suffix
    }

    private func export(kind: NiftiMaskKind) {
        let panel = NSSavePanel()
        panel.message = kind == .binaryMask ? "Export calcification mask" : "Export calcification atlas"
        let t = niftiTypes(); if !t.isEmpty { panel.allowedContentTypes = t }
        panel.nameFieldStringValue = defaultExportName(kind == .binaryMask ? "_calcmask.nii.gz" : "_calcatlas.nii.gz")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if kind == .binaryMask { try model.exportMask(to: url) }
            else { try model.exportAtlas(to: url) }
        } catch { exportError = error.localizedDescription }
    }
}

// MARK: - Active region editor

private struct ActiveRegionEditor: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var draft: CalcificationRegion

    private var hist: (counts: [Int], minHU: Double, maxHU: Double)? {
        guard !draft.box.isEmpty, let seg = model.makeSegmenter() else { return nil }
        return seg.histogram(in: draft.box, bins: 48, constrainToBrainMask: draft.parameters.constrainToBrainMask)
    }

    var body: some View {
        InspectorSection(title: "Active Region") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Picker("Method", selection: Binding(
                    get: { draft.parameters.method },
                    set: { model.setActiveRegionMethod($0) })) {
                    ForEach(SegmentationMethod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if draft.box.isEmpty {
                    Text("Drag a box around the calcification on any plane.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let range = thresholdRange
                    if let h = hist {
                        ROIHistogramView(counts: h.counts, minHU: h.minHU, maxHU: h.maxHU,
                                         low: draft.parameters.lowThresholdHU,
                                         high: draft.parameters.highThresholdHU,
                                         twoLevel: draft.parameters.method == .growFromSeed)
                            .frame(height: 56)
                    }

                    if draft.parameters.method == .growFromSeed {
                        thresholdSlider("Seed ≥", value: bindHigh, range: range, unit: "HU")
                        thresholdSlider("Grow ≥", value: bindLow, range: range, unit: "HU")
                    } else {
                        thresholdSlider("Threshold ≥", value: bindThreshold, range: range, unit: "HU")
                    }

                    HStack {
                        Button { otsu() } label: { Label("Otsu", systemImage: "wand.and.stars") }
                            .buttonStyle(.glass)
                        Spacer()
                        Text("\(draft.previewVoxelCount) voxels")
                            .font(.lentisReadout).foregroundStyle(.secondary)
                    }
                    if draft.previewTruncated {
                        Label("Grow hit the safety cap — add a brain mask.", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }

                    options
                }

                HStack(spacing: Spacing.s) {
                    Button { model.commitActiveRegion() } label: { Label("Add Region", systemImage: "checkmark") }
                        .buttonStyle(.glassProminent)
                        .disabled(draft.previewVoxelCount == 0)
                    Button { model.cancelActiveRegion() } label: { Text("Cancel") }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Slab").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(model.calcSlabDepth) },
                                      set: { model.setActiveRegionSlabDepth(Int($0.rounded())) }),
                       in: 1...41)
                Text("\(model.calcSlabDepth)").font(.lentisReadout).foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
            HStack {
                Text("Min size").font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { draft.parameters.minVoxelCount },
                                       set: { draft.parameters.minVoxelCount = max(1, $0); model.updateActiveRegionPreview() }),
                        in: 1...500) {
                    Text("\(draft.parameters.minVoxelCount)").font(.lentisReadout)
                }
            }
            Picker("Connectivity", selection: Binding(
                get: { draft.parameters.connectivity },
                set: { draft.parameters.connectivity = $0; model.updateActiveRegionPreview() })) {
                Text("6").tag(Connectivity.six)
                Text("26").tag(Connectivity.twentySix)
            }
            .pickerStyle(.segmented)
            Toggle("Constrain to brain mask", isOn: Binding(
                get: { draft.parameters.constrainToBrainMask },
                set: { draft.parameters.constrainToBrainMask = $0; model.updateActiveRegionPreview() }))
                .font(.caption)
                .disabled(!model.hasBrainMask)
        }
    }

    // Threshold bindings re-run the preview on every change.
    private var bindThreshold: Binding<Double> {
        Binding(get: { draft.parameters.lowThresholdHU },
                set: { draft.parameters.lowThresholdHU = $0; draft.parameters.highThresholdHU = $0
                       model.updateActiveRegionPreview() })
    }
    private var bindLow: Binding<Double> {
        Binding(get: { draft.parameters.lowThresholdHU },
                set: { draft.parameters.lowThresholdHU = $0; model.updateActiveRegionPreview() })
    }
    private var bindHigh: Binding<Double> {
        Binding(get: { draft.parameters.highThresholdHU },
                set: { draft.parameters.highThresholdHU = $0; model.updateActiveRegionPreview() })
    }

    private var thresholdRange: ClosedRange<Double> {
        if let h = hist, h.maxHU > h.minHU { return h.minHU...h.maxHU }
        return -100...2000
    }

    private func thresholdSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue)) \(unit)").font(.lentisReadout).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func otsu() {
        guard let seg = model.makeSegmenter() else { return }
        let t = seg.otsuThreshold(in: draft.box, constrainToBrainMask: draft.parameters.constrainToBrainMask)
        if draft.parameters.method == .growFromSeed {
            draft.parameters.highThresholdHU = t
            draft.parameters.lowThresholdHU = max(thresholdRange.lowerBound, t - 100)
        } else {
            draft.parameters.lowThresholdHU = t
            draft.parameters.highThresholdHU = t
        }
        model.updateActiveRegionPreview()
    }
}

// MARK: - Region row

private struct RegionRow: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var region: CalcificationRegion

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button { region.isVisible.toggle(); model.refreshSegmentationRender() } label: {
                Image(systemName: region.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(region.isVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)

            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: $region.name)
                    .textFieldStyle(.plain)
                    .font(.callout)
                Text("\(region.method.shortName) · \(region.voxelCount) vox" +
                     (region.anatomicalName.map { " · \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, Spacing.xs)
        .background(model.activeRegionID == region.id ? Color.lentisAccent.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.chip))
        .contentShape(Rectangle())
        .onTapGesture { model.activeRegionID = region.id }
        .contextMenu {
            Button("Re-edit") { model.reEditRegion(region.id) }
            Button("Delete", role: .destructive) { model.deleteRegion(region.id) }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(.sRGB, red: region.color.x, green: region.color.y, blue: region.color.z, opacity: 1) },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .red
                region.color = SIMD3(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
                model.refreshSegmentationRender()
            })
    }
}

// MARK: - ROI histogram

private struct ROIHistogramView: View {
    let counts: [Int]
    let minHU: Double
    let maxHU: Double
    let low: Double
    let high: Double
    let twoLevel: Bool

    var body: some View {
        GeometryReader { geo in
            let maxCount = max(1, counts.max() ?? 1)
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    let n = max(1, counts.count)
                    let bw = size.width / CGFloat(n)
                    for (i, c) in counts.enumerated() {
                        let bh = CGFloat(c) / CGFloat(maxCount) * size.height
                        let rect = CGRect(x: CGFloat(i) * bw, y: size.height - bh, width: max(1, bw - 0.5), height: bh)
                        ctx.fill(Path(rect), with: .color(.secondary.opacity(0.55)))
                    }
                }
                marker(low, color: .lentisCrosshair, width: w, height: h)
                if twoLevel { marker(high, color: .lentisAccent, width: w, height: h) }
            }
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(.white.opacity(0.12)))
        }
    }

    @ViewBuilder
    private func marker(_ value: Double, color: Color, width: CGFloat, height: CGFloat) -> some View {
        if maxHU > minHU {
            let frac = max(0, min(1, (value - minHU) / (maxHU - minHU)))
            Rectangle().fill(color).frame(width: 1.5, height: height)
                .position(x: CGFloat(frac) * width, y: height / 2)
        }
    }
}
