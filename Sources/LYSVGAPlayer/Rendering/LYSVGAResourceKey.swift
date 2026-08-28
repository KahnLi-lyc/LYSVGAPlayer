import Foundation

enum LYSVGAResourceKey {
    private static let removableExtensions: Set<String> = [
        "matte", "vector", "png", "jpg", "jpeg", "webp",
    ]

    static func canonicalize(_ value: String) -> String {
        var result = value as NSString
        guard result.pathExtension.isEmpty == false else {
            return value
        }
        result = result.deletingPathExtension as NSString
        while removableExtensions.contains(result.pathExtension.lowercased()) {
            result = result.deletingPathExtension as NSString
        }
        return result as String
    }

    static func standardizeDynamicKey(_ value: String) -> String {
        var result = value as NSString
        while removableExtensions.contains(result.pathExtension.lowercased()) {
            result = result.deletingPathExtension as NSString
        }
        return result as String
    }
}
