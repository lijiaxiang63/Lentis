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
    // Observed so the "Saves to <dir>/" hint refreshes live when the output mode
    // / custom folder changes in the Settings window.
    @ObservedObject private var settings = AppSettings.shared
    @State private var exportError: String?

    var body: some View {
        // Conditional body — the empty state REPLACES the sections when no volume
        // is loaded, so they can't composite underneath it (the old `.overlay`
        // drew the unavailable view on top of the still-visible sections).
        Group {
            if model.segmentationVolume == nil {
                emptyState
            } else {
                loadedBody
            }
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil },
                                                     set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var loadedBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                statusStrip
                Divider().padding(.horizontal, Spacing.m)
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
    }

    // MARK: - Empty state

    /// Shown when no volume is loaded. Hand-built (a bare `ContentUnavailableView`
    /// renders flush-left and clashes with the inspector column) — a centered
    /// glyph + title + caption that reads as a calm "open a file to begin".
    private var emptyState: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: Spacing.xs) {
                Text("No Volume")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Open a brain CT to segment\nintracranial calcifications.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(Spacing.xl)
    }

    // MARK: - Status strip (Brain · Regions · Export at a glance)

    /// One status pill's content. All three pills are pure reads of existing
    /// published state — no new model state, no segmenter calls.
    private struct StatusCellModel {
        let glyph: String
        let tint: Color
        let title: String
        let value: String
    }

    /// Brain-mask pill: running → ready → needs-setup → none.
    private var brainStatus: StatusCellModel {
        if model.isRunningSynthSeg {
            return .init(glyph: "hourglass", tint: .lentisAccent, title: "Brain", value: "Working")
        }
        if let layer = model.brainMaskLayer {
            return .init(glyph: "checkmark.seal.fill", tint: .green, title: "Brain",
                         value: layer.kind == .atlas ? "Parcellation" : "Mask")
        }
        if !model.synthSegAvailable {
            return .init(glyph: "wrench.and.screwdriver.fill", tint: .orange, title: "Brain", value: "Set Up")
        }
        return .init(glyph: "brain.head.profile", tint: .secondary, title: "Brain", value: "None")
    }

    /// Regions pill: editing a draft → committed count + total volume → none.
    private var regionsStatus: StatusCellModel {
        if model.draftRegion != nil {
            return .init(glyph: "square.dashed.inset.filled", tint: .lentisAccent, title: "Regions", value: "Editing")
        }
        if model.hasSegmentation {
            let n = model.calcRegions.count
            let totalVox = model.calcRegions.reduce(0) { $0 + $1.voxelCount }
            let vol = model.physicalVolumeString(voxelCount: totalVox)
            return .init(glyph: "square.dashed.inset.filled", tint: .lentisAccent, title: "Regions",
                         value: vol.isEmpty ? "\(n)" : "\(n) · \(vol)")
        }
        return .init(glyph: "square.dashed", tint: .secondary, title: "Regions", value: "None")
    }

    /// Export pill: blocked by a draft → exported → ready (pending) → nothing.
    private var exportStatus: StatusCellModel {
        if model.draftRegion != nil {
            return .init(glyph: "exclamationmark.triangle.fill", tint: .orange, title: "Export", value: "Finish")
        }
        if model.hasExportedSegmentation {
            return .init(glyph: "checkmark.seal.fill", tint: .green, title: "Export", value: "Saved")
        }
        if model.hasSegmentation {
            return .init(glyph: "tray.and.arrow.down.fill", tint: .orange, title: "Export", value: "Pending")
        }
        return .init(glyph: "tray", tint: .secondary, title: "Export", value: "—")
    }

    private var statusStrip: some View {
        GlassEffectContainer(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                statusCell(brainStatus)
                statusCell(regionsStatus)
                statusCell(exportStatus)
            }
        }
        .padding(.horizontal, Spacing.m)
    }

    private func statusCell(_ s: StatusCellModel) -> some View {
        HStack(spacing: Spacing.xs) {
            // Fixed glyph slot so an icon swap (e.g. into the running hourglass)
            // can't resize the row.
            Image(systemName: s.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(s.tint)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.title)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(s.value)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(s.tint.opacity(0.14)), in: RoundedRectangle(cornerRadius: Radius.chip))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(s.title): \(s.value)")
    }

    // MARK: - Brain mask

    /// Visual state of the brain mask area, driving the status glyph + tint so the
    /// section reads at a glance (color + icon) before the caption is parsed.
    private enum BrainMaskState {
        case ready          // a mask is loaded
        case generating     // SynthSeg running
        case canGenerate    // SynthSeg available, no mask yet
        case needsSetup     // SynthSeg not found

        var systemImage: String {
            switch self {
            case .ready:       return "checkmark.circle.fill"
            case .generating:  return "hourglass"
            case .canGenerate: return "wand.and.stars"
            case .needsSetup:  return "wrench.and.screwdriver.fill"
            }
        }
        var tint: Color {
            switch self {
            case .ready:                    return .green
            case .generating, .canGenerate: return .lentisAccent
            case .needsSetup:               return .orange
            }
        }
    }

    private var brainMaskState: BrainMaskState {
        if model.brainMaskLayer != nil { return .ready }
        if model.isRunningSynthSeg { return .generating }
        return model.synthSegAvailable ? .canGenerate : .needsSetup
    }

    /// One-line caption beside the glyph. During a run it announces the generation
    /// (the detailed progress lives in `runningStrip`) rather than contradicting
    /// the hourglass with the idle "no mask" fallback.
    private var brainMaskStatusText: String {
        if model.isRunningSynthSeg { return "Generating brain mask…" }
        return model.brainMaskStatus.isEmpty
            ? "No brain mask — skull may be included."
            : model.brainMaskStatus
    }

    private var brainMaskSection: some View {
        InspectorSection(title: "Brain Mask") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if model.isRunningSynthSeg {
                    brainMaskStatusHeader
                    runningStrip
                } else if model.brainMaskLayer != nil {
                    // A mask is loaded — collapse to a compact done-summary that
                    // reclaims vertical space for the (tall) Active Region editor.
                    brainMaskDoneSummary
                } else {
                    // No mask yet — the full action cluster, framed as optional.
                    brainMaskStatusHeader
                    Text("Optional — improves accuracy by excluding skull.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    brainMaskActionCluster
                    if model.synthSegAvailable, !model.synthSegStatus.isEmpty {
                        Text(model.synthSegStatus)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                if !model.synthSegOutputFiles.isEmpty {
                    synthSegOutputRow
                }
            }
        }
    }

    /// Expressive status header: a tinted glass glyph + caption, so the current
    /// state reads by color + icon before the words are parsed.
    private var brainMaskStatusHeader: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: brainMaskState.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(brainMaskState.tint)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.tint(brainMaskState.tint.opacity(0.22)), in: Circle())

            Text(brainMaskStatusText)
                .font(.caption)
                .foregroundStyle(model.brainMaskLayer == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Compact "mask ready" row: green glyph + status + an overflow menu holding
    /// the now-secondary Load Existing / Clear actions (the big Generate hero is
    /// unnecessary once a mask exists).
    private var brainMaskDoneSummary: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.tint(Color.green.opacity(0.22)), in: Circle())

            Text(model.brainMaskStatus.isEmpty ? "Brain mask loaded" : model.brainMaskStatus)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button { loadBrainMaskPanel() } label: { Label("Load Existing…", systemImage: "square.dashed") }
                if model.synthSegAvailable {
                    Button { model.generateBrainMaskWithSynthSeg() } label: {
                        Label("Regenerate with SynthSeg", systemImage: "wand.and.stars")
                    }
                }
                Divider()
                Button(role: .destructive) { model.clearBrainMask() } label: { Label("Clear", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Brain mask actions")
            .accessibilityLabel("Brain mask actions")
        }
    }

    /// Action cluster for the no-mask state. Adjacent glass surfaces blend per the
    /// Liquid Glass guidance: Generate is the hero (.glassProminent), Load Existing
    /// the quiet secondary, or a Set-Up SettingsLink when SynthSeg isn't found.
    private var brainMaskActionCluster: some View {
        GlassEffectContainer(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if model.synthSegAvailable {
                    Button { model.generateBrainMaskWithSynthSeg() } label: {
                        Label("Generate with SynthSeg", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.segmentationVolume == nil)
                } else {
                    SettingsLink {
                        Label("Set Up FreeSurfer…", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Text("FreeSurfer SynthSeg not found. Point Lentis at your FreeSurfer install in Settings.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button { loadBrainMaskPanel() } label: {
                    Label("Load Existing…", systemImage: "square.dashed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(model.segmentationVolume == nil)
            }
        }
    }

    /// Active-run strip: progress + status + Cancel on a faint accent-tinted glass
    /// surface so the in-flight state reads as distinct from idle, with the
    /// "minutes, keep working" reassurance below.
    private var runningStrip: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text(model.synthSegStatus)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { model.cancelSynthSeg() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding(Spacing.s)
            .glassEffect(.regular.tint(Color.lentisAccent.opacity(0.18)),
                         in: RoundedRectangle(cornerRadius: Radius.chip))

            Text("Runs on the CPU — usually several minutes. You can keep working.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the most recent SynthSeg run wrote its files, as a tappable glass card
    /// that reveals the generated mask/label in Finder.
    private var synthSegOutputRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Divider().padding(.vertical, 2)
            Button { model.revealSynthSegOutputInFinder() } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.lentisAccent)
                    VStack(alignment: .leading, spacing: 1) {
                        let n = model.synthSegOutputFiles.count
                        Text("Saved \(n) file\(n == 1 ? "" : "s")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                        if let dir = model.synthSegOutputDirectory {
                            Text((dir.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(dir.path)
                        }
                    }
                    Spacer(minLength: Spacing.xs)
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.s)
                .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(),
                         in: RoundedRectangle(cornerRadius: Radius.chip))
            .help("Reveal the generated files in Finder")
            .accessibilityLabel("Show generated files in Finder")
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
                    Text("Choose a method, then drag a box on any plane to start. Threshold keeps high-HU voxels inside the box; Grow floods out from a box drawn inside the calcification.")
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
        VStack(alignment: .leading, spacing: Spacing.s) {
            InspectorSectionHeader(title: "Regions",
                                   trailing: model.calcRegions.isEmpty ? nil : "\(model.calcRegions.count)")
            VStack(alignment: .leading, spacing: 2) {
                if model.calcRegions.isEmpty {
                    Text("No regions yet — pick a method above, then drag a box on a slice.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.s)
                } else {
                    ForEach(model.calcRegions) { region in
                        RegionRow(model: model, region: region)
                    }
                    brushControls
                        .padding(.horizontal, Spacing.s)
                        .padding(.top, Spacing.xs)
                }
            }
            .padding(.horizontal, Spacing.xs)
        }
    }

    @ViewBuilder
    private var brushControls: some View {
        // Only meaningful once a region is committed and selected — the brush edits
        // a committed region's voxels, so hide it during a draft (where it no-ops).
        if model.activeRegionID != nil, model.draftRegion == nil {
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
                if !model.brushDiameterString(radius: model.calcBrushRadius).isEmpty {
                    Text(verbatim: "Diameter \(model.brushDiameterString(radius: model.calcBrushRadius))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        InspectorSection(title: "Export") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Button { export(kind: .binaryMask) } label: { Label("Export Mask", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.glass)
                    Button { export(kind: .atlas) } label: { Label("Export Atlas", systemImage: "square.and.arrow.down.on.square") }
                        .buttonStyle(.glass)
                }
                .disabled(!model.hasSegmentation || model.draftRegion != nil)

                if model.draftRegion != nil {
                    Label("Finish or cancel the active region to export.", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.hasExportedSegmentation {
                    exportedRevealCard
                } else if model.hasSegmentation {
                    Text("Saves to \(exportLocationHint)/ — change the folder & file suffixes in Settings.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Persistent post-export confirmation: a tappable green glass card that
    /// reveals the written file(s) in Finder (the transient success Toast still
    /// fires on export; this is the lasting "it's saved here" affordance).
    private var exportedRevealCard: some View {
        let urls = [model.exportedMaskURL, model.exportedAtlasURL].compactMap { $0 }
        let subtitle = urls.count == 1
            ? urls[0].lastPathComponent
            : "Mask + Atlas exported"
        return Button {
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Exported")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Spacing.xs)
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.s)
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Radius.chip))
        .help("Reveal the exported file in Finder")
        .accessibilityLabel("Show exported file in Finder")
    }

    /// Abbreviated directory exports will be written to (for the inline hint).
    /// Uses the non-mutating BIDS URL builder so merely showing the hint doesn't
    /// scaffold the `derivatives/lentis/` tree before an export actually happens.
    private var exportLocationHint: String {
        let dir: URL
        if let bids = model.bidsDerivativeURL(desc: "calc", suffix: "mask") {
            dir = bids.deletingLastPathComponent()
        } else {
            dir = AppSettings.resolveOutputDirectory(
                sourceFile: model.loadedFileURL,
                mode: settings.outputMode == .bidsDerivatives ? .besideSource : settings.outputMode,
                customDirectory: settings.customOutputDirectoryURL)
        }
        return (dir.lastPathComponent.isEmpty ? dir.path : dir.lastPathComponent)
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

    /// Direct (no-dialog) export to the configured output location, confirmed by
    /// a Liquid-Glass success banner. The destination + suffix come from Settings.
    private func export(kind: NiftiMaskKind) {
        do {
            let url = try model.exportSegmentation(kind: kind)
            model.presentToast(ViewerToast(
                title: kind == .binaryMask ? "Mask exported" : "Atlas exported",
                subtitle: url.lastPathComponent,
                fileURL: url))
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Active region editor

private struct ActiveRegionEditor: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var draft: CalcificationRegion

    /// Fixed HU range for the Method-B grow boundary ("Grow ≥") slider, tuned at
    /// 0.1-HU precision regardless of the image histogram.
    static let growThresholdRange = SegmentationParameters.growBoundaryHURange

    private var hist: (counts: [Int], minHU: Double, maxHU: Double)? {
        guard !draft.box.isEmpty, let seg = model.makeSegmenter() else { return nil }
        return seg.histogram(in: draft.box, bins: 48, constrainToBrainMask: draft.parameters.constrainToBrainMask)
    }

    /// Thresholds are calibrated values; label them "HU" only for CT.
    private var unitLabel: String { model.effectiveModality == .ct ? "HU" : "Intensity" }

    /// Warn when the series isn't CT — the HU thresholds/bands don't apply.
    private var modalityAdvisory: String? {
        model.effectiveModality == .ct ? nil
            : "Thresholds assume CT Hounsfield units; this series reads as MRI/Intensity."
    }

    var body: some View {
        InspectorSection(title: "Active Region") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                // Full-width segmented control with no inline label — in the
                // narrow inspector the "Method" label competed with the two long
                // segment titles and got squeezed ("Metho/d"). The titles are
                // self-descriptive and the caption below names the chosen method;
                // `.labelsHidden()` keeps "Method" as the VoiceOver label.
                Picker("Method", selection: Binding(
                    get: { draft.parameters.method },
                    set: { model.setActiveRegionMethod($0) })) {
                    ForEach(SegmentationMethod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Always-visible explanation of what the chosen method expects of
                // the box — Method B in particular requires a box drawn ENTIRELY
                // inside the calcification (its mean HU seeds the grow).
                Text(verbatim: draft.parameters.method == .growFromSeed
                     ? "Draw the box ENTIRELY inside the calcification — its mean HU sets the seed, then the region grows out to the boundary HU (past the box)."
                     : "Draw the box loosely around the calcification — voxels at/above the threshold inside the box are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let advisory = modalityAdvisory {
                    Label(advisory, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if draft.box.isEmpty {
                    Text("Tip: drag on any plane to draw; drag the box's handles on another plane to set its depth.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if let h = hist {
                        ROIHistogramView(counts: h.counts, minHU: h.minHU, maxHU: h.maxHU,
                                         low: draft.parameters.lowThresholdHU,
                                         high: draft.parameters.highThresholdHU,
                                         twoLevel: draft.parameters.method == .growFromSeed)
                            .frame(height: 56)
                    }

                    if draft.parameters.method == .growFromSeed {
                        thresholdSlider("Seed ≥", value: bindHigh, range: seedRange, unit: unitLabel)
                        thresholdSlider("Grow ≥", value: bindLow, range: Self.growThresholdRange, unit: unitLabel, decimals: 1)
                        growReach
                    } else {
                        thresholdSlider("Threshold ≥", value: bindThreshold,
                                        range: SegmentationParameters.thresholdHURange, unit: unitLabel, decimals: 1)
                    }

                    HStack {
                        Button { autoSeed() } label: {
                            Label(draft.parameters.method == .growFromSeed ? "Mean" : "Otsu",
                                  systemImage: "wand.and.stars")
                        }
                            .buttonStyle(.glass)
                            .help(draft.parameters.method == .growFromSeed
                                  ? "Re-center the seed on the box's mean HU"
                                  : "Auto-pick the threshold (Otsu) over the box")
                        Spacer()
                        Text(verbatim: model.regionSizeString(voxelCount: draft.previewVoxelCount))
                            .font(.lentisReadout).foregroundStyle(.secondary)
                    }
                    if draft.previewTruncated {
                        Label("Grow hit the safety cap — add a brain mask or lower the reach.", systemImage: "exclamationmark.triangle")
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
            // A faint accent-tinted glass surface marks the editor as the live
            // in-progress region, echoing the status strip's "Regions · Editing".
            .padding(Spacing.s)
            .glassEffect(.regular.tint(Color.lentisAccent.opacity(0.10)),
                         in: RoundedRectangle(cornerRadius: Radius.card))
        }
    }

    // How far the grow may reach past the ROI box (Method B). A continuous
    // slider (no `step:` — a stepped slider lays out one tick label per step,
    // which is the documented SwiftUI layout trap) plus an Unlimited toggle that
    // floods the whole volume. Bounded by the brain mask when one constrains it.
    @ViewBuilder private var growReach: some View {
        let masked = draft.parameters.constrainToBrainMask && model.hasBrainMask
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle("Unlimited grow", isOn: Binding(
                get: { draft.parameters.growMarginVoxels == nil },
                set: { draft.parameters.growMarginVoxels = $0 ? nil
                            : CalcificationSegmenter.defaultGrowMarginVoxels
                       model.updateActiveRegionPreview() }))
                .font(.caption)
                .disabled(masked)
            if draft.parameters.growMarginVoxels != nil {
                HStack {
                    Text("Reach").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(draft.parameters.growMarginVoxels
                                      ?? CalcificationSegmenter.defaultGrowMarginVoxels) },
                        set: { draft.parameters.growMarginVoxels = max(1, Int($0.rounded()))
                               model.updateActiveRegionPreview() }),
                        in: 1...256)
                        .disabled(masked)
                    Text("\(draft.parameters.growMarginVoxels ?? 0) vox")
                        .font(.lentisReadout).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
            if masked {
                Text("Reach is bounded by the brain mask while it constrains the grow.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Min size").font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { draft.parameters.minVoxelCount },
                                       set: { draft.parameters.minVoxelCount = max(1, $0); model.updateActiveRegionPreview() }),
                        in: 1...500) {
                    Text("\(draft.parameters.minVoxelCount)").font(.lentisReadout)
                }
            }
            // Label-left + compact control-right (matching the Min-size row) so
            // the "Connectivity" label isn't squeezed by an inline segmented label.
            HStack {
                Text("Connectivity").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: Spacing.s)
                Picker("Connectivity", selection: Binding(
                    get: { draft.parameters.connectivity },
                    set: { draft.parameters.connectivity = $0; model.updateActiveRegionPreview() })) {
                    Text("6").tag(Connectivity.six)
                    Text("26").tag(Connectivity.twentySix)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Constrain to brain mask", isOn: Binding(
                get: { draft.parameters.constrainToBrainMask },
                set: { draft.parameters.constrainToBrainMask = $0; model.updateActiveRegionPreview() }))
                .font(.caption)
                .disabled(!model.hasBrainMask)
        }
    }

    // Threshold bindings re-run the preview on every change.
    private var bindThreshold: Binding<Double> {
        // Snap to 0.1 HU so Method A's threshold carries one decimal place.
        Binding(get: { draft.parameters.lowThresholdHU },
                set: { let v = ($0 * 10).rounded() / 10
                       draft.parameters.lowThresholdHU = v; draft.parameters.highThresholdHU = v
                       model.updateActiveRegionPreview() })
    }
    private var bindLow: Binding<Double> {
        // Snap to 0.1 HU so the grow boundary carries one decimal place.
        Binding(get: { draft.parameters.lowThresholdHU },
                set: { draft.parameters.lowThresholdHU = ($0 * 10).rounded() / 10
                       model.updateActiveRegionPreview() })
    }
    private var bindHigh: Binding<Double> {
        Binding(get: { draft.parameters.highThresholdHU },
                set: { draft.parameters.highThresholdHU = $0; model.updateActiveRegionPreview() })
    }

    /// "Seed ≥" range for Method B: the box's mean HU ± 20, since the box is
    /// confirmed calcification. Anchored to the stable stored mean (not the live
    /// slider value) so dragging doesn't drift the range under the thumb.
    private var seedRange: ClosedRange<Double> {
        let center = draft.seedMeanHU ?? draft.parameters.highThresholdHU
        return (center - 20)...(center + 20)
    }

    private func thresholdSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                                 unit: String, decimals: Int = 0) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(String(format: "%.\(decimals)f", value.wrappedValue)) \(unit)")
                .font(.lentisReadout).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func autoSeed() {
        guard let seg = model.makeSegmenter(), !draft.box.isEmpty else { return }
        if draft.parameters.method == .growFromSeed {
            // The box is confirmed calcification → re-center the seed on its mean
            // HU (the mean±20 slider re-centers with it). The grow boundary stays
            // under the user's control in its fixed 40–80 HU range.
            let mean = seg.meanHU(in: draft.box, constrainToBrainMask: draft.parameters.constrainToBrainMask)
            draft.seedMeanHU = mean
            draft.parameters.highThresholdHU = mean
        } else {
            // Clamp Otsu into the fixed 40–100 HU band so the slider stays valid.
            let r = SegmentationParameters.thresholdHURange
            let t = min(max(seg.otsuThreshold(in: draft.box, constrainToBrainMask: draft.parameters.constrainToBrainMask),
                            r.lowerBound), r.upperBound)
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

    private var isSelected: Bool { model.activeRegionID == region.id }

    private var regionColor: Color {
        Color(.sRGB, red: region.color.x, green: region.color.y, blue: region.color.z, opacity: 1)
    }

    /// Size (+ anatomical name); the method now reads as a trailing badge.
    private var subtitle: String {
        var s = model.regionSizeString(voxelCount: region.voxelCount)
        if let a = region.anatomicalName { s += " · \(a)" }
        return s
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button {
                region.isVisible.toggle()
                model.refreshSegmentationRender()
            } label: {
                Image(systemName: region.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(region.isVisible ? .primary : .tertiary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(region.isVisible ? "Hide Region" : "Show Region")
            .accessibilityLabel(region.isVisible ? "Hide \(region.name)" : "Show \(region.name)")

            // Compact circular color swatch. The native color well sits invisibly
            // behind an opaque circle (which ignores hits), so clicking the dot
            // still opens the system color panel — without the bulky rounded-rect
            // well crowding the name.
            ZStack {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .opacity(0.02)
                Circle()
                    .fill(regionColor)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                    .allowsHitTesting(false)
            }
            .frame(width: 15, height: 15)
            .help("Change region color")

            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: $region.name)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    // The name is serialized into the atlas LUT/dseg sidecar, so a
                    // rename makes a prior atlas export stale (the mask has no
                    // metadata and stays valid).
                    .onChange(of: region.name) { model.invalidateAtlasExport() }
                Text(verbatim: subtitle)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, 2)

            Spacer(minLength: Spacing.xs)

            // Method badge (THRESHOLD / GROW) — mirrors the Layers tab's kind
            // badge, so a region's method is scannable without reading the subtitle.
            Text(region.method.shortName.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .fixedSize()
                .accessibilityLabel("Method \(region.method.shortName)")

            // Visible Edit/Delete affordance (the right-click contextMenu below is
            // kept as a power-user shortcut). Disabled while a draft is in flight
            // so the user finishes/cancels it before touching committed regions.
            Menu {
                Button { model.reEditRegion(region.id) } label: { Label("Re-edit", systemImage: "pencil") }
                Button(role: .destructive) { model.deleteRegion(region.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.draftRegion != nil)
            .help("Re-edit or delete this region")
            .accessibilityLabel("Region actions")
        }
        // Dim a hidden region's row so its state is obvious in the list (matches
        // the Layers tab); the eye/menu stay clickable (opacity ≠ disabled).
        .opacity(region.isVisible ? 1 : 0.5)
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .background {
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(isSelected ? Color.lentisAccent.opacity(0.18) : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .strokeBorder(Color.lentisAccent.opacity(isSelected ? 0.55 : 0), lineWidth: 1)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectRegion(region.id) }
        .contextMenu {
            // Gated like the ellipsis menu: editing/deleting a committed region
            // while a draft preview (label 255) overlaps it would orphan voxels
            // that clearPreview later restores with no owning region.
            Button("Re-edit") { model.reEditRegion(region.id) }
                .disabled(model.draftRegion != nil)
            Button("Delete", role: .destructive) { model.deleteRegion(region.id) }
                .disabled(model.draftRegion != nil)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { regionColor },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .red
                region.color = SIMD3(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
                model.refreshSegmentationRender()
                // The color is serialized into the atlas LUT/dseg sidecar, so a
                // recolor makes a prior atlas export stale.
                model.invalidateAtlasExport()
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
                // Threshold value(s) above their markers, so the line is readable
                // against the HU axis without guessing.
                markerValue(low, color: .lentisCrosshair, width: w, height: h)
                if twoLevel { markerValue(high, color: .lentisAccent, width: w, height: h) }
                // HU axis end ticks (min / max of the in-box distribution).
                axisTick(Int(minHU.rounded()), x: 13, width: w, height: h)
                axisTick(Int(maxHU.rounded()), x: w - 15, width: w, height: h)
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

    @ViewBuilder
    private func markerValue(_ value: Double, color: Color, width: CGFloat, height: CGFloat) -> some View {
        if maxHU > minHU {
            let frac = max(0, min(1, (value - minHU) / (maxHU - minHU)))
            let x = max(16, min(width - 16, CGFloat(frac) * width))
            Text(verbatim: "\(Int(value.rounded()))")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 2).padding(.vertical, 0.5)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 2))
                .position(x: x, y: 7)
        }
    }

    @ViewBuilder
    private func axisTick(_ value: Int, x: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Text(verbatim: "\(value)")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .position(x: x, y: height - 6)
    }
}
