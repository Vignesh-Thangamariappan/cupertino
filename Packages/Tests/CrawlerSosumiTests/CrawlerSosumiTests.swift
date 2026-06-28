import CrawlerModels
@testable import CrawlerSosumi
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Crawler.Sosumi.ContentFetcher", .serialized)
struct CrawlerSosumiTests {
    @Test("developer.apple.com URLs rewrite to Sosumi path and preserve Apple content-location")
    func developerURLFetchesMarkdown() async throws {
        SosumiStubURLProtocol.reset()
        defer { SosumiStubURLProtocol.reset() }

        SosumiStubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://sosumi.test/documentation/swift/array?changes=latest")
            #expect(request.value(forHTTPHeaderField: "Accept")?.contains("text/markdown") == true)

            guard let requestURL = request.url,
                  let response = HTTPURLResponse(
                      url: requestURL,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: [
                          "Content-Type": "text/markdown; charset=utf-8",
                          "Content-Location": "https://developer.apple.com/documentation/swift/array",
                      ]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data("# Array\n\nStructure# Array\n".utf8))
        }

        let fetcher = try makeFetcher()
        let sourceURL = try #require(URL(string: "https://developer.apple.com/documentation/swift/array?changes=latest"))
        let result = try await fetcher.fetch(url: sourceURL)

        #expect(result.content.contains("# Array"))
        #expect(result.url.absoluteString == "https://developer.apple.com/documentation/swift/array")
        #expect(result.responseHeaders?["content-type"] == "text/markdown; charset=utf-8")
    }

    @Test("external URLs rewrite under /external")
    func externalURLRewritesUnderExternalPath() throws {
        let fetcher = try makeFetcher()
        let sourceURL = try #require(URL(string: "https://apple.github.io/swift-docc-render/documentation/docc"))

        let sosumiURL = try fetcher.sosumiURL(for: sourceURL)

        #expect(sosumiURL.absoluteString == "https://sosumi.test/external/https%3A%2F%2Fapple.github.io%2Fswift-docc-render%2Fdocumentation%2Fdocc")
    }

    @Test("Sosumi docs fragments do not leak into external URL rewriting")
    func baseURLFragmentsAreIgnoredForExternalURLs() throws {
        let fetcher = try makeFetcher(baseURL: "https://sosumi.test/?ref=docs#http")
        let sourceURL = try #require(URL(string: "https://apple.github.io/swift-docc-render/documentation/docc?changes=latest#overview"))

        let sosumiURL = try fetcher.sosumiURL(for: sourceURL)

        #expect(
            sosumiURL.absoluteString ==
                "https://sosumi.test/external/https%3A%2F%2Fapple.github.io%2Fswift-docc-render%2Fdocumentation%2Fdocc%3Fchanges%3Dlatest%23overview"
        )
    }

    @Test("non-success HTTP status throws")
    func nonSuccessHTTPStatusThrows() async throws {
        SosumiStubURLProtocol.reset()
        defer { SosumiStubURLProtocol.reset() }

        SosumiStubURLProtocol.handler = { request in
            guard let requestURL = request.url,
                  let response = HTTPURLResponse(
                      url: requestURL,
                      statusCode: 503,
                      httpVersion: "HTTP/1.1",
                      headerFields: ["Content-Type": "text/plain"]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data("unavailable".utf8))
        }

        let fetcher = try makeFetcher()
        let sourceURL = try #require(URL(string: "https://developer.apple.com/documentation/swift/array"))

        do {
            _ = try await fetcher.fetch(url: sourceURL)
            Issue.record("Expected HTTP status error")
        } catch Crawler.Sosumi.ContentFetcher.Error.httpStatus(let status) {
            #expect(status == 503)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeFetcher(baseURL: String = "https://sosumi.test/") throws -> Crawler.Sosumi.ContentFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SosumiStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return try Crawler.Sosumi.ContentFetcher(
            baseURL: #require(URL(string: baseURL)),
            session: session
        )
    }
}

/// URLProtocol stores process-global hooks by design. Tests reset the
/// handler around every use, and Swift Testing runs this suite's URLSession
/// requests synchronously through the configured ephemeral session.
final class SosumiStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

    // `URLProtocol`'s public API requires `class func` overrides.
    // swiftlint:disable static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // swiftlint:enable static_over_final_class

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
