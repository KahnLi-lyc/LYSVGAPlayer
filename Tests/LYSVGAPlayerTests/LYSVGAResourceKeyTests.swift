import XCTest
@testable import LYSVGAPlayer

final class LYSVGAResourceKeyTests: XCTestCase {
    func testCanonicalizesSingleAndRepeatedKnownSuffixesCaseInsensitively() {
        XCTAssertEqual(LYSVGAResourceKey.canonicalize("photo.png"), "photo")
        XCTAssertEqual(LYSVGAResourceKey.canonicalize("mask.MATTE.PNG"), "mask")
        XCTAssertEqual(LYSVGAResourceKey.canonicalize("folder/icon.JpEg.VeCtOr"), "folder/icon")
        XCTAssertEqual(LYSVGAResourceKey.canonicalize("shape.vector.matte.webp"), "shape")
    }

    func testPreservesExistingSingleExtensionRemovalBehavior() {
        XCTAssertEqual(LYSVGAResourceKey.canonicalize("audio.mp3"), "audio")
        XCTAssertEqual(LYSVGAResourceKey.canonicalize("archive.part.custom"), "archive.part")
        XCTAssertEqual(LYSVGAResourceKey.canonicalize("plain-key"), "plain-key")
    }
}
