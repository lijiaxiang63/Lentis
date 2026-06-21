// CustomLUTRepository.swift
// Lentis
//
// Persists user-imported FreeSurfer-format LUTs in Application Support. Files
// are identified by SHA-256 so importing identical contents is idempotent.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import CryptoKit

final class CustomLUTRepository {
    static let shared = CustomLUTRepository()

    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.directoryURL = applicationSupport
                .appendingPathComponent("Lentis", isDirectory: true)
                .appendingPathComponent("LUTs", isDirectory: true)
        }
    }

    func loadAll() -> [ColorLookupTable] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let digest = Self.digest(data)
                let name = Self.displayName(fromStoredURL: url)
                return try? ColorLookupTable.parse(
                    data: data,
                    name: name,
                    id: Self.customID(digest),
                    isBundled: false
                )
            }
    }

    func importFile(at sourceURL: URL) throws -> ColorLookupTable {
        let data = try Data(contentsOf: sourceURL)
        let digest = Self.digest(data)
        let id = Self.customID(digest)
        if let existing = loadAll().first(where: { $0.id == id }) { return existing }

        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let parsed = try ColorLookupTable.parse(data: data, name: sourceName, id: id, isBundled: false)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let safeName = Self.safeFilename(sourceName)
        let destination = directoryURL.appendingPathComponent("\(safeName)--\(digest.prefix(12)).lut")
        try data.write(to: destination, options: .atomic)
        return parsed
    }

    func remove(id: String) throws {
        guard id.hasPrefix("custom:") else { return }
        let digest = String(id.dropFirst("custom:".count))
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.lastPathComponent.contains(String(digest.prefix(12))) {
            let data = try Data(contentsOf: url)
            if Self.digest(data) == digest { try fileManager.removeItem(at: url) }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func customID(_ digest: String) -> String { "custom:\(digest)" }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0").union(.newlines)
        let cleaned = name.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return cleaned.isEmpty ? "Custom LUT" : cleaned
    }

    private static func displayName(fromStoredURL url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: "--", options: .backwards) else { return stem }
        return String(stem[..<range.lowerBound])
    }
}
