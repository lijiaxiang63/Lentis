// BIDSDataset.swift
// Lentis
//
// Pure, dependency-free model for browsing a BIDS (Brain Imaging Data Structure)
// dataset folder: parse a BIDS filename's entities, scan a dataset root into a
// subject → session → datatype → image-file hierarchy, and build BIDS-valid
// derivative output names/paths. No SwiftUI, no AppKit — fully unit-testable
// (the scan reads only directory listings + file sizes, never NIfTI headers).
//
// See https://bids-specification.readthedocs.io. Lentis only surfaces NIfTI
// images (.nii / .nii.gz); other files are ignored. A folder that isn't a valid
// BIDS dataset still opens as a flat "loose" list of every NIfTI it contains.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

// MARK: - Entities

/// A parsed BIDS file name: the ordered `key-value` entity pairs, the trailing
/// suffix, and the (compound) extension.
///
/// e.g. `sub-01_ses-02_acq-mprage_T1w.nii.gz` →
///      pairs [(sub,01),(ses,02),(acq,mprage)], suffix "T1w", ext "nii.gz".
struct BIDSEntities: Equatable {
    /// Ordered key-value entity pairs, in file-name order.
    var pairs: [(key: String, value: String)]
    /// The trailing suffix (the dash-less token before the extension), e.g. "T1w".
    var suffix: String
    /// Extension without the leading dot ("nii" or "nii.gz").
    var ext: String

    // Tuple arrays aren't auto-Equatable, so compare element-wise.
    static func == (l: BIDSEntities, r: BIDSEntities) -> Bool {
        l.suffix == r.suffix && l.ext == r.ext &&
        l.pairs.count == r.pairs.count &&
        zip(l.pairs, r.pairs).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    /// The value of a given entity key, if present (e.g. `value(for: "sub")`).
    func value(for key: String) -> String? { pairs.first { $0.key == key }?.value }

    /// Parse a BIDS file name into entities + suffix + extension. Robust to
    /// non-BIDS names (no key-value tokens → everything becomes the suffix).
    static func parse(fileName: String) -> BIDSEntities {
        var name = fileName
        var ext = ""
        let lower = name.lowercased()
        if lower.hasSuffix(".nii.gz") { ext = "nii.gz"; name = String(name.dropLast(7)) }
        else if lower.hasSuffix(".nii") { ext = "nii"; name = String(name.dropLast(4)) }
        else if let dot = name.lastIndex(of: ".") {
            ext = String(name[name.index(after: dot)...]); name = String(name[..<dot])
        }

        var pairs: [(key: String, value: String)] = []
        var suffix = ""
        for token in name.split(separator: "_", omittingEmptySubsequences: true).map(String.init) {
            // A `key-value` token has a dash that is not the first character.
            if let dash = token.firstIndex(of: "-"), dash != token.startIndex {
                pairs.append((key: String(token[..<dash]),
                              value: String(token[token.index(after: dash)...])))
            } else {
                // A dash-less token is the suffix; the last one wins.
                suffix = token
            }
        }
        return BIDSEntities(pairs: pairs, suffix: suffix, ext: ext)
    }

    /// Build a BIDS *derivative* file name from these (source) entities: keep all
    /// source entities, set/replace `desc-<desc>`, use the given suffix + extension.
    ///
    /// e.g. desc "calc", suffix "mask" →
    ///      `sub-01_ses-02_acq-mprage_desc-calc_mask.nii.gz`.
    func derivativeName(desc: String?, suffix newSuffix: String, ext newExt: String? = nil) -> String {
        // BIDS labels must be alphanumeric — sanitize carried-over entity values
        // (and the desc) so a slightly-off source name (e.g. `acq-pre-post`)
        // can't emit a validator-rejecting derivative name.
        func clean(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber }) }
        var kept = pairs.filter { $0.key != "desc" }.map { (key: $0.key, value: clean($0.value)) }
        if let desc {
            let d = clean(desc)
            if !d.isEmpty { kept.append((key: "desc", value: d)) }
        }
        let entityString = kept.map { "\($0.key)-\($0.value)" }.joined(separator: "_")
        let e = newExt ?? (ext.isEmpty ? "nii.gz" : ext)
        let stem = entityString.isEmpty ? newSuffix : "\(entityString)_\(newSuffix)"
        return "\(stem).\(e)"
    }
}

// MARK: - Image file

/// One NIfTI image within a dataset, with its parsed entities + datatype.
struct BIDSImageFile: Identifiable, Equatable {
    let url: URL
    let entities: BIDSEntities
    /// The datatype folder it lives in (anat/func/dwi/ct/…); nil for a loose file.
    let datatype: String?
    let fileSize: Int64

    var id: URL { url }
    var fileName: String { url.lastPathComponent }

    /// "sub-01" / "ses-02", or nil when the entity is absent.
    var subjectLabel: String? { entities.value(for: "sub").map { "sub-\($0)" } }
    var sessionLabel: String? { entities.value(for: "ses").map { "ses-\($0)" } }

    /// A genuine BIDS subject file (has a `sub-` entity). Loose files are false.
    var isBIDS: Bool { entities.value(for: "sub") != nil }

    /// Title for the navigator row: the suffix (T1w/FLAIR/ct/…), else the name.
    var displayTitle: String { entities.suffix.isEmpty ? fileName : entities.suffix }

    /// Entity chips shown under the title — everything except sub/ses (which are
    /// implied by the row's position in the subject/session tree).
    var detailChips: [String] {
        entities.pairs
            .filter { $0.key != "sub" && $0.key != "ses" }
            .map { "\($0.key)-\($0.value)" }
    }

    /// Combine a base `desc` label with this file's source-modality suffix so
    /// that derivatives of two sibling modalities (e.g. T1w vs ct of the SAME
    /// subject/session) get distinct, BIDS-valid `desc-` labels and can't
    /// silently overwrite one another. e.g. base "calc" + suffix "T1w" →
    /// "calcT1w"; base "brain" + "ct" → "brainCt". Empty source suffix → base.
    func descIncludingModality(_ base: String) -> String {
        let src = entities.suffix.filter { $0.isLetter || $0.isNumber }
        guard !src.isEmpty else { return base }
        return base + src.prefix(1).uppercased() + src.dropFirst()
    }
}

// MARK: - Session / Subject

struct BIDSSession: Identifiable, Equatable {
    /// "ses-01", or nil for the implicit single session (no `ses-*` folders).
    let label: String?
    let files: [BIDSImageFile]
    var id: String { label ?? "__implicit__" }
}

struct BIDSSubject: Identifiable, Equatable {
    let label: String                 // "sub-01"
    let sessions: [BIDSSession]
    var id: String { label }
    var imageCount: Int { sessions.reduce(0) { $0 + $1.files.count } }
    /// Render a session level only when sessions are named (i.e. real `ses-*`
    /// folders). A lone implicit session collapses straight to its files.
    var showsSessions: Bool { sessions.contains { $0.label != nil } }
}

// MARK: - Dataset

struct BIDSDataset: Equatable {
    let rootURL: URL
    /// Display name (dataset_description.json "Name", else the folder name).
    let name: String
    let subjects: [BIDSSubject]
    /// NIfTI files found when the folder isn't a valid BIDS dataset (flat list).
    let looseFiles: [BIDSImageFile]
    /// True for a real BIDS tree; false for a loose folder of NIfTI files.
    let isBIDS: Bool

    var subjectCount: Int { subjects.count }
    var imageCount: Int {
        subjects.reduce(0) { $0 + $1.imageCount } + looseFiles.count
    }

    /// Every image in display order (subjects → sessions → files, then loose).
    var allFiles: [BIDSImageFile] {
        var out: [BIDSImageFile] = []
        for s in subjects { for ses in s.sessions { out.append(contentsOf: ses.files) } }
        out.append(contentsOf: looseFiles)
        return out
    }

    /// The image to auto-load when the folder is opened (first available).
    var firstImage: BIDSImageFile? { allFiles.first }

    /// Look up the parsed file record for a URL (so a freshly-loaded URL can be
    /// matched back to its dataset entities for derivative naming + highlighting).
    func file(for url: URL) -> BIDSImageFile? {
        allFiles.first { $0.url == url }
    }
}

// MARK: - Scanning

extension BIDSDataset {

    /// A folder looks like BIDS if it has a `dataset_description.json`, a
    /// `participants.tsv`, or at least one `sub-*` subdirectory.
    static func looksLikeBIDS(at root: URL, fileManager fm: FileManager = .default) -> Bool {
        if fm.fileExists(atPath: root.appendingPathComponent("dataset_description.json").path) { return true }
        if fm.fileExists(atPath: root.appendingPathComponent("participants.tsv").path) { return true }
        return subdirectories(of: root, fm: fm).contains { $0.lastPathComponent.hasPrefix("sub-") }
    }

    static func isNiftiURL(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return n.hasSuffix(".nii") || n.hasSuffix(".nii.gz")
    }

    /// Recognized BIDS datatype folder names (plus this project's `ct` extension).
    /// Only NIfTI inside these folders is surfaced as a datatype image — so a
    /// stray/scratch folder (qc/, figures/, …) can't fabricate an invalid
    /// datatype that would later become an invalid derivatives subfolder.
    static let knownDatatypes: Set<String> = [
        "anat", "func", "dwi", "fmap", "perf", "pet",
        "meg", "eeg", "ieeg", "beh", "micr", "motion", "nirs", "ct",
    ]

    /// Scan a folder into a dataset. A valid BIDS tree builds the subject/session
    /// hierarchy; otherwise every NIfTI found (recursively, skipping
    /// derivatives/sourcedata/code) is returned as a flat loose list. Returns nil
    /// only when the folder contains no NIfTI at all.
    static func scan(at root: URL, fileManager fm: FileManager = .default) -> BIDSDataset? {
        let name = datasetName(at: root, fm: fm)
        if looksLikeBIDS(at: root, fileManager: fm) {
            let subjects = scanSubjects(root: root, fm: fm)
            if !subjects.isEmpty {
                return BIDSDataset(rootURL: root, name: name,
                                   subjects: subjects, looseFiles: [], isBIDS: true)
            }
        }
        let loose = looseNifti(root: root, fm: fm)
        guard !loose.isEmpty else { return nil }
        return BIDSDataset(rootURL: root, name: name,
                           subjects: [], looseFiles: loose, isBIDS: false)
    }

    // MARK: - Derivative output paths

    /// The BIDS derivatives directory for a source image under a named pipeline:
    /// `<root>/derivatives/<pipeline>/sub-XX/[ses-YY/]<datatype>/`. Pure (builds
    /// the URL only); nil when the file isn't a BIDS subject file. The caller
    /// creates the directory tree.
    func derivativesDirectory(pipeline: String, for file: BIDSImageFile) -> URL? {
        guard isBIDS, let sub = file.subjectLabel else { return nil }
        var dir = rootURL
            .appendingPathComponent("derivatives", isDirectory: true)
            .appendingPathComponent(pipeline, isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
        if let ses = file.sessionLabel { dir = dir.appendingPathComponent(ses, isDirectory: true) }
        dir = dir.appendingPathComponent(file.datatype ?? "anat", isDirectory: true)
        return dir
    }

    // MARK: - Scan internals

    private static func datasetName(at root: URL, fm: FileManager) -> String {
        let descURL = root.appendingPathComponent("dataset_description.json")
        if let data = try? Data(contentsOf: descURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let n = (obj["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty {
            return n
        }
        return root.lastPathComponent
    }

    private static func subdirectories(of dir: URL, fm: FileManager) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func niftiURLs(in dir: URL, fm: FileManager) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { isNiftiURL($0) }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(n)
    }

    private static func makeImageFile(_ url: URL, datatype: String?) -> BIDSImageFile {
        BIDSImageFile(url: url,
                      entities: BIDSEntities.parse(fileName: url.lastPathComponent),
                      datatype: datatype,
                      fileSize: fileSize(url))
    }

    /// Natural (numeric-aware) ordering so sub-2 sorts before sub-10.
    private static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    private static func sortFiles(_ files: [BIDSImageFile]) -> [BIDSImageFile] {
        files.sorted {
            let da = $0.datatype ?? "", db = $1.datatype ?? ""
            if da != db { return naturalLess(da, db) }
            return naturalLess($0.fileName, $1.fileName)
        }
    }

    /// Gather every NIfTI under a session/subject container: those in recognized
    /// datatype subfolders (datatype = the folder name) plus any directly inside
    /// (datatype nil). Non-datatype subfolders (ses-*, qc/, scratch dirs) are
    /// skipped, so a fabricated datatype can't leak into a derivatives path.
    private static func gatherFiles(in container: URL, fm: FileManager) -> [BIDSImageFile] {
        var files = niftiURLs(in: container, fm: fm).map { makeImageFile($0, datatype: nil) }
        for sub in subdirectories(of: container, fm: fm) {
            let dt = sub.lastPathComponent
            guard knownDatatypes.contains(dt.lowercased()) else { continue }
            files.append(contentsOf: niftiURLs(in: sub, fm: fm).map { makeImageFile($0, datatype: dt) })
        }
        return sortFiles(files)
    }

    private static func scanSubjects(root: URL, fm: FileManager) -> [BIDSSubject] {
        let subjectDirs = subdirectories(of: root, fm: fm)
            .filter { $0.lastPathComponent.hasPrefix("sub-") }
            .sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }

        var subjects: [BIDSSubject] = []
        for subDir in subjectDirs {
            let sessionDirs = subdirectories(of: subDir, fm: fm)
                .filter { $0.lastPathComponent.hasPrefix("ses-") }
                .sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }

            var sessions: [BIDSSession] = []
            if sessionDirs.isEmpty {
                let files = gatherFiles(in: subDir, fm: fm)
                if !files.isEmpty { sessions.append(BIDSSession(label: nil, files: files)) }
            } else {
                // Subject-level images (directly under sub-XX/ or its datatype
                // folders) sitting ALONGSIDE ses-* folders would otherwise be
                // dropped — keep them as a leading implicit session. gatherFiles
                // skips ses-* (not a datatype), so it won't re-list session files.
                let rootFiles = gatherFiles(in: subDir, fm: fm)
                if !rootFiles.isEmpty { sessions.append(BIDSSession(label: nil, files: rootFiles)) }
                for sesDir in sessionDirs {
                    let files = gatherFiles(in: sesDir, fm: fm)
                    if !files.isEmpty {
                        sessions.append(BIDSSession(label: sesDir.lastPathComponent, files: files))
                    }
                }
            }
            if !sessions.isEmpty {
                subjects.append(BIDSSubject(label: subDir.lastPathComponent, sessions: sessions))
            }
        }
        return subjects
    }

    /// Recursively collect every NIfTI under a non-BIDS folder, skipping hidden
    /// files and the BIDS reserved/derived folders (so a loose-folder open
    /// doesn't drag in a huge derivatives tree).
    private static func looseNifti(root: URL, fm: FileManager) -> [BIDSImageFile] {
        let skip: Set<String> = ["derivatives", "sourcedata", "code", ".git", ".datalad"]
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var out: [BIDSImageFile] = []
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skip.contains(url.lastPathComponent.lowercased()) { en.skipDescendants() }
                continue
            }
            if isNiftiURL(url) { out.append(makeImageFile(url, datatype: nil)) }
        }
        return sortFiles(out)
    }
}
