import Foundation

public enum LYSVGASource: Sendable {
    case data(Data, cacheKey: String? = nil)
    case file(URL)
    case remote(URL)
    case request(URLRequest)

    public static func bundleResource(
        named name: String,
        withExtension fileExtension: String = "svga",
        subdirectory: String? = nil,
        in bundle: Bundle = .main
    ) throws -> LYSVGASource {
        let path = name as NSString
        let explicitExtension = path.pathExtension
        let resourceName = explicitExtension.isEmpty ? name : path.deletingPathExtension
        let resourceExtension = explicitExtension.isEmpty ? fileExtension : explicitExtension
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension.isEmpty ? nil : resourceExtension,
            subdirectory: subdirectory
        ) else {
            let filename = resourceExtension.isEmpty
                ? resourceName
                : "\(resourceName).\(resourceExtension)"
            throw LYSVGAError.missingResource(filename)
        }
        return .file(url)
    }
}

public enum LYSVGACachePolicy: Sendable {
    case automatic
    case reloadIgnoringCache
    case memoryOnly
    case noCache
}

public struct LYSVGACacheConfiguration: Sendable {
    public let directory: URL
    public let memoryCountLimit: Int
    public let memoryCostLimit: Int
    public let diskSizeLimit: Int
    public let timeToLive: TimeInterval

    public init(
        directory: URL,
        memoryCountLimit: Int = 32,
        memoryCostLimit: Int = 64 * 1_024 * 1_024,
        diskSizeLimit: Int = 256 * 1_024 * 1_024,
        timeToLive: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.directory = directory
        self.memoryCountLimit = max(0, memoryCountLimit)
        self.memoryCostLimit = max(0, memoryCostLimit)
        self.diskSizeLimit = max(0, diskSizeLimit)
        self.timeToLive = max(0, timeToLive)
    }

    public static var `default`: LYSVGACacheConfiguration {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LYSVGACacheConfiguration(directory: base.appendingPathComponent("LYSVGAPlayer", isDirectory: true))
    }
}
