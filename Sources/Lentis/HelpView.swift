// HelpView.swift
// Lentis
//
// In-app help viewer showing usage guide, tools reference, and keyboard shortcuts.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Lentis Help")
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Overview
                    helpSection("Overview") {
                        Text("Lentis is a native macOS viewer for 3D brain NIfTI images (`.nii` / `.nii.gz`), supporting both CT and MRI. It displays images in neurological orientation with modality-aware window/level, multi-panel and MPR (multiplanar reconstruction) layouts, a linked 3D crosshair, and measurement annotations.")
                    }

                    // Opening Files
                    helpSection("Opening Files") {
                        Text("Use **File > Open** (Cmd+O) or click the **Open** button in the sidebar to select a NIfTI file (`.nii` / `.nii.gz`). You can also **drag and drop** a file onto the viewer.")
                        Text("The sidebar lists the open file. Click it to show it in the active panel.")
                    }

                    // Panel Layouts
                    helpSection("Panel Layouts") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("Cmd+1", "Single panel")
                            shortcutRow("Cmd+2", "Side by side (2 horizontal)")
                            shortcutRow("Cmd+3", "Stacked (2 vertical)")
                            shortcutRow("Cmd+4", "Four panels (2x2)")
                            shortcutRow("Cmd+Shift+M", "MPR layout")
                        }
                        Text("Click a panel to make it the active panel. Press **Tab** to cycle through panels. Drag the file from the sidebar onto a panel to show it there.")
                        Text("**Double-click** a panel to toggle fullscreen for that panel (or use the fullscreen button in the panel's top toolbar).")
                    }

                    // Tools
                    helpSection("Tools") {
                        Text("Select tools from the tool palette (fixed column to the left of the panels), the **Tools** menu, or with keyboard shortcuts:")
                        VStack(alignment: .leading, spacing: 6) {
                            toolRow("V", "cursorarrow", "Select", "Default pointer — click to activate panels")
                            toolRow("P", "arrow.up.and.down.and.arrow.left.and.right", "Pan", "Click and drag to pan the image")
                            toolRow("W", "sun.max", "Window/Level", "Drag to adjust brightness and contrast")
                            toolRow("Z", "magnifyingglass", "Zoom", "Drag up/down to zoom in/out")
                            toolRow("O", "rectangle.dashed", "ROI W/L", "Draw a rectangle to auto-set window/level from that region")
                            toolRow("S", "chart.bar.xaxis", "ROI Stats", "Draw a rectangle to see mean, min, max, std dev of pixel values")
                            toolRow("D", "ruler", "Ruler", "Click two points to measure distance in mm. A dashed preview line follows the cursor after the first click.")
                            toolRow("N", "angle", "Angle", "Click three points (vertex, arm1, arm2) to measure an angle. Dashed preview lines follow the cursor between clicks.")
                            toolRow("E", "eraser", "Eraser", "Click an annotation to delete it")
                        }
                        Text("Hold **Shift** to reveal a selection overlay, then click panels to **link** them so they scroll together (orange = linked). Press **Escape** to clear. This is separate from **L** Synchronized Scrolling, which links *all* panels' scroll positions.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Modifier Overrides
                    helpSection("Modifier Overrides") {
                        Text("Regardless of which tool is active, hold **Option** or **Control** to temporarily access common actions:")
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("Opt/Ctrl + Left-drag", "Pan the image")
                            shortcutRow("Opt/Ctrl + Right-drag", "Adjust Window/Level")
                            shortcutRow("Opt/Ctrl + Scroll", "Zoom in/out")
                        }
                    }

                    // Navigation
                    helpSection("Navigation") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("Up / Down", "Previous / next image in series")
                            shortcutRow("Left / Right", "Previous / next series")
                            shortcutRow("Page Up / Down", "Jump 10 images")
                            shortcutRow("Home / End", "Jump to first / last image")
                            shortcutRow("Scroll Wheel", "Scroll through images")
                            shortcutRow("Opt/Ctrl + Scroll", "Zoom in/out")
                            shortcutRow("Tab", "Cycle active panel")
                        }
                    }

                    // Window/Level
                    helpSection("Window/Level") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("A", "Auto window/level")
                            shortcutRow("I", "Invert (negate) the image")
                            shortcutRow("Right-drag", "Adjust Window/Level (works with any tool)")
                            Text("With the **W/L tool** active, drag horizontally to adjust window width and vertically to adjust window center.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Display Transforms
                    helpSection("Display Transforms") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("F", "Fit image to window")
                            shortcutRow("R", "Reset view (zoom, pan, and auto W/L)")
                            shortcutRow("] or .", "Rotate clockwise 90\u{00B0}")
                            shortcutRow("[ or ,", "Rotate counter-clockwise 90\u{00B0}")
                            shortcutRow("H", "Flip horizontal")
                        }
                    }

                    // MPR Views
                    helpSection("MPR (Multiplanar Reconstruction)") {
                        Text("The brain layout combines axial, sagittal, and coronal MPR planes with an interactive 3D volume rendering. Drag the 3D panel to rotate it; adjust Density in the top control bar. The three orthogonal planes remain linked by the crosshair.")
                    }

                    // Display guide (legends for on-screen overlays)
                    helpSection("Display Guide") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("**Orientation letters** at the panel edges mark patient directions: **R**ight, **L**eft, **A**nterior, **P**osterior, **S**uperior, **I**nferior. Images use the **neurological** convention — patient-left is screen-left.")
                            Text("**Modality badge** (top-left): **CT** = amber, **MRI** = teal. It is auto-detected; click it to switch.")
                            Text("**Histogram** (bottom): the yellow band is the current window; the white line is the level (center).")
                            Text("**Cursor readout** (bottom): the value is **HU** for CT or **Intensity** (arbitrary units) for MRI, with the volume voxel x/y/z in brackets; **RAS** coordinates are in millimetres.")
                            Text("**WL / WW** (bottom-left) are the window level and width in stored units (HU for CT).")
                        }
                    }

                    // Overlays & Panels
                    helpSection("Overlays & Other Features") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("X", "Toggle cross-reference lines")
                            shortcutRow("L", "Toggle synchronized scrolling and zoom")
                            shortcutRow("Shift (hold)", "Show group selection overlay")
                            shortcutRow("Escape", "Clear group selection")
                        }
                    }

                    // Full Keyboard Reference
                    helpSection("Keyboard Shortcuts Reference") {
                        VStack(alignment: .leading, spacing: 4) {
                            Group {
                                shortcutCompact("V", "Select tool (default)")
                                shortcutCompact("P", "Pan tool")
                                shortcutCompact("W", "Window/Level tool")
                                shortcutCompact("Z", "Zoom tool")
                                shortcutCompact("O", "ROI W/L tool")
                                shortcutCompact("S", "ROI Stats tool")
                                shortcutCompact("D", "Ruler tool")
                                shortcutCompact("N", "Angle tool")
                                shortcutCompact("E", "Eraser tool")
                            }
                            Divider().padding(.vertical, 4)
                            Group {
                                shortcutCompact("A", "Auto window/level")
                                shortcutCompact("I", "Invert image")
                                shortcutCompact("F", "Fit to window")
                                shortcutCompact("R", "Reset view")
                                shortcutCompact("H", "Flip horizontal")
                                shortcutCompact("] / .", "Rotate CW 90\u{00B0}")
                                shortcutCompact("[ / ,", "Rotate CCW 90\u{00B0}")
                            }
                            Divider().padding(.vertical, 4)
                            Group {
                                shortcutCompact("X", "Cross-reference lines")
                                shortcutCompact("L", "Synchronized scrolling & zoom")
                                shortcutCompact("Shift", "Group selection overlay")
                                shortcutCompact("Tab", "Cycle panel")
                                shortcutCompact("Esc", "Clear selection")
                            }
                            Divider().padding(.vertical, 4)
                            Group {
                                shortcutCompact("1-4", "Layout presets")
                                shortcutCompact("Cmd+1-4", "Layout presets (menu)")
                                shortcutCompact("Cmd+Shift+M", "MPR layout")
                                shortcutCompact("Cmd+Shift+L", "Sync scrolling (menu)")
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 500, idealHeight: 700)
        .preferredColorScheme(.dark)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func helpSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(.callout, design: .monospaced).bold())
                .frame(width: 120, alignment: .trailing)
            Text(description)
                .font(.callout)
        }
    }

    private func toolRow(_ key: String, _ icon: String, _ name: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(.callout, design: .monospaced).bold())
                .frame(width: 24, alignment: .center)
            Image(systemName: icon)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.bold())
                Text(description).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func shortcutCompact(_ key: String, _ description: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(.caption, design: .monospaced).bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1))
                .cornerRadius(4)
                .frame(width: 100, alignment: .trailing)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
