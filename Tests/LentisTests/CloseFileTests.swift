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

    func testImagePanelFileDropRoutesThroughReplaceConfirmation() {
        let (model, _) = makeLoadedModel()
        model.calcRegions = [makeRegion()]
        model.confirmReplaceOnDiscardOverride = true

        PanelInteractiveImageView.PanelImageInteractView.handleDroppedFileURL(
            URL(fileURLWithPath: "/tmp/lentis-panel-drop-replacement.nii.gz"),
            model: model)

        let exp = expectation(description: "panel drop routed on main")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(model.pendingConfirmation?.kind, .replace)
        XCTAssertEqual(model.pendingConfirmation?.actionLabel, "Replace")
        XCTAssertFalse(model.allSeries.isEmpty, "drop must not replace until confirmed")
    }

    // MARK: - Race: close must not be undone by an in-flight NIfTI load (P1)

    /// Write a small uncompressed `.nii` to a temp file and return its URL.
    /// `loadNifti` reads from disk via `NiftiImage.read(contentsOf:)`, which
    /// handles both `.nii` and `.nii.gz`.
    private func writeTempNifti() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-close-race-\(UUID().uuidString).nii")
        let data = buildNifti(
            NiftiSpec(nx: 4, ny: 4, nz: 2, datatype: 4, bitpix: 16),
            voxels: [Float](repeating: 40, count: 4 * 4 * 2))
        try data.write(to: url)
        return url
    }

    /// Close while a NIfTI decode is in flight must win: the background decode's
    /// main-thread `applyNiftiDataset` completion runs AFTER close (close is
    /// synchronous on main; the completion is queued onto main), so the load-
    /// generation guard discards it and the viewer stays empty.
    func testCloseDuringInFlightLoadDoesNotReopen() throws {
        let url = try writeTempNifti()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = ViewerModel()
        model.loadNifti(url: url)        // kicks off background decode
        XCTAssertTrue(model.isLoading, "load started")
        model.closeCurrentFile()          // supersede it on the main queue

        // Drain the main run loop so the background completion (queued onto main)
        // lands. The generation guard must discard it.
        let exp = expectation(description: "in-flight load settled")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertNil(model.niftiDataset, "stale load discarded — viewer stays empty")
        XCTAssertEqual(model.loadedFileName, "")
        XCTAssertTrue(model.allSeries.isEmpty)
        XCTAssertFalse(model.isLoading, "close reset isLoading; stale load didn't clobber it")
    }

    /// Sanity check: without a superseding close, the load DOES apply (proves the
    /// test fixture is valid and the guard isn't just always-aborting).
    func testLoadAppliesWhenNotSuperseded() throws {
        let url = try writeTempNifti()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = ViewerModel()
        model.loadNifti(url: url)

        // Poll until the background decode + main apply lands.
        let deadline = Date().addingTimeInterval(5)
        while model.niftiDataset == nil && model.errorMessage == nil && Date() < deadline {
            let exp = expectation(description: "load apply")
            DispatchQueue.main.async { exp.fulfill() }
            wait(for: [exp], timeout: 1.0)
        }
        XCTAssertNotNil(model.niftiDataset, "load applied when not superseded")
        XCTAssertFalse(model.allSeries.isEmpty)
    }

    // MARK: - Race: close must cancel an in-flight layer import (P2)

    /// Write a small same-grid mask NIfTI (single nonzero label) to a temp file.
    private func writeTempMaskNifti(matchingWidth w: Int, height h: Int, depth d: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-close-mask-\(UUID().uuidString).nii")
        var vox = [Float](repeating: 0, count: w * h * d)
        if !vox.isEmpty { vox[0] = 1 }
        let data = buildNifti(
            NiftiSpec(nx: w, ny: h, nz: d, datatype: 4, bitpix: 16), voxels: vox)
        try data.write(to: url)
        return url
    }

    /// Close while a layer import is in flight must win: the background import's
    /// main-thread completion is discarded by the layer-import-generation guard,
    /// so no layers are appended after close and `isImportingLayers` stays false.
    func testCloseDuringInFlightLayerImportDiscardsIt() throws {
        let (model, vol) = makeLoadedModel()
        let maskURL = try writeTempMaskNifti(
            matchingWidth: vol.width, height: vol.height, depth: vol.depth)
        defer { try? FileManager.default.removeItem(at: maskURL) }

        model.addLayerFiles([maskURL])   // kicks off background import
        XCTAssertTrue(model.isImportingLayers, "import started")
        model.closeCurrentFile()          // supersede it on the main queue

        // Drain the main run loop so the background completion lands.
        let exp = expectation(description: "in-flight import settled")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(model.layerStore.layers.isEmpty, "stale import discarded — no layers after close")
        XCTAssertFalse(model.isImportingLayers, "close reset isImportingLayers; stale import didn't clobber it")
    }

    /// Close alone (no in-flight import) must still reset `isImportingLayers`
    /// and clear any import error so the empty state isn't stuck "importing".
    func testCloseResetsImportFlags() {
        let (model, _) = makeLoadedModel()
        model.isImportingLayers = true
        model.layerImportError = "some error"
        model.closeCurrentFile()
        XCTAssertFalse(model.isImportingLayers, "isImportingLayers reset on close")
        XCTAssertNil(model.layerImportError, "layerImportError cleared on close")
    }

    // MARK: - Race: close must cancel an in-flight folder scan (P2 follow-up)

    /// Write a loose NIfTI into a temp folder so `loadFolder` finds it quickly.
    private func writeTempFolderWithNifti() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-close-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("scan-test.nii")
        let data = buildNifti(
            NiftiSpec(nx: 4, ny: 4, nz: 2, datatype: 4, bitpix: 16),
            voxels: [Float](repeating: 40, count: 4 * 4 * 2))
        try data.write(to: fileURL)
        return dir
    }

    /// Close while a folder scan is in flight must win: the scan's main-thread
    /// completion is discarded by the load-generation guard, so the dataset is
    /// not installed and no image is auto-loaded after close.
    func testCloseDuringInFlightFolderScanDiscardsIt() throws {
        let folderURL = try writeTempFolderWithNifti()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let model = ViewerModel()
        model.loadFolder(url: folderURL)   // kicks off background scan
        XCTAssertTrue(model.isScanningFolder, "scan started")
        model.closeCurrentFile()            // supersede it on the main queue

        // Drain the main run loop so the background scan completion lands.
        let exp = expectation(description: "in-flight scan settled")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertNil(model.dataset, "stale scan discarded — no dataset after close")
        XCTAssertNil(model.niftiDataset, "stale scan discarded — no image after close")
        XCTAssertTrue(model.allSeries.isEmpty)
        XCTAssertFalse(model.isScanningFolder, "close reset isScanningFolder; stale scan didn't clobber it")
    }
}
