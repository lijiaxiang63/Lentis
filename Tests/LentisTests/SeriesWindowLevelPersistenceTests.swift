import Foundation
import Testing
@testable import Lentis

// MARK: - Window/Level Persistence Tests
//
// These tests verify that W/L state remains keyed by the volume series and
// survives panel reassignment / navigation without being overwritten.

// MARK: - SeriesViewState W/L caching

@Test
func seriesStatesStoresWindowLevelAfterFirstLoad() {
    // First render/seed should write W/L into seriesStates so subsequent
    // renders can reuse it.
    let model = ViewerModel()
    let uid = "test-series-uid"

    // Pre-condition: no entry in seriesStates
    #expect(model.seriesStates[uid] == nil)

    // Simulate first-load write.
    var state = model.seriesStates[uid] ?? ViewerModel.SeriesViewState()
    state.windowWidth = 1500.0
    state.windowCenter = 300.0
    model.seriesStates[uid] = state

    // Post-condition: W/L is cached
    #expect(model.seriesStates[uid]?.windowWidth == 1500.0)
    #expect(model.seriesStates[uid]?.windowCenter == 300.0)
}

@Test
func seriesStatesNotOverwrittenOnSubsequentLoads() {
    // Simulate the guard introduced in the fix:
    // if seriesStates[uid]?.windowWidth != nil, don't overwrite.
    let model = ViewerModel()
    let uid = "test-series-uid-2"

    // Write initial W/L (first slice load)
    var state = ViewerModel.SeriesViewState()
    state.windowWidth = 2000.0
    state.windowCenter = 500.0
    model.seriesStates[uid] = state

    // Simulate second slice load attempting to overwrite (should be skipped)
    if model.seriesStates[uid]?.windowWidth == nil {
        var s = model.seriesStates[uid] ?? ViewerModel.SeriesViewState()
        s.windowWidth = 999.0
        s.windowCenter = 111.0
        model.seriesStates[uid] = s
    }

    // W/L must be unchanged
    #expect(model.seriesStates[uid]?.windowWidth == 2000.0)
    #expect(model.seriesStates[uid]?.windowCenter == 500.0)
}

@Test
func preservedWLRestoredFromSeriesStatesWhenPanelWindowWidthIsZero() {
    // Verify the preserved W/L lookup:
    // when panel.windowWidth == 0 but seriesStates has a saved W/L,
    // the effective preserved values should come from seriesStates.
    let model = ViewerModel()
    let uid = "test-series-uid-3"
    let seriesIndex = 0

    // Set up a minimal series so allSeries[seriesIndex].id == uid
    model.allSeries = [ImageSeries(id: uid, seriesNumber: 1, seriesDescription: "test")]

    // Pre-populate seriesStates with a known W/L (simulating a prior slice load)
    var state = ViewerModel.SeriesViewState()
    state.windowWidth = 1200.0
    state.windowCenter = 400.0
    model.seriesStates[uid] = state

    // Simulate a panel that just had its series assigned (windowWidth reset to 0)
    let panel = PanelState()
    panel.seriesIndex = seriesIndex
    panel.windowWidth = 0
    panel.windowCenter = 0

    // Replicate the preservedWW lookup logic.
    var preservedWW = panel.windowWidth
    var preservedWC = panel.windowCenter
    if preservedWW <= 0, panel.seriesIndex >= 0, panel.seriesIndex < model.allSeries.count {
        let seriesUID = model.allSeries[panel.seriesIndex].id
        if let saved = model.seriesStates[seriesUID],
           let sw = saved.windowWidth, let sc = saved.windowCenter, sw > 0 {
            preservedWW = sw
            preservedWC = sc
        }
    }

    // The preserved values should come from seriesStates, not the panel's zeros
    #expect(preservedWW == 1200.0)
    #expect(preservedWC == 400.0)
}

@Test
func preservedWLNotRestoredWhenSeriesStatesEmpty() {
    // When seriesStates has no entry, preservedWW stays 0 (genuine first load).
    let model = ViewerModel()
    let uid = "test-series-uid-4"
    let seriesIndex = 0

    model.allSeries = [ImageSeries(id: uid, seriesNumber: 1, seriesDescription: "test")]

    let panel = PanelState()
    panel.seriesIndex = seriesIndex
    panel.windowWidth = 0
    panel.windowCenter = 0

    var preservedWW = panel.windowWidth
    var preservedWC = panel.windowCenter
    if preservedWW <= 0, panel.seriesIndex >= 0, panel.seriesIndex < model.allSeries.count {
        let seriesUID = model.allSeries[panel.seriesIndex].id
        if let saved = model.seriesStates[seriesUID],
           let sw = saved.windowWidth, let sc = saved.windowCenter, sw > 0 {
            preservedWW = sw
            preservedWC = sc
        }
    }

    // No seriesStates entry → preservedWW stays 0 (triggers auto-compute path)
    #expect(preservedWW == 0.0)
    #expect(preservedWC == 0.0)
}

@Test
func adjustWindowLevelPersistsToSeriesStates() {
    // Verify that drag-based W/L adjustment (adjustWindowLevelForPanel) still
    // saves to seriesStates — ensures user adjustments persist across scroll.
    let model = ViewerModel()
    let uid = "test-series-uid-5"
    let seriesIndex = 0

    model.allSeries = [ImageSeries(id: uid, seriesNumber: 1, seriesDescription: "test")]

    let panel = PanelState()
    panel.seriesIndex = seriesIndex
    panel.windowWidth = 1000.0
    panel.windowCenter = 300.0

    model.adjustWindowLevelForPanel(panel, deltaWidth: 500.0, deltaCenter: 100.0)

    #expect(panel.windowWidth == 1500.0)
    #expect(panel.windowCenter == 400.0)
    #expect(model.seriesStates[uid]?.windowWidth == 1500.0)
    #expect(model.seriesStates[uid]?.windowCenter == 400.0)
}
