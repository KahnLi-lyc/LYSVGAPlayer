import Foundation
import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGARemoteDynamicImageTests: XCTestCase {
    func testSuccessfulHTTPResponseDecodesAndInstallsImage() async throws {
        let reader = DynamicImageReaderStub()
        let view = makeView(reader: reader)
        try await view.setVideo(try movie())
        let url = URL(string: "https://example.com/success.png")!
        let task = Task { try await view.setImage(from: url, forKey: "avatar.png") }
        await waitForStarts(1, reader: reader)

        await reader.succeed(url, data: try png(.blue), response: http(url, status: 200))
        try await task.value

        XCTAssertPixel(try installedImage(in: view), rgba: (0, 0, 255, 255))
    }

    func testNonHTTPResponseFailsWithKeyedInvalidResponse() async throws {
        let reader = DynamicImageReaderStub()
        let view = makeView(reader: reader)
        let url = URL(fileURLWithPath: "/tmp/image.png")
        let task = Task { try await view.setImage(from: url, forKey: "avatar.jpeg") }
        await waitForStarts(1, reader: reader)
        await reader.succeed(
            url,
            data: try png(.blue),
            response: URLResponse(url: url, mimeType: "image/png", expectedContentLength: 1, textEncodingName: nil)
        )

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .dynamicImageInvalidResponse(key: "avatar"))
        }
    }

    func testNonSuccessHTTPStatusAndInvalidImageReportKeyedErrors() async throws {
        let reader = DynamicImageReaderStub()
        let view = makeView(reader: reader)
        let statusURL = URL(string: "https://example.com/status")!
        let statusTask = Task { try await view.setImage(from: statusURL, forKey: "avatar") }
        await waitForStarts(1, reader: reader)
        await reader.succeed(statusURL, data: Data(), response: http(statusURL, status: 503))

        await XCTAssertThrowsErrorAsync(try await statusTask.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .dynamicImageHTTPStatus(key: "avatar", status: 503))
        }

        let decodeURL = URL(string: "https://example.com/bad-image")!
        let decodeTask = Task { try await view.setImage(from: decodeURL, forKey: "avatar") }
        await waitForStarts(2, reader: reader)
        await reader.succeed(decodeURL, data: Data("not an image".utf8), response: http(decodeURL, status: 204))

        await XCTAssertThrowsErrorAsync(try await decodeTask.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .dynamicImageDecodingFailure(key: "avatar"))
        }
    }

    func testNetworkFailureIsKeyedAndCallerCancellationBecomesCancelled() async throws {
        let reader = DynamicImageReaderStub()
        let view = makeView(reader: reader)
        let failureURL = URL(string: "https://example.com/offline")!
        let failureTask = Task { try await view.setImage(from: failureURL, forKey: "avatar.webp") }
        await waitForStarts(1, reader: reader)
        await reader.fail(failureURL, with: DynamicReaderError.offline)

        await XCTAssertThrowsErrorAsync(try await failureTask.value) { error in
            guard case let .dynamicImageNetworkFailure(key, reason) = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(key, "avatar")
            XCTAssertFalse(reason.isEmpty)
        }

        let cancellationURL = URL(string: "https://example.com/cancel")!
        let cancellationTask = Task { try await view.setImage(from: cancellationURL, forKey: "avatar") }
        await waitForStarts(2, reader: reader)
        cancellationTask.cancel()

        await XCTAssertThrowsErrorAsync(try await cancellationTask.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        await waitForCancellations(1, reader: reader)
    }

    func testNewRequestCancelsSameStandardKeyAndLateOldResponseCannotOverwrite() async throws {
        let reader = DynamicImageReaderStub(ignoresCancellation: true)
        let view = makeView(reader: reader)
        try await view.setVideo(try movie())
        let oldURL = URL(string: "https://example.com/old")!
        let newURL = URL(string: "https://example.com/new")!
        let oldTask = Task { try await view.setImage(from: oldURL, forKey: "avatar.png") }
        await waitForStarts(1, reader: reader)
        let newTask = Task { try await view.setImage(from: newURL, forKey: "avatar.vector.jpeg") }
        await waitForStarts(2, reader: reader)
        await waitForCancellations(1, reader: reader)

        await reader.succeed(newURL, data: try png(.blue), response: http(newURL, status: 200))
        try await newTask.value
        await reader.succeed(oldURL, data: try png(.green), response: http(oldURL, status: 200))

        await XCTAssertThrowsErrorAsync(try await oldTask.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        XCTAssertPixel(try installedImage(in: view), rgba: (0, 0, 255, 255))
    }

    func testLocalImageAndDynamicClearCancelOldRequestsAndPreventLateWrites() async throws {
        let reader = DynamicImageReaderStub(ignoresCancellation: true)
        let view = makeView(reader: reader)
        try await view.setVideo(try movie())
        let localURL = URL(string: "https://example.com/local-overrides")!
        let localTask = Task { try await view.setImage(from: localURL, forKey: "avatar.png") }
        await waitForStarts(1, reader: reader)

        view.setImage(try image(.blue), forKey: "avatar")
        await waitForCancellations(1, reader: reader)
        await reader.succeed(localURL, data: try png(.green), response: http(localURL, status: 200))
        await XCTAssertThrowsErrorAsync(try await localTask.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        XCTAssertPixel(try installedImage(in: view), rgba: (0, 0, 255, 255))

        let clearURL = URL(string: "https://example.com/clear")!
        let clearTask = Task { try await view.setImage(from: clearURL, forKey: "avatar") }
        await waitForStarts(2, reader: reader)
        view.clearDynamicContents()
        await waitForCancellations(2, reader: reader)
        await reader.succeed(clearURL, data: try png(.green), response: http(clearURL, status: 200))
        await XCTAssertThrowsErrorAsync(try await clearTask.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        XCTAssertPixel(try installedImage(in: view), rgba: (255, 0, 0, 255))
    }

    func testInvalidLocalImageIsNoOpAndDoesNotCancelValidRemoteRequest() async throws {
        let reader = DynamicImageReaderStub()
        let view = makeView(reader: reader)
        try await view.setVideo(try movie())
        let url = URL(string: "https://example.com/valid-after-invalid-local")!
        let task = Task { try await view.setImage(from: url, forKey: "avatar") }
        await waitForStarts(1, reader: reader)

        view.setImage(UIImage(), forKey: "avatar.png")

        let cancellationCount = await reader.counts().cancellations
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertPixel(try installedImage(in: view), rgba: (255, 0, 0, 255))
        await reader.succeed(url, data: try png(.blue), response: http(url, status: 200))
        try await task.value
        XCTAssertPixel(try installedImage(in: view), rgba: (0, 0, 255, 255))
    }

    func testPlayerClearCancelsRemoteRequestAndLeavesNoInstallationForLateResponse() async throws {
        let reader = DynamicImageReaderStub(ignoresCancellation: true)
        let view = makeView(reader: reader)
        try await view.setVideo(try movie())
        let url = URL(string: "https://example.com/player-clear")!
        let task = Task { try await view.setImage(from: url, forKey: "avatar") }
        await waitForStarts(1, reader: reader)

        view.clear()
        await waitForCancellations(1, reader: reader)
        await reader.succeed(url, data: try png(.blue), response: http(url, status: 200))

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        XCTAssertNil(view.video)
        XCTAssertNil(view.rendererForTesting)
    }

    func testReleasingViewCancelsPendingRequestWithoutCallerCancellation() async throws {
        let reader = DynamicImageReaderStub()
        var view: LYSVGAPlayerView? = makeView(reader: reader)
        weak let weakView = view
        let url = URL(string: "https://example.com/release")!
        let task = try XCTUnwrap(view).beginRemoteDynamicImageOperation(from: url, forKey: "avatar")
        await waitForStarts(1, reader: reader)

        view = nil
        for _ in 0..<100 where weakView != nil { await Task.yield() }
        if weakView != nil {
            task.cancel()
        }

        XCTAssertNil(weakView)
        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        await waitForCancellations(1, reader: reader)
    }

    func testLatestDynamicStateDuringPreparationIsAppliedBeforeFirstFrameDelegate() async throws {
        let preparationStarted = expectation(description: "preparation started")
        var resumePreparation: CheckedContinuation<Void, Never>?
        let delegate = DynamicFrameDelegateSpy()
        let view = LYSVGAPlayerView(preparationHook: { _ in
            preparationStarted.fulfill()
            await withCheckedContinuation { resumePreparation = $0 }
        })
        view.delegate = delegate
        let loadTask = Task { try await view.setVideo(try movie()) }
        await fulfillment(of: [preparationStarted])

        view.setImage(try image(.blue), forKey: "avatar")
        view.setImage(try image(.green), forKey: "avatar.png")
        delegate.onFirstFrame = { playerView in
            self.XCTAssertPixel(try! self.installedImage(in: playerView), rgba: (0, 255, 0, 255))
        }
        resumePreparation?.resume()

        try await loadTask.value
        XCTAssertEqual(delegate.frames, [0])
    }
}

private enum DynamicReaderError: Error {
    case offline
}

private actor DynamicImageReaderStub {
    typealias Output = (Data, URLResponse)
    private var continuations: [URL: CheckedContinuation<Output, Error>] = [:]
    private(set) var startCount = 0
    private(set) var cancellationCount = 0
    private let ignoresCancellation: Bool

    init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    func read(_ url: URL) async throws -> Output {
        startCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[url] = continuation
            }
        } onCancel: {
            Task { await self.cancel(url) }
        }
    }

    func succeed(_ url: URL, data: Data, response: URLResponse) {
        continuations.removeValue(forKey: url)?.resume(returning: (data, response))
    }

    func fail(_ url: URL, with error: Error) {
        continuations.removeValue(forKey: url)?.resume(throwing: error)
    }

    func counts() -> (starts: Int, cancellations: Int) {
        (startCount, cancellationCount)
    }

    private func cancel(_ url: URL) {
        cancellationCount += 1
        guard ignoresCancellation == false else { return }
        continuations.removeValue(forKey: url)?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class DynamicFrameDelegateSpy: LYSVGAPlayerViewDelegate {
    var frames: [Int] = []
    var onFirstFrame: ((LYSVGAPlayerView) -> Void)?

    func playerView(_ playerView: LYSVGAPlayerView, didDisplayFrame frame: Int, progress: Double) {
        frames.append(frame)
        if frames.count == 1 { onFirstFrame?(playerView) }
    }
}

@MainActor
private extension LYSVGARemoteDynamicImageTests {
    func makeView(reader: DynamicImageReaderStub) -> LYSVGAPlayerView {
        LYSVGAPlayerView(dynamicImageReader: { url in try await reader.read(url) })
    }

    func waitForStarts(_ expected: Int, reader: DynamicImageReaderStub) async {
        while await reader.counts().starts < expected { await Task.yield() }
    }

    func waitForCancellations(_ expected: Int, reader: DynamicImageReaderStub) async {
        while await reader.counts().cancellations < expected { await Task.yield() }
    }

    func movie() throws -> LYSVGAVideo {
        try LYSVGAVideo(
            version: "remote-dynamic",
            canvasSize: LYSVGASize(width: 20, height: 20),
            fps: 20,
            frameCount: 2,
            images: ["avatar.png": try png(.red)],
            audioData: [:],
            sprites: [LYSVGASprite(imageKey: "avatar.png", frames: [frame(), frame()])],
            audios: []
        )
    }

    func frame() -> LYSVGAFrame {
        LYSVGAFrame(alpha: 1, layout: LYSVGARect(x: 0, y: 0, width: 20, height: 20), transform: .identity)
    }

    func image(_ color: UIColor) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    func png(_ color: UIColor) throws -> Data {
        try XCTUnwrap(try image(color).pngData())
    }

    func http(_ url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func installedImage(in view: LYSVGAPlayerView) throws -> CGImage {
        try XCTUnwrap(view.rendererForTesting?.spriteLayers.first?.bitmapImageForTesting)
    }

    func XCTAssertPixel(
        _ image: CGImage,
        rgba expected: (Int, Int, Int, Int),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(Int(pixel[0]), expected.0, accuracy: 2, file: file, line: line)
        XCTAssertEqual(Int(pixel[1]), expected.1, accuracy: 2, file: file, line: line)
        XCTAssertEqual(Int(pixel[2]), expected.2, accuracy: 2, file: file, line: line)
        XCTAssertEqual(Int(pixel[3]), expected.3, accuracy: 2, file: file, line: line)
    }

    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ handler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            handler(error)
        }
    }
}
