import CryptoKit
import Foundation

enum LYSVGACacheKey {
    static func make(for source: LYSVGASource) throws -> String {
        switch source {
        case let .data(data, explicitKey):
            if let explicitKey {
                return sha256(Data("data:\(explicitKey)".utf8))
            }
            return sha256(data)
        case let .remote(url):
            guard let normalized = normalizedRemoteURL(url) else {
                throw LYSVGAError.invalidData("The remote URL is not absolute.")
            }
            return sha256(Data("remote:\(normalized.absoluteString)".utf8))
        case let .request(request):
            return try requestKey(request)
        case let .file(url):
            guard url.isFileURL else {
                throw LYSVGAError.fileFailure("A file source must use a file URL.")
            }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return sha256(Data("file:\(path):\(size):\(modified)".utf8))
            } catch {
                throw LYSVGAError.fileFailure(error.localizedDescription)
            }
        }
    }

    private static func requestKey(_ request: URLRequest) throws -> String {
        guard request.httpBodyStream == nil else {
            throw LYSVGAError.invalidRequest(
                "URLRequest.httpBodyStream is unsupported because it cannot be replayed safely."
            )
        }
        guard let url = request.url, let normalizedURL = normalizedRemoteURL(url) else {
            throw LYSVGAError.invalidRequest("The request URL must be absolute.")
        }

        let headers = (request.allHTTPHeaderFields ?? [:])
            .map { [$0.key.lowercased(), $0.value] }
            .sorted {
                if $0[0] == $1[0] { return $0[1] < $1[1] }
                return $0[0] < $1[0]
            }
        let identity: [String: Any] = [
            "allowsCellularAccess": request.allowsCellularAccess,
            "allowsConstrainedNetworkAccess": request.allowsConstrainedNetworkAccess,
            "allowsExpensiveNetworkAccess": request.allowsExpensiveNetworkAccess,
            "bodySHA256": request.httpBody.map(sha256) ?? "",
            "cachePolicy": request.cachePolicy.rawValue,
            "headers": headers,
            "httpMethod": (request.httpMethod ?? "GET").uppercased(),
            "httpShouldHandleCookies": request.httpShouldHandleCookies,
            "httpShouldUsePipelining": request.httpShouldUsePipelining,
            "networkServiceType": request.networkServiceType.rawValue,
            "timeoutInterval": request.timeoutInterval,
            "url": normalizedURL.absoluteString,
        ]
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        return sha256(Data("request:".utf8) + data)
    }

    private static func normalizedRemoteURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
