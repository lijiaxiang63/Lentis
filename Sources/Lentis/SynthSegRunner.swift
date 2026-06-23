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
    case nonZeroExit(Int32, tail: String)
    /// The child was killed by a signal (e.g. SIGABRT=6 from a TensorFlow abort).
    case aborted(signal: Int32, tail: String)
    case cancelled
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "mri_synthseg not found. Set $FREESURFER_HOME, or choose the binary."
        case .launchFailed(let m): return "Could not launch SynthSeg: \(m)"
        case .nonZeroExit(let c, let tail):
            return "SynthSeg exited with status \(c)." + Self.tailSuffix(tail)
        case .aborted(let sig, let tail):
            let name = Self.signalName(sig)
            return "SynthSeg crashed (signal \(sig)\(name.map { " · \($0)" } ?? "")). "
                + "This is usually a TensorFlow/Apple-Silicon abort — try updating FreeSurfer "
                + "(fs8.2 SynthSeg darwin_arm64 update)." + Self.tailSuffix(tail)
        case .cancelled: return "SynthSeg was cancelled."
        case .outputMissing: return "SynthSeg finished but produced no output."
        }
    }

    private static func tailSuffix(_ tail: String) -> String {
        let t = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "" : "\n\n\(t)"
    }

    private static func signalName(_ sig: Int32) -> String? {
        switch sig {
        case 4: return "SIGILL (illegal instruction)"
        case 6: return "SIGABRT (abort)"
        case 9: return "SIGKILL (likely out of memory)"
        case 11: return "SIGSEGV (segfault)"
        default: return nil
        }
    }
}

final class SynthSegRunner {
    static let defaultsKey = "LentisSynthSegBinaryPath"

    private var process: Process?
    private var cancelled = false
    /// Rolling tail of the child's combined stdout/stderr, surfaced on failure
    /// so a TensorFlow abort (SIGABRT) is diagnosable instead of "status 6".
    /// Touched from the pipe's readability queue and the termination handler, so
    /// guard it with a lock.
    private var outputTail = ""
    private let tailLock = NSLock()

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
    ///
    /// `ct` adds `--ct` (clip Hounsfield to [0,80]) — the documented correct way
    /// to run SynthSeg on a CT, which the loaded brain CT always is here. The run
    /// is pinned to CPU (`--cpu`, single-threaded) because the FreeSurfer 8.1
    /// Apple-Silicon TensorFlow aborts with SIGABRT (reported by the app as
    /// "status 6") when the GPU/Metal path initializes under a GUI-launched
    /// process; CPU inference is slower but does not abort.
    func run(inputURL: URL, outputURL: URL, parcellation: Bool, robust: Bool,
             ct: Bool = false, threads: Int = 1,
             userOverride: URL? = nil,
             progress: @escaping (String) -> Void,
             completion: @escaping (Result<URL, SynthSegError>) -> Void) {
        guard let binary = SynthSegRunner.locate(userOverride: userOverride) else {
            completion(.failure(.notFound)); return
        }
        setCancelled(false)
        tailLock.lock(); outputTail = ""; tailLock.unlock()
        let process = Process()
        process.executableURL = binary
        var args = ["--i", inputURL.path, "--o", outputURL.path]
        if parcellation { args.append("--parc") }
        if robust { args.append("--robust") }
        if ct { args.append("--ct") }
        args.append(contentsOf: ["--cpu", "--threads", String(max(1, threads))])
        process.arguments = args
        process.environment = SynthSegRunner.environment(for: binary)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendTail(text)
            DispatchQueue.main.async { progress(text) }
        }
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Drain anything buffered after the last readability callback.
            if let rest = try? pipe.fileHandleForReading.readToEnd(),
               !rest.isEmpty, let text = String(data: rest, encoding: .utf8) {
                self?.appendTail(text)
            }
            let status = proc.terminationStatus
            let bySignal = proc.terminationReason == .uncaughtSignal
            let cancelled = self?.isCancelled ?? false
            let tail = self?.readTail() ?? ""
            DispatchQueue.main.async {
                if cancelled { completion(.failure(.cancelled)) }
                else if bySignal { completion(.failure(.aborted(signal: status, tail: tail))) }
                else if status != 0 { completion(.failure(.nonZeroExit(status, tail: tail))) }
                else if !FileManager.default.fileExists(atPath: outputURL.path) { completion(.failure(.outputMissing)) }
                else { completion(.success(outputURL)) }
            }
        }
        self.process = process
        do { try process.run() }
        catch { completion(.failure(.launchFailed(error.localizedDescription))) }
    }

    func cancel() {
        setCancelled(true)
        process?.terminate()
    }

    // `cancelled` is written from the caller (main) and read from the process
    // termination queue, so guard it with the same lock as the output tail.
    private func setCancelled(_ v: Bool) { tailLock.lock(); cancelled = v; tailLock.unlock() }
    private var isCancelled: Bool { tailLock.lock(); defer { tailLock.unlock() }; return cancelled }

    /// Keep the last ~4 KB of combined output so a crash can be explained.
    private func appendTail(_ text: String) {
        tailLock.lock(); defer { tailLock.unlock() }
        outputTail += text
        if outputTail.count > 4096 { outputTail = String(outputTail.suffix(4096)) }
    }

    private func readTail() -> String {
        tailLock.lock(); defer { tailLock.unlock() }
        return outputTail
    }

    /// Environment for the child: FreeSurfer wants FREESURFER_HOME set and its
    /// bin on PATH. Derive FREESURFER_HOME from the binary (.../<home>/bin/...).
    ///
    /// Robustness for GUI launches: a Finder/`open`-launched app inherits a sparse
    /// environment, while a dev (`swift run`) launch can inherit a *toxic* one
    /// (a conda `PYTHONHOME`/`PYTHONPATH`/`VIRTUAL_ENV` that hijacks fspython's
    /// interpreter — observed to make fspython exit 1 with a "Python path
    /// configuration" error). The fspython wrapper sets its own `PYTHONPATH`/
    /// `PYTHONHOME`, so we strip any inherited Python interpreter vars, and we
    /// guarantee a writable `HOME`/`TMPDIR` (TensorFlow/Keras write scratch and
    /// `~/.keras`; a missing/unwritable HOME is another abort source).
    private static func environment(for binary: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = binary.deletingLastPathComponent().deletingLastPathComponent().path
        env["FREESURFER_HOME"] = env["FREESURFER_HOME"] ?? home
        let fsBin = home + "/bin"
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        if !existing.contains(fsBin) { env["PATH"] = "\(fsBin):/usr/local/bin:/usr/bin:/bin:" + existing }
        if env["SUBJECTS_DIR"] == nil { env["SUBJECTS_DIR"] = home + "/subjects" }
        env["PYTHONUNBUFFERED"] = "1"

        // Don't let an inherited Python environment hijack fspython.
        for key in ["PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONEXECUTABLE",
                    "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV"] {
            env.removeValue(forKey: key)
        }
        // Quiet TensorFlow + keep BLAS single-threaded (matches --threads 1; a
        // mismatched thread pool is a known macOS-arm64 abort trigger).
        env["TF_CPP_MIN_LOG_LEVEL"] = env["TF_CPP_MIN_LOG_LEVEL"] ?? "3"
        env["OMP_NUM_THREADS"] = env["OMP_NUM_THREADS"] ?? "1"

        // Guarantee a usable HOME + TMPDIR (sparse GUI env may lack them).
        let fm = FileManager.default
        if (env["HOME"].map { !fm.isWritableFile(atPath: $0) } ?? true) {
            env["HOME"] = NSHomeDirectory()
        }
        if (env["TMPDIR"].map { !fm.isWritableFile(atPath: $0) } ?? true) {
            env["TMPDIR"] = NSTemporaryDirectory()
        }
        return env
    }

    /// Reduce a streamed chunk to a short status line for the inspector.
    static func briefStatus(_ chunk: String) -> String? {
        let lines = chunk.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last(where: { !$0.isEmpty })
    }
}
