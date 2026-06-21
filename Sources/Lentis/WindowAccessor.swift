// WindowAccessor.swift
// OpenDicomViewer
//
// NSViewRepresentable that customizes the hosting NSWindow on appear:
// enables window dragging by background and installs a key interceptor
// for IME-independent keyboard shortcuts.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import AppKit

/// Invisible NSView added directly to the window's content view.
/// Overrides performKeyEquivalent which fires BEFORE the Input Method (Korean/Japanese/Chinese IME)
/// processes the event. This is the only reliable way to handle single-letter shortcuts
/// when a CJK input method is active.
private class KeyInterceptorView: NSView {
    weak var model: ViewerModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let model = model else { return super.performKeyEquivalent(with: event) }
        // Only handle unmodified keys
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return super.performKeyEquivalent(with: event) }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }

        switch key {
        case "1":
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) } }
            return true
        case "2":
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) } }
            return true
        case "3":
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) } }
            return true
        case "4":
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) } }
            return true
        case "r": model.resetViewForPanel(model.activePanel); return true
        case "l": model.synchronizedScrolling.toggle(); return true
        case "x": model.showCrossReference.toggle(); return true
        case "i": model.invertForPanel(model.activePanel); return true
        case "f": model.fitToWindowForPanel(model.activePanel); return true
        case "a":
            if let panel = model.activePanel { model.autoWindowLevelForPanel(panel) }
            return true
        case "o": model.activeTool = .roiWL; return true
        case "s": model.activeTool = .roiStats; return true
        case "d": model.activeTool = .ruler; return true
        case "n": model.activeTool = .angle; return true
        case "e": model.activeTool = .eraser; return true
        case "]", ".": model.rotateClockwiseForPanel(model.activePanel); return true
        case "[", ",": model.rotateCounterClockwiseForPanel(model.activePanel); return true
        case "w": model.activeTool = .windowLevel; return true
        case "v": model.activeTool = .select; return true
        case "p": model.activeTool = .pan; return true
        case "z": model.activeTool = .zoom; return true
        case "h": model.flipHorizontalForPanel(model.activePanel); return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let model: ViewerModel
    private static let centeredTitleIdentifier = NSUserInterfaceItemIdentifier("LentisCenteredWindowTitle")
    private static let keyInterceptorIdentifier = NSUserInterfaceItemIdentifier("LentisKeyInterceptor")

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.title = "Lentis"
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = false
                window.styleMask.remove(.fullSizeContentView)
                window.toolbarStyle = .expanded
                installCenteredTitle(in: window)

                // Allow moving by dragging background
                window.isMovableByWindowBackground = true

                // Install key interceptor for IME-independent shortcuts
                if let contentView = window.contentView {
                    if let interceptor = contentView.subviews.first(where: { $0.identifier == Self.keyInterceptorIdentifier }) as? KeyInterceptorView {
                        interceptor.model = model
                    } else {
                        let interceptor = KeyInterceptorView()
                        interceptor.identifier = Self.keyInterceptorIdentifier
                        interceptor.model = model
                        interceptor.frame = .zero
                        interceptor.isHidden = false
                        contentView.addSubview(interceptor)
                    }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
    }

    private func installCenteredTitle(in window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebarView = closeButton.superview else {
            return
        }

        let label: NSTextField
        if let existing = titlebarView.subviews.first(where: { $0.identifier == Self.centeredTitleIdentifier }) as? NSTextField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "Lentis")
            label.identifier = Self.centeredTitleIdentifier
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titlebarView.addSubview(label)

            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: titlebarView.widthAnchor, constant: -240)
            ])
        }

        label.stringValue = "Lentis"
    }
}
