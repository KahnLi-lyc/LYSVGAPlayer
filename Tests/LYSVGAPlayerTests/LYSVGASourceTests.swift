import Foundation
import XCTest
@testable import LYSVGAPlayer

final class LYSVGASourceTests: XCTestCase {
    func testBundleResourceResolvesNamesWithAndWithoutExtension() throws {
        let withoutExtension = try LYSVGASource.bundleResource(
            named: "matteRect",
            subdirectory: "Fixtures",
            in: .module
        )
        let withExtension = try LYSVGASource.bundleResource(
            named: "matteRect.svga",
            subdirectory: "Fixtures",
            in: .module
        )

        XCTAssertEqual(try fileURL(from: withoutExtension), try fileURL(from: withExtension))
        XCTAssertEqual(try fileURL(from: withExtension).lastPathComponent, "matteRect.svga")
    }

    func testBundleResourceSupportsSubdirectoryAndReportsMissingResource() throws {
        let source = try LYSVGASource.bundleResource(
            named: "matteRect",
            subdirectory: "Fixtures",
            in: .module
        )
        XCTAssertEqual(try fileURL(from: source).lastPathComponent, "matteRect.svga")

        XCTAssertThrowsError(
            try LYSVGASource.bundleResource(named: "does-not-exist", in: .module)
        ) { error in
            XCTAssertEqual(error as? LYSVGAError, .missingResource("does-not-exist.svga"))
        }
    }

    func testRequestCacheKeyIsStableAndSeparatesResponseAffectingFields() throws {
        var first = URLRequest(url: URL(string: "https://example.com/asset.svga?b=2&a=1")!)
        first.httpMethod = "POST"
        first.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        first.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        first.httpBody = Data("one".utf8)
        first.timeoutInterval = 12

        var reordered = first
        reordered.allHTTPHeaderFields = [
            "Content-Type": "application/octet-stream",
            "Authorization": "Bearer secret",
        ]
        XCTAssertEqual(
            try LYSVGACacheKey.make(for: .request(first)),
            try LYSVGACacheKey.make(for: .request(reordered))
        )

        var differentMethod = first
        differentMethod.httpMethod = "PUT"
        var differentHeader = first
        differentHeader.setValue("Bearer other", forHTTPHeaderField: "Authorization")
        var differentBody = first
        differentBody.httpBody = Data("two".utf8)
        var differentTimeout = first
        differentTimeout.timeoutInterval = 30

        let originalKey = try LYSVGACacheKey.make(for: .request(first))
        for request in [differentMethod, differentHeader, differentBody, differentTimeout] {
            XCTAssertNotEqual(originalKey, try LYSVGACacheKey.make(for: .request(request)))
        }
    }

    func testRequestWithBodyStreamCannotProduceCacheKey() {
        var request = URLRequest(url: URL(string: "https://example.com/asset.svga")!)
        request.httpBodyStream = InputStream(data: Data("stream".utf8))

        XCTAssertThrowsError(try LYSVGACacheKey.make(for: .request(request))) { error in
            XCTAssertEqual(
                error as? LYSVGAError,
                .invalidRequest("URLRequest.httpBodyStream is unsupported because it cannot be replayed safely.")
            )
        }
    }

    private func fileURL(from source: LYSVGASource) throws -> URL {
        guard case let .file(url) = source else {
            throw LYSVGAError.invalidData("Expected a file source.")
        }
        return url
    }
}
