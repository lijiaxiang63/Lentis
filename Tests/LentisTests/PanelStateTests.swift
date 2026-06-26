// PanelStateTests.swift
// Lentis Tests
//
// Tests for panel state enums (ViewerLayout, PanelMode, ActiveTool,
// NavigationDirection) and basic PanelState behavior.
// These tests focus on enum/state logic that does not require a running GUI.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import Lentis

final class PanelStateTests: XCTestCase {

    // MARK: - ViewerLayout

    func testViewerLayoutAllCases() {
        let cases = ViewerLayout.allCases
        XCTAssertEqual(cases.count, 4)
    }

    func testViewerLayoutRowsAndColumns() {
        XCTAssertEqual(ViewerLayout.single.rows, 1)
        XCTAssertEqual(ViewerLayout.single.columns, 1)
        XCTAssertEqual(ViewerLayout.single.panelCount, 1)

        XCTAssertEqual(ViewerLayout.twoHorizontal.rows, 1)
        XCTAssertEqual(ViewerLayout.twoHorizontal.columns, 2)
        XCTAssertEqual(ViewerLayout.twoHorizontal.panelCount, 2)

        XCTAssertEqual(ViewerLayout.twoVertical.rows, 2)
        XCTAssertEqual(ViewerLayout.twoVertical.columns, 1)
        XCTAssertEqual(ViewerLayout.twoVertical.panelCount, 2)

        XCTAssertEqual(ViewerLayout.quad.rows, 2)
        XCTAssertEqual(ViewerLayout.quad.columns, 2)
        XCTAssertEqual(ViewerLayout.quad.panelCount, 4)
    }

    func testViewerLayoutRawValues() {
        XCTAssertEqual(ViewerLayout.single.rawValue, "1\u{00d7}1")       // "1x1" with multiplication sign
        XCTAssertEqual(ViewerLayout.twoHorizontal.rawValue, "2\u{00d7}1")
        XCTAssertEqual(ViewerLayout.twoVertical.rawValue, "1\u{00d7}2")
        XCTAssertEqual(ViewerLayout.quad.rawValue, "2\u{00d7}2")
    }

    func testViewerLayoutIconNames() {
        XCTAssertEqual(ViewerLayout.single.iconName, "rectangle")
        XCTAssertEqual(ViewerLayout.twoHorizontal.iconName, "rectangle.split.2x1")
        XCTAssertEqual(ViewerLayout.twoVertical.iconName, "rectangle.split.1x2")
        XCTAssertEqual(ViewerLayout.quad.iconName, "rectangle.split.2x2")
    }

    func testViewerLayoutIdentifiable() {
        let layout = ViewerLayout.quad
        XCTAssertEqual(layout.id, layout.rawValue)
    }

    // MARK: - PanelMode

    func testPanelModeAllCases() {
        let cases = PanelMode.allCases
        XCTAssertEqual(cases.count, 4)
        XCTAssertTrue(cases.contains(.mprAxial))
        XCTAssertTrue(cases.contains(.mprSagittal))
        XCTAssertTrue(cases.contains(.mprCoronal))
        XCTAssertTrue(cases.contains(.volume3D))
    }

    func testPanelModeRawValues() {
        XCTAssertEqual(PanelMode.mprAxial.rawValue, "Axial")
        XCTAssertEqual(PanelMode.mprSagittal.rawValue, "Sagittal")
        XCTAssertEqual(PanelMode.mprCoronal.rawValue, "Coronal")
        XCTAssertEqual(PanelMode.volume3D.rawValue, "3D")
    }

    func testPanelModeIdentifiable() {
        let mode = PanelMode.mprSagittal
        XCTAssertEqual(mode.id, mode.rawValue)
    }

    // MARK: - ActiveTool

    func testActiveToolAllCases() {
        let cases = ActiveTool.allCases
        XCTAssertEqual(cases.count, 11)   // +roiBox, +calcBrush (Phase 9)
    }

    func testActiveToolRawValues() {
        XCTAssertEqual(ActiveTool.select.rawValue, "Select")
        XCTAssertEqual(ActiveTool.pan.rawValue, "Pan")
        XCTAssertEqual(ActiveTool.windowLevel.rawValue, "W/L")
        XCTAssertEqual(ActiveTool.zoom.rawValue, "Zoom")
        XCTAssertEqual(ActiveTool.roiWL.rawValue, "ROI W/L")
        XCTAssertEqual(ActiveTool.roiStats.rawValue, "ROI Stats")
        XCTAssertEqual(ActiveTool.ruler.rawValue, "Ruler")
        XCTAssertEqual(ActiveTool.angle.rawValue, "Angle")
        XCTAssertEqual(ActiveTool.eraser.rawValue, "Eraser")
    }

    func testActiveToolIcons() {
        // Verify each tool has a non-empty icon name
        for tool in ActiveTool.allCases {
            XCTAssertFalse(tool.icon.isEmpty, "\(tool.rawValue) should have an icon")
        }
    }

    func testActiveToolShortcutHints() {
        // Verify each tool has a single-character shortcut
        for tool in ActiveTool.allCases {
            XCTAssertEqual(tool.shortcutHint.count, 1, "\(tool.rawValue) shortcut should be 1 char")
        }
        // Verify specific shortcuts
        XCTAssertEqual(ActiveTool.select.shortcutHint, "V")
        XCTAssertEqual(ActiveTool.windowLevel.shortcutHint, "W")
        XCTAssertEqual(ActiveTool.zoom.shortcutHint, "Z")
    }

    func testActiveToolShortcutsAreUnique() {
        let shortcuts = ActiveTool.allCases.map { $0.shortcutHint }
        let uniqueShortcuts = Set(shortcuts)
        XCTAssertEqual(shortcuts.count, uniqueShortcuts.count, "All tool shortcuts should be unique")
    }

    func testActiveToolIdentifiable() {
        let tool = ActiveTool.ruler
        XCTAssertEqual(tool.id, tool.rawValue)
    }

    func testVolumePrimaryDragTools() {
        XCTAssertTrue(ActiveTool.select.rotatesVolumeOnPrimaryDrag)
        XCTAssertTrue(ActiveTool.pan.rotatesVolumeOnPrimaryDrag)
        XCTAssertFalse(ActiveTool.windowLevel.rotatesVolumeOnPrimaryDrag)
        XCTAssertFalse(ActiveTool.zoom.rotatesVolumeOnPrimaryDrag)
    }

    // MARK: - 3D Volume Interaction

    func testHorizontalVolumeDragTurnsWithPointerWithoutPitch() {
        let delta = VolumeRotationInteraction.rotationDelta(
            from: CGPoint(x: 20, y: 30),
            to: CGPoint(x: 100, y: 30)
        )

        XCTAssertLessThan(delta.yaw, 0)
        XCTAssertEqual(delta.yaw, -60)
        XCTAssertEqual(delta.pitch, 0)
    }

    func testVerticalVolumeDragTurnsWithPointerWithoutYaw() {
        let delta = VolumeRotationInteraction.rotationDelta(
            from: CGPoint(x: 20, y: 30),
            to: CGPoint(x: 20, y: 10)
        )

        XCTAssertEqual(delta.yaw, 0)
        XCTAssertGreaterThan(delta.pitch, 0)
    }

    // MARK: - PanelState basics

    func testPanelStateInitialValues() {
        let state = PanelState()
        XCTAssertEqual(state.seriesIndex, -1)
        XCTAssertEqual(state.imageIndex, -1)
        XCTAssertEqual(state.panelMode, .mprAxial)
        XCTAssertEqual(state.scale, 1.0)
        XCTAssertEqual(state.windowWidth, 0)
        XCTAssertEqual(state.windowCenter, 0)
        XCTAssertFalse(state.isInverted)
        XCTAssertEqual(state.rotationSteps, 0)
        XCTAssertFalse(state.isFlippedH)
        XCTAssertFalse(state.isFlippedV)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.annotations.isEmpty)
    }

    func testPanelStateReset() {
        let state = PanelState()
        // Modify various properties
        state.seriesIndex = 5
        state.imageIndex = 10
        state.panelMode = .mprSagittal
        state.scale = 2.5
        state.windowWidth = 400
        state.windowCenter = 50
        state.isInverted = true
        state.rotationSteps = 2
        state.isFlippedH = true
        state.isFlippedV = true
        state.isLoading = true
        state.errorMessage = "test error"
        state.mprSliceIndex = 42

        // Reset
        state.reset()

        // Verify everything is back to defaults
        XCTAssertEqual(state.seriesIndex, -1)
        XCTAssertEqual(state.imageIndex, -1)
        XCTAssertEqual(state.panelMode, .mprAxial)
        XCTAssertEqual(state.scale, 1.0)
        XCTAssertEqual(state.windowWidth, 0)
        XCTAssertEqual(state.windowCenter, 0)
        XCTAssertFalse(state.isInverted)
        XCTAssertEqual(state.rotationSteps, 0)
        XCTAssertFalse(state.isFlippedH)
        XCTAssertFalse(state.isFlippedV)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.mprSliceIndex, 0)
    }

    func testPanelStateUniqueIds() {
        let state1 = PanelState()
        let state2 = PanelState()
        XCTAssertNotEqual(state1.id, state2.id)
    }

    // MARK: - Reset View (ViewerModel.resetViewForPanel)

    /// resetViewForPanel must restore ALL spatial transforms (zoom, pan, 90°
    /// rotation, horizontal/vertical flip, invert) while PRESERVING the user's
    /// Window/Level. Previously it only reset zoom/pan and re-ran auto W/L,
    /// leaving rotation/flip/invert stuck — so "R" never fully restored the
    /// image after transform changes. Use a ViewerModel so the model-level
    /// reset path (the one wired to the R key, the menu item, and the new
    /// tool-palette button) is exercised directly.
    @MainActor
    func testResetViewRestoresSpatialTransformsKeepsWindowLevel() {
        let model = ViewerModel()
        let panel = model.panels[0]
        // Simulate the user changing every spatial transform + W/L.
        panel.scale = 2.5
        panel.translation = CGPoint(x: 40, y: -30)
        panel.rotationSteps = 2
        panel.isFlippedH = true
        panel.isFlippedV = true
        panel.isInverted = true
        panel.windowWidth = 400
        panel.windowCenter = 50

        model.resetViewForPanel(panel)

        // Spatial transforms back to defaults.
        XCTAssertEqual(panel.scale, 1.0)
        XCTAssertEqual(panel.translation, .zero)
        XCTAssertEqual(panel.rotationSteps, 0)
        XCTAssertFalse(panel.isFlippedH)
        XCTAssertFalse(panel.isFlippedV)
        XCTAssertFalse(panel.isInverted)
        // Window/Level preserved (not auto-restarted).
        XCTAssertEqual(panel.windowWidth, 400)
        XCTAssertEqual(panel.windowCenter, 50)
    }

    /// Resetting a nil panel must be a safe no-op (the toolbar/menu/button all
    /// pass model.activePanel, which can be nil).
    @MainActor
    func testResetViewForNilPanelIsNoOp() {
        let model = ViewerModel()
        model.resetViewForPanel(nil)  // should not crash
        XCTAssertTrue(true)
    }

    func testPanelStateIsRawDataAvailable() {
        let state = PanelState()
        XCTAssertFalse(state.isRawDataAvailable)
        state.rawPixelData = Data([0x00, 0x01])
        XCTAssertTrue(state.isRawDataAvailable)
    }

    // MARK: - AnnotationType

    func testAnnotationTypeRuler() {
        let annotation = Annotation(type: .ruler(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 0),
            distanceMM: 50.0
        ))
        XCTAssertNotNil(annotation.id)
        if case .ruler(let start, let end, let dist) = annotation.type {
            XCTAssertEqual(start, CGPoint(x: 0, y: 0))
            XCTAssertEqual(end, CGPoint(x: 100, y: 0))
            XCTAssertEqual(dist, 50.0)
        } else {
            XCTFail("Expected ruler annotation")
        }
    }

    func testAnnotationTypeAngle() {
        let annotation = Annotation(type: .angle(
            vertex: CGPoint(x: 50, y: 50),
            arm1: CGPoint(x: 0, y: 50),
            arm2: CGPoint(x: 50, y: 0),
            degrees: 90.0
        ))
        if case .angle(_, _, _, let degrees) = annotation.type {
            XCTAssertEqual(degrees, 90.0)
        } else {
            XCTFail("Expected angle annotation")
        }
    }

    func testAnnotationTypeROIStats() {
        let annotation = Annotation(type: .roiStats(
            rect: CGRect(x: 10, y: 10, width: 50, height: 50),
            mean: 100.0,
            max: 200.0,
            min: 50.0,
            stdDev: 25.0,
            count: 2500
        ))
        if case .roiStats(let rect, let mean, let max, let min, let stdDev, let count) = annotation.type {
            XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 50, height: 50))
            XCTAssertEqual(mean, 100.0)
            XCTAssertEqual(max, 200.0)
            XCTAssertEqual(min, 50.0)
            XCTAssertEqual(stdDev, 25.0)
            XCTAssertEqual(count, 2500)
        } else {
            XCTFail("Expected roiStats annotation")
        }
    }
}
