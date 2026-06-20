// CineToolbar.swift
// OpenDicomViewer
//
// Per-panel toolbar that appears at the top of each panel when a multi-frame
// series is loaded. Provides controls for cine playback including play/pause,
// frame-by-frame stepping, a frame scrubber slider, speed selection, FPS
// display, and loop mode toggle.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// Per-panel toolbar for cine/multi-frame playback controls.
/// Appears at the top of each panel when a multi-frame series is assigned.
struct CineToolbar: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState

    private let speedOptions: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]

    private var effectiveFPS: Double {
        panel.cineRate * panel.playbackSpeed
    }

    private var frameRangeUpperBound: Double {
        max(1.0, Double(panel.numberOfFrames - 1))
    }

    var body: some View {
        HStack(spacing: 4) {
            // Play/Pause button
            Button(action: {
                model.toggleCinePlayback(panel)
            }) {
                Image(systemName: panel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(.caption))
            }
            .buttonStyle(.plain)
            .help(panel.isPlaying ? "Pause" : "Play")

            // Step buttons (only when paused)
            if !panel.isPlaying {
                Button(action: {
                    model.stepCineFrame(panel, delta: -1)
                }) {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(.caption))
                }
                .buttonStyle(.plain)
                .help("Previous frame")

                Button(action: {
                    model.stepCineFrame(panel, delta: 1)
                }) {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(.caption))
                }
                .buttonStyle(.plain)
                .help("Next frame")
            }

            Divider().frame(height: 16)

            // Frame scrubber
            Slider(
                value: Binding(
                    get: { Double(panel.currentFrameIndex) },
                    set: { value in
                        if panel.isPlaying {
                            model.toggleCinePlayback(panel)
                        }
                        model.setCineFrame(panel, frame: Int(value))
                    }
                ),
                in: 0...frameRangeUpperBound,
                step: 1
            ) {
                Text("Frame")
            }
            .frame(width: 200)

            Divider().frame(height: 16)

            // Frame counter
            Text("Frame \(panel.currentFrameIndex + 1) / \(panel.numberOfFrames)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            // Speed control menu
            Menu {
                ForEach(speedOptions, id: \.self) { speed in
                    Button(speedLabel(speed)) {
                        model.setCinePlaybackSpeed(panel, speed: speed)
                    }
                }
            } label: {
                Text(speedLabel(panel.playbackSpeed))
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")

            // FPS display
            Text(String(format: "%.0f fps", effectiveFPS))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            // Loop toggle
            Button(action: {
                panel.loopPlayback.toggle()
            }) {
                Image(systemName: "repeat")
                    .font(.system(.caption))
                    .foregroundStyle(panel.loopPlayback ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(panel.loopPlayback ? "Loop on" : "Loop off")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .cornerRadius(6)
    }

    private func speedLabel(_ speed: Double) -> String {
        if speed == speed.rounded() {
            return String(format: "%.0fx", speed)
        } else {
            return String(format: "%.2gx", speed)
        }
    }
}
