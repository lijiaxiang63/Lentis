// AppSettingsTests.swift
// Lentis Tests
//
// Phase 9 — Settings store + output-location resolution:
//   • niftiBaseName strips .nii / .nii.gz and falls back.
//   • resolveOutputDirectory honors mode, falls back to a writable dir.
//   • AppSettings persists to (and rehydrates from) its UserDefaults suite.
// Licensed under the MIT License. See LICENSE for details.

import Testing
import Foundation
@testable import Lentis

struct AppSettingsTests {

    // MARK: - Base name

    @Test func niftiBaseNameStripsExtensions() {
        #expect(AppSettings.niftiBaseName("sub-01_ct.nii.gz") == "sub-01_ct")
        #expect(AppSettings.niftiBaseName("scan.NII") == "scan")
        #expect(AppSettings.niftiBaseName("plain") == "plain")
        #expect(AppSettings.niftiBaseName(".nii.gz") == "segmentation")
        #expect(AppSettings.niftiBaseName("") == "segmentation")
    }

    // MARK: - Output directory resolution

    @Test func besideSourceUsesTheSourceFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("sub.nii.gz")
        let resolved = AppSettings.resolveOutputDirectory(sourceFile: source,
                                                          mode: .besideSource,
                                                          customDirectory: nil)
        #expect(resolved.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func customFolderIsCreatedAndUsed() throws {
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: custom) }

        // The folder does not exist yet — resolution should create it.
        #expect(!FileManager.default.fileExists(atPath: custom.path))
        let resolved = AppSettings.resolveOutputDirectory(sourceFile: nil,
                                                          mode: .customFolder,
                                                          customDirectory: custom)
        #expect(resolved.standardizedFileURL == custom.standardizedFileURL)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func customFolderFallsBackToSourceWhenUnwritable() throws {
        // A custom path under /dev (not a creatable directory) forces the fallback
        // chain; with a writable source folder present, that wins next.
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lentis-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let source = srcDir.appendingPathComponent("ct.nii")
        let bogus = URL(fileURLWithPath: "/dev/null/nope", isDirectory: true)

        let resolved = AppSettings.resolveOutputDirectory(sourceFile: source,
                                                          mode: .customFolder,
                                                          customDirectory: bogus)
        #expect(resolved.standardizedFileURL == srcDir.standardizedFileURL)
    }

    @Test func resolutionAlwaysReturnsAWritableDirectory() {
        // No source, no custom dir → must still land on a writable fallback.
        let resolved = AppSettings.resolveOutputDirectory(sourceFile: nil,
                                                          mode: .besideSource,
                                                          customDirectory: nil)
        #expect(FileManager.default.isWritableFile(atPath: resolved.path))
    }

    // MARK: - Persistence

    @Test func settingsPersistAndRehydrate() throws {
        let suiteName = "lentis.test.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let a = AppSettings(defaults: suite)
        a.freesurferHome = "/Applications/freesurfer/8.1.0"
        a.synthSegBinaryPath = "/opt/bin/mri_synthseg"
        a.synthSegRobust = false
        a.synthSegParcellation = false
        a.synthSegThreads = 6
        a.outputMode = .customFolder
        a.customOutputDirectory = "/tmp/seg"
        a.autoLoadSynthSegResult = false
        a.writeDerivedBrainMask = false
        a.overlayOpacity = 0.72

        // A fresh instance over the same suite reflects every change.
        let b = AppSettings(defaults: suite)
        #expect(b.freesurferHome == "/Applications/freesurfer/8.1.0")
        #expect(b.synthSegBinaryPath == "/opt/bin/mri_synthseg")
        #expect(b.synthSegRobust == false)
        #expect(b.synthSegParcellation == false)
        #expect(b.synthSegThreads == 6)
        #expect(b.outputMode == .customFolder)
        #expect(b.customOutputDirectory == "/tmp/seg")
        #expect(b.autoLoadSynthSegResult == false)
        #expect(b.writeDerivedBrainMask == false)
        #expect(b.overlayOpacity == 0.72)
    }

    @Test func defaultsAreSensibleOnFirstRun() throws {
        let suiteName = "lentis.test.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let s = AppSettings(defaults: suite)
        #expect(s.freesurferHome.isEmpty)
        #expect(s.synthSegRobust)
        #expect(s.synthSegParcellation)
        #expect(s.synthSegThreads == 1)
        #expect(s.outputMode == .besideSource)
        #expect(s.autoLoadSynthSegResult)
        #expect(s.writeDerivedBrainMask)
        #expect(s.overlayOpacity == 0.45)
    }
}
