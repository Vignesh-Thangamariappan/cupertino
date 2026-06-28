import CoreProtocols
@testable import Crawler
import CrawlerModels
import Foundation
import LoggingModels
import SharedConstants
import Testing

@Suite("Crawler.AppleDocs Markdown fallback", .serialized)
struct AppleDocsMarkdownFallbackTests {
    private static let arrayMarkdown = """
    ---
    source: https://developer.apple.com/documentation/swift/array
    ---

    # Array

    Structure# Array

    An ordered, random-access collection.

    ```swift
    struct Array<Element>
    ```

    ## Topics

    - [Dictionary](https://developer.apple.com/documentation/swift/dictionary)
    """

    @Test("rendered Markdown fallback writes structured JSON")
    @MainActor
    func renderedMarkdownFallbackWritesStructuredJSON() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cupertino-markdown-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = try Shared.Configuration(
            crawler: Shared.Configuration.Crawler(
                startURL: #require(URL(string: "https://developer.apple.com/documentation/swift/array")),
                maxPages: 1,
                maxDepth: 1,
                outputDirectory: tempDir,
                requestDelay: 0
            ),
            changeDetection: Shared.Configuration.ChangeDetection(
                forceRecrawl: true,
                outputDirectory: tempDir
            ),
            output: Shared.Configuration.Output(format: .markdown)
        )

        let crawler = await Crawler.AppleDocs(
            configuration: config,
            htmlParser: Crawler.NoopHTMLParserStrategy(),
            appleJSONParser: Crawler.NoopAppleJSONParserStrategy(),
            markdownParser: LiveTestMarkdownParserStrategy(),
            priorityPackageStrategy: Crawler.NoopPriorityPackageStrategy(),
            fetcherFactory: MarkdownFetcherFactory(markdown: Self.arrayMarkdown),
            logger: Logging.NoopRecording()
        )

        let stats = try await crawler.crawl()

        #expect(stats.totalPages == 1)
        let jsonURL = try #require(Self.findJSONFile(in: tempDir))
        let data = try Data(contentsOf: jsonURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let page = try decoder.decode(Shared.Models.StructuredDocumentationPage.self, from: data)
        #expect(page.title == "Array")
        #expect(page.url.absoluteString == "https://developer.apple.com/documentation/swift/array")
        #expect(try #require(page.rawMarkdown).contains("Structure# Array"))
    }

    private static func findJSONFile(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension == "json",
               file.lastPathComponent != "metadata.json" {
                return file
            }
        }
        return nil
    }
}

@MainActor
private struct MarkdownFetcherFactory: Crawler.HTTPFetcherFactory {
    let markdown: String

    func makeFetcher(
        pageLoadTimeout _: Duration,
        javascriptWaitTime _: Duration
    ) -> any Core.Protocols.StringContentFetcher {
        MarkdownFetcher(markdown: markdown)
    }
}

private struct MarkdownFetcher: Core.Protocols.StringContentFetcher {
    let markdown: String

    func fetch(url: URL) async throws -> Core.Protocols.FetchResult<String> {
        Core.Protocols.FetchResult(
            content: markdown,
            url: url,
            responseHeaders: ["content-type": "text/markdown; charset=utf-8"]
        )
    }
}
