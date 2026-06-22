import AppKit
import XCTest
@testable import Lentis

final class WindowAccessorTests: XCTestCase {
    @MainActor
    func testCenteredTitleSuppressesRestoredNativeTitleSynchronously() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()
        coordinator.attach(to: window)

        XCTAssertEqual(window.title, "")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.accessibilityLabel(), "Lentis")
        XCTAssertEqual(window.miniwindowTitle, "Lentis")

        // Mirror SwiftUI restoring the leading title during an Inspector update.
        window.title = "Lentis"
        window.titleVisibility = .visible
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        XCTAssertEqual(window.title, "")
        XCTAssertEqual(window.titleVisibility, .hidden)
    }
}
