// MultiFrameDecoder.swift
// OpenDicomViewer
//
// Efficient decoder for multi-frame (cine/video) DICOM files.
// Uses memory-mapped I/O to avoid loading entire files into memory,
// and parses encapsulated pixel data to extract individual JPEG
// frames on demand with prefetch caching for smooth playback.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import AppKit
import ImageIO

func cineLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    let tempDir = FileManager.default.temporaryDirectory
    let path = tempDir.appendingPathComponent("odv_cine_debug_\(ProcessInfo.processInfo.processIdentifier).log").path
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            fh.write(data)
        }
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

class MultiFrameDecoder {
    let url: URL
    let numberOfFrames: Int
    let frameWidth: Int
    let frameHeight: Int
    let bitsAllocated: Int
    let samplesPerPixel: Int
    let cineRate: Double
    let frameTimeMs: Double
    let isColor: Bool

    private let mappedData: Data
    private var frameTable: [(offset: Int, length: Int)] = []
    private let frameCache = NSCache<NSNumber, NSImage>()
    private let prefetchQueue = DispatchQueue(label: "com.opendicomviewer.framePrefetch", qos: .userInitiated)

    // Decode-ahead ring buffer for smooth cine playback
    private var ringBuffer: [Int: CGImage] = [:]  // frame index -> decoded CGImage
    private let ringBufferLock = NSLock()
    private let ringBufferSize = 60  // ~2 seconds at 30fps
    private var ringBufferDecoding = false
    private var ringBufferTarget: Int = 0  // Target frame to decode ahead to

    /// Failable init - returns nil if file is not a valid multi-frame DICOM.
    init?(url: URL) {
        let initStart = CFAbsoluteTimeGetCurrent()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        cineLog("DECODER init start: \(url.lastPathComponent), size: \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))")
        // 1. Memory-map the file
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count > 132 else { return nil }
        self.mappedData = data
        self.url = url

        // 2. Parse header metadata using SimpleDicomParser
        let parser = SimpleDicomParser(data: data)
        guard let (elements, _, _) = try? parser.parse(stopAtPixelData: true) else { return nil }
        let pixelDataOffset = parser.offset  // Points at the (7FE0,0010) tag

        // Helper closures for tag lookup
        let getStr: (UInt16, UInt16) -> String? = { group, elem in
            elements.first(where: { $0.tag == DicomTag(group: group, element: elem) })?.stringValue
        }
        let getInt: (UInt16, UInt16) -> Int? = { group, elem in
            guard let el = elements.first(where: { $0.tag == DicomTag(group: group, element: elem) }) else {
                return nil
            }
            // IS (integer string) or US (binary uint16/uint32)
            if let s = el.stringValue, let v = Int(s.trimmingCharacters(in: .whitespaces)) {
                return v
            }
            return el.intValue
        }

        // Extract NumberOfFrames (0028,0008) - IS type; must be > 1 for multi-frame
        guard let nf = getInt(0x0028, 0x0008), nf > 1 else { return nil }
        self.numberOfFrames = nf

        // Dimensions
        self.frameWidth  = getInt(0x0028, 0x0011) ?? 0   // Columns
        self.frameHeight = getInt(0x0028, 0x0010) ?? 0   // Rows
        self.bitsAllocated  = getInt(0x0028, 0x0100) ?? 8
        self.samplesPerPixel = getInt(0x0028, 0x0002) ?? 1

        // PhotometricInterpretation (0028,0004)
        let photo = getStr(0x0028, 0x0004) ?? ""
        self.isColor = photo.contains("RGB") || photo.contains("YBR")

        // Timing: CineRate (0018,0040) IS, FrameTime (0018,1063) DS (ms/frame)
        // Prefer FrameTime; fall back to CineRate; default 30 fps
        let rawCineRate: Double
        if let cr = getInt(0x0018, 0x0040), cr > 0 {
            rawCineRate = Double(cr)
        } else {
            rawCineRate = 30.0
        }

        if let ftStr = getStr(0x0018, 0x1063),
           let ft = Double(ftStr.trimmingCharacters(in: .whitespaces)),
           ft > 0 {
            self.frameTimeMs = ft
            self.cineRate = 1000.0 / ft
        } else {
            self.cineRate = rawCineRate
            self.frameTimeMs = 1000.0 / rawCineRate
        }

        // 3. Find PixelData tag and parse encapsulated frame items
        let parseStart = CFAbsoluteTimeGetCurrent()
        var table: [(offset: Int, length: Int)] = []
        guard MultiFrameDecoder.findPixelDataAndParseFrames(data: data, frameTable: &table, pixelDataTagOffset: pixelDataOffset, fileURL: url) else {
            cineLog("DECODER findPixelDataAndParseFrames FAILED for \(url.lastPathComponent)")
            return nil
        }
        cineLog("DECODER Frame table built: \(table.count) frames in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - parseStart))s for \(url.lastPathComponent)")

        // Limit to declared frame count
        if table.count > nf {
            table = Array(table.prefix(nf))
        }
        self.frameTable = table

        // 4. Configure cache
        frameCache.countLimit = 120
        frameCache.totalCostLimit = 500 * 1024 * 1024 // 500 MB
        cineLog("DECODER init COMPLETE: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - initStart))s total for \(url.lastPathComponent) (\(min(nf, table.count)) effective frames)")
    }

    // MARK: - Frame Access

    /// Return a decoded frame image at the given index. Checks the cache first.
    func frameImage(at index: Int) -> NSImage? {
        guard index >= 0 && index < min(numberOfFrames, frameTable.count) else { return nil }

        let key = NSNumber(value: index)
        if let cached = frameCache.object(forKey: key) {
            return cached
        }

        let entry = frameTable[index]
        guard entry.offset >= 0 && entry.offset + entry.length <= mappedData.count else { return nil }

        // Zero-copy slice into memory-mapped data
        let frameData = mappedData[entry.offset..<(entry.offset + entry.length)]
        guard let image = NSImage(data: frameData) else { return nil }

        frameCache.setObject(image, forKey: key)
        return image
    }

    /// Decode a frame directly to CGImage (faster than NSImage for display pipeline)
    func frameCGImage(at index: Int) -> CGImage? {
        guard index >= 0 && index < min(numberOfFrames, frameTable.count) else { return nil }

        let entry = frameTable[index]
        guard entry.offset >= 0 && entry.offset + entry.length <= mappedData.count else { return nil }

        let frameData = mappedData[entry.offset..<(entry.offset + entry.length)] as NSData
        guard let source = CGImageSourceCreateWithData(frameData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true  // Force eager decode
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// Prefetch frames ahead of the current position for smooth playback.
    func prefetch(around index: Int, count: Int = 15) {
        prefetchQueue.async { [weak self] in
            guard let self = self else { return }
            let start = max(0, index)
            let end = min(self.effectiveFrameCount - 1, index + count)
            guard start <= end else { return }
            for i in start...end {
                _ = self.frameImage(at: i)
            }
        }
    }

    /// Number of frames that can actually be extracted (may be less than
    /// numberOfFrames if the file is truncated).
    var effectiveFrameCount: Int {
        min(numberOfFrames, frameTable.count)
    }

    /// Evict all cached frames, e.g. on a memory-pressure notification.
    func clearCache() {
        frameCache.removeAllObjects()
    }

    // MARK: - Ring Buffer

    /// Start filling the ring buffer ahead of the given frame index
    func startRingBuffer(from startIndex: Int) {
        ringBufferLock.lock()
        ringBufferTarget = startIndex
        let alreadyDecoding = ringBufferDecoding
        ringBufferDecoding = true
        ringBufferLock.unlock()

        guard !alreadyDecoding else { return }

        prefetchQueue.async { [weak self] in
            self?.fillRingBuffer()
        }
    }

    /// Stop the ring buffer (call when playback stops)
    func stopRingBuffer() {
        ringBufferLock.lock()
        ringBufferDecoding = false
        ringBuffer.removeAll()
        ringBufferLock.unlock()
    }

    /// Get a pre-decoded frame from the ring buffer (returns nil on miss)
    func ringBufferImage(at index: Int) -> CGImage? {
        ringBufferLock.lock()
        let img = ringBuffer[index]
        ringBufferLock.unlock()
        return img
    }

    /// Advance the ring buffer target (called each frame during playback)
    func advanceRingBuffer(to index: Int) {
        ringBufferLock.lock()
        ringBufferTarget = index
        // Evict frames more than ringBufferSize/2 behind current position
        let evictBefore = index - ringBufferSize / 2
        let keysToRemove = ringBuffer.keys.filter { $0 < evictBefore }
        for key in keysToRemove {
            ringBuffer.removeValue(forKey: key)
        }
        ringBufferLock.unlock()
    }

    /// Background worker that continuously fills the ring buffer ahead of playback
    private func fillRingBuffer() {
        while true {
            ringBufferLock.lock()
            guard ringBufferDecoding else {
                ringBufferLock.unlock()
                return
            }
            let target = ringBufferTarget
            ringBufferLock.unlock()

            // Find the next frame that needs decoding
            var decoded = false
            for i in 0..<ringBufferSize {
                let frameIdx = target + i
                guard frameIdx < effectiveFrameCount else { break }

                ringBufferLock.lock()
                let alreadyDecoded = ringBuffer[frameIdx] != nil
                let stillActive = ringBufferDecoding
                ringBufferLock.unlock()

                guard stillActive else { return }
                if alreadyDecoded { continue }

                // Decode this frame
                if let cgImage = frameCGImage(at: frameIdx) {
                    ringBufferLock.lock()
                    ringBuffer[frameIdx] = cgImage
                    ringBufferLock.unlock()
                    decoded = true
                    break  // Decode one frame per iteration to check for stop
                }
            }

            if !decoded {
                // All frames in window are decoded, sleep briefly
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    // MARK: - Encapsulated Pixel Data Parser

    /// Scan the memory-mapped DICOM bytes for the PixelData element
    /// (7FE0,0010) and walk its encapsulated item sequence to build a
    /// frame offset table.
    ///
    /// Encapsulated pixel data layout:
    ///   PixelData tag (7FE0,0010) + VR + length (FFFFFFFF)
    ///   Item 0 : Basic Offset Table   (FFFE,E000) + length + offsets
    ///   Item 1 : Frame 0 JPEG bytes   (FFFE,E000) + length + data
    ///   Item 2 : Frame 1 JPEG bytes   ...
    ///   Sequence Delimiter            (FFFE,E0DD) + 00000000
    private static func findPixelDataAndParseFrames(
        data: Data,
        frameTable: inout [(offset: Int, length: Int)],
        pixelDataTagOffset: Int = -1,
        fileURL: URL? = nil
    ) -> Bool {
        var tagOffset = pixelDataTagOffset

        if tagOffset < 0 {
            // Fallback: scan for PixelData tag (only used if offset not provided)
            // PixelData tag bytes in little-endian: group 7FE0 = E0 7F, element 0010 = 10 00
            let p0: UInt8 = 0xE0, p1: UInt8 = 0x7F, p2: UInt8 = 0x10, p3: UInt8 = 0x00

            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let count = data.count
                // Start after the 132-byte DICOM preamble+magic
                for i in 132..<(count - 12) {
                    if base[i] == p0 && base[i+1] == p1 && base[i+2] == p2 && base[i+3] == p3 {
                        tagOffset = i
                        break
                    }
                }
            }
        }

        guard tagOffset >= 0 else { return false }

        // Advance past the tag (4 bytes), then detect VR to find item start.
        var itemsStart = tagOffset + 4

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            guard itemsStart + 2 <= data.count else { return }
            let vr0 = base[itemsStart]
            let vr1 = base[itemsStart + 1]
            // ASCII 'O'=0x4F, 'B'=0x42, 'W'=0x57
            // Explicit VR OB or OW: VR(2) + reserved(2) + 32-bit length(4) = 8 bytes header
            if vr0 == 0x4F && (vr1 == 0x42 || vr1 == 0x57) {
                itemsStart += 8
            } else {
                // Implicit VR: 32-bit length only (4 bytes)
                itemsStart += 4
            }
        }

        // Walk the item sequence.
        // When a fileURL is available, use FileHandle seeks + small reads so that
        // only the 8-byte item headers are paged in (~26 KB for 3305 frames),
        // instead of sequentially touching every page in the memory-mapped file
        // which triggers macOS prefetch and pages in the entire file (~12 GB RSS).
        var offset = itemsStart
        var isFirstItem = true

        if let fileURL = fileURL {
            guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return false }
            defer { fh.closeFile() }

            while true {
                fh.seek(toFileOffset: UInt64(offset))
                let headerBytes = fh.readData(ofLength: 8)
                guard headerBytes.count == 8 else { break }

                let t0 = headerBytes[0], t1 = headerBytes[1]
                let t2 = headerBytes[2], t3 = headerBytes[3]

                // Sequence delimiter tag (FFFE,E0DD) in LE: FE FF DD E0
                if t0 == 0xFE && t1 == 0xFF && t2 == 0xDD && t3 == 0xE0 { break }

                // All items must carry item tag (FFFE,E000) in LE: FE FF 00 E0
                guard t0 == 0xFE && t1 == 0xFF && t2 == 0x00 && t3 == 0xE0 else { break }

                // 4-byte little-endian item length
                let len = Int(headerBytes[4])
                          | (Int(headerBytes[5]) << 8)
                          | (Int(headerBytes[6]) << 16)
                          | (Int(headerBytes[7]) << 24)

                let dataStart = offset + 8

                if isFirstItem {
                    // Item 0 is the Basic Offset Table; skip it
                    isFirstItem = false
                } else if len > 0 && dataStart + len <= data.count {
                    frameTable.append((offset: dataStart, length: len))
                }

                // Advance; guard against negative/zero len causing infinite loop
                offset = dataStart + max(0, len)
            }
        } else {
            // Fallback: walk items via the memory-mapped buffer (no file URL available)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let count = data.count

                while offset + 8 <= count {
                    let t0 = base[offset], t1 = base[offset+1]
                    let t2 = base[offset+2], t3 = base[offset+3]

                    // Sequence delimiter tag (FFFE,E0DD) in LE: FE FF DD E0
                    if t0 == 0xFE && t1 == 0xFF && t2 == 0xDD && t3 == 0xE0 { break }

                    // All items must carry item tag (FFFE,E000) in LE: FE FF 00 E0
                    guard t0 == 0xFE && t1 == 0xFF && t2 == 0x00 && t3 == 0xE0 else { break }

                    // 4-byte little-endian item length
                    let len = Int(base[offset+4])
                              | (Int(base[offset+5]) << 8)
                              | (Int(base[offset+6]) << 16)
                              | (Int(base[offset+7]) << 24)

                    let dataStart = offset + 8

                    if isFirstItem {
                        // Item 0 is the Basic Offset Table; skip it
                        isFirstItem = false
                    } else if len > 0 && dataStart + len <= count {
                        frameTable.append((offset: dataStart, length: len))
                    }

                    // Advance; guard against negative/zero len causing infinite loop
                    offset = dataStart + max(0, len)
                }
            }
        }

        return !frameTable.isEmpty
    }
}
