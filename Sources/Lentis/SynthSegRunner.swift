// SynthSegRunner.swift
// Lentis
//
// Phase 9 — runs FreeSurfer's `mri_synthseg` on a CT (via Foundation.Process,
// off-main, with streamed progress + cancel) to derive a brain mask /
// parcellation when the user hasn't loaded one. The output parcellation is then
// loaded as an overlay layer: used both to exclude skull (nonzero = brain) and
// to auto-name calcifications by anatomical location (centroid → FreeSurfer LUT).
//
// Locating the binary: $FREESURFER_HOME/bin, then PATH, then common install
// dirs, then a user-chosen path persisted in UserDefaults. The process
// environment derives FREESURFER_HOME from the binary so it works even when the
// app is launched from Finder (which doesn't inherit the shell environment).
//
// Requires an unsandboxed build + a working FreeSurfer install. The "load a
// brain mask" path and box-bounded Method A both work without SynthSeg.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

enum SynthSegError: LocalizedError {
    case notFound
    case launchFailed(String)
    case nonZeroExit(Int32)
    case cancelled
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "mri_synthseg not found. Set $FREESURFER_HOME, or choose the binary."
        case .launchFailed(let m): return "Could not launch SynthSeg: \(m)"
        case .nonZeroExit(let c): return "SynthSeg exited with status \(c)."
        case .cancelled: return "SynthSeg was cancelled."
        case .outputMissing: return "SynthSeg finished but produced no output."
        }
    }
}

final class SynthSegRunner {
    static let defaultsKey = "LentisSynthSegBinaryPath"

    private var process: Process?
    private var cancelled = false

    // MARK: - Locating the binary

    /// Find `mri_synthseg`: explicit override → persisted choice →
    /// $FREESURFER_HOME/bin → PATH → common install locations.
    static func locate(userOverride: URL? = nil) -> URL? {
        let fm = FileManager.default
        func ok(_ path: String) -> Bool { fm.isExecutableFile(atPath: path) }

        if let u = userOverride, ok(u.path) { return u }
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), ok(stored) {
            return URL(fileURLWithPath: stored)
        }
        let env = ProcessInfo.processInfo.environment
        if let home = env["FREESURFER_HOME"], ok(home + "/bin/mri_synthseg") {
            return URL(fileURLWithPath: home + "/bin/mri_synthseg")
        }
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") where ok(String(dir) + "/mri_synthseg") {
                return URL(fileURLWithPath: String(dir) + "/mri_synthseg")
            }
        }
        // Common install roots, including versioned /Applications/freesurfer/<ver>.
        var candidates = ["/usr/local/freesurfer/bin/mri_synthseg",
                          "/Applications/freesurfer/bin/mri_synthseg"]
        if let versions = try? fm.contentsOfDirectory(atPath: "/Applications/freesurfer") {
            for v in versions { candidates.append("/Applications/freesurfer/\(v)/bin/mri_synthseg") }
        }
        return candidates.first(where: ok).map { URL(fileURLWithPath: $0) }
    }

    static func isAvailable(userOverride: URL? = nil) -> Bool { locate(userOverride: userOverride) != nil }

    /// Persist a user-chosen binary path.
    static func setUserBinary(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
    }

    // MARK: - Running

    /// Launch SynthSeg. `progress` receives streamed stdout/stderr text on the
    /// main queue; `completion` fires on the main queue. Non-blocking.
    func run(inputURL: URL, outputURL: URL, parcellation: Bool, robust: Bool,
             userOverride: URL? = nil,
             progress: @escaping (String) -> Void,
             completion: @escaping (Result<URL, SynthSegError>) -> Void) {
        guard let binary = SynthSegRunner.locate(userOverride: userOverride) else {
            completion(.failure(.notFound)); return
        }
        cancelled = false
        let process = Process()
        process.executableURL = binary
        var args = ["--i", inputURL.path, "--o", outputURL.path]
        if parcellation { args.append("--parc") }
        if robust { args.append("--robust") }
        process.arguments = args
        process.environment = SynthSegRunner.environment(for: binary)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { progress(text) }
        }
        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            let cancelled = self.cancelled
            DispatchQueue.main.async {
                if cancelled { completion(.failure(.cancelled)) }
                else if status != 0 { completion(.failure(.nonZeroExit(status))) }
                else if !FileManager.default.fileExists(atPath: outputURL.path) { completion(.failure(.outputMissing)) }
                else { completion(.success(outputURL)) }
            }
        }
        self.process = process
        do { try process.run() }
        catch { completion(.failure(.launchFailed(error.localizedDescription))) }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    /// Environment for the child: FreeSurfer wants FREESURFER_HOME set and its
    /// bin on PATH. Derive FREESURFER_HOME from the binary (.../<home>/bin/...).
    private static func environment(for binary: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = binary.deletingLastPathComponent().deletingLastPathComponent().path
        env["FREESURFER_HOME"] = env["FREESURFER_HOME"] ?? home
        let fsBin = home + "/bin"
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        if !existing.contains(fsBin) { env["PATH"] = "\(fsBin):/usr/local/bin:/usr/bin:/bin:" + existing }
        if env["SUBJECTS_DIR"] == nil { env["SUBJECTS_DIR"] = home + "/subjects" }
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// Reduce a streamed chunk to a short status line for the inspector.
    static func briefStatus(_ chunk: String) -> String? {
        let lines = chunk.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last(where: { !$0.isEmpty })
    }
}
