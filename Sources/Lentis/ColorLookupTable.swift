// ColorLookupTable.swift
// Lentis
//
// FreeSurfer-compatible color lookup tables. The on-disk format is:
//   label-id  label-name  red  green  blue  transparency
// where transparency is the FreeSurfer RGBT convention (0 = opaque,
// 255 = transparent), not conventional alpha.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

struct LUTEntry: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let transparency: UInt8

    var opacity: Double { 1.0 - Double(transparency) / 255.0 }
    var rgb: SIMD3<Double> {
        SIMD3(Double(red) / 255.0, Double(green) / 255.0, Double(blue) / 255.0)
    }
}

struct ColorLookupTable: Identifiable, Equatable, Sendable {
    static let bundledID = "org.freesurfer.FreeSurferColorLUT"

    let id: String
    let name: String
    let entries: [Int32: LUTEntry]
    let isBundled: Bool

    subscript(label: Int32) -> LUTEntry? { entries[label] }

    static func parse(
        data: Data,
        name: String,
        id: String = UUID().uuidString,
        isBundled: Bool = false
    ) throws -> ColorLookupTable {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ColorLookupTableError.invalidUTF8
        }

        var parsed: [Int32: LUTEntry] = [:]
        for (zeroBasedLine, sourceLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = zeroBasedLine + 1
            let withoutComment = sourceLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let fields = withoutComment.split(whereSeparator: { $0.isWhitespace })
            if fields.isEmpty { continue }
            guard fields.count >= 6 else {
                throw ColorLookupTableError.malformedLine(lineNumber)
            }
            guard let label = Int32(fields[0]) else {
                throw ColorLookupTableError.invalidLabel(line: lineNumber, value: String(fields[0]))
            }
            guard parsed[label] == nil else {
                throw ColorLookupTableError.duplicateLabel(line: lineNumber, label: label)
            }

            let colorFields = fields.suffix(4)
            var channels: [UInt8] = []
            channels.reserveCapacity(4)
            for field in colorFields {
                guard let value = Int(field), (0...255).contains(value) else {
                    throw ColorLookupTableError.invalidChannel(line: lineNumber, value: String(field))
                }
                channels.append(UInt8(value))
            }
            let nameFields = fields.dropFirst().dropLast(4)
            let labelName = nameFields.map(String.init).joined(separator: " ")
            guard !labelName.isEmpty else {
                throw ColorLookupTableError.malformedLine(lineNumber)
            }
            parsed[label] = LUTEntry(
                id: label,
                name: labelName,
                red: channels[0], green: channels[1], blue: channels[2],
                transparency: channels[3]
            )
        }

        guard !parsed.isEmpty else { throw ColorLookupTableError.noEntries }
        return ColorLookupTable(id: id, name: name, entries: parsed, isBundled: isBundled)
    }

    static func bundled() throws -> ColorLookupTable {
        guard let url = Bundle.module.url(
            forResource: "FreeSurferColorLUT",
            withExtension: "txt",
            subdirectory: "Resources"
        ) ?? Bundle.module.url(forResource: "FreeSurferColorLUT", withExtension: "txt") else {
            throw ColorLookupTableError.bundledResourceMissing
        }
        return try parse(
            data: Data(contentsOf: url),
            name: "FreeSurfer",
            id: bundledID,
            isBundled: true
        )
    }

    /// Stable, vivid fallback for labels absent from the selected LUT.
    static func fallbackEntry(for label: Int32) -> LUTEntry {
        var x = UInt32(bitPattern: label) &* 1_664_525 &+ 1_013_904_223
        x ^= x >> 16
        let hue = Double(x % 360) / 360.0
        let rgb = hsvToRGB(hue: hue, saturation: 0.68, value: 0.95)
        return LUTEntry(
            id: label,
            name: "Label \(label)",
            red: UInt8((rgb.x * 255).rounded()),
            green: UInt8((rgb.y * 255).rounded()),
            blue: UInt8((rgb.z * 255).rounded()),
            transparency: 0
        )
    }

    private static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> SIMD3<Double> {
        let h = (hue - floor(hue)) * 6
        let i = Int(floor(h))
        let f = h - floor(h)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        switch i % 6 {
        case 0: return SIMD3(value, t, p)
        case 1: return SIMD3(q, value, p)
        case 2: return SIMD3(p, value, t)
        case 3: return SIMD3(p, q, value)
        case 4: return SIMD3(t, p, value)
        default: return SIMD3(value, p, q)
        }
    }
}

enum ColorLookupTableError: LocalizedError, Equatable {
    case invalidUTF8
    case malformedLine(Int)
    case invalidLabel(line: Int, value: String)
    case duplicateLabel(line: Int, label: Int32)
    case invalidChannel(line: Int, value: String)
    case noEntries
    case bundledResourceMissing

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The LUT is not valid UTF-8 text."
        case .malformedLine(let line):
            return "Line \(line) is not in ‘ID Name R G B T’ format."
        case .invalidLabel(let line, let value):
            return "Line \(line) has an invalid label ID ‘\(value)’."
        case .duplicateLabel(let line, let label):
            return "Line \(line) repeats label ID \(label)."
        case .invalidChannel(let line, let value):
            return "Line \(line) has an invalid color channel ‘\(value)’; expected 0…255."
        case .noEntries:
            return "The LUT contains no color entries."
        case .bundledResourceMissing:
            return "The bundled FreeSurfer color LUT is missing."
        }
    }
}
