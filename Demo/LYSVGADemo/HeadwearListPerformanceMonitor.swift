import Darwin
import QuartzCore
import UIKit

struct HeadwearListPerformanceSnapshot: Sendable {
    let framesPerSecond: Double
    let p95FrameMilliseconds: Double
    let hitchRate: Double
    let visiblePlayerCount: Int
    let residentMemoryBytes: UInt64
}

struct HeadwearListBenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let deviceModel: String
    let systemVersion: String
    let mode: String
    let rowCount: Int
    let assetFileNames: [String]
    let warmupSeconds: Double
    let durationSeconds: Double
    let averageFramesPerSecond: Double
    let p95FrameMilliseconds: Double
    let hitchRate: Double
    let peakResidentBytes: UInt64
    let traversalPeakResidentBytes: [UInt64]
}

@MainActor
final class HeadwearListPerformanceMonitor {
    var onUpdate: ((HeadwearListPerformanceSnapshot) -> Void)?
    var onFrame: ((TimeInterval) -> Void)?

    private var displayLink: CADisplayLink?
    private var previousTimestamp: TimeInterval?
    private var rollingIntervals: [TimeInterval] = []
    private var measurementIntervals: [TimeInterval] = []
    private var expectedFrameDuration = 1.0 / 60.0
    private var lastUpdateTimestamp: TimeInterval = 0
    private var visiblePlayerCount = 0
    private var isMeasuring = false
    private var measurementPeakResidentBytes: UInt64 = 0
    private var traversalPeakResidentBytes: [UInt64] = []
    private var currentTraversalPeakResidentBytes: UInt64 = 0
    private var currentTraversalHasFrames = false

    func start() {
        guard displayLink == nil else { return }
        previousTimestamp = nil
        let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
        isMeasuring = false
    }

    func resetRollingMetrics() {
        rollingIntervals.removeAll(keepingCapacity: true)
        previousTimestamp = nil
        emitSnapshot()
    }

    func updateVisiblePlayerCount(_ count: Int) {
        visiblePlayerCount = max(0, count)
    }

    func beginMeasurement() {
        measurementIntervals.removeAll(keepingCapacity: true)
        traversalPeakResidentBytes.removeAll(keepingCapacity: true)
        let memory = Self.residentMemoryBytes()
        measurementPeakResidentBytes = memory
        currentTraversalPeakResidentBytes = memory
        currentTraversalHasFrames = false
        isMeasuring = true
    }

    func markTraversalBoundary() {
        guard isMeasuring else { return }
        traversalPeakResidentBytes.append(currentTraversalPeakResidentBytes)
        currentTraversalPeakResidentBytes = Self.residentMemoryBytes()
        currentTraversalHasFrames = false
    }

    func cancelMeasurement() {
        isMeasuring = false
        measurementIntervals.removeAll(keepingCapacity: true)
        traversalPeakResidentBytes.removeAll(keepingCapacity: true)
        currentTraversalHasFrames = false
    }

    func finishMeasurement(
        mode: HeadwearListMode,
        rowCount: Int,
        assetFileNames: [String],
        warmupSeconds: Double,
        durationSeconds: Double
    ) -> HeadwearListBenchmarkReport? {
        guard isMeasuring, measurementIntervals.isEmpty == false else { return nil }
        isMeasuring = false
        if currentTraversalHasFrames {
            traversalPeakResidentBytes.append(currentTraversalPeakResidentBytes)
        }
        return HeadwearListBenchmarkReport(
            schemaVersion: 1,
            generatedAt: Date(),
            deviceModel: Self.deviceModelIdentifier(),
            systemVersion: UIDevice.current.systemVersion,
            mode: mode.title.lowercased(),
            rowCount: rowCount,
            assetFileNames: assetFileNames,
            warmupSeconds: warmupSeconds,
            durationSeconds: durationSeconds,
            averageFramesPerSecond: Self.framesPerSecond(for: measurementIntervals),
            p95FrameMilliseconds: Self.percentile(measurementIntervals, percentile: 0.95) * 1_000,
            hitchRate: hitchRate(for: measurementIntervals),
            peakResidentBytes: measurementPeakResidentBytes,
            traversalPeakResidentBytes: traversalPeakResidentBytes
        )
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        let targetDuration = displayLink.targetTimestamp - displayLink.timestamp
        if targetDuration.isFinite, targetDuration > 0 {
            expectedFrameDuration = targetDuration
        }
        defer { previousTimestamp = displayLink.timestamp }
        guard let previousTimestamp else { return }

        let interval = displayLink.timestamp - previousTimestamp
        guard interval.isFinite, interval > 0, interval < 1 else { return }
        rollingIntervals.append(interval)
        if rollingIntervals.count > 180 {
            rollingIntervals.removeFirst(rollingIntervals.count - 180)
        }
        if isMeasuring {
            measurementIntervals.append(interval)
            let memory = Self.residentMemoryBytes()
            measurementPeakResidentBytes = max(measurementPeakResidentBytes, memory)
            currentTraversalPeakResidentBytes = max(currentTraversalPeakResidentBytes, memory)
            currentTraversalHasFrames = true
        }
        onFrame?(interval)
        if displayLink.timestamp - lastUpdateTimestamp >= 0.5 {
            lastUpdateTimestamp = displayLink.timestamp
            emitSnapshot()
        }
    }

    private func emitSnapshot() {
        onUpdate?(HeadwearListPerformanceSnapshot(
            framesPerSecond: Self.framesPerSecond(for: rollingIntervals),
            p95FrameMilliseconds: Self.percentile(rollingIntervals, percentile: 0.95) * 1_000,
            hitchRate: hitchRate(for: rollingIntervals),
            visiblePlayerCount: visiblePlayerCount,
            residentMemoryBytes: Self.residentMemoryBytes()
        ))
    }

    private func hitchRate(for intervals: [TimeInterval]) -> Double {
        guard intervals.isEmpty == false else { return 0 }
        let threshold = expectedFrameDuration * 1.5
        let hitches = intervals.lazy.filter { $0 > threshold }.count
        return Double(hitches) / Double(intervals.count)
    }

    private static func framesPerSecond(for intervals: [TimeInterval]) -> Double {
        let total = intervals.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(intervals.count) / total
    }

    private static func percentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval {
        let sorted = values.sorted()
        guard sorted.isEmpty == false else { return 0 }
        let rank = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func residentMemoryBytes() -> UInt64 {
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

    private static func deviceModelIdentifier() -> String {
        if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatorModel
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineSize = MemoryLayout.size(ofValue: systemInfo.machine)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                String(cString: $0)
            }
        }
    }
}
