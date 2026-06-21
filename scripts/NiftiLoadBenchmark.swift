import Foundation

@main
struct NiftiLoadBenchmark {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: nifti-load-benchmark <file.nii.gz>\n", stderr)
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let started = Date.timeIntervalSinceReferenceDate
        let image = try NiftiImage.read(contentsOf: url)
        let readFinished = Date.timeIntervalSinceReferenceDate
        let dataset = NiftiDataset(image: image, seriesID: "benchmark", displayName: url.lastPathComponent)
        let datasetFinished = Date.timeIntervalSinceReferenceDate
        let volume = dataset.makeVolume(timepoint: 0)
        let volumeFinished = Date.timeIntervalSinceReferenceDate
        var checksum: Int64 = 0
        for voxel in volume.voxels { checksum += Int64(voxel) }

        let readElapsed = readFinished - started
        print(
            "read=\(readElapsed) dataset=\(datasetFinished - readFinished) " +
            "volume=\(volumeFinished - datasetFinished) total=\(volumeFinished - started) " +
            "dims=\(volume.width)x\(volume.height)x\(volume.depth) checksum=\(checksum)"
        )
        guard readElapsed < 8 else { exit(1) }
    }
}
