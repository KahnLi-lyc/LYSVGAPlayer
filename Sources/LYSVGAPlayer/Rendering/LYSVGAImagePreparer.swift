import CoreGraphics
import Foundation
import ImageIO

struct LYSVGAPreparedImage: @unchecked Sendable {
    // CGImage is an immutable Core Graphics object after creation.
    let cgImage: CGImage
}

enum LYSVGAImagePreparer {
    static var decodeOptions: CFDictionary {
        [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
    }

    @concurrent
    static func prepare(
        _ video: LYSVGAVideo,
        checkpoint: (@Sendable () async -> Void)? = nil
    ) async throws -> [String: LYSVGAPreparedImage] {
        try Task.checkCancellation()
        var result: [String: LYSVGAPreparedImage] = [:]
        result.reserveCapacity(video.images.count)

        for (sourceKey, data) in video.images {
            try Task.checkCancellation()
            await checkpoint?()
            try Task.checkCancellation()
            let key = LYSVGAResourceKey.canonicalize(sourceKey)
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: true] as CFDictionary
            ), let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                decodeOptions
            ) else {
                throw LYSVGAError.imagePreparationFailure(key)
            }
            result[key] = LYSVGAPreparedImage(cgImage: image)
        }

        try Task.checkCancellation()
        return result
    }
}
