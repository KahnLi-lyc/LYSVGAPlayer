import QuartzCore
import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGARendererTests: XCTestCase {
    func testBitmapFrameAppliesAlphaLayoutTransformAndReusesPreparedPixels() async throws {
        let imageData = try pngData(size: CGSize(width: 10, height: 10), color: .red)
        let frames = [
            frame(alpha: 0.5, x: 10, y: 20, width: 20, height: 20),
            frame(
                alpha: 1,
                x: 20,
                y: 10,
                width: 20,
                height: 20,
                transform: LYSVGATransform(a: 1, b: 0, c: 0, d: 1, tx: 5, ty: 4)
            ),
        ]
        let video = try makeVideo(
            width: 60,
            height: 60,
            images: ["red.png": imageData],
            sprites: [LYSVGASprite(imageKey: "red", frames: frames)]
        )
        let renderer = LYSVGARenderer()

        try await renderer.prepare(video: video)
        renderer.layout(in: CGRect(x: 0, y: 0, width: 60, height: 60), contentMode: .center, clipsToBounds: false)
        renderer.display(frame: 0)

        let sprite = try XCTUnwrap(renderer.spriteLayers.first)
        let firstContents = sprite.contentLayer.contents
        XCTAssertFalse(sprite.isHidden)
        XCTAssertEqual(sprite.opacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(sprite.contentLayer.bounds, CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(sprite.contentLayer.position, CGPoint(x: 10, y: 20))
        XCTAssertEqual(sprite.contentLayer.contentsGravity, .resizeAspect)
        XCTAssertPixel(render(renderer.rootLayer, size: CGSize(width: 60, height: 60)), x: 15, y: 25, rgba: (128, 0, 0, 128), tolerance: 8)
        XCTAssertPixel(render(renderer.rootLayer, size: CGSize(width: 60, height: 60)), x: 5, y: 5, rgba: (0, 0, 0, 0), tolerance: 2)

        renderer.display(frame: 1)

        XCTAssertTrue(firstContents as AnyObject === sprite.contentLayer.contents as AnyObject)
        XCTAssertEqual(sprite.contentLayer.position, CGPoint(x: 20, y: 10))
        XCTAssertEqual(sprite.contentLayer.affineTransform(), CGAffineTransform(translationX: 5, y: 4))
        XCTAssertEqual(sprite.contentLayer.frame, CGRect(x: 25, y: 14, width: 20, height: 20))
        let transformedImage = render(renderer.rootLayer, size: CGSize(width: 60, height: 60))
        XCTAssertEqual(nonTransparentBounds(transformedImage), CGRect(x: 25, y: 14, width: 20, height: 20))
        XCTAssertPixel(transformedImage, x: 30, y: 20, rgba: (255, 0, 0, 255), tolerance: 3)
    }

    func testVectorDescriptorsMapGeometryStyleAndKeepUsesStableShapePool() async throws {
        let pathShape = LYSVGAShape(
            type: .path(LYSVGAShapePath(path: "M1 2 L11 2 L11 12 Z")),
            style: LYSVGAShapeStyle(
                fill: LYSVGAColor(red: 1, green: 0, blue: 0, alpha: 0.75),
                stroke: LYSVGAColor(red: 0, green: 0, blue: 1, alpha: 1),
                strokeWidth: 2,
                lineCap: .round,
                lineJoin: .bevel,
                miterLimit: 7,
                lineDash: [3, 2, 1]
            ),
            transform: LYSVGATransform(a: 1, b: 0, c: 0, d: 1, tx: 4, ty: 5)
        )
        let rectShape = LYSVGAShape(
            type: .rect(LYSVGAShapeRect(rect: LYSVGARect(x: 20, y: 4, width: 12, height: 10), cornerRadius: 3)),
            style: LYSVGAShapeStyle(fill: LYSVGAColor(red: 0, green: 1, blue: 0, alpha: 1))
        )
        let ellipseShape = LYSVGAShape(
            type: .ellipse(LYSVGAShapeEllipse(centerX: 45, centerY: 10, radiusX: 6, radiusY: 4)),
            style: LYSVGAShapeStyle(fill: LYSVGAColor(red: 1, green: 1, blue: 0, alpha: 1))
        )
        let replacement = LYSVGAShape(
            type: .rect(LYSVGAShapeRect(rect: LYSVGARect(x: 1, y: 1, width: 5, height: 5), cornerRadius: 0)),
            style: LYSVGAShapeStyle(fill: LYSVGAColor(red: 0, green: 0, blue: 0, alpha: 1))
        )
        let frames = [
            frame(shapes: [pathShape, rectShape, ellipseShape]),
            frame(shapes: [LYSVGAShape(type: .keep), replacement]),
            frame(shapes: [LYSVGAShape(type: .keep)]),
            frame(shapes: [replacement]),
        ]
        let video = try makeVideo(
            width: 60,
            height: 30,
            frames: 4,
            sprites: [LYSVGASprite(imageKey: "vector.vector", frames: frames)]
        )
        let renderer = LYSVGARenderer()

        try await renderer.prepare(video: video)
        renderer.layout(in: CGRect(x: 0, y: 0, width: 60, height: 30), contentMode: .center, clipsToBounds: false)
        renderer.display(frame: 0)

        let vectorLayer = try XCTUnwrap(renderer.spriteLayers.first?.vectorLayer)
        XCTAssertEqual(vectorLayer.resolvedFrameIndices, [0, 0, 0, 3])
        XCTAssertEqual(vectorLayer.shapeLayers.count, 3)
        XCTAssertEqual(vectorLayer.sublayers?.count, 3)
        let layerIDs = vectorLayer.shapeLayers.map(ObjectIdentifier.init)
        let pathLayer = vectorLayer.shapeLayers[0]
        XCTAssertEqual(pathLayer.path?.boundingBoxOfPath, CGRect(x: 1, y: 2, width: 10, height: 10))
        XCTAssertColor(pathLayer.fillColor, rgba: (1, 0, 0, 0.75))
        XCTAssertColor(pathLayer.strokeColor, rgba: (0, 0, 1, 1))
        XCTAssertEqual(pathLayer.lineWidth, 2)
        XCTAssertEqual(pathLayer.lineCap, .round)
        XCTAssertEqual(pathLayer.lineJoin, .bevel)
        XCTAssertEqual(pathLayer.miterLimit, 7)
        XCTAssertEqual(pathLayer.lineDashPattern, [NSNumber(value: 3), NSNumber(value: 2)])
        XCTAssertEqual(pathLayer.lineDashPhase, 1)
        XCTAssertEqual(pathLayer.affineTransform(), CGAffineTransform(translationX: 4, y: 5))
        XCTAssertEqual(vectorLayer.shapeLayers[1].path?.boundingBoxOfPath, CGRect(x: 20, y: 4, width: 12, height: 10))
        XCTAssertEqual(vectorLayer.shapeLayers[2].path?.boundingBoxOfPath, CGRect(x: 39, y: 6, width: 12, height: 8))

        renderer.display(frame: 1)
        renderer.display(frame: 2)

        XCTAssertEqual(vectorLayer.shapeLayers.map(ObjectIdentifier.init), layerIDs)
        XCTAssertEqual(vectorLayer.sublayers?.count, 3)
        XCTAssertEqual(vectorLayer.applicationCount, 1)
        XCTAssertEqual(vectorLayer.shapeLayers[0].path?.boundingBoxOfPath, CGRect(x: 1, y: 2, width: 10, height: 10))
        XCTAssertFalse(vectorLayer.shapeLayers[2].isHidden)

        renderer.display(frame: 3)

        XCTAssertEqual(vectorLayer.shapeLayers.map(ObjectIdentifier.init), layerIDs)
        XCTAssertFalse(vectorLayer.shapeLayers[0].isHidden)
        XCTAssertTrue(vectorLayer.shapeLayers[1].isHidden)
        XCTAssertTrue(vectorLayer.shapeLayers[2].isHidden)
        XCTAssertEqual(vectorLayer.shapeLayers[0].path?.boundingBoxOfPath, CGRect(x: 1, y: 1, width: 5, height: 5))
        XCTAssertEqual(vectorLayer.applicationCount, 2)
    }

    func testLeadingKeepWithoutPreviousFrameRendersEmptyWithoutAllocatingLayers() async throws {
        let frame0 = frame(shapes: [LYSVGAShape(type: .keep)])
        let frame1 = frame(shapes: [
            LYSVGAShape(
                type: .rect(LYSVGAShapeRect(rect: LYSVGARect(x: 0, y: 0, width: 5, height: 5), cornerRadius: 0)),
                style: LYSVGAShapeStyle(fill: LYSVGAColor(red: 1, green: 0, blue: 0, alpha: 1))
            ),
        ])
        let video = try makeVideo(
            width: 10,
            height: 10,
            sprites: [LYSVGASprite(imageKey: "vector", frames: [frame0, frame1])]
        )
        let renderer = LYSVGARenderer()

        try await renderer.prepare(video: video)
        renderer.display(frame: 0)

        let vectorLayer = try XCTUnwrap(renderer.spriteLayers.first?.vectorLayer)
        XCTAssertEqual(vectorLayer.resolvedFrameIndices, [nil, 1])
        XCTAssertEqual(vectorLayer.shapeLayers.count, 1)
        XCTAssertTrue(vectorLayer.shapeLayers[0].isHidden)
    }

    func testClipPathUsesOneReusableMaskAndClipsPixels() async throws {
        let imageData = try pngData(size: CGSize(width: 20, height: 20), color: .red)
        let frames = [
            frame(width: 20, height: 20, clipPath: "M0 0 H10 V20 H0 Z"),
            frame(width: 20, height: 20, clipPath: "M10 0 H20 V20 H10 Z"),
        ]
        let video = try makeVideo(
            width: 20,
            height: 20,
            images: ["image.png": imageData],
            sprites: [LYSVGASprite(imageKey: "image", frames: frames)]
        )
        let renderer = LYSVGARenderer()

        try await renderer.prepare(video: video)
        renderer.layout(in: CGRect(x: 0, y: 0, width: 20, height: 20), contentMode: .center, clipsToBounds: false)
        renderer.display(frame: 0)

        let sprite = try XCTUnwrap(renderer.spriteLayers.first)
        let mask = try XCTUnwrap(sprite.clipMaskLayer)
        XCTAssertTrue(sprite.mask === mask)
        var image = render(renderer.rootLayer, size: CGSize(width: 20, height: 20))
        XCTAssertPixel(image, x: 4, y: 10, rgba: (255, 0, 0, 255), tolerance: 3)
        XCTAssertPixel(image, x: 16, y: 10, rgba: (0, 0, 0, 0), tolerance: 3)

        renderer.display(frame: 1)

        XCTAssertTrue(sprite.clipMaskLayer === mask)
        XCTAssertTrue(sprite.mask === mask)
        image = render(renderer.rootLayer, size: CGSize(width: 20, height: 20))
        XCTAssertPixel(image, x: 4, y: 10, rgba: (0, 0, 0, 0), tolerance: 3)
        XCTAssertPixel(image, x: 16, y: 10, rgba: (255, 0, 0, 255), tolerance: 3)
    }

    func testSingleMatteMasksContentAndMatteSpriteIsNotDirectlyDisplayed() async throws {
        let renderer = LYSVGARenderer()
        try await renderer.prepare(video: try matteVideo(contentCount: 1))
        renderer.layout(in: CGRect(x: 0, y: 0, width: 20, height: 20), contentMode: .center, clipsToBounds: false)
        renderer.display(frame: 0)

        XCTAssertEqual(renderer.matteHosts.count, 1)
        let host = try XCTUnwrap(renderer.matteHosts.first)
        XCTAssertEqual(host.contentLayers.count, 1)
        XCTAssertTrue(host.layer.mask === renderer.spriteLayers[0])
        XCTAssertFalse(renderer.canvasLayer.sublayers?.contains(where: { $0 === renderer.spriteLayers[0] }) ?? false)
        let image = render(renderer.rootLayer, size: CGSize(width: 20, height: 20))
        XCTAssertPixel(image, x: 4, y: 10, rgba: (255, 0, 0, 255), tolerance: 4)
        XCTAssertPixel(image, x: 16, y: 10, rgba: (0, 0, 0, 0), tolerance: 4)
    }

    func testMultipleMatteContentsShareOneHostAtFirstContentZOrder() async throws {
        let normal = vectorSprite(
            key: "normal",
            rect: LYSVGARect(x: 0, y: 15, width: 20, height: 5),
            color: LYSVGAColor(red: 0, green: 1, blue: 0, alpha: 1)
        )
        let base = try matteVideo(contentCount: 2)
        let video = try makeVideo(
            width: 20,
            height: 20,
            images: base.images,
            sprites: [base.sprites[0], base.sprites[1], normal, base.sprites[2]]
        )
        let renderer = LYSVGARenderer()

        try await renderer.prepare(video: video)
        renderer.display(frame: 0)

        let host = try XCTUnwrap(renderer.matteHosts.first)
        XCTAssertEqual(renderer.matteHosts.count, 1)
        XCTAssertEqual(host.contentLayers.count, 2)
        XCTAssertTrue(host.contentLayers[0] === renderer.spriteLayers[1])
        XCTAssertTrue(host.contentLayers[1] === renderer.spriteLayers[3])
        XCTAssertTrue(renderer.canvasLayer.sublayers?.first === host.layer)
        XCTAssertTrue(renderer.canvasLayer.sublayers?.last === renderer.spriteLayers[2])
        let image = render(renderer.rootLayer, size: CGSize(width: 20, height: 20))
        XCTAssertPixel(image, x: 4, y: 5, rgba: (255, 0, 0, 255), tolerance: 4)
        XCTAssertPixel(image, x: 16, y: 5, rgba: (0, 0, 0, 0), tolerance: 4)
    }

    func testInvalidVectorStyleAndTransformNeverReachShapeLayer() async throws {
        let shape = LYSVGAShape(
            type: .rect(LYSVGAShapeRect(rect: LYSVGARect(x: 1, y: 1, width: 5, height: 5), cornerRadius: 0)),
            style: LYSVGAShapeStyle(
                fill: LYSVGAColor(red: .nan, green: 0, blue: 0, alpha: 1),
                stroke: LYSVGAColor(red: 0, green: .infinity, blue: 0, alpha: 1),
                strokeWidth: .infinity,
                miterLimit: .nan,
                lineDash: [2, .infinity, 3]
            ),
            transform: LYSVGATransform(a: .nan, b: 0, c: 0, d: 1, tx: .infinity, ty: 0)
        )
        let video = try makeVideo(
            width: 10,
            height: 10,
            sprites: [LYSVGASprite(imageKey: "invalid.vector", frames: [frame(
                width: 10,
                height: 10,
                shapes: [shape]
            )])]
        )
        let renderer = LYSVGARenderer()

        try await renderer.prepare(video: video)
        renderer.display(frame: 0)

        let layer = try XCTUnwrap(renderer.spriteLayers[0].vectorLayer?.shapeLayers.first)
        XCTAssertNil(layer.fillColor)
        XCTAssertNil(layer.strokeColor)
        XCTAssertEqual(layer.lineWidth, 0)
        XCTAssertEqual(layer.miterLimit, 0)
        XCTAssertNil(layer.lineDashPattern)
        XCTAssertEqual(layer.lineDashPhase, 0)
        XCTAssertEqual(layer.affineTransform(), .identity)
    }

    func testMissingMatteKeepsReferencedContentHidden() async throws {
        let imageData = try pngData(size: CGSize(width: 20, height: 20), color: .red)
        let content = LYSVGASprite(
            imageKey: "red",
            frames: [frame(width: 20, height: 20)],
            matteKey: "missing.matte"
        )
        let video = try makeVideo(width: 20, height: 20, images: ["red.png": imageData], sprites: [content])
        let renderer = LYSVGARenderer()

        try await renderer.prepare(video: video)
        renderer.display(frame: 0)

        XCTAssertTrue(renderer.spriteLayers[0].isHidden)
        XCTAssertNil(renderer.spriteLayers[0].superlayer)
        XCTAssertEqual(renderer.matteHosts.count, 0)
        XCTAssertPixel(
            render(renderer.rootLayer, size: CGSize(width: 20, height: 20)),
            x: 10,
            y: 10,
            rgba: (0, 0, 0, 0),
            tolerance: 1
        )
    }

    func testMatteAndContentClipPathComposeTogether() async throws {
        let imageData = try pngData(size: CGSize(width: 20, height: 20), color: .red)
        let matte = vectorSprite(
            key: "mask.matte",
            rect: LYSVGARect(x: 0, y: 0, width: 10, height: 20),
            color: LYSVGAColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        let content = LYSVGASprite(
            imageKey: "red",
            frames: [frame(width: 20, height: 20, clipPath: "M0 0 H20 V10 H0 Z")],
            matteKey: "mask"
        )
        let renderer = LYSVGARenderer()
        try await renderer.prepare(video: try makeVideo(
            width: 20,
            height: 20,
            images: ["red.png": imageData],
            sprites: [matte, content]
        ))
        renderer.display(frame: 0)

        let image = render(renderer.rootLayer, size: CGSize(width: 20, height: 20))
        XCTAssertPixel(image, x: 5, y: 5, rgba: (255, 0, 0, 255), tolerance: 4)
        XCTAssertPixel(image, x: 15, y: 5, rgba: (0, 0, 0, 0), tolerance: 4)
        XCTAssertPixel(image, x: 5, y: 15, rgba: (0, 0, 0, 0), tolerance: 4)
    }

    func testMatteResolutionPrefersExactImageKeyBeforeCanonicalFallback() async throws {
        let canonicalCollision = vectorSprite(
            key: "mask.matte",
            rect: LYSVGARect(x: 0, y: 0, width: 5, height: 20),
            color: LYSVGAColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        let exactMatte = vectorSprite(
            key: "mask",
            rect: LYSVGARect(x: 15, y: 0, width: 5, height: 20),
            color: LYSVGAColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        let content = LYSVGASprite(
            imageKey: "content.vector",
            frames: [frame(
                width: 20,
                height: 20,
                shapes: [LYSVGAShape(
                    type: .rect(LYSVGAShapeRect(
                        rect: LYSVGARect(x: 0, y: 0, width: 20, height: 20),
                        cornerRadius: 0
                    )),
                    style: LYSVGAShapeStyle(fill: LYSVGAColor(red: 1, green: 0, blue: 0, alpha: 1))
                )]
            )],
            matteKey: "mask"
        )
        let renderer = LYSVGARenderer()

        try await renderer.prepare(video: try makeVideo(
            width: 20,
            height: 20,
            sprites: [canonicalCollision, exactMatte, content]
        ))
        renderer.display(frame: 0)

        let host = try XCTUnwrap(renderer.matteHosts.first)
        XCTAssertTrue(host.matteLayer === renderer.spriteLayers[1])
    }

    func testOutOfRangeFramesHideSpritesAndNonFiniteFrameDoesNotPolluteLayers() async throws {
        let invalid = LYSVGAFrame(
            alpha: .infinity,
            layout: LYSVGARect(x: .nan, y: .infinity, width: -.infinity, height: .nan),
            transform: LYSVGATransform(a: .nan, b: .infinity, c: 0, d: 1, tx: .nan, ty: .infinity),
            clipPath: "M0 0 L nan 1",
            shapes: []
        )
        let imageData = try pngData(size: CGSize(width: 10, height: 10), color: .red)
        let zeroAlpha = frame(alpha: 0, width: 10, height: 10)
        let valid = frame(width: 10, height: 10)
        let video = try makeVideo(
            width: 10,
            height: 10,
            images: ["red": imageData],
            sprites: [
                LYSVGASprite(imageKey: "red", frames: [invalid, zeroAlpha]),
                LYSVGASprite(imageKey: "red", frames: [valid]),
            ]
        )
        let renderer = LYSVGARenderer()
        try await renderer.prepare(video: video)

        renderer.display(frame: 0)
        let sprite = renderer.spriteLayers[0]
        XCTAssertTrue(sprite.isHidden)
        XCTAssertTrue(sprite.contentLayer.bounds.isFinite)
        XCTAssertTrue(sprite.contentLayer.position.isFinite)
        XCTAssertTrue(sprite.contentLayer.affineTransform().isFinite)

        renderer.display(frame: -1)
        XCTAssertNil(renderer.currentFrame)
        XCTAssertTrue(sprite.isHidden)
        renderer.display(frame: 1)
        XCTAssertEqual(renderer.currentFrame, 1)
        XCTAssertTrue(sprite.isHidden)
        XCTAssertTrue(renderer.spriteLayers[1].isHidden)
        renderer.display(frame: 2)
        XCTAssertNil(renderer.currentFrame)
        XCTAssertTrue(sprite.isHidden)
    }

    func testRendererCanvasUsesStandardFrameAndScaleForAllContentModes() async throws {
        let video = try makeVideo(width: 100, height: 50, sprites: [])
        let renderer = LYSVGARenderer()
        try await renderer.prepare(video: video)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let expected: [(UIView.ContentMode, CGRect)] = [
            (.scaleToFill, CGRect(x: 0, y: 0, width: 200, height: 200)),
            (.scaleAspectFit, CGRect(x: 0, y: 50, width: 200, height: 100)),
            (.scaleAspectFill, CGRect(x: -100, y: 0, width: 400, height: 200)),
            (.redraw, CGRect(x: 0, y: 0, width: 200, height: 200)),
            (.center, CGRect(x: 50, y: 75, width: 100, height: 50)),
            (.top, CGRect(x: 50, y: 0, width: 100, height: 50)),
            (.bottom, CGRect(x: 50, y: 150, width: 100, height: 50)),
            (.left, CGRect(x: 0, y: 75, width: 100, height: 50)),
            (.right, CGRect(x: 100, y: 75, width: 100, height: 50)),
            (.topLeft, CGRect(x: 0, y: 0, width: 100, height: 50)),
            (.topRight, CGRect(x: 100, y: 0, width: 100, height: 50)),
            (.bottomLeft, CGRect(x: 0, y: 150, width: 100, height: 50)),
            (.bottomRight, CGRect(x: 100, y: 150, width: 100, height: 50)),
        ]

        for (mode, frame) in expected {
            renderer.layout(in: bounds, contentMode: mode, clipsToBounds: mode == .scaleAspectFill)
            XCTAssertEqual(renderer.rootLayer.frame, bounds)
            XCTAssertEqual(renderer.canvasLayer.bounds, CGRect(x: 0, y: 0, width: 100, height: 50))
            XCTAssertEqual(renderer.canvasLayer.anchorPoint, .zero)
            XCTAssertEqual(renderer.canvasLayer.position, frame.origin)
            XCTAssertEqual(renderer.canvasLayer.affineTransform().a, frame.width / 100, accuracy: 0.0001)
            XCTAssertEqual(renderer.canvasLayer.affineTransform().d, frame.height / 50, accuracy: 0.0001)
            XCTAssertEqual(renderer.canvasLayer.frame, frame)
            XCTAssertEqual(renderer.rootLayer.masksToBounds, mode == .scaleAspectFill)
        }
    }

    func testDecodedV1AndV2MatteFixturesPrepareAndRenderNonEmptyPixels() async throws {
        for fixture in ["mutiMatte", "matteRect"] {
            let video = try LYSVGAFormatDecoder.decode(TestSupport.fixture(fixture))
            let renderer = LYSVGARenderer()
            try await renderer.prepare(video: video)
            renderer.layout(
                in: CGRect(x: 0, y: 0, width: video.canvasSize.width, height: video.canvasSize.height),
                contentMode: .center,
                clipsToBounds: true
            )
            renderer.display(frame: 0)

            let image = render(
                renderer.rootLayer,
                size: CGSize(width: video.canvasSize.width, height: video.canvasSize.height)
            )
            XCTAssertGreaterThan(nonTransparentPixelCount(image), 0, "Fixture \(fixture) rendered empty")
        }
    }
}

@MainActor
private extension LYSVGARendererTests {
    func makeVideo(
        width: Double,
        height: Double,
        frames: Int = 2,
        images: [String: Data] = [:],
        sprites: [LYSVGASprite]
    ) throws -> LYSVGAVideo {
        try LYSVGAVideo(
            version: "renderer-test",
            canvasSize: LYSVGASize(width: width, height: height),
            fps: 20,
            frameCount: frames,
            images: images,
            audioData: [:],
            sprites: sprites,
            audios: []
        )
    }

    func frame(
        alpha: Double = 1,
        x: Double = 0,
        y: Double = 0,
        width: Double = 60,
        height: Double = 30,
        transform: LYSVGATransform = .identity,
        clipPath: String? = nil,
        shapes: [LYSVGAShape] = []
    ) -> LYSVGAFrame {
        LYSVGAFrame(
            alpha: alpha,
            layout: LYSVGARect(x: x, y: y, width: width, height: height),
            transform: transform,
            clipPath: clipPath,
            shapes: shapes
        )
    }

    func vectorSprite(key: String, rect: LYSVGARect, color: LYSVGAColor) -> LYSVGASprite {
        LYSVGASprite(
            imageKey: key,
            frames: [frame(
                width: 20,
                height: 20,
                shapes: [LYSVGAShape(
                    type: .rect(LYSVGAShapeRect(rect: rect, cornerRadius: 0)),
                    style: LYSVGAShapeStyle(fill: color)
                )]
            )]
        )
    }

    func matteVideo(contentCount: Int) throws -> LYSVGAVideo {
        let red = try pngData(size: CGSize(width: 20, height: 20), color: .red)
        let matte = vectorSprite(
            key: "mask.matte",
            rect: LYSVGARect(x: 0, y: 0, width: 10, height: 20),
            color: LYSVGAColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        let content = (0..<contentCount).map { index in
            LYSVGASprite(
                imageKey: "red\(index)",
                frames: [frame(width: 20, height: 20)],
                matteKey: index == 0 ? "mask.matte" : "mask"
            )
        }
        let images = Dictionary(uniqueKeysWithValues: (0..<contentCount).map { ("red\($0).png", red) })
        return try makeVideo(width: 20, height: 20, images: images, sprites: [matte] + content)
    }

    func pngData(size: CGSize, color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.pngData())
    }

    func render(_ layer: CALayer, size: CGSize) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return context.makeImage()!
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int, Int) {
        let bytes = rgbaBytes(image)
        let offset = (y * image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
    }

    func rgbaBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    func nonTransparentPixelCount(_ image: CGImage) -> Int {
        rgbaBytes(image).enumerated().reduce(into: 0) { count, element in
            if element.offset % 4 == 3, element.element > 0 { count += 1 }
        }
    }

    func nonTransparentBounds(_ image: CGImage) -> CGRect {
        let bytes = rgbaBytes(image)
        var minimumX = image.width
        var minimumY = image.height
        var maximumX = -1
        var maximumY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                guard bytes[offset + 3] > 0 else { continue }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return .null }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }

    func XCTAssertPixel(
        _ image: CGImage,
        x: Int,
        y: Int,
        rgba: (Int, Int, Int, Int),
        tolerance: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = pixel(image, x: x, y: y)
        let message = "actual=\(actual), expected=\(rgba)"
        XCTAssertLessThanOrEqual(abs(actual.0 - rgba.0), tolerance, message, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.1 - rgba.1), tolerance, message, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.2 - rgba.2), tolerance, message, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.3 - rgba.3), tolerance, message, file: file, line: line)
    }

    func XCTAssertColor(
        _ color: CGColor?,
        rgba: (CGFloat, CGFloat, CGFloat, CGFloat),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let components = color.flatMap({ UIColor(cgColor: $0).cgColor.components }), components.count >= 4 else {
            return XCTFail("Expected an RGBA color", file: file, line: line)
        }
        XCTAssertEqual(components[0], rgba.0, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(components[1], rgba.1, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(components[2], rgba.2, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(components[3], rgba.3, accuracy: 0.001, file: file, line: line)
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.isFinite && size.width.isFinite && size.height.isFinite
    }
}

private extension CGPoint {
    var isFinite: Bool { x.isFinite && y.isFinite }
}

private extension CGAffineTransform {
    var isFinite: Bool {
        a.isFinite && b.isFinite && c.isFinite && d.isFinite && tx.isFinite && ty.isFinite
    }
}
