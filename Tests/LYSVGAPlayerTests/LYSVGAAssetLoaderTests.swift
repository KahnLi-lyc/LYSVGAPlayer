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

    func testCustomRequestPreservesMethodHeadersBodyTimeoutAndNetworkPolicy() async throws {
        URLProtocolStub.configure(
            statusCode: 200,
            data: try TestSupport.fixture("matteRect"),
            delay: 0
        )
        let (loader, session) = makeLoader()
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: testURL)
        request.httpMethod = "POST"
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("payload".utf8)
        request.timeoutInterval = 12
        request.allowsCellularAccess = false

        _ = try await loader.load(.request(request), cachePolicy: .noCache)

        let received = try XCTUnwrap(URLProtocolStub.receivedRequests.first)
        XCTAssertEqual(received.httpMethod, "POST")
        XCTAssertEqual(received.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(URLProtocolStub.receivedBodies.first, Data("payload".utf8))
        XCTAssertEqual(received.timeoutInterval, 12)
        XCTAssertFalse(received.allowsCellularAccess)
    }

    func testCustomRequestsCoalesceOnlyWhenTheirCacheIdentityMatches() async throws {
        URLProtocolStub.configure(
            statusCode: 200,
            data: try TestSupport.fixture("matteRect"),
            delay: 0.1
        )
        let (loader, session) = makeLoader()
        defer { session.invalidateAndCancel() }
        let url = testURL

        async let first = loader.load(
            .request(Self.makeVariantRequest(url: url, variant: "one")),
            cachePolicy: .noCache
        )
        async let duplicate = loader.load(
            .request(Self.makeVariantRequest(url: url, variant: "one")),
            cachePolicy: .noCache
        )
        _ = try await (first, duplicate)
        XCTAssertEqual(URLProtocolStub.startCount, 1)

        async let original = loader.load(
            .request(Self.makeVariantRequest(url: url, variant: "one")),
            cachePolicy: .noCache
        )
        async let different = loader.load(
            .request(Self.makeVariantRequest(url: url, variant: "two")),
            cachePolicy: .noCache
        )
        _ = try await (original, different)
        XCTAssertEqual(URLProtocolStub.startCount, 3)
    }

    func testCustomRequestRejectsBodyStreamBeforeStartingNetworkLoad() async throws {
        URLProtocolStub.configure(
            statusCode: 200,
            data: try TestSupport.fixture("matteRect"),
            delay: 0
        )
        let (loader, session) = makeLoader()
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: testURL)
        request.httpBodyStream = InputStream(data: Data("stream".utf8))

        do {
            _ = try await loader.load(.request(request), cachePolicy: .noCache)
            XCTFail("Expected a streamed request body to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? LYSVGAError,
                .invalidRequest("URLRequest.httpBodyStream is unsupported because it cannot be replayed safely.")
            )
        }
        XCTAssertEqual(URLProtocolStub.startCount, 0)
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

    func testDiskCacheDecodeCancellationPreservesCacheAndDoesNotFallBackToReader() async throws {
        for cancellation in CacheDecodeCancellation.allCases {
            let directory = TestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let configuration = cacheConfiguration(directory: directory)
            let source = LYSVGASource.data(Data([0x01]), cacheKey: "cached-\(cancellation)")
            let cachedData = Data([0x01])
            let fallbackData = Data([0x02])
            let expectedVideo = try TestSupport.video(version: "cached")
            let seeder = LYSVGAAssetLoader(
                session: .shared,
                cacheConfiguration: configuration,
                reader: { _, _ in cachedData },
                decoder: { _ in expectedVideo }
            )
            _ = try await seeder.load(source, cachePolicy: .automatic)

            let probe = CacheFallbackProbe(fallbackData: fallbackData)
            let cancellingLoader = LYSVGAAssetLoader(
                session: .shared,
                cacheConfiguration: configuration,
                reader: { _, _ in probe.read() },
                decoder: { data in
                    if data == cachedData {
                        throw cancellation.error
                    }
                    return expectedVideo
                }
            )
            do {
                _ = try await cancellingLoader.load(source, cachePolicy: .automatic)
                XCTFail("Expected \(cancellation) to cancel cached decoding.")
            } catch {
                XCTAssertEqual(error as? LYSVGAError, .cancelled)
            }
            XCTAssertEqual(probe.readCount, 0)

            let verificationProbe = CacheFallbackProbe(fallbackData: fallbackData)
            let verificationLoader = LYSVGAAssetLoader(
                session: .shared,
                cacheConfiguration: configuration,
                reader: { _, _ in verificationProbe.read() },
                decoder: { _ in expectedVideo }
            )
            let verifiedVideo = try await verificationLoader.load(source, cachePolicy: .automatic)
            XCTAssertEqual(verifiedVideo, expectedVideo)
            XCTAssertEqual(verificationProbe.readCount, 0)
        }
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

    private static func makeVariantRequest(url: URL, variant: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(variant, forHTTPHeaderField: "X-Variant")
        return request
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

private enum CacheDecodeCancellation: String, CaseIterable, Sendable {
    case task
    case url
    case library

    var error: any Error {
        switch self {
        case .task: CancellationError()
        case .url: URLError(.cancelled)
        case .library: LYSVGAError.cancelled
        }
    }
}

private final class CacheFallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let fallbackData: Data
    private var reads = 0

    init(fallbackData: Data) {
        self.fallbackData = fallbackData
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func read() -> Data {
        lock.withLock {
            reads += 1
            return fallbackData
        }
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
    nonisolated(unsafe) private static var received: [URLRequest] = []
    nonisolated(unsafe) private static var bodies: [Data?] = []

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

    static var receivedRequests: [URLRequest] {
        lock.withLock { received }
    }

    static var receivedBodies: [Data?] {
        lock.withLock { bodies }
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
            received = []
            bodies = []
        }
        lock.unlock()
    }

    static func reset() {
        configure(statusCode: 200, data: Data(), delay: 0)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        Self.lock.lock()
        let configuration = Self.configuration
        Self.starts += 1
        Self.received.append(request)
        Self.bodies.append(body)
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

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
