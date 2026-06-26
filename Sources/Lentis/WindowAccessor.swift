// WindowAccessor.swift
// Lentis
//
// NSViewRepresentable that configures the hosting NSWindow on appear: enables
// window dragging by the background, adopts the unified (Liquid Glass) toolbar
// style, and installs a key interceptor for IME-independent keyboard shortcuts.
//
// The window TITLE is owned by SwiftUI's `.navigationTitle` (the open file
// name) — this type no longer manages a custom centered title.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import AppKit

/// Invisible NSView added to the window's content view. Overrides
/// performKeyEquivalent, which fires BEFORE the Input Method (Korean/Japanese/
/// Chinese IME) processes the event — the only reliable way to handle
/// single-letter shortcuts when a CJK input method is active.
final class KeyInterceptorView: NSView {
    weak var model: ViewerModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let model else { return super.performKeyEquivalent(with: event) }
        // Only handle unmodified keys.
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return super.performKeyEquivalent(with: event) }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        return handle(key: key, model: model) ? true : super.performKeyEquivalent(with: event)
    }

    /// Pure single-letter shortcut routing, exposed for unit testing.
    /// Returns true if the key was handled.
    @discardableResult
    func handle(key: String, model: ViewerModel) -> Bool {
        switch key {
        case "1": withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) }
        case "2": withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) }
        case "3": withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) }
        case "4": withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) }
        case "r": model.resetViewForPanel(model.activePanel)
        case "l":
            // Sync scrolling is not used in MPR layout (crosshair tracks scrolls).
            if !model.isMPRLayout { model.synchronizedScrolling.toggle() }
        case "x": model.showCrossReference.toggle()
        case "i": model.invertForPanel(model.activePanel)
        case "f": model.fitToWindowForPanel(model.activePanel)
        case "a": if let panel = model.activePanel { model.autoWindowLevelForPanel(panel) }
        case "o": model.activateTool(.roiWL)
        case "s": model.activateTool(.roiStats)
        case "d": model.activateTool(.ruler)
        case "n": model.activateTool(.angle)
        case "e": model.activateTool(.eraser)
        case "]", ".": model.rotateClockwiseForPanel(model.activePanel)
        case "[", ",": model.rotateCounterClockwiseForPanel(model.activePanel)
        case "w": model.activateTool(.windowLevel)
        case "v": model.activateTool(.select)
        case "p": model.activateTool(.pan)
        case "z": model.activateTool(.zoom)
        case "h": model.flipHorizontalForPanel(model.activePanel)
        default: return false
        }
        return true
    }
}

struct WindowAccessor: NSViewRepresentable {
    let model: ViewerModel
    private static let keyInterceptorIdentifier = NSUserInterfaceItemIdentifier("LentisKeyInterceptor")

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                WindowAccessor.configure(window: window, model: model)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Configure the window and ensure the key interceptor is installed (and its
    /// model reference current). Idempotent. Returns the interceptor (exposed for
    /// unit testing).
    @discardableResult
    static func configure(window: NSWindow, model: ViewerModel) -> KeyInterceptorView {
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified

        if let contentView = window.contentView {
            if let existing = contentView.subviews.first(where: {
                $0.identifier == keyInterceptorIdentifier
            }) as? KeyInterceptorView {
                existing.model = model
                return existing
            }
            let interceptor = KeyInterceptorView()
            interceptor.identifier = keyInterceptorIdentifier
            interceptor.model = model
            interceptor.frame = .zero
            contentView.addSubview(interceptor)
            return interceptor
        }

        // No content view yet (e.g. a bare unit-test window): return a detached,
        // still-functional interceptor.
        let interceptor = KeyInterceptorView()
        interceptor.identifier = keyInterceptorIdentifier
        interceptor.model = model
        return interceptor
    }
}

// MARK: - Non-draggable surface

/// An invisible NSView whose `mouseDownCanMoveWindow` returns `false`. Used as a
/// SwiftUI `.background` on panes (e.g. the trailing inspector) that sit over a
/// window with `isMovableByWindowBackground = true`. Without it, clicking empty
/// padding around sliders/controls in the inspector drags the whole window
/// instead of letting the user grab the control. The inspector's interactive
/// controls (sliders, buttons) already consume their own mouse events; this
/// only claims the dead space around them.
private final class NonDraggableBackingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

private struct NonDraggableBackingRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableBackingView {
        NonDraggableBackingView()
    }

    func updateNSView(_ nsView: NonDraggableBackingView, context: Context) {}
}

extension View {
    /// Prevent `isMovableByWindowBackground` from claiming clicks on this view's
    /// empty areas. Apply to inspector/sidebar panes that host interactive
    /// controls (sliders, steppers) so dragging near a control doesn't move the
    /// window instead.
    func nonDraggableBackground() -> some View {
        background(NonDraggableBackingRepresentable())
    }
}
