import Compression
import Foundation

enum LYSVGACompression {
    private static let maximumOutputSize = 256 * 1_024 * 1_024

    static func inflateZlib(_ data: Data) throws -> Data {
        guard data.count >= 6 else {
            throw LYSVGAError.dataTooShort(actual: data.count, minimum: 6)
        }
        let compressionMethod = data[data.startIndex]
        let flags = data[data.index(after: data.startIndex)]
        guard compressionMethod & 0x0F == 8,
              compressionMethod >> 4 <= 7,
              (Int(compressionMethod) << 8 | Int(flags)) % 31 == 0,
              flags & 0x20 == 0 else {
            throw LYSVGAError.decompressionFailure("The zlib header is invalid or uses a preset dictionary.")
        }
        let payload = data.dropFirst(2).dropLast(4)
        guard payload.isEmpty == false else {
            throw LYSVGAError.decompressionFailure("The zlib payload is empty.")
        }

        var capacity = min(max(payload.count * 4, 64 * 1_024), maximumOutputSize)
        while capacity <= maximumOutputSize {
            try Task.checkCancellation()
            var output = Data(count: capacity)
            let decodedCount = output.withUnsafeMutableBytes { destination in
                payload.withUnsafeBytes { source in
                    guard let destinationAddress = destination.bindMemory(to: UInt8.self).baseAddress,
                          let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_decode_buffer(
                        destinationAddress,
                        capacity,
                        sourceAddress,
                        payload.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decodedCount > 0, decodedCount < capacity {
                try Task.checkCancellation()
                output.removeSubrange(decodedCount ..< output.count)
                guard try adler32(output) == expectedAdler32(data) else {
                    throw LYSVGAError.decompressionFailure("The zlib checksum does not match its payload.")
                }
                return output
            }
            guard capacity < maximumOutputSize else { break }
            capacity = min(capacity * 2, maximumOutputSize)
        }
        throw LYSVGAError.decompressionFailure("The zlib stream is corrupt, truncated, or exceeds 256 MiB.")
    }

    private static func expectedAdler32(_ data: Data) -> UInt32 {
        data.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func adler32(_ data: Data) throws -> UInt32 {
        let modulus: UInt32 = 65_521
        var first: UInt32 = 1
        var second: UInt32 = 0
        for (index, byte) in data.enumerated() {
            if index.isMultiple(of: 64 * 1_024) {
                try Task.checkCancellation()
            }
            first = (first + UInt32(byte)) % modulus
            second = (second + first) % modulus
        }
        return second << 16 | first
    }
}
