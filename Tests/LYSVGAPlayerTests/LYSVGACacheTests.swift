import Foundation
import XCTest
@testable import LYSVGAPlayer

final class LYSVGACacheTests: XCTestCase {
    func testMemoryCacheUsesCountLimitedLRUAndClear() async throws {
        let cache = LYSVGACache(configuration: configuration(memoryCount: 2))
        await cache.store(video: try TestSupport.video(version: "one"), forKey: "one")
        await cache.store(video: try TestSupport.video(version: "two"), forKey: "two")
        _ = await cache.video(forKey: "one")
        await cache.store(video: try TestSupport.video(version: "three"), forKey: "three")

        let one = await cache.video(forKey: "one")
        let two = await cache.video(forKey: "two")
        let three = await cache.video(forKey: "three")
        XCTAssertNotNil(one)
        XCTAssertNil(two)
        XCTAssertNotNil(three)

        await cache.clearMemory()
        let cleared = await cache.video(forKey: "one")
        XCTAssertNil(cleared)
    }

    func testDiskCachePersistsExpiresAndClears() async throws {
        let directory = TestSupport.temporaryDirectory()
        let configuration = LYSVGACacheConfiguration(
            directory: directory,
            memoryCountLimit: 1,
            memoryCostLimit: 1_024,
            diskSizeLimit: 1_024,
            timeToLive: 10
        )
        let first = LYSVGACache(configuration: configuration)
        let data = Data("movie".utf8)
        let now = Date(timeIntervalSince1970: 1_000)
        try await first.store(data: data, forKey: "key", now: now)

        let second = LYSVGACache(configuration: configuration)
        let persisted = try await second.data(forKey: "key", now: now.addingTimeInterval(1))
        let expired = try await second.data(forKey: "key", now: now.addingTimeInterval(11))
        XCTAssertEqual(persisted, data)
        XCTAssertNil(expired)

        try await first.store(data: data, forKey: "key", now: now)
        try await first.clearDisk()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func configuration(memoryCount: Int) -> LYSVGACacheConfiguration {
        LYSVGACacheConfiguration(
            directory: TestSupport.temporaryDirectory(),
            memoryCountLimit: memoryCount,
            memoryCostLimit: 10_000,
            diskSizeLimit: 10_000,
            timeToLive: 60
        )
    }
}
