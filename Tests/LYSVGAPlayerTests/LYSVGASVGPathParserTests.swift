import CoreGraphics
import XCTest
@testable import LYSVGAPlayer

final class LYSVGASVGPathParserTests: XCTestCase {
    func testMoveLineHorizontalVerticalCloseAbsoluteRelativeAndRepeatedParameters() throws {
        let path = try LYSVGASVGPathParser.parse("M1 1 L5 1 5 5 H3 V4 Z m10 0 l2 0 h2 v2 z")
        let elements = elements(of: path)

        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 1, y: 1, width: 14, height: 4))
        XCTAssertEqual(elements.filter { $0.type == .moveToPoint }.map { $0.points[0] }, [
            CGPoint(x: 1, y: 1),
            CGPoint(x: 11, y: 1),
        ])
        XCTAssertEqual(elements.filter { $0.type == .closeSubpath }.count, 2)
    }

    func testCubicAndSmoothCubicReflectPreviousControlPoint() throws {
        let path = try LYSVGASVGPathParser.parse("M0 0 C10 0 10 10 20 10 S30 20 40 10")
        let curves = elements(of: path).filter { $0.type == .addCurveToPoint }

        XCTAssertEqual(curves.count, 2)
        XCTAssertEqual(curves[1].points, [
            CGPoint(x: 30, y: 10),
            CGPoint(x: 30, y: 20),
            CGPoint(x: 40, y: 10),
        ])
        XCTAssertTrue(path.boundingBoxOfPath.contains(CGPoint(x: 20, y: 10)))
    }

    func testQuadraticAndSmoothQuadraticReflectPreviousControlPoint() throws {
        let path = try LYSVGASVGPathParser.parse("M0 0 Q10 20 20 0 T40 0")
        let curves = elements(of: path).filter { $0.type == .addQuadCurveToPoint }

        XCTAssertEqual(curves.count, 2)
        XCTAssertEqual(curves[1].points, [CGPoint(x: 30, y: -20), CGPoint(x: 40, y: 0)])
        XCTAssertGreaterThan(path.boundingBoxOfPath.height, 0)
    }

    func testRelativeMoveImplicitLinesNegativeAdjacencyDecimalsAndScientificNotation() throws {
        let path = try LYSVGASVGPathParser.parse("m1e1,1E1 5-5-.5.5")
        let records = elements(of: path)

        XCTAssertEqual(records.map(\.points).compactMap(\.last), [
            CGPoint(x: 10, y: 10),
            CGPoint(x: 15, y: 5),
            CGPoint(x: 14.5, y: 5.5),
        ])
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 10, y: 5, width: 5, height: 5))
    }

    func testEllipticalArcSupportsSweepLargeArcAndRotation() throws {
        let semicircle = try LYSVGASVGPathParser.parse("M0 0 A10 10 0 0 1 20 0 L10 0 Z")
        let semicircleBox = semicircle.boundingBoxOfPath
        let filledPoint = CGPoint(x: 10, y: semicircleBox.midY / 2)

        XCTAssertEqual(semicircle.currentPoint, CGPoint(x: 0, y: 0))
        XCTAssertEqual(semicircleBox.width, 20, accuracy: 0.000_001)
        XCTAssertEqual(semicircleBox.height, 10, accuracy: 0.000_001)
        XCTAssertTrue(semicircle.contains(filledPoint))

        let rotated = try LYSVGASVGPathParser.parse("M20 50 A30 10 45 1 1 80 50")
        let rotatedElements = elements(of: rotated)
        XCTAssertEqual(rotated.currentPoint.x, 80, accuracy: 0.000_001)
        XCTAssertEqual(rotated.currentPoint.y, 50, accuracy: 0.000_001)
        XCTAssertTrue(rotatedElements.contains { $0.type == .addCurveToPoint })
        XCTAssertGreaterThan(rotated.boundingBoxOfPath.height, 20)
    }

    func testCloseResetsCurrentPointForFollowingRelativeCommand() throws {
        let path = try LYSVGASVGPathParser.parse("M5 5 L10 5 Z l2 3")

        XCTAssertEqual(path.currentPoint, CGPoint(x: 7, y: 8))
    }

    func testEmptyUnsupportedIncompleteAndInvalidArcFlagsThrowInvalidPath() {
        let invalidPaths = [
            "",
            "   ,  ",
            "M",
            "M0 0 R10 10",
            "M0 0 C1 2 3 4",
            "M0 0 A10 10 0 2 1 20 0",
            "M0 0 A10 10 0 0 3 20 0",
        ]

        for source in invalidPaths {
            XCTAssertThrowsError(try LYSVGASVGPathParser.parse(source), "Expected failure for: \(source)") { error in
                guard case .invalidPath = error as? LYSVGAError else {
                    return XCTFail("Expected invalidPath for \(source), got \(error)")
                }
            }
        }
    }

    private struct ElementRecord {
        let type: CGPathElementType
        let points: [CGPoint]
    }

    private func elements(of path: CGPath) -> [ElementRecord] {
        var result: [ElementRecord] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let pointCount: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                pointCount = 1
            case .addQuadCurveToPoint:
                pointCount = 2
            case .addCurveToPoint:
                pointCount = 3
            case .closeSubpath:
                pointCount = 0
            @unknown default:
                pointCount = 0
            }
            result.append(ElementRecord(
                type: element.type,
                points: (0 ..< pointCount).map { element.points[$0] }
            ))
        }
        return result
    }
}
