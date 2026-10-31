import Foundation
import ZIPFoundation

enum LYSVGAFormat: Equatable {
    case zip
    case zlib
}

enum LYSVGAFormatDecoder {
    private static let maximumArchiveOutputSize = 256 * 1_024 * 1_024

    static func detect(_ data: Data) throws -> LYSVGAFormat {
        guard data.count >= 4 else {
            throw LYSVGAError.dataTooShort(actual: data.count, minimum: 4)
        }
        return data.starts(with: [0x50, 0x4B]) ? .zip : .zlib
    }

    static func decode(_ data: Data, faultTolerance: LYSVGAFaultTolerance = .strict) throws -> LYSVGAVideo {
        try Task.checkCancellation()
        switch try detect(data) {
        case .zip:
            return try decodeArchive(data, faultTolerance: faultTolerance)
        case .zlib:
            return try LYSVGAV2Decoder.decode(
                LYSVGACompression.inflateZlib(data),
                faultTolerance: faultTolerance
            )
        }
    }

    private static func decodeArchive(_ data: Data, faultTolerance: LYSVGAFaultTolerance) throws -> LYSVGAVideo {
        var resources: [String: Data] = [:]
        do {
            let archive = try Archive(data: data, accessMode: .read)
            var totalOutputSize = 0
            for entry in archive {
                try Task.checkCancellation()
                guard entry.type != .symlink else {
                    throw LYSVGAError.unsafeArchiveEntry(entry.path)
                }
                guard LYSVGAResourceResolver.isSafeRelativePath(entry.path) else {
                    throw LYSVGAError.unsafeArchiveEntry(entry.path)
                }
                guard entry.type == .file else { continue }
                let entrySize = Int(entry.uncompressedSize)
                guard entrySize <= maximumArchiveOutputSize - totalOutputSize else {
                    throw LYSVGAError.zipFailure("The archive output exceeds the configured size limit.")
                }
                var extracted = Data()
                extracted.reserveCapacity(entrySize)
                _ = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    guard chunk.count <= maximumArchiveOutputSize - totalOutputSize - extracted.count else {
                        throw LYSVGAError.zipFailure("The archive output exceeds the configured size limit.")
                    }
                    extracted.append(chunk)
                }
                totalOutputSize += extracted.count
                resources[entry.path.replacingOccurrences(of: "\\", with: "/")] = extracted
            }
        } catch let error as LYSVGAError {
            throw error
        } catch {
            throw LYSVGAError.zipFailure(error.localizedDescription)
        }

        try Task.checkCancellation()
        return try decodeArchiveResources(resources, faultTolerance: faultTolerance)
    }

    static func decodeArchiveResources(
        _ resources: [String: Data],
        faultTolerance: LYSVGAFaultTolerance = .strict
    ) throws -> LYSVGAVideo {
        if let protobuf = resources["movie.binary"] {
            return try LYSVGAV2Decoder.decode(protobuf, resources: resources, faultTolerance: faultTolerance)
        }
        if let json = resources["movie.spec"] {
            return try LYSVGAV1Decoder.decode(json, resources: resources, faultTolerance: faultTolerance)
        }
        throw LYSVGAError.invalidData("The archive contains neither movie.spec nor movie.binary.")
    }
}
