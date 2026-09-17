import LYSVGAPlayer
import XCTest

final class LYSVGAVersionTests: XCTestCase {
    func testPackageVersionIdentifier() {
        XCTAssertEqual(LYSVGAVersion.identifier, "0.1.1")
    }
}
