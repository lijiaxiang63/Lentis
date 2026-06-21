// Release-mode direct-volume-rendering throughput probe.
// Usage: VolumeRenderBenchmark <file.nii[.gz]> [resolution=320] [frames=12] [targetFPS=60]

import Foundation
import Darwin

@main
struct VolumeRenderBenchmark {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: VolumeRenderBenchmark <file.nii[.gz]> [resolution] [frames] [targetFPS]\n", stderr)
            exit(2)
        }

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let resolution = CommandLine.arguments.count > 2
            ? max(64, Int(CommandLine.arguments[2]) ?? 320)
            : 320
        let frameCount = CommandLine.arguments.count > 3
            ? max(3, Int(CommandLine.arguments[3]) ?? 12)
            : 12
        let targetFPS = CommandLine.arguments.count > 4
            ? max(1, Double(CommandLine.arguments[4]) ?? 60)
            : 60

        let image = try NiftiImage.read(contentsOf: url)
        let dataset = NiftiDataset(
            image: image,
            seriesID: "volume-render-benchmark",
            displayName: url.lastPathComponent
        )
        let volume = dataset.makeVolume(timepoint: 0)
        guard let renderer = MetalVolumeRenderer() else {
            fputs("Metal renderer unavailable\n", stderr)
            exit(2)
        }

        let (low, high) = dataset.suggestedWindow
        let windowWidth = Float(max(1, high - low))
        let windowCenter = Float((high + low) / 2)

        // Warm shader/texture/output allocation outside the measured loop.
        _ = renderer.renderVolume(
            volume: volume,
            cameraToVolume: MetalVolumeRenderer.cameraToVolumeMatrix(
                yawDegrees: -25,
                pitchDegrees: 18
            ),
            outputWidth: resolution,
            outputHeight: resolution,
            windowWidth: windowWidth,
            windowCenter: windowCenter,
            opacity: 1,
            invert: false
        )

        var timings: [Double] = []
        timings.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let yaw = -25 + Float(frame + 1) * 3
            let start = DispatchTime.now().uptimeNanoseconds
            guard renderer.renderVolume(
                volume: volume,
                cameraToVolume: MetalVolumeRenderer.cameraToVolumeMatrix(
                    yawDegrees: yaw,
                    pitchDegrees: 18
                ),
                outputWidth: resolution,
                outputHeight: resolution,
                windowWidth: windowWidth,
                windowCenter: windowCenter,
                opacity: 1,
                invert: false
            ) != nil else {
                fputs("render failed at frame \(frame)\n", stderr)
                exit(2)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            timings.append(elapsed)
            print(String(format: "frame=%02d yaw=%6.1f render_ms=%.3f", frame, yaw, elapsed))
        }

        let sorted = timings.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let budget = 1000.0 / targetFPS
        print(String(format: "summary resolution=%d frames=%d target_fps=%.0f median_ms=%.3f p95_ms=%.3f budget_ms=%.3f",
                     resolution, frameCount, targetFPS, median, p95, budget))

        // This command is the rotation-smoothness red/green feedback loop.
        if p95 > budget {
            fputs(String(format: "FAIL: p95 %.3f ms exceeds %.0f Hz frame budget %.3f ms\n",
                         p95, targetFPS, budget), stderr)
            exit(1)
        }
        print(String(format: "PASS: direct-volume preview sustains the %.0f Hz interaction budget",
                     targetFPS))
    }
}
