import Foundation

public enum LYSVGAError: Error, Equatable, Sendable {
    case invalidData(String)
    case dataTooShort(actual: Int, minimum: Int)
    case unsupportedFormat
    case zipFailure(String)
    case unsafeArchiveEntry(String)
    case decompressionFailure(String)
    case jsonFailure(String)
    case protobufFailure(String)
    case missingResource(String)
    case networkFailure(String)
    case httpStatus(Int)
    case fileFailure(String)
    case cacheFailure(String)
    case cancelled
    case invalidModel(String)
    case imagePreparationFailure(String)
    case invalidPath(String)
    case invalidPlaybackConfiguration(String)
    case audioPreparationFailure(audioKey: String, reason: String)
}

extension LYSVGAError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidData(reason): "Invalid SVGA data: \(reason)"
        case let .dataTooShort(actual, minimum): "SVGA data is too short (\(actual) bytes; at least \(minimum) required)."
        case .unsupportedFormat: "The SVGA format is unsupported."
        case let .zipFailure(reason): "Unable to read the SVGA ZIP archive: \(reason)"
        case let .unsafeArchiveEntry(path): "The SVGA archive contains an unsafe path: \(path)"
        case let .decompressionFailure(reason): "Unable to decompress SVGA data: \(reason)"
        case let .jsonFailure(reason): "Unable to decode SVGA JSON: \(reason)"
        case let .protobufFailure(reason): "Unable to decode SVGA Protobuf: \(reason)"
        case let .missingResource(key): "The SVGA resource is missing: \(key)"
        case let .networkFailure(reason): "Unable to load SVGA data: \(reason)"
        case let .httpStatus(status): "The SVGA request returned HTTP status \(status)."
        case let .fileFailure(reason): "Unable to read the SVGA file: \(reason)"
        case let .cacheFailure(reason): "The SVGA cache failed: \(reason)"
        case .cancelled: "The SVGA operation was cancelled."
        case let .invalidModel(reason): "The SVGA model is invalid: \(reason)"
        case let .imagePreparationFailure(key): "Unable to prepare the SVGA image: \(key)"
        case let .invalidPath(reason): "The SVG path is invalid: \(reason)"
        case let .invalidPlaybackConfiguration(reason): "The SVGA playback configuration is invalid: \(reason)"
        case let .audioPreparationFailure(audioKey, reason):
            "Unable to prepare SVGA audio '\(audioKey)': \(reason)"
        }
    }
}
