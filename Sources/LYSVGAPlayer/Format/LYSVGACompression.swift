import Compression
import Foundation

enum LYSVGACompression {
    static func inflateZlib(_ data: Data) throws -> Data {
        guard data.count >= 2 else {
            throw LYSVGAError.dataTooShort(actual: data.count, minimum: 2)
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
        let initialization = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initialization != COMPRESSION_STATUS_ERROR else {
            throw LYSVGAError.decompressionFailure("Unable to initialize the zlib decoder.")
        }
        defer { compression_stream_destroy(&stream) }

        let destinationSize = 64 * 1_024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destination.deallocate() }

        return try data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw LYSVGAError.invalidData("The input buffer is empty.")
            }
            stream.src_ptr = source
            stream.src_size = data.count

            var output = Data()
            while true {
                try Task.checkCancellation()
                stream.dst_ptr = destination
                stream.dst_size = destinationSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = destinationSize - stream.dst_size
                if produced > 0 {
                    output.append(destination, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    guard stream.src_size == 0, output.isEmpty == false else {
                        throw LYSVGAError.decompressionFailure("The zlib stream ended before producing a movie.")
                    }
                    return output
                case COMPRESSION_STATUS_OK:
                    continue
                default:
                    throw LYSVGAError.decompressionFailure("The zlib stream is corrupt or truncated.")
                }
            }
        }
    }
}
