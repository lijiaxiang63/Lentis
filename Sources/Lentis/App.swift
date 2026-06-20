// App.swift
// Lentis
//
// Application entry point. Configures the main window with a hidden titlebar
// and registers menu bar commands for layout switching, view operations
// (window/level, transforms, overlays), MPR mode, and synchronized scrolling.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

@main
struct LentisApp: App {
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    // Auto-open a file/directory if passed via --benchmark /path
                    if let benchIdx = CommandLine.arguments.firstIndex(of: "--benchmark"),
                       benchIdx + 1 < CommandLine.arguments.count {
                        let path = CommandLine.arguments[benchIdx + 1]
                        let url = URL(fileURLWithPath: path)
                        model.load(url: url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    model.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                // ─ Window/Level ─
                Button("Auto Window/Level (A)") {
                    if let panel = model.activePanel {
                        model.autoWindowLevelForPanel(panel)
                    }
                }

                Button("Invert (I)") {
                    model.invertForPanel(model.activePanel)
                }

                Divider()

                // ─ Transform ─
                Button("Fit to Window (F)") {
                    model.fitToWindowForPanel(model.activePanel)
                }

                Button("Reset View (R)") {
                    model.resetViewForPanel(model.activePanel)
                }

                Divider()

                Button("Rotate Clockwise 90° (])") {
                    model.rotateClockwiseForPanel(model.activePanel)
                }

                Button("Rotate Counter-Clockwise 90° ([)") {
                    model.rotateCounterClockwiseForPanel(model.activePanel)
                }

                Button("Flip Horizontal (H)") {
                    model.flipHorizontalForPanel(model.activePanel)
                }

                Button("Flip Vertical") {
                    model.flipVerticalForPanel(model.activePanel)
                }

                Divider()

                // ─ Overlays ─
                Toggle("Cross-Reference Lines (X)", isOn: $model.showCrossReference)
            }

            CommandMenu("Layout") {
                Button("Single Panel") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) }
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Side by Side") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) }
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Stacked") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) }
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Four Panels") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) }
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("MPR Layout") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setupMPRLayout() }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Toggle("Synchronized Scrolling", isOn: $model.synchronizedScrolling)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandMenu("Tools") {
                Button("Select (V)") { model.activeTool = .select }
                Button("Pan (P)") { model.activeTool = .pan }
                Button("Window/Level (W)") { model.activeTool = .windowLevel }
                Button("Zoom (Z)") { model.activeTool = .zoom }

                Divider()

                Button("ROI W/L (O)") { model.activeTool = .roiWL }
                Button("ROI Stats (S)") { model.activeTool = .roiStats }

                Divider()

                Button("Ruler (D)") { model.activeTool = .ruler }
                Button("Angle (N)") { model.activeTool = .angle }

                Divider()

                Button("Eraser (E)") { model.activeTool = .eraser }
            }

            CommandGroup(replacing: .help) {
                Button("Lentis Help") {
                    model.showHelp = true
                }
            }
        }
    }
}
