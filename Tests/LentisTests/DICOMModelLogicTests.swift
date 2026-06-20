import Foundation
import Testing
import simd
@testable import Lentis

private func imageContext(
    orientation: [Double],
    url: URL = URL(fileURLWithPath: "/tmp/test.dcm"),
    seriesUID: String = "series-1",
    numberOfFrames: Int = 1
) -> ImageContext {
    ImageContext(
        url: url,
        seriesUID: seriesUID,
        seriesDescription: "test",
        instanceNumber: 1,
        seriesNumber: 1,
        zLocation: nil,
        imagePosition: SIMD3<Double>(0, 0, 0),
        imageOrientation: orientation,
        pixelSpacing: SIMD2<Double>(1, 1),
        sliceThickness: 1.0,
        spacingBetweenSlices: 1.0,
        frameOfReferenceUID: nil,
        studyInstanceUID: nil,
        numberOfFrames: numberOfFrames
    )
}

@Test
func crossProduct() {
    let a = SIMD3<Double>(1, 0, 0)
    let b = SIMD3<Double>(0, 1, 0)
    #expect(Lentis.cross(a, b) == SIMD3<Double>(0, 0, 1))
}

@Test
func dominantAxisAxial() {
    let series = ImageSeries(
        id: "axial",
        seriesNumber: 1,
        seriesDescription: "axial",
        images: [imageContext(orientation: [1, 0, 0, 0, 1, 0])]
    )
    #expect(series.dominantAxis == .axial)
}

@Test
func dominantAxisCoronal() {
    let series = ImageSeries(
        id: "coronal",
        seriesNumber: 2,
        seriesDescription: "coronal",
        images: [imageContext(orientation: [1, 0, 0, 0, 0, 1])]
    )
    #expect(series.dominantAxis == .coronal)
}

@Test
func dominantAxisSagittal() {
    let series = ImageSeries(
        id: "sagittal",
        seriesNumber: 3,
        seriesDescription: "sagittal",
        images: [imageContext(orientation: [0, 1, 0, 0, 0, 1])]
    )
    #expect(series.dominantAxis == .sagittal)
}

// MARK: - Multi-frame grouping key

@Test
func groupingKeyForSingleFrameIsSeriesUID() {
    let ctx = imageContext(orientation: [1, 0, 0, 0, 1, 0], numberOfFrames: 1)
    #expect(ctx.seriesGroupingKey == "series-1")
}

@Test
func groupingKeyForMultiFrameIsPerFile() {
    let a = imageContext(
        orientation: [1, 0, 0, 0, 1, 0],
        url: URL(fileURLWithPath: "/tmp/cine-a.dcm"),
        seriesUID: "shared-uid",
        numberOfFrames: 100
    )
    let b = imageContext(
        orientation: [1, 0, 0, 0, 1, 0],
        url: URL(fileURLWithPath: "/tmp/cine-b.dcm"),
        seriesUID: "shared-uid",
        numberOfFrames: 100
    )
    // Two multi-frame files with identical seriesUID must produce distinct keys
    #expect(a.seriesGroupingKey != b.seriesGroupingKey)
    #expect(a.seriesGroupingKey.hasPrefix("shared-uid#mf#"))
    #expect(b.seriesGroupingKey.hasPrefix("shared-uid#mf#"))
}

@Test
func groupingBehaviorSplitsMultiFrameKeepsSingleFrame() {
    // 11 multi-frame cines sharing one SeriesUID + 2 single-frame files sharing another UID
    var contexts: [ImageContext] = []
    for i in 0..<11 {
        contexts.append(imageContext(
            orientation: [1, 0, 0, 0, 1, 0],
            url: URL(fileURLWithPath: "/tmp/cine-\(i).dcm"),
            seriesUID: "cine-uid",
            numberOfFrames: 100
        ))
    }
    for i in 0..<2 {
        contexts.append(imageContext(
            orientation: [1, 0, 0, 0, 1, 0],
            url: URL(fileURLWithPath: "/tmp/ct-\(i).dcm"),
            seriesUID: "ct-uid",
            numberOfFrames: 1
        ))
    }
    let grouped = Dictionary(grouping: contexts, by: { $0.seriesGroupingKey })
    // 11 unique cine keys + 1 ct-uid key = 12 groups
    #expect(grouped.count == 12)
    // Each multi-frame group has exactly 1 file
    let cineGroups = grouped.filter { $0.key.hasPrefix("cine-uid#mf#") }
    #expect(cineGroups.count == 11)
    for (_, imgs) in cineGroups { #expect(imgs.count == 1) }
    // Single-frame group has 2 files
    #expect(grouped["ct-uid"]?.count == 2)
}

@Test
func displayDescriptionIncludesFilenameForMultiFrame() {
    let ctx = imageContext(
        orientation: [1, 0, 0, 0, 1, 0],
        url: URL(fileURLWithPath: "/tmp/650.dcm"),
        numberOfFrames: 96
    )
    let desc = ctx.displaySeriesDescription(baseDescription: "Angio")
    #expect(desc.contains("650"))
    #expect(desc.contains("96"))
}

@Test
func displayDescriptionUnchangedForSingleFrame() {
    let ctx = imageContext(orientation: [1, 0, 0, 0, 1, 0], numberOfFrames: 1)
    let desc = ctx.displaySeriesDescription(baseDescription: "CT Chest")
    #expect(desc == "CT Chest")
}
