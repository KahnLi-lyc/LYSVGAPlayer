import Foundation

enum LYSVGAResourceResolver {
    static func containedURL(relativePath: String, in directory: URL) throws -> URL {
        let path = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
        guard isSafeRelativePath(path) else {
            throw LYSVGAError.unsafeArchiveEntry(relativePath)
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw LYSVGAError.unsafeArchiveEntry(relativePath)
        }
        return candidate
    }

    static func resolve(
        filename: String,
        key: String,
        directory: URL,
        fallbackExtension: String? = nil
    ) throws -> Data {
        var filenames = [filename]
        if let fallbackExtension, (filename as NSString).pathExtension.isEmpty {
            filenames.append((filename as NSString).appendingPathExtension(fallbackExtension) ?? filename)
        }
        for candidateName in filenames {
            let candidate = try containedURL(relativePath: candidateName, in: directory)
            if FileManager.default.fileExists(atPath: candidate.path) {
                do {
                    return try Data(contentsOf: candidate, options: [.mappedIfSafe])
                } catch {
                    throw LYSVGAError.missingResource("\(key) -> \(candidateName)")
                }
            }
        }
        throw LYSVGAError.missingResource("\(key) -> \(filename)")
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard path.isEmpty == false,
              (path as NSString).isAbsolutePath == false,
              path.hasPrefix("\\") == false,
              path.utf8.contains(0) == false else {
            return false
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard components.isEmpty == false,
              components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
            return false
        }
        guard let first = components.first else { return false }
        return first.count < 2 || first[first.index(after: first.startIndex)] != ":"
    }
}
