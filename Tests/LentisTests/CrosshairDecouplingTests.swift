// CrosshairDecouplingTests.swift
// Lentis Tests
//
// Regression tests for the crosshair-drag-lag fix. The shared 3D crosshair world
// point is held in its OWN `CrosshairState` ObservableObject, NOT `@Published` on
// `ViewerModel`. A crosshair drag rewrites it on every mouse event; routing that
// through `model.objectWillChange` invalidated every view bound to the model and
// re-ran the entire quad's SwiftUI layout per drag event (the drag lag). These
// tests lock in the decoupling: a crosshair write must invalidate ONLY the
// CrosshairState (which the overlays observe), never the model.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Combine
import Testing
import simd
@testable import Lentis

// MARK: - Crosshair decoupling

@Test
func crosshairWriteDoesNotInvalidateModel() {
    let model = ViewerModel()
    var modelFired = false
    let token = model.objectWillChange.sink { _ in modelFired = true }
    defer { token.cancel() }

    model.crosshairWorld = SIMD3<Double>(10, 20, 30)

    // The whole point of the fix: a crosshair write must NOT fire the model's
    // objectWillChange (which would re-lay-out every model-observing view).
    #expect(modelFired == false)
    // …but the value must still round-trip through the decoupled state.
    #expect(model.crosshair.world == SIMD3<Double>(10, 20, 30))
}

@Test
func crosshairWriteInvalidatesCrosshairState() {
    let model = ViewerModel()
    var crosshairFired = false
    let token = model.crosshair.objectWillChange.sink { _ in crosshairFired = true }
    defer { token.cancel() }

    model.crosshairWorld = SIMD3<Double>(1, 2, 3)

    // The CrossReferenceOverlays observe CrosshairState, so this IS the publisher
    // that must fire — the crosshair still redraws, just without the model churn.
    #expect(crosshairFired == true)
}

@Test
func normalModelWriteStillInvalidatesModel() {
    // Control: a genuine @Published on the model still fires objectWillChange.
    // Guards against the first test passing because of a broken subscription.
    let model = ViewerModel()
    var modelFired = false
    let token = model.objectWillChange.sink { _ in modelFired = true }
    defer { token.cancel() }

    model.showCrossReference.toggle()

    #expect(modelFired == true)
}

@Test
func crosshairWorldShimForwardsToCrosshairState() {
    // The `crosshairWorld` back-compat accessor must read/write `crosshair.world`.
    let model = ViewerModel()
    #expect(model.crosshairWorld == nil)

    model.crosshair.world = SIMD3<Double>(-5, 6, -7)
    #expect(model.crosshairWorld == SIMD3<Double>(-5, 6, -7))

    model.crosshairWorld = nil
    #expect(model.crosshair.world == nil)
}
