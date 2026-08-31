import Darwin
@_spi(LYSVGABenchmark) import LYSVGAPlayer
import QuartzCore
import SwiftUI

@main
struct LYSVGADemoApp: App {
    init() {
        DemoSupport.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["LYSVGA_DEVICE_BENCHMARK"] == "1" {
                DeviceBenchmarkView()
            } else {
                TabView {
                    SwiftUIDemoView()
                        .tabItem { Label("SwiftUI", systemImage: "swift") }

                    UIKitDemoContainer()
                        .tabItem { Label("UIKit", systemImage: "rectangle.on.rectangle") }
                }
            }
        }
    }
}

private struct UIKitDemoContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: UIKitDemoViewController())
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

private struct DeviceBenchmarkResult: Codable, Sendable {
    let name: String
    let iterations: Int
    let metrics: [String: Double]
}

private struct DeviceFirstPlayableMeasurement: Sendable {
    let wallMilliseconds: Double
    let cpuMilliseconds: Double
    let decodeMilliseconds: Double
    let prepareMilliseconds: Double
    let layoutDisplayMilliseconds: Double
    let renderMilliseconds: Double
    let layerCount: Int
}

private struct DeviceBenchmarkReport: Codable, Sendable {
    let results: [DeviceBenchmarkResult]
}

private struct DeviceBenchmarkView: View {
    var body: some View {
        ProgressView()
            .task {
                await DeviceBenchmarkRunner().run()
            }
    }
}

@MainActor
private struct DeviceBenchmarkRunner {
    private let renderSize = CGSize(width: 256, height: 256)

    func run() async {
        do {
            let v1Data = try bundledFixture("matteBitmap_1.x")
            let v2Data = try bundledFixture("rose_2.0.0")
            let businessData = try localBusinessFixture()
            var results: [DeviceBenchmarkResult] = []
            results.append(try await benchmarkParsing(data: v1Data, name: "parse.v1", iterations: 10))
            results.append(try await benchmarkParsing(data: v2Data, name: "parse.v2", iterations: 20))
            results.append(try await benchmarkFirstPlayable(data: businessData))
            let v2Video = try await loadVideo(data: v2Data)
            results.append(try await benchmarkFirstFrame(video: v2Video))
            results.append(try await benchmarkContinuousRendering(video: v2Video))
            try writeAndEmit(results)
            fflush(stdout)
            exit(EXIT_SUCCESS)
        } catch {
            fputs("LYSVGA_DEVICE_BENCHMARK_ERROR \(String(describing: error))\n", stderr)
            fflush(stderr)
            exit(EXIT_FAILURE)
        }
    }

    private func benchmarkParsing(
        data: Data,
        name: String,
        iterations: Int
    ) async throws -> DeviceBenchmarkResult {
        let loader = LYSVGAAssetLoader()
        var totalWallSeconds = 0.0
        var totalCPUSeconds = 0.0
        var peakResidentBytes = residentMemoryBytes()
        for _ in 0..<iterations {
            let wallStart = CACurrentMediaTime()
            let cpuStart = processCPUSeconds()
            _ = try await loader.load(
                .data(data, cacheKey: UUID().uuidString),
                cachePolicy: .noCache
            )
            totalWallSeconds += CACurrentMediaTime() - wallStart
            totalCPUSeconds += processCPUSeconds() - cpuStart
            peakResidentBytes = max(peakResidentBytes, residentMemoryBytes())
        }
        return DeviceBenchmarkResult(
            name: name,
            iterations: iterations,
            metrics: [
                "wallMilliseconds": totalWallSeconds * 1_000 / Double(iterations),
                "cpuMilliseconds": totalCPUSeconds * 1_000 / Double(iterations),
                "peakResidentBytes": Double(peakResidentBytes),
            ]
        )
    }

    private func benchmarkFirstPlayable(data: Data) async throws -> DeviceBenchmarkResult {
        for _ in 0..<3 {
            _ = try await measureFirstPlayable(data: data)
        }

        var measurements: [DeviceFirstPlayableMeasurement] = []
        var peakResidentBytes = residentMemoryBytes()
        for _ in 0..<30 {
            measurements.append(try await measureFirstPlayable(data: data))
            peakResidentBytes = max(peakResidentBytes, residentMemoryBytes())
        }
        let wallMilliseconds = measurements.map(\.wallMilliseconds)
        return DeviceBenchmarkResult(
            name: "first-playable.v2",
            iterations: measurements.count,
            metrics: [
                "wallMilliseconds": median(wallMilliseconds),
                "p95WallMilliseconds": percentile(wallMilliseconds, percentile: 0.95),
                "cpuMilliseconds": median(measurements.map(\.cpuMilliseconds)),
                "decodeMilliseconds": median(measurements.map(\.decodeMilliseconds)),
                "prepareMilliseconds": median(measurements.map(\.prepareMilliseconds)),
                "layoutDisplayMilliseconds": median(measurements.map(\.layoutDisplayMilliseconds)),
                "renderMilliseconds": median(measurements.map(\.renderMilliseconds)),
                "layerCount": Double(measurements.last?.layerCount ?? 0),
                "peakResidentBytes": Double(peakResidentBytes),
            ]
        )
    }

    private func measureFirstPlayable(data: Data) async throws -> DeviceFirstPlayableMeasurement {
        LYSVGABenchmarkSupport.resetPreparedImageCache()
        let loader = LYSVGAAssetLoader()
        let player = makePlayer()
        let wallStart = CACurrentMediaTime()
        let cpuStart = processCPUSeconds()
        let video = try await loader.load(
            .data(data, cacheKey: UUID().uuidString),
            cachePolicy: .noCache
        )
        let decodeEnd = CACurrentMediaTime()
        try await player.setVideo(video)
        let prepareEnd = CACurrentMediaTime()
        player.layoutIfNeeded()
        let layoutEnd = CACurrentMediaTime()
        _ = try render(player.layer)
        let renderEnd = CACurrentMediaTime()
        let measurement = DeviceFirstPlayableMeasurement(
            wallMilliseconds: (renderEnd - wallStart) * 1_000,
            cpuMilliseconds: (processCPUSeconds() - cpuStart) * 1_000,
            decodeMilliseconds: (decodeEnd - wallStart) * 1_000,
            prepareMilliseconds: (prepareEnd - decodeEnd) * 1_000,
            layoutDisplayMilliseconds: (layoutEnd - prepareEnd) * 1_000,
            renderMilliseconds: (renderEnd - layoutEnd) * 1_000,
            layerCount: recursiveLayerCount(player.layer)
        )
        await player.waitForImagePreheat()
        player.clear()
        return measurement
    }

    private func benchmarkFirstFrame(video: LYSVGAVideo) async throws -> DeviceBenchmarkResult {
        let iterations = 5
        var totalWallSeconds = 0.0
        var totalCPUSeconds = 0.0
        var totalPrepareSeconds = 0.0
        var totalLayoutSeconds = 0.0
        var totalRenderSeconds = 0.0
        var peakResidentBytes = residentMemoryBytes()
        var layerCount = 0

        for _ in 0..<iterations {
            let player = makePlayer()
            let wallStart = CACurrentMediaTime()
            let cpuStart = processCPUSeconds()
            try await player.setVideo(video)
            let prepareEnd = CACurrentMediaTime()
            player.layoutIfNeeded()
            let layoutEnd = CACurrentMediaTime()
            _ = try render(player.layer)
            let renderEnd = CACurrentMediaTime()
            totalWallSeconds += renderEnd - wallStart
            totalCPUSeconds += processCPUSeconds() - cpuStart
            totalPrepareSeconds += prepareEnd - wallStart
            totalLayoutSeconds += layoutEnd - prepareEnd
            totalRenderSeconds += renderEnd - layoutEnd
            peakResidentBytes = max(peakResidentBytes, residentMemoryBytes())
            layerCount = recursiveLayerCount(player.layer)
            await player.waitForImagePreheat()
            player.clear()
        }
        return DeviceBenchmarkResult(
            name: "first-frame.v2",
            iterations: iterations,
            metrics: [
                "wallMilliseconds": totalWallSeconds * 1_000 / Double(iterations),
                "cpuMilliseconds": totalCPUSeconds * 1_000 / Double(iterations),
                "prepareMilliseconds": totalPrepareSeconds * 1_000 / Double(iterations),
                "layoutDisplayMilliseconds": totalLayoutSeconds * 1_000 / Double(iterations),
                "renderMilliseconds": totalRenderSeconds * 1_000 / Double(iterations),
                "layerCount": Double(layerCount),
                "peakResidentBytes": Double(peakResidentBytes),
            ]
        )
    }

    private func benchmarkContinuousRendering(video: LYSVGAVideo) async throws -> DeviceBenchmarkResult {
        LYSVGABenchmarkSupport.resetPreparedImageCache()
        let player = makePlayer()
        try await player.setVideo(video)
        await player.waitForImagePreheat()
        player.layoutIfNeeded()
        let context = try makeContext()
        let iterations = 300
        let frameBudget = 1.0 / Double(video.fps)
        var overBudgetFrames = 0
        var peakResidentBytes = residentMemoryBytes()
        let wallStart = CACurrentMediaTime()
        let cpuStart = processCPUSeconds()

        for index in 0..<iterations {
            let frameStart = CACurrentMediaTime()
            context.clear(CGRect(origin: .zero, size: renderSize))
            context.saveGState()
            context.translateBy(x: 0, y: renderSize.height)
            context.scaleBy(x: 1, y: -1)
            player.seek(toFrame: index % video.frameCount)
            player.layer.render(in: context)
            context.restoreGState()
            if CACurrentMediaTime() - frameStart > frameBudget {
                overBudgetFrames += 1
            }
            if index.isMultiple(of: 10) {
                peakResidentBytes = max(peakResidentBytes, residentMemoryBytes())
            }
        }

        let wallSeconds = CACurrentMediaTime() - wallStart
        let cpuSeconds = processCPUSeconds() - cpuStart
        player.clear()
        return DeviceBenchmarkResult(
            name: "continuous-render.v2",
            iterations: iterations,
            metrics: [
                "wallMilliseconds": wallSeconds * 1_000,
                "cpuMilliseconds": cpuSeconds * 1_000,
                "averageFrameMilliseconds": wallSeconds * 1_000 / Double(iterations),
                "peakResidentBytes": Double(peakResidentBytes),
                "droppedFrameRate": Double(overBudgetFrames) / Double(iterations),
            ]
        )
    }

    private func loadVideo(data: Data) async throws -> LYSVGAVideo {
        try await LYSVGAAssetLoader().load(
            .data(data, cacheKey: UUID().uuidString),
            cachePolicy: .noCache
        )
    }

    private func makePlayer() -> LYSVGAPlayerView {
        let player = LYSVGAPlayerView(frame: CGRect(origin: .zero, size: renderSize))
        player.contentMode = .scaleAspectFit
        player.clipsToBounds = true
        return player
    }

    private func render(_ layer: CALayer) throws -> CGImage {
        let context = try makeContext()
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else {
            throw CocoaError(.coderInvalidValue)
        }
        return image
    }

    private func makeContext() throws -> CGContext {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(renderSize.width),
                  height: Int(renderSize.height),
                  bitsPerComponent: 8,
                  bytesPerRow: Int(renderSize.width) * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                      | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CocoaError(.coderInvalidValue)
        }
        return context
    }

    private func bundledFixture(_ name: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svga") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func localBusinessFixture() throws -> Data {
        let fileName = ProcessInfo.processInfo.environment["LYSVGA_BENCHMARK_ASSET"]
            ?? "head_wear_vip9.svga"
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(
            contentsOf: documentsURL.appendingPathComponent(fileName),
            options: .mappedIfSafe
        )
    }

    private func writeAndEmit(_ results: [DeviceBenchmarkResult]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportData = try encoder.encode(DeviceBenchmarkReport(results: results))
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try reportData.write(
            to: documentsURL.appendingPathComponent("lysvga-device-benchmark.json"),
            options: .atomic
        )
        encoder.outputFormatting = [.sortedKeys]
        for result in results {
            let data = try encoder.encode(result)
            print("LYSVGA_BENCHMARK_RESULT \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func recursiveLayerCount(_ layer: CALayer) -> Int {
        1 + (layer.sublayers?.reduce(0) { $0 + recursiveLayerCount($1) } ?? 0)
    }

    private func median(_ values: [Double]) -> Double {
        let sortedValues = values.sorted()
        guard sortedValues.isEmpty == false else { return 0 }
        let middle = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middle - 1] + sortedValues[middle]) / 2
        }
        return sortedValues[middle]
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        let sortedValues = values.sorted()
        guard sortedValues.isEmpty == false else { return 0 }
        let rank = Int(ceil(percentile * Double(sortedValues.count))) - 1
        return sortedValues[min(max(rank, 0), sortedValues.count - 1)]
    }

    private func processCPUSeconds() -> Double {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
