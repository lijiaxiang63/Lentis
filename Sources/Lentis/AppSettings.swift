// AppSettings.swift
// Lentis
//
// App-wide user preferences, persisted to UserDefaults. Single source of truth
// shared by the Settings window (SettingsView) and the viewer (SynthSeg run
// options, overlay defaults, where generated mask/label files are written).
//
// The store is a plain ObservableObject singleton: the Settings UI binds to it,
// while the viewer reads `AppSettings.shared` on demand (SynthSeg) or subscribes
// to specific publishers (overlay opacity → live re-render). SynthSegRunner.locate
// also consults the persisted FreeSurfer paths so a GUI-launched app (which does
// not inherit the shell environment) can still find the binary.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Combine

/// Where SynthSeg / segmentation outputs are written by default.
enum OutputLocationMode: String, CaseIterable, Identifiable {
    /// Same folder as the opened NIfTI — findable next to the source file.
    case besideSource
    /// A user-chosen folder.
    case customFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .besideSource: return "Next to the source file"
        case .customFolder: return "A folder I choose"
        }
    }
}

final class AppSettings: ObservableObject {
    /// Shared app-wide instance. The viewer reads this; the Settings UI binds it.
    static let shared = AppSettings()

    // Persisted under these UserDefaults keys (kept in one place). The SynthSeg
    // binary key intentionally reuses SynthSegRunner's existing key so a path
    // chosen before this Settings page existed still resolves.
    enum Key {
        static let freesurferHome     = "LentisFreeSurferHome"
        static let synthSegBinary     = SynthSegRunner.defaultsKey
        static let synthSegRobust     = "LentisSynthSegRobust"
        static let synthSegParcellation = "LentisSynthSegParcellation"
        static let synthSegThreads    = "LentisSynthSegThreads"
        static let outputMode         = "LentisOutputLocationMode"
        static let customOutputDir    = "LentisCustomOutputDirectory"
        static let autoLoadResult     = "LentisAutoLoadSynthSegResult"
        static let writeBrainMask     = "LentisWriteDerivedBrainMask"
        static let overlayOpacity     = "LentisOverlayOpacity"
    }

    private let defaults: UserDefaults

    // MARK: - FreeSurfer / SynthSeg

    /// FreeSurfer install root ($FREESURFER_HOME). `mri_synthseg` is derived as
    /// `<home>/bin/mri_synthseg`. Empty ⇒ fall back to env/PATH/common locations.
    @Published var freesurferHome: String {
        didSet { defaults.set(freesurferHome, forKey: Key.freesurferHome) }
    }

    /// Explicit override for the `mri_synthseg` binary. Empty ⇒ derive from
    /// `freesurferHome` / environment. Wins over the derived path.
    @Published var synthSegBinaryPath: String {
        didSet { defaults.set(synthSegBinaryPath, forKey: Key.synthSegBinary) }
    }

    /// `--robust` (slower, more accurate inference). On by default.
    @Published var synthSegRobust: Bool {
        didSet { defaults.set(synthSegRobust, forKey: Key.synthSegRobust) }
    }

    /// `--parc` (anatomical parcellation — needed to auto-name regions and to
    /// show a colored atlas layer). On by default.
    @Published var synthSegParcellation: Bool {
        didSet { defaults.set(synthSegParcellation, forKey: Key.synthSegParcellation) }
    }

    /// CPU threads (`--threads`). 1 by default: FreeSurfer 8.1's Apple-Silicon
    /// TensorFlow can abort with a mismatched thread pool, so >1 is opt-in.
    @Published var synthSegThreads: Int {
        didSet { defaults.set(synthSegThreads, forKey: Key.synthSegThreads) }
    }

    // MARK: - Output location

    /// Where generated mask/label files land. Beside the source file by default
    /// (so the user can find them right next to their CT).
    @Published var outputMode: OutputLocationMode {
        didSet { defaults.set(outputMode.rawValue, forKey: Key.outputMode) }
    }

    /// The folder used when `outputMode == .customFolder`.
    @Published var customOutputDirectory: String {
        didSet { defaults.set(customOutputDirectory, forKey: Key.customOutputDir) }
    }

    /// Auto-load the SynthSeg parcellation as a visible atlas layer + brain
    /// constraint when the run completes.
    @Published var autoLoadSynthSegResult: Bool {
        didSet { defaults.set(autoLoadSynthSegResult, forKey: Key.autoLoadResult) }
    }

    /// Also write a binary brain mask (`<base>_brainmask.nii.gz`) on the original
    /// CT grid, alongside the SynthSeg label file.
    @Published var writeDerivedBrainMask: Bool {
        didSet { defaults.set(writeDerivedBrainMask, forKey: Key.writeBrainMask) }
    }

    // MARK: - Appearance

    /// Default opacity for the calcification/segmentation overlay (0…1).
    @Published var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: Key.overlayOpacity) }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // didSet does not fire for assignments inside init, so these reads do not
        // write back the defaults.
        freesurferHome = defaults.string(forKey: Key.freesurferHome) ?? ""
        synthSegBinaryPath = defaults.string(forKey: Key.synthSegBinary) ?? ""
        synthSegRobust = (defaults.object(forKey: Key.synthSegRobust) as? Bool) ?? true
        synthSegParcellation = (defaults.object(forKey: Key.synthSegParcellation) as? Bool) ?? true
        synthSegThreads = (defaults.object(forKey: Key.synthSegThreads) as? Int) ?? 1
        outputMode = OutputLocationMode(rawValue: defaults.string(forKey: Key.outputMode) ?? "")
            ?? .besideSource
        customOutputDirectory = defaults.string(forKey: Key.customOutputDir) ?? ""
        autoLoadSynthSegResult = (defaults.object(forKey: Key.autoLoadResult) as? Bool) ?? true
        writeDerivedBrainMask = (defaults.object(forKey: Key.writeBrainMask) as? Bool) ?? true
        overlayOpacity = (defaults.object(forKey: Key.overlayOpacity) as? Double) ?? 0.45
    }

    // MARK: - Resolved URLs

    var freesurferHomeURL: URL? {
        freesurferHome.isEmpty ? nil : URL(fileURLWithPath: freesurferHome)
    }
    var synthSegBinaryURL: URL? {
        synthSegBinaryPath.isEmpty ? nil : URL(fileURLWithPath: synthSegBinaryPath)
    }
    var customOutputDirectoryURL: URL? {
        customOutputDirectory.isEmpty ? nil : URL(fileURLWithPath: customOutputDirectory)
    }

    // MARK: - Output directory resolution

    /// Resolve a writable directory for generated files, honoring the chosen mode
    /// and falling back gracefully when the preferred folder is missing or
    /// read-only: preferred → source folder → ~/Documents/Lentis → temp/Lentis →
    /// the system temp dir. Pure + injectable for tests.
    static func resolveOutputDirectory(sourceFile: URL?,
                                       mode: OutputLocationMode,
                                       customDirectory: URL?,
                                       fileManager fm: FileManager = .default) -> URL {
        func isWritableDir(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
            return fm.isWritableFile(atPath: url.path)
        }

        var candidates: [URL] = []
        switch mode {
        case .besideSource:
            if let src = sourceFile { candidates.append(src.deletingLastPathComponent()) }
        case .customFolder:
            if let custom = customDirectory { candidates.append(custom) }
            if let src = sourceFile { candidates.append(src.deletingLastPathComponent()) }
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("Lentis", isDirectory: true))
        }
        candidates.append(fm.temporaryDirectory.appendingPathComponent("Lentis", isDirectory: true))

        for dir in candidates {
            if !isWritableDir(dir) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if isWritableDir(dir) { return dir }
        }
        return fm.temporaryDirectory
    }

    /// Strip a `.nii` / `.nii.gz` extension from a file name, returning a clean
    /// base for naming generated sidecar files. Falls back to "segmentation".
    static func niftiBaseName(_ fileName: String) -> String {
        var base = fileName
        if base.lowercased().hasSuffix(".nii.gz") { base = String(base.dropLast(7)) }
        else if base.lowercased().hasSuffix(".nii") { base = String(base.dropLast(4)) }
        return base.isEmpty ? "segmentation" : base
    }
}
