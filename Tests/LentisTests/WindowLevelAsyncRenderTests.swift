// WindowLevelAsyncRenderTests.swift
// Lentis Tests
//
// Regression test for the W/L-drag responsiveness fix. adjustWindowLevelForPanel
// must update the panel's W/L *state* synchronously (the toolbar readout binds
// those @Published values) but run the slice re-render OFF the calling (main)
// thread, via the panel's async+coalesced loadingQueue — not synchronously
// inline as it used to (renderSlice on the megapixel slice, or worse a MIP
// renderProjection waitUntilCompleted GPU block, both on main).
//
// The telltale, exploited here: a DispatchQueue.main.async apply cannot preempt
// synchronous main-thread code, so immediately after the call the displayed
// image is still the SAME object (the render is merely enqueued); it only
// changes once the background render lands. On the OLD synchronous path the
// image would already be a new object by the time the call returned — so the
// `panel.image === baseline` assertion below goes red on the regression.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Combine
import Testing
import simd
@testable import Lentis

/// Poll a condition while yielding the main actor, so the main dispatch queue
/// can service the panels' `DispatchQueue.main.async` render-apply blocks. Each
/// `Task.sleep` suspension hands the main thread back to its executor (the main
/// queue), which is exactly where those applies run.
@MainActor
private func poll(until predicate: () -> Bool, timeout: TimeInterval = 3.0) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)  // 5 ms
    }
}

@MainActor
private func makeAxialMRIPanel() throws -> (ViewerModel, PanelState) {
    let nx = 8, ny = 8, nz = 8
    var vox = [Float](repeating: 0, count: nx * ny * nz)
    for i in 0..<vox.count { vox[i] = Float(i % 1000) }   // non-negative ⇒ MRI
    let img = try NiftiImage.read(data: buildNifti(
        NiftiSpec(nx: nx, ny: ny, nz: nz, datatype: 16, bitpix: 32), voxels: vox))
    let ds = NiftiDataset(image: img, seriesID: "wl-async", displayName: "wl-async")

    let model = ViewerModel()
    let vol = ds.makeVolume(timepoint: 0)
    model.niftiDataset = ds
    let idx = model.registerStandaloneVolume(vol, cacheKey: ds.seriesID, description: ds.displayName)
    model.niftiSeriesIndex = idx

    let panel = model.panels[0]
    panel.seriesIndex = idx
    panel.panelMode = .mprAxial
    panel.windowWidth = 500
    panel.windowCenter = 500
    return (model, panel)
}

@MainActor
@Test
func windowLevelRenderIsAsyncOffMainThread() async throws {
    let (model, panel) = try makeAxialMRIPanel()

    // First render: establish a baseline displayed image (+ rawPixelData), so a
    // W/L re-render has a current slice to work from. Drain the background queue
    // and its main-queue apply.
    model.loadMPRSlice(for: panel)
    await poll(until: { panel.image != nil })
    let baseline = try #require(panel.image)
    #expect(panel.rawPixelData != nil)
    let oldWW = panel.windowWidth

    // A W/L drag flush. NOTE: no `await` between here and assertion (b), so the
    // main actor never yields — the enqueued apply provably cannot run in between.
    model.adjustWindowLevelForPanel(panel, deltaWidth: 600, deltaCenter: 0)

    // (a) W/L state updates synchronously — the toolbar binds windowWidth/Center.
    #expect(panel.windowWidth == oldWW + 600)

    // (b) The re-render is NOT synchronous on the calling thread: the enqueued
    // main-queue apply cannot have run yet, so the displayed image is unchanged.
    // This is the assertion that fails on the old renderSlice-on-main path.
    #expect(panel.image === baseline)

    // (c) …but the render still happens — it lands once the background op and
    // its main-queue apply run.
    await poll(until: { panel.image !== baseline })
    #expect(panel.image !== baseline)
}

// MARK: - W/L-drag relayout fix

/// A W/L-drag flush must NOT fire `model.objectWillChange`. The lag was the whole
/// quad re-laying-out (SwiftUI `LayoutEngineBox`) on every drag event because
/// `adjustWindowLevelForPanel` wrote the `@Published seriesStates` on the MODEL
/// each flush. The fix: per-flush is panel-local (`persist: false`); the window is
/// committed to the model once at drag-end via `persistWindowToSeriesStates`.
/// (Same invariant style as `CrosshairDecouplingTests`.)
@MainActor
@Test
func windowLevelDragFlushDoesNotInvalidateModel() throws {
    let (model, panel) = try makeAxialMRIPanel()

    var modelFired = false
    let token = model.objectWillChange.sink { _ in modelFired = true }
    defer { token.cancel() }

    // Per-flush drag adjust → panel-local only → no model churn (no quad relayout).
    model.adjustWindowLevelForPanel(panel, deltaWidth: 200, deltaCenter: 50, persist: false)
    #expect(modelFired == false)
    // …but the panel-local W/L state still updated (drives the toolbar + re-render).
    #expect(panel.windowWidth == 700)   // seeded 500 + 200
    #expect(panel.windowCenter == 550)  // seeded 500 + 50
    // …and nothing was persisted to the model yet.
    #expect(model.seriesStates["wl-async"] == nil)

    // Drag-END commit → DOES touch the model (fires objectWillChange) and persists.
    modelFired = false
    model.persistWindowToSeriesStates(panel)
    #expect(modelFired == true)
    #expect(model.seriesStates["wl-async"]?.windowWidth == 700)
    #expect(model.seriesStates["wl-async"]?.windowCenter == 550)
}

/// Control: the DEFAULT path (`persist: true`, used by presets / auto / seeding)
/// must still persist + fire — guards against the test above passing because the
/// model subscription is broken.
@MainActor
@Test
func windowLevelPersistDefaultStillInvalidatesModel() throws {
    let (model, panel) = try makeAxialMRIPanel()
    var modelFired = false
    let token = model.objectWillChange.sink { _ in modelFired = true }
    defer { token.cancel() }

    model.adjustWindowLevelForPanel(panel, deltaWidth: 100, deltaCenter: 0)  // persist defaults true
    #expect(modelFired == true)
    #expect(model.seriesStates["wl-async"]?.windowWidth == 600)
}
