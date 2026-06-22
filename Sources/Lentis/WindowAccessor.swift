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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.titlebarAppearsTransparent = false
                window.styleMask.remove(.fullSizeContentView)
                window.toolbarStyle = .expanded
                context.coordinator.attach(to: window)

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
        if let window = nsView.window {
            // Apply this in the same SwiftUI update pass. Deferring the hide by
            // one run-loop turn lets AppKit draw its leading title for a frame.
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private weak var centeredTitleLabel: NSTextField?
        private var notificationTokens: [NSObjectProtocol] = []
        private var enforcementPending = false

        deinit {
            notificationTokens.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else {
                enforceCenteredTitle()
                return
            }

            notificationTokens.forEach(NotificationCenter.default.removeObserver)
            notificationTokens.removeAll()
            self.window = window
            centeredTitleLabel = nil

            // SwiftUI can reconfigure the NSWindow titlebar when an inspector is
            // presented or its content changes. That may restore the native
            // leading title after WindowAccessor initially hid it, leaving both
            // the native and custom centered titles visible. Reassert the title
            // presentation after AppKit finishes each affected window update.
            let center = NotificationCenter.default
            for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification] {
                notificationTokens.append(center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.scheduleTitleEnforcement()
                })
            }

            enforceCenteredTitle()
        }

        private func scheduleTitleEnforcement() {
            // Hide the native title immediately. The asynchronous repeat below
            // catches any final mutation SwiftUI performs after the notification.
            enforceCenteredTitle()
            guard !enforcementPending else { return }
            enforcementPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.enforcementPending = false
                self.enforceCenteredTitle()
            }
        }

        private func enforceCenteredTitle() {
            guard let window else { return }

            // The visible title is our centered NSTextField below. Keeping the
            // native title empty prevents a one-frame leading-title flash even
            // if SwiftUI temporarily restores titleVisibility while rebuilding
            // the Inspector. Preserve the human-readable name for accessibility
            // and the minimized-window label.
            if !window.title.isEmpty {
                window.title = ""
            }
            if window.accessibilityLabel() != "Lentis" {
                window.setAccessibilityLabel("Lentis")
            }
            if window.miniwindowTitle != "Lentis" {
                window.miniwindowTitle = "Lentis"
            }
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }

            guard let closeButton = window.standardWindowButton(.closeButton),
                  let titlebarView = closeButton.superview else {
                return
            }

            let label: NSTextField
            if let existing = centeredTitleLabel,
               existing.superview === titlebarView {
                label = existing
            } else if let existing = titlebarView.subviews.first(where: {
                $0.identifier == WindowAccessor.centeredTitleIdentifier
            }) as? NSTextField {
                label = existing
                centeredTitleLabel = existing
            } else {
                label = NSTextField(labelWithString: "Lentis")
                label.identifier = WindowAccessor.centeredTitleIdentifier
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
                centeredTitleLabel = label
            }

            if label.stringValue != "Lentis" {
                label.stringValue = "Lentis"
            }
        }
    }
}
