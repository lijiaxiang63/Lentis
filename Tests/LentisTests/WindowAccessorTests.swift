import AppKit
import XCTest
@testable import Lentis

/// The window title is now owned by SwiftUI's `.navigationTitle` (the open file
/// name), so there is no centered-title machinery left to test. These tests lock
/// the two responsibilities WindowAccessor retains: configuring the window and
/// installing the IME-independent key interceptor.
final class WindowAccessorTests: XCTestCase {
    @MainActor
    func testConfigureInstallsKeyInterceptorAndEnablesBackgroundDrag() {
        let model = ViewerModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let interceptor = WindowAccessor.configure(window: window, model: model)

        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(interceptor.model === model)
        XCTAssertNotNil(window.contentView?.subviews.first { $0 === interceptor })

        // Idempotent: a second configure reuses the same interceptor (no duplicate).
        let again = WindowAccessor.configure(window: window, model: model)
        XCTAssertTrue(again === interceptor)
        XCTAssertEqual(
            window.contentView?.subviews.compactMap { $0 as? KeyInterceptorView }.count, 1)
    }

    @MainActor
    func testKeyInterceptorRoutesShortcuts() {
        let model = ViewerModel()
        let interceptor = KeyInterceptorView()

        // Tool shortcuts.
        XCTAssertTrue(interceptor.handle(key: "w", model: model))
        XCTAssertEqual(model.activeTool, .windowLevel)
        XCTAssertTrue(interceptor.handle(key: "v", model: model))
        XCTAssertEqual(model.activeTool, .select)

        // Toggles.
        let sync = model.synchronizedScrolling
        XCTAssertTrue(interceptor.handle(key: "l", model: model))
        XCTAssertEqual(model.synchronizedScrolling, !sync)

        let crosshair = model.showCrossReference
        XCTAssertTrue(interceptor.handle(key: "x", model: model))
        XCTAssertEqual(model.showCrossReference, !crosshair)

        // An unmapped key is not handled (so AppKit can route it onward).
        XCTAssertFalse(interceptor.handle(key: "ä", model: model))
    }
}
