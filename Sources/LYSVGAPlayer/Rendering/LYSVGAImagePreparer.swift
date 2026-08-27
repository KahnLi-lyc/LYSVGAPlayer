import CoreGraphics
import Foundation
import ImageIO

struct LYSVGAPreparedImage: @unchecked Sendable {
    // CGImage is an immutable Core Graphics object after creation.
    let cgImage: CGImage
}

enum LYSVGAImagePreparer {
    @concurrent
    static func prepare(_ video: LYSVGAVideo) async throws -> [String: LYSVGAPreparedImage] {
        try Task.checkCancellation()
        var result: [String: LYSVGAPreparedImage] = [:]
        result.reserveCapacity(video.images.count)

        for (sourceKey, data) in video.images {
            try Task.checkCancellation()
            let key = LYSVGAResourceKey.canonicalize(sourceKey)
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: true] as CFDictionary
            ), let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            ) else {
                throw LYSVGAError.imagePreparationFailure(key)
            }
            result[key] = LYSVGAPreparedImage(cgImage: image)
        }

        try Task.checkCancellation()
        return result
    }
}
