import UIKit
import XCTest
@testable import LYSVGAPlayer

final class LYSVGACanvasLayoutTests: XCTestCase {
    func testAllUIKitContentModesUseStandardLayoutSemantics() {
        let videoSize = CGSize(width: 100, height: 50)
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 200)
        let expectations: [(UIView.ContentMode, CGRect)] = [
            (.scaleToFill, CGRect(x: 10, y: 20, width: 200, height: 200)),
            (.scaleAspectFit, CGRect(x: 10, y: 70, width: 200, height: 100)),
            (.scaleAspectFill, CGRect(x: -90, y: 20, width: 400, height: 200)),
            (.redraw, CGRect(x: 10, y: 20, width: 200, height: 200)),
            (.center, CGRect(x: 60, y: 95, width: 100, height: 50)),
            (.top, CGRect(x: 60, y: 20, width: 100, height: 50)),
            (.bottom, CGRect(x: 60, y: 170, width: 100, height: 50)),
            (.left, CGRect(x: 10, y: 95, width: 100, height: 50)),
            (.right, CGRect(x: 110, y: 95, width: 100, height: 50)),
            (.topLeft, CGRect(x: 10, y: 20, width: 100, height: 50)),
            (.topRight, CGRect(x: 110, y: 20, width: 100, height: 50)),
            (.bottomLeft, CGRect(x: 10, y: 170, width: 100, height: 50)),
            (.bottomRight, CGRect(x: 110, y: 170, width: 100, height: 50)),
        ]

        for (contentMode, expected) in expectations {
            XCTAssertEqual(
                LYSVGACanvasLayout.frame(videoSize: videoSize, in: bounds, contentMode: contentMode),
                expected,
                "Unexpected frame for \(contentMode.rawValue)"
            )
        }
    }

    func testAspectModesHandleNonSquarePortraitVideo() {
        let videoSize = CGSize(width: 50, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 100)

        XCTAssertEqual(
            LYSVGACanvasLayout.frame(videoSize: videoSize, in: bounds, contentMode: .scaleAspectFit),
            CGRect(x: 125, y: 0, width: 50, height: 100)
        )
        XCTAssertEqual(
            LYSVGACanvasLayout.frame(videoSize: videoSize, in: bounds, contentMode: .scaleAspectFill),
            CGRect(x: 0, y: -250, width: 300, height: 600)
        )
    }

    func testInvalidVideoOrContainerDimensionsReturnZero() {
        let validVideo = CGSize(width: 100, height: 100)
        let validBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let invalidVideoSizes = [
            CGSize(width: 0, height: 100),
            CGSize(width: -1, height: 100),
            CGSize(width: CGFloat.infinity, height: 100),
            CGSize(width: 100, height: CGFloat.nan),
        ]
        let invalidBounds = [
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: -1),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
        ]

        for videoSize in invalidVideoSizes {
            XCTAssertEqual(
                LYSVGACanvasLayout.frame(videoSize: videoSize, in: validBounds, contentMode: .center),
                .zero
            )
        }
        for bounds in invalidBounds {
            XCTAssertEqual(
                LYSVGACanvasLayout.frame(videoSize: validVideo, in: bounds, contentMode: .center),
                .zero
            )
        }
    }

    func testAllContentModesRejectNonFiniteBoundsOrigins() {
        let videoSize = CGSize(width: 100, height: 100)
        let invalidBounds = [
            CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100),
        ]
        let contentModes: [UIView.ContentMode] = [
            .scaleToFill, .scaleAspectFit, .scaleAspectFill, .redraw,
            .center, .top, .bottom, .left, .right,
            .topLeft, .topRight, .bottomLeft, .bottomRight,
        ]

        for bounds in invalidBounds {
            for contentMode in contentModes {
                XCTAssertEqual(
                    LYSVGACanvasLayout.frame(videoSize: videoSize, in: bounds, contentMode: contentMode),
                    .zero,
                    "Expected invalid origin to be rejected for mode \(contentMode.rawValue)"
                )
            }
        }
    }
}
