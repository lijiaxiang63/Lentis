// ROICursorTests.swift
// Lentis Tests
//
// Phase 9 follow-up — locks the directional resize-cursor logic shown when the
// pointer hovers a draft ROI box's resize handle. The pure classifier
// (`directionalResizeCursor`) and the handle→direction mapping
// (`resizeCursor(for:dirA:dirB:)`) are unit-tested without an NSView; they are
// the core that mouseMoved consults to swap in a horizontal / vertical /
// diagonal resize cursor so the user can see a handle is draggable. The screen
// direction of each in-plane axis is derived live from the shared forward
// transform (so it stays correct under zoom / flip / 90° panel rotation), so
// these tests deliberately feed rotated axis directions to confirm the cursor
// is NOT hardcoded to "axis A = horizontal".
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import Lentis

final class ROICursorTests: XCTestCase {

    private typealias View = PanelInteractiveImageView.PanelImageInteractView

    // MARK: - directionalResizeCursor(dx:dy:)

    func testHorizontalDirection() {
        XCTAssertEqual(View.directionalResizeCursor(dx: 10, dy: 0), .leftRight)
        XCTAssertEqual(View.directionalResizeCursor(dx: -10, dy: 0), .leftRight)
    }

    func testVerticalDirection() {
        XCTAssertEqual(View.directionalResizeCursor(dx: 0, dy: 10), .upDown)
        XCTAssertEqual(View.directionalResizeCursor(dx: 0, dy: -10), .upDown)
    }

    func testDiagonalSameSignIsUpLeftDownRight() {
        // y-down screen space: (dx>0, dy>0) → down-right ↔ ↖↘ cursor.
        XCTAssertEqual(View.directionalResizeCursor(dx: 10, dy: 10), .diagUpLeftDownRight)
        // (dx<0, dy<0) → up-left ↔ same ↖↘ diagonal (opposite end, same cursor).
        XCTAssertEqual(View.directionalResizeCursor(dx: -10, dy: -10), .diagUpLeftDownRight)
    }

    func testDiagonalOppositeSignIsUpRightDownLeft() {
        // (dx>0, dy<0) → up-right ↔ ↗↙ cursor.
        XCTAssertEqual(View.directionalResizeCursor(dx: 10, dy: -10), .diagUpRightDownLeft)
        // (dx<0, dy>0) → down-left ↔ same ↗↙ diagonal.
        XCTAssertEqual(View.directionalResizeCursor(dx: -10, dy: 10), .diagUpRightDownLeft)
    }

    func testMostlyHorizontalBeatsDiagonal() {
        // |dx| > 2.5·|dy| → horizontal even if dy ≠ 0.
        XCTAssertEqual(View.directionalResizeCursor(dx: 10, dy: 3), .leftRight)
        XCTAssertEqual(View.directionalResizeCursor(dx: -30, dy: 10), .leftRight)
    }

    func testMostlyVerticalBeatsDiagonal() {
        XCTAssertEqual(View.directionalResizeCursor(dx: 3, dy: 10), .upDown)
        XCTAssertEqual(View.directionalResizeCursor(dx: 10, dy: 30), .upDown)
    }

    func testDegenerateFallsBackToLeftRight() {
        XCTAssertEqual(View.directionalResizeCursor(dx: 0, dy: 0), .leftRight)
    }

    func testExactlyAtRatioIsDiagonal() {
        // |dx| == 2.5·|dy| is NOT strictly greater, so it falls through to the
        // diagonal branch (boundary belongs to diagonal, not cardinal).
        XCTAssertEqual(View.directionalResizeCursor(dx: 10, dy: 4), .diagUpLeftDownRight)
    }

    // MARK: - resizeCursor(for:dirA:dirB:)

    private func handle(_ a: BoxGrip, _ b: BoxGrip) -> BoxHandle {
        BoxHandle(gripA: a, gripB: b, voxel: SIMD3(0, 0, 0))
    }

    func testCornerHandleCombinesBothAxes() {
        // Corner moves both axes → sum direction.
        let h = handle(.lower, .lower)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 10, y: 0), dirB: CGPoint(x: 0, y: 10))
        XCTAssertEqual(r, .diagUpLeftDownRight)
    }

    func testEdgeMidpointMovingAxisAUsesAxisADirection() {
        // Edge midpoint: gripB is .fixed → only axis A moves.
        let h = handle(.lower, .fixed)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 10, y: 0), dirB: CGPoint(x: 0, y: 10))
        XCTAssertEqual(r, .leftRight)
    }

    func testEdgeMidpointMovingAxisBUsesAxisBDirection() {
        let h = handle(.fixed, .upper)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 10, y: 0), dirB: CGPoint(x: 0, y: 10))
        XCTAssertEqual(r, .upDown)
    }

    func testRotatedAxesStillClassifyByScreenDirection() {
        // After a 90° panel rotation, in-plane axis A may map to vertical and
        // axis B to horizontal-left. A corner handle must still pick the right
        // DIAGONAL from the actual screen directions, not assume "A=horizontal".
        // dirA=(0,10) [A now points down], dirB=(-10,0) [B now points left].
        let h = handle(.upper, .upper)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 0, y: 10), dirB: CGPoint(x: -10, y: 0))
        // sum = (-10, 10) → opposite sign → ↗↙ diagonal.
        XCTAssertEqual(r, .diagUpRightDownLeft)
    }

    func testFullyFixedHandleFallsBack() {
        // A handle that moves no axis (shouldn't occur in practice) is harmless.
        let h = handle(.fixed, .fixed)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 10, y: 0), dirB: CGPoint(x: 0, y: 10))
        XCTAssertEqual(r, .leftRight)
    }

    // MARK: - nsCursor mapping (smoke test the diagonal cursors build)

    func testCursorKindsMapToNSCursor() {
        // Cardinal kinds use the built-in NSCursor singletons.
        XCTAssertNotNil(View.ResizeCursorKind.leftRight.nsCursor)
        XCTAssertNotNil(View.ResizeCursorKind.upDown.nsCursor)
        // Diagonal kinds build a cursor from an SF Symbol (falls back to
        // .crosshair if the symbol is unavailable, never nil).
        XCTAssertNotNil(View.ResizeCursorKind.diagUpLeftDownRight.nsCursor)
        XCTAssertNotNil(View.ResizeCursorKind.diagUpRightDownLeft.nsCursor)
    }
}
