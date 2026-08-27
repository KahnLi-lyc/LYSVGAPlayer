import Compression
import Foundation

enum LYSVGACompression {
    private static let defaultMaximumOutputSize = 256 * 1_024 * 1_024
    private static let bufferSize = 64 * 1_024
    // Compression may absorb trailing bytes in one source block, so validate the tail byte by byte.
    private static let exactEndValidationSize = 64

    static func inflateZlib(
        _ data: Data,
        maximumOutputSize: Int = defaultMaximumOutputSize
    ) throws -> Data {
        guard data.count >= 6 else {
            throw LYSVGAError.dataTooShort(actual: data.count, minimum: 6)
        }
        guard maximumOutputSize >= 0 else {
            throw LYSVGAError.decompressionFailure("The maximum output size is invalid.")
        }
        let compressionMethod = data[data.startIndex]
        let flags = data[data.index(after: data.startIndex)]
        guard compressionMethod & 0x0F == 8,
              compressionMethod >> 4 <= 7,
              (Int(compressionMethod) << 8 | Int(flags)) % 31 == 0 else {
            throw LYSVGAError.decompressionFailure("The zlib header is invalid.")
        }
        guard flags & 0x20 == 0 else {
            throw LYSVGAError.decompressionFailure("Preset zlib dictionaries are unsupported.")
        }
        let payload = Data(data.dropFirst(2).dropLast(4))
        guard payload.isEmpty == false else {
            throw LYSVGAError.decompressionFailure("The zlib payload is empty.")
        }

        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            != COMPRESSION_STATUS_ERROR else {
            throw LYSVGAError.decompressionFailure("Unable to initialize the zlib decoder.")
        }
        defer { compression_stream_destroy(&stream) }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var output = Data()
        output.reserveCapacity(min(max(payload.count, bufferSize), maximumOutputSize))
        var first: UInt32 = 1
        var second: UInt32 = 0
        try payload.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw LYSVGAError.decompressionFailure("The zlib payload is empty.")
            }

            var sourceOffset = 0
            while true {
                try Task.checkCancellation()
                if stream.src_size == 0, sourceOffset < payload.count {
                    let remaining = payload.count - sourceOffset
                    let count = remaining > exactEndValidationSize
                        ? min(bufferSize, remaining - exactEndValidationSize)
                        : 1
                    stream.src_ptr = source.advanced(by: sourceOffset)
                    stream.src_size = count
                    sourceOffset += count
                }

                let sourceSizeBeforeProcessing = stream.src_size
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let processingFlags = sourceOffset == payload.count
                    ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    : 0
                let status = compression_stream_process(&stream, processingFlags)
                let produced = bufferSize - stream.dst_size
                guard produced <= maximumOutputSize - output.count else {
                    throw LYSVGAError.decompressionFailure("The zlib output exceeds the configured size limit.")
                }
                if produced > 0 {
                    try updateAdler32(destination, count: produced, first: &first, second: &second)
                    output.append(destination, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    let consumed = sourceOffset - stream.src_size
                    guard consumed == payload.count else {
                        throw LYSVGAError.decompressionFailure("The zlib stream contains trailing payload bytes.")
                    }
                    return
                case COMPRESSION_STATUS_OK:
                    guard produced > 0 || stream.src_size < sourceSizeBeforeProcessing else {
                        throw LYSVGAError.decompressionFailure("The zlib stream is corrupt or truncated.")
                    }
                default:
                    throw LYSVGAError.decompressionFailure("The zlib stream is corrupt or truncated.")
                }
            }
        }

        try Task.checkCancellation()
        guard second << 16 | first == expectedAdler32(data) else {
            throw LYSVGAError.decompressionFailure("The zlib checksum does not match its payload.")
        }
        return output
    }

    private static func expectedAdler32(_ data: Data) -> UInt32 {
        data.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func updateAdler32(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        first: inout UInt32,
        second: inout UInt32
    ) throws {
        let modulus: UInt32 = 65_521
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let end = min(offset + 5_552, count)
            while offset < end {
                first += UInt32(bytes[offset])
                second += first
                offset += 1
            }
            first %= modulus
            second %= modulus
        }
    }
}
