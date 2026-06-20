// WindowLevelTests.swift
// Lentis
//
// Tests for modality-aware window/level: the CT HU preset table, HU→stored
// conversion, and the per-panel seeding that fixes the dark quad-MPR layout
// (panels used to fall back to a generic 2000/500 window). Reuses the NIfTI
// fixture builder (buildNifti / NiftiSpec) from NiftiReaderTests.swift.

import Foundation
import Testing
@testable import Lentis

// MARK: - Fixtures

private func makeCTDataset(seriesID: String = "ct") throws -> NiftiDataset {
    let nx = 8, ny = 8, nz = 8
    var vox = [Float](repeating: -1000, count: nx * ny * nz)                                   // air
    for z in 3..<5 { for y in 0..<ny { for x in 0..<nx { vox[x + nx * (y + ny * z)] = 40 } } }  // tissue
    for z in 3..<5 { for y in 3..<5 { for x in 3..<5 { vox[x + nx * (y + ny * z)] = 400 } } }   // calcification
    let img = try NiftiImage.read(data: buildNifti(NiftiSpec(nx: nx, ny: ny, nz: nz, datatype: 4, bitpix: 16), voxels: vox))
    return NiftiDataset(image: img, seriesID: seriesID, displayName: seriesID)
}

private func makeMRIDataset(seriesID: String = "mr") throws -> NiftiDataset {
    let nx = 8, ny = 8, nz = 8
    var vox = [Float](repeating: 0, count: nx * ny * nz)
    for i in 0..<vox.count { vox[i] = Float(i % 1000) }            // 0…999, non-negative ⇒ MRI
    let img = try NiftiImage.read(data: buildNifti(NiftiSpec(nx: nx, ny: ny, nz: nz, datatype: 16, bitpix: 32), voxels: vox))
    return NiftiDataset(image: img, seriesID: seriesID, displayName: seriesID)
}

/// Install a dataset as the model's active NIfTI series (mirrors applyNiftiDataset's caching).
@discardableResult
private func installNifti(_ ds: NiftiDataset, into model: ViewerModel) -> Int {
    let vol = ds.makeVolume(timepoint: 0)
    model.niftiDataset = ds
    let idx = model.registerStandaloneVolume(vol, cacheKey: ds.seriesID, description: ds.displayName)
    model.niftiSeriesIndex = idx
    return idx
}

// MARK: - Preset table + HU→stored conversion (pure)

@Test
func ctPresetTableHasBrainDefault() {
    #expect(WindowPreset.defaultCT.name == "Brain")
    #expect(WindowPreset.defaultCT.width == 80 && WindowPreset.defaultCT.center == 40)
    #expect(WindowPreset.defaultCT.low == 0 && WindowPreset.defaultCT.high == 80)   // brief's (0, 80)
    #expect(WindowPreset.ctPresets.contains { $0.name == "Bone" })
    #expect(WindowPreset.ctPresets.contains { $0.name == "Subdural" })
}

@Test
func storedWindowIsIdentityForDirectHU() {
    let (w, c) = WindowPreset.defaultCT.storedWindow(slope: 1, intercept: 0)
    #expect(w == 80 && c == 40)
}

@Test
func storedWindowScalesForQuantizedCT() {
    // stored = (HU − intercept) / slope ⇒ slope 2, intercept −1000:
    //   width 80 → 40;  center 40 → (40 + 1000)/2 = 520
    let (w, c) = WindowPreset.defaultCT.storedWindow(slope: 2, intercept: -1000)
    #expect(abs(w - 40) < 1e-9 && abs(c - 520) < 1e-9)
}

// MARK: - Modality-aware seeding (model)

@Test
func ctSeriesSeedsBrainPresetInStoredUnits() throws {
    let model = ViewerModel()
    let ds = try makeCTDataset()
    let idx = installNifti(ds, into: model)
    #expect(ds.detectedModality == .ct)
    let w = try #require(model.modalityDefaultWindow(forSeriesIndex: idx))
    // Direct-HU CT ⇒ the Brain preset maps 1:1 onto stored units.
    #expect(abs(w.ww - 80) < 0.5 && abs(w.wc - 40) < 0.5)
}

@Test
func mriSeriesSeedsPercentileWindow() throws {
    let model = ViewerModel()
    let ds = try makeMRIDataset()
    let idx = installNifti(ds, into: model)
    #expect(ds.detectedModality == .mri)
    let w = try #require(model.modalityDefaultWindow(forSeriesIndex: idx))
    let (low, high) = ds.suggestedWindow
    #expect(abs(w.ww - max(high - low, 1)) < 1e-6)
    #expect(abs(w.wc - (high + low) / 2) < 1e-6)
}

@Test
func seededWindowPrefersSavedManualWindow() throws {
    let model = ViewerModel()
    let ds = try makeCTDataset()
    let idx = installNifti(ds, into: model)
    var st = ViewerModel.SeriesViewState()
    st.windowWidth = 1234
    st.windowCenter = 567
    model.seriesStates[ds.seriesID] = st
    let w = try #require(model.seededWindow(forSeriesIndex: idx))
    #expect(w.ww == 1234 && w.wc == 567)   // respects a prior manual drag over the preset
}

@Test
func assignSeriesToPanelSeedsNonZeroWindow() throws {
    // Regression guard for the dark quad-MPR bug: assigning a NIfTI series to a
    // panel must seed a non-zero, modality-appropriate W/L (not reset to 0, which
    // sent loadMPRSlice to its generic 2000/500 fallback).
    let model = ViewerModel()
    let ds = try makeCTDataset()
    let idx = installNifti(ds, into: model)
    let panel = model.panels[0]
    model.assignSeriesToPanel(panel, seriesIndex: idx)
    #expect(panel.windowWidth > 0)
    #expect(abs(panel.windowWidth - 80) < 0.5 && abs(panel.windowCenter - 40) < 0.5)
}

@Test
func applyWindowPresetAppliesToAllNiftiPanels() throws {
    // A preset chosen in one panel's toolbar syncs every panel showing the
    // series, so the ortho views share one window.
    let model = ViewerModel()
    let ds = try makeCTDataset()
    let idx = installNifti(ds, into: model)
    let p0 = PanelState(); p0.seriesIndex = idx
    let p1 = PanelState(); p1.seriesIndex = idx
    model.panels = [p0, p1]

    let subdural = try #require(WindowPreset.ctPresets.first { $0.name == "Subdural" })
    model.applyWindowPreset(subdural)
    #expect(abs(p0.windowWidth - 215) < 0.5 && abs(p0.windowCenter - 75) < 0.5)
    #expect(abs(p1.windowWidth - 215) < 0.5 && abs(p1.windowCenter - 75) < 0.5)
}

@Test
func applyModalityAutoWindowResetsCTToBrain() throws {
    let model = ViewerModel()
    let ds = try makeCTDataset()
    let idx = installNifti(ds, into: model)
    let panel = PanelState(); panel.seriesIndex = idx
    model.panels = [panel]
    panel.windowWidth = 4000; panel.windowCenter = 1000   // user dragged away

    model.applyModalityAutoWindow()
    #expect(abs(panel.windowWidth - 80) < 0.5 && abs(panel.windowCenter - 40) < 0.5)
}

@Test
func modalityOverrideReseedsWindow() throws {
    // Toggling CT→MRI swaps the seeded window from the Brain preset to the MRI
    // percentile window across all panels showing the series.
    let model = ViewerModel()
    let ds = try makeCTDataset()
    let idx = installNifti(ds, into: model)
    let panel = model.panels[0]
    model.assignSeriesToPanel(panel, seriesIndex: idx)
    #expect(abs(panel.windowWidth - 80) < 0.5)        // Brain (CT)

    model.setModalityOverride(.mri)
    let (low, high) = ds.suggestedWindow
    #expect(abs(panel.windowWidth - max(high - low, 1)) < 1e-6)   // now MRI percentile
}
