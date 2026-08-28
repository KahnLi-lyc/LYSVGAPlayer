import CoreGraphics
import Darwin
import Foundation
import QuartzCore
import UIKit
import XCTest
@testable import LYSVGAPlayer

private struct BenchmarkResult: Codable, Sendable {
    let name: String
    let iterations: Int
    let metrics: [String: Double]
}

private struct FirstPlayableMeasurement: Sendable {
    let wallSeconds: Double
    let cpuSeconds: Double
    let decodeSeconds: Double
    let prepareSeconds: Double
    let layoutDisplaySeconds: Double
    let renderSeconds: Double
    let layerCount: Int
}

@MainActor
final class LYSVGABenchmarkTests: XCTestCase {
    func testBenchmarks() async throws {
        try benchmarkV1Parsing()
        try benchmarkV2Parsing()
        try await benchmarkV2FirstPlayable()
        try await benchmarkV2FirstFrame()
        try await benchmarkContinuousRendering()
    }

    private func benchmarkV1Parsing() throws {
        try benchmarkParsing(fixture: "matteBitmap_1.x", name: "parse.v1", iterations: 10)
    }

    private func benchmarkV2Parsing() throws {
        try benchmarkParsing(fixture: "rose_2.0.0", name: "parse.v2", iterations: 20)
    }

    private func benchmarkV2FirstPlayable() async throws {
        let selectedFixture = try playableFixture()
        let size = CGSize(width: 256, height: 256)
        let warmupIterations = 3
        let measuredIterations = 30

        for _ in 0..<warmupIterations {
            _ = try await measureFirstPlayable(data: selectedFixture.data, size: size)
        }

        var measurements: [FirstPlayableMeasurement] = []
        measurements.reserveCapacity(measuredIterations)
        var peakResidentBytes = residentMemoryBytes()
        for _ in 0..<measuredIterations {
            measurements.append(try await measureFirstPlayable(data: selectedFixture.data, size: size))
            peakResidentBytes = max(peakResidentBytes, residentMemoryBytes())
        }

        let wallMilliseconds = measurements.map { $0.wallSeconds * 1_000 }
        print("LYSVGA_FIRST_PLAYABLE_ASSET \(selectedFixture.name)")
        emit(BenchmarkResult(
            name: "first-playable.v2",
            iterations: measuredIterations,
            metrics: [
                "wallMilliseconds": median(wallMilliseconds),
                "p95WallMilliseconds": percentile(wallMilliseconds, percentile: 0.95),
                "cpuMilliseconds": median(measurements.map { $0.cpuSeconds * 1_000 }),
                "decodeMilliseconds": median(measurements.map { $0.decodeSeconds * 1_000 }),
                "prepareMilliseconds": median(measurements.map { $0.prepareSeconds * 1_000 }),
                "layoutDisplayMilliseconds": median(measurements.map { $0.layoutDisplaySeconds * 1_000 }),
                "renderMilliseconds": median(measurements.map { $0.renderSeconds * 1_000 }),
                "layerCount": Double(measurements.last?.layerCount ?? 0),
                "peakResidentBytes": Double(peakResidentBytes),
            ]
        ))
    }

    private func benchmarkV2FirstFrame() async throws {
        let data = try fixture("rose_2.0.0")
        let video = try LYSVGAFormatDecoder.decode(data)
        let size = CGSize(width: 256, height: 256)
        let iterations = 5
        var totalWallSeconds = 0.0
        var totalCPUSeconds = 0.0
        var totalPrepareSeconds = 0.0
        var totalLayoutDisplaySeconds = 0.0
        var totalRenderSeconds = 0.0
        var peakResidentBytes = residentMemoryBytes()
        var layerCount = 0

        for _ in 0..<iterations {
            let wallStart = ContinuousClock.now
            let cpuStart = processCPUSeconds()
            let renderer = LYSVGARenderer()
            try await renderer.prepare(video: video)
            let prepareEnd = ContinuousClock.now
            renderer.layout(in: CGRect(origin: .zero, size: size), contentMode: .scaleAspectFit, clipsToBounds: true)
            renderer.display(frame: 0)
            let layoutDisplayEnd = ContinuousClock.now
            _ = try render(renderer.rootLayer, size: size)
            let renderEnd = ContinuousClock.now
            totalWallSeconds += seconds(from: wallStart.duration(to: renderEnd))
            totalCPUSeconds += processCPUSeconds() - cpuStart
            totalPrepareSeconds += seconds(from: wallStart.duration(to: prepareEnd))
            totalLayoutDisplaySeconds += seconds(from: prepareEnd.duration(to: layoutDisplayEnd))
            totalRenderSeconds += seconds(from: layoutDisplayEnd.duration(to: renderEnd))
            peakResidentBytes = max(peakResidentBytes, residentMemoryBytes())
            layerCount = recursiveLayerCount(renderer.rootLayer)
            await renderer.waitForImagePreheat()
        }

        emit(BenchmarkResult(
            name: "first-frame.v2",
            iterations: iterations,
            metrics: [
                "wallMilliseconds": totalWallSeconds * 1_000 / Double(iterations),
                "cpuMilliseconds": totalCPUSeconds * 1_000 / Double(iterations),
                "prepareMilliseconds": totalPrepareSeconds * 1_000 / Double(iterations),
                "layoutDisplayMilliseconds": totalLayoutDisplaySeconds * 1_000 / Double(iterations),
                "renderMilliseconds": totalRenderSeconds * 1_000 / Double(iterations),
                "layerCount": Double(layerCount),
                "peakResidentBytes": Double(peakResidentBytes),
            ]
        ))
    }

    private func benchmarkContinuousRendering() async throws {
        LYSVGAImagePreparer.resetCacheForTesting()
        let data = try fixture("rose_2.0.0")
        let video = try LYSVGAFormatDecoder.decode(data)
        let renderer = LYSVGARenderer()
        try await renderer.prepare(video: video)
        await renderer.waitForImagePreheat()
        let size = CGSize(width: 256, height: 256)
        renderer.layout(in: CGRect(origin: .zero, size: size), contentMode: .scaleAspectFit, clipsToBounds: true)
        let context = try makeContext(size: size)
        let iterations = 300
        let frameBudget = 1.0 / Double(video.fps)
        var overBudgetFrames = 0
        var peakResidentBytes = residentMemoryBytes()
        let wallStart = ContinuousClock.now
        let cpuStart = processCPUSeconds()

        for index in 0..<iterations {
            let frameStart = ContinuousClock.now
            context.clear(CGRect(origin: .zero, size: size))
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            renderer.display(frame: index % video.frameCount)
            renderer.rootLayer.render(in: context)
            context.restoreGState()
            if seconds(from: frameStart.duration(to: .now)) > frameBudget {
                overBudgetFrames += 1
            }
            if index.isMultiple(of: 10) {
                peakResidentBytes = max(peakResidentBytes, residentMemoryBytes())
            }
        }

        let wallSeconds = seconds(from: wallStart.duration(to: .now))
        let cpuSeconds = processCPUSeconds() - cpuStart
        emit(BenchmarkResult(
            name: "continuous-render.v2",
            iterations: iterations,
            metrics: [
                "wallMilliseconds": wallSeconds * 1_000,
                "cpuMilliseconds": cpuSeconds * 1_000,
                "averageFrameMilliseconds": wallSeconds * 1_000 / Double(iterations),
                "peakResidentBytes": Double(peakResidentBytes),
                "droppedFrameRate": Double(overBudgetFrames) / Double(iterations),
            ]
        ))
    }
}

@MainActor
private extension LYSVGABenchmarkTests {
    func measureFirstPlayable(data: Data, size: CGSize) async throws -> FirstPlayableMeasurement {
        LYSVGAImagePreparer.resetCacheForTesting()
        let wallStart = ContinuousClock.now
        let cpuStart = processCPUSeconds()
        let video = try LYSVGAFormatDecoder.decode(data)
        let decodeEnd = ContinuousClock.now
        let renderer = LYSVGARenderer()
        try await renderer.prepare(video: video)
        let prepareEnd = ContinuousClock.now
        renderer.layout(
            in: CGRect(origin: .zero, size: size),
            contentMode: .scaleAspectFit,
            clipsToBounds: true
        )
        renderer.display(frame: 0)
        let layoutDisplayEnd = ContinuousClock.now
        _ = try render(renderer.rootLayer, size: size)
        let renderEnd = ContinuousClock.now

        let measurement = FirstPlayableMeasurement(
            wallSeconds: seconds(from: wallStart.duration(to: renderEnd)),
            cpuSeconds: processCPUSeconds() - cpuStart,
            decodeSeconds: seconds(from: wallStart.duration(to: decodeEnd)),
            prepareSeconds: seconds(from: decodeEnd.duration(to: prepareEnd)),
            layoutDisplaySeconds: seconds(from: prepareEnd.duration(to: layoutDisplayEnd)),
            renderSeconds: seconds(from: layoutDisplayEnd.duration(to: renderEnd)),
            layerCount: recursiveLayerCount(renderer.rootLayer)
        )
        await renderer.waitForImagePreheat()
        return measurement
    }

    func benchmarkParsing(fixture fixtureName: String, name: String, iterations: Int) throws {
        let data = try fixture(fixtureName)
        let wallStart = ContinuousClock.now
        let cpuStart = processCPUSeconds()
        var peakResidentBytes = residentMemoryBytes()

        for index in 0..<iterations {
            _ = try autoreleasepool { try LYSVGAFormatDecoder.decode(data) }
            if index.isMultiple(of: 2) {
                peakResidentBytes = max(peakResidentBytes, residentMemoryBytes())
            }
        }

        let wallSeconds = seconds(from: wallStart.duration(to: .now))
        let cpuSeconds = processCPUSeconds() - cpuStart
        emit(BenchmarkResult(
            name: name,
            iterations: iterations,
            metrics: [
                "wallMilliseconds": wallSeconds * 1_000 / Double(iterations),
                "cpuMilliseconds": cpuSeconds * 1_000 / Double(iterations),
                "peakResidentBytes": Double(peakResidentBytes),
            ]
        ))
    }

    func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svga", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func playableFixture() throws -> (name: String, data: Data) {
        if let url = Bundle.module.url(
            forResource: "local-business",
            withExtension: "svga",
            subdirectory: "Fixtures"
        ) {
            return ("local-business.svga", try Data(contentsOf: url, options: .mappedIfSafe))
        }
        return ("rose_2.0.0.svga", try fixture("rose_2.0.0"))
    }

    func render(_ layer: CALayer, size: CGSize) throws -> CGImage {
        let context = try makeContext(size: size)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        return image
    }

    func makeContext(size: CGSize) throws -> CGContext {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: Int(size.width) * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CocoaError(.coderInvalidValue)
        }
        return context
    }

    func recursiveLayerCount(_ layer: CALayer) -> Int {
        1 + (layer.sublayers?.reduce(0) { $0 + recursiveLayerCount($1) } ?? 0)
    }

    func median(_ values: [Double]) -> Double {
        let sortedValues = values.sorted()
        guard sortedValues.isEmpty == false else { return 0 }
        let middle = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middle - 1] + sortedValues[middle]) / 2
        }
        return sortedValues[middle]
    }

    func percentile(_ values: [Double], percentile: Double) -> Double {
        let sortedValues = values.sorted()
        guard sortedValues.isEmpty == false else { return 0 }
        let rank = Int(ceil(percentile * Double(sortedValues.count))) - 1
        return sortedValues[min(max(rank, 0), sortedValues.count - 1)]
    }

    func emit(_ result: BenchmarkResult) {
        XCTAssertTrue(result.metrics.values.allSatisfy(\.isFinite))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) else {
            return XCTFail("Unable to encode benchmark result.")
        }
        print("LYSVGA_BENCHMARK_RESULT \(json)")
    }

    func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    func processCPUSeconds() -> Double {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
