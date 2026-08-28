import QuartzCore
import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGADynamicContentTests: XCTestCase {
    func testImageSetBeforeAndAfterInstallationPersistsAndClearRestoresOriginalPixels() async throws {
        let original = try solidImage(.red)
        let replacement = try solidImage(.blue)
        let view = LYSVGAPlayerView()
        let movie = try video(images: ["avatar.png": try XCTUnwrap(original.pngData())])

        view.setImage(replacement, forKey: "avatar")
        try await view.setVideo(movie)

        let sprite = try XCTUnwrap(view.rendererForTesting?.spriteLayers.first)
        XCTAssertPixel(try contentsImage(of: sprite), rgba: (0, 0, 255, 255))

        view.setImage(try solidImage(.green), forKey: "avatar.jpeg")
        XCTAssertPixel(try contentsImage(of: sprite), rgba: (0, 255, 0, 255))

        try await view.setVideo(movie)
        let reinstalledSprite = try XCTUnwrap(view.rendererForTesting?.spriteLayers.first)
        XCTAssertPixel(try contentsImage(of: reinstalledSprite), rgba: (0, 255, 0, 255))

        view.clearDynamicContents()
        XCTAssertPixel(try contentsImage(of: reinstalledSprite), rgba: (255, 0, 0, 255))
    }

    func testLoadAppliesDynamicStateBeforeItsFirstDisplayedFrame() async throws {
        let movie = try video(images: ["avatar.png": try XCTUnwrap(try solidImage(.red).pngData())])
        let loader = LYSVGAAssetLoader(
            session: .shared,
            cacheConfiguration: .init(directory: TestSupport.temporaryDirectory()),
            reader: { _, _ in Data([1]) },
            decoder: { _ in movie }
        )
        let view = LYSVGAPlayerView()
        view.setImage(try solidImage(.blue), forKey: "avatar")

        try await view.load(.data(Data([1])), using: loader, cachePolicy: .noCache)

        let sprite = try XCTUnwrap(view.rendererForTesting?.spriteLayers.first)
        XCTAssertPixel(try contentsImage(of: sprite), rgba: (0, 0, 255, 255))
    }

    func testStandardKeyMatchesKnownSuffixesButDoesNotStripCustomExtensions() async throws {
        let red = try XCTUnwrap(try solidImage(.red).pngData())
        let view = LYSVGAPlayerView()
        try await view.setVideo(try video(
            images: ["photo.png": red, "photo.custom.png": red],
            sprites: [sprite("photo.MATTE.PNG"), sprite("photo.custom")]
        ))

        view.setImage(try solidImage(.blue), forKey: "photo.vector.jpeg")

        let layers = try XCTUnwrap(view.rendererForTesting?.spriteLayers)
        XCTAssertPixel(try contentsImage(of: layers[0]), rgba: (0, 0, 255, 255))
        XCTAssertPixel(try contentsImage(of: layers[1]), rgba: (255, 0, 0, 255))

        view.setImage(try solidImage(.green), forKey: "photo.custom")
        XCTAssertPixel(try contentsImage(of: layers[1]), rgba: (0, 255, 0, 255))
    }

    func testAttributedTextLayerIsStableCenteredAndFollowsFrameLayout() async throws {
        let view = LYSVGAPlayerView()
        let frames = [
            frame(x: 2, y: 3, width: 40, height: 20),
            frame(x: 11, y: 13, width: 80, height: 40),
        ]
        let movie = try video(images: [:], sprites: [LYSVGASprite(imageKey: "label.vector", frames: frames)])
        let text = NSAttributedString(
            string: "Hi",
            attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.white]
        )

        view.setAttributedText(text, forKey: "label")
        try await view.setVideo(movie)

        let sprite = try XCTUnwrap(view.rendererForTesting?.spriteLayers.first)
        let textLayer = try XCTUnwrap(sprite.dynamicTextLayerForTesting)
        XCTAssertEqual(textLayer.string as? NSAttributedString, text)
        XCTAssertEqual(textLayer.contentsScale, view.layer.contentsScale)
        XCTAssertEqual(textLayer.frame.midX, sprite.contentLayer.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(textLayer.frame.midY, sprite.contentLayer.bounds.midY, accuracy: 0.001)

        view.seek(toFrame: 1)

        XCTAssertTrue(sprite.dynamicTextLayerForTesting === textLayer)
        XCTAssertEqual(sprite.contentLayer.position, CGPoint(x: 11, y: 13))
        XCTAssertEqual(sprite.contentLayer.bounds.size, CGSize(width: 80, height: 40))
        XCTAssertEqual(textLayer.frame.midX, sprite.contentLayer.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(textLayer.frame.midY, sprite.contentLayer.bounds.midY, accuracy: 0.001)
    }

    func testDrawingRunsAfterFrameImageAndTextUpdatesAndHiddenHasHighestPriority() async throws {
        let original = try XCTUnwrap(try solidImage(.red).pngData())
        let replacement = try solidImage(.blue)
        let view = LYSVGAPlayerView()
        try await view.setVideo(try video(images: ["item.png": original], sprites: [sprite("item.png")]))
        view.setImage(replacement, forKey: "item")
        view.setAttributedText(NSAttributedString(string: "draw"), forKey: "item")

        var observedFrames: [Int] = []
        view.setDrawingHandler({ layer, index in
            observedFrames.append(index)
            XCTAssertEqual(layer.bounds.size, CGSize(width: 20, height: 20))
            XCTAssertNotNil(layer.sublayers?.compactMap { $0 as? CATextLayer }.first)
            XCTAssertNotNil(layer.contents)
        }, forKey: "item")

        let sprite = try XCTUnwrap(view.rendererForTesting?.spriteLayers.first)
        XCTAssertEqual(observedFrames, [0])
        XCTAssertFalse(sprite.isHidden)

        view.setHidden(true, forKey: "item")
        XCTAssertTrue(sprite.isHidden)
        XCTAssertEqual(observedFrames, [0])

        view.setHidden(false, forKey: "item")
        XCTAssertFalse(sprite.isHidden)
        XCTAssertEqual(observedFrames, [0, 0])

        view.setDrawingHandler(nil, forKey: "item")
        view.seek(toFrame: 1)
        XCTAssertEqual(observedFrames, [0, 0])

        view.setDrawingHandler({ _, _ in observedFrames.append(99) }, forKey: "item")
        XCTAssertEqual(observedFrames, [0, 0, 99])
        view.setHidden(true, forKey: "item")
        view.clearDynamicContents()
        XCTAssertFalse(sprite.isHidden)
        XCTAssertNil(sprite.dynamicTextLayerForTesting)
        view.seek(toFrame: 0)
        XCTAssertEqual(observedFrames, [0, 0, 99])
    }

    func testDrawingHandlerDynamicUpdateDoesNotRecursivelyDisplayCurrentFrame() async throws {
        let original = try XCTUnwrap(try solidImage(.red).pngData())
        let view = LYSVGAPlayerView()
        try await view.setVideo(try video(images: ["item.png": original], sprites: [sprite("item.png")]))
        weak let weakView = view
        var callCount = 0

        view.setDrawingHandler({ _, _ in
            callCount += 1
            weakView?.setImage(try! self.solidImage(.green), forKey: "item")
        }, forKey: "item")

        XCTAssertEqual(callCount, 1)
        let sprite = try XCTUnwrap(view.rendererForTesting?.spriteLayers.first)
        XCTAssertPixel(try contentsImage(of: sprite), rgba: (0, 255, 0, 255))
        view.setDrawingHandler(nil, forKey: "item")
    }

    func testMatteOriginalAndZOrderCopyReceiveImageAndHiddenChangesTogether() async throws {
        let white = try XCTUnwrap(try solidImage(.white).pngData())
        let red = try XCTUnwrap(try solidImage(.red).pngData())
        let sprites = [
            sprite("mask.matte"),
            sprite("first", matteKey: "mask"),
            sprite("separator"),
            sprite("second", matteKey: "mask.matte"),
        ]
        let view = LYSVGAPlayerView()
        try await view.setVideo(try video(
            images: ["mask.png": white, "first.png": red, "separator.png": red, "second.png": red],
            sprites: sprites
        ))
        let replacement = try solidImage(.black)

        view.setImage(replacement, forKey: "mask")

        let renderer = try XCTUnwrap(view.rendererForTesting)
        XCTAssertEqual(renderer.matteHosts.count, 2)
        for host in renderer.matteHosts {
            XCTAssertPixel(try contentsImage(of: host.matteLayer), rgba: (0, 0, 0, 255))
        }

        view.setHidden(true, forKey: "mask.matte")
        XCTAssertTrue(renderer.matteHosts.allSatisfy(\.layer.isHidden))

        view.setHidden(false, forKey: "mask")
        XCTAssertTrue(renderer.matteHosts.allSatisfy { $0.layer.isHidden == false })
    }
}

@MainActor
private extension LYSVGADynamicContentTests {
    func video(
        images: [String: Data],
        sprites: [LYSVGASprite]? = nil
    ) throws -> LYSVGAVideo {
        try LYSVGAVideo(
            version: "dynamic",
            canvasSize: LYSVGASize(width: 100, height: 100),
            fps: 20,
            frameCount: 2,
            images: images,
            audioData: [:],
            sprites: sprites ?? [sprite("avatar.png")],
            audios: []
        )
    }

    func sprite(_ key: String, matteKey: String? = nil) -> LYSVGASprite {
        LYSVGASprite(imageKey: key, frames: [frame(), frame()], matteKey: matteKey)
    }

    func frame(
        x: Double = 0,
        y: Double = 0,
        width: Double = 20,
        height: Double = 20
    ) -> LYSVGAFrame {
        LYSVGAFrame(
            alpha: 1,
            layout: LYSVGARect(x: x, y: y, width: width, height: height),
            transform: .identity
        )
    }

    func solidImage(_ color: UIColor) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    func contentsImage(of sprite: LYSVGASpriteLayer) throws -> CGImage {
        try XCTUnwrap(sprite.bitmapImageForTesting)
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
}
