import CoreGraphics
import Foundation
import QuartzCore
import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGALocalAssetAcceptanceTests: XCTestCase {
    private let renderSize = CGSize(width: 256, height: 256)

    func testConfiguredLocalAssetsDecodePrepareAndRender() async throws {
        let rootPath = configuredAssetRootPath()
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            throw XCTSkip("No private business-asset directory at \(rootPath).")
        }
        let assetURLs = try localAssetURLs(in: rootURL)
        XCTAssertFalse(assetURLs.isEmpty, "No .svga files found under \(rootPath)")

        for url in assetURLs {
            try await verifyAsset(at: url)
        }
    }
}

@MainActor
private extension LYSVGALocalAssetAcceptanceTests {
    func configuredAssetRootPath() -> String {
        if let configured = ProcessInfo.processInfo.environment["LYSVGA_LOCAL_ASSETS"],
           configured.isEmpty == false {
            return configured
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestAssets/Local", isDirectory: true)
            .path
    }

    func verifyAsset(at url: URL) async throws {
        let data = try await Task.detached {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value

        let decodeStart = ContinuousClock.now
        let video = try LYSVGAFormatDecoder.decode(data)
        let decodeDuration = decodeStart.duration(to: .now)

        XCTAssertGreaterThan(video.canvasSize.width, 0, url.lastPathComponent)
        XCTAssertGreaterThan(video.canvasSize.height, 0, url.lastPathComponent)
        XCTAssertGreaterThan(video.fps, 0, url.lastPathComponent)
        XCTAssertGreaterThan(video.frameCount, 0, url.lastPathComponent)
        XCTAssertFalse(video.sprites.isEmpty, url.lastPathComponent)

        let renderer = LYSVGARenderer()
        let prepareStart = ContinuousClock.now
        try await renderer.prepare(video: video)
        let prepareDuration = prepareStart.duration(to: .now)
        renderer.layout(
            in: CGRect(origin: .zero, size: renderSize),
            contentMode: .scaleAspectFit,
            clipsToBounds: true
        )

        let sampledFrames = frameSamples(frameCount: video.frameCount)
        var visibleFrames = 0
        for frame in sampledFrames {
            renderer.display(frame: frame)
            if try nonTransparentPixelCount(in: renderer.rootLayer) > 0 {
                visibleFrames += 1
            }
        }
        XCTAssertGreaterThan(
            visibleFrames,
            0,
            "\(url.lastPathComponent) rendered transparent at sampled frames \(sampledFrames)"
        )

        let report = LocalAssetReport(
            file: url.lastPathComponent,
            bytes: data.count,
            version: video.version,
            canvas: "\(video.canvasSize.width)x\(video.canvasSize.height)",
            fps: video.fps,
            frames: video.frameCount,
            images: video.images.count,
            sprites: video.sprites.count,
            audioCues: video.audios.count,
            audioResources: video.audioData.count,
            sampledFrames: sampledFrames,
            visibleFrames: visibleFrames,
            decodeMilliseconds: decodeDuration.milliseconds,
            prepareMilliseconds: prepareDuration.milliseconds
        )
        let encodedReport = try JSONEncoder().encode(report)
        print("LYSVGA_LOCAL_ASSET_RESULT \(String(decoding: encodedReport, as: UTF8.self))")
    }

    func localAssetURLs(in rootURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "svga" }
            .sorted { $0.path < $1.path }
    }

    func frameSamples(frameCount: Int) -> [Int] {
        let sampleCount = min(frameCount, 7)
        guard sampleCount > 1 else { return [0] }
        return (0..<sampleCount).map { index in
            index * (frameCount - 1) / (sampleCount - 1)
        }
    }

    func nonTransparentPixelCount(in layer: CALayer) throws -> Int {
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                      | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CocoaError(.coderInvalidValue)
        }
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return stride(from: 3, to: pixels.count, by: 4).reduce(into: 0) { count, offset in
            if pixels[offset] > 0 { count += 1 }
        }
    }
}

private struct LocalAssetReport: Encodable {
    let file: String
    let bytes: Int
    let version: String
    let canvas: String
    let fps: Int
    let frames: Int
    let images: Int
    let sprites: Int
    let audioCues: Int
    let audioResources: Int
    let sampledFrames: [Int]
    let visibleFrames: Int
    let decodeMilliseconds: Double
    let prepareMilliseconds: Double
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
