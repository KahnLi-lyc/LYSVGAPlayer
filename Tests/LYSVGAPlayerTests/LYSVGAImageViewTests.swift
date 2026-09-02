import Foundation
import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGAImageViewTests: XCTestCase {
    func testPlayerViewLoadsNamedBundleResourceAndAutoplays() async throws {
        let view = LYSVGAPlayerView()

        try await view.load(
            named: "matteRect",
            subdirectory: "Fixtures",
            in: .module,
            cachePolicy: .noCache,
            autoplay: true
        )

        XCTAssertEqual(view.video?.version, "2.1.0")
        XCTAssertEqual(view.playbackState, .playing)
    }

    func testPlayerViewNamedLoadReportsMissingBundleResource() async {
        let view = LYSVGAPlayerView()

        do {
            try await view.load(named: "missing-image-view-fixture", in: .module)
            XCTFail("Expected a missing resource error.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .missingResource("missing-image-view-fixture.svga"))
        }
        XCTAssertEqual(view.playbackState, .failed)
    }

    func testImageViewLoadsBundleNameAndHonorsAutoPlay() async throws {
        let probe = ImageViewLoadProbe(delays: [:])
        let loader = makeLoader(probe: probe)
        let automaticView = LYSVGAImageView()
        let automaticDelegate = ImageViewDelegateSpy()
        automaticView.delegate = automaticDelegate
        automaticView.resourceBundle = .module
        automaticView.assetLoader = loader
        automaticView.cachePolicy = .noCache
        automaticView.imageName = "ImageViewFixture"

        let automaticDidPlay = await waitUntil { automaticView.playbackState == .playing }
        XCTAssertTrue(
            automaticDidPlay,
            "state=\(automaticView.playbackState), errors=\(automaticDelegate.errors)"
        )
        XCTAssertEqual(automaticView.video?.version, "ImageViewFixture.svga")

        let loadingOnlyView = LYSVGAImageView()
        let loadingOnlyDelegate = ImageViewDelegateSpy()
        loadingOnlyView.delegate = loadingOnlyDelegate
        loadingOnlyView.resourceBundle = .module
        loadingOnlyView.assetLoader = loader
        loadingOnlyView.cachePolicy = .noCache
        loadingOnlyView.autoPlay = false
        loadingOnlyView.imageName = "ImageViewFixture.svga"

        let loadingOnlyDidLoad = await waitUntil { loadingOnlyView.playbackState == .ready }
        XCTAssertTrue(
            loadingOnlyDidLoad,
            "state=\(loadingOnlyView.playbackState), errors=\(loadingOnlyDelegate.errors)"
        )
        XCTAssertEqual(loadingOnlyView.video?.version, "ImageViewFixture.svga")
    }

    func testImageViewTreatsHTTPNameAsRemoteSource() async throws {
        let probe = ImageViewLoadProbe(delays: [:])
        let view = LYSVGAImageView()
        view.assetLoader = makeLoader(probe: probe)
        view.cachePolicy = .noCache
        view.autoPlay = false

        view.imageName = "https://example.com/remote-headwear.svga"

        let didLoad = await waitUntil { view.playbackState == .ready }
        XCTAssertTrue(didLoad)
        XCTAssertEqual(view.video?.version, "remote-headwear.svga")
        XCTAssertEqual(probe.requestedIdentifiers, ["remote-headwear.svga"])
    }

    func testImageViewEmptyNameCancelsAndClears() async throws {
        let probe = ImageViewLoadProbe(delays: [:])
        let view = LYSVGAImageView()
        view.assetLoader = makeLoader(probe: probe)
        view.cachePolicy = .noCache
        view.autoPlay = false
        view.imageName = "https://example.com/installed.svga"
        let didInstall = await waitUntil { view.playbackState == .ready }
        XCTAssertTrue(didInstall)

        view.imageName = "  \n"

        XCTAssertEqual(view.playbackState, .idle)
        XCTAssertNil(view.video)
        XCTAssertNil(view.currentFrame)
    }

    func testImageViewRapidAssignmentsUseLatestRequest() async throws {
        let probe = ImageViewLoadProbe(delays: [
            "slow.svga": 0.25,
            "latest.svga": 0.01,
        ])
        let view = LYSVGAImageView()
        view.assetLoader = makeLoader(probe: probe)
        view.cachePolicy = .noCache
        view.autoPlay = false

        view.imageName = "https://example.com/slow.svga"
        let slowDidStart = await waitUntil { probe.requestedIdentifiers.contains("slow.svga") }
        XCTAssertTrue(slowDidStart)
        view.imageName = "https://example.com/latest.svga"

        let latestDidLoad = await waitUntil { view.video?.version == "latest.svga" }
        XCTAssertTrue(latestDidLoad)
        XCTAssertEqual(view.playbackState, .ready)
        XCTAssertGreaterThanOrEqual(probe.cancellationCount, 1)
    }

    func testImageViewClearCancelsPendingRequest() async throws {
        let probe = ImageViewLoadProbe(delays: ["pending-clear.svga": 5])
        let view = LYSVGAImageView()
        view.assetLoader = makeLoader(probe: probe)
        view.cachePolicy = .noCache
        view.imageName = "https://example.com/pending-clear.svga"
        let requestDidStart = await waitUntil {
            probe.requestedIdentifiers.contains("pending-clear.svga")
        }
        XCTAssertTrue(requestDidStart)

        view.clear()

        let requestDidCancel = await waitUntil { probe.cancellationCount == 1 }
        XCTAssertTrue(requestDidCancel)
        XCTAssertEqual(view.playbackState, .idle)
        XCTAssertNil(view.video)
    }

    func testImageViewReleaseCancelsPendingRequest() async throws {
        let probe = ImageViewLoadProbe(delays: ["pending.svga": 5])
        weak var weakView: LYSVGAImageView?
        var view: LYSVGAImageView? = LYSVGAImageView()
        view?.assetLoader = makeLoader(probe: probe)
        view?.cachePolicy = .noCache
        view?.imageName = "https://example.com/pending.svga"
        weakView = view
        let requestDidStart = await waitUntil { probe.requestedIdentifiers.contains("pending.svga") }
        XCTAssertTrue(requestDidStart)

        view = nil

        let viewDidRelease = await waitUntil { weakView == nil }
        XCTAssertTrue(viewDidRelease)
        let requestDidCancel = await waitUntil { probe.cancellationCount == 1 }
        XCTAssertTrue(requestDidCancel)
    }

    private func makeLoader(probe: ImageViewLoadProbe) -> LYSVGAAssetLoader {
        LYSVGAAssetLoader(
            session: .shared,
            cacheConfiguration: LYSVGACacheConfiguration(
                directory: TestSupport.temporaryDirectory(),
                memoryCountLimit: 0,
                memoryCostLimit: 0,
                diskSizeLimit: 0,
                timeToLive: 0
            ),
            reader: { source, _ in
                try await probe.read(source)
            },
            decoder: { data in
                try TestSupport.video(version: String(decoding: data, as: UTF8.self))
            }
        )
    }

    private func waitUntil(
        attempts: Int = 300,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

@MainActor
private final class ImageViewDelegateSpy: LYSVGAPlayerViewDelegate {
    private(set) var errors: [LYSVGAError] = []

    func playerView(_ playerView: LYSVGAPlayerView, didFailWith error: LYSVGAError) {
        errors.append(error)
    }
}

private final class ImageViewLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delays: [String: TimeInterval]
    private var identifiers: [String] = []
    private var cancellations = 0

    init(delays: [String: TimeInterval]) {
        self.delays = delays
    }

    var requestedIdentifiers: [String] {
        lock.withLock { identifiers }
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    func read(_ source: LYSVGASource) async throws -> Data {
        let identifier = Self.identifier(for: source)
        lock.withLock { identifiers.append(identifier) }
        if let delay = delays[identifier], delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                lock.withLock { cancellations += 1 }
                throw error
            }
        }
        return Data(identifier.utf8)
    }

    private static func identifier(for source: LYSVGASource) -> String {
        switch source {
        case .data:
            "data"
        case let .file(url), let .remote(url):
            url.lastPathComponent
        case let .request(request):
            request.url?.lastPathComponent ?? "request"
        }
    }
}
