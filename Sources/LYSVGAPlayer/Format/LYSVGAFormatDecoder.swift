import Foundation
import ZIPFoundation

enum LYSVGAFormat: Equatable {
    case zip
    case zlib
}

enum LYSVGAFormatDecoder {
    static func detect(_ data: Data) throws -> LYSVGAFormat {
        guard data.count >= 4 else {
            throw LYSVGAError.dataTooShort(actual: data.count, minimum: 4)
        }
        return data.starts(with: [0x50, 0x4B]) ? .zip : .zlib
    }

    static func decode(_ data: Data) throws -> LYSVGAVideo {
        try Task.checkCancellation()
        switch try detect(data) {
        case .zip:
            return try decodeArchive(data)
        case .zlib:
            return try LYSVGAV2Decoder.decode(LYSVGACompression.inflateZlib(data))
        }
    }

    private static func decodeArchive(_ data: Data) throws -> LYSVGAVideo {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LYSVGA-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            throw LYSVGAError.fileFailure(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let archiveURL = temporaryDirectory.appendingPathComponent("source.svga")
        do {
            try data.write(to: archiveURL, options: .atomic)
            let archive = try Archive(url: archiveURL, accessMode: .read)
            for entry in archive {
                try Task.checkCancellation()
                guard LYSVGAV1Decoder.isSafeRelativePath(entry.path) else {
                    throw LYSVGAError.unsafeArchiveEntry(entry.path)
                }
                let destination = temporaryDirectory.appendingPathComponent(entry.path)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try archive.extract(entry, to: destination)
            }
        } catch let error as LYSVGAError {
            throw error
        } catch {
            throw LYSVGAError.zipFailure(error.localizedDescription)
        }

        try Task.checkCancellation()
        let jsonURL = temporaryDirectory.appendingPathComponent("movie.spec")
        if fileManager.fileExists(atPath: jsonURL.path) {
            return try LYSVGAV1Decoder.decode(Data(contentsOf: jsonURL), resourceDirectory: temporaryDirectory)
        }
        let protobufURL = temporaryDirectory.appendingPathComponent("movie.binary")
        if fileManager.fileExists(atPath: protobufURL.path) {
            return try LYSVGAV2Decoder.decode(
                Data(contentsOf: protobufURL),
                resourceDirectory: temporaryDirectory
            )
        }
        throw LYSVGAError.invalidData("The archive contains neither movie.spec nor movie.binary.")
    }
}
