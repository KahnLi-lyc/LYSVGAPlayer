import Foundation
import XCTest
@testable import LYSVGAPlayer

final class LYSVGAAssetLoaderTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testRejectsNon2xxHTTPResponse() async throws {
        URLProtocolStub.configure(statusCode: 503, data: Data(), delay: 0)
        let (loader, session) = makeLoader()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await loader.load(.remote(testURL), cachePolicy: .noCache)
            XCTFail("Expected an HTTP status error.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .httpStatus(503))
        }
    }

    func testCoalescesConcurrentRequestsBySourceKey() async throws {
        URLProtocolStub.configure(
            statusCode: 200,
            data: try TestSupport.fixture("matteRect"),
            delay: 0.1
        )
        let (loader, session) = makeLoader()
        defer { session.invalidateAndCancel() }
        let url = testURL

        async let first = loader.load(.remote(url), cachePolicy: .noCache)
        async let second = loader.load(.remote(url), cachePolicy: .noCache)
        let videos = try await (first, second)

        XCTAssertEqual(videos.0, videos.1)
        XCTAssertEqual(URLProtocolStub.startCount, 1)
    }

    func testCancellingOneWaiterKeepsSharedRequestAlive() async throws {
        URLProtocolStub.configure(
            statusCode: 200,
            data: try TestSupport.fixture("matteRect"),
            delay: 0.15
        )
        let (loader, session) = makeLoader()
        defer { session.invalidateAndCancel() }
        let url = testURL

        let first = Task { try await loader.load(.remote(url), cachePolicy: .noCache) }
        let second = Task { try await loader.load(.remote(url), cachePolicy: .noCache) }
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("Expected the cancelled waiter to fail.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        let video = try await second.value
        XCTAssertGreaterThan(video.frameCount, 0)
        XCTAssertEqual(URLProtocolStub.startCount, 1)
        XCTAssertEqual(URLProtocolStub.stopCount, 0)
    }

    func testCancellingLastWaiterCancelsUnderlyingRequest() async throws {
        URLProtocolStub.configure(
            statusCode: 200,
            data: try TestSupport.fixture("matteRect"),
            delay: 1
        )
        let (loader, session) = makeLoader()
        defer { session.invalidateAndCancel() }
        let url = testURL

        let task = Task { try await loader.load(.remote(url), cachePolicy: .noCache) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(URLProtocolStub.stopCount, 1)
    }

    func testCancellingLastWaiterInterruptsDetachedDecoder() async throws {
        let probe = DecoderCancellationProbe()
        let loader = LYSVGAAssetLoader(
            session: .shared,
            cacheConfiguration: cacheConfiguration(directory: TestSupport.temporaryDirectory()),
            reader: { _, _ in Data([0x01]) },
            decoder: { _ in try probe.decodeUntilCancelled() }
        )
        let source = LYSVGASource.data(Data([0x01]), cacheKey: "cancellable-decode")
        let task = Task { try await loader.load(source, cachePolicy: .noCache) }
        for _ in 0 ..< 100 where probe.hasStarted == false {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(probe.hasStarted)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        for _ in 0 ..< 100 where probe.observedCancellation == false {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(probe.observedCancellation)
    }

    func testAutomaticDiskCacheAndClearAvoidSecondNetworkRequest() async throws {
        URLProtocolStub.configure(
            statusCode: 200,
            data: try TestSupport.fixture("matteRect"),
            delay: 0
        )
        let directory = TestSupport.temporaryDirectory()
        let (loader, session) = makeLoader(directory: directory)
        defer { session.invalidateAndCancel() }

        _ = try await loader.load(.remote(testURL), cachePolicy: .automatic)
        await loader.clearMemoryCache()
        _ = try await loader.load(.remote(testURL), cachePolicy: .automatic)
        XCTAssertEqual(URLProtocolStub.startCount, 1)

        try await loader.clearDiskCache()
        await loader.clearMemoryCache()
        _ = try await loader.load(.remote(testURL), cachePolicy: .automatic)
        XCTAssertEqual(URLProtocolStub.startCount, 2)
    }

    func testCachePolicySemanticsAndFailuresAreNotCached() async throws {
        URLProtocolStub.configure(statusCode: 500, data: Data(), delay: 0)
        let directory = TestSupport.temporaryDirectory()
        let (loader, session) = makeLoader(directory: directory)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await loader.load(.remote(testURL), cachePolicy: .automatic)
            XCTFail("Expected HTTP failure.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .httpStatus(500))
        }

        URLProtocolStub.configure(
            statusCode: 200,
            data: try TestSupport.fixture("matteRect"),
            delay: 0,
            resetCounts: false
        )
        _ = try await loader.load(.remote(testURL), cachePolicy: .memoryOnly)
        _ = try await loader.load(.remote(testURL), cachePolicy: .memoryOnly)
        XCTAssertEqual(URLProtocolStub.startCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        _ = try await loader.load(.remote(testURL), cachePolicy: .noCache)
        _ = try await loader.load(.remote(testURL), cachePolicy: .noCache)
        XCTAssertEqual(URLProtocolStub.startCount, 4)

        _ = try await loader.load(.remote(testURL), cachePolicy: .reloadIgnoringCache)
        _ = try await loader.load(.remote(testURL), cachePolicy: .reloadIgnoringCache)
        XCTAssertEqual(URLProtocolStub.startCount, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    private var testURL: URL {
        URL(string: "https://example.com/asset.svga")!
    }

    private func makeLoader(directory: URL = TestSupport.temporaryDirectory()) -> (LYSVGAAssetLoader, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return (LYSVGAAssetLoader(session: session, cacheConfiguration: cacheConfiguration(directory: directory)), session)
    }

    private func cacheConfiguration(directory: URL) -> LYSVGACacheConfiguration {
        LYSVGACacheConfiguration(
            directory: directory,
            memoryCountLimit: 4,
            memoryCostLimit: 1_024 * 1_024,
            diskSizeLimit: 4 * 1_024 * 1_024,
            timeToLive: 60
        )
    }
}

private final class DecoderCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var observedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func decodeUntilCancelled() throws -> LYSVGAVideo {
        lock.lock()
        started = true
        lock.unlock()
        while true {
            do {
                try Task.checkCancellation()
            } catch {
                lock.lock()
                cancelled = true
                lock.unlock()
                throw error
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private struct Configuration: Sendable {
        let statusCode: Int
        let data: Data
        let delay: TimeInterval
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuration = Configuration(statusCode: 200, data: Data(), delay: 0)
    nonisolated(unsafe) private static var starts = 0
    nonisolated(unsafe) private static var stops = 0

    private var workItem: DispatchWorkItem?
    private let stateLock = NSLock()
    private var didFinish = false

    static var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    static var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    static func configure(
        statusCode: Int,
        data: Data,
        delay: TimeInterval,
        resetCounts: Bool = true
    ) {
        lock.lock()
        configuration = Configuration(statusCode: statusCode, data: data, delay: delay)
        if resetCounts {
            starts = 0
            stops = 0
        }
        lock.unlock()
    }

    static func reset() {
        configure(statusCode: 200, data: Data(), delay: 0)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let configuration = Self.configuration
        Self.starts += 1
        Self.lock.unlock()

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.workItem?.isCancelled == false else { return }
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: configuration.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            self.stateLock.lock()
            self.didFinish = true
            self.stateLock.unlock()
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: configuration.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        workItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + configuration.delay, execute: item)
    }

    override func stopLoading() {
        stateLock.lock()
        let interrupted = didFinish == false
        stateLock.unlock()
        workItem?.cancel()
        if interrupted {
            Self.lock.lock()
            Self.stops += 1
            Self.lock.unlock()
        }
    }
}
