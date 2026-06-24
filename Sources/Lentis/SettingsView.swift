// SettingsView.swift
// Lentis
//
// The app's Settings window (⌘,). A native macOS preferences pane: a TabView of
// fixed-size forms, matching the system idiom used by Photos/Xcode/etc. Binds to
// the shared `AppSettings` (the single source of truth) plus a few read-only,
// model-derived status lines (FreeSurfer availability, the resolved output dir).
//
// Tabs:
//   • General — overlay default + where generated mask/label files go.
//   • FreeSurfer — locate mri_synthseg, SynthSeg run options.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettingsView(model: model, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            FreeSurferSettingsView(model: model, settings: settings)
                .tabItem { Label("FreeSurfer", systemImage: "brain.head.profile") }
        }
        // A fixed width is the macOS preferences convention; height grows to fit
        // each tab's form so neither tab is cramped or letter-boxed.
        .frame(width: 520)
        .tint(.lentisAccent)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Overlay opacity")
                    Slider(value: $settings.overlayOpacity, in: 0.1...1.0)
                    Text(settings.overlayOpacity, format: .percent.precision(.fractionLength(0)))
                        .font(.lentisReadout)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                        .monospacedDigit()
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Default translucency of the calcification / segmentation overlay. Each region’s color stays the same; this sets how strongly it tints the slice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Save generated files", selection: $settings.outputMode) {
                    ForEach(OutputLocationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if settings.outputMode == .customFolder {
                    HStack {
                        Text("Folder")
                        Spacer(minLength: Spacing.s)
                        Text(folderDisplay)
                            .font(.callout)
                            .foregroundStyle(settings.customOutputDirectory.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }

                LabeledContent("Files go to") {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(resolvedDirectoryDisplay)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(resolvedDirectory.path)
                    }
                }

                Toggle("Load the parcellation as a layer when SynthSeg finishes", isOn: $settings.autoLoadSynthSegResult)
                Toggle("Also write a binary brain mask (CT grid)", isOn: $settings.writeDerivedBrainMask)
            } header: {
                Text("Output Files")
            } footer: {
                Text("SynthSeg writes a label file (`…_synthseg.nii.gz`) and, optionally, a brain mask (`…_brainmask.nii.gz`); exports land here too. “Next to the source file” keeps them beside your CT; if that folder is read-only Lentis falls back to ~/Documents/Lentis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                exportNameRow(role: "Mask", icon: "square.dashed",
                              text: $settings.exportMaskSuffix,
                              fallback: AppSettings.defaultMaskSuffix)
                exportNameRow(role: "Atlas", icon: "square.stack.3d.up.fill",
                              text: $settings.exportAtlasSuffix,
                              fallback: AppSettings.defaultAtlasSuffix)

                // Live, fully-assembled output names so the user watches each file
                // name build from base + (sanitized) suffix + extension.
                LabeledContent("Preview") {
                    VStack(alignment: .trailing, spacing: 2) {
                        composedFilename(settings.exportMaskSuffix, fallback: AppSettings.defaultMaskSuffix)
                        composedFilename(settings.exportAtlasSuffix, fallback: AppSettings.defaultAtlasSuffix)
                    }
                }
            } header: {
                Text("Export File Names")
            } footer: {
                Text("Exports save directly (no dialog) to the output folder above. The atlas also writes a matching `…_LUT.txt`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Example base name (the open file, sans extension) for the live preview.
    private var exampleBase: String {
        model.loadedFileName.isEmpty ? "scan" : AppSettings.niftiBaseName(model.loadedFileName)
    }

    private func suffixPreview(_ value: String, _ fallback: String) -> String {
        AppSettings.sanitizedSuffix(value, fallback: fallback)
    }

    /// A grouped-Form filename-builder row: an icon + role label, with the value
    /// the single editable suffix token (set apart in a faint accent capsule) next
    /// to a fixed `.nii.gz` chip — so the row reads as the one editable part of an
    /// assembling filename rather than a stray trailing text field. Stays a native
    /// `LabeledContent` row (no glass cards that would fight the grouped form).
    private func exportNameRow(role: String, icon: String,
                               text: Binding<String>, fallback: String) -> some View {
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                TextField(fallback, text: text, prompt: Text(fallback))
                    .textFieldStyle(.plain)
                    .font(.lentisReadout)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 120)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, 3)
                    .background(Color.lentisAccent.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.lentisAccent.opacity(0.35), lineWidth: 0.5))

                Text(".nii.gz")
                    .font(.lentisReadout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        } label: {
            Label {
                Text(role)
            } icon: {
                Image(systemName: icon).foregroundStyle(Color.lentisAccent)
            }
        }
    }

    /// The full assembled filename for the Preview row: the dimmed base, the
    /// (sanitized) suffix span accented so the editable part stands out, and the
    /// dimmed extension — selectable so the user can copy the exact output name.
    private func composedFilename(_ rawSuffix: String, fallback: String) -> some View {
        let base = Text(exampleBase).foregroundStyle(.secondary)
        let suffix = Text(suffixPreview(rawSuffix, fallback)).foregroundStyle(Color.lentisAccent)
        let ext = Text(".nii.gz").foregroundStyle(.secondary)
        return Text("\(base)\(suffix)\(ext)")
            .font(.lentisReadout)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    private var folderDisplay: String {
        settings.customOutputDirectory.isEmpty
            ? "Not chosen"
            : abbreviate(URL(fileURLWithPath: settings.customOutputDirectory))
    }

    private var resolvedDirectory: URL {
        AppSettings.resolveOutputDirectory(sourceFile: model.loadedFileURL,
                                           mode: settings.outputMode,
                                           customDirectory: settings.customOutputDirectoryURL)
    }

    private var resolvedDirectoryDisplay: String { abbreviate(resolvedDirectory) }

    private func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for generated mask and label files"
        if panel.runModal() == .OK, let url = panel.url {
            settings.customOutputDirectory = url.path
        }
    }
}

// MARK: - FreeSurfer

private struct FreeSurferSettingsView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var settings: AppSettings

    /// Live availability of mri_synthseg given the current settings.
    private var resolvedBinary: URL? {
        SynthSegRunner.locate(userOverride: settings.synthSegBinaryURL)
    }

    var body: some View {
        Form {
            Section {
                statusRow
            } header: {
                Text("SynthSeg")
            } footer: {
                Text("Lentis runs FreeSurfer’s `mri_synthseg` to derive a brain mask / parcellation from a CT. Point it at your FreeSurfer install; a GUI-launched app can’t see your shell’s $FREESURFER_HOME, so set it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Locations") {
                pathRow(title: "FreeSurfer home",
                        placeholder: "/Applications/freesurfer/8.1.0",
                        text: $settings.freesurferHome,
                        chooseDirectories: true,
                        chooseMessage: "Choose the FreeSurfer install folder ($FREESURFER_HOME)")

                pathRow(title: "mri_synthseg (optional)",
                        placeholder: "Derived from FreeSurfer home",
                        text: $settings.synthSegBinaryPath,
                        chooseDirectories: false,
                        chooseMessage: "Locate the mri_synthseg executable")
            }

            Section {
                Toggle("Robust inference (`--robust`)", isOn: $settings.synthSegRobust)
                Toggle("Anatomical parcellation (`--parc`)", isOn: $settings.synthSegParcellation)
                Stepper(value: $settings.synthSegThreads, in: 1...16) {
                    LabeledContent("CPU threads", value: "\(settings.synthSegThreads)")
                }
            } header: {
                Text("Run Options")
            } footer: {
                Text("SynthSeg runs on the CPU (the Apple-Silicon GPU path aborts), so a full run takes several minutes. Parcellation enables anatomical region naming. More threads can be faster but may be unstable on Apple Silicon — raise it only if runs stay stable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusRow: some View {
        if let binary = resolvedBinary {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("mri_synthseg found")
                        .foregroundStyle(.primary)
                    Text((binary.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Label {
                Text("mri_synthseg not found — set a FreeSurfer home below.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func pathRow(title: String, placeholder: String, text: Binding<String>,
                         chooseDirectories: Bool, chooseMessage: String) -> some View {
        HStack(spacing: Spacing.s) {
            TextField(title, text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .truncationMode(.middle)
            Button("Choose…") {
                choose(into: text, directories: chooseDirectories, message: chooseMessage)
            }
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
    }

    private func choose(into text: Binding<String>, directories: Bool, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url {
            text.wrappedValue = url.path
        }
    }
}
