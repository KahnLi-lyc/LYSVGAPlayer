import Foundation
@testable import LYSVGAPlayer

enum TestSupport {
    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svga", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LYSVGATests-\(UUID().uuidString)", isDirectory: true)
    }

    static func video(version: String = "test", imageBytes: Int = 0) throws -> LYSVGAVideo {
        try LYSVGAVideo(
            version: version,
            canvasSize: LYSVGASize(width: 100, height: 100),
            fps: 20,
            frameCount: 2,
            images: imageBytes > 0 ? ["image": Data(repeating: 1, count: imageBytes)] : [:],
            audioData: [:],
            sprites: [],
            audios: []
        )
    }
}
