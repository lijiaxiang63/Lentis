// App.swift
// Lentis
//
// Application entry point. Configures menu bar commands for layout switching, view operations
// (window/level, transforms, overlays), MPR mode, and synchronized scrolling.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

@main
struct LentisApp: App {
    @StateObject private var model = ViewerModel()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        // The window title is owned by the detail view's `.navigationTitle`
        // (the open file name) — the native macOS pattern that replaces the old
        // custom centered-title machinery in WindowAccessor.
        WindowGroup {
            ContentView(model: model)
                .task {
                    // Auto-open a file/directory if passed via --benchmark /path
                    if let benchIdx = CommandLine.arguments.firstIndex(of: "--benchmark"),
                       benchIdx + 1 < CommandLine.arguments.count,
                       !model.didHandleCommandLineLaunch {
                        model.didHandleCommandLineLaunch = true
                        let path = CommandLine.arguments[benchIdx + 1]
                        let url = URL(fileURLWithPath: path)
                        model.load(url: url)

                        // Optional visual-QA companion for the benchmark path:
                        // wait for the base grid, import one external layer, and
                        // expose the Inspector without GUI automation.
                        if let layerIdx = CommandLine.arguments.firstIndex(of: "--benchmark-layer"),
                           layerIdx + 1 < CommandLine.arguments.count {
                            let deadline = Date().addingTimeInterval(120)
                            while model.niftiDataset == nil, model.errorMessage == nil, Date() < deadline {
                                try? await Task.sleep(nanoseconds: 20_000_000)
                            }
                            if model.niftiDataset != nil {
                                model.addLayerFiles([
                                    URL(fileURLWithPath: CommandLine.arguments[layerIdx + 1])
                                ])
                                while model.isImportingLayers, Date() < deadline {
                                    try? await Task.sleep(nanoseconds: 20_000_000)
                                }
                                model.showLayerInspector = true
                            }
                        }

                        // Deterministic, self-driving interactive-perf probe (no GUI /
                        // computer-use needed — computer-use coalesces a synthetic drag to
                        // ~2 events). Mirrors the removed --xhair-stress harness used for the
                        // crosshair fix: fire many W/L flushes, crosshair relocations, and
                        // scroll ticks; each logs its synchronous main-thread cost (wl_drag /
                        // crosshair_set / scroll_main). REMOVE once perf work is signed off.
                        if CommandLine.arguments.contains("--perf-stress") {
                            await LentisApp.runPerfStress(model)
                        }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    model.openFileOrFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.isLoading || model.isScanningFolder)

                Button("Open Folder…") {
                    model.openFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(model.isLoading || model.isScanningFolder)

                Divider()

                Button("Add Layer...") {
                    model.openLayerFiles()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.niftiDataset == nil)
            }

            InspectorCommands()

            CommandGroup(after: .toolbar) {
                // ─ Window/Level ─
                Button("Auto Window/Level (A)") {
                    if let panel = model.activePanel {
                        // Modality-aware auto-window — same path as the Auto button.
                        model.autoWindow(for: panel)
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
                    .disabled(model.isMPRLayout)
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

        // Native preferences window (⌘,). macOS adds the "Settings…" menu item
        // automatically. Binds the shared AppSettings; the model supplies the
        // read-only status lines (FreeSurfer availability, resolved output dir).
        Settings {
            SettingsView(model: model, settings: settings)
        }
    }

    // MARK: - Interactive-perf stress probe (--perf-stress; benchmark-only, removable)

    /// Self-driving interactive-responsiveness benchmark. Waits for the volume to
    /// load + first render, builds the MPR quad, then exercises the three hot
    /// interactions — yielding the main actor (~60 Hz) between events so each
    /// background render lands like a real drag — and records the synchronous
    /// main-thread cost of each:
    ///   • W/L flush on the megapixel sagittal MPR + 3D volume panels → wl_drag
    ///   • crosshair relocation through the volume → crosshair_set
    ///   • scroll tick (active panel + sync-scroll the quad) → scroll_main
    /// Read ~/Desktop/lentis_benchmark.csv between the `*_begin/_end` markers.
    @MainActor
    static func runPerfStress(_ model: ViewerModel) async {
        let log = BenchmarkLogger.shared
        func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        func waitFor(_ secs: Double, _ cond: () -> Bool) async {
            let deadline = Date().addingTimeInterval(secs)
            while !cond() && Date() < deadline { await sleep(20) }
        }

        // 1. Wait for the (background) inflate + first render.
        await waitFor(120) { model.panels.contains { $0.image != nil } }
        guard model.panels.contains(where: { $0.image != nil }) else {
            log.log(event: "perf_stress_abort", detail: "no first render"); return
        }
        // 2. Brain quad (axial/sagittal/coronal/3D volume).
        model.setupMPRLayout()
        await waitFor(60) {
            model.panels.count == 4 && model.panels[1].image != nil && model.panels[3].image != nil
        }
        guard model.panels.count == 4 else { log.log(event: "perf_stress_abort", detail: "no quad"); return }
        let axial = model.panels[0], sag = model.panels[1], volume3D = model.panels[3]

        // 3a. W/L flushes (alternating sign keeps the window in range).
        // Match the real drag path: panel-local mutations during the gesture,
        // followed by one model-level persistence write at drag end.
        // --wl-hold: sustained ~15 s W/L drive so the main thread can be `sample`d.
        let wlHold = CommandLine.arguments.contains("--wl-hold")
        log.log(event: "wl_stress_begin",
                detail: "sag \(sag.imageWidth)x\(sag.imageHeight) \(sag.panelMode.rawValue); panel3=\(volume3D.panelMode.rawValue) hold=\(wlHold)")
        let wlIters = wlHold ? 900 : 80
        for i in 0..<wlIters {
            let s = (i % 2 == 0) ? 1.0 : -1.0
            model.adjustWindowLevelForPanel(sag, deltaWidth: 60 * s, deltaCenter: 15 * s,
                                            persist: false)
            await sleep(16)
        }
        model.persistWindowToSeriesStates(sag)
        for i in 0..<80 {
            let s = (i % 2 == 0) ? 1.0 : -1.0
            model.adjustWindowLevelForPanel(volume3D, deltaWidth: 60 * s, deltaCenter: 15 * s,
                                            persist: false)
            await sleep(16)
        }
        model.persistWindowToSeriesStates(volume3D)
        log.log(event: "wl_stress_end", detail: "done")

        // 3b. Crosshair relocations (sweep a world point through the axial plane).
        if let base = axial.imagePositionPatient {
            log.log(event: "xhair_stress_begin", detail: "")
            for i in 0..<80 {
                let t = Double(i - 40)
                model.setCrosshair(SIMD3<Double>(base.0 + t, base.1 + t * 0.5, base.2), from: axial)
                await sleep(16)
            }
            log.log(event: "xhair_stress_end", detail: "")
        }

        // 3c. Scroll ticks (active panel + sync-scroll of the quad).
        model.activePanelID = axial.id
        log.log(event: "scroll_stress_begin", detail: "sync=\(model.synchronizedScrolling)")
        for i in 0..<80 {
            model.navigatePanelWithGroup(axial, direction: (i % 2 == 0) ? .nextImage : .prevImage)
            await sleep(16)
        }
        log.log(event: "scroll_stress_end", detail: "done")
    }
}
