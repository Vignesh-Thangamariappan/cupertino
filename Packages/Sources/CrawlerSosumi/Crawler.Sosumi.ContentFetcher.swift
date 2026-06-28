import CoreProtocols
import CrawlerModels
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension Crawler.Sosumi {
    /// URLSession-backed Markdown fetcher for the Sosumi HTTP API.
    ///
    /// `URLSession` is internally synchronized and intentionally shared
    /// behind this immutable fetcher; Swift 6 cannot prove that through
    /// the Foundation overlay, so the conformance is marked unchecked.
    final class ContentFetcher: @unchecked Sendable, Core.Protocols.StringContentFetcher {
        private let baseURL: URL
        private let session: URLSession

        public init(baseURL: URL, timeout: TimeInterval = 30) {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout

            self.baseURL = Self.normalizedBaseURL(baseURL)
            session = URLSession(configuration: configuration)
        }

        init(baseURL: URL, session: URLSession) {
            self.baseURL = Self.normalizedBaseURL(baseURL)
            self.session = session
        }

        public func fetch(url: URL) async throws -> Core.Protocols.FetchResult<String> {
            let sosumiURL = try sosumiURL(for: url)
            var request = URLRequest(url: sosumiURL)
            request.setValue("text/markdown, text/plain;q=0.9", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw Error.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw Error.httpStatus(httpResponse.statusCode)
            }
            guard let content = String(data: data, encoding: .utf8) else {
                throw Error.invalidContentEncoding
            }

            let headers = Self.headers(from: httpResponse)
            let finalURL = headers["content-location"]
                .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
                ?? url

            return Core.Protocols.FetchResult(
                content: content,
                url: finalURL,
                responseHeaders: headers
            )
        }

        func sosumiURL(for url: URL) throws -> URL {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                throw Error.unsupportedURL(url)
            }

            if url.host?.lowercased() == "developer.apple.com" {
                return try appendingDeveloperPath(from: url)
            }

            return try externalURL(for: url)
        }

        private func appendingDeveloperPath(from url: URL) throws -> URL {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
                  let sourceComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else {
                throw Error.invalidSosumiURL(baseURL)
            }

            let basePath = components.percentEncodedPath.trimmingTrailingSlash
            components.percentEncodedPath = basePath + sourceComponents.percentEncodedPath
            components.percentEncodedQuery = sourceComponents.percentEncodedQuery

            guard let result = components.url else {
                throw Error.invalidSosumiURL(baseURL)
            }
            return result
        }

        private func externalURL(for url: URL) throws -> URL {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
                  let encodedSource = Self.externalSourcePathComponent(from: url)
            else {
                throw Error.invalidSosumiURL(baseURL)
            }

            let basePath = components.percentEncodedPath.trimmingTrailingSlash
            components.percentEncodedPath = "\(basePath)/external/\(encodedSource)"

            guard let result = components.url else {
                throw Error.invalidSosumiURL(baseURL)
            }
            return result
        }

        private static func headers(from response: HTTPURLResponse) -> [String: String] {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key.lowercased()] = String(describing: value)
            }
            return headers
        }

        private static func normalizedBaseURL(_ url: URL) -> URL {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            components.percentEncodedQuery = nil
            components.fragment = nil
            return components.url ?? url
        }

        private static func externalSourcePathComponent(from url: URL) -> String? {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed)
        }
    }
}

extension Crawler.Sosumi.ContentFetcher {
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case unsupportedURL(URL)
        case invalidSosumiURL(URL)
        case invalidResponse
        case httpStatus(Int)
        case invalidContentEncoding

        public var errorDescription: String? {
            switch self {
            case .unsupportedURL(let url):
                return "Unsupported Sosumi source URL: \(url.absoluteString)"
            case .invalidSosumiURL(let url):
                return "Invalid Sosumi base URL: \(url.absoluteString)"
            case .invalidResponse:
                return "Sosumi returned a non-HTTP response"
            case .httpStatus(let status):
                return "Sosumi returned HTTP \(status)"
            case .invalidContentEncoding:
                return "Sosumi response was not valid UTF-8"
            }
        }
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        var value = self
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
