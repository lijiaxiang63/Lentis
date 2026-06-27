// CloseFileTests.swift
// Lentis Tests
//
// File → Close (⌘W) and drag-to-replace-with-confirmation:
//   • closeCurrentFile() returns the viewer to the empty launch state.
//   • hasUnsavedWork reflects regions, drafts, layers, and brain masks.
//   • requestClose / requestLoad gate on the confirmReplaceOnDiscard preference
//     (injectable via confirmReplaceOnDiscardOverride so tests don't mutate the
//     process-wide AppSettings.shared singleton).
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class CloseFileTests: XCTestCase {

    // MARK: - Fixtures

    /// A minimal CT volume registered as the loaded NIfTI series, with the
    /// model's niftiDataset/fileName populated so closeCurrentFile has something
    /// to clear. Mirrors SegmentationModelTests.makeModel plus the NIfTI
    /// metadata that load() would set. Builds the NIfTI in-memory via the
    /// shared `buildNifti` fixture (from NiftiReaderTests.swift) — no file I/O,
    /// and `buildNifti`/`read` can't fail for a valid spec so `try!` is safe.
    private func makeLoadedModel() -> (ViewerModel, VolumeData) {
        let count = 8 * 8 * 4
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
        for i in 0..<count { buf[i] = 40 }
        let vol = VolumeData(
            voxels: buf, width: 8, height: 8, depth: 4,
            spacingX: 1, spacingY: 1, spacingZ: 1,
            origin: SIMD3(0, 0, 0),
            rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
            rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "close-test")
        let img = try! NiftiImage.read(data: buildNifti(
            NiftiSpec(nx: 8, ny: 8, nz: 4, datatype: 4, bitpix: 16),
            voxels: [Float](repeating: 40, count: 8 * 8 * 4)))
        let ds = NiftiDataset(image: img, seriesID: "close-test", displayName: "close-test")
        let model = ViewerModel()
        let idx = model.registerStandaloneVolume(vol, cacheKey: "close-test", description: "close-test")
        model.niftiSeriesIndex = idx
        model.niftiDataset = ds
        model.loadedFileName = "close-test.nii.gz"
        model.loadedFileURL = URL(fileURLWithPath: "/tmp/close-test.nii.gz")
        model.panels = [PanelState()]
        model.layout = .single
        return (model, vol)
    }

    private func makeRegion(label: UInt8 = 1) -> CalcificationRegion {
        CalcificationRegion(
            label: label, name: "R", color: SIMD3(1, 0, 0),
            parameters: .defaults(for: .thresholdInROI),
            box: VoxelBox(xRange: 1..<3, yRange: 1..<3, zRange: 1..<3))
    }

    private func makeMaskLayer() -> OverlayLayer {
        OverlayLayer(
            sourceURL: URL(fileURLWithPath: "/tmp/mask.nii"),
            name: "Mask", kind: .mask,
            volume: OverlayLayerVolume(
                width: 1, height: 1, depth: 1,
                voxelToWorldMatrix: matrix_identity_double4x4,
                storage: .uint8([1]), labelCounts: [1: 1]))
    }

    // MARK: - closeCurrentFile

    func testCloseClearsAllLoadedState() {
        let (model, _) = makeLoadedModel()
        // Add an unsaved region + a layer so we exercise the full clear path.
        model.calcRegions = [makeRegion()]
        model.layerStore.add(makeMaskLayer())
        model.seriesStates["close-test"] = .init()
        XCTAssertFalse(model.allSeries.isEmpty)
        XCTAssertFalse(model.panels.isEmpty)
        XCTAssertNotNil(model.niftiDataset)

        model.closeCurrentFile()

        XCTAssertTrue(model.allSeries.isEmpty, "allSeries cleared")
        XCTAssertTrue(model.panels.isEmpty, "panels cleared → empty state")
        XCTAssertEqual(model.loadedFileName, "", "file name cleared")
        XCTAssertNil(model.loadedFileURL)
        XCTAssertNil(model.niftiDataset, "dataset cleared")
        XCTAssertNil(model.dataset)
        XCTAssertEqual(model.niftiSeriesIndex, -1)
        XCTAssertEqual(model.currentTimepoint, 0)
        XCTAssertNil(model.modalityOverride)
        XCTAssertNil(model.crosshairWorld)
        XCTAssertTrue(model.calcRegions.isEmpty, "regions cleared")
        XCTAssertNil(model.draftRegion)
        XCTAssertTrue(model.layerStore.layers.isEmpty, "layers cleared")
        XCTAssertNil(model.brainMaskLayer)
        XCTAssertTrue(model.seriesStates.isEmpty, "seriesStates cleared")
        XCTAssertEqual(model.layout, .single)
        XCTAssertFalse(model.isMPRLayout)
        XCTAssertFalse(model.showLayerInspector)
    }

    func testCloseIsIdempotentOnEmptyState() {
        let model = ViewerModel()
        // Closing with nothing open is a no-op (the menu item is disabled, but
        // the method itself must not crash or leave inconsistent state).
        model.closeCurrentFile()
        XCTAssertTrue(model.allSeries.isEmpty)
        XCTAssertTrue(model.panels.isEmpty)
        XCTAssertEqual(model.loadedFileName, "")
    }

    func testCloseReleasesVolumeCache() {
        let (model, _) = makeLoadedModel()
        XCTAssertNotNil(model.cachedVolume(forSeriesIndex: model.niftiSeriesIndex))
        model.closeCurrentFile()
        // The cache is cleared and the series index is invalid, so a lookup
        // returns nil rather than a stale volume from a previous session.
        XCTAssertNil(model.cachedVolume(forSeriesIndex: 0))
    }

    // MARK: - hasUnsavedWork

    func testHasUnsavedWorkFalseOnFreshModel() {
        let model = ViewerModel()
        XCTAssertFalse(model.hasUnsavedWork)
    }

    func testHasUnsavedWorkTrueForCommittedRegion() {
        let (model, _) = makeLoadedModel()
        model.calcRegions = [makeRegion()]
        XCTAssertTrue(model.hasUnsavedWork)
    }

    func testHasUnsavedWorkTrueForDraftRegion() {
        let (model, _) = makeLoadedModel()
        model.draftRegion = makeRegion(label: 255)
        XCTAssertTrue(model.hasUnsavedWork)
    }

    func testHasUnsavedWorkTrueForExternalLayer() {
        let (model, _) = makeLoadedModel()
        model.layerStore.add(makeMaskLayer())
        XCTAssertTrue(model.hasUnsavedWork)
    }

    // MARK: - requestClose confirmation gating

    func testRequestCloseSilentWhenPreferenceOff() {
        let (model, _) = makeLoadedModel()
        model.calcRegions = [makeRegion()]
        model.confirmReplaceOnDiscardOverride = false
        model.requestClose()
        XCTAssertNil(model.pendingConfirmation, "no prompt when preference off")
        XCTAssertTrue(model.allSeries.isEmpty, "closed immediately")
    }

    func testRequestClosePromptsWhenUnsavedWorkAndPreferenceOn() {
        let (model, _) = makeLoadedModel()
        model.calcRegions = [makeRegion()]
        model.confirmReplaceOnDiscardOverride = true
        model.requestClose()
        let pending = try? XCTUnwrap(model.pendingConfirmation)
        XCTAssertEqual(pending?.kind, .close)
        XCTAssertEqual(pending?.actionLabel, "Close")
        XCTAssertFalse(model.allSeries.isEmpty, "not closed yet — awaiting confirmation")
    }

    func testRequestCloseNoPromptWhenNoUnsavedWork() {
        let (model, _) = makeLoadedModel()
        // No regions / drafts / layers.
        model.confirmReplaceOnDiscardOverride = true
        model.requestClose()
        XCTAssertNil(model.pendingConfirmation, "nothing to discard → close immediately")
        XCTAssertTrue(model.allSeries.isEmpty)
    }

    func testRequestCloseNoPromptWhenNothingOpen() {
        let model = ViewerModel()
        model.confirmReplaceOnDiscardOverride = true
        model.requestClose()
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertTrue(model.allSeries.isEmpty)
    }

    func testPerformPendingConfirmationCloses() {
        let (model, _) = makeLoadedModel()
        model.calcRegions = [makeRegion()]
        model.confirmReplaceOnDiscardOverride = true
        model.requestClose()
        XCTAssertNotNil(model.pendingConfirmation)
        model.performPendingConfirmation()
        XCTAssertNil(model.pendingConfirmation, "pending cleared after perform")
        XCTAssertTrue(model.allSeries.isEmpty, "closed by the confirmed action")
    }

    func testCancelPendingConfirmationKeepsState() {
        let (model, _) = makeLoadedModel()
        model.calcRegions = [makeRegion()]
        model.confirmReplaceOnDiscardOverride = true
        model.requestClose()
        XCTAssertNotNil(model.pendingConfirmation)
        model.cancelPendingConfirmation()
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertFalse(model.allSeries.isEmpty, "state preserved on cancel")
        XCTAssertEqual(model.calcRegions.count, 1, "region preserved on cancel")
    }

    // MARK: - requestLoad confirmation gating

    func testRequestLoadPromptsWhenReplacingWithUnsavedWork() {
        let (model, _) = makeLoadedModel()
        model.calcRegions = [makeRegion()]
        model.confirmReplaceOnDiscardOverride = true
        model.requestLoad(url: URL(fileURLWithPath: "/tmp/lentis-close-test-replacement.nii.gz"))
        let pending = try? XCTUnwrap(model.pendingConfirmation)
        XCTAssertEqual(pending?.kind, .replace)
        XCTAssertEqual(pending?.actionLabel, "Replace")
        XCTAssertFalse(model.allSeries.isEmpty, "not replaced yet — awaiting confirmation")
    }

    func testRequestLoadSilentWhenNoPriorFile() {
        let model = ViewerModel()
        model.confirmReplaceOnDiscardOverride = true
        // No file open → no confirmation even with the preference on.
        model.requestLoad(url: URL(fileURLWithPath: "/tmp/lentis-close-test-replacement.nii.gz"))
        XCTAssertNil(model.pendingConfirmation)
    }

    func testRequestLoadSilentWhenPreferenceOff() {
        let (model, _) = makeLoadedModel()
        model.calcRegions = [makeRegion()]
        model.confirmReplaceOnDiscardOverride = false
        model.requestLoad(url: URL(fileURLWithPath: "/tmp/lentis-close-test-replacement.nii.gz"))
        XCTAssertNil(model.pendingConfirmation, "no prompt when preference off")
        // load() runs async off-main; don't assert final state here, just that
        // no confirmation was requested.
    }
}
