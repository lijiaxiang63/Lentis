// BIDSDatasetTests.swift
// Lentis Tests
//
// The pure BIDS model: filename entity parsing, derivative naming, dataset
// detection, scanning a real (temp) directory tree into subjects/sessions, the
// loose-folder fallback, and derivative directory paths.
// Licensed under the MIT License. See LICENSE for details.

import Testing
import Foundation
@testable import Lentis

struct BIDSDatasetTests {

    // MARK: - Entity parsing

    @Test func parsesEntitiesSuffixAndExtension() {
        let e = BIDSEntities.parse(fileName: "sub-01_ses-02_acq-mprage_T1w.nii.gz")
        #expect(e.suffix == "T1w")
        #expect(e.ext == "nii.gz")
        #expect(e.value(for: "sub") == "01")
        #expect(e.value(for: "ses") == "02")
        #expect(e.value(for: "acq") == "mprage")
        #expect(e.pairs.count == 3)
        // Order is preserved.
        #expect(e.pairs.first?.key == "sub")
    }

    @Test func parsesPlainNonBIDSName() {
        let e = BIDSEntities.parse(fileName: "scan.nii")
        #expect(e.suffix == "scan")
        #expect(e.ext == "nii")
        #expect(e.pairs.isEmpty)
        #expect(e.value(for: "sub") == nil)
    }

    @Test func derivativeNameKeepsEntitiesAndSetsDescAndSuffix() {
        let e = BIDSEntities.parse(fileName: "sub-01_ses-02_acq-mprage_T1w.nii.gz")
        #expect(e.derivativeName(desc: "calc", suffix: "mask")
                == "sub-01_ses-02_acq-mprage_desc-calc_mask.nii.gz")
        #expect(e.derivativeName(desc: "synthseg", suffix: "dseg")
                == "sub-01_ses-02_acq-mprage_desc-synthseg_dseg.nii.gz")
    }

    @Test func derivativeNameReplacesExistingDesc() {
        let e = BIDSEntities.parse(fileName: "sub-01_desc-preproc_T1w.nii.gz")
        // The source `desc-preproc` is replaced, not duplicated.
        #expect(e.derivativeName(desc: "brain", suffix: "mask")
                == "sub-01_desc-brain_mask.nii.gz")
    }

    @Test func derivativeNameWithNoDescOmitsIt() {
        let e = BIDSEntities.parse(fileName: "sub-03_FLAIR.nii.gz")
        #expect(e.derivativeName(desc: nil, suffix: "mask") == "sub-03_mask.nii.gz")
    }

    @Test func derivativeNameSanitizesHyphenatedEntityValues() {
        // A slightly-off source label `acq-pre-post` must not emit a non-BIDS
        // derivative name — the carried value is reduced to alphanumerics.
        let e = BIDSEntities.parse(fileName: "sub-01_acq-pre-post_T1w.nii.gz")
        #expect(e.derivativeName(desc: "calc", suffix: "dseg")
                == "sub-01_acq-prepost_desc-calc_dseg.nii.gz")
    }

    @Test func siblingModalitiesGetDistinctDerivativeNames() {
        // The collision fix: two sibling modalities of the same subject must NOT
        // produce the same mask/dseg name (which would silently overwrite).
        let t1 = BIDSEntities.parse(fileName: "sub-01_T1w.nii.gz")
        let ct = BIDSEntities.parse(fileName: "sub-01_ct.nii.gz")
        let f1 = BIDSImageFile(url: URL(fileURLWithPath: "/d/sub-01_T1w.nii.gz"),
                               entities: t1, datatype: "anat", fileSize: 0)
        let f2 = BIDSImageFile(url: URL(fileURLWithPath: "/d/sub-01_ct.nii.gz"),
                               entities: ct, datatype: "ct", fileSize: 0)
        let n1 = t1.derivativeName(desc: f1.descIncludingModality("calc"), suffix: "mask")
        let n2 = ct.derivativeName(desc: f2.descIncludingModality("calc"), suffix: "mask")
        #expect(n1 == "sub-01_desc-calcT1w_mask.nii.gz")
        #expect(n2 == "sub-01_desc-calcCt_mask.nii.gz")
        #expect(n1 != n2)
    }

    // MARK: - Image-file convenience

    @Test func imageFileLabelsAndBIDSFlag() {
        let bids = BIDSImageFile(
            url: URL(fileURLWithPath: "/d/sub-05_ses-1_T2w.nii.gz"),
            entities: BIDSEntities.parse(fileName: "sub-05_ses-1_T2w.nii.gz"),
            datatype: "anat", fileSize: 10)
        #expect(bids.isBIDS)
        #expect(bids.subjectLabel == "sub-05")
        #expect(bids.sessionLabel == "ses-1")
        #expect(bids.displayTitle == "T2w")
        #expect(bids.detailChips == [])   // sub/ses are filtered out

        let loose = BIDSImageFile(
            url: URL(fileURLWithPath: "/d/scan.nii.gz"),
            entities: BIDSEntities.parse(fileName: "scan.nii.gz"),
            datatype: nil, fileSize: 0)
        #expect(!loose.isBIDS)
        #expect(loose.subjectLabel == nil)
        #expect(loose.displayTitle == "scan")
    }

    @Test func detailChipsIncludeNonSubSesEntities() {
        let f = BIDSImageFile(
            url: URL(fileURLWithPath: "/d/sub-01_acq-hi_run-2_T1w.nii.gz"),
            entities: BIDSEntities.parse(fileName: "sub-01_acq-hi_run-2_T1w.nii.gz"),
            datatype: "anat", fileSize: 0)
        #expect(f.detailChips == ["acq-hi", "run-2"])
    }

    // MARK: - Scanning a real tree

    /// Build a small on-disk BIDS tree of empty files (the scanner reads only
    /// names + sizes, never NIfTI content).
    private func makeTree(_ root: URL, files: [String], extras: [String] = []) throws {
        let fm = FileManager.default
        for rel in files + extras {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    @Test func scansBIDSHierarchy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bids-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try makeTree(root, files: [
            "sub-01/anat/sub-01_T1w.nii.gz",
            "sub-01/anat/sub-01_FLAIR.nii.gz",
            "sub-02/ses-01/anat/sub-02_ses-01_T1w.nii.gz",
            "sub-02/ses-02/anat/sub-02_ses-02_T1w.nii.gz",
        ], extras: [
            "dataset_description.json",
            "sub-02/ses-01/anat/sub-02_ses-01_T1w.json",   // sidecar — must be ignored
            "derivatives/other/sub-99_x.nii.gz",            // derivatives — must be ignored
        ])
        // A meaningful dataset name.
        try "{\"Name\": \"My Study\"}".write(
            to: root.appendingPathComponent("dataset_description.json"), atomically: true, encoding: .utf8)

        let ds = try #require(BIDSDataset.scan(at: root))
        #expect(ds.isBIDS)
        #expect(ds.name == "My Study")
        #expect(ds.subjectCount == 2)
        #expect(ds.imageCount == 4)          // sidecar + derivatives excluded

        let sub01 = ds.subjects[0]
        #expect(sub01.label == "sub-01")
        #expect(!sub01.showsSessions)        // implicit single session
        #expect(sub01.imageCount == 2)

        let sub02 = ds.subjects[1]
        #expect(sub02.label == "sub-02")
        #expect(sub02.showsSessions)         // two named sessions
        #expect(sub02.sessions.count == 2)
        #expect(sub02.sessions.allSatisfy { $0.files.count == 1 })

        // The first image is under sub-01 (sorted first).
        #expect(ds.firstImage?.subjectLabel == "sub-01")
    }

    @Test func nonDatatypeSubfolderImagesAreDropped() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bids-dt-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try makeTree(root, files: [
            "sub-01/anat/sub-01_T1w.nii.gz",
            "sub-01/qc/sub-01_qc.nii.gz",   // non-datatype folder → must be ignored
        ])
        let ds = try #require(BIDSDataset.scan(at: root))
        #expect(ds.imageCount == 1)
        #expect(ds.subjects[0].sessions.first?.files.first?.datatype == "anat")
    }

    @Test func subjectRootImagesKeptAlongsideSessions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bids-mix-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try makeTree(root, files: [
            "sub-01/anat/sub-01_T1w.nii.gz",                 // subject-level, alongside ses-
            "sub-01/ses-01/anat/sub-01_ses-01_T1w.nii.gz",
        ])
        let ds = try #require(BIDSDataset.scan(at: root))
        let sub = ds.subjects[0]
        #expect(sub.imageCount == 2)                          // neither dropped
        #expect(sub.sessions.contains { $0.label == nil })    // implicit session for the root file
        #expect(sub.sessions.contains { $0.label == "ses-01" })
    }

    @Test func looseFolderFallback() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("loose-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try makeTree(root, files: ["a.nii.gz", "b.nii"], extras: ["notes.txt", "readme.md"])

        let ds = try #require(BIDSDataset.scan(at: root))
        #expect(!ds.isBIDS)
        #expect(ds.subjects.isEmpty)
        #expect(ds.looseFiles.count == 2)    // only the NIfTI files
        #expect(ds.imageCount == 2)
    }

    @Test func emptyFolderReturnsNil() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        #expect(BIDSDataset.scan(at: root) == nil)
    }

    @Test func detectionBySubFolderWithoutDescription() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bids2-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try makeTree(root, files: ["sub-07/anat/sub-07_T1w.nii"])
        #expect(BIDSDataset.looksLikeBIDS(at: root))
        let ds = try #require(BIDSDataset.scan(at: root))
        #expect(ds.isBIDS)
        #expect(ds.name == root.lastPathComponent)   // no description → folder name
    }

    // MARK: - Derivative directory

    @Test func derivativesDirectoryPath() throws {
        let root = URL(fileURLWithPath: "/data/study", isDirectory: true)
        let file = BIDSImageFile(
            url: root.appendingPathComponent("sub-02/ses-01/anat/sub-02_ses-01_T1w.nii.gz"),
            entities: BIDSEntities.parse(fileName: "sub-02_ses-01_T1w.nii.gz"),
            datatype: "anat", fileSize: 0)
        let ds = BIDSDataset(rootURL: root, name: "study", subjects: [], looseFiles: [], isBIDS: true)
        let dir = try #require(ds.derivativesDirectory(pipeline: "lentis", for: file))
        #expect(dir.path == "/data/study/derivatives/lentis/sub-02/ses-01/anat")
    }

    @Test func derivativesDirectoryNilForLooseFile() {
        let root = URL(fileURLWithPath: "/data/loose", isDirectory: true)
        let file = BIDSImageFile(
            url: root.appendingPathComponent("scan.nii.gz"),
            entities: BIDSEntities.parse(fileName: "scan.nii.gz"),
            datatype: nil, fileSize: 0)
        let ds = BIDSDataset(rootURL: root, name: "loose", subjects: [], looseFiles: [file], isBIDS: false)
        #expect(ds.derivativesDirectory(pipeline: "lentis", for: file) == nil)
    }
}
