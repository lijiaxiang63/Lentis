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
        // (.lower,.lower) corner: drag pulls toward the box's lower edges →
        // both axes negated → (-dirA) + (-dirB). With dirA=+x, dirB=+y(down)
        // that's (-10,-10) → same-sign → ↖↘ diagonal.
        let h = handle(.lower, .lower)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 10, y: 0), dirB: CGPoint(x: 0, y: 10))
        XCTAssertEqual(r, .diagUpLeftDownRight)
    }

    func testCornerGripsSignEachAxis() {
        // The P3 fix: a corner's two BoxGrips sign the drag direction per axis,
        // so the two diagonals of a box are distinguished (not all four corners
        // collapsing to one diagonal). With dirA=+x (axis A→right) and
        // dirB=+y (axis B→down):
        //   (.lower,.lower) → (-x,-y) ↖   (.upper,.upper) → (+x,+y) ↘  [↖↘ pair]
        //   (.lower,.upper) → (-x,+y) ↙   (.upper,.lower) → (+x,-y) ↗  [↗↙ pair]
        let dirA = CGPoint(x: 10, y: 0)
        let dirB = CGPoint(x: 0, y: 10)
        XCTAssertEqual(View.resizeCursor(for: handle(.lower, .lower), dirA: dirA, dirB: dirB), .diagUpLeftDownRight)
        XCTAssertEqual(View.resizeCursor(for: handle(.upper, .upper), dirA: dirA, dirB: dirB), .diagUpLeftDownRight)
        XCTAssertEqual(View.resizeCursor(for: handle(.lower, .upper), dirA: dirA, dirB: dirB), .diagUpRightDownLeft)
        XCTAssertEqual(View.resizeCursor(for: handle(.upper, .lower), dirA: dirA, dirB: dirB), .diagUpRightDownLeft)
    }

    func testEdgeMidpointMovingAxisAUsesAxisADirection() {
        // Edge midpoint: gripB is .fixed → only axis A moves; .lower negates it.
        let h = handle(.lower, .fixed)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 10, y: 0), dirB: CGPoint(x: 0, y: 10))
        XCTAssertEqual(r, .leftRight)
    }

    func testEdgeMidpointMovingAxisBUsesAxisBDirection() {
        // (.fixed,.upper): only axis B moves; .upper keeps +dirB = +y(down).
        let h = handle(.fixed, .upper)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 10, y: 0), dirB: CGPoint(x: 0, y: 10))
        XCTAssertEqual(r, .upDown)
    }

    func testEdgeMidpointLowerGripNegatesAxis() {
        // (.fixed,.lower): only axis B moves; .lower negates +dirB → -y(up).
        let h = handle(.fixed, .lower)
        let r = View.resizeCursor(for: h, dirA: CGPoint(x: 10, y: 0), dirB: CGPoint(x: 0, y: 10))
        // (-10) is degenerate-ish on x but |dy|=10 > 2.5·|dx|=0 → upDown.
        XCTAssertEqual(r, .upDown)
    }

    func testRotatedAxesStillClassifyByScreenDirection() {
        // The cursor must be classified from the ACTUAL screen directions of the
        // in-plane axes, not hardcoded to "axis A = horizontal". Give both axes
        // a diagonal screen direction (as a non-axis-aligned view would):
        //   dirA = (+3, +1) [A points mostly right, slightly down]
        //   dirB = (+1, +3) [B points mostly down, slightly right]
        // A (.upper,.upper) corner keeps both → (+4,+4) same-sign → ↖↘.
        // A (.upper,.lower) corner keeps A, negates B → (+3-1, +1-3) = (+2,-2)
        //   opposite-sign → ↗↙. This is the two-diagonal distinction the P3
        //   fix enables, derived purely from the screen directions.
        let dirA = CGPoint(x: 3, y: 1)
        let dirB = CGPoint(x: 1, y: 3)
        XCTAssertEqual(View.resizeCursor(for: handle(.upper, .upper), dirA: dirA, dirB: dirB), .diagUpLeftDownRight)
        XCTAssertEqual(View.resizeCursor(for: handle(.upper, .lower), dirA: dirA, dirB: dirB), .diagUpRightDownLeft)
    }

    func testRotatedPanelCornerDoesNotCollapseToZero() {
        // Locks the second P3 regression: after a 90°/270° panel rotation,
        // screenAxisDelta can return axis A as (nearly) vertical and axis B as
        // (nearly) horizontal. The OLD per-component corner formula
        // (dx=±dirA.x, dy=±dirB.y) collapsed to (0,0) here → a wrong horizontal
        // cursor. The fix sums the two FULL signed vectors, so the corner stays
        // a diagonal. Concretely: dirA=(0,10) [A→down], dirB=(-10,0) [B→left].
        //   (.lower,.lower): -A - B = -(0,10) - (-10,0) = (10,-10) → ↗↙
        //   (.upper,.upper): +A + B = (0,10) + (-10,0) = (-10,10) → ↗↙
        //   (.lower,.upper): -A + B = (0,-10) + (-10,0) = (-10,-10) → ↖↘
        //   (.upper,.lower): +A - B = (0,10) - (-10,0) = (10,10) → ↖↘
        let dirA = CGPoint(x: 0, y: 10)
        let dirB = CGPoint(x: -10, y: 0)
        XCTAssertEqual(View.resizeCursor(for: handle(.lower, .lower), dirA: dirA, dirB: dirB), .diagUpRightDownLeft)
        XCTAssertEqual(View.resizeCursor(for: handle(.upper, .upper), dirA: dirA, dirB: dirB), .diagUpRightDownLeft)
        XCTAssertEqual(View.resizeCursor(for: handle(.lower, .upper), dirA: dirA, dirB: dirB), .diagUpLeftDownRight)
        XCTAssertEqual(View.resizeCursor(for: handle(.upper, .lower), dirA: dirA, dirB: dirB), .diagUpLeftDownRight)
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
