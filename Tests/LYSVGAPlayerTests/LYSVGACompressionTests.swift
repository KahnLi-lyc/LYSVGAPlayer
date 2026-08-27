import Foundation
import XCTest
@testable import LYSVGAPlayer

final class LYSVGACompressionTests: XCTestCase {
    func testInflatesValidStreamingZlibData() throws {
        let expected = Data((0 ..< 150_000).map { UInt8($0 % 251) })

        XCTAssertEqual(try LYSVGACompression.inflateZlib(makeStoredZlib(expected)), expected)
    }

    func testRejectsInvalidZlibHeader() {
        var stream = makeStoredZlib(Data("movie".utf8))
        stream[stream.startIndex] = 0x77

        assertDecompressionFailure(stream)
    }

    func testRejectsPresetDictionary() {
        var stream = makeStoredZlib(Data("movie".utf8))
        stream[stream.index(after: stream.startIndex)] = 0x20

        assertDecompressionFailure(stream)
    }

    func testRejectsInvalidAdler32() {
        var stream = makeStoredZlib(Data("movie".utf8))
        stream[stream.index(before: stream.endIndex)] ^= 0x01

        assertDecompressionFailure(stream)
    }

    func testRejectsTruncatedDeflateStream() {
        var stream = makeStoredZlib(Data("movie".utf8))
        stream.remove(at: stream.index(stream.endIndex, offsetBy: -5))

        assertDecompressionFailure(stream)
    }

    func testRejectsTrailingDeflatePayload() {
        var stream = makeStoredZlib(Data("movie".utf8))
        stream.insert(0, at: stream.index(stream.endIndex, offsetBy: -4))

        assertDecompressionFailure(stream)
    }

    func testRejectsRepeatedAdler32() {
        var stream = makeStoredZlib(Data("movie".utf8))
        stream.append(stream.suffix(4))

        assertDecompressionFailure(stream)
    }

    func testAllowsOutputExactlyAtConfiguredLimit() throws {
        let expected = Data(repeating: 0x5A, count: 64)

        XCTAssertEqual(
            try LYSVGACompression.inflateZlib(makeStoredZlib(expected), maximumOutputSize: expected.count),
            expected
        )
    }

    func testRejectsOutputOverConfiguredLimit() {
        let stream = makeStoredZlib(Data(repeating: 0x5A, count: 65))

        XCTAssertThrowsError(try LYSVGACompression.inflateZlib(stream, maximumOutputSize: 64)) { error in
            guard case .decompressionFailure = error as? LYSVGAError else {
                return XCTFail("Expected decompressionFailure, got \(error)")
            }
        }
    }

    func testInflationRespondsToTaskCancellation() async {
        let stream = makeStoredZlib(Data(repeating: 0x5A, count: 150_000))
        let task = Task {
            while Task.isCancelled == false {
                await Task.yield()
            }
            return try LYSVGACompression.inflateZlib(stream)
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func assertDecompressionFailure(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try LYSVGACompression.inflateZlib(data), file: file, line: line) { error in
            guard case .decompressionFailure = error as? LYSVGAError else {
                return XCTFail("Expected decompressionFailure, got \(error)", file: file, line: line)
            }
        }
    }

    private func makeStoredZlib(_ payload: Data) -> Data {
        var result = Data([0x78, 0x01])
        if payload.isEmpty {
            result.append(contentsOf: [0x01, 0x00, 0x00, 0xFF, 0xFF])
        } else {
            var offset = 0
            while offset < payload.count {
                let blockSize = min(65_535, payload.count - offset)
                let isFinal = offset + blockSize == payload.count
                let length = UInt16(blockSize)
                let complement = ~length
                result.append(isFinal ? 0x01 : 0x00)
                result.append(UInt8(truncatingIfNeeded: length))
                result.append(UInt8(truncatingIfNeeded: length >> 8))
                result.append(UInt8(truncatingIfNeeded: complement))
                result.append(UInt8(truncatingIfNeeded: complement >> 8))
                result.append(payload[offset ..< offset + blockSize])
                offset += blockSize
            }
        }
        let checksum = adler32(payload)
        result.append(UInt8(truncatingIfNeeded: checksum >> 24))
        result.append(UInt8(truncatingIfNeeded: checksum >> 16))
        result.append(UInt8(truncatingIfNeeded: checksum >> 8))
        result.append(UInt8(truncatingIfNeeded: checksum))
        return result
    }

    private func adler32(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65_521
        var first: UInt32 = 1
        var second: UInt32 = 0
        for byte in data {
            first = (first + UInt32(byte)) % modulus
            second = (second + first) % modulus
        }
        return second << 16 | first
    }
}
